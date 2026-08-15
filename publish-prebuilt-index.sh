#!/usr/bin/env bash
# Promote an exact private prebuilt snapshot through a recoverable, fail-closed transaction.
set -euo pipefail

readonly ARTIFACT_KEY_ID=keyvault-lex-v2
readonly AZURE_KEY_VERSION=29f1df16fbc34bc7af12f47430cc5acc
readonly ARTIFACT_KEY_FINGERPRINT=155c58524c90c3d7b3c9f5041139c3313d21075139f8e4c948511c505039fb64

for required in PUBLICATION_PHASE PUBLISHER STAGING_PREFIX QUEUE_COMMIT WORKFLOW_COMMIT \
  EXPECTED_INDEX_SHA256 EXPECTED_INDEX_ETAG EXPECTED_INDEX_SIZE \
  EXPECTED_VECTORS_SHA256 EXPECTED_VECTORS_ETAG EXPECTED_VECTORS_SIZE \
  AZURE_INDEX_STORAGE_ACCOUNT AZURE_KEY_VAULT AZURE_KEY_NAME AZURE_CLIENT_ID \
  AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID GH_TOKEN GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_SHA; do
  [ -n "${!required:-}" ] || { echo "ERROR: $required is required" >&2; exit 2; }
done
case "$PUBLICATION_PHASE" in publish|postflight-cleanup) ;; *) echo "ERROR: invalid publication phase" >&2; exit 2 ;; esac
case "$PUBLISHER" in eu-eurlex|lu-legilux) ;; *) echo "ERROR: unsupported publisher" >&2; exit 2 ;; esac
for commit in "$QUEUE_COMMIT" "$WORKFLOW_COMMIT" "$GITHUB_SHA"; do
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: invalid full commit" >&2; exit 2; }
done
[ "$GITHUB_SHA" = "$WORKFLOW_COMMIT" ] && [ "$(git rev-parse HEAD)" = "$WORKFLOW_COMMIT" ] \
  || { echo "ERROR: checked-out workflow code differs from the dispatch pin" >&2; exit 2; }
[ "$GITHUB_REPOSITORY" = SFHAJJI/lex-ops ] \
  || { echo "ERROR: publication workflow is running from another repository" >&2; exit 2; }
for digest in "$EXPECTED_INDEX_SHA256" "$EXPECTED_VECTORS_SHA256"; do
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: invalid SHA-256" >&2; exit 2; }
done
for etag in "$EXPECTED_INDEX_ETAG" "$EXPECTED_VECTORS_ETAG"; do
  [[ "$etag" =~ ^0x[0-9A-F]+$ ]] || { echo "ERROR: ETags must be exact unquoted Azure values" >&2; exit 2; }
done
for size in "$EXPECTED_INDEX_SIZE" "$EXPECTED_VECTORS_SIZE"; do
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: staging sizes must be positive integers" >&2; exit 2; }
done

ops_root=$(pwd)
work_root=$(mktemp -d)
ticket_file="$work_root/index-queue.json"

git fetch --no-tags origin +refs/heads/fleet-status:refs/remotes/origin/fleet-status
bash require-ancestor.sh . "$QUEUE_COMMIT" refs/remotes/origin/fleet-status "queue commit"
git show "$QUEUE_COMMIT:status/index-queue.json" > "$ticket_file"
bash scripts/v4-release-contract.sh validate-ticket "$ticket_file"
ticket_id=$(jq -er .ticket_id "$ticket_file")
BUILD_CODE_COMMIT=$(jq -er .build_code_commit "$ticket_file")
ARTICLES_COMMIT=$(jq -er .articles_commit "$ticket_file")
articles_generation_sha=$(jq -er .articles_generation_sha256 "$ticket_file")
CORPUS_COMMIT=$(jq -er --arg pub "$PUBLISHER" \
  '.entries[] | select(.collection == $pub) | .corpus_commit' "$ticket_file")
repo=$(jq -er --arg pub "$PUBLISHER" \
  '.publishers[] | select(.enabled and .id == $pub) | .corpus_repo' publishers.json)
jq -e --arg pub "$PUBLISHER" --arg repo "$repo" --arg corpus "$CORPUS_COMMIT" \
  --arg code "$BUILD_CODE_COMMIT" --arg articles "$ARTICLES_COMMIT" '
    .mode == "prebuilt" and .build_code_commit == $code and .articles_commit == $articles
    and ([.entries[] | select(.collection == $pub and .corpus_repo == $repo
      and .corpus_commit == $corpus)] | length == 1)
  ' "$ticket_file" >/dev/null \
  || { echo "ERROR: publication inputs do not match the immutable ticket" >&2; exit 2; }
expected_prefix="staging/$PUBLISHER/$ticket_id"
[ "$STAGING_PREFIX" = "$expected_prefix" ] \
  || { echo "ERROR: staging prefix is not the canonical publisher/ticket prefix" >&2; exit 2; }

lex_root="$work_root/lex"
git clone --filter=blob:none "https://x-access-token:${GH_TOKEN}@github.com/SFHAJJI/lex.git" "$lex_root"
git -C "$lex_root" checkout --detach "$BUILD_CODE_COMMIT"
[ "$(git -C "$lex_root" rev-parse HEAD)" = "$BUILD_CODE_COMMIT" ] \
  || { echo "ERROR: publication tooling differs from the ticketed Lex commit" >&2; exit 2; }
git -C "$lex_root" fetch --no-tags origin main
bash require-ancestor.sh "$lex_root" "$BUILD_CODE_COMMIT" refs/remotes/origin/main "ticketed Lex commit"
publication_tool_commit=$(git -C "$lex_root" rev-parse HEAD)
. "$lex_root/scripts/deploy/az-reauth.sh"
. "$lex_root/scripts/deploy/az-retry.sh"

index="index-$PUBLISHER.db"
vectors="index-$PUBLISHER.vectors"
manifest="index-$PUBLISHER.manifest.json"
signature="index-$PUBLISHER.manifest.sig"
benchmark="retrieval-benchmark-$PUBLISHER.json"
benchmark_manifest="retrieval-benchmark-$PUBLISHER.manifest.json"
benchmark_signature="retrieval-benchmark-$PUBLISHER.manifest.sig"
cleanup_receipt="staging-cleanup-$PUBLISHER.json"
cleanup_manifest="staging-cleanup-$PUBLISHER.manifest.json"
cleanup_signature="staging-cleanup-$PUBLISHER.manifest.sig"
tag="index-$PUBLISHER-$ticket_id"
stamp=$(jq -er .generated_at "$ticket_file")
immutability_expiry=$(date -u --date="$stamp + 3650 days" +%Y-%m-%dT%H:%M:%SZ)
claim_name="publication-runs/$PUBLISHER/$ticket_id.json"
claim_file="$work_root/publication-run.json"
single_trust_roots="$work_root/trusted-artifact-root.json"

