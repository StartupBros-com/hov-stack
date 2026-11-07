#!/usr/bin/env bash
# Tests for sync.sh's `install` (and `check`) modes -- the smoke coverage
# missing per dotfiles#379: nothing under tests/ exercised sync.sh's install
# path, so #370/#373 (new SYSTEM_UNITS install class, 8 new unit files) shipped
# with zero CI coverage. install-smoke.yml is NOT the right home for this --
# it tests install.sh, a DIFFERENT installer; adding ** to its paths
# filter would re-run install.sh on every harness PR without necessarily
# exercising sync.sh at all (motion without coverage -- see the issue).
#
# Hermetic: builds its own $TMP/$HOME and distinct $CLAUDE_HOME, and points
# sync.sh's two system-scoped
# targets (CLAUDE_SYNC_SYSTEM_SYS_DIR / CLAUDE_SYNC_MANAGED_LOCK -- new,
# optional overrides added by this same change; unset on the real box, so
# behavior there is unchanged) at scratch paths under $TMP too, so even the
# sudo-deployed SYSTEM_UNITS/managed-lock loops never touch a real /etc path.
# The sudo calls still run for REAL (this box and CI both carry passwordless
# sudo -- see sync.sh's own SYSTEM_UNITS header comment), so the actual
# `sudo install -D ...` code path is exercised end-to-end; only the
# destination is fake.
#
# CLAUDE_SYNC_SKIP_HOOK_RECONCILE=1 (the same flag install-smoke.yml already
# sets for install.sh): the DCG/memory/papercut hook-reconcile functions resolve
# their targets through THIS box's home (e.g. ~/.local/bin/dcg), which a scratch
# $HOME does not carry -- see reconcile_dcg_hook's own comment.
#
# CLAUDE_MEMORY_MIRROR_ROOT points at an empty temp dir rather than the real
# $HERE/memory: with an empty (sandboxed) live root and the real, non-empty
# repo memory/ as the mirror, `check`'s memory_plan would report every real
# memory file as "mirror-only" forever -- a false drift unrelated to install
# correctness. Both sides empty means the memory comparison asserts nothing,
# which is correct here: memory sync is not what this suite guards.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
# Git records only modes 644 and 755, but cp -a carries the checkout's own: a
# worktree created under umask 0002 holds 664/775, and the literal 644 check on
# migration-targets.sh read red with nothing wrong in sync.sh (#1647, pro-gate
# round 1 on #1645). Normalize the copy to git's mode model so the fixture
# holds the tracked tree, not the host's umask. GNU chmod -R skips symlinks it
# meets while recursing.
copy_tracked() { cp -a "$1" "$2" && chmod -R u=rwX,go=rX "$2"; }
# Copy the source outside its git worktree: check() correctly reports pending
# source changes as drift, but that host state is unrelated to this fixture.
mkdir -p "$TMP/dotfiles"
# The harness tree is what sync.sh installs: copy each DOTFILES_HARNESS entry rather
# than the whole checkout, so docs/, harnesses/ and the repo-only root files stay out
# of the fixture the way the old mirror directory kept them out.
# shellcheck source=../lib/manifest.sh
. "$REPO/lib/manifest.sh"
for e in "${DOTFILES_HARNESS[@]}"; do copy_tracked "$REPO/$e" "$TMP/dotfiles/$e"; done
# sync.sh sources lib/profile.sh for the role model and reads hosts.tsv.
# Both belong in the fake tree because they are the same repo -- omitting them
# made sync.sh emit "No such file" on every invocation in this suite.
copy_tracked "$REPO/lib" "$TMP/dotfiles/lib"
# config/ holds the harness's policy files (dispatcher.env, repo-routes.json,
# system/docker-daemon.patch.json) beside the tool configs
# install.sh links; sync.sh reads and links from it, so the directory comes along whole.
copy_tracked "$REPO/config" "$TMP/dotfiles/config"
# NOT a copy of the real table. Appending to it looked right and was wrong: the
# developer box is already listed (satellite-host -> satellite), profile_role takes
# the FIRST match, and the appended workstation row lost. It passed on CI, where
# the runner is absent from the table, and failed only locally — the worst shape
# for a fixture. The hermetic tree gets a hermetic table with exactly one row.
# A hermetic tree is not a declared machine, but it must become one the way a
# real machine does: by getting a ROW, not by asserting a role in the
# environment. `workstation` now requires a hosts.tsv entry unconditionally --
# push authority hangs off that role, so an unregistered host claiming it via
# DOTFILES_ROLE is precisely the hole the table exists to close. Using the env
# var here would have tested the escape hatch instead of the mechanism, and it
# stopped working the moment the hole was closed.
printf '# hermetic fixture table — one row, this host only\n%s\t%s\n' \
  "$(hostname -s 2>/dev/null || hostname)" workstation > "$TMP/dotfiles/hosts.tsv"
REPO=$TMP/dotfiles
# Plain rm can't remove the root:root files this test's own sudo-install calls
# create under $CLAUDE_SYNC_SYSTEM_SYS_DIR / $CLAUDE_SYNC_MANAGED_LOCK (both
# under $TMP) -- fall back to a passwordless sudo rm so cleanup doesn't leave
# root-owned droppings in /tmp on every run.
trap 'rm -rf "$TMP" 2>/dev/null || sudo -n rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

HOME=$TMP/home
CLAUDE_HOME=$TMP/claude-home
retired_profile="$CLAUDE_HOME/config/loop-quality.json"
mkdir -p "$CLAUDE_HOME/config"
printf '%s\n' '{"retired":true}' >"$retired_profile"
export HOME CLAUDE_HOME
mkdir -p "$HOME"
# The overlay is the fixture's own, so no install here reads a real host's overlay
# files (foreign-units, hygiene-posture) through an inherited variable.
unset XDG_CONFIG_HOME
# Likewise the host route record: with these unset, repo-route.py keeps it under the
# fixture's $HOME, never in a real host's state directory.
unset XDG_STATE_HOME REPO_ROUTE_STATE
HOV_STACK_OVERLAY=$TMP/overlay
export HOV_STACK_OVERLAY
mkdir -p "$HOV_STACK_OVERLAY"

export CLAUDE_SYNC_SKIP_HOOK_RECONCILE=1
export CLAUDE_MEMORY_MIRROR_ROOT="$TMP/empty-mirror"
mkdir -p "$CLAUDE_MEMORY_MIRROR_ROOT"
export CLAUDE_SYNC_SYSTEM_SYS_DIR="$TMP/etc-systemd-system"
export CLAUDE_SYNC_MANAGED_LOCK="$TMP/etc-claude-code/managed-settings.json"
export CLAUDE_WINDOWS_HOME="$TMP/windows-home"
mkdir -p "$CLAUDE_WINDOWS_HOME"

SYNC="$REPO/sync.sh"

# Docker init policy uses its real subprocess CLI against asserted scratch
# paths. The mock implements only dockerd's offline validation interface and
# records every call; neither Docker nor a service manager is reachable here.
DOCKER_POLICY_ROOT=$TMP/docker-policy
DOCKER_DAEMON_TARGET=$DOCKER_POLICY_ROOT/etc/docker/daemon.json
DOCKER_ADOPTION_STATE=$DOCKER_POLICY_ROOT/var/lib/dotfiles/docker-init-adoption.json
DOCKER_ADOPTION_BACKUP=$DOCKER_POLICY_ROOT/var/lib/dotfiles/docker-init-adoption.original
DOCKER_POLICY_LOCK=$DOCKER_POLICY_ROOT/etc/docker/.daemon.json.dotfiles.lock
DOCKERD_FIXTURE=$DOCKER_POLICY_ROOT/bin/dockerd
DOCKER_VALIDATE_LOG=$DOCKER_POLICY_ROOT/dockerd-validation.log
mkdir -m 0700 "$DOCKER_POLICY_ROOT"
mkdir -p "$(dirname "$DOCKER_DAEMON_TARGET")" "$(dirname "$DOCKER_ADOPTION_STATE")" "$(dirname "$DOCKERD_FIXTURE")"
printf '%s\n' '{"log-driver":"local","unknown-option":{"preserve":true}}' >"$DOCKER_DAEMON_TARGET"
cat >"$DOCKERD_FIXTURE" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = --validate ]
[ "$2" = --config-file ]
printf '%s\n' "$*" >>"${DOCKER_VALIDATE_LOG:?}"
exit "${DOCKER_VALIDATE_EXIT:-0}"
SH
chmod +x "$DOCKERD_FIXTURE"
export DOCKER_VALIDATE_LOG
export CLAUDE_SYNC_DOCKER_TEST_ROOT="$DOCKER_POLICY_ROOT"
export CLAUDE_SYNC_DOCKER_DAEMON_TARGET="$DOCKER_DAEMON_TARGET"
export CLAUDE_SYNC_DOCKER_ADOPTION_STATE="$DOCKER_ADOPTION_STATE"
export CLAUDE_SYNC_DOCKER_ADOPTION_BACKUP="$DOCKER_ADOPTION_BACKUP"
export CLAUDE_SYNC_DOCKER_POLICY_LOCK="$DOCKER_POLICY_LOCK"
export CLAUDE_SYNC_DOCKERD="$DOCKERD_FIXTURE"

# Hermetic PATH shims: the fake systemctl, docker and crontab keep this
# scratch-home test from inspecting or mutating the operator's live managers.
TEST_BIN=$TMP/test-bin
mkdir -p "$TEST_BIN"
cat >"$TEST_BIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_COMMAND_LOG:?}"
exit 97
SH
cat >"$TEST_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
[ "${1:-}" = --user ] && shift
command=${1:-}; shift || true
case "$command" in
  show-environment|daemon-reload)
    exit 0
    ;;
  is-enabled)
    grep -Fxq -- "${1:-}" "${SYSTEMCTL_ENABLED_TIMERS:?}" 2>/dev/null
    ;;
  is-active)
    if grep -Fxq -- "${1:-}" "${SYSTEMCTL_ACTIVE_SERVICES:?}" 2>/dev/null; then
      printf '%s\n' active
      exit 0
    fi
    if grep -Fxq -- "${1:-}" "${SYSTEMCTL_FAILED_SERVICES:?}" 2>/dev/null; then
      printf '%s\n' failed
      exit 3
    fi
    printf '%s\n' inactive
    exit 3
    ;;
  enable)
    [ "${1:-}" = --now ] && shift
    for unit in "$@"; do
      if [ -n "${SYSTEMCTL_FAIL_ENABLE_TIMER:-}" ] \
         && [ "$unit" = "$SYSTEMCTL_FAIL_ENABLE_TIMER" ]; then
        exit 9
      fi
    done
    printf '%s\n' "$@" >> "$SYSTEMCTL_ENABLED_TIMERS"
    sort -u -o "$SYSTEMCTL_ENABLED_TIMERS" "$SYSTEMCTL_ENABLED_TIMERS"
    ;;
  disable)
    [ "${SYSTEMCTL_FAIL_DISABLE:-0}" = 1 ] && exit 9
    [ "${1:-}" = --now ] && shift
    for unit in "$@"; do
      grep -Fxv -- "$unit" "$SYSTEMCTL_ENABLED_TIMERS" \
        >"$SYSTEMCTL_ENABLED_TIMERS.next" || true
      mv "$SYSTEMCTL_ENABLED_TIMERS.next" "$SYSTEMCTL_ENABLED_TIMERS"
    done
    ;;
  stop)
    [ "${SYSTEMCTL_FAIL_STOP:-0}" = 1 ] && exit 9
    # Stopping clears active state, but deliberately does not reset a failed
    # unit. The reconciler must distinguish failed from proven inactive.
    for unit in "$@"; do
      [ "$unit" = "${SYSTEMCTL_STICKY_SERVICE:-}" ] && continue
      grep -Fxv -- "$unit" "$SYSTEMCTL_ACTIVE_SERVICES" \
        >"$SYSTEMCTL_ACTIVE_SERVICES.next" || true
      mv "$SYSTEMCTL_ACTIVE_SERVICES.next" "$SYSTEMCTL_ACTIVE_SERVICES"
    done
    ;;
  show)
    # check() treats this as an explicit no-user-manager skip. install() uses
    # show-environment above, so activation is still exercised. The hygiene-posture
    # section sets SYSTEMCTL_SHOW_REACHABLE=1 to give check() a reachable manager.
    [ "${SYSTEMCTL_SHOW_REACHABLE:-0}" = 1 ] && exit 0
    exit 3
    ;;
  *)
    exit 0
    ;;
esac
SH
cat >"$TEST_BIN/crontab" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = -l ] || exit 64
printf '%s\n' "$*" >>"${CRONTAB_CALL_LOG:?}"
case "${CRONTAB_MODE:-absent}" in
  unavailable)
    printf '%s\n' 'crontab: command not found' >&2
    exit 127
    ;;
  absent)
    printf '%s\n' 'no crontab for fixture' >&2
    exit 1
    ;;
  file)
    cat "${CRONTAB_FIXTURE:?}"
    ;;
  error)
    exit 2
    ;;
  drift)
    count=0
    [ -f "${CRONTAB_READ_COUNT:?}" ] && read -r count <"$CRONTAB_READ_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$CRONTAB_READ_COUNT"
    if [ "$count" -eq 1 ]; then
      cat "${CRONTAB_FIXTURE:?}"
    else
      cat "${CRONTAB_FIXTURE:?}"
      printf '%s\n' '0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh >> /redacted/log 2>&1'
    fi
    ;;
  *)
    exit 64
    ;;
esac
SH
chmod +x "$TEST_BIN/docker" "$TEST_BIN/systemctl" "$TEST_BIN/crontab"
export DOCKER_COMMAND_LOG="$TMP/docker-command.log"
export SYSTEMCTL_LOG="$TMP/systemctl.log"
export SYSTEMCTL_ENABLED_TIMERS="$TMP/systemctl-enabled-timers.state"
export SYSTEMCTL_ACTIVE_SERVICES="$TMP/systemctl-active-services.state"
export SYSTEMCTL_FAILED_SERVICES="$TMP/systemctl-failed-services.state"
export CRONTAB_FIXTURE="$TMP/crontab.fixture"
export CRONTAB_READ_COUNT="$TMP/crontab.read-count"
export CRONTAB_CALL_LOG="$TMP/crontab.calls"
: >"$CRONTAB_CALL_LOG"
export CLAUDE_SYNC_CUTOVER_LOCK="$TMP/critical-silence-cutover.lock"
: >"$DOCKER_COMMAND_LOG"
: >"$SYSTEMCTL_LOG"
: >"$SYSTEMCTL_ENABLED_TIMERS"
: >"$SYSTEMCTL_ACTIVE_SERVICES"
: >"$SYSTEMCTL_FAILED_SERVICES"
: >"$CRONTAB_FIXTURE"
export PATH="$TEST_BIN:$PATH"

# The three public Docker policy verbs validate their complete argv before the
# helper or sudo can run. Replace only the copied helper with an invocation
# probe, and shadow id/sudo for these calls so a routing regression is visible
# without any privileged or live-host effect.
DOCKER_POLICY_HELPER=$REPO/scripts/docker-daemon-config.py
DOCKER_POLICY_HELPER_REAL=$TMP/docker-daemon-config.real.py
DOCKER_POLICY_HELPER_LOG=$TMP/docker-policy-helper.log
DOCKER_POLICY_SUDO_LOG=$TMP/docker-policy-sudo.log
DOCKER_POLICY_ARGV_BIN=$TMP/docker-policy-argv-bin
cp "$DOCKER_POLICY_HELPER" "$DOCKER_POLICY_HELPER_REAL"
mkdir -p "$DOCKER_POLICY_ARGV_BIN"
cat >"$DOCKER_POLICY_HELPER" <<'PY'
import os
import sys

with open(os.environ["DOCKER_POLICY_HELPER_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(4)
PY
cat >"$DOCKER_POLICY_ARGV_BIN/id" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then
  printf '%s\n' 1000
  exit 0
fi
exec /usr/bin/id "$@"
SH
cat >"$DOCKER_POLICY_ARGV_BIN/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_POLICY_SUDO_LOG:?}"
exit 98
SH
chmod +x "$DOCKER_POLICY_ARGV_BIN/id" "$DOCKER_POLICY_ARGV_BIN/sudo"

assert_docker_policy_usage_refusal() {
  local label=$1 expected_usage=$2 out status config_before config_after
  shift 2
  : >"$DOCKER_POLICY_HELPER_LOG"
  : >"$DOCKER_POLICY_SUDO_LOG"
  config_before=$(sha256sum "$DOCKER_DAEMON_TARGET")
  out=$(PATH="$DOCKER_POLICY_ARGV_BIN:$PATH" \
    CLAUDE_SYNC_DOCKER_TEST_ROOT='' \
    DOCKER_POLICY_HELPER_LOG="$DOCKER_POLICY_HELPER_LOG" \
    DOCKER_POLICY_SUDO_LOG="$DOCKER_POLICY_SUDO_LOG" \
    "$SYNC" "$@" 2>&1)
  status=$?
  config_after=$(sha256sum "$DOCKER_DAEMON_TARGET")
  if [ "$status" -eq 2 ] \
     && grep -Fq "$expected_usage" <<<"$out" \
     && [ ! -s "$DOCKER_POLICY_HELPER_LOG" ] \
     && [ ! -s "$DOCKER_POLICY_SUDO_LOG" ] \
     && [ "$config_before" = "$config_after" ] \
     && [ ! -e "$DOCKER_ADOPTION_STATE" ] \
     && [ ! -e "$DOCKER_ADOPTION_BACKUP" ]; then
    ok
  else
    bad "$label was not refused before helper/sudo/config access (status=$status):"$'\n'"$out"$'\n'"helper: $(cat "$DOCKER_POLICY_HELPER_LOG")"$'\n'"sudo: $(cat "$DOCKER_POLICY_SUDO_LOG")"
  fi
}

assert_docker_policy_usage_refusal \
  "reconcile trailing argument" "usage: sync.sh reconcile-docker-init" \
  reconcile-docker-init trailing
assert_docker_policy_usage_refusal \
  "reconcile --help" "usage: sync.sh reconcile-docker-init" \
  reconcile-docker-init --help
assert_docker_policy_usage_refusal \
  "adopt malformed option" "usage: sync.sh adopt-docker-init [--allow-existing-false]" \
  adopt-docker-init --bogus
assert_docker_policy_usage_refusal \
  "adopt --help" "usage: sync.sh adopt-docker-init [--allow-existing-false]" \
  adopt-docker-init --help
assert_docker_policy_usage_refusal \
  "adopt trailing argument" "usage: sync.sh adopt-docker-init [--allow-existing-false]" \
  adopt-docker-init --allow-existing-false trailing
assert_docker_policy_usage_refusal \
  "rollback trailing argument" "usage: sync.sh rollback-docker-init" \
  rollback-docker-init trailing
assert_docker_policy_usage_refusal \
  "rollback --help" "usage: sync.sh rollback-docker-init" \
  rollback-docker-init --help
cp "$DOCKER_POLICY_HELPER_REAL" "$DOCKER_POLICY_HELPER"

# Positive wrapper routing uses a second policy root so explicit-false adoption
# and rollback cannot disturb the later plain-adoption fixture.
DOCKER_FALSE_ROOT=$TMP/docker-policy-false-route
DOCKER_FALSE_TARGET=$DOCKER_FALSE_ROOT/etc/docker/daemon.json
DOCKER_FALSE_STATE=$DOCKER_FALSE_ROOT/var/lib/dotfiles/docker-init-adoption.json
DOCKER_FALSE_BACKUP=$DOCKER_FALSE_ROOT/var/lib/dotfiles/docker-init-adoption.original
DOCKER_FALSE_LOCK=$DOCKER_FALSE_ROOT/etc/docker/.daemon.json.dotfiles.lock
DOCKER_FALSE_DOCKERD=$DOCKER_FALSE_ROOT/bin/dockerd
DOCKER_FALSE_VALIDATE_LOG=$DOCKER_FALSE_ROOT/dockerd-validation.log
mkdir -m 0700 "$DOCKER_FALSE_ROOT"
mkdir -p "$(dirname "$DOCKER_FALSE_TARGET")" "$(dirname "$DOCKER_FALSE_STATE")" "$(dirname "$DOCKER_FALSE_DOCKERD")"
cp "$DOCKERD_FIXTURE" "$DOCKER_FALSE_DOCKERD"
printf '%s\n' '{"init":false,"unknown-option":{"preserve":true}}' >"$DOCKER_FALSE_TARGET"
docker_false_original=$(cat "$DOCKER_FALSE_TARGET")
docker_false_adopt_out=$(DOCKER_VALIDATE_LOG="$DOCKER_FALSE_VALIDATE_LOG" \
  CLAUDE_SYNC_DOCKER_TEST_ROOT="$DOCKER_FALSE_ROOT" \
  CLAUDE_SYNC_DOCKER_DAEMON_TARGET="$DOCKER_FALSE_TARGET" \
  CLAUDE_SYNC_DOCKER_ADOPTION_STATE="$DOCKER_FALSE_STATE" \
  CLAUDE_SYNC_DOCKER_ADOPTION_BACKUP="$DOCKER_FALSE_BACKUP" \
  CLAUDE_SYNC_DOCKER_POLICY_LOCK="$DOCKER_FALSE_LOCK" \
  CLAUDE_SYNC_DOCKERD="$DOCKER_FALSE_DOCKERD" \
  "$SYNC" adopt-docker-init --allow-existing-false 2>&1)
docker_false_adopt_status=$?
if [ "$docker_false_adopt_status" -eq 0 ] \
   && jq -e '.init == true and ."unknown-option".preserve == true' "$DOCKER_FALSE_TARGET" >/dev/null \
   && [ "$(cat "$DOCKER_FALSE_BACKUP")" = "$docker_false_original" ] \
   && [ "$(jq -r .phase "$DOCKER_FALSE_STATE")" = adopted ]; then
  ok
else
  bad "explicit-false wrapper adoption did not route the approved flag (status=$docker_false_adopt_status):"$'\n'"$docker_false_adopt_out"
fi

docker_false_rollback_out=$(DOCKER_VALIDATE_LOG="$DOCKER_FALSE_VALIDATE_LOG" \
  CLAUDE_SYNC_DOCKER_TEST_ROOT="$DOCKER_FALSE_ROOT" \
  CLAUDE_SYNC_DOCKER_DAEMON_TARGET="$DOCKER_FALSE_TARGET" \
  CLAUDE_SYNC_DOCKER_ADOPTION_STATE="$DOCKER_FALSE_STATE" \
  CLAUDE_SYNC_DOCKER_ADOPTION_BACKUP="$DOCKER_FALSE_BACKUP" \
  CLAUDE_SYNC_DOCKER_POLICY_LOCK="$DOCKER_FALSE_LOCK" \
  CLAUDE_SYNC_DOCKERD="$DOCKER_FALSE_DOCKERD" \
  "$SYNC" rollback-docker-init 2>&1)
docker_false_rollback_status=$?
if [ "$docker_false_rollback_status" -eq 0 ] \
   && jq -e '.init == false and ."unknown-option".preserve == true' "$DOCKER_FALSE_TARGET" >/dev/null \
   && [ "$(jq -r .phase "$DOCKER_FALSE_STATE")" = rolled_back ]; then
  ok
else
  bad "Docker rollback wrapper did not route the mode-only command (status=$docker_false_rollback_status):"$'\n'"$docker_false_rollback_out"
fi

# -- push refuses stale policy before capturing any live file ----------------
# A reviewed canonical policy must not be overwritten by pre-install runtime
# copies. Exercise each source independently so short-circuiting cannot hide a
# missing managed or Windows guard.
stale_push_home=$TMP/stale-push-home
stale_push_windows=$TMP/stale-push-windows
stale_push_lock=$TMP/stale-managed-settings.json
mkdir -p "$stale_push_home" "$stale_push_windows/.claude"
cp "$REPO/settings.json" "$stale_push_home/settings.json"
cp "$REPO/managed-settings.json" "$stale_push_lock"
cp "$REPO/windows-stub/settings.json" "$stale_push_windows/.claude/settings.json"
tracked_policy_before=$(sha256sum "$REPO/settings.json" "$REPO/managed-settings.json" "$REPO/windows-stub/settings.json")

jq 'del(.permissions.disableAutoMode)' "$stale_push_home/settings.json" >"$TMP/stale-user.json"
mv "$TMP/stale-user.json" "$stale_push_home/settings.json"
stale_user_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_user_status=$?
if [ "$stale_user_status" -ne 0 ]; then ok; else bad "push accepted stale user Auto-mode policy"; fi
case "$stale_user_out" in *"user settings"*) ok ;; *) bad "stale user push did not name the blocking source" ;; esac
cp "$REPO/settings.json" "$stale_push_home/settings.json"

