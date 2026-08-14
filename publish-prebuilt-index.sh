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
: "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required}"
: "${AZURE_TENANT_ID:?AZURE_TENANT_ID is required}"
: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

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

git fetch --no-tags origin \
  +refs/heads/fleet-status:refs/remotes/origin/fleet-status
bash require-ancestor.sh . "$QUEUE_COMMIT" refs/remotes/origin/fleet-status "queue commit"
ticket_file=$(mktemp)
git show "$QUEUE_COMMIT:status/index-queue.json" > "$ticket_file"
bash scripts/v4-release-contract.sh validate-ticket "$ticket_file"
ticket_id=$(jq -er .ticket_id "$ticket_file")
jq -e --arg pub "$PUBLISHER" --arg repo "$repo" \
  --arg corpus "$CORPUS_COMMIT" --arg code "$BUILD_CODE_COMMIT" \
  --arg articles "$ARTICLES_COMMIT" \
  '.mode == "prebuilt"
   and .build_code_commit == $code
   and .articles_commit == $articles
   and ([.entries[] | select(.collection == $pub and .corpus_repo == $repo
          and .corpus_commit == $corpus)] | length == 1)' "$ticket_file" >/dev/null \
  || { echo "ERROR: publication inputs do not match the immutable build ticket" >&2; exit 2; }

# The checked-out Lex tree supplies the publication tooling. The index itself may have been built
# earlier, so preserve both commits rather than relabelling old bytes with today's source revision.
publication_tool_commit=$(git -C lex rev-parse HEAD)
[ "$publication_tool_commit" = "$BUILD_CODE_COMMIT" ] \
  || { echo "ERROR: publication tooling does not match the ticketed Lex commit" >&2; exit 2; }
git -C lex fetch --no-tags origin main
bash require-ancestor.sh lex "$BUILD_CODE_COMMIT" refs/remotes/origin/main "ticketed Lex commit"
. lex/scripts/deploy/az-reauth.sh
. lex/scripts/deploy/az-retry.sh

index="index-$PUBLISHER.db"
vectors="index-$PUBLISHER.vectors"
manifest="index-$PUBLISHER.manifest.json"
signature="index-$PUBLISHER.manifest.sig"
cleanup_receipt="staging-cleanup-$PUBLISHER.json"
cleanup_manifest="staging-cleanup-$PUBLISHER.manifest.json"
cleanup_signature="staging-cleanup-$PUBLISHER.manifest.sig"
tag="index-$PUBLISHER-$ticket_id"
stamp=$(date -u +%FT%TZ)

cleanup_exact_blob() {
  local name="$1" expected_etag="$2" exists observed
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query exists -o tsv)
  [ "$exists" = "true" ] || { [ "$exists" = "false" ] && return 0; return 1; }
  observed=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query properties.etag -o tsv)
  [ "$observed" = "$expected_etag" ] \
    || { echo "ERROR: refusing to delete changed staging blob $name" >&2; return 1; }
  if ! az_retry az storage blob delete --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$name" --if-match "$expected_etag" >/dev/null; then
    # A transport failure can hide a successful delete. Only the exact absence read-back
    # converts that ambiguous result to success; a changed or still-present blob fails closed.
    exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$name" --query exists -o tsv)
    [ "$exists" = "false" ] || return 1
  fi
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query exists -o tsv)
  [ "$exists" = "false" ] \
    || { echo "ERROR: staging blob deletion did not converge for $name" >&2; return 1; }
}

verify_blob_asset() {
  local prefix="$1" name="$2" expected_sha="$3" expected_size="$4" remote
  remote=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$prefix/$name" \
    --query '{sha:metadata.sha256,size:properties.contentLength}' -o json)
  [ "$(printf '%s' "$remote" | jq -r .sha)" = "$expected_sha" ] \
    && [ "$(printf '%s' "$remote" | jq -r .size)" = "$expected_size" ] \
    || { echo "ERROR: immutable Blob release verification failed for $name" >&2; return 1; }
}

