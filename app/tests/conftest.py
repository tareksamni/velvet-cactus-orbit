"""Shared test fixtures.

The application modules are top-level inside app/ (matching how they are laid
out in the container at /app), so the app directory goes on sys.path.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Iterator
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

APP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP_DIR))

TEST_BUCKET = "test-csv-uploads"


@pytest.fixture(autouse=True)
def _test_environment(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Point the app at a moto-backed bucket with dummy credentials.

    Credentials are set explicitly so a developer's real ~/.aws profile can
    never be picked up by the test suite.
    """
    monkeypatch.setenv("APP_S3_BUCKET", TEST_BUCKET)
    monkeypatch.setenv("APP_S3_PREFIX", "uploads")
    monkeypatch.setenv("APP_S3_REGION", "us-east-1")
    monkeypatch.setenv("APP_ENVIRONMENT", "test")
    monkeypatch.delenv("APP_S3_ENDPOINT_URL", raising=False)
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SECURITY_TOKEN": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": "us-east-1",
    }.items():
        monkeypatch.setenv(key, value)

    from config import get_settings

    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def s3_bucket() -> Iterator[str]:
    with mock_aws():
        boto3.client("s3", region_name="us-east-1").create_bucket(Bucket=TEST_BUCKET)
        yield TEST_BUCKET


@pytest.fixture
def client(s3_bucket: str) -> Iterator[object]:
    from fastapi.testclient import TestClient

    import main

    # Reset the module-level storage singleton so each test binds to its own
    # moto-mocked client.
    main._storage = None
    with TestClient(main.app) as test_client:
        yield test_client
    main._storage = None


@pytest.fixture
def sample_csv_bytes() -> bytes:
    return (Path(__file__).parent / "fixtures" / "sample.csv").read_bytes()


os.environ.setdefault("APP_ENVIRONMENT", "test")
