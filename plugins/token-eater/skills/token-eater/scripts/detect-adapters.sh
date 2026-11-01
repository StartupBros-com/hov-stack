#!/usr/bin/env bash
# detect-adapters.sh — scan for installed model CLIs from the registry and report which
# ones are available to spend.
#
# Output: one TSV line per registered adapter:
#   <available|missing>\t<id>\t<resolved_path|->
# Exit code: 0 if at least one adapter is available, 3 if none (plain-stop signal for the caller).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG="${TOKEN_EATER_REGISTRY:-$ROOT/adapters.yaml}"
[ -f "$REG" ] || { echo "registry not found: $REG" >&2; exit 2; }

# Extract each adapter id from the flat YAML list.
# (Deliberately dependency-free: no yq/python required on a user's machine.)
parse_registry() {
  awk '
    /^[[:space:]]*-[[:space:]]*id:/ { id=$0; sub(/.*id:[[:space:]]*/,"",id); gsub(/"/,"",id); print id }
  ' "$REG"
}

available=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if path="$(command -v "$id" 2>/dev/null)"; then
    printf 'available\t%s\t%s\n' "$id" "$path"
    available=$((available + 1))
  else
    printf 'missing\t%s\t-\n' "$id"
  fi
done < <(parse_registry)

[ "$available" -gt 0 ] || exit 3
