#!/usr/bin/env bash
# Does cass SEARCH actually work? Asks by querying, not by asking cass how it feels.
#
# WHY THIS EXISTS. Every cass lexical query fails while
# `cass doctor --json` returns `status: healthy, failures: 0`. Measured side by
# side on the same live state, 2026-09-20 and again 2026-09-21:
#
#     cass doctor          status=healthy  healthy=True  failures=0  warnings=10
#     cass-search-health   FAIL -- 0/5 queries usable
#
# DOCTOR IS NOT BLIND, WHICH IS THE SHARPER POINT. It reports
# `lexical.status = stale` and `lexical.checkpoint.completed = False` -- and files
# both under warnings while still returning `failures: 0`. A dead retrieval lane
# is classified as a warning. Every automated consumer reads that as healthy.
# So this check DELIBERATELY DOES NOT CONSULT `cass doctor`: the aggregate it
# publishes is the signal that failed, and adding it here would reintroduce it.
#
# THE SYMPTOM IS NOT STABLE, so do not match on it. 2026-09-20 every probe exited
# 9 with `scalar Quill query fuel exhausted after 10000000/10000000 units
# (segments=1453)`. 2026-09-21 every probe instead ran until killed by its own
# timeout: a single `cass search dcg --limit 3` ran 301s and returned zero
# results, with stderr showing `lexical rebuild flushed a streamed conversation
# batch` -- the query path was REBUILDING, not querying. Same dead lane, two
# different failure shapes. This check asserts non-zero exit generally rather
# than any particular error text, which is why it caught both.
#
# WHAT IS ACTUALLY DATED. The dead lane's last published lexical generation was
# 2026-09-11 22:39 (`lexical-generation-manifest.json`, conversation_count=31362,
# publish_state=published). The onset of query failure is NOT known and is not
# claimed here; an earlier revision of this comment asserted "~6 days" and could
# not support it. The lane was restored 2026-09-29 by `cass index --full
# --force-rebuild` on v0.9.0 (35,799 conversations published).
#
# THREE FAILURE MODES, ALL REAL:
#   - non-zero exit      the index is broken (fuel exhaustion, corrupt checkpoint)
#   - zero results       the index is EMPTY or the corpus was wiped. A query that
#                        returns nothing exits 0, so "did it run" is not a health
#                        check. This half caught nothing on 2026-09-20 but is the
#                        half that catches a bad rebuild, which is the very
#                        operation this check was written alongside.
#   - not search JSON    exit 0 but the output is not cass's `--json` contract.
#                        Counted as broken and named as such, never as "zero
#                        results": a format change must not read as an empty index.
#
# COUNT FROM `--json`, NEVER FROM THE HUMAN OUTPUT. The first version counted
# numbered lines (`^ *[0-9]+\.`), the shape its own test stub printed. Real cass
# never printed it: v0.9.0 prints `Score: ... | Agent: ...` blocks. So on
# 2026-09-29, with the lane restored and `cass search dcg --limit 3` returning 3
# hits, this check reported "exit=0 but ZERO results" for all five terms. It blamed
# the index for a parser miss. The stub had agreed with the check and not with cass.
#
# Exit 0 = healthy. Exit 1 = degraded/broken. Exit 2 = could not evaluate (cass
# or jq missing); deliberately NOT 0, because a check that cannot run must not
# read as a pass -- that is the same defect class as doctor's false green.
set -uo pipefail

# WHICH cass. An explicit CASS_HEALTH_BIN wins and is never second-guessed: an
# override that points nowhere is a broken setup and exits 2. Without one, use
# ~/.local/bin/cass, the binary cass-index.service's own ExecStart runs
# (%h/.local/bin/cass), so the check queries with the build that just indexed.
# Only if that is absent, fall back to PATH. This is for the unit, not for
# convenience. The systemd user manager's PATH has no ~/.local/bin, so as
# ExecStartPost this check, which then looked only on PATH, exited 2 ("'cass' not
# on PATH") every time. That was reproduced under the manager's real environment
# with systemd-run on 2026-09-29. It had never fired in the unit: the timer was
# off, and a killed ExecStart skips ExecStartPost.
if [ -n "${CASS_HEALTH_BIN:-}" ]; then
  CASS_BIN=$CASS_HEALTH_BIN
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/cass" ]; then
  CASS_BIN=$HOME/.local/bin/cass
else
  CASS_BIN=cass
