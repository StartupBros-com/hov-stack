#!/usr/bin/env bash
# tests/run-claude-tests.sh: run every unit suite under tests/ and report, invoking
# each with its native test runner, as the unit-suite step in ci.yml does.
#
# Discovery, relative to the repo root, sorted by path:
#   tests/*.test.sh, scripts/tests/*.test.sh   bash <file>
#   tests/*.test.py                                    python3 <file>
#   tests/test_*.py    python3 -m unittest discover -s tests -p <name> -v
#                             (top-level import; a run that
#                             collects 0 tests is a failure, since three suites
#                             carry no __main__ guard and would pass vacuously)
#   plugins/hov-stack/skills/**/*.test.mjs, scripts/tests/*.test.js
#                             node --test <name>, from the file's own directory
#
# tests/claude-tests.skips names what cannot pass from this repo, one TAB-separated
# line each: <xfail|skip> <path> <reason> [<signature>]. A skip suite is not run.
# An xfail suite still runs and must fail for the listed reason: its signature is
# an extended regex (grep -E) its log must match. The list fails closed: a path
# that is not a discovered suite, or an xfail that passes, is a stale entry and
# the run exits 2; an xfail whose log lacks its signature, or that times out, is
# killed by a signal or cannot start (exit 124 and above), or collects no test
# cases, is a plain failure. So the list can hide neither a repair, nor a
# regression, nor a new way of failing.
#
# Each suite runs under its own empty scratch HOME, umask 022 (what the runner
# image, systemd and ./setup use; a 002 host umask trips the parent-ownership
# chain docker-daemon-config.py checks), stdin from /dev/null, and a timeout
# (CLAUDE_TESTS_TIMEOUT seconds, default 600); -j N suites run at a time
# (default: nproc). Logs land under -o DIR (default: a fresh mktemp dir, kept) and
# the log of every failure is echoed at the end, so a CI log is self-contained.
# A reused -o DIR serves nothing stale: the runner removes its own earlier files
# for the suites about to run, stamps every result with this run's token, and
# counts a suite with no result from this run, or a launcher (xargs) that did
# not exit 0, as a failure. Positional arguments select suites by the path
# --list prints; a name that is not a discovered suite exits 2. Exit 0 all
# green, 1 any failure, 2 a stale skip entry or a usage error.
#
# On a machine whose PATH carries tools installed under the real HOME (mise
# shims), a suite that re-derives PATH from HOME sees the scratch HOME without
# them (docker-hygiene's unit-PATH check wants supabase there); CI has no such
# tools and that check skips itself.
#
#   bash tests/run-claude-tests.sh [-j N] [-o DIR] [--list] [suite...]
set -uo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SKIPS=$ROOT/tests/claude-tests.skips
TIMEOUT=${CLAUDE_TESTS_TIMEOUT:-600}

usage() { echo "usage: bash tests/run-claude-tests.sh [-j N] [-o DIR] [--list]"; }

