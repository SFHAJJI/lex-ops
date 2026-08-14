from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts" / "fresh-corpus-v4.sh").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "fresh-corpus-v4.yml").read_text(
    encoding="utf-8"
)
FLEET = (ROOT / "fleet.sh").read_text(encoding="utf-8")
PREBUILT = (ROOT / "publish-prebuilt-index.sh").read_text(encoding="utf-8")
RELEASE_CONTRACT = (ROOT / "scripts" / "v4-release-contract.sh").read_text(
    encoding="utf-8"
)


class FreshCorpusV4ContractTests(unittest.TestCase):
    def test_publishers_acquire_in_parallel_but_share_the_nightly_lock(self):
        self.assertIn("group: nightly-fleet", WORKFLOW)
        self.assertIn("max-parallel: 2", WORKFLOW)
        self.assertRegex(WORKFLOW, r"publisher: \[lu-legilux, eu-eurlex\]")
        self.assertIn("needs: corpus", WORKFLOW)

    def test_the_workflow_requires_one_exact_main_commit_and_confirmation(self):
        self.assertIn("REBUILD_LEX_CORPUS_V4_ONCE", WORKFLOW)
        self.assertIn("environment: corpus-v4-migration", WORKFLOW)
        self.assertIn("refs/heads/main", WORKFLOW)
        self.assertIn("grep -Fx \"$LEX_COMMIT\"", WORKFLOW)
        self.assertIn("merge-base --is-ancestor", SCRIPT)
        self.assertIn("validate-append-only-protection", WORKFLOW)

    def test_corpus_publication_is_complete_scoped_and_fast_forward_only(self):
        self.assertIn("ingest --fresh", SCRIPT)
        self.assertIn("verify corpus", SCRIPT)
        self.assertIn("git -C \"$directory\" add -- NOTICE manifest.json works", SCRIPT)
        self.assertIn("require_remote_unchanged \"$repo\" \"$baseline\"", SCRIPT)
        self.assertNotIn("git add -A", SCRIPT)
        self.assertNotIn("--force", SCRIPT)

    def test_a_partial_matrix_success_resumes_without_a_second_publisher_poll(self):
        self.assertIn('= "lex-corpus/4"', SCRIPT)
        self.assertIn("corpus manifest was materialized by another Lex commit", RELEASE_CONTRACT)
        self.assertIn("already committed and verified", SCRIPT)
        self.assertLess(SCRIPT.index('= "lex-corpus/4"'), SCRIPT.index("ingest --fresh"))

    def test_derivation_is_retryable_and_only_a_bounded_spot_check_repeats(self):
        self.assertEqual(1, SCRIPT.count('"${lex_cli[@]}" derive --publisher'))
        self.assertIn("--work \"$representative\"", SCRIPT)
        self.assertIn("lex-articles-generation/3", SCRIPT)
        self.assertIn("already matches the exact v4 derivation inputs", SCRIPT)
        self.assertIn("using already-published exact articles", SCRIPT)

    def test_ticket_binds_every_exact_commit_for_the_local_indexer(self):
        for field in (
            "build_code_commit:$code",
            "articles_commit:$articles",
            "corpus_commit:$corpus",
            "lex-index-build-queue/2",
            "ticket_id",
        ):
            self.assertIn(field, SCRIPT)
        self.assertIn("fleet-status.sh publish", SCRIPT)
        self.assertIn("reusing exact build ticket", SCRIPT)

    def test_prebuilt_publication_never_creates_a_candidate(self):
        self.assertNotIn("DEPLOY_AFTER_PUBLISH", PREBUILT)
        self.assertNotIn("repos/SFHAJJI/lex/dispatches", PREBUILT)

    def test_routine_and_prebuilt_publication_verify_complete_v4_provenance(self):
        required = (
            "--corpus-manifest",
            "--articles-generation",
            "--expected-corpus-commit",
            "--expected-code-commit",
            "--expected-articles-commit",
        )
        for contract in (FLEET, PREBUILT):
            for argument in required:
                self.assertIn(argument, contract)
        self.assertIn('lex-articles-generation/3', FLEET)
        self.assertNotIn("--reviewed-configuration", FLEET + PREBUILT)
        self.assertNotIn("--work-enrichment", FLEET + PREBUILT)
        self.assertIn("source_configuration_kind", FLEET)


if __name__ == "__main__":
    unittest.main()
