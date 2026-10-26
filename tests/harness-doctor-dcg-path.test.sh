#!/usr/bin/env bash
# Black-box contract for harness-doctor section 11b (dotfiles#1201): the tracked
# settings.json names the stable dcg symlink in the template's literal $HOME
# spelling, never a version and never a rendered home; the live settings.json
# names the binary that symlink resolves to.
#
# PLANTED NEGATIVES, each differing from the clean fixture in exactly one
# dimension: a tracked file that carries a version (the 2026-08-28..09-17 drift
# that stranded the repo on a reaped v0.13.3), a live hook that names the
# previous version after a promote, and a live hook whose binary is gone (the
# fail-OPEN case a fresh install from a stale pin would wire). A live hook
# spelled as the symlink is the honest control: it fires the same binary, so
# the check compares RESOLVED paths and must stay quiet.
#
# Hermetic: every home, repo, and binary is under /tmp; systemctl and cass are
# PATH stubs; nothing reads or writes the operator's ~/.claude or ~/.local.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-dcg-path.XXXXXX)
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

STUBBIN=$TMP/bin
mkdir -p "$STUBBIN"
cat >"$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$STUBBIN/cass" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUBBIN/systemctl" "$STUBBIN/cass"
JQ_DIR=$(dirname "$(command -v jq)")
NODE_DIR=$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")
TEST_PATH=$STUBBIN:$JQ_DIR:$NODE_DIR:/usr/bin:/bin

# make_home <name> <tracked-dcg-command> <live-dcg-command> <versions...>
#   Builds a fixture home whose dotfiles copy names <tracked>, whose live copy
#   names <live>, and whose ~/.local/lib/dcg holds one fake binary per version
#   with ~/.local/bin/dcg -> the LAST version given. Prints the home path.
make_home() {
  local name=$1 tracked=$2 live=$3; shift 3
  local home=$TMP/$name v last=""
  mkdir -p "$home/dotfiles" "$home/.claude" "$home/.local/bin"
  for v in "$@"; do
    mkdir -p "$home/.local/lib/dcg/$v"
    printf '#!/bin/sh\nexit 0\n' >"$home/.local/lib/dcg/$v/dcg"
    chmod +x "$home/.local/lib/dcg/$v/dcg"
    last=$v
  done
  [ -z "$last" ] || ln -sfn "$home/.local/lib/dcg/$last/dcg" "$home/.local/bin/dcg"
  jq -n --arg cmd "$tracked" '{permissions:{allow:[]},hooks:{PreToolUse:[{matcher:"Bash|PowerShell",hooks:[{type:"command",command:$cmd}]}]}}' \
    >"$home/dotfiles/settings.json"
  jq -n --arg cmd "$live" '{permissions:{allow:[]},hooks:{PreToolUse:[{matcher:"Bash|PowerShell",hooks:[{type:"command",command:$cmd}]}]}}' \
    >"$home/.claude/settings.json"
  printf '%s' "$home"
}

# Only section 11b is under test; every other section runs against the same
# empty fixture and is free to warn.
section_11b() {
  local home=$1
  HOME="$home" \
  PATH="$TEST_PATH" \
  DOTFILES_REPO="$home/dotfiles" \
  CLAUDE_MEMORY_LIVE_ROOT="$home/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$home/dotfiles/memory" \
  CLAUDE_HARNESS_REPO="$home/dotfiles" \
  CLAUDE_WINDOWS_HOME="$home/windows-home" \
  CLAUDE_MANAGED_SETTINGS_LOCK="$home/.claude/installed-managed-settings.json" \
  CLAUDE_MANAGED_SETTINGS_REF="$home/dotfiles/managed-settings.json" \
  HARNESS_DOCTOR_SKIP_TESTS=1 \
  SYNC_EXAMINED=1 SYNC_STATUS=0 CODEX_OUTPUT="in sync" CODEX_STATUS=0 \
  COLLISION_OUTPUT="" COLLISION_STATUS=0 SWEEP_OUTPUT="" SWEEP_STATUS=0 \
  DEFERRAL_WATCHLIST_FILE="$TMP/deferral-quiet.tsv" \
  DISPATCHER_LEDGER_FILE="$TMP/dispatcher-quiet.jsonl" \
  DISPATCHER_CONFIG="$TMP/dispatcher-quiet.env" \
    bash "$DOCTOR" 2>&1 | sed -n '/== 11b\./,/== 12\./p'
}
: >"$TMP/deferral-quiet.tsv"; : >"$TMP/dispatcher-quiet.jsonl"; printf 'RUNG=0\n' >"$TMP/dispatcher-quiet.env"

