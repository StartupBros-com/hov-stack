#!/usr/bin/env bash
# Black-box contract for harness-doctor section 8c (issue #424): live
# ~/.claude/hooks and ~/.claude/scripts resolving through a checkout parked on
# a non-default branch mean UNMERGED CODE RUNS LIVE in every session — the
# PR #419 fx-bridge incident, where feat/fx-skill-bridge's unreviewed
# plugin-auto-update.js executed against the real $HOME three minutes after
# commit because the main checkout was used as a work surface.
#
# PLANTED NEGATIVES: each contains() names the warning that disappears if the
# check — or one of its fail-closed arms (unresolvable live dir, undeterminable
# default branch) — is removed. Controls prove the default-branch and
# outside-any-checkout shapes stay quiet, and the mixed case pins both the
# per-checkout grouping and the pathspec scoping (a rogue file under scripts/
# must not be attributed to a home that only maps hooks/). Inward-vet lanes
# (2026-08-30): dirty or ahead-of-origin ON the default branch warns (same
# hazard, no branch switch), behind-only stays quiet (pins the three-dot
# diff), and a per-file symlink inside a non-checkout live dir fails closed
# instead of reading as no-exposure.
#
# Hermetic: fixture homes + throwaway git checkouts under /tmp mktemp scratch,
# PATH-stubbed systemctl/cass, no network, no live ~/.claude state.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/parked-checkout-doctor.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle'" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'" ;; *) ok ;; esac
}

NODE_DIR=$(dirname "$(command -v node)")
JQ_DIR=$(dirname "$(command -v jq)")
STUBBIN=$TMP/bin
mkdir -p "$STUBBIN"
TEST_PATH=$STUBBIN:$NODE_DIR:$JQ_DIR:/usr/bin:/bin

cat >"$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" is-enabled "*) exit 0 ;;
  *" is-active "*) echo active ;;
  *" ExecMainStatus "*) echo 0 ;;
  *" Result "*) echo success ;;
  *" list-unit-files "*) exit 1 ;;
esac
exit 0
STUB
cat >"$STUBBIN/cass" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"healthy":true,"health_level":"healthy","index":{"partial":false}}'
STUB
chmod +x "$STUBBIN/systemctl" "$STUBBIN/cass"

# Quiet fixtures for sections 27/28 so no run touches the operator's real
# watchlist or dispatcher state (same convention as harness-doctor-vacuity).
DTAB=$'\t'
printf '%s\n' "pcquiet${DTAB}active${DTAB}2026-08-30${DTAB}-${DTAB}fixture-src${DTAB}false${DTAB}quiet fixture" >"$TMP/deferral-quiet.tsv"
printf 'RUNG=0\n' >"$TMP/dispatcher-rung0.env"

GIT() { git -C "$1" -c user.email=fixture@test.invalid -c user.name=fixture "${@:2}"; }