cp "$REPO/settings.json" "$stale_push_home/settings.json"
jq '.permissions.defaultMode = "acceptEdits"' "$stale_push_home/settings.json" >"$TMP/stale-default.json"
mv "$TMP/stale-default.json" "$stale_push_home/settings.json"
stale_default_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_default_status=$?
if [ "$stale_default_status" -ne 0 ]; then ok; else bad "push accepted stale user defaultMode"; fi
case "$stale_default_out" in *"user settings"*) ok ;; *) bad "stale defaultMode push did not name the blocking source" ;; esac

cp "$REPO/settings.json" "$stale_push_home/settings.json"
jq '.permissions.disableBypassPermissionsMode = "disable"' "$stale_push_home/settings.json" >"$TMP/stale-user-bypass.json"
mv "$TMP/stale-user-bypass.json" "$stale_push_home/settings.json"
stale_user_bypass_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_user_bypass_status=$?
if [ "$stale_user_bypass_status" -ne 0 ]; then ok; else bad "push accepted bypass-disabled user policy"; fi
case "$stale_user_bypass_out" in *"user settings"*) ok ;; *) bad "bypass-disabled user push did not name the blocking source" ;; esac
cp "$REPO/settings.json" "$stale_push_home/settings.json"

# Push would copy an entry-less live deny over the canonical EnterPlanMode deny
# while it is still propagating; refuse and point at install. ExitPlanMode is
# not a substitute.
for plan_fixture in missing:'.permissions.deny -= ["EnterPlanMode"]' exit-only:'.permissions.deny = (.permissions.deny - ["EnterPlanMode"] + ["ExitPlanMode"])'; do
  jq "${plan_fixture#*:}" "$REPO/settings.json" >"$stale_push_home/settings.json"
  stale_plan_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
    CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_plan_status=$?
  if [ "$stale_plan_status" -ne 0 ]; then ok; else bad "push accepted user settings without the EnterPlanMode deny (${plan_fixture%%:*})"; fi
  case "$stale_plan_out" in
    *"user settings"*"EnterPlanMode"*"sync.sh install"*) ok ;;
    *) bad "EnterPlanMode push refusal (${plan_fixture%%:*}) did not name the source, the entry, and the install remedy:"$'\n'"$stale_plan_out" ;;
  esac
done
cp "$REPO/settings.json" "$stale_push_home/settings.json"

# The same clause stays out of the way when live carries the entry, and when
# the repo copy no longer has it (a deliberate removal). Driven through the
# guard function itself: a full push copies far more than this fixture owns.
push_guard_fns=$(sed -n '/^denies_enter_plan_mode() {/,/^}/p;/^guard_auto_mode_policy_for_push() {/,/^}/p' "$SYNC")
run_push_guard() {
  (
    H=$1 HERE=$2 MANAGED_LOCK=$stale_push_lock WIN=${3:-$stale_push_windows}
    eval "$push_guard_fns"
    guard_auto_mode_policy_for_push
  ) 2>&1
}
# Keep the existing Auto default negative beside the reverted acceptEdits case.
for default_edit in '.permissions.defaultMode = "auto"' 'del(.permissions.defaultMode)'; do
  jq "$default_edit" "$REPO/settings.json" >"$stale_push_home/settings.json"
  if default_guard_out=$(run_push_guard "$stale_push_home" "$REPO"); then
    bad "push guard accepted Auto/missing user defaultMode"
  else
    case "$default_guard_out" in *"user settings"*) ok ;; *) bad "default push refusal did not identify user settings:"$'\n'"$default_guard_out" ;; esac
  fi
done
cp "$REPO/settings.json" "$stale_push_home/settings.json"
if guard_ok_out=$(run_push_guard "$stale_push_home" "$REPO"); then
  ok
else
  bad "push guard refused live settings that carry the EnterPlanMode deny:"$'\n'"$guard_ok_out"
fi
removed_repo=$TMP/push-guard-removed-repo
removed_windows=$TMP/push-guard-removed-windows
mkdir -p "$removed_repo/windows-stub" "$TMP/push-guard-removed-home" "$removed_windows/.claude"
jq '.permissions.deny -= ["EnterPlanMode"]' "$REPO/settings.json" >"$removed_repo/settings.json"
cp "$removed_repo/settings.json" "$TMP/push-guard-removed-home/settings.json"
# A real entry-less Windows stub, not a missing one: a missing file fails
# closed the same way, so it cannot prove the Windows arm keys on canonical.
jq '.permissions.deny -= ["EnterPlanMode"]' "$REPO/windows-stub/settings.json" >"$removed_repo/windows-stub/settings.json"
cp "$removed_repo/windows-stub/settings.json" "$removed_windows/.claude/settings.json"
if guard_removed_out=$(run_push_guard "$TMP/push-guard-removed-home" "$removed_repo" "$removed_windows"); then
  ok
else
  bad "push guard refused a push after the EnterPlanMode deny was removed from the repo copy:"$'\n'"$guard_removed_out"
fi

jq 'del(.permissions.disableAutoMode)' "$stale_push_lock" >"$TMP/stale-managed.json"
mv "$TMP/stale-managed.json" "$stale_push_lock"
stale_managed_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_managed_status=$?
if [ "$stale_managed_status" -ne 0 ]; then ok; else bad "push accepted stale managed Auto-mode policy"; fi
case "$stale_managed_out" in *"managed settings"*) ok ;; *) bad "stale managed push did not name the blocking source" ;; esac

cp "$REPO/managed-settings.json" "$stale_push_lock"
jq '.permissions.disableBypassPermissionsMode = "disable"' "$stale_push_lock" >"$TMP/stale-managed-bypass.json"
mv "$TMP/stale-managed-bypass.json" "$stale_push_lock"
stale_managed_bypass_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_managed_bypass_status=$?
if [ "$stale_managed_bypass_status" -ne 0 ]; then ok; else bad "push accepted bypass-disabled managed policy"; fi
case "$stale_managed_bypass_out" in *"managed settings"*) ok ;; *) bad "bypass-disabled managed push did not name the blocking source" ;; esac

cp "$REPO/managed-settings.json" "$stale_push_lock"

jq 'del(.permissions.disableAutoMode)' "$stale_push_windows/.claude/settings.json" >"$TMP/stale-windows.json"
mv "$TMP/stale-windows.json" "$stale_push_windows/.claude/settings.json"
stale_windows_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_windows_status=$?
if [ "$stale_windows_status" -ne 0 ]; then ok; else bad "push accepted stale Windows Auto-mode policy"; fi
case "$stale_windows_out" in *"Windows settings"*) ok ;; *) bad "stale Windows push did not name the blocking source" ;; esac

cp "$REPO/windows-stub/settings.json" "$stale_push_windows/.claude/settings.json"
jq '.permissions.disableBypassPermissionsMode = "disable"' "$stale_push_windows/.claude/settings.json" >"$TMP/stale-windows-bypass.json"
mv "$TMP/stale-windows-bypass.json" "$stale_push_windows/.claude/settings.json"
stale_windows_bypass_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_windows_bypass_status=$?
if [ "$stale_windows_bypass_status" -ne 0 ]; then ok; else bad "push accepted bypass-disabled Windows policy"; fi
case "$stale_windows_bypass_out" in *"Windows settings"*) ok ;; *) bad "bypass-disabled Windows push did not name the blocking source" ;; esac

jq '.permissions.deny -= ["EnterPlanMode"]' "$REPO/windows-stub/settings.json" >"$stale_push_windows/.claude/settings.json"
stale_windows_plan_out=$(CLAUDE_HOME="$stale_push_home" CLAUDE_WINDOWS_HOME="$stale_push_windows" \
  CLAUDE_SYNC_MANAGED_LOCK="$stale_push_lock" "$SYNC" push 2>&1); stale_windows_plan_status=$?
if [ "$stale_windows_plan_status" -ne 0 ]; then ok; else bad "push accepted Windows settings without the EnterPlanMode deny"; fi
case "$stale_windows_plan_out" in
  *"Windows settings"*"EnterPlanMode"*"sync.sh install"*) ok ;;
  *) bad "Windows EnterPlanMode push refusal did not name the source, the entry, and the install remedy:"$'\n'"$stale_windows_plan_out" ;;
esac
cp "$REPO/windows-stub/settings.json" "$stale_push_windows/.claude/settings.json"
tracked_policy_after=$(sha256sum "$REPO/settings.json" "$REPO/managed-settings.json" "$REPO/windows-stub/settings.json")
if [ "$tracked_policy_before" = "$tracked_policy_after" ]; then ok; else bad "refused push changed tracked policy files"; fi

# -- direct runtime-env validation / fresh-seed paths ------------------------
# A standalone reconcile must create the requested harness home before it
# validates the mapped env-file target, then fail closed while leaving settings
# absent when that target is missing.
missing_runtime_home=$TMP/runtime-env-missing
missing_out=$(CLAUDE_HOME="$missing_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); missing_status=$?
if [ "$missing_status" -ne 0 ]; then ok; else bad "reconcile-runtime-env accepted a missing mapped CLAUDE_ENV_FILE target"; fi
if [ -d "$missing_runtime_home" ]; then ok; else bad "reconcile-runtime-env did not create CLAUDE_HOME before target validation"; fi
if [ ! -e "$missing_runtime_home/settings.json" ]; then ok; else bad "failed runtime-env validation wrote settings.json"; fi

# An env target must be sourceable. Directories, FIFOs, and symlinks to them
# must fail closed instead of being accepted by a broad existence check.
nonregular_runtime_home=$TMP/runtime-env-nonregular
mkdir -p "$nonregular_runtime_home/not-a-file"
ln -s "$nonregular_runtime_home/not-a-file" "$nonregular_runtime_home/claude-env.sh"
nonregular_out=$(CLAUDE_HOME="$nonregular_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); nonregular_status=$?
if [ "$nonregular_status" -ne 0 ]; then ok; else bad "reconcile-runtime-env accepted a non-regular CLAUDE_ENV_FILE target"; fi
if [ ! -e "$nonregular_runtime_home/settings.json" ]; then ok; else bad "non-regular runtime-env validation wrote settings.json"; fi

# A live settings symlink must never be followed or replaced: doing so makes a
# volatile runtime path an arbitrary-file write surface.
symlink_runtime_home=$TMP/runtime-env-symlink
mkdir -p "$symlink_runtime_home"
ln -s "$REPO/claude-env.sh" "$symlink_runtime_home/claude-env.sh"
printf '{"env":{"SYNC_SMOKE_KEEP":"target"}}\n' >"$TMP/settings-symlink-target.json"
cp "$TMP/settings-symlink-target.json" "$TMP/settings-symlink-before.json"
ln -s "$TMP/settings-symlink-target.json" "$symlink_runtime_home/settings.json"
symlink_out=$(CLAUDE_HOME="$symlink_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); symlink_status=$?
if [ "$symlink_status" -ne 0 ]; then ok; else bad "reconcile-runtime-env accepted a symlinked live settings.json"; fi
if [ -L "$symlink_runtime_home/settings.json" ] && cmp -s "$TMP/settings-symlink-target.json" "$TMP/settings-symlink-before.json"; then
  ok
else
  bad "failed symlink validation changed the settings link or its target"
fi

# Exercise reconcile_runtime_env's own fresh-settings branch (install normally
# seeds settings.json first). The portable live value must be this fixture's
# CLAUDE_HOME, never the template's literal $HOME/.claude spelling.
fresh_runtime_home=$TMP/runtime-env-fresh
mkdir -p "$fresh_runtime_home"
ln -s "$REPO/claude-env.sh" "$fresh_runtime_home/claude-env.sh"
ln -s "$REPO/mods" "$fresh_runtime_home/mods"
fresh_out=$(CLAUDE_HOME="$fresh_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); fresh_status=$?
if [ "$fresh_status" -eq 0 ]; then ok; else bad "fresh reconcile-runtime-env exited $fresh_status:"$'\n'"$fresh_out"; fi
if jq -e --arg home "$fresh_runtime_home" --arg repo "$REPO" --arg realhome "$HOME" '
    .env.CLAUDE_CODE_TOOL_MEMORY_LIMIT == "4G"
    and .env.CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP == "1"
    and .env.CLAUDE_ENV_FILE == ($home + "/claude-env.sh")
    and .env.WACLI_STORE_DIR == ($realhome + "/.local/state/wacli")
    and .env.PRO_GATE_ROUND_GUARD == "1"
    and .env.CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS == "50000"
    and .env.CLAUDE_CODE_PLUGIN_DIRS == ($home + "/mods/loop-breaker:" + $home + "/mods/agent-radar:" + $home + "/mods/read-ceiling-pager:" + $home + "/mods/reminder-diet:" + $home + "/mods/lookout:" + $home + "/mods/x-mcp-budget")
    and .permissions.disableAutoMode == "disable"
    and .permissions.defaultMode == "bypassPermissions"
    and .permissions.disableBypassPermissionsMode != "disable"
    and ([.permissions.deny[] | select(. == "EnterPlanMode")] | length) == 1
    and .modelSettings["claude-fable-5-1"].autoCompactWindow == 300000
    and .modelSettings["claude-opus-5-5"].autoCompactWindow == 300000
    and .modelSettings["claude-sonnet-5-5"].autoCompactWindow == 300000
    and .modelSettings["claude-sonnet-5"].autoCompactWindow == 300000
  ' "$fresh_runtime_home/settings.json" >/dev/null; then
  ok
else
  bad "fresh reconcile-runtime-env did not write the portable runtime policy"
fi
fresh_mode=$(stat -c '%a' "$fresh_runtime_home/settings.json" 2>/dev/null || echo MISSING)
if [ "$fresh_mode" = 600 ]; then ok; else bad "fresh runtime settings mode $fresh_mode, expected 600"; fi

# Stale and absent defaults adopt the fleet fallback without touching local policy.
for default_edit in '.permissions.defaultMode = "acceptEdits"' 'del(.permissions.defaultMode)'; do
  jq "$default_edit" "$fresh_runtime_home/settings.json" >"$TMP/default-input.json"
  cp "$TMP/default-input.json" "$fresh_runtime_home/settings.json"
  default_check=$(CLAUDE_HOME="$fresh_runtime_home" "$SYNC" check 2>&1)
  case "$default_check" in
    *"DRIFT: settings.json differs"*) ok ;;
    *) bad "check did not report stale/missing defaultMode" ;;
  esac
  default_out=$(CLAUDE_HOME="$fresh_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); default_status=$?
  if [ "$default_status" -eq 0 ] && jq -e '.permissions.defaultMode == "bypassPermissions"' "$fresh_runtime_home/settings.json" >/dev/null; then ok; else bad "stale/missing defaultMode did not migrate to bypassPermissions:"$'\n'"$default_out"; fi
  if cmp -s <(jq -S 'del(.permissions.defaultMode)' "$TMP/default-input.json") <(jq -S 'del(.permissions.defaultMode)' "$fresh_runtime_home/settings.json"); then ok; else bad "default migration changed unrelated settings"; fi
  cp "$fresh_runtime_home/settings.json" "$TMP/default-reconciled.json"
  default_backups=$(find "$fresh_runtime_home/backups" -name settings.json -type f | wc -l)
  default_again=$(CLAUDE_HOME="$fresh_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); default_again_status=$?
  if [ "$default_again_status" -eq 0 ] && cmp -s "$TMP/default-reconciled.json" "$fresh_runtime_home/settings.json" && [ "$default_backups" = "$(find "$fresh_runtime_home/backups" -name settings.json -type f | wc -l)" ]; then ok; else bad "default migration was not byte/backup idempotent:"$'\n'"$default_again"; fi
done
cp "$REPO/settings.json" "$TMP/canonical-before-bad-default.json"
for bad_default in '.permissions.defaultMode = "acceptEdits"' 'del(.permissions.defaultMode)'; do
  jq "$bad_default" "$TMP/canonical-before-bad-default.json" >"$REPO/settings.json"
  bad_default_out=$(CLAUDE_HOME="$fresh_runtime_home" "$SYNC" reconcile-runtime-env 2>&1); bad_default_status=$?
  if [ "$bad_default_status" -ne 0 ]; then ok; else bad "reconcile accepted bad canonical defaultMode"; fi
  case "$bad_default_out" in
    *"canonical settings defenses are missing or invalid"*) ok ;;
    *) bad "bad canonical default refusal did not diagnose defenses:"$'\n'"$bad_default_out" ;;
  esac
  if cmp -s "$TMP/default-reconciled.json" "$fresh_runtime_home/settings.json"; then ok; else bad "bad canonical default changed live settings"; fi
done
cp "$TMP/canonical-before-bad-default.json" "$REPO/settings.json"

# modelSettings is shared with the operator (dotfiles#1574): /autocompact and
# effort saves land there per model, and gateway routes get entries of their
# own. The canonical auto-compact windows must reach a live file that already
# carries such entries WITHOUT flattening them: a shallow object merge drops
# opus's effortLevel, and a wholesale replace drops the Codex-route entry.
merge_models_home=$TMP/runtime-env-merge-models
mkdir -p "$merge_models_home"
ln -s "$REPO/claude-env.sh" "$merge_models_home/claude-env.sh"
ln -s "$REPO/mods" "$merge_models_home/mods"
jq '.modelSettings = {
      "claude-opus-5-5": {"effortLevel": "xhigh"},
      "claude-bccf-route-codex-pool-astra": {"effortLevel": "xhigh"}
    }' "$REPO/settings.json" > "$merge_models_home/settings.json"
chmod 600 "$merge_models_home/settings.json"
merge_models_out=$(CLAUDE_HOME="$merge_models_home" "$SYNC" reconcile-runtime-env 2>&1); merge_models_status=$?
if [ "$merge_models_status" -eq 0 ]; then ok; else bad "merge reconcile-runtime-env over live modelSettings exited non-zero"; echo "  exit=$merge_models_status"$'\n'"$merge_models_out" >&2; fi
if jq -e '
    .modelSettings["claude-opus-5-5"].autoCompactWindow == 300000
    and .modelSettings["claude-opus-5-5"].effortLevel == "xhigh"
    and .modelSettings["claude-bccf-route-codex-pool-astra"].effortLevel == "xhigh"
    and (.modelSettings["claude-bccf-route-codex-pool-astra"] | has("autoCompactWindow") | not)
    and .modelSettings["claude-fable-5-1"].autoCompactWindow == 300000
    and .modelSettings["claude-sonnet-5-5"].autoCompactWindow == 300000
    and .modelSettings["claude-sonnet-5"].autoCompactWindow == 300000
  ' "$merge_models_home/settings.json" >/dev/null; then
  ok
else
  bad "merge reconcile did not deep-merge canonical modelSettings per model"
  echo "  live effortLevel and the Codex-route entry must survive and every canonical window must land; got: $(jq -c .modelSettings "$merge_models_home/settings.json" 2>/dev/null)" >&2
fi
# Parity: a TRACKED modelSettings entry that carries no window (an effort
# pin for some model, say) is not a window the fleet owns. Reconcile drops
# it from the projection, so check() must drop it too, or the live file would
# be DRIFT that no reconcile can clear. Same for a tracked `modelSettings: {}`:
# an empty projection is no key on either side (#1577 round 2).
cp "$REPO/settings.json" "$TMP/settings-canonical.before-nowindow"
jq '.modelSettings["claude-haiku-4-5"] = {effortLevel: "medium"}' "$TMP/settings-canonical.before-nowindow" > "$REPO/settings.json"
nowindow_out=$(CLAUDE_HOME="$merge_models_home" "$SYNC" reconcile-runtime-env 2>&1); nowindow_status=$?
if [ "$nowindow_status" -eq 0 ]; then ok; else bad "reconcile with a window-less canonical entry exited non-zero"; echo "  exit=$nowindow_status"$'\n'"$nowindow_out" >&2; fi
if jq -e '(.modelSettings | has("claude-haiku-4-5") | not)' "$merge_models_home/settings.json" >/dev/null; then ok; else bad "reconcile wrote a canonical entry that has no autoCompactWindow into the live file"; fi
nowindow_check=$(CLAUDE_HOME="$merge_models_home" "$SYNC" check 2>&1)
case "$nowindow_check" in
  *"DRIFT: settings.json differs"*) bad "check() reports DRIFT for a window-less canonical modelSettings entry that reconcile deliberately does not write" ;;
  *) ok ;;
esac
jq '.modelSettings = {}' "$TMP/settings-canonical.before-nowindow" > "$REPO/settings.json"
emptymap_check=$(CLAUDE_HOME="$merge_models_home" "$SYNC" check 2>&1)
case "$emptymap_check" in
  *"DRIFT: settings.json differs"*) bad "check() reports permanent DRIFT when the tracked modelSettings is an empty object" ;;
  *) ok ;;
esac
# The canonical window is range- and type-checked before anything is written
# (Claude Code accepts 100k to 1M; a string such as "300k" reads as 300 and
# clamps to the minimum). Each bad value must fail closed, leaving the live
# file as it was (#1577 ce-code-review, testing lens).
cp "$merge_models_home/settings.json" "$TMP/settings-live.before-badwindow"
for bad_window in '50000' '2000000' '"300k"' '300000.5'; do
  jq ".modelSettings[\"claude-fable-5-1\"].autoCompactWindow = $bad_window" "$TMP/settings-canonical.before-nowindow" > "$REPO/settings.json"
  badwindow_out=$(CLAUDE_HOME="$merge_models_home" "$SYNC" reconcile-runtime-env 2>&1); badwindow_status=$?
  if [ "$badwindow_status" -ne 0 ]; then ok; else bad "reconcile accepted an out-of-range or non-numeric canonical autoCompactWindow"; echo "  value=$bad_window"$'\n'"$badwindow_out" >&2; fi
  case "$badwindow_out" in
    *"canonical settings defenses are missing or invalid"*) ok ;;
    *) bad "bad-window refusal did not name the canonical defenses check"; echo "  value=$bad_window"$'\n'"$badwindow_out" >&2 ;;
  esac
  if cmp -s "$TMP/settings-live.before-badwindow" "$merge_models_home/settings.json"; then ok; else bad "a refused canonical window still changed the live settings.json"; fi
done
# A canonical modelSettings that is not an object of objects: reconcile
# refuses by the same check, and check() must say DRIFT rather than read
# the unreadable map as clean (#1577 ce-code-review cross-model lens, P1:
# a failed projection once emptied both sides of the comparison).
for bad_map in '"not-an-object"' '{"claude-fable-5-1": "garbage"}'; do
  jq ".modelSettings = $bad_map" "$TMP/settings-canonical.before-nowindow" > "$REPO/settings.json"
  badmap_out=$(CLAUDE_HOME="$merge_models_home" "$SYNC" reconcile-runtime-env 2>&1); badmap_status=$?
  if [ "$badmap_status" -ne 0 ]; then ok; else bad "reconcile accepted a canonical modelSettings that is not an object of objects"; echo "  value=$bad_map"$'\n'"$badmap_out" >&2; fi
  case "$badmap_out" in
    *"canonical settings defenses are missing or invalid"*) ok ;;
    *) bad "bad-map refusal did not name the canonical defenses check"; echo "  value=$bad_map"$'\n'"$badmap_out" >&2 ;;
  esac
  badmap_check=$(CLAUDE_HOME="$merge_models_home" "$SYNC" check 2>&1)
  case "$badmap_check" in
    *"DRIFT: settings.json canonical modelSettings is not an object"*) ok ;;
    *) bad "planted negative: check() read an unreadable canonical modelSettings as clean"; echo "  value=$bad_map" >&2 ;;
  esac
