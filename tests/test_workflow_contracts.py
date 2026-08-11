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
