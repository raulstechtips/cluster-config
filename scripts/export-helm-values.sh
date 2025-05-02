#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/../apps"

helm list -A -q | while read -r rel; do
  ns=$(helm list -A | awk -v r="$rel" '$1==r{print $2}')
  mkdir -p "$DEST/$rel/values"
  helm get values "$rel" -n "$ns" -o yaml \
    > "$DEST/$rel/values/prod.yaml"
  echo "✔  $rel → values/prod.yaml"
done
