#!/usr/bin/env python3
"""Pure validators for the prebuilt publication trust boundary."""

import hashlib
import json
from pathlib import Path
import re
import sys


COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
ETAG = re.compile(r"^0x[0-9A-F]+$")
TICKET = re.compile(r"^[0-9a-f]{64}$")

LEGACY_POINTERS = {
    "eu-eurlex": {
        "manifest": "2da4d2039b549ced38afbd305f9625e1190bf2118f5f765eef30d36a0c45c0d5",
        "pointer_sha": "a460020a374eaeb7adbcd87fdbeaeb231055e9efd4767422c5940a3f9cf842dc",
        "corpus": "7595e12ba31920fe6229f707f13eb5b8effa05c7",
        "published_at": "2026-08-14T04:29:37Z",
        "created_at": "2026-08-14T04:32:59Z",
        "files": [
            "eu-scope.json", "eu-work-enrichment.json", "index-eu-eurlex.db",
            "index-eu-eurlex.vectors", "model-manifest.json", "model.onnx",
            "sentencepiece.bpe.model",
        ],
    },
    "lu-legilux": {
        "manifest": "bb5a115b01262fbe486bd7c9f66e0941910aaf35bd23ee17caf7447b89b8a308",
        "pointer_sha": "6b25b34ab4e773c9f7b417183dc04dcc813c60ed96571fe636818d914aa215c0",
        "corpus": "69a4bec429c5afd73261e6959ca42c9ca796d567",
        "published_at": "2026-08-13T14:48:40Z",
        "created_at": "2026-08-13T14:51:44Z",
        "files": [
            "index-lu-legilux.db", "index-lu-legilux.vectors",
            "model-manifest.json", "model.onnx", "sentencepiece.bpe.model",
        ],
    },
}


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
    if len(arguments) != 8:
        fail(
            "usage: validate-benchmark REPORT PUBLISHER CODE CORPUS MANIFEST "
            "INDEX_SIZE VECTOR_SIZE EXPECTED_ACTIVATION"
        )
    report = read_json(arguments[0])
    publisher, code, corpus, manifest = arguments[1:5]
    expected_activation = arguments[7]
    if expected_activation not in {"true", "false"}:
        fail("expected benchmark activation must be true or false")
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
        fail("retrieval benchmark identity or frozen baseline differs")
    activation = report.get("activation_gate_passed")
    failures = report.get("gate_failures")
    if activation is not (expected_activation == "true"):
        fail("retrieval benchmark activation differs from its process result")
    if activation:
        if failures != []:
            fail("activated retrieval benchmark must have no gate failures")
    elif (
        not isinstance(failures, list)
        or not failures
        or any(not isinstance(item, str) or not item.strip() for item in failures)
    ):
        fail("quarantined retrieval benchmark must have typed gate failures")


def validate_staging_snapshot(arguments):
    validate_staging(arguments, allow_missing=False)


def validate_staging_cleanup_snapshot(arguments):
    validate_staging(arguments, allow_missing=True)