publish_pointer() {
  local manifest_id="$1" release_prefix="$2" published_at="$3"
  local expected_exists="$4" expected_etag="$5" expected_sha="$6"
  local pointer readback current_exists current_etag current_sha
  local -a condition
  pointer=$(mktemp)
  readback=$(mktemp)
  jq -cS -n --arg pub "$PUBLISHER" --arg manifest "$manifest_id" \
    --arg prefix "$release_prefix" --arg corpus "$CORPUS_COMMIT" \
    --arg published "$published_at" \
    '{schema:"lex-artifact-pointer/1",collection:$pub,manifest_sha256:$manifest,
      prefix:$prefix,corpus_commit:$corpus,published_at:$published}' > "$pointer"
  current_exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --query exists -o tsv)
  if [ "$current_exists" = "true" ]; then
    current_etag=$(az_retry az storage blob show --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "current/$PUBLISHER.json" --query properties.etag -o tsv)
    az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "current/$PUBLISHER.json" --file "$readback" \
      --if-match "$current_etag" >/dev/null
    if cmp -s "$pointer" "$readback"; then
      rm -f "$pointer" "$readback"
      return 0
    fi
    current_sha=$(sha256sum "$readback" | cut -d' ' -f1)
    [ "$expected_exists" = "true" ] \
      && [ "$current_etag" = "$expected_etag" ] \
      && [ "$current_sha" = "$expected_sha" ] \
      || { echo "ERROR: refusing to replace a changed current artifact pointer" >&2; return 1; }
    condition=(--if-match "$expected_etag")
  else
    [ "$current_exists" = "false" ] && [ "$expected_exists" = "false" ] \
      || { echo "ERROR: current artifact pointer existence changed" >&2; return 1; }
    condition=(--if-none-match '*')
  fi
  if ! az_retry az storage blob upload --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "current/$PUBLISHER.json" --file "$pointer" "${condition[@]}" >/dev/null; then
    echo "pointer update returned ambiguously; requiring exact desired read-back" >&2
  fi
  current_etag=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --query properties.etag -o tsv)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --file "$readback" --if-match "$current_etag" >/dev/null
  cmp -s "$pointer" "$readback" \
    || { echo "ERROR: current artifact pointer read-back differs" >&2; return 1; }
  rm -f "$pointer" "$readback"
}

