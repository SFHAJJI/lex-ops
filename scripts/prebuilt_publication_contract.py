#!/usr/bin/env python3
"""Pure validators for the prebuilt publication trust boundary."""

import json
from pathlib import Path
import sys


def fail(message):
    raise SystemExit(f"ERROR: {message}")


def read_json(path):
    try:
        with Path(path).open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, ValueError) as exception:
        fail(f"cannot read JSON contract input {path}: {exception}")


def normalize_etag(value):
    if not isinstance(value, str):
        return value
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def validate_benchmark(arguments):
    if len(arguments) != 7:
        fail(
            "usage: validate-benchmark REPORT PUBLISHER CODE CORPUS MANIFEST "
            "INDEX_SIZE VECTOR_SIZE"
        )
    report = read_json(arguments[0])
    publisher, code, corpus, manifest = arguments[1:5]
    try:
        index_size, vector_size = map(int, arguments[5:7])
    except ValueError:
        fail("benchmark artifact sizes must be integers")
    counts = {
        "lu-legilux": (37, 29, 8),
        "eu-eurlex": (163, 118, 45),
    }
    if publisher not in counts:
        fail("benchmark publisher is unsupported")
    sample_count, tuning_count, holdout_count = counts[publisher]
    cases_sha = "d952bb259a8a5bd8859056c9440bcc566127dbcc4f908bd1330b97de1b508f77"
    expected = {
        "schema": "lex-retrieval-benchmark/3",
        "sample_count": sample_count,
        "tuning_sample_count": tuning_count,
        "holdout_sample_count": holdout_count,
        "review_status": "reviewed",
        "baseline_schema": "lex-retrieval-baseline/2",
        "expected_cases_sha256": cases_sha,
        "actual_cases_sha256": cases_sha,
        "review_attestation": "repository-review:retrieval-v2-2026-08-09@2026-08-09",
        "activation_gate_passed": True,
        "gate_failures": [],
        "code_commit": code,
        "corpus_commit": corpus,
        "manifest_id": manifest,
        "model_id": "intfloat/multilingual-e5-small",
        "model_revision": "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        "machine": "github-actions-ubuntu-latest",
        "resource_configuration": "Container Apps Consumption target, 2 GiB configured limit",
        "memory_limit_bytes": 2147483648,
        "index_bytes": index_size,
        "vector_bytes": vector_size,
    }
    if not isinstance(report, dict) or any(
        report.get(key) != value for key, value in expected.items()
    ):
        fail("retrieval benchmark did not pass the exact activation gate")


def validate_staging_snapshot(arguments):
    validate_staging(arguments, allow_missing=False)


def validate_staging_cleanup_snapshot(arguments):
    validate_staging(arguments, allow_missing=True)


def validate_staging(arguments, allow_missing):
    if len(arguments) != 14:
        fail(
            "usage: validate-staging-snapshot SNAPSHOT PUBLISHER PREFIX TICKET "
            "CORPUS CODE ARTICLES GENERATION INDEX_SHA INDEX_ETAG INDEX_SIZE "
            "VECTORS_SHA VECTORS_ETAG VECTORS_SIZE"
        )
    (
        snapshot_path,
        publisher,
        prefix,
        ticket,
        corpus,
        code,
        articles,
        generation,
        index_sha,
        index_etag,
        index_size,
        vectors_sha,
        vectors_etag,
        vectors_size,
    ) = arguments
    try:
        index_size = int(index_size)
        vectors_size = int(vectors_size)
    except ValueError:
        fail("staging sizes must be integers")
    snapshot = read_json(snapshot_path)
    index = f"index-{publisher}.db"
    vectors = f"index-{publisher}.vectors"
    expected_names = {f"{prefix}/{index}", f"{prefix}/{vectors}"}
    actual_names = {
        item.get("name") for item in snapshot if isinstance(item, dict)
    } if isinstance(snapshot, list) else set()
    inventory_is_valid = (
        isinstance(snapshot, list)
        and len(actual_names) == len(snapshot)
        and (
            actual_names.issubset(expected_names)
            if allow_missing
            else actual_names == expected_names
        )
    )
    if not inventory_is_valid:
        fail("private staging inventory is not the exact DB/vector pair")
    common_metadata = {
        "articles_commit": articles,
        "articles_generation_sha256": generation,
        "build_code_commit": code,
        "collection": publisher,
        "corpus_commit": corpus,
        "queue_ticket_id": ticket,
    }
    expected = {
        f"{prefix}/{index}": {
            "sha": index_sha,
            "etag": index_etag,
            "size": index_size,
            "content_type": "application/vnd.sqlite3",
        },
        f"{prefix}/{vectors}": {
            "sha": vectors_sha,
            "etag": vectors_etag,
            "size": vectors_size,
            "content_type": "application/octet-stream",
        },
    }
    for item in snapshot:
        wanted = expected[item["name"]]
        if set(item) != {"metadata", "name", "properties"}:
            fail("normalized staging blob fields are not exact")
        properties = item["properties"]
        if not isinstance(properties, dict) or set(properties) != {
            "blobType",
            "contentLength",
            "contentSettings",
            "etag",
            "serverEncrypted",
        }:
            fail("normalized staging properties are not exact")
        if (
            properties["blobType"] != "BlockBlob"
            or properties["contentLength"] != wanted["size"]
            or properties["serverEncrypted"] is not True
            or properties["contentSettings"]
            != {"contentType": wanted["content_type"]}
            or normalize_etag(properties["etag"]) != wanted["etag"]
        ):
            fail("private staging properties differ from the dispatch snapshot")
        metadata = item["metadata"]
        wanted_metadata = {**common_metadata, "sha256": wanted["sha"]}
        if metadata != wanted_metadata:
            fail("private staging metadata is not canonical ticket evidence")


def validate_release(arguments):
    if len(arguments) != 5:
        fail("usage: validate-release RELEASE TAG_REF TAG CORPUS EXPECTED_ASSETS")
    release = read_json(arguments[0])
    tag_ref = read_json(arguments[1])
    tag, corpus = arguments[2:4]
    expected_assets = read_json(arguments[4])
    if (
        not isinstance(release, dict)
        or release.get("draft") is not False
        or release.get("prerelease") is not False
        or release.get("tag_name") != tag
        or release.get("target_commitish") != corpus
        or release.get("immutable") is not True
        or sorted(
            item.get("name") for item in release.get("assets", []) if isinstance(item, dict)
        )
        != sorted(expected_assets)
    ):
        fail("public GitHub release is not immutable and exact")
    tag_object = tag_ref.get("object", {})
    if (
        not isinstance(tag_object, dict)
        or tag_object.get("type") != "commit"
        or tag_object.get("sha") != corpus
    ):
        fail("release tag does not target the ticketed corpus commit")


COMMANDS = {
    "validate-benchmark": validate_benchmark,
    "validate-staging-snapshot": validate_staging_snapshot,
    "validate-staging-cleanup-snapshot": validate_staging_cleanup_snapshot,
    "validate-release": validate_release,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("unknown prebuilt publication-contract command")
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
