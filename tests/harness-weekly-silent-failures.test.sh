#!/usr/bin/env bash
# Hermetic regression contract for two silent-failure fixes in
# scripts/harness-weekly.sh (#1394).
#
# 1. CRASHES. The "docker hygiene", "agent write amplification" and "reclaim
#    sweep" sections used to end in `|| true`. A sub-check that crashed or was
#    killed (earlyoom's SIGTERM, say) printed a clean-looking section and
#    raised nothing. The weekly toast counts column-0 `^WARN` lines, so the
#    contract under test is:
#    - docker-hygiene exits 0 even with findings unless STRICT=1, which the
#      weekly never sets. Any non-zero exit is a crash and adds one WARN.
#    - agent-write-guard exits 1 WITH [CRIT]/[WARN] lines by design. That is a
#      finding, not a crash, and adds no WARN. Any other non-zero exit is a
#      crash and adds one WARN: a traceback (exit 1, no finding line), a kill
#      (143), or an argparse or missing-file error (2).
#    - reclaim-sweep in plan mode exits non-zero only when it refuses or
#      crashes, so any non-zero exit adds one WARN.
# 2. THROTTLING. A MemoryHigh cap on whatever unit runs this script throttles
#    and never kills, and nothing watches that unit. The "weekly run memory"
#    section reads the run's own cgroup and WARNs when the run stalled 60s or
#    more on memory (memory.pressure "some" total) with the bound engaged
#    (memory.events high > 0). Peak and high events alone must NOT warn: cache
#    trimming at the bound reaches both at no cost (measured at MemoryHigh=64M:
#    a 1 GiB cache read peaked at the bound with 2107 high events and 37025us
#    of stall). A run with no bound (memory.high=max, an interactive shell) or
#    with unreadable counters must say so and never WARN.
#
# EXTRACTION APPROACH: the same as harness-weekly-stash.test.sh. The sections
# are sed-extracted from the REAL shipped script and run with SCRIPTS pointing
# at stubs, and with the cgroup seams (HW_TEST_PROC_CGROUP,
# HW_TEST_CGROUP_ROOT) pointing at fixture files. So each case controls the
# exit codes, output and counters. Sanity checks fail loudly if an extraction
# comes back empty or loses what it is meant to test.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/scripts/harness-weekly.sh
TMP=$(mktemp -d /tmp/hw-silent-test.XXXXXX)
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
warn_lines() { # $1 = output; prints how many lines the weekly's ^WARN counter would count
  printf '%s\n' "$1" | grep -c '^WARN'
}
extract() { # $1 = output file, $2 = start pattern, $3 = end pattern (end line dropped)
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    sed -n "/$2/,/$3/p" "$SRC" | sed '$d'
  } > "$1"
  if [ -s "$1" ] && [ "$(wc -l < "$1")" -gt 2 ]; then ok; else
    echo "FAIL: sed extraction of '$2' produced an empty block -- a section header in harness-weekly.sh may have changed" >&2
    exit 1
  fi
  bash -n "$1" || { echo "FAIL: extracted $1 has a syntax error" >&2; exit 1; }
}
require_in() { # $1 = file, $2... = literal needles the extracted block must carry
  local f=$1 needle
  shift
  for needle in "$@"; do
    if grep -qF -- "$needle" "$f"; then ok; else
      bad "extraction sanity: '$needle' missing from $(basename "$f") -- extraction is testing stale or wrong code"
    fi
  done
}

# ============================================================================
# Part 1: crash surfacing
# ============================================================================
extract "$TMP/crash.sh" '## docker hygiene plan' '## spend visibility'
require_in "$TMP/crash.sh" 'docker-hygiene.sh' 'agent-write-guard.py' 'reclaim-sweep.py' 'agent-write-flagged:'

