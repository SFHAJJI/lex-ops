import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

import pyarrow.parquet as parquet

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dataset_to_parquet import MAXIMUM_JSON_ROW_BYTES, convert, validate_rows


class DatasetToParquetTests(unittest.TestCase):
    def test_large_compressed_json_object_converts(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "eu-eurlex-provisions.jsonl.gz"
            payload = {"provision_id": "annex_i", "text_md": "x" * (3 * 1024 * 1024)}
            with gzip.open(source, "wt", encoding="utf-8") as stream:
                stream.write(json.dumps(payload) + "\n")

            output = convert(source)

            table = parquet.read_table(output)
            self.assertEqual(1, table.num_rows)
            self.assertEqual(payload["text_md"], table.column("text_md")[0].as_py())

    def test_row_over_the_declared_ceiling_fails_before_conversion(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "provisions.jsonl.gz"
            with gzip.open(source, "wb") as stream:
                stream.write(b"x" * 65 + b"\n")

            with self.assertRaisesRegex(ValueError, "object on row 1 exceeds the 64-byte"):
                validate_rows(source, maximum_row_bytes=64)

    def test_row_ceiling_excludes_line_delimiters(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            lf = Path(root) / "lf.jsonl.gz"
            crlf = Path(root) / "crlf.jsonl.gz"
            with gzip.open(lf, "wb") as stream:
                stream.write(b"x" * 64 + b"\n")
            with gzip.open(crlf, "wb") as stream:
                stream.write(b"x" * 64 + b"\r\n")

            self.assertEqual(1, validate_rows(lf, maximum_row_bytes=64))
            self.assertEqual(1, validate_rows(crlf, maximum_row_bytes=64))

    def test_date_like_values_remain_strings_across_streaming_batches(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "lu-legilux-provisions.jsonl.gz"
            with gzip.open(source, "wt", encoding="utf-8") as stream:
                stream.write(json.dumps({"provision_id": "first", "valid_from": "2022-01-01"}) + "\n")
                stream.write(json.dumps({"provision_id": "second", "valid_from": "20220101"}) + "\n")

            table = parquet.read_table(convert(source))

            self.assertEqual(["2022-01-01", "20220101"], table.column("valid_from").to_pylist())

    def test_ceiling_covers_the_observed_eur_lex_annex(self) -> None:
        self.assertGreater(MAXIMUM_JSON_ROW_BYTES, 47_478_995)


if __name__ == "__main__":
    unittest.main()