# ---- one suite (child mode: bash run-claude-tests.sh --one "<kind> <path> <pass|fail>") ----
# Writes $CLAUDE_TESTS_LOGDIR/<slug>.log and .meta, prints the suite's one status line.
# An xfail suite's signature waits in $CLAUDE_TESTS_LOGDIR/<slug>.sig, written by the
# parent, so no regex has to survive the runlist line.
run_one() {
  local kind=$1 path=$2 expect=$3 logdir=$CLAUDE_TESTS_LOGDIR slug log home rc t0 secs status sig note
  slug=${path//\//__}
  log=$logdir/$slug.log
  home=$(mktemp -d "${TMPDIR:-/tmp}/claude-tests-home.XXXXXX")
  umask 022
  t0=$(date +%s)
  note=
  case $kind in
    sh)  HOME=$home timeout -k 10 "$TIMEOUT" bash "$path" </dev/null >"$log" 2>&1; rc=$? ;;
    pys) HOME=$home timeout -k 10 "$TIMEOUT" python3 "$path" </dev/null >"$log" 2>&1; rc=$? ;;
    py)  HOME=$home timeout -k 10 "$TIMEOUT" python3 -m unittest discover -s "${path%/*}" -p "${path##*/}" -v </dev/null >"$log" 2>&1; rc=$?
         # Python 3.12+ already exits 5 on "Ran 0 tests"; older ones exit 0. Name it either way.
         if grep -qE '^Ran 0 tests' "$log"; then
           echo "run-claude-tests: $path collected no test cases (unittest ran 0 tests)" >>"$log"
           [ "$rc" = 0 ] && rc=1
           note="collected no test cases"
         elif [ "$rc" = 0 ] && ! grep -qE '^Ran [1-9][0-9]* tests? in' "$log"; then
           echo "run-claude-tests: $path exited 0 without a unittest summary line" >>"$log"
           rc=1
           note="no unittest summary line"
         fi ;;
    mjs) ( cd "${path%/*}" && HOME=$home timeout -k 10 "$TIMEOUT" node --test "${path##*/}" ) </dev/null >"$log" 2>&1; rc=$? ;;
    *)   echo "run-claude-tests: unknown suite kind '$kind' for $path" >"$log"; rc=2; note="unknown suite kind" ;;
  esac
  secs=$(( $(date +%s) - t0 ))
  rm -rf -- "$home"
  if [ "$rc" = 124 ]; then
    echo "run-claude-tests: $path killed after ${TIMEOUT}s (CLAUDE_TESTS_TIMEOUT)" >>"$log"
    note="killed after ${TIMEOUT}s"
  elif [ "$rc" -ge 125 ]; then
    # 125 timeout itself failed, 126/127 could not start, 128+N killed by signal N (137: SIGKILL)
    echo "run-claude-tests: $path did not run to completion (exit $rc: a signal, or the command could not start)" >>"$log"
    note="did not run to completion"
  fi
  if [ "$expect" = fail ]; then
    sig=
    [ -f "$logdir/$slug.sig" ] && sig=$(cat "$logdir/$slug.sig")
    if [ "$rc" = 0 ]; then
      status=stale
    elif [ -n "$note" ]; then
      echo "run-claude-tests: $path is listed as xfail, but this is not the listed failure ($note)" >>"$log"
      status=fail; note="listed as xfail, but $note"
    elif [ -n "$sig" ] && grep -qE -- "$sig" "$log"; then
      status=xfail
    else
      echo "run-claude-tests: $path is listed as xfail, but its log does not match the listed signature /$sig/" >>"$log"
      status=fail; note="listed as xfail, but failed for another reason: log lacks /$sig/"
    fi
  else
    if [ "$rc" = 0 ]; then status=ok; else status=fail; fi
  fi
  printf 'rc=%s secs=%s status=%s run=%s\n' "$rc" "$secs" "$status" "${CLAUDE_TESTS_RUN:-}" >"$logdir/$slug.meta.tmp" \
    && mv -f "$logdir/$slug.meta.tmp" "$logdir/$slug.meta"
  case $status in
    ok)    printf 'ok     %-62s %5ss\n' "$path" "$secs" ;;
    fail)  printf 'FAIL   %-62s %5ss  rc=%s%s\n' "$path" "$secs" "$rc" "${note:+, $note}" ;;
    xfail) printf 'xfail  %-62s %5ss  rc=%s, listed in tests/claude-tests.skips\n' "$path" "$secs" "$rc" ;;
    stale) printf 'STALE  %-62s %5ss  passed, but tests/claude-tests.skips lists it as xfail\n' "$path" "$secs" ;;
  esac
}
if [ "${1:-}" = --one ]; then
  cd "$ROOT" || exit 2
  read -r kind path expect <<<"$2"
  run_one "$kind" "$path" "$expect"
  exit 0
fi

# ---- arguments ---------------------------------------------------------------
cd "$ROOT" || exit 2
jobs=$(nproc 2>/dev/null || echo 4)
logdir=
list=0
only=()
while [ $# -gt 0 ]; do
  case $1 in
    -j) [ $# -ge 2 ] || { usage >&2; exit 2; }; jobs=$2; shift 2 ;;
    -o) [ $# -ge 2 ] || { usage >&2; exit 2; }; logdir=$2; shift 2 ;;
    --list) list=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "run-claude-tests: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *) only+=("${1#./}"); shift ;;
  esac
done
case $jobs in ''|*[!0-9]*|0) echo "run-claude-tests: -j wants a positive number, got '$jobs'" >&2; exit 2 ;; esac