# Each Python stub prints $STUB_<P>_OUT, then behaves per $STUB_<P>_MODE: a
# number is its exit code, "raise" is an uncaught exception, and "term" is
# death by SIGTERM. The docker stub is a shell script, because the weekly
# executes it directly.
mkdir -p "$TMP/scripts" "$TMP/empty"
write_stub() { # $1 = file name, $2 = env prefix
  printf 'PREFIX = "%s"\n' "$2" > "$TMP/scripts/$1"
  cat >> "$TMP/scripts/$1" <<'PY'
import os, signal, sys
sys.stdout.write(os.environ.get(f"STUB_{PREFIX}_OUT", ""))
sys.stdout.flush()
mode = os.environ.get(f"STUB_{PREFIX}_MODE", "0")
if mode == "raise":
    raise RuntimeError("stub crash")
if mode == "term":
    os.kill(os.getpid(), signal.SIGTERM)
sys.exit(int(mode))
PY
}
write_stub agent-write-guard.py AWG
write_stub reclaim-sweep.py RECLAIM
cat > "$TMP/scripts/docker-hygiene.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_DOCKER_OUT:-docker-flagged:0}"
case "${STUB_DOCKER_MODE:-0}" in
  term) kill -TERM $$ ;;
  *) exit "${STUB_DOCKER_MODE:-0}" ;;
esac
SH
chmod +x "$TMP/scripts/docker-hygiene.sh"

AWG_CLEAN='agent-write-guard: clean — no SSD-hostile agent write patterns detected'
AWG_FINDING='[WARN] churn: path=/x ratio=40'
RECLAIM_CLEAN=$'reclaim-sweep [PLAN (nothing removed — pass --apply)]\n  nothing to reclaim\nreclaim-flagged:0'
RECLAIM_REFUSE='reclaim-sweep: liveness scan saw no processes — refusing to plan or apply'

# run_crash AWG_MODE AWG_OUT RECLAIM_MODE RECLAIM_OUT [DOCKER_MODE] [SCRIPTS_DIR]
run_crash() {
  SCRIPTS="${6:-$TMP/scripts}" STUB_DOCKER_MODE="${5:-0}" \
    STUB_AWG_MODE="$1" STUB_AWG_OUT="$2" STUB_RECLAIM_MODE="$3" STUB_RECLAIM_OUT="$4" \
    bash "$TMP/crash.sh" 2>&1
}

# -- case a: everything clean -------------------------------------------------
out=$(run_crash 0 "$AWG_CLEAN" 0 "$RECLAIM_CLEAN")
contains "$out" "agent-write-flagged:0" "a1: clean guard flags zero"
contains "$out" "docker-flagged:0" "a2: docker counter passes through"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "a3: clean run added a ^WARN line"$'\n'"$out"

# -- case b: guard findings (exit 1 WITH a finding line) are not a crash -----
out=$(run_crash 1 "$AWG_FINDING" 0 "$RECLAIM_CLEAN")
contains "$out" "agent-write-flagged:1" "b1: finding counted"
omits    "$out" "agent-write-guard crashed" "b2: findings exit is not a crash"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "b3: findings exit added a ^WARN line"$'\n'"$out"

# -- case c: guard traceback (exit 1, no finding line) is a crash ------------
out=$(run_crash raise "" 0 "$RECLAIM_CLEAN")
contains "$out" "WARN agent-write-guard crashed (exit 1" "c1: traceback surfaces as WARN"
contains "$out" "RuntimeError: stub crash" "c2: traceback stays in the report"
contains "$out" "agent-write-flagged:0" "c3: counter still prints after a crash"
[ "$(warn_lines "$out")" -eq 1 ] && ok || bad "c4: want exactly one ^WARN line"$'\n'"$out"

# -- case d: guard killed by SIGTERM ------------------------------------------
out=$(run_crash term "" 0 "$RECLAIM_CLEAN")
contains "$out" "WARN agent-write-guard crashed (exit 143" "d1: SIGTERM surfaces as WARN with exit 143"
[ "$(warn_lines "$out")" -eq 1 ] && ok || bad "d2: want exactly one ^WARN line"$'\n'"$out"

