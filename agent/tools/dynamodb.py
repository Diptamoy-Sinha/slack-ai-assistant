"""Cross-account DynamoDB read tools.

Assumes a reader role in the table's account via STS, then fetches a single
item by partition key. Table names are validated against an optional allowlist
so user-controlled input cannot reach arbitrary tables even when IAM is wider.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.types import TypeDeserializer
from strands import tool

from app_config import get_config

_SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,255}$")
_SAFE_VALUE = re.compile(r"^[A-Za-z0-9_.-]{1,1024}$")


class DynamoDbTool:
    MAX_CHARS = 30_000
    _REFRESH_BUFFER_SECONDS = 300

    def __init__(
        self,
        *,
        role_arn: str,
        external_id: str,
        region: str,
        table_allowlist: frozenset[str] | None,
    ):
        self.role_arn = role_arn
        self.external_id = external_id
        self.region = region
        self.table_allowlist = table_allowlist
        self._credentials: dict[str, Any] | None = None
        self._credentials_expire: datetime | None = None
        self._table_schemas: dict[str, dict[str, Any]] = {}

    def _validate_name(self, label: str, value: str) -> str | None:
        cleaned = value.strip()
        if not cleaned or not _SAFE_NAME.fullmatch(cleaned):
            return f"Invalid {label}: use letters, digits, underscore, dot, or hyphen."
        return None

    def _validate_value(self, label: str, value: str) -> str | None:
        cleaned = value.strip()
        if not cleaned or not _SAFE_VALUE.fullmatch(cleaned):
            return f"Invalid {label}: use letters, digits, underscore, dot, or hyphen."
        return None

    def _table_allowed(self, table_name: str) -> str | None:
        if self.table_allowlist is None:
            return None
        if table_name in self.table_allowlist:
            return None
        allowed = ", ".join(sorted(self.table_allowlist))
        return f"Table {table_name!r} is not allowed. Allowed tables: {allowed}."

    def _credentials_stale(self) -> bool:
        if self._credentials is None or self._credentials_expire is None:
            return True
        now = datetime.now(timezone.utc)
        remaining = (self._credentials_expire - now).total_seconds()
        return remaining <= self._REFRESH_BUFFER_SECONDS

    def _assume_role(self) -> dict[str, Any]:
        sts = boto3.client("sts", region_name=self.region)
        response = sts.assume_role(
            RoleArn=self.role_arn,
            RoleSessionName="slack-ai-assistant-dynamodb",
            ExternalId=self.external_id,
        )
        creds = response["Credentials"]
        self._credentials = {
            "aws_access_key_id": creds["AccessKeyId"],
            "aws_secret_access_key": creds["SecretAccessKey"],
            "aws_session_token": creds["SessionToken"],
        }
        expiration = creds["Expiration"]
        if expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=timezone.utc)
        self._credentials_expire = expiration
        return self._credentials

    def _ddb_client(self):
        if self._credentials_stale():
            self._assume_role()
        return boto3.client(
            "dynamodb",
            region_name=self.region,
            **self._credentials,  # type: ignore[arg-type]
        )

    def _deserialize_item(self, item: dict[str, Any]) -> dict[str, Any]:
        deserializer = TypeDeserializer()
        return {key: deserializer.deserialize(value) for key, value in item.items()}

    def _describe_table(self, table: str) -> dict[str, Any]:
        cached = self._table_schemas.get(table)
        if cached is not None:
            return cached

        response = self._ddb_client().describe_table(TableName=table)
        table_info = response["Table"]
        attr_types = {
            attr["AttributeName"]: attr["AttributeType"]
            for attr in table_info.get("AttributeDefinitions", [])
        }
        keys = {key["KeyType"]: key["AttributeName"] for key in table_info["KeySchema"]}
        schema = {
            "partition_key": keys["HASH"],
            "sort_key": keys.get("RANGE"),
            "attr_types": attr_types,
        }
        self._table_schemas[table] = schema
        return schema

    def _typed_value(self, attr_type: str, raw: str) -> dict[str, str]:
        if attr_type == "N":
            if not re.fullmatch(r"-?\d+(?:\.\d+)?", raw):
                raise ValueError(f"Expected a numeric value, got {raw!r}.")
            return {"N": raw}
        if attr_type == "B":
            raise ValueError("Binary keys are not supported.")
        return {"S": raw}

    def _client_error_message(self, exc: ClientError, table: str) -> str:
        code = exc.response.get("Error", {}).get("Code", "ClientError")
        detail = exc.response.get("Error", {}).get("Message", "")
        if code == "ResourceNotFoundException":
            return f"Table {table!r} was not found in {self.region}."
        if code in {"AccessDeniedException", "UnauthorizedException"}:
            return "Access denied reading that table."
        if detail:
            return f"DynamoDB error ({code}): {detail}"
        return f"DynamoDB error ({code})."

    def _format_items(self, items: list[dict[str, Any]], *, table: str, lookup: str) -> str:
        if not items:
            return f"No item found in {table!r} with {lookup}."

        payload = [self._deserialize_item(item) for item in items]
        if len(payload) == 1:
            text = json.dumps(payload[0], indent=2, default=str)
        else:
            text = json.dumps(payload, indent=2, default=str)

        if len(text) > self.MAX_CHARS:
            return text[: self.MAX_CHARS] + f"\n... (truncated, {len(text)} chars total)"
        return text

    @tool
    def get_dynamodb_item(
        self,
        table_name: str,
        item_id: str,
        partition_key: str = "id",
        sort_key_value: str | None = None,
    ) -> str:
        """Fetch one DynamoDB item by its partition key.

        Use this for Todo lookups and other configured tables. The Todo table
        uses partition key ``id`` (string) and sort key ``createdAt`` (number).
        Pass only ``item_id`` (e.g. ``todo-001``); the tool queries by partition
        key when a sort key is also defined on the table. Provide
        ``sort_key_value`` only when you know the full composite key.

        Args:
            table_name: DynamoDB table name, e.g. ``Todo``.
            item_id: Partition-key value for the item to fetch.
            partition_key: Partition-key attribute name. Defaults to ``id``.
            sort_key_value: Optional sort-key value when the table has one.
        """
        for label, value, validator in (
            ("table name", table_name, self._validate_name),
            ("item id", item_id, self._validate_value),
            ("partition key", partition_key, self._validate_name),
        ):
            if err := validator(label, value):
                return err

        if sort_key_value is not None:
            if err := self._validate_value("sort key value", sort_key_value):
                return err

        table = table_name.strip()
        if err := self._table_allowed(table):
            return err

        pk_name = partition_key.strip()
        pk_value = item_id.strip()

        try:
            schema = self._describe_table(table)
        except ClientError as exc:
            return self._client_error_message(exc, table)

        actual_pk = schema["partition_key"]
        if pk_name != actual_pk:
            return (
                f"Table {table!r} uses partition key {actual_pk!r}, not "
                f"{pk_name!r}. Retry with partition_key={actual_pk!r}."
            )

        pk_type = schema["attr_types"][actual_pk]
        try:
            pk_typed = self._typed_value(pk_type, pk_value)
        except ValueError as exc:
            return str(exc)

        client = self._ddb_client()
        sort_key = schema.get("sort_key")

        try:
            if sort_key and sort_key_value is None:
                response = client.query(
                    TableName=table,
                    KeyConditionExpression="#pk = :pk",
                    ExpressionAttributeNames={"#pk": actual_pk},
                    ExpressionAttributeValues={":pk": pk_typed},
                    Limit=10,
                )
                lookup = f"{actual_pk}={pk_value!r}"
                return self._format_items(response.get("Items", []), table=table, lookup=lookup)

            key = {actual_pk: pk_typed}
            if sort_key:
                sk_type = schema["attr_types"][sort_key]
                key[sort_key] = self._typed_value(sk_type, sort_key_value.strip())

            response = client.get_item(TableName=table, Key=key)
        except ClientError as exc:
            return self._client_error_message(exc, table)
        except ValueError as exc:
            return str(exc)

        lookup = f"{actual_pk}={pk_value!r}"
        if sort_key and sort_key_value is not None:
            lookup += f", {sort_key}={sort_key_value!r}"
        return self._format_items(
            [response["Item"]] if response.get("Item") else [],
            table=table,
            lookup=lookup,
        )

    def tools(self) -> list:
        return [self.get_dynamodb_item]


def _parse_allowlist(raw: str | None) -> frozenset[str] | None:
    if raw is None or not raw.strip():
        return None
    names = {part.strip() for part in raw.split(",") if part.strip()}
    return frozenset(names) if names else None


def dynamodb_tools() -> DynamoDbTool | None:
    """Create DynamoDB tools when cross-account reader config is present."""
    config = get_config()
    if not config.ddb_reader_role_arn or not config.ddb_external_id:
        return None
    return DynamoDbTool(
        role_arn=config.ddb_reader_role_arn,
        external_id=config.ddb_external_id,
        region=config.ddb_region or config.aws_region,
        table_allowlist=_parse_allowlist(config.ddb_table_allowlist),
    )
