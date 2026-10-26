#!/usr/bin/env bash
# The contract of cass-search-health.sh, proven by RUNNING it against a stubbed
# cass.
#
# WHY THIS CHECK EXISTS. On 2026-09-20 every cass lexical query had been failing
# for ~6 days -- `scalar Quill query fuel exhausted after 10000000/10000000 units
# (segments=1453)` -- while `cass doctor --json` reported `status: healthy,
# failures: 0`. Captured side by side on the same live state before any repair:
#
#     cass doctor            status=healthy healthy=True failures=0
#     cass-search-health     FAIL — 0/5 queries usable
#
# That contrast is the whole justification for querying instead of asking doctor,
# so it is asserted here as a standing property, not left as a story in a commit.
#
# Planted negatives:
#  - N2: cass exits NON-ZERO -> must FAIL. This is the live 2026-09-20 shape. A
#    check that only looks at stdout and never at the exit code passes it.
#  - N3: cass exits ZERO with NO results -> must FAIL. An empty index exits 0, so
#    "did the command run" is not a health check. This is the half that catches a
#    bad rebuild, which is exactly the operation this check shipped alongside.
#  - N5: cass MISSING -> must exit 2, NOT 0. A check that cannot evaluate must not
#    read as a pass; that is the same defect class as doctor's false green, and a
#    skip-reads-as-green is how this went unnoticed for six days.
#  - N7: the check must NOT consult `cass doctor`. If a future edit adds it back,
#    the green signal that failed here returns. Asserted against the source.
#  - N8: exit ZERO but the output is not search JSON -> must FAIL, and be named
#    as a format break, NOT as "ZERO results". The first version of this suite
#    stubbed numbered result lines that real cass never printed, so the check
#    passed here and reported 0/5 against a working index (2026-09-29). The `ok`
#    stub now mirrors real v0.9.0 in BOTH modes: `--json` prints the captured
#    result shape, and the human mode prints `Score:` blocks with no numbered
#    lines. So a check that scrapes human output fails case 1. Valid JSON with
#    no `hits` array (a renamed key, an object) is the same break (3b'').
#  - N9: no override and cass not on PATH, but present at ~/.local/bin/cass ->
#    must find it. That is the systemd user manager's environment, where this
#    check exited 2 on every unit run (reproduced 2026-09-29).
#  - N10: jq missing -> exit 2, never a pass.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
SCRIPT="$HERE/scripts/cass-search-health.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

FIXTURE=$HERE/tests/fixtures/cass-search-v0.9.0-hits.json
[ -f "$FIXTURE" ] || { echo "FAIL: fixture $FIXTURE missing" >&2; exit 1; }

