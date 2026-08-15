# Verify and publish one exact immutable GitHub release bundle; sourced by the orchestrator.
verify_receipt_header() {
  local root="$1"
  local receipt="$root/$cleanup_receipt" receipt_manifest="$root/$cleanup_manifest"
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
    --arg repository "$repo" --arg guard "$HYBRID_QUARANTINE_GUARD_COMMIT" \
    --arg index "$STAGING_PREFIX/$index" \
    --arg index_etag "$EXPECTED_INDEX_ETAG" --arg index_sha "$EXPECTED_INDEX_SHA256" \
    --argjson index_size "$EXPECTED_INDEX_SIZE" --arg vectors "$STAGING_PREFIX/$vectors" \
    --arg vectors_etag "$EXPECTED_VECTORS_ETAG" --arg vectors_sha "$EXPECTED_VECTORS_SHA256" \
    --argjson vectors_size "$EXPECTED_VECTORS_SIZE" --argjson canonical_assets "$canonical_assets_json" '
      (keys | sort) == ["articles_commit","benchmark_manifest_sha256","build_code_commit",
        "corpus_commit","generated_at","index_manifest_sha256","previous_pointer",
        "public_assets","publisher","purpose","queue_commit","queue_ticket_id","release_repository","release_tag",
        "run_id","runtime_guard_commit","schema","semantic_activation","staging","staging_prefix","workflow_commit"]
      and .schema == "lex-staging-cleanup-receipt/3"
      and .purpose == "delete-exact-published-prebuilt-staging"
      and .generated_at == $generated
      and .publisher == $publisher and .queue_ticket_id == $ticket and .queue_commit == $queue
      and .workflow_commit == $workflow and .run_id == $run and .corpus_commit == $corpus
      and .build_code_commit == $code and .articles_commit == $articles
      and .staging_prefix == $prefix and .release_tag == $tag and .release_repository == $repository
      and .runtime_guard_commit == $guard
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
        and (.size | type == "number" and . >= 0 and . < 2147483648)))
      and ([.public_assets[].name] | length == (unique | length))
      and ([.public_assets[].name] | sort) == $canonical_assets
    ' "$receipt" >/dev/null || { echo "ERROR: signed cleanup receipt identity is not exact" >&2; return 1; }
  manifest_id=$(jq -er .index_manifest_sha256 "$receipt") || return 1
  semantic_activation=$(jq -r \
    'if (.semantic_activation | type) == "boolean" then .semantic_activation else error end' \
    "$receipt") || return 1
  release_notes="Signed index, benchmark activation evidence, and whole-release manifest.

