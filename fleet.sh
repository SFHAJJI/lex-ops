#!/usr/bin/env bash
# lex-ops fleet runner — N-small centralized mode (spec §11.5).
# One cron, one credential, three-state status, pre-commit anomaly gate (§7.4 point 5).
set -uo pipefail

STAMP="$(date -u +%FT%TZ)"
mkdir -p status
overall_rc=0

for pub in $(jq -r '.publishers[] | select(.enabled) | .id' publishers.json); do
  repo=$(jq -r ".publishers[] | select(.id==\"$pub\") | .corpus_repo" publishers.json)
  dir="corpus-$pub"
  outcome="failed"
  works="null"

  echo "=== $pub ($repo) ==="
  if git clone --depth 50 "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$dir"; then
    prev_works=$(jq -r '.works // 0' "$dir/manifest.json" 2>/dev/null || echo 0)

    if dotnet run --project lex/src/Lex.Ingest -c Release -- ingest --publisher "$pub" --corpus "$dir"; then
      new_works=$(jq -r '.works // 0' "$dir/manifest.json" 2>/dev/null || echo 0)
      works="$new_works"

      # Pre-commit anomaly gate: a partial upstream response must not write history.
      if [ "$prev_works" -gt 0 ] && [ "$new_works" -lt $((prev_works * 95 / 100)) ]; then
        echo "ANOMALY: works $prev_works -> $new_works (>5% drop). Committing nothing."
        git -C "$dir" checkout -- . || true
        outcome="failed_anomaly"
        overall_rc=1
      elif [ -n "$(git -C "$dir" status --porcelain)" ]; then
        git -C "$dir" config user.name "lex-ops"
        git -C "$dir" config user.email "haji.soufien@gmail.com"
        # Scoped adds only — never add -A.
        git -C "$dir" add works manifest.json NOTICE README.md 2>/dev/null
        git -C "$dir" commit -m "nightly ingest $STAMP" && git -C "$dir" push && outcome="ran_committed" || outcome="failed"
      else
        outcome="ran_no_change"
      fi

      # Index rebuild + release only when the corpus advanced.
      if [ "$outcome" = "ran_committed" ]; then
        if dotnet run --project lex/src/Lex.Ingest -c Release -- index --corpus "$dir" \
             --out "index-$pub.db" --keyfile signing-key.pem; then
          tag="corpus-$(date -u +%F)"
          gh release create "$tag" "index-$pub.db" --repo "$repo" \
            --title "index-$pub $(date -u +%F)" \
            --notes "Signed nightly index (schema lex-index/1). Free to download and use; redistribution of any build reserved (NOTICE layer 2)." \
            || gh release upload "$tag" "index-$pub.db" --repo "$repo" --clobber || outcome="failed_release"
        else
          outcome="failed_index"; overall_rc=1
        fi
      fi
    else
      outcome="failed_ingest"; overall_rc=1
    fi
  else
    outcome="failed_clone"; overall_rc=1
  fi

  jq -n --arg pub "$pub" --arg run "$STAMP" --arg outcome "$outcome" --argjson works "${works:-null}" \
    '{publisher:$pub, run:$run, outcome:$outcome, works:$works}' > "status/$pub.json"
  echo "--- $pub: $outcome (works=$works)"
done

exit $overall_rc