fi
# Terms chosen to be corpus-independent: each is a word nearly every coding-agent
# archive uses constantly. A term that matches nothing is indistinguishable from a
# broken index, so they must be common, not clever. If they miss in your archive,
# set CASS_HEALTH_TERMS to words your own sessions use.
TERMS=${CASS_HEALTH_TERMS:-"error test file commit function"}
# A run that is merely slow is not the failure this guards; bound it so the check
# cannot itself hang the unit it is attached to.
PER_QUERY_TIMEOUT=${CASS_HEALTH_QUERY_TIMEOUT:-90}
# How many of the probe terms must succeed. Not all five: a single term can
# legitimately miss after a corpus prune, and a check that red-lines on one
# missing word gets switched off.
MIN_OK=${CASS_HEALTH_MIN_OK:-4}

command -v "$CASS_BIN" >/dev/null 2>&1 || {
  echo "cass-search-health: FAIL cannot evaluate — '$CASS_BIN' not found" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "cass-search-health: FAIL cannot evaluate — jq not on PATH" >&2
  exit 2
}

# stderr is kept apart from stdout: `--json` puts the result JSON on stdout and a
# failure as one `{"error":{...}}` line on stderr (v0.9.0).
ERR=$(mktemp) || { echo "cass-search-health: FAIL cannot evaluate — mktemp failed" >&2; exit 2; }
trap 'rm -f "$ERR"' EXIT

ok=0 broken=0 empty=0 total=0
first_error=""

for term in $TERMS; do
  total=$((total + 1))
  # -k: a cass that ignores SIGTERM must not hold the unit past the budget.
  # Operation-local safety: direct callers need the same protection as the unit.
  out=$(CASS_AUTO_REFRESH=0 timeout -k 5 "$PER_QUERY_TIMEOUT" "$CASS_BIN" \
    search "$term" --no-maintenance --mode lexical --limit 3 --json 2>"$ERR")
  rc=$?
  diag=$(cat "$ERR"; printf '%s' "$out")
  if [ "$rc" -ne 0 ]; then
    broken=$((broken + 1))
    # Keep the first real reason: the operator reading an alert needs the cause,
    # not a count. The fuel-exhaustion line is the diagnostic that names the
    # segment count, so prefer it; then cass's own error kind and message.
    if [ -z "$first_error" ]; then
      first_error=$(printf '%s\n' "$diag" | grep -o 'fuel exhausted[^"]*' | head -1)
      [ -n "$first_error" ] || first_error=$(printf '%s\n' "$diag" | grep '^{"error"' | tail -1 \
        | jq -r '.error | "\(.kind): \(.message)"' | cut -c1-160)
      [ -n "$first_error" ] || first_error=$(printf '%s\n' "$diag" | tail -1 | cut -c1-160)
    fi
    printf 'cass-search-health:   %-10s exit=%-3s %s\n' "$term" "$rc" "${first_error:0:90}" >&2
    continue
  fi
  # Exactly ONE result document. Slurped, so two documents cannot yield two
  # counts; a multi-line count once made `[ -eq ]` error out and fall through to
  # ok, which read two empty results as a pass.
  if ! hits=$(printf '%s' "$out" | jq -ers \
      'if length == 1 and (.[0].hits | type) == "array" then .[0].hits | length
       else error("expected one search result document with a hits array") end'); then
    broken=$((broken + 1))
    [ -n "$first_error" ] \
      || first_error="exit 0 but output is not cass search JSON: $(printf '%s\n' "$out" | head -1 | cut -c1-80)"
    printf 'cass-search-health:   %-10s exit=0 but output is not cass search JSON\n' "$term" >&2
    continue
  fi
  if [ "$hits" -eq 0 ]; then
    empty=$((empty + 1))
    printf 'cass-search-health:   %-10s exit=0 but ZERO results\n' "$term" >&2
    continue
  fi
  ok=$((ok + 1))
done

echo "cass-search-health: $ok/$total queries returned results (broken=$broken empty=$empty)"

if [ "$ok" -ge "$MIN_OK" ]; then
  exit 0
fi

echo "cass-search-health: FAIL — only $ok/$total queries usable, need $MIN_OK" >&2
[ -n "$first_error" ] && echo "cass-search-health: first cause: $first_error" >&2
echo "cass-search-health: NOTE \`cass doctor\` may still report healthy; it did on 2026-09-20 at 0/5." >&2
exit 1