done
cp "$TMP/settings-canonical.before-nowindow" "$REPO/settings.json"
# A LIVE map or entry that is not an object (a hand edit) must not hold the
# whole runtime-policy reconcile back: it is replaced by the canonical value
# and the permission floor still lands (#1577 cross-model lens, P2).
for bad_live in '.modelSettings = "garbage"' '.modelSettings["claude-fable-5-1"] = "garbage"'; do
  jq "$bad_live" "$merge_models_home/settings.json" > "$merge_models_home/settings.json.tmp" \
    && mv "$merge_models_home/settings.json.tmp" "$merge_models_home/settings.json"
  badlive_out=$(CLAUDE_HOME="$merge_models_home" "$SYNC" reconcile-runtime-env 2>&1); badlive_status=$?
  if [ "$badlive_status" -eq 0 ]; then ok; else bad "reconcile aborted on a malformed LIVE modelSettings instead of replacing it"; echo "  edit=$bad_live"$'\n'"$badlive_out" >&2; fi
  if jq -e '
      .modelSettings["claude-fable-5-1"].autoCompactWindow == 300000
      and .modelSettings["claude-sonnet-5"].autoCompactWindow == 300000
      and .permissions.disableAutoMode == "disable"
    ' "$merge_models_home/settings.json" >/dev/null; then ok; else bad "reconcile over a malformed live modelSettings did not restore the canonical windows beside the permission floor"; fi
done
# check() must read that reconciled file as clean: the live-only fields and
# the live-only model are the operator's, not drift.
merge_models_check=$(CLAUDE_HOME="$merge_models_home" "$SYNC" check 2>&1)
case "$merge_models_check" in
  *"DRIFT: settings.json differs"*) bad "check() reports settings DRIFT on a reconciled live file whose modelSettings carry live-only effortLevel fields and a live-only model entry" ;;
  *) ok ;;
esac
# PLANTED NEGATIVE: a window missing from the live file IS drift, so the
# projection above cannot be an exclusion of the whole key.
jq 'del(.modelSettings["claude-fable-5-1"].autoCompactWindow)' "$merge_models_home/settings.json" > "$merge_models_home/settings.json.tmp" \
  && mv "$merge_models_home/settings.json.tmp" "$merge_models_home/settings.json"
missing_window_check=$(CLAUDE_HOME="$merge_models_home" "$SYNC" check 2>&1)
case "$missing_window_check" in
  *"DRIFT: settings.json differs"*) ok ;;
  *) bad "planted negative: a live modelSettings entry missing its canonical autoCompactWindow was NOT reported as settings DRIFT" ;;
esac
# A window the operator saved with /autocompact for a model the canonical
# names is the one value this reconcile owns: it is DRIFT until reconciled,
# and reconcile restores the canonical window while leaving the operator's
# other fields on that entry alone (#1577 review, P2: the override is a
# documented ownership rule, not a silent side effect).
jq '.modelSettings["claude-fable-5-1"] = {autoCompactWindow: 500000, effortLevel: "high"}' "$merge_models_home/settings.json" > "$merge_models_home/settings.json.tmp" \
  && mv "$merge_models_home/settings.json.tmp" "$merge_models_home/settings.json"
saved_window_check=$(CLAUDE_HOME="$merge_models_home" "$SYNC" check 2>&1)
case "$saved_window_check" in
  *"DRIFT: settings.json differs"*) ok ;;
  *) bad "an operator-saved window on a canonical model was NOT reported as settings DRIFT" ;;
esac
saved_window_out=$(CLAUDE_HOME="$merge_models_home" "$SYNC" reconcile-runtime-env 2>&1); saved_window_status=$?
if [ "$saved_window_status" -eq 0 ]; then ok; else bad "reconcile over an operator-saved window exited non-zero"; echo "  exit=$saved_window_status"$'\n'"$saved_window_out" >&2; fi
if jq -e '
    .modelSettings["claude-fable-5-1"].autoCompactWindow == 300000
    and .modelSettings["claude-fable-5-1"].effortLevel == "high"
  ' "$merge_models_home/settings.json" >/dev/null; then
  ok
else
  bad "reconcile did not restore the canonical window while keeping the operator's effortLevel on the same entry"
  echo "  got: $(jq -c '.modelSettings["claude-fable-5-1"]' "$merge_models_home/settings.json" 2>/dev/null)" >&2
fi

# check()'s canonical side is lib/settings-seed.js with every key kept and the
# private overlay merged, and both sides are normalized: `$HOME/` rendered in
# hook commands and permission rules, hook groups sorted, empty events dropped.
# Each tolerance has a planted negative beside it, so normalization cannot be
# hiding a real difference.
sn_home=$TMP/settings-normal-home
mkdir -p "$sn_home"
ln -s "$REPO/claude-env.sh" "$sn_home/claude-env.sh"
ln -s "$REPO/mods" "$sn_home/mods"
sn_out=$(CLAUDE_HOME="$sn_home" "$SYNC" reconcile-runtime-env 2>&1) || bad "settings-normal fixture: reconcile-runtime-env failed:"$'\n'"$sn_out"
cp "$sn_home/settings.json" "$TMP/settings-normal-base.json"
sn_reset() { cp "$TMP/settings-normal-base.json" "$sn_home/settings.json"; }
sn_edit() { jq "$@" "$sn_home/settings.json" > "$sn_home/settings.json.tmp" && mv "$sn_home/settings.json.tmp" "$sn_home/settings.json"; }
# The settings line of `sync.sh check`, with the overlay directory given (an
# absent one means no overlay).
sn_check() { CLAUDE_HOME="$sn_home" HOV_STACK_OVERLAY="${1:-$TMP/settings-normal-no-overlay}" "$SYNC" check 2>&1 | grep -F 'settings.json' || true; }
sn_expect_clean() {
  local line; line=$(sn_check "${2:-}")
  case "$line" in *"DRIFT: settings.json"*) bad "$1 was reported as settings DRIFT: $line" ;; *) ok ;; esac
}
sn_expect_drift() {
  local line; line=$(sn_check "${3:-}")
  case "$line" in *"DRIFT: settings.json differs"*" in: "*"$2"*) ok ;; *) bad "$1 was not reported as settings DRIFT naming $2: ${line:-<no settings line>}" ;; esac
}
sn_expect_clean "a freshly reconciled live file"
# A rule the overlay adds, spelled with the template's `$HOME/`.
sn_ov=$TMP/settings-normal-overlay
mkdir -p "$sn_ov"
printf '%s\n' '{"permissions":{"allow":["Bash($HOME/planted/bin/tool:*)"]}}' > "$sn_ov/settings.json"
sn_expect_drift "an overlay allow rule missing from live" permissions "$sn_ov"
sn_edit --arg rule "Bash($HOME/planted/bin/tool:*)" '.permissions.allow += [$rule]'
sn_expect_clean "the overlay rule in live, rendered as setup writes it" "$sn_ov"
sn_reset
sn_edit '.permissions.allow += ["Bash($HOME/planted/bin/tool:*)"]'
sn_expect_clean "the overlay rule in live, in the template spelling sync.sh install copies" "$sn_ov"
sn_reset
# Hook order and spelling: groups run in parallel, and `$HOME/.claude` in a
# command is the config dir.
sn_edit '.hooks.PreToolUse |= reverse'
sn_expect_clean "reversed PreToolUse hook groups"
sn_reset
if jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("$HOME/.claude")' "$sn_home/settings.json" >/dev/null; then ok; else bad "settings-normal fixture: the first PreToolUse command no longer carries \$HOME/.claude, so the rendering case below tests nothing"; fi
sn_edit --arg cfg "$sn_home" '(.hooks.PreToolUse[0].hooks[0].command) |= (split("$HOME/.claude") | join($cfg))'
sn_expect_clean "a hook command with \$HOME/.claude rendered to the config dir"
sn_reset
if jq -e '.hooks | has("Notification") | not' "$sn_home/settings.json" >/dev/null; then ok; else bad "settings-normal fixture: live already has a Notification event, so the empty-event case below tests nothing"; fi
sn_edit '.hooks.Notification = []'
sn_expect_clean "an event with an empty hook list"
sn_reset
# PLANTED NEGATIVES: a different hook, a changed key the seed's allow-list
# leaves out (so the canonical side must keep every key), and an overlay
# that cannot be merged.
sn_edit '(.hooks.PreToolUse[0].hooks[0].command) |= . + " --planted"'
sn_expect_drift "a changed hook command" hooks
sn_reset
sn_edit '.advisorModel = "planted-model"'
sn_expect_drift "a changed live advisorModel" advisorModel
sn_reset
sn_bad_ov=$TMP/settings-normal-bad-overlay
mkdir -p "$sn_bad_ov"
printf '[]\n' > "$sn_bad_ov/settings.json"
sn_line=$(sn_check "$sn_bad_ov")
case "$sn_line" in
  *"DRIFT: settings.json canonical copy could not be built with the overlay"*"is not a JSON object"*) ok ;;
  *) bad "an overlay that is not a JSON object did not stop the comparison with the builder's reason: ${sn_line:-<no settings line>}" ;;
esac

# A CLAUDE_CODE_PLUGIN_DIRS entry whose folder has no plugin manifest must fail
# closed before anything is written: the engine would log a failed load in
# every session, and nothing else would say why. Only the manifest is moved
# aside, so the refusal can come from the manifest test alone, never from a
# missing folder. The fresh case above is the planted pair: the same folder
# with its manifest present reconciles.
missing_mod_home=$TMP/runtime-env-missing-mod
mkdir -p "$missing_mod_home"
ln -s "$REPO/claude-env.sh" "$missing_mod_home/claude-env.sh"
ln -s "$REPO/mods" "$missing_mod_home/mods"
mv "$REPO/mods/agent-radar/.claude-plugin/plugin.json" "$TMP/agent-radar.plugin.json.aside"
missing_mod_out=$(CLAUDE_HOME="$missing_mod_home" "$SYNC" reconcile-runtime-env 2>&1); missing_mod_status=$?
mv "$TMP/agent-radar.plugin.json.aside" "$REPO/mods/agent-radar/.claude-plugin/plugin.json"
if [ "$missing_mod_status" -ne 0 ]; then ok; else bad "reconcile-runtime-env accepted a CLAUDE_CODE_PLUGIN_DIRS folder with no plugin manifest"; fi
case "$missing_mod_out" in
  *"CLAUDE_CODE_PLUGIN_DIRS"*"agent-radar"*"plugin.json"*) ok ;;
  *) bad "missing-mod refusal did not name the key, the folder and the manifest:"$'\n'"$missing_mod_out" ;;
esac
if [ ! -e "$missing_mod_home/settings.json" ]; then ok; else bad "failed mod-folder validation wrote settings.json"; fi

# A list the harness cannot read as written is refused, not silently shortened:
# a trailing colon would otherwise drop an entry in the split and write a
# shorter list that check() then projects the same way, so nothing would say.
malformed_mod_home=$TMP/runtime-env-malformed-mods
mkdir -p "$malformed_mod_home"
ln -s "$REPO/claude-env.sh" "$malformed_mod_home/claude-env.sh"
ln -s "$REPO/mods" "$malformed_mod_home/mods"
cp "$REPO/settings.json" "$TMP/settings-canonical.before-malformed"
jq '.env.CLAUDE_CODE_PLUGIN_DIRS += ":"' "$TMP/settings-canonical.before-malformed" > "$REPO/settings.json"
malformed_mod_out=$(CLAUDE_HOME="$malformed_mod_home" "$SYNC" reconcile-runtime-env 2>&1); malformed_mod_status=$?
cp "$TMP/settings-canonical.before-malformed" "$REPO/settings.json"
if [ "$malformed_mod_status" -ne 0 ]; then ok; else bad "reconcile-runtime-env accepted a CLAUDE_CODE_PLUGIN_DIRS list with a trailing colon"; fi
case "$malformed_mod_out" in
  *"CLAUDE_CODE_PLUGIN_DIRS"*"empty entry"*) ok ;;
  *) bad "malformed-list refusal did not name the key and the empty entry:"$'\n'"$malformed_mod_out" ;;
esac
if [ ! -e "$malformed_mod_home/settings.json" ]; then ok; else bad "failed malformed-list validation wrote settings.json"; fi

# An embedded newline is the same defect in a worse shape: the here-string read
# behind the split stops at the first line, so "a\nb" would validate on "a"
# alone and reconcile would write a one-entry list that loads only the first
# mod, with check() projecting the same truncated string. The first line here
# is a valid entry whose folder has a manifest, so only the refusal of the
# control character keeps the shortened list from being written.
multiline_mod_home=$TMP/runtime-env-multiline-mods
mkdir -p "$multiline_mod_home"
ln -s "$REPO/claude-env.sh" "$multiline_mod_home/claude-env.sh"
ln -s "$REPO/mods" "$multiline_mod_home/mods"
cp "$REPO/settings.json" "$TMP/settings-canonical.before-multiline"
jq '.env.CLAUDE_CODE_PLUGIN_DIRS |= (split(":") | .[0] + "\n" + .[1])' "$TMP/settings-canonical.before-multiline" > "$REPO/settings.json"
multiline_mod_out=$(CLAUDE_HOME="$multiline_mod_home" "$SYNC" reconcile-runtime-env 2>&1); multiline_mod_status=$?
cp "$TMP/settings-canonical.before-multiline" "$REPO/settings.json"
if [ "$multiline_mod_status" -ne 0 ]; then ok; else bad "reconcile-runtime-env accepted a CLAUDE_CODE_PLUGIN_DIRS list with an embedded newline"; fi
case "$multiline_mod_out" in
  *"CLAUDE_CODE_PLUGIN_DIRS"*"control character"*) ok ;;
  *) bad "multiline-list refusal did not name the key and the control character:"$'\n'"$multiline_mod_out" ;;
esac
if [ ! -e "$multiline_mod_home/settings.json" ]; then ok; else bad "failed multiline-list validation wrote settings.json; its list (a truncated one loads only the first mod): $(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS' "$multiline_mod_home/settings.json")"; fi

# Retiring the mod list is a supported edit: a canonical copy that drops the
# key must reconcile, and the live list must be cleared rather than preserved
# (a stale live list would keep loading mods the repo retired). The same home
# with the key present reconciles in the fresh case above.
removed_mod_home=$TMP/runtime-env-removed-mods
mkdir -p "$removed_mod_home"
ln -s "$REPO/claude-env.sh" "$removed_mod_home/claude-env.sh"
ln -s "$REPO/mods" "$removed_mod_home/mods"
cp "$fresh_runtime_home/settings.json" "$removed_mod_home/settings.json"
chmod 0600 "$removed_mod_home/settings.json"
cp "$REPO/settings.json" "$TMP/settings-canonical.before-removed"
jq 'del(.env.CLAUDE_CODE_PLUGIN_DIRS)' "$TMP/settings-canonical.before-removed" > "$REPO/settings.json"
removed_mod_out=$(CLAUDE_HOME="$removed_mod_home" "$SYNC" reconcile-runtime-env 2>&1); removed_mod_status=$?
cp "$TMP/settings-canonical.before-removed" "$REPO/settings.json"
if [ "$removed_mod_status" -eq 0 ]; then ok; else bad "reconcile-runtime-env refused a canonical copy that dropped CLAUDE_CODE_PLUGIN_DIRS:"$'\n'"$removed_mod_out"; fi
if jq -e '(.env | has("CLAUDE_CODE_PLUGIN_DIRS") | not) and .env.CLAUDE_ENV_FILE != null' "$removed_mod_home/settings.json" >/dev/null; then ok; else bad "reconcile-runtime-env left the retired live CLAUDE_CODE_PLUGIN_DIRS in place"; fi

# -- the EnterPlanMode deny union keeps live deny intact ----------------------
# reconcile_runtime_env appends the canonical bare-name EnterPlanMode deny only
# when live lacks it: no re-sort, no second copy, no dropped live entry. A live
# deny that is not an array is refused untouched, and a canonical file without
# the entry leaves live deny alone (removal must not break install).
plan_mode_home() {
  local home=$TMP/plan-mode-$1
  mkdir -p "$home"
  ln -s "$REPO/claude-env.sh" "$home/claude-env.sh"
  ln -s "$REPO/mods" "$home/mods"
  printf '%s\n' "$2" >"$home/settings.json"
  chmod 0600 "$home/settings.json"
  printf '%s' "$home"
}

mid_home=$(plan_mode_home mid '{"permissions":{"deny":["Bash(a:*)","EnterPlanMode","Bash(b:*)"]}}')
mid_out=$(CLAUDE_HOME="$mid_home" "$SYNC" reconcile-runtime-env 2>&1); mid_status=$?
if [ "$mid_status" -eq 0 ] && jq -e '.permissions.deny == ["Bash(a:*)","EnterPlanMode","Bash(b:*)"]' "$mid_home/settings.json" >/dev/null; then
  ok
else
  bad "reconcile-runtime-env moved or duplicated an EnterPlanMode deny already present mid-array:"$'\n'"$mid_out"
fi