sha256_file() { sha256sum "$1" | cut -d' ' -f1; }
size_file() { wc -c < "$1" | tr -d ' '; }
normalize_etag() { local value="$1"; value=${value#\"}; value=${value%\"}; printf '%s' "$value"; }

prepare_single_trust_root() {
  local key_dir key_file key_id fingerprint
  key_dir=$(mktemp -d)
  key_file="$key_dir/public.pem"
  key_id=$(az_retry az keyvault key show --only-show-errors \
    --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
    --version "$AZURE_KEY_VERSION" --query key.kid -o tsv)
  case "$key_id" in */"$AZURE_KEY_VERSION") ;; *) echo "ERROR: Key Vault returned another key version" >&2; return 1 ;; esac
  az_retry az keyvault key download --only-show-errors --vault-name "$AZURE_KEY_VAULT" \
    --name "$AZURE_KEY_NAME" --version "$AZURE_KEY_VERSION" \
    --encoding PEM --file "$key_file" -o none >/dev/null
  fingerprint=$(openssl pkey -pubin -in "$key_file" -outform DER 2>/dev/null \
    | sha256sum | cut -d' ' -f1)
  [ "$fingerprint" = "$ARTIFACT_KEY_FINGERPRINT" ] \
    || { echo "ERROR: versioned Key Vault public key fingerprint differs" >&2; return 1; }
  jq -e --arg id "$ARTIFACT_KEY_ID" --arg fp "$ARTIFACT_KEY_FINGERPRINT" '
      [.[] | select(.key_id == $id and .fingerprint_sha256 == $fp)]
      | if length == 1 then . else error("exact artifact root is absent") end
    ' "$lex_root/deploy/trusted-artifact-roots.json" > "$single_trust_roots"
  [ "$(jq 'length' "$single_trust_roots")" -eq 1 ]
}

lock_blob_immutability() {
  local name="$1" policy mode expiry normalized_expiry
  policy=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" \
    --query properties.immutabilityPolicy -o json)
  mode=$(printf '%s' "$policy" | jq -r '.policyMode // ""')
  expiry=$(printf '%s' "$policy" | jq -r '.expiryTime // ""')
  normalized_expiry=""
  [ -z "$expiry" ] || normalized_expiry=$(date -u --date="$expiry" +%Y-%m-%dT%H:%M:%SZ)
  if [ "$mode" = Locked ]; then
    if [[ "$normalized_expiry" < "$immutability_expiry" ]]; then
      az_retry az storage blob immutability-policy set --auth-mode login --only-show-errors \
        --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" \
        --expiry-time "$immutability_expiry" --policy-mode Locked -o none >/dev/null
    fi
  else
    [ -z "$mode" ] || [ "$mode" = Unlocked ] \
      || { echo "ERROR: unknown immutability state for $name" >&2; return 1; }
    az_retry az storage blob immutability-policy set --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" \
      --expiry-time "$immutability_expiry" --policy-mode Unlocked -o none >/dev/null
    az_retry az storage blob immutability-policy set --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" \
      --policy-mode Locked -o none >/dev/null
  fi
  policy=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" \
    --query properties.immutabilityPolicy -o json)
  mode=$(printf '%s' "$policy" | jq -r '.policyMode // ""')
  expiry=$(printf '%s' "$policy" | jq -r '.expiryTime // ""')
  [ -n "$expiry" ] && normalized_expiry=$(date -u --date="$expiry" +%Y-%m-%dT%H:%M:%SZ)
  [ "$mode" = Locked ] \
    && [[ "$normalized_expiry" == "$immutability_expiry" || "$normalized_expiry" > "$immutability_expiry" ]] \
    || { echo "ERROR: Blob immutability policy is not locked through the required expiry for $name" >&2; return 1; }
}

verify_blob_asset() {
  local prefix="$1" name="$2" expected_sha="$3" expected_size="$4"
  local remote remote_etag downloaded expiry normalized_expiry
  remote=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$prefix/$name" \
    --query '{etag:properties.etag,size:properties.contentLength,sha:metadata.sha256,encrypted:properties.serverEncrypted,blobType:properties.blobType,policyMode:properties.immutabilityPolicy.policyMode,expiryTime:properties.immutabilityPolicy.expiryTime}' -o json)
  remote_etag=$(printf '%s' "$remote" | jq -er .etag)
  printf '%s' "$remote" | jq -e --arg sha "$expected_sha" --argjson size "$expected_size" '
    .sha == $sha and .size == $size and .encrypted == true
    and .blobType == "BlockBlob" and .policyMode == "Locked" and .expiryTime != null
  ' >/dev/null || { echo "ERROR: immutable Blob properties differ for $name" >&2; return 1; }
  expiry=$(printf '%s' "$remote" | jq -er .expiryTime)
  normalized_expiry=$(date -u --date="$expiry" +%Y-%m-%dT%H:%M:%SZ)
  [[ "$normalized_expiry" == "$immutability_expiry" || "$normalized_expiry" > "$immutability_expiry" ]] \
    || { echo "ERROR: immutable Blob retention is shorter than required for $name" >&2; return 1; }
  downloaded=$(mktemp)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$prefix/$name" --file "$downloaded" --if-match "$remote_etag" >/dev/null
  [ "$(sha256sum "$downloaded" | cut -d' ' -f1)" = "$expected_sha" ] \
    && [ "$(wc -c < "$downloaded" | tr -d ' ')" = "$expected_size" ] \
    || { echo "ERROR: immutable Blob byte read-back differs for $name" >&2; rm -f "$downloaded"; return 1; }
  rm -f "$downloaded"
}

capture_staging_snapshot() {
  local output="$1" inventory expected name
  inventory=$(az_retry az storage blob list --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --prefix "$STAGING_PREFIX/" --query '[].name' -o json)
  expected=$(printf '%s\n%s\n' "$STAGING_PREFIX/$index" "$STAGING_PREFIX/$vectors" \
    | sort | jq -Rsc 'split("\n") | map(select(length > 0))')
  printf '%s' "$inventory" | jq -e --argjson expected "$expected" 'sort == $expected' >/dev/null \
    || { echo "ERROR: staging prefix inventory is not the exact DB/vector pair" >&2; return 1; }
  : > "$output.items"
  for name in "$STAGING_PREFIX/$index" "$STAGING_PREFIX/$vectors"; do
    az_retry az storage blob show --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" -o json \
      | jq '{name,metadata,properties:{blobType:.properties.blobType,
          contentLength:.properties.contentLength,
          contentSettings:{contentType:.properties.contentSettings.contentType},
          etag:.properties.etag,serverEncrypted:.properties.serverEncrypted}}' \
      >> "$output.items"
  done
  jq -s 'sort_by(.name)' "$output.items" > "$output"
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-staging-snapshot \
    "$output" "$PUBLISHER" "$STAGING_PREFIX" "$ticket_id" "$CORPUS_COMMIT" \
    "$BUILD_CODE_COMMIT" "$ARTICLES_COMMIT" "$articles_generation_sha" \
    "$EXPECTED_INDEX_SHA256" "$EXPECTED_INDEX_ETAG" "$EXPECTED_INDEX_SIZE" \
    "$EXPECTED_VECTORS_SHA256" "$EXPECTED_VECTORS_ETAG" "$EXPECTED_VECTORS_SIZE"
  rm -f "$output.items"
}

