#!/usr/bin/env bash
# unit-health.sh — rate-aware health report for systemd --user units.
#
# WHY THIS EXISTS, GIVEN failed_unit_sweep() ALREADY CLASSIFIES FAILURES.
# The sweep in harness-doctor.sh answers "which failed units is nothing watching?"
# and answers it well. It cannot answer "how hard is this one failing?", because
# `systemctl list-units --state=failed` is a snapshot: a unit that failed once on
# Tuesday and a unit failing every 60 seconds are the same single row. Two
# consequences, both measured on workstation 2026-08-29:
#
#   1. tend-runtime-watchdog.service had failed 1253 times in 24h. The sweep sees
#      one row, identical to a unit that failed once. (That unit was retired and
#      deleted later the same day -- kept here because it is the measurement
#      this script exists to make, not a live example. The rate is the point.)
#   2. That unit carries no OnFailure= — and it should not. Edge-triggered
#      alerting on a 60s timer pages 1440 times a day. Rate is the PRECONDITION
#      for alerting a fast-timer unit at all, not a nicety on top of it.
#
# The sweep was weekly too (harness-weekly.timer, Mondays, retired 2026-10-17). Its
# own header records a unit red since 08-21 found on 08-29 — eight days. Both now
# run on demand.
#
# NO THIRD LIST. The header of failed_unit_sweep() warns that a third ownership
# list would rot the way the first two did, and it is right. Coverage class here
# is read from the same three mechanisms that already own the decision:
#   OnFailure=                 the alerting contract (#518)
#   NO OnFailure= ON PURPOSE   that contract's documented-exemption marker (#518)
#   UNITS_FOREIGN              the "another repo owns this" register (#515)
# This script adds a HEALTH axis (rate) and reuses the COVERAGE axis verbatim.
set -euo pipefail

SINCE="24 hours ago"
THRESHOLD=10
JSON=0
QUIET=0
DRY_RUN=0
# systemd's catalog entry "Unit failed" (SD_MESSAGE_UNIT_FAILED).
FAILURE_ID=d9b373ed55a64feb8242e02dbe79a49c

# POLICY SOURCES ARE FOUND RELATIVE TO THIS SCRIPT, NOT VIA A FIXED CHECKOUT PATH.
# The hardcoded path worked on workstation and nowhere else: CI checks the repo out at
# $GITHUB_WORKSPACE, so the tool exited 2 on every runner, correctly reporting
# that it could not read its own policy sources. This script always ships at
# <repo>/scripts/, so the register is always one directory up.
# Resolve both directory symlinks (~/.claude/scripts) and the PATH file symlink
# (~/.local/bin/unit-health), so either installed entry reads the same sources.
_SELF_DIR=$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")
REPO_SYSD="${UNIT_HEALTH_SYSD:-$_SELF_DIR/../systemd}"
SYNC_SH="${UNIT_HEALTH_SYNC:-$_SELF_DIR/../sync.sh}"

usage() {
  cat <<'USAGE'
unit-health.sh — rate-aware health report for systemd --user units

Usage: unit-health.sh [options]

  --since <expr>      journalctl window (default: "24 hours ago")
  --threshold <n>     failures in window that make a unit a HOT_LOOP (default: 10)
  --json              machine-readable output
  --quiet             only print problems (ignored with --json)
  --dry-run           describe the read-only queries without contacting systemd
                      or the journal
  -h, --help          this text

Includes loaded services (active/restarting daemons too), timer targets, failed
services, and services with a "Unit failed" journal event in the window. Service
properties are read in one batch; independent journal reads run at most eight at
a time when xargs is available (sequential otherwise).

Exit codes:
  0  no problems
  1  at least one HOT_LOOP or FAILED unit found
  2  the box could not be asked (systemctl/journalctl/jq unavailable, policy
     sources unreadable). Never silently "clean" — a gate that cannot
     compare must fail, not skip.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since|--threshold)
      [ $# -ge 2 ] || { echo "unit-health: $1 needs a value" >&2; exit 2; }
      if [ "$1" = --since ]; then SINCE="$2"; else THRESHOLD="$2"; fi
      shift 2 ;;
    --json)      JSON=1; shift ;;
    --quiet)     QUIET=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unit-health: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$THRESHOLD" in
  ''|*[!0-9]*) echo "unit-health: --threshold must be a non-negative integer, got: $THRESHOLD" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo 'unit-health: jq is required to read journal JSON' >&2; exit 2; }
