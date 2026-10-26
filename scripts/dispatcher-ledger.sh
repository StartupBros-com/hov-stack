#!/usr/bin/env bash
# dispatcher-ledger.sh: the machine-readable run ledger for the always-on
# work dispatcher (issue #444; plan docs/plans/2026-08-21-2308-...). JSONL,
# append-only, one row per run-lifecycle event -- run_id is the key and every
# state transition lands as a NEW row. Rows are never rewritten in place: an
# append-only ledger can only grow, never race a concurrent reader over an
# in-place edit.
#
# Path: $DISPATCHER_LEDGER_FILE, else $HOME/.claude/logs/dispatcher-ledger.jsonl
# (env seam mirrors DEFERRAL_WATCHLIST_FILE in deferral-watch.sh -- lets tests
# point the whole ledger at a scratch file instead of the operator's real log).
#
# Row shape: {fp:1, ts:<ISO8601 UTC, e.g. 2026-08-22T01:02:03Z>, run_id,
# issue, repo, branch, pr, event, ...}. event one of:
#   claimed  -- carries branch (the run's branch name, optional -- set by
#               dispatcher-tick.sh's dispatch step from wt-new.sh's own
#               branch field, issue #1428/U5, so a LATER tick's PR-discovery
#               poll can re-derive this run's repo+branch without re-deriving
#               either from anywhere else) and pr (the run's PR number,
#               optional -- and usually absent at claim time since issue
#               #1428: wt-new.sh now defers the PR to the branch's first
#               content push, R6 -- set by dispatcher-tick.sh's dispatch step
#               when a PR already exists, so a LATER tick's reconcile can
#               resolve this run's disposition from the PR's own
#               merge/close state) and config:{k, yield_max, ratchets}, the
#               gate snapshot at claim time, so a later ratchet flip never
#               retroactively reinterprets an old run's disposition.
#   launched -- carries pid (the run agent's process id; reconcile probes it).
#   pr-opened -- carries pr (required; usage error without it). Written when
#               a run's PR shows up AFTER its claimed row (issue #1428,
#               KTD5/AE4) -- dispatcher-tick.sh's build_pr_state and this
#               script's own reconcile snapshot both resolve a run's pr as
#               the first non-null pr across ALL of its rows, so a pr-opened
#               row is picked up exactly like a claimed row's pr would be.
#   ended    -- carries exit, window_cost_usd (number|null: the gateway's
#               spend over the run's window, every session in it, so an
#               upper bound; rows before dotfiles#1429 carry it as
#               cost_usd), tokens (number|null),
#               overlap (bool|null), cost_source:"ccflare-bracket", and --
#               ONLY when something killed the run mid-task (issue #562 for
#               the budget fence, #583 generalized) -- stopped:"budget" |
#               "background-tasks", plus -- ONLY when the run delivered no
#               commits (issue #583's empty-delivery backstop) -- empty:true.
#               A clean committing end carries neither key, so clean rows
#               and every pre-#562 row share one shape.
#   kept | waste | broken -- TERMINAL. FIRST-TERMINAL-WINS: once a run_id has
#               one of these, a second terminal append for the same run_id is
#               refused (exit 1, nothing written) -- disposition is decided
#               once, by whichever check (operator merge/close, or
#               reconcile's liveness probe) gets there first, never
#               overwritten by a later contradicting one.
#   ratchet-flip -- the audit row `audit-flip` appends: {fp, ts,
#               event:"ratchet-flip", ratchet, keep_rate, cost_per_kept}. No
#               run_id: this is a ledger-level audit event, not a run event.
#   audit-correction -- the repair row `audit-correction` appends (issue
#               #584): {fp, ts, run_id, event:"audit-correction",
#               voids:"broken", disposition?, reason}. Written when a run's
#               terminal row is provably wrong (the #584 reconcile bug
#               stamped clean-ended runs `broken` seconds after they
#               finished, before their PR verdict). Only a run that carries
#               an `ended` row can be corrected -- broken+ended is the
#               mis-mark signature; a never-ended broken run is presumed
#               genuinely broken. First-terminal-wins
#               stays intact: the wrong row is never rewritten and a second
#               terminal append stays refused -- summary folds the
#               correction in on top, so the run leaves the broken count
#               and is counted by the correction's disposition (kept|waste),
#               or as undispositioned while that disposition is pending.
#
# Subcommands (see each cmd_* function below for its own contract):
#   append      -- write one event row for a run.
#   summary     -- kept/waste/broken/undispositioned + cut-short (by
#                  reason) + empty-delivery counts, keep-rate,
#                  cost-per-kept over clean rows (a gateway-window upper
#                  bound, read from window_cost_usd or, on rows before
#                  dotfiles#1429, cost_usd), trailing dispatcher-flagged:N
#                  counter (mirrors spend-report.py's spend-flagged:N idiom).
#   reconcile   -- turn PR disposition + pid liveness + orphaned-claim age
#                  into terminal rows. Also disposes waste a run that ENDED
#                  but never got a pr: immediately for an empty delivery
#                  (empty:true, no pr), or once its ended row is older than
#                  --claim-ttl-hours (default 48) for a clean end with no pr
#                  (issue #1428, KTD5/AE4).
#   audit-flip  -- append a ratchet-flip audit row.
#   audit-correction -- append a correction row voiding a mis-marked
#                  terminal (issue #584; see the event list above).
#
# Readers parse tolerantly: read_rows() skips any line that doesn't parse as
# a JSON object, so one malformed line never crashes a summary or reconcile
# pass. Writers are best-effort-silent for CALLERS: mkdir -p the log dir,
# append one compact JSON line via `jq -cn`, and on any failure print a single
# diagnostic line and return/exit nonzero -- never an uncaught bash error that
# could abort a caller's own `set -e` flow.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/dispatcher-common.sh
. "$HERE/lib/dispatcher-common.sh"