def validate_legacy_pointer(arguments):
    if len(arguments) != 3:
        fail("usage: validate-legacy-pointer POINTER MANIFEST PUBLISHER")
    pointer_path = Path(arguments[0])
    pointer = read_json(pointer_path)
    manifest_path = Path(arguments[1])
    manifest = read_json(manifest_path)
    publisher = arguments[2]
    expected = LEGACY_POINTERS.get(publisher)
    if expected is None:
        fail("legacy pointer publisher is unsupported")
    try:
        pointer_bytes = pointer_path.read_bytes()
        manifest_bytes = manifest_path.read_bytes()
    except OSError as exception:
        fail(f"cannot read legacy manifest bytes: {exception}")
    if hashlib.sha256(pointer_bytes).hexdigest() != expected["pointer_sha"]:
        fail("legacy pointer bytes are not the exact frozen locator")
    if hashlib.sha256(manifest_bytes).hexdigest() != expected["manifest"]:
        fail("legacy manifest bytes are not the exact frozen release")
    expected_pointer = {
        "schema": "lex-artifact-pointer/1",
        "collection": publisher,
        "manifest_sha256": expected["manifest"],
        "prefix": f"releases/{publisher}/{expected['manifest']}",
        "corpus_commit": expected["corpus"],
        "published_at": expected["published_at"],
    }
    if pointer != expected_pointer:
        fail("legacy pointer is not the exact frozen release locator")
    expected_sources = {
        "articles_commit": "f95da3e9ce88baebc99d4b3d307679feca8c1d50",
        "build_origin": "hash-pinned-private-staging",
        "collection": publisher,
        "corpus_commit": expected["corpus"],
        "publication_tool_commit": "51e33b406475fa7ff7014d21d94ef2ae1c3c3ed4",
        "queue_commit": "7510ba2dccd3a99a02fb020faea2d074c43e1a54",
    }
    if (
        not isinstance(manifest, dict)
        or set(manifest) != {
            "algorithm", "code_commit", "created_at", "files", "key_id",
            "schema", "sources",
        }
        or manifest.get("schema") != "lex-artifacts/1"
        or manifest.get("algorithm") != "ECDSA-P256-SHA256"
        or manifest.get("key_id") != "keyvault-lex-v2"
        or manifest.get("code_commit") != "51e33b406475fa7ff7014d21d94ef2ae1c3c3ed4"
        or manifest.get("created_at") != expected["created_at"]
        or manifest.get("sources") != expected_sources
        or not isinstance(manifest.get("files"), list)
    ):
        fail("legacy signed manifest identity is not exact")
    files = manifest["files"]
    if [item.get("path") for item in files if isinstance(item, dict)] != expected["files"]:
        fail("legacy signed manifest inventory is not exact")
    for item in files:
        if (
            set(item) != {"kind", "path", "sha256", "size"}
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", item["path"])
            or not isinstance(item["kind"], str)
            or not item["kind"]
            or not isinstance(item["size"], int)
            or item["size"] <= 0
            or not isinstance(item["sha256"], str)
            or not DIGEST.fullmatch(item["sha256"])
        ):
            fail("legacy signed manifest file entry is invalid")
    print("\n".join(expected["files"]))


