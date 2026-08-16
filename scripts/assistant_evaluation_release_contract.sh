# shellcheck shell=bash

fetch_release_snapshot() {
  local output="$1"
  [[ "${EVALUATION_RELEASE_ID:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$EVALUATION_REPOSITORY/releases/$EVALUATION_RELEASE_ID" > "$output"
}

validate_release_tag() {
  local tag_ref="$1"
  jq -e --arg ref "refs/tags/$EVALUATION_RELEASE" \
    --arg commit "$WORKFLOW_COMMIT" '
      .ref == $ref
      and .object.type == "commit"
      and .object.sha == $commit
    ' "$tag_ref" >/dev/null
}

ensure_release_tag() {
  local state="$1" tag_ref="$2"
  local endpoint="repos/$EVALUATION_REPOSITORY/git/ref/tags/$EVALUATION_RELEASE"
  if gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
      "$endpoint" > "$tag_ref" 2>/dev/null; then
    validate_release_tag "$tag_ref"
    return
  fi
  [ "$state" = draft ] || return 1
  gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$EVALUATION_REPOSITORY/git/refs" \
    -f "ref=refs/tags/$EVALUATION_RELEASE" \
    -f "sha=$WORKFLOW_COMMIT" >/dev/null 2>&1 || true
  gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    "$endpoint" > "$tag_ref" || return 1
  validate_release_tag "$tag_ref"
}

write_expected_release_names() {
  local bootstrap="$1" output="$2"
  { [ "$bootstrap" = false ] || [ "$bootstrap" = true ]; } || return 1
  jq -cn --argjson bootstrap "$bootstrap" '
    [
      "assistant-eval-report.json",
      "assistant-cases-v3.json",
      "assistant-cases-v3.review.json",
      "assistant-cases-v3.review.sig",
      "assistant-eval-admission.json",
      "assistant-eval-admission.sig",
      "assistant-browser-evidence.json",
      "assistant-eval.manifest.json",
      "assistant-eval.manifest.sig"
    ] + (if $bootstrap then [
      "bootstrap-equivalence.json",
      "bootstrap-equivalence.manifest.json",
      "bootstrap-equivalence.manifest.sig"
    ] else [] end) | sort
  ' > "$output"
}

canonicalize_revision_routes() {
  local input="$1" output="$2"
  jq -eS '
    if type == "array"
      and length > 0
      and ([.[].id] | length) == ([.[].id] | unique | length)
      and ([.[].name] | length) == ([.[].name] | unique | length)
      and all(.[];
        (.id | type) == "string" and (.id | length) > 0
        and (.name | type) == "string" and (.name | length) > 0
        and (.properties.active | type) == "boolean"
        and ((.properties.trafficWeight // 0) | type) == "number"
        and ((.properties.trafficWeight // 0) % 1) == 0
        and (.properties.trafficWeight // 0) >= 0
        and (.properties.trafficWeight // 0) <= 100)
    then map({
      id,
      name,
      active:.properties.active,
      traffic_weight:(.properties.trafficWeight // 0)
    }) | sort_by(.name)
    else error("revision route inventory is malformed")
    end
  ' "$input" > "$output"
}

validate_utc_expiry() {
  local expiry="${1-}"
  [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?(Z|\+00:00)$ ]] \
    && date --utc --date="$expiry" +%s >/dev/null 2>&1
}

wait_for_utc_expiry() {
  local expiry="${1-}" maximum_wait_seconds="${2-}"
  local expiry_epoch now_epoch wait_seconds
  validate_utc_expiry "$expiry" \
    && [[ "$maximum_wait_seconds" =~ ^(0|[1-9][0-9]{0,3})$ ]] \
    && (( maximum_wait_seconds <= 1200 )) \
    || return 1
  expiry_epoch=$(date --utc --date="$expiry" +%s) \
    && [[ "$expiry_epoch" =~ ^[0-9]+$ ]] \
    || return 1
  # GNU date truncates fractional instants; round expiry up so publication
  # cannot occur during the final fractional second of a signed capability.
  if [[ "$expiry" == *.* ]]; then
    expiry_epoch=$((expiry_epoch + 1))
  fi
  now_epoch=$(date --utc +%s) \
    && [[ "$now_epoch" =~ ^[0-9]+$ ]] \
    || return 1
  wait_seconds=$((expiry_epoch - now_epoch))
  (( wait_seconds <= maximum_wait_seconds )) || return 1
  if (( wait_seconds > 0 )); then
    sleep "$wait_seconds" || return 1
  fi
  now_epoch=$(date --utc +%s) \
    && [[ "$now_epoch" =~ ^[0-9]+$ ]] \
    && (( now_epoch >= expiry_epoch ))
}

deactivate_zero_traffic_candidate() {
  local resource_group="$1" container_app="$2" candidate_revision="$3"
  local attempt state active
  state="${RUNNER_TEMP:?}/candidate-cleanup-state.json"
  for attempt in {1..6}; do
    az containerapp revision show -g "$resource_group" -n "$container_app" \
      --revision "$candidate_revision" -o json > "$state" || return 1
    jq -e --arg candidate "$candidate_revision" '
      .name == $candidate
      and (.properties.active | type) == "boolean"
      and (.properties.trafficWeight // 0) == 0
    ' "$state" >/dev/null || return 1
    active=$(jq -r '.properties.active' "$state") || return 1
    [ "$active" = false ] && return 0
    [ "$attempt" != 6 ] || return 1
    az containerapp revision deactivate -g "$resource_group" -n "$container_app" \
      --revision "$candidate_revision" >/dev/null 2>&1 || true
    sleep "$attempt"
  done
  return 1
}

validate_bootstrap_abandonment_prestate() {
  local resource_group="$1" container_app="$2" candidate_revision="$3"
  local rollback_revision="$4" app_state routes
  app_state="${RUNNER_TEMP:?}/bootstrap-abandonment-app.json"
  routes="${RUNNER_TEMP:?}/bootstrap-abandonment-routes.json"
  az containerapp show -g "$resource_group" -n "$container_app" -o json \
    > "$app_state" || return 1
  jq -e '.properties.configuration.maxInactiveRevisions == 1' \
    "$app_state" >/dev/null || return 1
  az containerapp revision list -g "$resource_group" -n "$container_app" \
    --all -o json > "$routes" || return 1
  jq -e --arg candidate "$candidate_revision" --arg rollback "$rollback_revision" '
    length == 3
    and ([.[] | select(.properties.active == false) | .name] == [$rollback])
    and ([.[] | select(.properties.active == true)] | length) == 2
    and (any(.[]; .name == $candidate and .properties.active == true
      and (.properties.trafficWeight // 0) == 0))
    and (any(.[]; .name == $rollback and .properties.active == false
      and (.properties.trafficWeight // 0) == 0))
    and ([.[] | select((.properties.trafficWeight // 0) > 0)] | length) == 1
    and ([.[] | select((.properties.trafficWeight // 0) == 100
      and .properties.active == true
      and .name != $candidate and .name != $rollback)] | length) == 1
  ' "$routes" >/dev/null
}

download_release_assets_by_id() {
  local root="$1" release="$2"
  local asset_id asset_name inventory
  [ ! -e "$root" ] || return 1
  mkdir "$root" || return 1
  jq -e '
    (.assets | type) == "array" and (.assets | length) > 0
    and ([.assets[].id] | length) == ([.assets[].id] | unique | length)
    and ([.assets[].name] | length) == ([.assets[].name] | unique | length)
    and all(.assets[];
      (.id | type) == "number" and (.id % 1 == 0) and .id > 0
      and (.name | type) == "string"
      and (.name | test("^[A-Za-z0-9._-]+$")))
  ' "$release" >/dev/null || return 1
  inventory="${release}.asset-ids.tsv"
  jq -er '.assets[] | [.id, .name] | @tsv' "$release" \
    | tr -d '\r' > "$inventory" || return 1
  while IFS=$'\t' read -r asset_id asset_name; do
    [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || return 1
    gh api -H 'Accept: application/octet-stream' \
      -H 'X-GitHub-Api-Version: 2026-03-10' \
      "repos/$EVALUATION_REPOSITORY/releases/assets/$asset_id" \
      > "$root/$asset_name" || return 1
  done < "$inventory"
  [ "$(find "$root" -maxdepth 1 -type f | wc -l)" = "$(jq '.assets | length' "$release")" ]
}

validate_release_snapshot() {
  local state="$1" root="$2" expected_names="$3" release="$4" attest="$5"
  local asset path sha size names inventory inventory_json readback downloaded
  { [ "$state" = draft ] || [ "$state" = public ]; } \
    && { [ "$attest" = false ] || [ "$attest" = true ]; } \
    || return 1
  jq -e '
    type == "array" and length > 0 and length == (unique | length)
    and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"))
  ' "$expected_names" >/dev/null || return 1
  names="${release}.names"
  inventory="${release}.assets.jsonl"
  inventory_json="${release}.assets.json"
  jq -er '.[]' "$expected_names" | tr -d '\r' > "$names" || return 1
  : > "$inventory"
  while IFS= read -r asset; do
    path="$root/$asset"
    [ -f "$path" ] || return 1
    sha=$(sha256sum "$path" | cut -d' ' -f1) || return 1
    size=$(wc -c < "$path" | tr -d ' ') || return 1
    jq -cn --arg name "$asset" --arg sha "$sha" --argjson size "$size" \
      '{name:$name,sha256:$sha,size:$size}' >> "$inventory" || return 1
  done < "$names"
  jq -s 'sort_by(.name)' "$inventory" > "$inventory_json" || return 1
  jq -e --arg state "$state" --arg tag "$EVALUATION_RELEASE" \
    --arg target main --slurpfile expected "$inventory_json" '
      .draft == ($state == "draft")
      and .prerelease == false
      and .immutable == ($state == "public")
      and .tag_name == $tag and .target_commitish == $target
      and ((.assets | type) == "array")
      and ([.assets[] | {name,digest,size,state}] | sort_by(.name))
        == ($expected[0]
          | map({name,digest:("sha256:" + .sha256),size,state:"uploaded"})
          | sort_by(.name))
    ' "$release" >/dev/null || return 1
  [ "$state" = public ] && [ "$attest" = true ] || return 0
  gh release verify "$EVALUATION_RELEASE" --repo "$EVALUATION_REPOSITORY" \
    >/dev/null || return 1
  readback=$(mktemp -d) || return 1
  while IFS= read -r asset; do
    path="$root/$asset"
    gh release verify-asset "$EVALUATION_RELEASE" "$path" \
      --repo "$EVALUATION_REPOSITORY" >/dev/null || return 1
    downloaded="$readback/$asset"
    curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
      --retry-delay 2 \
      "https://github.com/$EVALUATION_REPOSITORY/releases/download/$EVALUATION_RELEASE/$asset" \
      -o "$downloaded" || return 1
    [ -f "$downloaded" ] \
      && [ "$(sha256sum "$downloaded" | cut -d' ' -f1)" \
        = "$(sha256sum "$path" | cut -d' ' -f1)" ] \
      && [ "$(wc -c < "$downloaded" | tr -d ' ')" \
        = "$(wc -c < "$path" | tr -d ' ')" ] \
      && cmp --silent "$downloaded" "$path" \
      || return 1
  done < "$names"
}
