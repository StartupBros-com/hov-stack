#!/usr/bin/env bash
# Black-box regression contract for harness-doctor's verified vacuity sites.
#
# PLANTED NEGATIVES: the empty fixture recreates every false-clean input from
# dotfiles#394. Each assertion names the warning that disappears if its floor
# or explicit child/path/parse status check is removed. The populated fixture
# proves those same seams accept a real-looking corpus, including all four test
# families and the hosted-only MCP deny case.
#
# Hermetic: every HOME/repo/corpus is under /tmp/vacuity-batch2-*, systemctl and
# checker children are PATH/home stubs, and no command contacts the network or
# reads/writes the operator's ~/.claude state.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/vacuity-batch2-doctor.XXXXXX)
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
status_is() {
  local actual=$1 expected=$2 label=$3
  [ "$actual" -eq "$expected" ] && ok || bad "$label: expected exit $expected, got $actual"
}
status_nonzero() {
  local actual=$1 label=$2
  [ "$actual" -ne 0 ] && ok || bad "$label: expected nonzero exit, got 0"
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
  *" LastTriggerUSec "*) echo "2026-08-17 09:00:00 EDT" ;;
  *" list-unit-files "*) exit 1 ;;
esac
exit 0
STUB
cat >"$STUBBIN/cass" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"healthy":true,"health_level":"healthy","index":{"partial":false}}'
STUB
chmod +x "$STUBBIN/systemctl" "$STUBBIN/cass"

write_settings() {
  local home=$1 count=$2 hosted=$3
  python3 - "$home/.claude/settings.json" "$count" "$hosted" <<'PY'
import json, sys
path, count, hosted = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
settings = {
    "permissions": {
        "allow": [],
        "ask": [],
        "deny": [],
        "defaultMode": "bypassPermissions",
        "disableAutoMode": "disable",
    },
    "hooks": {},
    "env": {},
    "enabledPlugins": {},
    "skillOverrides": {f"fixture-{i:02d}": "user-invocable-only" for i in range(count)},
}
if hosted:
    settings["permissions"]["deny"] = [
        "mcp__x__create_users_bookmark",
        "mcp__x__create_users_bookmark_folder",
        "mcp__x__delete_users_bookmark",
    ]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle)
PY
  cp "$home/.claude/settings.json" "$home/dotfiles/settings.json"
  printf '%s\n' '{"permissions":{"deny":[],"disableAutoMode":"disable"}}' \
    >"$home/dotfiles/managed-settings.json"
  cp "$home/dotfiles/managed-settings.json" "$home/.claude/installed-managed-settings.json"
  local i
  for ((i = 0; i < count; i++)); do
    mkdir -p "$home/.claude/skills/fixture-$(printf '%02d' "$i")"
  done
}

make_home() {
  local name=$1 count=$2 hosted=$3
  local home=$TMP/$name/home
  mkdir -p \
    "$home/.claude/projects" \
    "$home/.claude/scripts" \
    "$home/.claude/skills" \
    "$home/dotfiles/scripts" \
    "$home/dotfiles/harness" \
    "$home/dotfiles/harnesses/codex" \
    "$home/windows-home/.claude"
  write_settings "$home" "$count" "$hosted"
  printf '%s\n' '{"permissions":{"allow":[],"deny":[],"ask":[],"disableAutoMode":"disable"}}' \
    >"$home/windows-home/.claude/settings.json"
  printf '%s\n' 'Break-glass fixture' >"$home/windows-home/.claude/CLAUDE.md"
  printf '%s\n' 'Break-glass fixture' >"$home/windows-home/AGENTS.md"
  if [ "$hosted" -eq 1 ]; then
    printf '%s\n' '{"mcpServers":{"x":{"type":"http","url":"https://example.invalid/mcp"}}}' \
      >"$home/.claude.json"
  else
    printf '%s\n' '{}' >"$home/.claude.json"
  fi

  cat >"$home/dotfiles/sync.sh" <<'STUB'
#!/usr/bin/env bash
echo "EXAMINED: ${SYNC_EXAMINED:-1}"
echo "in sync"
exit "${SYNC_STATUS:-0}"
STUB
  cat >"$home/dotfiles/harnesses/codex/sync.sh" <<'STUB'
#!/usr/bin/env bash
[ -n "${CODEX_OUTPUT:-}" ] && printf '%s\n' "$CODEX_OUTPUT"
exit "${CODEX_STATUS:-0}"
STUB
  cat >"$home/.claude/scripts/skill-collision-check.py" <<'STUB'
#!/usr/bin/env bash
if [ "${COLLISION_STATUS:-0}" -ne 0 ]; then
  echo "${COLLISION_OUTPUT:-fixture collision scan failed}" >&2
else
  echo "scanned 1 skills across fixture"
  echo "skill-collision-check: 0 live, 0 latent"
fi
exit "${COLLISION_STATUS:-0}"
STUB
  cat >"$home/dotfiles/scripts/skills-beads-sweep-check.py" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
status = int(os.environ.get("SWEEP_STATUS", "0"))
if status:
    print(os.environ.get("SWEEP_OUTPUT") or "fixture sweep failed", file=sys.stderr)
    raise SystemExit(status)
print(json.dumps({"critical_count": 0, "warn_count": 0}))
STUB
  chmod +x \
    "$home/dotfiles/sync.sh" \
    "$home/dotfiles/harnesses/codex/sync.sh" \
    "$home/.claude/scripts/skill-collision-check.py" \
    "$home/dotfiles/scripts/skills-beads-sweep-check.py"
  printf '%s\n' "$home"
}

populate_home() {
  local home=$1
  mkdir -p "$home/.claude/hooks" "$home/.claude/projects/project/memory"
  cat >"$home/.claude/projects/project/memory/note.md" <<'NOTE'
---
name: fixture-note
description: A realistic fixture note for the memory bloat scanner
metadata:
  type: project
---
A short durable fact.
NOTE
  printf '%s\n' '- [fixture](note.md)' >"$home/.claude/projects/project/memory/MEMORY.md"
  printf '%s\n' '# Current harness detail' >"$home/dotfiles/harness/current.md"
  local flow=$home/.claude/projects/project/session/workflows/scripts/flow.js
  mkdir -p "$(dirname "$flow")"
  printf '%s\n' "await agent('fixture', {model: 'sonnet'})" >"$flow"
  touch -d '30 days ago' "$flow"
  # Section 30 (ff-only autostash audit, #481): one guarded call site. The
  # scanner inventories `git ls-files`, so the fixture has to be a checkout —
  # the empty home stays a plain directory, which is its planted negative.
  printf '%s\n' '#!/usr/bin/env bash' 'git merge --ff-only --no-autostash origin/main' \
    >"$home/dotfiles/scripts/ff-fixture.sh"
  # Check 33 (#1355/#1356): a real-looking corpus needs at least one
  # resolvable, served, selectable cross-model repo, or the auditor's own
  # zero-repos floor (finding #2/#4's decoupling of repo accounting from
  # catalog state, demoted "zero repos" item) fires on this otherwise-clean
  # fixture -- round 2's early return on a missing catalog used to mask this
  # by skipping the repo scan entirely before the floor was ever reached.
  mkdir -p "$home/dotfiles/.compound-engineering" "$home/.codex"
  printf 'cross_model_peer: codex\ncross_model_model: gpt-6-astra\n' \
    >"$home/dotfiles/.compound-engineering/config.yaml"
  printf '{"fetched_at":"%s","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$home/.codex/models_cache.json"
  git init -q "$home/dotfiles" && git -C "$home/dotfiles" add -A
}

make_harness_repo() {
  local root=$1
  mkdir -p \
    "$root/tests" \
    "$root/scripts/tests" \
    "$root/plugins/hov-stack/skills/fixture/test" \
    "$root/hooks/tests"
  cat >"$root/tests/test_smoke.py" <<'PY'
import unittest
class Smoke(unittest.TestCase):
    def test_smoke(self):
        self.assertTrue(True)
PY
  cat >"$root/plugins/hov-stack/skills/fixture/test/smoke.test.mjs" <<'JS'
import test from 'node:test';
import assert from 'node:assert/strict';
test('smoke', () => assert.equal(1, 1));
JS
  cat >"$root/tests/root.test.sh" <<'SH'
#!/usr/bin/env bash
echo '1 passed'
SH
  cat >"$root/scripts/tests/nested.test.sh" <<'SH'
#!/usr/bin/env bash
echo '1 passed'
SH
  printf '%s\n' "// fixture inventory" >"$root/hooks/tests/smoke.test.js"
  cat >"$root/hooks/tests/run.sh" <<'SH'
#!/usr/bin/env bash
echo 'pass 1'
SH
  chmod +x "$root/tests/root.test.sh" "$root/scripts/tests/nested.test.sh" "$root/hooks/tests/run.sh"
}

# Section 27 (deferral watchlist) fixtures: vacuity runs must never depend on
# the operator's real crontab/loop-logs, so every run_doctor defaults to the
# quiet fixture; the dedicated B27 case below swaps in the alarm fixture to
# pin the fired/broken WARN paths of the doctor's own consumer code.
DTAB=$'\t'
printf '%s\n' "vquiet${DTAB}active${DTAB}2026-08-21${DTAB}-${DTAB}fixture-src${DTAB}false${DTAB}quiet fixture" >"$TMP/deferral-quiet.tsv"
{
  printf '%s\n' "vfired${DTAB}active${DTAB}2026-08-21${DTAB}-${DTAB}fired-src${DTAB}true${DTAB}fired fixture"
  printf '%s\n' "vbroken${DTAB}active${DTAB}2026-08-21${DTAB}-${DTAB}broken-src${DTAB}no-such-binary-432x${DTAB}broken fixture"
} >"$TMP/deferral-alarm.tsv"


# Section 28 (dispatcher ledger integrity) fixtures: every run_doctor call
# must stay deterministic regardless of the operator's real dispatcher
# state, so the default ledger/config pair is a quiet one-kept-run ledger at
# rung 0 (built through the real dispatcher-ledger.sh, the same producer
# dispatcher-ledger.test.sh exercises, so this fixture can never drift from
# the row shape the consumer actually parses). The dedicated B28 cases below
# swap in a stale/broken alarm ledger, a rung-1 config with the ledger
# absent, and a directory masquerading as the ledger file to pin the
# fail-closed "cannot verify" path.
DISPATCHER_LEDGER_SCRIPT=$REPO/scripts/dispatcher-ledger.sh
DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-quiet.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event claimed --run-id DQUIET1 >/dev/null
DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-quiet.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event launched --run-id DQUIET1 --pid 1 >/dev/null
DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-quiet.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event ended --run-id DQUIET1 --exit 0 --cost 1 --tokens 1 --overlap false >/dev/null
DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-quiet.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event kept --run-id DQUIET1 >/dev/null
printf 'RUNG=0\n' >"$TMP/dispatcher-quiet.env"

DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-alarm.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event claimed --run-id DBROKEN1 >/dev/null
DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-alarm.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event launched --run-id DBROKEN1 --pid 1 >/dev/null
DISPATCHER_LEDGER_FILE="$TMP/dispatcher-ledger-alarm.jsonl" "$DISPATCHER_LEDGER_SCRIPT" append --event broken --run-id DBROKEN1 >/dev/null
# A claimed+launched run whose own ts is planted far in the past (mirrors
# B/T3's orphaned-claim technique in dispatcher-ledger.test.sh) -- no
# terminal row, so it stays undispositioned, and its age alone (not tick
# count) is what pushes it into summary's stale_undisp bucket.
{
  printf '%s\n' '{"fp":1,"ts":"2020-01-01T00:00:00Z","run_id":"DSTALE1","issue":null,"repo":null,"event":"claimed","config":{"k":null,"yield_max":null,"ratchets":null}}'
  printf '%s\n' '{"fp":1,"ts":"2020-01-01T00:05:00Z","run_id":"DSTALE1","issue":null,"repo":null,"event":"launched","pid":999999999}'
} >>"$TMP/dispatcher-ledger-alarm.jsonl"

printf 'RUNG=1\n' >"$TMP/dispatcher-rung1.env"
mkdir -p "$TMP/dispatcher-ledger-dir"

run_doctor() {
  local home=$1 harness_repo=$2 skip_tests=$3
  HOME="$home" \
  PATH="${DOCTOR_TEST_PATH:-$TEST_PATH}" \
  DOTFILES_REPO="$home/dotfiles" \
  CLAUDE_FF_AUDIT="${CLAUDE_FF_AUDIT:-}" \
  CLAUDE_WF_PIN_AUDIT="${CLAUDE_WF_PIN_AUDIT:-}" \
  CLAUDE_WF_PIN_AUDIT_TIMEOUT_S="${CLAUDE_WF_PIN_AUDIT_TIMEOUT_S:-}" \
  CLAUDE_MEMORY_LIVE_ROOT="$home/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$home/dotfiles/memory" \
  CLAUDE_HARNESS_REPO="$harness_repo" \
  CLAUDE_WINDOWS_HOME="$home/windows-home" \
  CLAUDE_MANAGED_SETTINGS_LOCK="$home/.claude/installed-managed-settings.json" \
  CLAUDE_MANAGED_SETTINGS_REF="$home/dotfiles/managed-settings.json" \
  HARNESS_DOCTOR_SKIP_TESTS="$skip_tests" \
  SYNC_EXAMINED="${SYNC_EXAMINED:-1}" SYNC_STATUS="${SYNC_STATUS:-0}" \
  CODEX_OUTPUT="${CODEX_OUTPUT:-in sync}" CODEX_STATUS="${CODEX_STATUS:-0}" \
  COLLISION_OUTPUT="${COLLISION_OUTPUT:-}" COLLISION_STATUS="${COLLISION_STATUS:-0}" \
  SWEEP_OUTPUT="${SWEEP_OUTPUT:-}" SWEEP_STATUS="${SWEEP_STATUS:-0}" \
  DEFERRAL_WATCHLIST_FILE="${DEFERRAL_WATCHLIST_FILE:-$TMP/deferral-quiet.tsv}" \
  DISPATCHER_LEDGER_FILE="${DISPATCHER_LEDGER_FILE:-$TMP/dispatcher-ledger-quiet.jsonl}" \
  DISPATCHER_CONFIG="${DISPATCHER_CONFIG:-$TMP/dispatcher-quiet.env}" \
  CLAUDE_CODEX_MODELS_CACHE="" CLAUDE_INSTALLED_PLUGINS="" \
  CLAUDE_CM_AUDITOR="${CLAUDE_CM_AUDITOR:-}" CLAUDE_CM_TIMEOUT="${CLAUDE_CM_TIMEOUT:-}" \
    bash "$DOCTOR" 2>&1
}

# B4's producer contract: the child discloses comparisons from its actual
# branches. PLANTED NEGATIVE: remove the sync.sh instrumentation and these
# assertions fail even if harness-doctor's consumer is still present.
SYNC_FIX=$TMP/sync-corpus/repo
SYNC_HOME=$TMP/sync-corpus/home
mkdir -p \
  "$SYNC_FIX/scripts/lib" \
  "$SYNC_HOME/.claude" \
  "$TMP/sync-corpus/mirror" \
  "$TMP/sync-corpus/system-user" \
  "$TMP/sync-corpus/system-system"
