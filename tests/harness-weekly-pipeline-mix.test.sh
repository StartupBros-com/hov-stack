#!/usr/bin/env bash
# Hermetic regression contract for the pipeline-mix arm of harness-weekly.sh's
# toast gate (dotfiles#1045, pro-gate round 1 finding at harness-weekly.sh:107).
#
# THE FINDING: pipeline-mix-report.py prints its findings BRACKETED --
# `[WARN] pipeline-mix: ...` -- per the sibling report contract, and a trailing
# `pipeline-mix-flagged:N` counter. harness-weekly's gate recognizes exactly two
# shapes: a column-0 `^WARN` line, and an explicit allowlist of NAMED counters.
# A bracket matches neither. So with every other check healthy, exceeding either
# pipeline threshold printed into the log and notified nobody; only the report's
# own crash/dead-feed WARN could ever toast. A section wired to nothing is the
# same silence the section exists to break.
#
# EXTRACTION APPROACH: the same one harness-weekly-stash.test.sh uses. Running
# the whole file per scenario would invoke harness-doctor, gh, pnpm and the
# operator's real notify.sh, and would write into their ~/.claude/logs. This
# sed-extracts the REAL counter-scrape-and-notify block out of the shipped
# script and executes that, so it exercises shipped code rather than a
# hand-copied reimplementation. The sanity checks below fail loudly if the
# extraction ever comes back empty or loses the counter, so restructuring
# harness-weekly.sh cannot silently turn this suite into a test of nothing.
#
# notify.sh is STUBBED into a scratch HOME. This suite never sends a toast.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/scripts/harness-weekly.sh
TMP=$(mktemp -d /tmp/hw-pipeline-mix-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle'"$'\n'"$output" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'"$'\n'"$output" ;; *) ok ;; esac
}

# -- extract the counter-scrape + notify gate from the REAL shipped script ----
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'SCRIPTS=$HOME/.claude/scripts'
  echo 'REPORT=$1'
  sed -n '/^WARNS=\$(grep -c/,/^fi$/p' "$SRC"
} > "$TMP/gate.sh"
chmod +x "$TMP/gate.sh"

if [ -s "$TMP/gate.sh" ]; then ok; else
  echo "FAIL: sed extraction produced an empty gate.sh -- the 'WARNS=\$(grep -c' anchor in harness-weekly.sh may have changed" >&2
  exit 1
fi
bash -n "$TMP/gate.sh" || { echo "FAIL: extracted gate.sh has a syntax error" >&2; exit 1; }
if grep -q 'pipeline-mix-flagged' "$TMP/gate.sh"; then ok; else
  bad "extraction sanity: pipeline-mix-flagged is not scraped in the extracted gate -- the counter is unwired"
fi
if grep -q 'notify.sh' "$TMP/gate.sh"; then ok; else
  bad "extraction sanity: the extracted block does not reach notify.sh -- extraction is testing the wrong lines"
fi

# -- scratch HOME with a notify.sh that records instead of toasting -----------
FIXTURE_HOME=$TMP/home
mkdir -p "$FIXTURE_HOME/.claude/scripts"
cat > "$FIXTURE_HOME/.claude/scripts/notify.sh" <<'STUB'
#!/usr/bin/env bash
printf 'NOTIFIED %s\n' "$1" >> "$HOME/notify.log"
STUB
chmod +x "$FIXTURE_HOME/.claude/scripts/notify.sh"

run_gate() { # $1 = report file
  : > "$FIXTURE_HOME/notify.log"
  HOME="$FIXTURE_HOME" bash "$TMP/gate.sh" "$1" >/dev/null 2>&1
  cat "$FIXTURE_HOME/notify.log"
}

# Every case below writes a report in which pipeline-mix is the ONLY section
# with anything to say: no column-0 WARN line anywhere, and no other named
# counter, so every other term in the gate defaults to 0. If a toast fires, the
# pipeline-mix counter is the only thing that could have fired it.
mkreport() { # $1 = report path, $2 = pipeline-mix-flagged value ("" = omit)
  {
    echo "# harness weekly - fixture"
    echo "## pipeline mix"
    echo "gated merges in 7d: 12, of which 9 touch only the pipeline itself (75%)"
    echo "Pro rounds per gated issue: median 2, worst hov-stack#1028=5"
    echo "[WARN] pipeline-mix: 75% of merges were the pipeline working on itself (over 40%) - check that intake is fed from the product backlog"
    echo "[WARN] pipeline-mix: 1 issue(s) past 3 Pro rounds (hov-stack#1028) - a chain that does not converge is a design question, not another patch"
    [ -n "$2" ] && echo "pipeline-mix-flagged:$2"
  } > "$1"
}

