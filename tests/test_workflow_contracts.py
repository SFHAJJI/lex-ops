import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
IDENTITY_SCRIPT = ROOT / "scripts" / "assistant_evaluation_identity.py"
RELEASE_CONTRACT = ROOT / "scripts" / "assistant_evaluation_release_contract.sh"


class WorkflowContractTests(unittest.TestCase):
    def test_one_time_stale_claim_cleanup_is_exact_read_only_except_for_two_claims(self):
        path = WORKFLOWS / "recover-stale-publication-claims.yml"
        self.assertTrue(path.exists(), "the exact one-time stale-claim recovery is missing")
        workflow = path.read_text(encoding="utf-8")

        for expected in (
            "workflow_commit:",
            "github.sha == inputs.workflow_commit",
            "environment: production",
            "group: lex-production",
            "cancel-in-progress: false",
            "actions: read",
            "contents: read",
            "id-token: write",
            "GH_TOKEN: ${{ github.token }}",
            "297d84df5dc6c2405c1cd5665fb8d1354f76f013",
            ".github/workflows/publish-prebuilt-index.yml",
            'status == "completed"',
            'conclusion == "failure"',
            "31896356598",
            "31896356790",
            "publication-runs/eu-eurlex/cc6890caa4455bd4efa0c5c72b1c73516e8c0843d988782cf04d5b8dbf38173c.json",
            "0x8DEFAEC98CA64E6",
            "7060a32760b8c3b9699b6877b8d1fe6d3cf8cb969bed04338272c97ec50cf80d",
            "publication-runs/lu-legilux/f2d4c2ed2b673f9db4abda429ba1451c3be80a4344ab589c86b1a7f29d39819c.json",
            "0x8DEFAEC95B00B6C",
            "17098b242d224eeb6f0fd5e2b396e358d21fc4c34396d791df8a62bfdf95d344",
            "current/eu-eurlex.json",
            "0x8DEF9C349323805",
            "a460020a374eaeb7adbcd87fdbeaeb231055e9efd4767422c5940a3f9cf842dc",
            "current/lu-legilux.json",
            "0x8DEF94A869B8C85",
            "6b25b34ab4e773c9f7b417183dc04dcc813c60ed96571fe636818d914aa215c0",
            "0x8DEFAEA3A7D4D33",
            "f827e089bddff64709926af4341bc0ddbfbef829a5c3e29400754aec3b649fd9",
            "589156352",
            "0x8DEFAEC4628DF51",
            "fb600d1221ab108f5f55f287682844b9f2fa03308c5401ed7d9488ae2544b6ad",
            "140342576",
            "0x8DEFAB4AEE3239C",
            "fd404e736c29c4d19174ceb2c14667a80270409d222053fee79f0e25e910c0fa",
            "717422592",
            "0x8DEFAB4AB09F1A2",
            "4a4d5fae77d72e74e4c295eb119f15add988cda6fce85b470ca1eb3873b2294b",
            "46831856",
            "6a2fb2647dea3ba0b3391e40a0612073c626ef0966bd816cdb8b99b57135c8da",
            "index-eu-eurlex-cc6890caa4455bd4efa0c5c72b1c73516e8c0843d988782cf04d5b8dbf38173c",
            "index-lu-legilux-f2d4c2ed2b673f9db4abda429ba1451c3be80a4344ab589c86b1a7f29d39819c",
            "require_github_404",
            "verify_failed_run",
            "verify_claim",
            "inspect_claim",
            "verify_pointer",
            "verify_staging_snapshot",
            "prove_claim_absent",
            "HTTP 404",
            "--if-match",
            "$GITHUB_STEP_SUMMARY",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, workflow)

        self.assertNotIn("actions/checkout@", workflow)
        self.assertEqual(1, workflow.count("uses:"), "only pinned Azure OIDC login is allowed")
        self.assertRegex(
            workflow,
            r"uses: azure/login@[0-9a-f]{40}",
            "Azure login must be pinned to an immutable action commit",
        )
        publisher_workflow = (WORKFLOWS / "publish-prebuilt-index.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("group: publish-prebuilt-${{ inputs.publisher }}", publisher_workflow)
        self.assertIn("group: publish-prebuilt-${{ matrix.publisher }}", workflow)
        self.assertIn("publisher: [eu-eurlex, lu-legilux]", workflow)
        self.assertEqual(1, workflow.count("group: lex-production"))
        self.assertEqual(1, workflow.count("az storage blob delete"))
        self.assertIn('--name "$CLAIM_NAME" --if-match "$CLAIM_ETAG"', workflow)
        self.assertEqual(1, workflow.count("present) delete_claim ;;"))
        self.assertIn("false) printf -v \"$result_name\" '%s' absent", workflow)
        self.assertIn("conditional deletion response was ambiguous", workflow)
        self.assertEqual(
            2,
            len(re.findall(r"^\s+verify_pointer (?:before|after)$", workflow, re.MULTILINE)),
            "each publisher pointer must be byte-verified before and after cleanup",
        )
        self.assertEqual(
            2,
            len(re.findall(r"^\s+verify_staging_snapshot$", workflow, re.MULTILINE)),
            "each publisher staging snapshot must be verified before and after cleanup",
        )
        self.assertEqual(
            2,
            len(
                re.findall(
                    r"^\s+verify_absent_target (?:before|after)$",
                    workflow,
                    re.MULTILINE,
                )
            ),
            "each publisher release and tag must be absent before and after cleanup",
        )
        self.assertEqual(
            workflow.count("az storage blob "),
            workflow.count("--auth-mode login"),
            "every Blob operation must use the production OIDC identity",
        )
        for forbidden in (
            "--auth-mode key",
            "--account-key",
            "--sas-token",
            "az storage blob upload",
            "az storage blob update",
            "az storage blob metadata update",
            "az storage blob copy",
            "az storage blob delete-batch",
            "gh release",
            "git push",
            "workflow_call:",
            "schedule:",
            "LEX_OPS_TOKEN",
            "--request",
            " -X ",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, workflow)

    def test_one_time_stale_claim_cleanup_resumes_absent_and_ambiguous_delete_states(self):
        workflow = (WORKFLOWS / "recover-stale-publication-claims.yml").read_text(
            encoding="utf-8"
        )
        marker = "        run: |\n"
        self.assertIn(marker, workflow)
        run_script = "\n".join(
            line[10:] if line.startswith("          ") else line
            for line in workflow.split(marker, 1)[1].splitlines()
        )
        main_marker = '[[ "$EXPECTED_WORKFLOW_COMMIT" =~'
        self.assertIn(main_marker, run_script)
        prelude = run_script.split(main_marker, 1)[0]

        if os.name == "nt":
            bash = (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
                / "Git"
                / "bin"
                / "bash.exe"
            )
            bash_path = str(bash) if bash.exists() else None
        else:
            bash_path = shutil.which("bash")
        if not bash_path:
            self.skipTest("bash is required for the workflow recovery regression")

        harness = prelude + r'''
mock_state="$INITIAL_STATE"
az() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case "$1 $2 $3" in
    "storage blob exists")
      if [ "$mock_state" = present ]; then printf '%s\n' true; else printf '%s\n' false; fi
      ;;
    "storage blob show")
      printf '"%s"\n' "$CLAIM_ETAG"
      ;;
    "storage blob delete")
      mock_state=absent
      return "$DELETE_EXIT"
      ;;
    *) return 97 ;;
  esac
}
verify_claim() { printf '%s\n' verified >> "$MOCK_LOG"; }
claim_state=
inspect_claim claim_state
case "$claim_state" in
  present) delete_claim ;;
  absent) prove_claim_absent ;;
  *) die "invalid test claim state" ;;
esac
prove_claim_absent
printf 'initial=%s inspected=%s final=%s\n' "$INITIAL_STATE" "$claim_state" "$mock_state"
'''

        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            directory = Path(temporary)
            for initial_state in ("absent", "present"):
                with self.subTest(initial_state=initial_state):
                    log = directory / f"{initial_state}.log"
                    environment = os.environ.copy()
                    environment.update(
                        {
                            "PUBLISHER": "eu-eurlex",
                            "RUNNER_TEMP": directory.as_posix(),
                            "INITIAL_STATE": initial_state,
                            "DELETE_EXIT": "1",
                            "MOCK_LOG": log.as_posix(),
                        }
                    )
                    completed = subprocess.run(
                        [bash_path],
                        cwd=ROOT,
                        env=environment,
                        input=harness,
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(0, completed.returncode, completed.stderr)
                    commands = log.read_text(encoding="utf-8")
                    self.assertIn(f"initial={initial_state}", completed.stdout)
                    self.assertIn(f"inspected={initial_state}", completed.stdout)
                    self.assertIn("final=absent", completed.stdout)
                    if initial_state == "absent":
                        self.assertNotIn("storage blob delete", commands)
                        self.assertNotIn("verified", commands)
                    else:
                        self.assertEqual(1, commands.count("storage blob delete"))
                        self.assertIn("verified", commands)
                        self.assertIn(
                            "--name publication-runs/eu-eurlex/"
                            "cc6890caa4455bd4efa0c5c72b1c73516e8c0843d988782cf04d5b8dbf38173c.json "
                            "--if-match 0x8DEFAEC98CA64E6",
                            commands,
                        )
                        self.assertIn("deletion response was ambiguous", completed.stderr)

    def test_one_time_stale_claim_cleanup_helpers_run_with_nounset(self):
        workflow = (WORKFLOWS / "recover-stale-publication-claims.yml").read_text(
            encoding="utf-8"
        )
        marker = "        run: |\n"
        run_script = "\n".join(
            line[10:] if line.startswith("          ") else line
            for line in workflow.split(marker, 1)[1].splitlines()
        )
        main_marker = '[[ "$EXPECTED_WORKFLOW_COMMIT" =~'
        prelude = run_script.split(main_marker, 1)[0]

        if os.name == "nt":
            bash = (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
                / "Git"
                / "bin"
                / "bash.exe"
            )
            bash_path = str(bash) if bash.exists() else None
        else:
            bash_path = shutil.which("bash")
        if not bash_path:
            self.skipTest("bash is required for the workflow recovery regression")

        mocks = r'''
github_get() { :; }
require_github_404() { :; }
jq() { return 0; }
az() {
  case "$1 $2 $3" in
    "storage blob show") printf '{}\n' ;;
    "storage blob download") return 0 ;;
    *) return 97 ;;
  esac
}
sha256_file() { printf '%s' "$POINTER_SHA256"; }
size_file() { printf '%s' "$POINTER_SIZE"; }
'''

        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            for invocation in (
                "verify_absent_target before",
                "verify_pointer before",
            ):
                with self.subTest(invocation=invocation):
                    environment = os.environ.copy()
                    environment.update(
                        {
                            "PUBLISHER": "eu-eurlex",
                            "RUNNER_TEMP": Path(temporary).as_posix(),
                        }
                    )
                    completed = subprocess.run(
                        [bash_path],
                        cwd=ROOT,
                        env=environment,
                        input=prelude + mocks + invocation + "\n",
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(0, completed.returncode, completed.stderr)

    def test_exact_eu_staging_metadata_repair_is_bounded_and_conditional(self):
        path = WORKFLOWS / "repair-eu-staging-metadata.yml"
        self.assertTrue(path.exists(), "the reviewed one-time repair workflow is missing")
        workflow = path.read_text(encoding="utf-8")

        for expected in (
            "workflow_commit:",
            "if: github.ref == 'refs/heads/main'",
            "environment: production",
            "group: lex-production",
            "id-token: write",
            "contents: read",
            "WORKFLOW_COMMIT: ${{ github.sha }}",
            "EXPECTED_WORKFLOW_COMMIT: ${{ inputs.workflow_commit }}",
            "staging/eu-eurlex/cc6890caa4455bd4efa0c5c72b1c73516e8c0843d988782cf04d5b8dbf38173c",
            'DB_OLD_ETAG: "0x8DEFAB361991E14"',
            'DB_CONTENT_MD5_BASE64: ""',
            'VECTORS_OLD_ETAG: "0x8DEFAB361980DD4"',
            'VECTORS_CONTENT_MD5_BASE64: "ZzhDHADQX2tUFEJ3YPrRNg=="',
            "f827e089bddff64709926af4341bc0ddbfbef829a5c3e29400754aec3b649fd9",
            "fb600d1221ab108f5f55f287682844b9f2fa03308c5401ed7d9488ae2544b6ad",
            "ARTICLES_GENERATION_SHA256: 6a2fb2647dea3ba0b3391e40a0612073c626ef0966bd816cdb8b99b57135c8da",
            "articles_generation_sha256=$ARTICLES_GENERATION_SHA256",
            "application/vnd.sqlite3",
            "az storage blob metadata update",
            "az storage blob update",
            "--if-match",
            "az storage blob download",
            "sha256sum",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, workflow)

        self.assertIn("exact two-blob inventory", workflow)
        self.assertIn("legacy staging snapshot changed", workflow)
        self.assertIn("post-repair staging snapshot is not canonical", workflow)
        self.assertIn("post-repair byte hash differs", workflow)
        self.assertNotRegex(
            workflow,
            r"\b(?:db|vectors)_etag=\$\(repair_blob\b",
            "repair_blob must run directly so Bash errexit is not cleared by command substitution",
        )
        self.assertIn(
            '"$DB_CONTENT_MD5_BASE64" application/vnd.sqlite3 db db_etag',
            workflow,
        )
        self.assertIn(
            '"$VECTORS_SIZE" "$VECTORS_CONTENT_MD5_BASE64" '
            'application/octet-stream vectors vectors_etag',
            workflow,
        )
        self.assertIn('if ($expected_md5 | length) == 0', workflow)
        self.assertIn('then .properties.contentSettings.contentMd5 == null', workflow)
        self.assertIn('else .properties.contentSettings.contentMd5 == $expected_md5', workflow)
        self.assertIn('printf -v "$result_name" \'%s\' "$etag"', workflow)
        self.assertEqual(6, workflow.count("az storage blob "))
        self.assertEqual(
            workflow.count("az storage blob "),
            workflow.count("--auth-mode login"),
            "every Blob data-plane command must use OIDC login rather than key fallback",
        )
        self.assertEqual(3, workflow.count("--if-match"))
        for conditional_command in (
            "az storage blob download",
            "az storage blob metadata update",
            "az storage blob update",
        ):
            with self.subTest(conditional_command=conditional_command):
                self.assertRegex(
                    workflow,
                    rf"(?s){re.escape(conditional_command)}"
                    rf"(?:(?!\n\s*az storage blob ).)*?--if-match",
                    f"{conditional_command} must be ETag-conditional",
                )
        for forbidden in (
            "--auth-mode key",
            "--account-key",
            "--sas-token",
            "az storage blob upload",
            "az storage blob delete",
            "az storage blob copy",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, workflow)

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
        self.assertIn("candidate_owned=false", workflow)

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
        contract = RELEASE_CONTRACT.read_text(encoding="utf-8")
        publication = workflow.index('gh release upload "$EVALUATION_RELEASE"')
        prepublication = workflow.index("  immutable_prepublication:\n", publication)
        publish_boundary = workflow.index("gh api --method PATCH", prepublication)
        final_state = workflow.index("for attempt in {1..12}", publish_boundary)
        readback = workflow.index("validate_release_snapshot public", final_state)
        final_live = workflow.index("bootstrap-routes.readback.json", publication)

        self.assertLess(publication, final_live)
        self.assertLess(final_live, prepublication)
        self.assertLess(prepublication, publish_boundary)
        self.assertLess(publish_boundary, final_state)
        self.assertLess(final_state, readback)
        self.assertIn('.draft == ($state == "draft")', contract)
        self.assertIn('.immutable == ($state == "public")', contract)
        self.assertIn("[.assets[] | {name,digest,size,state}]", contract)
        self.assertIn("releases/assets/$asset_id", contract)
        self.assertIn("--retry-all-errors", contract)
        self.assertIn('sha256sum "$downloaded"', contract)
        self.assertIn('wc -c < "$downloaded"', contract)
        self.assertIn("evaluation release is not an exact retry-safe release", workflow)
        post_publish = workflow[publish_boundary:]
        self.assertNotIn('gh release upload "$EVALUATION_RELEASE"', post_publish)
        self.assertNotIn('gh release download "$EVALUATION_RELEASE"', post_publish)

    def test_evaluation_split_preserves_candidate_cleanup_authority(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        )
        ownership_start = workflow.index("  acquire_candidate_ownership:\n")
        prepare_start = workflow.index("  prepare:\n")
        publish_start = workflow.index("  publish:\n", prepare_start)
        postcheck_start = workflow.index("  verify:\n", publish_start)
        cleanup_start = workflow.index("  restore_candidate_if_unpublished:\n")
        ownership = workflow[ownership_start:prepare_start]
        prepare = workflow[prepare_start:publish_start]
        publish = workflow[publish_start:postcheck_start]
        cleanup = workflow[cleanup_start:]

        self.assertIn("candidate_owned: ${{ steps.acquire.outputs.candidate_owned }}", ownership)
        self.assertNotIn("revision activate", ownership)
        self.assertNotIn("revision deactivate", ownership)
        self.assertIn(
            '"repos/$EVALUATION_REPOSITORY/releases/$evaluation_release_id"',
            ownership,
        )
        self.assertIn(
            '"repos/$EVALUATION_REPOSITORY/releases/assets/$report_asset_id"',
            ownership,
        )
        self.assertIn(
            ".identity.target.revision_name == $candidate", ownership
        )
        self.assertIn(
            'bound_release="assistant-eval-${report_code_commit:0:12}-'
            '${actual_report_sha:0:12}"',
            ownership,
        )
        self.assertIn("needs: acquire_candidate_ownership", prepare)
        self.assertNotIn("candidate_owned: ${{ steps.stage.outputs.candidate_owned }}", prepare)
        self.assertIn('if [ "$status" -ne 0 ]; then', prepare)
        self.assertIn("cleanup_candidate || status=1", prepare)
        self.assertIn("trap finish EXIT TERM INT", prepare)

        self.assertIn("cleanup_candidate()", publish)
        self.assertIn("cleanup_candidate || status=1", publish)
        self.assertIn("trap finish EXIT TERM INT", publish)
        payload = publish.index("release-publish-payload.json")
        live_state = publish.index("publication-state.json", payload)
        relinquish = publish.index("candidate_owned=false", payload)
        boundary = publish.index("gh api --method PATCH", relinquish)
        self.assertLess(payload, relinquish)
        self.assertLess(payload, live_state)
        self.assertLess(live_state, relinquish)
        self.assertLess(relinquish, boundary)
        self.assertIn(
            "EXPECTED_BOOTSTRAP_ROUTES_SHA256: "
            "${{ needs.prepare.outputs.bootstrap_routes_sha256 }}",
            publish,
        )
        self.assertIn(
            "bootstrap_routes_sha256: ${{ steps.stage.outputs.bootstrap_routes_sha256 }}",
            prepare,
        )

        cleanup_header = cleanup[: cleanup.index("    permissions:")]
        self.assertIn(
            "needs.acquire_candidate_ownership.outputs.candidate_owned == 'true'",
            cleanup_header,
        )
        self.assertIn("needs.publish.result != 'success'", cleanup_header)
        self.assertNotIn("publication_attempted", cleanup_header)
        self.assertIn("always()", cleanup)
        self.assertIn("Restore one active quota authority", cleanup)
        self.assertNotIn("actions/checkout", cleanup)
        disambiguation = cleanup.index('if [ "$BOOTSTRAP_MODE" = true ]; then')
        deactivation = cleanup.index("for attempt in {1..6}")
        self.assertLess(disambiguation, deactivation)
        self.assertIn("PUBLISH_RESULT: ${{ needs.publish.result }}", cleanup)
        self.assertIn(
            "PUBLICATION_ATTEMPTED: "
            "${{ needs.publish.outputs.publication_attempted }}",
            cleanup,
        )
        self.assertIn(
            '"repos/$EVALUATION_REPOSITORY/releases/$EVALUATION_RELEASE_ID"',
            cleanup,
        )
        self.assertIn("retain bootstrap C for explicit recovery", cleanup)

    def test_standard_candidate_recovery_survives_attempted_publish_failure_or_cancel(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        )
        cleanup_start = workflow.index("  restore_candidate_if_unpublished:\n")
        cleanup = workflow[cleanup_start:]
        cleanup_header = cleanup[: cleanup.index("    permissions:")]
        cleanup_script = cleanup[cleanup.index("        run: |") :]

        self.assertIn("needs.publish.result != 'success'", cleanup_header)
        self.assertNotIn("needs.publish.outputs.publication_attempted", cleanup_header)
        bootstrap_guard = cleanup_script.index('if [ "$BOOTSTRAP_MODE" = true ]; then')
        attempted_guard = cleanup_script.index('PUBLICATION_ATTEMPTED')
        deactivation = cleanup_script.index("for attempt in {1..6}")
        self.assertLess(bootstrap_guard, attempted_guard)
        self.assertLess(attempted_guard, deactivation)
        self.assertIn(
            "BOOTSTRAP_MODE: ${{ needs.acquire_candidate_ownership.outputs.bootstrap_mode }}",
            cleanup,
        )

    def test_candidate_ownership_and_cleanup_never_claim_live_traffic(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        )
        contract = (
            ROOT / "scripts" / "assistant_evaluation_release_contract.sh"
        ).read_text(encoding="utf-8")
        ownership_start = workflow.index("  acquire_candidate_ownership:\n")
        prepare_start = workflow.index("  prepare:\n")
        cleanup_start = workflow.index("  restore_candidate_if_unpublished:\n")
        ownership = workflow[ownership_start:prepare_start]
        cleanup = workflow[cleanup_start:]

        self.assertIn("Azure login for read-only candidate acquisition", ownership)
        self.assertIn('(.properties.trafficWeight // 0) == 0', ownership)
        self.assertIn('[ "$candidate_active" = false ]', ownership)
        self.assertIn('[ "$candidate_active" = true ]', ownership)
        self.assertIn("validate_bootstrap_abandonment_prestate", ownership)
        cleanup_state = cleanup.index("candidate-cleanup-state.json")
        bootstrap_prestate = cleanup.index("bootstrap-cleanup-routes.json")
        inactive_limit = cleanup.index("maxInactiveRevisions == 1", bootstrap_prestate)
        exact_routes = cleanup.index("length == 3", inactive_limit)
        traffic_guard = cleanup.index('(.properties.trafficWeight // 0) == 0', cleanup_state)
        deactivation = cleanup.index("revision deactivate", traffic_guard)
        self.assertLess(bootstrap_prestate, inactive_limit)
        self.assertLess(inactive_limit, exact_routes)
        self.assertLess(exact_routes, deactivation)
        self.assertLess(cleanup_state, traffic_guard)
        self.assertLess(traffic_guard, deactivation)
        self.assertIn("deactivate_zero_traffic_candidate()", contract)
        self.assertIn("validate_bootstrap_abandonment_prestate()", contract)
        self.assertIn("maxInactiveRevisions == 1", contract)
        self.assertIn("length == 3", contract)
        self.assertIn('(.properties.trafficWeight // 0) == 0', contract)
        self.assertEqual(
            2,
            workflow.count(
                'deactivate_zero_traffic_candidate "$RESOURCE_GROUP" '
                '"$CONTAINER_APP" "$CANDIDATE_REVISION"'
            ),
        )

    def test_immutable_setting_secret_runs_only_on_fresh_isolated_jobs(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        )
        job_pattern = re.compile(
            r"^  (?P<id>[a-z][a-z0-9_]*):\r?\n(?P<body>.*?)"
            r"(?=^  [a-z][a-z0-9_]*:\r?\n|\Z)",
            re.MULTILINE | re.DOTALL,
        )
        jobs = {
            match.group("id"): match.group("body")
            for match in job_pattern.finditer(workflow)
        }
        secret_binding = (
            "LEX_OPS_TOKEN: ${{ secrets.LEX_OPS_TOKEN }}"
        )
        secret_jobs = {
            job_id: body for job_id, body in jobs.items() if secret_binding in body
        }
        self.assertEqual(
            {"immutable_prepublication"},
            set(secret_jobs),
        )
        for job_id, body in secret_jobs.items():
            with self.subTest(job=job_id):
                self.assertIn("runs-on: ubuntu-latest", body)
                self.assertIn("permissions: {}", body)
                self.assertIn("environment: production", body)
                self.assertEqual(
                    1,
                    len(re.findall(r"(?m)^      - (?:name:|uses:)", body)),
                )
                self.assertEqual(1, body.count(secret_binding))
                self.assertNotIn("actions/checkout", body)
                self.assertNotIn("      - uses:", body)
                self.assertNotIn("GITHUB_ENV", body)
                self.assertNotIn("GITHUB_PATH", body)
                self.assertIn("BASH_ENV: /dev/null", body)
                self.assertIn("PATH: /usr/bin:/bin", body)
                self.assertIn(
                    "shell: /usr/bin/bash --noprofile --norc -euo pipefail {0}",
                    body,
                )
                self.assertEqual(1, body.count("/usr/bin/gh api --method GET"))
                self.assertEqual(1, body.count("/usr/bin/jq -e"))
                for forbidden in (
                    "gh release",
                    "gh api --method POST",
                    "gh api --method PATCH",
                    "gh api --method DELETE",
                    "dotnet",
                    "npm ",
                    "source ",
                    ". scripts/",
                    ". lex/",
                ):
                    self.assertNotIn(forbidden, body)
                self.assertNotRegex(body, r"(?m)^\s*(?:for|while|until)\b")

        self.assertIn("needs: acquire_candidate_ownership", jobs["prepare"])
        self.assertIn("needs: prepare", jobs["immutable_prepublication"])
        self.assertIn(
            "needs: [prepare, immutable_prepublication]",
            jobs["publish"],
        )
        self.assertIn(
            "needs: [prepare, publish]",
            jobs["verify"],
        )
        self.assertIn("always()", jobs["verify"])
        self.assertIn("needs.prepare.result == 'success'", jobs["verify"])
        self.assertIn(
            "needs.publish.outputs.publication_attempted != 'false'",
            jobs["verify"],
        )

    def test_evaluation_publishes_only_the_pinned_release_id_at_the_boundary(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn('gh release edit "$EVALUATION_RELEASE"', workflow)
        publish_start = workflow.index("  publish:\n")
        postcheck_start = workflow.index("  verify:\n", publish_start)
        publish = workflow[publish_start:postcheck_start]
        self.assertIn(
            "EVALUATION_RELEASE_ID: ${{ needs.prepare.outputs.evaluation_release_id }}",
            publish,
        )
        payload = publish.index("release-publish-payload.json")
        exact_patch = publish.index(
            'gh api --method PATCH',
            payload,
        )
        live_state = publish.index("publication-state.json", payload)
        final_draft_recheck = publish.index(
            "draft release changed immediately before publication", live_state
        )
        self.assertIn(
            '"repos/$EVALUATION_REPOSITORY/releases/$EVALUATION_RELEASE_ID"',
            publish[exact_patch:],
        )
        relinquish = publish.index("candidate_owned=false", payload)
        self.assertLess(payload, relinquish)
        self.assertLess(live_state, final_draft_recheck)
        self.assertLess(final_draft_recheck, relinquish)
        self.assertLess(relinquish, exact_patch)
        self.assertIn(
            'echo "publication_attempted=true" >> "$GITHUB_OUTPUT"; \\\n'
            "            gh api --method PATCH",
            publish,
        )
        gap = publish[relinquish:exact_patch]
        for forbidden in (
            "release_notes=",
            "jq ",
            "fetch_release_snapshot",
            "validate_release_snapshot",
            "validate_release_tag",
        ):
            self.assertNotIn(forbidden, gap)

    def test_immutable_setting_credential_executes_one_bounded_get(self):
        candidate = (
            Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
            / "Git"
            / "bin"
            / "bash.exe"
        )
        bash = str(candidate) if candidate.is_file() else shutil.which("bash")
        if bash is None or shutil.which("jq") is None:
            self.skipTest("bash and jq are required for credential boundary tests")

        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(
            encoding="utf-8"
        )
        job_pattern = re.compile(
            r"^  (?P<id>[a-z][a-z0-9_]*):\r?\n(?P<body>.*?)"
            r"(?=^  [a-z][a-z0-9_]*:\r?\n|\Z)",
            re.MULTILINE | re.DOTALL,
        )
        jobs = {
            match.group("id"): match.group("body")
            for match in job_pattern.finditer(workflow)
        }
        names = ("immutable_prepublication",)
        scripts = []
        for name in names:
            body = jobs[name]
            marker = "        run: |\n"
            self.assertIn(marker, body)
            script = textwrap.dedent(body.split(marker, 1)[1])
            scripts.append(
                "set -euo pipefail\n"
                + script.replace("/usr/bin/gh", "gh").replace("/usr/bin/jq", "jq")
            )

        mock = r'''gh() {
  printf '%s\t%s\n' "${GH_TOKEN:-}" "$*" >> "$GH_AUDIT"
  printf '%s\n' "$GH_RESPONSE"
}
'''
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            directory = Path(temporary)
            audit = directory / "gh-audit.log"
            audit.write_text("", encoding="utf-8")
            environment = {
                **os.environ,
                "EVALUATION_REPOSITORY": "SFHAJJI/lex-ops",
                "GH_AUDIT": audit.as_posix(),
                "GH_RESPONSE": json.dumps(
                    {"enabled": True, "enforced_by_owner": False}
                ),
                "GH_TOKEN": "workflow-token",
                "LEX_OPS_TOKEN": "bounded-existing-token",
                "RUNNER_TEMP": directory.as_posix(),
            }
            for name, script in zip(names, scripts):
                completed = subprocess.run(
                    [bash, "-c", mock + script],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                with self.subTest(step=name):
                    self.assertEqual(0, completed.returncode, completed.stderr)

            calls = audit.read_text(encoding="utf-8").splitlines()
            self.assertEqual(1, len(calls), calls)
            for call in calls:
                token, arguments = call.split("\t", 1)
                self.assertEqual("bounded-existing-token", token)
                self.assertEqual(
                    "api --method GET -H Accept: application/vnd.github+json "
                    "-H X-GitHub-Api-Version: 2026-03-10 "
                    "repos/SFHAJJI/lex-ops/immutable-releases",
                    arguments,
                )

            missing = subprocess.run(
                [bash, "-c", mock + scripts[0]],
                cwd=ROOT,
                env={**environment, "LEX_OPS_TOKEN": ""},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(0, missing.returncode)
            self.assertEqual(1, len(audit.read_text(encoding="utf-8").splitlines()))

            disabled = subprocess.run(
                [bash, "-c", mock + scripts[0]],
                cwd=ROOT,
                env={
                    **environment,
                    "GH_RESPONSE": json.dumps(
                        {"enabled": False, "enforced_by_owner": False}
                    ),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(0, disabled.returncode)

    def test_evaluation_public_retry_verifies_without_mutating_the_release(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        retry_start = workflow.index('if [ "$PUBLIC_RETRY" = "true" ]')
        retry_end = workflow.index("bootstrap C must already be active", retry_start)
        retry = workflow[retry_start:retry_end]

        self.assertIn("assistant-eval verify-release", retry)
        self.assertIn(
            "candidate_owned: ${{ steps.acquire.outputs.candidate_owned }}", workflow
        )
        self.assertNotIn("gh release", retry)
        self.assertNotIn("gh api", retry)
        self.assertNotIn("curl", retry)
        self.assertIn('echo "PUBLIC_RETRY=$public_retry" >> "$GITHUB_ENV"', workflow)

    def test_evaluation_publication_describes_project_owner_review_honestly(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("project-owner review signature: verified", workflow)
        self.assertNotIn("independent review signature: verified", workflow)
        self.assertRegex(readme, r"verifies the project-owner review\s+signature")
        self.assertNotRegex(readme, r"verifies the independent human\s+review")
        self.assertIn("Promotion independently revalidates this package", workflow)

    def test_evaluation_release_json_contract_fails_closed(self):
        contract = RELEASE_CONTRACT.read_text(encoding="utf-8")
        candidate = (
            Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
            / "Git"
            / "bin"
            / "bash.exe"
        )
        bash = str(candidate) if candidate.is_file() else shutil.which("bash")
        self.assertIsNotNone(bash, "Git Bash is required for release contract tests")

        tag = "assistant-eval-aaaaaaaaaaaa-bbbbbbbbbbbb"
        commit = "c" * 40
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            directory = Path(temporary)
            contract_path = directory / "release-contract.sh"
            contract_path.write_text(contract, encoding="utf-8", newline="\n")
            evidence = directory / "evidence"
            evidence.mkdir()
            name = "assistant-eval-report.json"
            asset_path = evidence / name
            asset_path.write_bytes(b"exact release bytes")
            names_path = directory / "names.json"
            names_path.write_text(json.dumps([name]), encoding="utf-8")
            asset = {
                "id": 42,
                "name": name,
                "digest": "sha256:" + hashlib.sha256(asset_path.read_bytes()).hexdigest(),
                "size": asset_path.stat().st_size,
                "state": "uploaded",
            }
            release = {
                "draft": False,
                "prerelease": False,
                "immutable": True,
                "tag_name": tag,
                "target_commitish": "main",
                "assets": [asset],
            }
            tag_ref = {
                "ref": f"refs/tags/{tag}",
                "object": {"type": "commit", "sha": commit},
            }
            environment = {
                **os.environ,
                "EVALUATION_RELEASE": tag,
                "EVALUATION_REPOSITORY": "SFHAJJI/lex-ops",
                "WORKFLOW_COMMIT": commit,
            }

            def run_release(
                release_value=release,
                tag_value=tag_ref,
                state="public",
            ):
                release_path = directory / "release.json"
                tag_path = directory / "tag.json"
                release_path.write_text(json.dumps(release_value), encoding="utf-8")
                tag_path.write_text(json.dumps(tag_value), encoding="utf-8")
                return subprocess.run(
                    [
                        bash,
                        "-c",
                        'set -euo pipefail; . "$1"; '
                        'validate_release_snapshot "$2" "$3" "$4" "$5" false; '
                        'validate_release_tag "$6"',
                        "_",
                        contract_path.as_posix(),
                        state,
                        evidence.as_posix(),
                        names_path.as_posix(),
                        release_path.as_posix(),
                        tag_path.as_posix(),
                    ],
                    cwd=ROOT,
                    env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            valid_public = run_release()
            self.assertEqual(0, valid_public.returncode, valid_public.stderr)

            draft = json.loads(json.dumps(release))
            draft.update(draft=True, immutable=False)
            valid_draft = run_release(draft, state="draft")
            self.assertEqual(0, valid_draft.returncode, valid_draft.stderr)

            for field, value in (
                ("draft", True),
                ("prerelease", True),
                ("immutable", False),
                ("target_commitish", commit),
                ("tag_name", "assistant-eval-wrong"),
            ):
                changed = json.loads(json.dumps(release))
                changed[field] = value
                with self.subTest(field=field):
                    self.assertNotEqual(0, run_release(changed).returncode)
            for label, added in (
                ("extra", {"name": "injected", "digest": "sha256:" + "f" * 64, "size": 1, "state": "uploaded"}),
                ("duplicate", dict(asset)),
            ):
                changed = json.loads(json.dumps(release))
                changed["assets"].append(added)
                with self.subTest(asset_set=label):
                    self.assertNotEqual(0, run_release(changed).returncode)
            for field, value in (
                ("digest", "sha256:" + "f" * 64),
                ("size", 999),
                ("state", "new"),
            ):
                changed = json.loads(json.dumps(release))
                changed["assets"][0][field] = value
                with self.subTest(asset_field=field):
                    self.assertNotEqual(0, run_release(changed).returncode)
            for label, changed_ref in (
                ("wrong ref", {**tag_ref, "ref": "refs/tags/assistant-eval-wrong"}),
                ("indirect", {**tag_ref, "object": {"type": "tag", "sha": commit}}),
                (
                    "wrong target",
                    {**tag_ref, "object": {"type": "commit", "sha": "d" * 40}},
                ),
            ):
                with self.subTest(tag_ref=label):
                    self.assertNotEqual(0, run_release(tag_value=changed_ref).returncode)

            def run_tag_creation(state, initial_missing, tag_value=tag_ref, post_rc=0):
                output_path = directory / "created-tag.json"
                log_path = directory / "gh.log"
                log_path.write_text("", encoding="utf-8")
                result = subprocess.run(
                    [
                        bash,
                        "-c",
                        r'''set -euo pipefail
. "$1"
get_count=0
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  if [[ " $* " == *" --method POST "* ]]; then
    return "$GH_POST_RC"
  fi
  get_count=$((get_count + 1))
  if [ "$GH_INITIAL_MISSING" = true ] && [ "$get_count" = 1 ]; then
    return 1
  fi
  printf '%s\n' "$GH_TAG_JSON"
}
ensure_release_tag "$2" "$3"
''',
                        "_",
                        contract_path.as_posix(),
                        state,
                        output_path.as_posix(),
                    ],
                    cwd=ROOT,
                    env={
                        **environment,
                        "GH_LOG": str(log_path),
                        "GH_POST_RC": str(post_rc),
                        "GH_INITIAL_MISSING": str(initial_missing).lower(),
                        "GH_TAG_JSON": json.dumps(
                            tag_value
                        ),
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )
                return result, log_path.read_text(encoding="utf-8")

            public_missing, public_log = run_tag_creation("public", True)
            self.assertNotEqual(0, public_missing.returncode)
            self.assertNotIn("--method POST", public_log)

            draft_created, draft_log = run_tag_creation("draft", True)
            self.assertEqual(0, draft_created.returncode, draft_created.stderr)
            self.assertIn("--method POST", draft_log)
            self.assertIn(f"ref=refs/tags/{tag}", draft_log)
            self.assertIn(f"sha={commit}", draft_log)

            raced_create, raced_log = run_tag_creation("draft", True, post_rc=1)
            self.assertEqual(0, raced_create.returncode, raced_create.stderr)
            self.assertIn("--method POST", raced_log)

            wrong_existing, wrong_log = run_tag_creation(
                "draft",
                False,
                {**tag_ref, "object": {"type": "commit", "sha": "d" * 40}},
            )
            self.assertNotEqual(0, wrong_existing.returncode)
            self.assertNotIn("--method POST", wrong_log)

            def run_snapshot_fetch(release_id):
                output_path = directory / "fetched-release.json"
                log_path = directory / "fetch.log"
                log_path.write_text("", encoding="utf-8")
                result = subprocess.run(
                    [
                        bash,
                        "-c",
                        r'''set -euo pipefail
. "$1"
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  printf '%s\n' "$GH_RELEASE_JSON"
}
fetch_release_snapshot "$2"
''',
                        "_",
                        contract_path.as_posix(),
                        output_path.as_posix(),
                    ],
                    cwd=ROOT,
                    env={
                        **environment,
                        "EVALUATION_RELEASE_ID": release_id,
                        "GH_LOG": str(log_path),
                        "GH_RELEASE_JSON": json.dumps(release),
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )
                return result, log_path.read_text(encoding="utf-8")

            fetched, fetch_log = run_snapshot_fetch("17")
            self.assertEqual(0, fetched.returncode, fetched.stderr)
            self.assertIn("repos/SFHAJJI/lex-ops/releases/17", fetch_log)
            self.assertNotIn("/releases/tags/", fetch_log)
            for invalid_id in ("", "0", "01", "-1", "1.0", "abc"):
                invalid_fetch, invalid_log = run_snapshot_fetch(invalid_id)
                with self.subTest(release_id=invalid_id):
                    self.assertNotEqual(0, invalid_fetch.returncode)
                    self.assertEqual("", invalid_log)

            download_root = directory / "downloaded"
            download_log = directory / "download.log"
            downloaded = subprocess.run(
                [
                    bash,
                    "-c",
                    r'''set -euo pipefail
. "$1"
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  printf '%s' 'exact release bytes'
}
download_release_assets_by_id "$2" "$3"
''',
                    "_",
                    contract_path.as_posix(),
                    download_root.as_posix(),
                    (directory / "release.json").as_posix(),
                ],
                cwd=ROOT,
                env={**environment, "GH_LOG": str(download_log)},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, downloaded.returncode, downloaded.stderr)
            self.assertEqual(asset_path.read_bytes(), (download_root / name).read_bytes())
            download_calls = download_log.read_text(encoding="utf-8")
            self.assertIn("repos/SFHAJJI/lex-ops/releases/assets/42", download_calls)
            self.assertNotIn("/releases/tags/", download_calls)

            routes_one = directory / "routes-one.json"
            routes_two = directory / "routes-two.json"
            routes_changed = directory / "routes-changed.json"
            canonical_one = directory / "routes-one.canonical.json"
            canonical_two = directory / "routes-two.canonical.json"
            canonical_changed = directory / "routes-changed.canonical.json"
            route = {
                "id": "/apps/lex/revisions/candidate",
                "name": "ca-lex-web--candidate",
                "properties": {
                    "active": True,
                    "trafficWeight": 0,
                    "replicas": 1,
                    "runningState": "Running",
                    "healthState": "Healthy",
                    "lastActiveTime": "2026-08-15T10:00:00Z",
                },
            }
            routes_one.write_text(json.dumps([route]), encoding="utf-8")
            drifted = json.loads(json.dumps(route))
            drifted["properties"].update(
                replicas=3,
                runningState="Processing",
                healthState="Unknown",
                lastActiveTime="2026-08-15T10:05:00Z",
            )
            routes_two.write_text(json.dumps([drifted]), encoding="utf-8")
            changed = json.loads(json.dumps(drifted))
            changed["properties"]["trafficWeight"] = 100
            routes_changed.write_text(json.dumps([changed]), encoding="utf-8")

            def canonicalize(source, output):
                return subprocess.run(
                    [
                        bash,
                        "-c",
                        'set -euo pipefail; . "$1"; '
                        'canonicalize_revision_routes "$2" "$3"',
                        "_",
                        contract_path.as_posix(),
                        source.as_posix(),
                        output.as_posix(),
                    ],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )

            self.assertEqual(0, canonicalize(routes_one, canonical_one).returncode)
            self.assertEqual(0, canonicalize(routes_two, canonical_two).returncode)
            self.assertEqual(canonical_one.read_bytes(), canonical_two.read_bytes())
            self.assertEqual(
                0, canonicalize(routes_changed, canonical_changed).returncode
            )
            self.assertNotEqual(
                canonical_one.read_bytes(), canonical_changed.read_bytes()
            )

            def run_candidate_cleanup(active, traffic):
                state_path = directory / "candidate-state.json"
                marker_path = directory / "candidate-deactivated"
                log_path = directory / "candidate-cleanup.log"
                marker_path.unlink(missing_ok=True)
                log_path.write_text("", encoding="utf-8")
                state_path.write_text(
                    json.dumps(
                        {
                            "name": "ca-lex-web--candidate",
                            "properties": {
                                "active": active,
                                "trafficWeight": traffic,
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                result = subprocess.run(
                    [
                        bash,
                        "-c",
                        r'''set -euo pipefail
. "$1"
az() {
  printf '%s\n' "$*" >> "$AZ_LOG"
  case "$1 $2 $3" in
    "containerapp revision show")
      if [ -f "$AZ_DEACTIVATED" ]; then
        jq '.properties.active = false' "$AZ_STATE"
      else
        cat "$AZ_STATE"
      fi
      ;;
    "containerapp revision deactivate") touch "$AZ_DEACTIVATED" ;;
    *) return 97 ;;
  esac
}
sleep() { :; }
deactivate_zero_traffic_candidate rg-platform ca-lex-web ca-lex-web--candidate
''',
                        "_",
                        contract_path.as_posix(),
                    ],
                    cwd=ROOT,
                    env={
                        **environment,
                        "RUNNER_TEMP": directory.as_posix(),
                        "AZ_STATE": state_path.as_posix(),
                        "AZ_DEACTIVATED": marker_path.as_posix(),
                        "AZ_LOG": log_path.as_posix(),
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )
                return result, log_path.read_text(encoding="utf-8")

            safe_cleanup, safe_log = run_candidate_cleanup(True, 0)
            self.assertEqual(0, safe_cleanup.returncode, safe_cleanup.stderr)
            self.assertIn("containerapp revision deactivate", safe_log)
            inactive_cleanup, inactive_log = run_candidate_cleanup(False, 0)
            self.assertEqual(0, inactive_cleanup.returncode, inactive_cleanup.stderr)
            self.assertNotIn("containerapp revision deactivate", inactive_log)
            live_cleanup, live_log = run_candidate_cleanup(True, 100)
            self.assertNotEqual(0, live_cleanup.returncode)
            self.assertNotIn("containerapp revision deactivate", live_log)

            def run_bootstrap_prestate(routes, inactive_limit=1):
                app_path = directory / "bootstrap-app.json"
                routes_path = directory / "bootstrap-routes.json"
                app_path.write_text(
                    json.dumps(
                        {
                            "properties": {
                                "configuration": {
                                    "maxInactiveRevisions": inactive_limit
                                }
                            }
                        }
                    ),
                    encoding="utf-8",
                )
                routes_path.write_text(json.dumps(routes), encoding="utf-8")
                return subprocess.run(
                    [
                        bash,
                        "-c",
                        r'''set -euo pipefail
. "$1"
az() {
  case "$1 $2 $3" in
    "containerapp show -g") cat "$AZ_APP" ;;
    "containerapp revision list") cat "$AZ_ROUTES" ;;
    *) return 97 ;;
  esac
}
validate_bootstrap_abandonment_prestate \
  rg-platform ca-lex-web ca-lex-web--candidate ca-lex-web--rollback
''',
                        "_",
                        contract_path.as_posix(),
                    ],
                    cwd=ROOT,
                    env={
                        **environment,
                        "RUNNER_TEMP": directory.as_posix(),
                        "AZ_APP": app_path.as_posix(),
                        "AZ_ROUTES": routes_path.as_posix(),
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )

            bootstrap_routes = [
                {
                    "name": "ca-lex-web--authority",
                    "properties": {"active": True, "trafficWeight": 100},
                },
                {
                    "name": "ca-lex-web--rollback",
                    "properties": {"active": False, "trafficWeight": 0},
                },
                {
                    "name": "ca-lex-web--candidate",
                    "properties": {"active": True, "trafficWeight": 0},
                },
            ]
            self.assertEqual(
                0, run_bootstrap_prestate(bootstrap_routes).returncode
            )
            self.assertNotEqual(
                0, run_bootstrap_prestate(bootstrap_routes, inactive_limit=2).returncode
            )
            extra_routes = [*bootstrap_routes, bootstrap_routes[1]]
            self.assertNotEqual(0, run_bootstrap_prestate(extra_routes).returncode)
            live_candidate = json.loads(json.dumps(bootstrap_routes))
            live_candidate[2]["properties"]["trafficWeight"] = 10
            self.assertNotEqual(0, run_bootstrap_prestate(live_candidate).returncode)

    def test_evaluation_release_is_attested_before_azure_and_frozen_exactly(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        contract = RELEASE_CONTRACT.read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("attestations: read", workflow)
        self.assertIn("WORKFLOW_COMMIT: ${{ github.sha }}", workflow)
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", workflow)
        self.assertIn('gh release verify "$EVALUATION_RELEASE" --repo "$EVALUATION_REPOSITORY"', contract)
        self.assertIn('gh release verify-asset "$EVALUATION_RELEASE"', contract)
        self.assertIn('repos/$EVALUATION_REPOSITORY/git/ref/tags/$EVALUATION_RELEASE', workflow)
        self.assertIn('[[ "$WORKFLOW_COMMIT" =~ ^[0-9a-f]{40}$ ]]', workflow)
        self.assertIn(
            'gh release view "$EVALUATION_RELEASE" --repo "$EVALUATION_REPOSITORY"',
            workflow + contract,
        )
        self.assertIn("--json databaseId,tagName", workflow)
        self.assertNotIn(
            'repos/$EVALUATION_REPOSITORY/releases/tags/$EVALUATION_RELEASE',
            workflow,
        )

        secret_binding = "LEX_OPS_TOKEN: ${{ secrets.LEX_OPS_TOKEN }}"
        step_pattern = re.compile(
            r"^      - name: (?P<name>[^\r\n]+)\r?\n(?P<body>.*?)"
            r"(?=^      - (?:name:|uses:)|\Z)",
            re.MULTILINE | re.DOTALL,
        )
        secret_steps = [
            (match.group("name"), match.group("body"))
            for match in step_pattern.finditer(workflow)
            if secret_binding in match.group("body")
        ]
        self.assertEqual(
            ["Recheck immutable-release setting before publication"],
            [name for name, _ in secret_steps],
        )
        self.assertEqual(1, workflow.count(secret_binding))
        self.assertNotIn("IMMUTABLE_RELEASES_READ_TOKEN", workflow + readme)
        self.assertEqual(
            1,
            workflow.count(
                'GH_TOKEN="$LEX_OPS_TOKEN" /usr/bin/gh api --method GET'
            ),
        )
        self.assertEqual(
            1,
            workflow.count("repos/SFHAJJI/lex-ops/immutable-releases"),
        )
        self.assertNotIn("read_immutable_release_setting", workflow)
        self.assertIn("`LEX_OPS_TOKEN`", readme)
        self.assertIn("one hard-coded prepublication Immutable Releases setting read", readme)
        self.assertIn("sole step on a fresh,", readme)
        self.assertIn("patches the pinned numeric release ID", readme)

        identity = workflow.index("scripts/assistant_evaluation_identity.py")
        tag_creation = workflow.index('ensure_release_tag "$release_state"', identity)
        self.assertLess(identity, tag_creation)

        download = workflow.index("Download the exact draft or immutable public evidence")
        public_retry_verify = workflow.index(
            'validate_release_snapshot "$release_state" evidence',
            download,
        )
        azure = workflow.index("Azure login for authenticated evidence", public_retry_verify)
        self.assertLess(public_retry_verify, azure)

        upload = workflow.index('gh release upload "$EVALUATION_RELEASE"')
        immutable_recheck = workflow.index("  immutable_prepublication:\n", upload)
        exact_draft_recheck = workflow.index(
            "draft release changed immediately before publication", immutable_recheck
        )
        publish = workflow.index("gh api --method PATCH", exact_draft_recheck)
        self.assertLess(upload, immutable_recheck)
        self.assertLess(immutable_recheck, exact_draft_recheck)
        self.assertLess(exact_draft_recheck, publish)

        poll = workflow.index("for attempt in {1..12}", publish)
        final_verify = workflow.index("validate_release_snapshot public", poll)
        self.assertLess(publish, poll)
        self.assertLess(poll, final_verify)

        asset_start = workflow.index("          release_assets=(")
        asset_end = workflow.index("          )", asset_start)
        base_assets = re.findall(
            r"^\s+evidence/([A-Za-z0-9._-]+)$",
            workflow[asset_start:asset_end],
            re.MULTILINE,
        )
        bootstrap_start = workflow.index("            release_assets+=(", asset_end)
        bootstrap_end = workflow.index("            )", bootstrap_start)
        bootstrap_assets = re.findall(
            r"^\s+evidence/([A-Za-z0-9._-]+)$",
            workflow[bootstrap_start:bootstrap_end],
            re.MULTILINE,
        )
        self.assertEqual(
            [
                "assistant-eval-report.json",
                "assistant-cases-v3.json",
                "assistant-cases-v3.review.json",
                "assistant-cases-v3.review.sig",
                "assistant-browser-evidence.json",
                "assistant-eval.manifest.json",
                "assistant-eval.manifest.sig",
            ],
            base_assets,
        )
        self.assertEqual(
            [
                "bootstrap-equivalence.json",
                "bootstrap-equivalence.manifest.json",
                "bootstrap-equivalence.manifest.sig",
            ],
            bootstrap_assets,
        )

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