# A cancellation can occur between the two exact ETag deletes. A finalized public release is an
# immutable retry marker: verify its dedicated signed cleanup receipt and every core public asset,
# then finish only the still-present allowlisted blob. This path never rebuilds or mutates a release.
if public_state=$(gh release view "$tag" --repo "$repo" \
    --json isDraft,isPrerelease,tagName,assets 2>/dev/null) \
    && printf '%s' "$public_state" | jq -e --arg tag "$tag" \
      '.tagName == $tag and .isDraft == false and .isPrerelease == false' >/dev/null; then
  retry_dir=$(mktemp -d)
  retry_dir=$(realpath "$retry_dir")
  temporary_root=$(realpath "${TMPDIR:-/tmp}")
  case "$retry_dir" in
    "$temporary_root"/*) ;;
    *) echo "ERROR: cleanup retry directory is outside the temporary root" >&2; exit 1 ;;
  esac
  for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
    curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
      "https://github.com/$repo/releases/download/$tag/$asset" -o "$retry_dir/$asset"
  done
  dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
    --root "$retry_dir" --manifest "$retry_dir/$cleanup_manifest" \
    --signature "$retry_dir/$cleanup_signature" \
    --trust-roots lex/deploy/trusted-artifact-roots.json
  jq -e --arg publisher "$PUBLISHER" --arg ticket "$ticket_id" \
      --arg corpus "$CORPUS_COMMIT" --arg code "$BUILD_CODE_COMMIT" \
      --arg articles "$ARTICLES_COMMIT" --arg prefix "$STAGING_PREFIX" \
      --arg index "$STAGING_PREFIX/$index" --arg vectors "$STAGING_PREFIX/$vectors" \
      --arg index_asset "$index" --arg vectors_asset "$vectors" \
      --arg manifest_asset "$manifest" --arg signature_asset "$signature" \
      --arg cleanup_receipt "$cleanup_receipt" --arg cleanup_manifest "$cleanup_manifest" \
      --arg cleanup_signature "$cleanup_signature" \
      --arg index_sha "$EXPECTED_INDEX_SHA256" \
      --arg vectors_sha "$EXPECTED_VECTORS_SHA256" --arg tag "$tag" '
        .schema == "lex-staging-cleanup-receipt/1"
        and .purpose == "delete-exact-published-prebuilt-staging"
        and .publisher == $publisher and .queue_ticket_id == $ticket
        and .corpus_commit == $corpus and .build_code_commit == $code
        and .articles_commit == $articles and .staging_prefix == $prefix
        and .release_tag == $tag
        and .staging.index.name == $index and .staging.index.sha256 == $index_sha
        and .staging.vectors.name == $vectors
        and .staging.vectors.sha256 == $vectors_sha
        and (.staging.index.etag | type == "string" and length > 0)
        and (.staging.vectors.etag | type == "string" and length > 0)
        and (.index_manifest_sha256 | test("^[0-9a-f]{64}$"))
        and (.generated_at | type == "string" and fromdateiso8601 > 0)
        and (.public_assets | type == "array" and length > 0)
        and ([.public_assets[].name] | unique | length) == (.public_assets | length)
        and ([.public_assets[] | select(.name == $index_asset and .sha256 == $index_sha)] | length == 1)
        and ([.public_assets[] | select(.name == $vectors_asset and .sha256 == $vectors_sha)] | length == 1)
        and (.index_manifest_sha256 as $manifest_sha
          | ([.public_assets[] | select(.name == $manifest_asset and .sha256 == $manifest_sha)] | length == 1))
        and ([.public_assets[] | select(.name == $signature_asset)] | length == 1)
        and ([.public_assets[] | select(.name == $cleanup_receipt
          or .name == $cleanup_manifest or .name == $cleanup_signature)] | length == 0)
        and (.previous_pointer | type == "object")
        and ((.previous_pointer.exists == true
              and (.previous_pointer.etag | type == "string" and length > 0)
              and (.previous_pointer.sha256 | test("^[0-9a-f]{64}$")))
          or (.previous_pointer.exists == false
              and .previous_pointer.etag == null and .previous_pointer.sha256 == null))
        and all(.public_assets[];
          (.name | test("^[A-Za-z0-9._-]+$"))
          and (.sha256 | test("^[0-9a-f]{64}$"))
          and (.size | type == "number" and . >= 0))' \
    "$retry_dir/$cleanup_receipt" >/dev/null \
    || { echo "ERROR: signed staging cleanup retry receipt is invalid" >&2; exit 2; }
  expected_retry_assets=$(
    {
      jq -r '.public_assets[].name' "$retry_dir/$cleanup_receipt"
      printf '%s\n' "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"
    } | sort | jq -Rsc 'split("\n") | map(select(length > 0))'
  )
  public_state=$(gh release view "$tag" --repo "$repo" \
    --json isDraft,isPrerelease,tagName,assets)
  printf '%s' "$public_state" | jq -e --arg tag "$tag" \
      --argjson expected "$expected_retry_assets" '
        .tagName == $tag and .isDraft == false and .isPrerelease == false
        and ([.assets[].name] | sort) == $expected' >/dev/null \
    || { echo "ERROR: public release retry asset inventory is not exact" >&2; exit 1; }
  while IFS= read -r item; do
    name=$(printf '%s' "$item" | jq -r .name)
    expected_sha=$(printf '%s' "$item" | jq -r .sha256)
    expected_size=$(printf '%s' "$item" | jq -r .size)
    curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
      "https://github.com/$repo/releases/download/$tag/$name" -o "$retry_dir/$name"
    [ "$(sha256sum "$retry_dir/$name" | cut -d' ' -f1)" = "$expected_sha" ] \
      && [ "$(wc -c < "$retry_dir/$name" | tr -d ' ')" = "$expected_size" ] \
      || { echo "ERROR: public release retry read-back differs for $name" >&2; exit 1; }
  done < <(jq -c '.public_assets[]' "$retry_dir/$cleanup_receipt")
  manifest_id=$(jq -r .index_manifest_sha256 "$retry_dir/$cleanup_receipt")
  release_prefix="releases/$PUBLISHER/$manifest_id"
  while IFS= read -r item; do
    verify_blob_asset "$release_prefix" \
      "$(printf '%s' "$item" | jq -r .name)" \
      "$(printf '%s' "$item" | jq -r .sha256)" \
      "$(printf '%s' "$item" | jq -r .size)"
  done < <(jq -c '.public_assets[]' "$retry_dir/$cleanup_receipt")
  for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
    verify_blob_asset "$release_prefix" "$asset" \
      "$(sha256sum "$retry_dir/$asset" | cut -d' ' -f1)" \
      "$(wc -c < "$retry_dir/$asset" | tr -d ' ')"
  done
  publish_pointer "$manifest_id" "$release_prefix" \
    "$(jq -r .generated_at "$retry_dir/$cleanup_receipt")" \
    "$(jq -r .previous_pointer.exists "$retry_dir/$cleanup_receipt")" \
    "$(jq -r '.previous_pointer.etag // ""' "$retry_dir/$cleanup_receipt")" \
    "$(jq -r '.previous_pointer.sha256 // ""' "$retry_dir/$cleanup_receipt")"
  cleanup_exact_blob "$STAGING_PREFIX/$index" \
    "$(jq -r .staging.index.etag "$retry_dir/$cleanup_receipt")"
  cleanup_exact_blob "$STAGING_PREFIX/$vectors" \
    "$(jq -r .staging.vectors.etag "$retry_dir/$cleanup_receipt")"
  rm -r -- "$retry_dir"
  echo "published_manifest=$manifest_id"
  exit 0
fi

echo "=== snapshot current artifact pointer ==="
previous_pointer_file=$(mktemp)
previous_pointer_exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
  --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
  --name "current/$PUBLISHER.json" --query exists -o tsv)
if [ "$previous_pointer_exists" = "true" ]; then
  previous_pointer_etag=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --query properties.etag -o tsv)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --file "$previous_pointer_file" \
    --if-match "$previous_pointer_etag" >/dev/null
  previous_pointer_sha=$(sha256sum "$previous_pointer_file" | cut -d' ' -f1)
else
  [ "$previous_pointer_exists" = "false" ] \
    || { echo "ERROR: current artifact pointer existence is malformed" >&2; exit 1; }
  previous_pointer_etag=""
  previous_pointer_sha=""
fi
rm -f "$previous_pointer_file"

echo "=== download hash-pinned prebuilt artifacts ==="
index_etag=$(az_retry az storage blob show --auth-mode login --only-show-errors \
  --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
  --name "$STAGING_PREFIX/$index" --query properties.etag -o tsv)
vectors_etag=$(az_retry az storage blob show --auth-mode login --only-show-errors \
  --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
  --name "$STAGING_PREFIX/$vectors" --query properties.etag -o tsv)
[ -n "$index_etag" ] && [ -n "$vectors_etag" ] \
  || { echo "ERROR: staging inputs have no stable ETag" >&2; exit 1; }
for asset in "$index" "$vectors"; do
  etag="$index_etag"
  [ "$asset" = "$index" ] || etag="$vectors_etag"
  az_retry az storage blob download --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$STAGING_PREFIX/$asset" --file "$asset" --overwrite true \
    --if-match "$etag" >/dev/null
done
printf '%s  %s\n%s  %s\n' "$EXPECTED_INDEX_SHA256" "$index" \
  "$EXPECTED_VECTORS_SHA256" "$vectors" | sha256sum -c -

echo "=== resolve exact corpus and pinned embedding runtime ==="
git clone --filter=blob:none "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" corpus
git -C corpus checkout --detach "$CORPUS_COMMIT"
test "$(git -C corpus rev-parse HEAD)" = "$CORPUS_COMMIT"
bash require-ancestor.sh corpus "$CORPUS_COMMIT" refs/remotes/origin/main "ticketed corpus commit"
git clone --filter=blob:none \
  "https://x-access-token:${GH_TOKEN}@github.com/SFHAJJI/lex-articles.git" articles-ticket
git -C articles-ticket checkout --detach "$ARTICLES_COMMIT"
test "$(git -C articles-ticket rev-parse HEAD)" = "$ARTICLES_COMMIT"
bash require-ancestor.sh articles-ticket "$ARTICLES_COMMIT" refs/remotes/origin/main \
  "ticketed articles commit"
source_configuration=-
[ "$PUBLISHER" = "eu-eurlex" ] \
  && source_configuration=lex/src/Lex.Sources.EurLex/eu-scope.json
bash scripts/v4-release-contract.sh validate-source "$ticket_file" "$PUBLISHER" "$repo" \
  "$CORPUS_COMMIT" "$BUILD_CODE_COMMIT" "$ARTICLES_COMMIT" \
  corpus/manifest.json articles-ticket/generation.json "$source_configuration"

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
  --expected-articles-commit "$ARTICLES_COMMIT" \
  --corpus-manifest corpus/manifest.json \
  --articles-generation articles-ticket/generation.json)
if [ "$PUBLISHER" = "eu-eurlex" ]; then
  cp lex/src/Lex.Sources.EurLex/eu-scope.json eu-scope.json
  artifact_files+=(--file eu-scope.json)
  release_assets+=(eu-scope.json)
fi
dotnet run --project lex/src/Lex.Ingest -c Release -- verify stamp \
  "${verify_stamp_args[@]}"

echo "=== create and verify Key Vault-signed whole-artifact manifest ==="
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
  --root . "${artifact_files[@]}" --manifest "$manifest" \
  --key-id "$ARTIFACT_KEY_ID" --code-commit "$BUILD_CODE_COMMIT" \
  --source "collection=$PUBLISHER" --source "corpus_commit=$CORPUS_COMMIT" \
  --source "articles_commit=$ARTICLES_COMMIT" --source "queue_ticket_id=$ticket_id" \
  --source "publication_tool_commit=$publication_tool_commit" \
  --source "build_origin=hash-pinned-private-staging"
digest=$(openssl dgst -sha256 -binary "$manifest" | openssl base64 -A)
az_retry az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
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
    --source "articles_commit=$ARTICLES_COMMIT" --source "queue_ticket_id=$ticket_id" \
    --source "index_manifest_sha256=$manifest_id"
benchmark_digest=$(openssl dgst -sha256 -binary "$benchmark_manifest" | openssl base64 -A)
az_retry az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
    --algorithm ES256 --digest "$benchmark_digest" -o json \
    | jq -er 'if type == "string" then . else (.signature // .value // .result) end' \
    > "$benchmark_signature"
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
    --root . --manifest "$benchmark_manifest" --signature "$benchmark_signature" \
    --trust-roots lex/deploy/trusted-artifact-roots.json
release_assets+=("$benchmark" "$benchmark_manifest" "$benchmark_signature")

release_assets+=("$manifest" "$signature")

echo "=== create signed exact staging-cleanup receipt ==="
asset_inventory=$(mktemp)
for asset in "${release_assets[@]}"; do
  jq -cn --arg name "$(basename "$asset")" \
    --arg sha "$(sha256sum "$asset" | cut -d' ' -f1)" \
    --argjson size "$(wc -c < "$asset" | tr -d ' ')" \
    '{name:$name,sha256:$sha,size:$size}' >> "$asset_inventory"
done
jq -cS -n --arg publisher "$PUBLISHER" --arg ticket "$ticket_id" \
  --arg corpus "$CORPUS_COMMIT" --arg code "$BUILD_CODE_COMMIT" \
  --arg articles "$ARTICLES_COMMIT" --arg prefix "$STAGING_PREFIX" \
  --arg index "$STAGING_PREFIX/$index" --arg index_etag "$index_etag" \
  --arg index_sha "$EXPECTED_INDEX_SHA256" \
  --arg vectors "$STAGING_PREFIX/$vectors" --arg vectors_etag "$vectors_etag" \
  --arg vectors_sha "$EXPECTED_VECTORS_SHA256" --arg manifest "$manifest_id" \
  --arg tag "$tag" --arg generated "$stamp" \
  --argjson previous_exists "$previous_pointer_exists" \
  --arg previous_etag "$previous_pointer_etag" --arg previous_sha "$previous_pointer_sha" \
  --slurpfile assets "$asset_inventory" \
  '{schema:"lex-staging-cleanup-receipt/1",
    purpose:"delete-exact-published-prebuilt-staging",generated_at:$generated,
    publisher:$publisher,queue_ticket_id:$ticket,corpus_commit:$corpus,
    build_code_commit:$code,articles_commit:$articles,staging_prefix:$prefix,
    release_tag:$tag,index_manifest_sha256:$manifest,
    staging:{index:{name:$index,etag:$index_etag,sha256:$index_sha},
      vectors:{name:$vectors,etag:$vectors_etag,sha256:$vectors_sha}},
    previous_pointer:{exists:$previous_exists,
      etag:(if $previous_exists then $previous_etag else null end),
      sha256:(if $previous_exists then $previous_sha else null end)},
    public_assets:$assets}' > "$cleanup_receipt"
rm -f "$asset_inventory"
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact manifest \
  --root . --file "$cleanup_receipt" --manifest "$cleanup_manifest" \
  --key-id "$ARTIFACT_KEY_ID" --code-commit "$BUILD_CODE_COMMIT" \
  --source "purpose=delete-exact-published-prebuilt-staging" \
  --source "publisher=$PUBLISHER" --source "queue_ticket_id=$ticket_id" \
  --source "index_manifest_sha256=$manifest_id"
cleanup_digest=$(openssl dgst -sha256 -binary "$cleanup_manifest" | openssl base64 -A)
az_retry az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
  --algorithm ES256 --digest "$cleanup_digest" -o json \
  | jq -er 'if type == "string" then . else (.signature // .value // .result) end' \
  > "$cleanup_signature"
dotnet run --project lex/src/Lex.Ingest -c Release -- artifact verify \
  --root . --manifest "$cleanup_manifest" --signature "$cleanup_signature" \
  --trust-roots lex/deploy/trusted-artifact-roots.json
release_assets+=("$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature")

echo "=== publish immutable Blob release ==="
release_prefix="releases/$PUBLISHER/$manifest_id"
for asset in "${release_assets[@]}"; do
  sha=$(sha256sum "$asset" | cut -d' ' -f1)
  size=$(wc -c < "$asset" | tr -d ' ')
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$release_prefix/$(basename "$asset")" --query exists -o tsv)
  if [ "$exists" = "true" ]; then
    remote=$(az_retry az storage blob show --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$release_prefix/$(basename "$asset")" \
      --query '{sha:metadata.sha256,size:properties.contentLength}' -o json)
    [ "$(printf '%s' "$remote" | jq -r .sha)" = "$sha" ] \
      && [ "$(printf '%s' "$remote" | jq -r .size)" = "$size" ] \
      || { echo "ERROR: refusing to overwrite changed immutable Blob asset $asset" >&2; exit 1; }
  else
    [ "$exists" = "false" ] \
      || { echo "ERROR: Blob existence read-back is malformed for $asset" >&2; exit 1; }
    if ! az_retry az storage blob upload --auth-mode login --only-show-errors --overwrite false \
        --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
        --name "$release_prefix/$(basename "$asset")" --file "$asset" \
        --metadata "sha256=$sha" >/dev/null; then
      # A lost response after creation is accepted only when exact immutable metadata reads back.
      verify_blob_asset "$release_prefix" "$(basename "$asset")" "$sha" "$size"
    fi
  fi
done
echo "=== verify immutable Blob release ==="
for asset in "${release_assets[@]}"; do
  expected_sha=$(sha256sum "$asset" | cut -d' ' -f1)
  expected_size=$(wc -c < "$asset" | tr -d ' ')
  verify_blob_asset "$release_prefix" "$(basename "$asset")" \
    "$expected_sha" "$expected_size"
done
echo "=== publish public GitHub release ==="
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  draft_state=$(gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease,tagName)
  printf '%s' "$draft_state" | jq -e --arg tag "$tag" \
    '.tagName == $tag and .isDraft == true and .isPrerelease == false' >/dev/null \
    || { echo "ERROR: refusing to mutate an existing public or prerelease tag" >&2; exit 1; }
else
  gh release create "$tag" --repo "$repo" --draft \
    --title "index-$PUBLISHER ${ticket_id:0:12}" \
    --notes "Signed index and whole-release manifest. Verify against the public key pinned by Lex before use. Free to download and use; redistribution of any build reserved (NOTICE layer 2)."
fi
gh release upload "$tag" "${release_assets[@]}" --repo "$repo" --clobber
expected_assets=$(for asset in "${release_assets[@]}"; do basename "$asset"; done \
  | sort | jq -Rsc \
  'split("\n") | map(select(length > 0))')
gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease,assets \
  | jq -e --argjson expected "$expected_assets" '
      .isDraft == true and .isPrerelease == false
      and ([.assets[].name] | sort) == $expected' >/dev/null \
  || { echo "ERROR: draft release asset inventory is not exact" >&2; exit 1; }

draft_release_dir=$(mktemp -d)
draft_release_dir=$(realpath "$draft_release_dir")
temporary_root=$(realpath "${TMPDIR:-/tmp}")
case "$draft_release_dir" in
  "$temporary_root"/*) ;;
  *) echo "ERROR: draft release read-back directory is outside the temporary root" >&2; exit 1 ;;
esac
gh release download "$tag" --repo "$repo" --dir "$draft_release_dir"
for asset in "${release_assets[@]}"; do
  asset_name=$(basename "$asset")
  downloaded="$draft_release_dir/$asset_name"
  [ -f "$downloaded" ] \
    && [ "$(sha256sum "$downloaded" | cut -d' ' -f1)" = "$(sha256sum "$asset" | cut -d' ' -f1)" ] \
    && [ "$(wc -c < "$downloaded" | tr -d ' ')" = "$(wc -c < "$asset" | tr -d ' ')" ] \
    || { echo "ERROR: draft release read-back differs for $asset_name" >&2; exit 1; }
done
rm -r -- "$draft_release_dir"
gh release edit "$tag" --repo "$repo" --draft=false >/dev/null

echo "=== verify public GitHub release ==="
release_state=$(gh release view "$tag" --repo "$repo" \
  --json isDraft,isPrerelease,tagName,assets)
printf '%s' "$release_state" | jq -e --arg tag "$tag" \
  --argjson expected "$expected_assets" '
    .tagName == $tag and .isDraft == false and .isPrerelease == false
    and ([.assets[].name] | sort) == $expected' >/dev/null \
  || { echo "ERROR: GitHub release is not the expected public final release" >&2; exit 1; }
public_release_dir=$(mktemp -d)
public_release_dir=$(realpath "$public_release_dir")
temporary_root=$(realpath "${TMPDIR:-/tmp}")
case "$public_release_dir" in
  "$temporary_root"/*) ;;
  *) echo "ERROR: public release read-back directory is outside the temporary root" >&2; exit 1 ;;
esac
for asset in "${release_assets[@]}"; do
  asset_name=$(basename "$asset")
  curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
    "https://github.com/$repo/releases/download/$tag/$asset_name" \
    -o "$public_release_dir/$asset_name"
  downloaded="$public_release_dir/$asset_name"
  [ -f "$downloaded" ] \
    || { echo "ERROR: GitHub release is missing $asset_name" >&2; exit 1; }
  [ "$(sha256sum "$downloaded" | cut -d' ' -f1)" = "$(sha256sum "$asset" | cut -d' ' -f1)" ] \
    && [ "$(wc -c < "$downloaded" | tr -d ' ')" = "$(wc -c < "$asset" | tr -d ' ')" ] \
    || { echo "ERROR: GitHub release read-back differs for $asset_name" >&2; exit 1; }
done
rm -r -- "$public_release_dir"

publish_pointer "$manifest_id" "$release_prefix" "$stamp" \
  "$previous_pointer_exists" "$previous_pointer_etag" "$previous_pointer_sha"

echo "=== remove verified private staging inputs ==="
cleanup_exact_blob "$STAGING_PREFIX/$index" "$index_etag"
cleanup_exact_blob "$STAGING_PREFIX/$vectors" "$vectors_etag"

echo "published_manifest=$manifest_id"
