#!/usr/bin/env bash
# Current-code gate for fresh-corpus and prebuilt-index identities. Never delegate this validation
# to the historical Lex commit named by an untrusted queue ticket.
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

sha256_stdin() {
  sha256sum | awk '{print $1}'
}

validate_ticket() {
  local ticket="$1" expected actual
  jq -e '
      (keys | sort) == ["articles_commit","articles_generation_sha256","build_code_commit","entries","generated_at","mode","schema","ticket_id"]
      and .schema == "lex-index-build-queue/2"
      and (.mode == "prebuilt" or .mode == "hosted")
      and (.generated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (.ticket_id | type == "string" and test("^[0-9a-f]{64}$"))
      and (.build_code_commit | type == "string" and test("^[0-9a-f]{40}$"))
      and (.articles_commit | type == "string" and test("^[0-9a-f]{40}$"))
      and (.articles_generation_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      and (.entries | type == "array" and length >= 1 and length <= 2)
      and ([.entries[].collection] as $collections
           | $collections == ($collections | sort | unique))
      and (all(.entries[];
        (keys | sort) == ["collection","corpus_commit","corpus_manifest_sha256","corpus_repo","deriver_code_commit","deriver_tree_id","ingester_code_commit","profiles_sha256","source_configuration_kind","source_configuration_sha256"]
        and (.corpus_commit | type == "string" and test("^[0-9a-f]{40}$"))
        and (.corpus_manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.ingester_code_commit | type == "string" and test("^[0-9a-f]{40}$"))
        and (.deriver_code_commit | type == "string" and test("^[0-9a-f]{40}$"))
        and (.deriver_tree_id | type == "string" and test("^[0-9a-f]{40}$"))
        and (.profiles_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.source_configuration_kind == "code_only" or .source_configuration_kind == "engineering_scope")
        and ((.collection == "eu-eurlex" and .corpus_repo == "SFHAJJI/lex-corpus-eu-eurlex"
              and .source_configuration_kind == "engineering_scope")
             or (.collection == "lu-legilux" and .corpus_repo == "SFHAJJI/lex-corpus-lu-legilux"
                 and .source_configuration_kind == "code_only"))
        and (if .source_configuration_kind == "code_only"
             then .source_configuration_sha256 == null
             else (.source_configuration_sha256 | type == "string" and test("^[0-9a-f]{64}$")) end)))
    ' "$ticket" >/dev/null || fail "ticket must satisfy lex-index-build-queue/2"
  actual=$(jq -er .ticket_id "$ticket")
  expected=$(jq -j -S -c 'del(.ticket_id,.generated_at)' "$ticket" | sha256_stdin)
  [ "$actual" = "$expected" ] || fail "ticket_id does not match the canonical ticket inputs"
}

validate_migration_ticket() {
  validate_ticket "$1"
  jq -e '
    .mode == "prebuilt"
    and [.entries[].collection] == ["eu-eurlex","lu-legilux"]
  ' "$1" >/dev/null || fail "migration ticket must contain both publishers"
}

validate_corpus_manifest() {
  local publisher="$1" manifest="$2" source_configuration="$3" expected_ingester="$4"
  local ingester source_kind source_sha
  ingester=$(jq -er --arg publisher "$publisher" '
    select(.schema == "lex-corpus/4" and .publisher.id == $publisher)
    | .ingester_code_commit
    | select(type == "string" and test("^[0-9a-f]{40}$"))
  ' "$manifest") || fail "corpus manifest is not exact lex-corpus/4 publisher evidence"
  if [ "$expected_ingester" != "-" ] && [ "$ingester" != "$expected_ingester" ]; then
    fail "corpus manifest was materialized by another Lex commit"
  fi
  source_kind=$(jq -er '.source_configuration_kind' "$manifest")
  case "$publisher" in
    eu-eurlex)
      [ "$source_kind" = "engineering_scope" ] \
        || fail "EUR-Lex corpus must bind its engineering scope"
      [ "$source_configuration" != "-" ] && [ -f "$source_configuration" ] \
        || fail "EUR-Lex source configuration is required"
      source_sha=$(sha256_file "$source_configuration")
      [ "$(jq -er '.source_configuration_sha256' "$manifest")" = "$source_sha" ] \
        || fail "EUR-Lex source configuration does not match the corpus manifest"
      ;;
    lu-legilux)
      [ "$source_kind" = "code_only" ] && [ "$source_configuration" = "-" ] \
        && jq -e '.source_configuration_sha256 == null' "$manifest" >/dev/null \
        || fail "Legilux corpus must use code-only source configuration"
      ;;
    *) fail "unsupported publisher $publisher" ;;
  esac
  printf '%s\n' "$ingester"
}

