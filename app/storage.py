"""Object storage access.

One boto3 client serves both environments. `APP_S3_ENDPOINT_URL` pointed at the
in-cluster MinIO service gives the local demo; leaving it unset makes boto3 talk
to real AWS S3. The application code is identical either way, which is the point
— the locally exercised path is the same code that would run in production.

There is deliberately no database. "Previously processed files" is answered by
listing the bucket, which keeps the app stateless so the HPA can scale it
horizontally without shared state. See docs/adr/0005.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import PurePosixPath
from typing import IO, Any

import boto3
from botocore.client import Config
from botocore.exceptions import BotoCoreError, ClientError

from config import Settings

logger = logging.getLogger(__name__)


class StorageError(RuntimeError):
    """Raised when object storage cannot satisfy a request."""


@dataclass(frozen=True)
class StoredObject:
    key: str
    filename: str
    size_bytes: int
    row_count: int | None
    uploaded_at: datetime | None


def _safe_filename(name: str) -> str:
    """Strip any path components and characters that complicate S3 keys."""
    base = PurePosixPath(name.replace("\\", "/")).name or "upload.csv"
    cleaned = "".join(c if c.isalnum() or c in "._-" else "-" for c in base)
    return cleaned[:120] or "upload.csv"


class ObjectStorage:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._bucket = settings.s3_bucket
        self._prefix = settings.s3_prefix.strip("/")

        # Bounded timeouts and retries matter here: with botocore's defaults an
        # unreachable endpoint blocks for around a minute, which is long enough
        # to stall application startup and fail the liveness probe while MinIO
        # is still coming up. Fail fast and let Kubernetes retry the probe.
        config_kwargs: dict[str, Any] = {
            "connect_timeout": settings.s3_connect_timeout,
            "read_timeout": settings.s3_read_timeout,
            "retries": {"max_attempts": settings.s3_max_attempts, "mode": "standard"},
        }
        # MinIO only supports path-style addressing; real S3 accepts both.
        if settings.s3_force_path_style or settings.s3_endpoint_url:
            config_kwargs["s3"] = {"addressing_style": "path"}

        client_kwargs: dict[str, Any] = {
            "region_name": settings.s3_region,
            "config": Config(**config_kwargs),
        }
        if settings.s3_endpoint_url:
            client_kwargs["endpoint_url"] = settings.s3_endpoint_url
        if settings.s3_access_key_id and settings.s3_secret_access_key:
            client_kwargs["aws_access_key_id"] = settings.s3_access_key_id
            client_kwargs["aws_secret_access_key"] = settings.s3_secret_access_key

        self._client = boto3.client("s3", **client_kwargs)

    # -- writes ------------------------------------------------------------

    def build_key(self, filename: str) -> str:
        now = datetime.now(UTC)
        unique = uuid.uuid4().hex[:8]
        return f"{self._prefix}/{now:%Y/%m/%d}/{unique}-{_safe_filename(filename)}"

    def put(self, key: str, body: bytes | IO[bytes], *, row_count: int | None = None) -> None:
        metadata: dict[str, str] = {"uploaded-at": datetime.now(UTC).isoformat()}
        if row_count is not None:
            metadata["row-count"] = str(row_count)
        try:
            self._client.put_object(
                Bucket=self._bucket,
                Key=key,
                Body=body,
                ContentType="text/csv",
                Metadata=metadata,
            )
        except (ClientError, BotoCoreError) as exc:
            raise StorageError(f"could not store object {key}: {exc}") from exc

    # -- reads -------------------------------------------------------------

    def get(self, key: str) -> bytes:
        try:
            response = self._client.get_object(Bucket=self._bucket, Key=key)
            body: bytes = response["Body"].read()
            return body
        except (ClientError, BotoCoreError) as exc:
            raise StorageError(f"could not read object {key}: {exc}") from exc

    def list_processed(self, limit: int = 100) -> list[StoredObject]:
        """List archived files, newest first.

        Note the trade-off: this is a bucket listing, not an indexed query. It
        is correct and cheap at case-study scale; at very high object counts a
        real deployment would maintain an index (DynamoDB, or S3 Inventory).
        """
        try:
            paginator = self._client.get_paginator("list_objects_v2")
            pages = paginator.paginate(
                Bucket=self._bucket,
                Prefix=f"{self._prefix}/",
                PaginationConfig={"MaxItems": limit * 5},
            )
            # Typed as Any because the concrete TypedDict differs between
            # boto3-stubs versions; only Key/Size/LastModified are read.
            contents: list[Any] = []
            for page in pages:
                contents.extend(page.get("Contents", []))
        except (ClientError, BotoCoreError) as exc:
            raise StorageError(f"could not list bucket {self._bucket}: {exc}") from exc

        # S3 returns timezone-aware timestamps; the fallback must be aware too
        # or the sort raises on any object missing LastModified.
        epoch = datetime.min.replace(tzinfo=UTC)
        contents.sort(key=lambda item: item.get("LastModified") or epoch, reverse=True)

        objects: list[StoredObject] = []
        for item in contents[:limit]:
            key = item["Key"]
            objects.append(
                StoredObject(
                    key=key,
                    filename=PurePosixPath(key).name,
                    size_bytes=int(item.get("Size", 0)),
                    row_count=None,
                    uploaded_at=item.get("LastModified"),
                )
            )
        return objects

    def head_row_count(self, key: str) -> int | None:
        """Read the row-count we stamped into object metadata at upload time."""
        try:
            response = self._client.head_object(Bucket=self._bucket, Key=key)
        except (ClientError, BotoCoreError):
            return None
        raw = response.get("Metadata", {}).get("row-count")
        return int(raw) if raw and raw.isdigit() else None

    # -- health ------------------------------------------------------------

    def ping(self) -> bool:
        """Readiness check: can we reach the bucket?"""
        try:
            self._client.head_bucket(Bucket=self._bucket)
            return True
        except (ClientError, BotoCoreError) as exc:
            logger.warning("storage not reachable: %s", exc)
            return False

    def ensure_bucket(self) -> None:
        """Create the bucket if it is missing.

        Only ever used against MinIO in the local demo — in AWS the bucket is
        owned by Terraform, and the application's IAM policy does not include
        s3:CreateBucket.
        """
        if not self._settings.s3_endpoint_url:
            return
        # This runs during application startup, so it must never raise: if
        # storage is not up yet the pod should still start and let the
        # readiness probe hold traffic back until it is. Note that
        # NoCredentialsError is a BotoCoreError, not a ClientError — catching
        # only the latter here would crash the process at boot.
        try:
            self._client.head_bucket(Bucket=self._bucket)
            return
        except (ClientError, BotoCoreError) as exc:
            logger.info("bucket %s not reachable yet (%s); attempting to create it", self._bucket, exc)

        try:
            self._client.create_bucket(Bucket=self._bucket)
            logger.info("created bucket %s", self._bucket)
        except (ClientError, BotoCoreError) as exc:
            logger.warning("could not create bucket %s: %s", self._bucket, exc)
