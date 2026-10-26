#!/usr/bin/env bash
# fx-skills bridge: copy Claude Code plugin skills into ~/.fx/skills/ so fx
# can discover them (fx has no plugin system of its own).
#
# fx does NOT follow symlinks for skill discovery — every skill must be a real
# directory. So we rsync from the plugin cache, not symlink. The plugin-auto-
# update hook calls `install` after every plugin update, keeping copies fresh.
#
# Plugin skills live at:
#   ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/<name>/
# Version dirs accumulate (old ones are never cleaned up), so we resolve the
# current user-scope version from installed_plugins.json — the source of truth,
# not the cache directory listing.
#
# Call patterns:
#   fx/sync-skills.sh install   Copy/refresh skills (idempotent)
#   fx/sync-skills.sh check     Exit 1 + DRIFT lines if any copy is stale
#   fx/sync-skills.sh list      Print current skills and their source versions
#
# Wiring: called from fx/sync.sh (which is called from install.sh). Also safe
# to run standalone. No-op if jq or installed_plugins.json is missing.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FX_SKILLS="${FX_SKILLS:-$HOME/.fx/skills}"
PLUGINS_JSON="${CLAUDE_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}"

# Plugins to bridge and the skills to skip from each.
# Skips are skills that don't make sense in fx (platform-specific, marketing,
# or redundant with fx's own tooling).
declare -A PLUGIN_SPEC=(
  ["compound-engineering@every-marketplace"]="ce-test-xcode ce-test-browser ce-product-pulse ce-promote ce-riffrec-feedback-analysis"
  # pro-gate@hov: excluded — its SKILL.md reads ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json
  # at runtime, an env var fx does not provide. Bridging it would surface a skill
  # that errors on every invocation. Re-enable when pro-gate is portable or an
  # fx-specific wrapper that resolves the plugin root is generated.
)

# ── resolve current user-scope plugin cache path from installed_plugins.json ──
resolve_plugin_path() {
  local plugin="$1"
  jq -r --arg p "$plugin" \
    '.plugins[$p]?[]? | select(.scope=="user") | .installPath' \
    "$PLUGINS_JSON" 2>/dev/null | head -1
}

