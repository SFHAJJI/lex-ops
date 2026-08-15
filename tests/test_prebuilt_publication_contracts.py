import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "publish-prebuilt-index.yml"
PUBLISH = ROOT / "publish-prebuilt-index.sh"
BUILD = ROOT / "scripts" / "prebuilt-publication-build.sh"
RELEASE = ROOT / "scripts" / "prebuilt-publication-release.sh"
CONTRACT = ROOT / "scripts" / "prebuilt_publication_contract.py"


def expanded_publisher():
    script = PUBLISH.read_text(encoding="utf-8")
    script = script.replace(
        '. "$ops_root/scripts/prebuilt-publication-build.sh"',
        BUILD.read_text(encoding="utf-8"),
    )
    return script.replace(
        '. "$ops_root/scripts/prebuilt-publication-release.sh"',
        RELEASE.read_text(encoding="utf-8"),
    )


class PrebuiltPublicationContractTests(unittest.TestCase):
    publisher = "lu-legilux"
    ticket = "a" * 64
    queue = "b" * 40
    corpus = "c" * 40
    code = "d" * 40
    articles = "e" * 40
    generation = "f" * 64
    index_sha = "1" * 64
    vectors_sha = "2" * 64
    index_etag = "0xABC123"
    vectors_etag = "0xDEF456"
    index_size = 1234
    vectors_size = 5678
    runtime_guard = "03f94295f3e678b47cb0511a082698f34373679c"

    def test_benchmark_must_be_an_exact_activation_decision(self):
        report = {
            "schema": "lex-retrieval-benchmark/3",
            "sample_count": 37,
            "tuning_sample_count": 29,
            "holdout_sample_count": 8,
            "review_status": "reviewed",
            "baseline_schema": "lex-retrieval-baseline/2",
            "expected_cases_sha256": "d952bb259a8a5bd8859056c9440bcc566127dbcc4f908bd1330b97de1b508f77",
            "actual_cases_sha256": "d952bb259a8a5bd8859056c9440bcc566127dbcc4f908bd1330b97de1b508f77",
            "review_attestation": "repository-review:retrieval-v2-2026-08-09@2026-08-09",
            "activation_gate_passed": True,
            "gate_failures": [],
            "code_commit": self.code,
            "corpus_commit": self.corpus,
            "manifest_id": self.index_sha,
            "model_id": "intfloat/multilingual-e5-small",
            "model_revision": "614241f622f53c4eeff9890bdc4f31cfecc418b3",
            "machine": "github-actions-ubuntu-latest",
            "resource_configuration": "Container Apps Consumption target, 2 GiB configured limit",
            "memory_limit_bytes": 2147483648,
            "index_bytes": self.index_size,
            "vector_bytes": self.vectors_size,
        }
        completed = self.run_contract(
            "validate-benchmark",
            report,
            self.publisher,
            self.code,
            self.corpus,
            self.index_sha,
            str(self.index_size),
            str(self.vectors_size),
            "true",
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        quarantined = dict(report)
        quarantined["activation_gate_passed"] = False
        quarantined["gate_failures"] = ["holdout warm p95 exceeds 250 ms"]
        completed = self.run_contract(
            "validate-benchmark",
            quarantined,
            self.publisher,
            self.code,
            self.corpus,
            self.index_sha,
            str(self.index_size),
            str(self.vectors_size),
            "false",
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        failing_reports = []
        for field, value in (
            ("gate_failures", ["recall below threshold"]),
            ("code_commit", "0" * 40),
            ("corpus_commit", "0" * 40),
            ("manifest_id", "0" * 64),
        ):
            candidate = dict(report)
            candidate[field] = value
            failing_reports.append(candidate)
        for candidate in failing_reports:
            with self.subTest(candidate=candidate):
                completed = self.run_contract(
                    "validate-benchmark",
                    candidate,
                    self.publisher,
                    self.code,
                    self.corpus,
                    self.index_sha,
                    str(self.index_size),
                    str(self.vectors_size),
                    "true",
                )
                self.assertNotEqual(0, completed.returncode)
        for field, value in (
            ("schema", "lex-retrieval-benchmark/2"),
            ("actual_cases_sha256", "0" * 64),
            ("sample_count", 36),
            ("holdout_sample_count", 7),
            ("review_attestation", "unreviewed"),
            ("model_revision", "unknown"),
            ("vector_bytes", self.vectors_size + 1),
        ):
            candidate = dict(report)
            candidate[field] = value
            with self.subTest(field=field):
                completed = self.run_contract(
                    "validate-benchmark",
                    candidate,
                    self.publisher,
                    self.code,
                    self.corpus,
                    self.index_sha,
                    str(self.index_size),
                    str(self.vectors_size),
                    "true",
                )
                self.assertNotEqual(0, completed.returncode)

        for failures in ([], [""], [1], "holdout warm p95 exceeds 250 ms"):
            candidate = dict(quarantined)
            candidate["gate_failures"] = failures
            with self.subTest(quarantine_failures=failures):
                completed = self.run_contract(
                    "validate-benchmark",
                    candidate,
                    self.publisher,
                    self.code,
                    self.corpus,
                    self.index_sha,
                    str(self.index_size),
                    str(self.vectors_size),
                    "false",
                )
                self.assertNotEqual(0, completed.returncode)

        for report_value, expected_activation in (
            (report, "false"),
            (quarantined, "true"),
            (quarantined, "maybe"),
        ):
            with self.subTest(expected_activation=expected_activation):
                completed = self.run_contract(
                    "validate-benchmark",
                    report_value,
                    self.publisher,
                    self.code,
                    self.corpus,
                    self.index_sha,
                    str(self.index_size),
                    str(self.vectors_size),
                    expected_activation,
                )
                self.assertNotEqual(0, completed.returncode)

    def test_staging_snapshot_is_exact_and_canonical(self):
        snapshot = self.staging_snapshot()
        completed = self.validate_staging(snapshot)
        self.assertEqual(0, completed.returncode, completed.stderr)

        mutations = []
        extra = json.loads(json.dumps(snapshot))
        extra.append(json.loads(json.dumps(extra[0])))
        extra[-1]["name"] += ".bak"
        mutations.append(extra)

        wrong_ticket = json.loads(json.dumps(snapshot))
        wrong_ticket[0]["metadata"]["queue_ticket_id"] = "0" * 64
        mutations.append(wrong_ticket)

        wrong_generation_key = json.loads(json.dumps(snapshot))
        generation = wrong_generation_key[0]["metadata"].pop(
            "articles_generation_sha256"
        )
        wrong_generation_key[0]["metadata"]["generation_sha256"] = generation
        mutations.append(wrong_generation_key)

        wrong_type = json.loads(json.dumps(snapshot))
        wrong_type[0]["properties"]["contentSettings"]["contentType"] = (
            "application/octet-stream"
        )
        mutations.append(wrong_type)

        unencrypted = json.loads(json.dumps(snapshot))
        unencrypted[1]["properties"]["serverEncrypted"] = False
        mutations.append(unencrypted)

        changed_etag = json.loads(json.dumps(snapshot))
        changed_etag[1]["properties"]["etag"] = '"0xCHANGED"'
        mutations.append(changed_etag)

        for candidate in mutations:
            with self.subTest(candidate=candidate):
                self.assertNotEqual(0, self.validate_staging(candidate).returncode)

    def test_cleanup_retry_accepts_only_an_exact_remaining_subset(self):
        snapshot = self.staging_snapshot()
        for remaining in (snapshot, snapshot[:1], snapshot[1:], []):
            with self.subTest(remaining=remaining):
                completed = self.validate_staging(
                    remaining, command="validate-staging-cleanup-snapshot"
                )
                self.assertEqual(0, completed.returncode, completed.stderr)
        unexpected = snapshot[:1]
        unexpected[0]["name"] += ".bak"
        self.assertNotEqual(
            0,
            self.validate_staging(
                unexpected, command="validate-staging-cleanup-snapshot"
            ).returncode,
        )

    def test_lineage_receipts_preserve_closed_schema_versions(self):
        pointer_v2, receipt_v2 = self.lineage_evidence("2")
        completed = self.run_contract(
            "validate-lineage-receipt",
            receipt_v2,
            pointer_v2,
            self.publisher,
            self.runtime_guard,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        pointer_v3, receipt_v3 = self.lineage_evidence("3")
        completed = self.run_contract(
            "validate-lineage-receipt",
            receipt_v3,
            pointer_v3,
            self.publisher,
            self.runtime_guard,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        pointer_v1, receipt_v1 = self.lineage_evidence("1")
        completed = self.run_contract(
            "validate-lineage-receipt",
            receipt_v1,
            pointer_v1,
            self.publisher,
            self.runtime_guard,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        malformed = []
        missing_guard = json.loads(json.dumps(receipt_v3))
        missing_guard.pop("runtime_guard_commit")
        malformed.append((pointer_v3, missing_guard))
        wrong_guard = json.loads(json.dumps(receipt_v3))
        wrong_guard["runtime_guard_commit"] = "0" * 40
        malformed.append((pointer_v3, wrong_guard))
        guard_smuggled_into_v2 = json.loads(json.dumps(receipt_v2))
        guard_smuggled_into_v2["runtime_guard_commit"] = self.runtime_guard
        malformed.append((pointer_v2, guard_smuggled_into_v2))
        mislabeled_v2 = json.loads(json.dumps(receipt_v2))
        mislabeled_v2["schema"] = "lex-staging-cleanup-receipt/3"
        malformed.append((pointer_v3, mislabeled_v2))
        mismatched_semantic = json.loads(json.dumps(receipt_v3))
        mismatched_semantic["semantic_activation"] = True
        malformed.append((pointer_v3, mismatched_semantic))
        for pointer, receipt in malformed:
            with self.subTest(receipt=receipt):
                completed = self.run_contract(
                    "validate-lineage-receipt",
                    receipt,
                    pointer,
                    self.publisher,
                    self.runtime_guard,
                )
                self.assertNotEqual(0, completed.returncode)

    def test_public_release_and_tag_must_be_immutable_and_exact(self):
        tag = f"index-{self.publisher}-{self.ticket}"
        expected_assets = [
            {"name": "a.json", "sha256": "3" * 64, "size": 123},
            {"name": "b.sig", "sha256": "4" * 64, "size": 456},
        ]
        release = {
            "draft": False,
            "prerelease": False,
            "tag_name": tag,
            "target_commitish": self.corpus,
            "immutable": True,
            "assets": [
                {
                    "name": asset["name"],
                    "state": "uploaded",
                    "size": asset["size"],
                    "digest": f"sha256:{asset['sha256']}",
                }
                for asset in expected_assets
            ],
        }
        tag_ref = {
            "object": {
                "type": "commit",
                "sha": self.corpus,
                "url": f"https://api.github.test/commits/{self.corpus}",
            }
        }
        completed = self.run_contract(
            "validate-release",
            release,
            tag_ref,
            tag,
            self.corpus,
            expected_assets,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        for field, value in (
            ("draft", True),
            ("immutable", False),
            ("target_commitish", "main"),
        ):
            candidate = dict(release)
            candidate[field] = value
            with self.subTest(field=field):
                self.assertNotEqual(
                    0,
                    self.run_contract(
                        "validate-release",
                        candidate,
                        tag_ref,
                        tag,
                        self.corpus,
                        expected_assets,
                    ).returncode,
                )
        oversized = json.loads(json.dumps(expected_assets))
        oversized[0]["size"] = 2147483648
        self.assertNotEqual(
            0,
            self.run_contract(
                "validate-release", release, tag_ref, tag, self.corpus, oversized
            ).returncode,
        )
        wrong_ref = {"object": {"type": "tag", "sha": self.corpus}}
        self.assertNotEqual(
            0,
            self.run_contract(
                "validate-release",
                release,
                wrong_ref,
                tag,
                self.corpus,
                expected_assets,
            ).returncode,
        )
        for field, value in (
            ("digest", "sha256:" + "0" * 64),
            ("size", 999),
            ("state", "new"),
        ):
            wrong_asset = json.loads(json.dumps(release))
            wrong_asset["assets"][0][field] = value
            with self.subTest(asset_field=field):
                self.assertNotEqual(
                    0,
                    self.run_contract(
                        "validate-release",
                        wrong_asset,
                        tag_ref,
                        tag,
                        self.corpus,
                        expected_assets,
                    ).returncode,
                )

    def test_immutable_release_setting_requires_enabled_true(self):
        enabled = self.run_contract(
            "validate-immutable-release-setting", {"enabled": True}
        )
        self.assertEqual(0, enabled.returncode, enabled.stderr)
        for setting in ({"enabled": False}, {}, {"enabled": "true"}):
            with self.subTest(setting=setting):
                self.assertNotEqual(
                    0,
                    self.run_contract(
                        "validate-immutable-release-setting", setting
                    ).returncode,
                )

    def test_legacy_pointer_authentication_is_limited_to_exact_known_manifests(self):
        for publisher in ("eu-eurlex", "lu-legilux"):
            manifest, manifest_sha, corpus = self.legacy_manifest(publisher)
            pointer = {
                "schema": "lex-artifact-pointer/1",
                "collection": publisher,
                "manifest_sha256": manifest_sha,
                "prefix": f"releases/{publisher}/{manifest_sha}",
                "corpus_commit": corpus,
                "published_at": (
                    "2026-08-14T04:29:37Z"
                    if publisher == "eu-eurlex"
                    else "2026-08-13T14:48:40Z"
                ),
            }
            completed = self.run_legacy_contract(pointer, manifest, publisher)
            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertEqual(
                [item["path"] for item in manifest["files"]],
                completed.stdout.splitlines(),
            )

            for mutation in ("pointer_digest", "pointer_corpus", "manifest_file"):
                changed_pointer = json.loads(json.dumps(pointer))
                changed_manifest = json.loads(json.dumps(manifest))
                if mutation == "pointer_digest":
                    changed_pointer["manifest_sha256"] = "0" * 64
                elif mutation == "pointer_corpus":
                    changed_pointer["corpus_commit"] = "0" * 40
                else:
                    changed_manifest["files"][0]["size"] += 1
                with self.subTest(publisher=publisher, mutation=mutation):
                    rejected = self.run_legacy_contract(
                        changed_pointer, changed_manifest, publisher
                    )
                    self.assertNotEqual(0, rejected.returncode)

    def test_workflow_and_script_close_every_release_blocker(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        script = expanded_publisher()
        contract = CONTRACT.read_text(encoding="utf-8")

        for input_name in (
            "workflow_commit",
            "index_etag",
            "index_size",
            "vectors_etag",
            "vectors_size",
        ):
            self.assertIn(f"      {input_name}:", workflow)
        self.assertGreaterEqual(
            workflow.count(
                "github.ref == 'refs/heads/main' && github.sha == inputs.workflow_commit"
            ),
            2,
        )
        self.assertIn("postflight_cleanup:", workflow)
        self.assertIn("needs: publish", workflow)
        self.assertIn("PUBLICATION_PHASE: publish", workflow)
        self.assertIn("PUBLICATION_PHASE: postflight-cleanup", workflow)

        self.assertIn('expected_prefix="staging/$PUBLISHER/$ticket_id"', script)
        self.assertIn("validate-staging-snapshot", script)
        self.assertIn('publication-runs/$PUBLISHER/$ticket_id.json', script)
        self.assertIn("--if-none-match '*'", script)
        self.assertIn("GITHUB_RUN_ID", script)
        self.assertIn("WORKFLOW_COMMIT", script)
        self.assertIn("git rev-parse HEAD", script)

        self.assertNotIn("lex-releases", script)
        self.assertNotIn("publish_blob_bundle", script)
        self.assertNotIn("verify_blob_bundle", script)
        self.assertNotIn("storage container-rm", script)
        self.assertNotIn("storage container immutability-policy", script)
        self.assertNotIn("storage blob immutability-policy set", script)
        self.assertIn("validate-immutable-release-setting", script)
        self.assertIn('setting.get("enabled") is not True', contract)
        self.assertIn('gh release verify "$tag" --repo "$repo"', script)
        self.assertIn('gh release verify-asset "$tag"', script)
        self.assertIn('"sha256:" + expected["sha256"]', contract)
        self.assertIn('"$asset_size" -lt 2147483648', script)

        self.assertIn("AZURE_KEY_VERSION=29f1df16fbc34bc7af12f47430cc5acc", script)
        self.assertIn(
            "ARTIFACT_KEY_FINGERPRINT=155c58524c90c3d7b3c9f5041139c3313d21075139f8e4c948511c505039fb64",
            script,
        )
        self.assertIn('--version "$AZURE_KEY_VERSION"', script)
        self.assertIn('--trust-roots "$single_trust_roots"', script)

        self.assertIn(
            "HYBRID_QUARANTINE_GUARD_COMMIT="
            "03f94295f3e678b47cb0511a082698f34373679c",
            script,
        )
        self.assertIn(
            '"$HYBRID_QUARANTINE_GUARD_COMMIT" refs/remotes/origin/main',
            script,
        )
        self.assertIn("5) expected_semantic_activation=false", script)
        self.assertIn('expected_semantic_activation=false', script)
        self.assertIn("validate-benchmark", script)
        self.assertIn('--source "runtime_guard_commit=$HYBRID_QUARANTINE_GUARD_COMMIT"', script)
        self.assertIn('runtime_guard_commit:$guard', script)
        self.assertIn('Semantic activation: $semantic_activation', script)
        self.assertNotIn("jq -er .semantic_activation", script)
        self.assertNotIn("jq -er .previous_pointer.exists", script)
        self.assertIn('--source "index_sha256=$EXPECTED_INDEX_SHA256"', script)
        self.assertIn('--source "vectors_sha256=$EXPECTED_VECTORS_SHA256"', script)
        self.assertIn('schema:"lex-staging-cleanup-receipt/3"', script)
        self.assertIn("validate-lineage-receipt", script)
        self.assertIn("validate-legacy-pointer", script)
        self.assertIn(
            "2da4d2039b549ced38afbd305f9625e1190bf2118f5f765eef30d36a0c45c0d5",
            contract,
        )
        self.assertIn(
            "bb5a115b01262fbe486bd7c9f66e0941910aaf35bd23ee17caf7447b89b8a308",
            contract,
        )
        legacy_start = script.index(
            'if [ "$pointer_schema" = lex-artifact-pointer/1 ]'
        )
        legacy_end = script.index("  else", legacy_start)
        legacy = script[legacy_start:legacy_end]
        self.assertIn("validate-legacy-pointer", legacy)
        self.assertIn('artifact verify', legacy)
        self.assertIn('while IFS= read -r asset', legacy)
        self.assertNotIn("$cleanup_receipt", legacy)
        self.assertNotIn("$cleanup_manifest", legacy)
        self.assertNotIn("$cleanup_signature", legacy)

        self.assertIn('--arg target "$CORPUS_COMMIT"', script)
        self.assertIn('target_commitish:$target', script)
        self.assertIn("immutable-releases", script)
        self.assertIn('X-GitHub-Api-Version: 2026-03-10', script)
        self.assertIn("validate-release", script)
        self.assertIn("merge-base --is-ancestor", script)
        self.assertIn("signed previous pointer evidence", script)
        self.assertIn('release_tag:$tag', script)
        self.assertIn('release_repository:$repository', script)
        self.assertIn('receipt_manifest_sha256:$receipt', script)
        self.assertIn(
            'pointer.get("release_tag") != receipt.get("release_tag")', contract
        )
        self.assertIn(
            'receipt_manifest_id=$(sha256_file "$previous_dir/$cleanup_manifest")',
            script,
        )
        self.assertIn('$(jq -er .receipt_manifest_sha256 "$pointer")', script)

        publish_case = script[script.index('case "$PUBLICATION_PHASE" in') :]
        cleanup_case = publish_case.index("postflight-cleanup)")
        self.assertNotIn("cleanup_exact_blob", publish_case[:cleanup_case])
        self.assertIn("cleanup_exact_blob", publish_case[cleanup_case:])
        self.assertIn("verify public GitHub release", publish_case[cleanup_case:])
        self.assertIn("verify current artifact pointer", publish_case[cleanup_case:])

    def test_draft_release_is_pinned_by_numeric_id_before_tag_upload_and_publication(self):
        script = RELEASE.read_text(encoding="utf-8")

        self.assertIn("discover_exact_draft", script)
        self.assertIn('repos/$repo/releases/$release_id', script)
        self.assertIn('refs/tags/$tag', script)
        self.assertIn('-f "ref=refs/tags/$tag"', script)
        self.assertIn('"sha=$CORPUS_COMMIT"', script)
        self.assertIn("https://uploads.github.com/repos/$repo/releases/$release_id/assets", script)
        self.assertIn('--request PATCH', script)
        self.assertIn('"https://api.github.com/repos/$repo/releases/$release_id"', script)
        self.assertIn('--data-binary "@$work_root/publish-release.json"', script)

        prepare = script[script.index("prepare_exact_draft()") :]
        create_tag = prepare.index("ensure_exact_tag")
        upload = prepare.index("upload_missing_assets")
        self.assertLess(create_tag, upload, "the exact lightweight tag must exist before asset upload")
        finalize = script[script.index("finalize_and_verify_public_release()") :]
        self.assertLess(
            finalize.index("require_github_immutable_releases"), finalize.index("--request PATCH")
        )

        for mutable_tag_lookup in (
            'gh release create "$tag"',
            'gh release upload "$tag"',
            'gh release edit "$tag"',
        ):
            with self.subTest(mutable_tag_lookup=mutable_tag_lookup):
                self.assertNotIn(mutable_tag_lookup, script)

    def test_draft_inventory_accepts_only_exact_uploaded_assets(self):
        bash = Path(r"C:\Program Files\Git\bin\bash.exe") if sys.platform == "win32" else Path("/bin/bash")
        if not bash.exists() or subprocess.run(
            [str(bash)], input="command -v jq >/dev/null", text=True, check=False
        ).returncode:
            self.skipTest("bash with jq is required")

        digest = "a" * 64
        expected = [{"name": "asset.bin", "sha256": digest, "size": 3}]
        release = {
            "id": 7,
            "tag_name": "index-lu-legilux-" + "a" * 64,
            "target_commitish": "c" * 40,
            "name": "index-lu-legilux " + "a" * 12,
            "body": "notes",
            "published_at": None,
            "draft": True,
            "prerelease": False,
            "immutable": False,
            "assets": [{
                "id": 11, "name": "asset.bin", "state": "uploaded",
                "digest": "sha256:" + digest, "size": 3,
            }],
        }
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            root = Path(temporary)
            paths = {"EXPECTED": root / "expected.json", "EXACT": root / "exact.json"}
            paths["WRONG"] = root / "wrong.json"
            paths["UNKNOWN"] = root / "unknown.json"
            paths["EXPECTED"].write_text(json.dumps(expected), encoding="utf-8")
            paths["EXACT"].write_text(json.dumps(release), encoding="utf-8")
            wrong = json.loads(json.dumps(release)); wrong["assets"][0]["digest"] = "sha256:" + "b" * 64
            unknown = json.loads(json.dumps(release)); unknown["assets"][0]["name"] = "unknown.bin"
            paths["WRONG"].write_text(json.dumps(wrong), encoding="utf-8")
            paths["UNKNOWN"].write_text(json.dumps(unknown), encoding="utf-8")
            environment = os.environ.copy()
            environment.update({key: value.as_posix() for key, value in paths.items()})
            environment["RELEASE_SCRIPT"] = RELEASE.as_posix()
            completed = subprocess.run([str(bash)], env=environment, text=True, capture_output=True,
                input='set -euo pipefail\nrelease_id=7; tag="index-lu-legilux-' + "a" * 64 + '"; '
                'CORPUS_COMMIT="' + "c" * 40 + '"; PUBLISHER=lu-legilux; ticket_id="' + "a" * 64 + '"; '
                'release_notes=notes\n. "$RELEASE_SCRIPT"\n'
                'validate_draft_inventory "$EXACT" "$EXPECTED" true\n'
                '! validate_draft_inventory "$WRONG" "$EXPECTED" true\n'
                '! validate_draft_inventory "$UNKNOWN" "$EXPECTED" true\n', check=False)
            self.assertEqual(0, completed.returncode, completed.stderr)

    def test_transient_draft_locator_failure_never_creates_a_release(self):
        bash = Path(r"C:\Program Files\Git\bin\bash.exe") if sys.platform == "win32" else Path("/bin/bash")
        if not bash.exists():
            self.skipTest("bash is required")

        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            root = Path(temporary)
            environment = os.environ.copy()
            environment.update({
                "MOCK_LOG": (root / "calls.log").as_posix(),
                "RELEASE_SCRIPT": RELEASE.as_posix(),
                "TEST_ROOT": root.as_posix(),
            })
            completed = subprocess.run(
                [str(bash)], env=environment, text=True, capture_output=True, check=False,
                input=r'''set -euo pipefail
. "$RELEASE_SCRIPT"
work_root=$TEST_ROOT
repo=SFHAJJI/lex-corpus-eu-eurlex
tag=index-eu-eurlex-test
CORPUS_COMMIT=1111111111111111111111111111111111111111
PUBLISHER=eu-eurlex
ticket_id=2222222222222222222222222222222222222222222222222222222222222222
release_notes=notes
release_id=
require_github_immutable_releases() { :; }
write_asset_inventory() { printf '[]' > "$2"; }
jq() { printf '{}'; }
gh() { printf 'gh %s\n' "$*" >> "$MOCK_LOG"; return 75; }
gh_api() {
  printf 'gh_api %s\n' "$*" >> "$MOCK_LOG"
  [[ " $* " == *" --method POST " ]] && return 0
  return 75
}
! prepare_exact_draft "$TEST_ROOT"
! grep -q -- '--method POST' "$MOCK_LOG"
''')
            self.assertEqual(0, completed.returncode, completed.stderr)

    def staging_snapshot(self):
        prefix = f"staging/{self.publisher}/{self.ticket}"
        common = {
            "collection": self.publisher,
            "queue_ticket_id": self.ticket,
            "corpus_commit": self.corpus,
            "build_code_commit": self.code,
            "articles_commit": self.articles,
            "articles_generation_sha256": self.generation,
        }
        return [
            {
                "name": f"{prefix}/index-{self.publisher}.db",
                "properties": {
                    "blobType": "BlockBlob",
                    "contentLength": self.index_size,
                    "contentSettings": {"contentType": "application/vnd.sqlite3"},
                    "etag": f'"{self.index_etag}"',
                    "serverEncrypted": True,
                },
                "metadata": {**common, "sha256": self.index_sha},
            },
            {
                "name": f"{prefix}/index-{self.publisher}.vectors",
                "properties": {
                    "blobType": "BlockBlob",
                    "contentLength": self.vectors_size,
                    "contentSettings": {"contentType": "application/octet-stream"},
                    "etag": f'"{self.vectors_etag}"',
                    "serverEncrypted": True,
                },
                "metadata": {**common, "sha256": self.vectors_sha},
            },
        ]

    def lineage_evidence(self, version):
        generated = "2026-08-15T00:00:00Z"
        prefix = f"staging/{self.publisher}/{self.ticket}"
        tag = f"index-{self.publisher}-{self.ticket}"
        assets = [
            {"name": f"index-{self.publisher}.db", "sha256": self.index_sha, "size": self.index_size},
            {"name": f"index-{self.publisher}.vectors", "sha256": self.vectors_sha, "size": self.vectors_size},
        ]
        previous = {"exists": False, "etag": None, "sha256": None}
        if version == "1":
            pointer = {
                "schema": "lex-artifact-pointer/1",
                "collection": self.publisher,
                "corpus_commit": self.corpus,
                "manifest_sha256": self.index_sha,
                "prefix": f"releases/{self.publisher}/{self.index_sha}",
                "published_at": generated,
            }
            receipt = {
                "schema": "lex-staging-cleanup-receipt/1",
                "purpose": "delete-exact-published-prebuilt-staging",
                "generated_at": generated,
                "publisher": self.publisher,
                "queue_ticket_id": self.ticket,
                "corpus_commit": self.corpus,
                "build_code_commit": self.code,
                "articles_commit": self.articles,
                "staging_prefix": prefix,
                "release_tag": tag,
                "index_manifest_sha256": self.index_sha,
                "staging": {
                    "index": {"name": f"{prefix}/index-{self.publisher}.db", "etag": self.index_etag, "sha256": self.index_sha},
                    "vectors": {"name": f"{prefix}/index-{self.publisher}.vectors", "etag": self.vectors_etag, "sha256": self.vectors_sha},
                },
                "previous_pointer": previous,
                "public_assets": assets,
            }
            return pointer, receipt

        pointer = {
            "schema": "lex-artifact-pointer/2",
            "collection": self.publisher,
            "manifest_sha256": self.index_sha,
            "benchmark_manifest_sha256": self.vectors_sha,
            "semantic_activation": False,
            "receipt_manifest_sha256": "3" * 64,
            "release_tag": tag,
            "release_repository": f"SFHAJJI/lex-corpus-{self.publisher}",
            "corpus_commit": self.corpus,
            "published_at": generated,
        }
        receipt = {
            "schema": f"lex-staging-cleanup-receipt/{version}",
            "purpose": "delete-exact-published-prebuilt-staging",
            "generated_at": generated,
            "publisher": self.publisher,
            "queue_ticket_id": self.ticket,
            "queue_commit": self.queue,
            "workflow_commit": self.code,
            "run_id": "123456",
            "corpus_commit": self.corpus,
            "build_code_commit": self.code,
            "articles_commit": self.articles,
            "staging_prefix": prefix,
            "release_tag": tag,
            "release_repository": f"SFHAJJI/lex-corpus-{self.publisher}",
            "index_manifest_sha256": self.index_sha,
            "benchmark_manifest_sha256": self.vectors_sha,
            "semantic_activation": False,
            "staging": {
                "index": {"name": f"{prefix}/index-{self.publisher}.db", "etag": self.index_etag, "sha256": self.index_sha, "size": self.index_size},
                "vectors": {"name": f"{prefix}/index-{self.publisher}.vectors", "etag": self.vectors_etag, "sha256": self.vectors_sha, "size": self.vectors_size},
            },
            "previous_pointer": previous,
            "public_assets": assets,
        }
        if version == "3":
            receipt["runtime_guard_commit"] = self.runtime_guard
        return pointer, receipt

    def validate_staging(self, snapshot, command="validate-staging-snapshot"):
        return self.run_contract(
            command,
            snapshot,
            self.publisher,
            f"staging/{self.publisher}/{self.ticket}",
            self.ticket,
            self.corpus,
            self.code,
            self.articles,
            self.generation,
            self.index_sha,
            self.index_etag,
            str(self.index_size),
            self.vectors_sha,
            self.vectors_etag,
            str(self.vectors_size),
        )

    def run_contract(self, command, *arguments):
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            values = []
            for index, argument in enumerate(arguments):
                if isinstance(argument, (dict, list)):
                    path = Path(temporary) / f"argument-{index}.json"
                    path.write_text(
                        json.dumps(argument, separators=(",", ":")),
                        encoding="utf-8",
                    )
                    values.append(path.as_posix())
                else:
                    values.append(str(argument))
            return subprocess.run(
                [sys.executable, CONTRACT.as_posix(), command, *values],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    def run_legacy_contract(self, pointer, manifest, publisher):
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            directory = Path(temporary)
            pointer_path = directory / "pointer.json"
            manifest_path = directory / "manifest.json"
            pointer_path.write_bytes((json.dumps(pointer, indent=2) + "\n").encode())
            manifest_path.write_bytes(
                json.dumps(manifest, separators=(",", ":")).encode()
            )
            return subprocess.run(
                [
                    sys.executable,
                    CONTRACT.as_posix(),
                    "validate-legacy-pointer",
                    pointer_path.as_posix(),
                    manifest_path.as_posix(),
                    publisher,
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    @staticmethod
    def legacy_manifest(publisher):
        common_files = [
            {
                "path": "model-manifest.json",
                "kind": "json",
                "size": 369,
                "sha256": "4fef034b325dd2b7e5296ed5927c7ea21a144861a4b964cc1ab15129f6ccc696",
            },
            {
                "path": "model.onnx",
                "kind": "embedding-model",
                "size": 118346824,
                "sha256": "dd476dd0c2514e9b9be83aeb3853fac0763e0bdf4a71645407587d77c48a2d88",
            },
            {
                "path": "sentencepiece.bpe.model",
                "kind": "file",
                "size": 5069051,
                "sha256": "cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865",
            },
        ]
        if publisher == "eu-eurlex":
            manifest_sha = "2da4d2039b549ced38afbd305f9625e1190bf2118f5f765eef30d36a0c45c0d5"
            corpus = "7595e12ba31920fe6229f707f13eb5b8effa05c7"
            created_at = "2026-08-14T04:32:59Z"
            files = [
                {
                    "path": "eu-scope.json",
                    "kind": "json",
                    "size": 4814,
                    "sha256": "7cfa06fd83a8e5bdffe9c9c3713c2aeaf357ffbabb65545b4577c5ca4d1760bf",
                },
                {
                    "path": "eu-work-enrichment.json",
                    "kind": "json",
                    "size": 8352,
                    "sha256": "b5fc3668cc2370748ad32daad7240aaf91ab4008facfd9c3da1bf49d65a14be3",
                },
                {
                    "path": "index-eu-eurlex.db",
                    "kind": "sqlite-index",
                    "size": 603197440,
                    "sha256": "366447f7c114d8e5586687b8f28ea78b9e7d058a80235ee9996f6a25f4859e94",
                },
                {
                    "path": "index-eu-eurlex.vectors",
                    "kind": "file",
                    "size": 333574016,
                    "sha256": "01fe518b462a64f7337c672a4863da9fab86e56586844affaa146016b495b9b9",
                },
                *common_files,
            ]
        elif publisher == "lu-legilux":
            manifest_sha = "bb5a115b01262fbe486bd7c9f66e0941910aaf35bd23ee17caf7447b89b8a308"
            corpus = "69a4bec429c5afd73261e6959ca42c9ca796d567"
            created_at = "2026-08-13T14:51:44Z"
            files = [
                {
                    "path": "index-lu-legilux.db",
                    "kind": "sqlite-index",
                    "size": 575389696,
                    "sha256": "c18e1d395b539eb0529e61d0df68aac0902793cc0a1d74396b5b920a01bd0271",
                },
                {
                    "path": "index-lu-legilux.vectors",
                    "kind": "file",
                    "size": 46717376,
                    "sha256": "1bab8de8a3c03a30149feecf8cecee9e5d4a74ad0ebaa440208b2529718b1109",
                },
                *common_files,
            ]
        else:
            raise ValueError(publisher)
        code = "51e33b406475fa7ff7014d21d94ef2ae1c3c3ed4"
        manifest = {
            "schema": "lex-artifacts/1",
            "algorithm": "ECDSA-P256-SHA256",
            "key_id": "keyvault-lex-v2",
            "created_at": created_at,
            "code_commit": code,
            "sources": {
                "articles_commit": "f95da3e9ce88baebc99d4b3d307679feca8c1d50",
                "build_origin": "hash-pinned-private-staging",
                "collection": publisher,
                "corpus_commit": corpus,
                "publication_tool_commit": code,
                "queue_commit": "7510ba2dccd3a99a02fb020faea2d074c43e1a54",
            },
            "files": files,
        }
        return manifest, manifest_sha, corpus


if __name__ == "__main__":
    unittest.main()
