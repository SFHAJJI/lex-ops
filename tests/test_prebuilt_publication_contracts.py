from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


class PrebuiltPublicationContractTests(unittest.TestCase):
    def test_deletes_only_unchanged_staging_inputs_after_release(self):
        script = (ROOT / "publish-prebuilt-index.sh").read_text(encoding="utf-8")
        workflow = (WORKFLOWS / "publish-prebuilt-index.yml").read_text(encoding="utf-8")
        verification = script.index("=== verify immutable Blob release ===")
        pointer = script.rindex('publish_pointer "$manifest_id"')
        cleanup = script.index("=== remove verified private staging inputs ===")
        github_release = script.index("=== publish public GitHub release ===")
        github_verification = script.index("=== verify public GitHub release ===")
        draft_readback = script.index('gh release download "$tag"')
        public_boundary = script.index('gh release edit "$tag"')

        self.assertLess(verification, cleanup)
        self.assertLess(github_release, cleanup)
        self.assertLess(github_release, github_verification)
        self.assertLess(github_verification, cleanup)
        self.assertLess(github_verification, pointer)
        self.assertLess(pointer, cleanup)
        self.assertLess(draft_readback, public_boundary)
        self.assertIn('gh release view "$tag" --repo "$repo"', script)
        self.assertIn("isDraft,isPrerelease,tagName", script)
        self.assertIn('gh release download "$tag"', script)
        self.assertIn("https://github.com/$repo/releases/download/$tag/$asset_name", script)
        self.assertIn('sha256sum "$downloaded"', script)
        self.assertIn('wc -c < "$downloaded"', script)
        self.assertIn('cleanup_exact_blob "$STAGING_PREFIX/$index" "$index_etag"', script)
        self.assertIn('cleanup_exact_blob "$STAGING_PREFIX/$vectors" "$vectors_etag"', script)
        self.assertIn('--name "$name" --if-match "$expected_etag"', script)
        self.assertIn('tag="index-$PUBLISHER-$QUEUE_COMMIT"', script)
        self.assertIn('schema:"lex-staging-cleanup-receipt/1"', script)
        self.assertIn("previous_pointer:{exists:$previous_exists", script)
        self.assertIn('condition=(--if-match "$expected_etag")', script)
        self.assertIn("condition=(--if-none-match '*')", script)
        self.assertIn("refusing to replace a changed current artifact pointer", script)
        self.assertIn("artifact verify", script)
        self.assertIn("verify_blob_asset", script)
        self.assertIn(". lex/scripts/deploy/az-retry.sh", script)
        self.assertIn(". lex/scripts/deploy/az-reauth.sh", script)
        azure_calls = re.findall(r"(?m)^\s*(?:[a-z_]+\s*=\s*\$\()?az\s+", script)
        self.assertEqual([], azure_calls)
        self.assertNotIn("DEPLOY_AFTER_PUBLISH", script)
        self.assertNotIn("DEPLOY_AFTER_PUBLISH", workflow)
        self.assertNotIn("repos/SFHAJJI/lex/dispatches", script)
        cleanup_block = script[cleanup:]
        self.assertNotIn("delete-batch", cleanup_block)
        self.assertNotIn("releases/", cleanup_block)
        self.assertNotIn("rm -rf", script)
        self.assertIn('case "$public_release_dir" in', script)

    def test_public_release_retry_is_verify_only_before_reconciliation(self):
        script = (ROOT / "publish-prebuilt-index.sh").read_text(encoding="utf-8")
        retry_start = script.index("if public_state=$(gh release view")
        retry_end = script.index('echo "=== snapshot current artifact pointer ==="')
        retry = script[retry_start:retry_end]

        receipt_verify = retry.index("artifact verify")
        public_verify = retry.index("public release retry read-back differs")
        blob_verify = retry.index("verify_blob_asset")
        pointer = retry.index("publish_pointer")
        cleanup = retry.index("cleanup_exact_blob")
        self.assertLess(receipt_verify, public_verify)
        self.assertLess(public_verify, blob_verify)
        self.assertLess(blob_verify, pointer)
        self.assertLess(pointer, cleanup)
        self.assertNotIn("gh release upload", retry)
        self.assertNotIn("gh release edit", retry)
        self.assertNotIn("gh release create", retry)
        self.assertIn("signed staging cleanup retry receipt is invalid", retry)


if __name__ == "__main__":
    unittest.main()
