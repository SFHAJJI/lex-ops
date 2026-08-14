#!/usr/bin/env bash
# One-time lex-corpus/4 migration. The workflow serializes this script with the nightly Fleet.
set -euo pipefail

mode="${1:-}"
: "${LEX_COMMIT:?LEX_COMMIT is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
[[ "$LEX_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: LEX_COMMIT must be a full lowercase SHA" >&2; exit 2; }

git -C lex fetch --no-tags origin main
test "$(git -C lex rev-parse HEAD)" = "$LEX_COMMIT"
git -C lex merge-base --is-ancestor "$LEX_COMMIT" refs/remotes/origin/main \
  || { echo "ERROR: LEX_COMMIT is not on protected Lex main" >&2; exit 2; }

gh auth setup-git
dotnet build lex/src/Lex.Ingest/Lex.Ingest.csproj -c Release
lex_cli=(dotnet lex/src/Lex.Ingest/bin/Release/net10.0/Lex.Ingest.dll)

repo_for() {
  jq -er --arg publisher "$1" \
    '.publishers[] | select(.enabled and .id == $publisher) | .corpus_repo' \
    publishers.json
}

configuration_for() {
  case "$1" in
    lu-legilux) printf '%s\n' lex/config/lu-work-enrichment.json ;;
    eu-eurlex) printf '%s\n' lex/config/eu-work-enrichment.json ;;
    *) echo "ERROR: unsupported publisher $1" >&2; return 2 ;;
  esac
}

require_remote_unchanged() {
  local repo="$1" expected="$2" observed
  observed=$(git ls-remote "https://github.com/$repo.git" refs/heads/main | cut -f1)
  [ "$observed" = "$expected" ] \
    || { echo "ERROR: $repo main changed during the migration" >&2; return 1; }
}

corpus() {
  : "${PUBLISHER:?PUBLISHER is required}"
  local repo directory baseline free_bytes baseline_bytes required_bytes scope_args=()
  repo=$(repo_for "$PUBLISHER")
  directory="corpus-$PUBLISHER"
  gh repo clone "$repo" "$directory" -- --depth 1 --branch main
  baseline=$(git -C "$directory" rev-parse HEAD)

  # A matrix sibling may have committed while a previous run later failed. Resume without a
  # second publisher poll, but only when the protected head is the exact v4 materialization this
  # reviewed Lex commit would have produced.
  if [ "$(jq -r '.schema // ""' "$directory/manifest.json")" = "lex-corpus/4" ]; then
    test "$(jq -r '.ingester_code_commit // ""' "$directory/manifest.json")" = "$LEX_COMMIT" \
      || { echo "ERROR: existing v4 corpus was materialized by another Lex commit" >&2; exit 2; }
    "${lex_cli[@]}" verify corpus --corpus "$directory"
    {
      echo "### Fresh corpus: $PUBLISHER"
      echo "- already committed and verified: \`$baseline\`"
      echo "- Lex materializer: \`$LEX_COMMIT\`"
    } >> "$GITHUB_STEP_SUMMARY"
    return 0
  fi

  # The fresh writer stages beside the disposable checkout. Refuse before any publisher body
  # request when the runner cannot hold one candidate plus bounded headroom.
  baseline_bytes=$(du -sb "$directory/works" "$directory/manifest.json" \
    "$directory/NOTICE" | awk '{total += $1} END {print total}')
  free_bytes=$(df --output=avail -B1 . | tail -1 | tr -d ' ')
  required_bytes=$((baseline_bytes * 5 / 4 + 2147483648))
  [ "$free_bytes" -ge "$required_bytes" ] \
    || { echo "ERROR: insufficient runner disk for the adjacent fresh candidate" >&2; exit 1; }

  if [ "$PUBLISHER" = "eu-eurlex" ]; then
    scope_args=(--scope lex/src/Lex.Sources.EurLex/eu-scope.json)
  fi
  "${lex_cli[@]}" ingest --fresh --publisher "$PUBLISHER" \
    --corpus "$directory" --code-commit "$LEX_COMMIT" "${scope_args[@]}"
  "${lex_cli[@]}" verify corpus --corpus "$directory"

  # Only the evidence layer may change. Adjacent stage/backup directories never enter this repo.
  git -C "$directory" add -- NOTICE manifest.json works
  test -n "$(git -C "$directory" diff --cached --name-only)" \
    || { echo "ERROR: fresh migration produced no replacement commit" >&2; exit 1; }
  git -C "$directory" diff --quiet
  test -z "$(git -C "$directory" ls-files --others --exclude-standard)"
  require_remote_unchanged "$repo" "$baseline"

  git -C "$directory" config user.name lex-ops
  git -C "$directory" config user.email 26882784+SFHAJJI@users.noreply.github.com
  git -C "$directory" commit -m \
    "fresh lex-corpus/4 $PUBLISHER from Lex ${LEX_COMMIT:0:12}"
  local committed
  committed=$(git -C "$directory" rev-parse HEAD)
  git -C "$directory" push origin HEAD:refs/heads/main
  test "$(git ls-remote "https://github.com/$repo.git" refs/heads/main | cut -f1)" = "$committed"
  echo "publisher=$PUBLISHER corpus_commit=$committed"
  {
    echo "### Fresh corpus: $PUBLISHER"
    echo "- baseline: \`$baseline\`"
    echo "- lex-corpus/4: \`$committed\`"
    echo "- Lex materializer: \`$LEX_COMMIT\`"
  } >> "$GITHUB_STEP_SUMMARY"
}

