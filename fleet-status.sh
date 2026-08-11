#!/usr/bin/env bash
# Keep generated Fleet state off the PR-protected code branch while retaining an
# immutable, fast-forward-only history for index-build tickets.
set -euo pipefail

command_name="${1:-}"
remote="${FLEET_STATUS_REMOTE:-origin}"
branch="${FLEET_STATUS_BRANCH:-fleet-status}"
status_dir="status"
remote_ref="refs/remotes/$remote/$branch"

fetch_status_branch() {
  if ! git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1; then
    return 1
  fi
  git fetch --no-tags "$remote" "+refs/heads/$branch:$remote_ref"
}

hydrate() {
  if fetch_status_branch; then
    git restore --source "$remote_ref" --worktree -- "$status_dir"
  else
    echo "no existing $branch branch; using the checked-out status baseline"
  fi
}

publish() {
  test -d "$status_dir" || { echo "ERROR: status directory is missing" >&2; exit 2; }
  git config user.name "lex-ops"
  git config user.email "26882784+SFHAJJI@users.noreply.github.com"

  for attempt in 1 2 3; do
    base=""
    if fetch_status_branch; then
      base=$(git rev-parse "$remote_ref")
    fi

    index_file=$(mktemp)
    rm -f "$index_file"
    if [ -n "$base" ]; then
      GIT_INDEX_FILE="$index_file" git read-tree "$base^{tree}"
    else
      GIT_INDEX_FILE="$index_file" git read-tree --empty
    fi
    GIT_INDEX_FILE="$index_file" git add -A -- "$status_dir"
    tree=$(GIT_INDEX_FILE="$index_file" git write-tree)
    rm -f "$index_file"

    if [ -n "$base" ] && [ "$tree" = "$(git rev-parse "$base^{tree}")" ]; then
      echo "no status change"
      return 0
    fi

    parent=()
    [ -n "$base" ] && parent=(-p "$base")
    commit=$(printf 'fleet status %s\n' "$(date -u +%F)" | git commit-tree "$tree" "${parent[@]}")
    if git push "$remote" "$commit:refs/heads/$branch"; then
      git update-ref "$remote_ref" "$commit"
      echo "published_status_commit=$commit"
      return 0
    fi

    if [ "$attempt" -lt 3 ]; then
      sleep $((attempt * 2))
    fi
  done

  echo "status commit could not be published after three attempts" >&2
  exit 1
}

case "$command_name" in
  hydrate) hydrate ;;
  publish) publish ;;
  *) echo "usage: $0 hydrate|publish" >&2; exit 2 ;;
esac
