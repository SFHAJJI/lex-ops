#!/usr/bin/env bash
# Promote an exact private prebuilt snapshot through a recoverable, fail-closed transaction.
set -euo pipefail

readonly ARTIFACT_KEY_ID=keyvault-lex-v2
readonly AZURE_KEY_VERSION=29f1df16fbc34bc7af12f47430cc5acc
readonly ARTIFACT_KEY_FINGERPRINT=155c58524c90c3d7b3c9f5041139c3313d21075139f8e4c948511c505039fb64
readonly HYBRID_QUARANTINE_GUARD_COMMIT=03f94295f3e678b47cb0511a082698f34373679c

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
bash require-ancestor.sh "$lex_root" "$HYBRID_QUARANTINE_GUARD_COMMIT" refs/remotes/origin/main \
  "hybrid quarantine runtime guard"
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
release_id=
stamp=$(jq -er .generated_at "$ticket_file")
claim_name="publication-runs/$PUBLISHER/$ticket_id.json"
claim_file="$work_root/publication-run.json"
single_trust_roots="$work_root/trusted-artifact-root.json"

sha256_file() { sha256sum "$1" | cut -d' ' -f1; }
size_file() { wc -c < "$1" | tr -d ' '; }
normalize_etag() { local value="$1"; value=${value#\"}; value=${value%\"}; printf '%s' "$value"; }
gh_api() { gh api -H 'X-GitHub-Api-Version: 2026-03-10' "$@"; }

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
    --query '{etag:properties.etag,size:properties.contentLength,metadata:metadata,encrypted:properties.serverEncrypted,blobType:properties.blobType}' -o json)
  remote_etag=$(printf '%s' "$remote" | jq -er .etag)
  printf '%s' "$remote" | jq -e --arg sha "$(sha256_file "$claim_file")" \
    --argjson size "$(size_file "$claim_file")" '
      .metadata == {sha256:$sha} and .size == $size
      and .encrypted == true and .blobType == "BlockBlob"
    ' >/dev/null \
    || { echo "ERROR: durable publication claim properties differ" >&2; return 1; }
  downloaded=$(mktemp)
  az_retry az storage blob download --auth-mode login --only-show-errors --overwrite true \
    --account-name "$AZURE_INDEX_STORAGE_ACCOUNT" --container-name lex \
    --name "$claim_name" --file "$downloaded" --if-match "$remote_etag" >/dev/null
  cmp -s "$claim_file" "$downloaded" \
    || { echo "ERROR: ticket is claimed by another workflow identity" >&2; rm -f "$downloaded"; return 1; }
  rm -f "$downloaded"
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

download_legacy_blob_conditionally() {
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
  local pointer="$1" pointer_schema manifest_id prefix corpus previous_dir receipt_manifest_id
  local previous_tag asset release_state tag_state legacy_manifest legacy_signature legacy_assets
  jq -e --arg pub "$PUBLISHER" '
      ((.schema == "lex-artifact-pointer/1"
        and (keys | sort) == ["collection","corpus_commit","manifest_sha256","prefix","published_at","schema"])
       or (.schema == "lex-artifact-pointer/2"
        and (keys | sort) == ["benchmark_manifest_sha256","collection","corpus_commit",
          "manifest_sha256","published_at","receipt_manifest_sha256","release_repository","release_tag",
          "schema","semantic_activation"]))
      and .collection == $pub
      and (.manifest_sha256 | test("^[0-9a-f]{64}$"))
      and (.corpus_commit | test("^[0-9a-f]{40}$"))
      and (if .schema == "lex-artifact-pointer/1" then
        .prefix == ("releases/" + $pub + "/" + .manifest_sha256)
      else
        (.benchmark_manifest_sha256 | test("^[0-9a-f]{64}$"))
        and (.receipt_manifest_sha256 | test("^[0-9a-f]{64}$"))
        and .release_repository == ("SFHAJJI/lex-corpus-" + $pub)
        and (.release_tag | test("^index-" + $pub + "-[0-9a-f]{64}$"))
        and (.semantic_activation | type == "boolean") end)
    ' "$pointer" >/dev/null \
    || { echo "ERROR: current pointer is not an exact supported document" >&2; return 1; }
  pointer_schema=$(jq -er .schema "$pointer") || return 1
  manifest_id=$(jq -er .manifest_sha256 "$pointer")
  corpus=$(jq -er .corpus_commit "$pointer")
  previous_dir=$(mktemp -d) || return 1
  if [ "$pointer_schema" = lex-artifact-pointer/1 ]; then
    prefix=$(jq -er .prefix "$pointer") || return 1
    legacy_manifest="index-$PUBLISHER.manifest.json"
    legacy_signature="index-$PUBLISHER.manifest.sig"
    download_legacy_blob_conditionally "$prefix/$legacy_manifest" \
      "$previous_dir/$legacy_manifest" || return 1
    download_legacy_blob_conditionally "$prefix/$legacy_signature" \
      "$previous_dir/$legacy_signature" || return 1
    legacy_assets=$(python3 "$ops_root/scripts/prebuilt_publication_contract.py" \
      validate-legacy-pointer "$pointer" "$previous_dir/$legacy_manifest" "$PUBLISHER") \
      || return 1
    [ -n "$legacy_assets" ] || return 1
    while IFS= read -r asset; do
      [ -n "$asset" ] || return 1
      download_legacy_blob_conditionally "$prefix/$asset" "$previous_dir/$asset" || return 1
    done <<< "$legacy_assets"
    dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
      --root "$previous_dir" --manifest "$previous_dir/$legacy_manifest" \
      --signature "$previous_dir/$legacy_signature" --trust-roots "$single_trust_roots"
    previous_corpus_commit="$corpus"
    return 0
  else
    previous_tag=$(jq -er .release_tag "$pointer") || return 1
    release_state=$(gh_api "repos/$repo/releases/tags/$previous_tag") || return 1
    printf '%s' "$release_state" | jq -e --arg tag "$previous_tag" --arg corpus "$corpus" '
      .draft == false and .prerelease == false and .immutable == true
      and .tag_name == $tag and .target_commitish == $corpus
    ' >/dev/null || { echo "ERROR: previous pointer release is not immutable and exact" >&2; return 1; }
    tag_state=$(gh_api "repos/$repo/git/ref/tags/$previous_tag") || return 1
    printf '%s' "$tag_state" | jq -e --arg corpus "$corpus" \
      '.object.type == "commit" and .object.sha == $corpus' >/dev/null \
      || { echo "ERROR: previous pointer tag target differs" >&2; return 1; }
    gh release verify "$previous_tag" --repo "$repo" >/dev/null || return 1
    for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
      curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
        "https://github.com/$repo/releases/download/$previous_tag/$asset" \
        -o "$previous_dir/$asset" || return 1
      gh release verify-asset "$previous_tag" "$previous_dir/$asset" \
        --repo "$repo" >/dev/null || return 1
    done
  fi
  receipt_manifest_id=$(sha256_file "$previous_dir/$cleanup_manifest")
  if [ "$pointer_schema" = lex-artifact-pointer/2 ]; then
    [ "$receipt_manifest_id" = "$(jq -er .receipt_manifest_sha256 "$pointer")" ] \
      || { echo "ERROR: previous pointer receipt manifest identity differs" >&2; return 1; }
  fi
  dotnet run --project "$lex_root/src/Lex.Ingest" -c Release -- artifact verify \
    --root "$previous_dir" --manifest "$previous_dir/$cleanup_manifest" \
    --signature "$previous_dir/$cleanup_signature" --trust-roots "$single_trust_roots"
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-lineage-receipt \
    "$previous_dir/$cleanup_receipt" "$pointer" "$PUBLISHER" \
    "$HYBRID_QUARANTINE_GUARD_COMMIT" \
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

. "$ops_root/scripts/prebuilt-publication-build.sh"


. "$ops_root/scripts/prebuilt-publication-release.sh"

make_desired_pointer() {
  local output="$1"
  jq -cS -n --arg pub "$PUBLISHER" --arg manifest "$manifest_id" \
    --arg benchmark "$benchmark_manifest_id" --arg receipt "$receipt_manifest_id" \
    --arg tag "$tag" --arg repository "$repo" \
    --arg corpus "$CORPUS_COMMIT" --arg published "$stamp" \
    --argjson semantic "$semantic_activation" '
      {schema:"lex-artifact-pointer/2",collection:$pub,manifest_sha256:$manifest,
       benchmark_manifest_sha256:$benchmark,semantic_activation:$semantic,
       receipt_manifest_sha256:$receipt,release_tag:$tag,release_repository:$repository,
       corpus_commit:$corpus,published_at:$published}
    ' > "$output"
}

publish_pointer_from_bundle() {
  local root="$1" pointer_name="current/$PUBLISHER.json" desired current exists observed
  local current_sha current_etag expected_exists expected_etag expected_sha
  local -a condition
  desired="$work_root/desired-pointer.json"
  make_desired_pointer "$desired"
  expected_exists=$(jq -r \
    'if (.previous_pointer.exists | type) == "boolean" then .previous_pointer.exists else error end' \
    "$root/$cleanup_receipt")
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
  make_desired_pointer "$desired"
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
require_github_immutable_releases
acquire_or_verify_claim

case "$PUBLICATION_PHASE" in
  publish)
    echo "=== validate exact private staging snapshot ==="
    capture_staging_snapshot "$work_root/staging.json"
    download_staging_snapshot "$work_root/staging.json"
    if pin_public_release; then
      download_github_bundle public
      publish_pointer_from_bundle "$bundle_root"
      echo "published_manifest=$manifest_id"
      exit 0
    fi
    echo "=== authenticate previous pointer and enforce monotonic corpus lineage ==="
    snapshot_current_pointer
    resolve_sources_and_build_bundle
    verify_complete_bundle "$bundle_root"
    echo "=== prepare exact recoverable GitHub draft ==="
    prepare_exact_draft "$bundle_root"
    finalize_and_verify_public_release
    publish_pointer_from_bundle "$bundle_root"
    echo "published_manifest=$manifest_id"
    ;;
  postflight-cleanup)
    echo "=== verify public GitHub release ==="
    pin_public_release
    download_github_bundle public
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
