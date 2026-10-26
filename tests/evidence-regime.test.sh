#!/usr/bin/env bash
# evidence-regime.test.sh: planted-negative suite for gate-check.sh and ab-pair.sh.
#
# Every case is a PLANTED NEGATIVE paired with a near-identical control that differs ONLY in
# the forbidden dimension. A suite that only proves the happy path cannot detect a gate that
# has stopped gating.
#
# Ceremony Test: consumer = anyone editing either script; gate = their correctness;
# defect = OBSERVED (a green aggregate that proves nothing: acme-app #1251);
# delete-when = both scripts are deleted.
#
# Usage: tests/evidence-regime.test.sh   (also run by harness-doctor)
# Exit: 0 all pass, 1 any failure.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE_CHECK="$ROOT/scripts/gate-check.sh"
AB_PAIR="$ROOT/bin/ab-pair.sh"
WS_CHECK="$ROOT/scripts/work-spec-check.sh"
WT_NEW="$ROOT/scripts/wt-new.sh"

WORK=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="evregime-"))')
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { # check <label> <want-exit> <got-exit>
  if [ "$2" = "$3" ]; then
    printf '  PASS  %-58s exit=%s\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-58s want=%s got=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}

# ---------------------------------------------------------------- fixtures (no shell redirect)
WORK="$WORK" python3 - <<'PY'
import json, os, pathlib
w = pathlib.Path(os.environ["WORK"])
def put(name, obj): (w / name).write_text(json.dumps(obj))

put("skipped.json", {"required": ["Test", "Lint"], "check_runs": [
    {"name": "Test", "status": "completed", "conclusion": "skipped"},
    {"name": "Lint", "status": "completed", "conclusion": "success"}]})
# Control: byte-identical except the one forbidden dimension (Test's conclusion).
put("success.json", {"required": ["Test", "Lint"], "check_runs": [
    {"name": "Test", "status": "completed", "conclusion": "success"},
    {"name": "Lint", "status": "completed", "conclusion": "success"}]})
put("empty.json", {"check_runs": [], "statuses": []})
put("missing.json", {"required": ["Test", "Deploy"], "check_runs": [
    {"name": "Test", "status": "completed", "conclusion": "success"}]})
put("pending.json", {"required": ["Test"], "check_runs": [
    {"name": "Test", "status": "in_progress", "conclusion": None}]})
put("unknown_required.json", {"protection": "unreadable", "check_runs": [
    {"name": "Test", "status": "completed", "conclusion": "skipped"}]})
# Found live on dotfiles#173: an UNPROTECTED base branch has no required checks at all, so a
# skipped OPTIONAL bot check must not read as a gate failure - but it must not read as a pass
# either. These two differ only in `protection`, which is the whole point.
put("unprotected.json", {"protection": "absent", "check_runs": [
    {"name": "[code]smith", "status": "completed", "conclusion": "skipped"}]})
put("unreadable_same.json", {"protection": "unreadable", "check_runs": [
    {"name": "[code]smith", "status": "completed", "conclusion": "skipped"}]})
# A ruleset-derived required set binds exactly as hard as a classic one; only the reported
# source differs. dotfiles#193: main was ruleset-protected and the gate called it UNPROTECTED.
put("ruleset_ok.json", {"protection": "ruleset", "required": ["Harness suites"],
    "check_runs": [{"name": "Harness suites", "status": "completed", "conclusion": "success"}]})
put("ruleset_missing.json", {"protection": "ruleset", "required": ["Harness suites"],
    "check_runs": [{"name": "[code]smith", "status": "completed", "conclusion": "skipped"}]})
# dotfiles#1598: a draft head runs no suites. All required checks green still fails, on the draft.
put("draft_green.json", {"draft": True, "required": ["Harness suites"],
    "check_runs": [{"name": "Harness suites", "status": "completed", "conclusion": "success"}]})
# Marking ready leaves the draft run's failed aggregate beside the ready run's checks.
put("ready_after_draft.json", {"required": ["Harness suites"], "check_runs": [
    {"name": "Harness suites (draft)", "status": "completed", "conclusion": "failure"},
    {"name": "Harness suites", "status": "completed", "conclusion": "success"}]})
put("draft_name_only.json", {"required": ["Harness suites"], "check_runs": [
    {"name": "Harness suites (draft)", "status": "completed", "conclusion": "failure"}]})
put("legacy_status.json", {"required": ["ci/legacy"], "check_runs": [],
    "statuses": [{"context": "ci/legacy", "state": "success"}]})
# An arm whose metric is present but null - the acme-evals throughput-probe shape.
put("nullmetric.json", {"summary": {"median_approx_tok_s": None}})
put("goodmetric_a.json", {"summary": {"median_approx_tok_s": 100.0}})
put("goodmetric_b.json", {"summary": {"median_approx_tok_s": 125.0}})
PY

echo "== gate-check.sh =="
"$GATE_CHECK" --fixture "$WORK/skipped.json" >/dev/null 2>&1
check "PLANTED: skipped required check must not pass" 1 $?
"$GATE_CHECK" --fixture "$WORK/success.json" >/dev/null 2>&1
check "control: same set, all success, must pass" 0 $?
"$GATE_CHECK" --fixture "$WORK/empty.json" >/dev/null 2>&1
check "PLANTED: empty check set is not vacuously green" 1 $?
"$GATE_CHECK" --fixture "$WORK/missing.json" >/dev/null 2>&1
check "PLANTED: required-but-never-reported must fail" 1 $?
"$GATE_CHECK" --fixture "$WORK/pending.json" >/dev/null 2>&1
check "PLANTED: still-running check must not read success" 1 $?
"$GATE_CHECK" --fixture "$WORK/unknown_required.json" >/dev/null 2>&1
check "PLANTED: unknown required set widens, does not pass" 1 $?
"$GATE_CHECK" --fixture "$WORK/legacy_status.json" >/dev/null 2>&1
check "control: legacy commit status satisfies required" 0 $?
"$GATE_CHECK" --fixture "$WORK/unprotected.json" >/dev/null 2>&1
check "unprotected branch is UNPROTECTED(3), not FAIL(1)" 3 $?
"$GATE_CHECK" --fixture "$WORK/unreadable_same.json" >/dev/null 2>&1
check "PLANTED: same checks, unreadable protection, must FAIL" 1 $?
"$GATE_CHECK" --fixture "$WORK/ruleset_ok.json" >/dev/null 2>&1
check "ruleset-required check present and green passes" 0 $?
"$GATE_CHECK" --fixture "$WORK/ruleset_missing.json" >/dev/null 2>&1
check "PLANTED: ruleset-required check never reported must FAIL, not pass" 1 $?
OUT_RS=$("$GATE_CHECK" --fixture "$WORK/ruleset_ok.json" 2>&1)
grep -qi "from repository ruleset" <<<"$OUT_RS"
check "ruleset scope names its real source, not 'branch protection'" 0 $?
"$GATE_CHECK" --fixture "$WORK/nonexistent.json" >/dev/null 2>&1
check "unreadable fixture is a usage error, not a pass" 2 $?

echo "== ab-pair.sh =="
# The gate must not weaken to nothing at small n. Caught on review of PR #173: with one
# sample per arm, stdev defaulted to 0.0, printed "cv=0.00%", passed any gate, and turned a
# single unpaired measurement into a 5.87x verdict. A vacuous gate is worse than none - it
# is trusted.
"$AB_PAIR" -n 1 -g 5 -- sleep 0.05 ::: sleep 0.30 >/dev/null 2>&1
check "PLANTED: n=1 must be refused, not cv=0.00% verdict" 2 $?
"$AB_PAIR" -n 2 -g 5 -- sleep 0.05 ::: sleep 0.30 >/dev/null 2>&1
check "PLANTED: n=2 dispersion is degenerate, must refuse" 2 $?
"$AB_PAIR" -n 0 -g 5 -- true ::: true >/dev/null 2>&1
check "PLANTED: n=0 must be refused" 2 $?
"$AB_PAIR" -n abc -g 5 -- true ::: true >/dev/null 2>&1
check "non-integer -n is a usage error, not an n=0 run" 2 $?
"$AB_PAIR" -n 3 -g 5 -- true ::: false >/dev/null 2>&1
check "PLANTED: failing arm is VOID, never a timing row" 4 $?
# The wall-clock path must reach a verdict AND must really be measuring wall time, and neither
# assertion may rest on host noise. Verdict: for n samples that are all > 0, sample cv% is
# bounded above by sqrt(n)*100 (approached only as n-1 of them go to 0), so at n=3 it caps at
# 173.2% and -g 200 cannot refuse however noisy the host. The old gate of 25 on sleep 0.3 only
# made a flip unlikely; dotfiles#923 is what unlikely looks like. Measurement: sleep never
# returns early and perf_counter is monotonic, so each arm's median is at least its sleep
# length on any host; a sample() that stopped measuring (a constant, CPU time, zero) fails
# that floor, which is the regression the old wall-clock flapper case used to be the only
# guard against.
OUT_WALL=$("$AB_PAIR" -n 3 -g 200 -- sleep 0.05 ::: sleep 0.2 2>&1)
check "control: wall-clock arms reach a verdict on any host" 0 $?
printf '%s\n' "$OUT_WALL" | python3 -c '
import re, sys
t = sys.stdin.read()
a = float(re.search(r"^A: median=(\S+)", t, re.M).group(1))
b = float(re.search(r"^B: median=(\S+)", t, re.M).group(1))
sys.exit(0 if a >= 0.05 and b >= 0.2 else 1)'
check "control: wall medians sit at or above their sleep floors" 0 $?

# Refusal cases must not rest on host noise either. `true ::: true` at -g 5 used to sit here,
# assuming spawn jitter always pushes cv% over 5%. It does not: a quiet CI runner produced a
# verdict (dotfiles#923), and on the operator's box single arms measured 1.8% cv. An arm whose
# every sample is scripted puts the dispersion under the test's control: the k-th call prints
# {"m": <k-th value>}, and running past the list is a loud VOID, never a repeat.
SCRIPTED="$WORK/scripted.sh"
WORK="$WORK" python3 - <<'PY'
import os, pathlib, stat
p = pathlib.Path(os.environ["WORK"]) / "scripted.sh"
p.write_text(r"""#!/usr/bin/env bash
f="$1"; shift
n=$(cat "$f" 2>/dev/null || echo 0); echo $((n+1)) > "$f"
[ "$n" -lt $# ] || { echo "scripted.sh: no value for call $((n+1))" >&2; exit 9; }
printf '{"m": %s}\n' "${@:$((n+1)):1}"
""")
p.chmod(p.stat().st_mode | stat.S_IEXEC)
PY
# Control: real, nonzero dispersion inside the gate (cv 2.3% and 2.4%) and a real median gap.
"$AB_PAIR" -n 3 -g 5 --metric m -- "$SCRIPTED" "$WORK/sa" 100 100 104 \
  ::: "$SCRIPTED" "$WORK/sb" 120 120 125 >/dev/null 2>&1
check "control: scripted arms under the gate reach a verdict" 0 $?
# PLANTED: both arms draw only from the values 100 and 200, in opposite phase. Within-arm cv
# is 43% (A) and 35% (B), and the 2x median gap is an artefact of which sample landed where:
# with the gate disabled ab-pair prints "verdict: A wins" on this input, which is exactly
# "ranking noise". With the gate, both arms are over 5% and it refuses.
"$AB_PAIR" -n 3 -g 5 --metric m -- "$SCRIPTED" "$WORK/pa" 100 200 100 \
  ::: "$SCRIPTED" "$WORK/pb" 200 100 200 >/dev/null 2>&1
check "PLANTED: noise-only arm difference refuses, never ranks" 3 $?
# PLANTED: arms that measure as exactly zero are the deterministic form of "unmeasurably
# fast". With mean 0 the dispersion is 0/0; ab-pair's cv line resolves that to inf rather than
# 0.00%, so the gate refuses instead of calling an exact tie. Wall-clock never yields an exact
# 0, so --metric is the only way to reach that branch. Assert the printed cv too: a regression
# to cv=0.00% would still exit 3 via the later "median is zero" guard and hide behind the code.
OUT_ZERO=$("$AB_PAIR" -n 3 -g 5 --metric m -- "$SCRIPTED" "$WORK/za" 0 0 0 \
  ::: "$SCRIPTED" "$WORK/zb" 0 0 0 2>&1)
check "PLANTED: zero-measuring arms refuse; cv undefined, not 0%" 3 $?
grep -q "cv=inf%" <<<"$OUT_ZERO"
check "PLANTED: zero-mean dispersion reads inf, not 0.00%" 0 $?

# PLANTED: noise above the gate must refuse even with a large median gap. B's samples flap
# 400/10, so its cv% is ~110% while its median sits 4x from A's; a large effect never licenses
# a noisy measurement. Scripted since dotfiles#923: it was a wall-clock sleep 0.4/0.01 flapper
# whose exit code, however safe its margin, still came from measured durations.
"$AB_PAIR" -n 4 -g 5 --metric m -- "$SCRIPTED" "$WORK/ga" 50 50 50 50 \
  ::: "$SCRIPTED" "$WORK/gb" 400 10 400 10 >/dev/null 2>&1
check "PLANTED: cv% over gate refuses despite median gap" 3 $?

"$AB_PAIR" -n 3 -g 500 --metric summary.median_approx_tok_s --higher-better \
  -- cat "$WORK/goodmetric_a.json" ::: cat "$WORK/goodmetric_b.json" >/dev/null 2>&1
check "control: --metric reads a numeric field from JSON" 0 $?

# PLANTED: --higher-better must change WHICH ARM WINS. Asserting only on the exit code cannot
# see that: exit is 0 whichever arm is declared the winner, so inverting the comparison would
# fail nothing. A=100 tok/s, B=125 tok/s -> B wins when higher is better, A wins when it is not.
VERDICT_HI=$("$AB_PAIR" -n 3 -g 500 --metric summary.median_approx_tok_s --higher-better \
  -- cat "$WORK/goodmetric_a.json" ::: cat "$WORK/goodmetric_b.json" 2>&1)
grep -q "verdict: B wins" <<<"$VERDICT_HI"
check "PLANTED: --higher-better picks the LARGER arm (B)" 0 $?
VERDICT_LO=$("$AB_PAIR" -n 3 -g 500 --metric summary.median_approx_tok_s \
  -- cat "$WORK/goodmetric_a.json" ::: cat "$WORK/goodmetric_b.json" 2>&1)
grep -q "verdict: A wins" <<<"$VERDICT_LO"
check "PLANTED: without the flag the SMALLER arm (A) wins" 0 $?

# PLANTED: a --metric path descending past a scalar leaf raises TypeError. Uncaught, that
# exits 1 -- a code this script does not define -- instead of the documented VOID exit 4.
"$AB_PAIR" -n 3 -g 500 --metric summary.median_approx_tok_s.oops \
  -- cat "$WORK/goodmetric_a.json" ::: cat "$WORK/goodmetric_a.json" >/dev/null 2>&1
check "PLANTED: metric path past a scalar is VOID(4), not a crash" 4 $?

"$GATE_CHECK" --fixture "$WORK/draft_green.json" >"$WORK/draft.out" 2>&1; check "fixture: draft with all-green checks fails (1)" 1 $?
grep -q "is a draft" "$WORK/draft.out" && ! grep -q "gate-check scope" "$WORK/draft.out"
check "fixture: draft fails before any check evaluation" 0 $?
"$GATE_CHECK" --fixture "$WORK/ready_after_draft.json" >/dev/null 2>&1
check "ready head beside the draft run's failed aggregate passes" 0 $?
"$GATE_CHECK" --fixture "$WORK/draft_name_only.json" >/dev/null 2>&1
check "PLANTED: only the draft-named failure leaves the required check missing" 1 $?
# PLANTED: a flag given with no value is a USAGE error (2), never 1 -- gate-check.sh reserves
# 1 for 'a required check is not success', so exit 1 here would be indistinguishable from a
# real gate failure for any caller branching on the code.
"$AB_PAIR" -n >/dev/null 2>&1;        check "PLANTED: bare -n is a usage error (2), not 1" 2 $?
"$AB_PAIR" -g >/dev/null 2>&1;        check "PLANTED: bare -g is a usage error (2), not 1" 2 $?
"$AB_PAIR" --metric >/dev/null 2>&1;  check "PLANTED: bare --metric is a usage error (2), not 1" 2 $?
"$GATE_CHECK" --fixture >/dev/null 2>&1
check "PLANTED: bare --fixture is a usage error (2), not 1" 2 $?
"$AB_PAIR" --help >/dev/null 2>&1;    check "--help prints usage and exits 0" 0 $?
"$GATE_CHECK" --help >/dev/null 2>&1; check "gate-check --help prints usage and exits 0" 0 $?
"$AB_PAIR" -n 3 -g 500 --metric summary.median_approx_tok_s \
  -- cat "$WORK/goodmetric_a.json" ::: cat "$WORK/nullmetric.json" >/dev/null 2>&1
check "PLANTED: null metric is VOID, not a measurement" 4 $?
"$AB_PAIR" -n 3 -g 500 --metric summary.nope \
  -- cat "$WORK/goodmetric_a.json" ::: cat "$WORK/goodmetric_a.json" >/dev/null 2>&1
check "PLANTED: absent metric path is VOID, not zero" 4 $?
"$AB_PAIR" -n 3 -g 5 -- true >/dev/null 2>&1
check "missing ::: separator is a usage error" 2 $?

echo "== gate-check.sh (live gh path, PATH-stubbed) =="
# Every case above drives gate-check.sh through --fixture, which supplies `protection` as a
# literal field and therefore never runs the shell classifier that derives it from gh's error
# text. That classifier decides whether the gate applies at all, so leaving it unexercised
# means the suite cannot see a whole class of defect. These cases stub `gh` on PATH and
# emulate its real semantics (including the documented --paginate/--jq/--slurp behaviour).
WORK="$WORK" python3 - <<'PY'
import os, pathlib, stat
w = pathlib.Path(os.environ["WORK"])
(w / "bin").mkdir(exist_ok=True)
gh = w / "bin" / "gh"
gh.write_text(r'''#!/usr/bin/env bash
# Minimal gh emulator. Scenario selected by GH_STUB_SCENARIO.
ARGS="$*"
S="${GH_STUB_SCENARIO:-}"

if [[ "$ARGS" == *"--json headRefOid"* ]]; then
  echo "cafebabecafebabecafebabecafebabecafebabe"; exit 0
fi

if [[ "$ARGS" == *"--json isDraft"* ]]; then
  case "$S" in
    draft)         echo "true"; exit 0 ;;
    draftunread)   exit 1 ;;
    draftgarbage)  echo "null"; exit 0 ;;
    *)             echo "false"; exit 0 ;;
  esac
fi

if [[ "$ARGS" == *"--json baseRefName"* ]]; then
  case "$S" in
    nobase) exit 1 ;;              # base-branch resolution fails, prints nothing
    *)      echo "main"; exit 0 ;;
  esac
fi

if [[ "$ARGS" == *"rules/branches"* ]]; then
  # Rulesets endpoint. Only reached when classic protection said "Branch not protected".
  case "$S" in
    ruleset_protected) echo '["Test"]'; exit 0 ;;
    ruleset_unreadable) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
    *) echo '[]'; exit 0 ;;      # no ruleset requires a check -> genuinely unprotected
  esac
fi

if [[ "$ARGS" == *"protection/required_status_checks"* ]]; then
  case "$S" in
    unprotected|nobase|ruleset_protected|ruleset_unreadable)
      echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
    renamed404)
      echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
    forbidden)
      echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
    *)
      echo '["Test"]'; exit 0 ;;
  esac
fi

if [[ "$ARGS" == *"actions/runs"* ]]; then
  # The head's workflow runs: suite 100 is workflow 7's older run, suite 200 the newer one.
  case "$S" in
    superseded_green|superseded_red)
      echo '[{"workflow_runs":[{"id":2,"workflow_id":7,"event":"pull_request","check_suite_id":200,"status":"completed","created_at":"2026-10-05T13:54:24Z"},{"id":1,"workflow_id":7,"event":"pull_request","check_suite_id":100,"status":"completed","created_at":"2026-10-05T03:33:59Z"}]}]' ;;
    *) echo '[{"total_count":0,"workflow_runs":[]}]' ;;
  esac
  exit 0
fi

if [[ "$ARGS" == *"check-runs"* ]]; then
  case "$S" in
    apifail) echo 'gh: API rate limit exceeded (HTTP 403)' >&2; exit 1 ;;
    superseded_green)
      # Newest first, as the API orders them: a re-trigger cancelled the older suite.
      echo '[{"check_runs":[{"name":"Test","status":"completed","conclusion":"success","check_suite":{"id":200}},{"name":"Test","status":"completed","conclusion":"cancelled","check_suite":{"id":100}}]}]'
      exit 0 ;;
    superseded_red)
      echo '[{"check_runs":[{"name":"Test","status":"completed","conclusion":"failure","check_suite":{"id":200}},{"name":"Test","status":"completed","conclusion":"success","check_suite":{"id":100}}]}]'
      exit 0 ;;
    multipage)
      # Real gh: --paginate with --jq applies the filter PER PAGE and concatenates the
      # resulting documents; --paginate with --slurp returns ONE array of page objects.
      if [[ "$ARGS" == *"--slurp"* ]]; then
        echo '[{"check_runs":[{"name":"Test","status":"completed","conclusion":"success"}]},{"check_runs":[{"name":"Other","status":"completed","conclusion":"success"}]}]'
      elif [[ "$ARGS" == *"--jq"* ]]; then
        echo '[{"name":"Test","status":"completed","conclusion":"success"}]'
        echo '[{"name":"Other","status":"completed","conclusion":"success"}]'
      else
        echo '{"check_runs":[{"name":"Test","status":"completed","conclusion":"success"}]}'
      fi
      exit 0 ;;
    protected_success)
      if [[ "$ARGS" == *"--slurp"* ]]; then
        echo '[{"check_runs":[{"name":"Test","status":"completed","conclusion":"success"}]}]'
      else
        echo '[{"name":"Test","status":"completed","conclusion":"success"}]'
      fi
      exit 0 ;;
    *)
      if [[ "$ARGS" == *"--slurp"* ]]; then
        echo '[{"check_runs":[{"name":"Test","status":"completed","conclusion":"skipped"}]}]'
      else
        echo '[{"name":"Test","status":"completed","conclusion":"skipped"}]'
      fi
      exit 0 ;;
  esac
fi

if [[ "$ARGS" == *"/status"* ]]; then
  if [[ "$ARGS" == *"--slurp"* ]]; then echo '[{"statuses":[]}]'; else echo '[]'; fi
  exit 0
fi
exit 0
''')
gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
PY

live() { # live <scenario> ; runs gate-check.sh with the stub on PATH
  GH_STUB_SCENARIO="$1" PATH="$WORK/bin:$PATH" "$GATE_CHECK" acme/repo 1 2>&1
}

live protected_success >/dev/null 2>&1; check "live: protected + all success passes" 0 $?
live protected_skipped >/dev/null 2>&1; check "live: protected + skipped required fails" 1 $?
live unprotected >/dev/null 2>&1;       check "live: unprotected branch is UNPROTECTED(3)" 3 $?
live forbidden >/dev/null 2>&1;         check "live: 403 widens and fails on a skipped check" 1 $?
# dotfiles#1595: GitHub keeps every suite a head has had. A suite a newer run of its
# workflow superseded must not decide the verdict either way.
live superseded_green >/dev/null 2>&1;  check "live: a cancelled suite a newer green run superseded passes" 0 $?
# PLANTED: newest-first order plus name-keyed last-wins kept the OLDER suite's success.
live superseded_red >/dev/null 2>&1;    check "live: the newest run's failure fails over an older success" 1 $?

# dotfiles#1598: draft state is read before any check; unreadable is UNAVAILABLE, never not-draft.
OUT_DRAFT=$(live draft); DRAFT_RC=$?
check "live: a draft PR fails (1)" 1 "$DRAFT_RC"
grep -q "is a draft" <<<"$OUT_DRAFT" && grep -q "dotfiles#1598" <<<"$OUT_DRAFT"
check "live: draft FAIL names the draft and dotfiles#1598" 0 $?
live draftunread >/dev/null 2>&1; check "live: unreadable draft state is UNAVAILABLE (3)" 3 $?
live draftgarbage >/dev/null 2>&1; check "live: null draft state is UNAVAILABLE (3)" 3 $?

# PLANTED (#3): base-branch resolution fails. Exit 3 alone cannot distinguish this from a
# genuinely unprotected branch -- both are 3 -- so assert the MESSAGE, exactly the lesson the
# --higher-better case teaches below.
# Capture first, then grep: under `set -o pipefail` a pipeline reports gate-check's exit 3
# rather than grep's 0, so piping directly would assert the wrong thing.
OUT_NOBASE=$(live nobase); grep -qi "UNAVAILABLE" <<<"$OUT_NOBASE"
check "PLANTED: unresolved base says UNAVAILABLE, not UNPROTECTED" 0 $?
grep -qi "UNPROTECTED" <<<"$OUT_NOBASE"
check "PLANTED: unresolved base must NOT claim UNPROTECTED" 1 $?

# PLANTED (#4): the check-runs API call fails. A failed query must not read as 'zero checks'.
OUT_APIFAIL=$(live apifail); grep -qi "UNAVAILABLE" <<<"$OUT_APIFAIL"
check "PLANTED: failed check-runs query is UNAVAILABLE, not empty" 0 $?

# PLANTED (#5): multi-page check-runs. The required check IS present on page 1; a pagination
# bug that drops it would report MISSING.
live multipage >/dev/null 2>&1; check "PLANTED: multi-page check-runs still finds the check" 0 $?

# PLANTED (#10): a 404 that is NOT 'branch not protected' (renamed branch, invisible repo).
# Misreading it as 'absent' WAIVES the gate; it must widen instead and fail the skipped check.
live renamed404 >/dev/null 2>&1; check "PLANTED: non-protection 404 widens, does not waive" 1 $?

# PLANTED (#11): the defect this file exists to prevent recurring. A RULESET-protected branch
# 404s "Branch not protected" on the classic endpoint exactly like an unprotected one. Trusting
# that 404 alone made gate-check report "nothing gates this merge" for dotfiles main while a
# ruleset required `Harness suites` (observed on dotfiles#193, 2026-08-06). Exit code alone
# cannot separate this from the genuine case, so assert the MESSAGE too.
OUT_RSLIVE=$(live ruleset_protected)
grep -qi "UNPROTECTED" <<<"$OUT_RSLIVE"
check "PLANTED: ruleset-protected branch must NOT be called UNPROTECTED" 1 $?
live ruleset_protected >/dev/null 2>&1
check "PLANTED: ruleset-required check skipped must FAIL(1), not UNPROTECTED(3)" 1 $?

# PLANTED (#12): classic says unprotected, the rules endpoint is unreadable. The union of the
# two is UNKNOWN, never empty - concluding 'absent' here waives the gate in the permissive
# direction the classifier's own comment forbids.
OUT_RSUNREAD=$(live ruleset_unreadable)
grep -qi "UNPROTECTED" <<<"$OUT_RSUNREAD"
check "PLANTED: unreadable rules endpoint must NOT claim UNPROTECTED" 1 $?
live ruleset_unreadable >/dev/null 2>&1
check "PLANTED: unreadable rules widens and fails the skipped check" 1 $?

echo "== work-spec-check.sh =="
# The two new work-spec fields are marked `required:` in the issue form, but GitHub enforces
# that ONLY in the web New Issue UI -- never on `gh issue create --body-file`, which is the
# path wt-new.sh takes. This guard is what makes `required:` true on the path agents use.
WORK="$WORK" WT_NEW="$WT_NEW" python3 - <<'PY'
import os, pathlib, re
w = pathlib.Path(os.environ["WORK"])

FULL = """## Context & Motivation

Because.

## Acceptance Criteria (testable assertions)

- [ ] it works

## Planted negative (what a wrong implementation would fail)

- a near-identical case differing only in the forbidden dimension

## No-Claim Boundary (what green here will NOT prove)

Does not prove anything about production.
"""
(w / "ws_full.md").write_text(FULL)
# Each of the next three differs from ws_full.md in exactly ONE dimension.
(w / "ws_no_planted.md").write_text(
    FULL.replace("""## Planted negative (what a wrong implementation would fail)

- a near-identical case differing only in the forbidden dimension

""", ""))
(w / "ws_no_boundary.md").write_text(
    FULL.replace("""## No-Claim Boundary (what green here will NOT prove)

Does not prove anything about production.
""", ""))
# Heading present, nothing under it: an empty section is the same unstated requirement as a
# missing one, and a naive "does the heading exist" check would wave it through.
(w / "ws_empty_section.md").write_text(
    FULL.replace("- a near-identical case differing only in the forbidden dimension\n", ""))

# Extract wt-new.sh's OWN fallback skeleton rather than a copy of it. If that heredoc ever
# drifts from the required set, this test fails -- which is why no yml->markdown generator is
# needed to keep the two in step.
src = pathlib.Path(os.environ["WT_NEW"]).read_text()
m = re.search(r"cat >\"\$BODY_FILE\" <<'EOF'\n(.*?)\nEOF\n", src, re.S)
(w / "ws_fallback.md").write_text(m.group(1) if m else "EXTRACTION-FAILED")
PY

"$WS_CHECK" "$WORK/ws_full.md" >/dev/null 2>&1
check "control: a complete work-spec body passes" 0 $?
"$WS_CHECK" "$WORK/ws_no_planted.md" >/dev/null 2>&1
check "PLANTED: body without a Planted negative is refused" 1 $?
"$WS_CHECK" "$WORK/ws_no_boundary.md" >/dev/null 2>&1
check "PLANTED: body without a No-Claim Boundary is refused" 1 $?
"$WS_CHECK" "$WORK/ws_empty_section.md" >/dev/null 2>&1
check "PLANTED: heading with no content is refused, not waved through" 1 $?
"$WS_CHECK" "$WORK/ws_fallback.md" >/dev/null 2>&1
check "wt-new.sh's own fallback skeleton satisfies the guard" 0 $?
"$WS_CHECK" "$WORK/nonexistent.md" >/dev/null 2>&1
check "unreadable body is a usage error (2), not a pass" 2 $?
"$WS_CHECK" >/dev/null 2>&1
check "no argument is a usage error (2)" 2 $?
"$WS_CHECK" --help >/dev/null 2>&1
check "--help prints usage and exits 0" 0 $?

echo
echo "evidence-regime: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