if [ "$DRY_RUN" -eq 1 ]; then
  plan_text='Enumerate loaded services, timer targets, failed services and services with a Unit failed journal event; read Id, ActiveState and Result in one batch; count journal failure lines per service. No units are changed.'
  plan=$(jq -n --arg since "$SINCE" --arg threshold "$THRESHOLD" --arg failure_id "$FAILURE_ID" \
    --arg plan "$plan_text" '{
    dry_run:true, since:$since, threshold:($threshold|tonumber), commands:[
      ["systemctl", "--user", "list-units", "--type=service", "--all", "--no-legend", "--plain"],
      ["systemctl", "--user", "list-timers", "--all", "--no-legend", "--plain"],
      ["systemctl", "--user", "list-units", "--state=failed", "--no-legend", "--plain"],
      ["journalctl", "--user", ("MESSAGE_ID=" + $failure_id), "--since", $since,
        "--no-pager", "-o", "json", "--output-fields=USER_UNIT"]
    ], per_unit:["systemctl show Id ActiveState Result (one batch)",
      "journalctl failure count (at most eight concurrent)"],
    policy:["unit files and drop-ins", "UNITS_FOREIGN"], plan:$plan
  }')
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$plan"
  else
    printf 'unit-health: dry run, window="%s" threshold=%s\n' "$SINCE" "$THRESHOLD"
    printf '%s\n' "$plan" | jq -r '.commands[] | map(@sh) | join(" ")'
    printf '%s\n' "$plan_text"
  fi
  exit 0
fi

# --- fail closed on a box that cannot be asked -------------------------------
command -v systemctl >/dev/null 2>&1 || { echo "unit-health: no systemctl on this host" >&2; exit 2; }
command -v journalctl >/dev/null 2>&1 || { echo "unit-health: no journalctl on this host" >&2; exit 2; }
systemctl --user show -p Version >/dev/null 2>&1 || {
  echo "unit-health: no reachable systemd --user manager in this context" >&2; exit 2; }

FOREIGN=""
# The register is sync.sh's UNITS_FOREIGN line plus the host's <overlay>/foreign-units.
if [ -f "$_SELF_DIR/../lib/foreign-units.sh" ]; then
  # shellcheck source=SCRIPTDIR/../lib/foreign-units.sh
  . "$_SELF_DIR/../lib/foreign-units.sh"
  FOREIGN=$(foreign_units_register "$SYNC_SH")
fi
if [ ! -d "$REPO_SYSD" ] || [ -z "$FOREIGN" ]; then
  echo "unit-health: cannot read the unit register ($REPO_SYSD / UNITS_FOREIGN in $SYNC_SH, via lib/foreign-units.sh)" >&2
  echo "unit-health: refusing to report coverage from policy sources that did not load" >&2
  exit 2
fi

# --- coverage class: the same three reads failed_unit_sweep() performs -------
#
# ONE DELIBERATE DIFFERENCE: DROP-INS COUNT.
# failed_unit_sweep() tests `-f "$sysd/$file"` and reads only the main unit file.
# systemd merges `<unit>.d/*.conf` into the unit, so an OnFailure= placed in a
# drop-in is live and in force while being invisible to a main-file-only read --
# that unit reports UNALERTED or UNOWNED when it is in fact wired to page.
# jsm-auto-update is the shape that surfaced this on workstation 2026-08-29: the repo
# ships jsm-auto-update.timer and jsm-auto-update.service.d/ but no main
# .service file at all. Its drop-ins happen to carry no OnFailure=, so UNOWNED
# is the correct answer there -- but only by luck, and the next unit to put its
# alerting in an override.conf would be misreported.
#
# This function therefore reads main file AND drop-ins. The same latent gap
# exists in failed_unit_sweep(); it is left alone here rather than edited
# through, because that function is pinned by its own suite and belongs to the
# doctor. It is called out in the PR body instead.
coverage_class() {
  local unit=$1 file base dropin
  case "$unit" in
    *@*) file="${unit%%@*}@.${unit##*.}" ;;
    *)   file=$unit ;;
  esac
  base=${unit%.*}
  dropin="$REPO_SYSD/$file.d"

  # The unit is "declared here" if the repo ships either the unit or a drop-in.
  if [ -f "$REPO_SYSD/$file" ] || [ -d "$dropin" ]; then
    if [ -f "$REPO_SYSD/$file" ] && grep -qE '^OnFailure=' "$REPO_SYSD/$file"; then
      echo ALERTED
    elif [ -d "$dropin" ] && grep -rqE '^OnFailure=' "$dropin" 2>/dev/null; then
      echo ALERTED
    elif [ -f "$REPO_SYSD/$file" ] && grep -qF 'NO OnFailure= ON PURPOSE' "$REPO_SYSD/$file"; then
      echo EXEMPT
    elif [ -d "$dropin" ] && grep -rqF 'NO OnFailure= ON PURPOSE' "$dropin" 2>/dev/null; then
      echo EXEMPT
    elif [ -f "$REPO_SYSD/$file" ]; then
      echo UNALERTED
    else
      # Drop-ins only, no main unit, no alerting in either: the repo shapes this
      # unit without owning it. Not UNALERTED (nothing here declares the unit),
      # not FOREIGN (no other repo claims it either).
      echo UNOWNED
    fi
  elif grep -qF " $base " <<<" $FOREIGN "; then
    echo FOREIGN
  else
    echo UNOWNED
  fi
}

