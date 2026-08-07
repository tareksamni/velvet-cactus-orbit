"""Storage-layer tests, including the startup-resilience behaviour that keeps a
pod alive while object storage is still coming up."""

from __future__ import annotations

import pytest

from config import Settings
from storage import ObjectStorage, StorageError, _safe_filename


def test_startup_bucket_check_never_raises_when_storage_is_unreachable() -> None:
    """Regression: a pod must still start when MinIO is not up yet.

    Readiness holds traffic back until storage is reachable. Note that
    botocore raises NoCredentialsError (a BotoCoreError, not a ClientError)
    when it cannot sign a request, which previously escaped and killed the
    process during startup.
    """
    settings = Settings(
        s3_endpoint_url="http://127.0.0.1:9",
        s3_bucket="unreachable",
        s3_connect_timeout=1,
        s3_max_attempts=1,
    )

    ObjectStorage(settings).ensure_bucket()  # must not raise


def test_ping_reports_false_rather_than_raising_when_storage_is_down() -> None:
    settings = Settings(
        s3_endpoint_url="http://127.0.0.1:9",
        s3_bucket="unreachable",
        s3_connect_timeout=1,
        s3_max_attempts=1,
    )

    assert ObjectStorage(settings).ping() is False


def test_storage_errors_are_wrapped_not_leaked_as_boto_exceptions() -> None:
    settings = Settings(
        s3_endpoint_url="http://127.0.0.1:9",
        s3_bucket="unreachable",
        s3_connect_timeout=1,
        s3_max_attempts=1,
    )
    storage = ObjectStorage(settings)

    with pytest.raises(StorageError):
        storage.list_processed()


@pytest.mark.parametrize(
    ("supplied", "expected"),
    [
        ("soh.csv", "soh.csv"),
        ("../../etc/passwd", "passwd"),
        ("C:\\Users\\bob\\stock file.csv", "stock-file.csv"),
        ("", "upload.csv"),
        ("../../../", "upload.csv"),
    ],
)
def test_uploaded_filenames_cannot_escape_the_key_prefix(supplied: str, expected: str) -> None:
    assert _safe_filename(supplied) == expected


def test_object_key_is_date_partitioned_and_unique() -> None:
    storage = ObjectStorage(Settings(s3_prefix="uploads"))

    first = storage.build_key("soh.csv")
    second = storage.build_key("soh.csv")

    assert first.startswith("uploads/")
    assert first.endswith("-soh.csv")
    assert first != second, "keys must not collide when the same filename is uploaded twice"
