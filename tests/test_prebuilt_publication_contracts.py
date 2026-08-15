import json
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

    def test_benchmark_must_be_an_exact_passing_activation_gate(self):
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
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        failing_reports = []
        for field, value in (
            ("activation_gate_passed", False),
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

        self.assertNotIn('"$benchmark_rc" -eq 5', script)
        self.assertIn("validate-benchmark", script)
        self.assertIn('--source "index_sha256=$EXPECTED_INDEX_SHA256"', script)
        self.assertIn('--source "vectors_sha256=$EXPECTED_VECTORS_SHA256"', script)

        self.assertIn('--target "$CORPUS_COMMIT"', script)
        self.assertIn("immutable-releases", script)
        self.assertIn('X-GitHub-Api-Version: 2026-03-10', script)
        self.assertIn("validate-release", script)
        self.assertIn("merge-base --is-ancestor", script)
        self.assertIn("signed previous pointer evidence", script)
        self.assertIn('release_tag:$tag', script)
        self.assertIn('release_repository:$repository', script)
        self.assertIn('receipt_manifest_sha256:$receipt', script)
        self.assertIn('.release_tag == $pointer[0].release_tag', script)
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


if __name__ == "__main__":
    unittest.main()
