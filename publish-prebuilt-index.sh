#!/usr/bin/env bash
# Promote a completed local/self-hosted index without weakening the release trust boundary.
# Staging bytes are hash-pinned by the dispatch, revalidated by the OIDC runner, covered by a
# Key Vault signature, benchmarked, and only then copied to immutable runtime releases.
set -euo pipefail

: "${PUBLISHER:?PUBLISHER is required}"
: "${STAGING_PREFIX:?STAGING_PREFIX is required}"
: "${QUEUE_COMMIT:?QUEUE_COMMIT is required}"
: "${CORPUS_COMMIT:?CORPUS_COMMIT is required}"
: "${BUILD_CODE_COMMIT:?BUILD_CODE_COMMIT is required}"
: "${ARTICLES_COMMIT:?ARTICLES_COMMIT is required}"
: "${EXPECTED_INDEX_SHA256:?EXPECTED_INDEX_SHA256 is required}"
: "${EXPECTED_VECTORS_SHA256:?EXPECTED_VECTORS_SHA256 is required}"
: "${ARTIFACT_KEY_ID:?ARTIFACT_KEY_ID is required}"
: "${AZURE_INDEX_STORAGE_ACCOUNT:?AZURE_INDEX_STORAGE_ACCOUNT is required}"
: "${AZURE_KEY_VAULT:?AZURE_KEY_VAULT is required}"
: "${AZURE_KEY_NAME:?AZURE_KEY_NAME is required}"

[[ "$STAGING_PREFIX" =~ ^staging/[a-z0-9-]+/[A-Za-z0-9._/-]+$ ]] \
  || { echo "ERROR: unsafe staging prefix" >&2; exit 2; }