LEDGER_FILE="$(dispatcher_ledger_file)"

# require_nonneg_int_flag <flag> <value>: reconcile's numeric flags feed bash
# `-gt` comparisons that would error out silently under 2>/dev/null and skip
# every disposition they guard (issue #444 F-J for --cadence-mins, issue
# #1428 KTD5/AE4 for --claim-ttl-hours), so a non-numeric or overflow-length
# value fails loud at the door instead: usage exit 64.
require_nonneg_int_flag() {
  case "$2" in
    ''|*[!0-9]*) echo "dispatcher-ledger: $1 must be a non-negative integer" >&2; exit 64 ;;
  esac
  [ "${#2}" -le 9 ] || { echo "dispatcher-ledger: $1 is implausibly large" >&2; exit 64; }
}

usage() {
  cat >&2 <<'EOF'
usage:
  dispatcher-ledger.sh append --event E --run-id ID
      [--issue N] [--repo R] [--branch B] [--pr N] [--pid P] [--exit N] [--cost X] [--tokens N]
      [--overlap true|false] [--stopped budget|background-tasks] [--empty true]
      [--config-k N] [--config-yield N] [--config-ratchets S]
  dispatcher-ledger.sh summary
  dispatcher-ledger.sh reconcile --pr-state FILE [--cadence-mins N] [--claim-ttl-hours N]
  dispatcher-ledger.sh audit-flip --ratchet NAME --keep-rate X --cost-per-kept Y
  dispatcher-ledger.sh audit-correction --run-id ID --voids broken [--disposition kept|waste] --reason TEXT

event enum: claimed | launched | ended | kept | waste | broken | pr-opened
EOF
  exit 64
}

# read_rows() is now shared -- see scripts/lib/dispatcher-common.sh.
# Called with no argument everywhere in this file, so it reads
# dispatcher_ledger_file() (same $DISPATCHER_LEDGER_FILE-or-default this
# script's own $LEDGER_FILE resolves to).