cp "$REPO/sync.sh" "$SYNC_FIX/sync.sh"
cp "$REPO/scripts/lib/floor-assert.sh" "$SYNC_FIX/scripts/lib/floor-assert.sh"
SYNC_EMPTY_OUT=$(HOME="$SYNC_HOME" \
  CLAUDE_HOME="$SYNC_HOME/.claude" \
  CLAUDE_MEMORY_LIVE_ROOT="$SYNC_HOME/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$TMP/sync-corpus/mirror" \
  CLAUDE_SYNC_SYSTEM_SYS_DIR="$TMP/sync-corpus/system-system" \
  XDG_CONFIG_HOME="$TMP/sync-corpus/system-user" \
  bash "$SYNC_FIX/sync.sh" check 2>&1)
SYNC_EMPTY_STATUS=$?
status_is "$SYNC_EMPTY_STATUS" 2 "B4 direct sync check empty status"
contains "$SYNC_EMPTY_OUT" "EXAMINED: 0" "B4 producer empty inventory"
contains "$SYNC_EMPTY_OUT" "sync corpus: examined 0 item(s)" "B4 direct sync check empty floor"
omits "$SYNC_EMPTY_OUT" "in sync" "B4 direct sync check empty false clean"
SYNC_PREVIEW_EMPTY_OUT=$(HOME="$SYNC_HOME" \
  CLAUDE_HOME="$SYNC_HOME/.claude" \
  CLAUDE_MEMORY_LIVE_ROOT="$SYNC_HOME/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$TMP/sync-corpus/mirror" \
  bash "$SYNC_FIX/sync.sh" memory-preview 2>&1)
SYNC_PREVIEW_EMPTY_STATUS=$?
status_is "$SYNC_PREVIEW_EMPTY_STATUS" 2 "B4 direct memory preview empty status"
contains "$SYNC_PREVIEW_EMPTY_OUT" "memory preview corpus: examined 0 item(s)" "B4 direct memory preview empty floor"
omits "$SYNC_PREVIEW_EMPTY_OUT" "memory in sync" "B4 direct memory preview empty false clean"
# This control is populated and valid; equal windowless settings are now drift.
printf '%s\n' '{"autoCompactWindow":300000}' >"$SYNC_FIX/settings.json"
printf '%s\n' '{"autoCompactWindow":300000}' >"$SYNC_HOME/.claude/settings.json"
SYNC_ONE_OUT=$(HOME="$SYNC_HOME" \
  CLAUDE_HOME="$SYNC_HOME/.claude" \
  CLAUDE_MEMORY_LIVE_ROOT="$SYNC_HOME/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$TMP/sync-corpus/mirror" \
  CLAUDE_SYNC_SYSTEM_SYS_DIR="$TMP/sync-corpus/system-system" \
  XDG_CONFIG_HOME="$TMP/sync-corpus/system-user" \
  bash "$SYNC_FIX/sync.sh" check 2>&1)
SYNC_ONE_STATUS=$?
status_is "$SYNC_ONE_STATUS" 0 "B4 direct sync check populated status"
contains "$SYNC_ONE_OUT" "EXAMINED: 1" "B4 producer populated inventory"
mkdir -p "$SYNC_HOME/.claude/projects/project/memory" "$TMP/sync-corpus/mirror/project"
printf '%s\n' 'fixture memory' >"$SYNC_HOME/.claude/projects/project/memory/MEMORY.md"
printf '%s\n' 'fixture memory' >"$TMP/sync-corpus/mirror/project/MEMORY.md"
SYNC_PREVIEW_ONE_OUT=$(HOME="$SYNC_HOME" \
  CLAUDE_HOME="$SYNC_HOME/.claude" \
  CLAUDE_MEMORY_LIVE_ROOT="$SYNC_HOME/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$TMP/sync-corpus/mirror" \
  bash "$SYNC_FIX/sync.sh" memory-preview 2>&1)
SYNC_PREVIEW_ONE_STATUS=$?
status_is "$SYNC_PREVIEW_ONE_STATUS" 0 "B4 direct memory preview populated status"
contains "$SYNC_PREVIEW_ONE_OUT" "memory in sync" "B4 direct memory preview populated clean"

EMPTY_HOME=$(make_home empty 0 0)
EMPTY_HARNESS=$TMP/empty-harness
mkdir -p "$EMPTY_HARNESS"

SYNC_EXAMINED=0 CODEX_OUTPUT='in sync' CODEX_STATUS=1 \
COLLISION_OUTPUT='fixture collision scan failed' COLLISION_STATUS=2 \
SWEEP_OUTPUT='fixture sweep failed' SWEEP_STATUS=1 \
  EMPTY_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 0)
EMPTY_STATUS=$?
status_nonzero "$EMPTY_STATUS" "B0 empty harness-doctor status (currently 1)"
status_is "$EMPTY_STATUS" 1 "B0 empty harness-doctor current status"

contains "$EMPTY_OUT" "python test modules: examined 0 item(s)" "B1 python family"
contains "$EMPTY_OUT" "node skill suites: examined 0 item(s)" "B1 node family"
contains "$EMPTY_OUT" "bash test suites: examined 0 item(s)" "B1 bash family"
contains "$EMPTY_OUT" "hook test files: examined 0 item(s)" "B1 hook family"
omits "$EMPTY_OUT" "all harness test suites green" "B1 empty tree"
contains "$EMPTY_OUT" "hooks root missing, unreadable, or dangling" "B3 missing hooks root"
contains "$EMPTY_OUT" "dotfiles sync corpus: examined 0 item(s)" "B4 empty sync corpus"
contains "$EMPTY_OUT" "codex hook sync check failed (exit 1)" "B5 child status"
contains "$EMPTY_OUT" "skillOverrides corpus: examined 0 item(s), expected at least 60" "B6 empty overrides"
contains "$EMPTY_OUT" "skill-collision-check failed (exit 2)" "A3 checker status"
contains "$EMPTY_OUT" "MCP deny corpus: examined 0 item(s)" "B7 empty deny corpus"
omits "$EMPTY_OUT" "ok: MCP deny entries: 0 checked / 0 skipped" "B7 zero-item ok"
contains "$EMPTY_OUT" "harness detail docs: examined 0 item(s)" "B8 empty docs"
contains "$EMPTY_OUT" "skills-beads-sweep-check failed (exit 1): fixture sweep failed" "B10 child failure"
omits "$EMPTY_OUT" "beads-to-gh skill sweep: clean" "B10 fabricated clean"
contains "$EMPTY_OUT" "ff-only autostash audit did NOT run" "B12 empty ff-only corpus (not a checkout)"
omits "$EMPTY_OUT" "every ff-only call site switches autostash off" "B12 zero-corpus ok"

# B11: matching settings copies can still be identically unsafe. The doctor must
# assert permission-mode semantics independently of the equality comparison.
POLICY_BAD_HOME=$(make_home policy-bad 60 1)
python3 - "$POLICY_BAD_HOME/.claude/settings.json" "$POLICY_BAD_HOME/dotfiles/settings.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        settings = json.load(handle)
    settings["permissions"].pop("disableAutoMode", None)
    settings["permissions"]["defaultMode"] = "acceptEdits"
    settings["permissions"]["disableBypassPermissionsMode"] = "disable"
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(settings, handle)
windows_path = sys.argv[1].replace(".claude/settings.json", "windows-home/.claude/settings.json")
with open(windows_path, encoding="utf-8") as handle:
    windows_settings = json.load(handle)
windows_settings["permissions"].pop("disableAutoMode", None)
windows_settings["permissions"]["disableBypassPermissionsMode"] = "disable"
with open(windows_path, "w", encoding="utf-8") as handle:
    json.dump(windows_settings, handle)
for path in [
    sys.argv[1].replace(".claude/settings.json", "dotfiles/managed-settings.json"),
    sys.argv[1].replace("settings.json", "installed-managed-settings.json"),
]:
    with open(path, encoding="utf-8") as handle:
        settings = json.load(handle)
    settings["permissions"].pop("disableAutoMode", None)
    settings["permissions"]["disableBypassPermissionsMode"] = "disable"
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(settings, handle)
PY
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  POLICY_BAD_OUT=$(run_doctor "$POLICY_BAD_HOME" "$EMPTY_HARNESS" 1)
contains "$POLICY_BAD_OUT" "live settings do not disable Auto mode" "B11 live Auto omission"
contains "$POLICY_BAD_OUT" "tracked settings do not disable Auto mode" "B11 tracked Auto omission"
contains "$POLICY_BAD_OUT" "live settings defaultMode is not bypassPermissions" "B11 live default drift"
contains "$POLICY_BAD_OUT" "tracked settings defaultMode is not bypassPermissions" "B11 tracked default drift"
contains "$POLICY_BAD_OUT" "live settings disable bypassPermissions" "B11 live bypass regression"
contains "$POLICY_BAD_OUT" "tracked settings disable bypassPermissions" "B11 tracked bypass regression"
contains "$POLICY_BAD_OUT" "tracked managed settings do not disable Auto mode" "B11 tracked managed Auto omission"
contains "$POLICY_BAD_OUT" "installed managed settings do not disable Auto mode" "B11 installed managed Auto omission"
contains "$POLICY_BAD_OUT" "tracked managed settings disable bypassPermissions" "B11 tracked managed bypass regression"
contains "$POLICY_BAD_OUT" "installed managed settings disable bypassPermissions" "B11 installed managed bypass regression"
contains "$POLICY_BAD_OUT" "Windows stub settings.json do not disable Auto mode" "B11 Windows Auto omission"
contains "$POLICY_BAD_OUT" "Windows stub settings.json disable bypassPermissions" "B11 Windows bypass regression"

WINDOWS_MISSING_HOME=$(make_home windows-missing 60 1)
rm "$WINDOWS_MISSING_HOME/windows-home/.claude/settings.json"
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  WINDOWS_MISSING_OUT=$(run_doctor "$WINDOWS_MISSING_HOME" "$EMPTY_HARNESS" 1)
contains "$WINDOWS_MISSING_OUT" "Windows stub settings.json is missing or non-regular; Auto-mode policy is absent" "B11 Windows settings absence"

# The semantic policy parser is Python-backed and must still run when jq is
# absent; only the broad structural comparison may become unverified.
NO_JQ_BIN=$TMP/no-jq-bin
mkdir -p "$NO_JQ_BIN"
python3 - "$NO_JQ_BIN" "$NODE_DIR" <<'PY'
import os, pathlib, sys
out = pathlib.Path(sys.argv[1])
for directory in [pathlib.Path("/usr/bin"), pathlib.Path("/bin"), pathlib.Path(sys.argv[2])]:
    if not directory.is_dir():
        continue
    for source in directory.iterdir():
        if source.name in {"jq", "systemctl", "cass"} or (out / source.name).exists():
            continue
        try:
            os.symlink(source, out / source.name)
        except OSError:
            pass
PY
cp "$STUBBIN/systemctl" "$NO_JQ_BIN/systemctl"
cp "$STUBBIN/cass" "$NO_JQ_BIN/cass"
DOCTOR_TEST_PATH=$NO_JQ_BIN SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  POLICY_BAD_NOJQ_OUT=$(run_doctor "$POLICY_BAD_HOME" "$EMPTY_HARNESS" 1)
contains "$POLICY_BAD_NOJQ_OUT" "settings.json structural drift is unverified because jq is unavailable" "B11 no-jq structural warning"
contains "$POLICY_BAD_NOJQ_OUT" "live settings do not disable Auto mode" "B11 no-jq live semantics"
contains "$POLICY_BAD_NOJQ_OUT" "tracked settings disable bypassPermissions" "B11 no-jq tracked semantics"
unset DOCTOR_TEST_PATH

# B27: section 27's consumer path (heredoc parse + WARN/ok case mapping) is
# pinned against fixtures — the shipped deferral-watchlist.test.sh covers the
# PRODUCER only, and enforcement machinery gets its own planted negatives
# (evidence-regime §4; inward-vet finding on the first cut of issue #432).
contains "$EMPTY_OUT" "deferral vquiet: quiet" "B27 quiet fixture consumed through section 27"
contains "$EMPTY_OUT" "deferral watchlist: no fired or broken triggers" "B27 quiet run ok-line"
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
DEFERRAL_WATCHLIST_FILE=$TMP/deferral-alarm.tsv \
  ALARM_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$ALARM_OUT" "deferral trigger FIRED: vfired" "B27 fired entry WARNs"
contains "$ALARM_OUT" "source: fired-src" "B27 fired WARN names the entry's own source pointer"
contains "$ALARM_OUT" "deferral trigger check BROKEN: vbroken" "B27 broken entry WARNs distinctly"
omits "$ALARM_OUT" "deferral watchlist: no fired or broken triggers" "B27 alarm run must not print the clean ok-line"

# B28: section 28's consumer path (rung-aware missing-ledger branch, summary
# delegation, flagged-count parse, fail-closed cannot-verify path) is pinned
# against fixtures -- dispatcher-ledger.test.sh covers the PRODUCER only.
# EMPTY_OUT already ran through run_doctor()'s new quiet dispatcher-ledger
# default (one kept run, rung 0), so it doubles as the quiet-fixture control
# here exactly as B27 reuses it above.
contains "$EMPTY_OUT" "dispatcher ledger: integrity checks quiet" "B28 quiet fixture default ok-line"
DISPATCHER_LEDGER_FILE=$TMP/dispatcher-ledger-alarm.jsonl \
  DISPATCH_ALARM_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$DISPATCH_ALARM_OUT" "dispatcher ledger: 2 flagged (broken runs or stale undispositioned)" "B28 broken+stale fixture warns the exact flagged count"
omits "$DISPATCH_ALARM_OUT" "dispatcher ledger: integrity checks quiet" "B28 alarm run must not print the clean ok-line"
DISPATCHER_LEDGER_FILE=$TMP/dispatcher-ledger-missing.jsonl \
  DISPATCHER_CONFIG=$TMP/dispatcher-rung1.env \
  DISPATCH_RUNG1_MISSING_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$DISPATCH_RUNG1_MISSING_OUT" "dispatcher ledger absent at $TMP/dispatcher-ledger-missing.jsonl (rung=1 — a live dispatcher writing nothing is the silent-stall shape)" "B28 missing ledger at rung>=1 WARNs (silent-stall shape)"
DISPATCHER_LEDGER_FILE=$TMP/dispatcher-ledger-missing.jsonl \
  DISPATCHER_CONFIG=$TMP/dispatcher-quiet.env \
  DISPATCH_RUNG0_MISSING_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$DISPATCH_RUNG0_MISSING_OUT" "dispatcher ledger absent (rung 0 — no runs expected)" "B28 missing ledger at rung 0 is ok, not a warn"
DISPATCHER_LEDGER_FILE=$TMP/dispatcher-ledger-dir \
  DISPATCH_CORRUPT_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$DISPATCH_CORRUPT_OUT" "dispatcher ledger: cannot verify ($TMP/dispatcher-ledger-dir exists but is not a regular file)" "B28 non-regular-file ledger path fails closed (cannot verify)"
unset DISPATCHER_LEDGER_FILE DISPATCHER_CONFIG

ln -s "$TMP/no-such-hooks" "$EMPTY_HOME/.claude/hooks"
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  DANGLING_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$DANGLING_OUT" "hooks root missing, unreadable, or dangling" "B3 dangling hooks root"