# ---- the skip list -----------------------------------------------------------
declare -A skip_kind skip_reason skip_sig
if [ -f "$SKIPS" ]; then
  n=0
  while IFS=$'\t' read -r kind path reason sig; do
    n=$((n + 1))
    case $kind in ''|'#'*) continue ;; esac
    case $kind in
      xfail|skip) ;;
      *) echo "run-claude-tests: $SKIPS:$n: kind must be xfail or skip, got '$kind'" >&2; exit 2 ;;
    esac
    if [ -z "$path" ] || [ -z "$reason" ]; then
      echo "run-claude-tests: $SKIPS:$n: want <xfail|skip> TAB <path> TAB <reason> [TAB <signature>]" >&2; exit 2
    fi
    case $sig in *$'\t'*)
      echo "run-claude-tests: $SKIPS:$n: more than four TAB-separated fields" >&2; exit 2 ;;
    esac
    if [ "$kind" = xfail ]; then
      if [ -z "$sig" ]; then
        echo "run-claude-tests: $SKIPS:$n: an xfail entry needs a fourth field, the grep -E signature its log must match" >&2; exit 2
      fi
      grep -E -- "$sig" </dev/null >/dev/null 2>&1
      if [ $? = 2 ]; then
        echo "run-claude-tests: $SKIPS:$n: the signature is not a valid grep -E pattern: $sig" >&2; exit 2
      fi
    elif [ -n "$sig" ]; then
      echo "run-claude-tests: $SKIPS:$n: a skip entry is not run, so it takes no signature" >&2; exit 2
    fi
    if [ -n "${skip_kind[$path]:-}" ]; then
      echo "run-claude-tests: $SKIPS:$n: $path is listed twice" >&2; exit 2
    fi
    skip_kind[$path]=$kind
    skip_reason[$path]=$reason
    skip_sig[$path]=$sig
  done <"$SKIPS"
fi