[[ "$QUEUE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: queue commit must be a full lowercase SHA" >&2; exit 2; }
[[ "$CORPUS_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: corpus commit must be a full lowercase SHA" >&2; exit 2; }
[[ "$BUILD_CODE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: build code commit must be a full lowercase SHA" >&2; exit 2; }
[[ "$ARTICLES_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: articles commit must be a full lowercase SHA" >&2; exit 2; }
[[ "$EXPECTED_INDEX_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "ERROR: invalid index SHA-256" >&2; exit 2; }
[[ "$EXPECTED_VECTORS_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "ERROR: invalid vector SHA-256" >&2; exit 2; }
repo=$(jq -er --arg pub "$PUBLISHER" \
  '.publishers[] | select(.enabled and .id == $pub) | .corpus_repo' publishers.json)

git cat-file -e "$QUEUE_COMMIT^{commit}" 2>/dev/null \
  || { echo "ERROR: queue commit is not present" >&2; exit 2; }
git merge-base --is-ancestor "$QUEUE_COMMIT" refs/remotes/origin/main \
  || { echo "ERROR: queue commit is not on the current main history" >&2; exit 2; }
ticket=$(git show "$QUEUE_COMMIT:status/index-queue.json")
printf '%s' "$ticket" | jq -e --arg pub "$PUBLISHER" --arg repo "$repo" \
  --arg corpus "$CORPUS_COMMIT" --arg code "$BUILD_CODE_COMMIT" \
  --arg articles "$ARTICLES_COMMIT" \
  '.schema == "lex-index-build-queue/1"
   and .mode == "prebuilt"
   and .build_code_commit == $code
   and .articles_commit == $articles
   and ([.entries[] | select(.collection == $pub and .corpus_repo == $repo
          and .corpus_commit == $corpus)] | length == 1)' >/dev/null \
  || { echo "ERROR: publication inputs do not match the immutable build ticket" >&2; exit 2; }

# The checked-out Lex tree supplies the publication tooling. The index itself may have been built
# earlier, so preserve both commits rather than relabelling old bytes with today's source revision.
publication_tool_commit=$(git -C lex rev-parse HEAD)
[ "$publication_tool_commit" = "$BUILD_CODE_COMMIT" ] \
  || { echo "ERROR: publication tooling does not match the ticketed Lex commit" >&2; exit 2; }

index="index-$PUBLISHER.db"
vectors="index-$PUBLISHER.vectors"
manifest="index-$PUBLISHER.manifest.json"
signature="index-$PUBLISHER.manifest.sig"
stamp=$(date -u +%FT%TZ)

echo "=== download hash-pinned prebuilt artifacts ==="
for asset in "$index" "$vectors"; do
  az storage blob download --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$STAGING_PREFIX/$asset" --file "$asset" --overwrite true >/dev/null
done
printf '%s  %s\n%s  %s\n' "$EXPECTED_INDEX_SHA256" "$index" \
  "$EXPECTED_VECTORS_SHA256" "$vectors" | sha256sum -c -

echo "=== resolve exact corpus and pinned embedding runtime ==="
git clone --filter=blob:none "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" corpus
git -C corpus checkout --detach "$CORPUS_COMMIT"
test "$(git -C corpus rev-parse HEAD)" = "$CORPUS_COMMIT"
git clone --filter=blob:none \
  "https://x-access-token:${GH_TOKEN}@github.com/SFHAJJI/lex-articles.git" articles-ticket
git -C articles-ticket checkout --detach "$ARTICLES_COMMIT"
test "$(git -C articles-ticket rev-parse HEAD)" = "$ARTICLES_COMMIT"

cp lex/deploy/embedding-model/model-manifest.json model-manifest.json
model_revision=$(jq -r .revision model-manifest.json)
model_sha=$(jq -r '.files["model.onnx"]' model-manifest.json)
tokenizer_sha=$(jq -r '.files["sentencepiece.bpe.model"]' model-manifest.json)
model_base="https://huggingface.co/intfloat/multilingual-e5-small/resolve/$model_revision"
curl -fsSL --retry 3 --retry-delay 5 -o model.onnx \
  "$model_base/onnx/model_qint8_avx512_vnni.onnx"
curl -fsSL --retry 3 --retry-delay 5 -o sentencepiece.bpe.model \
  "$model_base/sentencepiece.bpe.model"
printf '%s  %s\n%s  %s\n' "$model_sha" model.onnx \
  "$tokenizer_sha" sentencepiece.bpe.model | sha256sum -c -
dotnet run --project lex/src/Lex.Ingest -c Release -- embedding-smoke \
  --model-dir . --text "protection des donnees personnelles"

artifact_files=(--file "$index" --file "$vectors" --file model-manifest.json \
  --file model.onnx --file sentencepiece.bpe.model)
release_assets=("$index" "$vectors" model-manifest.json model.onnx sentencepiece.bpe.model)
verify_stamp_args=(--db "$index" --expected-collection "$PUBLISHER" \
  --expected-corpus-commit "$CORPUS_COMMIT" \
  --expected-code-commit "$BUILD_CODE_COMMIT" \
  --expected-articles-commit "$ARTICLES_COMMIT")
if [ "$PUBLISHER" = "eu-eurlex" ]; then
  cp lex/src/Lex.Sources.EurLex/eu-scope.json eu-scope.json
  cp lex/config/eu-work-enrichment.json eu-work-enrichment.json
  verify_stamp_args+=(--work-enrichment eu-work-enrichment.json)
  artifact_files+=(--file eu-scope.json --file eu-work-enrichment.json)
  release_assets+=(eu-scope.json eu-work-enrichment.json)
fi
dotnet run --project lex/src/Lex.Ingest -c Release -- verify stamp \
  "${verify_stamp_args[@]}"

echo "=== create and verify Key Vault-signed whole-artifact manifest ==="
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
  --root . "${artifact_files[@]}" --manifest "$manifest" \
  --key-id "$ARTIFACT_KEY_ID" --code-commit "$BUILD_CODE_COMMIT" \
  --source "collection=$PUBLISHER" --source "corpus_commit=$CORPUS_COMMIT" \
  --source "articles_commit=$ARTICLES_COMMIT" --source "queue_commit=$QUEUE_COMMIT" \
  --source "publication_tool_commit=$publication_tool_commit" \
  --source "build_origin=hash-pinned-private-staging"
digest=$(openssl dgst -sha256 -binary "$manifest" | openssl base64 -A)
az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
  --algorithm ES256 --digest "$digest" -o json \
  | jq -er 'if type == "string" then . else (.signature // .value // .result) end' \
  > "$signature"
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
  --root . --manifest "$manifest" --signature "$signature" \
  --trust-roots lex/deploy/trusted-artifact-roots.json
manifest_id=$(sha256sum "$manifest" | cut -d' ' -f1)

echo "=== benchmark retrieval (a gated result is publishable) ==="
benchmark="retrieval-benchmark-$PUBLISHER.json"
set +e
dotnet run --project lex/src/Lex.Ingest -c Release -- benchmark \
    --index "$index" --vectors "$vectors" --model-dir . --out "$benchmark" \
    --code-commit "$publication_tool_commit" --manifest-id "$manifest_id" \
    --machine github-actions-ubuntu-latest \
    --resource "Container Apps Consumption target, 2 GiB configured limit" \
    --memory-limit-bytes 2147483648
benchmark_rc=$?
set -e
[ "$benchmark_rc" -eq 0 ] || [ "$benchmark_rc" -eq 5 ] \
  || { echo "ERROR: benchmark execution failed ($benchmark_rc)" >&2; exit "$benchmark_rc"; }

benchmark_manifest="retrieval-benchmark-$PUBLISHER.manifest.json"
benchmark_signature="retrieval-benchmark-$PUBLISHER.manifest.sig"
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
    --root . --file "$benchmark" --manifest "$benchmark_manifest" \
    --key-id "$ARTIFACT_KEY_ID" --code-commit "$publication_tool_commit" \
    --source "collection=$PUBLISHER" --source "corpus_commit=$CORPUS_COMMIT" \
    --source "articles_commit=$ARTICLES_COMMIT" --source "queue_commit=$QUEUE_COMMIT" \
    --source "index_manifest_sha256=$manifest_id"
benchmark_digest=$(openssl dgst -sha256 -binary "$benchmark_manifest" | openssl base64 -A)
az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
    --algorithm ES256 --digest "$benchmark_digest" -o json \
    | jq -er 'if type == "string" then . else (.signature // .value // .result) end' \
    > "$benchmark_signature"
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
    --root . --manifest "$benchmark_manifest" --signature "$benchmark_signature" \
    --trust-roots lex/deploy/trusted-artifact-roots.json
release_assets+=("$benchmark" "$benchmark_manifest" "$benchmark_signature")

release_assets+=("$manifest" "$signature")

echo "=== publish immutable Blob release ==="
release_prefix="releases/$PUBLISHER/$manifest_id"
for asset in "${release_assets[@]}"; do
  sha=$(sha256sum "$asset" | cut -d' ' -f1)
  az storage blob upload --auth-mode login --only-show-errors --overwrite false \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$release_prefix/$(basename "$asset")" --file "$asset" \
    --metadata "sha256=$sha" >/dev/null
done
pointer=$(mktemp)
jq -n --arg pub "$PUBLISHER" --arg manifest "$manifest_id" \
  --arg prefix "$release_prefix" --arg corpus "$CORPUS_COMMIT" --arg published "$stamp" \
  '{schema:"lex-artifact-pointer/1",collection:$pub,manifest_sha256:$manifest,
    prefix:$prefix,corpus_commit:$corpus,published_at:$published}' > "$pointer"
az storage blob upload --auth-mode login --only-show-errors --overwrite true \
  --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
  --name "current/$PUBLISHER.json" --file "$pointer" >/dev/null
rm -f "$pointer"

echo "=== publish public GitHub release ==="
tag="corpus-$(date -u +%F)"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" "${release_assets[@]}" --repo "$repo" --clobber
else
  gh release create "$tag" "${release_assets[@]}" --repo "$repo" \
    --title "index-$PUBLISHER $(date -u +%F)" \
    --notes "Signed index and whole-release manifest. Verify against the public key pinned by Lex before use. Free to download and use; redistribution of any build reserved (NOTICE layer 2)."
fi

if [ "${DEPLOY_AFTER_PUBLISH:-0}" = "1" ]; then
  gh api repos/SFHAJJI/lex/dispatches -X POST \
    -f event_type=verified_artifact_release \
    -F 'client_payload[require_manifest]=true' \
    -F 'client_payload[promote]=false'
fi

echo "published_manifest=$manifest_id"
