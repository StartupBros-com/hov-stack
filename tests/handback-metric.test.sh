#!/usr/bin/env bash
# Hermetic regression tests for harness-doctor's positive-handoff metric (check
# 26). Every case runs against an isolated $HOME with a fixture ledger written
# to the exact path check 26 reads -- $HOME/.claude/logs/handback-ledger.jsonl,
# matching check 25's own hardcoded-path convention (no override exists).
# Never reads or writes the operator's real ~/.claude/logs/handback-ledger.jsonl.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR="$HERE/scripts/harness-doctor.sh"
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Isolate HOME before invoking the doctor at all. Check 26 always reads
# $HOME/.claude/logs/handback-ledger.jsonl, so isolating HOME is both
# necessary and sufficient -- no env override is needed or exists.
export HOME="$TMP/home"
export HARNESS_DOCTOR_SKIP_TESTS=1
mkdir -p "$HOME"
LEDGER="$HOME/.claude/logs/handback-ledger.jsonl"

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$DOCTOR" ] || { echo "FAIL: doctor not found at $DOCTOR" >&2; exit 1; }
bash -n "$DOCTOR" || { echo "FAIL: $DOCTOR does not parse" >&2; exit 1; }

write_fixture() {
  local kind=$1
  mkdir -p "$(dirname "$LEDGER")"
  python3 - "$LEDGER" "$kind" <<'PY'
import datetime
import json
import sys

path, kind = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)


def row(session, pr, outcome=None, *, when=now, fp=1):
    data = {
        "ts": when.isoformat().replace("+00:00", "Z"),
        "session_id": session,
        "repo": "acme/widgets",
        "pr": pr,
        "condition": "no-tag",
        "mode": "shadow",
    }
    if fp is not None:
        data["fp"] = fp
    if outcome is not None:
        data["outcome"] = outcome
    return data


extra_lines = []
if kind == "mixed":
    # The first row mirrors U3's shipped v1 shape: no fp, no outcome -- a
    # hand-back by provenance, since appendHandbackRow() only ever logs an
    # UNRESOLVED evaluation. The third row is the planted non-hand-back that
    # must not inflate the count.
    rows = [
        row("session-legacy", 1, fp=None),
        row("session-handback", 2, "hand-back"),
        row("session-inconclusive", 3, "inconclusive"),
    ]
elif kind == "inconclusive":
    rows = [
        row("session-inconclusive-a", 11, "inconclusive"),
        row("session-inconclusive-b", 12, "inconclusive"),
    ]
elif kind == "window-malformed":
    rows = [
        row("session-old", 21, "hand-back", when=now - datetime.timedelta(days=8)),
        row("session-fresh", 22, "hand-back"),
    ]
    extra_lines = ["this is not valid JSON {"]
else:
    raise SystemExit(f"unknown fixture kind: {kind}")

with open(path, "w", encoding="utf-8") as f:
    for item in rows:
        f.write(json.dumps(item) + "\n")
    for line in extra_lines:
        f.write(line + "\n")
PY
}

extract_check() {
  python3 - "$CASE_OUT" "$SECTION" <<'PY'
import sys

report, destination = sys.argv[1:]
text = open(report, encoding="utf-8", errors="replace").read()
start = text.find("== 26.")
end = text.find("\n== 27.", start) if start >= 0 else -1
section = text[start:end if end >= 0 else None] if start >= 0 else ""
open(destination, "w", encoding="utf-8").write(section)
PY
}

CASE=0
run_doctor() {
  CASE=$((CASE + 1))
  CASE_OUT="$TMP/doctor-$CASE.out"
  SECTION="$CASE_OUT.check-26"
  # Other checks intentionally see this fake HOME and will WARN (rollout
  # gaps, missing scripts, etc.) -- expected and out of scope. Only check
  # 26's own extracted section is asserted on below.
  bash "$DOCTOR" >"$CASE_OUT" 2>&1 || true
  extract_check
}

expect() {
  local needle=$1 message=$2
  if grep -Fq -- "$needle" "$SECTION"; then
    ok
  else
    bad "$message: $(<"$SECTION")"
  fi
}

expect_no_warn() {
  if grep -Fq 'WARN' "$SECTION"; then
    bad "$1: $(<"$SECTION")"
  else
    ok
  fi
}

expect_check_boundary() {
  if grep -Fq '== 27.' "$SECTION"; then
    bad "$1: check 27 leaked into check 26: $(<"$SECTION")"
  else
    ok
  fi
}

echo "-- happy: mixed outcomes count only hand-backs and distinct sessions --"
write_fixture mixed
run_doctor
expect 'handback-flagged:2' 'happy: expected two hand-back records'
expect '2 hand-back record(s)' 'happy: record count was not reported'
expect '2 distinct session(s)' 'happy: distinct-session count was not reported'
expect_no_warn 'happy: metric emitted WARN'
expect_check_boundary 'happy: extraction must stop at the next numbered check'

echo "-- planted negative: all inconclusive rows must not inflate hand-back count --"
write_fixture inconclusive
run_doctor
expect 'handback-flagged:0' 'all-inconclusive: expected handback-flagged:0'
expect '0 distinct session(s)' 'all-inconclusive: inconclusive sessions were counted'
expect_no_warn 'all-inconclusive: metric emitted WARN'

echo "-- edge: absent ledger skips cleanly without a metric WARN --"
rm -f "$LEDGER"
run_doctor
expect 'hand-back ledger absent' 'absent-ledger: did not report skip'
expect_no_warn 'absent-ledger: emitted WARN instead of an ok/skip'

echo "-- edge: stale and malformed rows are excluded without crashing --"
write_fixture window-malformed
run_doctor
expect 'handback-flagged:1' 'window-malformed: expected one in-window hand-back'
expect '1 distinct session(s)' 'window-malformed: expected only fresh session'
expect_no_warn 'window-malformed: metric emitted WARN'

if [ "$fail" -eq 0 ]; then
  echo "ok — handback metric: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — handback metric: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