# ── copy one skill if its source exists ──
# Uses rsync so changed files inside the skill (scripts, references) are
# updated incrementally and removed files are cleaned up (--delete).
#
# P0 safety: if $dst is a symlink, rsync follows it (the trailing slash on
# "$dst/" makes rsync treat a symlinked dir as the target dir) and --delete
# then removes "extra" files inside the symlink's TARGET — i.e. it can destroy
# files outside our ownership. A legacy bridge used to symlink skill dirs, so
# such a symlink must be removed (not followed) before we rsync into a fresh
# real directory. A real directory we own is safe — rsync --delete on it only
# prunes files we previously put there.
copy_skill() {
  local src="$1" name="$2"
  local dst="$FX_SKILLS/$name"

  if [ ! -d "$src" ]; then
    echo "  SKIP $name (source missing)" >&2
    return 0
  fi

  mkdir -p "$FX_SKILLS"

  # P0 safety: never delete a directory we don't own. If $dst exists as a real
  # directory WITHOUT our ownership marker, refuse rather than destroy user data.
  # If it's a symlink (legacy bridge), remove the link only.
  if [ -L "$dst" ]; then
    rm "$dst" || { echo "  FAIL $name (cannot remove legacy symlink $dst)" >&2; return 1; }
    echo "  replaced legacy symlink for $name"
  elif [ -d "$dst" ] && [ ! -f "$dst/.fx-bridge-managed" ]; then
    echo "  FAIL $name (destination exists but is not bridge-managed; refusing to overwrite $dst)" >&2
    return 1
  fi

  # Stage into a temp directory, then swap. --exclude keeps our ownership marker
  # immune to --delete. rsync --delete is safe here because staging is a fresh
  # empty directory we just created.
  local staging changes rc
  staging=$(mktemp -d "$FX_SKILLS/.${name}.staging.XXXXXX") 2>/dev/null
  if [ -z "$staging" ]; then
    echo "  FAIL $name (cannot create staging dir)" >&2
    return 1
  fi
  # `exec 9>&-` closes the install-lock fd inside the substitution SUBSHELL,
  # not just for rsync: the flock lives on the open file description, so any
  # surviving inheritor (an orphaned subshell or rsync after a timeout kill of
  # the parent — reproduced in review) would otherwise keep the lock held and
  # phantom-block every later install for as long as it runs.
  changes=$(exec 9>&-; rsync -a --delete --exclude='.fx-bridge-managed' \
    --itemize-changes "$src/" "$staging/" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$staging"
    echo "  FAIL $name (rsync error)" >&2
    return 1
  fi
  # Mark this skill as bridge-managed so orphan cleanup can later remove it.
  printf '%s\n' "$name" > "$staging/.fx-bridge-managed" 2>/dev/null || true
  # Swap via renames, never rm-then-mv: a crash between `rm -rf $dst` and the
  # `mv` into place leaves NO copy of the skill at all (the hook's hard timeout
  # kill is enough to hit that window — reproduced in review). Park the old dir
  # aside with an atomic rename, move staging in, then discard the parked copy.
  # Every crash window now leaves either the old dir still at $dst, or a
  # .<name>.old.* dir that recover_leftovers() restores on the next run.
  local old=""
  if [ -d "$dst" ]; then
    old=$(mktemp -d "$FX_SKILLS/.${name}.old.XXXXXX" 2>/dev/null)
    if [ -z "$old" ] || ! mv -T "$dst" "$old" 2>/dev/null; then
      [ -n "$old" ] && rmdir "$old" 2>/dev/null
      rm -rf "$staging"
      echo "  FAIL $name (cannot park old $dst for atomic swap)" >&2
      return 1
    fi
  fi
  if ! mv -T "$staging" "$dst" 2>/dev/null; then
    # Restore the parked copy so a failed swap never loses the skill.
    [ -n "$old" ] && mv -T "$old" "$dst" 2>/dev/null
    rm -rf "$staging"
    echo "  FAIL $name (cannot move staging to $dst)" >&2
    return 1
  fi
  if [ -n "$old" ]; then
    rm -rf "$old"
  fi
  if [ -n "$changes" ]; then
    echo "  copied $name"
  fi
}

# ── collect expected (skill-name, source-path) pairs ──
# Prints one line per skill: <name>\t<source-path>
# Exit code 1 = the source view is INCOMPLETE: some plugin has an
# installed_plugins.json entry but its cache path has no skills/ dir (a
# mid-update window, or a stale JSON). The caller must not prune orphans
# against an incomplete view. A plugin with NO json entry is different — that
# is a real uninstall, and its bridged copies are legitimate orphans.
collect_skills() {
  local plugin skip_list skip_set src_root skill skip incomplete=0
  for plugin in "${!PLUGIN_SPEC[@]}"; do
    src_root=$(resolve_plugin_path "$plugin")
    [ -z "$src_root" ] && continue
    if [ ! -d "$src_root/skills" ]; then
      echo "fx-skills: WARN: $plugin resolves to $src_root but skills/ is missing (mid-update?); source view incomplete" >&2
      incomplete=1
      continue
    fi

    skip_list="${PLUGIN_SPEC[$plugin]}"
    declare -A skip_set=()
    for skip in $skip_list; do skip_set["$skip"]=1; done

    for skill_dir in "$src_root"/skills/*/; do
      [ -d "$skill_dir" ] || continue
      skill=$(basename "$skill_dir")
      [ -n "${skip_set[$skill]:-}" ] && continue
      printf '%s\t%s\n' "$skill" "$skill_dir"
    done
    unset skip_set
  done
  return "$incomplete"
}

# ── crash recovery: heal leftovers from an interrupted install ──
# copy_skill's swap can be killed between its two renames (the hook enforces a
# hard timeout), leaving `.<name>.old.*` (the parked previous copy) and/or
# `.<name>.staging.*` (an unfinished stage). Under the install lock: restore a
# parked copy whose skill dir vanished, discard everything else. Staging dirs
# are always safe to discard — a stage is only ever promoted by the run that
# created it, and that run is gone.
recover_leftovers() {
  [ -d "$FX_SKILLS" ] || return 0
  local d base name
  for d in "$FX_SKILLS"/.*.old.* "$FX_SKILLS"/.*.staging.*; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    case "$base" in
      # Staging FIRST, anchored to mktemp's 6-char suffix: a skill whose own
      # name contains ".old." would otherwise have its staging leftover
      # matched by the old-branch pattern and "restored" under a truncated
      # name (caught in review). A staging name always ends ".staging.XXXXXX".
      .*.staging.??????)
        rm -rf "$d"
        ;;
      .*.old.??????)
        name=${base#.}
        name=${name%.old.*}
        if [ -n "$name" ] && [ ! -e "$FX_SKILLS/$name" ] \
           && mv -T "$d" "$FX_SKILLS/$name" 2>/dev/null; then
          echo "  recovered $name from interrupted swap" >&2
          continue
        fi
        rm -rf "$d"
        ;;
    esac
  done
  return 0
}

# ── fingerprint a skill directory for drift checking ──
# Hash the ENTIRE directory tree: every file's content + relative path + mode
# (executable bit). Compound Engineering skills invoke scripts/ and references/*.md
# at runtime; a content-only hash would miss mode changes that make executable
# scripts non-executable. We cd into the dir and hash RELATIVE paths with their
# mode prefix so two directories with identical content+mode but different
# absolute locations (source cache vs ~/.fx/skills copy) produce the same
# fingerprint. Sorting makes the checksum order-independent. find -printf '%m %p'
# gives us "644 ./SKILL.md"; we feed each to a shell that strips the mode for
# md5sum but includes it in the output stream so it participates in the hash.
# The .fx-bridge-managed marker is excluded so it doesn't cause false drift.
skill_fingerprint() {
  local dir="$1"
  if [ -d "$dir" ]; then
    ( cd "$dir" && find . -type f -not -name '.fx-bridge-managed' -printf '%m %p\0' \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' line; do
          mode="${line%% *}"
          path="${line#* }"
          hash=$(md5sum "$path" | cut -d' ' -f1)
          printf '%s %s %s\n' "$mode" "$path" "$hash"
        done \
      | md5sum | cut -d' ' -f1 )
  else
    echo "MISSING"
  fi
}

cmd_install() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "fx-skills: jq not found; skipping" >&2
    return 0
  fi
  if [ ! -f "$PLUGINS_JSON" ]; then
    echo "fx-skills: $PLUGINS_JSON not found; skipping" >&2
    return 0
  fi
  # Corrupted JSON is NOT the same as "no plugins installed": both produce an
  # empty manifest (resolve_plugin_path swallows jq errors), but only the
  # first is a fault worth surfacing. rc 1 here reaches fxBridgeError via the
  # hook, which harness-doctor 10f reads; the guarded install.sh call turns it
  # into a WARN, not an abort. Nothing is pruned either way.
  if ! jq -e . "$PLUGINS_JSON" >/dev/null 2>&1; then
    echo "fx-skills: $PLUGINS_JSON is not valid JSON; skipping (nothing pruned)" >&2
    return 1
  fi

  mkdir -p "$FX_SKILLS" 2>/dev/null

  # One install at a time: concurrent runs (the SessionStart hook firing during
  # a manual install) can otherwise reap each other's in-flight staging dirs and
  # destroy freshly-written copies — reproduced in review. fd 9 is held for the
  # remainder of the process and released by the kernel on exit, crash included;
  # children close it (see copy_skill's rsync) so no orphan can hold it either.
  if command -v flock >/dev/null 2>&1; then
    # NB: the 2>/dev/null is scoped to the { } group, NOT attached to exec —
    # `exec 9>… 2>/dev/null` would permanently silence stderr for the rest of
    # the run (every FAIL/WARN/recovery line). The 9>> fd itself persists, as
    # intended; >> so an existing lock file is never truncated.
    if { exec 9>>"$FX_SKILLS/.fx-bridge.lock"; } 2>/dev/null; then
      if ! flock -n 9 2>/dev/null; then
        echo "fx-skills: another install is already running; skipping" >&2
        return 0
      fi
    fi
  fi

  recover_leftovers

  echo "Copying fx plugin skills..."
  local count=0 failures=0 failed_names=""
  local current_names=""  # space-separated list of skill names synced this run

  # Materialize the source manifest before any mutation. Process substitution
  # (< <(collect_skills)) hides a collector failure: a malformed
  # installed_plugins.json emits zero rows, failures stays zero, and orphan
  # cleanup would delete every marker-owned skill. Capturing into a variable
  # lets us detect an empty collection and abort before touching anything.
  local manifest collect_rc
  manifest=$(collect_skills)
  collect_rc=$?
  if [ -z "$manifest" ]; then
    # A legitimate state (plugin not installed / nothing to bridge), so exit 0:
    # install.sh runs under `set -e`, and the previous `return 1` here aborted
    # the ENTIRE installer mid-run. Never prune against an empty view — cleanup
    # is skipped along with the copies.
    echo "  WARN: no skills found in source (check $PLUGINS_JSON); nothing to install, orphan cleanup skipped" >&2
    return 0
  fi

  while IFS=$'\t' read -r name src; do
    current_names="$current_names $name "
    if copy_skill "$src" "$name"; then
      count=$((count + 1))
    else
      failures=$((failures + 1))
      failed_names="$failed_names $name"
    fi
  done <<< "$manifest"
  echo "  $count skill(s) processed"

  # Abort orphan cleanup if any copy failed — a partial sync means the source
  # set is incomplete, and pruning against an incomplete set would delete skills
  # that are still current. Only prune when all copies succeeded.
  if [ "$failures" -gt 0 ]; then
    echo "fx-skills: $failures skill(s) failed to copy:$failed_names" >&2
    echo "  orphan cleanup skipped (copy failures detected — not pruning to avoid data loss)" >&2
    return 1
  fi

  # Same doctrine for an incomplete COLLECTION: a plugin whose json entry
  # resolves but whose cache lacks skills/ means the source view is partial
  # (mid-update). Pruning against it would delete skills that are still
  # installed. Copies above were fine; only the prune is unsafe.
  if [ "$collect_rc" -ne 0 ]; then
    echo "  orphan cleanup skipped (source view incomplete — not pruning to avoid data loss)" >&2
    return 0
  fi

  # Orphan cleanup: remove bridge-owned skill dirs in $FX_SKILLS that are no
  # longer in the current source set. We only touch real directories carrying
  # our ownership marker (.fx-bridge-managed) so we never delete a skill the
  # user placed by hand or follow a symlink into another location.
  if [ -d "$FX_SKILLS" ]; then
    local d oname removed=0
    # Use find to enumerate only real directories (no trailing slash, no symlink
    # dereference) — globbing with */ dereferences symlinks and can follow them
    # into other locations.
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      oname=$(basename "$d")
      # Never treat dot-dirs as orphans: in-flight staging dirs from a
      # concurrent or interrupted run carry the ownership marker too, and
      # reaping one destroys a copy mid-swap (reproduced in review).
      # recover_leftovers() — under the lock — is the only reaper for those.
      case "$oname" in .*) continue ;; esac
      [ -f "$d/.fx-bridge-managed" ] || continue   # not ours — leave it
      case " $current_names " in
        *" $oname "*) ;;                             # still present in source
        *) rm -rf "$d"; removed=$((removed + 1)) ;;
      esac
    done < <(find "$FX_SKILLS" -mindepth 1 -maxdepth 1 -type d)
    [ "$removed" -gt 0 ] && echo "  removed $removed orphaned skill dir(s)"
  fi

  return 0
}

