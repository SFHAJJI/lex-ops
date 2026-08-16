#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import re
import sys


MAXIMUM_REPORT_BYTES = 4 * 1024 * 1024
CODE_COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
REVISION = re.compile(r"^ca-lex-web--[a-z0-9-]+$")
RELEASE = re.compile(r"^assistant-eval-[0-9a-f]{12}-[0-9a-f]{12}$")
RUN_IDENTITY = re.compile(r"^[0-9a-f]{16}$")
REPORT_SCHEMA = "lex-assistant-eval-report/3"


def nested(document, *path):
    current = document
    for part in path:
        if not isinstance(current, dict) or part not in current:
            raise ValueError(f"report is missing {'.'.join(path)}")
        current = current[part]
    return current


def matching_string(document, pattern, *path):
    value = nested(document, *path)
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ValueError(f"report has invalid {'.'.join(path)}")
    return value


def validate(report_path, expected_revision, expected_release):
    if not REVISION.fullmatch(expected_revision):
        raise ValueError("invalid candidate revision")
    if not RELEASE.fullmatch(expected_release):
        raise ValueError("invalid evaluation release tag")

    report_bytes = report_path.read_bytes()
    if not 0 < len(report_bytes) <= MAXIMUM_REPORT_BYTES:
        raise ValueError("assistant evaluation report exceeds its byte limit")
    try:
        report = json.loads(report_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("assistant evaluation report is malformed") from error
    if not isinstance(report, dict):
        raise ValueError("assistant evaluation report must be an object")

    code_commit = matching_string(
        report, CODE_COMMIT, "identity", "target", "code_commit")
    report_revision = matching_string(
        report, REVISION, "identity", "target", "revision_name")
    manifest_set = matching_string(
        report, DIGEST, "identity", "target", "artifact_manifest_set")
    evidence_sha = matching_string(
        report, DIGEST, "identity", "target", "evidence_sha256")
    cases_sha = matching_string(report, DIGEST, "cases_sha256")
    admission_sha = matching_string(report, DIGEST, "admission_sha256")
    admission_run_identity = matching_string(
        report, RUN_IDENTITY, "admission_run_identity")
    if nested(report, "schema") != REPORT_SCHEMA:
        raise ValueError("assistant evaluation report schema is unsupported")
    if nested(report, "activation_gate_passed") is not True:
        raise ValueError("assistant evaluation activation gate did not pass")
    if nested(report, "gate_failures") != []:
        raise ValueError("assistant evaluation report contains gate failures")
    if report_revision != expected_revision:
        raise ValueError("report revision does not match dispatch")

    report_sha = hashlib.sha256(report_bytes).hexdigest()
    bound_release = f"assistant-eval-{code_commit[:12]}-{report_sha[:12]}"
    if bound_release != expected_release:
        raise ValueError("release tag does not bind report bytes and code")

    return {
        "CODE_COMMIT": code_commit,
        "TARGET_MANIFEST_SET": manifest_set,
        "TARGET_EVIDENCE_SHA": evidence_sha,
        "CASES_SHA": cases_sha,
        "ADMISSION_RUN_IDENTITY": admission_run_identity,
        "ADMISSION_SHA": admission_sha,
        "REPORT_SCHEMA": REPORT_SCHEMA,
    }, report_sha


def main():
    if len(sys.argv) != 5:
        print(
            "usage: assistant_evaluation_identity.py REPORT EXPECTED_REVISION "
            "EXPECTED_RELEASE GITHUB_ENV_FILE",
            file=sys.stderr,
        )
        return 2
    report_path = Path(sys.argv[1])
    try:
        environment, report_sha = validate(report_path, sys.argv[2], sys.argv[3])
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2

    with Path(sys.argv[4]).open("a", encoding="utf-8", newline="\n") as output:
        for key, value in environment.items():
            output.write(f"{key}={value}\n")
    print(
        "validated assistant evaluation identity: "
        f"revision={sys.argv[2]} code={environment['CODE_COMMIT'][:12]} "
        f"report={report_sha[:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