download_staging_snapshot() {
  local snapshot="$1" asset expected_sha expected_size remote_etag
  for asset in "$index" "$vectors"; do
    expected_sha="$EXPECTED_INDEX_SHA256"; expected_size="$EXPECTED_INDEX_SIZE"
    [ "$asset" = "$index" ] || { expected_sha="$EXPECTED_VECTORS_SHA256"; expected_size="$EXPECTED_VECTORS_SIZE"; }
    remote_etag=$(jq -er --arg name "$STAGING_PREFIX/$asset" '.[] | select(.name == $name) | .properties.etag' "$snapshot")
    az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$STAGING_PREFIX/$asset" --file "$work_root/$asset" --if-match "$remote_etag" >/dev/null
    [ "$(sha256_file "$work_root/$asset")" = "$expected_sha" ] \
      && [ "$(size_file "$work_root/$asset")" = "$expected_size" ] \
      || { echo "ERROR: conditional staging byte read-back differs for $asset" >&2; return 1; }
  done
  capture_staging_snapshot "$work_root/staging-after-download.json"
}

create_claim_document() {
  jq -cS -n --arg repository "$GITHUB_REPOSITORY" --arg publisher "$PUBLISHER" --arg ticket "$ticket_id" \
    --arg run "$GITHUB_RUN_ID" --arg workflow "$WORKFLOW_COMMIT" --arg queue "$QUEUE_COMMIT" \
    --arg prefix "$STAGING_PREFIX" --arg index_sha "$EXPECTED_INDEX_SHA256" \
    --arg index_etag "$EXPECTED_INDEX_ETAG" --argjson index_size "$EXPECTED_INDEX_SIZE" \
    --arg vectors_sha "$EXPECTED_VECTORS_SHA256" --arg vectors_etag "$EXPECTED_VECTORS_ETAG" \
    --argjson vectors_size "$EXPECTED_VECTORS_SIZE" '
      {schema:"lex-prebuilt-publication-run/1",repository:$repository,publisher:$publisher,
       queue_ticket_id:$ticket,queue_commit:$queue,workflow_commit:$workflow,run_id:$run,
       staging_prefix:$prefix,
       staging:{index:{sha256:$index_sha,etag:$index_etag,size:$index_size},
         vectors:{sha256:$vectors_sha,etag:$vectors_etag,size:$vectors_size}}}
    ' > "$claim_file"
}

verify_claim_content() {
  local remote remote_etag downloaded
  remote=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$claim_name" \
    --query '{etag:properties.etag,size:properties.contentLength,sha:metadata.sha256}' -o json)
  remote_etag=$(printf '%s' "$remote" | jq -er .etag)
  printf '%s' "$remote" | jq -e --arg sha "$(sha256_file "$claim_file")" \
    --argjson size "$(size_file "$claim_file")" '.sha == $sha and .size == $size' >/dev/null \
    || { echo "ERROR: durable publication claim properties differ" >&2; return 1; }
  downloaded=$(mktemp)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$claim_name" --file "$downloaded" --if-match "$remote_etag" >/dev/null
  cmp -s "$claim_file" "$downloaded" \
    || { echo "ERROR: ticket is claimed by another workflow identity" >&2; rm -f "$downloaded"; return 1; }
  rm -f "$downloaded"
}

verify_claim() {
  local policy mode expiry normalized_expiry
  verify_claim_content
  policy=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$claim_name" \
    --query properties.immutabilityPolicy -o json)
  mode=$(printf '%s' "$policy" | jq -r '.policyMode // ""')
  expiry=$(printf '%s' "$policy" | jq -r '.expiryTime // ""')
  [ -n "$expiry" ] && normalized_expiry=$(date -u --date="$expiry" +%Y-%m-%dT%H:%M:%SZ)
  [ "$mode" = Locked ] \
    && [[ "$normalized_expiry" == "$immutability_expiry" || "$normalized_expiry" > "$immutability_expiry" ]] \
    || { echo "ERROR: durable publication claim is not immutable through the required expiry" >&2; return 1; }
}

acquire_or_verify_claim() {
  local exists claim_sha
  create_claim_document
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$claim_name" --query exists -o tsv)
  if [ "$exists" = false ]; then
    [ "$PUBLICATION_PHASE" = publish ] \
      || { echo "ERROR: postflight has no durable publication claim" >&2; return 1; }
    claim_sha=$(sha256_file "$claim_file")
    if ! az_retry az storage blob upload --auth-mode login --only-show-errors --overwrite false \
        --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
        --name "$claim_name" --file "$claim_file" --content-type application/json \
        --metadata "sha256=$claim_sha" --if-none-match '*' >/dev/null; then
      echo "publication claim creation was ambiguous; requiring exact read-back" >&2
    fi
  elif [ "$exists" != true ]; then
    echo "ERROR: publication claim existence is malformed" >&2
    return 1
  fi
  verify_claim_content
  if [ "$PUBLICATION_PHASE" = publish ]; then
    lock_blob_immutability "$claim_name"
  fi
  verify_claim
}

sign_manifest() {
  local manifest_path="$1" signature_path="$2" digest
  digest=$(openssl dgst -sha256 -binary "$manifest_path" | openssl base64 -A)
  az_retry az keyvault key sign --vault-name "$AZURE_KEY_VAULT" --name "$AZURE_KEY_NAME" \
    --version "$AZURE_KEY_VERSION" --algorithm ES256 --digest "$digest" -o json \
    | jq -er 'if type == "string" then . else (.signature // .value // .result) end' \
    > "$signature_path"
}

