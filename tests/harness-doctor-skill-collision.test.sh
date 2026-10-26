#!/usr/bin/env bash
# Black-box contract for harness-doctor section 7's skill-name collision check
# (dotfiles#1247): a skill directory named like a built-in slash command
# shadows the command. Measured 2026-09-20: Warp's skill-doctor, copied to
# skills/skill-doctor in a throwaway config dir, answered /skill-doctor instead
# of the built-in usage report (docs/vets/2026-09-20-warp-skill-doctor-harness-vet.md).
#
# PLANTED NEGATIVE: skills/skill-doctor beside an innocent skill. HONEST
# CONTROL: two innocent skills, which must stay quiet and be counted. VACUITY:
# a home with no skill directories at all must warn, never pass silently.
#
# Hermetic: every home is under /tmp; systemctl and cass are PATH stubs;
# nothing reads or writes the operator's ~/.claude, ~/.agents or ~/.codex.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-skill-collision.XXXXXX)
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
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBBIN/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBBIN/cass"
chmod +x "$STUBBIN/systemctl" "$STUBBIN/cass"
JQ_DIR=$(dirname "$(command -v jq)")
NODE_DIR=$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")
TEST_PATH=$STUBBIN:$JQ_DIR:$NODE_DIR:/usr/bin:/bin

# make_home <name> [skill-dir...]: a fixture home whose ~/.claude/skills holds
# one minimal skill per name given. Prints the home path.
make_home() {
  local name=$1; shift
  local home=$TMP/$name d
  mkdir -p "$home/dotfiles" "$home/.claude"
  for d in "$@"; do
    mkdir -p "$home/.claude/skills/$d"
    printf '# %s\n' "$d" >"$home/.claude/skills/$d/SKILL.md"
  done
  printf '%s' "$home"
}

# Only section 7 is under test; every other section runs against the same
# fixture and is free to warn.
section_7() {
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
    bash "$DOCTOR" 2>&1 | sed -n '/== 7\./,/== 8\./p'
}
: >"$TMP/deferral-quiet.tsv"; : >"$TMP/dispatcher-quiet.jsonl"; printf 'RUNG=0\n' >"$TMP/dispatcher-quiet.env"

# Honest control: two innocent skills, counted, no warning.
h=$(make_home clean my-tool another-tool)
out=$(section_7 "$h")
contains "$out" "no skill shadows a built-in slash command (2 dirs)" "clean: ok line carries the count"
omits "$out" "shadows it" "clean: no collision warning"

# Planted negative: a skill named like the built-in /skill-doctor.
h=$(make_home planted my-tool skill-doctor)
out=$(section_7 "$h")
contains "$out" "WARN: skill 'skill-doctor'" "planted: collision warned by name"
contains "$out" "Check which one answers /skill-doctor here" "planted: remedy asks to verify, not to assume"
omits "$out" "ok: skills structurally sound" "planted: section not reported ok"

# Planted negative on a second root and a second name: ~/.codex/skills/run.
h=$(make_home codex-planted my-tool)
mkdir -p "$h/.codex/skills/run"; printf '# run\n' >"$h/.codex/skills/run/SKILL.md"
out=$(section_7 "$h")
contains "$out" "WARN: skill 'run'" "codex root: collision warned"
omits "$out" "scanned zero skill directories" "codex root: second root counted"

# Honest control with glob characters in a directory name: literal compare, no warning.
h=$(make_home globby my-tool)
mkdir -p "$h/.claude/skills/star*name"; printf '# g\n' >"$h/.claude/skills/star*name/SKILL.md"
out=$(section_7 "$h")
omits "$out" "shares its name" "glob-character name: no collision warning"
contains "$out" "(2 dirs)" "glob-character name: counted"

# Vacuity: no skill directories at all must not pass silently.
h=$(make_home empty)
out=$(section_7 "$h")
contains "$out" "scanned zero skill directories" "vacuity: zero-scan warned"

echo "harness-doctor-skill-collision: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
