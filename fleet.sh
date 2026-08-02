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

# ---- derived consumption layer (lex-articles): regenerate, guard, push (§ blueprint inc 4).
# Determinism guard: derived files may only change when a corpus changed — a diff without
# any corpus commit means extractor nondeterminism or profile drift, and commits nothing.
echo "=== derive (lex-articles) ==="
derive_outcome="failed"
if git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/SFHAJJI/lex-articles.git" articles; then
  derive_ok=1
  for pub in $(jq -r '.publishers[] | select(.enabled) | .id' publishers.json); do
    [ -d "corpus-$pub" ] || continue
    dotnet run --project lex/src/Lex.Ingest -c Release -- derive --publisher "$pub" --corpus "corpus-$pub" --out articles || derive_ok=0
  done
  [ "$derive_ok" = 1 ] && { dotnet run --project lex/src/Lex.Ingest -c Release -- catalog --articles articles || derive_ok=0; }
  if [ "$derive_ok" = 1 ]; then
    changed=$(git -C articles status --porcelain | wc -l)
    committed=$(grep -c '"outcome": *"ran_committed"' status/*.json 2>/dev/null || true)
    if [ "$changed" -gt 0 ] && [ "${committed:-0}" -eq 0 ]; then
      echo "DERIVE NONDETERMINISM: $changed derived files changed with no corpus change. Committing nothing."
      derive_outcome="failed_nondeterminism"; overall_rc=1
    elif [ "$changed" -gt 0 ]; then
      git -C articles config user.name "lex-ops"
      git -C articles config user.email "haji.soufien@gmail.com"
      git -C articles add catalog.json lu-legilux eu-eurlex 2>/dev/null
      git -C articles commit -m "nightly derive $STAMP" && git -C articles push \
        && derive_outcome="ran_committed" || { derive_outcome="failed_push"; overall_rc=1; }
    else
      derive_outcome="ran_no_change"
    fi
  else
    overall_rc=1
  fi
else
  derive_outcome="failed_clone"; overall_rc=1
fi
jq -n --arg run "$STAMP" --arg outcome "$derive_outcome" \
  '{publisher:"lex-articles", run:$run, outcome:$outcome}' > "status/lex-articles.json"
echo "--- lex-articles: $derive_outcome"

# ---- dataset release assets (lex-articles): JSONL.gz + parquet, only when derive committed.
# All row fields are flat strings, so parquet schema inference is deterministic.
echo "=== dataset (lex-articles release assets) ==="
dataset_outcome="skipped_no_change"
if [ "$derive_outcome" = "ran_committed" ]; then
  dataset_ok=1
  dotnet run --project lex/src/Lex.Ingest -c Release -- dataset --articles articles --out dataset || dataset_ok=0
  if [ "$dataset_ok" = 1 ]; then
    python3 -m pip install --quiet pyarrow \
      || python3 -m pip install --quiet --break-system-packages pyarrow || dataset_ok=0
  fi
  if [ "$dataset_ok" = 1 ]; then
    python3 - <<'PYEOF' || dataset_ok=0
import glob, gzip, shutil
import pyarrow.json as pj, pyarrow.parquet as pq
for gzpath in glob.glob("dataset/*-provisions.jsonl.gz"):
    jl = gzpath[:-3]
    with gzip.open(gzpath, "rb") as fin, open(jl, "wb") as fout:
        shutil.copyfileobj(fin, fout)
    out = jl.replace(".jsonl", ".parquet")
    pq.write_table(pj.read_json(jl), out, compression="zstd")
    print("parquet:", out)
PYEOF
  fi
  if [ "$dataset_ok" = 1 ]; then
    tag="dataset-$(date -u +%F)"
    if gh release create "$tag" dataset/*-provisions.jsonl.gz dataset/*-provisions.parquet \
         --repo SFHAJJI/lex-articles --title "dataset $(date -u +%F)" \
         --notes "One row per provision-version (licence + attribution inline). JSONL.gz and parquet, same rows. Regenerated nightly when the law changes." \
       || gh release upload "$tag" dataset/*-provisions.jsonl.gz dataset/*-provisions.parquet \
            --repo SFHAJJI/lex-articles --clobber; then
      dataset_outcome="ran_published"
    else
      dataset_outcome="failed_release"; overall_rc=1
    fi
  else
    dataset_outcome="failed_build"; overall_rc=1
  fi
fi
jq -n --arg run "$STAMP" --arg outcome "$dataset_outcome" \
  '{publisher:"lex-dataset", run:$run, outcome:$outcome}' > "status/lex-dataset.json"
echo "--- lex-dataset: $dataset_outcome"

# ---- KPI line (append-only): one JSON line per night with fleet-wide coverage numbers.
# git history of status/*.json has the same facts, but a flat JSONL makes trends readable
# without git archaeology (and feeds any future /coverage sparkline directly).
echo "=== kpi ==="
kpi_works=0; kpi_versions=0
for pub in $(jq -r '.publishers[] | select(.enabled) | .id' publishers.json); do
  [ -f "corpus-$pub/manifest.json" ] || continue
  kpi_works=$((kpi_works + $(jq -r '.works // 0' "corpus-$pub/manifest.json")))
  kpi_versions=$((kpi_versions + $(jq -r '.versions // 0' "corpus-$pub/manifest.json")))
done
art_works=0; art_anchors=0; art_versions=0
if [ -f articles/catalog.json ]; then
  art_works=$(jq '[.works[]] | length' articles/catalog.json)
  art_anchors=$(jq '[.works[].anchors] | add // 0' articles/catalog.json)
  art_versions=$(jq '[.works[].derived_versions] | add // 0' articles/catalog.json)
fi
jq -nc --arg run "$STAMP" \
  --argjson works "$kpi_works" --argjson versions "$kpi_versions" \
  --argjson art_works "$art_works" --argjson art_versions "$art_versions" --argjson art_anchors "$art_anchors" \
  '{run:$run, corpus:{works:$works, versions:$versions}, articles:{works:$art_works, derived_versions:$art_versions, anchors:$art_anchors}}' \
  >> status/kpi.jsonl
tail -1 status/kpi.jsonl

exit $overall_rc