# ---- discovery ---------------------------------------------------------------
discover() {
  {
    for f in tests/*.test.sh scripts/tests/*.test.sh; do
      [ -e "$f" ] && printf 'sh\t%s\n' "$f"
    done
    for f in tests/*.test.py; do
      [ -e "$f" ] && printf 'pys\t%s\n' "$f"
    done
    for f in tests/test_*.py; do
      [ -e "$f" ] && printf 'py\t%s\n' "$f"
    done
    [ -d plugins/hov-stack/skills ] && find plugins/hov-stack/skills -type f -name '*.test.mjs' | while IFS= read -r f; do
      printf 'mjs\t%s\n' "$f"
    done
    for f in scripts/tests/*.test.js; do
      [ -e "$f" ] && printf 'mjs\t%s\n' "$f"
    done
  } | sort -t "$(printf '\t')" -k2,2
}
manifest=$(discover)
declare -A is_suite
while IFS=$'\t' read -r kind path; do
  [ -n "$path" ] && is_suite[$path]=$kind
done <<<"$manifest"

stale_paths=()
for path in "${!skip_kind[@]}"; do
  [ -n "${is_suite[$path]:-}" ] || stale_paths+=("$path")
done
if [ ${#stale_paths[@]} -gt 0 ]; then
  for path in "${stale_paths[@]}"; do
    echo "run-claude-tests: stale entry in tests/claude-tests.skips: $path is not a discovered suite (moved, deleted or never one); remove the line" >&2
  done
  exit 2
fi

total=$(grep -c . <<<"$manifest")
label="$total suites discovered"
if [ ${#only[@]} -gt 0 ]; then
  declare -A want
  for path in "${only[@]}"; do
    if [ -z "${is_suite[$path]:-}" ]; then
      echo "run-claude-tests: $path is not a discovered suite (bash tests/run-claude-tests.sh --list prints them)" >&2
      exit 2
    fi
    want[$path]=1
  done
  filtered=
  while IFS=$'\t' read -r kind path; do
    [ -n "${want[$path]:-}" ] && filtered+="$kind"$'\t'"$path"$'\n'
  done <<<"$manifest"
  manifest=${filtered%$'\n'}
  label="${#want[@]} of $total suites selected"
fi

if [ "$list" = 1 ]; then
  while IFS=$'\t' read -r kind path; do
    [ -n "$path" ] || continue
    printf '%-5s %-6s %s\n' "$kind" "${skip_kind[$path]:-run}" "$path"
  done <<<"$manifest"
  exit 0
fi

# ---- run ---------------------------------------------------------------------
if [ -z "$logdir" ]; then
  logdir=$(mktemp -d "${TMPDIR:-/tmp}/claude-tests.XXXXXX")
else
  mkdir -p "$logdir" || exit 2
  logdir=$(cd "$logdir" && pwd -P)
fi
export CLAUDE_TESTS_LOGDIR=$logdir
# One token per run; a .meta that carries another one is a previous run's, not a result.
CLAUDE_TESTS_RUN="$$.$(date +%s)"
export CLAUDE_TESTS_RUN
runlist=$logdir/runlist
: >"$runlist"
discovered=0 skipped=0
while IFS=$'\t' read -r kind path; do
  [ -n "$path" ] || continue
  discovered=$((discovered + 1))
  slug=${path//\//__}
  case ${skip_kind[$path]:-} in
    skip)  skipped=$((skipped + 1)); printf 'skip   %-62s        %s\n' "$path" "${skip_reason[$path]}" ;;
    xfail) rm -f -- "$logdir/$slug.meta" "$logdir/$slug.log"
           printf '%s\n' "${skip_sig[$path]}" >"$logdir/$slug.sig"
           printf '%s %s fail\n' "$kind" "$path" >>"$runlist" ;;
    *)     rm -f -- "$logdir/$slug.meta" "$logdir/$slug.log" "$logdir/$slug.sig"
           printf '%s %s pass\n' "$kind" "$path" >>"$runlist" ;;
  esac
done <<<"$manifest"

t_start=$(date +%s)
echo "run-claude-tests: $label, $skipped skipped, running the rest $jobs at a time; logs in $logdir"
xargs -d '\n' -P "$jobs" -n 1 bash "$SELF" --one <"$runlist"
launch_rc=$?
if [ "$launch_rc" != 0 ]; then
  echo "run-claude-tests: the launcher (xargs) exited $launch_rc: a runner child was killed or could not start, so some results below may be missing" >&2
fi

# ---- collect -----------------------------------------------------------------
ran=0 ok=0 failed=0 xfail=0 stale=0
fails=() stales=()
while IFS=$'\t' read -r kind path; do
  [ -n "$path" ] || continue
  [ "${skip_kind[$path]:-}" = skip ] && continue
  ran=$((ran + 1))
  slug=${path//\//__}
  meta=$logdir/$slug.meta
  if [ ! -f "$meta" ] || [ "$(sed -n 's/.*run=\([^ ]*\).*/\1/p' "$meta")" != "$CLAUDE_TESTS_RUN" ]; then
    failed=$((failed + 1)); fails+=("$path")
    echo "FAIL   $path  (no result recorded by this run: the runner's child for it did not finish)"
    continue
  fi
  status=$(sed -n 's/.*status=\([a-z]*\).*/\1/p' "$meta")
  case $status in
    ok)    ok=$((ok + 1)) ;;
    xfail) xfail=$((xfail + 1)) ;;
    stale) stale=$((stale + 1)); stales+=("$path") ;;
    *)     failed=$((failed + 1)); fails+=("$path") ;;
  esac
done <<<"$manifest"

if [ ${#fails[@]} -gt 0 ]; then
  for path in "${fails[@]}"; do
    log=$logdir/${path//\//__}.log
    echo
    echo "===== $path ($log)"
    if [ -f "$log" ]; then
      lines=$(wc -l <"$log")
      if [ "$lines" -gt 400 ]; then
        sed -n '1,200p' "$log"
        echo "... ($((lines - 400)) lines elided, see $log) ..."
        tail -n 200 "$log"
      else
        cat "$log"
      fi
    else
      echo "(no log written)"
    fi
  done
  echo
fi
if [ ${#stales[@]} -gt 0 ]; then
  for path in "${stales[@]}"; do
    echo "run-claude-tests: stale entry in tests/claude-tests.skips: $path passed; remove its xfail line" >&2
  done
fi

printf 'claude-tests: %s; %s ran: %s ok, %s failed, %s expected failures; %s skipped; %s stale skip entries; %ss wall\n' \
  "$label" "$ran" "$ok" "$failed" "$xfail" "$skipped" "$stale" "$(( $(date +%s) - t_start ))"
if [ "$stale" -gt 0 ]; then exit 2; fi
if [ "$failed" -gt 0 ]; then exit 1; fi
if [ "$launch_rc" != 0 ]; then
  echo "run-claude-tests: every collected suite passed, but the launcher exited $launch_rc; not green" >&2
  exit 1
fi
exit 0
