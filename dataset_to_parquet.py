#!/usr/bin/env python3
"""Convert Lex's bounded compressed JSONL datasets to Parquet."""

from __future__ import annotations

import argparse
import gzip
from pathlib import Path

import pyarrow
import pyarrow.json as pyarrow_json
import pyarrow.parquet as parquet


# EUR-Lex can publish very large annex tables. The current largest held JSONL row is
# 47,478,995 bytes, so the default PyArrow block (~1 MiB) cannot frame it. Keep the
# supported ceiling explicit: it bounds validation and PyArrow's conversion buffer.
MAXIMUM_JSON_ROW_BYTES = 64 * 1024 * 1024

DATASET_COLUMNS = (
    "provision_id",
    "lex_id",
    "anchor",
    "type",
    "num",
    "heading",
    "language",
    "valid_from",
    "valid_to",
    "article_valid_from",
    "title",
    "text_md",
    "text_sha256",
    "source_sha256",
    "source_uri",
    "profile",
    "license",
    "attribution",
)
DATASET_SCHEMA = pyarrow.schema((column, pyarrow.string()) for column in DATASET_COLUMNS)


def validate_rows(path: Path, maximum_row_bytes: int = MAXIMUM_JSON_ROW_BYTES) -> int:
    """Fail before conversion when one JSON object exceeds the declared row ceiling."""

    rows = 0
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rb") as source:
        while True:
            row = source.readline(maximum_row_bytes + 1)
            if not row:
                return rows
            rows += 1
            if len(row) > maximum_row_bytes:
                raise ValueError(
                    f"{path}: JSONL row {rows} exceeds the "
                    f"{maximum_row_bytes}-byte dataset ceiling"
                )


def convert(path: Path) -> Path:
    validate_rows(path)
    name = path.name.removesuffix(".gz").removesuffix(".jsonl") + ".parquet"
    output = path.with_name(name)
    temporary = output.with_suffix(output.suffix + ".tmp")
    batches = pyarrow_json.open_json(
        path,
        read_options=pyarrow_json.ReadOptions(block_size=MAXIMUM_JSON_ROW_BYTES),
        parse_options=pyarrow_json.ParseOptions(
            explicit_schema=DATASET_SCHEMA,
            unexpected_field_behavior="error",
        ),
    )
    try:
        with parquet.ParquetWriter(temporary, batches.schema, compression="zstd") as writer:
            for batch in batches:
                writer.write_batch(batch)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.files:
        output = convert(path)
        print(f"parquet: {output}")


if __name__ == "__main__":
    main()