# make_cass <name> <behaviour> [dir]
#   ok        like real cass v0.9.0: under `--json`, the result shape captured
#             from `cass search dcg --limit 3 --json` on 2026-09-29 (values
#             replaced, keys and nesting kept); without it, the human
#             `Score: ... | Agent: ...` blocks, which have no numbered lines
#   empty     exit 0, the real v0.9.0 zero-hit `--json` result (captured
#             2026-09-29: same keys plus `suggestions`, nothing on stderr)
#   noisy     the `ok` result, plus the message cass printed on stderr while
#             rebuilding on 2026-09-21: stdout must be read alone
#   human     exit 0, human output even under `--json` (a format break)
#   twodocs   exit 0, two empty `--json` results on stdout
#   renamed   exit 0, valid JSON whose results sit under a key other than `hits`
#   hitsobj   exit 0, valid JSON whose `hits` is an object, not an array
#   hang      ignores SIGTERM and sleeps past any per-query timeout
#   fuel      exit 9 with the real 2026-09-20 fuel-exhaustion message
#   jsonerr   exit 3 with the real v0.9.0 `{"error":{...}}` stderr line
#             (missing-index, captured 2026-09-29)
make_cass() {
  # Separate statements on purpose: `local name=$1 d=$TMP/$name` expands every
  # RHS before assigning any of them, so $name there resolves to the OUTER
  # scope and trips `set -u`. Bit me writing this file.
  local name=$1 b=$2
  local d=${3:-$TMP/$name}
  mkdir -p "$d"
  cat > "$d/cass" <<STUB
#!/usr/bin/env bash
HUMAN='----------------------------------------------------------------
Score: 30.25 | Agent: claude_code | WS: /fixture/workspace
Path: /fixture/session-one.jsonl
Snippet: a **dcg** snippet'
json=0
for a in "\$@"; do [ "\$a" = --json ] && json=1; done
case "$b" in
  safe)
    printf '%s|%s\n' "\${CASS_AUTO_REFRESH:-unset}" "\$*" >> '$TMP/safety-calls'
    maintenance=0 mode='' previous=''
    for a in "\$@"; do
      [ "\$a" = --no-maintenance ] && maintenance=1
      [ "\$previous" = --mode ] && mode=\$a
      previous=\$a
    done
    if [ "\${CASS_AUTO_REFRESH:-unset}" != 0 ] || [ "\$maintenance" != 1 ] || [ "\$mode" != lexical ]; then
      echo 'unsafe health invocation: refresh/maintenance/lexical contract missing' >&2
      exit 8
    fi
    cat '$FIXTURE'; exit 0 ;;
  four|three)
    case "\$2" in
      function) printf '{"hits":[]}\n'; exit 0 ;;
      commit) [ "$b" = three ] && { printf '{"hits":[]}\n'; exit 0; } ;;
    esac
    cat '$FIXTURE'; exit 0 ;;
  ok)
    if [ "\$json" = 1 ]; then cat '$FIXTURE'; else printf '%s\n' "\$HUMAN"; fi
    exit 0 ;;
  empty)
    printf '{"query":"x","limit":3,"offset":0,"count":0,"total_matches":0,"hits":[],"max_tokens":null,"request_id":null,"cursor":null,"hits_clamped":false,"budget":{"elapsed_ms":1000,"budget_ms":120000,"timed_out":false,"skipped_sections":[],"recommended_next_probe":null},"suggestions":[]}\n'
    exit 0 ;;
  noisy)
    printf 'lexical rebuild flushed a streamed conversation batch\n' >&2
    cat '$FIXTURE'; exit 0 ;;
  human)
    printf '%s\n' "\$HUMAN"; exit 0 ;;
  twodocs)
    printf '{"count":0,"hits":[]}\n{"count":0,"hits":[]}\n'; exit 0 ;;
  renamed)
    printf '{"query":"x","count":3,"total_matches":3,"results":[{},{},{}]}\n'; exit 0 ;;
  hitsobj)
    printf '{"query":"x","count":3,"hits":{"total":3,"items":[{},{},{}]}}\n'; exit 0 ;;
  hang)
    trap '' TERM; sleep 60; exit 0 ;;
  fuel)
    printf 'search failed: executing a Quill lexical query: scalar Quill query fuel exhausted after 10000000/10000000 units (segments=1453, dictionary_blocks=9995906)\n' >&2
    exit 9 ;;
  jsonerr)
    printf '{"error":{"code":3,"kind":"missing-index","message":"cass has not been initialized in /x yet, so search cannot run until the first index completes.","hint":"Run cass index --full once.","retryable":true}}\n' >&2
    exit 3 ;;
esac
STUB
  chmod +x "$d/cass"
  printf '%s\n' "$d/cass"
}

# A PATH holding exactly the tools the check and the stub use, and no cass, so
# the lookup-order cases cannot be satisfied by a real cass on the runner.
# make_sysbin <dir> [tool to leave out]
make_sysbin() {
  local dir=$1 skip=${2:-} t
  mkdir -p "$dir"
  for t in bash env timeout grep head tail cut cat jq mktemp rm; do
    [ "$t" = "$skip" ] && continue
    ln -s "$(command -v "$t")" "$dir/$t" || return 1
  done
}