def validate_lineage_receipt(arguments):
    if len(arguments) != 4:
        fail("usage: validate-lineage-receipt RECEIPT POINTER PUBLISHER GUARD")
    receipt = read_json(arguments[0])
    pointer = read_json(arguments[1])
    publisher, guard = arguments[2:4]
    if publisher not in {"lu-legilux", "eu-eurlex"} or not COMMIT.fullmatch(guard):
        fail("lineage publisher or runtime guard is invalid")
    if not isinstance(receipt, dict) or not isinstance(pointer, dict):
        fail("lineage receipt and pointer must be objects")

    pointer_v1_keys = {
        "collection", "corpus_commit", "manifest_sha256", "prefix",
        "published_at", "schema",
    }
    pointer_v2_keys = {
        "benchmark_manifest_sha256", "collection", "corpus_commit",
        "manifest_sha256", "published_at", "receipt_manifest_sha256",
        "release_repository", "release_tag", "schema", "semantic_activation",
    }
    pointer_schema = pointer.get("schema")
    if pointer_schema == "lex-artifact-pointer/1":
        if set(pointer) != pointer_v1_keys:
            fail("legacy lineage pointer keys are not exact")
    elif pointer_schema == "lex-artifact-pointer/2":
        if set(pointer) != pointer_v2_keys:
            fail("GitHub lineage pointer keys are not exact")
    else:
        fail("lineage pointer schema is unsupported")
    if (
        pointer.get("collection") != publisher
        or not isinstance(pointer.get("corpus_commit"), str)
        or not COMMIT.fullmatch(pointer["corpus_commit"])
        or not isinstance(pointer.get("manifest_sha256"), str)
        or not DIGEST.fullmatch(pointer["manifest_sha256"])
        or not isinstance(pointer.get("published_at"), str)
        or not pointer["published_at"]
    ):
        fail("lineage pointer identity is invalid")

    v1_keys = {
        "articles_commit", "build_code_commit", "corpus_commit", "generated_at",
        "index_manifest_sha256", "previous_pointer", "public_assets", "publisher",
        "purpose", "queue_ticket_id", "release_tag", "schema", "staging",
        "staging_prefix",
    }
    v2_keys = {
        "articles_commit", "benchmark_manifest_sha256", "build_code_commit",
        "corpus_commit", "generated_at", "index_manifest_sha256", "previous_pointer",
        "public_assets", "publisher", "purpose", "queue_commit", "queue_ticket_id",
        "release_repository", "release_tag", "run_id", "schema",
        "semantic_activation", "staging", "staging_prefix", "workflow_commit",
    }
    receipt_schema = receipt.get("schema")
    if receipt_schema == "lex-staging-cleanup-receipt/1":
        if set(receipt) != v1_keys or pointer_schema != "lex-artifact-pointer/1":
            fail("legacy cleanup receipt shape or pointer pairing is invalid")
        has_sizes = False
    elif receipt_schema == "lex-staging-cleanup-receipt/2":
        if set(receipt) != v2_keys or pointer_schema != "lex-artifact-pointer/2":
            fail("cleanup receipt v2 shape or pointer pairing is invalid")
        has_sizes = True
    elif receipt_schema == "lex-staging-cleanup-receipt/3":
        if (
            set(receipt) != v2_keys | {"runtime_guard_commit"}
            or pointer_schema != "lex-artifact-pointer/2"
            or receipt.get("runtime_guard_commit") != guard
        ):
            fail("cleanup receipt v3 guard, shape or pointer pairing is invalid")
        has_sizes = True
    else:
        fail("cleanup receipt schema is unsupported")

    ticket = receipt.get("queue_ticket_id")
    prefix = f"staging/{publisher}/{ticket}"
    if (
        receipt.get("purpose") != "delete-exact-published-prebuilt-staging"
        or receipt.get("publisher") != publisher
        or not isinstance(ticket, str)
        or not TICKET.fullmatch(ticket)
        or receipt.get("staging_prefix") != prefix
        or receipt.get("release_tag") != f"index-{publisher}-{ticket}"
        or receipt.get("corpus_commit") != pointer["corpus_commit"]
        or receipt.get("index_manifest_sha256") != pointer["manifest_sha256"]
        or receipt.get("generated_at") != pointer["published_at"]
        or not isinstance(receipt.get("build_code_commit"), str)
        or not COMMIT.fullmatch(receipt["build_code_commit"])
        or not isinstance(receipt.get("articles_commit"), str)
        or not COMMIT.fullmatch(receipt["articles_commit"])
    ):
        fail("cleanup receipt does not bind the pointer identity")

    if receipt_schema == "lex-staging-cleanup-receipt/1":
        if pointer.get("prefix") != f"releases/{publisher}/{pointer['manifest_sha256']}":
            fail("legacy pointer release prefix is invalid")
    elif (
        pointer.get("release_repository") != f"SFHAJJI/lex-corpus-{publisher}"
        or pointer.get("release_tag") != receipt.get("release_tag")
        or receipt.get("release_repository") != pointer.get("release_repository")
        or receipt.get("benchmark_manifest_sha256")
        != pointer.get("benchmark_manifest_sha256")
        or not isinstance(pointer.get("semantic_activation"), bool)
        or receipt.get("semantic_activation") != pointer.get("semantic_activation")
        or not isinstance(pointer.get("receipt_manifest_sha256"), str)
        or not DIGEST.fullmatch(pointer["receipt_manifest_sha256"])
        or not isinstance(receipt.get("queue_commit"), str)
        or not COMMIT.fullmatch(receipt["queue_commit"])
        or not isinstance(receipt.get("workflow_commit"), str)
        or not COMMIT.fullmatch(receipt["workflow_commit"])
        or not isinstance(receipt.get("run_id"), str)
        or not receipt["run_id"]
        or not isinstance(receipt.get("benchmark_manifest_sha256"), str)
        or not DIGEST.fullmatch(receipt["benchmark_manifest_sha256"])
        or not isinstance(receipt.get("semantic_activation"), bool)
    ):
        fail("GitHub cleanup receipt does not bind the pointer identity")

    previous = receipt.get("previous_pointer")
    if not isinstance(previous, dict) or set(previous) != {"etag", "exists", "sha256"}:
        fail("cleanup receipt previous pointer is not exact")
    if previous.get("exists") is True:
        valid_etag = isinstance(previous.get("etag"), str) and (
            bool(previous["etag"]) if not has_sizes else bool(ETAG.fullmatch(previous["etag"]))
        )
        if (
            not valid_etag
            or not isinstance(previous.get("sha256"), str)
            or not DIGEST.fullmatch(previous["sha256"])
        ):
            fail("cleanup receipt previous pointer snapshot is invalid")
    elif (
        previous.get("exists") is not False
        or previous.get("etag") is not None
        or previous.get("sha256") is not None
    ):
        fail("cleanup receipt absent previous pointer is invalid")

    staging = receipt.get("staging")
    if not isinstance(staging, dict) or set(staging) != {"index", "vectors"}:
        fail("cleanup receipt staging pair is not exact")
    for kind, suffix in (
        ("index", f"index-{publisher}.db"),
        ("vectors", f"index-{publisher}.vectors"),
    ):
        item = staging.get(kind)
        keys = {"etag", "name", "sha256"} | ({"size"} if has_sizes else set())
        if (
            not isinstance(item, dict)
            or set(item) != keys
            or item.get("name") != f"{prefix}/{suffix}"
            or not isinstance(item.get("etag"), str)
            or (has_sizes and not ETAG.fullmatch(item["etag"]))
            or (not has_sizes and not item["etag"])
            or not isinstance(item.get("sha256"), str)
            or not DIGEST.fullmatch(item["sha256"])
            or (
                has_sizes
                and (
                    not isinstance(item.get("size"), int)
                    or isinstance(item["size"], bool)
                    or item["size"] <= 0
                )
            )
        ):
            fail("cleanup receipt staging item is invalid")

    assets = receipt.get("public_assets")
    if not isinstance(assets, list) or not assets:
        fail("cleanup receipt public asset inventory is absent")
    names = []
    for asset in assets:
        if (
            not isinstance(asset, dict)
            or set(asset) != {"name", "sha256", "size"}
            or not isinstance(asset.get("name"), str)
            or not re.fullmatch(r"[A-Za-z0-9._-]+", asset["name"])
            or not isinstance(asset.get("sha256"), str)
            or not DIGEST.fullmatch(asset["sha256"])
            or not isinstance(asset.get("size"), int)
            or isinstance(asset["size"], bool)
            or asset["size"] < 0
            or (has_sizes and asset["size"] >= 2147483648)
        ):
            fail("cleanup receipt public asset inventory is invalid")
        names.append(asset["name"])
    if len(names) != len(set(names)):
        fail("cleanup receipt public asset names are duplicated")


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
        not isinstance(expected_assets, list)
        or not expected_assets
        or any(
            not isinstance(asset, dict)
            or set(asset) != {"name", "sha256", "size"}
            or not isinstance(asset["name"], str)
            or not isinstance(asset["sha256"], str)
            or len(asset["sha256"]) != 64
            or not isinstance(asset["size"], int)
            or isinstance(asset["size"], bool)
            or asset["size"] < 0
            or asset["size"] >= 2147483648
            for asset in expected_assets
        )
        or len({asset["name"] for asset in expected_assets}) != len(expected_assets)
    ):
        fail("expected GitHub release assets are not exact")
    release_assets = release.get("assets", []) if isinstance(release, dict) else []
    actual_by_name = {
        asset.get("name"): asset
        for asset in release_assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    if (
        not isinstance(release, dict)
        or release.get("draft") is not False
        or release.get("prerelease") is not False
        or release.get("tag_name") != tag
        or release.get("target_commitish") != corpus
        or release.get("immutable") is not True
        or len(actual_by_name) != len(release_assets)
        or set(actual_by_name) != {asset["name"] for asset in expected_assets}
    ):
        fail("public GitHub release is not immutable and exact")
    for expected in expected_assets:
        actual = actual_by_name[expected["name"]]
        if (
            actual.get("state") != "uploaded"
            or actual.get("size") != expected["size"]
            or actual.get("digest") != "sha256:" + expected["sha256"]
        ):
            fail("GitHub release asset digest or size differs")
    tag_object = tag_ref.get("object", {})
    if (
        not isinstance(tag_object, dict)
        or tag_object.get("type") != "commit"
        or tag_object.get("sha") != corpus
    ):
        fail("release tag does not target the ticketed corpus commit")


def validate_immutable_release_setting(arguments):
    if len(arguments) != 1:
        fail("usage: validate-immutable-release-setting SETTING")
    setting = read_json(arguments[0])
    if not isinstance(setting, dict) or setting.get("enabled") is not True:
        fail("repository immutable releases are not enabled")


COMMANDS = {
    "validate-benchmark": validate_benchmark,
    "validate-lineage-receipt": validate_lineage_receipt,
    "validate-legacy-pointer": validate_legacy_pointer,
    "validate-staging-snapshot": validate_staging_snapshot,
    "validate-staging-cleanup-snapshot": validate_staging_cleanup_snapshot,
    "validate-release": validate_release,
    "validate-immutable-release-setting": validate_immutable_release_setting,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("unknown prebuilt publication-contract command")
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