cleanup_exact_blob() {
  local name="$1" expected_etag="$2" exists observed
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query exists -o tsv)
  [ "$exists" = true ] || { [ "$exists" = false ] && return 0; return 1; }
  observed=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query properties.etag -o tsv)
  [ "$(normalize_etag "$observed")" = "$expected_etag" ] \
    || { echo "ERROR: refusing to delete changed staging blob $name" >&2; return 1; }
  if ! az_retry az storage blob delete --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$name" --if-match "$observed" >/dev/null; then
    exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$name" --query exists -o tsv)
    [ "$exists" = false ] || return 1
  fi
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query exists -o tsv)
  [ "$exists" = false ] \
    || { echo "ERROR: staging blob deletion did not converge for $name" >&2; return 1; }
}

download_blob_conditionally() {
  local name="$1" output="$2" remote_etag
  remote_etag=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --query properties.etag -o tsv)
  [ -n "$remote_etag" ] || { echo "ERROR: Blob has no stable ETag: $name" >&2; return 1; }
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --file "$output" --if-match "$remote_etag" >/dev/null
}

authenticate_previous_pointer() {
  local pointer="$1" manifest_id prefix corpus previous_dir
  jq -e --arg pub "$PUBLISHER" '
      ((.schema == "lex-artifact-pointer/1"
        and (keys | sort) == ["collection","corpus_commit","manifest_sha256","prefix","published_at","schema"])
       or (.schema == "lex-artifact-pointer/2"
        and (keys | sort) == ["benchmark_manifest_sha256","collection","corpus_commit",
          "manifest_sha256","prefix","published_at","schema","semantic_activation"]))
      and .collection == $pub
      and (.manifest_sha256 | test("^[0-9a-f]{64}$"))
      and .prefix == ("releases/" + $pub + "/" + .manifest_sha256)
      and (.corpus_commit | test("^[0-9a-f]{40}$"))
      and (if .schema == "lex-artifact-pointer/2" then
        (.benchmark_manifest_sha256 | test("^[0-9a-f]{64}$"))
        and (.semantic_activation | type == "boolean") else true end)
    ' "$pointer" >/dev/null \
    || { echo "ERROR: current pointer is not an exact supported document" >&2; return 1; }
  manifest_id=$(jq -er .manifest_sha256 "$pointer")
  prefix=$(jq -er .prefix "$pointer")
  corpus=$(jq -er .corpus_commit "$pointer")
  previous_dir=$(mktemp -d)
  download_blob_conditionally "$prefix/$cleanup_receipt" "$previous_dir/$cleanup_receipt"
  download_blob_conditionally "$prefix/$cleanup_manifest" "$previous_dir/$cleanup_manifest"
  download_blob_conditionally "$prefix/$cleanup_signature" "$previous_dir/$cleanup_signature"
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$previous_dir" --manifest "$previous_dir/$cleanup_manifest" \
    --signature "$previous_dir/$cleanup_signature" --trust-roots "$single_trust_roots"
  jq -e --arg pub "$PUBLISHER" --arg corpus "$corpus" --arg manifest "$manifest_id" \
    --slurpfile pointer "$pointer" '
      (.schema == "lex-staging-cleanup-receipt/1" or .schema == "lex-staging-cleanup-receipt/2")
      and .publisher == $pub and .corpus_commit == $corpus
      and .index_manifest_sha256 == $manifest
      and (if $pointer[0].schema == "lex-artifact-pointer/2" then
        .schema == "lex-staging-cleanup-receipt/2"
        and .benchmark_manifest_sha256 == $pointer[0].benchmark_manifest_sha256
        and .semantic_activation == $pointer[0].semantic_activation else true end)
    ' "$previous_dir/$cleanup_receipt" >/dev/null \
    || { echo "ERROR: signed previous pointer evidence does not authenticate its lineage" >&2; return 1; }
  previous_corpus_commit="$corpus"
}