for shape in empty:'{}' nodeny:'{"permissions":{"allow":["Read"]}}'; do
  shape_home=$(plan_mode_home "${shape%%:*}" "${shape#*:}")
  shape_out=$(CLAUDE_HOME="$shape_home" "$SYNC" reconcile-runtime-env 2>&1); shape_status=$?
  if [ "$shape_status" -eq 0 ] && jq -e '
      .permissions.deny == ["EnterPlanMode"]
      and .permissions.disableAutoMode == "disable"
      and ((.permissions.allow // ["Read"]) == ["Read"])
    ' "$shape_home/settings.json" >/dev/null; then
    ok
  else
    bad "reconcile-runtime-env did not create the EnterPlanMode deny for live settings shaped ${shape%%:*}:"$'\n'"$shape_out"
  fi
done

for shape in string:'{"permissions":{"deny":"EnterPlanMode"}}' object:'{"permissions":{"deny":{"EnterPlanMode":true}}}'; do
  shape_home=$(plan_mode_home "bad-${shape%%:*}" "${shape#*:}")
  cp "$shape_home/settings.json" "$TMP/plan-mode-bad-before.json"
  shape_out=$(CLAUDE_HOME="$shape_home" "$SYNC" reconcile-runtime-env 2>&1); shape_status=$?
  if [ "$shape_status" -ne 0 ] && cmp -s "$shape_home/settings.json" "$TMP/plan-mode-bad-before.json"; then
    ok
  else
    bad "reconcile-runtime-env accepted or rewrote a ${shape%%:*} permissions.deny:"$'\n'"$shape_out"
  fi
done

cp "$REPO/settings.json" "$TMP/canonical-settings-with-plan-deny.json"
jq '.permissions.deny -= ["EnterPlanMode"]' "$TMP/canonical-settings-with-plan-deny.json" >"$REPO/settings.json"
removed_home=$(plan_mode_home removed '{"permissions":{"deny":["Bash(a:*)"]}}')
removed_out=$(CLAUDE_HOME="$removed_home" "$SYNC" reconcile-runtime-env 2>&1); removed_status=$?
cp "$TMP/canonical-settings-with-plan-deny.json" "$REPO/settings.json"
if [ "$removed_status" -eq 0 ] && jq -e '
    .permissions.deny == ["Bash(a:*)"]
    and .permissions.disableAutoMode == "disable"
    and .env.CLAUDE_CODE_TOOL_MEMORY_LIMIT == "4G"
  ' "$removed_home/settings.json" >/dev/null; then
  ok
else
  bad "canonical settings without the EnterPlanMode deny broke reconcile or still changed live deny:"$'\n'"$removed_out"
fi

# -- a canonical file that loses the reap opt-out fails closed ---------------
# reconcile_runtime_env projects the key and validates it as a non-empty
# string, so a canonical copy that dropped it must refuse to touch live
# (dotfiles#1442). Same contract as PRO_GATE_ROUND_GUARD; this is the first
# fixture that exercises that branch for any of the portable env keys.
jq 'del(.env.CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP)' "$TMP/canonical-settings-with-plan-deny.json" >"$REPO/settings.json"
noreap_home=$(plan_mode_home noreap '{"env":{"SYNC_SMOKE_KEEP":"present"},"permissions":{"deny":["Bash(a:*)"]}}')
cp "$noreap_home/settings.json" "$TMP/noreap-before.json"
noreap_out=$(CLAUDE_HOME="$noreap_home" "$SYNC" reconcile-runtime-env 2>&1); noreap_status=$?
cp "$TMP/canonical-settings-with-plan-deny.json" "$REPO/settings.json"
if [ "$noreap_status" -ne 0 ] && cmp -s "$noreap_home/settings.json" "$TMP/noreap-before.json"; then
  ok
else
  bad "canonical settings without CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP did not fail closed (status $noreap_status):"$'\n'"$noreap_out"
fi

# -- Windows break-glass settings carry the same EnterPlanMode deny ----------
# Auto mode already off must not short-circuit the deny union; Windows-local
# keys survive; a second run and an already-reconciled file write nothing.
win_plan_fixture() {
  local root=$TMP/win-plan-$1
  mkdir -p "$root/claude-home" "$root/windows/.claude"
  printf '%s' "$root"
}
run_win_reconcile() {
  CLAUDE_HOME="$1/claude-home" CLAUDE_WINDOWS_HOME="$1/windows" "$SYNC" reconcile-windows-auto-mode 2>&1
}
win_backups() { find "$1/claude-home" -path '*/backups/*' -type f -name settings.json 2>/dev/null | wc -l; }

win_auto=$(win_plan_fixture auto-set)
jq '.permissions.deny = ["Bash(win-local:*)"] | .winLocalKeep = true' \
  "$REPO/windows-stub/settings.json" >"$win_auto/windows/.claude/settings.json"
win_auto_out=$(run_win_reconcile "$win_auto"); win_auto_status=$?
if [ "$win_auto_status" -eq 0 ] && jq -e '
    .permissions.deny == ["Bash(win-local:*)","EnterPlanMode"]
    and .permissions.disableAutoMode == "disable"
    and .winLocalKeep == true
  ' "$win_auto/windows/.claude/settings.json" >/dev/null; then
  ok
else
  bad "Windows reconcile skipped or mangled the EnterPlanMode deny when Auto mode was already off:"$'\n'"$win_auto_out"
fi
win_auto_backups=$(win_backups "$win_auto")
win_auto_again=$(run_win_reconcile "$win_auto")
if grep -Fq 'already reconciled' <<<"$win_auto_again" \
   && [ "$win_auto_backups" = "$(win_backups "$win_auto")" ] \
   && jq -e '([.permissions.deny[] | select(. == "EnterPlanMode")] | length) == 1' "$win_auto/windows/.claude/settings.json" >/dev/null; then
  ok
else
  bad "Windows reconcile was not idempotent on a second run:"$'\n'"$win_auto_again"
fi

win_seed=$(win_plan_fixture seed)
win_seed_out=$(run_win_reconcile "$win_seed"); win_seed_status=$?
if [ "$win_seed_status" -eq 0 ] \
   && jq -e '([.permissions.deny[] | select(. == "EnterPlanMode")] | length) == 1' "$win_seed/windows/.claude/settings.json" >/dev/null; then
  ok
else
  bad "a seeded Windows settings.json lacks the EnterPlanMode deny:"$'\n'"$win_seed_out"
fi

win_done=$(win_plan_fixture done)
cp "$REPO/windows-stub/settings.json" "$win_done/windows/.claude/settings.json"
win_done_out=$(run_win_reconcile "$win_done")
if grep -Fq 'already reconciled' <<<"$win_done_out" && [ "$(win_backups "$win_done")" = 0 ]; then
  ok
else
  bad "Windows reconcile rewrote settings that already carry both policies:"$'\n'"$win_done_out"
fi

win_bad=$(win_plan_fixture bad-deny)
jq '.permissions.deny = "EnterPlanMode"' "$REPO/windows-stub/settings.json" >"$win_bad/windows/.claude/settings.json"
cp "$win_bad/windows/.claude/settings.json" "$TMP/win-plan-bad-before.json"
win_bad_out=$(run_win_reconcile "$win_bad"); win_bad_status=$?
if [ "$win_bad_status" -ne 0 ] && cmp -s "$win_bad/windows/.claude/settings.json" "$TMP/win-plan-bad-before.json"; then
  ok
else
  bad "Windows reconcile accepted or rewrote a non-array permissions.deny:"$'\n'"$win_bad_out"
fi

cp "$REPO/windows-stub/settings.json" "$TMP/windows-stub-with-plan-deny.json"
jq '.permissions.deny -= ["EnterPlanMode"]' "$TMP/windows-stub-with-plan-deny.json" >"$REPO/windows-stub/settings.json"
win_removed=$(win_plan_fixture removed)
jq '.permissions.deny = ["Bash(win-local:*)"] | del(.permissions.disableAutoMode)' \
  "$REPO/windows-stub/settings.json" >"$win_removed/windows/.claude/settings.json"
win_removed_out=$(run_win_reconcile "$win_removed"); win_removed_status=$?
cp "$TMP/windows-stub-with-plan-deny.json" "$REPO/windows-stub/settings.json"
if [ "$win_removed_status" -eq 0 ] && jq -e '
    .permissions.deny == ["Bash(win-local:*)"]
    and .permissions.disableAutoMode == "disable"
  ' "$win_removed/windows/.claude/settings.json" >/dev/null; then
  ok
else
  bad "Windows canonical without the EnterPlanMode deny broke reconcile or still changed live deny:"$'\n'"$win_removed_out"
fi

win_gone_out=$(CLAUDE_HOME="$TMP/win-plan-gone-home" CLAUDE_WINDOWS_HOME="$TMP/win-plan-gone" "$SYNC" reconcile-windows-auto-mode 2>&1); win_gone_status=$?
if [ "$win_gone_status" -eq 0 ] && grep -Fq 'skipped Windows Auto-mode policy' <<<"$win_gone_out" && [ ! -e "$TMP/win-plan-gone" ]; then
  ok
else
  bad "Windows reconcile did not skip an absent Windows home:"$'\n'"$win_gone_out"
fi

# -- The tracked WhatsApp guard command runs the deployed guard ----------------
# The tracked settings.json spells the guard with the runtime $HOME, so account
# authority is never published beside a missing hook. Run that exact command,
# as the hook runner would, from a home whose hooks are this checkout's.
fresh_whatsapp_root=$TMP/whatsapp-hook-runtime
mkdir -p "$fresh_whatsapp_root/.claude"
ln -s "$REPO/hooks" "$fresh_whatsapp_root/.claude/hooks"
fresh_whatsapp_command=$(jq -r '
  [.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("whatsapp-guard.js")) | .command]
  | if length == 1 then .[0] else empty end
' "$REPO/settings.json")
if [ -n "$fresh_whatsapp_command" ]; then ok; else bad "the tracked settings.json does not register the WhatsApp guard exactly once"; fi
# A non-wacli Bash call is a no-op for this guard: quiet pass-through means
# exit 0 and empty stdout (issue #1339), not an echo of the probe input --
# exit 0 with a crashed/MODULE_NOT_FOUND hook's empty stdout would otherwise
# satisfy this the same way, so status is asserted explicitly too.
fresh_whatsapp_probe='{"tool_name":"Bash","tool_input":{"command":"printf no-whatsapp"}}'
fresh_whatsapp_probe_out=$(printf '%s' "$fresh_whatsapp_probe" | \
  HOME="$fresh_whatsapp_root" /usr/bin/bash -c "$fresh_whatsapp_command"); fresh_whatsapp_probe_status=$?
if [ "$fresh_whatsapp_probe_status" -eq 0 ] && [ -z "$fresh_whatsapp_probe_out" ]; then
  ok
else
  bad "runtime-home WhatsApp hook command did not quietly pass through a non-wacli call (status $fresh_whatsapp_probe_status):"$'\n'"$fresh_whatsapp_probe_out"
fi
# A quiet pass-through alone cannot prove the runtime-home command executed
# the DEPLOYED guard -- a bare `true` would satisfy it too. Prove it with an
# input the guard actually denies: a wacli call carrying a process
# substitution, which the permission dialog cannot resolve to a literal
# payload (mirrors whatsapp-guard.test.js's shell-expansion deny suite).
fresh_whatsapp_deny_probe='{"tool_name":"Bash","tool_input":{"command":"wacli send file --to Alice --file <(printf data)"}}'
fresh_whatsapp_deny_probe_out=$(printf '%s' "$fresh_whatsapp_deny_probe" | \
  HOME="$fresh_whatsapp_root" /usr/bin/bash -c "$fresh_whatsapp_command"); fresh_whatsapp_deny_probe_status=$?
if [ "$fresh_whatsapp_deny_probe_status" -eq 0 ] \
   && printf '%s' "$fresh_whatsapp_deny_probe_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  ok
else
  bad "runtime-home WhatsApp hook command did not deny a shell-expanded wacli call (status $fresh_whatsapp_deny_probe_status):"$'\n'"$fresh_whatsapp_deny_probe_out"
fi

# -- StructuredOutput unwrap: the papercut plugin registers it, sync.sh does not
# The papercut plugin (papercut@hov) registers structured-output-unwrap and
# read-ceiling-chunk itself, so on a fresh host without it the reconcile exits 0
# and writes nothing (tests/papercut-plugin-reconcile.test.sh covers retiring a
# settings copy once the plugin is enabled). The hook must still quietly pass a
# non-StructuredOutput call through (empty stdout, exit 0 -- issue #1339).
fresh_unwrap_root=$TMP/unwrap-hook-fresh
fresh_unwrap_home=$fresh_unwrap_root/.claude
mkdir -p "$fresh_unwrap_home"
ln -s "$REPO/hooks" "$fresh_unwrap_home/hooks"
fresh_unwrap_out=$(env -u CLAUDE_INSTALLED_PLUGINS HOME="$fresh_unwrap_root" CLAUDE_HOME="$fresh_unwrap_home" "$SYNC" reconcile-structured-output-unwrap 2>&1); fresh_unwrap_status=$?
if [ "$fresh_unwrap_status" -eq 0 ]; then ok; else bad "fresh reconcile-structured-output-unwrap exited $fresh_unwrap_status:"$'\n'"$fresh_unwrap_out"; fi
if [ ! -e "$fresh_unwrap_home/settings.json" ]; then
  ok
else
  bad "fresh reconcile-structured-output-unwrap wrote a settings.json; the papercut plugin registers that hook"
fi
fresh_unwrap_probe='{"tool_name":"Bash","tool_input":{"command":"printf no-unwrap"}}'
fresh_unwrap_probe_out=$(printf '%s' "$fresh_unwrap_probe" | node "$REPO/hooks/PreToolUse/structured-output-unwrap.js"); fresh_unwrap_probe_status=$?
if [ "$fresh_unwrap_probe_status" -eq 0 ] && [ -z "$fresh_unwrap_probe_out" ]; then
  ok
else
  bad "structured-output-unwrap did not quietly pass a non-StructuredOutput call through (status $fresh_unwrap_probe_status):"$'\n'"$fresh_unwrap_probe_out"
fi

# -- Read ceiling chunk: the papercut plugin registers it, sync.sh does not -----
fresh_chunk_root=$TMP/chunk-hook-fresh
fresh_chunk_home=$fresh_chunk_root/.claude
mkdir -p "$fresh_chunk_home"
ln -s "$REPO/hooks" "$fresh_chunk_home/hooks"
fresh_chunk_out=$(env -u CLAUDE_INSTALLED_PLUGINS HOME="$fresh_chunk_root" CLAUDE_HOME="$fresh_chunk_home" "$SYNC" reconcile-read-ceiling-chunk 2>&1); fresh_chunk_status=$?
if [ "$fresh_chunk_status" -eq 0 ]; then ok; else bad "fresh reconcile-read-ceiling-chunk exited $fresh_chunk_status:"$'\n'"$fresh_chunk_out"; fi
if [ ! -e "$fresh_chunk_home/settings.json" ]; then
  ok
else
  bad "fresh reconcile-read-ceiling-chunk wrote a settings.json; the papercut plugin registers that hook"
fi
fresh_chunk_probe='{"tool_name":"Read","tool_input":{"file_path":"/nonexistent/first-attempt.txt"},"session_id":"s-fresh0000","cwd":"/tmp"}'
fresh_chunk_probe_out=$(printf '%s' "$fresh_chunk_probe" | PAPERCUT_STORE="$TMP/chunk-empty-store" node "$REPO/hooks/PreToolUse/read-ceiling-chunk.js"); fresh_chunk_probe_status=$?
if [ "$fresh_chunk_probe_status" -eq 0 ] && [ -z "$fresh_chunk_probe_out" ]; then
  ok
else
  bad "read-ceiling-chunk rewrote a first attempt with no recorded failure (status $fresh_chunk_probe_status):"$'\n'"$fresh_chunk_probe_out"
fi

# -- Shape rewrite passes a non-isolated call through ---------------------------
# A non-isolated call (cwd carries no .claude/worktrees/ segment) is outside
# what this hook ever rewrites, so it must quietly pass through (empty
# stdout, exit 0 -- issue #1339; no longer a byte-for-byte echo).
fresh_shape_probe='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"s-fresh0000","cwd":"/tmp"}'
fresh_shape_probe_out=$(printf '%s' "$fresh_shape_probe" | PAPERCUT_STORE="$TMP/shape-empty-store" node "$REPO/hooks/PreToolUse/shape-rewrite.js"); fresh_shape_probe_status=$?
if [ "$fresh_shape_probe_status" -eq 0 ] && [ -z "$fresh_shape_probe_out" ]; then
  ok
else
  bad "shape-rewrite rewrote a non-isolated call with no worktree cwd (status $fresh_shape_probe_status):"$'\n'"$fresh_shape_probe_out"
fi

# -- pr-record registration is retired ----------------------------------------
# The PostToolUse pr-record hook wrote session->PR rows for the Stop hook's
# hand-back check, retired 2026-11-03 without ever leaving shadow mode.
# reconcile now only removes the registration, in either spelling; the tracked
# settings.json no longer carries it, and a fresh host must not get it seeded.
echo "=== pr-record hook retire ===" >&2
PR_RECORD_COMMAND='"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PostToolUse/pr-record.js"'
if ! grep -qF 'PostToolUse/pr-record.js' "$REPO/settings.json"; then ok; else bad "the tracked settings.json still registers the retired pr-record hook"; fi
fresh_prrec_root=$TMP/pr-record-hook-fresh
fresh_prrec_home=$fresh_prrec_root/.claude
mkdir -p "$fresh_prrec_home"
ln -s "$REPO/hooks" "$fresh_prrec_home/hooks"
fresh_prrec_out=$(HOME="$fresh_prrec_root" CLAUDE_HOME="$fresh_prrec_home" "$SYNC" reconcile-pr-record-hook 2>&1); fresh_prrec_status=$?
if [ "$fresh_prrec_status" -eq 0 ]; then ok; else bad "fresh reconcile-pr-record-hook exited $fresh_prrec_status:"$'\n'"$fresh_prrec_out"; fi
if [ ! -f "$fresh_prrec_home/settings.json" ] || ! jq -e --arg c "$PR_RECORD_COMMAND" '
    [.hooks[]?[]?.hooks[]? | .command] | index($c) != null
  ' "$fresh_prrec_home/settings.json" >/dev/null; then
  ok
else
  bad "fresh reconcile-pr-record-hook registered the retired hook"
fi
PRREC_RECON_ROOT=$TMP/pr-record-recon-existing
PRREC_RECON_HOME=$PRREC_RECON_ROOT/.claude
mkdir -p "$PRREC_RECON_HOME"
ln -s "$REPO/hooks" "$PRREC_RECON_HOME/hooks"
prrec_rendered_cmd="node \"$PRREC_RECON_HOME/hooks/PostToolUse/pr-record.js\""
jq -n --arg rec "$PR_RECORD_COMMAND" --arg rendered "$prrec_rendered_cmd" '
  {hooks:{PostToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$rec,timeout:10}]},
    {matcher:"Bash",hooks:[{type:"command",command:$rendered,timeout:10}]},
    {matcher:"*",hooks:[{type:"command",command:"keep-this-unrelated-hook"}]}
  ],
  # A copy under another event: the retire walks every event, and an event it
  # empties is left as an empty list rather than a group with no hooks.
  Stop:[{matcher:"*",hooks:[{type:"command",command:$rec,timeout:10}]}]}}
' >"$PRREC_RECON_HOME/settings.json"
chmod 0640 "$PRREC_RECON_HOME/settings.json"
prrec_recon_out=$(HOME="$PRREC_RECON_ROOT" CLAUDE_HOME="$PRREC_RECON_HOME" \
  "$SYNC" reconcile-pr-record-hook 2>&1); prrec_recon_status=$?
if [ "$prrec_recon_status" -eq 0 ]; then ok; else bad "pr-record retire (pre-existing host) exited $prrec_recon_status:"$'\n'"$prrec_recon_out"; fi
if jq -e '
    ([.hooks.PostToolUse[]?.hooks[]? | .command] == ["keep-this-unrelated-hook"])
    and (.hooks.Stop == [])
  ' "$PRREC_RECON_HOME/settings.json" >/dev/null; then
  ok
else
  bad "pr-record retire (pre-existing host) did not remove exactly the pr-record groups:"$'\n'"$(jq -c '.hooks.PostToolUse' "$PRREC_RECON_HOME/settings.json")"
fi
if [ "$(stat -c %a "$PRREC_RECON_HOME/settings.json")" = 640 ]; then ok; else bad "pr-record retire (pre-existing host) changed live settings mode"; fi
if find "$PRREC_RECON_HOME/backups" -path '*hook-retire-*' -name settings.json -type f -print -quit | grep -q .; then ok; else bad "pr-record retire (pre-existing host) did not back up live settings"; fi
prrec_recon_after=$(jq -S . "$PRREC_RECON_HOME/settings.json")
prrec_again_out=$(HOME="$PRREC_RECON_ROOT" CLAUDE_HOME="$PRREC_RECON_HOME" \
  "$SYNC" reconcile-pr-record-hook 2>&1); prrec_again_status=$?
prrec_backups_n=$(find "$PRREC_RECON_HOME/backups" -path '*hook-retire-*' -name settings.json -type f 2>/dev/null | wc -l)
if [ "$prrec_again_status" -eq 0 ] && [ "$(jq -S . "$PRREC_RECON_HOME/settings.json")" = "$prrec_recon_after" ] \
   && [ "$prrec_backups_n" -eq 1 ]; then
  ok
else
  bad "pr-record retire was not idempotent on a second run (exit $prrec_again_status, backups $prrec_backups_n):"$'\n'"$prrec_again_out"
fi

# Pulled directly from sync.sh itself so this suite covers whatever units
# exist there later instead of duplicating (and silently drifting from) a
# hardcoded list.
eval "$(grep -E '^(UNITS|SYSTEM_UNITS)=' "$SYNC")"

# A stale symlink-to-directory at a stable-file destination must be replaced,
# not dereferenced by ln(1). The existing STABLE_FILES assertions below verify
# that this path resolves to the repo file after install.
mkdir -p "$TMP/stale-env-target" "$CLAUDE_HOME" "$CLAUDE_WINDOWS_HOME/.claude"
ln -s "$TMP/stale-env-target" "$CLAUDE_HOME/claude-env.sh"
jq 'del(.permissions.disableAutoMode) | .permissions.deny -= ["EnterPlanMode"] | .syncSmokeKeep = true' \
  "$REPO/windows-stub/settings.json" >"$CLAUDE_WINDOWS_HOME/.claude/settings.json"
cp "$CLAUDE_WINDOWS_HOME/.claude/settings.json" "$TMP/windows-settings-before-install.json"

