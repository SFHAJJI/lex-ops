import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
IDENTITY_SCRIPT = ROOT / "scripts" / "assistant_evaluation_identity.py"


class WorkflowContractTests(unittest.TestCase):
    def test_external_actions_are_pinned_to_full_commits(self):
        action = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.MULTILINE)
        invalid = []
        for workflow in sorted(WORKFLOWS.glob("*.yml")):
            for value in action.findall(workflow.read_text(encoding="utf-8")):
                if value.startswith("./"):
                    continue
                _, separator, reference = value.rpartition("@")
                if not separator or not re.fullmatch(r"[0-9a-f]{40}", reference):
                    invalid.append(f"{workflow.name}: {value}")
        self.assertEqual([], invalid)

    def test_evaluation_identity_helper_exports_only_validated_values(self):
        report = self.report()
        completed, environment = self.run_helper(report)

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual(
            {
                "CODE_COMMIT": report["identity"]["target"]["code_commit"],
                "TARGET_MANIFEST_SET": report["identity"]["target"]["artifact_manifest_set"],
                "TARGET_EVIDENCE_SHA": report["identity"]["target"]["evidence_sha256"],
                "CASES_SHA": report["cases_sha256"],
                "REPORT_SCHEMA": "lex-assistant-eval-report/3",
            },
            environment,
        )

    def test_evaluation_identity_helper_rejects_unbound_or_failing_reports(self):
        cases = []

        wrong_revision = self.report()
        cases.append((wrong_revision, "ca-lex-web--different", None))

        wrong_schema = self.report()
        wrong_schema["schema"] = "lex-assistant-eval-report/2"
        cases.append((wrong_schema, None, None))

        failed_gate = self.report()
        failed_gate["activation_gate_passed"] = False
        failed_gate["gate_failures"] = ["grounding"]
        cases.append((failed_gate, None, None))

        wrong_digest = self.report()
        wrong_digest["identity"]["target"]["evidence_sha256"] = "not-a-digest"
        cases.append((wrong_digest, None, None))

        for report, revision, release in cases:
            with self.subTest(report=report, revision=revision, release=release):
                completed, _ = self.run_helper(
                    report,
                    expected_revision=revision,
                    expected_release=release,
                )
                self.assertNotEqual(0, completed.returncode)

    def test_evaluation_publisher_retries_transient_candidate_lifecycle_calls(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")

        self.assertIn(". lex/scripts/deploy/az-retry.sh", workflow)
        self.assertIn(". lex/scripts/deploy/az-reauth.sh", workflow)
        self.assertIn("az_retry az containerapp revision activate", workflow)
        self.assertIn("az_reauth", workflow)
        self.assertIn("expected exactly one active revision", workflow)

    def test_evaluation_publisher_signs_and_verifies_exact_bootstrap_equivalence(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")

        for name in (
            "bootstrap_rollback_revision",
            "bootstrap_canonical_template_digest",
            "bootstrap_expected_image_digest",
        ):
            self.assertIn(name, workflow)
        self.assertIn("bootstrap equivalence inputs must be supplied together", workflow)
        self.assertIn("group: lex-production", workflow)
        self.assertIn("crsoufien3orem.azurecr.io/lex-web@", workflow)
        self.assertIn("lex/scripts/deploy/revision_template_digest.py", workflow)
        self.assertIn('"lex-first-release-equivalence/1"', workflow)
        self.assertIn('excluded_template_fields:["revisionSuffix"]', workflow)
        self.assertIn('preparation_state:$preparation', workflow)
        self.assertIn('legacy_authority:{revision_name:$legacy', workflow)
        self.assertIn('created_time:$rollback_created,active:false,traffic_weight:0', workflow)
        self.assertIn('created_time:$candidate_created,active:true,traffic_weight:0', workflow)
        self.assertIn("bootstrap-equivalence.json", workflow)
        self.assertIn("bootstrap-equivalence.manifest.json", workflow)
        self.assertIn("bootstrap-equivalence.manifest.sig", workflow)
        self.assertIn("purpose=assistant-evaluation-bootstrap-equivalence", workflow)
        signing = workflow.index("equivalence_manifest_digest=")
        verification = workflow.index("assistant-eval verify-bootstrap-equivalence", signing)
        publication = workflow.index('gh release upload "$EVALUATION_RELEASE"', verification)
        self.assertLess(signing, verification)
        self.assertLess(verification, publication)
        self.assertIn('--rollback-revision "$BOOTSTRAP_ROLLBACK_REVISION"', workflow)
        self.assertIn('--legacy-authority-revision "$legacy_authority"', workflow)
        self.assertIn('--canonical-template-digest "$BOOTSTRAP_CANONICAL_TEMPLATE_DIGEST"', workflow)
        self.assertIn('--image-digest "$BOOTSTRAP_EXPECTED_IMAGE_DIGEST"', workflow)
        self.assertIn('--cases-sha256 "$CASES_SHA"', workflow)
        self.assertIn('--source "cases_sha256=$CASES_SHA"', workflow)
        self.assertIn('cases_sha256:$cases', workflow)
        self.assertIn("not independently evaluated", workflow)
        self.assertIn("bootstrap signing state is not exact A=100/R-inactive/C-active", workflow)
        self.assertIn("bootstrap chronology must be exact A < R < C", workflow)
        self.assertIn('echo "candidate_owned=false" >> "$GITHUB_OUTPUT"', workflow)

    def test_every_revision_list_uses_complete_azure_inventory(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        ).replace("\\\n", " ")
        calls = re.findall(
            r"az(?:_retry)?\s+containerapp\s+revision\s+list\b[^\r\n]*",
            workflow,
        )
        self.assertTrue(calls)
        self.assertTrue(all("--all" in call for call in calls), calls)

    def test_evaluation_publication_reads_draft_and_public_assets_exactly(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        publication = workflow.index('gh release upload "$EVALUATION_RELEASE"')
        publish_boundary = workflow.index('gh release edit "$EVALUATION_RELEASE"', publication)
        final_state = workflow.index(
            'published=$(gh release view "$EVALUATION_RELEASE"', publish_boundary
        )
        readback = workflow.index(
            'https://github.com/SFHAJJI/lex-ops/releases/download/$EVALUATION_RELEASE/$asset',
            final_state,
        )
        final_live = workflow.index("bootstrap-routes.readback.json", publication)
        relinquish = workflow.index(
            'echo "candidate_owned=false" >> "$GITHUB_OUTPUT"', publication
        )

        self.assertLess(publication, final_live)
        self.assertLess(final_live, relinquish)
        self.assertLess(relinquish, publish_boundary)
        self.assertLess(publish_boundary, final_state)
        self.assertLess(final_state, readback)
        self.assertIn(".isDraft == true and .isPrerelease == false", workflow)
        self.assertIn(".isDraft == false and .isPrerelease == false", workflow)
        self.assertIn("([.assets[].name] | sort) == $expected", workflow)
        self.assertIn("--retry-all-errors", workflow)
        self.assertIn('sha256sum "$downloaded"', workflow)
        self.assertIn('wc -c < "$downloaded"', workflow)
        self.assertIn("evaluation release is not an exact retry-safe release", workflow)
        post_publish = workflow[publish_boundary:]
        self.assertNotIn('gh release upload "$EVALUATION_RELEASE"', post_publish)
        self.assertNotIn('gh release download "$EVALUATION_RELEASE"', post_publish)

    def test_evaluation_public_retry_verifies_without_mutating_the_release(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        retry_start = workflow.index('if [ "$PUBLIC_RETRY" = "true" ]')
        retry_end = workflow.index("bootstrap C must already be active", retry_start)
        retry = workflow[retry_start:retry_end]

        self.assertIn("assistant-eval verify-release", retry)
        self.assertIn("public retry release identity or asset set differs", retry)
        self.assertIn("public retry read-back changed", retry)
        self.assertIn("candidate_owned=$candidate_owned", retry)
        self.assertNotIn("gh release upload", retry)
        self.assertNotIn("gh release edit", retry)
        self.assertIn('echo "PUBLIC_RETRY=true" >> "$GITHUB_ENV"', workflow)
        self.assertIn("and ([.assets[].name] | sort) == ($allowed | sort)", workflow)

    def test_evaluation_publication_describes_project_owner_review_honestly(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("project-owner review signature: verified", workflow)
        self.assertNotIn("independent review signature: verified", workflow)
        self.assertRegex(readme, r"verifies the project-owner review\s+signature")
        self.assertNotRegex(readme, r"verifies the independent human\s+review")
        self.assertIn("Promotion independently revalidates this package", workflow)

    @staticmethod
    def report():
        return {
            "schema": "lex-assistant-eval-report/3",
            "cases_sha256": "c" * 64,
            "identity": {
                "target": {
                    "code_commit": "a" * 40,
                    "revision_name": "ca-lex-web--raaaaaaaaaaa-bbbbbbbbbbbb-123-1",
                    "artifact_manifest_set": "b" * 64,
                    "evidence_sha256": "d" * 64,
                }
            },
            "gate_failures": [],
            "activation_gate_passed": True,
        }

    def run_helper(self, report, expected_revision=None, expected_release=None):
        expected_revision = expected_revision or report["identity"]["target"]["revision_name"]
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            directory = Path(temporary)
            report_path = directory / "assistant-eval-report.json"
            environment_path = directory / "github.env"
            report_path.write_text(
                json.dumps(report, separators=(",", ":")),
                encoding="utf-8",
            )
            report_sha = hashlib.sha256(report_path.read_bytes()).hexdigest()
            expected_release = expected_release or (
                "assistant-eval-"
                f"{report['identity']['target']['code_commit'][:12]}-"
                f"{report_sha[:12]}"
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(IDENTITY_SCRIPT),
                    report_path.as_posix(),
                    expected_revision,
                    expected_release,
                    environment_path.as_posix(),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            environment = {}
            if environment_path.exists():
                for line in environment_path.read_text(encoding="utf-8").splitlines():
                    key, value = line.split("=", 1)
                    environment[key] = value
            return completed, environment


if __name__ == "__main__":
    unittest.main()