snapshot_current_pointer() {
  local pointer_name="current/$PUBLISHER.json" observed
  previous_pointer_file="$work_root/previous-pointer.json"
  previous_pointer_exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$pointer_name" --query exists -o tsv)
  if [ "$previous_pointer_exists" = true ]; then
    observed=$(az_retry az storage blob show --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$pointer_name" --query properties.etag -o tsv)
    previous_pointer_etag=$(normalize_etag "$observed")
    az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$pointer_name" --file "$previous_pointer_file" --if-match "$observed" >/dev/null
    previous_pointer_sha=$(sha256_file "$previous_pointer_file")
    authenticate_previous_pointer "$previous_pointer_file"
  else
    [ "$previous_pointer_exists" = false ] \
      || { echo "ERROR: current pointer existence is malformed" >&2; return 1; }
    previous_pointer_etag=""; previous_pointer_sha=""; previous_corpus_commit=""
  fi
}

resolve_sources_and_build_bundle() {
  local corpus_root="$work_root/corpus" articles_root="$work_root/articles-ticket"
  local source_configuration=- model_revision model_sha tokenizer_sha model_base
  local manifest_id benchmark_rc benchmark_digest asset_inventory cleanup_digest
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
    jq -cn --arg name "$asset" --arg sha "$(sha256_file "$work_root/$asset")" \
      --argjson size "$(size_file "$work_root/$asset")" \
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
    --argjson semantic "$semantic_activation" --arg tag "$tag" --arg generated "$stamp" \
    --argjson previous_exists "$previous_pointer_exists" --arg previous_etag "$previous_pointer_etag" \
    --arg previous_sha "$previous_pointer_sha" --slurpfile assets "$asset_inventory" '
      {schema:"lex-staging-cleanup-receipt/2",purpose:"delete-exact-published-prebuilt-staging",
       generated_at:$generated,publisher:$publisher,queue_ticket_id:$ticket,queue_commit:$queue,
       workflow_commit:$workflow,run_id:$run,corpus_commit:$corpus,build_code_commit:$code,
       articles_commit:$articles,staging_prefix:$prefix,release_tag:$tag,
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
      --source "workflow_commit=$WORKFLOW_COMMIT" --source "run_id=$GITHUB_RUN_ID" \
      --source "index_manifest_sha256=$manifest_id" \
      --source "semantic_activation=$semantic_activation"
  )
  sign_manifest "$work_root/$cleanup_manifest" "$work_root/$cleanup_signature"
  release_assets+=("$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature")
  bundle_root="$work_root"
}

verify_receipt_header() {
  local root="$1" receipt="$root/$cleanup_receipt" receipt_manifest="$root/$cleanup_manifest"
  local receipt_signature="$root/$cleanup_signature" canonical_assets_json
  local -a canonical_assets=("$index" "$vectors" model-manifest.json model.onnx \
    sentencepiece.bpe.model "$benchmark" "$benchmark_manifest" "$benchmark_signature" \
    "$manifest" "$signature")
  [ "$PUBLISHER" = eu-eurlex ] && canonical_assets+=(eu-scope.json)
  canonical_assets_json=$(printf '%s\n' "${canonical_assets[@]}" | sort \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$root" --manifest "$receipt_manifest" --signature "$receipt_signature" \
    --trust-roots "$single_trust_roots" >/dev/null || return 1
  jq -e --arg publisher "$PUBLISHER" --arg ticket "$ticket_id" --arg queue "$QUEUE_COMMIT" \
    --arg workflow "$WORKFLOW_COMMIT" --arg run "$GITHUB_RUN_ID" --arg corpus "$CORPUS_COMMIT" \
    --arg code "$BUILD_CODE_COMMIT" --arg articles "$ARTICLES_COMMIT" \
    --arg prefix "$STAGING_PREFIX" --arg tag "$tag" --arg generated "$stamp" \
    --arg index "$STAGING_PREFIX/$index" \
    --arg index_etag "$EXPECTED_INDEX_ETAG" --arg index_sha "$EXPECTED_INDEX_SHA256" \
    --argjson index_size "$EXPECTED_INDEX_SIZE" --arg vectors "$STAGING_PREFIX/$vectors" \
    --arg vectors_etag "$EXPECTED_VECTORS_ETAG" --arg vectors_sha "$EXPECTED_VECTORS_SHA256" \
    --argjson vectors_size "$EXPECTED_VECTORS_SIZE" --argjson canonical_assets "$canonical_assets_json" '
      (keys | sort) == ["articles_commit","benchmark_manifest_sha256","build_code_commit",
        "corpus_commit","generated_at","index_manifest_sha256","previous_pointer",
        "public_assets","publisher","purpose","queue_commit","queue_ticket_id","release_tag",
        "run_id","schema","semantic_activation","staging","staging_prefix","workflow_commit"]
      and .schema == "lex-staging-cleanup-receipt/2"
      and .purpose == "delete-exact-published-prebuilt-staging"
      and .generated_at == $generated
      and .publisher == $publisher and .queue_ticket_id == $ticket and .queue_commit == $queue
      and .workflow_commit == $workflow and .run_id == $run and .corpus_commit == $corpus
      and .build_code_commit == $code and .articles_commit == $articles
      and .staging_prefix == $prefix and .release_tag == $tag
      and (.index_manifest_sha256 | test("^[0-9a-f]{64}$"))
      and (.benchmark_manifest_sha256 | test("^[0-9a-f]{64}$"))
      and (.semantic_activation | type == "boolean")
      and .staging.index == {name:$index,etag:$index_etag,sha256:$index_sha,size:$index_size}
      and .staging.vectors == {name:$vectors,etag:$vectors_etag,sha256:$vectors_sha,size:$vectors_size}
      and (.previous_pointer | keys | sort) == ["etag","exists","sha256"]
      and (.previous_pointer.exists | type == "boolean")
      and (if .previous_pointer.exists then
        (.previous_pointer.etag | type == "string" and test("^0x[0-9A-F]+$"))
        and (.previous_pointer.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      else .previous_pointer.etag == null and .previous_pointer.sha256 == null end)
      and (.public_assets | type == "array")
      and (all(.public_assets[];
        (keys | sort) == ["name","sha256","size"]
        and (.name | type == "string" and test("^[A-Za-z0-9._-]+$") and contains("/") | not)
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.size | type == "number" and . >= 0)))
      and ([.public_assets[].name] | length == (unique | length))
      and ([.public_assets[].name] | sort) == $canonical_assets
    ' "$receipt" >/dev/null || { echo "ERROR: signed cleanup receipt identity is not exact" >&2; return 1; }
  manifest_id=$(jq -er .index_manifest_sha256 "$receipt") || return 1
  semantic_activation=$(jq -er .semantic_activation "$receipt") || return 1
  benchmark_manifest_id=$(jq -er .benchmark_manifest_sha256 "$receipt") || return 1
  release_prefix="releases/$PUBLISHER/$manifest_id"
  previous_pointer_exists=$(jq -er .previous_pointer.exists "$receipt") || return 1
  previous_pointer_etag=$(jq -r '.previous_pointer.etag // ""' "$receipt") || return 1
  previous_pointer_sha=$(jq -r '.previous_pointer.sha256 // ""' "$receipt") || return 1
  expected_assets_json="$root/expected-release-assets.json"
  if ! {
    jq -r '.public_assets[].name' "$receipt"
    printf '%s\n' "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"
  } | sort | jq -Rsc 'split("\n") | map(select(length > 0))' > "$expected_assets_json"; then
    return 1
  fi
  jq -e --arg id "$ARTIFACT_KEY_ID" --arg workflow "$WORKFLOW_COMMIT" \
    --arg run "$GITHUB_RUN_ID" --arg manifest "$manifest_id" --arg code "$BUILD_CODE_COMMIT" \
    --arg receipt "$cleanup_receipt" --arg publisher "$PUBLISHER" --arg ticket "$ticket_id" \
    --arg receipt_sha "$(sha256_file "$receipt")" --argjson semantic "$semantic_activation" '
      .key_id == $id and .code_commit == $code
      and (.files | length == 1) and .files[0].path == $receipt
      and .files[0].sha256 == $receipt_sha
      and (.sources | keys | sort) == ["index_manifest_sha256","publisher","purpose",
        "queue_ticket_id","run_id","semantic_activation","workflow_commit"]
      and .sources.purpose == "delete-exact-published-prebuilt-staging"
      and .sources.publisher == $publisher and .sources.queue_ticket_id == $ticket
      and .sources.workflow_commit == $workflow and .sources.run_id == $run
      and .sources.index_manifest_sha256 == $manifest
      and .sources.semantic_activation == ($semantic | tostring)
    ' "$receipt_manifest" >/dev/null \
    || { echo "ERROR: cleanup signature manifest does not bind the transaction" >&2; return 1; }
}

verify_complete_bundle() {
  local root="$1" item name expected_sha expected_size canonical_index_files_json
  local -a canonical_index_files=("$index" "$vectors" model-manifest.json model.onnx sentencepiece.bpe.model)
  [ "$PUBLISHER" = eu-eurlex ] && canonical_index_files+=(eu-scope.json)
  canonical_index_files_json=$(printf '%s\n' "${canonical_index_files[@]}" | sort \
    | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
  verify_receipt_header "$root" || return 1
  while IFS= read -r item; do
    name=$(printf '%s' "$item" | jq -r .name)
    expected_sha=$(printf '%s' "$item" | jq -r .sha256)
    expected_size=$(printf '%s' "$item" | jq -r .size)
    [ -f "$root/$name" ] && [ "$(sha256_file "$root/$name")" = "$expected_sha" ] \
      && [ "$(size_file "$root/$name")" = "$expected_size" ] \
      || { echo "ERROR: release bundle differs for $name" >&2; return 1; }
  done < <(jq -c '.public_assets[]' "$root/$cleanup_receipt")
  [ "$(sha256_file "$root/$manifest")" = "$manifest_id" ] \
    && [ "$(sha256_file "$root/$benchmark_manifest")" = "$benchmark_manifest_id" ] \
    || { echo "ERROR: signed release manifest identities differ" >&2; return 1; }
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$root" --manifest "$root/$manifest" --signature "$root/$signature" \
    --trust-roots "$single_trust_roots" >/dev/null || return 1
  jq -e --arg id "$ARTIFACT_KEY_ID" --arg pub "$PUBLISHER" --arg corpus "$CORPUS_COMMIT" \
    --arg code "$BUILD_CODE_COMMIT" --arg articles "$ARTICLES_COMMIT" --arg ticket "$ticket_id" \
    --arg workflow "$WORKFLOW_COMMIT" --arg index_sha "$EXPECTED_INDEX_SHA256" \
    --argjson index_size "$EXPECTED_INDEX_SIZE" --arg vectors_sha "$EXPECTED_VECTORS_SHA256" \
    --argjson vectors_size "$EXPECTED_VECTORS_SIZE" --argjson canonical_files "$canonical_index_files_json" '
      .key_id == $id and .code_commit == $code and .sources.collection == $pub
      and (.sources | keys | sort) == ["articles_commit","build_origin","collection",
        "corpus_commit","index_sha256","publication_tool_commit","queue_ticket_id","vectors_sha256"]
      and .sources.corpus_commit == $corpus and .sources.articles_commit == $articles
      and .sources.queue_ticket_id == $ticket and .sources.publication_tool_commit == $code
      and .sources.index_sha256 == $index_sha and .sources.vectors_sha256 == $vectors_sha
      and ([.files[].path] | sort) == $canonical_files
      and ([.files[] | select(.path == ("index-" + $pub + ".db")
        and .sha256 == $index_sha and .size == $index_size)] | length == 1)
      and ([.files[] | select(.path == ("index-" + $pub + ".vectors")
        and .sha256 == $vectors_sha and .size == $vectors_size)] | length == 1)
    ' "$root/$manifest" >/dev/null \
    || { echo "ERROR: index manifest does not bind the exact DB/vector provenance" >&2; return 1; }
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$root" --manifest "$root/$benchmark_manifest" \
    --signature "$root/$benchmark_signature" --trust-roots "$single_trust_roots" >/dev/null || return 1
  jq -e --arg id "$ARTIFACT_KEY_ID" --arg manifest "$manifest_id" \
    --arg report "$benchmark" --arg report_sha "$(sha256_file "$root/$benchmark")" \
    --arg pub "$PUBLISHER" --arg corpus "$CORPUS_COMMIT" --arg ticket "$ticket_id" \
    --arg code "$publication_tool_commit" \
    --argjson semantic "$semantic_activation" '
      .key_id == $id and .code_commit == $code
      and (.files | length == 1) and .files[0].path == $report and .files[0].sha256 == $report_sha
      and (.sources | keys | sort) == ["collection","corpus_commit","index_manifest_sha256",
        "queue_ticket_id","semantic_activation"]
      and .sources.collection == $pub and .sources.corpus_commit == $corpus
      and .sources.queue_ticket_id == $ticket and .sources.index_manifest_sha256 == $manifest
      and .sources.semantic_activation == ($semantic | tostring)
    ' "$root/$benchmark_manifest" >/dev/null \
    || { echo "ERROR: benchmark manifest does not bind semantic activation" >&2; return 1; }
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-benchmark \
    "$root/$benchmark" "$PUBLISHER" "$publication_tool_commit" "$CORPUS_COMMIT" \
    "$manifest_id" "$EXPECTED_INDEX_SIZE" "$EXPECTED_VECTORS_SIZE" || return 1
  [ "$(jq -er .activation_gate_passed "$root/$benchmark")" = "$semantic_activation" ] \
    || { echo "ERROR: receipt semantic activation differs from the signed benchmark" >&2; return 1; }
}

validate_tag_target() {
  local output="$1"
  gh api "repos/$repo/git/ref/tags/$tag" > "$output" || return 1
  jq -e --arg corpus "$CORPUS_COMMIT" \
    '.object.type == "commit" and .object.sha == $corpus' "$output" >/dev/null \
    || { echo "ERROR: release tag does not target the ticketed corpus commit" >&2; return 1; }
}

download_github_bundle() {
  local state="$1" root release_json tag_json asset
  root=$(mktemp -d)
  if [ "$state" = draft ]; then
    for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
      gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$root" || return 1
    done
  else
    for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
      curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
        "https://github.com/$repo/releases/download/$tag/$asset" -o "$root/$asset" || return 1
    done
  fi
  verify_receipt_header "$root" || return 1
  release_json="$root/release.json"
  gh api "repos/$repo/releases/tags/$tag" > "$release_json" || return 1
  jq -e --slurpfile expected "$expected_assets_json" \
    '([.assets[].name] | sort) == ($expected[0] | sort)' "$release_json" >/dev/null \
    || { echo "ERROR: GitHub release asset inventory is not exact" >&2; return 1; }
  while IFS= read -r asset; do
    [ -f "$root/$asset" ] && continue
    if [ "$state" = draft ]; then
      gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$root" || return 1
    else
      curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
        "https://github.com/$repo/releases/download/$tag/$asset" -o "$root/$asset" || return 1
    fi
  done < <(jq -r '.[]' "$expected_assets_json")
  tag_json="$root/tag.json"
  validate_tag_target "$tag_json" || return 1
  if [ "$state" = public ]; then
    python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-release \
      "$release_json" "$tag_json" "$tag" "$CORPUS_COMMIT" "$expected_assets_json" || return 1
  else
    jq -e --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" '
      .draft == true and .prerelease == false and .tag_name == $tag
      and .target_commitish == $corpus and .immutable == false
    ' "$release_json" >/dev/null \
      || { echo "ERROR: draft release identity is not exact" >&2; return 1; }
  fi
  verify_complete_bundle "$root" || return 1
  bundle_root="$root"
}

verify_blob_bytes_before_lock() {
  local name="$1" expected_file="$2" expected_sha="$3" expected_size="$4"
  local remote remote_etag downloaded
  remote=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" \
    --query '{etag:properties.etag,size:properties.contentLength,sha:metadata.sha256,encrypted:properties.serverEncrypted,blobType:properties.blobType}' -o json)
  remote_etag=$(printf '%s' "$remote" | jq -er .etag)
  printf '%s' "$remote" | jq -e --arg sha "$expected_sha" --argjson size "$expected_size" '
      .sha == $sha and .size == $size and .encrypted == true and .blobType == "BlockBlob"
    ' >/dev/null || { echo "ERROR: existing release Blob properties differ for $name" >&2; return 1; }
  downloaded=$(mktemp)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$name" --file "$downloaded" --if-match "$remote_etag" >/dev/null
  [ "$(sha256_file "$downloaded")" = "$expected_sha" ] \
    && [ "$(size_file "$downloaded")" = "$expected_size" ] \
    && cmp -s "$expected_file" "$downloaded" \
    || { echo "ERROR: existing release Blob bytes differ for $name" >&2; rm -f "$downloaded"; return 1; }
  rm -f "$downloaded"
}

publish_blob_bundle() {
  local root="$1" asset sha size exists blob_name
  echo "=== publish immutable Blob release ==="
  while IFS= read -r asset; do
    sha=$(sha256_file "$root/$asset")
    size=$(size_file "$root/$asset")
    blob_name="$release_prefix/$asset"
    exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$blob_name" --query exists -o tsv)
    if [ "$exists" = true ]; then
      verify_blob_bytes_before_lock "$blob_name" "$root/$asset" "$sha" "$size"
    else
      [ "$exists" = false ] || { echo "ERROR: release Blob existence is malformed" >&2; return 1; }
      if ! az_retry az storage blob upload --auth-mode login --only-show-errors --overwrite false \
          --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
          --name "$blob_name" --file "$root/$asset" --metadata "sha256=$sha" \
          --if-none-match '*' >/dev/null; then
        echo "release Blob creation was ambiguous; requiring exact byte read-back" >&2
      fi
      verify_blob_bytes_before_lock "$blob_name" "$root/$asset" "$sha" "$size"
    fi
    lock_blob_immutability "$blob_name"
    verify_blob_asset "$release_prefix" "$asset" "$sha" "$size"
  done < <(jq -r '.[]' "$expected_assets_json")
}

verify_blob_bundle() {
  local root="$1" asset sha size
  echo "=== verify immutable Blob release ==="
  while IFS= read -r asset; do
    sha=$(sha256_file "$root/$asset")
    size=$(size_file "$root/$asset")
    verify_blob_asset "$release_prefix" "$asset" "$sha" "$size"
  done < <(jq -r '.[]' "$expected_assets_json")
}

require_github_immutable_releases() {
  gh api "repos/$repo/immutable-releases" \
    | jq -e '.enabled == true' >/dev/null \
    || { echo "ERROR: repository immutable releases are not enabled" >&2; return 1; }
}

prepare_exact_draft() {
  local root="$1" state release_json
  require_github_immutable_releases
  if state=$(gh api "repos/$repo/releases/tags/$tag" 2>/dev/null); then
    printf '%s' "$state" | jq -e --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" '
      .draft == true and .prerelease == false and .tag_name == $tag
      and .target_commitish == $corpus and .immutable == false
    ' >/dev/null || { echo "ERROR: refusing to mutate an existing non-draft release" >&2; return 1; }
  else
    gh release create "$tag" --repo "$repo" --draft --target "$CORPUS_COMMIT" \
      --title "index-$PUBLISHER ${ticket_id:0:12}" \
      --notes "Signed index, benchmark activation evidence, and whole-release manifest."
  fi
  validate_tag_target "$work_root/draft-tag.json"
  mapfile -t release_uploads < <(jq -r --arg root "$root/" '.[] | $root + .' "$expected_assets_json")
  gh release upload "$tag" "${release_uploads[@]}" --repo "$repo" --clobber
  release_json="$work_root/draft-release.json"
  gh api "repos/$repo/releases/tags/$tag" > "$release_json"
  jq -e --slurpfile expected "$expected_assets_json" --arg corpus "$CORPUS_COMMIT" '
      .draft == true and .prerelease == false and .target_commitish == $corpus
      and ([.assets[].name] | sort) == ($expected[0] | sort)
    ' "$release_json" >/dev/null || { echo "ERROR: exact draft publication failed" >&2; return 1; }
  download_github_bundle draft
}

finalize_and_verify_public_release() {
  local state attempt
  gh release edit "$tag" --repo "$repo" --draft=false >/dev/null
  for attempt in $(seq 1 12); do
    state=$(gh api "repos/$repo/releases/tags/$tag")
    if printf '%s' "$state" | jq -e '.draft == false and .immutable == true' >/dev/null; then
      download_github_bundle public
      return 0
    fi
    sleep 5
  done
  echo "ERROR: GitHub release did not become immutable" >&2
  return 1
}

make_desired_pointer() {
  local root="$1" output="$2"
  jq -cS -n --arg pub "$PUBLISHER" --arg manifest "$manifest_id" \
    --arg benchmark "$benchmark_manifest_id" --arg prefix "$release_prefix" \
    --arg corpus "$CORPUS_COMMIT" --arg published "$stamp" \
    --argjson semantic "$semantic_activation" '
      {schema:"lex-artifact-pointer/2",collection:$pub,manifest_sha256:$manifest,
       benchmark_manifest_sha256:$benchmark,semantic_activation:$semantic,
       prefix:$prefix,corpus_commit:$corpus,published_at:$published}
    ' > "$output"
}

publish_pointer_from_bundle() {
  local root="$1" pointer_name="current/$PUBLISHER.json" desired current exists observed
  local current_sha current_etag expected_exists expected_etag expected_sha
  local -a condition
  desired="$work_root/desired-pointer.json"
  make_desired_pointer "$root" "$desired"
  expected_exists=$(jq -er .previous_pointer.exists "$root/$cleanup_receipt")
  expected_etag=$(jq -r '.previous_pointer.etag // ""' "$root/$cleanup_receipt")
  expected_sha=$(jq -r '.previous_pointer.sha256 // ""' "$root/$cleanup_receipt")
  current=$(mktemp)
  exists=$(az_retry az storage blob exists --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$pointer_name" --query exists -o tsv)
  if [ "$exists" = true ]; then
    observed=$(az_retry az storage blob show --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$pointer_name" --query properties.etag -o tsv)
    current_etag=$(normalize_etag "$observed")
    az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$pointer_name" --file "$current" --if-match "$observed" >/dev/null
    if cmp -s "$desired" "$current"; then rm -f "$current"; return 0; fi
    current_sha=$(sha256_file "$current")
    [ "$expected_exists" = true ] && [ "$current_etag" = "$expected_etag" ] \
      && [ "$current_sha" = "$expected_sha" ] \
      || { echo "ERROR: refusing to replace a changed current artifact pointer" >&2; return 1; }
    condition=(--if-match "$observed")
  else
    [ "$exists" = false ] && [ "$expected_exists" = false ] \
      || { echo "ERROR: current artifact pointer existence changed" >&2; return 1; }
    condition=(--if-none-match '*')
  fi
  if ! az_retry az storage blob upload --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$pointer_name" --file "$desired" --content-type application/json \
      "${condition[@]}" >/dev/null; then
    echo "pointer update was ambiguous; requiring exact desired read-back" >&2
  fi
  observed=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$pointer_name" --query properties.etag -o tsv)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$pointer_name" --file "$current" --if-match "$observed" >/dev/null
  cmp -s "$desired" "$current" \
    || { echo "ERROR: current artifact pointer read-back differs" >&2; return 1; }
  rm -f "$current"
}

verify_current_pointer() {
  local root="$1" desired observed readback
  desired="$work_root/postflight-desired-pointer.json"
  make_desired_pointer "$root" "$desired"
  observed=$(az_retry az storage blob show --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --query properties.etag -o tsv)
  readback=$(mktemp)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "current/$PUBLISHER.json" --file "$readback" --if-match "$observed" >/dev/null
  cmp -s "$desired" "$readback" \
    || { echo "ERROR: current artifact pointer is not the signed release identity" >&2; return 1; }
  rm -f "$readback"
}

capture_remaining_staging_for_cleanup() {
  local output="$1" inventory expected name asset expected_sha expected_size remote_etag
  inventory=$(az_retry az storage blob list --auth-mode login --only-show-errors \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --prefix "$STAGING_PREFIX/" --query '[].name' -o json)
  expected=$(printf '%s\n%s\n' "$STAGING_PREFIX/$index" "$STAGING_PREFIX/$vectors" \
    | sort | jq -Rsc 'split("\n") | map(select(length > 0))')
  printf '%s' "$inventory" | jq -e --argjson expected "$expected" \
    'all(.[]; . as $name | $expected | index($name) != null)' >/dev/null \
    || { echo "ERROR: staging cleanup prefix contains an unexpected blob" >&2; return 1; }
  : > "$output.items"
  while IFS= read -r name; do
    az_retry az storage blob show --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex --name "$name" -o json \
      | jq '{name,metadata,properties:{blobType:.properties.blobType,
          contentLength:.properties.contentLength,
          contentSettings:{contentType:.properties.contentSettings.contentType},
          etag:.properties.etag,serverEncrypted:.properties.serverEncrypted}}' \
      >> "$output.items"
  done < <(printf '%s' "$inventory" | jq -r '.[]')
  jq -s 'sort_by(.name)' "$output.items" > "$output"
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-staging-cleanup-snapshot \
    "$output" "$PUBLISHER" "$STAGING_PREFIX" "$ticket_id" "$CORPUS_COMMIT" \
    "$BUILD_CODE_COMMIT" "$ARTICLES_COMMIT" "$articles_generation_sha" \
    "$EXPECTED_INDEX_SHA256" "$EXPECTED_INDEX_ETAG" "$EXPECTED_INDEX_SIZE" \
    "$EXPECTED_VECTORS_SHA256" "$EXPECTED_VECTORS_ETAG" "$EXPECTED_VECTORS_SIZE"
  while IFS= read -r name; do
    asset=${name##*/}
    expected_sha="$EXPECTED_INDEX_SHA256"; expected_size="$EXPECTED_INDEX_SIZE"
    [ "$asset" = "$index" ] || { expected_sha="$EXPECTED_VECTORS_SHA256"; expected_size="$EXPECTED_VECTORS_SIZE"; }
    remote_etag=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .properties.etag' "$output")
    az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --name "$name" --file "$work_root/postflight-$asset" --if-match "$remote_etag" >/dev/null
    [ "$(sha256_file "$work_root/postflight-$asset")" = "$expected_sha" ] \
      && [ "$(size_file "$work_root/postflight-$asset")" = "$expected_size" ] \
      || { echo "ERROR: remaining staging bytes differ before cleanup" >&2; return 1; }
  done < <(printf '%s' "$inventory" | jq -r '.[]')
  rm -f "$output.items"
}

prepare_single_trust_root
acquire_or_verify_claim

case "$PUBLICATION_PHASE" in
  publish)
    echo "=== validate exact private staging snapshot ==="
    capture_staging_snapshot "$work_root/staging.json"
    download_staging_snapshot "$work_root/staging.json"
    require_github_immutable_releases
    if release_state=$(gh api "repos/$repo/releases/tags/$tag" 2>/dev/null); then
      if printf '%s' "$release_state" | jq -e '.draft == false' >/dev/null; then
        download_github_bundle public
        verify_blob_bundle "$bundle_root"
        publish_pointer_from_bundle "$bundle_root"
        echo "published_manifest=$manifest_id"
        exit 0
      fi
      if download_github_bundle draft; then
        publish_blob_bundle "$bundle_root"
        finalize_and_verify_public_release
        verify_blob_bundle "$bundle_root"
        publish_pointer_from_bundle "$bundle_root"
        echo "published_manifest=$manifest_id"
        exit 0
      fi
      echo "incomplete same-run draft found; rebuilding before any Blob publication" >&2
    fi
    echo "=== authenticate previous pointer and enforce monotonic corpus lineage ==="
    snapshot_current_pointer
    resolve_sources_and_build_bundle
    verify_complete_bundle "$bundle_root"
    echo "=== prepare exact recoverable GitHub draft ==="
    prepare_exact_draft "$bundle_root"
    publish_blob_bundle "$bundle_root"
    finalize_and_verify_public_release
    verify_blob_bundle "$bundle_root"
    publish_pointer_from_bundle "$bundle_root"
    echo "published_manifest=$manifest_id"
    ;;
  postflight-cleanup)
    echo "=== verify public GitHub release ==="
    download_github_bundle public
    echo "=== verify immutable Blob release ==="
    verify_blob_bundle "$bundle_root"
    echo "=== verify current artifact pointer ==="
    verify_current_pointer "$bundle_root"
    echo "=== revalidate exact remaining staging bytes ==="
    capture_remaining_staging_for_cleanup "$work_root/postflight-staging.json"
    cleanup_exact_blob "$STAGING_PREFIX/$index" "$EXPECTED_INDEX_ETAG"
    cleanup_exact_blob "$STAGING_PREFIX/$vectors" "$EXPECTED_VECTORS_ETAG"
    remaining=$(az_retry az storage blob list --auth-mode login --only-show-errors \
      --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
      --prefix "$STAGING_PREFIX/" --query 'length(@)' -o tsv)
    [ "$remaining" = 0 ] || { echo "ERROR: staging cleanup did not reach exact absence" >&2; exit 1; }
    echo "postflight_cleanup_manifest=$manifest_id"
    ;;
esac