echo "=== sync.sh install (fresh retry) ===" >&2
out=$("$SYNC" install 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "sync.sh install exited $status:"$'\n'"$out"; fi

# Routine install may validate the reviewed candidate but cannot perform first
# adoption. Unknown target keys and exact bytes remain operator-owned until the
# dedicated explicit verb is invoked.
if grep -Fq 'docker-init: pending adoption' <<<"$out" \
   && grep -Fq 'runtime not verified' <<<"$out" \
   && jq -e '."unknown-option".preserve == true and (has("init") | not)' "$DOCKER_DAEMON_TARGET" >/dev/null \
   && [ ! -e "$DOCKER_ADOPTION_STATE" ] \
   && [ ! -e "$DOCKER_ADOPTION_BACKUP" ]; then
  ok
else
  bad "routine workstation install published or misreported first Docker adoption:"$'\n'"$out"
fi

# Adoption is a separate public sync action. It may add only init=true, retains
# the original bytes as the immutable baseline, and still makes no runtime claim.
docker_original=$(cat "$DOCKER_DAEMON_TARGET")
docker_adopt_out=$("$SYNC" adopt-docker-init 2>&1); docker_adopt_status=$?
if [ "$docker_adopt_status" -eq 0 ] \
   && grep -Fq 'runtime not verified' <<<"$docker_adopt_out" \
   && jq -e '.init == true and ."unknown-option".preserve == true' "$DOCKER_DAEMON_TARGET" >/dev/null \
   && [ "$(cat "$DOCKER_ADOPTION_BACKUP")" = "$docker_original" ] \
   && [ "$(jq -r .phase "$DOCKER_ADOPTION_STATE")" = adopted ]; then
  ok
else
  bad "explicit Docker init adoption failed or clobbered unowned settings:"$'\n'"$docker_adopt_out"
fi

# Once adopted, policy validation failures are installer failures rather than a
# silently green install. Snapshot all Docker-owned artifacts around the call.
docker_failure_before=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_failure_out=$(DOCKER_VALIDATE_EXIT=42 "$SYNC" install 2>&1); docker_failure_status=$?
docker_failure_after=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
if [ "$docker_failure_status" -ne 0 ] \
   && [ "$docker_failure_before" = "$docker_failure_after" ] \
   && grep -Fq 'Docker configuration validation failed' <<<"$docker_failure_out" \
   && ! grep -Fq 'install done' <<<"$docker_failure_out"; then
  ok
else
  bad "adopted Docker policy failure did not propagate through sync install:"$'\n'"$docker_failure_out"
fi
if [ ! -s "$DOCKER_COMMAND_LOG" ] \
   && ! grep -Eq '(^|[[:space:]])(start|stop|restart|reload)[[:space:]]+(docker|docker\.service)([[:space:]]|$)' "$SYSTEMCTL_LOG"; then
  ok
else
  bad "Docker policy helper operated the Docker CLI or service manager"
fi

migrated_timers='mcp-servers-update.timer
skills-update.timer'
migrated_services='mcp-servers-update.service
skills-update.service'
timer_enabled() { grep -Fxq -- "$1" "$SYSTEMCTL_ENABLED_TIMERS"; }
service_active() { grep -Fxq -- "$1" "$SYSTEMCTL_ACTIVE_SERVICES"; }
service_failed() { grep -Fxq -- "$1" "$SYSTEMCTL_FAILED_SERVICES"; }
enabled_migrated_count() {
  local timer count=0
  while IFS= read -r timer; do
    timer_enabled "$timer" && count=$((count + 1))
  done <<EOF_MIGRATED_TIMERS
$migrated_timers
EOF_MIGRATED_TIMERS
  printf '%s\n' "$count"
}
active_migrated_count() {
  local service count=0
  while IFS= read -r service; do
    service_active "$service" && count=$((count + 1))
  done <<EOF_MIGRATED_SERVICES
$migrated_services
EOF_MIGRATED_SERVICES
  printf '%s\n' "$count"
}
# With no crontab nothing owns either job, so both migrated timers are admitted.
[ "$(enabled_migrated_count)" -eq 2 ] \
  && ok || bad "workstation with no crontab did not admit both migrated timers"
# backup-harness.timer is opt-in: its script refuses a public origin, so a workstation
# install must not be the thing that schedules it.
if ! timer_enabled backup-harness.timer && timer_enabled dcg-auto-update.timer \
   && timer_enabled tools-auto-update.timer; then
  ok
else
  bad "workstation install enabled the opt-in backup-harness.timer, or skipped its own role set"
fi

# -- scheduler ownership/role reconciliation (all hermetic) ----------------
# One exact legacy owner excludes only its own replacement. Its service is
# active while the timer is already disabled, proving safety does not depend on
# is-enabled. Unrelated timer/service state must survive every safety path.
printf '%s\n' 'unrelated-existing.timer' >>"$SYSTEMCTL_ENABLED_TIMERS"
printf '%s\n' 'unrelated-existing.service' >>"$SYSTEMCTL_ACTIVE_SERVICES"
grep -Fxv -- mcp-servers-update.timer "$SYSTEMCTL_ENABLED_TIMERS" \
  >"$SYSTEMCTL_ENABLED_TIMERS.next" || true
mv "$SYSTEMCTL_ENABLED_TIMERS.next" "$SYSTEMCTL_ENABLED_TIMERS"
printf '%s\n' mcp-servers-update.service >>"$SYSTEMCTL_ACTIVE_SERVICES"
sort -u -o "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_ACTIVE_SERVICES"
printf '%s\n' '0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh >> /redacted/log 2>&1' \
  >"$CRONTAB_FIXTURE"
export CRONTAB_MODE=file
owner_out=$("$SYNC" install 2>&1); owner_status=$?
if [ "$owner_status" -eq 0 ] \
   && ! timer_enabled mcp-servers-update.timer \
   && [ "$(enabled_migrated_count)" -eq 1 ] \
   && ! service_active mcp-servers-update.service \
   && timer_enabled unrelated-existing.timer \
   && service_active unrelated-existing.service; then
  ok
else
  bad "one exact legacy owner did not quiesce only its replacement:"$'\n'"$owner_out"
fi

# A successful stop response is not enough: reconciliation must independently
# prove the service is inactive before claiming the ownership handoff is safe.
printf '%s\n' mcp-servers-update.service >>"$SYSTEMCTL_ACTIVE_SERVICES"
sort -u -o "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_ACTIVE_SERVICES"
export SYSTEMCTL_STICKY_SERVICE=mcp-servers-update.service
sticky_out=$("$SYNC" install 2>&1); sticky_status=$?
unset SYSTEMCTL_STICKY_SERVICE
if [ "$sticky_status" -ne 0 ] \
   && service_active mcp-servers-update.service \
   && grep -Fq 'not proven inactive' <<<"$sticky_out"; then
  ok
else
  bad "scheduler claimed safety without proving the replacement service inactive:"$'\n'"$sticky_out"
fi
"$SYNC" install >/dev/null 2>&1 \
  || bad "scheduler fixture did not recover after the sticky-service negative"

# `systemctl stop` can leave a oneshot in failed state. Failed is not proof of
# inactivity for this ownership gate: reconciliation must fail closed while
# preserving unrelated manager state.
printf '%s\n' mcp-servers-update.service >"$SYSTEMCTL_FAILED_SERVICES"
: >"$SYSTEMCTL_LOG"
failed_service_out=$("$SYNC" install 2>&1); failed_service_status=$?
if [ "$failed_service_status" -ne 0 ] \
   && service_failed mcp-servers-update.service \
   && timer_enabled unrelated-existing.timer \
   && service_active unrelated-existing.service \
   && ! grep -Fq -- 'unrelated-existing' "$SYSTEMCTL_LOG" \
   && grep -Fq 'not proven inactive' <<<"$failed_service_out"; then
  ok
else
  bad "scheduler accepted a failed replacement service or touched unrelated state:"$'\n'"$failed_service_out"
fi
: >"$SYSTEMCTL_FAILED_SERVICES"
"$SYNC" install >/dev/null 2>&1 \
  || bad "scheduler fixture did not recover after the failed-service negative"

# Commented targets and standalone assignments are inactive. Empty and absent
# crontabs are both valid no-owner states.
printf '%s\n' \
  'PATH="$HOME/bin:/usr/bin" # standalone environment' \
  '# 0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh' >"$CRONTAB_FIXTURE"
ignored_out=$("$SYNC" install 2>&1); ignored_status=$?
[ "$ignored_status" -eq 0 ] && [ "$(enabled_migrated_count)" -eq 2 ] \
  && ok || bad "comment/environment records prevented migrated timer admission:"$'\n'"$ignored_out"
: >"$CRONTAB_FIXTURE"
empty_out=$("$SYNC" install 2>&1); empty_status=$?
[ "$empty_status" -eq 0 ] && [ "$(enabled_migrated_count)" -eq 2 ] \
  && ok || bad "empty crontab did not admit both migrated timers:"$'\n'"$empty_out"

# The inline-assignment trap is not a standalone environment record. It must
# fail closed for the mentioned job while the other job remains independent.
printf '%s\n' 'FOO=1 0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh' \
  >"$CRONTAB_FIXTURE"
ambiguous_out=$("$SYNC" install 2>&1); ambiguous_status=$?
if [ "$ambiguous_status" -eq 0 ] \
   && ! timer_enabled mcp-servers-update.timer \
   && [ "$(enabled_migrated_count)" -eq 1 ]; then
  ok
else
  bad "ambiguous inline assignment did not block only its mapped replacement:"$'\n'"$ambiguous_out"
fi

# Satellites never admit migrated timers. Exercise all three public paths
# (install/check/push) from a satellite host table.
fixture_hostname=$(hostname -s 2>/dev/null || hostname)
printf '# satellite fixture table\n%s\t%s\n' "$fixture_hostname" satellite \
  >"$REPO/hosts.tsv"
# PLANTED NEGATIVE: a satellite whose environment carries no proxy URL fails
# closed at the runtime-env step, names the variable, and leaves the live URL
# as it was. The public tree ships no proxy host; the overlay env is the only
# source of CCFLARE_URL_SATELLITE.
unset CCFLARE_URL_SATELLITE
sat_unset_url_before=$(jq -r '.env.ANTHROPIC_BASE_URL // ""' "$CLAUDE_HOME/settings.json" 2>/dev/null)
sat_unset_out=$("$SYNC" install 2>&1); sat_unset_status=$?
if [ "$sat_unset_status" -ne 0 ] && grep -Fq 'CCFLARE_URL_SATELLITE is unset' <<<"$sat_unset_out"; then
  ok
else
  bad "satellite install with CCFLARE_URL_SATELLITE unset did not fail closed naming the variable (exit $sat_unset_status):"$'\n'"$sat_unset_out"
fi
sat_unset_url_after=$(jq -r '.env.ANTHROPIC_BASE_URL // ""' "$CLAUDE_HOME/settings.json" 2>/dev/null)
if [ "$sat_unset_url_after" = "$sat_unset_url_before" ]; then
  ok
else
  bad "satellite install with CCFLARE_URL_SATELLITE unset changed ANTHROPIC_BASE_URL from '$sat_unset_url_before' to '$sat_unset_url_after'"
fi
export CCFLARE_URL_SATELLITE=https://proxy-host.example.net
: >"$CRONTAB_FIXTURE"
docker_satellite_before=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_satellite_validations_before=$(wc -l <"$DOCKER_VALIDATE_LOG")
satellite_out=$("$SYNC" install 2>&1); satellite_status=$?
satellite_check_out=$("$SYNC" check 2>&1); satellite_check_status=$?
satellite_push_out=$("$SYNC" push 2>&1); satellite_push_status=$?
if [ "$satellite_status" -eq 0 ] \
   && [ "$(enabled_migrated_count)" -eq 0 ] \
   && [ "$(active_migrated_count)" -eq 0 ] \
   && timer_enabled unrelated-existing.timer \
   && service_active unrelated-existing.service; then
  ok
else
  bad "satellite admitted a migrated timer or changed unrelated state:"$'\n'"$satellite_out"
fi
if [ "$satellite_push_status" -eq 2 ]; then
  ok
else
  bad "satellite push was not refused (check=$satellite_check_status push=$satellite_push_status):"$'\n'"$satellite_check_out"$'\n'"$satellite_push_out"
fi
docker_satellite_after=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_satellite_validations_after=$(wc -l <"$DOCKER_VALIDATE_LOG")
if [ "$docker_satellite_before" = "$docker_satellite_after" ] \
   && [ "$docker_satellite_validations_before" -eq "$docker_satellite_validations_after" ] \
   && ! grep -Fq 'docker-init' <<<"$satellite_out"$'\n'"$satellite_check_out"$'\n'"$satellite_push_out"; then
  ok
else
  bad "satellite install/check/push claimed or validated Docker init policy"
fi

# dotfiles#1724: no migrated timer can be admitted on a satellite, so cron
# availability/content must not gate unrelated installation. Seed real fake-
# manager state each time so both disabling timers and stopping services count.
seed_satellite_scheduler() {
  printf '%s\n' "$migrated_timers" backup-harness.timer \
    unrelated-existing.timer >"$SYSTEMCTL_ENABLED_TIMERS"
  printf '%s\n' "$migrated_services" \
    unrelated-existing.service >"$SYSTEMCTL_ACTIVE_SERVICES"
  : >"$SYSTEMCTL_FAILED_SERVICES"
  : >"$SYSTEMCTL_LOG"
  : >"$CRONTAB_CALL_LOG"
}
printf '%s\n' '0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh' >"$CRONTAB_FIXTURE"
for satellite_cron_mode in unavailable error absent file drift; do
  seed_satellite_scheduler
  export CRONTAB_MODE=$satellite_cron_mode
  satellite_cron_out=$("$SYNC" install 2>&1); satellite_cron_status=$?
  if [ "$satellite_cron_status" -eq 0 ] \
     && [ ! -s "$CRONTAB_CALL_LOG" ] \
     && [ "$(enabled_migrated_count)" -eq 0 ] \
     && [ "$(active_migrated_count)" -eq 0 ]; then
    ok
  else
    bad "satellite cron mode $satellite_cron_mode blocked install, read cron, or left a replacement active:"$'\n'"$satellite_cron_out"
  fi
  if timer_enabled dcg-auto-update.timer \
     && timer_enabled tools-auto-update.timer && ! timer_enabled backup-harness.timer \
     && timer_enabled unrelated-existing.timer && service_active unrelated-existing.service; then
    ok
  else
    bad "satellite cron mode $satellite_cron_mode did not reconcile only its existing role set"
  fi
done

# Skipping cron ownership never skips checked quiescence, activation errors, or
# the shared cutover lock. None of these failures may claim install success.
for satellite_failure in disable stop sticky failed enable lock; do
  seed_satellite_scheduler
  export CRONTAB_MODE=unavailable
  case "$satellite_failure" in
    disable) export SYSTEMCTL_FAIL_DISABLE=1 ;;
    stop) export SYSTEMCTL_FAIL_STOP=1 ;;
    sticky) export SYSTEMCTL_STICKY_SERVICE=mcp-servers-update.service ;;
    failed) printf '%s\n' mcp-servers-update.service >"$SYSTEMCTL_FAILED_SERVICES" ;;
    enable) export SYSTEMCTL_FAIL_ENABLE_TIMER=dcg-auto-update.timer ;;
    lock) exec 9>"$CLAUDE_SYNC_CUTOVER_LOCK"; flock -n 9 ;;
  esac
  satellite_failure_before=$(sha256sum "$SYSTEMCTL_ENABLED_TIMERS" "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_FAILED_SERVICES")
  satellite_failure_out=$("$SYNC" install 2>&1); satellite_failure_status=$?
  if [ "$satellite_failure" = lock ]; then flock -u 9; exec 9>&-; fi
  unset SYSTEMCTL_FAIL_DISABLE SYSTEMCTL_FAIL_STOP SYSTEMCTL_STICKY_SERVICE SYSTEMCTL_FAIL_ENABLE_TIMER
  if [ "$satellite_failure_status" -ne 0 ] && [ ! -s "$CRONTAB_CALL_LOG" ] \
     && timer_enabled unrelated-existing.timer && service_active unrelated-existing.service; then
    ok
  else
    bad "satellite $satellite_failure failure was hidden, read cron, or changed unrelated state:"$'\n'"$satellite_failure_out"
  fi
  case "$satellite_failure" in
    disable) satellite_failure_message='could not disable migrated timer' ;;
    stop) satellite_failure_message='could not stop migrated service' ;;
    sticky|failed) satellite_failure_message='not proven inactive' ;;
    enable) satellite_failure_message='enable --now failed' ;;
    lock) satellite_failure_message='cutover lock is held' ;;
  esac
  grep -Fq "$satellite_failure_message" <<<"$satellite_failure_out" \
    && ok || bad "satellite $satellite_failure did not report the actual failing gate"
  if [ "$satellite_failure" = enable ]; then
    [ "$(enabled_migrated_count)" -eq 0 ] && [ "$(active_migrated_count)" -eq 0 ] \
      && ok || bad "satellite failed enable left a migrated replacement active"
  elif [ "$satellite_failure" = lock ]; then
    satellite_failure_after=$(sha256sum "$SYSTEMCTL_ENABLED_TIMERS" "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_FAILED_SERVICES")
    [ "$satellite_failure_before" = "$satellite_failure_after" ] \
      && ! grep -Eq -- '--user (enable|disable|stop)' "$SYSTEMCTL_LOG" \
      && ok || bad "satellite held lock allowed a scheduler transition"
  else
    ! grep -Fq -- '--user enable --now' "$SYSTEMCTL_LOG" \
      && ok || bad "satellite $satellite_failure failure still enabled its base timers"
  fi
done
seed_satellite_scheduler
export CRONTAB_MODE=file
"$SYNC" install >/dev/null 2>&1 || bad "satellite scheduler did not recover after failure fixtures"


# An undeclared host cannot use DOTFILES_ROLE=workstation as a backdoor. It may
# fail the broader install/check role gate, but still cannot push.
printf '# unknown-host fixture table\n' >"$REPO/hosts.tsv"
docker_unknown_before=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_unknown_validations_before=$(wc -l <"$DOCKER_VALIDATE_LOG")
unknown_out=$(DOTFILES_ROLE=workstation "$SYNC" install 2>&1); unknown_status=$?
unknown_check_out=$(DOTFILES_ROLE=workstation "$SYNC" check 2>&1); unknown_check_status=$?
unknown_push_out=$(DOTFILES_ROLE=workstation "$SYNC" push 2>&1); unknown_push_status=$?
if [ "$unknown_status" -ne 0 ] \
   && [ "$unknown_check_status" -ne 0 ] \
   && [ "$unknown_push_status" -eq 2 ]; then
  ok
else
  bad "undeclared host asserting DOTFILES_ROLE=workstation was not refused by install/check/push:"$'\n'"$unknown_out"$'\n'"$unknown_check_out"$'\n'"$unknown_push_out"
fi
docker_unknown_after=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_unknown_validations_after=$(wc -l <"$DOCKER_VALIDATE_LOG")
if [ "$docker_unknown_before" = "$docker_unknown_after" ] \
   && [ "$docker_unknown_validations_before" -eq "$docker_unknown_validations_after" ] \
   && ! grep -Fq 'docker-init' <<<"$unknown_out"$'\n'"$unknown_check_out"$'\n'"$unknown_push_out"; then
  ok
else
  bad "undeclared host claimed or validated Docker init policy"
fi

# A damaged checkout may retain the historical DOTFILES_ROLE fallback for
# unrelated units: with no authoritative profile library, install must still
# succeed and enable the workstation timer set.
docker_missing_profile_before=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_missing_profile_validations_before=$(wc -l <"$DOCKER_VALIDATE_LOG")
mv "$REPO/lib/profile.sh" "$TMP/profile.sh.authoritative"
# The workstation set leaves an opted-in backup-harness.timer enabled where the satellite
# set disables it, so seeding it enabled tells the two roles apart.
printf '%s\n' backup-harness.timer >>"$SYSTEMCTL_ENABLED_TIMERS"
missing_profile_out=$(DOTFILES_ROLE=workstation "$SYNC" install 2>&1); missing_profile_status=$?
missing_profile_check_out=$(DOTFILES_ROLE=workstation "$SYNC" check 2>&1); missing_profile_check_status=$?
mv "$TMP/profile.sh.authoritative" "$REPO/lib/profile.sh"
if [ "$missing_profile_status" -eq 0 ] && timer_enabled backup-harness.timer \
   && timer_enabled dcg-auto-update.timer && timer_enabled tools-auto-update.timer; then
  ok
else
  bad "missing profile library broke the unrelated role fallback (check=$missing_profile_check_status):"$'\n'"$missing_profile_out"$'\n'"$missing_profile_check_out"
fi
docker_missing_profile_after=$(sha256sum "$DOCKER_DAEMON_TARGET" "$DOCKER_ADOPTION_STATE" "$DOCKER_ADOPTION_BACKUP")
docker_missing_profile_validations_after=$(wc -l <"$DOCKER_VALIDATE_LOG")
if [ "$docker_missing_profile_before" = "$docker_missing_profile_after" ] \
   && [ "$docker_missing_profile_validations_before" -eq "$docker_missing_profile_validations_after" ] \
   && ! grep -Fq 'docker-init' <<<"$missing_profile_out"$'\n'"$missing_profile_check_out"; then
  ok
else
  bad "missing authoritative profile selected or validated Docker init policy"
fi

printf '# workstation fixture table\n%s\t%s\n' "$fixture_hostname" workstation \
  >"$REPO/hosts.tsv"
unset CCFLARE_URL_SATELLITE

# Read failure disables both migrated timers, preserves unrelated state,
# and is visible to the caller.
while IFS= read -r timer; do printf '%s\n' "$timer"; done <<EOF_REENABLE_READ_FAILURE \
  >>"$SYSTEMCTL_ENABLED_TIMERS"
$migrated_timers
EOF_REENABLE_READ_FAILURE
while IFS= read -r service; do printf '%s\n' "$service"; done <<EOF_REACTIVATE_READ_FAILURE \
  >>"$SYSTEMCTL_ACTIVE_SERVICES"
$migrated_services
EOF_REACTIVATE_READ_FAILURE
sort -u -o "$SYSTEMCTL_ENABLED_TIMERS" "$SYSTEMCTL_ENABLED_TIMERS"
sort -u -o "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_ACTIVE_SERVICES"
export CRONTAB_MODE=error
read_fail_out=$("$SYNC" install 2>&1); read_fail_status=$?
if [ "$read_fail_status" -ne 0 ] \
   && [ "$(enabled_migrated_count)" -eq 0 ] \
   && [ "$(active_migrated_count)" -eq 0 ] \
   && timer_enabled unrelated-existing.timer \
   && service_active unrelated-existing.service \
   && grep -Fq 'crontab could not be read and classified' <<<"$read_fail_out"; then
  ok
else
  bad "unreadable crontab did not fail closed without collateral timer changes:"$'\n'"$read_fail_out"
fi

# The satellite-only path must not classify exit 127 as an empty workstation
# crontab. Workstation ownership remains unknown and all replacements stop.
printf '%s\n' "$migrated_timers" >>"$SYSTEMCTL_ENABLED_TIMERS"
printf '%s\n' "$migrated_services" >>"$SYSTEMCTL_ACTIVE_SERVICES"
export CRONTAB_MODE=unavailable
: >"$CRONTAB_CALL_LOG"
unavailable_cron_out=$("$SYNC" install 2>&1); unavailable_cron_status=$?
if [ "$unavailable_cron_status" -ne 0 ] && [ -s "$CRONTAB_CALL_LOG" ] \
   && [ "$(enabled_migrated_count)" -eq 0 ] && [ "$(active_migrated_count)" -eq 0 ] \
   && timer_enabled unrelated-existing.timer && service_active unrelated-existing.service \
   && grep -Fq 'crontab could not be read and classified' <<<"$unavailable_cron_out"; then
  ok
else
  bad "workstation accepted unavailable cron or failed to quiesce replacements:"$'\n'"$unavailable_cron_out"
fi


# A held shared cutover lock must return before any enable/disable transition.
export CRONTAB_MODE=absent
: >"$SYSTEMCTL_LOG"
state_before_lock=$(sha256sum \
  "$SYSTEMCTL_ENABLED_TIMERS" "$SYSTEMCTL_ACTIVE_SERVICES" \
  "$SYSTEMCTL_FAILED_SERVICES")
exec 9>"$CLAUDE_SYNC_CUTOVER_LOCK"
flock -n 9
lock_out=$("$SYNC" install 2>&1); lock_status=$?
flock -u 9
exec 9>&-
state_after_lock=$(sha256sum \
  "$SYSTEMCTL_ENABLED_TIMERS" "$SYSTEMCTL_ACTIVE_SERVICES" \
  "$SYSTEMCTL_FAILED_SERVICES")
if [ "$lock_status" -ne 0 ] \
   && [ "$state_before_lock" = "$state_after_lock" ] \
   && ! grep -Eq -- '--user (enable|disable|stop)' "$SYSTEMCTL_LOG" \
   && grep -Fq 'cutover lock is held' <<<"$lock_out"; then
  ok
else
  bad "held cutover lock changed timer state or was not visible:"$'\n'"$lock_out"
fi

# A crontab change after enablement invalidates admission. The drift fixture
# introduces the mcp-servers-update owner on the second read; all just-admitted
# replacements are disabled because the snapshot as a whole lost CAS identity.
: >"$CRONTAB_FIXTURE"
: >"$CRONTAB_READ_COUNT"
printf '%s\n' mcp-servers-update.service >>"$SYSTEMCTL_ACTIVE_SERVICES"
sort -u -o "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_ACTIVE_SERVICES"
export CRONTAB_MODE=drift
drift_out=$("$SYNC" install 2>&1); drift_status=$?
if [ "$drift_status" -ne 0 ] \
   && [ "$(enabled_migrated_count)" -eq 0 ] \
   && ! service_active mcp-servers-update.service \
   && timer_enabled unrelated-existing.timer \
   && service_active unrelated-existing.service \
   && grep -Fq 'crontab drifted' <<<"$drift_out"; then
  ok
else
  bad "post-enable digest drift did not revoke replacement ownership:"$'\n'"$drift_out"
fi

# A failed enable --now is never reported as install success, and no migrated
# timer from that attempted admission remains enabled.
export CRONTAB_MODE=absent
printf '%s\n' skills-update.service >>"$SYSTEMCTL_ACTIVE_SERVICES"
sort -u -o "$SYSTEMCTL_ACTIVE_SERVICES" "$SYSTEMCTL_ACTIVE_SERVICES"
export SYSTEMCTL_FAIL_ENABLE_TIMER=skills-update.timer
enable_fail_out=$("$SYNC" install 2>&1); enable_fail_status=$?
unset SYSTEMCTL_FAIL_ENABLE_TIMER
if [ "$enable_fail_status" -ne 0 ] \
   && [ "$(enabled_migrated_count)" -eq 0 ] \
   && [ "$(active_migrated_count)" -eq 0 ] \
   && timer_enabled unrelated-existing.timer \
   && service_active unrelated-existing.service \
   && grep -Fq 'enable --now failed' <<<"$enable_fail_out"; then
  ok
else
  bad "systemctl enable failure was hidden or left a migrated replacement active:"$'\n'"$enable_fail_out"
fi

# Restore the suite's normal no-crontab workstation state for all later install
# and check assertions.
unset CRONTAB_MODE
"$SYNC" install >/dev/null 2>&1 || bad "scheduler fixture did not recover after failure scenarios"

# -- STABLE_DIRS symlinked into place --------------------------------------
for d in hooks scripts bin commands agents workflows mods; do
  if [ -L "$CLAUDE_HOME/$d" ]; then ok; else bad "STABLE_DIRS: $d was not symlinked"; fi
  if [ "$(readlink -f "$CLAUDE_HOME/$d" 2>/dev/null)" = "$(readlink -f "$REPO/$d")" ]; then
    ok
  else
    bad "STABLE_DIRS: $d symlink does not resolve to the repo copy"
  fi
done

# -- tracked script modes remain authoritative -----------------------------
if [ -x "$CLAUDE_HOME/scripts/jsm-auto-update-wrapper.sh" ]; then
  ok
else
  bad "scripts: jsm-auto-update-wrapper.sh was not installed executable"
fi
if [ -x "$CLAUDE_HOME/scripts/harness-doctor.sh" ]; then
  ok
else
  bad "scripts: ordinary executable harness-doctor.sh lost its executable mode"
fi
if [ ! -x "$CLAUDE_HOME/scripts/migration-targets.sh" ]; then
  ok
else
  bad "scripts: source-only migration-targets.sh became executable"
fi
migration_targets_mode=$(stat -c '%a' "$CLAUDE_HOME/scripts/migration-targets.sh" 2>/dev/null || echo MISSING)
if [ "$migration_targets_mode" = 644 ]; then
  ok
else
  bad "scripts: migration-targets.sh mode is $migration_targets_mode, expected 644"
fi

# -- fixture copy holds git's modes, not the checkout umask (#1647) ---------
# Pro-gate round 1 on #1645: a checkout made under umask 0002 read red above.
# Plant those modes so the fixture's own copy is pinned on any host, CI's 644
# checkout included.
umask_probe=$TMP/umask-0002-checkout
mkdir -p "$umask_probe/src/sub"
printf 'source-only\n' > "$umask_probe/src/plain.sh"
printf '#!/bin/sh\n' > "$umask_probe/src/exec.sh"
chmod 664 "$umask_probe/src/plain.sh"
chmod 775 "$umask_probe/src/exec.sh" "$umask_probe/src/sub"
copy_tracked "$umask_probe/src" "$umask_probe/dst"
probe_modes=$(stat -c '%a' "$umask_probe/dst/plain.sh" "$umask_probe/dst/exec.sh" "$umask_probe/dst/sub" 2>/dev/null | tr '\n' ' ')
if [ "$probe_modes" = "644 755 755 " ]; then
  ok
else
  bad "fixture copy (#1647): umask-0002 checkout modes 664/775/775 copied as ${probe_modes:-MISSING}, expected 644 755 755"
fi

# -- STABLE_FILES symlinked -------------------------------------------------
for f in CLAUDE.md claude-env.sh memory-dream.json; do
  if [ -L "$CLAUDE_HOME/$f" ]; then ok; else bad "STABLE_FILES: $f was not symlinked"; fi
  if [ "$(readlink -f "$CLAUDE_HOME/$f" 2>/dev/null)" = "$(readlink -f "$REPO/$f")" ]; then
    ok
  else
    bad "STABLE_FILES: $f symlink does not resolve to the repo copy"
  fi
done

