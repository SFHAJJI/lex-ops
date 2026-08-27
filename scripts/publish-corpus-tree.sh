#!/usr/bin/env bash
set -uo pipefail

fail() {
  echo "ERROR: $2" >&2
  echo "$1"
  exit 1
}

[ "$#" -eq 2 ] || { echo "failed_usage"; exit 2; }
directory="$1"
stamp="$2"
branch_ref=$(git -C "$directory" symbolic-ref --quiet HEAD 2>/dev/null) \
  || fail failed_branch "corpus publication requires an attached main branch"
[ "$branch_ref" = "refs/heads/main" ] \
  || fail failed_branch "corpus publication is restricted to refs/heads/main"

git -C "$directory" add -- works manifest.json NOTICE README.md 2>/dev/null \
  || fail failed_add "could not stage the scoped corpus evidence"

staged_paths=$(mktemp) \
  || fail failed_diff "could not allocate the staged-path check"
trap 'rm -f -- "$staged_paths"' EXIT
git -C "$directory" diff --cached --name-only --no-renames -z > "$staged_paths" \
  || fail failed_diff "could not inspect the staged corpus paths"
while IFS= read -r -d '' staged_path; do
  case "$staged_path" in
    works/*|manifest.json|NOTICE|README.md) ;;
    *) fail failed_scope "a staged path falls outside the corpus evidence allowlist" ;;
  esac
done < "$staged_paths"
rm -f -- "$staged_paths"
trap - EXIT

git -C "$directory" diff --cached --quiet
diff_rc=$?
case "$diff_rc" in
  0) echo "ran_no_change"; exit 0 ;;
  1) ;;
  *) fail failed_diff "could not inspect the staged corpus evidence" ;;
esac

git -C "$directory" config user.name "lex-ops" \
  && git -C "$directory" config user.email "26882784+SFHAJJI@users.noreply.github.com" \
  || fail failed_commit "could not configure the corpus commit identity"

git -C "$directory" commit -m "nightly ingest $stamp" >&2 \
  || fail failed_commit "could not commit the staged corpus evidence"

committed=$(git -C "$directory" rev-parse HEAD 2>/dev/null) \
  || fail failed_readback "could not read back the local corpus commit"

git -C "$directory" push origin "HEAD:refs/heads/main" >&2 \
  || fail failed_push "could not push the corpus commit"

remote_commit=$(git -C "$directory" ls-remote --exit-code origin \
  "refs/heads/main" 2>/dev/null | awk 'NR == 1 { print $1 }') \
  || fail failed_readback "could not read back the remote corpus head"
[ "$remote_commit" = "$committed" ] \
  || fail failed_readback "remote corpus head does not match the pushed commit"

echo "ran_committed"
