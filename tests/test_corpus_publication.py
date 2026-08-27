import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "publish-corpus-tree.sh"
FLEET = (ROOT / "fleet.sh").read_text(encoding="utf-8")


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


def run(*args: str, cwd: Path) -> str:
    completed = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout.strip()


def run_result(*args: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


@unittest.skipUnless(BASH and shutil.which("git"), "requires bash and git")
class CorpusPublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.work = self.root / "work"

        run("git", "init", "--bare", "--initial-branch=main", str(self.remote), cwd=self.root)
        run("git", "init", "--initial-branch=main", str(self.seed), cwd=self.root)
        run("git", "config", "user.name", "test", cwd=self.seed)
        run("git", "config", "user.email", "test@example.invalid", cwd=self.seed)
        run("git", "config", "commit.gpgsign", "false", cwd=self.seed)
        (self.seed / "works").mkdir()
        (self.seed / "works" / "record.txt").write_text("base\n", encoding="utf-8")
        (self.seed / "manifest.json").write_text("{}\n", encoding="utf-8")
        (self.seed / "NOTICE").write_text("notice\n", encoding="utf-8")
        (self.seed / "README.md").write_text("readme\n", encoding="utf-8")
        (self.seed / "outside.txt").write_text("outside\n", encoding="utf-8")
        run(
            "git", "add", "--", "works", "manifest.json", "NOTICE", "README.md",
            "outside.txt", cwd=self.seed,
        )
        run("git", "commit", "-m", "initial", cwd=self.seed)
        run("git", "remote", "add", "origin", str(self.remote), cwd=self.seed)
        run("git", "push", "-u", "origin", "main", cwd=self.seed)
        run("git", "clone", str(self.remote), str(self.work), cwd=self.root)
        run("git", "config", "commit.gpgsign", "false", cwd=self.work)
        self.baseline = run("git", "rev-parse", "HEAD", cwd=self.work)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def publish(self) -> subprocess.CompletedProcess[str]:
        return run_result(
            BASH,
            str(SCRIPT),
            str(self.work),
            "2026-08-28T00:00:00Z",
            cwd=self.root,
        )

    def remote_head(self) -> str:
        return run(
            "git", "--git-dir", str(self.remote), "rev-parse", "refs/heads/main", cwd=self.root
        )

    def run_fleet_publication_block(
        self, helper_outcome: str, helper_returncode: int
    ) -> subprocess.CompletedProcess[str]:
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        helper = scripts / "publish-corpus-tree.sh"
        helper.write_text(
            f"#!/usr/bin/env bash\nprintf '%s\\n' '{helper_outcome}'\n"
            f"exit {helper_returncode}\n",
            encoding="utf-8",
            newline="\n",
        )
        start = FLEET.index(
            '        publication_outcome=$(bash scripts/publish-corpus-tree.sh'
        )
        end = FLEET.index("      fi\n\n      # Index rebuild happens AFTER", start)
        block = textwrap.dedent(FLEET[start:end])
        shell = (
            "set -uo pipefail\n"
            "dir=corpus-test\n"
            "STAMP=2026-08-28T00:00:00Z\n"
            "outcome=failed\n"
            "overall_rc=0\n"
            f"{block}"
            "printf '%s\\t%s\\n' \"$outcome\" \"$overall_rc\"\n"
        )
        return run_result(BASH, "-c", shell, cwd=self.root)

    @staticmethod
    def install_hook(repository: Path, name: str, body: str) -> None:
        hook_root = (
            repository / "hooks"
            if repository.name.endswith(".git")
            else repository / ".git" / "hooks"
        )
        hook = hook_root / name
        hook.write_bytes(f"#!/bin/sh\n{body}\n".encode("utf-8"))
        hook.chmod(0o755)

    def test_unscoped_dirty_file_is_a_typed_no_change_without_a_commit(self) -> None:
        (self.work / "outside.txt").write_text("local only\n", encoding="utf-8")

        result = self.publish()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("ran_no_change", result.stdout.strip())
        self.assertEqual(self.baseline, run("git", "rev-parse", "HEAD", cwd=self.work))
        self.assertEqual(self.baseline, self.remote_head())
        self.assertEqual("", run("git", "diff", "--cached", "--name-only", cwd=self.work))

    def test_pre_staged_unscoped_file_fails_closed_without_a_commit(self) -> None:
        (self.work / "outside.txt").write_text("must not publish\n", encoding="utf-8")
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")
        run("git", "add", "--", "outside.txt", cwd=self.work)

        result = self.publish()

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("failed_scope", result.stdout.strip())
        self.assertEqual(self.baseline, run("git", "rev-parse", "HEAD", cwd=self.work))
        self.assertEqual(self.baseline, self.remote_head())
        self.assertEqual(
            {"manifest.json", "outside.txt"},
            set(run("git", "diff", "--cached", "--name-only", cwd=self.work).splitlines()),
        )

    def test_scoped_change_commits_pushes_and_reads_back_the_remote_head(self) -> None:
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")

        result = self.publish()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("ran_committed", result.stdout.strip())
        committed = run("git", "rev-parse", "HEAD", cwd=self.work)
        self.assertNotEqual(self.baseline, committed)
        self.assertEqual(committed, self.remote_head())

    def test_a_tag_named_main_cannot_redirect_the_branch_publication(self) -> None:
        run("git", "tag", "main", cwd=self.work)
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")

        result = self.publish()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("ran_committed", result.stdout.strip())
        self.assertEqual(run("git", "rev-parse", "HEAD", cwd=self.work), self.remote_head())
        redirected = run_result(
            "git", "--git-dir", str(self.remote), "rev-parse", "refs/heads/heads/main",
            cwd=self.root,
        )
        self.assertNotEqual(0, redirected.returncode)

    def test_publication_rejects_every_attached_branch_except_main(self) -> None:
        run("git", "switch", "-c", "alternate/test", cwd=self.work)
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")

        result = self.publish()

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("failed_branch", result.stdout.strip())
        self.assertEqual(self.baseline, self.remote_head())
        alternate = run_result(
            "git", "--git-dir", str(self.remote), "rev-parse", "refs/heads/alternate/test",
            cwd=self.root,
        )
        self.assertNotEqual(0, alternate.returncode)

    def test_commit_failure_is_typed_and_nonzero(self) -> None:
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")
        self.install_hook(self.work, "pre-commit", "exit 23")

        result = self.publish()

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("failed_commit", result.stdout.strip())
        self.assertEqual(self.baseline, run("git", "rev-parse", "HEAD", cwd=self.work))
        self.assertEqual(self.baseline, self.remote_head())

    def test_push_failure_is_typed_and_nonzero(self) -> None:
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")
        self.install_hook(self.remote, "pre-receive", "exit 24")

        result = self.publish()

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("failed_push", result.stdout.strip())
        self.assertNotEqual(self.baseline, run("git", "rev-parse", "HEAD", cwd=self.work))
        self.assertEqual(self.baseline, self.remote_head())

    def test_remote_readback_mismatch_is_typed_and_nonzero(self) -> None:
        (self.work / "manifest.json").write_text('{"changed":true}\n', encoding="utf-8")
        self.install_hook(
            self.remote,
            "post-receive",
            f"git update-ref refs/heads/main {self.baseline}",
        )

        result = self.publish()

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("failed_readback", result.stdout.strip())
        self.assertNotEqual(self.baseline, run("git", "rev-parse", "HEAD", cwd=self.work))
        self.assertEqual(self.baseline, self.remote_head())

    def test_fleet_uses_the_typed_corpus_publication_boundary(self) -> None:
        self.assertIn("bash scripts/publish-corpus-tree.sh", FLEET)
        self.assertIn("git clone --depth 50 --branch main --single-branch", FLEET)
        self.assertNotIn(
            'git -C "$dir" commit -m "nightly ingest $STAMP" && git -C "$dir" push',
            FLEET,
        )

    def test_fleet_propagates_publication_failure_and_preserves_no_change(self) -> None:
        failure = self.run_fleet_publication_block("failed_push", 1)
        no_change = self.run_fleet_publication_block("ran_no_change", 0)

        self.assertEqual(0, failure.returncode, failure.stderr)
        self.assertEqual("failed_push\t1", failure.stdout.strip())
        self.assertEqual(0, no_change.returncode, no_change.stderr)
        self.assertEqual("ran_no_change\t0", no_change.stdout.strip())


if __name__ == "__main__":
    unittest.main()
