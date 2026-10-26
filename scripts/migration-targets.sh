#!/usr/bin/env bash
# Shared application-to-Supabase-project registry for migration controllers.
# Safe to source: declarations and read-only helpers only.

# The repository and the app-to-project-ref map are service identifiers, so they are not in
# the tree. They come from a JSON file: $HOV_STACK_MIGRATION_TARGETS_FILE, else
# migration-targets.json in the overlay directory the other overlay readers use,
# $HOV_STACK_OVERLAY or $XDG_CONFIG_HOME/hov-stack (default $HOME/.config/hov-stack).
# config/migration-targets.example.json shows the shape. With no file present every
# accessor below fails closed with a message naming the path and the variable.
migration_targets_file() {
  if [ -n "${HOV_STACK_MIGRATION_TARGETS_FILE:-}" ]; then
    printf '%s\n' "$HOV_STACK_MIGRATION_TARGETS_FILE"
  else
    printf '%s\n' "${HOV_STACK_OVERLAY:-${XDG_CONFIG_HOME:-$HOME/.config}/hov-stack}/migration-targets.json"
  fi
}

# Print one jq query's result over the targets file; non-zero with a message when the file
# is missing or malformed.
migration_targets_query() {
  local file
  file=$(migration_targets_file)
  [ -r "$file" ] || {
    echo "migration-targets: no target map at $file (set HOV_STACK_MIGRATION_TARGETS_FILE or create it; see config/migration-targets.example.json)" >&2
    return 1
  }
  jq -er "$1" "$file" 2>/dev/null || {
    echo "migration-targets: $file is not a valid target map (see config/migration-targets.example.json)" >&2
    return 1
  }
}

# <owner>/<name> of the canonical application repository.
migration_origin_repo() {
  migration_targets_query '.repository | select(type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))'
}

migration_default_repo() {
  local repo
  repo=$(migration_origin_repo) || return 1
  printf '%s\n' "$HOME/SITES/${repo##*/}"
}

migration_target_entries() {
  migration_targets_query '.apps | to_entries[] | select(.value | type == "string" and test("^[a-z]{20}$")) | "\(.key):\(.value)"'
}

# Both accessors capture the query first: a loop over a process substitution would return
# the loop's status and hide a missing or malformed map behind an empty, successful answer.
migration_target_apps() {
  local entries entry
  entries=$(migration_target_entries) || return 1
  while IFS= read -r entry; do printf '%s\n' "${entry%%:*}"; done <<< "$entries"
}

migration_target_ref() {
  local target="${1:-}" entries entry
  entries=$(migration_target_entries) || return 1
  while IFS= read -r entry; do
    [ "${entry%%:*}" = "$target" ] || continue
    printf '%s\n' "${entry##*:}"
    return 0
  done <<< "$entries"
  return 1
}

# Exact ledger/local identities that predate the fail-closed identity gate.
# Output is: recorded remote name<TAB>current local filename suffix. A null
# remote name is represented as <unnamed>. Both sides are compared, so this
# cannot excuse a future local rename or a different remote identity.
migration_legacy_identity() {
  local file
  file=$(migration_targets_file)
  [ -r "$file" ] || return 1
  jq -er --arg app "${1:-}" --arg version "${2:-}" '
    .legacy_identities[$app][$version]
    | select(type == "object" and has("remote") and has("local"))
    | select((.remote == null or (.remote | type == "string")) and (.local | type == "string"))
    | "\(if .remote == null then "<unnamed>" else .remote end)\t\(.local)"
  ' "$file" 2>/dev/null
}