derive() {
  bash fleet-status.sh hydrate
  gh repo clone SFHAJJI/lex-articles articles -- --depth 1 --branch main
  local articles_base tree_id publisher repo corpus_dir corpus_commit configuration
  local representative works articles_commit status_commit
  articles_base=$(git -C articles rev-parse HEAD)
  tree_id=$(git -C lex rev-parse HEAD:src/Lex.Derive)
  declare -A corpus_commits work_counts

  for publisher in lu-legilux eu-eurlex; do
    repo=$(repo_for "$publisher")
    corpus_dir="corpus-$publisher"
    gh repo clone "$repo" "$corpus_dir" -- --depth 1 --branch main
    corpus_commit=$(git -C "$corpus_dir" rev-parse HEAD)
    corpus_commits[$publisher]="$corpus_commit"
    "${lex_cli[@]}" verify corpus --corpus "$corpus_dir"
    test "$(jq -r .schema "$corpus_dir/manifest.json")" = "lex-corpus/4"
    work_counts[$publisher]=$(jq -r .works "$corpus_dir/manifest.json")
    configuration=$(configuration_for "$publisher")

    "${lex_cli[@]}" derive --publisher "$publisher" --corpus "$corpus_dir" \
      --out articles --code-commit "$LEX_COMMIT" --deriver-tree-id "$tree_id" \
      --corpus-commit "$corpus_commit" --reviewed-configuration "$configuration"

    # One deterministic spot check catches a broken profile without paying for a second full
    # derivation. The signed index later verifies every consumed source/hash coordinate.
    if [ "$publisher" = "lu-legilux" ]; then
      representative=loi-2006-07-31-n2
    else
      representative=32013r0575
    fi
    test -d "$corpus_dir/works/$representative"
    "${lex_cli[@]}" verify derive --publisher "$publisher" \
      --corpus "$corpus_dir" --articles articles --work "$representative" \
      --code-commit "$LEX_COMMIT" --deriver-tree-id "$tree_id" \
      --corpus-commit "$corpus_commit" --reviewed-configuration "$configuration"
    rm -rf -- "$corpus_dir"
  done

  "${lex_cli[@]}" catalog --articles articles
  jq -e --arg lu "${corpus_commits[lu-legilux]}" \
    --arg eu "${corpus_commits[eu-eurlex]}" '
      .schema == "lex-articles-generation/2"
      and .publishers["lu-legilux"].corpus_commit == $lu
      and .publishers["eu-eurlex"].corpus_commit == $eu
      and (.publishers["lu-legilux"].ingester_code_commit | test("^[0-9a-f]{40}$"))
      and (.publishers["eu-eurlex"].ingester_code_commit | test("^[0-9a-f]{40}$"))
    ' articles/generation.json >/dev/null

  git -C articles add -- generation.json catalog.json lu-legilux eu-eurlex
  test -n "$(git -C articles diff --cached --name-only)" \
    || { echo "ERROR: fresh corpora produced no derived replacement" >&2; exit 1; }
  git -C articles diff --quiet
  test -z "$(git -C articles ls-files --others --exclude-standard)"
  require_remote_unchanged SFHAJJI/lex-articles "$articles_base"
  git -C articles config user.name lex-ops
  git -C articles config user.email 26882784+SFHAJJI@users.noreply.github.com
  git -C articles commit -m "derive lex-corpus/4 from Lex ${LEX_COMMIT:0:12}"
  articles_commit=$(git -C articles rev-parse HEAD)
  git -C articles push origin HEAD:refs/heads/main
  test "$(git ls-remote https://github.com/SFHAJJI/lex-articles.git refs/heads/main | cut -f1)" \
    = "$articles_commit"

  stamp=$(date -u +%FT%TZ)
  for publisher in lu-legilux eu-eurlex; do
    jq -n --arg publisher "$publisher" --arg run "$stamp" \
      --arg corpus "${corpus_commits[$publisher]}" \
      --argjson works "${work_counts[$publisher]}" \
      '{publisher:$publisher,run:$run,outcome:"fresh_v4_committed",works:$works,
        corpus_commit:$corpus}' > "status/$publisher.json"
  done
  jq -n --arg run "$stamp" --arg articles "$articles_commit" \
    '{publisher:"lex-articles",run:$run,outcome:"fresh_v4_committed",
      articles_commit:$articles}' > status/lex-articles.json
  jq -n --arg generated "$stamp" --arg code "$LEX_COMMIT" \
    --arg articles "$articles_commit" \
    --arg lu "${corpus_commits[lu-legilux]}" \
    --arg eu "${corpus_commits[eu-eurlex]}" \
    '{schema:"lex-index-build-queue/1",generated_at:$generated,mode:"prebuilt",
      build_code_commit:$code,articles_commit:$articles,entries:[
        {collection:"eu-eurlex",corpus_repo:"SFHAJJI/lex-corpus-eu-eurlex",corpus_commit:$eu},
        {collection:"lu-legilux",corpus_repo:"SFHAJJI/lex-corpus-lu-legilux",corpus_commit:$lu}
      ]}' > status/index-queue.json
  output=$(bash fleet-status.sh publish)
  printf '%s\n' "$output"
  status_commit=$(printf '%s\n' "$output" | sed -n 's/^published_status_commit=//p')
  [[ "$status_commit" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "ERROR: immutable build ticket was not published" >&2; exit 1; }
  {
    echo "### Fresh lex-corpus/4 derivation"
    echo "- articles: \`$articles_commit\`"
    echo "- build ticket: \`$status_commit\`"
    echo "- next: build both ticketed indexes through the local DirectML path"
  } >> "$GITHUB_STEP_SUMMARY"
}

case "$mode" in
  corpus) corpus ;;
  derive) derive ;;
  *) echo "usage: $0 corpus|derive" >&2; exit 2 ;;
esac
