#!/usr/bin/bash
# sync.sh — Claude Code harness ⇄ dotfiles backup.
#
# Canonical harness home is WSL ~/.claude (see memory: cc-two-homes-decommission).
# This directory backs up its durable parts so a new PC (or a rebuilt one) can
# restore the whole setup with one command.
#
#   STABLE parts   (hooks/ scripts/ bin/ commands/ agents/ CLAUDE.md,
#       claude-env.sh)
#       live IN THIS REPO and are symlinked into ~/.claude — edits show up in
#       `git status` immediately; no sync step.
#   VOLATILE parts (settings.json, keybindings.json — Claude Code rewrites these
#       atomically, which would break symlinks; per-project memory; systemd
#       user units; Windows break-glass stubs)
#       are copy-synced by `push`. Settings also receive repo changes through
#       the three-way apply, preserving live edits and holding deny removals.
#   MANAGED LOCK   (/etc/claude-code/managed-settings.json — the root-owned deny
#       floor that holds even in bypassPermissions/YOLO mode) is deployed FROM
#       this repo by `./setup --root` (needs sudo) and captured by `push`. It cannot be
#       symlinked: Claude Code reads it as root-level policy. Verified by
#       harness-doctor check 12 (existence + root ownership + content match).
#   SYSTEM UNITS   (systemd-system/ -> /etc/systemd/system, root-owned; a literal
#       $HOME/ in a template is rendered for this account by `./setup --root` and reversed by push) — for
#       units whose resource (swap) is kernel-global, boot-scoped state that
#       belongs to multi-user.target, not the per-user `systemd --user` manager
#       (see zram-swap.service; this box's sudo policy is unscoped NOPASSWD:ALL,
#       so passwordless privilege isn't why these can't be --user units).
#       Deployed the same way as the managed lock (sudo install, graceful no-sudo
#       fallback) but NEVER auto-enabled by `./setup --root` — activation is an explicit
#       operator step, unlike the --user timers below.
#
# Usage:
#   ./setup           Link harness files and seed or merge settings.
#   ./setup --root    Reconcile Docker policy, managed lock and system units.
#   ./setup --enable-units  Deploy user units and reconcile role timers.
#   sync.sh apply-settings [--plan] [--quiet] [--seed-base <rev>]
#                     Apply tracked settings against the last-applied base.
#                     Plan and check report conflicts and held deny removals.
#   sync.sh reconcile-docker-init
#                     Validate the reviewed init=true candidate and finalize only
#                     an already-published workstation adoption transaction.
#   sync.sh adopt-docker-init [--allow-existing-false]
#                     Explicitly adopt init=true on the declared workstation;
#                     the optional flag approves replacing an explicit false.
#   sync.sh rollback-docker-init
#                     Restore only the prior init value (or absence) while
#                     retaining settings owned by other actors.
#   sync.sh reconcile-dcg
#                     Add/update only the canonical DCG PreToolUse hook in an
#                     existing live settings.json. Backs up before changing it.
#   sync.sh reconcile-runtime-env
#                     Merge portable runtime policy: the durable memory/env-file keys,
#                     the background-shell pressure-reap opt-out
#                     (CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP, dotfiles#1442),
#                     canonical WACLI_STORE_DIR, the pro-gate round guard
#                     (PRO_GATE_ROUND_GUARD), the Read token cap
#                     (CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS), disabled TypeScript
#                     LSP, disabled Auto mode, and the canonical EnterPlanMode deny.
#   sync.sh reconcile-windows-auto-mode
#                     Same mode policy (Auto mode off, EnterPlanMode denied) for the
#                     Windows break-glass settings.json.
#   sync.sh push      Refresh volatile copies + managed lock into the repo
#                     (run before commit).
#   sync.sh check     Exit 1 + DRIFT lines if live harness differs from repo
#                     (consumed by harness-doctor check 10).
#   sync.sh memory-preview  Show copies and mirror-only files without mutation.
#   sync.sh memory-push     Preview, then copy live memory into the mirror without deletion.
#   sync.sh memory-check    Exit 1 when memory differs. Mirror-only paths are
#                     printed but are NOT drift: the push runs without --delete,
#                     so the mirror is append-only history and no command here
#                     can clear one. A live project store that has vanished
#                     entirely IS drift, and reports as "LOST live store".
#
# Exit codes: 0 clean/success, 1 drift or audit findings, 2 usage/runtime error.
#
# NOT managed here (on purpose): credentials (.credentials.json — log in
# manually), ~/.claude.json (runtime state + oauth), skills/ (jsm sync),
# plugins/ cache dir (install artifacts — restore via `claude plugin`;
# enabledPlugins themselves ARE tracked, via settings.json), session/history data.
set -uo pipefail

# The repo root, resolved through readlink -f: a caller that reaches this file
# as ~/.claude/scripts/../sync.sh must not relocate "canonical" to ~/.claude.
# `cd` applies `..` logically BEFORE the symlink is followed (pwd -P does not
# undo that), which is exactly how every nightly dcg promote from 2026-08-28 to
# 2026-09-17 rewrote the live settings.json instead of the tracked one (#1201).
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)
# shellcheck source=scripts/lib/floor-assert.sh
. "$HERE/scripts/lib/floor-assert.sh"
# Role model. Sourced when present; a checkout broken enough to be missing it
# has no role; an environment variable cannot replace the roster.
# Docker-init ownership is stricter: only the versioned profile library can
# authorize it, so the fallback can never select it.
PROFILE_LIBRARY_AUTHORITATIVE=0
if [ -r "$HERE/lib/profile.sh" ]; then
  # shellcheck source=lib/profile.sh
  . "$HERE/lib/profile.sh"
  PROFILE_LIBRARY_AUTHORITATIVE=1
else
  profile_role() { return 1; }
  profile_is() { [ "$(profile_role 2>/dev/null)" = "$1" ]; }
fi

docker_init_role_selected() {
  [ "$PROFILE_LIBRARY_AUTHORITATIVE" -eq 1 ] && profile_is workstation
}
H=${CLAUDE_HOME:-$HOME/.claude}
MEMORY_LIVE_ROOT=${CLAUDE_MEMORY_LIVE_ROOT:-$H/projects}
MEMORY_MIRROR_ROOT=${CLAUDE_MEMORY_MIRROR_ROOT:-$HERE/memory}
# The mirror is opt-in (#346): push and check touch it only when it is named or
# an explicit `sync.sh memory-push` has created the default one. Otherwise push
# would copy private notes into this checkout, a public repository, and check
# would report drift on every host that keeps no mirror. harness-doctor gates
# its memory audit the same way.
memory_mirror_opted_in() {
  [ -n "${CLAUDE_MEMORY_MIRROR_ROOT:-}" ] || [ -d "$MEMORY_MIRROR_ROOT" ]
}
memory_mirror_absent_reason() {
  echo "no mirror at $MEMORY_MIRROR_ROOT and CLAUDE_MEMORY_MIRROR_ROOT is unset (the mirror is opt-in; sync.sh memory-push creates it)"
}
MEMORY_AUDIT=$HERE/scripts/memory-audit.py
CRON_OWNERSHIP_HELPER=$HERE/scripts/cron-ownership.py
CRITICAL_SILENCE_TIMERS="mcp-servers-update.timer skills-update.timer"
CUTOVER_LOCK=${CLAUDE_SYNC_CUTOVER_LOCK:-$HOME/.local/state/claude/critical-silence-cutover.lock}
# memory-mine.py runtime state: a lock, an idempotency ledger, and pre-apply
# MEMORY.md snapshots. Live-store-local, never part of the backup. One list,
# consumed by BOTH memory_plan (which skips these) and memory_push (which turns
# them into rsync --exclude args) -- when only the copy side knew about them the
# preview reported 11 files as COPY on every single run and the push then
# correctly declined to copy any of them, so `memory-check` could never reach
# "memory in sync" and its non-zero exit stopped meaning anything.
# Glob syntax, matched against the basename.
MEMORY_MINER_DROPPINGS=(
  '.mine-apply.lock'
  '.mined-sessions.json'
  '.MEMORY.md.pre-mine-*'
)

# Whether a store-relative path is miner runtime state rather than a note.
memory_is_dropping() {
  local base=${1##*/} pattern
  for pattern in "${MEMORY_MINER_DROPPINGS[@]}"; do
    # shellcheck disable=SC2053  # glob match is the point
    [[ $base == $pattern ]] && return 0
  done
  return 1
}

SYS=$HOME/.config/systemd/user
STATUSLINE_DIR=${CLAUDE_SYNC_STATUSLINE_DIR:-$HOME/.config/statusline-stack}
STATUSLINE_RENDERER=$STATUSLINE_DIR/local-statusline.mjs
STATUSLINE_REF=$HERE/statusline-stack/local-statusline.mjs
# Overridable for hermetic CI/test runs only (tests/sync-install-smoke.test.sh);
# the real box never sets this, so install()/check() behavior there is unchanged.
SYSTEM_SYS=${CLAUDE_SYNC_SYSTEM_SYS_DIR:-/etc/systemd/system}
DOCKER_INIT_HELPER=$HERE/scripts/docker-daemon-config.py
DOCKER_INIT_PATCH=$HERE/config/system/docker-daemon.patch.json
DOCKER_INIT_TARGET=${CLAUDE_SYNC_DOCKER_DAEMON_TARGET:-/etc/docker/daemon.json}
DOCKER_INIT_STATE=${CLAUDE_SYNC_DOCKER_ADOPTION_STATE:-/var/lib/dotfiles/docker-init-adoption.json}
DOCKER_INIT_BACKUP=${CLAUDE_SYNC_DOCKER_ADOPTION_BACKUP:-/var/lib/dotfiles/docker-init-adoption.original}
DOCKER_INIT_LOCK=${CLAUDE_SYNC_DOCKER_POLICY_LOCK:-/etc/docker/.daemon.json.dotfiles.lock}
DOCKER_INIT_DOCKERD=${CLAUDE_SYNC_DOCKERD:-/usr/bin/dockerd}
DOCKER_INIT_TEST_ROOT=${CLAUDE_SYNC_DOCKER_TEST_ROOT:-}

# Invoke the narrow Docker policy helper only for an authoritatively declared
# workstation. Routine reconcile/check first run unprivileged and escalate only
# when root-owned recovery state requires it; explicit adoption/rollback are the
# only commands allowed to publish. The helper never operates a service manager.
docker_init_policy() {
  local action=${1:?} rc extra=${2:-}
  local -a command=(
    /usr/bin/python3 "$DOCKER_INIT_HELPER" "$action"
    --profile workstation
    --patch "$DOCKER_INIT_PATCH"
    --target "$DOCKER_INIT_TARGET"
    --state "$DOCKER_INIT_STATE"
    --backup "$DOCKER_INIT_BACKUP"
    --lock "$DOCKER_INIT_LOCK"
    --dockerd "$DOCKER_INIT_DOCKERD"
  )

  if ! docker_init_role_selected; then
    case "$action" in
      adopt|rollback)
        echo "docker-init: ERROR: policy action requires an authoritative workstation profile" >&2
        return 2
        ;;
      *) return 0 ;;
    esac
  fi
  if [ -n "$DOCKER_INIT_TEST_ROOT" ]; then
    command+=(--test-root "$DOCKER_INIT_TEST_ROOT")
  fi
  if [ -n "$extra" ]; then
    command+=("$extra")
  fi

  if { [ "$action" = adopt ] || [ "$action" = rollback ]; } \
     && [ -z "$DOCKER_INIT_TEST_ROOT" ] \
     && [ "$(id -u)" -ne 0 ]; then
    sudo -n "${command[@]}"
    return $?
  fi
  if "${command[@]}"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 4 ] && [ -z "$DOCKER_INIT_TEST_ROOT" ]; then
    sudo -n "${command[@]}"
    return $?
  fi
  return "$rc"
}

# The Windows profile that mirrors this WSL user; CLAUDE_WINDOWS_HOME overrides
# the default when the two user names differ.
WIN=${CLAUDE_WINDOWS_HOME:-/mnt/c/Users/${USER:-$(id -un)}}
STABLE_DIRS="hooks scripts bin commands agents workflows mods"
STABLE_FILES="CLAUDE.md claude-env.sh memory-dream.json"
VOLATILE_FILES="settings.json keybindings.json"
# Proxy base URL by host role (better-ccflare tailnet sharing). Single source
# of truth for reconcile_runtime_env, apply-settings and check(). The
# workstation runs the proxy, so its URL is loopback; a satellite reaches the
# workstation's serve URL, which names a private host and therefore never
# comes from this tree: an exported CCFLARE_URL_SATELLITE wins, else the
# overlay env file (~/.config/hov-stack/env) answers, read below once
# lib/overlay.sh is loaded.
CCFLARE_URL_WORKSTATION="http://127.0.0.1:8788"
CCFLARE_URL_SATELLITE=${CCFLARE_URL_SATELLITE:-}
# Flat unit names, plus drop-in overrides written as "<unit>.d/<file>.conf". The
# jsm-auto-update drop-ins are overrides, not a unit we own: jsm installs and may
# rewrite jsm-auto-update.service itself, while drop-ins survive that rewrite.
UNITS="harness-unit-failure-alert@.service backup-harness.service backup-harness.timer dcg-auto-update.service dcg-auto-update.timer tools-auto-update.service tools-auto-update.timer codex-auto-update.service codex-auto-update.timer jsm-auto-update.service.d/override.conf jsm-auto-update.service.d/zz-skills-localize.conf wt-sweep.service wt-sweep.timer pkg-cache-prune.service pkg-cache-prune.timer docker-hygiene.service docker-hygiene.timer reclaim-sweep.service reclaim-sweep.timer disk-watermark.service disk-watermark.timer jsm-auto-update.timer mcp-servers-update.service mcp-servers-update.timer skills-update.service skills-update.timer cass-release-promote.service cass-release-promote.timer"
# The deletion-capable hygiene timers stay out of the enable-now line below by
# convention.
# codex-auto-update.timer stays out of it too (dotfiles#1377): it promotes a new Codex
# CLI within minutes of release and feeds better-ccflare's client identity, so
# turning it on is `systemctl --user enable --now codex-auto-update.timer`, done
# by hand. It is also absent from all_role_units, so reconcile never disables it.
# Live --user units owned by other repositories are deliberately not managed here.
# Consumed by check() so another owner's units do not reappear every week.
# Owners were verified against each repository on 2026-08-27, not assumed.
# Private unit stems belong in the overlay's foreign-units file:
#
#   Growth operations: the private growth-ops repository ships its backup,
#       collect, detect and health units in machine/*.{service,timer}, with
#       machine/install.sh and its own alert service template. Fully installable.
#   Community intel: the private community-intel tool ships its cycle units
#       in systemd/ and installs them through bootstrap.sh.
#   Evaluation tooling: the private evals repository ships its OAuth-siphon
#       service and timer in scripts/.
#
# The live deployment gap is tracked in the author's infrastructure repository's #206
# (incident-runner shared it until retirement and removal of its workstation units on
# 2026-10-18):
#
#   check-fleet-drift
#       The infrastructure repository's host unit directory.
#       Versioned there and enabled on workstation, but the deploy manifest has ZERO
#       rows targeting workstation -- so that repo owns them and deploys them nowhere.
#       A rebuilt workstation loses them. Same asymmetry too: deploy.sh verifies every
#       DECLARED artifact and nothing verifies every live artifact is declared.
#
# RETIRED AND GONE 2026-08-29: tend-runtime-watchdog, and the rest of tend.
#
# This slot used to hold a deliberate omission. tend (EveryInc/tend, a third-
# party dogfood target for the design-md bakeoff) was left out of both UNITS and
# UNITS_FOREIGN on purpose, so the live-unit check would keep reporting drift
# until someone actually removed it -- "a comment saying retire this one day is
# a comment; a failing check is a to-do that closes itself."
#
# It closed. The to-do worked exactly as designed: the drift line is what put
# tend in front of an operator, who confirmed on 2026-08-29 that it was unused.
# Five units are now deleted (tend-runtime-watchdog .service/.timer, tend-demo,
# tend-demo-bridge, tend-windows-relay), along with the packaged runtime, the
# demo state dir, and the checkout. Backups: ~/.claude/archive/tend-units-*/ and
# a git bundle of the one local-only commit.
#
# Kept as a record because the mechanism earned it, and because the cost of the
# gap is worth remembering: the watchdog had been failing every 60s -- 1253
# times in its last 24 hours -- and the Windows-side "\Tend Loopback Watchdog"
# had its PT1M trigger stripped back on 2026-08-05 for being overkill "for how
# rarely he uses Tend", while the WSL side never got the same treatment.
#
# App-owned SERVICES, surfaced once the enumeration stopped being timers-only.
#   voxtype            voxtype push-to-talk voice-to-text daemon (satellite-host)
#   check-fleet-drift  the infrastructure repository's host unit directory -- ALREADY
#                      versioned there, .service AND .timer. Declaring it here
#                      too would create a second owner, which is this check's own
#                      failure mode inverted.
UNITS_FOREIGN="check-fleet-drift voxtype"
# A host's own units come from <overlay>/foreign-units, never from the line above, which
# scripts/unit-health.sh and scripts/harness-doctor.sh read as written; the helper that
# all three share says how.
# shellcheck source=lib/foreign-units.sh
. "$HERE/lib/foreign-units.sh"
UNITS_FOREIGN=$(foreign_units_with_overlay "$UNITS_FOREIGN" "$UNITS")
# shellcheck source=lib/overlay-units.sh
. "$HERE/lib/overlay-units.sh"
OVERLAY_UNIT_PATHS=() OVERLAY_UNIT_SOURCES=() OVERLAY_UNIT_FLAGS=() OVERLAY_UNIT_ERRORS=()
if declare -F overlay_units_load >/dev/null; then overlay_units_load "$UNITS"; fi
# A host's hygiene-timer posture (deletion on, schedule, which timers run) comes from
# <overlay>/hygiene-posture; install applies it as drop-ins and check reports drift.
# shellcheck source=lib/hygiene-posture.sh
. "$HERE/lib/hygiene-posture.sh"
# The satellite proxy URL from the overlay env when the caller exported none. A
# session's Bash calls get that file through claude-env.sh, but the SessionStart
# settings hook, an ssh-run install and a systemd unit run without it; an apply
# that found no URL there wrote the tracked loopback over a satellite's live one.
[ -n "$CCFLARE_URL_SATELLITE" ] || CCFLARE_URL_SATELLITE=$(overlay_env_get CCFLARE_URL_SATELLITE)

# Root-owned system units (systemd-system/ -> $SYSTEM_SYS), NOT --user units —
# see the header comment. Deliberately never enabled/started by `./setup --root`; see
# the OPERATOR ACTIVATION CHECKLIST in the PR that introduced zram-swap.service.
SYSTEM_UNITS="zram-swap.service fstrim.timer.d/10-wsl.conf fstrim.service.d/10-wsl.conf docker-containers.slice"
# Overridable for the same hermetic-test reason as SYSTEM_SYS above; unset on the real box.
MANAGED_LOCK=${CLAUDE_SYNC_MANAGED_LOCK:-/etc/claude-code/managed-settings.json}   # root-owned deny floor (survives YOLO/bypassPermissions)
MANAGED_REF=$HERE/managed-settings.json               # canonical source, version-controlled here
# dcg's own `self_heal_hook` rewrites this hook entry to the RESOLVED absolute
# binary path (upstream v0.7.7, "fail-closed absolute hook paths" — it stops a
# repointed ~/.local/bin symlink from silently swapping the guard out). If this
# stayed the symlink path, `sync.sh reconcile-dcg` and self-heal would each keep
# rewriting settings.json back to their own spelling. Resolving here means both
# write the identical string, and an upgrade that repoints the symlink is picked
# up automatically. Falls back to the symlink path if resolution fails.
DCG_COMMAND=$(readlink -f "$HOME/.local/bin/dcg" 2>/dev/null || echo "$HOME/.local/bin/dcg")
MODE=${1:-check}

# Defensive tripwire: this repo is an explicit allowlist copier (never a
# directory sweep), so a raw credential should never reach it. But a future
# edit to STABLE_DIRS/STABLE_FILES could silently start tracking one (e.g. the
# GA4 service-account key that lives at ~/.claude/ top level). Scan the
# version-controlled tree for high-signal credential material and refuse.
# High precision (private-key/service-account signatures only) -> no false
# positives on ordinary config. Returns 1 and prints offenders if any found.
guard_no_credentials() {
  local hits re
  # Patterns are assembled from fragments so this scanner does not match its
  # own source (grep would otherwise flag sync.sh itself). At runtime the
  # shell concatenates each fragment back into the full signature.
  re="BEGIN [A-Z ]*PRIV""ATE KEY|\"type\":[[:space:]]*\"service""_account\"|\"priv""ate_key_id\""
  # Pruned: .git anywhere; every node_modules, whose package READMEs carry example
  # keys (dotenv's does) and which this tree never tracks; and .claude/worktrees,
  # other agents' separate checkouts, which a run from the main checkout would
  # otherwise sweep and refuse on. Everything else is scanned as before, symlinks
  # still not followed.
  hits=$(find "$HERE" \( -name .git -o -type d -name node_modules -o -path "$HERE/.claude/worktrees" \) -prune \
      -o -type f -print0 2>/dev/null | xargs -0 -r grep -IlE "$re" -- 2>/dev/null) || true
  if [ -n "$hits" ]; then
    echo "SECRET GUARD: credential material found in the dotfiles tree — refusing to proceed:" >&2
    echo "$hits" | sed 's/^/  /' >&2
    echo "  (a service-account key or private key must never be version-controlled here." >&2
    echo "   Remove it from the synced path and keep it under ~/.claude/ top level only.)" >&2
    return 1
  fi
  return 0
}

