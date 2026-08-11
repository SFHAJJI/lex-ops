import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "fleet-status.sh"


def find_bash() -> str | None:
    if os.name == "nt":
        git_bash = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe"
        if git_bash.exists():
            return str(git_bash)
    return shutil.which("bash")


BASH = find_bash()


def run(*args: str, cwd: Path, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout.strip()


@unittest.skipUnless(BASH and shutil.which("git"), "requires bash and git")
class FleetStatusTests(unittest.TestCase):
    def test_status_history_is_published_off_main_and_hydrated_on_the_next_run(self) -> None:
        with tempfile.TemporaryDirectory() as root_text:
            root = Path(root_text)
            remote = root / "remote.git"
            first = root / "first"
            second = root / "second"
            run("git", "init", "--bare", str(remote), cwd=root)
            run("git", "init", "-b", "main", str(first), cwd=root)
            run("git", "config", "user.name", "test", cwd=first)
            run("git", "config", "user.email", "test@example.invalid", cwd=first)
            (first / "status").mkdir()
            (first / "status" / "publisher.json").write_text("main-old\n", encoding="utf-8")
            (first / "README.md").write_text("main\n", encoding="utf-8")
            run("git", "add", ".", cwd=first)
            run("git", "commit", "-m", "initial", cwd=first)
            run("git", "remote", "add", "origin", str(remote), cwd=first)
            run("git", "push", "-u", "origin", "main", cwd=first)

            (first / "status" / "publisher.json").write_text("night-one\n", encoding="utf-8")
            run(BASH, str(SCRIPT), "publish", cwd=first)
            first_status = run("git", "rev-parse", "refs/remotes/origin/fleet-status", cwd=first)
            self.assertEqual(
                ["status/publisher.json"],
                run("git", "ls-tree", "-r", "--name-only", first_status, cwd=first).splitlines(),
            )
            self.assertEqual("main-old", run("git", "show", "origin/main:status/publisher.json", cwd=first))

            run("git", "clone", "--branch", "main", str(remote), str(second), cwd=root)
            run("git", "config", "user.name", "test", cwd=second)
            run("git", "config", "user.email", "test@example.invalid", cwd=second)
            run(BASH, str(SCRIPT), "hydrate", cwd=second)
            self.assertEqual("night-one\n", (second / "status" / "publisher.json").read_text(encoding="utf-8"))

            (second / "status" / "publisher.json").write_text("night-two\n", encoding="utf-8")
            run(BASH, str(SCRIPT), "publish", cwd=second)
            second_status = run("git", "rev-parse", "refs/remotes/origin/fleet-status", cwd=second)
            self.assertEqual(first_status, run("git", "rev-parse", f"{second_status}^", cwd=second))
            self.assertEqual("night-two", run("git", "show", f"{second_status}:status/publisher.json", cwd=second))
            self.assertEqual("main-old", run("git", "show", "origin/main:status/publisher.json", cwd=second))

    def test_prebuilt_publication_consumes_status_branch_and_rechecks_source_histories(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "publish-prebuilt-index.yml").read_text(encoding="utf-8")
        publisher = (ROOT / "publish-prebuilt-index.sh").read_text(encoding="utf-8")

        self.assertIn("refs/remotes/origin/fleet-status", workflow)
        self.assertIn("refs/remotes/origin/fleet-status", publisher)
        self.assertIn('git -C lex merge-base --is-ancestor "$BUILD_CODE_COMMIT"', publisher)
        self.assertIn('git -C corpus merge-base --is-ancestor "$CORPUS_COMMIT"', publisher)
        self.assertIn('git -C articles-ticket merge-base --is-ancestor "$ARTICLES_COMMIT"', publisher)


if __name__ == "__main__":
    unittest.main()
