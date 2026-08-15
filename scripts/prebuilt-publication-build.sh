# Build and sign one deterministic release bundle from the already-validated staging snapshot.
resolve_sources_and_build_bundle() {
  local corpus_root="$work_root/corpus" articles_root="$work_root/articles-ticket"
  local source_configuration=- model_revision model_sha tokenizer_sha model_base
  local manifest_id benchmark_rc asset_inventory asset_size
  git clone --filter=blob:none "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$corpus_root"
  git -C "$corpus_root" checkout --detach "$CORPUS_COMMIT"
  [ "$(git -C "$corpus_root" rev-parse HEAD)" = "$CORPUS_COMMIT" ]
  bash require-ancestor.sh "$corpus_root" "$CORPUS_COMMIT" \
    refs/remotes/origin/main "ticketed corpus commit"
  if [ "$previous_pointer_exists" = true ]; then
    git -C "$corpus_root" cat-file -e "$previous_corpus_commit^{commit}"
    git -C "$corpus_root" merge-base --is-ancestor "$previous_corpus_commit" "$CORPUS_COMMIT" \
      || { echo "ERROR: refusing non-monotonic corpus pointer rollback" >&2; return 1; }
  fi
  git clone --filter=blob:none \
    "https://x-access-token:${GH_TOKEN}@github.com/SFHAJJI/lex-articles.git" "$articles_root"
  git -C "$articles_root" checkout --detach "$ARTICLES_COMMIT"
  [ "$(git -C "$articles_root" rev-parse HEAD)" = "$ARTICLES_COMMIT" ]
  bash require-ancestor.sh "$articles_root" "$ARTICLES_COMMIT" \
    refs/remotes/origin/main "ticketed articles commit"
  if [ "$PUBLISHER" = eu-eurlex ]; then
    source_configuration="$lex_root/src/Lex.Sources.EurLex/eu-scope.json"
  fi
  bash "$ops_root/scripts/v4-release-contract.sh" validate-source "$ticket_file" \
    "$PUBLISHER" "$repo" "$CORPUS_COMMIT" "$BUILD_CODE_COMMIT" "$ARTICLES_COMMIT" \
    "$corpus_root/manifest.json" "$articles_root/generation.json" "$source_configuration"

  cp "$lex_root/deploy/embedding-model/model-manifest.json" "$work_root/model-manifest.json"
  model_revision=$(jq -r .revision "$work_root/model-manifest.json")
  model_sha=$(jq -r '.files["model.onnx"]' "$work_root/model-manifest.json")
  tokenizer_sha=$(jq -r '.files["sentencepiece.bpe.model"]' "$work_root/model-manifest.json")
  model_base="https://huggingface.co/intfloat/multilingual-e5-small/resolve/$model_revision"
  curl -fsSL --retry 3 --retry-delay 5 -o "$work_root/model.onnx" \
    "$model_base/onnx/model_qint8_avx512_vnni.onnx"
  curl -fsSL --retry 3 --retry-delay 5 -o "$work_root/sentencepiece.bpe.model" \
    "$model_base/sentencepiece.bpe.model"
  printf '%s  %s\n%s  %s\n' "$model_sha" "$work_root/model.onnx" \
    "$tokenizer_sha" "$work_root/sentencepiece.bpe.model" | sha256sum -c -
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- embedding-smoke \
    --model-dir "$work_root" --text "protection des donnees personnelles"

  artifact_files=(--file "$index" --file "$vectors" --file model-manifest.json \
    --file model.onnx --file sentencepiece.bpe.model)
  release_assets=("$index" "$vectors" model-manifest.json model.onnx sentencepiece.bpe.model)
  if [ "$PUBLISHER" = eu-eurlex ]; then
    cp "$lex_root/src/Lex.Sources.EurLex/eu-scope.json" "$work_root/eu-scope.json"
    artifact_files+=(--file eu-scope.json)
    release_assets+=(eu-scope.json)
  fi
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- verify stamp \
    --db "$work_root/$index" --expected-collection "$PUBLISHER" \
    --expected-corpus-commit "$CORPUS_COMMIT" --expected-code-commit "$BUILD_CODE_COMMIT" \
    --expected-articles-commit "$ARTICLES_COMMIT" \
    --corpus-manifest "$corpus_root/manifest.json" \
    --articles-generation "$articles_root/generation.json"

  echo "=== create versioned Key Vault-signed whole-artifact manifest ==="
  (
    cd "$work_root"
    dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact manifest \
      --root . "${artifact_files[@]}" --manifest "$manifest" --now "$stamp" \
      --key-id "$ARTIFACT_KEY_ID" --code-commit "$BUILD_CODE_COMMIT" \
      --source "collection=$PUBLISHER" --source "corpus_commit=$CORPUS_COMMIT" \
      --source "articles_commit=$ARTICLES_COMMIT" --source "queue_ticket_id=$ticket_id" \
      --source "publication_tool_commit=$publication_tool_commit" \
      --source "index_sha256=$EXPECTED_INDEX_SHA256" \
      --source "vectors_sha256=$EXPECTED_VECTORS_SHA256" \
      --source "build_origin=exact-private-staging-snapshot"
  )
  sign_manifest "$work_root/$manifest" "$work_root/$signature"
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$work_root" --manifest "$work_root/$manifest" --signature "$work_root/$signature" \
    --trust-roots "$single_trust_roots"
  manifest_id=$(sha256_file "$work_root/$manifest")

  echo "=== benchmark retrieval and derive signed semantic activation ==="
  set +e
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- benchmark \
    --index "$work_root/$index" --vectors "$work_root/$vectors" --model-dir "$work_root" \
    --out "$work_root/$benchmark" --now "$stamp" --code-commit "$publication_tool_commit" \
    --manifest-id "$manifest_id" --machine github-actions-ubuntu-latest \
    --resource "Container Apps Consumption target, 2 GiB configured limit" \
    --memory-limit-bytes 2147483648
  benchmark_rc=$?
  set -e
  [ "$benchmark_rc" -eq 0 ] \
    || { echo "ERROR: semantic quarantine publication is disabled until runtime enforcement is pinned ($benchmark_rc)" >&2; return "$benchmark_rc"; }
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-benchmark \
    "$work_root/$benchmark" "$PUBLISHER" "$publication_tool_commit" "$CORPUS_COMMIT" \
    "$manifest_id" "$EXPECTED_INDEX_SIZE" "$EXPECTED_VECTORS_SIZE"
  semantic_activation=$(jq -er .activation_gate_passed "$work_root/$benchmark")

  (
    cd "$work_root"
    dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact manifest \
      --root . --file "$benchmark" --manifest "$benchmark_manifest" --now "$stamp" \
      --key-id "$ARTIFACT_KEY_ID" --code-commit "$publication_tool_commit" \
      --source "collection=$PUBLISHER" --source "corpus_commit=$CORPUS_COMMIT" \
      --source "queue_ticket_id=$ticket_id" --source "index_manifest_sha256=$manifest_id" \
      --source "semantic_activation=$semantic_activation"
  )
  sign_manifest "$work_root/$benchmark_manifest" "$work_root/$benchmark_signature"
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$work_root" --manifest "$work_root/$benchmark_manifest" \
    --signature "$work_root/$benchmark_signature" --trust-roots "$single_trust_roots"
  release_assets+=("$benchmark" "$benchmark_manifest" "$benchmark_signature" "$manifest" "$signature")

  asset_inventory="$work_root/public-assets.jsonl"
  : > "$asset_inventory"
  for asset in "${release_assets[@]}"; do
    asset_size=$(size_file "$work_root/$asset")
    [ "$asset_size" -lt 2147483648 ] \
      || { echo "ERROR: GitHub-only publication rejects assets at or above 2 GiB: $asset" >&2; return 1; }
    jq -cn --arg name "$asset" --arg sha "$(sha256_file "$work_root/$asset")" \
      --argjson size "$asset_size" \
      '{name:$name,sha256:$sha,size:$size}' >> "$asset_inventory"
  done
  jq -cS -n --arg publisher "$PUBLISHER" --arg ticket "$ticket_id" \
    --arg queue "$QUEUE_COMMIT" --arg workflow "$WORKFLOW_COMMIT" --arg run "$GITHUB_RUN_ID" \
    --arg corpus "$CORPUS_COMMIT" --arg code "$BUILD_CODE_COMMIT" \
    --arg articles "$ARTICLES_COMMIT" --arg prefix "$STAGING_PREFIX" \
    --arg index "$STAGING_PREFIX/$index" --arg index_etag "$EXPECTED_INDEX_ETAG" \
    --arg index_sha "$EXPECTED_INDEX_SHA256" --argjson index_size "$EXPECTED_INDEX_SIZE" \
    --arg vectors "$STAGING_PREFIX/$vectors" --arg vectors_etag "$EXPECTED_VECTORS_ETAG" \
    --arg vectors_sha "$EXPECTED_VECTORS_SHA256" --argjson vectors_size "$EXPECTED_VECTORS_SIZE" \
    --arg manifest "$manifest_id" --arg benchmark_manifest "$(sha256_file "$work_root/$benchmark_manifest")" \
    --arg repository "$repo" \
    --argjson semantic "$semantic_activation" --arg tag "$tag" --arg generated "$stamp" \
    --argjson previous_exists "$previous_pointer_exists" --arg previous_etag "$previous_pointer_etag" \
    --arg previous_sha "$previous_pointer_sha" --slurpfile assets "$asset_inventory" '
      {schema:"lex-staging-cleanup-receipt/2",purpose:"delete-exact-published-prebuilt-staging",
       generated_at:$generated,publisher:$publisher,queue_ticket_id:$ticket,queue_commit:$queue,
       workflow_commit:$workflow,run_id:$run,corpus_commit:$corpus,build_code_commit:$code,
       articles_commit:$articles,staging_prefix:$prefix,release_tag:$tag,
       release_repository:$repository,
       index_manifest_sha256:$manifest,benchmark_manifest_sha256:$benchmark_manifest,
       semantic_activation:$semantic,
       staging:{index:{name:$index,etag:$index_etag,sha256:$index_sha,size:$index_size},
         vectors:{name:$vectors,etag:$vectors_etag,sha256:$vectors_sha,size:$vectors_size}},
       previous_pointer:{exists:$previous_exists,
         etag:(if $previous_exists then $previous_etag else null end),
         sha256:(if $previous_exists then $previous_sha else null end)},public_assets:$assets}
    ' > "$work_root/$cleanup_receipt"
  (
    cd "$work_root"
    dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact manifest \
      --root . --file "$cleanup_receipt" --manifest "$cleanup_manifest" --now "$stamp" \
      --key-id "$ARTIFACT_KEY_ID" --code-commit "$BUILD_CODE_COMMIT" \
      --source "purpose=delete-exact-published-prebuilt-staging" \
      --source "publisher=$PUBLISHER" --source "queue_ticket_id=$ticket_id" \
      --source "release_repository=$repo" \
      --source "workflow_commit=$WORKFLOW_COMMIT" --source "run_id=$GITHUB_RUN_ID" \
      --source "index_manifest_sha256=$manifest_id" \
      --source "semantic_activation=$semantic_activation"
  )
  sign_manifest "$work_root/$cleanup_manifest" "$work_root/$cleanup_signature"
  release_assets+=("$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature")
  bundle_root="$work_root"
}
