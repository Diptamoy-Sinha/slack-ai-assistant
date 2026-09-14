import hashlib
import os
import re
from typing import Any

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from strands import _identifier
from strands.session import FileSessionManager, S3SessionManager
from strands.session.repository_session_manager import RepositorySessionManager
from strands.types.exceptions import SessionException

from app_config import get_config

_USER_ID_PATTERN = re.compile(r"^[a-f0-9]{64}$")
DEFAULT_AGENT_ID = "default"


class SessionBackendError(Exception):
    """Session storage backend is misconfigured."""


def user_storage_key(email: str) -> str:
    normalized = email.strip().lower()
    return hashlib.sha256(normalized.encode()).hexdigest()


def _resolve_user_id(email: str) -> str:
    if _USER_ID_PATTERN.fullmatch(email):
        return email
    return user_storage_key(email)


def ensure_session_backend() -> None:
    config = get_config()
    bucket = config.s3_session_bucket
    if not bucket:
        raise SessionBackendError("S3_SESSION_BUCKET must be set")

    if config.s3_auto_create_bucket:
        create_bucket(bucket)
    else:
        verify_bucket(bucket)


def verify_bucket(bucket_name: str) -> None:
    region = get_config().aws_region
    try:
        s3 = boto3.client("s3", region_name=region)
        s3.head_bucket(Bucket=bucket_name)
    except NoCredentialsError as exc:
        raise SessionBackendError(
            "AWS credentials not found. Mount ~/.aws into the container or set "
            "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
        ) from exc
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in ("404", "NoSuchBucket"):
            raise SessionBackendError(f"S3 bucket {bucket_name} does not exist") from exc
        raise SessionBackendError(f"Cannot access S3 bucket {bucket_name}: {exc}") from exc
    except Exception as exc:
        raise SessionBackendError(f"Cannot access S3 bucket {bucket_name}: {exc}") from exc


def create_bucket(bucket_name: str) -> None:
    region = get_config().aws_region
    try:
        s3 = boto3.client("s3", region_name=region)
        params: dict[str, Any] = {"Bucket": bucket_name}
        if region != "us-east-1":
            params["CreateBucketConfiguration"] = {"LocationConstraint": region}
        s3.create_bucket(**params)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("BucketAlreadyExists", "BucketAlreadyOwnedByYou"):
            pass
        else:
            raise SessionBackendError(f"Failed to create bucket {bucket_name}: {e}") from e
    except Exception as e:
        raise SessionBackendError(f"Failed to create bucket {bucket_name}: {e}") from e


def _session_backend() -> str:
    return get_config().session_backend.strip().lower()


def _local_storage_dir(user_id: str) -> str:
    base_dir = get_config().local_session_dir
    resolved_user_id = _resolve_user_id(user_id)
    return os.path.join(base_dir, resolved_user_id)


def build_session_manager(user_id: str, session_id: str) -> RepositorySessionManager:
    if _session_backend() == "file":
        return FileSessionManager(
            session_id=session_id,
            storage_dir=_local_storage_dir(user_id),
        )

    config = get_config()
    ensure_session_backend()
    resolved_user_id = _resolve_user_id(user_id)
    bucket = config.s3_session_bucket
    assert bucket is not None
    base_prefix = config.s3_session_prefix.strip("/")
    prefix = f"{base_prefix}/users/{resolved_user_id}"

    return S3SessionManager(
        session_id=session_id,
        bucket=bucket,
        prefix=prefix,
        region_name=config.aws_region,
    )


def _validate_session_id(session_id: str) -> str:
    return _identifier.validate(session_id, _identifier.Identifier.SESSION)


def _extract_text(message: dict[str, Any]) -> str:
    parts: list[str] = []
    for block in message.get("content", []):
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            parts.append(block["text"])
    return "\n".join(parts)


def get_session_messages(
    user_id: str,
    session_id: str,
    agent_id: str = DEFAULT_AGENT_ID,
) -> list[dict[str, Any]] | None:
    session_id = _validate_session_id(session_id)
    manager = build_session_manager(user_id, session_id)

    if manager._is_new_session:
        manager.session_repository.delete_session(session_id)
        return None

    messages = manager.session_repository.list_messages(session_id, agent_id)
    result: list[dict[str, Any]] = []
    for session_message in messages:
        message = session_message.to_message()
        role = message.get("role")
        if role not in ("user", "assistant"):
            continue

        text = _extract_text(message)
        if not text:
            continue

        result.append(
            {
                "message_id": session_message.message_id,
                "role": role,
                "content": text,
                "created_at": session_message.created_at,
            }
        )
    return result


def delete_session(user_id: str, session_id: str) -> bool:
    session_id = _validate_session_id(session_id)
    manager = build_session_manager(user_id, session_id)

    if manager._is_new_session:
        manager.session_repository.delete_session(session_id)
        return False

    try:
        manager.session_repository.delete_session(session_id)
    except SessionException:
        return False
    return True
