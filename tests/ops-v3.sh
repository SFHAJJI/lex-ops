#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_paths=$(cat <<'PATHS'
.gitattributes
.github/workflows/ops-v3.yml
.github/workflows/v3-preview.yml
.gitignore
LICENSE
README.md
SECURITY.md
scripts/v3-preview.sh
tests/ops-v3.sh
PATHS
)
actual_paths="$(git ls-files | LC_ALL=C sort)"
test "$actual_paths" = "$expected_paths"

bash -n scripts/v3-preview.sh
grep -Fq 'name: ops-v3' .github/workflows/ops-v3.yml
grep -Fq 'name: v3-preview' .github/workflows/v3-preview.yml

fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"

cat > "$fixture_root/bin/az" <<'AZ'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_AZ_LOG"
case "$1 $2" in
  'containerapp show')
    if test -f "${FAKE_AZ_SHOW_ERROR_FILE:-/nonexistent}"; then
      exit 9
    fi
    if test -n "${FAKE_AZ_SHOW_EXIT:-}"; then
      exit "$FAKE_AZ_SHOW_EXIT"
    fi
    test -f "$FAKE_AZ_STATE" || exit 3
    cat <<JSON
{"name":"$V3_APP_NAME","properties":{"managedEnvironmentId":"/subscriptions/example/resourceGroups/$V3_RESOURCE_GROUP/providers/Microsoft.App/managedEnvironments/$V3_ENVIRONMENT","configuration":{"ingress":{"external":true,"fqdn":"$V3_APP_NAME.example.test","targetPort":8080,"customDomains":[]},"registries":[{"server":"${FAKE_REGISTRY_SERVER:-crsoufien3orem.azurecr.io}","identity":"$V3_REGISTRY_IDENTITY"}]},"template":{"containers":[{"image":"$V3_IMAGE"}],"scale":{"minReplicas":0,"maxReplicas":1}}}}
JSON
    ;;
  'containerapp create')
    touch "$FAKE_AZ_STATE"
    ;;
  'containerapp delete')
    rm -f -- "$FAKE_AZ_STATE"
    if test -n "${FAKE_AZ_SHOW_ERROR_FILE:-}"; then
      touch "$FAKE_AZ_SHOW_ERROR_FILE"
    fi
    ;;
  *)
    echo "unexpected az command: $*" >&2
    exit 9
    ;;
esac
AZ

cat > "$fixture_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if test -n "${FAKE_CURL_FAIL_FIRST:-}"; then
  count=0
  test ! -f "$FAKE_CURL_COUNT" || count="$(< "$FAKE_CURL_COUNT")"
  count=$((count + 1))
  printf '%s' "$count" > "$FAKE_CURL_COUNT"
  if test "$count" -eq 1; then
    exit 22
  fi
fi
case "$url" in
  */health/ready)
    : > "$output"
    printf '204'
    ;;
  *family=eli*)
    printf '%s' '{"branch":"success","schema":"lex-v3-synthetic-resolve-envelope/1","synthetic":true,"object_type":"envelope","status":"ok","matched_coordinate":"eli/synthetic-preview","result":{"objects":[{}]}}' > "$output"
    printf '200'
    ;;
  *family=historical_legal_id*)
    printf '%s' '{"branch":"refusal","schema":"lex-v3-synthetic-resolve-envelope/1","synthetic":true,"object_type":"envelope","status":"identifier_unknown","refusal":{"asserts_absence_of_law":false}}' > "$output"
    printf '200'
    ;;
  *)
    echo "unexpected curl target: $url" >&2
    exit 8
    ;;
esac
CURL
chmod +x "$fixture_root/bin/az" "$fixture_root/bin/curl"

export PATH="$fixture_root/bin:$PATH"
export MSYS_NO_PATHCONV=1
export PYTHON_BIN="${PYTHON_BIN:-python}"
export FAKE_AZ_LOG="$fixture_root/az.log"
export FAKE_AZ_STATE="$fixture_root/app.exists"
export FAKE_CURL_COUNT="$fixture_root/curl.count"
export V3_APP_NAME='lex-v3-preview-123-1'
export V3_RESOURCE_GROUP='rg-platform'
export V3_ENVIRONMENT='cae-platform-law'
export V3_IMAGE='crsoufien3orem.azurecr.io/lex@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
export V3_REGISTRY_IDENTITY='/subscriptions/example/resourceGroups/rg-platform/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-lex-runtime'

if V3_APP_NAME=production scripts/v3-preview.sh deploy 2>/dev/null; then
  echo 'unsafe app name was accepted' >&2
  exit 1
fi

if V3_IMAGE='crsoufien3orem.azurecr.io/lex:latest' scripts/v3-preview.sh deploy 2>/dev/null; then
  echo 'mutable image reference was accepted' >&2
  exit 1
fi

: > "$FAKE_AZ_LOG"
if FAKE_AZ_SHOW_EXIT=9 scripts/v3-preview.sh deploy 2>/dev/null; then
  echo 'unknown Azure read-back failure was treated as absence' >&2
  exit 1
fi
if grep -Fq 'containerapp create' "$FAKE_AZ_LOG"; then
  echo 'deploy mutated Azure after an unknown read-back failure' >&2
  exit 1
fi

if FAKE_REGISTRY_SERVER='registry.example' scripts/v3-preview.sh deploy >/dev/null 2>&1; then
  echo 'wrong registry server was accepted' >&2
  exit 1
fi
rm -f -- "$FAKE_AZ_STATE"

fqdn="$(scripts/v3-preview.sh deploy)"
test "$fqdn" = 'lex-v3-preview-123-1.example.test'
FAKE_CURL_FAIL_FIRST=1 V3_SMOKE_RETRY_DELAY_SECONDS=0 V3_FQDN="$fqdn" scripts/v3-preview.sh smoke

if FAKE_AZ_SHOW_EXIT=9 scripts/v3-preview.sh teardown 2>/dev/null; then
  echo 'unknown Azure teardown read-back failure was treated as absence' >&2
  exit 1
fi

export FAKE_AZ_SHOW_ERROR_FILE="$fixture_root/show.error"
if scripts/v3-preview.sh teardown 2>/dev/null; then
  echo 'unknown post-delete read-back failure was treated as deletion proof' >&2
  exit 1
fi
unset FAKE_AZ_SHOW_ERROR_FILE
rm -f -- "$fixture_root/show.error"
touch "$FAKE_AZ_STATE"
scripts/v3-preview.sh teardown
test ! -e "$FAKE_AZ_STATE"
grep -Fq 'containerapp create' "$FAKE_AZ_LOG"
grep -Fq -- '--min-replicas 0' "$FAKE_AZ_LOG"
grep -Fq -- '--max-replicas 1' "$FAKE_AZ_LOG"
grep -Fq -- "--image $V3_IMAGE" "$FAKE_AZ_LOG"
grep -Fq -- "--user-assigned $V3_REGISTRY_IDENTITY" "$FAKE_AZ_LOG"
grep -Fq -- "--environment $V3_ENVIRONMENT" "$FAKE_AZ_LOG"
grep -Fq -- '--registry-server crsoufien3orem.azurecr.io' "$FAKE_AZ_LOG"
grep -Fq -- "--registry-identity $V3_REGISTRY_IDENTITY" "$FAKE_AZ_LOG"
grep -Fq 'containerapp delete' "$FAKE_AZ_LOG"

echo 'ops-v3 checks passed'