# The tracked copy spells the symlink with the template's literal $HOME.
SYM='$HOME/.local/bin/dcg'

# Clean: repo names the symlink, live names the resolved current version.
h=$(make_home clean "$SYM" "$TMP/clean/.local/lib/dcg/v1.0.0/dcg" v0.9.0 v1.0.0)
out=$(section_11b "$h")
contains "$out" "ok: dcg hook: repo names the symlink; live names $h/.local/lib/dcg/v1.0.0/dcg" "clean fixture ok line"
omits "$out" "WARN:" "clean fixture warns nothing in 11b"

# Planted: the tracked copy carries a version (the reaped-pin drift).
h=$(make_home tracked-versioned '$HOME/.local/lib/dcg/v0.13.3/dcg' "$TMP/tracked-versioned/.local/lib/dcg/v1.0.0/dcg" v1.0.0)
out=$(section_11b "$h")
contains "$out" 'WARN: tracked settings.json names a dcg hook command other than the template symlink ($HOME/.local/lib/dcg/v0.13.3/dcg)' "tracked version is warned"
contains "$out" "reconcile-dcg migrates it" "tracked version names the migration"
omits "$out" "ok: dcg hook" "tracked version is not reported ok"

# Planted: the tracked copy carries a rendered home (a live file copied back over
# the template). The repo must name the literal $HOME form, never one user's home.
h=$(make_home tracked-rendered "/home/someone/.local/bin/dcg" "$TMP/tracked-rendered/.local/lib/dcg/v1.0.0/dcg" v1.0.0)
out=$(section_11b "$h")
contains "$out" "WARN: tracked settings.json names a dcg hook command other than the template symlink (/home/someone/.local/bin/dcg)" "tracked rendered home is warned"
omits "$out" "ok: dcg hook" "tracked rendered home is not reported ok"

# Planted: live still names the previous version after a promote.
h=$(make_home live-stale "$SYM" "$TMP/live-stale/.local/lib/dcg/v0.9.0/dcg" v0.9.0 v1.0.0)
out=$(section_11b "$h")
contains "$out" "but the installed guard is $h/.local/lib/dcg/v1.0.0/dcg: a promote did not re-point" "stale live version is warned"
omits "$out" "ok: dcg hook" "stale live version is not reported ok"

# Planted: live names a binary that is gone (fail-OPEN).
h=$(make_home live-missing "$SYM" "$TMP/live-missing/.local/lib/dcg/v0.0.0/dcg" v1.0.0)
out=$(section_11b "$h")
contains "$out" "names a missing binary ($h/.local/lib/dcg/v0.0.0/dcg): the guard fails OPEN" "missing live binary is warned"
omits "$out" "a promote did not re-point" "a missing binary is not also reported as stale"

# Control: live spelled as the symlink resolves to the installed binary; quiet.
h=$(make_home live-symlink "$SYM" "$TMP/live-symlink/.local/bin/dcg" v1.0.0)
out=$(section_11b "$h")
omits "$out" "WARN:" "symlink-spelled live hook is accepted (resolved compare)"
contains "$out" "ok: dcg hook: repo names the symlink" "symlink-spelled live hook reports ok"

if [ "$fail" -ne 0 ]; then
  echo "FAILED — harness-doctor dcg path: $pass passed, $fail failed" >&2
  exit 1
fi
echo "ok — harness-doctor dcg path: $pass/$pass assertions passed"