rm "$EMPTY_HOME/.claude/hooks"
mkdir -p "$EMPTY_HOME/.claude/hooks"
SYNC_EXAMINED=1 CODEX_STATUS=0 \
COLLISION_OUTPUT='  COLLISION: alpha <-> beta — byte-identical descriptions' COLLISION_STATUS=1 \
SWEEP_STATUS=0 \
  COLLISION_OUT=$(run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$COLLISION_OUT" "skill trigger collision: alpha <-> beta" "A3 collision parsing"
omits "$COLLISION_OUT" "skill-collision-check failed (exit 1)" "A3 collision status meaning"

MALFORMED_HOME=$(make_home malformed 60 1)
populate_home "$MALFORMED_HOME"
printf '%s\n' '{not json' >"$MALFORMED_HOME/.claude.json"
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  MALFORMED_OUT=$(run_doctor "$MALFORMED_HOME" "$EMPTY_HARNESS" 1)
contains "$MALFORMED_OUT" "global MCP policy could not read/parse" "B2 malformed global config"
omits "$MALFORMED_OUT" "global stdio servers within documented exceptions" "B2 false clean"
contains "$MALFORMED_OUT" "check 14: mcp-deny scan errored" "B7 broken config"
omits "$MALFORMED_OUT" "MCP deny entries resolve to real tools" "B7 broken false clean"

FULL_HOME=$(make_home populated 60 1)
populate_home "$FULL_HOME"
FULL_HARNESS=$TMP/populated-harness
make_harness_repo "$FULL_HARNESS"
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  FULL_OUT=$(run_doctor "$FULL_HOME" "$FULL_HARNESS" 0)

contains "$FULL_OUT" "python test modules examined: 1" "B1 python disclosure"
contains "$FULL_OUT" "node skill suites examined: 1" "B1 node disclosure"
contains "$FULL_OUT" "bash test suites examined: 2" "B1 bash disclosure"
contains "$FULL_OUT" "bash: nested.test.sh" "B1 nested bash discovery"
contains "$FULL_OUT" "hook test files examined: 1" "B1 hook disclosure"
contains "$FULL_OUT" "all harness test suites green" "B1 populated control"
contains "$FULL_OUT" "MCP deny entries: 0 checked / 3 skipped" "B7 hosted-only control"
contains "$FULL_OUT" "harness docs examined: 1" "B8 populated control"
contains "$FULL_OUT" "global stdio servers within documented exceptions" "B2 valid zero-stdio control"
omits "$FULL_OUT" "hooks root missing, unreadable, or dangling" "B3 existing empty root control"
omits "$FULL_OUT" "refusing to report clean" "populated false floor warning"
contains "$FULL_OUT" "0 finding(s) across 1 --ff-only call site(s)" "B12 populated ff-only control"

# B1 drain: the bash loop feeds its suite list on stdin, so a suite that read
# stdin swallowed the rest of the list and the loop ended under an ok line
# (weekly runs to 2026-10-12 ran 7/131, 8/146 and 129/169 suites).
# a-drain reads stdin; b-fail and z-sentinel sort after it, so they only run
# if every suite reads </dev/null. b-fail, test_fail.py and the node failures
# each name their failing test, which the WARN must carry instead of a bare
# count or a trailing summary line. b-fail prints enough FAIL lines to pass
# the 64 KiB pipe capacity, and the run ignores SIGPIPE as B23's does, so a
# name cap that closed its input early would put "Broken pipe" in the WARN.
DRAIN_HARNESS=$TMP/drain-harness
make_harness_repo "$DRAIN_HARNESS"
cat >"$DRAIN_HARNESS/tests/a-drain.test.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo '1 passed'
SH
cat >"$DRAIN_HARNESS/tests/b-fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo 'FAIL: named-bash-case'
pad=$(printf 'x%.0s' $(seq 1 160))
for i in $(seq 1 1500); do echo "FAIL: noisy-case-$i-$pad"; done
echo 'trailing summary line'
exit 1
SH
cat >"$DRAIN_HARNESS/tests/z-sentinel.test.sh" <<'SH'
#!/usr/bin/env bash
echo '1 passed'
SH
cat >"$DRAIN_HARNESS/tests/test_fail.py" <<'PY'
import unittest
class Named(unittest.TestCase):
    def test_named_python_failure(self):
        self.assertEqual(1, 2)
PY
cat >"$DRAIN_HARNESS/plugins/hov-stack/skills/fixture/test/fail.test.mjs" <<'JS'
import test from 'node:test';
import assert from 'node:assert/strict';
test('named node failure', () => assert.equal(1, 2));
JS
# TAP indents a failing subtest under its parent, as describe()/it() suites do.
cat >"$DRAIN_HARNESS/plugins/hov-stack/skills/fixture/test/nested.test.mjs" <<'JS'
import test from 'node:test';
import assert from 'node:assert/strict';
test('outer node suite', async (t) => {
  await t.test('nested subtest failure', () => assert.equal(1, 2));
});
JS
DRAIN_OUT=$( (trap '' PIPE; run_doctor "$FULL_HOME" "$DRAIN_HARNESS" 0) 2>&1)
contains "$DRAIN_OUT" "bash test suites examined: 5" "B1 drain fixture lists five bash suites"
contains "$DRAIN_OUT" "bash: z-sentinel.test.sh" "B1 a stdin-reading suite does not end the bash loop"
contains "$DRAIN_OUT" "named-bash-case" "B1 bash WARN names the failing case"
contains "$DRAIN_OUT" "test_named_python_failure" "B1 python WARN names the failing test"
contains "$DRAIN_OUT" "named node failure" "B1 node WARN names the failing test"
contains "$DRAIN_OUT" "nested subtest failure" "B1 node WARN names a failing subtest"
omits "$DRAIN_OUT" "Broken pipe" "B1 the failing-name cap drains its input"
omits "$DRAIN_OUT" "the loop ended early" "B1 every listed suite ran"
omits "$DRAIN_OUT" "all harness test suites green" "B1 drain fixture is not green"

# B1 ran-vs-listed: with every suite on </dev/null nothing above can end the
# loop early, so the guard is checked against a copy of the doctor whose bash
# loop still hands each suite its stdin; a-drain then swallows the rest of the
# list. The node guard has no such check: node --test gives each test file its
# own stdin, so no node suite can drain the list.
MUT_DIR=$TMP/mutant-scripts
mkdir -p "$MUT_DIR"
ln -s "$REPO/scripts/"* "$MUT_DIR/"
rm "$MUT_DIR/harness-doctor.sh"
sed 's|timeout 300 bash "$(basename "$t")" 2>&1 </dev/null|timeout 300 bash "$(basename "$t")" 2>\&1|' \
  "$DOCTOR" >"$MUT_DIR/harness-doctor.sh"
if cmp -s "$DOCTOR" "$MUT_DIR/harness-doctor.sh"; then
  bad "B1 ran-vs-listed: the bash loop's </dev/null line moved; update this mutation"
else
  MUT_OUT=$(DOCTOR="$MUT_DIR/harness-doctor.sh" run_doctor "$FULL_HOME" "$DRAIN_HARNESS" 0)
  contains "$MUT_OUT" "bash test suites: ran 2 of 5 listed; the loop ended early" \
    "B1 ran-vs-listed guard reports a loop a suite cut short"
fi

# B1 skip header: docker-init-runtime.test.sh needs operator-supplied images,
# containers and a socket, so the bare weekly run always refused (exit 64) and
# raised a FAILING WARN every week (dotfiles#1840 decision 3). A suite opts out
# with a `# harness-doctor-skip: <reason>` line in its leading comment block; the
# doctor names it as skipped instead of running it. A marker after the first
# non-comment line is suite content (this file's own heredocs among them), so
# n-late still runs and still WARNs.
SKIP_HARNESS=$TMP/skip-harness
make_harness_repo "$SKIP_HARNESS"
cat >"$SKIP_HARNESS/tests/m-manual.test.sh" <<'SH'
#!/usr/bin/env bash
# Real proof that needs operator arguments.
# harness-doctor-skip: needs operator-supplied images and containers
echo 'REFUSED: fixture refuses without operator arguments' >&2
exit 64
SH
cat >"$SKIP_HARNESS/tests/n-late.test.sh" <<'SH'
#!/usr/bin/env bash
echo 'FAIL: late-marker-case'
# harness-doctor-skip: too late to count
exit 1
SH
SKIP_OUT=$(run_doctor "$FULL_HOME" "$SKIP_HARNESS" 0)
contains "$SKIP_OUT" "bash test suites examined: 4" "B1 skip fixture lists four bash suites"
contains "$SKIP_OUT" "skip: bash: m-manual.test.sh — needs operator-supplied images and containers" "B1 a skip header names the suite and its reason"
omits "$SKIP_OUT" "FAILING: m-manual.test.sh" "B1 a skip-header suite is not run"
contains "$SKIP_OUT" "late-marker-case" "B1 a marker after the header does not skip the suite"
omits "$SKIP_OUT" "the loop ended early" "B1 a skipped suite counts as handled"

# B7: skills/synced is skills-sync's container of vendored skills, so it has
# no SKILL.md of its own; a skill dir that is genuinely empty still warns.
SYNCED_HOME=$(make_home skills-synced 0 0)
mkdir -p "$SYNCED_HOME/.claude/skills/synced/vendored" "$SYNCED_HOME/.claude/skills/plain-empty"
SYNCED_OUT=$(run_doctor "$SYNCED_HOME" "$EMPTY_HARNESS" 1)
contains "$SYNCED_OUT" "skill dir without SKILL.md: plain-empty" "B7 empty skill dir still warns"
omits "$SYNCED_OUT" "skill dir without SKILL.md: synced" "B7 skills/synced container is not a skill"

# B5 (issue #1199): check 5's inverse nested test. Claude Code 2.1.277+ reads
# AGENTS.md by itself only when NO CLAUDE.md sits on the path; under a root
# pointer the engine attaches nested files named CLAUDE.md only, so a nested
# AGENTS.md with no sibling pointer never loads. Three repos that differ only
# in the forbidden dimension: stub-dead (root pointer, nested AGENTS.md, no
# nested pointer) must WARN; stub-clean (same plus the nested pointer) and
# fallback-ok (no root CLAUDE.md at all, so the fallback attaches the nested
# file) must not. A check that ignores the root-CLAUDE.md precondition warns
# on fallback-ok; one that only walks nested CLAUDE.md files (the loop above
# it) never warns on stub-dead. The index is what `git ls-files` reads, so the
# files are added, never committed (a commit-less repo also keeps the
# "active repo missing AGENTS.md" arm quiet: every fixture has a root file).
AGENTS_HOME=$(make_home agents-md 60 1)
populate_home "$AGENTS_HOME"
for fixture in stub-dead stub-clean fallback-ok local-only; do
  mkdir -p "$AGENTS_HOME/SITES/$fixture/packages/a"
  printf '%s\n' '# root instructions' >"$AGENTS_HOME/SITES/$fixture/AGENTS.md"
  printf '%s\n' '# package instructions' >"$AGENTS_HOME/SITES/$fixture/packages/a/AGENTS.md"
done
printf '%s\n' '@AGENTS.md' >"$AGENTS_HOME/SITES/stub-dead/CLAUDE.md"
printf '%s\n' '@AGENTS.md' >"$AGENTS_HOME/SITES/stub-clean/CLAUDE.md"
printf '%s\n' '@AGENTS.md' >"$AGENTS_HOME/SITES/stub-clean/packages/a/CLAUDE.md"
# dotclaude-pointer: a nested pointer at packages/a/.claude/CLAUDE.md attaches
# on Read exactly like packages/a/CLAUDE.md (headless probe, 2026-09-18: two
# Read calls, sentinel from the nested .claude/CLAUDE.md present), so it is a
# valid sibling and must not count as dead.
mkdir -p "$AGENTS_HOME/SITES/dotclaude-pointer/packages/a/.claude"
printf '%s\n' '# root instructions' >"$AGENTS_HOME/SITES/dotclaude-pointer/AGENTS.md"
printf '%s\n' '@AGENTS.md' >"$AGENTS_HOME/SITES/dotclaude-pointer/CLAUDE.md"
printf '%s\n' '# package instructions' >"$AGENTS_HOME/SITES/dotclaude-pointer/packages/a/AGENTS.md"
printf '%s\n' '@AGENTS.md' >"$AGENTS_HOME/SITES/dotclaude-pointer/packages/a/.claude/CLAUDE.md"
# local-only: the gitignored CLAUDE.local.md is the third root spelling that
# keeps the engine on the CLAUDE.md path — a precondition that checks only
# CLAUDE.md / .claude/CLAUDE.md skips this repo and misses its orphan.
printf '%s\n' '# private notes' >"$AGENTS_HOME/SITES/local-only/CLAUDE.local.md"
# Skip-pattern anchoring (vet of #1200): a ROOT-level fixtures/ dir must be
# skipped like a nested one (unanchored '*/fixtures/*' needs a slash before
# it and flags this), while a real dir that merely ends in ".claude" must
# still count (unanchored '*.claude/*' swallows it). stub-dead therefore
# expects exactly 2: packages/a plus foo.claude, never fixtures.
mkdir -p "$AGENTS_HOME/SITES/stub-dead/fixtures" "$AGENTS_HOME/SITES/stub-dead/foo.claude"
printf '%s\n' '# fixture data' >"$AGENTS_HOME/SITES/stub-dead/fixtures/AGENTS.md"
printf '%s\n' '# real package' >"$AGENTS_HOME/SITES/stub-dead/foo.claude/AGENTS.md"
for fixture in stub-dead stub-clean fallback-ok local-only dotclaude-pointer; do
  git init -q "$AGENTS_HOME/SITES/$fixture" && git -C "$AGENTS_HOME/SITES/$fixture" add -A
done
SYNC_EXAMINED=1 CODEX_STATUS=0 COLLISION_STATUS=0 SWEEP_STATUS=0 \
  AGENTS_OUT=$(run_doctor "$AGENTS_HOME" "$FULL_HARNESS" 0)
contains "$AGENTS_OUT" "stub-dead: 2 nested AGENTS.md with no sibling CLAUDE.md pointer" "B5 unstubbed nested AGENTS.md under a root pointer warns (fixtures/ skipped, foo.claude/ counted)"
contains "$AGENTS_OUT" "local-only: 1 nested AGENTS.md with no sibling CLAUDE.md pointer" "B5 a root CLAUDE.local.md alone keeps the engine on the CLAUDE.md path"
omits "$AGENTS_OUT" "stub-clean:" "B5 nested pointer present is clean"
omits "$AGENTS_OUT" "dotclaude-pointer:" "B5 a nested .claude/CLAUDE.md pointer counts as a sibling"
omits "$AGENTS_OUT" "fallback-ok:" "B5 no root CLAUDE.md means the fallback loads it"
omits "$AGENTS_OUT" "dual instruction files" "B5 root pointers are not twins"

# B12: the doctor's own WARN-emission arm (scanner exit 1 with findings) and
# its crash arm (exit 1 with none — python's unhandled-exception status).
FF_BARE_HOME=$(make_home ff-bare 60 1)
populate_home "$FF_BARE_HOME"
printf '%s\n' '#!/usr/bin/env bash' 'git pull --ff-only' >"$FF_BARE_HOME/dotfiles/scripts/ff-bare.sh"
git -C "$FF_BARE_HOME/dotfiles" add -A
FF_BARE_OUT=$(run_doctor "$FF_BARE_HOME" "$FULL_HARNESS" 1)
contains "$FF_BARE_OUT" "WARN: scripts/ff-bare.sh:2: pull --ff-only leaves autostash" "B12 unguarded site named by the doctor"
omits "$FF_BARE_OUT" "every ff-only call site switches autostash off" "B12 unguarded site false clean"
cat >"$TMP/ff-crash.py" <<'PY'
import sys
print("Traceback (most recent call last):", file=sys.stderr)
print("RuntimeError: fixture crash", file=sys.stderr)
sys.exit(1)
PY
FF_CRASH_OUT=$(CLAUDE_FF_AUDIT="$TMP/ff-crash.py" run_doctor "$FULL_HOME" "$FULL_HARNESS" 1)
contains "$FF_CRASH_OUT" "ff-only autostash audit exited 1 but named no finding" "B12 crashed scanner is not a verdict"
omits "$FF_CRASH_OUT" "every ff-only call site switches autostash off" "B12 crashed scanner false clean"
omits "$FULL_OUT" "skills-beads-sweep-check failed" "B10 successful control"
omits "$FULL_OUT" "settings do not disable Auto mode" "B11 safe settings control"
omits "$FULL_OUT" "settings defaultMode is not bypassPermissions" "B11 default-mode control"
omits "$FULL_OUT" "settings disable bypassPermissions" "B11 bypass-availability control"
omits "$FULL_OUT" "Windows stub settings.json do not disable Auto mode" "B11 Windows policy control"
omits "$FULL_OUT" "Windows stub settings.json disable bypassPermissions" "B11 Windows bypass control"

# B8a: section 8a resolves every registered hook command against the disk.
# This is the #507 shape — `install` strips prior registrations by exact
# command-string equality, so a relocated hook leaves a dead twin behind and
# the canonical registration is added beside it rather than replacing it.
make_hookreg_home() {
  local name=$1 include_dead=$2 home
  home=$(make_home "$name" 0 0)
  mkdir -p "$home/.claude/hooks/PreToolUse"
  : >"$home/.claude/hooks/PreToolUse/live-guard.js"
  python3 - "$home/.claude/settings.json" "$home" "$include_dead" <<'PY'
import json, sys
path, home, include_dead = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, encoding="utf-8") as handle:
    settings = json.load(handle)
groups = [{"matcher": "Bash", "hooks": [
    {"type": "command", "command": f'node "{home}/.claude/hooks/PreToolUse/live-guard.js"'}]}]
if include_dead:
    groups.append({"matcher": "Bash", "hooks": [
        {"type": "command", "command": f'node "{home}/.claude/staging-gone/hooks/PreToolUse/dead-guard.js"'}]})
settings["hooks"] = {"PreToolUse": groups}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle)
PY
  printf '%s' "$home"
}