Semantic activation: $semantic_activation
Runtime quarantine guard: $HYBRID_QUARANTINE_GUARD_COMMIT"
  benchmark_manifest_id=$(jq -er .benchmark_manifest_sha256 "$receipt") || return 1
  receipt_manifest_id=$(sha256_file "$receipt_manifest") || return 1
  previous_pointer_exists=$(jq -r \
    'if (.previous_pointer.exists | type) == "boolean" then .previous_pointer.exists else error end' \
    "$receipt") || return 1
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
    --arg repository "$repo" --arg guard "$HYBRID_QUARANTINE_GUARD_COMMIT" \
    --arg receipt_sha "$(sha256_file "$receipt")" --argjson semantic "$semantic_activation" '
      .key_id == $id and .code_commit == $code
      and (.files | length == 1) and .files[0].path == $receipt
      and .files[0].sha256 == $receipt_sha
      and (.sources | keys | sort) == ["index_manifest_sha256","publisher","purpose",
        "queue_ticket_id","release_repository","run_id","runtime_guard_commit",
        "semantic_activation","workflow_commit"]
      and .sources.purpose == "delete-exact-published-prebuilt-staging"
      and .sources.publisher == $publisher and .sources.queue_ticket_id == $ticket
      and .sources.release_repository == $repository
      and .sources.workflow_commit == $workflow and .sources.run_id == $run
      and .sources.index_manifest_sha256 == $manifest
      and .sources.runtime_guard_commit == $guard
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
    --arg code "$publication_tool_commit" --arg guard "$HYBRID_QUARANTINE_GUARD_COMMIT" \
    --argjson semantic "$semantic_activation" '
      .key_id == $id and .code_commit == $code
      and (.files | length == 1) and .files[0].path == $report and .files[0].sha256 == $report_sha
      and (.sources | keys | sort) == ["collection","corpus_commit","index_manifest_sha256",
        "queue_ticket_id","runtime_guard_commit","semantic_activation"]
      and .sources.collection == $pub and .sources.corpus_commit == $corpus
      and .sources.queue_ticket_id == $ticket and .sources.index_manifest_sha256 == $manifest
      and .sources.runtime_guard_commit == $guard
      and .sources.semantic_activation == ($semantic | tostring)
    ' "$root/$benchmark_manifest" >/dev/null \
    || { echo "ERROR: benchmark manifest does not bind semantic activation" >&2; return 1; }
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-benchmark \
    "$root/$benchmark" "$PUBLISHER" "$publication_tool_commit" "$CORPUS_COMMIT" \
    "$manifest_id" "$EXPECTED_INDEX_SIZE" "$EXPECTED_VECTORS_SIZE" \
    "$semantic_activation" || return 1
  [ "$(jq -r 'if (.activation_gate_passed | type) == "boolean" then .activation_gate_passed else error end' \
      "$root/$benchmark")" = "$semantic_activation" ] \
    || { echo "ERROR: receipt semantic activation differs from the signed benchmark" >&2; return 1; }
}

validate_tag_snapshot() {
  local output="$1"
  jq -e --arg ref "refs/tags/$tag" --arg corpus "$CORPUS_COMMIT" \
    '.ref == $ref and .object.type == "commit" and .object.sha == $corpus' "$output" >/dev/null \
    || { echo "ERROR: release tag does not target the ticketed corpus commit" >&2; return 1; }
}

validate_tag_target() {
  local output="$1"
  gh_api "repos/$repo/git/ref/tags/$tag" > "$output" || return 1
  validate_tag_snapshot "$output"
}

fetch_release_snapshot() {
  local output="$1"
  [[ "$release_id" =~ ^[1-9][0-9]*$ ]] || return 1
  gh_api "repos/$repo/releases/$release_id" > "$output"
}

