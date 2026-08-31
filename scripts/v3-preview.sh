#!/usr/bin/env bash
set -euo pipefail

python_bin="${PYTHON_BIN:-python3}"

require_environment() {
  : "${V3_APP_NAME:?V3_APP_NAME is required}"
  : "${V3_RESOURCE_GROUP:?V3_RESOURCE_GROUP is required}"
  : "${V3_ENVIRONMENT:?V3_ENVIRONMENT is required}"
  : "${V3_IMAGE:?V3_IMAGE is required}"
  : "${V3_PREVIEW_PULL_IDENTITY:?V3_PREVIEW_PULL_IDENTITY is required}"

  [[ "$V3_APP_NAME" =~ ^lex-v3-preview-[0-9]+-[0-9]+$ ]] \
    || { echo 'preview app name is unsafe' >&2; exit 2; }
  [[ "$V3_IMAGE" =~ ^crsoufien3orem\.azurecr\.io/[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] \
    || { echo 'preview image must be immutable' >&2; exit 2; }
}

read_back() {
  az resource show \
    --resource-group "$V3_RESOURCE_GROUP" \
    --resource-type Microsoft.App/containerApps \
    --name "$V3_APP_NAME" \
    --output json \
    --only-show-errors
}

verify_read_back() {
  local state="$1"
  STATE_JSON="$state" "$python_bin" - <<'PY'
import json
import os

state = json.loads(os.environ["STATE_JSON"])
properties = state["properties"]
configuration = properties["configuration"]
container = properties["template"]["containers"][0]
scale = properties["template"]["scale"]
registries = configuration.get("registries", [])
registry_server = os.environ["V3_IMAGE"].split("/", 1)[0]

assert state["name"] == os.environ["V3_APP_NAME"]
assert properties["managedEnvironmentId"].casefold().endswith(
    ("/" + os.environ["V3_ENVIRONMENT"]).casefold()
)
assert configuration["ingress"]["external"] is True
assert configuration["ingress"]["targetPort"] == 8080
assert configuration["ingress"].get("customDomains") in (None, [])
assert container["image"] == os.environ["V3_IMAGE"]
assert scale["minReplicas"] == 0
assert scale["maxReplicas"] == 1
assert any(
    item.get("server", "").casefold() == registry_server.casefold()
    and item.get("identity", "").casefold() == os.environ["V3_PREVIEW_PULL_IDENTITY"].casefold()
    for item in registries
), (registries, registry_server, os.environ["V3_PREVIEW_PULL_IDENTITY"])
assert configuration["ingress"]["fqdn"]
print(configuration["ingress"]["fqdn"])
PY
}

deploy() {
  local existing_state read_status
  set +e
  existing_state="$(read_back)"
  read_status=$?
  set -e
  case "$read_status" in
    0)
      echo 'preview app already exists' >&2
      exit 1
      ;;
    3) ;;
    *) return "$read_status" ;;
  esac

  local registry_server="${V3_IMAGE%%/*}"
  az containerapp create \
    --resource-group "$V3_RESOURCE_GROUP" \
    --name "$V3_APP_NAME" \
    --environment "$V3_ENVIRONMENT" \
    --image "$V3_IMAGE" \
    --user-assigned "$V3_PREVIEW_PULL_IDENTITY" \
    --registry-server "$registry_server" \
    --registry-identity "$V3_PREVIEW_PULL_IDENTITY" \
    --ingress external \
    --target-port 8080 \
    --min-replicas 0 \
    --max-replicas 1 \
    --output none \
    --only-show-errors

  verify_read_back "$(read_back)"
}

smoke() {
  : "${V3_FQDN:?V3_FQDN is required}"
  local scratch
  scratch="$(mktemp -d)"

  if ! bounded_get "$scratch/health" "https://$V3_FQDN/health/ready"; then
    rm -rf -- "$scratch"
    return 1
  fi
  if ! bounded_get "$scratch/success.json" \
    "https://$V3_FQDN/api/v3-preview/resolve?family=eli&coordinate=eli%2Fsynthetic-preview"; then
    rm -rf -- "$scratch"
    return 1
  fi
  if ! bounded_get "$scratch/refusal.json" \
    "https://$V3_FQDN/api/v3-preview/resolve?family=historical_legal_id&coordinate=historical_legal_id%3Asynthetic-preview"; then
    rm -rf -- "$scratch"
    return 1
  fi

  SUCCESS_JSON="$(< "$scratch/success.json")" \
    REFUSAL_JSON="$(< "$scratch/refusal.json")" \
    "$python_bin" - <<'PY'
import json
import os

success = json.loads(os.environ["SUCCESS_JSON"])
refusal = json.loads(os.environ["REFUSAL_JSON"])

assert success["branch"] == "success"
assert success["schema"] == "lex-v3-synthetic-resolve-envelope/1"
assert success["synthetic"] is True
assert success["object_type"] == "envelope"
assert success["status"] == "ok"
assert success["matched_coordinate"] == "eli/synthetic-preview"
assert len(success["result"]["objects"]) == 1
assert refusal["branch"] == "refusal"
assert refusal["schema"] == "lex-v3-synthetic-resolve-envelope/1"
assert refusal["synthetic"] is True
assert refusal["object_type"] == "envelope"
assert refusal["status"] == "identifier_unknown"
assert refusal["refusal"]["asserts_absence_of_law"] is False
PY

  rm -rf -- "$scratch"
}

bounded_get() {
  local output="$1"
  local url="$2"
  local retry_delay="${V3_SMOKE_RETRY_DELAY_SECONDS:-3}"
  local attempt

  for attempt in 1 2 3 4; do
    if curl --silent --show-error --fail-with-body \
      --connect-timeout 10 --max-time 30 --output "$output" "$url" >/dev/null; then
      return 0
    fi
    test "$attempt" -eq 4 || sleep "$retry_delay"
  done
  return 1
}

teardown() {
  local state read_status
  set +e
  state="$(read_back)"
  read_status=$?
  set -e
  case "$read_status" in
    0) ;;
    3) return 0 ;;
    *) return "$read_status" ;;
  esac

  az containerapp delete \
    --resource-group "$V3_RESOURCE_GROUP" \
    --name "$V3_APP_NAME" \
    --yes \
    --output none \
    --only-show-errors

  set +e
  state="$(read_back)"
  read_status=$?
  set -e
  case "$read_status" in
    0)
      echo 'preview deletion was not observable' >&2
      exit 1
      ;;
    3) ;;
    *) return "$read_status" ;;
  esac
}

require_environment
case "${1:-}" in
  deploy) deploy ;;
  smoke) smoke ;;
  teardown) teardown ;;
  *) echo 'usage: v3-preview.sh deploy|smoke|teardown' >&2; exit 2 ;;
esac
