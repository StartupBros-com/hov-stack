#!/usr/bin/env bash
# Shared git-derived scope check for delegation adapters (Bash 3.2 compatible).
# Inputs: worktree directory and optional newline-delimited allowlist path.
# Outputs (reset on every call): CHANGED, MADE_CHANGES, SCOPE_VIOLATION, OFFENDERS.
# The caller decides the exit code; a scope violation is data, not helper failure.
delegate_collect_changes_and_scope() {
  local WT="$1" ALLOWED="${2:-}" _c f
  CHANGED=(); while IFS= read -r _c; do CHANGED+=("$_c"); done < <(cd "$WT" && { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u | grep -v '^$' | while IFS= read -r f; do [ -L "$f" ] || printf '%s\n' "$f"; done)   # mapfile is bash 4+ (absent on macOS bash 3.2)
  MADE_CHANGES=false; [ "${#CHANGED[@]}" -gt 0 ] && MADE_CHANGES=true

  SCOPE_VIOLATION=false; OFFENDERS=()
  if [ -n "$ALLOWED" ] && [ -f "$ALLOWED" ] && [ "$MADE_CHANGES" = true ]; then
    for f in "${CHANGED[@]}"; do
      grep -qxF "$f" "$ALLOWED" || { SCOPE_VIOLATION=true; OFFENDERS+=("$f"); }
    done
  fi

  # Do not expose the last conditional/grep status to callers using set -e.
  return 0
}
