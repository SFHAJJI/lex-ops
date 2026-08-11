#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 4 ] || { echo "usage: $0 repository commit trusted-ref label" >&2; exit 2; }
repository="$1"
commit="$2"
trusted_ref="$3"
label="$4"

[[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: $label must be a full lowercase commit SHA" >&2; exit 2; }
git -C "$repository" cat-file -e "$commit^{commit}" 2>/dev/null \
  || { echo "ERROR: $label is not present" >&2; exit 2; }
git -C "$repository" show-ref --verify --quiet "$trusted_ref" \
  || { echo "ERROR: trusted history $trusted_ref is not present for $label" >&2; exit 2; }
git -C "$repository" merge-base --is-ancestor "$commit" "$trusted_ref" \
  || { echo "ERROR: $label is not on $trusted_ref" >&2; exit 2; }
