"""Pydantic response models.

These exist so the OpenAPI document generated at /openapi.json is a real
contract rather than a list of untyped endpoints. Every JSON route declares one
of these as its ``response_model``.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class ParsedRow(BaseModel):
    """A single data row from the uploaded CSV."""

    line_number: int = Field(..., description="1-indexed line in the source file.", examples=[1])
    values: list[str] = Field(
        ...,
        description="Field values in column order.",
        examples=[["211627629", "Purple Safi Kaftan", "4900.0000"]],
    )


class ParseErrorModel(BaseModel):
    """A line that could not be parsed. The rest of the file is still processed."""

    line_number: int
    reason: str = Field(..., examples=["expected 3 columns, got 2"])
    raw: str = Field(..., description="Truncated copy of the offending line.")


class ProcessedFile(BaseModel):
    """Summary of a file that has been parsed and archived to object storage."""

    key: str = Field(..., description="Object storage key.", examples=["uploads/2026/08/07/9f2c-soh.csv"])
    filename: str = Field(..., examples=["soh.csv"])
    size_bytes: int = Field(..., examples=[45720])
    row_count: int | None = Field(
        None, description="Rows counted at upload time, from object metadata.", examples=[750]
    )
    uploaded_at: datetime | None = None


class ParseResultResponse(BaseModel):
    """The result of parsing an uploaded or previously stored CSV."""

    key: str
    filename: str
    columns: list[str] = Field(..., examples=[["sku", "product_name", "price"]])
    row_count: int = Field(..., description="Total data rows in the file.", examples=[750])
    displayed_rows: int = Field(..., description="Rows included in this response (capped by APP_MAX_ROWS_DISPLAY).")
    truncated: bool = Field(..., description="True when the file has more rows than were returned.")
    had_header: bool
    errors: list[ParseErrorModel] = Field(default_factory=list)
    rows: list[ParsedRow] = Field(default_factory=list)


class ProcessedFileList(BaseModel):
    """Previously processed files, newest first."""

    count: int
    files: list[ProcessedFile]


class HealthResponse(BaseModel):
    status: str = Field(..., examples=["ok"])
    environment: str = Field(..., examples=["dev"])


class ReadyResponse(BaseModel):
    status: str = Field(..., examples=["ready"])
    storage: str = Field(..., description="Object storage reachability.", examples=["reachable"])


class ErrorResponse(BaseModel):
    detail: str = Field(..., examples=["File is not a CSV."])