# How many terminal (kept/waste/broken) rows already exist for this run_id.
run_id_terminal_count() {
  local rid="$1" n
  n=$(read_rows | jq -s --arg rid "$rid" \
    '[ .[] | select(.run_id == $rid and (.event=="kept" or .event=="waste" or .event=="broken")) ] | length' \
    2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# mkdir -p the log dir and append one line. Never throws: any failure is a
# one-line stderr diagnostic plus a nonzero return, so callers using `||`
# (or ignoring the exit code entirely, per the best-effort-silent contract)
# never see a raw bash error.
write_row() {
  local row="$1" dir
  dir=$(dirname -- "$LEDGER_FILE")
  if ! mkdir -p -- "$dir" 2>/dev/null; then
    echo "dispatcher-ledger: cannot create log directory $dir" >&2
    return 1
  fi
  if ! printf '%s\n' "$row" >> "$LEDGER_FILE" 2>/dev/null; then
    echo "dispatcher-ledger: append failed (unwritable $LEDGER_FILE)" >&2
    return 1
  fi
  return 0
}

# do_append: the shared implementation behind the `append` subcommand AND
# reconcile's own transitions, so both paths validate and write identically
# -- reconcile is not a second, drifting copy of the first-terminal-wins
# logic.
do_append() {
  local event="" run_id="" issue="" repo="" branch="" pr="" pid="" exitc="" cost="" tokens="" overlap="" stopped="" empty="" ck="" cy="" cr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --event)           [ $# -ge 2 ] || usage; event="$2"; shift 2 ;;
      --run-id)          [ $# -ge 2 ] || usage; run_id="$2"; shift 2 ;;
      --issue)           [ $# -ge 2 ] || usage; issue="$2"; shift 2 ;;
      --repo)            [ $# -ge 2 ] || usage; repo="$2"; shift 2 ;;
      --branch)          [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
      --pr)              [ $# -ge 2 ] || usage; pr="$2"; shift 2 ;;
      --pid)             [ $# -ge 2 ] || usage; pid="$2"; shift 2 ;;
      --exit)            [ $# -ge 2 ] || usage; exitc="$2"; shift 2 ;;
      --cost)            [ $# -ge 2 ] || usage; cost="$2"; shift 2 ;;
      --tokens)          [ $# -ge 2 ] || usage; tokens="$2"; shift 2 ;;
      --overlap)         [ $# -ge 2 ] || usage; overlap="$2"; shift 2 ;;
      --stopped)         [ $# -ge 2 ] || usage; stopped="$2"; shift 2 ;;
      --empty)           [ $# -ge 2 ] || usage; empty="$2"; shift 2 ;;
      --config-k)        [ $# -ge 2 ] || usage; ck="$2"; shift 2 ;;
      --config-yield)    [ $# -ge 2 ] || usage; cy="$2"; shift 2 ;;
      --config-ratchets) [ $# -ge 2 ] || usage; cr="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$event" ] || { echo "dispatcher-ledger: append needs --event" >&2; exit 64; }
  [ -n "$run_id" ] || { echo "dispatcher-ledger: append needs --run-id" >&2; exit 64; }
  # run_id is the ledger's primary key and is round-tripped through @tsv in
  # reconcile's snapshot read; reject any value carrying whitespace, control
  # characters, or a backslash so a malformed key can never corrupt that
  # tab-delimited read or smuggle escape sequences into the JSONL (issue #444,
  # F-F). jq would escape these on the way in, but keeping them out of the
  # ledger entirely is the clean invariant -- a real run_id is a bare token.
  case "$run_id" in
    *[[:space:]]*|*[[:cntrl:]]*|*\\*)
      echo "dispatcher-ledger: --run-id contains whitespace, control chars, or a backslash -- refusing" >&2
      exit 64 ;;
  esac
  case "$event" in
    claimed|launched|ended|kept|waste|broken|pr-opened) ;;
    *) echo "dispatcher-ledger: unknown --event '$event' (want claimed|launched|ended|kept|waste|broken|pr-opened)" >&2; exit 64 ;;
  esac
  # pr-opened (issue #1428, KTD5/AE4): a run whose PR shows up AFTER its
  # claimed row -- the whole point of the event is to carry the pr, so a
  # pr-opened row with no --pr is a caller bug, failed loud at the door.
  if [ "$event" = "pr-opened" ] && [ -z "$pr" ]; then
    echo "dispatcher-ledger: --pr is required for --event pr-opened" >&2
    exit 64
  fi
  case "$overlap" in
    ''|true|false) ;;
    *) echo "dispatcher-ledger: --overlap must be true or false" >&2; exit 64 ;;
  esac
  # --stopped (issue #562, widened by #583): closed enum of known cut-short
  # reasons. Bound to `ended` rows only -- any other event claiming a stop is
  # a caller bug worth failing loud on at the door, never silently recording.
  # Unknown reasons are rejected on purpose: a new kill path earns its enum
  # value here (and a summary counter) before it may land in the ledger.
  case "$stopped" in
    ''|budget|background-tasks) ;;
    *) echo "dispatcher-ledger: --stopped must be 'budget' or 'background-tasks'" >&2; exit 64 ;;
  esac
  if [ -n "$stopped" ] && [ "$event" != "ended" ]; then
    echo "dispatcher-ledger: --stopped is only valid with --event ended" >&2
    exit 64
  fi
  # --empty (issue #583): the empty-delivery backstop's ledger surface. Only
  # `true` is accepted -- a run that delivered commits omits the flag
  # entirely, so clean committing rows never grow the key and pre-#583 rows
  # parse identically.
  case "$empty" in
    ''|true) ;;
    *) echo "dispatcher-ledger: --empty must be 'true' (omit the flag for a run that delivered commits)" >&2; exit 64 ;;
  esac
  if [ -n "$empty" ] && [ "$event" != "ended" ]; then
    echo "dispatcher-ledger: --empty is only valid with --event ended" >&2
    exit 64
  fi

  # first-terminal-wins is a read-then-write invariant: run_id_terminal_count
  # reads the ledger, then write_row appends -- and two concurrent do_append
  # calls for the same run_id (reconcile racing an operator-driven append, say)
  # could BOTH pass the terminal check before either writes, landing two
  # terminal rows and breaking the invariant. Serialize the whole
  # check -> build -> write window under an flock so at most one writer is ever
  # inside it (issue #444, F-G). _ledger_write reads do_append's locals via
  # bash dynamic scope (it is called only from here) and uses `return`, so its
  # status flows out as the subshell's exit status and then do_append's return.
  local ledger_dir lockfile
  ledger_dir=$(dirname -- "$LEDGER_FILE")
  mkdir -p -- "$ledger_dir" 2>/dev/null || true
  lockfile="$LEDGER_FILE.lock"

  _ledger_write() {
    case "$event" in
      kept|waste|broken)
        local n
        n=$(run_id_terminal_count "$run_id") || n=0
        if [ "${n:-0}" -gt 0 ]; then
          echo "dispatcher-ledger: run $run_id already has a terminal row -- first-terminal-wins, refusing to append '$event'" >&2
          return 1
        fi
        ;;
    esac

    local ts row
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    row=$(jq -cn \
      --argjson fp 1 \
      --arg ts "$ts" --arg run_id "$run_id" --arg event "$event" \
      --arg issue "$issue" --arg repo "$repo" --arg branch "$branch" --arg pr "$pr" --arg pid "$pid" --arg exitc "$exitc" \
      --arg cost "$cost" --arg tokens "$tokens" --arg overlap "$overlap" \
      --arg stopped "$stopped" --arg empty "$empty" \
      --arg ck "$ck" --arg cy "$cy" --arg cr "$cr" '
        def num(x): if x == "" then null else (x | tonumber) end;
        def str(x): if x == "" then null else x end;
        {fp: $fp, ts: $ts, run_id: $run_id, issue: num($issue), repo: str($repo), branch: str($branch), pr: num($pr), event: $event}
        + (if $event == "claimed" then
              {config: {k: num($ck), yield_max: num($cy), ratchets: str($cr)}}
            else {} end)
        + (if $event == "launched" then
              {pid: num($pid)}
            else {} end)
        + (if $event == "ended" then
              {exit: num($exitc), window_cost_usd: num($cost), tokens: num($tokens),
               overlap: (if $overlap == "" then null else ($overlap == "true") end),
               cost_source: "ccflare-bracket"}
              + (if $stopped == "" then {} else {stopped: $stopped} end)
              + (if $empty == "" then {} else {empty: true} end)
            else {} end)
      ' 2>/dev/null) || { echo "dispatcher-ledger: failed to build row JSON for event '$event' (bad numeric arg?)" >&2; return 1; }

    write_row "$row"
  }

  # Fail-OPEN: a missing flock binary, a lock fd we can't even open, or a lock
  # we can't take within the timeout all still run the append -- the ledger is
  # best-effort by contract (write_row never throws), so a locking hiccup must
  # degrade to the old unlocked path, never block or drop a run's event row.
  #
  # The `: 2>/dev/null 9>"$lockfile"` probe matters: when the ledger DIR is
  # unwritable -- the very failure write_row must report with its own one-line
  # diagnostic -- opening the .lock fd fails too. Probing first (with the `:`
  # builtin, not `exec`, so a failed redirect can never exit the shell) lets us
  # fall straight through to the unlocked write, where write_row still fires
  # its diagnostic, instead of the subshell redirect swallowing it. The
  # `|| true` keeps a -w timeout from short-circuiting the locked section; on
  # that path the residual race window is exactly the pre-fix behavior.
  if command -v flock >/dev/null 2>&1 && : 2>/dev/null 9>"$lockfile"; then
    ( flock -w 5 9 || true; _ledger_write ) 9>"$lockfile"
  else
    _ledger_write
  fi
}

