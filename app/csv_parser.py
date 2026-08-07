"""CSV parsing for the stock-on-hand export format.

The attached sample (`soh.csv`) is headerless, quoted, three columns:

    "211627629","Purple Safi Kaftan","4900.0000"
     sku         product_name        price

No schema was provided with the case study, so the column meanings are inferred
from the data (see ASSUMPTIONS.md). The parser is deliberately tolerant: it
accepts an optional header row, quoted fields containing commas, CRLF line
endings, and ragged rows — a bad line is recorded as an error and skipped rather
than aborting the whole file, because one malformed row should not cost the
other 749.

Standard library only; no pandas for a three-column file.
"""

from __future__ import annotations

import csv
import io
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation

# Column names used when the file has no header row, matching the sample format.
DEFAULT_COLUMNS: tuple[str, ...] = ("sku", "product_name", "price")

# csv's default field size limit is generous but not unbounded; a single field
# larger than this is a malformed file, not a legitimate product name.
MAX_FIELD_SIZE = 1024 * 1024


@dataclass(frozen=True)
class Row:
    """One parsed data row."""

    line_number: int
    values: tuple[str, ...]
    # Populated only when the row matches the expected 3-column shape.
    price: Decimal | None = None

    def as_dict(self, columns: tuple[str, ...]) -> dict[str, str]:
        return dict(zip(columns, self.values, strict=False))


@dataclass(frozen=True)
class ParseError:
    line_number: int
    reason: str
    raw: str


@dataclass
class ParseResult:
    columns: tuple[str, ...]
    rows: list[Row] = field(default_factory=list)
    errors: list[ParseError] = field(default_factory=list)
    had_header: bool = False
    # Total data rows seen in the file, which may exceed len(rows) when the
    # caller passed a display limit.
    total_rows: int = 0
    truncated: bool = False

    @property
    def row_count(self) -> int:
        return self.total_rows

    @property
    def error_count(self) -> int:
        return len(self.errors)


def _looks_like_header(values: list[str]) -> bool:
    """Decide whether the first row is a header or data.

    The sample format's last column is always a decimal price. If the last
    field does not parse as a number, we are almost certainly looking at
    column titles.
    """
    if not values:
        return False
    if len(values) != len(DEFAULT_COLUMNS):
        # Unknown shape: fall back to a text heuristic on the whole row.
        return not any(_is_number(v) for v in values)
    return not _is_number(values[-1])


def _is_number(value: str) -> bool:
    try:
        Decimal(value.strip())
    except (InvalidOperation, ValueError):
        return False
    return True


def _to_price(value: str) -> Decimal | None:
    try:
        return Decimal(value.strip())
    except (InvalidOperation, ValueError):
        return None


def _normalise_header(values: list[str]) -> tuple[str, ...]:
    return tuple(v.strip().strip('"').lower().replace(" ", "_") or f"column_{i + 1}" for i, v in enumerate(values))


def parse(
    stream: io.TextIOBase,
    *,
    max_rows: int | None = None,
) -> ParseResult:
    """Parse a CSV stream into a :class:`ParseResult`.

    Args:
        stream: text-mode file-like object, already decoded.
        max_rows: cap on how many rows are *retained* for display. The full file
            is still read so ``total_rows`` and errors stay accurate.
    """
    previous_limit = csv.field_size_limit()
    csv.field_size_limit(MAX_FIELD_SIZE)
    try:
        reader = csv.reader(stream)
        result = ParseResult(columns=DEFAULT_COLUMNS)
        expected_width: int | None = None

        for index, raw_values in enumerate(reader, start=1):
            # Skip blank lines rather than reporting them as errors; trailing
            # newlines at end of file are normal, not malformed.
            if not raw_values or all(not v.strip() for v in raw_values):
                continue

            if expected_width is None:
                if _looks_like_header(raw_values):
                    result.columns = _normalise_header(raw_values)
                    result.had_header = True
                    expected_width = len(raw_values)
                    continue
                expected_width = len(raw_values)
                if expected_width == len(DEFAULT_COLUMNS):
                    result.columns = DEFAULT_COLUMNS
                else:
                    result.columns = tuple(f"column_{i + 1}" for i in range(expected_width))

            if len(raw_values) != expected_width:
                result.errors.append(
                    ParseError(
                        line_number=index,
                        reason=f"expected {expected_width} columns, got {len(raw_values)}",
                        raw=",".join(raw_values)[:200],
                    )
                )
                continue

            result.total_rows += 1

            if max_rows is not None and len(result.rows) >= max_rows:
                result.truncated = True
                continue

            values = tuple(v.strip() for v in raw_values)
            price = _to_price(values[-1]) if len(values) == len(DEFAULT_COLUMNS) else None
            result.rows.append(Row(line_number=index, values=values, price=price))

        return result
    finally:
        csv.field_size_limit(previous_limit)


def parse_bytes(data: bytes, *, max_rows: int | None = None, encoding: str = "utf-8") -> ParseResult:
    """Convenience wrapper for an in-memory upload.

    Decodes as UTF-8 with a latin-1 fallback, since exports of this kind are
    frequently produced by systems that are vague about encoding.
    """
    try:
        text = data.decode(encoding)
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    # newline="" is required so the csv module handles quoted embedded newlines.
    return parse(io.StringIO(text, newline=""), max_rows=max_rows)
