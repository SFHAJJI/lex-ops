import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FLEET = ROOT / "fleet.sh"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"


HARNESS = r'''
git() {
  if [ "$1" = clone ]; then
    target="${@: -1}"
    printf '%s\n' "$target" >> "$NETWORK_LOG"
    mkdir -p "$target"
    if [ "$target" = articles ]; then
      printf '%s\n' '{"schema":"lex-articles-generation/3"}' > "$target/generation.json"
      printf '%s\n' '{"works":[]}' > "$target/catalog.json"
    else
      printf '%s\n' '{"works":1,"versions":1}' > "$target/manifest.json"
    fi
    return 0
  fi
  if [ "$1" = -C ] && [ "$3" = rev-parse ]; then
    case "$4" in
      HEAD:src/Lex.Derive) printf '%040d\n' 0 ;;
      *) printf '%040d\n' 0 ;;
    esac
    return 0
  fi
  return 0
}

jq() {
  case "$*" in
    *'.publishers[] | select(.enabled) | .id'*)
      printf '%s\n' lu-legilux eu-eurlex ;;
    *corpus_repo*lu-legilux*) printf '%s\n' SFHAJJI/lex-corpus-lu ;;
    *corpus_repo*eu-eurlex*) printf '%s\n' SFHAJJI/lex-corpus-eu ;;
    *'.outcome // "failed"'*) printf '%s\n' failed_base_integrity ;;
    *'.works // 0'*|*'.versions // 0'*) printf '%s\n' 1 ;;
    *) printf '%s\n' '{}' ;;
  esac
}

dotnet() {
  printf '%s\n' "$*" >> "$DOTNET_LOG"
  case " $* " in
    *' verify corpus '*) return "$VERIFY_RC" ;;
    *' ingest '*) return 9 ;;
    *' catalog '*) return 0 ;;
    *) return 97 ;;
  esac
}

gh() {
  case "$*" in
    'release view '*) return 1 ;;
    *) printf 'gh %s\n' "$*" >> "$DOWNSTREAM_LOG"; return 97 ;;
  esac
}
az() { printf 'az %s\n' "$*" >> "$DOWNSTREAM_LOG"; return 97; }
curl() { printf 'curl %s\n' "$*" >> "$DOWNSTREAM_LOG"; return 97; }

source ./fleet.sh
'''


class FleetRunIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name == "nt":
            candidate = (
                Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
                / "Git"
                / "bin"
                / "bash.exe"
            )
            cls.bash = str(candidate) if candidate.exists() else None
        else:
            cls.bash = shutil.which("bash")

    def setUp(self):
        if not self.bash:
            self.skipTest("bash is required for the Fleet contract")

    def test_nightly_binds_github_run_and_attempt(self):
        workflow = NIGHTLY.read_text(encoding="utf-8")
        self.assertIn(
            'SOURCE_RUN_ID_PREFIX: "gha:${{ github.run_id }}:${{ github.run_attempt }}"',
            workflow,
        )

    def test_missing_identity_fails_before_clone_or_ingest(self):
        completed, dotnet, network, downstream = self.run_fleet(None)

        self.assertEqual(2, completed.returncode, completed.stderr)
        self.assertEqual([], dotnet)
        self.assertEqual([], network)
        self.assertEqual([], downstream)
        self.assertIn("SOURCE_RUN_ID_PREFIX", completed.stderr)

    def test_malformed_identity_fails_before_clone_or_ingest(self):
        for identity in ("gha:700", "gha:abc:1", "gha:700:0", "gha:700:1:extra"):
            with self.subTest(identity=identity):
                completed, dotnet, network, downstream = self.run_fleet(identity)
                self.assertEqual(2, completed.returncode, completed.stderr)
                self.assertEqual([], dotnet)
                self.assertEqual([], network)
                self.assertEqual([], downstream)

    def test_each_publisher_and_attempt_has_one_exact_identity(self):
        first = self.run_fleet("gha:700:1")
        second = self.run_fleet("gha:700:2")

        first_ingests = [line for line in first[1] if " ingest " in f" {line} "]
        second_ingests = [line for line in second[1] if " ingest " in f" {line} "]
        self.assertEqual(2, len(first_ingests))
        self.assertEqual(2, len(second_ingests))

        def identities_by_publisher(lines):
            identities = {}
            for line in lines:
                arguments = line.split()
                self.assertEqual(1, arguments.count("--publisher"))
                self.assertEqual(1, arguments.count("--run-id"))
                publisher = arguments[arguments.index("--publisher") + 1]
                identities[publisher] = arguments[arguments.index("--run-id") + 1]
            return identities

        first_ids = identities_by_publisher(first_ingests)
        second_ids = identities_by_publisher(second_ingests)
        self.assertEqual(
            {
                "lu-legilux": "gha:700:1:lu-legilux",
                "eu-eurlex": "gha:700:1:eu-eurlex",
            },
            first_ids,
        )
        self.assertEqual(
            {
                "lu-legilux": "gha:700:2:lu-legilux",
                "eu-eurlex": "gha:700:2:eu-eurlex",
            },
            second_ids,
        )
        self.assertTrue(set(first_ids.values()).isdisjoint(second_ids.values()))

    def test_historical_base_block_still_prevents_downstream_commands(self):
        completed, dotnet, network, downstream = self.run_fleet(
            "gha:700:1", verify_rc=4
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertEqual(2, sum(" verify corpus " in f" {line} " for line in dotnet))
        self.assertIn("articles", network, "the real derived branch was not exercised")
        for forbidden in (" ingest ", " derive ", " index ", " artifact ", " dataset "):
            with self.subTest(forbidden=forbidden):
                self.assertFalse(any(forbidden in f" {line} " for line in dotnet))
        self.assertEqual([], downstream)
        self.assertIn("failed_base_integrity", completed.stdout)
        self.assertEqual(2, completed.stdout.count("refusing index refresh"))

    def run_fleet(self, identity_prefix, *, verify_rc=0):
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            directory = Path(temporary)
            shutil.copy2(FLEET, directory / "fleet.sh")
            shutil.copy2(ROOT / "publishers.json", directory / "publishers.json")
            dotnet_log = directory / "dotnet.log"
            network_log = directory / "network.log"
            downstream_log = directory / "downstream.log"
            for path in (dotnet_log, network_log, downstream_log):
                path.touch()

            environment = os.environ.copy()
            environment.update(
                {
                    "GH_TOKEN": "test-token",
                    "VERIFY_RC": str(verify_rc),
                    "DOTNET_LOG": dotnet_log.as_posix(),
                    "NETWORK_LOG": network_log.as_posix(),
                    "DOWNSTREAM_LOG": downstream_log.as_posix(),
                }
            )
            environment.pop("SOURCE_RUN_ID_PREFIX", None)
            if identity_prefix is not None:
                environment["SOURCE_RUN_ID_PREFIX"] = identity_prefix

            completed = subprocess.run(
                [self.bash],
                cwd=directory,
                env=environment,
                input=HARNESS,
                text=True,
                capture_output=True,
                check=False,
            )
            return (
                completed,
                dotnet_log.read_text(encoding="utf-8").splitlines(),
                network_log.read_text(encoding="utf-8").splitlines(),
                downstream_log.read_text(encoding="utf-8").splitlines(),
            )


if __name__ == "__main__":
    unittest.main()