# CONTROL: every registration resolves, so the check must report a populated
# examination rather than staying silent.
HOOKREG_OK_HOME=$(make_hookreg_home hookreg-ok 0)
HOOKREG_OK_OUT=$(run_doctor "$HOOKREG_OK_HOME" "$EMPTY_HARNESS" 1)
contains "$HOOKREG_OK_OUT" "1 registered hook command(s), all targets present" \
  "B8a control examined a populated registration set"

# PLANTED NEGATIVE: one registration points at a path that does not exist. It
# must be named, and the sibling registration that DOES resolve must not be.
HOOKREG_DEAD_HOME=$(make_hookreg_home hookreg-dead 1)
HOOKREG_DEAD_OUT=$(run_doctor "$HOOKREG_DEAD_HOME" "$EMPTY_HARNESS" 1)
contains "$HOOKREG_DEAD_OUT" "dead-guard.js" "B8a dead registration named"
contains "$HOOKREG_DEAD_OUT" "so every matching event fails" "B8a dead registration explains the impact"
omits "$HOOKREG_DEAD_OUT" "all targets present" "B8a dead registration suppresses the clean line"
omits "$HOOKREG_DEAD_OUT" "does not exist, so every matching event fails: $HOOKREG_DEAD_HOME/.claude/hooks/PreToolUse/live-guard.js" \
  "B8a resolvable sibling not reported"

# B8a $HOME: whatsapp-guard registers as `node "$HOME/..."` with a literal
# $HOME, which sync.sh's hook_command_target expands. Section 8a used to read
# only `"/abs"`, so that registration was counted but never checked.
make_home_hookreg_home() {
  local name=$1 include_dead=$2 home
  home=$(make_home "$name" 0 0)
  mkdir -p "$home/.claude/hooks/PreToolUse"
  : >"$home/.claude/hooks/PreToolUse/live-home-guard.js"
  python3 - "$home/.claude/settings.json" "$include_dead" <<'PY'
import json, sys
path, include_dead = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    settings = json.load(handle)
hooks = [{"type": "command", "command": 'node "$HOME/.claude/hooks/PreToolUse/live-home-guard.js"'},
         {"type": "command", "command": "true"}]
if include_dead:
    hooks.append({"type": "command", "command": 'node "$HOME/.claude/staging-gone/hooks/PreToolUse/home-dead-guard.js"'})
settings["hooks"] = {"PreToolUse": [{"matcher": "Bash", "hooks": hooks}]}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(settings, handle)
PY
  printf '%s' "$home"
}
HOOKREG_HOME_OK_HOME=$(make_home_hookreg_home hookreg-home-ok 0)
HOOKREG_HOME_OK_OUT=$(run_doctor "$HOOKREG_HOME_OK_HOME" "$EMPTY_HARNESS" 1)
contains "$HOOKREG_HOME_OK_OUT" "2 registered hook command(s), all targets present (1 name no path, so are not checked)" \
  "B8a \$HOME control resolves and counts the pathless command"
HOOKREG_HOME_DEAD_HOME=$(make_home_hookreg_home hookreg-home-dead 1)
HOOKREG_HOME_DEAD_OUT=$(run_doctor "$HOOKREG_HOME_DEAD_HOME" "$EMPTY_HARNESS" 1)
contains "$HOOKREG_HOME_DEAD_OUT" "fails: $HOOKREG_HOME_DEAD_HOME/.claude/staging-gone/hooks/PreToolUse/home-dead-guard.js" \
  "B8a dead \$HOME registration named with \$HOME expanded"
omits "$HOOKREG_HOME_DEAD_OUT" "live-home-guard.js" "B8a resolvable \$HOME sibling not reported"

# B8: settings.json is one of three live wiring paths. An agent's frontmatter
# registered lean-collector's agent-scoped/readonly-bash.js (retired
# 2026-10-17), and whatsapp-guard.js
# require()s discord-write-guard and resend-write-guard; on 2026-10-15 those
# three were section 8's only orphan WARNs, all false. Section 8a resolves the
# frontmatter targets too: a gone one never runs, which for a fence fails open.
# PLANTED NEGATIVES: a hook nothing reaches is still named, and so is an agent
# hook whose script is gone. So are two unregistered hooks that require each
# other: only a registered sibling's require() counts, or a cycle (the whatsapp
# family's shape) would vouch for itself once its anchor's registration was lost.
write_agent() {
  printf '%s\n' '---' "name: $2" 'hooks:' '  PreToolUse:' '    - matcher: "Bash"' '      hooks:' \
    '        - type: command' "          command: \"node $3\"" '---' 'Agent body.' >"$1/.claude/agents/$2.md"
}
HOOKWIRE_HOME=$(make_hookreg_home hookwire 0)
mkdir -p "$HOOKWIRE_HOME/.claude/agents" "$HOOKWIRE_HOME/.claude/hooks/agent-scoped"
printf '%s\n' "module.exports = require('./sibling-guard');" >"$HOOKWIRE_HOME/.claude/hooks/PreToolUse/live-guard.js"
: >"$HOOKWIRE_HOME/.claude/hooks/PreToolUse/sibling-guard.js"
: >"$HOOKWIRE_HOME/.claude/hooks/PreToolUse/stray-guard.js"
printf '%s\n' "require('./cycle-b');" >"$HOOKWIRE_HOME/.claude/hooks/PreToolUse/cycle-a.js"
printf '%s\n' "require('./cycle-a');" >"$HOOKWIRE_HOME/.claude/hooks/PreToolUse/cycle-b.js"
: >"$HOOKWIRE_HOME/.claude/hooks/agent-scoped/fence.js"
write_agent "$HOOKWIRE_HOME" fenced "$HOOKWIRE_HOME/.claude/hooks/agent-scoped/fence.js"
write_agent "$HOOKWIRE_HOME" unfenced "$HOOKWIRE_HOME/.claude/hooks/agent-scoped/gone.js"
HOOKWIRE_OUT=$(run_doctor "$HOOKWIRE_HOME" "$EMPTY_HARNESS" 1)
omits "$HOOKWIRE_OUT" "(orphan?): $HOOKWIRE_HOME/.claude/hooks/agent-scoped/fence.js" "B8 agent-frontmatter hook is wired"
omits "$HOOKWIRE_OUT" "(orphan?): $HOOKWIRE_HOME/.claude/hooks/PreToolUse/sibling-guard.js" "B8 sibling-required hook is wired"
contains "$HOOKWIRE_OUT" "(orphan?): $HOOKWIRE_HOME/.claude/hooks/PreToolUse/stray-guard.js" "B8 unreached hook still named"
contains "$HOOKWIRE_OUT" "(orphan?): $HOOKWIRE_HOME/.claude/hooks/PreToolUse/cycle-a.js" "B8 require cycle does not vouch for cycle-a"
contains "$HOOKWIRE_OUT" "(orphan?): $HOOKWIRE_HOME/.claude/hooks/PreToolUse/cycle-b.js" "B8 require cycle does not vouch for cycle-b"
contains "$HOOKWIRE_OUT" "agent unfenced.md registers a hook at a path that does not exist, so that hook never runs: $HOOKWIRE_HOME/.claude/hooks/agent-scoped/gone.js" \
  "B8a gone agent hook named"
omits "$HOOKWIRE_OUT" "does not exist, so that hook never runs: $HOOKWIRE_HOME/.claude/hooks/agent-scoped/fence.js" \
  "B8a resolvable agent hook not reported"