run() { # run <cass-path> -> exit status
  CASS_HEALTH_BIN="$1" CASS_HEALTH_QUERY_TIMEOUT=5 \
    bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
  printf '%s\n' "$?"
}

# 1. Healthy index: all five queries return results -> exit 0.
rc=$(run "$(make_cass good ok)")
[ "$rc" = 0 ] && ok || bad "healthy index exited $rc (want 0) :: $(tail -1 "$TMP/err")"
grep -qF '5/5 queries returned results' "$TMP/out" && ok \
  || bad "healthy run did not report 5/5 :: $(cat "$TMP/out")"

# The caller may explicitly enable refresh; each query still must be read-only
# and lexical. The stub validates actual argv and env, not source spelling.
SAFE=$(make_cass safe safe)
rc=$(CASS_AUTO_REFRESH=1 run "$SAFE")
[ "$rc" = 0 ] && ok || bad "safety-argv fixture rejected health invocation: $(cat "$TMP/err")"
[ "$(wc -l < "$TMP/safety-calls")" = 5 ] && ok || bad "safety fixture did not see all five calls"

# A genuine 4/5 passes by default; 3/5 fails. MIN_OK=6 below is a different edge.
rc=$(run "$(make_cass four four)")
[ "$rc" = 0 ] && ok || bad "four usable terms exited $rc (want 0)"
grep -qF '4/5 queries returned results (broken=0 empty=1)' "$TMP/out" && ok \
  || bad "four-term fixture did not exercise one empty result"
rc=$(run "$(make_cass three three)")
[ "$rc" = 1 ] && ok || bad "three usable terms exited $rc (want 1)"
grep -qF '3/5 queries returned results (broken=0 empty=2)' "$TMP/out" && ok \
  || bad "three-term fixture did not exercise two empty results"

# 1b. cass writes diagnostics to stderr: on 2026-09-21 every query printed
#     `lexical rebuild flushed a streamed conversation batch` there. A healthy
#     result must still count, so stderr must never be parsed as the result.
rc=$(run "$(make_cass noisy noisy)")
[ "$rc" = 0 ] && ok || bad "stderr noise beside a healthy result exited $rc (want 0) :: $(tail -1 "$TMP/err")"

# 2. PLANTED NEGATIVE: the live 2026-09-20 shape. Non-zero exit must FAIL.
rc=$(run "$(make_cass broken fuel)")
[ "$rc" = 1 ] && ok || bad "fuel-exhausted index exited $rc (want 1) — the gate is dead"
grep -qF '0/5 queries returned results' "$TMP/out" && ok \
  || bad "broken run did not report 0/5"
# The operator reading the alert needs the CAUSE, not just a count.
grep -qF 'fuel exhausted' "$TMP/err" && ok \
  || bad "the failure reason was not surfaced — an alert without a cause gets ignored"

# 3. PLANTED NEGATIVE: exit 0 with zero results must FAIL. Differs from case 1
#    ONLY in whether result lines came back.
rc=$(run "$(make_cass hollow empty)")
[ "$rc" = 1 ] && ok \
  || bad "empty index exited $rc (want 1) — 'it ran' is not 'it works'"
grep -qF 'ZERO results' "$TMP/err" && ok \
  || bad "empty-result case was not named in the output"

# 3b. PLANTED NEGATIVE: exit 0 with output that is not search JSON must FAIL,
#     and be named as a format break rather than blamed on the index.
rc=$(run "$(make_cass drift human)")
[ "$rc" = 1 ] && ok || bad "non-JSON output exited $rc (want 1)"
grep -qF 'not cass search JSON' "$TMP/err" && ok \
  || bad "a format break was not named :: $(tail -2 "$TMP/err")"
grep -qF 'ZERO results' "$TMP/err" \
  && bad "a format break was reported as an empty index — the 2026-09-29 false alarm" || ok

