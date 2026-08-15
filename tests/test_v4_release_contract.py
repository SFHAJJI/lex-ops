import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "scripts" / "v4-release-contract.sh"


def find_bash() -> str | None:
    if os.name == "nt":
        git_bash = (
            Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
            / "Git"
            / "bin"
            / "bash.exe"
        )
        if git_bash.exists():
            return str(git_bash)
    return shutil.which("bash")


BASH = find_bash()


def run_contract(*args: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, str(CONTRACT), *args],
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(BASH and shutil.which("jq"), "requires bash and jq")
class V4ReleaseContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.publisher = "eu-eurlex"
        self.repository = "SFHAJJI/lex-corpus-eu-eurlex"
        self.corpus_commit = "a" * 40
        self.ingester_commit = "b" * 40
        self.lex_commit = "c" * 40
        self.tree_id = "d" * 40
        self.articles_commit = "e" * 40
        self.configuration = self.root / "configuration.json"
        self.configuration.write_bytes(b'{"scope":"reviewed"}\n')
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "schema": "lex-corpus/4",
                    "publisher": {"id": self.publisher},
                    "ingester_code_commit": self.ingester_commit,
                    "source_configuration_kind": "engineering_scope",
                    "source_configuration_sha256": digest(
                        self.configuration.read_bytes()
                    ),
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        profiles = ["fmx4-eu/1", "xhtml-eu/1"]
        self.generation = self.root / "generation.json"
        self.generation.write_text(
            json.dumps(
                {
                    "schema": "lex-articles-generation/3",
                    "publishers": {
                        self.publisher: {
                            "collection": self.publisher,
                            "corpus_repository": "lex-corpus-eu-eurlex",
                            "corpus_commit": self.corpus_commit,
                            "corpus_manifest_sha256": digest(self.manifest.read_bytes()),
                            "ingester_code_commit": self.ingester_commit,
                            "deriver_code_commit": self.lex_commit,
                            "deriver_tree_id": self.tree_id,
                            "profiles": profiles,
                            "profiles_sha256": digest(
                                ("\n".join(profiles) + "\n").encode("utf-8")
                            ),
                        }
                    },
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def ticket_core(self) -> dict:
        generation = json.loads(self.generation.read_text(encoding="utf-8"))[
            "publishers"
        ][self.publisher]
        eu_entry = {
            "collection": self.publisher,
            "corpus_repo": self.repository,
            "corpus_commit": self.corpus_commit,
            "corpus_manifest_sha256": generation["corpus_manifest_sha256"],
            "ingester_code_commit": self.ingester_commit,
            "deriver_code_commit": self.lex_commit,
            "deriver_tree_id": self.tree_id,
            "profiles_sha256": generation["profiles_sha256"],
            "source_configuration_kind": "engineering_scope",
            "source_configuration_sha256": digest(
                self.configuration.read_bytes()
            ),
        }
        lu_entry = {
            **eu_entry,
            "collection": "lu-legilux",
            "corpus_repo": "SFHAJJI/lex-corpus-lu-legilux",
            "corpus_commit": "1" * 40,
            "source_configuration_kind": "code_only",
            "source_configuration_sha256": None,
        }
        return {
            "schema": "lex-index-build-queue/2",
            "mode": "prebuilt",
            "build_code_commit": self.lex_commit,
            "articles_commit": self.articles_commit,
            "articles_generation_sha256": digest(self.generation.read_bytes()),
            "entries": [eu_entry, lu_entry],
        }

    def seal(self, generated_at: str, name: str = "ticket.json") -> Path:
        core = self.root / "core.json"
        core.write_text(json.dumps(self.ticket_core()), encoding="utf-8")
        ticket = self.root / name
        result = run_contract(
            "seal-ticket", core.name, ticket.name, generated_at, cwd=self.root
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return ticket

    def test_ticket_identity_is_stable_and_tampering_fails_closed(self) -> None:
        first = self.seal("2026-08-14T10:00:00Z", "first.json")
        second = self.seal("2026-08-14T11:00:00Z", "second.json")
        first_json = json.loads(first.read_text(encoding="utf-8"))
        second_json = json.loads(second.read_text(encoding="utf-8"))
        self.assertEqual(first_json["ticket_id"], second_json["ticket_id"])
        self.assertNotEqual(first_json["generated_at"], second_json["generated_at"])
        self.assertEqual(
            0,
            run_contract("validate-ticket", first.name, cwd=self.root).returncode,
        )

        first_json["articles_commit"] = "f" * 40
        first.write_text(json.dumps(first_json), encoding="utf-8")
        rejected = run_contract("validate-ticket", first.name, cwd=self.root)
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("ticket_id", rejected.stderr)

    def test_queue_v1_is_rejected_even_when_its_commits_are_well_formed(self) -> None:
        legacy = self.ticket_core()
        legacy["schema"] = "lex-index-build-queue/1"
        path = self.root / "legacy.json"
        path.write_text(json.dumps(legacy), encoding="utf-8")
        result = run_contract("validate-ticket", path.name, cwd=self.root)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("lex-index-build-queue/2", result.stderr)

    def test_ticket_source_contract_binds_generation_manifest_and_source_scope(self) -> None:
        ticket = self.seal("2026-08-14T10:00:00Z")
        args = (
            "validate-source",
            ticket.name,
            self.publisher,
            self.repository,
            self.corpus_commit,
            self.lex_commit,
            self.articles_commit,
            self.manifest.name,
            self.generation.name,
            self.configuration.name,
        )
        accepted = run_contract(*args, cwd=self.root)
        self.assertEqual(0, accepted.returncode, accepted.stderr)

        generation = json.loads(self.generation.read_text(encoding="utf-8"))
        generation["publishers"][self.publisher]["corpus_commit"] = "9" * 40
        self.generation.write_text(json.dumps(generation), encoding="utf-8")
        rejected = run_contract(*args, cwd=self.root)
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("generation", rejected.stderr)

    def test_corpus_manifest_exposes_its_ingester_without_relabeling_it(self) -> None:
        accepted = run_contract(
            "validate-corpus-manifest",
            self.publisher,
            self.manifest.name,
            self.configuration.name,
            "-",
            cwd=self.root,
        )
        self.assertEqual(0, accepted.returncode, accepted.stderr)
        self.assertEqual(self.ingester_commit, accepted.stdout.strip())

        exact = run_contract(
            "validate-corpus-manifest",
            self.publisher,
            self.manifest.name,
            self.configuration.name,
            self.ingester_commit,
            cwd=self.root,
        )
        self.assertEqual(0, exact.returncode, exact.stderr)

        rejected = run_contract(
            "validate-corpus-manifest",
            self.publisher,
            self.manifest.name,
            self.configuration.name,
            self.lex_commit,
            cwd=self.root,
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("another Lex commit", rejected.stderr)

    def test_corpus_resume_is_executable_ancestor_and_scope_policy(self) -> None:
        repository = self.root / "lex"
        repository.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@example.invalid"],
            cwd=repository,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "test"], cwd=repository, check=True
        )
        subprocess.run(
            ["git", "config", "core.autocrlf", "false"],
            cwd=repository,
            check=True,
        )
        scope = repository / "src" / "Lex.Sources.EurLex" / "eu-scope.json"
        scope.parent.mkdir(parents=True)
        old_scope = b'{"scope":"old"}\n'
        new_scope = b'{"scope":"new"}\n'
        scope.write_bytes(old_scope)
        subprocess.run(["git", "add", "."], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "old"], cwd=repository, check=True)
        old_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True
        ).strip()

        (repository / "README").write_text("same scope\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "same"], cwd=repository, check=True)
        same_scope_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True
        ).strip()

        scope.write_bytes(new_scope)
        subprocess.run(["git", "add", "."], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "new"], cwd=repository, check=True)
        changed_scope_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True
        ).strip()
        main_branch = subprocess.check_output(
            ["git", "branch", "--show-current"], cwd=repository, text=True
        ).strip()

        subprocess.run(
            ["git", "checkout", "-q", "--orphan", "divergent"],
            cwd=repository,
            check=True,
        )
        subprocess.run(["git", "rm", "-q", "-rf", "."], cwd=repository, check=True)
        scope.parent.mkdir(parents=True, exist_ok=True)
        scope.write_bytes(old_scope)
        subprocess.run(["git", "add", "."], cwd=repository, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "divergent"], cwd=repository, check=True
        )
        divergent_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True
        ).strip()
        subprocess.run(
            ["git", "checkout", "-q", main_branch], cwd=repository, check=True
        )

        current_old_scope = self.root / "old-scope.json"
        current_old_scope.write_bytes(old_scope)
        current_new_scope = self.root / "new-scope.json"
        current_new_scope.write_bytes(new_scope)

        def write_eu_manifest(ingester: str) -> None:
            self.manifest.write_text(
                json.dumps(
                    {
                        "schema": "lex-corpus/4",
                        "publisher": {"id": self.publisher},
                        "ingester_code_commit": ingester,
                        "source_configuration_kind": "engineering_scope",
                        "source_configuration_sha256": digest(old_scope),
                    },
                    separators=(",", ":"),
                )
                + "\n",
                encoding="utf-8",
            )

        write_eu_manifest(old_commit)
        exact = run_contract(
            "classify-corpus-resume",
            self.publisher,
            self.manifest.name,
            current_old_scope.name,
            str(repository),
            old_commit,
            cwd=self.root,
        )
        self.assertEqual(0, exact.returncode, exact.stderr)
        self.assertEqual(f"reuse {old_commit}", exact.stdout.strip())

        ancestor = run_contract(
            "classify-corpus-resume",
            self.publisher,
            self.manifest.name,
            current_old_scope.name,
            str(repository),
            same_scope_commit,
            cwd=self.root,
        )
        self.assertEqual(0, ancestor.returncode, ancestor.stderr)
        self.assertEqual(f"reuse {old_commit}", ancestor.stdout.strip())

        changed = run_contract(
            "classify-corpus-resume",
            self.publisher,
            self.manifest.name,
            current_new_scope.name,
            str(repository),
            changed_scope_commit,
            cwd=self.root,
        )
        self.assertEqual(0, changed.returncode, changed.stderr)
        self.assertEqual(f"rebuild {old_commit}", changed.stdout.strip())

        write_eu_manifest(divergent_commit)
        divergent = run_contract(
            "classify-corpus-resume",
            self.publisher,
            self.manifest.name,
            current_new_scope.name,
            str(repository),
            changed_scope_commit,
            cwd=self.root,
        )
        self.assertNotEqual(0, divergent.returncode)
        self.assertIn("protected Lex ancestor", divergent.stderr)

        self.manifest.write_text(
            json.dumps(
                {
                    "schema": "lex-corpus/4",
                    "publisher": {"id": "lu-legilux"},
                    "ingester_code_commit": old_commit,
                    "source_configuration_kind": "code_only",
                    "source_configuration_sha256": None,
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        lu = run_contract(
            "classify-corpus-resume",
            "lu-legilux",
            self.manifest.name,
            "-",
            str(repository),
            changed_scope_commit,
            cwd=self.root,
        )
        self.assertEqual(0, lu.returncode, lu.stderr)
        self.assertEqual(f"reuse {old_commit}", lu.stdout.strip())

    def test_legacy_articles_generation_is_explicitly_reinitialized_for_v3(self) -> None:
        repository = self.root / "articles"
        repository.mkdir()
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        generation = repository / "generation.json"
        generation.write_text(
            json.dumps(
                {
                    "schema": "lex-articles-generation/1",
                    "deriver_fingerprint": "legacy",
                    "corpus_commits": {"lu-legilux": "a" * 40},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        subprocess.run(
            ["git", "-C", str(repository), "add", "generation.json"], check=True
        )

        migrated = run_contract(
            "prepare-articles-generation", str(repository), cwd=self.root
        )
        self.assertEqual(0, migrated.returncode, migrated.stderr)
        self.assertEqual("legacy", migrated.stdout.strip())
        self.assertFalse(generation.exists())

        # The first derivation may create a partial generation/3 locally. The helper must
        # preserve it so the second publisher can be added, while the outer workflow refuses
        # publication until both exact entries are present.
        partial = {
            "schema": "lex-articles-generation/3",
            "publishers": {"lu-legilux": {"collection": "lu-legilux"}},
        }
        generation.write_text(json.dumps(partial) + "\n", encoding="utf-8")
        before = generation.read_bytes()
        current = run_contract(
            "prepare-articles-generation", str(repository), cwd=self.root
        )
        self.assertEqual(0, current.returncode, current.stderr)
        self.assertEqual("current", current.stdout.strip())
        self.assertEqual(before, generation.read_bytes())

        generation.write_text(
            '{"schema":"lex-articles-generation/99"}\n', encoding="utf-8"
        )
        rejected = run_contract(
            "prepare-articles-generation", str(repository), cwd=self.root
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("unknown schema", rejected.stderr)
        self.assertTrue(generation.exists())

    def test_retry_after_articles_push_reuses_the_exact_tree(self) -> None:
        repository = self.root / "articles"
        repository.mkdir()
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "config", "user.name", "test"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repository), "config", "user.email", "test@example.test"],
            check=True,
        )
        generation = repository / "generation.json"
        generation.write_text("{}\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repository), "add", "generation.json"], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "published"], check=True
        )

        reuse = run_contract(
            "classify-articles-tree", str(repository), cwd=self.root
        )
        self.assertEqual(0, reuse.returncode, reuse.stderr)
        self.assertEqual("reuse", reuse.stdout.strip())

        generation.write_text('{"schema":"next"}\n', encoding="utf-8")
        subprocess.run(["git", "-C", str(repository), "add", "generation.json"], check=True)
        publish = run_contract(
            "classify-articles-tree", str(repository), cwd=self.root
        )
        self.assertEqual(0, publish.returncode, publish.stderr)
        self.assertEqual("publish", publish.stdout.strip())

        (repository / "unexpected.txt").write_text("no", encoding="utf-8")
        rejected = run_contract(
            "classify-articles-tree", str(repository), cwd=self.root
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("untracked", rejected.stderr)

    def test_retry_reuses_same_ticket_and_refuses_a_newer_ticket(self) -> None:
        candidate = self.seal("2026-08-14T10:00:00Z", "candidate.json")
        same = self.seal("2026-08-14T11:00:00Z", "same.json")
        reuse = run_contract(
            "classify-ticket", same.name, candidate.name, cwd=self.root
        )
        self.assertEqual(0, reuse.returncode, reuse.stderr)
        self.assertEqual("reuse", reuse.stdout.strip())

        different_core = self.ticket_core()
        different_core["articles_commit"] = "9" * 40
        core = self.root / "different-core.json"
        core.write_text(json.dumps(different_core), encoding="utf-8")
        different = self.root / "different.json"
        sealed = run_contract(
            "seal-ticket",
            core.name,
            different.name,
            "2026-08-14T12:00:00Z",
            cwd=self.root,
        )
        self.assertEqual(0, sealed.returncode, sealed.stderr)
        rejected = run_contract(
            "classify-migration-ticket", different.name, candidate.name, cwd=self.root
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("superseded", rejected.stderr)

        routine = run_contract(
            "classify-ticket", different.name, candidate.name, cwd=self.root
        )
        self.assertEqual(0, routine.returncode, routine.stderr)
        self.assertEqual("publish", routine.stdout.strip())

    def test_append_only_source_policy_is_executable(self) -> None:
        accepted = self.root / "accepted.json"
        accepted.write_text(
            json.dumps(
                {
                    "enforce_admins": {"enabled": True},
                    "required_linear_history": {"enabled": True},
                    "allow_force_pushes": {"enabled": False},
                    "allow_deletions": {"enabled": False},
                    "required_pull_request_reviews": None,
                }
            ),
            encoding="utf-8",
        )
        self.assertEqual(
            0,
            run_contract(
                "validate-append-only-protection", accepted.name, cwd=self.root
            ).returncode,
        )
        rejected_json = json.loads(accepted.read_text(encoding="utf-8"))
        rejected_json["allow_force_pushes"]["enabled"] = True
        accepted.write_text(json.dumps(rejected_json), encoding="utf-8")
        rejected = run_contract(
            "validate-append-only-protection", accepted.name, cwd=self.root
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("append-only", rejected.stderr)

    def test_code_policy_requires_reviewed_pull_requests(self) -> None:
        policy = self.root / "code-policy.json"
        value = {
            "enforce_admins": {"enabled": True},
            "required_linear_history": {"enabled": True},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": False},
            "required_pull_request_reviews": {"required_approving_review_count": 1},
        }
        policy.write_text(json.dumps(value), encoding="utf-8")
        accepted = run_contract(
            "validate-protected-code", policy.name, cwd=self.root
        )
        self.assertEqual(0, accepted.returncode, accepted.stderr)

        value["required_pull_request_reviews"] = None
        policy.write_text(json.dumps(value), encoding="utf-8")
        rejected = run_contract(
            "validate-protected-code", policy.name, cwd=self.root
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("reviewed pull requests", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