# --- the unit set: loaded, timers, failed now, or failed in the window --------
# A Restart= daemon may be active again by the time we look. Timer targets and
# failed state alone omitted both SSH tunnels despite 1,910 failures in a week.
units_file=$(mktemp) || exit 1
trap 'rm -f "$units_file"' EXIT

# A QUERY THAT FAILED AND A BOX WITH NOTHING ON IT ARE DIFFERENT ANSWERS.
# The first draft conflated them and exited 2 on both, which made the tool
# fail-closed on an input where the honest answer is "clean" -- a fresh runner
# has no --user timers at all. A gate that can never return PASS gets switched
# off, so the status of each query is captured and only a FAILED query is fatal.
raw_timers=""
raw_failed=""
raw_services=""
if ! raw_services=$(systemctl --user list-units --type=service --all --no-legend --plain); then
  echo "unit-health: could not enumerate loaded --user services; the sweep did NOT run" >&2
  exit 2
fi
if ! raw_timers=$(systemctl --user list-timers --all --no-legend --plain 2>/dev/null); then
  echo "unit-health: could not enumerate --user timers; the sweep did NOT run" >&2
  exit 2
fi
if ! raw_failed=$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null); then
  echo "unit-health: could not enumerate failed --user units; the sweep did NOT run" >&2
  exit 2
fi

printf '%s\n' "$raw_timers" | awk '{ print $NF }' | grep -F '.service' >>"$units_file" || true
printf '%s\n' "$raw_failed" | awk '{ print $1 }' | grep -F '.service' >>"$units_file" || true

printf '%s\n' "$raw_services" | awk '{ print $1 }' | grep -F '.service' >>"$units_file" || true

# A service that failed in the window and has since been unloaded is absent from
# all three snapshots. Match systemd's failure event, not arbitrary application
# text. USER_UNIT keeps the user-manager inventory separate from system units
# visible in the journal.
if ! journalctl --user "MESSAGE_ID=$FAILURE_ID" --since "$SINCE" --no-pager \
    -o json --output-fields=USER_UNIT \
    | jq -r 'select(.USER_UNIT | type == "string") | .USER_UNIT |
      select(endswith(".service"))' >>"$units_file"; then
  echo 'unit-health: could not discover failed user services; refusing an incomplete report' >&2
  exit 2
fi

sort -u -o "$units_file" "$units_file"