# 3b'. PLANTED NEGATIVE: two result documents must FAIL. The first --json
#      version counted each document, got a two-line count, and `[ -eq ]` erred
#      into the ok branch: two EMPTY results passed 5/5 (caught in review).
rc=$(run "$(make_cass twodocs twodocs)")
[ "$rc" = 1 ] && ok || bad "two result documents exited $rc (want 1) — a false green"
grep -qF 'not cass search JSON' "$TMP/err" && ok \
  || bad "two result documents were not named as a format break"

# 3b''. PLANTED NEGATIVE: valid JSON whose shape drifted must FAIL as a format
#       break. Without the array-type guard a renamed key reads as an empty
#       index, and an object `hits` counts its keys as results.
for shape in renamed hitsobj; do
  rc=$(run "$(make_cass "$shape" "$shape")")
  [ "$rc" = 1 ] && ok || bad "$shape JSON exited $rc (want 1) — a false green"
  grep -qF 'not cass search JSON' "$TMP/err" && ok \
    || bad "$shape JSON was not named as a format break :: $(tail -2 "$TMP/err")"
  grep -qF 'ZERO results' "$TMP/err" \
    && bad "$shape JSON was reported as an empty index" || ok
done

# 3c. cass's own JSON error surfaces as kind + message, not a raw brace line.
rc=$(run "$(make_cass jerr jsonerr)")
[ "$rc" = 1 ] && ok || bad "JSON-error run exited $rc (want 1)"
grep -qF 'first cause: missing-index: cass has not been initialized' "$TMP/err" && ok \
  || bad "cass's error kind/message was not surfaced :: $(tail -2 "$TMP/err")"

# 4. PLANTED NEGATIVE: cannot evaluate must be 2, never 0.
rc=$(CASS_HEALTH_BIN=/nonexistent/cass bash "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?")
[ "$rc" = 2 ] && ok \
  || bad "missing cass exited $rc (want 2) — a skip that reads as a pass is the original defect"

# 4b. PLANTED NEGATIVE (the unit's environment): no override and no cass on
#     PATH, but ~/.local/bin/cass exists -> the check must find and use it.
SYSBIN=$TMP/sysbin
make_sysbin "$SYSBIN" || { echo "FAIL: could not build $SYSBIN" >&2; exit 1; }
if PATH=$SYSBIN command -v cass >/dev/null 2>&1; then
  bad "precondition: $SYSBIN resolves a cass, so the fallback case proves nothing"
else
  ok