validate_generation() {
  local publisher="$1" repository="$2" corpus_commit="$3" deriver_commit="$4" tree_id="$5"
  local manifest="$6" generation="$7" source_configuration="$8"
  local manifest_sha ingester repo_name profiles canonical_profiles profiles_sha
  ingester=$(validate_corpus_manifest "$publisher" "$manifest" "$source_configuration" -)
  manifest_sha=$(sha256_file "$manifest")
  repo_name=${repository#SFHAJJI/}
  profiles=$(jq -cer --arg publisher "$publisher" '.publishers[$publisher].profiles' "$generation") \
    || fail "generation profiles are absent"
  canonical_profiles=$(printf '%s' "$profiles" | jq -c 'sort | unique')
  [ "$profiles" = "$canonical_profiles" ] \
    && [ "$(printf '%s' "$profiles" | jq 'length')" -gt 0 ] \
    && printf '%s' "$profiles" | jq -e \
      'all(.[]; type == "string" and test("^[A-Za-z0-9._/-]{1,128}$"))' >/dev/null \
    || fail "generation profiles must be non-empty, sorted and unique"
  # jq.exe emits CRLF even for explicit newlines. Strip only CR after rejecting it from the
  # closed profile alphabet so ticket validation is byte-identical on Windows and Linux.
  profiles_sha=$(printf '%s' "$profiles" | jq -r '.[]' | tr -d '\r' | sha256_stdin)

  jq -e --arg publisher "$publisher" --arg repository "$repo_name" \
    --arg corpus "$corpus_commit" --arg manifest "$manifest_sha" --arg ingester "$ingester" \
    --arg deriver "$deriver_commit" --arg tree "$tree_id" \
    --arg profiles "$profiles_sha" '
      .schema == "lex-articles-generation/3"
      and (.publishers | type == "object")
      and .publishers[$publisher].collection == $publisher
      and .publishers[$publisher].corpus_repository == $repository
      and .publishers[$publisher].corpus_commit == $corpus
      and .publishers[$publisher].corpus_manifest_sha256 == $manifest
      and .publishers[$publisher].ingester_code_commit == $ingester
      and .publishers[$publisher].deriver_code_commit == $deriver
      and .publishers[$publisher].deriver_tree_id == $tree
      and .publishers[$publisher].profiles_sha256 == $profiles
    ' "$generation" >/dev/null || fail "generation does not bind the exact v4 derivation inputs"
}

validate_source() {
  local ticket="$1" publisher="$2" repository="$3" corpus_commit="$4" build_commit="$5"
  local articles_commit="$6" manifest="$7" generation="$8" source_configuration="$9"
  local manifest_sha generation_sha ingester profiles_sha source_kind source_sha
  local deriver_commit tree_id
  validate_ticket "$ticket"
  deriver_commit=$(jq -er --arg publisher "$publisher" \
    '.entries[] | select(.collection == $publisher) | .deriver_code_commit' "$ticket")
  tree_id=$(jq -er --arg publisher "$publisher" \
    '.entries[] | select(.collection == $publisher) | .deriver_tree_id' "$ticket")
  validate_generation "$publisher" "$repository" "$corpus_commit" "$deriver_commit" "$tree_id" \
    "$manifest" "$generation" "$source_configuration"
  manifest_sha=$(sha256_file "$manifest")
  generation_sha=$(sha256_file "$generation")
  ingester=$(jq -er .ingester_code_commit "$manifest")
  profiles_sha=$(jq -er --arg publisher "$publisher" '.publishers[$publisher].profiles_sha256' "$generation")
  source_kind=$(jq -er .source_configuration_kind "$manifest")
  source_sha=$(jq -c '.source_configuration_sha256 // null' "$manifest")
  jq -e --arg publisher "$publisher" --arg repository "$repository" \
    --arg corpus "$corpus_commit" --arg build "$build_commit" --arg articles "$articles_commit" \
    --arg generation "$generation_sha" --arg tree "$tree_id" --arg manifest "$manifest_sha" \
    --arg ingester "$ingester" --arg deriver "$deriver_commit" \
    --arg profiles "$profiles_sha" --arg source_kind "$source_kind" \
    --argjson source_sha "$source_sha" '
      .build_code_commit == $build and .articles_commit == $articles
      and .articles_generation_sha256 == $generation
      and ([.entries[] | select(
        .collection == $publisher and .corpus_repo == $repository
        and .corpus_commit == $corpus and .corpus_manifest_sha256 == $manifest
        and .ingester_code_commit == $ingester and .deriver_code_commit == $deriver
        and .deriver_tree_id == $tree
        and .profiles_sha256 == $profiles
        and .source_configuration_kind == $source_kind
        and .source_configuration_sha256 == $source_sha)] | length == 1)
    ' "$ticket" >/dev/null || fail "ticket entry does not bind the exact generation inputs"
}

seal_ticket() {
  local core="$1" output="$2" generated_at="$3" ticket_id temporary
  jq -e 'has("ticket_id") | not' "$core" >/dev/null || fail "ticket core already has ticket_id"
  jq -e 'has("generated_at") | not' "$core" >/dev/null || fail "ticket core already has generated_at"
  ticket_id=$(jq -j -S -c . "$core" | sha256_stdin)
  temporary="$output.tmp"
  jq --arg ticket "$ticket_id" --arg generated "$generated_at" \
    '. + {ticket_id:$ticket,generated_at:$generated}' "$core" > "$temporary"
  mv "$temporary" "$output"
  validate_ticket "$output"
}

classify_articles_tree() {
  local repository="$1"
  git -C "$repository" diff --quiet \
    || fail "articles tree has unstaged changes"
  [ -z "$(git -C "$repository" ls-files --others --exclude-standard)" ] \
    || fail "articles tree has untracked files"
  if git -C "$repository" diff --cached --quiet; then
    echo reuse
  else
    echo publish
  fi
}

classify_ticket() {
  local current="$1" candidate="$2" schema current_id candidate_id
  validate_ticket "$candidate"
  [ -f "$current" ] || { echo publish; return; }
  schema=$(jq -r '.schema // ""' "$current")
  if [ "$schema" = "lex-index-build-queue/1" ]; then
    echo replace
    return
  fi
  [ "$schema" = "lex-index-build-queue/2" ] \
    || fail "current index queue has an unknown schema"
  validate_ticket "$current"
  current_id=$(jq -er .ticket_id "$current")
  candidate_id=$(jq -er .ticket_id "$candidate")
  if [ "$current_id" = "$candidate_id" ]; then
    echo reuse
  else
    echo publish
  fi
}

classify_migration_ticket() {
  local current="$1" candidate="$2" action
  action=$(classify_ticket "$current" "$candidate")
  if [ "$action" = publish ] && [ -f "$current" ] \
     && [ "$(jq -r '.schema // ""' "$current")" = "lex-index-build-queue/2" ]; then
    fail "another queue/2 ticket superseded this migration"
  fi
  echo "$action"
}

validate_append_only_protection() {
  jq -e '
    .enforce_admins.enabled == true
    and .required_linear_history.enabled == true
    and .allow_force_pushes.enabled == false
    and .allow_deletions.enabled == false
    and .required_pull_request_reviews == null
  ' "$1" >/dev/null || fail "source branch protection is not append-only direct-push policy"
}

validate_protected_code() {
  jq -e '
    .enforce_admins.enabled == true
    and .required_linear_history.enabled == true
    and .allow_force_pushes.enabled == false
    and .allow_deletions.enabled == false
    and (.required_pull_request_reviews | type == "object")
  ' "$1" >/dev/null || fail "code branch protection does not require reviewed pull requests"
}

case "${1:-}" in
  validate-corpus-manifest)
    [ "$#" -eq 5 ] || fail "usage: $0 validate-corpus-manifest PUBLISHER MANIFEST SOURCE_CONFIGURATION_OR_DASH EXPECTED_INGESTER_OR_DASH"
    validate_corpus_manifest "$2" "$3" "$4" "$5"
    ;;
  validate-generation)
    [ "$#" -eq 9 ] || fail "usage: $0 validate-generation PUBLISHER REPOSITORY CORPUS DERIVER TREE MANIFEST GENERATION SOURCE_CONFIGURATION_OR_DASH"
    validate_generation "${@:2}"
    ;;
  classify-articles-tree)
    [ "$#" -eq 2 ] || fail "usage: $0 classify-articles-tree REPOSITORY"
    classify_articles_tree "$2"
    ;;
  classify-ticket)
    [ "$#" -eq 3 ] || fail "usage: $0 classify-ticket CURRENT CANDIDATE"
    classify_ticket "$2" "$3"
    ;;
  classify-migration-ticket)
    [ "$#" -eq 3 ] || fail "usage: $0 classify-migration-ticket CURRENT CANDIDATE"
    classify_migration_ticket "$2" "$3"
    ;;
  seal-ticket)
    [ "$#" -eq 4 ] || fail "usage: $0 seal-ticket CORE OUTPUT GENERATED_AT"
    seal_ticket "$2" "$3" "$4"
    ;;
  validate-ticket)
    [ "$#" -eq 2 ] || fail "usage: $0 validate-ticket TICKET"
    validate_ticket "$2"
    ;;
  validate-migration-ticket)
    [ "$#" -eq 2 ] || fail "usage: $0 validate-migration-ticket TICKET"
    validate_migration_ticket "$2"
    ;;
  validate-source)
    [ "$#" -eq 10 ] || fail "usage: $0 validate-source TICKET PUBLISHER REPOSITORY CORPUS BUILD ARTICLES MANIFEST GENERATION SOURCE_CONFIGURATION_OR_DASH"
    validate_source "${@:2}"
    ;;
  validate-append-only-protection)
    [ "$#" -eq 2 ] || fail "usage: $0 validate-append-only-protection JSON"
    validate_append_only_protection "$2"
    ;;
  validate-protected-code)
    [ "$#" -eq 2 ] || fail "usage: $0 validate-protected-code JSON"
    validate_protected_code "$2"
    ;;
  *) fail "unknown v4 release-contract command" ;;
esac