# -- VOLATILE_FILES seeded with repo content --------------------------------
for f in settings.json keybindings.json; do
  if [ -f "$CLAUDE_HOME/$f" ] && [ ! -L "$CLAUDE_HOME/$f" ]; then
    ok
  else
    bad "VOLATILE_FILES: $f was not seeded as a real file"
  fi
  if [ "$f" = settings.json ]; then
    if cmp -s \
        <(jq -S --arg home "$CLAUDE_HOME" --arg realhome "$HOME" '
            # The tracked file is a template. sync.sh'"'"'s fresh seed renders the env
            # values spelled $HOME/ to the installing home (Claude Code exports env
            # as written) and keeps hook commands and permission rules as the
            # template (a shell expands the former; the latter match literally),
            # then sets the two env paths below.
            .env |= with_entries(.value |= (if type == "string" and startswith("$HOME/") then $realhome + .[5:] else . end))
            | .env.CLAUDE_ENV_FILE = ($home + "/claude-env.sh")
            | .env.CLAUDE_CODE_PLUGIN_DIRS = ($home + "/mods/loop-breaker:" + $home + "/mods/agent-radar:" + $home + "/mods/read-ceiling-pager:" + $home + "/mods/reminder-diet:" + $home + "/mods/lookout:" + $home + "/mods/x-mcp-budget")
          ' "$REPO/$f") \
        <(jq -S . "$CLAUDE_HOME/$f"); then
      ok
    else
      bad "VOLATILE_FILES: settings.json content does not match the portable repo seed"
    fi
  elif cmp -s "$CLAUDE_HOME/$f" "$REPO/$f" 2>/dev/null; then
    ok
  else
    bad "VOLATILE_FILES: $f content does not match the repo copy after a fresh install"
  fi
done

# -- Native Windows keeps break-glass config but cannot enter Auto mode ------
if jq -e '
    .permissions.disableAutoMode == "disable"
    and .permissions.disableBypassPermissionsMode != "disable"
    and .permissions.deny == ["EnterPlanMode"]
    and .syncSmokeKeep == true
  ' "$CLAUDE_WINDOWS_HOME/.claude/settings.json" >/dev/null; then
  ok
else
  bad "Windows settings did not gain Auto-mode policy and the EnterPlanMode deny while preserving local config"
fi
if find "$CLAUDE_HOME/backups" -type f -name settings.json -exec cmp -s {} "$TMP/windows-settings-before-install.json" \; -print -quit | grep -q .; then
  ok
else
  bad "Windows Auto-mode reconcile did not preserve a byte-identical backup"
fi

# -- Claude Bash OOM defenses are present in the seeded volatile config ------
if jq -e --arg home "$CLAUDE_HOME" --arg realhome "$HOME" '
    .env.CLAUDE_CODE_TOOL_MEMORY_LIMIT == "4G"
    and .env.CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP == "1"
    and .env.CLAUDE_ENV_FILE == ($home + "/claude-env.sh")
    and .env.WACLI_STORE_DIR == ($realhome + "/.local/state/wacli")
    and .env.PRO_GATE_ROUND_GUARD == "1"
    and .env.CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS == "50000"
    and .env.CLAUDE_CODE_PLUGIN_DIRS == ($home + "/mods/loop-breaker:" + $home + "/mods/agent-radar:" + $home + "/mods/read-ceiling-pager:" + $home + "/mods/reminder-diet:" + $home + "/mods/lookout:" + $home + "/mods/x-mcp-budget")
    and .permissions.disableAutoMode == "disable"
    and .permissions.defaultMode == "bypassPermissions"
    and .permissions.disableBypassPermissionsMode != "disable"
  ' "$CLAUDE_HOME/settings.json" >/dev/null; then
  ok
else
  bad "settings.json: Claude tool memory limit / env-file defenses are missing"
fi
# The tracked settings.json names the STABLE symlink and never a version
# (dotfiles#1201); the installed live copy names whatever the symlink resolves
# to on this host (the versioned binary, or the symlink itself where no dcg is
# installed). These assertions are about ORDER, so anchor on either spelling.
dcg_cmd=$(jq -r '
  [ .hooks.PreToolUse[]?.hooks[]?.command // ""
    | select(. == "$HOME/.local/bin/dcg") ]
  | if length == 1 then .[0] else empty end
' "$REPO/settings.json")
if [ -n "$dcg_cmd" ]; then ok; else bad "canonical settings must contain exactly one dcg hook command, naming the literal \$HOME/.local/bin/dcg and no version (dotfiles#1201)"; fi
if jq -e --arg realhome "$HOME" '
    .hooks.PreToolUse as $groups
    | ([ $groups[] | .hooks[]? | .command
        | (. == "$HOME/.local/bin/dcg" or (startswith($realhome + "/.local/") and test("/\\.local/(lib/dcg/v[0-9]+\\.[0-9]+\\.[0-9]+|bin)/dcg$"))) ] | index(true)) as $dcg
    | ([ $groups[] | .hooks[]? | .command ] | index("\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/PreToolUse/grep-cost-guard.js\"")) as $guard
    | ([ $groups[] | .hooks[]? | .command ] | index("\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/PreToolUse/heavy-job-admission.js\"")) as $heavy
    | ([ $groups[] | .hooks[]? | .command ] | index("\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/PreToolUse/whatsapp-guard.js\"")) as $whatsapp
    | $dcg != null and $guard == ($dcg + 1) and $heavy == ($guard + 1) and $whatsapp == ($heavy + 1)
  ' "$CLAUDE_HOME/settings.json" >/dev/null; then
  ok
else
  bad "settings.json: grep-cost/heavy-job/WhatsApp guards are not registered immediately after DCG in order"
fi
if jq -e '
    ([.hooks.PreToolUse[]?.hooks[]? | select(
      .command == "\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/PreToolUse/grep-cost-guard.js\""
      or .command == "\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/PreToolUse/heavy-job-admission.js\""
    )] | length == 2 and all(.[]; has("timeout") | not))
    and ([.hooks.PreToolUse[]?.hooks[]? | select(
      .command == "\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/PreToolUse/whatsapp-guard.js\""
    )] | length == 1 and all(.[]; .timeout == 5))
  ' "$CLAUDE_HOME/settings.json" >/dev/null; then
  ok
else
  bad "settings.json: resource/WhatsApp hook timing is wrong"
fi

# -- installed CLAUDE_ENV_FILE behavior -------------------------------------
# Source the exact path written to installed settings. It must remove only the
# Claude-injected grep/find functions and preserve unrelated shell functions.
installed_env_file=$(jq -r .env.CLAUDE_ENV_FILE "$CLAUDE_HOME/settings.json")
grep() { :; }
find() { :; }
sync_smoke_unrelated() { :; }
# shellcheck disable=SC1090
. "$installed_env_file"
if declare -F grep >/dev/null; then bad "CLAUDE_ENV_FILE left grep as a function"; else ok; fi
if declare -F find >/dev/null; then bad "CLAUDE_ENV_FILE left find as a function"; else ok; fi
if declare -F sync_smoke_unrelated >/dev/null; then ok; else bad "CLAUDE_ENV_FILE removed an unrelated function"; fi
unset -f sync_smoke_unrelated

# -- focused live-settings reconciliation preserves unrelated config ---------
# A configured machine keeps its volatile settings.json. Prove that the runtime
# OOM defenses and disabled TypeScript LSP are restored without replacing an
# unrelated env/plugin key or an unknown hook group.
live_settings="$CLAUDE_HOME/settings.json"
settings_tmp="$TMP/settings-test.tmp"
jq '
  del(.env.CLAUDE_CODE_TOOL_MEMORY_LIMIT, .env.CLAUDE_ENV_FILE, .env.WACLI_STORE_DIR, .env.PRO_GATE_ROUND_GUARD, .env.CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS, .env.CLAUDE_CODE_PLUGIN_DIRS, .permissions.disableAutoMode)
  # Present but wrong, not absent: a merge that only fills missing keys would leave the
  # reap enabled and pass every other assertion here (dotfiles#1442 planted negative).
  | .env.CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP = "0"
  | .permissions.deny = (
      [.permissions.deny[] | select(. != "EnterPlanMode")] as $deny
      | $deny[0:1] + ["Bash(sync-smoke-live-only:*)"] + $deny[1:]
    )
  | .permissions.defaultMode = "acceptEdits"
  | .env.SYNC_SMOKE_KEEP = "present"
  | .enabledPlugins["typescript-lsp@claude-plugins-official"] = true
  | .enabledPlugins["sync-smoke-keep@example"] = true
  | .hooks.PreToolUse = (
      [{matcher: "Bash", hooks: [{type: "command", command: "node /tmp/unknown-live-hook.js", timeout: 7}]}]
      + .hooks.PreToolUse
    )
' "$live_settings" >"$settings_tmp" && mv "$settings_tmp" "$live_settings"
chmod 0640 "$live_settings"
cp "$live_settings" "$TMP/settings-before-runtime-reconcile.json"
hooks_before=$(jq -S .hooks "$live_settings")
permissions_before=$(jq -S '.permissions | del(.disableAutoMode, .defaultMode)' "$live_settings")

env_out=$("$SYNC" reconcile-runtime-env 2>&1); env_status=$?
if [ "$env_status" -eq 0 ]; then ok; else bad "reconcile-runtime-env exited $env_status:"$'\n'"$env_out"; fi
if jq -e --arg home "$CLAUDE_HOME" --arg realhome "$HOME" '
    .env.SYNC_SMOKE_KEEP == "present"
    and .env.CLAUDE_CODE_TOOL_MEMORY_LIMIT == "4G"
    and .env.CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP == "1"
    and .env.CLAUDE_ENV_FILE == ($home + "/claude-env.sh")
    and .env.WACLI_STORE_DIR == ($realhome + "/.local/state/wacli")
    and .env.PRO_GATE_ROUND_GUARD == "1"
    and .env.CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS == "50000"
    and .env.CLAUDE_CODE_PLUGIN_DIRS == ($home + "/mods/loop-breaker:" + $home + "/mods/agent-radar:" + $home + "/mods/read-ceiling-pager:" + $home + "/mods/reminder-diet:" + $home + "/mods/lookout:" + $home + "/mods/x-mcp-budget")
    and .enabledPlugins["typescript-lsp@claude-plugins-official"] == false
    and .enabledPlugins["sync-smoke-keep@example"] == true
    and .permissions.disableAutoMode == "disable"
    and .permissions.defaultMode == "bypassPermissions"
  ' "$live_settings" >/dev/null; then
  ok
else
  bad "reconcile-runtime-env did not merge defenses while preserving unknown env/plugins"
fi
if [ "$hooks_before" = "$(jq -S .hooks "$live_settings")" ]; then ok; else bad "runtime reconcile changed unrelated hooks"; fi
permissions_after=$(jq -S '.permissions | del(.disableAutoMode, .defaultMode)' "$live_settings")
permissions_expected=$(printf '%s' "$permissions_before" | jq -S '.deny += ["EnterPlanMode"]')
if [ "$permissions_expected" = "$permissions_after" ]; then
  ok
else
  bad "reconcile-runtime-env changed permissions beyond disableAutoMode/defaultMode and one appended EnterPlanMode deny"
fi
if jq -e '(.permissions.deny | index("ExitPlanMode")) == null' "$live_settings" >/dev/null; then
  ok
else
  bad "reconcile-runtime-env denied ExitPlanMode"
fi
live_mode=$(stat -c '%a' "$live_settings" 2>/dev/null || echo MISSING)
if [ "$live_mode" = 600 ]; then ok; else bad "reconcile-runtime-env left live settings mode at $live_mode instead of 600"; fi
if find "$CLAUDE_HOME/backups" -type f -name settings.json -exec cmp -s {} "$TMP/settings-before-runtime-reconcile.json" \; -print -quit | grep -q .; then
  ok
else
  bad "reconcile-runtime-env did not preserve a byte-identical settings backup"
fi
# A second hourly run finds nothing to do: no rewrite, no new backup, and the
# appended deny entry is still there exactly once.
env_backups_before=$(find "$CLAUDE_HOME/backups" -type f -name settings.json | wc -l)
env_again_out=$("$SYNC" reconcile-runtime-env 2>&1)
env_backups_after=$(find "$CLAUDE_HOME/backups" -type f -name settings.json | wc -l)
if grep -Fq 'already reconciled' <<<"$env_again_out" \
   && [ "$env_backups_before" = "$env_backups_after" ] \
   && jq -e '([.permissions.deny[] | select(. == "EnterPlanMode")] | length) == 1' "$live_settings" >/dev/null; then
  ok
else
  bad "reconcile-runtime-env was not idempotent on a second run:"$'\n'"$env_again_out"
fi

# The preservation fixture is deliberately live-only; restore the canonical
# copy so the later whole-config check can still prove a clean install world.
jq --arg home "$CLAUDE_HOME" '.env.CLAUDE_ENV_FILE = ($home + "/claude-env.sh")' \
  "$REPO/settings.json" >"$settings_tmp" && mv "$settings_tmp" "$live_settings"

# -- statusline renderer: only the versioned file, never runtime stack state --
statusline="$HOME/.config/statusline-stack/local-statusline.mjs"
if [ -L "$statusline" ]; then ok; else bad "statusline renderer was not linked"; fi
if [ "$(readlink -f "$statusline" 2>/dev/null)" = "$(readlink -f "$REPO/statusline-stack/local-statusline.mjs")" ]; then
  ok
else
  bad "statusline renderer does not resolve to the repo copy"
fi
if [ ! -e "$HOME/.config/statusline-stack/stack.sh" ] && [ ! -e "$HOME/.config/statusline-stack/original-statusline.json" ]; then
  ok
else
  bad "sync install manufactured runtime-owned statusline stack files"
fi

# -- portable route policy, never host-local authority ----------------------
# $CLAUDE_HOME, not $HOME/.claude: sync.sh links this under $H, and this fixture
# deliberately gives the harness home its own directory so a bug that assumed
# the default spelling cannot pass by accident.
if [ -L "$CLAUDE_HOME/config/repo-routes.json" ] \
   && [ "$(readlink -f "$CLAUDE_HOME/config/repo-routes.json")" = "$(readlink -f "$REPO/config/repo-routes.json")" ]; then
  ok
else
  bad "repo route policy was not linked from versioned config"
fi
# Ask repo-route.py where it keeps the host route record rather than spelling the path out
# here. The spelled-out path was the retired ~/.local/state/claude/repo-routes.json, where
# nothing writes any more, so this check passed whatever install did. The retired path is
# still checked, in case an old copy of the bootstrap writes there.
route_state=$(python3 -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("repo_route", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.state_path())' "$REPO/scripts/repo-route.py") || route_state=""
case "$route_state" in
  "") bad "could not ask repo-route.py where it keeps the host route record" ;;
  "$HOME"/*)
    if [ -e "$route_state" ] || [ -e "$HOME/.local/state/claude/repo-routes.json" ]; then
      bad "install seeded host-local repo authority"
    else
      ok
    fi ;;
  *) bad "repo-route.py keeps the host route record outside the fixture home: $route_state" ;;
esac
# The retired controller config must be preserved in exactly one backup.
if [ ! -e "$retired_profile" ] \
   && [ "$(find "$CLAUDE_HOME/config" -maxdepth 1 -name "${retired_profile##*/}.pre-sync.*.bak" -type f | wc -l)" = 1 ]; then
  ok
else
  bad "retired controller config was not moved to exactly one backup"
fi
route_hooks=$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("canonical-worktree-route-guard.js"))] | length' "$REPO/settings.json")
if [ "$route_hooks" = 1 ]; then ok; else bad "canonical settings must contain exactly one repo-route guard"; fi
# Existing unrelated hook groups remain present in the canonical config.
if jq -e '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("git-guard.js"))' "$REPO/settings.json" >/dev/null; then ok; else bad "unrelated PreToolUse hooks disappeared"; fi

# -- UNITS deploy loop (#370/#373) ------------------------------------------
# Every unit is covered the same way: no per-unit special case, because each
# is just a name in sync.sh's UNITS= string.
for u in $UNITS; do
  dst="$HOME/.config/systemd/user/$u"
  if [ -f "$dst" ]; then ok; else bad "UNITS: $u was not deployed to \$HOME/.config/systemd/user"; fi
  if [ -f "$dst" ] && cmp -s "$dst" "$REPO/systemd/$u"; then
    ok
  else
    bad "UNITS: $u content differs from the repo copy"
  fi
done

# PLANTED NEGATIVE: a failed user-unit copy must make install fail, not leave a
# stale unit behind while printing "install done".
copy_fail_unit="$HOME/.config/systemd/user/backup-harness.service"
mv "$copy_fail_unit" "$TMP/backup-harness.service.parked"
ln -s /dev/full "$copy_fail_unit"
copy_fail_out=$("$SYNC" install 2>&1); copy_fail_status=$?
rm "$copy_fail_unit"
mv "$TMP/backup-harness.service.parked" "$copy_fail_unit"
if [ "$copy_fail_status" -ne 0 ]; then ok; else bad "sync.sh install exited 0 after backup-harness.service deployment failed"; fi
if grep -Fq 'failed to deploy user unit backup-harness.service' <<<"$copy_fail_out"; then
  ok
else
  bad "failed user-unit copy did not name the stale unit:"$'\n'"$copy_fail_out"
fi

# Keep these explicit as well as covered by the generic loop: if either name is
# accidentally removed from UNITS, a loop derived from UNITS would skip it and
# report a false green instead of proving both JSM drop-ins were installed.
for u in jsm-auto-update.service.d/override.conf jsm-auto-update.service.d/zz-skills-localize.conf; do
  dst="$HOME/.config/systemd/user/$u"
  if [ -f "$dst" ] && cmp -s "$dst" "$REPO/systemd/$u"; then
    ok
  else
    bad "JSM drop-in: $u was not installed byte-for-byte"
  fi
done

jsm_override="$HOME/.config/systemd/user/jsm-auto-update.service.d/override.conf"
jsm_localize="$HOME/.config/systemd/user/jsm-auto-update.service.d/zz-skills-localize.conf"

if grep -q '^Environment=PATH=' "$jsm_override"; then
  bad "JSM drop-in: Environment=PATH must not hardcode a host home"
else
  ok
fi

mapfile -t jsm_success_statuses < <(grep '^SuccessExitStatus=' "$jsm_override")
if [ "${#jsm_success_statuses[@]}" -eq 1 ] \
   && [ "${jsm_success_statuses[0]-}" = 'SuccessExitStatus=' ]; then
  ok
else
  bad "JSM drop-in: SuccessExitStatus is not reset exactly once"
fi

mapfile -t jsm_exec_starts < <(grep '^ExecStart=' "$jsm_override")
if [ "${#jsm_exec_starts[@]}" -eq 2 ] \
   && [ "${jsm_exec_starts[0]-}" = 'ExecStart=' ] \
   && [ "${jsm_exec_starts[1]-}" = 'ExecStart=%h/.claude/scripts/jsm-auto-update-wrapper.sh' ]; then
  ok
else
  bad "JSM drop-in: ExecStart is not exactly reset to the tracked wrapper"
fi

mapfile -t jsm_stop_posts < <(grep '^ExecStopPost=' "$jsm_localize")
if [ "${#jsm_stop_posts[@]}" -eq 1 ] \
   && [ "${jsm_stop_posts[0]-}" = 'ExecStopPost=%h/.claude/scripts/skills-localize.sh apply' ]; then
  ok
else
  bad "JSM drop-in: policy reconciliation is not the sole unmasked ExecStopPost"
fi

# -- SYSTEM_UNITS deploy loop via sudo (#370's new install class, the change
#    that motivated dotfiles#379) ------------------------------------------
for u in $SYSTEM_UNITS; do
  dst="$CLAUDE_SYNC_SYSTEM_SYS_DIR/$u"
  if [ -f "$dst" ]; then ok; else bad "SYSTEM_UNITS: $u was not sudo-deployed to $dst"; fi
  # The tracked unit is a $HOME template (a system unit runs as root, where %h is /root, so
  # the installed copy must carry the absolute path): the deployed file must equal the
  # template rendered for this fixture account, independently of sync.sh's own renderer,
  # and carry no literal $HOME.
  mkdir -p "$(dirname "$TMP/rendered-system/$u")"
  sed -e "s|\$HOME/\.claude/|$CLAUDE_HOME/|g" -e "s|\$HOME/|$HOME/|g" "$REPO/systemd-system/$u" > "$TMP/rendered-system/$u"
  if [ -f "$dst" ] && cmp -s "$dst" "$TMP/rendered-system/$u"; then
    ok
  else
    bad "SYSTEM_UNITS: $u content differs from the repo template rendered for this account"
  fi
  if [ -f "$dst" ] && ! grep -q -F "\$HOME" "$dst"; then ok; else bad "SYSTEM_UNITS: $u was deployed with an unrendered \$HOME"; fi
  mode=$(stat -c '%a' "$dst" 2>/dev/null || echo MISSING)
  if [ "$mode" = 644 ]; then ok; else bad "SYSTEM_UNITS: $u deployed with mode $mode, expected 644"; fi
done
# The zram unit is the template that carries home paths: prove the rendering did something,
# not a vacuous equality of two files that never spelled $HOME.
if grep -q -F "ExecStart=\$HOME/.claude/scripts/zram-swap.sh start" "$REPO/systemd-system/zram-swap.service" \
   && grep -q -F "ExecStart=$CLAUDE_HOME/scripts/zram-swap.sh start" "$CLAUDE_SYNC_SYSTEM_SYS_DIR/zram-swap.service"; then
  ok
else
  bad "SYSTEM_UNITS: zram-swap.service's ExecStart was not rendered from the \$HOME template into the fixture harness home"
fi

# -- managed-settings lock deploy via sudo -----------------------------------
if [ -f "$CLAUDE_SYNC_MANAGED_LOCK" ]; then ok; else bad "MANAGED_LOCK: was not sudo-deployed to $CLAUDE_SYNC_MANAGED_LOCK"; fi
if [ -f "$CLAUDE_SYNC_MANAGED_LOCK" ] && cmp -s "$CLAUDE_SYNC_MANAGED_LOCK" "$REPO/managed-settings.json"; then
  ok
else
  bad "MANAGED_LOCK: content differs from the repo copy"
fi
if jq -e '
    .permissions.disableAutoMode == "disable"
    and .permissions.disableBypassPermissionsMode != "disable"
  ' "$CLAUDE_SYNC_MANAGED_LOCK" >/dev/null; then
  ok
else
  bad "MANAGED_LOCK: Auto mode remains available or bypassPermissions was disabled"
fi

# -- idempotence: a second install is a no-op, no new backup dir ------------
before=$(find "$CLAUDE_HOME/backups" -maxdepth 1 -mindepth 1 2>/dev/null | sort)
echo "=== sync.sh install (2nd run, idempotence) ===" >&2
out2=$("$SYNC" install 2>&1); status2=$?
if [ "$status2" -eq 0 ]; then ok; else bad "sync.sh install (2nd run) exited $status2:"$'\n'"$out2"; fi
after=$(find "$CLAUDE_HOME/backups" -maxdepth 1 -mindepth 1 2>/dev/null | sort)
if [ "$before" = "$after" ]; then
  ok
else
  bad "second install run created new backup entries under \$CLAUDE_HOME/backups -- not idempotent"
fi

# -- manifest/check mode sees a clean world ----------------------------------
echo "=== sync.sh check ===" >&2
check_out=$("$SYNC" check 2>&1); check_status=$?
if [ "$check_status" -eq 0 ]; then
  ok
else
  bad "sync.sh check reported drift after a fresh install:"$'\n'"$check_out"
fi

# -- host-declared hygiene posture (#408) --------------------------------------
# <overlay>/hygiene-posture is how a host keeps deletion on and its hygiene timers
# enabled across `sync.sh install`. This section runs on the clean, fully installed
# fixture above and puts the fixture back at its end. The overlay is the fixture's own
# ($HOV_STACK_OVERLAY, set at the top); the shim systemctl is the only manager.
echo "=== hygiene posture ===" >&2
hp_sys=$HOME/.config/systemd/user
hp_file=$HOV_STACK_OVERLAY/hygiene-posture
hp_stems_re='(wt-sweep|reclaim-sweep|docker-hygiene|pkg-cache-prune)\.timer'
hp_enabled_saved=$TMP/hp-enabled-timers.saved
cp "$SYSTEMCTL_ENABLED_TIMERS" "$hp_enabled_saved"
hp_log_mark() { wc -l <"$SYSTEMCTL_LOG"; }
hp_log_since() { tail -n +"$(($1 + 1))" "$SYSTEMCTL_LOG"; }
hp_dropins() { find "$hp_sys" -name 50-hygiene-posture.conf 2>/dev/null | sort; }
hp_tree() { hp_dropins | while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha256sum <"$f")"; done; }

# a. No posture file: install writes no drop-in and enables no hygiene timer.
[ ! -e "$hp_file" ] || bad "hygiene posture precondition: $hp_file exists"
hp_mark=$(hp_log_mark)
hp_none_out=$("$SYNC" install 2>&1); hp_none_status=$?
if [ "$hp_none_status" -eq 0 ]; then ok; else bad "install with no hygiene-posture file exited $hp_none_status:"$'\n'"$hp_none_out"; fi
if [ -z "$(hp_dropins)" ]; then ok; else bad "install with no hygiene-posture file wrote a posture drop-in: $(hp_dropins)"; fi
if hp_log_since "$hp_mark" | grep -Eq "$hp_stems_re"; then
  bad "install with no hygiene-posture file touched a hygiene timer: $(hp_log_since "$hp_mark" | grep -E "$hp_stems_re")"