memory_plan() {
  local changes=0 m proj rel destination
  MEMORY_ITEMS_EXAMINED=0
  for m in "$MEMORY_LIVE_ROOT"/*/memory; do
    [ -d "$m" ] || continue
    proj=$(basename "$(dirname "$m")")
    while IFS= read -r -d '' source; do
      MEMORY_ITEMS_EXAMINED=$((MEMORY_ITEMS_EXAMINED + 1))
      rel=${source#"$m"/}
      destination=$MEMORY_MIRROR_ROOT/$proj/$rel
      # Skipped BEFORE the symlink check on purpose: memory_push excludes these
      # unconditionally, so a symlinked lock file is still never dereferenced
      # into the mirror, and refusing the whole push over one would be a
      # self-inflicted outage of exactly the kind the per-file gate removed.
      if memory_is_dropping "$rel"; then
        continue
      elif [ -L "$source" ]; then
        echo "BLOCK live symlink $proj/$rel"
        changes=1
      elif [ -L "$destination" ] || [ ! -f "$destination" ] || ! cmp -s "$source" "$destination"; then
        echo "COPY $proj/$rel"
        changes=1
      fi
    done < <(find "$m" \( -type f -o -type l \) -print0 | sort -z)
  done
  if [ -d "$MEMORY_MIRROR_ROOT" ]; then
    local lost_reported=" "
    while IFS= read -r -d '' destination; do
      MEMORY_ITEMS_EXAMINED=$((MEMORY_ITEMS_EXAMINED + 1))
      rel=${destination#"$MEMORY_MIRROR_ROOT"/}
      proj=${rel%%/*}
      rel=${rel#*/}
      if [ -f "$MEMORY_LIVE_ROOT/$proj/memory/$rel" ] || [ -L "$MEMORY_LIVE_ROOT/$proj/memory/$rel" ]; then
        continue
      fi
      if [ ! -d "$MEMORY_LIVE_ROOT/$proj/memory" ]; then
        # The whole live store for this project is gone while the mirror still
        # holds its notes. That is not deletion hygiene, it is loss -- an
        # unmounted home, a wiped ~/.claude, a renamed project -- and it is the
        # one mirror-only shape that must stay loud. Without it, making KEEP
        # informational would let a vanished live root report "memory in sync":
        # the corpus floor counts mirror files too, so the mirror walk alone
        # satisfies it. Reported once per project, not once per file.
        case $lost_reported in
          *" $proj "*) ;;
          *)
            lost_reported="$lost_reported$proj "
            echo "LOST live store $proj (mirror has notes, $MEMORY_LIVE_ROOT/$proj/memory does not exist)"
            changes=1
            ;;
        esac
        continue
      fi
      # Informational, deliberately not drift. memory_push runs without
      # --delete, so the mirror is append-only history by design and NOTHING
      # sync.sh offers can resolve one of these lines. Counting them as drift
      # made `check` print "DRIFT: memory differs" on every run forever (46
      # such paths on the box where this was found), which is an alarm that
      # cannot be cleared and therefore an alarm nobody reads.
      echo "KEEP mirror-only $proj/$rel"
    done < <(find "$MEMORY_MIRROR_ROOT" \( -type f -o -type l \) -print0 | sort -z)
  fi
  return "$changes"
}

memory_preview() {
  local result=0
  memory_plan || result=$?
  floor "$MEMORY_ITEMS_EXAMINED" 1 "memory preview corpus" || return 2
  [ "$result" -eq 0 ] && echo "memory in sync"
  return "$result"
}

# Set by guard_memory_copy: "<project>/<relative>" for every file the auditor
# excluded from this push. Read by memory_push when it builds rsync exclusions.
MEMORY_QUARANTINE_PATHS=()

