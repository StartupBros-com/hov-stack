#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
while IFS= read -r -d '' file; do
  printf 'checking %s\n' "$file"
  jq empty "$file"
done < <(find "$root" -path '*/.git' -prune -o -name '*.json' -print0)

while IFS= read -r -d '' file; do
  printf 'checking %s\n' "$file"
  yq eval '.' "$file" >/dev/null
done < <(find "$root" -path '*/.git' -prune -o \( -name '*.yaml' -o -name '*.yml' \) -print0)