else ok; fi
if grep -Eq "^$hp_stems_re\$" "$SYSTEMCTL_ENABLED_TIMERS"; then bad "install with no hygiene-posture file left a hygiene timer enabled"; else ok; fi
if grep -q 'hygiene' <<<"$hp_none_out"; then bad "install with no hygiene-posture file said something about hygiene posture:"$'\n'"$hp_none_out"; else ok; fi
hp_none_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -q 'hygiene posture' <<<"$hp_none_check"; then bad "check with no hygiene-posture file printed posture lines:"$'\n'"$hp_none_check"; else ok; fi

# b. A declared posture: exact drop-ins, exactly those timers, a hand-written override untouched.
mkdir -p "$hp_sys/wt-sweep.service.d"
printf '[Service]\nEnvironment=PUSH=1\n' >"$hp_sys/wt-sweep.service.d/override.conf"
cp "$hp_sys/wt-sweep.service.d/override.conf" "$TMP/hp-override.expected"
printf '%s\n' \
  '# smoke posture' \
  'wt-sweep DRY_RUN=0' \
  'wt-sweep OnCalendar=daily' \
  'reclaim-sweep RECLAIM_SWEEP_APPLY=1' >"$hp_file"
hp_mark=$(hp_log_mark)
hp_decl_out=$("$SYNC" install 2>&1); hp_decl_status=$?
if [ "$hp_decl_status" -eq 0 ]; then ok; else bad "install with a valid hygiene posture exited $hp_decl_status:"$'\n'"$hp_decl_out"; fi
hp_header="# Written by sync.sh install from the overlay's hygiene-posture file.
# Edit that file, not this one; install rewrites or removes this drop-in."
hp_expect_dropin() {
  local path=$1 expected=$2
  if [ -f "$path" ] && [ "$(cat "$path")" = "$expected" ]; then ok; else bad "posture drop-in $path is not as declared:"$'\n'"$(cat "$path" 2>&1)"; fi
}
hp_expect_dropin "$hp_sys/wt-sweep.service.d/50-hygiene-posture.conf" "$hp_header
[Service]
Environment=DRY_RUN=0"
hp_expect_dropin "$hp_sys/wt-sweep.timer.d/50-hygiene-posture.conf" "$hp_header
[Timer]
OnCalendar=
OnCalendar=daily"
hp_expect_dropin "$hp_sys/reclaim-sweep.service.d/50-hygiene-posture.conf" "$hp_header
[Service]
Environment=RECLAIM_SWEEP_APPLY=1"
if [ "$(hp_dropins | wc -l)" -eq 3 ]; then ok; else bad "expected exactly three posture drop-ins:"$'\n'"$(hp_dropins)"; fi
if [ "$(hp_log_since "$hp_mark" | grep -E "$hp_stems_re")" = "--user enable --now wt-sweep.timer reclaim-sweep.timer" ]; then
  ok
else
  bad "install did not enable exactly wt-sweep.timer and reclaim-sweep.timer in one call:"$'\n'"$(hp_log_since "$hp_mark" | grep -E "$hp_stems_re")"
fi
if grep -Fxq wt-sweep.timer "$SYSTEMCTL_ENABLED_TIMERS" && grep -Fxq reclaim-sweep.timer "$SYSTEMCTL_ENABLED_TIMERS" \
   && ! grep -Eq '^(docker-hygiene|pkg-cache-prune)\.timer$' "$SYSTEMCTL_ENABLED_TIMERS"; then
  ok
else
  bad "enabled timers after a declared posture are not exactly the declared hygiene pair:"$'\n'"$(cat "$SYSTEMCTL_ENABLED_TIMERS")"
fi
if grep -Fq 'hygiene timers enabled from overlay posture: wt-sweep reclaim-sweep' <<<"$hp_decl_out"; then ok; else bad "install did not report the enabled hygiene timers:"$'\n'"$hp_decl_out"; fi
if cmp -s "$hp_sys/wt-sweep.service.d/override.conf" "$TMP/hp-override.expected"; then ok; else bad "install changed a hand-written override.conf"; fi
hp_decl_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -q 'hygiene posture' <<<"$hp_decl_check"; then bad "check reported hygiene posture drift right after install:"$'\n'"$hp_decl_check"; else ok; fi
hp_again=$(hp_tree)
"$SYNC" install >/dev/null 2>&1
if [ "$hp_again" = "$(hp_tree)" ]; then ok; else bad "a second install changed the posture drop-ins"; fi

# c. Drift: a deleted drop-in, a not-enabled declared timer.
rm -f "$hp_sys/wt-sweep.service.d/50-hygiene-posture.conf"
hp_gone_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -Fq "DRIFT: hygiene posture: $hp_sys/wt-sweep.service.d/50-hygiene-posture.conf is not installed (sync.sh install)" <<<"$hp_gone_check"; then ok; else bad "check did not report the deleted posture drop-in:"$'\n'"$hp_gone_check"; fi
printf '[Service]\nEnvironment=DRY_RUN=1\n' >"$hp_sys/wt-sweep.service.d/50-hygiene-posture.conf"
hp_diff_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -Fq "DRIFT: hygiene posture: $hp_sys/wt-sweep.service.d/50-hygiene-posture.conf differs from the overlay declaration (sync.sh install)" <<<"$hp_diff_check"; then ok; else bad "check did not report the edited posture drop-in:"$'\n'"$hp_diff_check"; fi
"$SYNC" install >/dev/null 2>&1
hp_expect_dropin "$hp_sys/wt-sweep.service.d/50-hygiene-posture.conf" "$hp_header
[Service]
Environment=DRY_RUN=0"
grep -Fxv wt-sweep.timer "$SYSTEMCTL_ENABLED_TIMERS" >"$TMP/hp-enabled.next"; cp "$TMP/hp-enabled.next" "$SYSTEMCTL_ENABLED_TIMERS"
hp_off_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -Fq 'DRIFT: hygiene posture: wt-sweep.timer is declared but not enabled (sync.sh install)' <<<"$hp_off_check"; then ok; else bad "check did not report a declared timer that is not enabled:"$'\n'"$hp_off_check"; fi
if grep -Fq 'reclaim-sweep.timer is declared but not enabled' <<<"$hp_off_check"; then bad "check reported an enabled declared timer as not enabled"; else ok; fi
hp_unreach_check=$("$SYNC" check 2>&1)
if grep -Fq 'is declared but not enabled' <<<"$hp_unreach_check"; then bad "check judged timer state with no reachable user manager:"$'\n'"$hp_unreach_check"; else ok; fi
"$SYNC" install >/dev/null 2>&1

# d. Dropping a stem removes its generated drop-in and never disables its timer.
printf '%s\n' 'wt-sweep DRY_RUN=0' 'wt-sweep OnCalendar=daily' >"$hp_file"
hp_stale_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -Fq "DRIFT: hygiene posture: $hp_sys/reclaim-sweep.service.d/50-hygiene-posture.conf is no longer declared (sync.sh install removes it)" <<<"$hp_stale_check"; then ok; else bad "check did not report the no-longer-declared drop-in:"$'\n'"$hp_stale_check"; fi
hp_mark=$(hp_log_mark)
hp_drop_out=$("$SYNC" install 2>&1); hp_drop_status=$?
if [ "$hp_drop_status" -eq 0 ]; then ok; else bad "install after dropping a stem exited $hp_drop_status:"$'\n'"$hp_drop_out"; fi
if [ ! -e "$hp_sys/reclaim-sweep.service.d/50-hygiene-posture.conf" ]; then ok; else bad "install left the dropped stem's generated drop-in"; fi
if [ -f "$hp_sys/wt-sweep.service.d/50-hygiene-posture.conf" ] && [ -f "$hp_sys/wt-sweep.timer.d/50-hygiene-posture.conf" ]; then ok; else bad "install removed a still-declared drop-in"; fi
if hp_log_since "$hp_mark" | grep -E '(^| )(disable|stop)( |$)' | grep -Eq "$hp_stems_re"; then
  bad "install disabled or stopped a hygiene timer:"$'\n'"$(hp_log_since "$hp_mark" | grep -E "$hp_stems_re")"
else ok; fi
if grep -Fxq reclaim-sweep.timer "$SYSTEMCTL_ENABLED_TIMERS"; then ok; else bad "the dropped stem's timer is no longer enabled"; fi
if cmp -s "$hp_sys/wt-sweep.service.d/override.conf" "$TMP/hp-override.expected"; then ok; else bad "install changed a hand-written override.conf when removing a drop-in"; fi
if grep -Fq 'hygiene posture: removed' <<<"$hp_drop_out"; then ok; else bad "install did not report removing the stale drop-in:"$'\n'"$hp_drop_out"; fi

# e. An invalid file: nothing applied, nothing removed, nothing enabled, install red, check red.
printf '%s\n' 'wt-sweep DRYRUN=0' >"$hp_file"
grep -Fxv wt-sweep.timer "$SYSTEMCTL_ENABLED_TIMERS" >"$TMP/hp-enabled.next"; cp "$TMP/hp-enabled.next" "$SYSTEMCTL_ENABLED_TIMERS"
hp_tree_before=$(hp_tree)
hp_mark=$(hp_log_mark)
hp_bad_out=$("$SYNC" install 2>&1); hp_bad_status=$?
if [ "$hp_bad_status" -ne 0 ]; then ok; else bad "install with an invalid hygiene-posture file exited 0:"$'\n'"$hp_bad_out"; fi
if grep -Fq "ERROR: $hp_file is invalid; no hygiene posture applied (fix the file and re-run install)" <<<"$hp_bad_out"; then ok; else bad "install did not print the invalid-posture error:"$'\n'"$hp_bad_out"; fi
if grep -Fq 'hygiene-posture: unknown key for wt-sweep: wt-sweep DRYRUN=0' <<<"$hp_bad_out"; then ok; else bad "install did not print the line-level error:"$'\n'"$hp_bad_out"; fi
if [ "$hp_tree_before" = "$(hp_tree)" ]; then ok; else bad "install with an invalid hygiene-posture file wrote or removed a posture drop-in"; fi
if hp_log_since "$hp_mark" | grep -Eq "$hp_stems_re"; then bad "install with an invalid hygiene-posture file touched a hygiene timer"; else ok; fi
if grep -Fq 'install done.' <<<"$hp_bad_out"; then bad "install with an invalid hygiene-posture file still reported success"; else ok; fi
hp_bad_check=$(SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -Fq "DRIFT: hygiene posture: $hp_file is invalid (see errors above)" <<<"$hp_bad_check"; then ok; else bad "check did not report the invalid posture file:"$'\n'"$hp_bad_check"; fi

# f. An overlay path that is not absolute: the posture is unknown, not empty. Install
#    warns and leaves the drop-ins as they are (as ./setup reads nothing there), the file
#    at the relative path is never read, and check reports it.
printf '%s\n' 'wt-sweep DRY_RUN=0' 'wt-sweep OnCalendar=daily' >"$hp_file"
mkdir -p "$TMP/hp-relcwd/ovrel"
printf '%s\n' 'pkg-cache-prune' >"$TMP/hp-relcwd/ovrel/hygiene-posture"
hp_tree_before=$(hp_tree)
if [ -n "$hp_tree_before" ]; then ok; else bad "hygiene posture precondition: no drop-ins installed before the relative-overlay case"; fi
hp_mark=$(hp_log_mark)
hp_rel_out=$(cd "$TMP/hp-relcwd" && HOV_STACK_OVERLAY=ovrel "$SYNC" install 2>&1); hp_rel_status=$?
if [ "$hp_rel_status" -eq 0 ]; then ok; else bad "install with a relative overlay path exited $hp_rel_status:"$'\n'"$hp_rel_out"; fi
if grep -Fq 'WARN the overlay path is not absolute (HOV_STACK_OVERLAY or HOME); hygiene posture not read, its drop-ins left as they are' <<<"$hp_rel_out"; then ok; else bad "install did not warn about the relative overlay path:"$'\n'"$hp_rel_out"; fi
if [ "$hp_tree_before" = "$(hp_tree)" ]; then ok; else bad "install with a relative overlay path wrote or removed a posture drop-in"; fi
if hp_log_since "$hp_mark" | grep -Eq "$hp_stems_re"; then bad "install with a relative overlay path touched a hygiene timer"; else ok; fi
hp_rel_check=$(cd "$TMP/hp-relcwd" && HOV_STACK_OVERLAY=ovrel SYSTEMCTL_SHOW_REACHABLE=1 "$SYNC" check 2>&1)
if grep -Fq 'DRIFT: hygiene posture: the overlay path is not absolute (HOV_STACK_OVERLAY or HOME), so the posture was not read' <<<"$hp_rel_check"; then ok; else bad "check did not report the relative overlay path:"$'\n'"$hp_rel_check"; fi
rm -rf "$TMP/hp-relcwd"

# g. A directory where a drop-in goes: install refuses it and fails, rather than moving the
#    drop-in inside it and reporting it written.
printf '%s\n' 'wt-sweep DRY_RUN=0' 'wt-sweep OnCalendar=daily' 'reclaim-sweep RECLAIM_SWEEP_APPLY=1' >"$hp_file"
hp_dir=$hp_sys/reclaim-sweep.service.d/50-hygiene-posture.conf
mkdir -p "$hp_dir"
hp_mark=$(hp_log_mark)
hp_dir_out=$("$SYNC" install 2>&1); hp_dir_status=$?
if [ "$hp_dir_status" -ne 0 ]; then ok; else bad "install with a directory at a drop-in path exited 0:"$'\n'"$hp_dir_out"; fi
if grep -Fq "ERROR: $hp_dir is a directory; hygiene posture drop-in not written" <<<"$hp_dir_out"; then ok; else bad "install did not report the directory at the drop-in path:"$'\n'"$hp_dir_out"; fi
if [ -z "$(find "$hp_dir" -mindepth 1 2>/dev/null)" ]; then ok; else bad "install left files inside the directory at the drop-in path: $(find "$hp_dir" -mindepth 1)"; fi
if grep -Fq 'hygiene posture: wrote '"$hp_dir" <<<"$hp_dir_out"; then bad "install reported writing the drop-in it could not write"; else ok; fi
if hp_log_since "$hp_mark" | grep -Eq "$hp_stems_re"; then bad "install with a directory at a drop-in path enabled a hygiene timer"; else ok; fi
if grep -Fq 'install done.' <<<"$hp_dir_out"; then bad "install with a directory at a drop-in path still reported success"; else ok; fi
rmdir "$hp_dir" "$hp_sys/reclaim-sweep.service.d"

# Put the fixture back: no file means install removes what it generated, and only that.
rm -f "$hp_file"
"$SYNC" install >/dev/null 2>&1 || bad "install did not recover once the hygiene-posture file was removed"
if [ -z "$(hp_dropins)" ]; then ok; else bad "install left generated posture drop-ins after the file was removed: $(hp_dropins)"; fi
if cmp -s "$hp_sys/wt-sweep.service.d/override.conf" "$TMP/hp-override.expected"; then ok; else bad "removing the posture touched a hand-written override.conf"; fi
rm -rf "$hp_sys/wt-sweep.service.d"
cp "$hp_enabled_saved" "$SYSTEMCTL_ENABLED_TIMERS"

# -- native global fallback: actual install/reconcile/check interfaces -------
if jq -e '.autoCompactWindow == 300000 and .autoCompactEnabled == true' "$fresh_runtime_home/settings.json" >/dev/null \
   && jq -e '.autoCompactWindow == 300000' "$CLAUDE_HOME/settings.json" >/dev/null; then
  ok
else
  bad "fresh runtime/install seeds lack the 300K global fallback"
fi
cp "$CLAUDE_HOME/settings.json" "$TMP/global-live-baseline.json"
cp "$REPO/settings.json" "$TMP/global-canonical-baseline.json"
for unset_global in 'del(.autoCompactWindow)' '.autoCompactWindow = null'; do
  jq "$unset_global" "$TMP/global-live-baseline.json" >"$CLAUDE_HOME/settings.json"
  global_check=$("$SYNC" check 2>&1); global_check_status=$?
  if [ "$global_check_status" -ne 0 ] && grep -Fq 'DRIFT: settings.json' <<<"$global_check"; then ok; else bad "check missed unset global fallback: $unset_global"; fi
  # Cover the configured-install path too, not just direct reconciliation.
  global_adopt=$("$SYNC" install 2>&1); global_adopt_status=$?
  if [ "$global_adopt_status" -eq 0 ] && jq -e '.autoCompactWindow == 300000' "$CLAUDE_HOME/settings.json" >/dev/null; then ok; else bad "install did not adopt unset global fallback: $unset_global"$'\n'"$global_adopt"; fi
done
jq '.autoCompactWindow = 500000
    | .modelSettings["claude-bccf-route-quality"] = {autoCompactWindow: 500000, effortLevel: "xhigh"}' \
  "$TMP/global-live-baseline.json" >"$CLAUDE_HOME/settings.json"
global_override=$("$SYNC" reconcile-runtime-env 2>&1); global_override_status=$?
if [ "$global_override_status" -eq 0 ] && jq -e '
    .autoCompactWindow == 500000
    and .modelSettings["claude-bccf-route-quality"] == {autoCompactWindow: 500000, effortLevel: "xhigh"}
  ' "$CLAUDE_HOME/settings.json" >/dev/null; then ok; else bad "reconcile changed global/gateway overrides:"$'\n'"$global_override"; fi
global_override_check=$("$SYNC" check 2>&1); global_override_check_status=$?
if [ "$global_override_check_status" -eq 0 ]; then ok; else bad "check rejected valid global/gateway overrides:"$'\n'"$global_override_check"; fi
global_backups_before=$(find "$CLAUDE_HOME/backups" -type f -name settings.json | wc -l)
cp "$CLAUDE_HOME/settings.json" "$TMP/global-idempotent.json"
global_again=$("$SYNC" reconcile-runtime-env 2>&1); global_again_status=$?
if [ "$global_again_status" -eq 0 ] && grep -Fq 'already reconciled' <<<"$global_again" \
   && cmp -s "$TMP/global-idempotent.json" "$CLAUDE_HOME/settings.json" \
   && [ "$global_backups_before" = "$(find "$CLAUDE_HOME/backups" -type f -name settings.json | wc -l)" ]; then ok; else bad "global override reconciliation not idempotent:"$'\n'"$global_again"; fi
# Global adoption must not change saved pins/disable controls or obey the
# invoking shell's session-only overrides as a source of persisted policy.
jq '.model = "claude-bccf-route-quality" | .forceLoginOrgUUID = "fixture-org"
    | .autoCompactEnabled = false | .env.DISABLE_AUTO_COMPACT = "1"
    | .env.ANTHROPIC_MODEL = "fixture-backend-pin"' \
  "$TMP/global-idempotent.json" >"$CLAUDE_HOME/settings.json"
global_controls=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=600000 DISABLE_AUTO_COMPACT=1 "$SYNC" reconcile-runtime-env 2>&1); global_controls_status=$?
if [ "$global_controls_status" -eq 0 ] && jq -e '
    .autoCompactWindow == 500000 and .autoCompactEnabled == false
    and .model == "claude-bccf-route-quality" and .forceLoginOrgUUID == "fixture-org"
    and .env.DISABLE_AUTO_COMPACT == "1" and .env.ANTHROPIC_MODEL == "fixture-backend-pin"
    and (.env | has("CLAUDE_CODE_AUTO_COMPACT_WINDOW") | not)
  ' "$CLAUDE_HOME/settings.json" >/dev/null; then ok; else bad "global reconciliation changed pins/disable controls or persisted caller overrides:"$'\n'"$global_controls"; fi
# Non-null malformed values stay visible, even false (jq // would replace it).
for malformed_global in '50000' '2000000' '"300k"' '300000.5' 'false' '{}' '[]'; do
  jq --argjson value "$malformed_global" '.autoCompactWindow = $value | del(.env.PRO_GATE_ROUND_GUARD)' \
    "$TMP/global-live-baseline.json" >"$CLAUDE_HOME/settings.json"
  global_bad_out=$("$SYNC" reconcile-runtime-env 2>&1); global_bad_status=$?
  if [ "$global_bad_status" -eq 0 ] && jq -e --argjson value "$malformed_global" '
      .autoCompactWindow == $value and .env.PRO_GATE_ROUND_GUARD == "1"
    ' "$CLAUDE_HOME/settings.json" >/dev/null; then ok; else bad "malformed global was replaced or blocked unrelated reconciliation: $malformed_global"$'\n'"$global_bad_out"; fi
  global_bad_check=$("$SYNC" check 2>&1); global_bad_check_status=$?
  if [ "$global_bad_check_status" -ne 0 ] && grep -Fq 'DRIFT: settings.json' <<<"$global_bad_check"; then ok; else bad "check accepted malformed global: $malformed_global"; fi
done
cp "$TMP/global-live-baseline.json" "$CLAUDE_HOME/settings.json"
for bad_global in '50000' '2000000' '"300k"' '300000.5'; do
  jq --argjson value "$bad_global" '.autoCompactWindow = $value' \
    "$TMP/global-canonical-baseline.json" >"$REPO/settings.json"
  global_refusal=$("$SYNC" reconcile-runtime-env 2>&1); global_refusal_status=$?
  if [ "$global_refusal_status" -ne 0 ] \
     && cmp -s "$TMP/global-live-baseline.json" "$CLAUDE_HOME/settings.json"; then ok; else bad "invalid canonical global reconciled/wrote live: $bad_global"$'\n'"$global_refusal"; fi
  global_invalid_home=$(mktemp -d "$TMP/global-invalid-install.XXXXXX")
  global_install_refusal=$(CLAUDE_HOME="$global_invalid_home" "$SYNC" install 2>&1); global_install_refusal_status=$?
  if [ "$global_install_refusal_status" -ne 0 ] && [ -z "$(find "$global_invalid_home" -mindepth 1 -print -quit)" ]; then ok; else bad "invalid canonical global installed live artifacts: $bad_global"$'\n'"$global_install_refusal"; fi
  # Equal invalid values cannot pass the drift projection by equality alone.
  jq --argjson value "$bad_global" '.autoCompactWindow = $value' \
    "$TMP/global-live-baseline.json" >"$CLAUDE_HOME/settings.json"
  global_invalid_check=$("$SYNC" check 2>&1); global_invalid_check_status=$?
  if [ "$global_invalid_check_status" -ne 0 ] && grep -Fq 'DRIFT: settings.json' <<<"$global_invalid_check"; then ok; else bad "check accepted equal invalid global windows: $bad_global"; fi
  cp "$TMP/global-live-baseline.json" "$CLAUDE_HOME/settings.json"
done
cp "$TMP/global-canonical-baseline.json" "$REPO/settings.json"

# -- planted negative: an ABSENT user unit is drift, not silence -------------
# Before this, the UNITS check loop only compared units that were already
# installed, so a unit that had never been deployed -- or that was deleted --
# was skipped entirely and check stayed green. Four real units were missing on
# this host with no report. Absence is the failure mode that matters most,
# because it is exactly the state a stale install leaves behind.
echo "=== sync.sh check: missing user unit ===" >&2
victim=$(set -- $UNITS; echo "$1")
if [ -n "$victim" ] && [ -f "$HOME/.config/systemd/user/$victim" ]; then
  mv "$HOME/.config/systemd/user/$victim" "$TMP/$victim.parked"
  miss_out=$("$SYNC" check 2>&1); miss_status=$?
  mv "$TMP/$victim.parked" "$HOME/.config/systemd/user/$victim"

  if [ "$miss_status" -ne 0 ]; then ok; else bad "sync.sh check exited 0 with $victim absent"; fi
  if grep -qF "systemd/$victim is not installed" <<<"$miss_out"; then
    ok
  else
    bad "sync.sh check did not name the absent unit $victim:"$'\n'"$miss_out"
  fi

  # Restoring must return check to green -- proves the assertion above keyed on
  # the absence and not on some other drift the fixture was already carrying.
  restored_out=$("$SYNC" check 2>&1); restored_status=$?
  if [ "$restored_status" -eq 0 ]; then
    ok
  else
    bad "sync.sh check stayed red after restoring $victim:"$'\n'"$restored_out"
  fi
