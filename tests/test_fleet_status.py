import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "fleet-status.sh"
HISTORY_GATE = ROOT / "require-ancestor.sh"


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


def run_result(*args: str, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


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
            (first / "status" / "publisher.json").write_text('{"run":"main-old"}\n', encoding="utf-8")
            (first / "status" / "obsolete.json").write_text('{"old":true}\n', encoding="utf-8")
            (first / "README.md").write_text("main\n", encoding="utf-8")
            run("git", "add", ".", cwd=first)
            run("git", "commit", "-m", "initial", cwd=first)
            run("git", "remote", "add", "origin", str(remote), cwd=first)
            run("git", "push", "-u", "origin", "main", cwd=first)

            run(BASH, str(SCRIPT), "hydrate", cwd=first)
            (first / "status" / "publisher.json").write_text('{"run":"night-one"}\n', encoding="utf-8")
            (first / "status" / "obsolete.json").unlink()
            run(BASH, str(SCRIPT), "publish", cwd=first)
            first_status = run("git", "rev-parse", "refs/remotes/origin/fleet-status", cwd=first)
            self.assertEqual(
                ["status/publisher.json"],
                run("git", "ls-tree", "-r", "--name-only", first_status, cwd=first).splitlines(),
            )
            self.assertEqual('{"run":"main-old"}', run("git", "show", "origin/main:status/publisher.json", cwd=first))

            run("git", "clone", "--branch", "main", str(remote), str(second), cwd=root)
            run("git", "config", "user.name", "test", cwd=second)
            run("git", "config", "user.email", "test@example.invalid", cwd=second)
            run(BASH, str(SCRIPT), "hydrate", cwd=second)
            self.assertEqual(
                '{"run":"night-one"}\n',
                (second / "status" / "publisher.json").read_text(encoding="utf-8"),
            )
            self.assertFalse((second / "status" / "obsolete.json").exists())

            (second / "status" / "publisher.json").write_text('{"run":"night-two"}\n', encoding="utf-8")
            run(BASH, str(SCRIPT), "publish", cwd=second)
            second_status = run("git", "rev-parse", "refs/remotes/origin/fleet-status", cwd=second)
            self.assertEqual(first_status, run("git", "rev-parse", f"{second_status}^", cwd=second))
            self.assertEqual(
                '{"run":"night-two"}',
                run("git", "show", f"{second_status}:status/publisher.json", cwd=second),
            )
            self.assertEqual('{"run":"main-old"}', run("git", "show", "origin/main:status/publisher.json", cwd=second))

    def test_hydration_fails_closed_when_the_remote_cannot_be_read(self) -> None:
        with tempfile.TemporaryDirectory() as root_text:
            root = Path(root_text)
            run("git", "init", "-b", "main", cwd=root)
            (root / "status").mkdir()
            (root / "status" / "publisher.json").write_text('{"run":"local"}\n', encoding="utf-8")
            env = os.environ.copy()
            env["FLEET_STATUS_REMOTE"] = "missing-remote"

            result = run_result(BASH, str(SCRIPT), "hydrate", cwd=root, env=env)

            self.assertNotEqual(0, result.returncode)
            self.assertEqual('{"run":"local"}\n', (root / "status" / "publisher.json").read_text(encoding="utf-8"))

    def test_a_stale_writer_cannot_replace_a_newer_status_commit(self) -> None:
        with tempfile.TemporaryDirectory() as root_text:
            root = Path(root_text)
            remote = root / "remote.git"
            seed = root / "seed"
            first = root / "first"
            stale = root / "stale"
            run("git", "init", "--bare", str(remote), cwd=root)
            run("git", "init", "-b", "main", str(seed), cwd=root)
            run("git", "config", "user.name", "test", cwd=seed)
            run("git", "config", "user.email", "test@example.invalid", cwd=seed)
            (seed / "status").mkdir()
            (seed / "status" / "publisher.json").write_text('{"run":"base"}\n', encoding="utf-8")
            run("git", "add", ".", cwd=seed)
            run("git", "commit", "-m", "initial", cwd=seed)
            run("git", "remote", "add", "origin", str(remote), cwd=seed)
            run("git", "push", "-u", "origin", "main", cwd=seed)
            run(BASH, str(SCRIPT), "hydrate", cwd=seed)
            run(BASH, str(SCRIPT), "publish", cwd=seed)

            for checkout in (first, stale):
                run("git", "clone", "--branch", "main", str(remote), str(checkout), cwd=root)
                run("git", "config", "user.name", "test", cwd=checkout)
                run("git", "config", "user.email", "test@example.invalid", cwd=checkout)
                run(BASH, str(SCRIPT), "hydrate", cwd=checkout)

            (first / "status" / "publisher.json").write_text('{"run":"newer"}\n', encoding="utf-8")
            run(BASH, str(SCRIPT), "publish", cwd=first)
            (stale / "status" / "other.json").write_text('{"run":"stale"}\n', encoding="utf-8")

            rejected = run_result(BASH, str(SCRIPT), "publish", cwd=stale)

            self.assertNotEqual(0, rejected.returncode)
            run("git", "fetch", "origin", "fleet-status", cwd=stale)
            self.assertEqual(
                '{"run":"newer"}',
                run("git", "show", "origin/fleet-status:status/publisher.json", cwd=stale),
            )
            self.assertNotEqual(
                0,
                run_result("git", "cat-file", "-e", "origin/fleet-status:status/other.json", cwd=stale).returncode,
            )

    def test_hydration_rejects_a_non_regular_status_entry(self) -> None:
        with tempfile.TemporaryDirectory() as root_text:
            root = Path(root_text)
            remote = root / "remote.git"
            seed = root / "seed"
            victim = root / "victim"
            run("git", "init", "--bare", str(remote), cwd=root)
            run("git", "init", "-b", "main", str(seed), cwd=root)
            run("git", "config", "user.name", "test", cwd=seed)
            run("git", "config", "user.email", "test@example.invalid", cwd=seed)
            (seed / "status").mkdir()
            (seed / "status" / "publisher.json").write_text('{"run":"base"}\n', encoding="utf-8")
            run("git", "add", ".", cwd=seed)
            run("git", "commit", "-m", "initial", cwd=seed)
            run("git", "remote", "add", "origin", str(remote), cwd=seed)
            run("git", "push", "-u", "origin", "main", cwd=seed)
            run(BASH, str(SCRIPT), "hydrate", cwd=seed)
            run(BASH, str(SCRIPT), "publish", cwd=seed)
            blob = subprocess.run(
                ("git", "hash-object", "-w", "--stdin"),
                cwd=seed,
                input="../README.md\n",
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            run("git", "switch", "--detach", "origin/fleet-status", cwd=seed)
            run("git", "update-index", "--add", "--cacheinfo", f"120000,{blob},status/escape.json", cwd=seed)
            run("git", "commit", "-m", "malicious status mode", cwd=seed)
            run("git", "push", "origin", "HEAD:fleet-status", cwd=seed)

            run("git", "clone", "--branch", "main", str(remote), str(victim), cwd=root)
            rejected = run_result(BASH, str(SCRIPT), "hydrate", cwd=victim)

            self.assertNotEqual(0, rejected.returncode)
            self.assertFalse((victim / "status" / "escape.json").exists())

    def test_history_gate_rejects_a_commit_outside_the_named_history(self) -> None:
        with tempfile.TemporaryDirectory() as root_text:
            root = Path(root_text)
            run("git", "init", "-b", "main", cwd=root)
            run("git", "config", "user.name", "test", cwd=root)
            run("git", "config", "user.email", "test@example.invalid", cwd=root)
            (root / "value.txt").write_text("main\n", encoding="utf-8")
            run("git", "add", ".", cwd=root)
            run("git", "commit", "-m", "main", cwd=root)
            main_commit = run("git", "rev-parse", "HEAD", cwd=root)
            run("git", "switch", "-c", "untrusted", cwd=root)
            (root / "value.txt").write_text("untrusted\n", encoding="utf-8")
            run("git", "add", ".", cwd=root)
            run("git", "commit", "-m", "untrusted", cwd=root)
            untrusted_commit = run("git", "rev-parse", "HEAD", cwd=root)

            accepted = run_result(BASH, str(HISTORY_GATE), str(root), main_commit, "refs/heads/main", "source", cwd=root)
            rejected = run_result(
                BASH,
                str(HISTORY_GATE),
                str(root),
                untrusted_commit,
                "refs/heads/main",
                "source",
                cwd=root,
            )

            self.assertEqual(0, accepted.returncode)
            self.assertNotEqual(0, rejected.returncode)

    def test_prebuilt_publication_consumes_status_branch_and_rechecks_source_histories(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "publish-prebuilt-index.yml").read_text(encoding="utf-8")
        publisher = (ROOT / "publish-prebuilt-index.sh").read_text(encoding="utf-8")

        self.assertIn("refs/remotes/origin/fleet-status", workflow)
        self.assertIn("refs/remotes/origin/fleet-status", publisher)
        self.assertIn("git fetch --no-tags origin", publisher)
        self.assertEqual(4, publisher.count("bash require-ancestor.sh"))


if __name__ == "__main__":
    unittest.main()
