#!/usr/bin/env bash
# deferral-watch.sh: run every ACTIVE entry's trigger_check from the deferral
# watchlist and classify the outcome, so "not now — revisit when X" decisions
# surface themselves instead of rotting (issue #432). The founding incidents
# are recorded in the watchlist file's own header.
#
# Data: harness/deferral-watchlist.tsv. Override precedence: --file
# PATH beats $DEFERRAL_WATCHLIST_FILE beats the default. The env seam exists
# for harness-doctor-vacuity.test.sh, which pins the doctor's section-27
# consumer path against fixtures instead of the operator's live box.
#
# trigger_check exit-code contract:
#   0     -> fired  (the revisit condition is TRUE; surface it)
#   1     -> quiet  (checked, not fired)
#   other -> broken (the check itself failed: missing binary, bad syntax,
#            timeout). Distinct from quiet BY DESIGN — a gate that cannot
#            compare must fail, not read as green. Also classified broken:
#            an unknown status column, and an EMPTY trigger_check field — a
#            short/malformed row would otherwise run `bash -c ""`, which
#            exits 0 and would read as FIRED (inward-vet finding).
# Each check runs under `timeout 30` with stdout/stderr discarded; only the
# exit code speaks.
#
# Output: one "<id>\t<outcome>\t<source>" line per non-resolved entry,
# outcome one of fired | quiet | broken | manual; source is the row's own
# source column, so consumers can name each deferral's provenance (issue
# #432 AC2). harness-doctor section 27 parses these lines.
# Exit: 2 if any broken, else 1 if any fired, else 0 (broken dominates fired
# so a check that cannot verify never hides behind a fired sibling in callers
# that only read the exit code). 64 = usage / watchlist missing.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILE="${DEFERRAL_WATCHLIST_FILE:-$HERE/../harness/deferral-watchlist.tsv}"
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:?--file needs a path}"; shift 2 ;;
    *) echo "usage: deferral-watch.sh [--file PATH]" >&2; exit 64 ;;
  esac
done
[ -f "$FILE" ] || { echo "deferral-watch: watchlist not found: $FILE" >&2; exit 64; }

FIRED=0 BROKEN=0
# `|| [ -n "$id" ]` keeps the loop body alive for a final line with no
# trailing newline — without it, `read` returns nonzero at EOF and the LAST
# row is silently dropped, unclassified: a fired trigger vanishes and the
# runner exits 0 clean (inward-vet finding, reproduced by both lenses).
while IFS=$'\t' read -r id status added resolved source check prose || [ -n "$id" ]; do
  # shellcheck disable=SC2034  # added/resolved/prose are file columns not used here
  case "$id" in ''|\#*) continue ;; esac
  [ "$status" = resolved ] && continue
  if [ "$status" != active ]; then
    printf '%s\tbroken\t%s\n' "$id" "$source"; BROKEN=1; continue
  fi
  if [ -z "$check" ]; then
    printf '%s\tbroken\t%s\n' "$id" "$source"; BROKEN=1; continue
  fi
  case "$check" in
    MANUAL:*) printf '%s\tmanual\t%s\n' "$id" "$source"; continue ;;
  esac
  timeout 30 bash -c "$check" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) printf '%s\tfired\t%s\n' "$id" "$source"; FIRED=1 ;;
    1) printf '%s\tquiet\t%s\n' "$id" "$source" ;;
    *) printf '%s\tbroken\t%s\n' "$id" "$source"; BROKEN=1 ;;
  esac
done < "$FILE"

[ "$BROKEN" = 1 ] && exit 2
[ "$FIRED" = 1 ] && exit 1
exit 0
