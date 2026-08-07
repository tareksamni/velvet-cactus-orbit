"""API tests: the upload -> parse -> archive -> list round trip, against a
moto-mocked S3. Same code path that talks to MinIO locally and real S3 in AWS."""

from __future__ import annotations

from typing import Any

CSV_HEADERS = {"content-type": "text/csv"}


def upload(client: Any, data: bytes, filename: str = "soh.csv") -> Any:
    return client.post("/api/v1/files", files={"file": (filename, data, "text/csv")})


def test_upload_parses_and_archives(client: Any, sample_csv_bytes: bytes) -> None:
    response = upload(client, sample_csv_bytes)

    assert response.status_code == 201
    body = response.json()
    assert body["row_count"] == 12
    assert body["columns"] == ["sku", "product_name", "price"]
    assert body["rows"][0]["values"][1] == "Purple Safi Kaftan"
    assert body["key"].startswith("uploads/")
    assert body["key"].endswith("-soh.csv")


def test_uploaded_file_appears_in_the_processed_list(client: Any, sample_csv_bytes: bytes) -> None:
    key = upload(client, sample_csv_bytes).json()["key"]

    listed = client.get("/api/v1/files").json()

    assert listed["count"] == 1
    assert listed["files"][0]["key"] == key
    assert listed["files"][0]["size_bytes"] == len(sample_csv_bytes)


def test_stored_file_can_be_re_parsed_from_storage(client: Any, sample_csv_bytes: bytes) -> None:
    key = upload(client, sample_csv_bytes).json()["key"]

    response = client.get(f"/api/v1/files/{key}")

    assert response.status_code == 200
    assert response.json()["row_count"] == 12


def test_row_count_is_stamped_into_object_metadata(client: Any, sample_csv_bytes: bytes, s3_bucket: str) -> None:
    import boto3

    key = upload(client, sample_csv_bytes).json()["key"]

    head = boto3.client("s3", region_name="us-east-1").head_object(Bucket=s3_bucket, Key=key)

    assert head["Metadata"]["row-count"] == "12"


def test_empty_upload_is_rejected(client: Any) -> None:
    assert upload(client, b"").status_code == 400


def test_non_csv_upload_is_rejected(client: Any) -> None:
    response = client.post("/api/v1/files", files={"file": ("notes.txt", b"hello", "text/plain")})

    assert response.status_code == 415


def test_oversized_upload_is_rejected(client: Any, monkeypatch: Any) -> None:
    from config import get_settings

    get_settings.cache_clear()
    monkeypatch.setenv("APP_MAX_UPLOAD_BYTES", "10")
    get_settings.cache_clear()

    response = upload(client, b'"1","Product name here","10.00"\n')

    assert response.status_code == 413


def test_missing_object_returns_404(client: Any) -> None:
    assert client.get("/api/v1/files/uploads/2020/01/01/nope.csv").status_code == 404


def test_html_index_renders(client: Any) -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert "Upload a CSV" in response.text


def test_html_upload_prints_the_lines_to_the_browser(client: Any, sample_csv_bytes: bytes) -> None:
    response = client.post("/upload", files={"file": ("soh.csv", sample_csv_bytes, "text/csv")})

    assert response.status_code == 200
    # The case study asks for the file's lines to be printed to the browser.
    assert "Purple Safi Kaftan" in response.text
    assert "Black Embroidered Tulle Ball Gown" in response.text


def test_healthz_does_not_depend_on_storage(client: Any) -> None:
    assert client.get("/healthz").json()["status"] == "ok"


def test_readyz_reports_storage_reachable(client: Any) -> None:
    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.json()["storage"] == "reachable"


def test_openapi_document_is_served_and_typed(client: Any) -> None:
    spec = client.get("/openapi.json").json()

    assert spec["info"]["title"] == "CSV Processor"
    assert "/api/v1/files" in spec["paths"]
    assert "ParseResultResponse" in spec["components"]["schemas"]