cmd_append() { do_append "$@"; }

# summary: computes disposition counts and cost over ALL run_ids ever seen in
# the ledger, plus surfaces any ratchet-flip audit rows and warns (does not
# crash) on a run_id whose rows never include a `claimed` row.
# Audit-correction rows (issue #584) are folded in here: a run whose terminal
# row is voided by a correction leaves the broken count and is counted by the
# correction's disposition instead (or as undispositioned while that
# disposition is still pending); `audit-corrected: N` names how many runs
# carry a correction, and each correction row is surfaced like ratchet-flips.
cmd_summary() {
  [ $# -eq 0 ] || usage
  local now_epoch
  now_epoch=$(date -u +%s)

  local jq_prog
  read -r -d '' jq_prog <<'JQEOF' || true
. as $all
| [ $all[] | select(.run_id != null) ] as $runrows
| ( $runrows
    | group_by(.run_id)
    | map(. as $g
        # raw terminal: the FIRST kept/waste/broken row, exactly as before.
        | ( ($g | map(select(.event=="kept" or .event=="waste" or .event=="broken")) | .[0].event) // null ) as $term
        # audit-correction overlay (issue #584): a correction row whose
        # .voids names this run's raw terminal voids it; the run then counts
        # by the first disposition any of its corrections carry, or as
        # undispositioned while that disposition is still pending. The
        # terminal ROW itself is untouched -- first-terminal-wins governs
        # the event stream, corrections govern only how summary counts it.
        | ( $g | map(select(.event=="audit-correction")) | sort_by(.ts) ) as $corr
        | ( [ $corr[] | select(.voids == $term) ] ) as $voiding
        | {
            run_id: $g[0].run_id,
            earliest_ts: ($g | map(.ts) | min),
            events: ($g | map(.event) | unique),
            corrected: ($term != null and ($voiding | length) > 0),
            terminal: ( if $term != null and ($voiding | length) > 0
                        then ([ $voiding[] | .disposition | select(. != null) ] | .[0])
                        else $term end ),
            ended: ( ($g | map(select(.event=="ended")) | .[-1]) // null )
          })
  ) as $runs
| ($runs | map(select(.terminal=="kept")) | length) as $kept
| ($runs | map(select(.terminal=="waste")) | length) as $waste
| ($runs | map(select(.terminal=="broken")) | length) as $broken
| ($runs | map(select(.terminal==null))) as $undisp
| ($undisp | length) as $undisp_count
| ( $undisp | map( ($now - (.earliest_ts | fromdateiso8601)) / 3600.0 ) ) as $undisp_ages
| ( if ($undisp_ages | length) > 0 then ($undisp_ages | max) else null end ) as $oldest_age
| ( [ $undisp_ages[] | select(. > 24) ] | length ) as $stale_undisp
| ( $runs | map(select(.ended != null and (.ended.stopped // null) != null)) ) as $cutshort
| ( $cutshort | length ) as $cut_n
| ( $cutshort | map(select(.ended.stopped == "budget")) | length ) as $cut_budget
| ( $cutshort | map(select(.ended.stopped == "background-tasks")) | length ) as $cut_bg
| ( $cut_n - $cut_budget - $cut_bg ) as $cut_other
| ( $runs | map(select(.ended != null and (.ended.empty // false) == true)) | length ) as $empty_n
| ($runs | map(select(.terminal=="kept"))) as $keptruns
| ( $keptruns | map(select(.ended != null and .ended.overlap == false and (.ended.window_cost_usd // .ended.cost_usd) != null)) ) as $clean
| ( $clean | length ) as $clean_n
| ( (($clean | map(.ended.window_cost_usd // .ended.cost_usd) | add)) // 0 ) as $clean_sum
| ( $kept - $clean_n ) as $contaminated
| ( $runs | map(select((.events | index("claimed")) == null)) | map(.run_id) ) as $no_claim
| ( [ $all[] | select(.event=="ratchet-flip") ] | sort_by(.ts) ) as $audit_rows
| ( [ $all[] | select(.event=="audit-correction") ] | sort_by(.ts) ) as $corr_rows
| ( $runs | map(select(.corrected)) | length ) as $corrected_n
| ( $broken + $stale_undisp ) as $flagged
| "kept: \($kept)   waste: \($waste)   broken: \($broken)",
  ( "undispositioned: \($undisp_count) (oldest: "
    + (if $oldest_age == null then "n/a" else "\(($oldest_age * 10 | round) / 10)h" end)
    + ")" ),
  ( "cut-short: \($cut_n) (budget: \($cut_budget), background-tasks: \($cut_bg)"
    + (if $cut_other > 0 then ", other: \($cut_other)" else "" end)
    + ")" ),
  ( "empty-delivery: \($empty_n)" ),
  ( "audit-corrected: \($corrected_n)" ),
  ( "keep-rate: "
    + (if ($kept + $waste) > 0
        then "\((($kept / ($kept + $waste)) * 1000 | round) / 10)% (\($kept)/\($kept + $waste))"
        else "n/a" end) ),
  ( "cost-per-kept (clean, gateway window, upper bound): "
    + (if $clean_n > 0
        then "$\((($clean_sum / $clean_n) * 100 | round) / 100) (n=\($clean_n))"
        else "n/a" end)
    + "   contaminated-kept: \($contaminated)" ),
  ( $no_claim[] | "WARN dispatcher-ledger: run \(.) has a transition row but no claimed row" ),
  ( $audit_rows[] | "ratchet-flip: \(.ratchet) keep_rate=\(.keep_rate) cost_per_kept=\(.cost_per_kept) at \(.ts)" ),
  ( $corr_rows[] | "audit-correction: run \(.run_id) voided \(.voids)"
      + (if .disposition != null then " -> \(.disposition)" else " (awaiting disposition)" end)
      + " at \(.ts)" ),
  "dispatcher-flagged:\($flagged)"
JQEOF

  read_rows | jq -s -r --argjson now "$now_epoch" "$jq_prog"
}

# reconcile: turns PR-state and process-liveness facts into terminal rows.
#   --pr-state FILE   TSV run_id<TAB>pr_state, pr_state in merged|closed|open.
#                      merged -> kept, closed -> waste, open -> no-op.
#   --cadence-mins N   (default 20) a `claimed` row with no `launched`
#                      sibling older than this, and still non-terminal, is
#                      `broken` (the claim never turned into a run).
# A run with an `ended` row is exempt from BOTH liveness rules (issue #584):
# it completed -- a gone pid is its expected state, not evidence of breakage
# -- so it stays non-terminal, awaiting its PR verdict via --pr-state,
# however many ticks that takes.
# Every transition (including ones do_append refuses under first-terminal-
# wins) is attempted through do_append, so the SAME refusal logic governs
# both the CLI `append` path and reconcile's own writes; only successful
# appends print a transition line.
cmd_reconcile() {
  local pr_state_file="" cadence_mins=20 claim_ttl_hours=48
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr-state)      [ $# -ge 2 ] || usage; pr_state_file="$2"; shift 2 ;;
      --cadence-mins)  [ $# -ge 2 ] || usage
                       # Feeds `[ "$age_mins" -gt "$cadence_mins" ]` below.
                       require_nonneg_int_flag --cadence-mins "$2"
                       cadence_mins="$2"; shift 2 ;;
      --claim-ttl-hours) [ $# -ge 2 ] || usage
                       # Feeds `[ "$ended_age_hours" -gt "$claim_ttl_hours" ]`
                       # in step 4 below (the no-pr-after-ttl rule).
                       require_nonneg_int_flag --claim-ttl-hours "$2"
                       claim_ttl_hours="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$pr_state_file" ] || { echo "dispatcher-ledger: reconcile needs --pr-state FILE" >&2; exit 64; }
  [ -f "$pr_state_file" ] || { echo "dispatcher-ledger: pr-state file not found: $pr_state_file" >&2; exit 64; }

  local now_epoch
  now_epoch=$(date -u +%s)

  # 1) PR-state driven dispositions (merged -> kept, closed -> waste).
  local rid state ev
  while IFS=$'\t' read -r rid state || [ -n "$rid" ]; do
    case "$rid" in ''|\#*) continue ;; esac
    case "$state" in
      merged) ev=kept ;;
      closed) ev=waste ;;
      open)   continue ;;
      *) echo "dispatcher-ledger: reconcile: unknown pr_state '$state' for $rid, skipping" >&2; continue ;;
    esac
    if do_append --event "$ev" --run-id "$rid"; then
      echo "$rid -> $ev"
    fi
  done < "$pr_state_file"

  # 2) Dead-pid launched runs, and 3) orphaned claims older than cadence --
  # both scoped to run_ids that are STILL non-terminal after step 1.
  #
  # FIX7 (perf, no behavior change): this used to re-read the whole ledger
  # from disk up to 4x PER run_id (run_id_terminal_count, a launched-count
  # probe, a last-launched-pid probe, a first-claimed-ts probe) -- O(run_ids
  # x ledger size). Everything the loop below needs is now computed in ONE
  # upfront jq pass over the ledger (taken AFTER step 1's appends, so it
  # sees exactly the picture the old per-run_id reads would have) and handed
  # to a pure-bash loop that never touches the ledger file again. Two facts
  # make that substitution safe:
  #   - a run_id's own data can only change here via THIS loop's own
  #     do_append for that SAME run_id, which always happens strictly after
  #     that run_id's row was already read out of the snapshot below --
  #     the same order the old per-run_id reads observed.
  #   - do_append only ever writes a row tagged with the run_id it was
  #     called for, so no run_id's snapshot can be invalidated by another
  #     run_id's processing earlier in this same loop.
  # has_launched is an explicit boolean (any launched row at all for this
  # run_id), NOT inferred from latest_event: a run that reached
  # claimed->launched->ended (still non-terminal) has latest_event "ended",
  # yet the ORIGINAL code's `launched_count -gt 0` check still takes the
  # dead-pid branch for it. Collapsing that into "latest_event == launched"
  # would silently change behavior for exactly that run shape, so
  # has_launched is carried as its own field instead. has_ended follows the
  # same explicit-boolean pattern (issue #584): any ended row at all, however
  # the run got there. latest_event and pr
  # are carried through per the tuple shape even though this loop doesn't
  # branch on them, for parity with what a caller reading the ledger
  # would expect the snapshot to contain.
  #
  # Nullable fields (launched_pid, claimed_ts, pr) are emitted as the
  # sentinel "-" rather than an empty string. `read` with IFS set to a pure
  # whitespace character (tab is one, even as the sole IFS byte) collapses
  # RUNS of that delimiter and strips them at field boundaries exactly like
  # $IFS word-splitting does -- so a genuinely empty middle field (e.g. no
  # launched row -> empty launched_pid) silently vanishes and shifts every
  # later column left by one instead of reading as "". Never emitting an
  # empty field sidesteps that collapse entirely; "-" is translated back to
  # "" immediately after the read.
  local rid2 terminal_count latest_event has_launched has_ended launched_pid claimed_ts pr_val age_mins
  while IFS=$'\t' read -r rid2 terminal_count latest_event has_launched has_ended launched_pid claimed_ts pr_val || [ -n "$rid2" ]; do
    [ -n "$rid2" ] || continue
    [ "$launched_pid" = "-" ] && launched_pid=""
    [ "$claimed_ts" = "-" ] && claimed_ts=""
    [ "${terminal_count:-0}" -gt 0 ] && continue
    # Issue #584: a run with an `ended` row COMPLETED -- its pid being gone
    # is the expected state, and its claim obviously turned into a run. It is
    # awaiting its PR verdict (step 1 disposes it once the PR is merged or
    # closed), so neither the dead-pid rule nor the orphaned-claim age rule
    # below may touch it. The pid probe exists ONLY for a run whose process
    # died without ever writing `ended` (box reboot, OOM kill, kill -9) --
    # that case has no ended row and still lands `broken` below.
    [ "$has_ended" = "true" ] && continue

    if [ "$has_launched" = "true" ]; then
      if [ -n "$launched_pid" ] && ! kill -0 "$launched_pid" 2>/dev/null; then
        if do_append --event broken --run-id "$rid2"; then
          echo "$rid2 -> broken (dead pid $launched_pid)"
        fi
      fi
    else
      if [ -n "$claimed_ts" ]; then
        age_mins=$(jq -n --arg ts "$claimed_ts" --argjson now "$now_epoch" \
          '(($now - ($ts | fromdateiso8601)) / 60) | floor' 2>/dev/null) || age_mins=""
        if [ -n "$age_mins" ] && [ "$age_mins" -gt "$cadence_mins" ] 2>/dev/null; then
          if do_append --event broken --run-id "$rid2"; then
            echo "$rid2 -> broken (orphaned claim, ${age_mins}m old)"
          fi
        fi
      fi
    fi
  done < <(read_rows | jq -r -s '
      [ .[] | select(.run_id != null) ]
      | group_by(.run_id)
      | map({
          run_id: .[0].run_id,
          terminal_count: ([ .[] | select(.event=="kept" or .event=="waste" or .event=="broken") ] | length),
          latest_event: ( max_by(.ts) | .event ),
          has_launched: ( ([ .[] | select(.event=="launched") ] | length) > 0 ),
          has_ended: ( ([ .[] | select(.event=="ended") ] | length) > 0 ),
          launched_pid: ( [ .[] | select(.event=="launched") ] | last | .pid ),
          claimed_ts: ( [ .[] | select(.event=="claimed") ] | first | .ts ),
          pr: ( [ .[] | select(.pr != null) ] | first | .pr )
        })
      | .[]
      | [ .run_id, (.terminal_count|tostring), (.latest_event // "-"), (.has_launched|tostring),
          (.has_ended|tostring),
          ((.launched_pid // "-")|tostring), (.claimed_ts // "-"), ((.pr // "-")|tostring) ]
      | @tsv
    ')

  # 4) Terminal disposition for runs that ended without ever getting a pr
  # (issue #1428, KTD5/AE4) -- independent of steps 2/3 above (which are
  # scoped to launched-liveness and claim-age, and explicitly skip any run
  # with an ended row, per the #584 exemption a few lines up). This step is
  # the mirror image: it ONLY looks at runs that DID end, and only those
  # that never got a pr on any row. Two sub-rules, first-terminal-wins
  # still enforced via the terminal_count>0 skip below (re-read fresh here,
  # AFTER steps 1-3's own appends, so a run either of those just
  # terminalized is correctly skipped rather than double-disposed):
  #   - an empty delivery (ended --empty true, issue #583) with no pr is
  #     unambiguous waste -- there is nothing left to wait for, so dispose
  #     it immediately rather than parking it for --claim-ttl-hours.
  #   - a clean end (no --empty) with no pr might still be waiting on a
  #     human to open the PR from already-pushed commits, so it only
  #     disposes once its ended row is older than --claim-ttl-hours.
  # pr is resolved the same way as step 2/3 and as dispatcher-tick.sh's
  # build_pr_state: the first non-null pr across ALL of the run's rows, so
  # a pr-opened row (or a claimed --pr) both count as "got a pr" here.
  local rid3 terminal_count3 has_ended3 empty3 ended_ts3 pr_val3 ended_age_hours
  while IFS=$'\t' read -r rid3 terminal_count3 has_ended3 empty3 ended_ts3 pr_val3 || [ -n "$rid3" ]; do
    [ -n "$rid3" ] || continue
    [ "$ended_ts3" = "-" ] && ended_ts3=""
    [ "${terminal_count3:-0}" -gt 0 ] && continue
    [ "$has_ended3" = "true" ] || continue
    [ "$pr_val3" = "-" ] || continue
    if [ "$empty3" = "true" ]; then
      if do_append --event waste --run-id "$rid3"; then
        echo "$rid3 -> waste (empty-delivery-no-pr)"
      fi
      continue
    fi
    [ -n "$ended_ts3" ] || continue
    ended_age_hours=$(jq -n --arg ts "$ended_ts3" --argjson now "$now_epoch" \
      '(($now - ($ts | fromdateiso8601)) / 3600) | floor' 2>/dev/null) || ended_age_hours=""
    if [ -n "$ended_age_hours" ] && [ "$ended_age_hours" -gt "$claim_ttl_hours" ] 2>/dev/null; then
      if do_append --event waste --run-id "$rid3"; then
        echo "$rid3 -> waste (no-pr-after-ttl, ${ended_age_hours}h old)"
      fi
    fi
  done < <(read_rows | jq -r -s '
      [ .[] | select(.run_id != null) ]
      | group_by(.run_id)
      | map({
          run_id: .[0].run_id,
          terminal_count: ([ .[] | select(.event=="kept" or .event=="waste" or .event=="broken") ] | length),
          has_ended: ( ([ .[] | select(.event=="ended") ] | length) > 0 ),
          empty: ( [ .[] | select(.event=="ended") ] | last | (.empty // false) ),
          ended_ts: ( [ .[] | select(.event=="ended") ] | last | .ts ),
          pr: ( [ .[] | select(.pr != null) ] | first | .pr )
        })
      | .[]
      | [ .run_id, (.terminal_count|tostring), (.has_ended|tostring), (.empty|tostring),
          ((.ended_ts // "-")|tostring), ((.pr // "-")|tostring) ]
      | @tsv
    ')

  return 0
}

cmd_audit_flip() {
  local ratchet="" keep_rate="" cost_per_kept=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ratchet)       [ $# -ge 2 ] || usage; ratchet="$2"; shift 2 ;;
      --keep-rate)     [ $# -ge 2 ] || usage; keep_rate="$2"; shift 2 ;;
      --cost-per-kept) [ $# -ge 2 ] || usage; cost_per_kept="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$ratchet" ]       || { echo "dispatcher-ledger: audit-flip needs --ratchet NAME" >&2; exit 64; }
  [ -n "$keep_rate" ]     || { echo "dispatcher-ledger: audit-flip needs --keep-rate X" >&2; exit 64; }
  [ -n "$cost_per_kept" ] || { echo "dispatcher-ledger: audit-flip needs --cost-per-kept Y" >&2; exit 64; }

  local ts row
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  row=$(jq -cn \
    --argjson fp 1 --arg ts "$ts" --arg ratchet "$ratchet" \
    --arg kr "$keep_rate" --arg cpk "$cost_per_kept" '
      {fp: $fp, ts: $ts, event: "ratchet-flip", ratchet: $ratchet,
       keep_rate: ($kr | tonumber), cost_per_kept: ($cpk | tonumber)}
    ' 2>/dev/null) || { echo "dispatcher-ledger: failed to build audit-flip row (non-numeric --keep-rate/--cost-per-kept?)" >&2; return 1; }

  write_row "$row"
}

# audit-correction (issue #584): the repair path for a run whose TERMINAL row
# is provably wrong (the #584 reconcile dead-pid bug stamped clean-ended runs
# `broken` seconds after they finished, before their PR verdict).
# First-terminal-wins is deliberately NOT weakened: the wrong terminal row
# stays in history, a second terminal append stays refused, and the
# correction lands as a NEW audit row that summary folds in on top -- the
# ledger ends up telling the truth without rewriting history in place.
#
# `--disposition kept|waste` is given only when the run's PR verdict is
# already known; a dispositionless correction leaves the run counted as
# undispositioned (awaiting verdict) and is completed later by a SECOND
# correction row carrying the disposition. Refusals mirror
# first-terminal-wins (exit 1, nothing written): no matching terminal row to
# void; a prior correction already carrying a disposition (first disposition
# wins); a duplicate dispositionless correction; a run with NO ended row
# (the mis-mark signature is broken+ended -- a never-ended broken run is
# presumed genuinely broken, and correcting it would falsify the keep-rate).
cmd_audit_correction() {
  local run_id="" voids="" disposition="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id)      [ $# -ge 2 ] || usage; run_id="$2"; shift 2 ;;
      --voids)       [ $# -ge 2 ] || usage; voids="$2"; shift 2 ;;
      --disposition) [ $# -ge 2 ] || usage; disposition="$2"; shift 2 ;;
      --reason)      [ $# -ge 2 ] || usage; reason="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$run_id" ] || { echo "dispatcher-ledger: audit-correction needs --run-id" >&2; exit 64; }
  [ -n "$reason" ] || { echo "dispatcher-ledger: audit-correction needs --reason (an unexplained correction is just a quieter rewrite)" >&2; exit 64; }
  # Same run_id charset guard as do_append (issue #444, F-F): this key is
  # round-tripped through @tsv in reconcile's snapshot read.
  case "$run_id" in
    *[[:space:]]*|*[[:cntrl:]]*|*\\*)
      echo "dispatcher-ledger: --run-id contains whitespace, control chars, or a backslash -- refusing" >&2
      exit 64 ;;
  esac
  # Closed enum, one value today (mirrors --stopped budget): the only known
  # mis-mark producer is the #584 dead-pid bug, which only ever wrote
  # `broken`. Widening this to void a kept/waste row would let corrections
  # rewrite OPERATOR verdicts -- that stays refused until a real case earns
  # it.
  case "$voids" in
    broken) ;;
    *) echo "dispatcher-ledger: --voids must be 'broken'" >&2; exit 64 ;;
  esac
  case "$disposition" in
    ''|kept|waste) ;;
    *) echo "dispatcher-ledger: --disposition must be kept or waste" >&2; exit 64 ;;
  esac

  local ledger_dir lockfile
  ledger_dir=$(dirname -- "$LEDGER_FILE")
  mkdir -p -- "$ledger_dir" 2>/dev/null || true
  lockfile="$LEDGER_FILE.lock"

  # Read-then-write under the same flock discipline (and the same fail-OPEN
  # fallback) as do_append: every refusal check below reads the ledger, and
  # two concurrent corrections for the same run must not both land.
  _correction_write() {
    local st
    st=$(read_rows | jq -s --arg rid "$run_id" -c '
        [ .[] | select(.run_id == $rid) ] as $rows
        | { terminal: ( ($rows | map(select(.event=="kept" or .event=="waste" or .event=="broken")) | .[0].event) // null ),
            has_ended: ( ($rows | map(select(.event=="ended")) | length) > 0 ),
            corr_total: ( $rows | map(select(.event=="audit-correction")) | length ),
            corr_with_disp: ( $rows | map(select(.event=="audit-correction" and .disposition != null)) | length ) }
      ' 2>/dev/null) || st=""
    [ -n "$st" ] || { echo "dispatcher-ledger: audit-correction could not read the ledger" >&2; return 1; }
    local terminal has_ended corr_total corr_with_disp
    terminal=$(printf '%s' "$st" | jq -r '.terminal // ""' 2>/dev/null)
    has_ended=$(printf '%s' "$st" | jq -r '.has_ended' 2>/dev/null)
    corr_total=$(printf '%s' "$st" | jq -r '.corr_total' 2>/dev/null)
    corr_with_disp=$(printf '%s' "$st" | jq -r '.corr_with_disp' 2>/dev/null)
    if [ "$terminal" != "$voids" ]; then
      echo "dispatcher-ledger: run $run_id has no '$voids' terminal row to void (terminal: ${terminal:-none}) -- refusing" >&2
      return 1
    fi
    # The mis-mark signature is broken + ended (inward-vet finding, 2026-08-28):
    # a run with NO ended row died without completing, so its broken verdict
    # is presumed TRUE -- accepting a correction here would let a typo (or a
    # bad actor) recast a genuine crash as kept and falsify the keep-rate.
    if [ "$has_ended" != "true" ]; then
      echo "dispatcher-ledger: run $run_id has no ended row -- a run that never ended is presumed genuinely broken, not mis-marked; refusing" >&2
      return 1
    fi
    if [ "${corr_with_disp:-0}" -gt 0 ] 2>/dev/null; then
      echo "dispatcher-ledger: run $run_id already has a disposition-carrying correction -- first disposition wins, refusing" >&2
      return 1
    fi
    if [ -z "$disposition" ] && [ "${corr_total:-0}" -gt 0 ] 2>/dev/null; then
      echo "dispatcher-ledger: run $run_id already has a pending correction awaiting disposition -- refusing a duplicate" >&2
      return 1
    fi

    local ts row
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # disposition is an absent KEY when not yet known (never null), mirroring
    # the `stopped` precedent: pending rows and completed rows stay two
    # cleanly distinguishable shapes.
    row=$(jq -cn \
      --argjson fp 1 --arg ts "$ts" --arg run_id "$run_id" \
      --arg voids "$voids" --arg disposition "$disposition" --arg reason "$reason" '
        {fp: $fp, ts: $ts, run_id: $run_id, event: "audit-correction", voids: $voids}
        + (if $disposition == "" then {} else {disposition: $disposition} end)
        + {reason: $reason}
      ' 2>/dev/null) || { echo "dispatcher-ledger: failed to build audit-correction row" >&2; return 1; }

    write_row "$row"
  }

  if command -v flock >/dev/null 2>&1 && : 2>/dev/null 9>"$lockfile"; then
    ( flock -w 5 9 || true; _correction_write ) 9>"$lockfile"
  else
    _correction_write
  fi
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] && shift
  case "$cmd" in
    append)      cmd_append "$@" ;;
    summary)     cmd_summary "$@" ;;
    reconcile)   cmd_reconcile "$@" ;;
    audit-flip)  cmd_audit_flip "$@" ;;
    audit-correction) cmd_audit_correction "$@" ;;
    ''|-h|--help) usage ;;
    *) echo "dispatcher-ledger: unknown subcommand '$cmd'" >&2; usage ;;
  esac
}

main "$@"
exit $?