fi
make_cass unithome ok "$TMP/home/.local/bin" >/dev/null
rc=$(env -u CASS_HEALTH_BIN PATH="$SYSBIN" HOME="$TMP/home" CASS_HEALTH_QUERY_TIMEOUT=5 \
      "$BASH" "$SCRIPT" >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?")
[ "$rc" = 0 ] && ok \
  || bad "cass only in ~/.local/bin exited $rc (want 0) — the unit case :: $(tail -1 "$TMP/err")"
grep -qF '5/5 queries returned results' "$TMP/out" && ok \
  || bad "HOME/.local/bin fallback did not report 5/5 :: $(cat "$TMP/out")"

# 4b'. The indexer's own binary wins over PATH: a broken cass earlier on PATH
#      must not stand in for the ~/.local/bin/cass the unit indexed with.
make_cass pathfuel fuel "$TMP/pathfuel" >/dev/null
rc=$(env -u CASS_HEALTH_BIN PATH="$TMP/pathfuel:$SYSBIN" HOME="$TMP/home" CASS_HEALTH_QUERY_TIMEOUT=5 \
      "$BASH" "$SCRIPT" >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?")
[ "$rc" = 0 ] && ok \
  || bad "a PATH cass was queried instead of HOME/.local/bin/cass (exit $rc, want 0)"

# 4c. ...and with no cass anywhere it is still "cannot evaluate", never a pass,
#     including when HOME itself is unset.
rc=$(env -u CASS_HEALTH_BIN PATH="$SYSBIN" HOME="$TMP/nohome" \
      "$BASH" "$SCRIPT" >/dev/null 2>"$TMP/err"; printf '%s' "$?")
[ "$rc" = 2 ] && ok || bad "no cass anywhere exited $rc (want 2)"
rc=$(env -u CASS_HEALTH_BIN -u HOME PATH="$SYSBIN" \
      "$BASH" "$SCRIPT" >/dev/null 2>"$TMP/err"; printf '%s' "$?")
[ "$rc" = 2 ] && ok || bad "HOME unset, no cass: exited $rc (want 2) :: $(tail -1 "$TMP/err")"

# 4d. PLANTED NEGATIVE: without jq the count cannot be read -> 2, never 0.
NOJQ=$TMP/sysbin-nojq
make_sysbin "$NOJQ" jq || { echo "FAIL: could not build $NOJQ" >&2; exit 1; }
NOJQ_CASS=$(make_cass nojq ok)
rc=$(PATH="$NOJQ" CASS_HEALTH_BIN="$NOJQ_CASS" CASS_HEALTH_QUERY_TIMEOUT=5 \
      "$BASH" "$SCRIPT" >/dev/null 2>"$TMP/err"; printf '%s' "$?")
[ "$rc" = 2 ] && ok || bad "missing jq exited $rc (want 2)"
grep -qF 'jq not on PATH' "$TMP/err" && ok || bad "missing jq was not named"

# 5. Threshold is honoured: 4/5 is acceptable, so a single missing term after a
#    corpus prune does not red-line a working index.
GOOD=$(make_cass thresh ok)
rc=$(CASS_HEALTH_BIN="$GOOD" CASS_HEALTH_QUERY_TIMEOUT=5 CASS_HEALTH_MIN_OK=6 \
      bash "$SCRIPT" >/dev/null 2>&1; printf '%s' "$?")
[ "$rc" = 1 ] && ok || bad "MIN_OK=6 against 5 terms exited $rc (want 1)"

# 5b. A cass that ignores SIGTERM is still bounded (timeout -k). Without -k the
#     per-query bound is only as good as cass honouring TERM, and the unit's
#     ExecStartPost budget in search-health.conf assumes it is bounded. The stub
#     sleeps 60s; -k 5 on a 1s timeout ends it at about 6s.
HANG=$(make_cass hang hang)
start=$SECONDS
rc=$(CASS_HEALTH_BIN="$HANG" CASS_HEALTH_QUERY_TIMEOUT=1 CASS_HEALTH_TERMS=one CASS_HEALTH_MIN_OK=1 \
      bash "$SCRIPT" >/dev/null 2>"$TMP/err"; printf '%s' "$?")
took=$((SECONDS - start))
[ "$rc" = 1 ] && ok || bad "TERM-ignoring cass exited $rc (want 1)"
[ "$took" -lt 40 ] && ok || bad "TERM-ignoring cass held the check ${took}s — timeout has no kill-after"

# 6. PLANTED NEGATIVE: the check must never consult `cass doctor`. Doctor was
#    measured green at 0/5 on 2026-09-20; reintroducing it restores the exact
#    false signal this script replaces.
# Must test for INVOKING doctor, not for the word appearing. The script names
# doctor in its own rationale and in a NOTE it prints to stderr; an assertion
# that greps the bare word fires on those and calls a correct script broken --
# which is what the first version of this check did.
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -v -E '^[[:space:]]*(echo|printf)' | grep -qE '(^|[;&|$( ])(cass|\$CASS_BIN|"\$CASS_BIN")[[:space:]]+doctor'; then
  bad "cass-search-health invokes \`cass doctor\` — that is the false green it exists to replace"
else
  ok
fi
# ...and the rationale must stay written down, or the next editor re-adds it.
grep -qF 'doctor' "$SCRIPT" && ok \
  || bad "the doctor-is-untrustworthy rationale was removed from the script comments"

# 7. Not here: the unit wiring that runs this check after every index pass (a
#    cass-index.service drop-in) is not in this repo, so neither is its test.

if [ "$fail" -eq 0 ]; then
  echo "ok — cass search health contract: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — cass search health contract: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