# -- case e: guard exit 2 (argparse error) ----------------------------------
out=$(run_crash 2 "" 0 "$RECLAIM_CLEAN")
contains "$out" "WARN agent-write-guard crashed (exit 2" "e1: exit 2 surfaces as WARN"

# -- case f: reclaim refuses (liveness scan failed closed) -------------------
out=$(run_crash 0 "$AWG_CLEAN" 1 "$RECLAIM_REFUSE")
contains "$out" "WARN reclaim sweep crashed or refused to plan (exit 1" "f1: refusal surfaces as WARN"
contains "$out" "refusing to plan or apply" "f2: refusal reason stays in the report"
[ "$(warn_lines "$out")" -eq 1 ] && ok || bad "f3: want exactly one ^WARN line"$'\n'"$out"

# -- case g: reclaim killed by SIGTERM --------------------------------------
out=$(run_crash 0 "$AWG_CLEAN" term "")
contains "$out" "WARN reclaim sweep crashed or refused to plan (exit 143" "g1: SIGTERM surfaces as WARN"

# -- case h: docker hygiene crashes or is killed -----------------------------
out=$(run_crash 0 "$AWG_CLEAN" 0 "$RECLAIM_CLEAN" 3)
contains "$out" "WARN docker hygiene crashed or failed (exit 3" "h1: docker crash surfaces as WARN"
[ "$(warn_lines "$out")" -eq 1 ] && ok || bad "h2: want exactly one ^WARN line"$'\n'"$out"
out=$(run_crash 0 "$AWG_CLEAN" 0 "$RECLAIM_CLEAN" term)
contains "$out" "WARN docker hygiene crashed or failed (exit 143" "h3: docker SIGTERM surfaces as WARN"

# -- case i: every script missing -------------------------------------------
out=$(run_crash 0 "" 0 "" 0 "$TMP/empty")
contains "$out" "WARN docker hygiene crashed or failed (exit 127" "i1: missing docker-hygiene surfaces as WARN"
contains "$out" "WARN agent-write-guard crashed (exit 2" "i2: missing guard surfaces as WARN"
contains "$out" "WARN reclaim sweep crashed or refused to plan (exit 2" "i3: missing sweep surfaces as WARN"
[ "$(warn_lines "$out")" -eq 3 ] && ok || bad "i4: want exactly three ^WARN lines"$'\n'"$out"

# ============================================================================
# Part 2: weekly run memory against the unit's own MemoryHigh
# ============================================================================
extract "$TMP/mem.sh" '## weekly run memory' '^} >>"\$REPORT" 2>&1'
require_in "$TMP/mem.sh" 'HW_TEST_PROC_CGROUP' 'HW_TEST_CGROUP_ROOT' 'memory.peak' 'memory.high' 'memory.pressure'

CG=/user.slice/user-1001.slice/user@1001.service/app.slice/run-u1234.service
G=1073741824
S=1000000 # memory.pressure totals are microseconds
# fixture HIGH PEAK HIGH_EVENTS STALL_US: writes one cgroup's counters under
# $TMP/cg. memory.pressure uses the kernel's real two-line format; "full" is
# written different from "some" so a parser reading the wrong line fails.
fixture() {
  rm -rf "$TMP/cg" && mkdir -p "$TMP/cg$CG"
  printf '0::%s\n' "$CG" > "$TMP/proc-cgroup"
  printf '%s\n' "$1" > "$TMP/cg$CG/memory.high"
  printf '%s\n' "$2" > "$TMP/cg$CG/memory.peak"
  printf 'low 0\nhigh %s\nmax 0\noom 0\noom_kill 0\n' "$3" > "$TMP/cg$CG/memory.events"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=%s\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=%s\n' \
    "$4" "$(( $4 / 2 ))" > "$TMP/cg$CG/memory.pressure"
}
run_mem() {
  HW_TEST_PROC_CGROUP="$TMP/proc-cgroup" HW_TEST_CGROUP_ROOT="$TMP/cg" bash "$TMP/mem.sh" 2>&1
}