# Check 23 read only wf-pin-audit's exit code (unpinned calls) and its last
# line, so every uncapped-fan-out and over-broad-schema WARN it computed was
# discarded (rent-check 2026-09-02, dotfiles#837: 699 in one week). A fresh
# script with one of each, and a pinned model so the exit code stays 0, must
# surface as a tallied warning; the fixtures with no in-window script must not.
HYGIENE_HOME=$(make_home hygiene 60 1)
populate_home "$HYGIENE_HOME"
HYGIENE_FLOW=$HYGIENE_HOME/.claude/projects/project/session/workflows/scripts/hygiene.js
cat >"$HYGIENE_FLOW" <<'JS'
const items = ['a', 'b']
await parallel(items.map(i => () => agent(i, {model: 'sonnet', schema: {type: 'object', properties: {},
  required: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'], additionalProperties: false}})))
JS
# Many more DISTINCT offenders (wf-pin-audit skips byte-identical duplicates)
# so the deduped example-path list overflows awk's output buffer: that is
# what made a trailing `head -3` close the pipe early on the first live run
# (2026-09-02, 692 WARN lines) and put "Broken pipe" from sed/grep/printf
# into the report. Four short paths never reproduce it.
# The deduped path list must exceed the 64 KiB pipe capacity so the writers
# are still writing when the reader closes (~400 paths of ~250 bytes), AND
# SIGPIPE must be ignored, as systemd starts every service: with the default
# disposition the writers die silently and no fixture size reproduces the
# report noise (measured at 120, 400 and 1000 paths). `trap '' PIPE` in the
# subshell is inherited across exec by every process the doctor spawns.
hygiene_pad=$(printf 'x%.0s' $(seq 1 160))
hygiene_i=2
while [ "$hygiene_i" -le 400 ]; do
  printf '// offender %s\n' "$hygiene_i" \
    | cat - "$HYGIENE_FLOW" >"$HYGIENE_HOME/.claude/projects/project/session/workflows/scripts/hygiene-offender-$hygiene_pad-$hygiene_i.js"
  hygiene_i=$((hygiene_i + 1))
done
HYGIENE_OUT=$( (trap '' PIPE; run_doctor "$HYGIENE_HOME" "$EMPTY_HARNESS" 1) 2>&1)
contains "$HYGIENE_OUT" "wf-pin-audit soft findings (last 8 days, 400 scripts scanned): 400 with an uncapped fan-out, 400 with an over-broad required schema" \
  "B23 soft findings tallied with the scanned denominator"
contains "$HYGIENE_OUT" "e.g. $HYGIENE_HOME/.claude/projects/project/session/workflows/scripts/hygiene" \
  "B23 an offending script is named, not just counted"
omits "$HYGIENE_OUT" "Broken pipe" "B23 the example-path cap must drain its input, not close the pipe"
omits "$HYGIENE_OUT" "unpinned agent() call" "B23 pinned fixture must not trip the exit-code path"
omits "$HYGIENE_OUT" "workflow scripts pinned, capped, and schema-lean" "B23 soft findings suppress the clean line"
omits "$EMPTY_OUT" "wf-pin-audit soft findings" "B23 planted negative: no scripts, no tally"
omits "$FULL_OUT" "wf-pin-audit soft findings" "B23 planted negative: only a 30-day-old script, no tally"

# A schema-only script pins the zero-count wording of the other counter, so
# the `||` branch is exercised on its own and a counter stuck at 0 renders.
HYGIENE2_HOME=$(make_home hygiene-schema-only 60 1)
populate_home "$HYGIENE2_HOME"
HYGIENE2_FLOW=$HYGIENE2_HOME/.claude/projects/project/session/workflows/scripts/schema-only.js
cat >"$HYGIENE2_FLOW" <<'JS'
await agent('one', {model: 'sonnet', schema: {type: 'object', properties: {},
  required: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'], additionalProperties: false}})
JS
HYGIENE2_OUT=$(run_doctor "$HYGIENE2_HOME" "$EMPTY_HARNESS" 1)
contains "$HYGIENE2_OUT" "1 scripts scanned): 0 with an uncapped fan-out, 1 with an over-broad required schema" \
  "B23 schema-only fixture renders the zero fan-out counter"

# Round 11 (#1351 fourth adversarial pass): check 23 reads wf-pin-audit.py
# through `_wf_out=$(python3 wf-pin-audit.py --days 8 2>&1)` and warns with
# `echo "$_wf_out" | tail -1`. stdout is block-buffered when piped and only
# flushes at process exit, while stderr is unbuffered -- a per-script
# "lexer budget exceeded ... unaudited" WARN written to stderr used to reach
# that merged capture before stdout's own buffered summary flushed, so
# tail -1 always saw the stdout "wf-pin-audit: clean (...)" line even though
# a script had gone unaudited. WF_PIN_LEX_BUDGET_MS=1 guarantees the large
# synthetic script below blows its own per-script lexer budget regardless of
# machine speed (findAllDeclarationPositions() runs unconditionally), while
# containing zero agent() calls, so a false "clean" reading would be
# indistinguishable from a genuinely quiet window without this assertion.
UNAUDITED_HOME=$(make_home wf-pin-unaudited 60 1)
populate_home "$UNAUDITED_HOME"
UNAUDITED_SCRIPTS=$UNAUDITED_HOME/.claude/projects/project/session/workflows/scripts
python3 - "$UNAUDITED_SCRIPTS/huge.js" <<'PY'
import sys
path = sys.argv[1]
with open(path, "w", encoding="utf-8") as handle:
    for i in range(50000):
        handle.write(f"const helper_{i} = 0\n")
PY
UNAUDITED_OUT=$(WF_PIN_LEX_BUDGET_MS=1 run_doctor "$UNAUDITED_HOME" "$EMPTY_HARNESS" 1)
contains "$UNAUDITED_OUT" "UNAUDITED" \
  "B23 lexer-budget-exceeded WARN surfaces through harness-doctor's own consumer idiom"
omits "$UNAUDITED_OUT" "wf-pin-audit: clean" \
  "B23 planted negative: an unaudited script must never render as the clean summary through 2>&1 | tail -1"
omits "$UNAUDITED_OUT" "wf-pin-audit: wf-pin-audit:" \
  "B23 the WARN does not repeat the auditor's own name prefix"

# Finding #7 (PR #1352 round 7): unlike every other subprocess this doctor
# shells out to, wf-pin-audit.py's node-backed lexer call had no external
# timeout of its own -- an oversized corpus could hang check 23 indefinitely.
# CLAUDE_WF_PIN_AUDIT points the doctor at a stub auditor that sleeps well
# past a tiny CLAUDE_WF_PIN_AUDIT_TIMEOUT_S, so `timeout`'s own exit 124 must
# be mapped to a dedicated WARN naming the timeout -- never silently treated
# as ok (a stuck check 23 must never render the "workflow scripts pinned,
# capped, and schema-lean" ok-line).
cat >"$TMP/wf-pin-audit-sleeper.py" <<'PY'
import time
time.sleep(5)
PY
WF_TIMEOUT_OUT=$(CLAUDE_WF_PIN_AUDIT="$TMP/wf-pin-audit-sleeper.py" \
  CLAUDE_WF_PIN_AUDIT_TIMEOUT_S=1 run_doctor "$EMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$WF_TIMEOUT_OUT" "wf-pin-audit: timed out after 1s" \
  "B23 an oversized corpus that hangs the lexer times out with a named WARN"
omits "$WF_TIMEOUT_OUT" "workflow scripts pinned, capped, and schema-lean" \
  "B23 planted negative: a timed-out run must never render the ok-line"

# Check 33 (#1355, round 3 / #1356): the comparison itself now lives in
# scripts/cross-model-catalog-check.js (node --test covers it
# directly; see cross-model-catalog-check.test.js). This suite exercises the
# doctor's own thin consumer: env-to-flag plumbing, the always-on vs
# clean-only summary-line split, and every finding's message text reaching
# stdout through `timeout` + `jq` unmangled. run_doctor's
# DOTFILES_REPO="$home/dotfiles" makes the dotfiles-repo arm of the check
# exercise the fixture's own .compound-engineering/config.yaml, and
# HOME="$home" makes ~/SITES, ~/.codex/models_cache.json and
# ~/.claude/plugins/installed_plugins.json read the fixture tree the same way
# the doctor reads the operator's real one. run_doctor also force-clears
# CLAUDE_CODEX_MODELS_CACHE/CLAUDE_INSTALLED_PLUGINS on
# every call now (fixture hygiene): the bogus exports below are the planted
# leak canary for that clear — if it ever regressed, every fixture in this
# section would read the wrong catalog or registry at once, not
# just one dedicated test.
export CLAUDE_CODEX_MODELS_CACHE=$TMP/leaked-catalog-must-be-ignored.json
export CLAUDE_INSTALLED_PLUGINS=$TMP/leaked-registry-must-be-ignored.json
printf '%s\n' '{"models":[]}' >"$CLAUDE_CODEX_MODELS_CACHE"

CM_NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cm_days_ago() { date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ; }

make_cm_home() {
  local home
  home=$(make_home "$1" 0 0)
  mkdir -p "$home/dotfiles/.compound-engineering" "$home/.codex"
  printf '%s\n' "$home"
}

cm_catalog() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

cm_config() {
  local path=$1 peer=$2 model=$3
  mkdir -p "$(dirname "$path")"
  : >"$path"
  [ -n "$peer" ] && printf 'cross_model_peer: %s\n' "$peer" >>"$path"
  [ -n "$model" ] && printf 'cross_model_model: %s\n' "$model" >>"$path"
}

cm_entry() {
  local scope=$1 version=$2 install=$3 project=${4-}
  if [ -n "$project" ]; then
    printf '{"scope":"%s","version":"%s","installPath":"%s","projectPath":"%s"}' \
      "$scope" "$version" "$install" "$project"
  else
    printf '{"scope":"%s","version":"%s","installPath":"%s"}' "$scope" "$version" "$install"
  fi
}

make_cm_registry() {
  local home=$1 entries=$2
  mkdir -p "$home/.claude/plugins"
  printf '{"plugins":{"compound-engineering@every-marketplace":%s}}\n' "$entries" \
    >"$home/.claude/plugins/installed_plugins.json"
}

make_cm_plugin_script() {
  local path=$1 codex=$2
  mkdir -p "$(dirname "$path")"
  if [ -n "$codex" ]; then
    printf 'M_CODEX="%s"\n' "$codex" >"$path"
  else
    printf '# no default line here\n' >"$path"
  fi
}

CM_CATALOG_OK='{"fetched_at":"'"$CM_NOW_ISO"'","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1},{"slug":"gpt-5.6-luna","visibility":"list","supported_in_api":true,"priority":2}]}'

# --- all-served clean fixture --------------------------------------------
CM_OK_HOME=$(make_cm_home cm-ok)
cm_catalog "$CM_OK_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_OK_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_OK_OUT=$(run_doctor "$CM_OK_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_OK_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 a served slug produces the always-on summary line"
contains "$CM_OK_OUT" "dotfiles effective model 'gpt-6-astra' (config.yaml), catalog age 0d" \
  "B33 a served slug also produces the clean-only dotfiles line"
omits "$CM_OK_OUT" "is not in the served codex catalog" "B33 planted negative: a served slug names no WARN"
omits "$CM_OK_OUT" "shadows cross_model_model" "B33 planted negative: no config.local.yaml means no shadow WARN"

# --- required dotfiles path: missing/file are not a checked default ------
CM_REQUIRED_HOME=$(make_cm_home cm-required-dotfiles)
cm_catalog "$CM_REQUIRED_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
CM_REQUIRED_INSTALL=$CM_REQUIRED_HOME/user-plugin
make_cm_plugin_script "$CM_REQUIRED_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
make_cm_registry "$CM_REQUIRED_HOME" "[$(cm_entry user 1.0.0 "$CM_REQUIRED_INSTALL")]"
# No config file: a valid directory still uses the plugin.
CM_REQUIRED_VALID_OUT=$(run_doctor "$CM_REQUIRED_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REQUIRED_VALID_OUT" "dotfiles effective model 'gpt-5.6-luna' (plugin-default 1.0.0), catalog age 0d" \
  "B33 required-path control: a readable directory needs no config to use the plugin default"
contains "$CM_REQUIRED_VALID_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 required-path control: a readable directory is counted as checked"

mv "$CM_REQUIRED_HOME/dotfiles" "$CM_REQUIRED_HOME/saved-dotfiles"
CM_REQUIRED_MISSING_OUT=$(run_doctor "$CM_REQUIRED_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REQUIRED_MISSING_OUT" "dotfiles: required dotfiles directory is missing: $CM_REQUIRED_HOME/dotfiles" \
  "B33 required-path regression: a missing directory is named, not interpreted as absent config"
contains "$CM_REQUIRED_MISSING_OUT" "0 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 1 unreadable" \
  "B33 required-path regression: a missing directory is counted unreadable exactly once"
contains "$CM_REQUIRED_MISSING_OUT" "WARN cross-model codex repos: examined 0 item(s), expected at least 1" \
  "B33 required-path regression: a missing dotfiles path cannot satisfy the comparison floor"
omits "$CM_REQUIRED_MISSING_OUT" "dotfiles effective model" \
  "B33 required-path regression: a missing directory cannot produce the clean-only line"

printf 'not a directory\n' >"$CM_REQUIRED_HOME/dotfiles"
CM_REQUIRED_FILE_OUT=$(run_doctor "$CM_REQUIRED_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REQUIRED_FILE_OUT" "dotfiles: required dotfiles path is not a directory: $CM_REQUIRED_HOME/dotfiles" \
  "B33 required-path regression: a regular file is named rather than assigned a plugin default"
contains "$CM_REQUIRED_FILE_OUT" "0 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 1 unreadable" \
  "B33 required-path regression: a regular file is counted unreadable exactly once"
contains "$CM_REQUIRED_FILE_OUT" "WARN cross-model codex repos: examined 0 item(s), expected at least 1" \
  "B33 required-path regression: a regular file cannot satisfy the comparison floor"
omits "$CM_REQUIRED_FILE_OUT" "dotfiles effective model" \
  "B33 required-path regression: a regular file cannot produce the clean-only line"

# --- unserved slug + config.local.yaml shadow -----------------------------
CM_WARN_HOME=$(make_cm_home cm-warn)
cm_catalog "$CM_WARN_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_WARN_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_WARN_HOME/SITES/unserved-app/.compound-engineering" \
  "$CM_WARN_HOME/SITES/shadow-app/.compound-engineering" \
  "$CM_WARN_HOME/SITES/same-app/.compound-engineering"
# Planted negative: a slug the catalog above never lists.
cm_config "$CM_WARN_HOME/SITES/unserved-app/.compound-engineering/config.yaml" '' gpt-9-vega
# Shadow: config.local.yaml resolves first and differs from config.yaml,
# though both values are individually served — the shadow itself is the
# finding, independent of catalog membership.
cm_config "$CM_WARN_HOME/SITES/shadow-app/.compound-engineering/config.yaml" '' gpt-6-astra
cm_config "$CM_WARN_HOME/SITES/shadow-app/.compound-engineering/config.local.yaml" '' gpt-5.6-luna
# Planted negative (round 4): the same pin in both layers is not a shadow.
cm_config "$CM_WARN_HOME/SITES/same-app/.compound-engineering/config.yaml" '' gpt-6-astra
cm_config "$CM_WARN_HOME/SITES/same-app/.compound-engineering/config.local.yaml" '' gpt-6-astra
CM_WARN_OUT=$(run_doctor "$CM_WARN_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_WARN_OUT" \
  "unserved-app: cross_model_model 'gpt-9-vega' (config.yaml) is not in the served codex catalog — best selectable: gpt-6-astra, 2 selectable slug(s)" \
  "B33 finding #6: a planted unserved slug names the best selectable replacement and the selectable count"
contains "$CM_WARN_OUT" "shadow-app: config.local.yaml shadows cross_model_model ('gpt-5.6-luna') over config.yaml's 'gpt-6-astra'" \
  "B33 a config.local.yaml shadow is named even when both values are served"
omits "$CM_WARN_OUT" "shadow-app: cross_model_model" "B33 the shadowed repo's resolved (served) model gets no separate catalog WARN"
omits "$CM_WARN_OUT" "same-app: config.local.yaml shadows" "B33 planted negative: equal pins in both layers are not a shadow"
contains "$CM_WARN_OUT" "4 of 4 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 findings #2/#5: the always-on summary line still prints when other WARNs fired (stricter than round 2, which only asserted its absence)"
omits "$CM_WARN_OUT" "dotfiles effective model" "B33 any WARN still suppresses the clean-only dotfiles line"

# --- missing catalog -------------------------------------------------------
CM_NOCAT_HOME=$(make_cm_home cm-nocat)
cm_config "$CM_NOCAT_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
# No .codex/models_cache.json at all.
CM_NOCAT_OUT=$(run_doctor "$CM_NOCAT_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_NOCAT_OUT" \
  "codex model catalog missing: $CM_NOCAT_HOME/.codex/models_cache.json — run \`codex\` once to refresh it" \
  "B33 a missing catalog is named by path and told to run codex once"
contains "$CM_NOCAT_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 finding #2: a missing catalog still discloses the summary counts (stricter than round 2, which only asserted their absence)"
omits "$CM_NOCAT_OUT" "is not in the served codex catalog" "B33 a missing catalog skips every comparison"
omits "$CM_NOCAT_OUT" "dotfiles effective model" "B33 a missing catalog still blocks the clean-only line"

# --- empty / malformed / stale / no-fetched-at catalog states -------------
CM_CATEMPTY_HOME=$(make_cm_home cm-catempty)
cm_catalog "$CM_CATEMPTY_HOME/.codex/models_cache.json" '{"models":[]}'
cm_config "$CM_CATEMPTY_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATEMPTY_OUT=$(run_doctor "$CM_CATEMPTY_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_CATEMPTY_OUT" \
  "codex model catalog is empty: $CM_CATEMPTY_HOME/.codex/models_cache.json — run \`codex\` once to refresh it" \
  "B33 demoted item: an empty catalog is distinguished from a missing one"
omits "$CM_CATEMPTY_OUT" "is not in the served codex catalog" "B33 an empty catalog skips every comparison too"

CM_CATBAD_HOME=$(make_cm_home cm-catbad)
cm_catalog "$CM_CATBAD_HOME/.codex/models_cache.json" '{not valid json'
cm_config "$CM_CATBAD_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATBAD_OUT=$(run_doctor "$CM_CATBAD_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_CATBAD_OUT" \
  "codex model catalog unreadable: $CM_CATBAD_HOME/.codex/models_cache.json (malformed JSON) — run \`codex\` once to refresh it" \
  "B33 demoted item: malformed catalog JSON is its own state, distinct from missing or empty"

CM_CATSTALE_HOME=$(make_cm_home cm-catstale)
CM_CATSTALE_JSON='{"fetched_at":"'"$(cm_days_ago 40)"'","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}'
cm_catalog "$CM_CATSTALE_HOME/.codex/models_cache.json" "$CM_CATSTALE_JSON"
cm_config "$CM_CATSTALE_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATSTALE_OUT=$(run_doctor "$CM_CATSTALE_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_CATSTALE_OUT" \
  "codex model catalog is 40 days old ($CM_CATSTALE_HOME/.codex/models_cache.json) — run \`codex\` once to refresh it" \
  "B33 demoted item: a stale fetched_at warns by payload age, not the file's mtime"
contains "$CM_CATSTALE_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 a stale catalog still runs the model comparison, it just also warns about age"

# Exact boundary: the demoted item's own wording is ">= 30 days", not "> 30" —
# 29 must read fresh and 30 must read stale, distinct from CM_CATSTALE's
# coarse 40-day case above which cannot tell >= from > apart.
CM_CATFRESH29_HOME=$(make_cm_home cm-catfresh29)
CM_CATFRESH29_JSON='{"fetched_at":"'"$(cm_days_ago 29)"'","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}'
cm_catalog "$CM_CATFRESH29_HOME/.codex/models_cache.json" "$CM_CATFRESH29_JSON"
cm_config "$CM_CATFRESH29_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATFRESH29_OUT=$(run_doctor "$CM_CATFRESH29_HOME" "$EMPTY_HARNESS" 1)
omits "$CM_CATFRESH29_OUT" "codex model catalog is 29 days old" \
  "B33 demoted item boundary: 29 days old is not stale"
contains "$CM_CATFRESH29_OUT" "catalog age 29d" \
  "B33 demoted item boundary: a fresh 29-day catalog reaches the clean summary line"

CM_CATSTALE30_HOME=$(make_cm_home cm-catstale30)
CM_CATSTALE30_JSON='{"fetched_at":"'"$(cm_days_ago 30)"'","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}'
cm_catalog "$CM_CATSTALE30_HOME/.codex/models_cache.json" "$CM_CATSTALE30_JSON"
cm_config "$CM_CATSTALE30_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATSTALE30_OUT=$(run_doctor "$CM_CATSTALE30_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_CATSTALE30_OUT" \
  "codex model catalog is 30 days old ($CM_CATSTALE30_HOME/.codex/models_cache.json) — run \`codex\` once to refresh it" \
  "B33 demoted item boundary: exactly 30 days old is stale (the floor-division edge the review flagged)"

CM_CATNOFETCH_HOME=$(make_cm_home cm-catnofetch)
cm_catalog "$CM_CATNOFETCH_HOME/.codex/models_cache.json" \
  '{"models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}'
cm_config "$CM_CATNOFETCH_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATNOFETCH_OUT=$(run_doctor "$CM_CATNOFETCH_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_CATNOFETCH_OUT" \
  "codex model catalog has no parseable fetched_at ($CM_CATNOFETCH_HOME/.codex/models_cache.json); mtime " \
  "B33 demoted item: a catalog with no parseable fetched_at is its own WARN, not silently treated as fresh"
contains "$CM_CATNOFETCH_OUT" "is a hint only — run \`codex\` once to refresh it" \
  "B33 demoted item: the mtime fallback is explicitly labelled a hint, not a substitute for fetched_at"

# Round 4: a fetched_at in the future is clock skew or a corrupted cache —
# never fresh (the resolver's own readCatalogCache guard), never a negative age.
CM_CATFUTURE_HOME=$(make_cm_home cm-catfuture)
CM_CATFUTURE_JSON='{"fetched_at":"'"$(date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ)"'","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}'
cm_catalog "$CM_CATFUTURE_HOME/.codex/models_cache.json" "$CM_CATFUTURE_JSON"
cm_config "$CM_CATFUTURE_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_CATFUTURE_OUT=$(run_doctor "$CM_CATFUTURE_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_CATFUTURE_OUT" \
  "is in the future ($CM_CATFUTURE_HOME/.codex/models_cache.json) — clock skew or a corrupted cache; run \`codex\` once to refresh it" \
  "B33 round 4: a future fetched_at is its own WARN"
omits "$CM_CATFUTURE_OUT" "dotfiles effective model" \
  "B33 round 4: a future fetched_at never reaches the clean line (no negative age)"

# --- finding #1: unreadable config named, not treated as unset -----------
CM_CONFIG_UNREADABLE_HOME=$(make_cm_home cm-config-unreadable)
cm_catalog "$CM_CONFIG_UNREADABLE_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_CONFIG_UNREADABLE_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
chmod 000 "$CM_CONFIG_UNREADABLE_HOME/dotfiles/.compound-engineering/config.yaml"
if [ "$(id -u)" -ne 0 ]; then
  CM_CONFIG_UNREADABLE_OUT=$(run_doctor "$CM_CONFIG_UNREADABLE_HOME" "$EMPTY_HARNESS" 1)
  contains "$CM_CONFIG_UNREADABLE_OUT" "dotfiles: config.yaml could not be read (EACCES)" \
    "B33 finding #1: a config.yaml the process cannot read is named, not treated as unset"
  omits "$CM_CONFIG_UNREADABLE_OUT" "dotfiles effective model" \
    "B33 finding #1: an unreadable config keeps the run from reporting clean"
  contains "$CM_CONFIG_UNREADABLE_OUT" "0 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 1 unreadable" \
    "B33 round 4: a repo with an unreadable config is counted unreadable, never checked on a partial read"
else
  echo "SKIP: B33 finding #1 config-unreadable fixture needs a non-root process (chmod 000 does not block root)"
fi
chmod 644 "$CM_CONFIG_UNREADABLE_HOME/dotfiles/.compound-engineering/config.yaml"

# Round 4 (reliability review): an unsearchable .compound-engineering/
# directory made BOTH config files stat as absent through a catch-all, so the
# repo silently fell through to plugin-default resolution.
CM_CEDIR_LOCKED_HOME=$(make_cm_home cm-cedir-locked)
cm_catalog "$CM_CEDIR_LOCKED_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_CEDIR_LOCKED_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-9-vega
chmod 000 "$CM_CEDIR_LOCKED_HOME/dotfiles/.compound-engineering"
if [ "$(id -u)" -ne 0 ]; then
  CM_CEDIR_LOCKED_OUT=$(run_doctor "$CM_CEDIR_LOCKED_HOME" "$EMPTY_HARNESS" 1)
  contains "$CM_CEDIR_LOCKED_OUT" "dotfiles: config.local.yaml could not be read (EACCES)" \
    "B33 round 4: an unsearchable .compound-engineering/ names config.local.yaml as unreadable, not absent"
  contains "$CM_CEDIR_LOCKED_OUT" "dotfiles: config.yaml could not be read (EACCES)" \
    "B33 round 4: an unsearchable .compound-engineering/ names config.yaml as unreadable, not absent"
  contains "$CM_CEDIR_LOCKED_OUT" "0 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 1 unreadable" \
    "B33 round 4: the unsearchable repo is counted unreadable, never checked"
  omits "$CM_CEDIR_LOCKED_OUT" "plugin registry missing" \
    "B33 round 4 planted negative: the repo never falls through to plugin-default resolution"
  omits "$CM_CEDIR_LOCKED_OUT" "gpt-9-vega" \
    "B33 round 4 planted negative: nothing is compared on a partial read"
else
  echo "SKIP: B33 round 4 unsearchable .compound-engineering fixture needs a non-root process (chmod 000 does not block root)"
fi
chmod 755 "$CM_CEDIR_LOCKED_HOME/dotfiles/.compound-engineering"

# --- finding #2: unreadable SITES root, and a deeper unreadable repo -----
CM_SITES_UNREADABLE_HOME=$(make_cm_home cm-sites-unreadable)
cm_catalog "$CM_SITES_UNREADABLE_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_SITES_UNREADABLE_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_SITES_UNREADABLE_HOME/SITES"
chmod 000 "$CM_SITES_UNREADABLE_HOME/SITES"
if [ "$(id -u)" -ne 0 ]; then
  CM_SITES_UNREADABLE_OUT=$(run_doctor "$CM_SITES_UNREADABLE_HOME" "$EMPTY_HARNESS" 1)
  contains "$CM_SITES_UNREADABLE_OUT" \
    "SITES root exists but could not be listed: $CM_SITES_UNREADABLE_HOME/SITES (EACCES)" \
    "B33 finding #2: an unreadable SITES root is named, not silently treated as absent"
  contains "$CM_SITES_UNREADABLE_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
    "B33 finding #2: the summary still reports the dotfiles-only partial scan"
  omits "$CM_SITES_UNREADABLE_OUT" "dotfiles effective model" \
    "B33 finding #2: an unreadable SITES root keeps the run from reporting clean"
else
  echo "SKIP: B33 finding #2 sites-unreadable fixture needs a non-root process (chmod 000 does not block root)"
fi
chmod 755 "$CM_SITES_UNREADABLE_HOME/SITES"

CM_REPO_UNREADABLE_HOME=$(make_cm_home cm-repo-unreadable)
cm_catalog "$CM_REPO_UNREADABLE_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_REPO_UNREADABLE_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_REPO_UNREADABLE_HOME/SITES/aaa-locked-app/.compound-engineering" \
  "$CM_REPO_UNREADABLE_HOME/SITES/zzz-later-app/.compound-engineering"
cm_config "$CM_REPO_UNREADABLE_HOME/SITES/zzz-later-app/.compound-engineering/config.yaml" codex gpt-9-vega
chmod 000 "$CM_REPO_UNREADABLE_HOME/SITES/aaa-locked-app"
if [ "$(id -u)" -ne 0 ]; then
  CM_REPO_UNREADABLE_OUT=$(run_doctor "$CM_REPO_UNREADABLE_HOME" "$EMPTY_HARNESS" 1)
  contains "$CM_REPO_UNREADABLE_OUT" "aaa-locked-app: repo directory exists but could not be entered (EACCES)" \
    "B33 finding #2: a repo directory that cannot be entered is named, not silently skipped"
  contains "$CM_REPO_UNREADABLE_OUT" \
    "zzz-later-app: cross_model_model 'gpt-9-vega' (config.yaml) is not in the served codex catalog" \
    "B33 finding #2: a later repo (sorted after the unenterable one) is still checked"
  contains "$CM_REPO_UNREADABLE_OUT" "2 of 3 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 1 unreadable" \
    "B33 round 4: an unenterable repo is counted in unreadable and discovered, never dropped from the counts"
else
  echo "SKIP: B33 finding #2 repo-unreadable fixture needs a non-root process (chmod 000 does not block root)"
fi
chmod 755 "$CM_REPO_UNREADABLE_HOME/SITES/aaa-locked-app"

# --- finding #3: invalid cross_model_peer values -------------------------
CM_PEER_INVALID_LOCAL_HOME=$(make_cm_home cm-peer-invalid-local)
cm_catalog "$CM_PEER_INVALID_LOCAL_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
CM_PIL_INSTALL=$CM_PEER_INVALID_LOCAL_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_PIL_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
make_cm_registry "$CM_PEER_INVALID_LOCAL_HOME" "[$(cm_entry user 3.28.2 "$CM_PIL_INSTALL")]"
printf 'cross_model_peer: not-a-real-peer\n' >"$CM_PEER_INVALID_LOCAL_HOME/dotfiles/.compound-engineering/config.local.yaml"
cm_config "$CM_PEER_INVALID_LOCAL_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-totally-unserved
CM_PEER_INVALID_LOCAL_OUT=$(run_doctor "$CM_PEER_INVALID_LOCAL_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_PEER_INVALID_LOCAL_OUT" \
  "dotfiles: config.local.yaml sets cross_model_peer 'not-a-real-peer', which the installed compound-engineering plugin ($CM_PIL_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh) does not recognize — resolution continues to the next layer" \
  "B33 finding #3: an invalid config.local.yaml peer is named and resolution falls through"
contains "$CM_PEER_INVALID_LOCAL_OUT" \
  "dotfiles: cross_model_model 'gpt-totally-unserved' (config.yaml) is not in the served codex catalog" \
  "B33 finding #3: the lower config.yaml layer's codex peer still reaches the model comparison"
CM_PEER_INVALID_LOCAL_COUNT=$(printf '%s\n' "$CM_PEER_INVALID_LOCAL_OUT" | grep -c 'does not recognize')
status_is "$CM_PEER_INVALID_LOCAL_COUNT" 1 "B33 finding #3: only the invalid layer produces a peer-invalid finding"

CM_PEER_INVALID_BOTH_HOME=$(make_cm_home cm-peer-invalid-both)
cm_catalog "$CM_PEER_INVALID_BOTH_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
CM_PIB_INSTALL=$CM_PEER_INVALID_BOTH_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_PIB_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
make_cm_registry "$CM_PEER_INVALID_BOTH_HOME" "[$(cm_entry user 3.28.2 "$CM_PIB_INSTALL")]"
printf 'cross_model_peer: bogus-1\n' >"$CM_PEER_INVALID_BOTH_HOME/dotfiles/.compound-engineering/config.local.yaml"
printf 'cross_model_peer: bogus-2\ncross_model_model: gpt-9-vega\n' >"$CM_PEER_INVALID_BOTH_HOME/dotfiles/.compound-engineering/config.yaml"
CM_PEER_INVALID_BOTH_OUT=$(run_doctor "$CM_PEER_INVALID_BOTH_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_PEER_INVALID_BOTH_OUT" "dotfiles: config.local.yaml sets cross_model_peer 'bogus-1'" \
  "B33 finding #3: the upper layer's invalid peer is named"
contains "$CM_PEER_INVALID_BOTH_OUT" "dotfiles: config.yaml sets cross_model_peer 'bogus-2'" \
  "B33 finding #3: the lower layer's invalid peer is named too when it is also invalid"
CM_PEER_INVALID_BOTH_COUNT=$(printf '%s\n' "$CM_PEER_INVALID_BOTH_OUT" | grep -c 'does not recognize')
status_is "$CM_PEER_INVALID_BOTH_COUNT" 2 "B33 finding #3: both invalid layers each produce their own finding"
# Round 4 (validator-confirmed): CE's ordinary-key rule continues past every
# invalid layer to the skill default, codex. Round 3 dropped this repo from
# every count instead, so its model was never compared.
contains "$CM_PEER_INVALID_BOTH_OUT" \
  "dotfiles: cross_model_model 'gpt-9-vega' (config.yaml) is not in the served codex catalog" \
  "B33 round 4: invalid on every layer falls through to codex and still reaches the model comparison"
contains "$CM_PEER_INVALID_BOTH_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 round 4: the all-invalid repo is counted as checked, never dropped from the counts"

# --- finding #4: registry-driven plugin default, scoped per repo ---------
CM_REGISTRY_SCOPE_HOME=$(make_cm_home cm-registry-scope)
cm_catalog "$CM_REGISTRY_SCOPE_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
printf 'cross_model_peer: codex\n' >"$CM_REGISTRY_SCOPE_HOME/dotfiles/.compound-engineering/config.yaml"
mkdir -p "$CM_REGISTRY_SCOPE_HOME/SITES/proj-app/.compound-engineering"
printf 'cross_model_peer: codex\n' >"$CM_REGISTRY_SCOPE_HOME/SITES/proj-app/.compound-engineering/config.yaml"
CM_RS_OLD=$CM_REGISTRY_SCOPE_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/1.0.0
CM_RS_NEW=$CM_REGISTRY_SCOPE_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/9.0.0
make_cm_plugin_script "$CM_RS_OLD/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-old-slug
make_cm_plugin_script "$CM_RS_NEW/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-new-slug
# The registry pins the OLDER version to the project-scoped repo and the
# NEWER version to user scope -- a sort -V | tail -1 over the cache
# directory (the bug this finding fixes) would pick 9.0.0 for BOTH repos.
make_cm_registry "$CM_REGISTRY_SCOPE_HOME" \
  "[$(cm_entry project 1.0.0 "$CM_RS_OLD" "$CM_REGISTRY_SCOPE_HOME/SITES/proj-app"),$(cm_entry user 9.0.0 "$CM_RS_NEW")]"
CM_REGISTRY_SCOPE_OUT=$(run_doctor "$CM_REGISTRY_SCOPE_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REGISTRY_SCOPE_OUT" \
  "dotfiles: cross_model_model 'gpt-new-slug' (plugin-default 9.0.0) is not in the served codex catalog" \
  "B33 finding #4: the repo with no project-scoped entry resolves the user-scope version's default"
contains "$CM_REGISTRY_SCOPE_OUT" \
  "proj-app: cross_model_model 'gpt-old-slug' (plugin-default 1.0.0) is not in the served codex catalog" \
  "B33 finding #4: the project-scoped repo resolves its own pinned version's default, not the newest directory"

# Local scope must beat served project/user defaults, through a realpath
# alias, and must not leak into a different repo (even a child path).
CM_LOCAL_HOME=$(make_cm_home cm-local-scope)
cm_catalog "$CM_LOCAL_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_LOCAL_HOME/dotfiles/.compound-engineering/config.yaml" codex ''
cm_config "$CM_LOCAL_HOME/dotfiles/child/.compound-engineering/config.yaml" codex ''
ln -s "$CM_LOCAL_HOME/dotfiles" "$CM_LOCAL_HOME/dotfiles-alias"
mkdir -p "$CM_LOCAL_HOME/SITES"
ln -s "$CM_LOCAL_HOME/dotfiles/child" "$CM_LOCAL_HOME/SITES/child-app"
CM_LOCAL_USER=$CM_LOCAL_HOME/user-plugin
CM_LOCAL_PROJECT=$CM_LOCAL_HOME/project-plugin
CM_LOCAL_INSTALL=$CM_LOCAL_HOME/local-plugin
make_cm_plugin_script "$CM_LOCAL_USER/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-6-astra
make_cm_plugin_script "$CM_LOCAL_PROJECT/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
make_cm_plugin_script "$CM_LOCAL_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-local-unserved
printf 'M_CLAUDE="opus"\n' >>"$CM_LOCAL_USER/skills/ce-code-review/scripts/cross-model-adversarial-review.sh"
printf 'M_CLAUDE="opus"\n' >>"$CM_LOCAL_PROJECT/skills/ce-code-review/scripts/cross-model-adversarial-review.sh"
# Registry order is intentionally not scope precedence.
make_cm_registry "$CM_LOCAL_HOME" \
  "[$(cm_entry local 0.0.0 "$CM_LOCAL_HOME/must-not-read" "$CM_LOCAL_HOME/elsewhere"),$(cm_entry user 1.0.0 "$CM_LOCAL_USER"),$(cm_entry project 2.0.0 "$CM_LOCAL_PROJECT" "$CM_LOCAL_HOME/dotfiles-alias"),$(cm_entry local 3.0.0 "$CM_LOCAL_INSTALL" "$CM_LOCAL_HOME/dotfiles-alias")]"
CM_LOCAL_OUT=$(run_doctor "$CM_LOCAL_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_LOCAL_OUT" "dotfiles: cross_model_model 'gpt-local-unserved' (plugin-default 3.0.0) is not in the served codex catalog" \
  "B33 regression: matching local install wins over served project/user defaults"
omits "$CM_LOCAL_OUT" "child-app: cross_model_model" \
  "B33 planted negative: a nonmatching local/project entry cannot affect a child repo"
omits "$CM_LOCAL_OUT" "dotfiles effective model" \
  "B33 regression: the local default WARN suppresses the clean-only line"
contains "$CM_LOCAL_OUT" "2 of 2 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 regression: local scope leaves both repos counted"

# Only project/user scripts recognize claude. Validating against either would
# incorrectly skip dotfiles instead of warning and checking its local default.
cm_config "$CM_LOCAL_HOME/dotfiles/.compound-engineering/config.yaml" claude ''
CM_LOCAL_PEER_OUT=$(run_doctor "$CM_LOCAL_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_LOCAL_PEER_OUT" "dotfiles: config.yaml sets cross_model_peer 'claude', which the installed compound-engineering plugin ($CM_LOCAL_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh) does not recognize" \
  "B33 regression: peer-target validation uses the same matching local install"
contains "$CM_LOCAL_PEER_OUT" "dotfiles: cross_model_model 'gpt-local-unserved' (plugin-default 3.0.0) is not in the served codex catalog" \
  "B33 regression: the invalid local peer falls back to codex and audits the local default"
contains "$CM_LOCAL_PEER_OUT" "2 of 2 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 regression: local peer validation must not silently skip a repo"
omits "$CM_LOCAL_PEER_OUT" "child-app: cross_model_model" \
  "B33 planted negative: peer validation does not broaden local scope"

CM_REGISTRY_NO_ENTRY_HOME=$(make_cm_home cm-registry-no-entry)
cm_catalog "$CM_REGISTRY_NO_ENTRY_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_REGISTRY_NO_ENTRY_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_REGISTRY_NO_ENTRY_HOME/SITES/orphan-app/.compound-engineering"
# No cross_model_model pin on orphan-app, and the registry below has only a
# project-scoped entry for a DIFFERENT project (no user-scope fallback), so
# this repo has no applicable plugin entry. Round 3 skipped it quietly; the
# round-3 review's validator confirmed that let the dotfiles repo print the
# clean line over a repo nobody checked, so round 4 names it.
CM_RNE_INSTALL=$CM_REGISTRY_NO_ENTRY_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_RNE_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-6-astra
make_cm_registry "$CM_REGISTRY_NO_ENTRY_HOME" \
  "[$(cm_entry project 3.28.2 "$CM_RNE_INSTALL" "$CM_REGISTRY_NO_ENTRY_HOME/SITES/some-other-project")]"
CM_REGISTRY_NO_ENTRY_OUT=$(run_doctor "$CM_REGISTRY_NO_ENTRY_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REGISTRY_NO_ENTRY_OUT" "1 of 2 repo(s) checked: 0 other-peer skipped, 1 no-plugin skipped, 0 unreadable" \
  "B33 finding #4: a repo with no applicable registry entry is listed in the summary"
contains "$CM_REGISTRY_NO_ENTRY_OUT" \
  "orphan-app: no compound-engineering entry in the plugin registry ($CM_REGISTRY_NO_ENTRY_HOME/.claude/plugins/installed_plugins.json) applies to this repo, so the plugin's codex default cannot be resolved — pin cross_model_model or install the plugin for this repo" \
  "B33 round 4: the no-entry repo is named, not skipped silently"
omits "$CM_REGISTRY_NO_ENTRY_OUT" "plugin registry missing" "B33 finding #4: a readable registry is not reported missing"
omits "$CM_REGISTRY_NO_ENTRY_OUT" "dotfiles effective model" \
  "B33 round 4: an unchecked no-entry repo blocks the clean summary"

CM_REGISTRY_MISSING_HOME=$(make_cm_home cm-registry-missing)
cm_catalog "$CM_REGISTRY_MISSING_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_REGISTRY_MISSING_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_REGISTRY_MISSING_HOME/SITES/aaa-noplugin-app/.compound-engineering" \
  "$CM_REGISTRY_MISSING_HOME/SITES/zzz-own-pin-app/.compound-engineering"
cm_config "$CM_REGISTRY_MISSING_HOME/SITES/zzz-own-pin-app/.compound-engineering/config.yaml" codex gpt-9-vega
# No .claude/plugins/installed_plugins.json at all under this fixture home.
CM_REGISTRY_MISSING_OUT=$(run_doctor "$CM_REGISTRY_MISSING_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REGISTRY_MISSING_OUT" \
  "plugin registry missing: $CM_REGISTRY_MISSING_HOME/.claude/plugins/installed_plugins.json — cross_model_peer values cannot be validated and repos without their own cross_model_model pin cannot be checked; repair the registry or pin cross_model_model per repo" \
  "B33 finding #4: a missing registry fails closed and names the path"
contains "$CM_REGISTRY_MISSING_OUT" "2 of 3 repo(s) checked: 0 other-peer skipped, 1 no-plugin skipped, 0 unreadable" \
  "B33 round 4: the plugin-less repo is counted, the pinned ones checked"
contains "$CM_REGISTRY_MISSING_OUT" \
  "zzz-own-pin-app: cross_model_model 'gpt-9-vega' (config.yaml) is not in the served codex catalog" \
  "B33 finding #4: a later repo with its own pin is still checked after a missing-registry repo"
CM_REGISTRY_MISSING_WARN_COUNT=$(printf '%s\n' "$CM_REGISTRY_MISSING_OUT" | grep -c 'plugin registry missing')
status_is "$CM_REGISTRY_MISSING_WARN_COUNT" 1 "B33 finding #4: the missing-registry warning fires exactly once for the whole run"

CM_REGISTRY_MALFORMED_HOME=$(make_cm_home cm-registry-malformed)
cm_catalog "$CM_REGISTRY_MALFORMED_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_REGISTRY_MALFORMED_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_REGISTRY_MALFORMED_HOME/SITES/noplugin-app/.compound-engineering" "$CM_REGISTRY_MALFORMED_HOME/.claude/plugins"
printf '{not valid json' >"$CM_REGISTRY_MALFORMED_HOME/.claude/plugins/installed_plugins.json"
CM_REGISTRY_MALFORMED_OUT=$(run_doctor "$CM_REGISTRY_MALFORMED_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_REGISTRY_MALFORMED_OUT" \
  "plugin registry unreadable: $CM_REGISTRY_MALFORMED_HOME/.claude/plugins/installed_plugins.json — cross_model_peer values cannot be validated and repos without their own cross_model_model pin cannot be checked; repair the registry or pin cross_model_model per repo" \
  "B33 finding #4 demoted item: malformed registry JSON is distinguished from a missing registry"
contains "$CM_REGISTRY_MALFORMED_OUT" "1 of 2 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 1 unreadable" \
  "B33 round 4: an unpinned repo behind an unreadable registry is unreadable, not plugin-less"

CM_PLUGIN_DEFAULT_UNREADABLE_HOME=$(make_cm_home cm-plugdef-unreadable)
cm_catalog "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/SITES/bbb-nodefault-app/.compound-engineering" \
  "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/SITES/ccc-nodefault-app/.compound-engineering" \
  "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/SITES/zzz-own-pin-app/.compound-engineering"
cm_config "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/SITES/zzz-own-pin-app/.compound-engineering/config.yaml" codex gpt-9-vega
CM_PDU_INSTALL=$CM_PLUGIN_DEFAULT_UNREADABLE_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_PDU_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" ""
make_cm_registry "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME" "[$(cm_entry user 3.28.2 "$CM_PDU_INSTALL")]"
CM_PLUGIN_DEFAULT_UNREADABLE_OUT=$(run_doctor "$CM_PLUGIN_DEFAULT_UNREADABLE_HOME" "$EMPTY_HARNESS" 1)
# Round 4: one finding per repo that needs the default (round 3 deduped it
# per install path and dropped every affected repo from the counts), worded
# for what is actually wrong with the script.
contains "$CM_PLUGIN_DEFAULT_UNREADABLE_OUT" \
  "bbb-nodefault-app: the plugin's codex default is unknown — plugin script has no M_CODEX= line ($CM_PDU_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh)" \
  "B33 round 4: a plugin script with no M_CODEX= line is named for each repo that needs its default"
contains "$CM_PLUGIN_DEFAULT_UNREADABLE_OUT" \
  "ccc-nodefault-app: the plugin's codex default is unknown — plugin script has no M_CODEX= line" \
  "B33 round 4: a second repo on the same install gets its own finding"
CM_PDU_COUNT=$(printf '%s\n' "$CM_PLUGIN_DEFAULT_UNREADABLE_OUT" | grep -c "the plugin's codex default is unknown")
status_is "$CM_PDU_COUNT" 2 "B33 round 4: exactly one unknown-default finding per affected repo"
contains "$CM_PLUGIN_DEFAULT_UNREADABLE_OUT" "2 of 4 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 2 unreadable" \
  "B33 round 4: repos with an unknown plugin default are counted unreadable, never dropped from the counts"
contains "$CM_PLUGIN_DEFAULT_UNREADABLE_OUT" \
  "zzz-own-pin-app: cross_model_model 'gpt-9-vega' (config.yaml) is not in the served codex catalog" \
  "B33 finding #4: a later repo's own pin is still checked after an unreadable plugin default"

CM_PLUGIN_SCRIPT_MISSING_HOME=$(make_cm_home cm-plugscript-missing)
cm_catalog "$CM_PLUGIN_SCRIPT_MISSING_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_PLUGIN_SCRIPT_MISSING_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_PLUGIN_SCRIPT_MISSING_HOME/SITES/nodefault-app/.compound-engineering"
CM_PSM_INSTALL=$CM_PLUGIN_SCRIPT_MISSING_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
# The registry names an install path whose review script does not exist.
make_cm_registry "$CM_PLUGIN_SCRIPT_MISSING_HOME" "[$(cm_entry user 3.28.2 "$CM_PSM_INSTALL")]"
CM_PLUGIN_SCRIPT_MISSING_OUT=$(run_doctor "$CM_PLUGIN_SCRIPT_MISSING_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_PLUGIN_SCRIPT_MISSING_OUT" \
  "nodefault-app: the plugin's codex default is unknown — could not read the plugin script ($CM_PSM_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh: ENOENT)" \
  "B33 round 4: an unreadable script is worded apart from a script with no M_CODEX= line"

CM_PLUGIN_DEFAULT_SERVED_HOME=$(make_cm_home cm-plugdef-served)
cm_catalog "$CM_PLUGIN_DEFAULT_SERVED_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_PLUGIN_DEFAULT_SERVED_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_PLUGIN_DEFAULT_SERVED_HOME/SITES/nodefault-app/.compound-engineering"
CM_PDS_INSTALL=$CM_PLUGIN_DEFAULT_SERVED_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_PDS_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
make_cm_registry "$CM_PLUGIN_DEFAULT_SERVED_HOME" "[$(cm_entry user 3.28.2 "$CM_PDS_INSTALL")]"
CM_PLUGIN_DEFAULT_SERVED_OUT=$(run_doctor "$CM_PLUGIN_DEFAULT_SERVED_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_PLUGIN_DEFAULT_SERVED_OUT" "2 of 2 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 finding #4: a served plugin default reaches the clean summary with both repos counted"
omits "$CM_PLUGIN_DEFAULT_SERVED_OUT" "is not in the served codex catalog" "B33 planted negative: a served plugin default names no catalog WARN"

# --- finding #5: non-codex peer skip, counted on both the clean and WARN
# paths (round 2's count line printed only on the clean path) -------------
# The peer is validated against a real plugin script: since round 4 a peer
# the auditor cannot validate is named, so a clean other-peer skip needs one.
CM_OTHER_PEER_CLEAN_HOME=$(make_cm_home cm-other-peer-clean)
cm_catalog "$CM_OTHER_PEER_CLEAN_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_OTHER_PEER_CLEAN_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_OPC_INSTALL=$CM_OTHER_PEER_CLEAN_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_OPC_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
printf 'M_CLAUDE="claude-opus-5-5"\n' >>"$CM_OPC_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh"
make_cm_registry "$CM_OTHER_PEER_CLEAN_HOME" "[$(cm_entry user 3.28.2 "$CM_OPC_INSTALL")]"
mkdir -p "$CM_OTHER_PEER_CLEAN_HOME/SITES/other-tool-app/.compound-engineering"
cm_config "$CM_OTHER_PEER_CLEAN_HOME/SITES/other-tool-app/.compound-engineering/config.yaml" claude gpt-would-fail-if-compared
CM_OTHER_PEER_CLEAN_OUT=$(run_doctor "$CM_OTHER_PEER_CLEAN_HOME" "$EMPTY_HARNESS" 1)
omits "$CM_OTHER_PEER_CLEAN_OUT" "gpt-would-fail-if-compared" \
  "B33 finding #5: a non-codex peer's cross_model_model is never compared against the catalog"
contains "$CM_OTHER_PEER_CLEAN_OUT" "1 of 2 repo(s) checked: 1 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 finding #5: the other-peer skip is counted in the clean summary"
contains "$CM_OTHER_PEER_CLEAN_OUT" "dotfiles effective model 'gpt-6-astra' (config.yaml), catalog age 0d" \
  "B33 finding #5: an other-peer skip elsewhere does not block the clean summary"

# cursor has no M_CURSOR= line (the plugin's route_model prints 'auto' for
# it), so this also plants the round-4 no-model-target case.
CM_OTHER_PEER_WARN_HOME=$(make_cm_home cm-other-peer-warn)
cm_catalog "$CM_OTHER_PEER_WARN_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_OTHER_PEER_WARN_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-does-not-exist
CM_OPW_INSTALL=$CM_OTHER_PEER_WARN_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_OPW_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
make_cm_registry "$CM_OTHER_PEER_WARN_HOME" "[$(cm_entry user 3.28.2 "$CM_OPW_INSTALL")]"
mkdir -p "$CM_OTHER_PEER_WARN_HOME/SITES/other-tool-app/.compound-engineering"
cm_config "$CM_OTHER_PEER_WARN_HOME/SITES/other-tool-app/.compound-engineering/config.yaml" cursor gpt-would-fail-if-compared
CM_OTHER_PEER_WARN_OUT=$(run_doctor "$CM_OTHER_PEER_WARN_HOME" "$EMPTY_HARNESS" 1)
omits "$CM_OTHER_PEER_WARN_OUT" "gpt-would-fail-if-compared" \
  "B33 finding #5: the other-peer repo's model stays uncompared even on a WARN run"
omits "$CM_OTHER_PEER_WARN_OUT" "does not recognize" \
  "B33 round 4 planted negative: cursor is a plugin target even without an M_CURSOR= line"
contains "$CM_OTHER_PEER_WARN_OUT" "1 of 2 repo(s) checked: 1 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 finding #5: a WARN elsewhere must not hide the other-peer count (round 2 printed this only on the clean path)"
omits "$CM_OTHER_PEER_WARN_OUT" "dotfiles effective model" "B33 the unrelated WARN still suppresses the clean-only line"

# --- finding #6: hidden / deprecated catalog aliases, and the API-lane flag
# Mirrors the live catalog's shape: a priority-1 selectable model, a
# hidden-but-served alias, a listed model with supported_in_api: false, and a
# listed model deprecated toward the priority-1 one via upgrade.model. An
# explicit deprecated pin is kept by selectModel, not warned about. The
# supported_in_api flag gates only the opt-in API-key lane (apiCandidate),
# so since round 4 repo-noapi is a planted negative: the OAuth lane the
# cross-model peer runs on can select that model.
CM_SELECTABILITY_HOME=$(make_cm_home cm-selectability)
CM_SELECTABILITY_JSON='{"fetched_at":"'"$CM_NOW_ISO"'","models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1},{"slug":"gpt-hidden-vega","visibility":"hidden","supported_in_api":true,"priority":2},{"slug":"gpt-noapi-vega","visibility":"list","supported_in_api":false,"priority":3},{"slug":"gpt-old-vega","visibility":"list","supported_in_api":true,"priority":0,"upgrade":{"model":"gpt-6-astra"}}]}'
cm_catalog "$CM_SELECTABILITY_HOME/.codex/models_cache.json" "$CM_SELECTABILITY_JSON"
cm_config "$CM_SELECTABILITY_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
mkdir -p "$CM_SELECTABILITY_HOME/SITES/repo-hidden/.compound-engineering" \
  "$CM_SELECTABILITY_HOME/SITES/repo-noapi/.compound-engineering" \
  "$CM_SELECTABILITY_HOME/SITES/repo-deprecated/.compound-engineering" \
  "$CM_SELECTABILITY_HOME/SITES/repo-phantom/.compound-engineering"
cm_config "$CM_SELECTABILITY_HOME/SITES/repo-hidden/.compound-engineering/config.yaml" codex gpt-hidden-vega
cm_config "$CM_SELECTABILITY_HOME/SITES/repo-noapi/.compound-engineering/config.yaml" codex gpt-noapi-vega
cm_config "$CM_SELECTABILITY_HOME/SITES/repo-deprecated/.compound-engineering/config.yaml" codex gpt-old-vega
cm_config "$CM_SELECTABILITY_HOME/SITES/repo-phantom/.compound-engineering/config.yaml" codex gpt-nonexistent
CM_SELECTABILITY_OUT=$(run_doctor "$CM_SELECTABILITY_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_SELECTABILITY_OUT" \
  "repo-hidden: cross_model_model 'gpt-hidden-vega' (config.yaml) is served but not selectable — hidden" \
  "B33 finding #6: a served-but-hidden slug is model-not-selectable, not model-unserved"
omits "$CM_SELECTABILITY_OUT" "repo-noapi: cross_model_model" \
  "B33 round 4 planted negative: supported_in_api: false is selectable on the OAuth lane, so no WARN"
omits "$CM_SELECTABILITY_OUT" "repo-deprecated: cross_model_model" \
  "B33 regression: a listed deprecated explicit pin stays selectable, just as selectModel keeps it"
contains "$CM_SELECTABILITY_OUT" \
  "repo-phantom: cross_model_model 'gpt-nonexistent' (config.yaml) is not in the served codex catalog — best selectable: gpt-6-astra, 3 selectable slug(s)" \
  "B33 finding #6: model-unserved names the best selectable replacement and the selectable count, not the whole list"

contains "$CM_SELECTABILITY_OUT" "5 of 5 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 regression: accepting a deprecated pin does not remove any repo from the counts"

# Positive clean observable: remove unrelated WARNs from the mixed fixture.
CM_DEPRECATED_HOME=$(make_cm_home cm-deprecated)
cm_catalog "$CM_DEPRECATED_HOME/.codex/models_cache.json" "$CM_SELECTABILITY_JSON"
cm_config "$CM_DEPRECATED_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-old-vega
CM_DEPRECATED_OUT=$(run_doctor "$CM_DEPRECATED_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_DEPRECATED_OUT" "dotfiles effective model 'gpt-old-vega' (config.yaml), catalog age 0d" \
  "B33 regression: an explicit listed deprecated pin reaches the clean-only dotfiles line"
contains "$CM_DEPRECATED_OUT" "1 of 1 repo(s) checked: 0 other-peer skipped, 0 no-plugin skipped, 0 unreadable" \
  "B33 regression: the accepted deprecated pin is counted as checked"

# --- demoted item: zero checked repos trips the floor ---------------------
CM_ZERO_REPOS_HOME=$(make_cm_home cm-zero-repos)
cm_catalog "$CM_ZERO_REPOS_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
# No dotfiles config and no SITES repos at all -- dotfiles falls through to
# plugin-default resolution with no registry present, landing in
# skipped_no_plugin, so repos.checked stays 0.
CM_ZERO_REPOS_OUT=$(run_doctor "$CM_ZERO_REPOS_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_ZERO_REPOS_OUT" \
  "WARN cross-model codex repos: examined 0 item(s), expected at least 1 — refusing to report clean" \
  "B33 demoted item: zero checked repos trips the floor instead of reporting clean"
contains "$CM_ZERO_REPOS_OUT" "0 of 1 repo(s) checked: 0 other-peer skipped, 1 no-plugin skipped, 0 unreadable" \
  "B33 demoted item: the zero-repos run still discloses its own counts"
contains "$CM_ZERO_REPOS_OUT" "plugin registry missing:" \
  "B33 demoted item: the zero-repos fixture's own repo also names why it could not be checked"

# --- finding #7: dotfiles pinning a non-codex peer still gets a real
# enumerated dotfiles.source, never a blank one ----------------------------
CM_DOTFILES_OTHER_PEER_HOME=$(make_cm_home cm-dotfiles-other-peer)
cm_catalog "$CM_DOTFILES_OTHER_PEER_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
CM_DOP_INSTALL=$CM_DOTFILES_OTHER_PEER_HOME/.claude/plugins/cache/every-marketplace/compound-engineering/3.28.2
make_cm_plugin_script "$CM_DOP_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh" gpt-5.6-luna
printf 'M_GROK="grok-4.7"\n' >>"$CM_DOP_INSTALL/skills/ce-code-review/scripts/cross-model-adversarial-review.sh"
make_cm_registry "$CM_DOTFILES_OTHER_PEER_HOME" "[$(cm_entry user 3.28.2 "$CM_DOP_INSTALL")]"
printf 'cross_model_peer: grok\n' >"$CM_DOTFILES_OTHER_PEER_HOME/dotfiles/.compound-engineering/config.yaml"
mkdir -p "$CM_DOTFILES_OTHER_PEER_HOME/SITES/clean-app/.compound-engineering"
cm_config "$CM_DOTFILES_OTHER_PEER_HOME/SITES/clean-app/.compound-engineering/config.yaml" codex gpt-6-astra
CM_DOTFILES_OTHER_PEER_OUT=$(run_doctor "$CM_DOTFILES_OTHER_PEER_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_DOTFILES_OTHER_PEER_OUT" "dotfiles effective model '' (other-peer, skipped), catalog age 0d" \
  "B33 finding #7: dotfiles.source is a real enumerated string even when dotfiles itself pins a non-codex peer"
omits "$CM_DOTFILES_OTHER_PEER_OUT" "dotfiles effective model '' ()" \
  "B33 finding #7 planted negative: the old blank-source shape can no longer occur"

# --- demoted item: the auditor itself being unavailable is a WARN, never
# a fabricated clean run ---------------------------------------------------
CM_AUDITOR_MISSING_HOME=$(make_cm_home cm-auditor-missing)
cm_catalog "$CM_AUDITOR_MISSING_HOME/.codex/models_cache.json" "$CM_CATALOG_OK"
cm_config "$CM_AUDITOR_MISSING_HOME/dotfiles/.compound-engineering/config.yaml" codex gpt-6-astra
CM_AUDITOR_MISSING_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_MISSING_HOME/does-not-exist.js" \
  run_doctor "$CM_AUDITOR_MISSING_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_AUDITOR_MISSING_OUT" "cross-model catalog auditor missing: $CM_AUDITOR_MISSING_HOME/does-not-exist.js" \
  "B33 demoted item: a missing auditor script warns and never fabricates a clean run"

CM_AUDITOR_GARBAGE_HOME=$(make_cm_home cm-auditor-garbage)
printf '%s\n' "console.log('not json, deliberately');" >"$CM_AUDITOR_GARBAGE_HOME/garbage-auditor.js"
CM_AUDITOR_GARBAGE_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_GARBAGE_HOME/garbage-auditor.js" \
  run_doctor "$CM_AUDITOR_GARBAGE_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_AUDITOR_GARBAGE_OUT" "cross-model catalog auditor produced unexpected output:" \
  "B33 demoted item: non-JSON auditor stdout warns by name instead of failing jq silently"

CM_AUDITOR_TIMEOUT_HOME=$(make_cm_home cm-auditor-timeout)
printf '%s\n' "setTimeout(() => {}, 5000);" >"$CM_AUDITOR_TIMEOUT_HOME/slow-auditor.js"
CM_AUDITOR_TIMEOUT_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_TIMEOUT_HOME/slow-auditor.js" CLAUDE_CM_TIMEOUT=1 \
  run_doctor "$CM_AUDITOR_TIMEOUT_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_AUDITOR_TIMEOUT_OUT" \
  "cross-model catalog auditor timed out after 1s: $CM_AUDITOR_TIMEOUT_HOME/slow-auditor.js" \
  "B33 demoted item: a hung auditor times out and warns instead of hanging the whole doctor run"

# Round 4 (Codex peer review): the doctor checks the auditor's whole JSON
# contract, typed, not the presence of four keys. This shape has all four
# keys and a valid checked count; round 3 let the jq error inside the
# findings loop pass silently and printed the clean line.
CM_AUDITOR_BADSHAPE_HOME=$(make_cm_home cm-auditor-badshape)
cat >"$CM_AUDITOR_BADSHAPE_HOME/badshape-auditor.js" <<'JS'
console.log(JSON.stringify({ findings: 'not-an-array', repos: { checked: 1, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: 0, discovered: 1 }, catalog: { age_days: 0 }, dotfiles: { model: 'gpt', source: 'config.yaml' } }));
JS
CM_AUDITOR_BADSHAPE_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_BADSHAPE_HOME/badshape-auditor.js" \
  run_doctor "$CM_AUDITOR_BADSHAPE_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_AUDITOR_BADSHAPE_OUT" "cross-model catalog auditor produced unexpected output:" \
  "B33 round 4: a findings value that is not an array fails the typed contract"
omits "$CM_AUDITOR_BADSHAPE_OUT" "dotfiles effective model" \
  "B33 round 4 planted negative: a malformed auditor shape never reaches the clean line"

CM_AUDITOR_BADSUM_HOME=$(make_cm_home cm-auditor-badsum)
cat >"$CM_AUDITOR_BADSUM_HOME/badsum-auditor.js" <<'JS'
console.log(JSON.stringify({ findings: [], repos: { checked: 1, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: 0, discovered: 2 }, catalog: { age_days: 0 }, dotfiles: { model: 'gpt-6-astra', source: 'config.yaml' } }));
JS
CM_AUDITOR_BADSUM_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_BADSUM_HOME/badsum-auditor.js" \
  run_doctor "$CM_AUDITOR_BADSUM_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_AUDITOR_BADSUM_OUT" "cross-model catalog auditor produced unexpected output:" \
  "B33 round 4: repo buckets that do not sum to repos.discovered fail the contract (a repo went missing)"
omits "$CM_AUDITOR_BADSUM_OUT" "dotfiles effective model" \
  "B33 round 4 planted negative: a repo missing from the counts never reaches the clean line"

# stderr is captured apart from stdout: a diagnostic line on stderr must not
# corrupt valid JSON, and a failing auditor's WARN quotes it.
CM_AUDITOR_STDERR_HOME=$(make_cm_home cm-auditor-stderr)
cat >"$CM_AUDITOR_STDERR_HOME/stderr-auditor.js" <<'JS'
process.stderr.write('(node:1) ExperimentalWarning: stray diagnostic line\n');
console.log(JSON.stringify({ findings: [], repos: { checked: 1, skipped_other_peer: 0, skipped_no_plugin: 0, unreadable: 0, discovered: 1 }, catalog: { age_days: 0 }, dotfiles: { model: 'gpt-6-astra', source: 'config.yaml' } }));
JS
CM_AUDITOR_STDERR_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_STDERR_HOME/stderr-auditor.js" \
  run_doctor "$CM_AUDITOR_STDERR_HOME" "$EMPTY_HARNESS" 1)
omits "$CM_AUDITOR_STDERR_OUT" "cross-model catalog auditor produced unexpected output" \
  "B33 round 4: a stray stderr line does not turn valid JSON into unexpected output"
contains "$CM_AUDITOR_STDERR_OUT" "dotfiles effective model 'gpt-6-astra' (config.yaml), catalog age 0d" \
  "B33 round 4: valid JSON with stderr noise still reaches the clean line"

CM_AUDITOR_EXIT_HOME=$(make_cm_home cm-auditor-exit)
cat >"$CM_AUDITOR_EXIT_HOME/exit-auditor.js" <<'JS'
process.stderr.write('auditor blew up: EIO reading the catalog\n');
process.exitCode = 3;
JS
CM_AUDITOR_EXIT_OUT=$(CLAUDE_CM_AUDITOR="$CM_AUDITOR_EXIT_HOME/exit-auditor.js" \
  run_doctor "$CM_AUDITOR_EXIT_HOME" "$EMPTY_HARNESS" 1)
contains "$CM_AUDITOR_EXIT_OUT" "cross-model catalog auditor exited 3: auditor blew up: EIO reading the catalog" \
  "B33 round 4: a failing auditor's WARN quotes its stderr"

unset CLAUDE_CODEX_MODELS_CACHE CLAUDE_INSTALLED_PLUGINS

if [ "$fail" -ne 0 ]; then
  echo "FAILED — harness-doctor vacuity: $pass passed, $fail failed" >&2
  exit 1
fi
echo "ok — harness-doctor vacuity: $pass/$pass assertions passed"