# The gate is per-file. A sensitive indicator drops that one note from the copy;
# only a live symlink (the store is no longer a self-contained tree) refuses the
# whole push. The previous version refused everything on any indicator, which
# cost the backup six consecutive nights over six filename false positives.
guard_memory_copy() {
  local gate status path
  MEMORY_QUARANTINE_PATHS=()
  [ -f "$MEMORY_AUDIT" ] || {
    echo "memory push refused: auditor missing at $MEMORY_AUDIT" >&2
    return 2
  }
  gate=$(python3 "$MEMORY_AUDIT" \
    --live-root "$MEMORY_LIVE_ROOT" \
    --mirror-root "$MEMORY_MIRROR_ROOT" \
    --copy-gate)
  status=$?
  if [ "$status" -eq 1 ]; then
    # Name the paths here. The previous message told the operator to go re-run
    # the auditor by hand, so six nightly failures in a row said nothing about
    # which files caused them.
    echo "memory push refused: live symlink in the memory store" >&2
    printf '%s' "$gate" | python3 -c 'import json,sys
for item in json.load(sys.stdin)["blocked"]:
    print("  BLOCK", item["kind"], item["project"] + "/" + item.get("path", ""))' >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    echo "memory push refused: auditor could not inspect live memory" >&2
    return 2
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    MEMORY_QUARANTINE_PATHS+=("$path")
  done < <(printf '%s' "$gate" | python3 -c 'import json,sys
for path in json.load(sys.stdin)["quarantine_paths"]:
    print(path)')
  if [ "${#MEMORY_QUARANTINE_PATHS[@]}" -gt 0 ]; then
    echo "memory push: ${#MEMORY_QUARANTINE_PATHS[@]} path(s) quarantined, not copied:" >&2
    printf '%s' "$gate" | python3 -c 'import json,sys
for item in json.load(sys.stdin)["quarantined"]:
    print("  QUARANTINE", item["kind"], item["project"] + "/" + item["path"])' >&2
    # A path quarantined today may have been copied by an earlier push. This
    # guard never deletes from the mirror (see the no --delete note below), so
    # say so rather than implying the bytes are absent.
    for path in "${MEMORY_QUARANTINE_PATHS[@]}"; do
      [ -e "$MEMORY_MIRROR_ROOT/$path" ] &&
        echo "  QUARANTINE-RESIDUE $path already exists in the mirror from an earlier push; review it" >&2
    done
    echo "  (clear a false positive by adding the path to memory-filename-allowlist.txt)" >&2
  fi
  return 0
}

memory_push() {
  local m proj q
  local -a excludes
  memory_preview || true
  guard_memory_copy || return $?
  mkdir -p "$MEMORY_MIRROR_ROOT" || { echo "memory push failed: cannot create $MEMORY_MIRROR_ROOT" >&2; return 2; }
  for m in "$MEMORY_LIVE_ROOT"/*/memory; do
    [ -d "$m" ] || continue
    # Re-check confinement at the copy site: a symlinked project or memory
    # root would make rsync dereference and import an external tree.
    if [ -L "$m" ] || [ -L "$(dirname "$m")" ]; then
      echo "memory push failed: symlinked memory root $m (refusing to copy)" >&2
      return 2
    fi
    proj=$(basename "$(dirname "$m")")
    mkdir -p "$MEMORY_MIRROR_ROOT/$proj" || { echo "memory push failed: cannot create mirror dir for $proj" >&2; return 2; }
    # No --delete: mirror-only history is preserved for manual review or restore.
    # Miner droppings come from MEMORY_MINER_DROPPINGS so this list and
    # memory_plan's can never drift apart again; also gitignored as a second
    # layer for droppings deposited by older pushes.
    # Quarantined paths are anchored to this project's transfer root so a
    # same-named note in another project is not excluded by accident.
    excludes=()
    for q in "${MEMORY_MINER_DROPPINGS[@]}"; do
      excludes+=("--exclude=$q")
    done
    for q in "${MEMORY_QUARANTINE_PATHS[@]}"; do
      case $q in
        "$proj"/*) excludes+=("--exclude=/${q#"$proj"/}") ;;
      esac
    done
    rsync -a \
      "${excludes[@]}" \
      "$m/" "$MEMORY_MIRROR_ROOT/$proj/" || { echo "memory push failed: rsync error on $proj (mirror may be partial)" >&2; return 2; }
  done
  if [ "${#MEMORY_QUARANTINE_PATHS[@]}" -gt 0 ]; then
    echo "memory push complete (mirror-only paths preserved; ${#MEMORY_QUARANTINE_PATHS[@]} quarantined path(s) NOT copied)"
  else
    echo "memory push complete (mirror-only paths preserved)"
  fi
}

# settings.json is intentionally not symlinked because Claude rewrites it.
# Reconcile only a single named standalone hook group so live-only/runtime-owned
# fields and every other hook survive. The canonical group is read from the repo
# copy rather than duplicated here, keeping one source of truth.
# args: <label> <hook event> <hook command string> [canonical settings.json path]
#       [superseded commands to retire, a JSON array]
# reconcile_dcg_hook is the one caller; every other tracked hook is placed by
# apply_settings (hov-stack #479), which puts it where the tracked file groups it.
#
# The 4th argument exists so a caller can reconcile against a NORMALIZED copy of
# the canonical settings without first mutating the tracked file. `./setup` must
# not write anything inside the checkout — see reconcile_dcg_hook.
#
# A registered hook command resolves through the $H/hooks symlink into the MAIN
# checkout, not whatever worktree ran the reconcile. Registering a hook whose
# file only exists on an unmerged branch therefore points every matching tool
# event at a missing module: the hook errors on every fire while settings.json
# looks correct. Fail closed instead — merge and pull first, then reconcile.
hook_command_target() {
  local cmd=$1 target
  # `interpreter "/abs/path"`, `interpreter "$HOME/path"`, or a bare
  # absolute executable in either spelling. Only the exact runtime-home
  # prefix is expandable; arbitrary variables stay unresolved rather than
  # becoming trusted paths.
  target=$(printf '%s' "$cmd" | sed -n \
    -e 's|.*"\(/[^"]*\)".*|\1|p' \
    -e 's|.*"\(\$HOME/[^"]*\)".*|\1|p')
  [ -n "$target" ] || case $cmd in /*|'$HOME/'*) target=${cmd%% *} ;; esac
  printf '%s' "$target"
}

# The tracked settings.json is a template: every home path is spelled with a
# literal $HOME (a shell expands it in hook commands, and a file that names no
# real home can never point a restored account at a different user's missing
# hook). A live file carries this machine's rendered spelling. Tests and
# bootstrap fixtures override CLAUDE_HOME. Map the harness-home prefix, in
# both spellings, into the harness home being reconciled; render a bare $HOME
# prefix with this machine's home; all other paths retain their exact meaning.
target_in_harness_home() {
  local target=$1
  case $target in
    "$HOME/.claude") printf '%s' "$H" ;;
    "$HOME/.claude/"*) printf '%s/%s' "$H" "${target#"$HOME"/.claude/}" ;;
    '$HOME/.claude') printf '%s' "$H" ;;
    '$HOME/.claude/'*) printf '%s/%s' "$H" "${target#\$HOME/.claude/}" ;;
    '$HOME') printf '%s' "$HOME" ;;
    '$HOME/'*) printf '%s/%s' "$HOME" "${target#\$HOME/}" ;;
    *) printf '%s' "$target" ;;
  esac
}

# A system unit template spells the harness home as a literal $HOME/.claude/ (any other
# home path as $HOME/) for the same reason settings.json does. A system unit runs as root,
# where %h is /root, so the installed copy must carry the absolute path: `./setup --root` renders
# the template for this account and compares the live file with that rendering, and
# `push` reverses it so a captured unit stays a template.
render_system_unit() { # $1 template, $2 rendered output
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//"\$HOME/.claude/"/"$H/"}
    line=${line//"\$HOME/"/"$HOME/"}
    printf '%s\n' "$line"
  done < "$1" > "$2"
}
unrender_system_unit() { # $1 live unit, $2 template output
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//"$H/"/"\$HOME/.claude/"}
    line=${line//"$HOME/"/"\$HOME/"}
    printf '%s\n' "$line"
  done < "$1" > "$2"
}

# A CLAUDE_CODE_PLUGIN_DIRS list with every entry mapped through
# target_in_harness_home and joined by ':' again. The canonical value spells the
# harness's own mods as $HOME/.claude/mods/<mod>: ~/.claude/mods is a
# STABLE_DIRS symlink into the canonical checkout, so the live entry stays
# correct whichever checkout ran the reconcile, a worktree included, the same
# way a registered hook command resolves through the $H/hooks symlink. No
# existence check here: the reconcile tests each folder before writing, and
# check() tests the same folders before trusting an equal string. No shape
# check either: the read below stops at the first newline and drops a trailing
# empty field, so both callers run plugin_dirs_invalid_reason before this.
mapped_plugin_dirs_of() {
  local list=$1 out="" entry
  local -a entries=()
  IFS=: read -r -a entries <<<"$list"
  for entry in "${entries[@]}"; do
    out="${out:+$out:}$(target_in_harness_home "$entry")"
  done
  printf '%s' "$out"
}

# Why a CLAUDE_CODE_PLUGIN_DIRS list cannot be used as written, or nothing when
# it can. A control character is refused first: the here-string read behind the
# split in mapped_plugin_dirs_of stops at the first newline, so "a\nb" would
# validate on "a" alone and be written as a one-entry list that loads only the
# first mod. An empty entry (a leading, trailing or doubled colon) would be
# dropped silently by the same split, and an entry that is neither absolute nor
# under $HOME is one this harness cannot test for a manifest, so each is
# refused rather than written on trust.
plugin_dirs_invalid_reason() {
  local list=$1 entry
  local -a entries=()
  case $list in
    '') printf '%s' 'is empty'; return 0 ;;
    *[[:cntrl:]]*) printf '%s' 'contains a control character (a newline, carriage return or tab), at which the colon split would silently cut the list'; return 0 ;;
    :*|*:|*::*) printf '%s' 'has an empty entry (a leading, trailing or doubled colon)'; return 0 ;;
  esac
  IFS=: read -r -a entries <<<"$list"
  for entry in "${entries[@]}"; do
    case $entry in
      /*|'$HOME/'*) ;;
      *) printf '%s' "names $entry, which is not an absolute path"; return 0 ;;
    esac
  done
  return 0
}

# The first entry of a mapped CLAUDE_CODE_PLUGIN_DIRS list with no plugin
# manifest at <entry>/.claude-plugin/plugin.json, or nothing when each has one.
plugin_dir_missing_manifest() {
  local mapped=$1 entry
  local -a entries=()
  IFS=: read -r -a entries <<<"$mapped"
  for entry in "${entries[@]}"; do
    [ -f "$entry/.claude-plugin/plugin.json" ] || { printf '%s' "$entry"; return 0; }
  done
  return 0
}

# A mapped CLAUDE_CODE_PLUGIN_DIRS list with this host's own plugin folders
# appended: <overlay>/plugin-dirs, one absolute folder per line, blank lines and
# # comments ignored (the skill-plugins line format). Each folder is added once,
# after the tracked list, so a mod added to the tracked list later still reaches
# the host. A line that cannot be loaded (not absolute, a colon or control
# character in it, no .claude-plugin/plugin.json there) is left out and named on
# stderr; the rest is still returned. With no tracked list, or no file, the input
# comes back unchanged. reconcile_runtime_env, build_settings_desired and check
# all call this, so the three agree on one value.
plugin_dirs_with_overlay() {
  local list=$1 dir file line folder why
  [ -n "$list" ] || return 0
  if ! dir=$(overlay_dir) || [ ! -f "$dir/plugin-dirs" ]; then
    printf '%s' "$list"
    return 0
  fi
  file=$dir/plugin-dirs
  while IFS= read -r line || [ -n "$line" ]; do
    folder=${line%%#*}
    folder="${folder#"${folder%%[![:space:]]*}"}"
    folder="${folder%"${folder##*[![:space:]]}"}"
    [ -n "$folder" ] || continue
    why=""
    case $folder in
      *[[:cntrl:]]*) why='it contains a control character' ;;
      *:*) why='it contains a colon, which separates entries in the list' ;;
      /*) [ -f "$folder/.claude-plugin/plugin.json" ] || why='it has no .claude-plugin/plugin.json' ;;
      *) why='it is not an absolute path' ;;
    esac
    if [ -n "$why" ]; then
      printf '%s names %s, which is left out of CLAUDE_CODE_PLUGIN_DIRS: %s\n' "$file" "$folder" "$why" >&2
      continue
    fi
    case ":$list:" in *":$folder:"*) continue ;; esac
    list="$list:$folder"
  done <"$file"
  printf '%s' "$list"
}

reconcile_hook_group() {
  local label=$1 event=$2 cmd=$3
  local live=$H/settings.json canonical=${4:-$HERE/settings.json} canonical_group
  local extra_dead=${5:-[]}
  local tmp backup mode target checked_target require_target
  local dead_twins canonical_base twin_cmd twin_target twin_checked
  local -a retired_targets respelled_targets

  guard_no_credentials || return 1
  # Harness-owned targets must exist even when their parent tree is absent.
  # External operator-specific targets (DCG) keep the established foreign-host
  # exception only when their parent itself is absent; once that parent exists,
  # a missing executable is a real defect.
  target=$(hook_command_target "$cmd")
  checked_target=$(target_in_harness_home "$target")
  require_target=0
  case $checked_target in
    "$H"|"$H"/*) require_target=1 ;;
    *) [ -d "$(dirname "$checked_target")" ] && require_target=1 ;;
  esac
  if [ -n "$checked_target" ] && [ "$require_target" -eq 1 ] && [ ! -e "$checked_target" ]; then
    echo "$label reconcile: hook target $target does not exist at $checked_target (registering it would fail on every event); live settings were not changed" >&2
    echo "  if this hook is still on an unmerged branch, merge it and pull the main checkout first" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "$label reconcile requires jq; settings.json was not changed" >&2
    return 1
  }
  jq -e . "$canonical" >/dev/null 2>&1 || {
    echo "$label reconcile: canonical settings.json is invalid; live settings were not changed" >&2
    return 1
  }

  canonical_group=$(jq -ce --arg event "$event" --arg cmd "$cmd" '
    [
      .hooks[$event][]?
      | select([.hooks[]? | select(.type == "command" and .command == $cmd)] | length > 0)
    ]
    | if length == 1 then .[0]
      else error("canonical settings must contain exactly one standalone hook group for this command")
      end
  ' "$canonical") || {
    echo "$label reconcile: canonical hook is missing or duplicated; live settings were not changed" >&2
    return 1
  }

  mkdir -p "$H" || return 1
  if [ ! -e "$live" ]; then
    command install -m 0600 "$canonical" "$live" || {
      echo "$label reconcile: could not seed live settings.json" >&2
      return 1
    }
    echo "  seeded settings.json with canonical $label hook"
    return 0
  fi
  [ -f "$live" ] && [ ! -L "$live" ] && jq -e . "$live" >/dev/null 2>&1 || {
    echo "$label reconcile: live settings.json is missing, symlinked, not a regular file, or invalid; it was not changed" >&2
    return 1
  }

  # A hook that MOVES leaves its old registration behind. The strip below
  # matches by exact command string, so the stale spelling survives and the
  # canonical one is inserted BESIDE it rather than replacing it; every
  # matching event then fires a command that cannot run, while settings.json
  # looks correct and install prints success. Measured 2026-08-27 (#509) — two
  # such twins survived a textbook-correct cutover and were found only by hand.
  #
  # Retire a prior registration only when BOTH hold: it names the same hook
  # basename as the canonical command, AND its target is absent from disk.
  # The basename alone is NOT enough — until dotfiles#991 codex-quota-guard.js
  # was deliberately registered twice, under ~/.claude/hooks and under the
  # per-host routing tree, so a basename rule would have deleted a working
  # registration. Requiring the target to be missing is what makes the removal
  # provable rather than a guess: a registration pointing at nothing has no
  # behaviour to lose. A twin that is present but SUPERSEDED is a different
  # case and needs explicit retirement, never this generic rule.
  #
  # Two registrations of UNRELATED hooks can share a basename (two index.js).
  # Retiring the missing one is still correct — it could only fail on every
  # event — but note this fires solely while reconciling that hook, so a stale
  # entry for a hook install does not manage is left for harness-doctor 8a.
  # $6 lets a hook-specific reconciler name registrations it KNOWS are superseded
  # (dcg's previous version, kept on disk as a rollback, is the case: present, so
  # the missing-target rule below cannot retire it). Merged, never replacing.
  dead_twins=$extra_dead
  retired_targets=()
  respelled_targets=()
  canonical_base=${target##*/}
  if [ -n "$target" ] && [ -n "$canonical_base" ]; then
    while IFS= read -r twin_cmd; do
      [ -n "$twin_cmd" ] || continue
      [ "$twin_cmd" != "$cmd" ] || continue
      twin_target=$(hook_command_target "$twin_cmd")
      [ -n "$twin_target" ] || continue
      [ "${twin_target##*/}" = "$canonical_base" ] || continue
      twin_checked=$(target_in_harness_home "$twin_target")
      [ -n "$twin_checked" ] || continue
      if [ "$twin_checked" = "$checked_target" ]; then
        # The same file under another spelling: a registration rendered with
        # a real home before the tracked file became a $HOME template. One
        # file, one registration: the canonical spelling replaces it.
        dead_twins=$(printf '%s' "$dead_twins" | jq -c --arg c "$twin_cmd" '. + [$c]') || return 1
        respelled_targets+=("$twin_target")
        continue
      fi
      [ ! -e "$twin_checked" ] || continue
      dead_twins=$(printf '%s' "$dead_twins" | jq -c --arg c "$twin_cmd" '. + [$c]') || return 1
      retired_targets+=("$twin_target")
    done < <(jq -r --arg event "$event" '.hooks[$event][]? | .hooks[]? | .command // empty' "$live")
  fi

  tmp=$(mktemp "$H/.settings.json.hook.XXXXXX") || return 1
  if ! jq --arg event "$event" --arg cmd "$cmd" --argjson canonical "$canonical_group" --argjson dead "$dead_twins" '
    .hooks = (.hooks // {})
    | ([
            (.hooks[$event] // [])[]
            # Bind $c first: the argument to index() is evaluated against the
            # INPUT to index(), so inside ($dead | index(.command)) the .command
            # would resolve against $dead -- the array -- and error on every hook.
            | .hooks = ((.hooks // []) | map(select(.command as $c | $c != $cmd and ($dead | index($c) == null))))
            | select((.hooks | length) > 0)
       ]) as $groups
    | .hooks[$event] = [$canonical] + $groups
  ' "$live" >"$tmp"; then
    rm -f "$tmp"
    echo "$label reconcile failed; live settings.json was not changed" >&2
    return 1
  fi

  if cmp -s <(jq -S . "$live") <(jq -S . "$tmp"); then
    rm -f "$tmp"
    echo "  $label hook already reconciled"
    return 0
  fi

  mkdir -p "$H/backups" || {
    rm -f "$tmp"
    return 1
  }
  backup=$(mktemp -d "$H/backups/hook-adopt-$(date +%Y%m%d-%H%M%S)-XXXXXX") || {
    rm -f "$tmp"
    return 1
  }
  cp -a "$live" "$backup/settings.json" || {
    rm -f "$tmp"
    return 1
  }
  mode=$(stat -c '%a' "$live" 2>/dev/null || echo 600)
  if ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$live"; then
    rm -f "$tmp"
    echo "$label reconcile: atomic settings replacement failed; backup remains at $backup/settings.json" >&2
    return 1
  fi
  # Reported only after the replacement succeeded, so the line never claims a
  # removal that a failed write rolled back. The backup path follows it, which
  # is the recovery anchor if a retirement turns out to be wrong.
  if [ "${#retired_targets[@]}" -gt 0 ]; then
    for twin_target in "${retired_targets[@]}"; do
      echo "  retired stale $label registration at $twin_target (no file there; it could only fail on every event)"
    done
  fi
  if [ "${#respelled_targets[@]}" -gt 0 ]; then
    for twin_target in "${respelled_targets[@]}"; do
      echo "  replaced the $label registration spelled $twin_target with the canonical spelling (same file)"
    done
  fi
  echo "  reconciled $label hook; previous settings backed up to $backup/settings.json"
}

# reconcile_dcg_hook [--write-canonical]
#
# DCG hook path policy (dotfiles#1201). The TRACKED settings.json names the
# stable symlink ~/.local/bin/dcg and never a version. The LIVE settings.json
# names the RESOLVED versioned binary (~/.local/lib/dcg/vX.Y.Z/dcg): upstream's
# fail-closed absolute hook path, the form dcg's own self_heal_hook writes, and
# the reason a repointed symlink cannot silently swap the guard. This reconciler
# bridges the two forms:
#
#   * the canonical group is materialised in a temp copy with its dcg command
#     resolved to $DCG_COMMAND before the generic reconcile runs, so the live
#     file always carries the resolved path and the repo never carries one;
#   * every live dcg registration naming a DIFFERENT version is retired as
#     superseded. dcg is a single-slot registration; the previous version dir
#     is deliberately kept on disk as the rollback affordance (dcg-update.sh),
#     so the generic "target missing" twin rule below would never fire for it
#     and a promote would leave two guards registered.
#
# Without the flag this is READ-ONLY against the checkout (what `./setup`
# uses; an unattended writer inside the checkout manufactures the local
# modification that makes the next fast-forward refuse, dotfiles#479).
#
# `--write-canonical` is now a MIGRATION only: a canonical that still carries a
# versioned path is rewritten to the symlink form. It never records a version.
# Before 2026-09-18 this verb wrote the promoted version INTO the tracked file,
# and dcg-update.sh invoked it through the ~/.claude/scripts symlink, where
# `cd .../scripts/..` resolves to ~/.claude: every nightly promote from
# 2026-08-28 to 2026-09-17 therefore "recorded" the version into the LIVE file
# while the tracked copy froze on a version that was later reaped (#1201).
# The tracked file spells the symlink with the template's $HOME; the live file
# carries this machine's rendered path. The patterns accept both spellings, the
# home escaped for the ERE and Oniguruma (jq) engines they reach.
DCG_SYMLINK='$HOME/.local/bin/dcg'
DCG_HOME_RE=$(printf '%s' "$HOME" | sed -e 's/[][\\.^$*+?(){}|/]/\\&/g')
DCG_VERSIONED_RE="^(\\\$HOME|$DCG_HOME_RE)/\\.local/lib/dcg/v[0-9]+\\.[0-9]+\\.[0-9]+/dcg\$"
DCG_PATH_RE="^(\\\$HOME|$DCG_HOME_RE)/\\.local/(lib/dcg/v[0-9]+\\.[0-9]+\\.[0-9]+|bin)/dcg\$"
reconcile_dcg_hook() {
  local write_canonical=0
  [ "${1:-}" = "--write-canonical" ] && write_canonical=1
  local canonical=$HERE/settings.json tmp normalized="" dead='[]' rc

  command -v jq >/dev/null 2>&1 || {
    echo "DCG reconcile requires jq; settings.json was not changed" >&2
    return 1
  }
  jq -e . "$canonical" >/dev/null 2>&1 || {
    echo "DCG reconcile: canonical settings.json is invalid; live settings were not changed" >&2
    return 1
  }

  # Migration: a versioned path in the tracked file becomes the symlink form.
  if [ "$write_canonical" -eq 1 ] && jq -e --arg re "$DCG_PATH_RE" --arg sym "$DCG_SYMLINK" '
        [.. | objects | (.command? // "") | select(test($re) and . != $sym)] | length > 0
      ' "$canonical" >/dev/null 2>&1; then
    tmp=$(mktemp "$HERE/.settings.json.dcg.XXXXXX") || return 1
    if jq --arg re "$DCG_PATH_RE" --arg sym "$DCG_SYMLINK" '
          (.. | objects | select((.command? // "") | test($re)) | .command) |= $sym
        ' "$canonical" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$canonical"
      echo "  canonical settings.json dcg hook normalized to $DCG_SYMLINK (the repo records no version)"
    else
      rm -f "$tmp"
      echo "  WARN: could not normalize the canonical dcg hook to $DCG_SYMLINK" >&2
      return 1
    fi
  fi

  # The live file gets the resolved path: materialise the canonical group with
  # $DCG_COMMAND in a temp copy. Left alone when they already agree (a host
  # with no dcg installed resolves DCG_COMMAND to the symlink itself).
  if ! jq -e --arg cmd "$DCG_COMMAND" \
       '[.. | objects | select(.command? == $cmd)] | length > 0' "$canonical" >/dev/null 2>&1; then
    normalized=$(mktemp "${TMPDIR:-/tmp}/sync-dcg-settings.XXXXXX") || return 1
    if ! jq --arg re "$DCG_PATH_RE" --arg cmd "$DCG_COMMAND" '
          (.. | objects | select((.command? // "") | test($re)) | .command) |= $cmd
        ' "$canonical" >"$normalized" 2>/dev/null || [ ! -s "$normalized" ]; then
      rm -f "$normalized"
      echo "  WARN: could not resolve the canonical dcg hook to $DCG_COMMAND" >&2
      return 1
    fi
    echo "  dcg hook: repo names $DCG_SYMLINK; live is reconciled to the installed $DCG_COMMAND"
  fi

  # Superseded live registrations: a VERSIONED dcg path that is not the resolved
  # command (the previous release after a promote). A live entry spelled as the
  # symlink is left alone: it resolves to the installed binary, so it is a
  # duplicate the operator chose, not a stale guard.
  if [ -f "$H/settings.json" ]; then
    dead=$(jq -c --arg re "$DCG_VERSIONED_RE" --arg cmd "$DCG_COMMAND" '
        [.hooks.PreToolUse[]? | .hooks[]? | (.command // "") | select(test($re) and . != $cmd)] | unique
      ' "$H/settings.json" 2>/dev/null) || dead='[]'
  fi

  reconcile_hook_group "DCG" PreToolUse "$DCG_COMMAND" "${normalized:-$canonical}" "$dead"
  rc=$?
  [ -n "$normalized" ] && rm -f "$normalized"
  if [ "$rc" -eq 0 ] && [ "$dead" != "[]" ]; then
    echo "  retired superseded dcg registration(s): $(printf '%s' "$dead" | jq -r 'join(", ")')"
  fi
  return $rc
}

# The papercut plugin owns its three hooks; the seed carries none.
# harness-doctor section 19 reports missing or duplicate registrations.
PAPERCUT_PLUGIN_ID=papercut@hov
papercut_plugin_active() {
  local registry=${CLAUDE_INSTALLED_PLUGINS:-$H/plugins/installed_plugins.json}
  command -v jq >/dev/null 2>&1 && [ -f "$registry" ] && [ -f "$H/settings.json" ] || return 1
  # A project-scope install runs only in that project, so it does not count.
  jq -e --arg id "$PAPERCUT_PLUGIN_ID" '(.plugins[$id] // []) | any(.scope == "user")' \
    "$registry" >/dev/null 2>&1 || return 1
  # Only an explicit true: `claude plugin install` writes it, and treating an absent
  # key as enabled could hide a missing registration.
  jq -e --arg id "$PAPERCUT_PLUGIN_ID" '.enabledPlugins[$id] == true' \
    "$H/settings.json" >/dev/null 2>&1
}

# The owner phase ensures papercut@hov is installed, including when called
# without the default plugin installer. The seed carries none of its hooks:
# without the plugin, a fresh host captures no failures. Left alone: an explicit
# enabledPlugins["papercut@hov"] = false (a choice; harness-doctor section 19 still
# reports the dead capture), a host with no claude CLI, and adding the hov marketplace
# (./setup's job; adding a marketplace trusts a new source).
# CLAUDE_SYNC_CLAUDE_BIN names the claude CLI to run (default: the one on PATH); a
# path that is not executable counts as no CLI. Returns 1 when the CLI is there and
# the install or enable failed; `role owner` then finishes and exits 3.
PAPERCUT_MARKETPLACE_SOURCE=StartupBros-com/hov-stack
PAPERCUT_INSTALL_ERROR=
papercut_claude() {
  # The CLI writes the plugin registry and enabledPlugins under its config directory,
  # which must be the $H this run reads. CLAUDE_CONFIG_DIR also moves where Claude
  # Code reads .claude.json, so it is set only when $H is not the default.
  if [ "$H" = "$HOME/.claude" ]; then
    env -u CLAUDE_CONFIG_DIR "$@"
  else
    env CLAUDE_CONFIG_DIR="$H" "$@"
  fi
}
ensure_papercut_plugin() {
  local claude registry verb out rc=0
  local -a run=()
  PAPERCUT_INSTALL_ERROR=
  if papercut_plugin_active; then
    echo "  papercut: $PAPERCUT_PLUGIN_ID is installed at user scope and enabled"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1 || [ ! -f "$H/settings.json" ]; then
    echo "  papercut: $PAPERCUT_PLUGIN_ID not installed: needs jq and $H/settings.json (./setup seeds it)"
    return 0
  fi
  if jq -e --arg id "$PAPERCUT_PLUGIN_ID" '.enabledPlugins[$id] == false' "$H/settings.json" >/dev/null 2>&1; then
    echo "  papercut: $PAPERCUT_PLUGIN_ID is disabled in settings.json, so it was left as it is (claude plugin enable $PAPERCUT_PLUGIN_ID --scope user turns it back on)"
    return 0
  fi
  claude=${CLAUDE_SYNC_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}
  if [ -z "$claude" ] || [ ! -x "$claude" ]; then
    echo "  papercut: no claude CLI${claude:+ at $claude}, so $PAPERCUT_PLUGIN_ID was not installed (install Claude Code, then re-run ./setup)"
    return 0
  fi
  registry=${CLAUDE_INSTALLED_PLUGINS:-$H/plugins/installed_plugins.json}
  verb=install
  [ -f "$registry" ] \
    && jq -e --arg id "$PAPERCUT_PLUGIN_ID" '(.plugins[$id] // []) | any(.scope == "user")' "$registry" >/dev/null 2>&1 \
    && verb=enable
  command -v timeout >/dev/null 2>&1 && run=(timeout 300)
  echo "  papercut: claude plugin $verb $PAPERCUT_PLUGIN_ID --scope user"
  out=$(papercut_claude "${run[@]}" "$claude" plugin "$verb" "$PAPERCUT_PLUGIN_ID" --scope user </dev/null 2>&1) || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then
    PAPERCUT_INSTALL_ERROR="claude plugin $verb $PAPERCUT_PLUGIN_ID exited $rc: $(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}')"
    echo "  ERROR papercut: $PAPERCUT_INSTALL_ERROR" >&2
    echo "    If the hov marketplace is not added: claude plugin marketplace add $PAPERCUT_MARKETPLACE_SOURCE" >&2
    echo "    If its local copy is stale: claude plugin marketplace update hov" >&2
    return 1
  fi
  if ! papercut_plugin_active; then
    PAPERCUT_INSTALL_ERROR="claude plugin $verb $PAPERCUT_PLUGIN_ID exited 0, but it is still not installed at user scope and enabled"
    echo "  ERROR papercut: $PAPERCUT_INSTALL_ERROR" >&2
    return 1
  fi
  echo "  papercut: $PAPERCUT_PLUGIN_ID is now installed at user scope and enabled"
}

# A model-initiated EnterPlanMode call drops a session out of bypass
# permissions, so both settings reconcilers carry a canonical bare-name deny
# into live settings (dotfiles#1392). The union is keyed on canonical presence,
# not validated as a defense, so removing the entry later cannot break install.
# True when the settings file denies EnterPlanMode by exact bare name.
denies_enter_plan_mode() {
  jq -e '(.permissions.deny // []) as $deny
    | ($deny | type) == "array" and any($deny[]; . == "EnterPlanMode")' "$1" >/dev/null 2>&1
}
# Append the deny when live lacks it, keeping live entries and their order;
# refuse a live deny that is not an array.
ENSURE_ENTER_PLAN_MODE_DENIED_JQ='def ensure_enter_plan_mode_denied:
  .permissions.deny as $deny
  | if $deny == null then .permissions.deny = ["EnterPlanMode"]
    elif ($deny | type) != "array" then error("live permissions.deny is not an array")
    elif any($deny[]; . == "EnterPlanMode") then .
    else .permissions.deny = $deny + ["EnterPlanMode"]
    end;'

# Shared by the owner-phase preflight, runtime reconciliation and the drift projection.
# Test the type before floor: malformed non-numeric live values are drift, not
# a jq failure that could accidentally empty both sides of a comparison.
VALID_COMPACT_WINDOW_JQ='def valid_compact_window:
  if type == "number" then . == floor and . >= 100000 and . <= 1000000
  else false end;'

# The drift projection's last step, on both sides: two spellings Claude Code
# treats alike compare alike. A hook command runs through a shell, so its
# `$HOME/` is rendered with lib/settings-seed.js's mapping ($HOME/.claude to the
# config dir, then $HOME/ to the home). A permission rule's `$HOME/` is rendered
# the same way for another reason: setup's seed writes the rendered rule and
# older installations kept the template's spelling; settings-seed.js already
# counts the two spellings as one entry. Env values are read literally and are
# not rendered here. An event with no hooks is no event, and
# hook groups and the hooks in a group are sorted: "When an event fires, its
# matching hooks run in parallel" (code.claude.com/docs/en/hooks). Permission
# lists are sorted too: rules are applied by kind (deny, then ask, then allow),
# not by their position in a list.
SETTINGS_NORMAL_JQ='def render_home($cfg; $home):
  split("$HOME/.claude") | join($cfg) | split("$HOME/") | join($home + "/");
def settings_normal($cfg; $home):
  (if (.permissions | type) == "object"
   then .permissions |= with_entries(if (.value | type) == "array"
          then .value |= (map(if type == "string" then render_home($cfg; $home) else . end) | sort)
          else . end)
   else . end)
  | (if (.hooks | type) == "object"
     then .hooks |= (with_entries(select(.value != []))
       | map_values(if type == "array"
           then map(if type == "object" and (.hooks | type) == "array"
                    then .hooks |= (map(if type == "object" and (.command | type) == "string"
                                        then .command |= render_home($cfg; $home) else . end) | sort)
                    else . end)
                | sort
           else . end))
     else . end);'

validate_canonical_compact_window() {
  if ! jq -e "$VALID_COMPACT_WINDOW_JQ"'.autoCompactWindow | valid_compact_window' "$HERE/settings.json" >/dev/null; then
    echo "runtime-env reconcile: canonical settings defenses are missing or invalid (autoCompactWindow must be an integer from 100000 to 1000000); live settings were not changed" >&2
    return 1
  fi
}

# settings.json is volatile, so seeding these keys on a fresh machine is not
# enough: an already-configured machine keeps its live file. Merge only the
# canonical defense-in-depth settings and preserve every other live key.
reconcile_runtime_env() (
  local live=$H/settings.json canonical=$HERE/settings.json canonical_defenses plan_deny=false
  local env_file env_target scratch="" tmp="" replace_tmp="" backup mode proxy_base_url=""

  cleanup_runtime_env() {
    [ -z "$replace_tmp" ] || rm -f -- "$replace_tmp"
    [ -z "$tmp" ] || rm -f -- "$tmp"
    [ -z "$scratch" ] || rmdir -- "$scratch" 2>/dev/null || true
  }
  trap cleanup_runtime_env EXIT

  guard_no_credentials || return 1
  command -v jq >/dev/null 2>&1 || {
    echo "runtime-env reconcile requires jq; settings.json was not changed" >&2
    return 1
  }
  validate_canonical_compact_window || return 1
  canonical_defenses=$(jq -ce '
    . as $settings
    | .env as $env
    | {
        env: {
          CLAUDE_CODE_TOOL_MEMORY_LIMIT: $env.CLAUDE_CODE_TOOL_MEMORY_LIMIT,
          CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP: $env.CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP,
          CLAUDE_ENV_FILE: $env.CLAUDE_ENV_FILE,
          WACLI_STORE_DIR: $env.WACLI_STORE_DIR,
          PRO_GATE_ROUND_GUARD: $env.PRO_GATE_ROUND_GUARD,
          CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS: $env.CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS
        },
        autoCompactWindow: $settings.autoCompactWindow,
        typescriptLsp: $settings.enabledPlugins["typescript-lsp@claude-plugins-official"],
        disableAutoMode: $settings.permissions.disableAutoMode,
        defaultMode: $settings.permissions.defaultMode
      }
    # CLAUDE_CODE_PLUGIN_DIRS is optional: a canonical copy that drops it
    # retires the mod list, so the key is carried only when present (a
    # present empty string still fails the non-empty check below). It is
    # added as a step after the object literal because jq 1.7, which the
    # install-smoke container runs, rejects an infix operator as an object
    # value ("May need parentheses around object key expression").
    | if ($env | has("CLAUDE_CODE_PLUGIN_DIRS"))
      then .env.CLAUDE_CODE_PLUGIN_DIRS = $env.CLAUDE_CODE_PLUGIN_DIRS
      else . end
    # modelSettings.<model>.autoCompactWindow (dotfiles#1574): the fleet
    # auto-compact window per Anthropic model. Only the window is canonical;
    # the same object also holds operator saves (/autocompact, effort) and
    # gateway-route entries, so the projection keeps just that one field per
    # named model and the merge below is a per-model deep merge.
    # A canonical map or entry that is not an object fails the type check
    # below (a non-object entry is projected as the window itself), never
    # a jq error: the refusal names the defenses check either way.
    | .modelSettings = (($settings.modelSettings // {})
        | if type == "object" then . else {"": .} end
        | with_entries(.value |= (if type == "object" then {autoCompactWindow: .autoCompactWindow} else {autoCompactWindow: .} end))
        | with_entries(select(.value.autoCompactWindow != null)))
    | if all(.env[]; type == "string" and length > 0)
        and .typescriptLsp == false
        and .disableAutoMode == "disable"
        and .defaultMode == "bypassPermissions"
        and all(.modelSettings | to_entries[]; (.key | length) > 0
                                  and (.value.autoCompactWindow | type) == "number"
                                  and (.value.autoCompactWindow | . == floor)
                                  and .value.autoCompactWindow >= 100000
                                  and .value.autoCompactWindow <= 1000000)
      then .
      else error("canonical runtime defenses are missing or invalid")
      end
  ' "$canonical") || {
    echo "runtime-env reconcile: canonical settings defenses are missing or invalid; live settings were not changed" >&2
    return 1
  }

  # The mapped target lives under the harness home in portable fixtures. Make
  # that home real before validating, then require the env file itself: a
  # settings entry pointing at a missing file silently loses both shell shims.
  mkdir -p "$H" || return 1
  env_file=$(printf '%s' "$canonical_defenses" | jq -r .env.CLAUDE_ENV_FILE)
  env_target=$(target_in_harness_home "$env_file")
  if [ ! -f "$env_target" ]; then
    echo "runtime-env reconcile: CLAUDE_ENV_FILE target $env_file is not a regular file at $env_target; live settings were not changed" >&2
    echo "  if it is still on an unmerged branch, merge it and pull the main checkout first" >&2
    return 1
  fi
  canonical_defenses=$(printf '%s' "$canonical_defenses" | jq -ce --arg env_target "$env_target" '
    .env.CLAUDE_ENV_FILE = $env_target
  ') || {
    echo "runtime-env reconcile: could not map the canonical CLAUDE_ENV_FILE; live settings were not changed" >&2
    return 1
  }

  # The mods the harness loads in every session are reached through the
  # ~/.claude/mods STABLE_DIRS symlink (linked by ./setup, like the env file
  # above), so each CLAUDE_CODE_PLUGIN_DIRS entry is mapped through CLAUDE_HOME
  # and must carry a plugin manifest first: a settings entry pointing at a
  # missing folder makes the engine log a failed load in every session, and
  # nothing else would say why (the same silent-loss shape as a missing env
  # file). A list that cannot be read as written is refused the same way.
  plugin_dirs=$(printf '%s' "$canonical_defenses" | jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty')
  if [ -n "$plugin_dirs" ]; then
    invalid_plugin_dirs=$(plugin_dirs_invalid_reason "$plugin_dirs")
    if [ -n "$invalid_plugin_dirs" ]; then
      echo "runtime-env reconcile: canonical CLAUDE_CODE_PLUGIN_DIRS $invalid_plugin_dirs; live settings were not changed" >&2
      return 1
    fi
    mapped_plugin_dirs=$(mapped_plugin_dirs_of "$plugin_dirs")
    missing_plugin_dir=$(plugin_dir_missing_manifest "$mapped_plugin_dirs")
    if [ -n "$missing_plugin_dir" ]; then
      echo "runtime-env reconcile: CLAUDE_CODE_PLUGIN_DIRS names $missing_plugin_dir, but $missing_plugin_dir/.claude-plugin/plugin.json is not a regular file (the engine would log a failed load in every session); live settings were not changed" >&2
      echo "  install links ~/.claude/mods into the canonical checkout; if the mod is still on an unmerged branch, merge it and pull the main checkout first" >&2
      return 1
    fi
    mapped_plugin_dirs=$(plugin_dirs_with_overlay "$mapped_plugin_dirs")
    canonical_defenses=$(printf '%s' "$canonical_defenses" | jq -ce --arg dirs "$mapped_plugin_dirs" '
      .env.CLAUDE_CODE_PLUGIN_DIRS = $dirs
    ') || {
      echo "runtime-env reconcile: could not map the canonical CLAUDE_CODE_PLUGIN_DIRS; live settings were not changed" >&2
      return 1
    }
  fi

  # Every remaining canonical env value spelled with the template's $HOME/ is
  # rendered with this machine's home: Claude Code exports env values as
  # written, so an unrendered one would name a path that does not exist.
  canonical_defenses=$(printf '%s' "$canonical_defenses" | jq -ce --arg home "$HOME" '
    .env |= with_entries(.value |= (if type == "string" and startswith("$HOME/") then $home + .[5:] else . end))
  ') || {
    echo "runtime-env reconcile: could not render the canonical env paths; live settings were not changed" >&2
    return 1
  }

  # ANTHROPIC_BASE_URL is the first role-VARYING key in this merge: the guard
  # URL is loopback only where the proxy actually runs (workstation), and the
  # proxy host's tailnet serve URL on satellites. Mirror install()'s timer-role
  # case, including its refuse-to-guess arm: an undeclared host must not
  # inherit either role's URL (the author's infrastructure repository plan
  # 2026-08-30-0030-feat-ccflare-tailnet-sharing-plan.md, R7).
  case "$(profile_role 2>/dev/null || echo unknown)" in
    workstation) proxy_base_url="$CCFLARE_URL_WORKSTATION" ;;
    satellite)
      proxy_base_url="$CCFLARE_URL_SATELLITE"
      [ -n "$proxy_base_url" ] || {
        echo "runtime-env reconcile: this host is a satellite and CCFLARE_URL_SATELLITE is unset." >&2
        echo "  Set it in the overlay env (~/.config/hov-stack/env) to the proxy host's serve URL;" >&2
        echo "  live settings were not changed." >&2
        return 1
      } ;;
    *)
      echo "runtime-env reconcile: no usable role for $(hostname -s 2>/dev/null || hostname) in hosts.tsv." >&2
      echo "  Refusing to guess ANTHROPIC_BASE_URL (workstation = loopback guard, satellite =" >&2
      echo "  the proxy host's serve URL); live settings were not changed." >&2
      return 1 ;;
  esac
  canonical_defenses=$(printf '%s' "$canonical_defenses" | jq -ce --arg proxy_url "$proxy_base_url" '
    .env.ANTHROPIC_BASE_URL = $proxy_url
  ') || {
    echo "runtime-env reconcile: could not set the role proxy URL; live settings were not changed" >&2
    return 1
  }

  # Redirect jq only inside a unique /tmp directory. A second, same-directory
  # replacement file below exists solely to retain atomic rename semantics when
  # CLAUDE_HOME is mounted on a filesystem different from /tmp.
  scratch=$(mktemp -d /tmp/claude-runtime-env.XXXXXX) || return 1
  tmp=$scratch/settings.json
  if [ ! -e "$live" ]; then
    if ! jq --arg env_target "$env_target" --argjson canonical "$canonical_defenses" --arg home "$HOME" '
        .env.CLAUDE_ENV_FILE = $env_target
        | .env.ANTHROPIC_BASE_URL = $canonical.env.ANTHROPIC_BASE_URL
        | if ($canonical.env | has("CLAUDE_CODE_PLUGIN_DIRS"))
          then .env.CLAUDE_CODE_PLUGIN_DIRS = $canonical.env.CLAUDE_CODE_PLUGIN_DIRS
          else del(.env.CLAUDE_CODE_PLUGIN_DIRS) end
        | .enabledPlugins["typescript-lsp@claude-plugins-official"] = $canonical.typescriptLsp
        | .permissions.disableAutoMode = $canonical.disableAutoMode
        | .permissions.defaultMode = $canonical.defaultMode
        | .env |= with_entries(.value |= (if type == "string" and startswith("$HOME/") then $home + .[5:] else . end))
      ' "$canonical" >"$tmp"; then
      echo "runtime-env reconcile: could not render portable settings; live settings.json was not changed" >&2
      return 1
    fi
    command install -m 0600 "$tmp" "$live" || {
      echo "runtime-env reconcile: could not seed live settings.json" >&2
      return 1
    }
    echo "  seeded settings.json with portable canonical runtime policy"
    return 0
  fi
  [ -f "$live" ] && [ ! -L "$live" ] && jq -e . "$live" >/dev/null 2>&1 || {
    echo "runtime-env reconcile: live settings.json is missing, symlinked, not a regular file, or invalid; it was not changed" >&2
    return 1
  }

  denies_enter_plan_mode "$canonical" && plan_deny=true
  if ! jq --argjson canonical "$canonical_defenses" --argjson plan_deny "$plan_deny" "$ENSURE_ENTER_PLAN_MODE_DENIED_JQ"'
      .env = ((.env // {}) + $canonical.env)
      | if ($canonical.env | has("CLAUDE_CODE_PLUGIN_DIRS")) then . else del(.env.CLAUDE_CODE_PLUGIN_DIRS) end
      | .enabledPlugins = ((.enabledPlugins // {}) + {
          "typescript-lsp@claude-plugins-official": $canonical.typescriptLsp
        })
      # The standalone startup default is fleet-owned alongside Auto-off.
      # Explicit per-launch CLI modes still override this settings fallback.
      | .permissions = ((.permissions // {}) + {
          disableAutoMode: $canonical.disableAutoMode,
          defaultMode: $canonical.defaultMode
        })
      # Only absent/null global state adopts the fallback. Keep explicit live
      # values, including malformed non-null ones: check reports those as drift
      # without blocking unrelated runtime policy. Do not use // (eats false).
      | if .autoCompactWindow == null then .autoCompactWindow = $canonical.autoCompactWindow else . end
      # Per-model deep merge: a live entry keeps its own fields (effortLevel,
      # a window the operator saved for a model the canonical does not name),
      # and only the canonical window is written over it. For a model the
      # canonical names, the canonical window is the fleet value and an
      # interactive /autocompact save for that model is overwritten on the
      # next reconcile (same ownership rule as CLAUDE_CODE_PLUGIN_DIRS);
      # the per-launch override is CLAUDE_CODE_AUTO_COMPACT_WINDOW, which
      # outranks every settings value (claude-loop.sh sets it for runs).
      # A live map or entry that is not an object (a hand edit) is replaced
      # by the canonical value rather than aborting: this reconcile also
      # carries the permission floor, and one malformed window entry must
      # not hold that back.
      | .modelSettings = reduce ($canonical.modelSettings | to_entries[]) as $m
          ((if (.modelSettings | type) == "object" then .modelSettings else {} end);
           .[$m.key] = ((if (.[$m.key] | type) == "object" then .[$m.key] else {} end) + $m.value))
      | if $plan_deny then ensure_enter_plan_mode_denied else . end
    ' "$live" >"$tmp"; then
    echo "runtime-env reconcile failed; live settings.json was not changed" >&2
    return 1
  fi
  if cmp -s <(jq -S . "$live") <(jq -S . "$tmp"); then
    echo "  runtime policy already reconciled"
    return 0
  fi

  mkdir -p "$H/backups" || return 1
  backup=$(mktemp -d "$H/backups/env-adopt-$(date +%Y%m%d-%H%M%S)-XXXXXX") || {
    return 1
  }
  cp -a "$live" "$backup/settings.json" || return 1
  mode=600
  replace_tmp=$(mktemp "$H/.settings.json.env-replace.XXXXXX") || {
    echo "runtime-env reconcile: could not create atomic replacement; backup remains at $backup/settings.json" >&2
    return 1
  }
  if ! command install -m "$mode" "$tmp" "$replace_tmp" || ! mv -f "$replace_tmp" "$live"; then
    echo "runtime-env reconcile: atomic settings replacement failed; backup remains at $backup/settings.json" >&2
    return 1
  fi
  echo "  reconciled runtime policy; previous settings backed up to $backup/settings.json"
)

# Native Windows Claude Code remains a deliberate break-glass surface. Keep its
# mode-availability policy (Auto mode off, EnterPlanMode denied) in parity
# without copying the WSL harness or replacing unrelated Windows-local settings.
reconcile_windows_auto_mode() (
  local canonical=$HERE/windows-stub/settings.json live=$WIN/.claude/settings.json
  local tmp="" replace_tmp="" backup mode plan_deny=false

  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  cleanup_windows_auto_mode() {
    [ -z "$replace_tmp" ] || rm -f -- "$replace_tmp"
    [ -z "$tmp" ] || rm -f -- "$tmp"
  }
  trap cleanup_windows_auto_mode EXIT

  [ -d "$WIN" ] || {
    echo "  skipped Windows Auto-mode policy ($WIN is absent)"
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    echo "Windows Auto-mode reconcile requires jq; settings.json was not changed" >&2
    return 1
  }
  jq -e '.permissions.disableAutoMode == "disable"' "$canonical" >/dev/null 2>&1 || {
    echo "Windows Auto-mode reconcile: canonical policy is missing or invalid" >&2
    return 1
  }
  mkdir -p "$WIN/.claude" || return 1
  if [ ! -e "$live" ]; then
    command install -m 0600 "$canonical" "$live" || {
      echo "Windows Auto-mode reconcile: could not seed $live" >&2
      return 1
    }
    echo "  seeded Windows settings.json with disabled Auto mode"
    return 0
  fi
  if [ ! -f "$live" ] || [ -L "$live" ]; then
    echo "Windows Auto-mode reconcile: live settings.json is symlinked or non-regular" >&2
    return 1
  fi
  if ! jq -e . "$live" >/dev/null 2>&1; then
    echo "Windows Auto-mode reconcile: live settings.json is invalid" >&2
    return 1
  fi
  denies_enter_plan_mode "$canonical" && plan_deny=true
  tmp=$(mktemp "$WIN/.claude/.settings.json.auto-mode.XXXXXX") || return 1
  if ! jq --argjson plan_deny "$plan_deny" "$ENSURE_ENTER_PLAN_MODE_DENIED_JQ"'
      .permissions = ((.permissions // {}) + {disableAutoMode: "disable"})
      | if $plan_deny then ensure_enter_plan_mode_denied else . end
    ' "$live" >"$tmp"; then
    echo "Windows Auto-mode reconcile failed; Windows settings.json was not changed" >&2
    return 1
  fi
  if cmp -s <(jq -S . "$live") <(jq -S . "$tmp"); then
    echo "  Windows Auto-mode policy already reconciled"
    return 0
  fi
  mkdir -p "$H/backups" || return 1
  backup=$(mktemp -d "$H/backups/windows-auto-mode-adopt-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
  cp -a "$live" "$backup/settings.json" || return 1
  mode=$(stat -c '%a' "$live" 2>/dev/null || echo 600)
  replace_tmp=$(mktemp "$WIN/.claude/.settings.json.auto-mode-replace.XXXXXX") || return 1
  if ! command install -m "$mode" "$tmp" "$replace_tmp" || ! mv -f "$replace_tmp" "$live"; then
    rm -f "$tmp" "$replace_tmp"
    echo "Windows Auto-mode reconcile: atomic replacement failed; backup remains at $backup/settings.json" >&2
    return 1
  fi
  rm -f "$tmp"
  echo "  reconciled Windows Auto-mode policy; previous settings backed up to $backup/settings.json"
)

# `push` captures runtime-owned settings, so a stale runtime could otherwise
# overwrite a newly reviewed policy in the repo. Refuse before copying anything;
# `install` is the convergence operation for all three live settings surfaces.
guard_auto_mode_policy_for_push() {
  local label path policy_filter
  command -v jq >/dev/null 2>&1 || {
    echo "push refused: jq is required to verify the Auto-mode policy" >&2
    return 1
  }
  for label in user managed; do
    case "$label" in
      user)
        path=$H/settings.json
        policy_filter='.permissions.disableAutoMode == "disable"
          and .permissions.defaultMode == "bypassPermissions"
          and .permissions.disableBypassPermissionsMode != "disable"'
        ;;
      managed)
        path=$MANAGED_LOCK
        policy_filter='.permissions.disableAutoMode == "disable"
          and .permissions.disableBypassPermissionsMode != "disable"'
        ;;
    esac
    if [ ! -f "$path" ] || ! jq -e "$policy_filter" "$path" >/dev/null 2>&1; then
      local remedy=./setup
      [ "$label" != managed ] || remedy='./setup --root'
      echo "push refused: $label settings at $path violate the required Auto/default/bypass policy; run $remedy first" >&2
      return 1
    fi
  done
  # While the canonical EnterPlanMode deny propagates, an entry-less live file
  # would revert it; the check goes inert once the repo copy drops the entry.
  if denies_enter_plan_mode "$HERE/settings.json" && ! denies_enter_plan_mode "$H/settings.json"; then
    echo "push refused: user settings at $H/settings.json lack the EnterPlanMode deny that the repo copy carries; run ./setup first" >&2
    return 1
  fi
  if [ -d "$WIN" ]; then
    path=$WIN/.claude/settings.json
    if [ ! -f "$path" ] || ! jq -e '
        .permissions.disableAutoMode == "disable"
        and .permissions.disableBypassPermissionsMode != "disable"
      ' "$path" >/dev/null 2>&1; then
      echo "push refused: Windows settings at $path violate the required Auto/bypass policy; run ./setup first" >&2
      return 1
    fi
    if denies_enter_plan_mode "$HERE/windows-stub/settings.json" && ! denies_enter_plan_mode "$path"; then
      echo "push refused: Windows settings at $path lack the EnterPlanMode deny that the repo copy carries; run ./setup first" >&2
      return 1
    fi
  fi
}

# push_shrink_guard <live> <canonical> - refuse a push that would gut a file.
#
# Written after doing exactly this by accident on 2026-08-27. The role gate
# below correctly refused a push from the satellite; the documented override
# (DOTFILES_ROLE=workstation) then let it through, and one command replaced the
# workstation's 693-line settings.json with the laptop's -- deleting the entire
# env block (ccflare routing), every permission, every skillOverride and the
# plugin set. Recovered from git; nothing in the tool objected.
#
# So the role gate is necessary and NOT sufficient. An escape hatch one
# environment variable wide is a hatch someone falls through. This guard is
# role-INDEPENDENT on purpose, because the same shape threatens the workstation
# itself: Claude Code rewrites settings.json by atomic rename, and a truncated
# rewrite would be captured just as silently.
#
# Threshold is a two-thirds LOSS, not a diff. A legitimate edit trims entries;
# this fires only when most of the file evaporates. The escape is separate from
# the role override, so bypassing takes a second, different decision.
push_shrink_guard() {
  local live=$1 canon=$2 l c
  [ -f "$canon" ] || return 0
  [ "${SYNC_ALLOW_SHRINK:-0}" = 1 ] && return 0
  l=$(wc -l < "$live" 2>/dev/null || echo 0)
  c=$(wc -l < "$canon" 2>/dev/null || echo 0)
  [ "$c" -lt 20 ] && return 0
  if [ $(( l * 3 )) -lt "$c" ]; then
    echo "sync.sh push: REFUSED - $(basename "$canon") would shrink ${c} -> ${l} lines." >&2
    echo "  More than a two-thirds loss. If the live file is genuinely correct" >&2
    echo "  (a deliberate prune), re-run with SYNC_ALLOW_SHRINK=1." >&2
    return 1
  fi
  return 0
}

push() {
  # PUSH AUTHORITY. Canonical live state belongs to the workstation, by
  # declaration rather than by which box someone happened to run this on.
  #
  # Without this gate the first fix made on a satellite overwrites the
  # workstation's captured state, and nothing notices until a rebuild produces a
  # machine configured like the laptop. `push` is the only verb that writes the
  # repo from live state, so it is the only one that needs the gate; check,
  # install and the memory verbs stay available everywhere.
  if ! profile_is workstation; then
    echo "sync.sh push: refused — this host is '$(profile_role 2>/dev/null || echo undeclared)', not the workstation." >&2
    echo "  Canonical live state is the workstation's (see hosts.tsv). A satellite" >&2
    echo "  consumes the harness and never publishes it." >&2
    echo "  Add this host's row to hosts.tsv. To move canonical authority," >&2
    echo "  change the workstation declaration in hosts.tsv." >&2
    return 2
  fi
  guard_no_credentials || exit 1
  guard_auto_mode_policy_for_push || return 1
  guard_permission_drop_for_push || return 1
  # No "$HERE/memory" here: an existing mirror directory opts push and check into
  # memory (#346), so creating it on every push would opt every host in.
  # memory_push creates the mirror root itself when it runs.
  mkdir -p "$HERE/systemd" "$HERE/systemd-system" "$HERE/windows-stub"
  for d in $STABLE_DIRS; do
    # Only copy while un-adopted; once symlinked, repo and live are the same files.
    [ -d "$H/$d" ] && [ ! -L "$H/$d" ] && rsync -a --delete "$H/$d/" "$HERE/$d/"
  done
  for f in $STABLE_FILES; do
    [ -f "$H/$f" ] && [ ! -L "$H/$f" ] && cp "$H/$f" "$HERE/$f"
  done
  for f in $VOLATILE_FILES; do
    [ -f "$H/$f" ] || continue
    push_shrink_guard "$H/$f" "$HERE/$f" || exit 3
    if [ "$f" = "settings.json" ] && command -v jq >/dev/null 2>&1; then
      # The live file may carry the host-local better-ccflare API key
      # (env.ANTHROPIC_CUSTOM_HEADERS, or legacy env.ANTHROPIC_AUTH_TOKEN,
      # written by ccflare-key-install). It is a
      # secret and must never enter the tracked canonical copy — strip it on
      # the way in. guard_no_credentials cannot catch it (PEM-shaped secrets
      # only), and check() deliberately excludes the key from both sides of
      # its comparison, so this copy is the one containment point.
      # env.CLAUDE_CODE_PLUGIN_DIRS is harness-owned: reconcile_runtime_env
      # writes it from the canonical spelling mapped through CLAUDE_HOME, so the
      # live value is never the source of truth. Keep the canonical value here,
      # mapped or unapproved mod list into the tracked copy. Absence is just as
      # authoritative: a canonical copy that deliberately dropped the key must
      # not get the still-present live value copied back, which would silently
      # re-enable a retired mod list.
      canonical_plugin_dirs=$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$HERE/$f")
      canonical_plugin_dirs_present=$(jq -r '((.env | type) == "object") and (.env | has("CLAUDE_CODE_PLUGIN_DIRS"))' "$HERE/$f")
      # env paths rendered with this machine's home go back to the template's
      # $HOME/ spelling: the tracked copy names no real home.
      jq --arg dirs "$canonical_plugin_dirs" --argjson present "$canonical_plugin_dirs_present" --arg home "$HOME" '
        if (.env | type) == "object" then .env |= (del(.ANTHROPIC_AUTH_TOKEN) | del(.ANTHROPIC_CUSTOM_HEADERS)) else . end
        | if (.env | type) == "object"
          then (if $present then .env.CLAUDE_CODE_PLUGIN_DIRS = $dirs else del(.env.CLAUDE_CODE_PLUGIN_DIRS) end)
          else . end
        | if (.env | type) == "object"
          then .env |= with_entries(.value |= (if type == "string" and startswith($home + "/") then "$HOME" + .[($home | length):] else . end))
          else . end
      ' "$H/$f" > "$HERE/$f" || exit 3
    else
      cp "$H/$f" "$HERE/$f"
    fi
  done
  # Preview is always emitted before memory mutation. Copying is non-destructive.
  if memory_mirror_opted_in; then
    memory_push || return $?
  else
    echo "  memory not copied: $(memory_mirror_absent_reason)"
  fi
  for u in $UNITS; do
    mkdir -p "$(dirname "$HERE/systemd/$u")"          # $u may be "<unit>.d/<file>.conf"
    [ -f "$SYS/$u" ] && cp "$SYS/$u" "$HERE/systemd/$u"
  done
  # Root-owned system units are world-readable (0644, standard unit-file mode),
  # so capturing a deliberate `sudo install` into $SYSTEM_SYS needs no sudo here.
  for u in $SYSTEM_UNITS; do
    [ -f "$SYSTEM_SYS/$u" ] && unrender_system_unit "$SYSTEM_SYS/$u" "$HERE/systemd-system/$u"
  done
  # Root-owned managed lock is world-readable; capture a deliberate `sudo` edit
  # to /etc so it gets recorded (canonical source otherwise stays this repo).
  [ -f "$MANAGED_LOCK" ] && cp "$MANAGED_LOCK" "$MANAGED_REF"
  if [ -d "$WIN/.claude" ]; then
    cp "$WIN/.claude/CLAUDE.md"           "$HERE/windows-stub/CLAUDE.md"           2>/dev/null || true
    cp "$WIN/.claude/settings.json"       "$HERE/windows-stub/settings.json"       2>/dev/null || true
    cp "$WIN/.claude/settings.local.json" "$HERE/windows-stub/settings.local.json" 2>/dev/null || true
    cp "$WIN/AGENTS.md"                   "$HERE/windows-stub/AGENTS.md"           2>/dev/null || true
  fi
  echo "push complete — $(git -C "$HERE" status --porcelain 2>/dev/null | wc -l) path(s) changed"
}

# Read cron as inert text. crontab(1) uses exit 1 for the normal "no crontab"
# state, so distinguish that specific empty state from every other read error.
# The raw snapshot is mode 0600, never printed, and removed before returning.
read_active_crontab() {
  local snapshot=$1 error_file=$2 rc
  : >"$snapshot" || return 1
  chmod 600 "$snapshot" || return 1
  if crontab -l >"$snapshot" 2>"$error_file"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ] && [ ! -s "$snapshot" ] \
     && grep -qiE 'no crontab([[:space:]]|$)' "$error_file"; then
    : >"$snapshot"
    return 0
  fi
  return 1
}

quiesce_critical_silence_replacements() {
  local timers=${1:-$CRITICAL_SILENCE_TIMERS} reason=${2:-scheduler ownership safety gate}
  local timer service active_state failed=0 services=""
  [ -n "$timers" ] || return 0

  for timer in $timers; do
    case " $CRITICAL_SILENCE_TIMERS " in
      *" $timer "*) ;;
      *)
        echo "  ERROR: refusing to quiesce out-of-scope replacement $timer" >&2
        return 1
        ;;
    esac
    service=${timer%.timer}.service
    services="$services $service"
  done

  # NO-CLAIM BOUNDARY (2026-09-12, the author's infrastructure repository's #387): reachability probe
  # for the install()-side of this file (same intent as the undeclared-unit
  # check's NO-CLAIM BOUNDARY in check() further down, but that one gates on
  # `show -p Version` under a check()-specific contract; this one reuses
  # install()'s own existing `show-environment` reachability convention --
  # see the SYSTEM_UNITS
  # daemon-reload guard above -- so the two install-path probes agree, and
  # sync-install-smoke.test.sh's fake systemctl, which answers `show` and
  # `show-environment` differently on purpose, exercises this function's real
  # enable/disable/stop logic rather than short-circuiting it). Applied here
  # because moving install-smoke off a full-VM Blacksmith runner onto an ARC
  # container pod surfaced the gap -- the pod has no systemd PID 1 at all, so
  # every systemctl --user call below fails not because a migrated timer is
  # stuck, but because there is no session bus to ask. That is NOT the failure
  # this function exists to catch (a real double-scheduled job), and treating
  # it as one fails closed in every satellite/container/hermetic context that
  # never had one of these five units running in the first place. Unreachable
  # means "nothing here to quiesce" and prints a visible SKIP, every run, so
  # the narrowing cannot hide quietly; reachable but failing still fails
  # closed exactly as before.
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "  SKIP: no reachable systemd --user manager; migrated replacement(s) for $reason assumed absent"
    return 0
  fi

  echo "  quiescing migrated replacement(s): $reason"
  # shellcheck disable=SC2086
  if ! systemctl --user disable --now $timers >/dev/null 2>&1; then
    echo "  ERROR: could not disable migrated timer(s) after $reason" >&2
    failed=1
  fi

  # A timer can already be disabled while the oneshot it launched is still
  # running. Stop the same-name services explicitly, then prove every one is
  # exactly inactive before claiming the ownership handoff is safe. A failed
  # unit still needs operator-visible recovery and is not safe evidence.
  # shellcheck disable=SC2086
  if ! systemctl --user stop $services >/dev/null 2>&1; then
    echo "  ERROR: could not stop migrated service(s) after $reason" >&2
    failed=1
  fi
  for service in $services; do
    active_state=$(systemctl --user is-active "$service" 2>/dev/null)
    if [ "$active_state" != inactive ]; then
      echo "  ERROR: migrated service $service is not proven inactive after $reason" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

# Reconcile role ownership under the same lock U5 uses for record-scoped cron
# cutovers. This is deliberately a five-job gate, not a scheduler framework.
reconcile_role_timers() {
  local role=$1 base_enable=$2 lock_dir snapshot_before snapshot_after
  local error_before error_after scan_before scan_after digest_before digest_after
  local timer state admitted="" enable_set all_role_units failed=0

  case "$role" in
    workstation|satellite) ;;
    *) echo "  ERROR: refusing timer reconciliation for unknown role $role" >&2; return 1 ;;
  esac

  lock_dir=$(dirname "$CUTOVER_LOCK")
  mkdir -p "$lock_dir" || {
    echo "  ERROR: cannot create scheduler cutover lock directory" >&2
    return 1
  }
  exec 8>"$CUTOVER_LOCK" || {
    echo "  ERROR: cannot open scheduler cutover lock" >&2
    return 1
  }
  if ! flock -n 8; then
    echo "  ERROR: scheduler cutover lock is held; no timer state changed" >&2
    exec 8>&-
    return 1
  fi

  if [ "$role" = satellite ]; then
    # Satellites cannot admit these five jobs. Prove their replacements are
    # quiescent without claiming anything about cron availability or contents.
    # Requiring a cron read here blocks unrelated self-maintenance on hosts
    # without crontab(1), even though no ownership handoff can occur (#1724).
    if ! quiesce_critical_silence_replacements "$CRITICAL_SILENCE_TIMERS" "not in the satellite role set"; then
      exec 8>&-
      return 1
    fi
  else
    snapshot_before=$(mktemp "${TMPDIR:-/tmp}/critical-silence-cron-before.XXXXXX") || failed=1
    snapshot_after=$(mktemp "${TMPDIR:-/tmp}/critical-silence-cron-after.XXXXXX") || failed=1
    error_before=$(mktemp "${TMPDIR:-/tmp}/critical-silence-cron-error-before.XXXXXX") || failed=1
    error_after=$(mktemp "${TMPDIR:-/tmp}/critical-silence-cron-error-after.XXXXXX") || failed=1
    scan_before=$(mktemp "${TMPDIR:-/tmp}/critical-silence-scan-before.XXXXXX") || failed=1
    scan_after=$(mktemp "${TMPDIR:-/tmp}/critical-silence-scan-after.XXXXXX") || failed=1
    if [ "$failed" -ne 0 ]; then
      echo "  ERROR: could not allocate protected scheduler snapshots" >&2
      rm -f -- "${snapshot_before:-}" "${snapshot_after:-}" "${error_before:-}" \
        "${error_after:-}" "${scan_before:-}" "${scan_after:-}"
      exec 8>&-
      return 1
    fi
    chmod 600 "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
      "$scan_before" "$scan_after" || failed=1

    if [ "$failed" -ne 0 ] \
       || [ ! -r "$CRON_OWNERSHIP_HELPER" ] \
       || ! read_active_crontab "$snapshot_before" "$error_before" \
       || ! /usr/bin/python3 "$CRON_OWNERSHIP_HELPER" scan --home "$HOME" \
            "$snapshot_before" >"$scan_before" 2>/dev/null; then
      echo "  ERROR: active crontab could not be read and classified; migrated timers fail closed" >&2
      quiesce_critical_silence_replacements "$CRITICAL_SILENCE_TIMERS" "unreadable or unparseable crontab" || true
      rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
        "$scan_before" "$scan_after"
      exec 8>&-
      return 1
    fi
    digest_before=$(sha256sum "$snapshot_before" | awk '{print $1}') || {
      echo "  ERROR: active crontab digest failed" >&2
      quiesce_critical_silence_replacements "$CRITICAL_SILENCE_TIMERS" "crontab digest failure" || true
      rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
        "$scan_before" "$scan_after"
      exec 8>&-
      return 1
    }

    for timer in $CRITICAL_SILENCE_TIMERS; do
      state=$(awk -F '\t' -v timer="$timer" '$1 == timer {print $2}' "$scan_before")
      case "$state" in
        absent)
          admitted="$admitted $timer"
          ;;
        active|ambiguous)
          quiesce_critical_silence_replacements "$timer" "$state legacy cron ownership" || failed=1
          ;;
        *)
          echo "  ERROR: ownership scan omitted $timer; migrated timers fail closed" >&2
          failed=1
          ;;
      esac
    done
    if [ "$failed" -ne 0 ]; then
      quiesce_critical_silence_replacements "$CRITICAL_SILENCE_TIMERS" "ownership classification failure" || true
      rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
        "$scan_before" "$scan_after"
      exec 8>&-
      return 1
    fi
  fi

  enable_set="$base_enable$admitted"
  all_role_units="dcg-auto-update.timer tools-auto-update.timer $CRITICAL_SILENCE_TIMERS"
  # backup-harness.timer is opt-in on a workstation, so install leaves its state alone there.
  # A satellite still turns it off: a second machine pushing the shared backup branch
  # duplicates or clobbers the workstation's copy.
  case $role in satellite) all_role_units="backup-harness.timer $all_role_units" ;; esac
  for timer in $all_role_units; do
    case " $enable_set " in *" $timer "*) continue ;; esac
    case " $UNITS " in *" $timer "*) ;; *) continue ;; esac
    # Migrated timers were handled above with checked safety disables.
    case " $CRITICAL_SILENCE_TIMERS " in *" $timer "*) continue ;; esac
    if systemctl --user is-enabled "$timer" >/dev/null 2>&1; then
      echo "  disabling $timer (not in the $role role set)"
      systemctl --user disable --now "$timer" >/dev/null 2>&1 || true
    fi
  done

  # shellcheck disable=SC2086
  if [ -n "$enable_set" ] && ! systemctl --user enable --now $enable_set 2>/dev/null; then
    echo "  ERROR: systemctl enable --now failed; migrated replacements are being disabled" >&2
    quiesce_critical_silence_replacements "$admitted" "failed replacement activation" || true
    if [ "$role" = workstation ]; then
      rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
        "$scan_before" "$scan_after"
    fi
    exec 8>&-
    return 1
  fi

  if [ "$role" = workstation ]; then
    if ! read_active_crontab "$snapshot_after" "$error_after" \
       || ! /usr/bin/python3 "$CRON_OWNERSHIP_HELPER" scan --home "$HOME" \
            "$snapshot_after" >"$scan_after" 2>/dev/null; then
      echo "  ERROR: post-enable crontab verification failed" >&2
      quiesce_critical_silence_replacements "$admitted" "post-enable crontab read failure" || true
      rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
        "$scan_before" "$scan_after"
      exec 8>&-
      return 1
    fi
    digest_after=$(sha256sum "$snapshot_after" | awk '{print $1}') || digest_after=unavailable
    if [ "$digest_before" != "$digest_after" ]; then
      echo "  ERROR: crontab drifted during timer reconciliation" >&2
      quiesce_critical_silence_replacements "$admitted" "concurrent crontab drift" || true
      rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
        "$scan_before" "$scan_after"
      exec 8>&-
      return 1
    fi
    for timer in $admitted; do
      state=$(awk -F '\t' -v timer="$timer" '$1 == timer {print $2}' "$scan_after")
      if [ "$state" != absent ]; then
        echo "  ERROR: legacy ownership reappeared for $timer" >&2
        quiesce_critical_silence_replacements "$timer" "legacy owner appeared after activation" || true
        failed=1
      fi
    done

    rm -f -- "$snapshot_before" "$snapshot_after" "$error_before" "$error_after" \
      "$scan_before" "$scan_after"
  fi
  exec 8>&-
  [ "$failed" -eq 0 ] || return 1
  echo "  timers enabled ($role): $(echo "$enable_set" | wc -w)"
  return 0
}

# Apply <overlay>/hygiene-posture (lib/hygiene-posture.sh) as drop-ins under the user unit
# directory. Sets HYGIENE_POSTURE_ROWS and HYGIENE_POSTURE_DECLARED for the enable step.
# An invalid file returns 1 having touched no drop-in; an overlay path that is not
# absolute returns 0 having touched none and declared nothing. Only ever writes or removes files
# named $HYGIENE_POSTURE_DROPIN: a hand-written override.conf is the operator's.
# role refresh sets HYGIENE_POSTURE_PENDING to its pending-reload marker. A posture
# drop-in is a unit file too: the marker goes down before the first rewrite or removal,
# so a refresh killed in between still reloads on the next run.
hygiene_posture_mark_pending() {
  [ -n "${HYGIENE_POSTURE_PENDING:-}" ] || return 0
  [ ! -f "$HYGIENE_POSTURE_PENDING" ] || return 0
  if mkdir -p "$(dirname "$HYGIENE_POSTURE_PENDING")" && touch "$HYGIENE_POSTURE_PENDING"; then
    return 0
  fi
  echo "  failed to record pending user-unit reload; leaving $1 alone" >&2
  return 1
}

apply_hygiene_posture() {
  local file rows stem kind dir dest want
  HYGIENE_POSTURE_DECLARED=""
  HYGIENE_POSTURE_CHANGED=0
  if ! declare -F hygiene_posture_load >/dev/null; then
    echo "  ERROR: lib/hygiene-posture.sh is not loaded; no hygiene posture applied" >&2
    return 1
  fi
  # As in ./setup, a relative overlay path is reported and read by nothing. The posture is
  # then unknown, not empty: the drop-ins stay as they are and no hygiene timer is enabled.
  if ! file=$(hygiene_posture_file 2>/dev/null); then
    echo "  WARN the overlay path is not absolute (HOV_STACK_OVERLAY or HOME); hygiene posture not read, its drop-ins left as they are" >&2
    return 0
  fi
  if ! rows=$(hygiene_posture_load); then
    echo "  ERROR: $file is invalid; no hygiene posture applied (fix the file and re-run ./setup --enable-units)" >&2
    return 1
  fi
  HYGIENE_POSTURE_ROWS=$rows
  HYGIENE_POSTURE_DECLARED=$(hygiene_posture_declared | tr '\n' ' ')
  HYGIENE_POSTURE_DECLARED=${HYGIENE_POSTURE_DECLARED% }
  for stem in $HYGIENE_POSTURE_STEMS; do
    for kind in service timer; do
      dir=$SYS/$stem.$kind.d
      dest=$dir/$HYGIENE_POSTURE_DROPIN
      if [ "${1:-}" = refresh ]; then
        [ -f "$dest" ] || [ -L "$dest" ] || continue
        case "$(readlink -f "$dest")" in
          "$(readlink -f "$SYS")"/*) ;;
          *) echo "  refusing posture drop-in outside user unit directory: $dest" >&2; return 1 ;;
        esac
      fi
      want=$(hygiene_posture_render "$stem" "$kind")
      if [ -n "$want" ]; then
        if [ -f "$dest" ] && [ "$(cat -- "$dest")" = "$want" ]; then
          continue
        fi
        # mv onto a directory would move the drop-in inside it and report success.
        if [ -d "$dest" ]; then
          echo "  ERROR: $dest is a directory; hygiene posture drop-in not written" >&2
          return 1
        fi
        hygiene_posture_mark_pending "$dest" || return 1
        if ! mkdir -p "$dir" \
           || ! printf '%s\n' "$want" >"$dest.tmp.$$" \
           || ! mv -f "$dest.tmp.$$" "$dest"; then
          rm -f "$dest.tmp.$$"
          echo "  ERROR: could not write hygiene posture drop-in $dest" >&2
          return 1
        fi
        HYGIENE_POSTURE_CHANGED=$((HYGIENE_POSTURE_CHANGED + 1))
        echo "  hygiene posture: wrote $dest"
      elif [ -e "$dest" ] || [ -L "$dest" ]; then
        hygiene_posture_mark_pending "$dest" || return 1
        if ! rm -f -- "$dest"; then
          echo "  ERROR: could not remove stale hygiene posture drop-in $dest" >&2
          return 1
        fi
        rmdir "$dir" 2>/dev/null || true
        HYGIENE_POSTURE_CHANGED=$((HYGIENE_POSTURE_CHANGED + 1))
        echo "  hygiene posture: removed $dest (no longer declared)"
      fi
    done
  done
}

install_volatile_seed() {
  for f in $VOLATILE_FILES; do
    # Never clobber a live config — the live copy is authoritative once it exists.
    [ -f "$H/$f" ] || { [ -f "$HERE/$f" ] && cp "$HERE/$f" "$H/$f" && echo "  seeded $f"; }
  done
}

install_statusline() {
  # The statusline directory also holds runtime-owned stack.sh/original-statusline.json,
  # so adopting the whole directory would destroy that state. Version and link only
  # the renderer, backup-first, exactly like the individual CLI links below.
  if [ -f "$STATUSLINE_REF" ]; then
    mkdir -p "$STATUSLINE_DIR"
    if [ -e "$STATUSLINE_RENDERER" ] && [ ! -L "$STATUSLINE_RENDERER" ] \
       && ! cmp -s "$STATUSLINE_RENDERER" "$STATUSLINE_REF"; then
      _bak="$STATUSLINE_RENDERER.pre-sync.$(date +%Y%m%d-%H%M%S).bak"
      cp -p "$STATUSLINE_RENDERER" "$_bak" && echo "  backed up divergent local-statusline.mjs -> $_bak"
    fi
    if ln -sfn "$STATUSLINE_REF" "$STATUSLINE_RENDERER.tmp.$$" \
       && mv -Tf "$STATUSLINE_RENDERER.tmp.$$" "$STATUSLINE_RENDERER"; then
      echo "  linked statusline-stack/local-statusline.mjs"
    else
      rm -f "$STATUSLINE_RENDERER.tmp.$$"
      echo "  WARN failed to link statusline-stack/local-statusline.mjs"
      return 1
    fi
  fi
}

install_hooks() {
  # apply_settings below adds and removes the tracked hooks. These reconcilers
  # do what it cannot (hov-stack #479): respell a live `node "..."` hook onto
  # the launcher (the apply keys the two spellings as different hooks and would
  # register the script twice), retire a live hook that no base ever recorded
  # (the apply removes only what its base names), and retire the papercut
  # settings copies only once the plugin owns them (the apply has no
  # conditional removal). dcg keeps its own verb because the apply folds every
  # dcg path into one identity, so only reconcile_dcg_hook moves live onto this
  # host's resolved binary. CI sets the foreign-host skip explicitly; it is
  # never auto-detected.
  if [ "${CLAUDE_SYNC_SKIP_HOOK_RECONCILE:-0}" = 1 ]; then
    echo "  skipped hook reconcile (CLAUDE_SYNC_SKIP_HOOK_RECONCILE=1)"
  else
    # ./setup sets CLAUDE_SYNC_SKIP_DCG_RECONCILE=1 when there is no dcg at
    # ~/.local/bin/dcg (--no-dcg, or a dcg elsewhere on PATH): reconcile_dcg_hook
    # refuses to register a missing target, and setup accepts a run without one.
    if [ "${CLAUDE_SYNC_SKIP_DCG_RECONCILE:-0}" = 1 ]; then
      echo "  skipped dcg hook reconcile (no dcg at ~/.local/bin/dcg)"
    else
      reconcile_dcg_hook || return 1
    fi
    # Not `|| return 1`: a failed plugin install (offline, marketplace not added)
    # still allows links, units and timers to install. Report failure at the end.
    ensure_papercut_plugin || papercut_failed=1
  fi
}

install_repo_routes() {
  # Link only the portable policy. Never seed or copy the host-local authority
  # state, because that would manufacture a canonical checkout on another host.
  if [ -f "$HERE/config/repo-routes.json" ]; then
    mkdir -p "$H/config"
    ln -sfn "$HERE/config/repo-routes.json" "$H/config/repo-routes.json" && echo "  linked config/repo-routes.json"
  fi
}

install_retire_loop_quality() {
  # Preserve the retired controller's regular config beside its former path.
  _qp="$H/config/loop-quality.json"
  if [ -f "$_qp" ] && [ ! -L "$_qp" ]; then
    _qbak="$_qp.pre-sync.$(date +%Y%m%d-%H%M%S).$$.bak"
    mv -Tn "$_qp" "$_qbak" && [ ! -e "$_qp" ] || return 1
    echo "  retired config/loop-quality.json (loop_quality removed, #1914) -> $_qbak"
  fi
}

install_runtime_policy() {
  # Unlike hook commands, these settings are portable and their CLAUDE_ENV_FILE
  # target is linked through STABLE_FILES by ./setup. Reconcile them even when
  # a foreign-host smoke test explicitly skips absolute hook registrations.
  reconcile_runtime_env || return 1
  reconcile_windows_auto_mode || return 1
}

install_watchdog_link() {
  # The 5-minute memory watchdog is invoked by crontab as ~/.local/bin/wsl-watchdog.sh
  # and lived ONLY there, unversioned, until 2026-08-06 — the most active piece of
  # self-healing automation on the box with no history and no backup. Symlinking that
  # path at the repo copy keeps the crontab entry working untouched while making the
  # script reviewable. Back up a divergent real file first: overwriting the live copy
  # of a job that runs every 5 minutes is not something to do blind.
  if [ -d "$HOME/.local/bin" ]; then
    _wd="$HOME/.local/bin/wsl-watchdog.sh"
    if [ -e "$_wd" ] && [ ! -L "$_wd" ] && ! cmp -s "$_wd" "$HERE/bin/wsl-watchdog.sh"; then
      # Timestamped, matching reconcile_hook_group's convention above: a fixed
      # .bak name lets a second divergence-then-install cycle silently overwrite
      # the only copy of the first divergent version.
      _bak="$_wd.pre-sync.$(date +%Y%m%d-%H%M%S).bak"
      cp -p "$_wd" "$_bak" && echo "  backed up divergent wsl-watchdog.sh -> $_bak"
    fi
    # Swap atomically: `ln -sf` unlinks then re-creates, leaving a window where
    # the path does not exist, and a cron fires this script every 5 minutes.
    # symlink-to-temp + `mv -T` is a single rename(2), so the path is never absent.
    if ln -sfn "$HERE/bin/wsl-watchdog.sh" "$_wd.tmp.$$" && mv -Tf "$_wd.tmp.$$" "$_wd"; then
      echo "  linked bin/wsl-watchdog.sh"
    else
      rm -f "$_wd.tmp.$$"; echo "  WARN failed to link bin/wsl-watchdog.sh"
    fi
  fi
}

install_managed_lock() {
  # Deploy the root-owned managed-settings lock (the one immutable, YOLO-proof
  # deny floor). Can't symlink a root policy file, so install a copy with sudo.
  if [ -f "$MANAGED_REF" ] && ! cmp -s "$MANAGED_REF" "$MANAGED_LOCK" 2>/dev/null; then
    if sudo -n true 2>/dev/null; then
      sudo install -D -m 0644 -o root -g root "$MANAGED_REF" "$MANAGED_LOCK" &&
        echo "  installed managed-settings lock -> $MANAGED_LOCK"
    else
      echo "  managed-settings lock needs sudo — run: sudo install -D -m 0644 -o root -g root $MANAGED_REF $MANAGED_LOCK"
    fi
  fi
}

install_memory_seed() {
  for m in "$MEMORY_MIRROR_ROOT"/*/; do
    [ -d "$m" ] || continue
    proj=$(basename "$m")
    dest=$MEMORY_LIVE_ROOT/$proj/memory
    [ -d "$dest" ] || { mkdir -p "$dest"; rsync -a "$m" "$dest/"; echo "  seeded memory/$proj"; }
  done
}

install_user_units() {
  local index error
  # Copy each declared user unit into the user unit directory. The standalone
  # and root installers share this path.
  for u in $UNITS; do
    [ -f "$HERE/systemd/$u" ] || continue
    mkdir -p "$(dirname "$SYS/$u")" || {
      echo "  failed to create user-unit destination for $u" >&2
      return 1
    }
    install_user_unit "$u" || return 1
  done
  for error in "${OVERLAY_UNIT_ERRORS[@]}"; do echo "  $error" >&2; done
  for index in "${!OVERLAY_UNIT_PATHS[@]}"; do
    u=${OVERLAY_UNIT_PATHS[$index]}
    mkdir -p "$(dirname "$SYS/$u")" || return 1
    install_user_unit "$u" "${OVERLAY_UNIT_SOURCES[$index]}" || return 1
  done
}

install_user_unit() {
  local unit=$1 source=${2:-$HERE/systemd/$1}
  if ! cp "$source" "$SYS/$unit" || ! cmp -s "$source" "$SYS/$unit"; then
    echo "  failed to deploy user unit $unit; refusing to report harness install success" >&2
    return 1
  fi
}

install_hygiene_posture() {
  # Host-declared hygiene posture (lib/hygiene-posture.sh). An invalid file is reported
  # and fails the enable phase at the end, after everything unrelated has been updated.
  if apply_hygiene_posture; then posture_ok=1; else posture_failed=1; fi
}

install_system_units() {
  # System-level units (root-owned, privileged setup — see SYSTEM_UNITS above).
  # Same deploy pattern as the managed lock: sudo install, graceful no-sudo
  # fallback that prints the manual command. Deliberately NOT enabled/started
  # here, unlike the --user timers below — this is new, load-bearing memory-tier
  # infrastructure on a box already under pressure, and its activation belongs
  # to the operator (see the introducing PR's OPERATOR ACTIVATION CHECKLIST).
  # Workstation only: they size and trim the workstation's own WSL box. With no
  # role check, a satellite with passwordless sudo got all four in /etc on its
  # first install (xps-omarchy, 2026-11-14).
  if profile_is workstation; then
    for u in $SYSTEM_UNITS; do
      [ -f "$HERE/systemd-system/$u" ] || continue
      rendered=$(mktemp) || exit 3
      render_system_unit "$HERE/systemd-system/$u" "$rendered"
      if cmp -s "$rendered" "$SYSTEM_SYS/$u" 2>/dev/null; then
        rm -f "$rendered"
        continue
      fi
      if sudo -n true 2>/dev/null; then
        sudo install -D -m 0644 -o root -g root "$rendered" "$SYSTEM_SYS/$u" &&
          echo "  installed system unit $u -> $SYSTEM_SYS/$u (NOT enabled — see operator activation checklist)"
        rm -f "$rendered"
      else
        echo "  system unit $u needs sudo — run: sudo install -D -m 0644 -o root -g root $rendered $SYSTEM_SYS/$u (systemd-system/$u rendered for this account)"
      fi
    done
  else
    echo "  system units skipped (host role $(profile_role 2>/dev/null || echo undeclared); they are workstation-only)"
  fi
}

install_daemon_reload() {
  if systemctl --user show-environment >/dev/null 2>&1; then
    if ! systemctl --user daemon-reload; then
      echo "  systemd user manager is reachable but daemon-reload failed; refusing install success" >&2
      return 1
    fi
  else
    echo "  WARN systemd user manager unavailable; units copied but daemon-reload deferred" >&2
  fi
  # Adding a unit to the selected inventory is only HALF the wiring — it gets copied and
  # drift-checked, but stays inert unless its .timer is also named here. Keep the two
  # lists in step; a unit installed and never enabled is the silent-failure shape this
  # whole dcg-auto-update change exists to remove.
  #
}

install_role_selection() {
  # DELIBERATE EXCEPTION — the four hygiene timers (wt-sweep, pkg-cache-prune,
  # docker-hygiene, reclaim-sweep) are NOT in this list, on purpose, even though
  # they ship in an observe-only/plan-only stage. Every `./setup --enable-units`
  # run (e.g. to pick up an unrelated settings.json change) must not be the thing
  # that silently starts a new deletion-capable timer on an operator's box before
  # they've read the PR that introduced it. Enable them by hand per the OPERATOR
  # ACTIVATION CHECKLIST in dotfiles PR "wsl-hygiene-timers" — this is a loud,
  # documented omission, not the silent-gap failure mode described above.
  # The one way install enables them is the host's own declaration: a stem named in
  # <overlay>/hygiene-posture (lib/hygiene-posture.sh) is enabled after the role
  # reconcile below, with the posture it declares written as drop-ins. No file, no
  # change: a host that never declared a posture keeps every hygiene timer as it is.
  #
  # OPT-IN — backup-harness.timer is not in the workstation set either. It pushes
  # live memory to a branch of the checkout's origin, and scripts/backup-harness.sh
  # refuses to push to a public repository, so on a clone of this public repo an
  # enabled timer fails every night. Enable it by hand once origin is private or
  # DOTFILES points at a private checkout (systemd/README.md); install then leaves
  # it enabled on a workstation and still disables it on a satellite.
  #
  # ROLE-KEYED, replacing a hardcoded literal that was itself a workstation
  # profile written by hand. hosts.tsv is the declaration; lib/profile.sh reads it.
  #
  # A satellite gets self-maintenance ONLY. Everything withheld is withheld for a
  # reason, not for tidiness:
  #
  #   backup-harness      writes a SHARED REMOTE branch. Two machines pushing it
  #                       is a real conflict.
  # It keeps dcg-auto-update (the guard must stay current everywhere) and
  # tools-auto-update, which the presence gate after this case adds for either
  # role only where one of its tools is installed.
  case "$(profile_role 2>/dev/null || echo unknown)" in
    workstation)
      _role=workstation
      _enable="dcg-auto-update.timer" ;;
    satellite)
      _role=satellite
      _enable="dcg-auto-update.timer" ;;
    *)
      # FATAL, not a warning. An unrecognised or missing role previously enabled
      # nothing while check() still reported the host as mapped, so a typo on a
      # rebuilt machine produced a green check and zero scheduled work -- the
      # failure looked like success. profile_assert_known existed for exactly
      # this and had no callers.
      echo "  ERROR: no usable role for $(hostname -s 2>/dev/null || hostname) in hosts.tsv." >&2
      echo "         Refusing to guess: satellite would silently disable a workstation," >&2
      echo "         workstation would let a second machine publish canonical state." >&2
      profile_assert_known >/dev/null || true
      return 1 ;;
  esac

}

install_tools_gate() {
  # tools-auto-update joins the set only where tool-update.sh would find one of
  # its tools (hov-stack#632). Nothing here installs xf, csctf or ru, and its
  # all-missing guard fails a run that finds none, so on a host that never
  # installed them the timer could only fail and page, every night. Left out of
  # the set, the reconcile below disables it like any timer outside the role
  # set; the first install after a tool appears enables it again.
  if bash "$HERE/scripts/tool-update.sh" --any-installed >/dev/null 2>&1; then
    _enable="$_enable tools-auto-update.timer"
  else
    echo "  tools-auto-update.timer: none of tool-update.sh's tools is installed here, so it stays off; install one, then re-run ./setup --enable-units"
  fi

}

install_role_timers() {
  local index overlay_failed=0
  local overlay_timers=()
  reconcile_role_timers "$_role" "$_enable" || return 1
  for index in "${!OVERLAY_UNIT_PATHS[@]}"; do
    [ "${OVERLAY_UNIT_FLAGS[$index]}" = on ] || continue
    overlay_timers+=("${OVERLAY_UNIT_PATHS[$index]}")
  done
  if [ "${#overlay_timers[@]}" -gt 0 ]; then
    if systemctl --user show-environment >/dev/null 2>&1; then
      # A failure is reported and held until the posture timers below have run.
      if systemctl --user enable --now "${overlay_timers[@]}"; then
        echo "  overlay timers enabled: ${overlay_timers[*]}"
      else
        echo "  ERROR: could not enable overlay timers: ${overlay_timers[*]}" >&2
        overlay_failed=1
      fi
    else
      echo "  WARN systemd user manager unavailable; overlay timers not enabled: ${overlay_timers[*]}" >&2
    fi
  fi
  if [ "$posture_ok" = 1 ] && [ -n "$HYGIENE_POSTURE_DECLARED" ]; then
    if systemctl --user show-environment >/dev/null 2>&1; then
      _posture_timers=""
      for _stem in $HYGIENE_POSTURE_DECLARED; do _posture_timers="$_posture_timers $_stem.timer"; done
      # shellcheck disable=SC2086 # one word per timer is the point
      if systemctl --user enable --now $_posture_timers; then
        echo "  hygiene timers enabled from overlay posture: $HYGIENE_POSTURE_DECLARED"
      else
        echo "  ERROR: could not enable the hygiene timers the overlay posture declares: $HYGIENE_POSTURE_DECLARED" >&2
        posture_failed=1
      fi
    else
      echo "  WARN systemd user manager unavailable; hygiene timers declared in the overlay posture not enabled: $HYGIENE_POSTURE_DECLARED" >&2
    fi
  fi
  [ "$overlay_failed" = 0 ] || return 1
}

role_unit_file() {
  local phase=$1 unit=$2 source=$3
  if [ ! -f "$SYS/$unit" ]; then
    new=$((new + 1))
    echo "  new unit: $unit (not installed)"
  elif ! cmp -s "$source" "$SYS/$unit"; then
    if [ "$phase" = refresh ]; then
      case "$(readlink -f "$SYS/$unit")" in
        "$(readlink -f "$SYS")"/*) ;;
        *) echo "  refusing unit outside user unit directory: $unit" >&2; refused=$((refused + 1)); return 0 ;;
      esac
      if [ -z "$refresh_backup" ]; then
        if ! mkdir -p "$H/backups" || ! refresh_backup=$(mktemp -d "$H/backups/unit-refresh-$(date +%Y%m%d-%H%M%S)-XXXXXX"); then
          echo "  failed to create unit refresh backup for $unit" >&2
          failed=$((failed + 1))
          return 0
        fi
        echo "  unit refresh backup: $refresh_backup"
      fi
      # -L: a unit that is a symlink inside the unit directory is overwritten
      # through the link, so the backup keeps the bytes behind it, not the link.
      if ! (cd "$refresh_backup" && mkdir -p "./$(dirname "$unit")" && cp -pL -- "$SYS/$unit" "./$unit"); then
        echo "  failed to back up user unit $unit; leaving it alone" >&2
        failed=$((failed + 1))
        return 0
      fi
      [ ! -L "$SYS/$unit" ] || echo "  $unit was a symlink to $(readlink -f "$SYS/$unit"); the backup holds its contents"
      # The marker goes down before the first write, so a refresh killed between
      # a write and the reload still reloads on the next run.
      if [ "$marked" -eq 0 ]; then
        if ! mkdir -p "$(dirname "$pending")" || ! touch "$pending"; then
          echo "  failed to record pending user-unit reload; leaving $unit alone" >&2
          failed=$((failed + 1))
          return 0
        fi
        marked=1
      fi
      if ! install_user_unit "$unit" "$source"; then
        failed=$((failed + 1))
        return 0
      fi
      echo "  updated unit: $unit"
    else
      echo "  unit differs: $unit"
    fi
    changed=$((changed + 1))
  fi
}

overlay_unit_timers_check() {
  local index unit reachable='' result=0
  for index in "${!OVERLAY_UNIT_PATHS[@]}"; do
    [ "${OVERLAY_UNIT_FLAGS[$index]}" = on ] || continue
    if [ -z "$reachable" ]; then
      if ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "SKIP: no reachable systemd --user manager; overlay timer enable-state check not applicable"
        return 0
      fi
      reachable=1
    fi
    unit=${OVERLAY_UNIT_PATHS[$index]}
    if ! systemctl --user is-enabled "$unit" >/dev/null 2>&1; then
      echo "${1}overlay timer $unit is not enabled (./setup --enable-units)"
      result=1
    fi
  done
  return "$result"
}

role_unit_files() {
  local phase=$1 unit index error changed=0 new=0 refused=0 failed=0 reload_failed=0 refresh_backup="" marked=0
  local pending="$H/.hov-stack/units-reload-pending"
  for unit in $UNITS; do
    [ -f "$HERE/systemd/$unit" ] || continue
    role_unit_file "$phase" "$unit" "$HERE/systemd/$unit"
  done
  for error in "${OVERLAY_UNIT_ERRORS[@]}"; do
    echo "  $error"
    refused=$((refused + 1))
  done
  for index in "${!OVERLAY_UNIT_PATHS[@]}"; do
    role_unit_file "$phase" "${OVERLAY_UNIT_PATHS[$index]}" "${OVERLAY_UNIT_SOURCES[$index]}"
  done
  if [ "$phase" = check ]; then overlay_unit_timers_check '  ' || failed=$((failed + 1)); fi
  if [ "$phase" = refresh ]; then
    HYGIENE_POSTURE_PENDING=$pending
    apply_hygiene_posture refresh || failed=$((failed + 1))
    HYGIENE_POSTURE_PENDING=
    changed=$((changed + HYGIENE_POSTURE_CHANGED))
  fi
  if [ "$changed" -gt 0 ]; then
    if [ "$phase" = refresh ]; then
      role_summary="$changed unit file(s) updated"
    else
      role_summary="$changed unit file(s) differ"
      if [ "${#OVERLAY_UNIT_PATHS[@]}" -gt 0 ]; then role_summary="$role_summary: ./setup"; fi
    fi
  fi
  if [ "$phase" = refresh ]; then
    if [ "$refused" -gt 0 ] || [ "$failed" -gt 0 ]; then
      role_summary="$changed unit file(s) updated; $refused refused; $failed failed"
    fi
    if [ -f "$pending" ]; then
      if systemctl --user show-environment >/dev/null 2>&1; then
        if systemctl --user daemon-reload; then
          rm -f -- "$pending" || reload_failed=1
        else
          echo "  systemd user manager is reachable but daemon-reload failed" >&2
          reload_failed=1
        fi
      else
        echo "  WARN systemd user manager unavailable; units copied but daemon-reload deferred" >&2
      fi
    fi
  fi
  if [ -f "$pending" ]; then
    echo "  user unit reload pending: re-run ./setup when the user manager is available"
    role_summary="${role_summary:+$role_summary; }user unit reload pending"
  fi
  [ "$new" -eq 0 ] || role_summary="${role_summary:+$role_summary; }$new new unit(s): ./setup --enable-units"
  if [ -f "$MANAGED_REF" ] && ! cmp -s "$MANAGED_REF" "$MANAGED_LOCK"; then
    echo "  managed lock differs: ./setup --root"
    role_summary="${role_summary:+$role_summary; }managed lock differs: ./setup --root"
  fi
  changed=0
  if profile_is workstation; then
    for unit in $SYSTEM_UNITS; do
      [ -f "$HERE/systemd-system/$unit" ] || continue
      if ! cmp -s <(render_system_unit "$HERE/systemd-system/$unit" /dev/stdout) "$SYSTEM_SYS/$unit"; then
        echo "  system unit differs: $unit"
        changed=$((changed + 1))
      fi
    done
  fi
  [ "$changed" -eq 0 ] || role_summary="${role_summary:+$role_summary; }$changed system unit(s) differ: ./setup --root"
  [ "$refused" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$reload_failed" -eq 0 ]
}

role_steps() {
  case "$1" in
    refresh|check) role_unit_files "$1" || return 1 ;;
    owner)
      validate_canonical_compact_window || return 1
      install_volatile_seed
      install_statusline || return 1
      install_hooks || return 1
      install_repo_routes
      install_retire_loop_quality || return 1
      install_runtime_policy || return 1
      install_watchdog_link || return 1
      install_memory_seed
      role_summary="owner steps complete"
      if [ "$papercut_failed" = 1 ]; then
        echo "  FAILED to install $PAPERCUT_PLUGIN_ID: $PAPERCUT_INSTALL_ERROR" >&2
        role_summary="owner steps complete; papercut install failed: $PAPERCUT_INSTALL_ERROR"
        return 3
      fi
      ;;
    enable)
      install_user_units || return 1
      install_hygiene_posture
      install_daemon_reload || return 1
      install_role_selection || return 1
      install_tools_gate
      install_role_timers || return 1
      [ "$posture_failed" = 0 ] || return 1
      role_summary="role timers reconciled"
      ;;
    root)
      docker_init_policy reconcile || return 1
      install_managed_lock
      install_system_units
      role_summary="root steps complete (see any sudo instructions above)"
      ;;
  esac
  return 0
}

role_phase() {
  local role_summary="" papercut_failed=0 posture_failed=0 posture_ok=0 rc=0
  case "${1:-}" in
    refresh|owner|enable|root|check) [ "$#" -eq 1 ] || rc=2 ;;
    *) rc=2 ;;
  esac
  if [ "$rc" = 2 ]; then
    echo "usage: sync.sh role <refresh|owner|enable|root|check>" >&2
    return 2
  fi
  if ! profile_is workstation && ! profile_is satellite; then
    echo "role: no role for this host; add its row to hosts.tsv" >&2
    return 1
  fi
  role_steps "$1" || rc=$?
  if [ "$rc" = 1 ]; then role_summary="${role_summary:+$role_summary; }$1 failed (see above)"; fi
  echo "role: ${role_summary:-nothing to change}"
  return "$rc"
}

# live_tree_is_here: true when the live ~/.claude runs from this tree, i.e. one of its
# stable directories is a symlink into it (the comparison check's link loop makes).
live_tree_is_here() {
  local d
  for d in $STABLE_DIRS; do
    [ -L "$H/$d" ] && [ "$(readlink -f "$H/$d")" = "$(readlink -f "$HERE/$d")" ] && return 0
  done
  return 1
}

guard_permission_drop_for_push() {
  [ "${SYNC_ALLOW_PERMISSION_DROP:-}" != 1 ] || return 0
  local list missing count first noun
  for list in allow deny; do
    missing=$(jq -rn --arg cfg "$H" --arg home "$HOME" --arg list "$list" --slurpfile tracked "$HERE/settings.json" --slurpfile live "$H/settings.json" "$SETTINGS_NORMAL_JQ"'
      ($live[0].permissions[$list] // [] | map(render_home($cfg; $home))) as $live
      | ($tracked[0].permissions[$list] // [])[] | render_home($cfg; $home) | select(. as $entry | $live | index($entry) | not)') || return 1
    if [ -n "$missing" ]; then
      count=$(printf '%s\n' "$missing" | wc -l)
      first=$(printf '%s\n' "$missing" | head -1)
      noun=entries; [ "$count" != 1 ] || noun=entry
      echo "push refused: live settings at $H/settings.json lack $count tracked permissions.$list $noun, e.g. $first; run sync.sh apply-settings first, or set SYNC_ALLOW_PERMISSION_DROP=1 if live dropped them on purpose" >&2
      return 1
    fi
  done
}

build_settings_desired() (
  local src=$1 out=$2 tmp ov='' dir env_file plugin_dirs proxy_url=''
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  if dir=$(overlay_dir) && [ -f "$dir/settings.json" ]; then ov=$dir/settings.json; fi
  SETTINGS_SEED_ALL_KEYS=1 node "$HERE/lib/settings-seed.js" "$src" "$tmp/seed.json" "$H" "$HOME" "$DCG_COMMAND" "$ov" >/dev/null || return 1
  env_file=$(target_in_harness_home "$(jq -r '.env.CLAUDE_ENV_FILE // empty' "$src")")
  plugin_dirs=$(plugin_dirs_with_overlay "$(mapped_plugin_dirs_of "$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$src")")")
  case "$(profile_role 2>/dev/null)" in
    workstation) proxy_url=$CCFLARE_URL_WORKSTATION ;;
    satellite) proxy_url=$CCFLARE_URL_SATELLITE ;;
  esac
  node -e 'const fs=require("fs"); const {stripOwned}=require(process.argv[1]); fs.writeFileSync(process.argv[3],JSON.stringify(stripOwned(JSON.parse(fs.readFileSync(process.argv[2])))))' "$HERE/lib/settings-apply.js" "$tmp/seed.json" "$tmp/owned.json" || return 1
  jq --arg env_file "$env_file" --arg plugin_dirs "$plugin_dirs" --arg proxy_url "$proxy_url" '
    if (.env | type) == "object" then
      (if (.env | has("CLAUDE_ENV_FILE")) and $env_file != "" then .env.CLAUDE_ENV_FILE=$env_file else . end)
      | (if (.env | has("CLAUDE_CODE_PLUGIN_DIRS")) and $plugin_dirs != "" then .env.CLAUDE_CODE_PLUGIN_DIRS=$plugin_dirs else . end)
      | (if (.env | has("ANTHROPIC_BASE_URL")) and $proxy_url != "" then .env.ANTHROPIC_BASE_URL=$proxy_url else . end)
    else . end' "$tmp/owned.json" >"$out" || return 1
)

apply_settings() (
  local plan=0 quiet=0 rev='' role tmp base rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan) plan=1 ;;
      --quiet) quiet=1 ;;
      --seed-base) [ "$#" -ge 2 ] || { echo 'missing seed revision' >&2; return 2; }; rev=$2; shift ;;
      *) echo 'usage: sync.sh apply-settings [--plan] [--quiet] [--seed-base <rev>]' >&2; return 2 ;;
    esac
    shift
  done
  role=$(profile_role 2>/dev/null) || role=undeclared
  # A host that does not apply only writes the stamp below, which needs node
  # alone; every ./setup starter file registers the SessionStart hook that
  # lands here, and ./setup asks for git and node, not jq (#651). A plan and
  # an applying host read the template with jq.
  if ! command -v node >/dev/null \
    || { ! command -v jq >/dev/null && { [ "$plan" = 1 ] || [[ "$role" == workstation || "$role" == satellite ]]; }; }; then
    echo 'settings: node and jq are required' >&2
    return 1
  fi
  if [ -n "$rev" ]; then
    git -C "$HERE" rev-parse --verify "$rev^{commit}" >/dev/null 2>&1 || { echo "invalid seed revision" >&2; return 2; }
  fi
  if [ "$plan" = 0 ]; then
    if [ -n "$rev" ] && [[ "$role" != workstation && "$role" != satellite ]]; then
      echo "settings: skipped (host role $role: --seed-base needs a workstation or satellite host)"; return 2
    fi
    mkdir -p "$H/.hov-stack" || return 1
    chmod 700 "$H/.hov-stack" || return 1
    case "$role" in workstation|satellite) ;; *)
      node -e 'const fs=require("fs"); const {inputsHash}=require(process.argv[1]+"/lib/settings-apply.js");const file=process.argv[2]+"/.hov-stack/settings-apply.stamp", tmp=file+"."+process.pid; fs.writeFileSync(tmp,inputsHash({root:process.argv[1],cfg:process.argv[2],overlayDir:process.argv[3],dcgPath:process.argv[4]})+"\n",{mode:0o600,flag:"wx"});fs.renameSync(tmp,file)' "$HERE" "$H" "$(overlay_dir)" "$DCG_COMMAND" || return 1
      echo "settings: skipped (host role $role: only workstation and satellite hosts apply automatically)"; return 0 ;;
    esac
    exec 9>"$H/.hov-stack/settings-apply.lock" || return 1
    flock -w 10 9 || { echo 'settings: skipped (another apply held the lock for 10s)'; return 0; }
  fi
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  base=$H/.hov-stack/settings-base.json
  build_settings_desired "$HERE/settings.json" "$tmp/desired.json" 2>"$tmp/error" || { head -1 "$tmp/error" >&2; return 1; }
  if [ -n "$rev" ]; then
    [ ! -e "$base" ] || { echo 'a base already exists' >&2; return 2; }
    git -C "$HERE" show "$rev:settings.json" >"$tmp/template.json" 2>/dev/null || { echo 'invalid seed revision' >&2; return 2; }
    build_settings_desired "$tmp/template.json" "$tmp/base.json" || return 1
    if [ "$plan" = 1 ]; then base=$tmp/base.json
    else (umask 077; cp "$tmp/base.json" "$base") || return 1; fi
  fi
  local -a flags=()
  local value reason missing
  value=$(jq -r '.env.CLAUDE_ENV_FILE // empty' "$tmp/desired.json")
  if jq -e '.env | has("CLAUDE_ENV_FILE")' "$tmp/desired.json" >/dev/null 2>&1 && [ ! -f "$value" ]; then
    flags+=(--skip-path "env.CLAUDE_ENV_FILE=target is not a regular file")
  fi
  # A satellite with no proxy URL, exported or in the overlay env, keeps live's
  # ANTHROPIC_BASE_URL: desired would carry the tracked loopback, which no
  # satellite serves. install refuses outright here (reconcile_runtime_env); the
  # apply skips only this key, so the rest of the settings still land.
  if [ "$role" = satellite ] && [ -z "$CCFLARE_URL_SATELLITE" ] \
     && jq -e '.env | has("ANTHROPIC_BASE_URL")' "$tmp/desired.json" >/dev/null 2>&1; then
    flags+=(--skip-path "env.ANTHROPIC_BASE_URL=this host is a satellite and CCFLARE_URL_SATELLITE is unset; set it in the overlay env")
  fi
  value=$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$tmp/desired.json")
  if jq -e '.env | has("CLAUDE_CODE_PLUGIN_DIRS")' "$tmp/desired.json" >/dev/null 2>&1; then
    reason=$(plugin_dirs_invalid_reason "$value")
    # Mapping splits on colons; validate the source too so control characters
    # or empty entries cannot disappear before the mapped-value validation.
    if [ -z "$reason" ] && jq -e '.env | has("CLAUDE_CODE_PLUGIN_DIRS")' "$HERE/settings.json" >/dev/null 2>&1; then
      reason=$(plugin_dirs_invalid_reason "$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$HERE/settings.json")")
    fi
    missing=$(plugin_dir_missing_manifest "$value")
    if [ -n "$reason" ] || [ -n "$missing" ]; then
      flags+=(--skip-path "env.CLAUDE_CODE_PLUGIN_DIRS=plugin directories invalid or missing manifest")
    fi
  fi
  [ "$plan" = 0 ] || flags+=(--plan)
  node "$HERE/lib/settings-apply.js" --desired "$tmp/desired.json" --live "$H/settings.json" --base "$base" --config-dir "$H" --home "$HOME" --backup-root "$H/backups" --stamp "$H/.hov-stack/settings-apply.stamp" --overlay-dir "$(overlay_dir)" --dcg-path "$DCG_COMMAND" "${flags[@]}" >"$tmp/output"; rc=$?
  if [ "$quiet" = 1 ]; then grep '^settings: ' "$tmp/output" || :; else cat "$tmp/output"; fi
  return "$rc"
)

check() {
  local drift=0 examined=0 canonical_env_file mapped_env_file _docker_policy_out
  guard_no_credentials || { echo "DRIFT: credential material tracked in the harness tree (see SECRET GUARD above)"; drift=1; }
  # An undeclared host is drift, not a neutral state. Until it is in hosts.tsv,
  # install enables NO timers and push has no authority to check -- the machine
  # is silently half-configured, which is the shape this repo keeps getting
  # bitten by. One line in hosts.tsv fixes it; nothing else should.
  # Only claim a host is UNMAPPED when there is a table for it to be missing
  # from. A tree with no hosts.tsv is not an undeclared machine -- it is a
  # partial checkout or a hermetic test fixture, and the manifest checks already
  # cover the former. Reporting "no role in hosts.tsv" where no hosts.tsv exists
  # is a misleading message that made two hermetic suites fail for a condition
  # neither was testing.
  if [ -r "${DOTFILES_ROLE_FILE:-$HERE/hosts.tsv}" ]; then
    if ! _role=$(profile_role 2>/dev/null); then
      echo "DRIFT: $(hostname -s 2>/dev/null || hostname) has no role in hosts.tsv (install enables no timers here)"; drift=1
    else
      case "$_role" in
        workstation|satellite) ;;
        *) echo "DRIFT: unrecognised role '$_role' — install would enable NO timers while this check passed"; drift=1 ;;
      esac
    fi
  elif live_tree_is_here; then
    # But a tree the live ~/.claude runs from is no fixture. It is a switched host
    # whose roster never came along (the public tree carries none), and every
    # role-dependent verb refuses there while the gate above stays quiet.
    echo "DRIFT: no host roster is readable (${DOTFILES_ROLE_FILE:-$HERE/hosts.tsv}); copy the fleet's hosts.tsv there — install, push and reconcile-runtime-env refuse until it exists"
    drift=1
  fi
  if docker_init_role_selected; then
    examined=$((examined + 1))
    if _docker_policy_out=$(docker_init_policy check 2>&1); then
      printf '%s\n' "$_docker_policy_out"
    else
      echo "DRIFT: Docker init policy check failed: $_docker_policy_out"
      drift=1
    fi
  fi
  for d in $STABLE_DIRS; do
    if [ -L "$H/$d" ]; then
      examined=$((examined + 1))
      [ "$(readlink -f "$H/$d")" = "$(readlink -f "$HERE/$d")" ] ||
        { echo "DRIFT: ~/.claude/$d is a symlink pointing outside the repo"; drift=1; }
    elif [ -d "$H/$d" ] && [ -d "$HERE/$d" ]; then
      examined=$((examined + 1))
      rsync -rcn --delete --out-format='%n' "$H/$d/" "$HERE/$d/" 2>/dev/null | grep -q . &&
        { echo "DRIFT: $d/ differs from repo (not adopted, or symlink clobbered — sync.sh push or install)"; drift=1; }
    fi
  done
  for f in $STABLE_FILES $VOLATILE_FILES; do
    { [ -f "$H/$f" ] && [ -f "$HERE/$f" ]; } || continue
    examined=$((examined + 1))
    if [ "$f" = "settings.json" ] && command -v jq >/dev/null 2>&1; then
      # Tripwire: the tracked canonical copy must never carry the host-local
      # better-ccflare API key. The comparison below deliberately excludes the
      # key from both sides, so without this check a leaked token would sit in
      # the repo invisibly. push() strips it; this catches every other path.
      if jq -e '((.env.ANTHROPIC_AUTH_TOKEN // "") + (.env.ANTHROPIC_CUSTOM_HEADERS // "")) | length > 0' "$HERE/$f" >/dev/null 2>&1; then
        echo "DRIFT: $f canonical copy carries a ccflare secret (env.ANTHROPIC_AUTH_TOKEN or env.ANTHROPIC_CUSTOM_HEADERS) — host-local by design; remove it and rotate the key"
        drift=1
      fi
      # statusLine/spinnerVerbs are owned by the statusline ad daemon and churn
      # constantly — compare everything except its keys; the DRIFT line names
      # each top-level key that differs. Project the canonical env-file
      # path through CLAUDE_HOME just as reconcile_runtime_env does so hermetic
      # and foreign-home installs compare against their actual live contract.
      canonical_env_file=$(jq -r '.env.CLAUDE_ENV_FILE // empty' "$HERE/$f")
      mapped_env_file=$(target_in_harness_home "$canonical_env_file")
      # CLAUDE_CODE_PLUGIN_DIRS is written through CLAUDE_HOME like the env
      # file, so the canonical spelling is projected the same way. An equal
      # string is not a loadable mod: a manifest removed after install leaves
      # live and canonical identical while every session logs a failed load,
      # so the folders are tested here as reconcile tests them before writing.
      canonical_plugin_dirs=$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$HERE/$f")
      # A malformed canonical list is validated before it is mapped: the split
      # in mapped_plugin_dirs_of drops a trailing empty field, so "a:b:" would
      # project to the same valid-looking value already live and check would
      # stay green on a list reconcile refuses to write.
      # A present empty string is as invalid as a malformed one, so the
      # validator runs whenever the key exists, not whenever it has a value.
      invalid_plugin_dirs=""
      canonical_plugin_dirs_present=$(jq -r '((.env | type) == "object") and (.env | has("CLAUDE_CODE_PLUGIN_DIRS"))' "$HERE/$f")
      [ "$canonical_plugin_dirs_present" != true ] || invalid_plugin_dirs=$(plugin_dirs_invalid_reason "$canonical_plugin_dirs")
      if [ -n "$invalid_plugin_dirs" ]; then
        echo "DRIFT: $f canonical env.CLAUDE_CODE_PLUGIN_DIRS $invalid_plugin_dirs (sync.sh reconcile-runtime-env refuses it)"
        drift=1
      fi
      mapped_plugin_dirs=$(mapped_plugin_dirs_of "$canonical_plugin_dirs")
      if [ -n "$mapped_plugin_dirs" ] && [ -z "$invalid_plugin_dirs" ]; then
        missing_plugin_dir=$(plugin_dir_missing_manifest "$mapped_plugin_dirs")
        [ -z "$missing_plugin_dir" ] ||
          { echo "DRIFT: $f env.CLAUDE_CODE_PLUGIN_DIRS names $missing_plugin_dir, which has no .claude-plugin/plugin.json (./setup relinks ~/.claude/mods; a mod on an unmerged branch is not loadable)"; drift=1; }
        # The overlay's plugin-dirs lines are compared below as part of the
        # desired settings, which drop a line that cannot be loaded; name it
        # here, since the builder's stderr is shown only when it fails.
        overlay_plugin_dirs_err=$(plugin_dirs_with_overlay "$mapped_plugin_dirs" 2>&1 >/dev/null)
        [ -z "$overlay_plugin_dirs_err" ] ||
          { printf '%s\n' "$overlay_plugin_dirs_err" | sed 's/^/DRIFT: /'; drift=1; }
      fi
      # ANTHROPIC_BASE_URL is role-projected exactly as reconcile_runtime_env
      # writes it, or a satellite's legitimate tailnet URL reads as permanent
      # DRIFT. ANTHROPIC_AUTH_TOKEN is host-local by design (never canonical —
      # plan R12), so it is excluded from both sides rather than compared. An
      # unknown role skips the URL projection: reconcile fails closed there, so
      # a raw comparison is the honest signal.
      proxy_base_url=""
      case "$(profile_role 2>/dev/null || echo unknown)" in
        workstation) proxy_base_url="$CCFLARE_URL_WORKSTATION" ;;
        satellite)
          proxy_base_url="$CCFLARE_URL_SATELLITE"
          [ -n "$proxy_base_url" ] || echo "  note: this host is a satellite and CCFLARE_URL_SATELLITE is unset (the overlay env, ~/.config/hov-stack/env, sets it); ANTHROPIC_BASE_URL is compared as written" ;;
      esac
      # The projection is conditional because assigning the key outright CREATES
      # it on settings that never declared one, so two byte-identical files (a
      # bare `{}` fixture against a bare `{}` live copy) would compare as drift.
      # modelSettings is compared on the canonical windows alone (dotfiles#1574):
      # the live side is projected to {model: {autoCompactWindow}} for the
      # models the canonical names, so an operator's effortLevel save or a
      # gateway-route entry is not drift, while a missing or changed window is.
      # Both sides use the SAME projection reconcile writes (a canonical entry
      # with no window is dropped, an empty map is no key), or a tracked
      # entry that only carries another field would be drift reconcile can
      # never clear.
      # A canonical map the projection cannot read (not an object of
      # objects) is DRIFT on its own: an empty substitution here once made
      # both sides of the comparison fail alike and read as clean.
      canonical_windows=$(jq -ce '(.modelSettings // {})
        | if type == "object" then . else error("modelSettings is not an object") end
        | with_entries(.value |= (if type == "object" then {autoCompactWindow: .autoCompactWindow} else error("modelSettings entry is not an object") end))
        | with_entries(select(.value.autoCompactWindow != null))' "$HERE/$f" 2>/dev/null) || {
        echo "DRIFT: $f canonical modelSettings is not an object of per-model objects (sync.sh reconcile-runtime-env refuses it)"
        drift=1
        continue
      }
      # Valid explicit global windows are operator exceptions. Missing/null and
      # malformed coverage must still be drift, even when both files agree.
      if ! jq -e "$VALID_COMPACT_WINDOW_JQ"'.autoCompactWindow | valid_compact_window' "$HERE/$f" >/dev/null; then
        echo "DRIFT: $f canonical autoCompactWindow must be an integer from 100000 to 1000000"
        drift=1
      fi
      if ! jq -e "$VALID_COMPACT_WINDOW_JQ"'.autoCompactWindow | valid_compact_window' "$H/$f" >/dev/null; then
        echo "DRIFT: $f live autoCompactWindow is missing or invalid (expected an integer from 100000 to 1000000)"
        drift=1
      fi
      canonical_global_window=$(jq -c '.autoCompactWindow' "$HERE/$f")
      # The canonical side is what this host's live file should hold, built by
      # the code setup seeds a machine with: lib/settings-seed.js renders every
      # `$HOME/`, merges the private overlay (README, "The private overlay") and
      # resolves the dcg hook to $DCG_COMMAND, the path reconcile_dcg_hook
      # writes. SETTINGS_SEED_ALL_KEYS keeps the keys a seed leaves out.
      # Compared raw instead, every overlay rule and every rendered path read
      # as drift that no remedy could clear.
      settings_overlay=""
      if settings_ov_dir=$(overlay_dir) && [ -f "$settings_ov_dir/settings.json" ]; then
        settings_overlay=$settings_ov_dir/settings.json
      fi
      settings_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sync-check-settings.XXXXXX") || {
        echo "DRIFT: $f was not compared (no scratch directory for the projection)"; drift=1; continue; }
      if ! settings_seed_err=$(build_settings_desired "$HERE/$f" "$settings_tmp/canonical.json" 2>&1 >/dev/null); then
        # The builder's own refusal is one line; an uncaught node error ends in a
        # "Node.js vN" banner, so name its Error line instead.
        settings_seed_why=$(printf '%s\n' "$settings_seed_err" | grep -m1 -E '^(settings-seed: |[A-Za-z]*Error: )') \
          || settings_seed_why=$(printf '%s\n' "$settings_seed_err" | tail -1)
        echo "DRIFT: $f canonical copy could not be built${settings_overlay:+ with the overlay $settings_overlay}: $settings_seed_why"
        drift=1; rm -rf "$settings_tmp"; continue
      fi
      settings_live_ok=1 settings_canonical_ok=1
      node -e 'const fs=require("fs"); const {stripOwned}=require(process.argv[1]); fs.writeFileSync(process.argv[3],JSON.stringify(stripOwned(JSON.parse(fs.readFileSync(process.argv[2])))))' "$HERE/lib/settings-apply.js" "$H/$f" "$settings_tmp/live.owned.json" 2>/dev/null || settings_live_ok=0
      jq -S --arg cfg "$H" --arg home "$HOME" --argjson canonical_windows "$canonical_windows" --argjson canonical_global_window "$canonical_global_window" "$VALID_COMPACT_WINDOW_JQ$SETTINGS_NORMAL_JQ"'
                      if (.autoCompactWindow | valid_compact_window) then .autoCompactWindow = $canonical_global_window else . end
                      | if ($canonical_windows | length) > 0
                        then .modelSettings = ((if (.modelSettings | type) == "object" then .modelSettings else {} end)
                               | with_entries(select(.key as $k | $canonical_windows | has($k)))
                               | with_entries(.value |= (if type == "object" then {autoCompactWindow: .autoCompactWindow} else {autoCompactWindow: .} end)))
                        else del(.modelSettings) end
                      | settings_normal($cfg; $home)' "$settings_tmp/live.owned.json" >"$settings_tmp/live.proj.json" 2>/dev/null || settings_live_ok=0
      jq -S --arg env_file "$mapped_env_file" --arg proxy_url "$proxy_base_url" --arg plugin_dirs "$mapped_plugin_dirs" --argjson canonical_windows "$canonical_windows" --arg cfg "$H" --arg home "$HOME" "$SETTINGS_NORMAL_JQ"'
               if ($canonical_windows | length) > 0
                 then .modelSettings = $canonical_windows
                 else del(.modelSettings) end
               | settings_normal($cfg; $home)
             ' "$settings_tmp/canonical.json" >"$settings_tmp/canonical.proj.json" 2>/dev/null || settings_canonical_ok=0
      if [ "$settings_live_ok" -eq 0 ] || [ "$settings_canonical_ok" -eq 0 ] ||
         ! cmp -s "$settings_tmp/live.proj.json" "$settings_tmp/canonical.proj.json"; then
        settings_keys=""
        if [ "$settings_live_ok" -eq 0 ]; then
          settings_keys=" (the live copy could not be projected; is it valid JSON?)"
        elif [ "$settings_canonical_ok" -eq 0 ]; then
          settings_keys=" (the canonical copy could not be projected)"
        else
          settings_keys=$(jq -rn --slurpfile a "$settings_tmp/live.proj.json" --slurpfile b "$settings_tmp/canonical.proj.json" '
              ($a[0] // {}) as $l | ($b[0] // {}) as $c
              | [($l | keys) + ($c | keys) | unique[] | select($l[.] != $c[.])] | " in: " + join(", ")' 2>/dev/null) || settings_keys=""
        fi
        # push copies the whole live file over the repo, overlay entries
        # included, so it is the remedy only for a live-only entry that is
        # public (docs/solutions/integration-issues/a-permissions-entry-added-
        # to-the-tracked-settings-json-never-reaches-the-live-file.md).
        settings_plugin_dirs_hint=""
        if [ "$settings_live_ok" -eq 1 ] && [ "$settings_canonical_ok" -eq 1 ] &&
           jq -en --slurpfile a "$settings_tmp/live.proj.json" --slurpfile b "$settings_tmp/canonical.proj.json" \
             '$a[0].env.CLAUDE_CODE_PLUGIN_DIRS != $b[0].env.CLAUDE_CODE_PLUGIN_DIRS' >/dev/null 2>&1; then
          settings_plugin_dirs_hint="; a plugin folder only this host loads goes in the overlay's plugin-dirs file, not in env.CLAUDE_CODE_PLUGIN_DIRS"
        fi
        echo "DRIFT: $f differs from repo copy beyond ad-daemon-owned keys$settings_keys (an entry only live has goes into settings.json, or the overlay when private; one only the repo has reaches live through sync.sh apply-settings$settings_plugin_dirs_hint)"
        drift=1
      fi
      if ! settings_apply_check=$(node "$HERE/lib/settings-apply.js" --desired "$settings_tmp/canonical.json" --live "$H/$f" --base "$H/.hov-stack/settings-base.json" --config-dir "$H" --home "$HOME" --report check 2>"$settings_tmp/apply-error"); then
        echo "DRIFT: settings.json apply check failed: $(head -1 "$settings_tmp/apply-error")"
        drift=1
      fi
      [ -z "$settings_apply_check" ] || printf '%s\n' "$settings_apply_check"
      if [[ "$settings_apply_check" == *DRIFT:* ]]; then drift=1; fi
      rm -rf "$settings_tmp"
    else
      cmp -s "$H/$f" "$HERE/$f" ||
        { echo "DRIFT: $f differs from repo copy (sync.sh push)"; drift=1; }
    fi
  done
  if [ -f "$HERE/config/repo-routes.json" ]; then
    examined=$((examined + 1))
    [ -L "$H/config/repo-routes.json" ] && [ "$(readlink -f "$H/config/repo-routes.json")" = "$(readlink -f "$HERE/config/repo-routes.json")" ] || {
      echo "DRIFT: config/repo-routes.json is not linked to the versioned policy"; drift=1;
    }
  fi
  if [ -f "$STATUSLINE_REF" ]; then
    examined=$((examined + 1))
    [ -L "$STATUSLINE_RENDERER" ] \
      && [ "$(readlink -f "$STATUSLINE_RENDERER")" = "$(readlink -f "$STATUSLINE_REF")" ] || {
        echo "DRIFT: statusline-stack/local-statusline.mjs is not linked to the versioned renderer"; drift=1;
      }
  fi
  if memory_mirror_opted_in; then
    memory_plan >/dev/null || { echo "DRIFT: memory differs (sync.sh memory-preview, then memory-push)"; drift=1; }
    examined=$((examined + MEMORY_ITEMS_EXAMINED))
  else
    echo "SKIP: memory — $(memory_mirror_absent_reason)"
  fi
  # A unit that is in the repo but MISSING from the live tree is drift too.
  #
  # The previous form compared only when BOTH files existed, so a unit added to
  # UNITS and then never actually installed was invisible here — and therefore
  # invisible to harness-doctor, which consumes only these DRIFT: lines. That is
  # the gap that would have let the #476 OnFailure= handler sit undeployed with
  # nothing ever reporting it, and it contradicts this file's own claim above
  # that a unit added to UNITS "gets copied and drift-checked".
  #
  # Measured when this check was added: FOUR pre-existing units were already
  # missing live — two retired-then-removed families, .service + .timer
  # each — although README.md and harness/dispatcher-ratchets.md both
  # state they are "copied on install, NOT auto-enabled". The copy loop above is
  # unconditional, so their absence was never a deliberate opt-out; it was
  # simply unreported since they landed (2026-08-22 and 2026-08-25). Not enabled
  # is a policy; not installed is drift.
  for u in $UNITS; do
    [ -f "$HERE/systemd/$u" ] || continue
    examined=$((examined + 1))
    if [ ! -f "$SYS/$u" ]; then
      echo "DRIFT: systemd/$u is not installed (./setup --enable-units)"; drift=1
    elif ! cmp -s "$SYS/$u" "$HERE/systemd/$u"; then
      echo "DRIFT: systemd/$u differs (sync.sh push)"; drift=1
    fi
  done

  local overlay_index overlay_path overlay_error
  for overlay_error in "${OVERLAY_UNIT_ERRORS[@]}"; do
    echo "DRIFT: $overlay_error"; drift=1
  done
  for overlay_index in "${!OVERLAY_UNIT_PATHS[@]}"; do
    overlay_path=${OVERLAY_UNIT_PATHS[$overlay_index]}
    examined=$((examined + 1))
    if [ ! -f "$SYS/$overlay_path" ]; then
      echo "DRIFT: overlay unit $overlay_path is not installed (./setup --enable-units)"; drift=1
    elif ! cmp -s "$SYS/$overlay_path" "${OVERLAY_UNIT_SOURCES[$overlay_index]}"; then
      echo "DRIFT: overlay unit $overlay_path differs (./setup)"; drift=1
    fi
  done
  overlay_unit_timers_check 'DRIFT: ' || drift=1

  # Host-declared hygiene posture (lib/hygiene-posture.sh): the overlay's declaration
  # against the drop-ins and timers install should have left. No file and no generated
  # drop-in prints nothing. The timer-enabled half needs the user manager; without one
  # the SKIP line below already says so, and no second line is invented here.
  # A tree without lib/hygiene-posture.sh (a minimal fixture copy of sync.sh) already
  # printed the failed source above; it has no posture to compare.
  if ! declare -F hygiene_posture_load >/dev/null; then
    :
  elif ! _posture_file=$(hygiene_posture_file 2>/dev/null); then
    echo "DRIFT: hygiene posture: the overlay path is not absolute (HOV_STACK_OVERLAY or HOME), so the posture was not read"; drift=1
  elif ! _posture_rows=$(hygiene_posture_load); then
    echo "DRIFT: hygiene posture: $_posture_file is invalid (see errors above)"; drift=1
  else
    # shellcheck disable=SC2034 # read by hygiene_posture_render (lib/hygiene-posture.sh)
    HYGIENE_POSTURE_ROWS=$_posture_rows
    for _stem in $HYGIENE_POSTURE_STEMS; do
      for _kind in service timer; do
        _dest=$SYS/$_stem.$_kind.d/$HYGIENE_POSTURE_DROPIN
        _want=$(hygiene_posture_render "$_stem" "$_kind")
        if [ -n "$_want" ]; then
          if [ ! -f "$_dest" ]; then
            echo "DRIFT: hygiene posture: $_dest is not installed (./setup --enable-units)"; drift=1
          elif [ "$(cat -- "$_dest")" != "$_want" ]; then
            echo "DRIFT: hygiene posture: $_dest differs from the overlay declaration (./setup --enable-units)"; drift=1
          fi
        elif [ -e "$_dest" ] || [ -L "$_dest" ]; then
          echo "DRIFT: hygiene posture: $_dest is no longer declared (./setup --enable-units removes it)"; drift=1
        fi
      done
    done
    if systemctl --user show -p Version >/dev/null 2>&1; then
      for _stem in $(hygiene_posture_declared); do
        systemctl --user is-enabled "$_stem.timer" >/dev/null 2>&1 || {
          echo "DRIFT: hygiene posture: $_stem.timer is declared but not enabled (./setup --enable-units)"; drift=1
        }
      done
    fi
    unset HYGIENE_POSTURE_ROWS
  fi

  # The INVERSE of the loop above, and the reason it exists: that one proves
  # every DECLARED unit is live. Nothing proved every LIVE unit is declared.
  #
  # This is lib/check.sh manifest_check (c) applied to systemd instead of
  # symlinks -- the same "live config nothing owns" class that lib/manifest.sh's
  # header was written about, at the one layer that had no checker. Measured
  # 2026-08-27 on workstation: 29 enabled --user timers, 18 declared. THIRTEEN would have
  # vanished on a rebuild without a word.
  #
  # TIMERS *AND* SERVICES. An earlier revision queried --type=timer while this
  # comment claimed every live unit, so enabled services never entered the loop.
  # On workstation that hid five in exactly the policed class. A checker whose scope is
  # narrower than its documentation is worse than one that admits its limits,
  # because the gap reads as coverage.
  #
  # TWO WAYS TO BE DECLARED, because this repo has two. A unit named in the
  # role-selected inventory is copy-installed by install(); a unit in lib/manifest.sh is SYMLINKED into
  # ~/.config/systemd/user (pi-local-champion-tunnel.service is the live case).
  # Recognising only the first would report a correctly-managed unit as drift,
  # and a checker that cries wolf gets muted -- which is how the original gap
  # survived. A fragment that resolves into this repo is declared, whichever
  # mechanism put it there.
  #
  # Only units whose fragment lives under $HOME are considered. A distro unit
  # (/usr/lib/systemd/user, e.g. launchpadlib-cache-clean from
  # python3-launchpadlib) is the OS's to own.
  # NOT APPLICABLE vs BROKEN, and the probe has to be the right one.
  #
  # First attempt used `[ -d /run/systemd/system ]` — systemd is PID 1 — which is
  # true on this workstation and still wrong: the hermetic suite and CI both run
  # WITHOUT a session bus, so `systemctl --user` exits 3 while systemd is very
  # much PID 1. The question is not "does this host run systemd" but "can this
  # PROCESS reach a user manager", and only the second one predicts whether the
  # enumeration can work.
  #
  # So: probe reachability cheaply. Unreachable means the check does not apply
  # here (container, hermetic fixture, cron without a bus) and prints a visible
  # SKIP. Reachable but failing IS the broken case and stays drift — that is the
  # fail-closed property the review asked for, kept where it can actually mean
  # something.
  #
  # NO-CLAIM BOUNDARY, stated because it is a real narrowing: a workstation whose
  # user bus has died reads as "unreachable" and will SKIP rather than alarm.
  # That machine has larger symptoms — every one of its timers is dead — and this
  # check is not the place to discover it. What the skip cannot do is hide
  # quietly: it prints, every run.
  if ! systemctl --user show -p Version >/dev/null 2>&1; then
    echo "SKIP: no reachable systemd --user manager in this context; undeclared-unit check not applicable"
  elif command -v systemctl >/dev/null 2>&1; then
    _live_units=$(systemctl --user list-unit-files --type=timer --type=service \
                    --state=enabled --no-legend 2>/dev/null)
    _live_rc=$?
    # A GATE THAT CANNOT COMPARE MUST FAIL, NOT SKIP. Previously the query ran
    # inside a command substitution with 2>/dev/null and its status was never
    # tested, so a dead user manager or bus produced zero rows, raised no DRIFT,
    # and let check() print "in sync". That is the zero-run-green shape this
    # harness treats as failure everywhere else, sitting inside the very check
    # meant to catch silent gaps.
    if [ "$_live_rc" -ne 0 ]; then
      echo "DRIFT: could not enumerate live --user units (systemctl exit $_live_rc) — undeclared-unit check did NOT run"
      drift=1
    elif [ -z "$_live_units" ]; then
      echo "DRIFT: live --user unit enumeration returned nothing — expected at least the units install() enables; check did NOT run meaningfully"
      drift=1
    else
      while read -r unit _; do
        [ -n "$unit" ] || continue
        case " $UNITS " in *" $unit "*) continue ;; esac
        case " $UNITS_FOREIGN " in *" ${unit%.*} "*) continue ;; esac
        # SAME DISEASE AS THE ENUMERATION, ONE LAYER DOWN. This used to suppress
        # errors and never test the status, so a `show` that failed returned an
        # empty FragmentPath, which then took the non-$HOME `continue` below --
        # the detector stayed green while unable to classify an enabled unit.
        # Proven with a shim: a listed zz-probe.service whose `show` exits 9
        # produced no drift at all. A unit the check CANNOT CLASSIFY is a named
        # failure, never a skip.
        frag=$(systemctl --user show -p FragmentPath --value "$unit" 2>/dev/null); frag_rc=$?
        if [ "$frag_rc" -ne 0 ] || [ -z "$frag" ]; then
          echo "DRIFT: cannot classify enabled unit $unit (systemctl show exit $frag_rc, FragmentPath empty) — undeclared-unit check is incomplete"
          drift=1
          continue
        fi
        case "$frag" in "$HOME"/*) ;; *) continue ;; esac
        # Declared by lib/manifest.sh: the live path is a symlink into this repo.
        _resolved=$(readlink -f "$frag" 2>/dev/null)
        case "$_resolved" in "$HERE"/*) continue ;; esac
        echo "DRIFT: $unit is enabled but nothing declares it (add to UNITS, link it via lib/manifest.sh, or add to UNITS_FOREIGN with its owning repo)"
        drift=1
      done <<EOF_LIVE_UNITS
$_live_units
EOF_LIVE_UNITS
    fi
  else
    echo "DRIFT: systemctl unavailable — undeclared-unit check did NOT run"
    drift=1
  fi
  # SYSTEM_UNITS deliberately KEEPS the both-exist guard. Installing one needs
  # sudo and is an explicit operator act (the root phase prints a manual
  # command when sudo is unavailable), so "absent" is a legitimate state there
  # rather than drift. Flagged rather than changed: making it drift is a
  # separate decision with a different blast radius.
  for u in $SYSTEM_UNITS; do
    if [ -f "$SYSTEM_SYS/$u" ] && [ -f "$HERE/systemd-system/$u" ]; then
      examined=$((examined + 1))
      rendered=$(mktemp) || exit 3
      render_system_unit "$HERE/systemd-system/$u" "$rendered"
      ! cmp -s "$SYSTEM_SYS/$u" "$rendered" &&
        { echo "DRIFT: systemd-system/$u differs (sync.sh push)"; drift=1; }
      rm -f "$rendered"
    fi
  done
  if [ -n "$(git -C "$HERE" status --porcelain 2>/dev/null)" ]; then
    echo "DRIFT: uncommitted harness changes in the repo (commit + push them)"; drift=1
  fi
  # Measured 2026-08-17: 3,387 actual comparisons (5 dirs, 3 files,
  # 3,351 memory paths, 27 user units, 1 system unit). The corpus is dynamic;
  # consumers floor only zero and disclose the measured count.
  echo "EXAMINED: $examined"
  floor "$examined" 1 "sync corpus" || return 2
  [ "$drift" -eq 0 ] && echo "in sync"
  return "$drift"
}

case "$MODE" in
  apply-settings) apply_settings "${@:2}" ;;
  push) push ;;
  install) echo "sync.sh install was removed. Use ./setup (links and settings), ./setup --enable-units (units and timers), and ./setup --root (lock and system units)." >&2; exit 2 ;;
  role) role_phase "${@:2}" ;;
  reconcile-dcg) reconcile_dcg_hook --write-canonical ;;
  ensure-papercut-plugin) ensure_papercut_plugin ;;
  reconcile-runtime-env) reconcile_runtime_env ;;
  reconcile-windows-auto-mode) reconcile_windows_auto_mode ;;
  reconcile-docker-init)
    if [ "$#" -ne 1 ]; then
      echo "usage: sync.sh reconcile-docker-init" >&2
      exit 2
    fi
    docker_init_policy reconcile
    ;;
  adopt-docker-init)
    case "$#" in
      1) docker_init_policy adopt ;;
      2)
        case "$2" in
          --allow-existing-false) docker_init_policy adopt --allow-existing-false ;;
          *) echo "usage: sync.sh adopt-docker-init [--allow-existing-false]" >&2; exit 2 ;;
        esac
        ;;
      *) echo "usage: sync.sh adopt-docker-init [--allow-existing-false]" >&2; exit 2 ;;
    esac
    ;;
  rollback-docker-init)
    if [ "$#" -ne 1 ]; then
      echo "usage: sync.sh rollback-docker-init" >&2
      exit 2
    fi
    docker_init_policy rollback
    ;;
  check) check ;;
  memory-preview|memory-check) memory_preview ;;
  memory-push) memory_push ;;
  *) echo "usage: sync.sh apply-settings [--plan] [--quiet] [--seed-base <rev>]|push|role <refresh|owner|enable|root|check>|reconcile-docker-init|adopt-docker-init [--allow-existing-false]|rollback-docker-init|reconcile-dcg|reconcile-runtime-env|reconcile-windows-auto-mode|ensure-papercut-plugin|check|memory-preview|memory-check|memory-push" >&2; exit 2 ;;
esac
