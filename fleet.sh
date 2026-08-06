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

      # Recompute record and observation hashes before either derivation or commit.
      # This also rejects orphaned version directories and manifest/filesystem drift.
      if ! dotnet run --project lex/src/Lex.Ingest -c Release -- verify corpus --corpus "$dir"; then
        echo "INTEGRITY: corpus evidence verification failed. Committing nothing."
        outcome="failed_integrity"
        overall_rc=1
      # Pre-commit anomaly gate: a partial upstream response must not write history.
      elif [ "$prev_works" -gt 0 ] && [ "$new_works" -lt $((prev_works * 95 / 100)) ]; then
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

      # Index rebuild happens AFTER the derive stage (lex-index/3 needs --articles;
      # an index built without provisions has a dead search). Remember who advanced.
      [ "$outcome" = "ran_committed" ] && echo "$pub $repo" >> .index-queue
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
    # grep -c over MULTIPLE files prints "path:count" per file, not a total — the old form
    # produced a multi-line string, the integer test below errored, and the guard fell
    # through to committing. It had never once fired. Count matching FILES instead.
    committed=$(grep -l '"outcome": *"ran_committed"' status/*.json 2>/dev/null | wc -l)
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

# ---- index rebuild + release for publishers whose corpus advanced tonight.
# Runs after derive so lex-index/3 gets the fresh per-article layer (--articles);
# without it the provisions/FTS tables are empty and search is dead.
#
# Reordering the stages was not enough: the queue is written from the INGEST outcome, so a
# failed derive (clone failure, extractor error) still let a signed, valid, zero-provision
# index reach the public repo by a different route. Publishing an index now REQUIRES a
# derived layer that is known good.
if [ "$derive_outcome" != "ran_committed" ] && [ "$derive_outcome" != "ran_no_change" ]; then
  echo "SKIPPING INDEX: derive outcome is '$derive_outcome' — refusing to publish an index"
  echo "built against an unverified derived layer."
  rm -f .index-queue
  overall_rc=1
fi
# A publisher whose CORPUS is quiet never reaches the queue above, so it never rebuilds its
# index. That is a defect, not a saving: an index is a function of the corpus AND of the code
# that builds it, so when a column is added to lex-index/2 a quiet publisher keeps serving the
# old shape indefinitely.
#
# It bit on 2026-08-05. eu-eurlex had not moved since 2026-08-03, so its published index still
# had 21 columns and lacked `profile`. IndexReader.Open correctly refused it, and the EU acts
# vanished from the served corpus the moment the deploy started fetching published indexes
# instead of a developer's local copy.
#
# A max-age rebuild is the cheap general answer: whatever changed, corpus or code or neither,
# no published index is ever more than a week behind the builder that makes it.
# Only when derive is known good. The block above deliberately empties the queue when it is
# not, and re-queueing here would walk straight past that safety check.
if [ "$derive_outcome" = "ran_committed" ] || [ "$derive_outcome" = "ran_no_change" ]; then
  MAX_INDEX_AGE_DAYS="${MAX_INDEX_AGE_DAYS:-7}"
  echo "=== stale-index check (max ${MAX_INDEX_AGE_DAYS}d) ==="
  for pub in $(jq -r '.publishers[] | select(.enabled) | .id' publishers.json); do
    repo=$(jq -r ".publishers[] | select(.id==\"$pub\") | .corpus_repo" publishers.json)
    if [ -f .index-queue ] && grep -q "^$pub " .index-queue; then
      echo "--- $pub: already queued"; continue
    fi
    # No corpus checkout means ingest failed tonight. Do not paper over that with a rebuild.
    if [ ! -d "corpus-$pub" ]; then
      echo "--- $pub: no corpus checkout, skipping"; continue
    fi
    published=$(gh release view --repo "$repo" --json publishedAt -q .publishedAt 2>/dev/null || true)
    if [ -z "$published" ]; then
      echo "--- $pub: no release yet, queueing"; echo "$pub $repo" >> .index-queue; continue
    fi
    manifest="index-$pub.manifest.json"
    if ! gh release view --repo "$repo" --json assets -q '.assets[].name' 2>/dev/null \
         | grep -Fxq "$manifest"; then
      echo "--- $pub: release has no signed artifact manifest, queueing migration refresh"
      echo "$pub $repo" >> .index-queue
      continue
    fi
    age=$(( ( $(date -u +%s) - $(date -u -d "$published" +%s) ) / 86400 ))
    if [ "$age" -ge "$MAX_INDEX_AGE_DAYS" ]; then
      echo "--- $pub: published index is ${age}d old, queueing a refresh"
      echo "$pub $repo" >> .index-queue
    else
      echo "--- $pub: published index is ${age}d old, fresh enough"
    fi
  done


fi

if [ -f .index-queue ]; then
  # The evidence verifier and derivation have already consumed publisher bodies. IndexFromCorpus
  # reads only manifest/meta records plus the verified derived layer, so keeping duplicate XML,
  # HTML, PDF and Formex working-tree bytes during index/vector construction only exhausts the
  # ephemeral runner disk. Delete them from these throwaway clones, never from the source repos.
  # Git metadata stays mounted so corpus_commit remains provable in the artifact manifest.
  echo "=== reclaim ephemeral evidence working-tree space ==="
  for corpus_dir in corpus-*; do
    [ -d "$corpus_dir/works" ] || continue
    find "$corpus_dir/works" -type f ! -name meta.json -delete
    find "$corpus_dir/works" -depth -type d -empty -delete
  done
  # The article commit, if any, was already pushed. Indexing and dataset export need its files,
  # not a second copy of their history in this disposable checkout.
  rm -rf articles/.git
  df -h .

  published_artifacts=0
  lex_code_commit=$(git -C lex rev-parse HEAD)

  # The encoder is a release artifact, not an unpinned package download at runtime. Resolve the
  # exact reviewed revision, verify both files against the manifest committed in Lex, then run
  # one real inference before spending time building vectors. The private model path never
  # reaches the web container: only these verified, signed files do.
  cp lex/deploy/embedding-model/model-manifest.json model-manifest.json
  model_revision=$(jq -r .revision model-manifest.json)
  model_sha=$(jq -r '.files["model.onnx"]' model-manifest.json)
  tokenizer_sha=$(jq -r '.files["sentencepiece.bpe.model"]' model-manifest.json)
  model_base="https://huggingface.co/intfloat/multilingual-e5-small/resolve/$model_revision"
  if ! curl -fsSL --retry 3 --retry-delay 5 \
       -o model.onnx "$model_base/onnx/model_qint8_avx512_vnni.onnx" \
     || ! curl -fsSL --retry 3 --retry-delay 5 \
       -o sentencepiece.bpe.model "$model_base/sentencepiece.bpe.model" \
     || ! printf '%s  %s\n%s  %s\n' "$model_sha" model.onnx \
       "$tokenizer_sha" sentencepiece.bpe.model | sha256sum -c - \
     || ! dotnet run --project lex/src/Lex.Ingest -c Release -- embedding-smoke \
       --model-dir . --text "protection des donnees personnelles"; then
    echo "ERROR: pinned embedding model download or inference smoke failed"
    rm -f .index-queue
    overall_rc=1
  fi

fi

if [ -f .index-queue ]; then
  lex_code_commit=$(git -C lex rev-parse HEAD)
  while read -r pub repo; do
    echo "=== index ($pub) ==="
    if dotnet run --project lex/src/Lex.Ingest -c Release -- index --corpus "corpus-$pub" \
         --articles articles --out "index-$pub.db" --keyfile signing-key.pem \
         --embedding-model . --vectors "index-$pub.vectors"; then
      corpus_commit=$(git -C "corpus-$pub" rev-parse HEAD)
      manifest="index-$pub.manifest.json"
      signature="index-$pub.manifest.sig"
      artifact_files=(--file "index-$pub.db" --file "index-$pub.vectors" \
        --file model-manifest.json --file model.onnx --file sentencepiece.bpe.model)
      release_assets=("index-$pub.db" "index-$pub.vectors" model-manifest.json \
        model.onnx sentencepiece.bpe.model)
      if [ "$pub" = "eu-eurlex" ]; then
        cp lex/src/Lex.Sources.EurLex/eu-scope.json eu-scope.json
        artifact_files+=(--file eu-scope.json)
        release_assets+=(eu-scope.json)
      fi
      signing_mode="${ARTIFACT_SIGNING_MODE:-legacy}"
      if [ "$signing_mode" = "keyvault" ]; then
        : "${AZURE_KEY_VAULT:?AZURE_KEY_VAULT is required for Key Vault signing}"
        : "${AZURE_KEY_NAME:?AZURE_KEY_NAME is required for Key Vault signing}"
        : "${ARTIFACT_KEY_ID:?ARTIFACT_KEY_ID is required for Key Vault signing}"
        if ! dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
             --root . "${artifact_files[@]}" --manifest "$manifest" \
             --key-id "$ARTIFACT_KEY_ID" --code-commit "$lex_code_commit" \
             --source "collection=$pub" --source "corpus_commit=$corpus_commit"; then
          echo "--- $pub: failed_manifest"; overall_rc=1; continue
        fi
        # Azure CLI accepts the digest as padded standard base64. Its signature result is
        # base64url, which Lex's verifier accepts explicitly.
        digest=$(openssl dgst -sha256 -binary "$manifest" | openssl base64 -A)
        if ! az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
             --algorithm ES256 --digest "$digest" --query value -o tsv > "$signature"; then
          echo "--- $pub: failed_key_vault_sign"; overall_rc=1; continue
        fi
      elif ! dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
           --root . "${artifact_files[@]}" --manifest "$manifest" --signature "$signature" \
           --keyfile signing-key.pem --key-id legacy-index-2026 --code-commit "$lex_code_commit" \
           --source "collection=$pub" --source "corpus_commit=$corpus_commit"; then
        echo "--- $pub: failed_manifest"; overall_rc=1; continue
      fi
      if ! dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
           --root . --manifest "$manifest" --signature "$signature" \
           --trust-roots lex/deploy/trusted-artifact-roots.json; then
        echo "--- $pub: failed_manifest_verify"; overall_rc=1; continue
      fi
      if [ "$pub" = "eu-eurlex" ]; then
        benchmark="retrieval-benchmark-$pub.json"
        manifest_id=$(sha256sum "$manifest" | cut -d' ' -f1)
        dotnet run --project lex/src/Lex.Ingest -c Release -- benchmark \
          --index "index-$pub.db" --vectors "index-$pub.vectors" --model-dir . \
          --out "$benchmark" --code-commit "$lex_code_commit" --manifest-id "$manifest_id" \
          --machine "github-actions-ubuntu-latest" \
          --resource "Container Apps Consumption target, 0.5 GiB configured limit" \
          --memory-limit-bytes 536870912
        benchmark_rc=$?
        if [ "$benchmark_rc" -ne 0 ] && [ "$benchmark_rc" -ne 5 ]; then
          echo "--- $pub: failed_benchmark"; overall_rc=1; continue
        fi
        # Exit 5 means the public activation gate did not pass. That is an expected, publishable
        # result while hybrid is gated, not permission to change the production default.
        benchmark_manifest="retrieval-benchmark-$pub.manifest.json"
        benchmark_signature="retrieval-benchmark-$pub.manifest.sig"
        if [ "$signing_mode" = "keyvault" ]; then
          if ! dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
               --root . --file "$benchmark" --manifest "$benchmark_manifest" \
               --key-id "$ARTIFACT_KEY_ID" --code-commit "$lex_code_commit" \
               --source "collection=$pub" --source "corpus_commit=$corpus_commit" \
               --source "index_manifest_sha256=$manifest_id"; then
            echo "--- $pub: failed_benchmark_manifest"; overall_rc=1; continue
          fi
          benchmark_digest=$(openssl dgst -sha256 -binary "$benchmark_manifest" | openssl base64 -A)
          if ! az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
               --algorithm ES256 --digest "$benchmark_digest" --query value -o tsv \
               > "$benchmark_signature"; then
            echo "--- $pub: failed_benchmark_key_vault_sign"; overall_rc=1; continue
          fi
        elif ! dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
             --root . --file "$benchmark" --manifest "$benchmark_manifest" \
             --signature "$benchmark_signature" --keyfile signing-key.pem \
             --key-id legacy-index-2026 --code-commit "$lex_code_commit" \
             --source "collection=$pub" --source "corpus_commit=$corpus_commit" \
             --source "index_manifest_sha256=$manifest_id"; then
          echo "--- $pub: failed_benchmark_manifest"; overall_rc=1; continue
        fi
        if ! dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
             --root . --manifest "$benchmark_manifest" --signature "$benchmark_signature" \
             --trust-roots lex/deploy/trusted-artifact-roots.json; then
          echo "--- $pub: failed_benchmark_manifest_verify"; overall_rc=1; continue
        fi
        release_assets+=("$benchmark" "$benchmark_manifest" "$benchmark_signature")
      fi
      tag="corpus-$(date -u +%F)"
      release_assets+=("$manifest" "$signature")
      if gh release create "$tag" "${release_assets[@]}" --repo "$repo" \
           --title "index-$pub $(date -u +%F)" \
           --notes "Signed index and whole-release manifest. Verify against the public key pinned by Lex before use. Free to download and use; redistribution of any build reserved (NOTICE layer 2)." \
         || gh release upload "$tag" "${release_assets[@]}" --repo "$repo" --clobber; then
        published_artifacts=1
      else
        echo "--- $pub: failed_release"
        overall_rc=1
      fi
    else
      echo "--- $pub: failed_index"; overall_rc=1
    fi
  done < .index-queue
  rm -f .index-queue

  # Deployment remains explicitly gated during the migration. Once the Lex production OIDC
  # environment exists, setting this repository variable to 1 turns a verified publication into
  # an immutable image and candidate revision instead of leaving production one release behind.
  if [ "$published_artifacts" = "1" ] && [ "${DEPLOY_AFTER_PUBLISH:-0}" = "1" ]; then
    gh api repos/SFHAJJI/lex/dispatches -X POST \
      -f event_type=verified_artifact_release \
      -F 'client_payload[require_manifest]=true' \
      || { echo "--- deploy dispatch failed"; overall_rc=1; }
  fi
fi

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