# -- case j: today's shape, a 5.7G peak under the 12G bound ------------------
fixture $((12 * G)) $((57 * G / 10)) 0 $((2 * S / 10))
out=$(run_mem)
contains "$out" "peak 5836M of MemoryHigh 12288M, high events 0, memory stall 0s" "j1: peak, bound and stall reported"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "j2: a peak well under the bound added a ^WARN"$'\n'"$out"

# -- case k: cache trimming AT the bound stays quiet ---------------------------
# The measured cache-only shape: peak at 100% of the bound, thousands of high
# events, 37025us of stall. The first version of this check (a 90%-of-peak
# WARN) fired here.
fixture $((12 * G)) $((12 * G)) 2107 37025
out=$(run_mem)
contains "$out" "peak 12288M of MemoryHigh 12288M, high events 2107, memory stall 0s" "k1: saturated cache reported"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "k2: cache trimming at the bound added a ^WARN"$'\n'"$out"

# -- case l: real throttling stall with the bound engaged WARNs ---------------
fixture $((12 * G)) $((12 * G)) 21841 $((120 * S))
out=$(run_mem)
contains "$out" "WARN weekly run stalled 120s on memory with its MemoryHigh engaged (21841 high events)" "l1: throttling stall WARNs"
[ "$(warn_lines "$out")" -eq 1 ] && ok || bad "l2: want exactly one ^WARN line"$'\n'"$out"

# -- case m: the 60s boundary, and stall without the bound engaged -----------
fixture $((12 * G)) $((12 * G)) 5 $((60 * S - 1))
out=$(run_mem)
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "m1: 59.999999s of stall added a ^WARN"$'\n'"$out"
fixture $((12 * G)) $((12 * G)) 5 $((60 * S))
out=$(run_mem)
[ "$(warn_lines "$out")" -eq 1 ] && ok || bad "m2: exactly 60s of stall with high events did not WARN"$'\n'"$out"
fixture $((12 * G)) $((4 * G)) 0 $((300 * S))
out=$(run_mem)
contains "$out" "memory stall 300s" "m3: host-pressure stall still reported"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "m4: stall with the bound never engaged added a ^WARN"$'\n'"$out"

# -- case n: no bound on this cgroup (an interactive run) --------------------
fixture max $((3 * G)) 0 $((5 * S))
out=$(run_mem)
contains "$out" "peak 3072M, memory stall 5s, no MemoryHigh on this cgroup" "n1: unbounded cgroup reported"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "n2: unbounded cgroup added a ^WARN"$'\n'"$out"

# -- case o: unreadable or malformed counters say so and never WARN ----------
fixture $((12 * G)) $((12 * G)) 9 $((120 * S))
rm -f "$TMP/cg$CG/memory.peak"
out=$(run_mem)
contains "$out" "cgroup counters unreadable" "o1: missing memory.peak reported"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "o2: unreadable counters added a ^WARN"$'\n'"$out"
fixture $((12 * G)) max 9 $((120 * S))
out=$(run_mem)
contains "$out" "cgroup counters unreadable" "o3: a non-numeric peak is not arithmetic"
fixture $((12 * G)) $((12 * G)) 9 $((120 * S))
printf 'garbage\n' > "$TMP/proc-cgroup"
out=$(run_mem)
contains "$out" "cgroup counters unreadable" "o4: an unparseable /proc/self/cgroup reported"
fixture $((12 * G)) $((12 * G)) 9 $((120 * S))
rm -f "$TMP/cg$CG/memory.pressure"
out=$(run_mem)
contains "$out" "memory.pressure unreadable, so the cost of throttling was not checked" "o5: missing PSI reported as not checked"
[ "$(warn_lines "$out")" -eq 0 ] && ok || bad "o6: missing PSI added a ^WARN"$'\n'"$out"

if [ "$fail" -eq 0 ]; then
  printf 'ok — harness-weekly-silent-failures: %s passed, %s failed\n' "$pass" "$fail"
else
  printf 'FAIL — harness-weekly-silent-failures: %s passed, %s failed\n' "$pass" "$fail" >&2
  exit 1
fi