# Batch cheap property reads and bound concurrent independent journal reads.
# A single multi-unit JSON journal query was 7x slower on the live seven-day
# window; keep the original indexed per-service query and its failure semantics.
batched=0
declare -A active_by_unit=() result_by_unit=() failures_by_unit=()
mapfile -t units <"$units_file"
if command -v xargs >/dev/null 2>&1 && [ "${#units[@]}" -gt 0 ]; then
  batched=1
  if ! properties=$(systemctl --user show -p Id -p ActiveState -p Result -- "${units[@]}"); then
    echo 'unit-health: could not read service properties; refusing an incomplete report' >&2
    exit 2
  fi
  id="" state="" service_result=""
  while IFS='=' read -r key value; do
    case "$key" in
      Id) id=$value ;;
      ActiveState) state=$value ;;
      Result) service_result=$value ;;
      '')
        if [ -n "$id" ]; then
          active_by_unit["$id"]=$state
          result_by_unit["$id"]=$service_result
        fi
        id="" state="" service_result="" ;;
    esac
  done <<<"$properties"$'\n'
  for unit in "${units[@]}"; do
    if [ -z "${active_by_unit[$unit]:-}" ] || [ -z "${result_by_unit[$unit]:-}" ]; then
      echo "unit-health: incomplete service properties for $unit; refusing an incomplete report" >&2
      exit 2
    fi
  done
  if ! counts=$(printf '%s\0' "${units[@]}" | xargs -0 -n 1 -P 8 \
      bash "$_SELF_DIR/lib/unit-health-journal.sh" "$SINCE"); then
    echo 'unit-health: journal collection failed; refusing an incomplete report' >&2
    exit 2
  fi
  while IFS=$'\t' read -r unit count; do
    [ -n "$unit" ] || continue
    failures_by_unit["$unit"]=$count
  done <<<"$counts"
fi

# --- per-unit health ---------------------------------------------------------
rows=""
problems=0
while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  if [ "$batched" -eq 1 ]; then
    active=${active_by_unit[$unit]}
    result=${result_by_unit[$unit]}
    fails=${failures_by_unit[$unit]:-0}
  else
    active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    result=$(systemctl --user show "$unit" -p Result --value 2>/dev/null || true)

    # awk succeeds when no lines match; pipefail still catches an unreadable
    # journal, including one that emitted records before failing.
    if ! fails=$(journalctl --user -u "$unit" --since "$SINCE" --no-pager -o cat \
        | awk 'index($0, "Failed with result") { n++ } END { print n+0 }'); then
      echo "unit-health: could not read journal for $unit; refusing an incomplete report" >&2
      exit 2
    fi
  fi

  cov=$(coverage_class "$unit")

  if [ "$THRESHOLD" -gt 0 ] && [ "$fails" -ge "$THRESHOLD" ]; then
    health=HOT_LOOP
  elif [ "$active" = "failed" ] || [ "$fails" -gt 0 ]; then
    health=FAILED
  else
    health=OK
  fi

  [ "$health" = "OK" ] || problems=$((problems + 1))
  printf -v rows '%s%s\t%s\t%s\t%s\t%s\t%s\n' "$rows" \
    "$unit" "$health" "$fails" "$cov" "${active:-unknown}" "${result:-none}"
done <"$units_file"

TAB=$(printf '\t')

json_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

# --- output ------------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "since": '
  json_string "$SINCE"
  printf ',\n'
  printf '  "threshold": %s,\n' "$THRESHOLD"
  printf '  "problems": %s,\n' "$problems"
  printf '  "units": [\n'
  separator=""
  while IFS=$'\t' read -r unit health fails cov active result; do
    [ -n "$unit" ] || continue
    printf '%s    {"unit": ' "$separator"
    json_string "$unit"
    printf ', "health": "%s", "failures": %s, "coverage": "%s", "active": "%s", "result": "%s"}' \
      "$health" "$fails" "$cov" "$active" "$result"
    separator=$',\n'
  done <<<"$rows"
  [ -z "$separator" ] || printf '\n'
  printf '  ]\n}\n'
else
  printf 'unit-health: window="%s" hot-loop threshold=%s\n\n' "$SINCE" "$THRESHOLD"
  {
    printf 'UNIT\tHEALTH\tFAILS\tCOVERAGE\tACTIVE\tRESULT\n'
    if [ "$QUIET" -eq 1 ]; then
      printf '%s' "$rows" | awk -F'\t' 'NF>1 && $2 != "OK"'
    else
      printf '%s' "$rows"
    fi
  } | column -t -s "$TAB"
  printf '\n'
  if [ "$problems" -eq 0 ]; then
    printf 'unit-health: OK — no failing or hot-looping units in window\n'
  else
    printf 'unit-health: %s unit(s) need attention\n' "$problems"
    printf '  HOT_LOOP + coverage=UNOWNED is the blind spot: failing hard, watched by nothing.\n'
    printf '  Inspect with: journalctl --user -u <unit> -n 30\n'
  fi
fi

[ "$problems" -eq 0 ] || exit 1
exit 0
