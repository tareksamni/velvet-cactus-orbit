"""CSV processing web application.

Serves both an HTML interface (the case study asks for a basic UI) and a typed
JSON API under /api/v1, so the generated OpenAPI document is a usable contract
rather than a description of form posts.

Static assets under app/static are copied into a shared emptyDir volume at pod
start and served by the nginx container in front of this app — see
charts/csv-app/templates/deployment.yaml. This app mounts them too so it can run
standalone during development.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import csv_parser
from config import Settings, get_settings
from schemas import (
    ErrorResponse,
    HealthResponse,
    ParsedRow,
    ParseErrorModel,
    ParseResultResponse,
    ProcessedFile,
    ProcessedFileList,
    ReadyResponse,
)
from storage import ObjectStorage, StorageError

BASE_DIR = Path(__file__).resolve().parent

logging.basicConfig(
    level=get_settings().log_level.upper(),
    format='{"level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
)
logger = logging.getLogger("csv_app")

templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    logger.info("starting %s in %s", settings.app_name, settings.environment)
    # No-op against real S3; creates the demo bucket when pointed at MinIO.
    ObjectStorage(settings).ensure_bucket()
    yield


app = FastAPI(
    lifespan=lifespan,
    title="CSV Processor",
    # Kept in step with Chart.appVersion and the published image tag, so the
    # version a client sees in /openapi.json matches the release it came from.
    version="1.1.0",
    summary="Upload, parse and archive stock-on-hand CSV exports.",
    description=(
        "Parses CSV files in the stock-on-hand export format "
        "(`sku`, `product_name`, `price`), renders the parsed lines, and archives "
        "the original file to S3-compatible object storage where a lifecycle "
        "policy transitions it to Glacier.\n\n"
        "Built for a DevOps case study — see `ASSUMPTIONS.md` in the repository."
    ),
    openapi_tags=[
        {"name": "api", "description": "JSON API for programmatic use."},
        {"name": "ui", "description": "Server-rendered HTML interface."},
        {"name": "ops", "description": "Health and readiness probes."},
    ],
)

app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

_storage: ObjectStorage | None = None


def get_storage(settings: Annotated[Settings, Depends(get_settings)]) -> ObjectStorage:
    global _storage
    if _storage is None:
        _storage = ObjectStorage(settings)
    return _storage


SettingsDep = Annotated[Settings, Depends(get_settings)]
StorageDep = Annotated[ObjectStorage, Depends(get_storage)]


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _validate_upload(upload: UploadFile, data: bytes, settings: Settings) -> None:
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Uploaded file is empty.")
    if len(data) > settings.max_upload_bytes:
        raise HTTPException(
            status.HTTP_413_CONTENT_TOO_LARGE,
            f"File exceeds the {settings.max_upload_bytes} byte limit.",
        )
    name = (upload.filename or "").lower()
    if not name.endswith(".csv"):
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "File is not a CSV.")


def _to_response(key: str, filename: str, result: csv_parser.ParseResult) -> ParseResultResponse:
    return ParseResultResponse(
        key=key,
        filename=filename,
        columns=list(result.columns),
        row_count=result.row_count,
        displayed_rows=len(result.rows),
        truncated=result.truncated,
        had_header=result.had_header,
        errors=[ParseErrorModel(line_number=e.line_number, reason=e.reason, raw=e.raw) for e in result.errors],
        rows=[ParsedRow(line_number=r.line_number, values=list(r.values)) for r in result.rows],
    )


def _process_upload(data: bytes, filename: str, storage: ObjectStorage, settings: Settings) -> ParseResultResponse:
    result = csv_parser.parse_bytes(data, max_rows=settings.max_rows_display)
    key = storage.build_key(filename)
    storage.put(key, data, row_count=result.row_count)
    logger.info("processed %s -> %s (%d rows, %d errors)", filename, key, result.row_count, result.error_count)
    return _to_response(key, filename, result)


# ---------------------------------------------------------------------------
# HTML interface
# ---------------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse, tags=["ui"], summary="Upload form and processed-file list")
def index(request: Request, storage: StorageDep, settings: SettingsDep) -> HTMLResponse:
    try:
        files = storage.list_processed(limit=settings.max_files_listed)
        storage_error = None
    except StorageError as exc:
        files, storage_error = [], str(exc)
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={"files": files, "settings": settings, "storage_error": storage_error},
    )


@app.post("/upload", response_class=HTMLResponse, tags=["ui"], summary="Upload a CSV via the web form")
async def upload_form(
    request: Request,
    storage: StorageDep,
    settings: SettingsDep,
    file: Annotated[UploadFile, File(description="CSV file to process.")],
) -> HTMLResponse:
    data = await file.read()
    _validate_upload(file, data, settings)
    try:
        parsed = _process_upload(data, file.filename or "upload.csv", storage, settings)
    except StorageError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"Object storage unavailable: {exc}") from exc
    return templates.TemplateResponse(
        request=request,
        name="view.html",
        context={"result": parsed, "settings": settings},
    )


@app.get("/files/{key:path}", response_class=HTMLResponse, tags=["ui"], summary="Re-read and display a stored file")
def view_file(request: Request, key: str, storage: StorageDep, settings: SettingsDep) -> HTMLResponse:
    try:
        data = storage.get(key)
    except StorageError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"No such file: {exc}") from exc
    result = csv_parser.parse_bytes(data, max_rows=settings.max_rows_display)
    parsed = _to_response(key, key.rsplit("/", 1)[-1], result)
    return templates.TemplateResponse(
        request=request,
        name="view.html",
        context={"result": parsed, "settings": settings},
    )


# ---------------------------------------------------------------------------
# JSON API
# ---------------------------------------------------------------------------


@app.post(
    "/api/v1/files",
    response_model=ParseResultResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["api"],
    summary="Upload and process a CSV file",
    responses={
        400: {"model": ErrorResponse, "description": "Empty file."},
        413: {"model": ErrorResponse, "description": "File too large."},
        415: {"model": ErrorResponse, "description": "Not a CSV file."},
        502: {"model": ErrorResponse, "description": "Object storage unavailable."},
    },
)
async def api_upload(
    storage: StorageDep,
    settings: SettingsDep,
    file: Annotated[UploadFile, File(description="CSV file to process.")],
) -> ParseResultResponse:
    data = await file.read()
    _validate_upload(file, data, settings)
    try:
        return _process_upload(data, file.filename or "upload.csv", storage, settings)
    except StorageError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"Object storage unavailable: {exc}") from exc


@app.get(
    "/api/v1/files",
    response_model=ProcessedFileList,
    tags=["api"],
    summary="List previously processed files",
    responses={502: {"model": ErrorResponse, "description": "Object storage unavailable."}},
)
def api_list(storage: StorageDep, settings: SettingsDep) -> ProcessedFileList:
    try:
        objects = storage.list_processed(limit=settings.max_files_listed)
    except StorageError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    files = [
        ProcessedFile(
            key=o.key,
            filename=o.filename,
            size_bytes=o.size_bytes,
            row_count=o.row_count,
            uploaded_at=o.uploaded_at,
        )
        for o in objects
    ]
    return ProcessedFileList(count=len(files), files=files)


@app.get(
    "/api/v1/files/{key:path}",
    response_model=ParseResultResponse,
    tags=["api"],
    summary="Re-parse a previously processed file",
    responses={404: {"model": ErrorResponse, "description": "No such object."}},
)
def api_get(key: str, storage: StorageDep, settings: SettingsDep) -> ParseResultResponse:
    try:
        data = storage.get(key)
    except StorageError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(exc)) from exc
    result = csv_parser.parse_bytes(data, max_rows=settings.max_rows_display)
    return _to_response(key, key.rsplit("/", 1)[-1], result)


# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------


@app.get("/healthz", response_model=HealthResponse, tags=["ops"], summary="Liveness probe")
def healthz(settings: SettingsDep) -> HealthResponse:
    """Liveness only — deliberately does not touch S3, so a storage outage
    restarts nothing."""
    return HealthResponse(status="ok", environment=settings.environment)


@app.get(
    "/readyz",
    response_model=ReadyResponse,
    tags=["ops"],
    summary="Readiness probe",
    responses={503: {"model": ErrorResponse, "description": "Object storage unreachable."}},
)
def readyz(storage: StorageDep) -> ReadyResponse:
    """Readiness — the pod cannot usefully serve traffic without object storage."""
    if not storage.ping():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Object storage unreachable.")
    return ReadyResponse(status="ready", storage="reachable")


@app.get("/favicon.ico", include_in_schema=False)
def favicon() -> RedirectResponse:
    return RedirectResponse(url="/static/favicon.svg", status_code=status.HTTP_307_TEMPORARY_REDIRECT)