discover_exact_draft() {
  local locator="$work_root/draft-locator.json" snapshot="$work_root/draft-discovered.json"
  local owner="${repo%%/*}" name="${repo#*/}" query
  [ -n "$owner" ] && [ -n "$name" ] && [ "$repo" = "$owner/$name" ] && [[ "$name" != */* ]] \
    || return 2
  query='query($owner:String!,$name:String!,$tag:String!){repository(owner:$owner,name:$name){nameWithOwner release(tagName:$tag){databaseId tagName}}}'
  gh_api graphql -f query="$query" -f owner="$owner" -f name="$name" -f tag="$tag" \
    > "$locator" 2>/dev/null || return 2
  jq -e --arg repo "$repo" '
      ((.errors // []) == []) and .data.repository.nameWithOwner == $repo
      and (.data.repository | has("release"))
      and (.data.repository.release == null or (.data.repository.release | type) == "object")
    ' "$locator" >/dev/null || return 2
  if jq -e '.data.repository.release == null' "$locator" >/dev/null; then
    return 1
  fi
  release_id=$(jq -er --arg tag "$tag" '
      .data.repository.release | select(.tagName == $tag) | .databaseId
      | select(type == "number" and . > 0 and . == floor)
    ' "$locator") || return 2
  fetch_release_snapshot "$snapshot" || return 2
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" \
    --arg name "index-$PUBLISHER ${ticket_id:0:12}" --arg notes "$release_notes" '
      .id == $id and .tag_name == $tag and .target_commitish == $corpus
      and .name == $name and .body == $notes and .published_at == null
      and .draft == true and .prerelease == false
      and .immutable == false and (.assets | type) == "array"
      and ([.assets[].id] | length) == ([.assets[].id] | unique | length)
      and ([.assets[].name] | length) == ([.assets[].name] | unique | length)
    ' "$snapshot" >/dev/null || return 2
}

pin_public_release() {
  local locator="$work_root/public-locator.json" snapshot="$work_root/public-pinned.json"
  gh_api "repos/$repo/releases/tags/$tag" > "$locator" 2>/dev/null || return 1
  release_id=$(jq -er --arg tag "$tag" '
      select(.tag_name == $tag) | .id
      | select(type == "number" and . > 0 and . == floor)
    ' "$locator") || return 1
  fetch_release_snapshot "$snapshot" || return 1
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" '
      .id == $id and .tag_name == $tag and .target_commitish == $corpus
      and .draft == false and .prerelease == false and .immutable == true
    ' "$snapshot" >/dev/null
}

ensure_exact_tag() {
  local output="$work_root/draft-tag.json" endpoint="repos/$repo/git/ref/tags/$tag" attempt
  if gh_api "$endpoint" > "$output" 2>/dev/null; then
    validate_tag_snapshot "$output"
    return $?
  fi
  gh_api --method POST "repos/$repo/git/refs" \
    -f "ref=refs/tags/$tag" -f "sha=$CORPUS_COMMIT" >/dev/null 2>&1 || true
  for attempt in $(seq 1 12); do
    if gh_api "$endpoint" > "$output" 2>/dev/null; then
      validate_tag_snapshot "$output"
      return $?
    fi
    [ "$attempt" -eq 12 ] || sleep 5
  done
  echo "ERROR: release tag was not readable after bounded creation read-back" >&2
  return 1
}

write_asset_inventory() {
  local root="$1" output="$2" asset
  local item="$output.items"
  : > "$item"
  while IFS= read -r asset; do
    [ -f "$root/$asset" ] || return 1
    jq -cn --arg name "$asset" --arg sha "$(sha256_file "$root/$asset")" \
      --argjson size "$(size_file "$root/$asset")" '{name:$name,sha256:$sha,size:$size}' \
      >> "$item" || return 1
  done < <(jq -r '.[]' "$expected_assets_json")
  jq -s 'sort_by(.name)' "$item" > "$output" || return 1
  rm -f "$item"
}

validate_draft_inventory() {
  local snapshot="$1" expected="$2" complete="$3"
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" \
    --arg name "index-$PUBLISHER ${ticket_id:0:12}" --arg notes "$release_notes" \
    --argjson complete "$complete" --slurpfile expected "$expected" '
      ($expected[0] | map({key:.name,value:{digest:("sha256:" + .sha256),size:.size}})
        | from_entries) as $wanted
      | .id == $id and .tag_name == $tag and .target_commitish == $corpus
      and .name == $name and .body == $notes and .published_at == null
      and .draft == true and .prerelease == false and .immutable == false
      and ([.assets[].id] | length) == ([.assets[].id] | unique | length)
      and ([.assets[].name] | length) == ([.assets[].name] | unique | length)
      and all(.assets[]; .state == "uploaded" and (.name as $asset_name
        | $wanted[$asset_name] != null and .digest == $wanted[$asset_name].digest
        and .size == $wanted[$asset_name].size))
      and (if $complete then
        ([.assets[].name] | sort) == ([$wanted | keys[]] | sort)
      else true end)
    ' "$snapshot" >/dev/null
}

upload_missing_assets() {
  local root="$1" expected="$2" snapshot="$work_root/draft-upload.json" asset status
  fetch_release_snapshot "$snapshot" || return 1
  validate_draft_inventory "$snapshot" "$expected" false || return 1
  while IFS= read -r asset; do
    if jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' "$snapshot" >/dev/null; then
      continue
    fi
    if ! status=$(curl --proto '=https' --tlsv1.2 --silent --show-error \
        --connect-timeout 30 --header "Authorization: Bearer $GH_TOKEN" \
        --header 'Content-Type: application/octet-stream' --data-binary "@$root/$asset" \
        "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$asset" \
        --output /dev/null --write-out '%{http_code}'); then
      status=ambiguous
    fi
    if [ "$status" != 201 ]; then
      echo "release asset upload was ambiguous; requiring exact numeric-ID read-back" >&2
    fi
    fetch_release_snapshot "$snapshot" || return 1
    validate_draft_inventory "$snapshot" "$expected" false || return 1
    jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' "$snapshot" >/dev/null \
      || return 1
  done < <(jq -r '.[].name' "$expected")
  validate_draft_inventory "$snapshot" "$expected" true
}

download_draft_asset() {
  local snapshot="$1" asset="$2" output="$3" asset_id
  asset_id=$(jq -er --arg name "$asset" '
      [.assets[] | select(.name == $name)]
      | select(length == 1) | .[0].id
      | select(type == "number" and . > 0 and . == floor)
    ' "$snapshot") || return 1
  gh_api -H 'Accept: application/octet-stream' \
    "repos/$repo/releases/assets/$asset_id" > "$output"
}

download_github_bundle() {
  local state="$1" root release_json tag_json asset exact_assets_json
  root=$(mktemp -d) || return 1
  release_json="$root/release.json"
  fetch_release_snapshot "$release_json" || return 1
  if [ "$state" = draft ]; then
    for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
      download_draft_asset "$release_json" "$asset" "$root/$asset" || return 1
    done
  else
    for asset in "$cleanup_receipt" "$cleanup_manifest" "$cleanup_signature"; do
      curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
        "https://github.com/$repo/releases/download/$tag/$asset" -o "$root/$asset" || return 1
    done
  fi
  verify_receipt_header "$root" || return 1
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" \
    --arg notes "$release_notes" --slurpfile expected "$expected_assets_json" '
      .id == $id and .tag_name == $tag and .target_commitish == $corpus and .body == $notes
      and ([.assets[].name] | sort) == ($expected[0] | sort)
    ' \
    "$release_json" >/dev/null \
    || { echo "ERROR: GitHub release asset inventory is not exact" >&2; return 1; }
  while IFS= read -r asset; do
    [ -f "$root/$asset" ] && continue
    if [ "$state" = draft ]; then
      download_draft_asset "$release_json" "$asset" "$root/$asset" || return 1
    else
      curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
        "https://github.com/$repo/releases/download/$tag/$asset" -o "$root/$asset" || return 1
    fi
  done < <(jq -r '.[]' "$expected_assets_json")
  verify_complete_bundle "$root" || return 1
  exact_assets_json="$root/exact-release-assets.json"
  write_asset_inventory "$root" "$exact_assets_json" || return 1
  jq -e 'all(.[]; .size < 2147483648)' "$exact_assets_json" >/dev/null \
    || { echo "ERROR: GitHub-only release contains an asset at or above 2 GiB" >&2; return 1; }
  tag_json="$root/tag.json"
  validate_tag_target "$tag_json" || return 1
  if [ "$state" = public ]; then
    python3 "$ops_root/scripts/prebuilt_publication_contract.py" validate-release \
      "$release_json" "$tag_json" "$tag" "$CORPUS_COMMIT" "$exact_assets_json" || return 1
    gh release verify "$tag" --repo "$repo" >/dev/null || return 1
    while IFS= read -r asset; do
      gh release verify-asset "$tag" "$root/$asset" --repo "$repo" >/dev/null || return 1
    done < <(jq -r '.[]' "$expected_assets_json")
  else
    validate_draft_inventory "$release_json" "$exact_assets_json" true \
      || { echo "ERROR: draft release identity or asset digests are not exact" >&2; return 1; }
  fi
  bundle_root="$root"
}

require_github_immutable_releases() {
  local setting="$work_root/immutable-release-setting.json"
  gh release verify --help >/dev/null || return 1
  gh release verify-asset --help >/dev/null || return 1
  gh_api "repos/$repo/immutable-releases" > "$setting" || return 1
  python3 "$ops_root/scripts/prebuilt_publication_contract.py" \
    validate-immutable-release-setting "$setting" || return 1
}

prepare_exact_draft() {
  local root="$1" status release_json="$work_root/draft-release.json"
  local expected="$work_root/local-release-assets.json" payload="$work_root/create-release.json"
  require_github_immutable_releases
  write_asset_inventory "$root" "$expected" || return 1
  if [ -z "$release_id" ]; then
    if discover_exact_draft; then
      :
    else
      status=$?
      [ "$status" = 1 ] || return 1
      jq -n --arg tag "$tag" --arg target "$CORPUS_COMMIT" \
        --arg name "index-$PUBLISHER ${ticket_id:0:12}" --arg body "$release_notes" \
        '{tag_name:$tag,target_commitish:$target,name:$name,body:$body,draft:true,prerelease:false}' \
        > "$payload" || return 1
      if gh_api --method POST "repos/$repo/releases" --input "$payload" > "$release_json"; then
        release_id=$(jq -er '.id | select(type == "number" and . > 0 and . == floor)' \
          "$release_json") || return 1
      else
        echo "draft creation response was ambiguous; requiring exact discovery" >&2
        release_id=
        discover_exact_draft || return 1
      fi
    fi
  fi
  fetch_release_snapshot "$release_json" || return 1
  validate_draft_inventory "$release_json" "$expected" false \
    || { echo "ERROR: refusing to mutate a changed draft release" >&2; return 1; }
  ensure_exact_tag || return 1
  upload_missing_assets "$root" "$expected" || return 1
  download_github_bundle draft
}

finalize_and_verify_public_release() {
  local state attempt status prepublish="$work_root/prepublish-release.json"
  fetch_release_snapshot "$prepublish" || return 1
  validate_draft_inventory "$prepublish" "$bundle_root/exact-release-assets.json" true || return 1
  validate_tag_target "$work_root/prepublish-tag.json" || return 1
  require_github_immutable_releases || return 1
  jq -n '{draft:false,make_latest:"false"}' > "$work_root/publish-release.json" || return 1
  if ! status=$(curl --proto '=https' --tlsv1.2 --silent --show-error \
      --connect-timeout 30 --request PATCH --header "Authorization: Bearer $GH_TOKEN" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2026-03-10' --header 'Content-Type: application/json' \
      --data-binary "@$work_root/publish-release.json" \
      "https://api.github.com/repos/$repo/releases/$release_id" \
      --output "$work_root/published-response.json" --write-out '%{http_code}'); then
    status=ambiguous
  fi
  if [ "$status" != 200 ]; then
    echo "release publication response was ambiguous; requiring exact numeric-ID read-back" >&2
  fi
  for attempt in $(seq 1 12); do
    state="$work_root/public-release-$attempt.json"
    if fetch_release_snapshot "$state" \
        && jq -e --argjson id "$release_id" --arg tag "$tag" --arg corpus "$CORPUS_COMMIT" '
          .id == $id and .tag_name == $tag and .target_commitish == $corpus
          and .draft == false and .prerelease == false and .immutable == true
        ' "$state" >/dev/null \
        && validate_tag_target "$work_root/public-tag-$attempt.json"; then
      if download_github_bundle public; then
        return 0
      fi
      echo "immutable release attestation is not yet verifiable; retrying" >&2
    fi
    sleep 5
  done
  echo "ERROR: GitHub release did not become immutable" >&2
  return 1
}
