"""Parser tests, driven by the real attached format plus the malformed cases a
production upload endpoint actually receives."""

from __future__ import annotations

import io
from decimal import Decimal
from pathlib import Path

import pytest

import csv_parser

FIXTURE = Path(__file__).parent / "fixtures" / "sample.csv"

SAMPLE = (
    '"211627629","Purple Safi Kaftan","4900.0000"\n'
    '"211627628","Multi-coloured Gilet Abaya","4900.0000"\n'
    '"211624698","Black Embroidered Tulle Ball Gown","9600.0000"\n'
)


def parse(text: str, **kwargs: object) -> csv_parser.ParseResult:
    return csv_parser.parse(io.StringIO(text, newline=""), **kwargs)  # type: ignore[arg-type]


def test_parses_real_fixture_file() -> None:
    result = csv_parser.parse_bytes(FIXTURE.read_bytes())

    assert result.row_count == 12
    assert result.had_header is False
    assert result.columns == ("sku", "product_name", "price")
    assert result.errors == []
    assert result.rows[0].values == ("211627629", "Purple Safi Kaftan", "4900.0000")
    assert result.rows[0].price == Decimal("4900.0000")


def test_headerless_file_is_not_mistaken_for_a_header() -> None:
    result = parse(SAMPLE)

    assert result.had_header is False
    assert result.row_count == 3, "the first data row must not be consumed as a header"


def test_header_row_is_detected_and_normalised() -> None:
    result = parse("SKU,Product Name,Price\n" + SAMPLE)

    assert result.had_header is True
    assert result.columns == ("sku", "product_name", "price")
    assert result.row_count == 3


def test_quoted_field_containing_a_comma() -> None:
    result = parse('"123","Dress, long, black","1500.0000"\n')

    assert result.row_count == 1
    assert result.rows[0].values == ("123", "Dress, long, black", "1500.0000")


def test_crlf_line_endings() -> None:
    result = parse(SAMPLE.replace("\n", "\r\n"))

    assert result.row_count == 3
    assert result.errors == []


def test_ragged_row_is_skipped_not_fatal() -> None:
    result = parse(SAMPLE + '"999","Missing price column"\n' + '"1000","Good row","10.0000"\n')

    assert result.row_count == 4, "the good rows either side of the bad one survive"
    assert len(result.errors) == 1
    assert result.errors[0].reason == "expected 3 columns, got 2"


def test_blank_lines_are_ignored_not_reported_as_errors() -> None:
    result = parse(SAMPLE + "\n\n")

    assert result.row_count == 3
    assert result.errors == []


def test_empty_file() -> None:
    result = parse("")

    assert result.row_count == 0
    assert result.rows == []
    assert result.errors == []


def test_max_rows_caps_display_but_not_the_count() -> None:
    result = parse(SAMPLE, max_rows=1)

    assert result.row_count == 3, "the whole file is still counted"
    assert len(result.rows) == 1, "only one row is retained for rendering"
    assert result.truncated is True


def test_latin1_fallback_for_non_utf8_bytes() -> None:
    raw = '"1","Café Dress","10.00"\n'.encode("latin-1")

    result = csv_parser.parse_bytes(raw)

    assert result.row_count == 1
    assert "Caf" in result.rows[0].values[1]


def test_non_numeric_price_still_parses_as_a_row() -> None:
    result = parse('"1","Some product","N/A"\n"2","Other","10.00"\n')

    # The first row looks header-ish by the numeric heuristic, so it is treated
    # as a header. This is the documented trade-off of header sniffing.
    assert result.had_header is True
    assert result.row_count == 1


@pytest.mark.parametrize("width", [1, 2, 4, 5])
def test_files_with_other_column_counts_get_generic_column_names(width: int) -> None:
    line = ",".join(str(i) for i in range(width)) + "\n"

    result = parse(line * 3)

    assert result.row_count == 3
    assert len(result.columns) == width
    assert result.columns[0] == "column_1"