# A throwaway "dotfiles-shaped" checkout on main, with local origin/main +
# origin/HEAD refs so the doctor can compare without any network.
make_checkout() {
  local dir=$1
  mkdir -p "$dir/hooks/SessionStart" "$dir/scripts"
  git -C "$dir" init -q -b main
  printf '%s\n' '// reviewed, merged hook' >"$dir/hooks/SessionStart/base.js"
  printf '%s\n' 'echo base' >"$dir/scripts/base.sh"
  GIT "$dir" add hooks scripts
  GIT "$dir" commit -q -m 'base: reviewed files'
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# make_home <name> <hooks-target> <scripts-target>  (empty target = plain dir)
make_home() {
  local home=$TMP/$1/home hooks_target=$2 scripts_target=$3
  mkdir -p "$home/.claude/projects" "$home/windows-home/.claude"
  if [ -n "$hooks_target" ]; then
    ln -s "$hooks_target" "$home/.claude/hooks"
  else
    mkdir -p "$home/.claude/hooks"
  fi
  if [ -n "$scripts_target" ]; then
    ln -s "$scripts_target" "$home/.claude/scripts"
  else
    mkdir -p "$home/.claude/scripts"
  fi
  printf '%s' "$home"
}

run_doctor() {
  local home=$1
  HOME="$home" \
  PATH="$TEST_PATH" \
  DOTFILES_REPO="$home/dotfiles" \
  CLAUDE_MEMORY_LIVE_ROOT="$home/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$home/dotfiles/memory" \
  CLAUDE_HARNESS_REPO="$home/empty-harness" \
  CLAUDE_WINDOWS_HOME="$home/windows-home" \
  CLAUDE_MANAGED_SETTINGS_LOCK="$home/.claude/installed-managed-settings.json" \
  CLAUDE_MANAGED_SETTINGS_REF="$home/dotfiles/managed-settings.json" \
  HARNESS_DOCTOR_SKIP_TESTS=1 \
  DEFERRAL_WATCHLIST_FILE="$TMP/deferral-quiet.tsv" \
  DISPATCHER_LEDGER_FILE="$TMP/absent-dispatcher-ledger.jsonl" \
  DISPATCHER_CONFIG="$TMP/dispatcher-rung0.env" \
    bash "$DOCTOR" 2>&1
}

# --- fixtures ----------------------------------------------------------------

CO_DEFAULT=$TMP/co-default
make_checkout "$CO_DEFAULT"

# The incident shape: main checkout parked on a feature branch carrying an
# unreviewed committed hook AND an untracked script (both lanes must be named).
CO_PARKED=$TMP/co-parked
make_checkout "$CO_PARKED"
GIT "$CO_PARKED" checkout -q -b feat/fx-skill-bridge
printf '%s\n' '// UNREVIEWED — live in every session' \
  >"$CO_PARKED/hooks/SessionStart/plugin-auto-update.js"
GIT "$CO_PARKED" add hooks/SessionStart/plugin-auto-update.js
GIT "$CO_PARKED" commit -q -m 'unreviewed hook on a parked branch'
printf '%s\n' 'echo untracked' >"$CO_PARKED/scripts/rogue-untracked.sh"

# Parked branch with zero delta under the live dirs: still a tripwire (the
# next commit goes live unreviewed), but with distinct wording.
CO_PARKED_CLEAN=$TMP/co-parked-clean
make_checkout "$CO_PARKED_CLEAN"
GIT "$CO_PARKED_CLEAN" checkout -q -b feat/parked-clean

# Dirty ON the default branch: a tracked hook edited in place plus an
# untracked script, no branch switch, nothing committed — the inward-vet
# high-severity finding (same blast radius as the incident, previously ok'd).
CO_DIRTY_MAIN=$TMP/co-dirty-main
make_checkout "$CO_DIRTY_MAIN"
printf '%s\n' '// edited in place on main, never committed' >>"$CO_DIRTY_MAIN/hooks/SessionStart/base.js"
printf '%s\n' 'echo untracked-on-main' >"$CO_DIRTY_MAIN/scripts/rogue-on-main.sh"

# Committed straight to main, never pushed: ahead of origin/main by one
# unreviewed commit while sitting on the default branch.
CO_AHEAD_MAIN=$TMP/co-ahead-main
make_checkout "$CO_AHEAD_MAIN"
printf '%s\n' '// committed straight to main, never pushed' >>"$CO_AHEAD_MAIN/hooks/SessionStart/base.js"
GIT "$CO_AHEAD_MAIN" add hooks/SessionStart/base.js
GIT "$CO_AHEAD_MAIN" commit -q -m 'unpushed commit directly on main'

# Merely BEHIND origin/main with a clean tree: reviewed code, just stale —
# must stay quiet. This is the planted negative for the three-dot diff; a
# two-dot comparison would false-warn on every stale-but-clean launch pad.
CO_BEHIND_MAIN=$TMP/co-behind-main
make_checkout "$CO_BEHIND_MAIN"
printf '%s\n' '// reviewed upstream change' >>"$CO_BEHIND_MAIN/hooks/SessionStart/base.js"
GIT "$CO_BEHIND_MAIN" add hooks/SessionStart/base.js
GIT "$CO_BEHIND_MAIN" commit -q -m 'upstream change'
git -C "$CO_BEHIND_MAIN" update-ref refs/remotes/origin/main HEAD
git -C "$CO_BEHIND_MAIN" reset -q --hard HEAD~1

CO_DETACHED=$TMP/co-detached
make_checkout "$CO_DETACHED"
GIT "$CO_DETACHED" checkout -q --detach

# No origin/HEAD, no origin/main, no origin/master: the check cannot compare
# and must fail closed rather than read as quiet.
CO_NO_DEFAULT=$TMP/co-no-default
make_checkout "$CO_NO_DEFAULT"
git -C "$CO_NO_DEFAULT" symbolic-ref --delete refs/remotes/origin/HEAD
git -C "$CO_NO_DEFAULT" update-ref -d refs/remotes/origin/main

# --- C1: control — both live dirs resolve through a default-branch checkout --
C1_HOME=$(make_home c1 "$CO_DEFAULT/hooks" "$CO_DEFAULT/scripts")
C1_OUT=$(run_doctor "$C1_HOME")
contains "$C1_OUT" "on default branch 'main'" "C1 default-branch checkout named ok"
contains "$C1_OUT" "live hooks/scripts resolve through default-branch checkouts only" "C1 section clean line"
omits "$C1_OUT" "parked on branch" "C1 no parked warning on default branch"
omits "$C1_OUT" "parked-checkout tripwire could not examine" "C1 no fail-closed warning when resolvable"

# --- C2: the incident — parked branch, unreviewed files live ----------------
C2_HOME=$(make_home c2 "$CO_PARKED/hooks" "$CO_PARKED/scripts")
C2_OUT=$(run_doctor "$C2_HOME")
contains "$C2_OUT" "parked on branch 'feat/fx-skill-bridge'" "C2 parked branch named"
contains "$C2_OUT" "~/.claude/hooks, ~/.claude/scripts" "C2 both live dirs grouped into one checkout warning"
contains "$C2_OUT" "differ from origin/main" "C2 delta measured against origin default"
contains "$C2_OUT" "unreviewed: hooks/SessionStart/plugin-auto-update.js,scripts/rogue-untracked.sh" "C2 committed + untracked live files named inside 8c's own warn (not section 8's orphan line)"
omits "$C2_OUT" "live hooks/scripts resolve through default-branch checkouts only" "C2 clean line suppressed"

# --- C3: parked branch, zero delta — still a tripwire, distinct wording ------
C3_HOME=$(make_home c3 "$CO_PARKED_CLEAN/hooks" "$CO_PARKED_CLEAN/scripts")
C3_OUT=$(run_doctor "$C3_HOME")
contains "$C3_OUT" "parked on branch 'feat/parked-clean'" "C3 clean parked branch still named"
contains "$C3_OUT" "no live hooks/scripts files differ from origin/main yet" "C3 zero-delta wording"
omits "$C3_OUT" "run in EVERY session unreviewed:" "C3 no fabricated file list"

# --- C4: detached HEAD is parked too ----------------------------------------
C4_HOME=$(make_home c4 "$CO_DETACHED/hooks" "$CO_DETACHED/scripts")
C4_OUT=$(run_doctor "$C4_HOME")
contains "$C4_OUT" "parked at detached HEAD" "C4 detached HEAD warned"

# --- C5: default branch undeterminable — fail closed, never quiet -----------
C5_HOME=$(make_home c5 "$CO_NO_DEFAULT/hooks" "$CO_NO_DEFAULT/scripts")
C5_OUT=$(run_doctor "$C5_HOME")
contains "$C5_OUT" "default branch cannot be determined" "C5 cannot-compare fails closed"
omits "$C5_OUT" "live hooks/scripts resolve through default-branch checkouts only" "C5 clean line suppressed"

# --- C6: dangling live dir — fail closed, never quiet ------------------------
C6_HOME=$(make_home c6 "$CO_DEFAULT/hooks" "$TMP/no-such-scripts")
C6_OUT=$(run_doctor "$C6_HOME")
contains "$C6_OUT" "live ~/.claude/scripts cannot be resolved to a directory" "C6 dangling live dir fails closed"
contains "$C6_OUT" "on default branch 'main'" "C6 resolvable sibling still examined"
omits "$C6_OUT" "live ~/.claude/hooks cannot be resolved" "C6 resolvable sibling not misreported"

# --- C7: plain dirs outside any checkout — no exposure, stays quiet ---------
C7_HOME=$(make_home c7 "" "")
C7_OUT=$(run_doctor "$C7_HOME")
contains "$C7_OUT" "resolves outside any git checkout" "C7 outside-git shape disclosed"
contains "$C7_OUT" "live hooks/scripts resolve through default-branch checkouts only" "C7 section clean line"
omits "$C7_OUT" "parked on branch" "C7 no parked warning without a checkout"

# --- C8: mixed — grouping and pathspec scoping -------------------------------
# hooks through the parked checkout, scripts through the default one: the
# parked warning must be scoped to hooks, so the rogue untracked file
# under scripts (a dir this home does NOT map) must not be attributed.
C8_HOME=$(make_home c8 "$CO_PARKED/hooks" "$CO_DEFAULT/scripts")
C8_OUT=$(run_doctor "$C8_HOME")
contains "$C8_OUT" "parked on branch 'feat/fx-skill-bridge'" "C8 parked checkout warned"
contains "$C8_OUT" "unreviewed: hooks/SessionStart/plugin-auto-update.js — merge the branch" "C8 hooks delta named inside 8c's own warn"
omits "$C8_OUT" "rogue-untracked.sh" "C8 unmapped scripts dir not attributed (pathspec scoping)"
contains "$C8_OUT" "on default branch 'main'" "C8 default-branch sibling ok"

# --- C9: dirty ON the default branch — same hazard, no branch switch --------
C9_HOME=$(make_home c9 "$CO_DIRTY_MAIN/hooks" "$CO_DIRTY_MAIN/scripts")
C9_OUT=$(run_doctor "$C9_HOME")
contains "$C9_OUT" "on default branch 'main' BUT 2 live file(s) differ from origin/main" "C9 dirty-on-default warned"
contains "$C9_OUT" "unreviewed: hooks/SessionStart/base.js,scripts/rogue-on-main.sh" "C9 modified + untracked files named"
omits "$C9_OUT" "parked on branch" "C9 not misreported as parked"
omits "$C9_OUT" "live hooks/scripts resolve through default-branch checkouts only" "C9 clean line suppressed"

# --- C9b: committed straight to main, never pushed ---------------------------
C9B_HOME=$(make_home c9b "$CO_AHEAD_MAIN/hooks" "$CO_AHEAD_MAIN/scripts")
C9B_OUT=$(run_doctor "$C9B_HOME")
contains "$C9B_OUT" "on default branch 'main' BUT 1 live file(s) differ from origin/main" "C9b unpushed commit on default warned"
contains "$C9B_OUT" "hooks/SessionStart/base.js" "C9b unpushed committed file named"
omits "$C9B_OUT" "parked on branch" "C9b not misreported as parked"

# --- C9c: merely BEHIND origin with a clean tree — reviewed, stays quiet -----
C9C_HOME=$(make_home c9c "$CO_BEHIND_MAIN/hooks" "$CO_BEHIND_MAIN/scripts")
C9C_OUT=$(run_doctor "$C9C_HOME")
contains "$C9C_OUT" "(no live delta vs origin/main)" "C9c behind-only reads clean (three-dot diff)"
omits "$C9C_OUT" "live file(s) differ from origin/main" "C9c stale-but-reviewed code never reads as unreviewed"

# --- C10: per-file symlink inside a non-checkout live dir — fail closed ------
C10_HOME=$(make_home c10 "" "$CO_DEFAULT/scripts")
ln -s "$CO_PARKED/hooks/SessionStart/plugin-auto-update.js" "$C10_HOME/.claude/hooks/sneaky-link.js"
C10_OUT=$(run_doctor "$C10_HOME")
contains "$C10_OUT" "contains 1 symlink(s) — per-file symlinks cannot be attributed" "C10 nested symlink fails closed"
omits "$C10_OUT" "~/.claude/hooks resolves outside any git checkout" "C10 no false outside-git all-clear"
omits "$C10_OUT" "live hooks/scripts resolve through default-branch checkouts only" "C10 clean line suppressed"

if [ "$fail" -ne 0 ]; then
  echo "FAILED — harness-doctor parked-checkout: $pass passed, $fail failed" >&2
  exit 1
fi
echo "ok — harness-doctor parked-checkout: $pass/$pass assertions passed"