# -- case a: pipeline-mix is the only nonzero counter -> the toast fires ------
# This is the finding, stated as a test: two real threshold findings, an
# otherwise healthy week, and before the fix nobody was told.
mkreport "$TMP/report-a.log" 2
out=$(run_gate "$TMP/report-a.log")
contains "$out" "NOTIFIED"                  "a1: a pipeline-mix flag alone triggers the notification"
contains "$out" "2 pipeline-mix flag(s)"    "a2: the toast names the pipeline-mix count, not an anonymous drift warning"
# The report body carries no '^WARN' line, so this cannot have come from WARNS.
if grep -qE '^WARN' "$TMP/report-a.log"; then
  bad "a3: the fixture leaked a column-0 WARN line, so the case proves nothing"
else ok; fi

# -- case b (PLANTED NEGATIVE): a quiet week does not toast ------------------
mkreport "$TMP/report-b.log" 0
sed -i '/^\[WARN\]/d' "$TMP/report-b.log"
out=$(run_gate "$TMP/report-b.log")
omits "$out" "NOTIFIED" "b1: a zero pipeline-mix counter must not nag"

# -- case c (PLANTED NEGATIVE): brackets alone were never the signal ---------
# The mechanism of the finding: with the counter absent, the two [WARN] body
# lines are still there and still must not reach the gate on their own. If this
# ever starts notifying, the gate has grown a bracket-matching path and case a
# would pass for the wrong reason.
mkreport "$TMP/report-c.log" ""
out=$(run_gate "$TMP/report-c.log")
omits "$out" "NOTIFIED" "c1: bracketed [WARN] findings alone do not reach the toast gate"

# -- case d: the report's own dead-feed WARN still toasts --------------------
# The unbracketed partial/dead-feed line is a separate contract (^WARN), and the
# counter fix must not displace it.
mkreport "$TMP/report-d.log" 0
sed -i '/^\[WARN\]/d' "$TMP/report-d.log"
echo "WARN pipeline-mix: could not read merges for acme-org/announce-bot - the share is partial" >> "$TMP/report-d.log"
out=$(run_gate "$TMP/report-d.log")
contains "$out" "NOTIFIED"           "d1: a dead pipeline-mix feed still trips the drift gate"
contains "$out" "1 drift warning(s)" "d2: the dead-feed line lands in WARNS, not in the pipeline-mix counter"

# -- case e: the wiring is present in the real script, not just the extract --
if grep -q "PIPEMIX=\$(grep -oE 'pipeline-mix-flagged:\[0-9\]+'" "$SRC"; then ok; else
  bad "e1: harness-weekly.sh does not read a PIPEMIX counter from the report"
fi
# Position-independent on purpose: the sibling stash suite already pins the
# term that must stay last in the chain, so this only asserts membership.
if grep -q '\${PIPEMIX:-0}" -gt 0 \]' "$SRC"; then ok; else
  bad "e2: PIPEMIX is not OR-ed into the notify gate, so the flags would never toast"
fi
if grep -q 'pipeline-mix flag(s)' "$SRC"; then ok; else
  bad "e3: the toast message does not name the pipeline-mix count"
fi
# The producer has to keep printing what the gate reads.
if grep -q 'pipeline-mix-flagged:%d' "$REPO/scripts/pipeline-mix-report.py"; then ok; else
  bad "e4: pipeline-mix-report.py no longer prints the counter the gate scrapes"
fi

# -- report -----------------------------------------------------------------
total=$((pass + fail))
if [ "$fail" -gt 0 ]; then
  echo "FAILED — harness-weekly pipeline-mix toast gate: $fail of $total assertions failed" >&2
  exit 1
fi
echo "ok — harness-weekly pipeline-mix toast gate: $pass/$total assertions passed"
