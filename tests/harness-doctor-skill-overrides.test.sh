#!/usr/bin/env bash
# Black-box contract for harness-doctor section 13: every skillOverrides key
# resolves to a skill Claude Code can actually list. Three shapes resolve: a
# user skill dir (~/.claude/skills/<key>), a claude.ai-synced skill
# ('anthropic-skills:<name>' under skills/synced/<account>_<org>/<name>/), and
# a bundled skill with no dir at all (keybindings-help, claude-api). Before
# 2026-09-23 the last two warned as stale ghosts, so the four live
# anthropic-skills:* overrides and claude-api raised five false warnings
# every run.
#
# PLANTED NEGATIVES: a synced key whose skill is gone, a synced key whose name
# carries a glob character (must be tested literally, never expanded), a plain
# ghost, and a key whose skill gained a '-local' suffix. HONEST CONTROL: user,
# synced, and bundled keys together, at the 60-entry corpus floor, stay quiet.
#
# Hermetic: every home is under /tmp; systemctl and cass are PATH stubs;
# nothing reads or writes the operator's ~/.claude.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-skill-overrides.XXXXXX)
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

SYNCED_ROOT=acct_org

# make_home <name> [extra-key...]: a fixture home with 60 user skill dirs
# (fill-00..fill-59, all overridden, so the corpus floor holds), one synced
# skill 'pdf', and a skillOverrides map of the fillers plus every extra key.
# Prints the home path.
make_home() {
  local name=$1; shift
  local home=$TMP/$name i
  mkdir -p "$home/dotfiles" "$home/.claude/skills/synced/$SYNCED_ROOT/pdf"
  printf '# pdf\n' >"$home/.claude/skills/synced/$SYNCED_ROOT/pdf/SKILL.md"
  for i in $(seq -w 0 59); do
    mkdir -p "$home/.claude/skills/fill-$i"
    printf '# fill\n' >"$home/.claude/skills/fill-$i/SKILL.md"
  done
  { for i in $(seq -w 0 59); do printf 'fill-%s\n' "$i"; done; printf '%s\n' "$@"; } \
    | jq -R -s 'split("\n") | map(select(length > 0)) | {skillOverrides: (map({key: ., value: "name-only"}) | from_entries)}' \
    >"$home/.claude/settings.json"
  printf '%s' "$home"
}

# Only section 13 is under test; every other section runs against the same
# fixture and is free to warn.
section_13() {
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
    bash "$DOCTOR" 2>&1 | sed -n '/== 13\./,/== 13b\./p'
}
: >"$TMP/deferral-quiet.tsv"; : >"$TMP/dispatcher-quiet.jsonl"; printf 'RUNG=0\n' >"$TMP/dispatcher-quiet.env"

# Honest control: user, synced, and bundled keys all resolve.
h=$(make_home clean anthropic-skills:pdf keybindings-help simplify claude-api)
out=$(section_13 "$h")
contains "$out" "all skillOverrides resolve to installed skills" "clean: ok line"
omits "$out" "WARN:" "clean: synced and bundled keys are not ghosts"

# Honest control: the bundled skills Claude Code 2.1.302 added to the listing.
h=$(make_home bundled-2-1-302 artifact-capabilities artifact-design artifact-diagramming plugin-authoring denial-triage)
out=$(section_13 "$h")
contains "$out" "all skillOverrides resolve to installed skills" "bundled-2-1-302: ok line"
omits "$out" "WARN:" "bundled-2-1-302: not ghosts"

# Planted negative: a synced key whose skill is gone.
h=$(make_home synced-gone anthropic-skills:morning)
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'anthropic-skills:morning' names no synced skill" "synced-gone: warned"
omits "$out" "all skillOverrides resolve" "synced-gone: not reported ok"

# Planted negative: a synced dir with no SKILL.md does not count.
h=$(make_home synced-empty anthropic-skills:docx)
mkdir -p "$h/.claude/skills/synced/$SYNCED_ROOT/docx"
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'anthropic-skills:docx' names no synced skill" "synced-empty: warned"

# Planted negative: a glob character in the key is tested literally, so it
# must not match the real synced 'pdf' skill.
h=$(make_home synced-glob 'anthropic-skills:*')
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'anthropic-skills:*' names no synced skill" "synced-glob: literal, warned"

# Planted negative: a plain ghost is still a ghost.
h=$(make_home ghost ghosty)
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'ghosty' names no installed skill" "ghost: warned"

# Planted negative: a skill that gained a '-local' suffix gets the re-point hint.
h=$(make_home renamed foo)
mkdir -p "$h/.claude/skills/foo-local"; printf '# foo\n' >"$h/.claude/skills/foo-local/SKILL.md"
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'foo' has no skill dir but 'foo-local' exists" "renamed: re-point hint"

# Planted negative: a bundled-looking name that is not in the list is a ghost.
h=$(make_home not-bundled keybindings-helper)
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'keybindings-helper' names no installed skill" "not-bundled: exact-name match only"

# Planted negative: a built-in command that is not a skill (section 7's list
# carries these) is still a ghost; an override cannot act on /status or /compact.
h=$(make_home command-not-skill status compact)
out=$(section_13 "$h")
contains "$out" "WARN: skillOverride 'status' names no installed skill" "command-not-skill: status warned"
contains "$out" "WARN: skillOverride 'compact' names no installed skill" "command-not-skill: compact warned"

echo "harness-doctor-skill-overrides: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
