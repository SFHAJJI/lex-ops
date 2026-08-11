#!/usr/bin/env bash
# Keep generated Fleet state off the PR-protected code branch while retaining an
# immutable, fast-forward-only history for index-build tickets.
set -euo pipefail

command_name="${1:-}"
remote="${FLEET_STATUS_REMOTE:-origin}"
branch="${FLEET_STATUS_BRANCH:-fleet-status}"
status_dir="status"
remote_ref="refs/remotes/$remote/$branch"
base_file=$(git rev-parse --git-path lex-fleet-status-base)
maximum_files=1024
maximum_file_bytes=4194304
maximum_total_bytes=16777216

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

fetch_status_branch() {
  set +e
  git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1
  result=$?
  set -e
  case "$result" in
    0)
      git fetch --no-tags "$remote" "+refs/heads/$branch:$remote_ref"
      ;;
    2)
      git update-ref -d "$remote_ref" 2>/dev/null || true
      return 2
      ;;
    *)
      echo "ERROR: cannot read $remote/$branch" >&2
      return "$result"
      ;;
  esac
}

validate_status_tree() {
  local ref="$1" count=0 total=0 entry metadata path mode type object size
  while IFS= read -r -d '' entry; do
    metadata=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    read -r mode type object size <<< "$metadata"
    [ "$mode" = "100644" ] && [ "$type" = "blob" ] \
      || fail "$ref contains a non-regular status entry"
    [[ "$path" =~ ^status/[a-z0-9][a-z0-9.-]{0,127}\.(json|jsonl)$ ]] \
      || fail "$ref contains a path outside the bounded status layout"
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$maximum_file_bytes" ] \
      || fail "$path exceeds the status file limit"
    count=$((count + 1))
    total=$((total + size))
    [ "$count" -le "$maximum_files" ] && [ "$total" -le "$maximum_total_bytes" ] \
      || fail "$ref exceeds the status tree limit"
  done < <(git ls-tree -r -l -z "$ref")
  [ "$count" -gt 0 ] || fail "$ref has no status files"
}

validate_working_status() {
  local count=0 total=0 path relative size
  test -d "$status_dir" || fail "status directory is missing"
  while IFS= read -r -d '' path; do
    relative=${path#./}
    [ -f "$path" ] && [ ! -L "$path" ] \
      || fail "$relative is not a regular status file"
    [[ "$relative" =~ ^status/[a-z0-9][a-z0-9.-]{0,127}\.(json|jsonl)$ ]] \
      || fail "$relative is outside the bounded status layout"
    size=$(wc -c < "$path")
    size=${size//[[:space:]]/}
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$maximum_file_bytes" ] \
      || fail "$relative exceeds the status file limit"
    count=$((count + 1))
    total=$((total + size))
    [ "$count" -le "$maximum_files" ] && [ "$total" -le "$maximum_total_bytes" ] \
      || fail "working status exceeds the status tree limit"
  done < <(find "$status_dir" -mindepth 1 -print0)
  [ "$count" -gt 0 ] || fail "status directory has no files"
}

record_base() {
  mkdir -p "$(dirname "$base_file")"
  printf '%s\n' "$1" > "$base_file"
}

hydrate() {
  if fetch_status_branch; then
    base=$(git rev-parse "$remote_ref")
    validate_status_tree "$base"
    git restore --source "$base" --worktree -- "$status_dir"
    record_base "$base"
  else
    result=$?
    [ "$result" -eq 2 ] || exit "$result"
    validate_working_status
    record_base absent
    echo "no existing $branch branch; using the checked-out status baseline"
  fi
}

publish() {
  test -f "$base_file" || fail "hydrate must run before publish"
  expected_base=$(tr -d '\r\n' < "$base_file")
  [[ "$expected_base" = "absent" || "$expected_base" =~ ^[0-9a-f]{40}$ ]] \
    || fail "invalid hydrated status base"
  validate_working_status
  git config user.name "lex-ops"
  git config user.email "26882784+SFHAJJI@users.noreply.github.com"

  index_file=$(mktemp)
  rm -f "$index_file"
  GIT_INDEX_FILE="$index_file" git read-tree --empty
  GIT_INDEX_FILE="$index_file" git add -A -- "$status_dir"
  tree=$(GIT_INDEX_FILE="$index_file" git write-tree)
  rm -f "$index_file"

  if fetch_status_branch; then
    current_base=$(git rev-parse "$remote_ref")
    validate_status_tree "$current_base"
  else
    result=$?
    [ "$result" -eq 2 ] || exit "$result"
    current_base=absent
  fi
  [ "$current_base" = "$expected_base" ] \
    || fail "$branch changed after hydration; refusing to overwrite newer state"

  if [ "$current_base" != "absent" ] && [ "$tree" = "$(git rev-parse "$current_base^{tree}")" ]; then
    echo "no status change"
    return 0
  fi

  parent=()
  [ "$current_base" != "absent" ] && parent=(-p "$current_base")
  commit=$(printf 'fleet status %s\n' "$(date -u +%F)" | git commit-tree "$tree" "${parent[@]}")

  for attempt in 1 2 3; do
    if git push "$remote" "$commit:refs/heads/$branch"; then
      git update-ref "$remote_ref" "$commit"
      echo "published_status_commit=$commit"
      return 0
    fi

    if fetch_status_branch; then
      observed=$(git rev-parse "$remote_ref")
      if [ "$observed" = "$commit" ]; then
        echo "published_status_commit=$commit"
        return 0
      fi
      [ "$observed" = "$expected_base" ] \
        || fail "$branch changed while publishing; refusing to overwrite newer state"
    else
      result=$?
      [ "$result" -eq 2 ] || exit "$result"
      [ "$expected_base" = "absent" ] \
        || fail "$branch disappeared while publishing"
    fi
    [ "$attempt" -lt 3 ] && sleep $((attempt * 2))
  done

  fail "status commit could not be published after three attempts"
}

case "$command_name" in
  hydrate) hydrate ;;
  publish) publish ;;
  *) echo "usage: $0 hydrate|publish" >&2; exit 2 ;;
esac
