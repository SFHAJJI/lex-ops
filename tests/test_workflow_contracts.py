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
        final_state = workflow.index("for attempt in {1..12}", publish_boundary)
        readback = workflow.index("validate_release_snapshot public evidence", final_state)
        final_live = workflow.index("bootstrap-routes.readback.json", publication)
        relinquish = workflow.index(
            'echo "candidate_owned=false" >> "$GITHUB_OUTPUT"', publication
        )

        self.assertLess(publication, final_live)
        self.assertLess(final_live, relinquish)
        self.assertLess(relinquish, publish_boundary)
        self.assertLess(publish_boundary, final_state)
        self.assertLess(final_state, readback)
        self.assertIn('.draft == ($state == "draft")', workflow)
        self.assertIn('.immutable == ($state == "public")', workflow)
        self.assertIn("[.assets[] | {name,digest,size,state}]", workflow)
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
        self.assertIn("candidate_owned=$candidate_owned", retry)
        self.assertNotIn("gh release", retry)
        self.assertNotIn("gh api", retry)
        self.assertNotIn("curl", retry)
        self.assertIn('echo "PUBLIC_RETRY=true" >> "$GITHUB_ENV"', workflow)

    def test_evaluation_publication_describes_project_owner_review_honestly(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("project-owner review signature: verified", workflow)
        self.assertNotIn("independent review signature: verified", workflow)
        self.assertRegex(readme, r"verifies the project-owner review\s+signature")
        self.assertNotRegex(readme, r"verifies the independent human\s+review")
        self.assertIn("Promotion independently revalidates this package", workflow)

    def test_evaluation_release_json_contract_fails_closed(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")
        start = workflow.index("# BEGIN EVALUATION_RELEASE_CONTRACT")
        end = workflow.index("# END EVALUATION_RELEASE_CONTRACT", start)
        contract = textwrap.dedent(workflow[workflow.index("\n", start) + 1 : end])
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
                setting_value={"enabled": True},
                state="public",
            ):
                release_path = directory / "release.json"
                tag_path = directory / "tag.json"
                setting_path = directory / "setting.json"
                release_path.write_text(json.dumps(release_value), encoding="utf-8")
                tag_path.write_text(json.dumps(tag_value), encoding="utf-8")
                setting_path.write_text(json.dumps(setting_value), encoding="utf-8")
                return subprocess.run(
                    [
                        bash,
                        "-c",
                        'set -euo pipefail; . "$1"; '
                        'validate_release_snapshot "$2" "$3" "$4" "$5" "$7" false; '
                        'validate_release_tag "$6"',
                        "_",
                        contract_path.as_posix(),
                        state,
                        evidence.as_posix(),
                        names_path.as_posix(),
                        release_path.as_posix(),
                        tag_path.as_posix(),
                        setting_path.as_posix(),
                    ],
                    cwd=ROOT,
                    env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            valid_public = run_release()
            self.assertEqual(0, valid_public.returncode, valid_public.stderr)
            self.assertNotEqual(0, run_release(setting_value={"enabled": False}).returncode)

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

    def test_evaluation_release_is_attested_before_azure_and_frozen_exactly(self):
        workflow = (WORKFLOWS / "publish-assistant-evaluation.yml").read_text(encoding="utf-8")

        self.assertIn("attestations: read", workflow)
        self.assertIn("WORKFLOW_COMMIT: ${{ github.sha }}", workflow)
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", workflow)
        self.assertIn('repos/$EVALUATION_REPOSITORY/immutable-releases', workflow)
        self.assertIn('gh release verify "$EVALUATION_RELEASE" --repo "$EVALUATION_REPOSITORY"', workflow)
        self.assertIn('gh release verify-asset "$EVALUATION_RELEASE"', workflow)
        self.assertIn('repos/$EVALUATION_REPOSITORY/git/ref/tags/$EVALUATION_RELEASE', workflow)
        self.assertIn('[[ "$WORKFLOW_COMMIT" =~ ^[0-9a-f]{40}$ ]]', workflow)
        self.assertIn(
            'gh release view "$EVALUATION_RELEASE" --repo "$EVALUATION_REPOSITORY"',
            workflow,
        )
        self.assertIn("--json databaseId,tagName", workflow)
        self.assertNotIn(
            'repos/$EVALUATION_REPOSITORY/releases/tags/$EVALUATION_RELEASE',
            workflow,
        )

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
        immutable_recheck = workflow.index("immutable-release-setting-prepublish.json", upload)
        exact_draft_recheck = workflow.index("validate_release_snapshot", immutable_recheck)
        publish = workflow.index('gh release edit "$EVALUATION_RELEASE"', exact_draft_recheck)
        self.assertLess(upload, immutable_recheck)
        self.assertLess(immutable_recheck, exact_draft_recheck)
        self.assertLess(exact_draft_recheck, publish)

        poll = workflow.index("for attempt in {1..12}", publish)
        final_verify = workflow.index("validate_release_snapshot public evidence", poll)
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