else
  bad "planted negative could not run: no installed unit from UNITS to remove"
fi

# -- planted negatives: CLAUDE_CODE_PLUGIN_DIRS is compared, and its folders are tested --
# A check() that stopped comparing the key, or compared only the string, would
# stay green here. Both negatives restore the fixture and prove check returns
# to green, so each assertion keys on the planted fault alone.
echo "=== sync.sh check: wrong live CLAUDE_CODE_PLUGIN_DIRS ===" >&2
live_mods_before=$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS' "$CLAUDE_HOME/settings.json")
jq '.env.CLAUDE_CODE_PLUGIN_DIRS = "/opt/elsewhere/some-mod"' "$CLAUDE_HOME/settings.json" > "$TMP/settings-wrong-mods.json"
cp "$TMP/settings-wrong-mods.json" "$CLAUDE_HOME/settings.json"
wrong_mods_out=$("$SYNC" check 2>&1); wrong_mods_status=$?
jq --arg v "$live_mods_before" '.env.CLAUDE_CODE_PLUGIN_DIRS = $v' "$CLAUDE_HOME/settings.json" > "$TMP/settings-restored-mods.json"
cp "$TMP/settings-restored-mods.json" "$CLAUDE_HOME/settings.json"
if [ "$wrong_mods_status" -ne 0 ]; then ok; else bad "sync.sh check exited 0 with a foreign live CLAUDE_CODE_PLUGIN_DIRS"; fi
case "$wrong_mods_out" in
  *"DRIFT: settings.json differs"*) ok ;;
  *) bad "sync.sh check did not report the foreign live CLAUDE_CODE_PLUGIN_DIRS as settings drift:"$'\n'"$wrong_mods_out" ;;
esac
restored_mods_out=$("$SYNC" check 2>&1); restored_mods_status=$?
if [ "$restored_mods_status" -eq 0 ]; then ok; else bad "sync.sh check stayed red after restoring CLAUDE_CODE_PLUGIN_DIRS:"$'\n'"$restored_mods_out"; fi

echo "=== sync.sh check: a mod manifest removed after install ===" >&2
mv "$REPO/mods/loop-breaker/.claude-plugin/plugin.json" "$TMP/loop-breaker.plugin.json.aside"
gone_manifest_out=$("$SYNC" check 2>&1); gone_manifest_status=$?
mv "$TMP/loop-breaker.plugin.json.aside" "$REPO/mods/loop-breaker/.claude-plugin/plugin.json"
if [ "$gone_manifest_status" -ne 0 ]; then ok; else bad "sync.sh check exited 0 with loop-breaker's manifest removed"; fi
case "$gone_manifest_out" in
  *"CLAUDE_CODE_PLUGIN_DIRS names"*"loop-breaker"*"plugin.json"*) ok ;;
  *) bad "sync.sh check did not name the mod whose manifest is gone:"$'\n'"$gone_manifest_out" ;;
esac
after_manifest_out=$("$SYNC" check 2>&1); after_manifest_status=$?
if [ "$after_manifest_status" -eq 0 ]; then ok; else bad "sync.sh check stayed red after restoring loop-breaker's manifest:"$'\n'"$after_manifest_out"; fi

# A malformed canonical list (trailing colon) maps to the same valid-looking
# value already live, because the split drops the empty field. check must
# validate the canonical spelling itself, as reconcile-runtime-env does.
echo "=== sync.sh check: malformed canonical CLAUDE_CODE_PLUGIN_DIRS ===" >&2
cp "$REPO/settings.json" "$TMP/settings-canonical.before-check-malformed"
jq '.env.CLAUDE_CODE_PLUGIN_DIRS += ":"' "$TMP/settings-canonical.before-check-malformed" > "$REPO/settings.json"
malformed_check_out=$("$SYNC" check 2>&1); malformed_check_status=$?
cp "$TMP/settings-canonical.before-check-malformed" "$REPO/settings.json"
if [ "$malformed_check_status" -ne 0 ]; then ok; else bad "sync.sh check exited 0 with a trailing-colon canonical CLAUDE_CODE_PLUGIN_DIRS"; fi
case "$malformed_check_out" in
  *"CLAUDE_CODE_PLUGIN_DIRS"*"empty entry"*) ok ;;
  *) bad "sync.sh check did not name the malformed canonical CLAUDE_CODE_PLUGIN_DIRS:"$'\n'"$malformed_check_out" ;;
esac
after_malformed_out=$("$SYNC" check 2>&1); after_malformed_status=$?
if [ "$after_malformed_status" -eq 0 ]; then ok; else bad "sync.sh check stayed red after restoring the canonical CLAUDE_CODE_PLUGIN_DIRS:"$'\n'"$after_malformed_out"; fi

# A present empty string is as invalid as a malformed list (reconcile rejects
# it), and an empty live copy normalizes to the same value, so check must key
# on the key's presence rather than on its value.
echo "=== sync.sh check: present-empty canonical CLAUDE_CODE_PLUGIN_DIRS ===" >&2
cp "$REPO/settings.json" "$TMP/settings-canonical.before-check-empty"
cp "$CLAUDE_HOME/settings.json" "$TMP/settings-live.before-check-empty"
jq '.env.CLAUDE_CODE_PLUGIN_DIRS = ""' "$TMP/settings-canonical.before-check-empty" > "$REPO/settings.json"
jq '.env.CLAUDE_CODE_PLUGIN_DIRS = ""' "$TMP/settings-live.before-check-empty" > "$CLAUDE_HOME/settings.json"
empty_check_out=$("$SYNC" check 2>&1); empty_check_status=$?
cp "$TMP/settings-canonical.before-check-empty" "$REPO/settings.json"
cp "$TMP/settings-live.before-check-empty" "$CLAUDE_HOME/settings.json"
if [ "$empty_check_status" -ne 0 ]; then ok; else bad "sync.sh check exited 0 with a present-empty canonical CLAUDE_CODE_PLUGIN_DIRS"; fi
case "$empty_check_out" in
  *"CLAUDE_CODE_PLUGIN_DIRS"*"is empty"*) ok ;;
  *) bad "sync.sh check did not name the present-empty canonical CLAUDE_CODE_PLUGIN_DIRS:"$'\n'"$empty_check_out" ;;
esac
after_empty_out=$("$SYNC" check 2>&1); after_empty_status=$?
if [ "$after_empty_status" -eq 0 ]; then ok; else bad "sync.sh check stayed red after restoring settings from the present-empty case:"$'\n'"$after_empty_out"; fi

# push must treat an absent canonical key as authoritative. Planted negative:
# a canonical copy that deliberately dropped the key, against a live copy that
# still carries it, must not have the live list copied back into the tracked file.
echo "=== sync.sh push: canonical CLAUDE_CODE_PLUGIN_DIRS removed ===" >&2
cp "$REPO/settings.json" "$TMP/settings-canonical.before-push-removal"
cp "$CLAUDE_HOME/settings.json" "$TMP/settings-live.before-push-removal"
jq 'del(.env.CLAUDE_CODE_PLUGIN_DIRS)' "$TMP/settings-canonical.before-push-removal" > "$REPO/settings.json"
# The canonical file already lacks the key before push runs, so "still lacks
# it" alone would pass a push that exited before its settings write. push must
# exit 0, and a canary only the live copy carries must land in the canonical
# copy, before the key's absence says anything about the preservation branch.
jq '.env.SMOKE_PUSH_CANARY = "copied by push"' "$TMP/settings-live.before-push-removal" > "$CLAUDE_HOME/settings.json"
# push's memory stage runs after the settings write and its auditor refuses a
# live root with no project memory (exit 2), which would leave the exit status
# saying nothing about the branch under test, so push gets one project memory
# of its own and a mirror of its own to copy it into.
push_memory_live=$TMP/push-memory-live
push_memory_mirror=$TMP/push-memory-mirror
mkdir -p "$push_memory_live/smoke/memory" "$push_memory_mirror"
printf '# Memory index\n' > "$push_memory_live/smoke/memory/MEMORY.md"
CLAUDE_MEMORY_LIVE_ROOT="$push_memory_live" CLAUDE_MEMORY_MIRROR_ROOT="$push_memory_mirror" \
  "$SYNC" push >"$TMP/push-removal.out" 2>&1; push_removal_status=$?
push_removal_has_key=$(jq -r '.env | has("CLAUDE_CODE_PLUGIN_DIRS")' "$REPO/settings.json")
push_removal_canary=$(jq -r '.env.SMOKE_PUSH_CANARY // empty' "$REPO/settings.json")
cp "$TMP/settings-canonical.before-push-removal" "$REPO/settings.json"
cp "$TMP/settings-live.before-push-removal" "$CLAUDE_HOME/settings.json"
if [ "$push_removal_status" -eq 0 ]; then ok; else bad "sync.sh push exited $push_removal_status in the fixture, so the removed-key branch was not proven reached:"$'\n'"$(cat "$TMP/push-removal.out")"; fi
if [ "$push_removal_canary" = "copied by push" ]; then ok; else bad "sync.sh push did not rewrite the canonical settings.json from the live copy (the removed-key branch was never reached):"$'\n'"$(cat "$TMP/push-removal.out")"; fi
if [ "$push_removal_has_key" = false ]; then ok; else bad "sync.sh push resurrected env.CLAUDE_CODE_PLUGIN_DIRS into a canonical copy that dropped it (push status $push_removal_status):"$'\n'"$(cat "$TMP/push-removal.out")"; fi

# -- memory mirror is opt-in (#346) --------------------------------------------
# A named mirror is the positive arm: the push above had CLAUDE_MEMORY_MIRROR_ROOT
# set and must have copied the live note into it. With the variable unset and no
# <checkout>/memory, push must copy nothing into the checkout (an untracked dir
# of a public repository) and check must say SKIP rather than report drift. The
# same live note is offered in every arm, so on the pre-#346 code the unset arms
# create $REPO/memory and print the drift line.
echo "=== memory mirror opt-in ===" >&2
if [ -f "$push_memory_mirror/smoke/MEMORY.md" ]; then ok; else bad "push with CLAUDE_MEMORY_MIRROR_ROOT named did not copy live memory into it:"$'\n'"$(cat "$TMP/push-removal.out")"; fi
if [ ! -e "$REPO/memory" ]; then ok; else bad "fixture precondition: $REPO/memory exists before the opt-out push"; fi
cp "$REPO/settings.json" "$TMP/settings-canonical.before-optout"
cp "$CLAUDE_HOME/settings.json" "$TMP/settings-live.before-optout"
env -u CLAUDE_MEMORY_MIRROR_ROOT CLAUDE_MEMORY_LIVE_ROOT="$push_memory_live" \
  "$SYNC" push >"$TMP/push-optout.out" 2>&1; push_optout_status=$?
cp "$TMP/settings-canonical.before-optout" "$REPO/settings.json"
cp "$TMP/settings-live.before-optout" "$CLAUDE_HOME/settings.json"
if [ "$push_optout_status" -eq 0 ]; then ok; else bad "sync.sh push with no mirror exited $push_optout_status:"$'\n'"$(cat "$TMP/push-optout.out")"; fi
if [ ! -e "$REPO/memory" ]; then ok; else bad "sync.sh push with no mirror named copied live memory into the checkout:"$'\n'"$(find "$REPO/memory" | head -5)"; fi
if grep -q 'memory not copied: no mirror at' "$TMP/push-optout.out"; then ok; else bad "sync.sh push with no mirror did not say it copied no memory:"$'\n'"$(cat "$TMP/push-optout.out")"; fi
optout_check=$(env -u CLAUDE_MEMORY_MIRROR_ROOT CLAUDE_MEMORY_LIVE_ROOT="$push_memory_live" "$SYNC" check 2>&1)
if grep -q 'DRIFT: memory differs' <<<"$optout_check"; then bad "sync.sh check with no mirror reported memory drift:"$'\n'"$optout_check"; else ok; fi
if grep -q 'SKIP: memory — no mirror at' <<<"$optout_check"; then ok; else bad "sync.sh check with no mirror did not print its memory SKIP line:"$'\n'"$optout_check"; fi
if [ ! -e "$REPO/memory" ]; then ok; else bad "sync.sh check with no mirror created $REPO/memory"; fi
# A named but empty mirror still opts in, so the same live note is drift.
mkdir -p "$TMP/optin-empty-mirror"
optin_check=$(CLAUDE_MEMORY_LIVE_ROOT="$push_memory_live" CLAUDE_MEMORY_MIRROR_ROOT="$TMP/optin-empty-mirror" "$SYNC" check 2>&1)
if grep -q 'DRIFT: memory differs' <<<"$optin_check"; then ok; else bad "sync.sh check with a named empty mirror did not report the uncopied note as drift:"$'\n'"$optin_check"; fi

# -- install must not write the tracked source tree --------------------------
# dotfiles#479: `install` runs unattended from a timer, and
# reconcile_dcg_hook used to re-point the dcg version pin by rewriting the
# TRACKED settings.json. That is the installer manufacturing the exact
# local modification that makes the NEXT fast-forward refuse — hourly. Purity is
# asserted over the WHOLE copied tree by checksum, not just settings.json, so a
# future writer anywhere in the copied tree trips this too.
echo "=== source-tree purity ===" >&2
PURE=$TMP/pure
PURE_HOME=$TMP/pure-home
mkdir -p "$PURE" "$PURE_HOME"
for e in "${DOTFILES_HARNESS[@]}"; do cp -a "$REPO/$e" "$PURE/$e"; done
cp -a "$REPO/config" "$PURE/config"
cp -a "$REPO/lib" "$PURE/lib"
cp -a "$REPO/hosts.tsv" "$PURE/hosts.tsv"

# Pin the canonical dcg hook to a version that is NOT the resolved binary, so the
# re-point path actually fires. With a pin that already matches, `install` has
# nothing to rewrite and this section would pass while asserting nothing.
pure_settings=$PURE/settings.json
pure_tmp=$TMP/pure-settings.json
if jq '(.. | objects | select((.command? // "") | (. == "$HOME/.local/bin/dcg" or startswith("$HOME/.local/lib/dcg/v"))) | .command)
       |= "$HOME/.local/lib/dcg/v0.0.1/dcg"' "$pure_settings" >"$pure_tmp" && [ -s "$pure_tmp" ]; then
  mv "$pure_tmp" "$pure_settings"
  pinned=$(jq -r '[.. | objects | select(.command? == "$HOME/.local/lib/dcg/v0.0.1/dcg")] | length' "$pure_settings")
  if [ "$pinned" -ge 1 ]; then ok; else bad "purity fixture: no dcg hook was pinned, so the re-point path cannot fire"; fi
else
  rm -f "$pure_tmp"
  bad "purity fixture: could not pin the canonical dcg hook"
  pinned=0
fi

pure_before=$(cd "$PURE" && find . -type f -exec sha256sum {} + | sort)
# CLAUDE_SYNC_CLAUDE_BIN names a missing CLI: with the hook block on, install would
# otherwise run the real `claude plugin install papercut@hov` from PATH on a dev box.
pure_out=$(env -u CLAUDE_SYNC_SKIP_HOOK_RECONCILE \
  HOME="$PURE_HOME" \
  CLAUDE_SYNC_CLAUDE_BIN="$TMP/no-claude" \
  CLAUDE_SYNC_SYSTEM_SYS_DIR="$TMP/pure-etc-systemd" \
  CLAUDE_SYNC_MANAGED_LOCK="$TMP/pure-etc-claude/managed-settings.json" \
  "$PURE/sync.sh" install 2>&1)
pure_after=$(cd "$PURE" && find . -type f -exec sha256sum {} + | sort)
# Deliberately NOT gated on install's exit code. On a host without the real dcg
# binary the reconcile can legitimately fail late, but the canonical rewrite this
# guards happens BEFORE that point — so purity must hold either way.
if [ "$pure_before" = "$pure_after" ]; then
  ok
else
  bad "sync.sh install modified its own source tree:"$'\n'"$(diff <(echo "$pure_before") <(echo "$pure_after") | head -20)"$'\n'"install said:"$'\n'"$pure_out"
fi

# The converse: the EXPLICIT verb migrates a versioned canonical to the symlink
# form and records NO version (dotfiles#1201). Before 2026-09-18 it wrote the
# promoted version into the tracked file; that write is what stranded the repo
# on a reaped version, so its absence is asserted, not assumed.
if [ "$pinned" -ge 1 ]; then
  env -u CLAUDE_SYNC_SKIP_HOOK_RECONCILE HOME="$PURE_HOME" \
    "$PURE/sync.sh" reconcile-dcg >/dev/null 2>&1
  still_pinned=$(jq -r '[.. | objects | select(.command? == "$HOME/.local/lib/dcg/v0.0.1/dcg")] | length' "$pure_settings")
  any_version=$(jq -r '[.. | objects | (.command? // "") | select(startswith("$HOME/.local/lib/dcg/v"))] | length' "$pure_settings")
  symlinked=$(jq -r '[.. | objects | select(.command? == "$HOME/.local/bin/dcg")] | length' "$pure_settings")
  if [ "$still_pinned" = "0" ] && [ "$any_version" = "0" ] && [ "$symlinked" -ge 1 ]; then
    ok
  else
    bad "sync.sh reconcile-dcg must migrate a versioned canonical dcg hook to the literal \$HOME/.local/bin/dcg and record no version (v0.0.1 left: $still_pinned, versioned: $any_version, symlink: $symlinked)"
  fi
fi

# -- every registered hook command resolves to a tracked file ----------------
# dotfiles#501/#454: the OOM guards ran live for two days out of
# ~/.claude/emergency-oom-guard/, a staging dir in nobody's repo. Every
# registration was valid and every hook fired, so nothing looked wrong — but a
# rebuild, or the next `install` that rewrote settings.json, would have removed
# the protection silently. `check` could not catch it either: it compares live
# settings against the repo copy, so a path BOTH sides agree on passes even
# when the file it names is tracked by no one.
#
# The floor: a hook command in the canonical settings.json must name a file git
# actually tracks, or one of the deliberate host-local exceptions below.
echo "=== hook registrations resolve to tracked files ===" >&2

# The real checkout — not the $TMP copy $REPO was rebound to at the top of this
# file. `git ls-files` is the whole point here, and that copy is not a repo.
SRC_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if git -C "$SRC_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  ok
else
  bad "hook-registration floor: $SRC_REPO is not a git checkout, so tracked-ness cannot be decided"
fi

# Deliberate host-local targets: real paths on the operator's box that are
# CORRECTLY absent from this repo. Anything not matching one of these is work
# that exists on exactly one machine.
HOST_LOCAL_OK=(
  # dcg ships as an external binary; the tracked file names its stable symlink
  # in the template's literal $HOME spelling and never a version (dotfiles#1201).
  '^\$HOME/\.local/bin/dcg$'
  # The per-identity routing tree (~/.local/share/claude-routing/<sha>/hooks/)
  # was allowed here while the 2026-08-26 rollout bundle carried its own copy
  # of codex-quota-guard; dotfiles#991 retired that duplicate registration, so
  # the entry is gone too (this floor fails on an allowlist entry that matches
  # nothing, by design).
)

# Mirrors sync.sh's hook_command_target so this floor and the reconcilers agree
# on what a command's target IS; a divergence here would guard the wrong string.
hook_target_of() {
  local cmd=$1 target
  target=$(printf '%s' "$cmd" | sed -n \
    -e 's|.*"\(/[^"]*\)".*|\1|p' \
    -e 's|.*"\(\$HOME/[^"]*\)".*|\1|p')
  [ -n "$target" ] || case $cmd in /*|'$HOME/'*) target=${cmd%% *} ;; esac
  printf '%s' "$target"
}

# One resolved absolute target per line. Commands naming no absolute path go to
# stderr rather than being dropped: they are out of scope for a tracked-ness
# check, but a growing pile of them would mean this floor is quietly checking
# less than it appears to.
hook_targets_of() {
  local settings=$1 cmd target
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    target=$(hook_target_of "$cmd")
    if [ -z "$target" ]; then
      echo "  (not path-resolvable, out of scope): $cmd" >&2
      continue
    fi
    printf '%s\n' "$target"
  done < <(jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command // empty' "$settings")
}

# One line per violation on stdout, nothing when every target is accounted for.
untracked_hook_targets() {
  local settings=$1 target rest allow matched
  while IFS= read -r target; do
    matched=0
    for allow in "${HOST_LOCAL_OK[@]}"; do
      grep -Eq "$allow" <<<"$target" && { matched=1; break; }
    done
    [ "$matched" -eq 0 ] || continue
    case $target in
      "$HOME/.claude/"*)
        # A live file rendered with this box's home (written before the tracked
        # file became a template) still maps into the checkout.
        rest=${target#"$HOME"/.claude/}
        git -C "$SRC_REPO" ls-files --error-unmatch "$rest" >/dev/null 2>&1 ||
          echo "$target -> $rest is tracked by nothing in this repo"
        ;;
      '$HOME/.claude/'*)
        rest=${target#\$HOME/.claude/}
        git -C "$SRC_REPO" ls-files --error-unmatch "$rest" >/dev/null 2>&1 ||
          echo "$target -> $rest is tracked by nothing in this repo"
        ;;
      *)
        echo "$target is neither under ~/.claude nor an allowed host-local path"
        ;;
    esac
  done < <(hook_targets_of "$settings")
}

hookreg_settings=$SRC_REPO/settings.json
hookreg_count=$(jq -r '[.hooks | to_entries[] | .value[]? | .hooks[]? | .command // empty] | length' "$hookreg_settings")
# Vacuity floor: a scan that finds no commands reports "clean" forever. There
# are 20 today; 10 leaves room to retire half of them without going blind.
if [ "$hookreg_count" -ge 10 ]; then
  ok
else
  bad "hook-registration floor found only $hookreg_count command(s) in $hookreg_settings — the scan is checking nothing"
fi

hookreg_violations=$(untracked_hook_targets "$hookreg_settings")
if [ -z "$hookreg_violations" ]; then
  ok
else
  bad "canonical settings.json registers hook targets that are not tracked:"$'\n'"$hookreg_violations"
fi

# Each exception must still match something. A host-local entry left behind
# after its hook is gone silently widens the allowlist for whatever lands on
# that path next.
# Match against RESOLVED targets, not raw command strings: `node "/path/x.js"`
# never matches a `^`-anchored path pattern, which would fail every exception
# whose hook is invoked through an interpreter.
hookreg_targets=$(hook_targets_of "$hookreg_settings" 2>/dev/null)
for allow in "${HOST_LOCAL_OK[@]}"; do
  if grep -Eq "$allow" <<<"$hookreg_targets"; then
    ok
  else
    bad "host-local allowlist entry matches no registration and should be removed: $allow"
  fi
done

# PLANTED NEGATIVE 1 — the exact #454 shape. Re-register a guard at the
# unversioned staging path this floor exists to catch; it must be reported.
hookreg_neg=$TMP/hookreg-negative.json
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"command":"node \"$HOME/.claude/emergency-oom-guard/hooks/PreToolUse/grep-cost-guard.js\""}]}]' \
  "$hookreg_settings" >"$hookreg_neg"
if untracked_hook_targets "$hookreg_neg" 2>/dev/null | grep -q 'emergency-oom-guard'; then
  ok
else
  bad "planted negative: a hook registered into an untracked staging dir was NOT reported"
fi

# PLANTED NEGATIVE 2 — a target outside ~/.claude that no exception covers.
hookreg_neg2=$TMP/hookreg-negative-2.json
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"command":"/opt/vendor-drop/some-hook"}]}]' \
  "$hookreg_settings" >"$hookreg_neg2"
if untracked_hook_targets "$hookreg_neg2" 2>/dev/null | grep -q '/opt/vendor-drop/some-hook'; then
  ok
else
  bad "planted negative: a hook outside ~/.claude and outside the allowlist was NOT reported"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — sync.sh install/check smoke: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — sync.sh install/check smoke: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