cmd_check() {
  if ! command -v jq >/dev/null 2>&1; then return 0; fi
  if [ ! -f "$PLUGINS_JSON" ]; then return 0; fi

  local drift=0 name src dst src_fp dst_fp
  # Build the set of currently-sourced skill names for orphan detection.
  local current_names=""
  while IFS=$'\t' read -r name src; do
    current_names="$current_names $name "
    dst="$FX_SKILLS/$name"
    src_fp=$(skill_fingerprint "$src")
    dst_fp=$(skill_fingerprint "$dst")
    if [ "$src_fp" != "$dst_fp" ]; then
      echo "DRIFT: $name (src=$src_fp dst=$dst_fp)"
      drift=1
    fi
  done < <(collect_skills)

  # Orphan detection: a bridge-managed skill dir still present in $FX_SKILLS
  # but no longer in the source set is stale (removed/renamed/uninstalled
  # upstream) and should be reported so the user runs `sync-skills.sh install`
  # to prune it. We only flag dirs carrying our ownership marker.
  if [ -d "$FX_SKILLS" ]; then
    local d oname
    # Use find (not glob */ which dereferences symlinks) to enumerate real dirs only.
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      oname=$(basename "$d")
      # Dot-dirs are bridge internals (staging/parked/lock), not skills —
      # install's recover_leftovers() handles them; don't flag them as drift.
      case "$oname" in .*) continue ;; esac
      [ -f "$d/.fx-bridge-managed" ] || continue
      case " $current_names " in
        *" $oname "*) ;;
        *) echo "DRIFT: $oname is an orphaned bridge-managed skill (not in source; run install to remove)"; drift=1 ;;
      esac
    done < <(find "$FX_SKILLS" -mindepth 1 -maxdepth 1 -type d)
  fi
  return $drift
}

cmd_list() {
  if [ ! -d "$FX_SKILLS" ]; then
    echo "(no ~/.fx/skills/ directory)"
    return 0
  fi
  local name fp
  for d in "$FX_SKILLS"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    fp=$(skill_fingerprint "$d")
    printf '%-28s %s\n' "$name" "$fp"
  done
}

MODE="${1:-install}"
case "$MODE" in
  install) cmd_install ;;
  check)   cmd_check ;;
  list)    cmd_list ;;
  *) echo "usage: sync-skills.sh install|check|list" >&2; exit 2 ;;
esac
