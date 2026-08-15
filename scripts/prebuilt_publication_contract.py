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
    if len(arguments) != 4:
        fail("usage: validate-benchmark REPORT CODE CORPUS MANIFEST")
    report = read_json(arguments[0])
    expected = {
        "activation_gate_passed": True,
        "gate_failures": [],
        "code_commit": arguments[1],
        "corpus_commit": arguments[2],
        "manifest_id": arguments[3],
    }
    if not isinstance(report, dict) or any(
        report.get(key) != value for key, value in expected.items()
    ):
        fail("retrieval benchmark did not pass the exact activation gate")


def validate_staging_snapshot(arguments):
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
    if (
        not isinstance(snapshot, list)
        or len(snapshot) != 2
        or {item.get("name") for item in snapshot if isinstance(item, dict)}
        != expected_names
    ):
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
    if tag_ref.get("object") != {"type": "commit", "sha": corpus}:
        fail("release tag does not target the ticketed corpus commit")


COMMANDS = {
    "validate-benchmark": validate_benchmark,
    "validate-staging-snapshot": validate_staging_snapshot,
    "validate-release": validate_release,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("unknown prebuilt publication-contract command")
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
