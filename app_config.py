"""Application configuration loaded once at startup.

Local: reads from ``.env`` (via python-dotenv).
AWS:   reads a JSON secret from AWS Secrets Manager (``APP_SECRETS_ARN`` or
       ``APP_SECRETS_NAME``), then exposes values through ``get_config()`` and
       ``os.environ`` for libraries that expect env vars.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

logger = logging.getLogger(__name__)

_config: AppConfig | None = None


@dataclass(frozen=True)
class AppConfig:
    slack_bot_token: str
    slack_app_token: str
    openai_api_key: str
    slack_api_url: str = "https://slack.com/api"
    tavily_api_key: str | None = None
    session_backend: str = "file"
    local_session_dir: str = ".sessions"
    s3_session_bucket: str | None = None
    s3_session_prefix: str = "sessions"
    aws_region: str = "us-east-1"
    s3_auto_create_bucket: bool = False


def _config_source() -> str:
    explicit = os.getenv("CONFIG_SOURCE", "").strip().lower()
    if explicit in {"env", "dotenv", "local"}:
        return "local"
    if explicit in {"secrets_manager", "aws"}:
        return "aws"
    if os.getenv("APP_SECRETS_ARN") or os.getenv("APP_SECRETS_NAME"):
        return "aws"
    return "local"


def _load_local_values() -> dict[str, str]:
    from dotenv import load_dotenv

    load_dotenv(dotenv_path=".env", override=False)

    keys = [
        "SLACK_BOT_TOKEN",
        "SLACK_APP_TOKEN",
        "OPENAI_API_KEY",
        "SLACK_API_URL",
        "TAVILY_API_KEY",
        "SESSION_BACKEND",
        "LOCAL_SESSION_DIR",
        "S3_SESSION_BUCKET",
        "S3_SESSION_PREFIX",
        "AWS_REGION",
        "S3_AUTO_CREATE_BUCKET",
    ]
    return {key: value for key in keys if (value := os.getenv(key))}


def _load_secrets_manager_values() -> dict[str, str]:
    import boto3
    from botocore.exceptions import ClientError

    secret_id = os.getenv("APP_SECRETS_ARN") or os.getenv("APP_SECRETS_NAME")
    if not secret_id:
        raise RuntimeError(
            "CONFIG_SOURCE is secrets_manager but APP_SECRETS_ARN or "
            "APP_SECRETS_NAME is not set"
        )

    region = os.getenv("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)

    try:
        response = client.get_secret_value(SecretId=secret_id)
    except ClientError as exc:
        raise RuntimeError(f"Failed to load secret {secret_id!r}") from exc

    secret_string = response.get("SecretString")
    if not secret_string:
        raise RuntimeError(f"Secret {secret_id!r} has no SecretString payload")

    payload = json.loads(secret_string)
    if not isinstance(payload, dict):
        raise RuntimeError(f"Secret {secret_id!r} must be a JSON object")

    values: dict[str, str] = {}
    for key, value in payload.items():
        if value is None:
            continue
        if not isinstance(key, str):
            continue
        values[key] = str(value)
    return values


def _require(values: dict[str, str], key: str) -> str:
    value = values.get(key, "").strip()
    if not value:
        raise RuntimeError(f"Missing required config value: {key}")
    return value


def _optional(
    values: dict[str, str], key: str, default: str | None = None
) -> str | None:
    value = values.get(key)
    if value is None or not str(value).strip():
        return default
    return str(value).strip()


def _as_bool(value: str | None) -> bool:
    return (value or "").lower() in {"1", "true", "yes"}


def _build_config(values: dict[str, str]) -> AppConfig:
    return AppConfig(
        slack_bot_token=_require(values, "SLACK_BOT_TOKEN"),
        slack_app_token=_require(values, "SLACK_APP_TOKEN"),
        openai_api_key=_require(values, "OPENAI_API_KEY"),
        slack_api_url=_optional(values, "SLACK_API_URL", "https://slack.com/api")
        or "https://slack.com/api",
        tavily_api_key=_optional(values, "TAVILY_API_KEY"),
        session_backend=_optional(values, "SESSION_BACKEND", "file") or "file",
        local_session_dir=_optional(values, "LOCAL_SESSION_DIR", ".sessions")
        or ".sessions",
        s3_session_bucket=_optional(values, "S3_SESSION_BUCKET"),
        s3_session_prefix=_optional(values, "S3_SESSION_PREFIX", "sessions")
        or "sessions",
        aws_region=_optional(values, "AWS_REGION", "us-east-1") or "us-east-1",
        s3_auto_create_bucket=_as_bool(_optional(values, "S3_AUTO_CREATE_BUCKET")),
    )


def _apply_to_environ(config: AppConfig) -> None:
    """Mirror config into os.environ for third-party libraries."""
    mapping: dict[str, str | None] = {
        "SLACK_BOT_TOKEN": config.slack_bot_token,
        "SLACK_APP_TOKEN": config.slack_app_token,
        "OPENAI_API_KEY": config.openai_api_key,
        "SLACK_API_URL": config.slack_api_url,
        "TAVILY_API_KEY": config.tavily_api_key,
        "SESSION_BACKEND": config.session_backend,
        "LOCAL_SESSION_DIR": config.local_session_dir,
        "S3_SESSION_BUCKET": config.s3_session_bucket,
        "S3_SESSION_PREFIX": config.s3_session_prefix,
        "AWS_REGION": config.aws_region,
        "S3_AUTO_CREATE_BUCKET": "true" if config.s3_auto_create_bucket else "false",
    }
    for key, value in mapping.items():
        if value is not None:
            os.environ[key] = value


def init_config() -> AppConfig:
    """Load configuration once and make it available via ``get_config()``."""
    global _config
    if _config is not None:
        return _config

    source = _config_source()
    if source == "local":
        logger.info("Loading config from .env")
        values = _load_local_values()
    else:
        logger.info("Loading config from AWS Secrets Manager")
        values = _load_secrets_manager_values()

    config = _build_config(values)
    _apply_to_environ(config)
    _config = config
    return config


def get_config() -> AppConfig:
    if _config is None:
        raise RuntimeError(
            "Config not initialized. Call init_config() at application startup."
        )
    return _config
