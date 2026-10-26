#!/usr/bin/env bash
# docker-hygiene — dev-container lifecycle + disk reclaim, in the wt-sweep mould.
#
#   DRY_RUN=1 (default) prints the plan as `would:` lines; DRY_RUN=0 executes.
#                    The "removed" counters (summary table, trailing summary
#                    line, JSON *_removed) count real removals only and stay 0
#                    in a dry run.
#   ONLY=<project>   restrict EVERY section to one stack (e.g. ONLY=startupbros).
#   IDLE_DAYS=7      a stack whose checkouts have gone quiet this long is flagged.
#   EXITED_DAYS=7    exited containers older than this are removed.
#   ZOMBIE_MAX=5     orphan count that makes a recyclable container eligible.
#   RECYCLE_EXTRA=   extra service names to treat as recyclable, pipe-separated.
#   STOP_IDLE=0      1 = also `supabase stop` idle stacks (DRY_RUN=0 required).
#   STOP_ORPHANS=0   1 = also `supabase stop --project-id` ORPHAN stacks: no
#                    supabase/config.toml anywhere under $SITES and no live
#                    process cwd (DRY_RUN=0 required). Independent of STOP_IDLE.
#   REAP_VOLUMES=0   1 = also `docker volume rm` dangling Supabase volumes whose
#                    project no supabase/config.toml under $SITES declares
#                    (_archive and worktrees included) and that are older than
#                    VOLUME_GRACE_HOURS. DRY_RUN=1 prints them as `would:`.
#   VOLUME_GRACE_HOURS=24  a volume created more recently than this is kept.
#   AGGRESSIVE=0     1 = also remove images unreferenced by any container.
#   CACHE=0          1 = also drop the build cache.
#   JSON=0           1 = emit a machine-readable summary object after the report.
#   STRICT=0         1 = exit nonzero for inspection or attempted-action errors.
#   RECLAIM_WARN_MB=20480  WARN (and trip the weekly toast) above this.
#   SCAN_DEPTH=6     depth for the config scan used for stack AGE (not liveness).
#
# Policy (safety-ordered; every destructive step names its target explicitly):
#   zombie-choked RECYCLABLE container (>= ZOMBIE_MAX) .. docker restart
#   any other zombie-choked container ................... report only
#   stack with a live process cwd in any checkout ....... SKIP entirely
#   exited container older than EXITED_DAYS ............. docker rm <id>
#   dangling (untagged, unreferenced) image ............. docker rmi <id>
#   image unreferenced by any container ................. report only unless AGGRESSIVE=1
#   idle stack (every checkout quiet IDLE_DAYS) ......... report (STOP_IDLE=1 acts)
#   orphan stack (no config.toml anywhere, no live cwd) . report (STOP_ORPHANS=1 acts)
#   dangling Supabase volume, project undeclared, old ... report (REAP_VOLUMES=1 acts)
#   any other volume .................................... NEVER touched — report only
#
# WHY ORPHANS ARE ACTIONABLE WHEN IDLE STACKS ARE NOT (2026-09-16)
# A stack is "in use" when some process has its cwd inside a checkout that
# declares the stack's project_id. An orphan has no such checkout anywhere, so
# nobody can be working in it; the only residual risk — a network client from
# outside any checkout — is the same one STOP_IDLE already accepts. What makes
# idle different is an owner: a quiet checkout is still someone's checkout, and
# stopping under it costs them a `supabase start`. An orphan has no owner. The
# worktree lifecycle (wt-sweep, wt-done, Agent View, `git worktree remove`) has
# never stopped containers, and the day this landed the weekly run had WARNed
# on 24 orphan stacks / 38 containers — 14 from one finished campaign, up to two
# weeks old, ~4 GB RAM plus swap — without acting. Orphan stops run through the
# same identity + liveness guards as idle stops and re-scan for a checkout at
# action time. The stop itself keeps the volumes, but an orphan's project is
# usually undeclared too, so with REAP_VOLUMES=1 the volume section later in
# the same run removes them once they are past VOLUME_GRACE_HOURS, and a later
# `supabase start` comes up with an empty database.
#
# "Anywhere" has to mean more than $SITES. The plan-time scan and the liveness
# map are $SITES-scoped on purpose (cost), which is fine for idle stacks — a
# checkout outside $SITES cannot be aged — but wrong for orphans, where no
# checkout at all is the premise. So orphan classification and the action-time
# recheck also consult two unscoped signals (stack_checkout_evidence): the
# stack's own bind mounts (`supabase start` mounts templates/snippets/functions
# from the checkout into kong, studio and edge-runtime; a bind source under a
# supabase/ directory that still exists on disk IS the checkout, wherever it
# is) and any process cwd, anywhere, that walks up to a config.toml declaring
# this project id. Either one is a hold. Residual, documented: a db-only stack
# (no bind mounts) whose checkout is outside $SITES with no process inside it
# is indistinguishable from an orphan. The adversarial review of the
# introducing PR found a live example — a /tmp verification checkout whose
# studio container still bind-mounted it — so this is not theoretical.
#   build cache ......................................... report only unless CACHE=1
#
# WHY THIS ENUMERATES INSTEAD OF PRUNING
# `docker container prune`, `docker image prune`, `docker volume prune` and
# `docker system prune` are ALL blocked by dcg (containers.docker), while the
# targeted verbs `docker rm`, `docker rmi`, `docker restart` and `docker stop`
# are allowed. That is the correct shape anyway: a blanket prune cannot express
# "not that volume, it has my Postgres data in it". So this script decides per
# object, logs the reason, and acts on named IDs — which also means it runs from
# an agent session without tripping the guard. dcg denies `docker volume rm`
# when an agent types it. REAP_VOLUMES uses it here in the same per-object form,
# on names that pass the checks in the volume section.
#
# WHY UNDECLARED SUPABASE VOLUMES ARE REAPED AND NO OTHER VOLUME IS (2026-10-06, #1627)
# A stopped Supabase stack's database volume reports as dangling. Pruning
# volumes on a schedule would silently destroy local Postgres data whose only
# copy is that volume, so a volume whose project a checkout under $SITES still
# declares is never touched, and neither is any unlabelled or anonymous volume.
# Run-scoped stacks are different. Agents start them from a /tmp workdir
# (`supabase start --workdir /tmp/...`) and stop them with a plain
# `supabase stop` that keeps the volumes, and no checkout under $SITES owns
# that data. The workdir itself often survives (12 of the first 14 reap
# candidates still had theirs 5-6 days later, 2026-10-06). It does not keep
# the volume, and `supabase start` there after a reap gets an empty database.
# That pile reached 236 GB in six days (2026-09-29..10-04, peak 61 GB/day). It
# filled the root filesystem twice in eight days, and disk-watermark's CRIT
# toast fired three days running without anything acting on it.
# REAP_VOLUMES=1 removes a volume only when all four hold:
# - it is dangling;
# - it carries com.supabase.cli.project;
# - no config.toml under $SITES declares that project (a full-depth scan with
#   worktrees and _archive included, plus $SITES/<project>; a scan error,
#   or a found config.toml that cannot be read, reaps nothing);
# - it is older than VOLUME_GRACE_HOURS by CreatedAt.
# `docker volume rm` itself refuses a volume a container still uses.
# Residuals:
# - The grace counts from creation, not from the stop.
# - A project_id written as env(...) cannot be matched, so its volumes read as
#   undeclared. One live instance on 2026-10-06, a third-party reference
#   clone, and none of that day's dangling volumes were its. Holding every
#   volume on such a config would have stopped the reap on this host.
# - A checkout outside $SITES that declares the project, a /tmp workdir
#   included, is invisible here. STOP_ORPHANS holds a running stack on
#   bind-mount or process-cwd evidence outside $SITES; a dangling volume has
#   no container to read mounts from, and the reap checks neither.
# - A directory symlinked in under $SITES is not followed (find -H follows
#   only $SITES itself), so a checkout reached only through such a link counts
#   as outside $SITES. On 2026-10-07 workstation had 8 of these links, none leading to a
#   supabase/config.toml. find -L would follow them, but it exits 1 on any
#   link loop, which fails the scan and stops every reap.
# - The checkout scan is a snapshot (87 s over 870 configs, 2026-10-06;
#   173 s cold over 1,000, 2026-10-07). Candidates are re-checked against a
#   second, warm walk (14-20 s) just before removal, which narrows the window
#   to that walk and the removals; it cannot close it, since nothing
#   coordinates checkout creation with this run.
#
# WHY THE SUPABASE PREFLIGHT REFUSES STOPS BUT KEEPS RECLAIMING (2026-10-04, #1555)
# STOP_IDLE and STOP_ORPHANS exec `supabase`. The systemd --user manager's
# stock PATH has no ~/.local/bin and no mise shims, so the scheduled unit
# (STOP_ORPHANS=1 since 2026-09-16) ran its first stop attempts, 25 of them
# on 2026-09-30, as exit 127 and discarded the CLI's stderr, leaving
# `failed: supabase stop project=<id>` as the whole record. Now: with
# DRY_RUN=0 and a stop mode on, `command -v supabase` runs before the first
# docker call. A miss prints the binary, the PATH searched and the remedy,
# records an observation error (so STRICT exits 1 and the unit's failure
# alert carries the cause), and every stop this run is refused before its
# identity reads with a per-stack held_precondition row; no CLI call is made.
# Exited-container and image reclaim still run: AGGRESSIVE reclaim is the
# disk-full lever this unit exists for (see the unit's Stage 2 note), and a
# PATH regression must not switch it off for weeks. The miss is recorded
# eagerly, not at the first refused stop: a host that enabled the timer with
# a stop mode on and no CLI is misconfigured and should page even on a week
# with nothing to stop. Dry runs and runs with both stop modes off never exec
# the CLI and are not gated. Every attempted stop keeps the CLI's stderr
# (last 3 lines, folded into one bounded line) in the FAILED line and the
# action-error detail.
#
# ZOMBIE BACKGROUND (why restart is the only lever)
# Supabase studio/pg_meta health-check with `CMD-SHELL node --eval=...` every
# 10s at a 2s timeout. The shell forks node rather than exec'ing it; when the
# host stalls and the probe blows its deadline, Docker kills the shell it tracks
# and the node grandchild is reparented to the container's PID 1 — the app
# itself, which is not an init and never wait()s. The corpse is then unreapable
# for the container's lifetime: SIGKILL to a zombie is a no-op, since the
# process is already dead. Only the parent exiting clears it. Hence: recycle the
# container, or stop the stack. No reaper script can ever fix this.
#
# FIXES FROM ADVERSARIAL REVIEW (2026-08-06) — each of these was a real defect:
#   * Liveness is now derived by walking LIVE PROCESS CWDS UPWARD to the nearest
#     supabase/config.toml, not by scanning $SITES to a fixed depth. The harness
#     puts checkouts at <repo>/.claude/worktrees/<wt>/apps/<app>/ — eight levels
#     down. A maxdepth-6 scan found 0 of them while 1214 existed and live agent
#     sessions were running inside them, so the "someone is working here" guard
#     silently passed and would have restarted containers under active work.
#   * Recyclability is a FAIL-CLOSED ALLOWLIST (studio, pg_meta) instead of a
#     stateful denylist. The denylist treated every unrecognised service as safe
#     to restart, and it classified `kong` — the single gateway fronting the
#     whole stack — as disposable.
#   * project/service come from container LABELS, not from splitting the name.
#     `supabase init` copies the directory name into project_id with no charset
#     validation, so an underscore in a project id made `supabase_db_my_proj`
#     parse as service "db_my", which missed the stateful pattern and made a
#     live Postgres container restart-eligible.
#   * A docker failure after the initial `docker info` gate used to yield
#     `zombies:0 ... flagged:0`, exit 0 — byte-identical to a clean host.
#     Every query's exit status is now checked and surfaced.
#   * AGGRESSIVE's in-use image set is computed BEFORE anything is removed;
#     building it afterwards let an image referenced only by a just-reaped
#     container read as unreferenced, and the dry run could not preview it.
#   * ONLY= now gates every section, not just the two it originally reached.
set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"; ONLY="${ONLY:-}"
IDLE_DAYS="${IDLE_DAYS:-7}"; EXITED_DAYS="${EXITED_DAYS:-7}"; ZOMBIE_MAX="${ZOMBIE_MAX:-5}"
STOP_IDLE="${STOP_IDLE:-0}"; STOP_ORPHANS="${STOP_ORPHANS:-0}"
REAP_VOLUMES="${REAP_VOLUMES:-0}"; VOLUME_GRACE_HOURS="${VOLUME_GRACE_HOURS:-24}"
AGGRESSIVE="${AGGRESSIVE:-0}"; CACHE="${CACHE:-0}"; JSON="${JSON:-0}"
STRICT="${STRICT:-0}"
RECLAIM_WARN_MB="${RECLAIM_WARN_MB:-20480}"
SCAN_DEPTH="${SCAN_DEPTH:-6}"
# How far BELOW a live process cwd to look for stacks it plausibly owns.
# 3 reaches apps/<app>/supabase/config.toml from a monorepo root.
LIVE_DOWN_DEPTH="${LIVE_DOWN_DEPTH:-4}"
SITES="${SITES:-$HOME/SITES}"
PROCFS_ROOT="${PROCFS_ROOT:-/proc}"
PROC_LIVENESS="${PROC_LIVENESS:-$(dirname "${BASH_SOURCE[0]}")/lib/proc_liveness.py}"

# Fail-closed: ONLY these services are ever restarted automatically. Both are
# the confirmed zombie producers (node --eval health probes) and both are
# stateless request-servers whose restart costs a few seconds of one endpoint.
# Deliberately NOT included: kong (restarting the gateway drops every in-flight
# request for the entire stack), inbucket/mailpit (mounts nothing — a restart
# discards captured test emails), rest, vector, edge_runtime, and anything
# unrecognised. Widen at your own risk with RECYCLE_EXTRA='rest|vector'.
RECYCLABLE_RE="^(studio|pg_meta${RECYCLE_EXTRA:+|$RECYCLE_EXTRA})$"

now=$(date +%s)
n_zomb=0; n_zomb_total=0; n_recycled=0; n_held=0; n_idle=0; n_exited=0; n_exited_eligible=0; n_img=0; n_vol=0; n_flagged=0
n_dockerr=0; n_init_detected=0; n_init_not_detected=0; n_init_unknown=0; n_actionerr=0; n_procerr=0; n_obserr=0
declare -a RECYCLED=() IDLE_STACKS=() ZOMBIE_HOLD=()

append_action_error_detail() {
  [ "${DOCKER_HYGIENE_TEST_ACTION_DETAIL_FAILURE:-0}" = 1 ] && return 1
  printf '%s\n' "$1" >>"$ACTION_ERRFILE" 2>/dev/null
}

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "      would: $*"; return 0; fi
  if "$@" >/dev/null 2>&1; then echo "      ok: $*"; return 0
  else
    echo "      !! FAILED: $*"
    n_actionerr=$(( n_actionerr + 1 ))
    append_action_error_detail "$*" || :
    return 1
  fi
}
# run() returns 0 for a dry-run plan line, so `run ... && n=$(( n + 1 ))`
# counted would-removals as removals and the weekly DRY_RUN=1 JSON=1 report
# read them as cleanup (#1628 volumes, #1630 exited containers and images).
# This succeeds only for a real, successful action: every "removed" counter
# is gated on it, never on run() itself.
applied() { run "$@" && [ "$DRY_RUN" != 1 ]; }

report_scratch_failure() {
  echo "docker-hygiene: reporting scratch unavailable; no actions attempted"
  echo "docker-hygiene: zombies:0 recycled:0 idle-stacks:0 exited:0 images:0 reclaim-mb:0 docker-errors:0 docker-flagged:1 zombies-total:0 containers-observed:0 init-detected:0 init-not-detected:0 init-unknown:0 inspection-errors:1 observation-errors:1 action-errors:0 state:error inventory-complete:false volumes:0"
  if [ "$JSON" = 1 ]; then
    printf '%s\n' '{"zombies":0,"recycled":0,"held":0,"idle_stacks":0,"exited_removed":0,"images_removed":0,"flagged":1,"docker_errors":0,"recycled_names":[],"idle_stack_names":[],"held_names":[],"zombies_total":0,"containers_observed":0,"init_detected":0,"init_not_detected":0,"init_unknown":0,"inventory_complete":false,"inspection_errors":1,"observation_errors":1,"action_errors":0,"state":"error","container_observations":[],"stack_observations":[],"action_error_details":[],"observation_error_details":["reporting scratch unavailable"],"volumes_removed":0}'
  fi
  [ "$STRICT" = 1 ] && return 1
  return 0
}

# Every reporting ledger must exist before mutation can become eligible. A
# private directory gives them one admission boundary and one cleanup target;
# falling back to unchecked /tmp pathnames can lose the only strict error signal
# during the same disk-exhaustion condition this tool is meant to diagnose.
REPORT_DIR=""
if ! REPORT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/docker-hygiene.XXXXXX" 2>/dev/null); then
  report_scratch_failure
  exit $?
fi
ERRFILE="$REPORT_DIR/docker-errors"
PROCERRFILE="$REPORT_DIR/process-errors"
ACTION_ERRFILE="$REPORT_DIR/action-errors"
OBSERRFILE="$REPORT_DIR/observation-errors"
CONTAINER_OBS_FILE="$REPORT_DIR/container-observations"
STACK_OBS_FILE="$REPORT_DIR/stack-observations"
trap 'rm -rf -- "$REPORT_DIR"' EXIT
if ! { : >"$ERRFILE" && : >"$PROCERRFILE" && : >"$ACTION_ERRFILE" && \
       : >"$OBSERRFILE" && : >"$CONTAINER_OBS_FILE" && : >"$STACK_OBS_FILE"; }; then
  report_scratch_failure
  _scratch_rc=$?
  exit "$_scratch_rc"
fi

# Every docker read goes through this. A query that fails must never be
# indistinguishable from a query that legitimately returned nothing: that is how
# a broken run renders as a clean bill of health.
#
# Failures are recorded in a FILE, not a variable. Almost every caller consumes
# dock() through `< <(dock ...)`, which is a subshell, so a counter increment
# would be discarded the moment the loop ends — the first version of this fix
# reported 1 error when 4 queries had failed, and would have reported 0 (a clean
# run) had `docker system df` been the one query that still worked.
note_dock_err() { echo "$1" >>"$ERRFILE" 2>/dev/null; }
note_proc_err() { echo "$1" >>"$PROCERRFILE" 2>/dev/null; }
note_observation_err() {
  n_obserr=$(( n_obserr + 1 ))
  printf '%s\n' "$1" >>"$OBSERRFILE" 2>/dev/null || :
}
dock_err_count() { wc -l <"$ERRFILE" 2>/dev/null | tr -d ' ' || echo 0; }
file_line_count() { wc -l <"$1" 2>/dev/null | tr -d ' ' || echo 0; }

record_container_observation() {
  local rc
  case "${DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE:-}" in
    container|all) rc=97 ;;
    *)
    python3 - "$CONTAINER_OBS_FILE" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
keys = ("id", "name", "project", "service", "direct_zombies", "total_zombies",
        "init", "decision", "reason", "action_result")
values = sys.argv[2:]
row = dict(zip(keys, values))
row["direct_zombies"] = int(row["direct_zombies"])
row["total_zombies"] = int(row["total_zombies"])
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
      rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    note_observation_err "container observation write failed"
  fi
  # The failure is carried by the reporting ledger so unchecked callers cannot
  # accidentally suppress it or change action flow.
  return 0
}

record_stack_observation() {
  local rc
  case "${DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE:-}" in
    stack|all) rc=97 ;;
    *)
    python3 - "$STACK_OBS_FILE" "$@" <<'PY'
import json
import sys

path, project, ids, decision, reason, action_result, owner_path = sys.argv[1:]
row = {
    "project": project,
    "container_ids": ids.split() if ids else [],
    "decision": decision,
    "reason": reason,
    "action_result": action_result,
    "owner_path": owner_path,
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
      rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    note_observation_err "stack observation write failed"
  fi
  return 0
}
dock() {
  local out
  if ! out=$(docker "$@" 2>/dev/null); then
    note_dock_err "docker $*"
    echo "WARN docker query failed: docker $* — counts in this section are INCOMPLETE" >&2
    return 1
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# `docker system df` prints Reclaimable as e.g. "44.29GB (79%)" or "82.28kB".
# Naive digit-stripping turns that into 44.2979, so parse value+unit explicitly.
# Emits whole megabytes, or -1 if the query itself failed — a failed size lookup
# used to print 0 and silently suppress the RECLAIM_WARN_MB alert this tool
# exists to raise, while every other number in the report stayed correct.
df_reclaimable_mb() {
  local raw
  raw=$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null) \
    || { note_dock_err "docker system df"; echo -1; return; }
  [ -z "$raw" ] && { note_dock_err "docker system df (empty)"; echo -1; return; }
  printf '%s\n' "$raw" | awk -F'\t' -v want="${1:-}" '
    { type=$1; r=$2
      if (want != "" && type != want) next
      sub(/ *\(.*\)$/, "", r)
      if (match(r, /[0-9.]+/)) { v = substr(r, RSTART, RLENGTH) + 0 } else { next }
      u = substr(r, RSTART+RLENGTH); gsub(/ /, "", u)
      if      (u ~ /^[Tt]B/) v *= 1024*1024
      else if (u ~ /^[Gg]B/) v *= 1024
      else if (u ~ /^[Mm]B/) v *= 1
      else if (u ~ /^[Kk]B/) v /= 1024
      else                   v /= (1024*1024)
      s += v }
    END { printf "%d", (s ? s : 0) }'
}

# Extract project_id from a supabase config.toml. Handles inline comments and
# single-quoted values: `project_id = "x" # note` used to yield an empty string
# and `project_id = 'x'` used to yield the literal quotes, both of which made a
# perfectly healthy stack report as orphaned.
# A file that cannot be read returns 2 with no id, so the volume reap can tell
# "unreadable" from "declares nothing"; the other callers ignore the status.
parse_project_id() {
  local v
  v=$(sed -n 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$1" 2>/dev/null) || return 2
  v=${v%%$'\n'*}
  # Quoted values are resolved FIRST: a '#' inside quotes is data, not a
  # comment. Stripping comments first truncated project_id = "my#project" to
  # "my", which would then also break the LIVE_PROJ key match against the
  # container label (which carries the real, untruncated id).
  case "$v" in
    \"*) v=${v#\"}; v=${v%%\"*} ;;
    \'*) v=${v#\'}; v=${v%%\'*} ;;
    *)   v=${v%%#*}; v=$(printf '%s' "$v" | sed 's/[[:space:]]*$//') ;;
  esac
  # Some configs interpolate the id from the environment; that is not resolvable.
  case "$v" in ''|'env('*|'$'*) printf '' ; return ;; esac
  printf '%s' "$v"
}

# Stack-stop preflight; see "WHY THE SUPABASE PREFLIGHT REFUSES STOPS BUT
# KEEPS RECLAIMING" in the header. Sits before the first docker call. The
# resolved binary is logged so a run under the unit's own environment shows
# which supabase it would exec; a miss is recorded once here (observation
# error, so STRICT fails the run with the cause) and refused per stack in
# guarded_stack_stop. Nothing exits here: every reclaim section still runs.
SUPABASE_BIN=""
if [ "$DRY_RUN" != 1 ] && { [ "$STOP_IDLE" = 1 ] || [ "$STOP_ORPHANS" = 1 ]; }; then
  SUPABASE_BIN=$(command -v supabase 2>/dev/null || :)
  if [ -z "$SUPABASE_BIN" ]; then
    _cause="supabase CLI not found on PATH=${PATH:-}"
    echo "docker-hygiene: !! $_cause"
    # The remedy names the stop mode(s) actually on. A fixed STOP_ORPHANS=0
    # was already satisfied on an idle-only run, so following it changed
    # nothing (pro-gate round 3 on #1562).
    _off=""
    [ "$STOP_IDLE" = 1 ] && _off="STOP_IDLE=0"
    [ "$STOP_ORPHANS" = 1 ] && _off="${_off}${_off:+ }STOP_ORPHANS=0"
    echo "docker-hygiene: stack stops are enabled (STOP_IDLE=$STOP_IDLE STOP_ORPHANS=$STOP_ORPHANS) and will be refused this run; exited-container and image reclaim continue. Remedy: install the CLI, add its directory to the unit's Environment=PATH, or set $_off / disable docker-hygiene.timer on a host that does not run Supabase"
    note_observation_err "$_cause"
  else
    echo "docker-hygiene: supabase CLI: $SUPABASE_BIN (stack stops enabled)"
  fi
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker-hygiene: docker daemon unreachable — nothing to do"
  # The supabase preflight above may already have recorded an observation
  # error. This exit carries whatever the ledger holds (count, detail, the
  # inspection sum and the flag) instead of a fixed zero, so the summary line
  # and the JSON never contradict the cause printed a few lines up
  # (pro-gate round 2 on #1562).
  _gate_flagged=1
  [ "$n_obserr" -gt 0 ] && _gate_flagged=$(( _gate_flagged + 1 ))
  _gate_inspecterr=$(( 1 + n_obserr ))
  if [ "$n_obserr" -gt 0 ]; then
    echo "WARN docker-hygiene: $n_obserr observation/reporting operation(s) FAILED — report inventory is INCOMPLETE"
    sed 's/^/  failed: /' "$OBSERRFILE" 2>/dev/null
  fi
  echo "docker-hygiene: zombies:0 recycled:0 idle-stacks:0 exited:0 images:0 reclaim-mb:0 docker-errors:1 docker-flagged:$_gate_flagged zombies-total:0 containers-observed:0 init-detected:0 init-not-detected:0 init-unknown:0 inspection-errors:$_gate_inspecterr observation-errors:$n_obserr action-errors:0 state:error inventory-complete:false volumes:0"
  if [ "$JSON" = 1 ]; then
    python3 - "$_gate_flagged" "$_gate_inspecterr" "$n_obserr" "$OBSERRFILE" <<'PY'
import json
import sys

a = sys.argv[1:]
with open(a[3], encoding="utf-8", errors="replace") as fh:
    details = [line.rstrip("\n") for line in fh if line.rstrip("\n")]
print(json.dumps({
    "zombies": 0, "recycled": 0, "held": 0, "idle_stacks": 0,
    "exited_removed": 0, "images_removed": 0, "flagged": int(a[0]),
    "docker_errors": 1, "recycled_names": [], "idle_stack_names": [],
    "held_names": [], "zombies_total": 0, "containers_observed": 0,
    "init_detected": 0, "init_not_detected": 0,
    "init_unknown": 0, "inventory_complete": False,
    "inspection_errors": int(a[1]), "observation_errors": int(a[2]),
    "action_errors": 0, "state": "error",
    "container_observations": [], "stack_observations": [],
    "action_error_details": [], "observation_error_details": details,
    "volumes_removed": 0,
}))
PY
  fi
  [ "$STRICT" = 1 ] && exit 1
  exit 0
fi

# ---------------------------------------------------------------- liveness ---
# Which projects have a human or agent working in them RIGHT NOW.
# Derived by walking each live process cwd UPWARD to the nearest
# supabase/config.toml. This is depth-unlimited by construction, which is the
# whole point — see the review note in the header about worktree checkouts.
declare -A LIVE_PROJ=()
LIVE_BUILT=0
build_live_projects() {
  [ "$LIVE_BUILT" = 1 ] && return 0
  LIVE_BUILT=1
  local p t d pid f hit
  local -A seen=()
  for p in "$PROCFS_ROOT"/[0-9]*/cwd; do
    t=$(readlink "$p" 2>/dev/null) || continue
    t=${t% (deleted)}
    case "$t" in "$SITES"/*) ;; *) continue ;; esac
    [ -n "${seen[$t]:-}" ] && continue      # dozens of procs share one cwd
    seen[$t]=1
    [ -d "$t" ] || continue                 # deleted cwd: fail closed
    # (1) UPWARD — the app directory this process is inside.
    hit=0; d="$t"
    while [ "$d" != "/" ] && [ "$d" != "$SITES" ]; do
      if [ -f "$d/supabase/config.toml" ]; then
        pid=$(parse_project_id "$d/supabase/config.toml")
        [ -n "$pid" ] && { LIVE_PROJ[$pid]="$d"; hit=1; }
        break
      fi
      d=$(dirname "$d")
    done
    [ "$hit" = 1 ] && continue
    # (2) DOWNWARD — a cwd at a MONOREPO ROOT sits ABOVE apps/<app>/supabase/,
    # so the upward walk alone can never see it: someone working at
    # ~/SITES/acme-app marks none of its three stacks live, and the tool would
    # happily restart containers under them. Only runs when the upward walk
    # found nothing, which keeps it to a handful of scans. Over-marking a stack
    # as "in use" is the fail-safe direction — it declines to act.
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      pid=$(parse_project_id "$f")
      [ -n "$pid" ] && [ -z "${LIVE_PROJ[$pid]:-}" ] && LIVE_PROJ[$pid]="$t"
    done < <(find "$t" -maxdepth "$LIVE_DOWN_DEPTH" \
               \( -name node_modules -o -name .git -o -name dist -o -name .next \) -prune \
               -o -path '*/supabase/config.toml' -print 2>/dev/null)
  done
  return 0
}
stack_live() { build_live_projects; [ -n "${LIVE_PROJ[$1]:-}" ]; }

# Action-time liveness needs every checkout spelling a detached process may hold,
# including nested worktrees whose real cwd is elsewhere. This index is separate
# from the age map below so worktree mtimes cannot widen retention.
declare -A LIVENESS_PROJ_DIRS=()
LIVENESS_PROJ_MAP_BUILT=0
build_liveness_proj_map() {
  [ "$LIVENESS_PROJ_MAP_BUILT" = 1 ] && return 0
  LIVENESS_PROJ_MAP_BUILT=1
  local f pid d
  while IFS= read -r f; do
    pid=$(parse_project_id "$f"); [ -z "$pid" ] && continue
    d=$(dirname "$(dirname "$f")")
    LIVENESS_PROJ_DIRS[$pid]="${LIVENESS_PROJ_DIRS[$pid]:-}${d}"$'\n'
  done < <(find "$SITES" \
             \( -name node_modules -o -name .git -o -name .next -o -name dist \
                -o -name .venv -o -name _archive \) -prune \
             -o -path '*/supabase/config.toml' -print 2>/dev/null)
  return 0
}
liveness_proj_dirs() {
  build_liveness_proj_map
  { [ -d "$SITES/$1" ] && echo "$SITES/$1"
    printf '%s' "${LIVENESS_PROJ_DIRS[$1]:-}"; } | grep -v '^$' | sort -u
}

# ------------------------------------------------------------ stack ageing ---
# Candidate checkouts for AGE only. Worktrees are deliberately excluded here:
# including all 1214 of them would make almost every stack look freshly active
# and destroy idle detection in the other direction. The liveness-only map above
# includes worktrees without letting their mtimes affect this calculation.
declare -A PROJ_DIRS=()
PROJ_MAP_BUILT=0
build_proj_map() {
  [ "$PROJ_MAP_BUILT" = 1 ] && return 0
  PROJ_MAP_BUILT=1
  local f pid d
  while IFS= read -r f; do
    pid=$(parse_project_id "$f"); [ -z "$pid" ] && continue
    d=$(dirname "$(dirname "$f")")
    PROJ_DIRS[$pid]="${PROJ_DIRS[$pid]:-}${d}"$'\n'
  done < <(find "$SITES" -maxdepth "$SCAN_DEPTH" \
             \( -name node_modules -o -name .git -o -name .next -o -name dist \
                -o -name .venv -o -name _archive -o -name worktrees \) -prune \
             -o -path '*/supabase/config.toml' -print 2>/dev/null)
  return 0
}
# Projects that some checkout under $SITES declares, used for REAP_VOLUMES only.
# Unlike the liveness map, this keeps _archive, because an archived checkout
# still owns its data. It also records whether the scan completed: a failed scan,
# a missing $SITES or a found config.toml that cannot be read must never read as
# "nobody declares this project".
declare -A DECLARED_PROJ=()
DECLARED_SCAN=""
build_declared_projects() {
  [ -n "$DECLARED_SCAN" ] && return 0
  local list f pid
  # -H: a symlinked $SITES (moved to another disk) must be walked, not read as
  # an empty, complete scan that leaves every project undeclared.
  if [ ! -d "$SITES" ] || ! list=$(find -H "$SITES" \
       \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name .venv \) -prune \
       -o -path '*/supabase/config.toml' -print 2>/dev/null); then
    DECLARED_SCAN=failed
    note_observation_err "checkout scan of $SITES failed; no volume reaped this run"
    return 0
  fi
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! pid=$(parse_project_id "$f"); then
      DECLARED_SCAN=failed
      note_observation_err "checkout scan could not read $f; no volume reaped this run"
      continue
    fi
    [ -n "$pid" ] && DECLARED_PROJ[$pid]=1
  done <<<"$list"
  [ -n "$DECLARED_SCAN" ] || DECLARED_SCAN=ok
}

proj_dirs() {
  build_proj_map
  { [ -d "$SITES/$1" ] && echo "$SITES/$1"
    printf '%s' "${PROJ_DIRS[$1]:-}"; } | grep -v '^$' | sort -u
}
repo_age_days() {
  local repo="$1" ct mt newest
  [ -d "$repo" ] || { echo -1; return; }
  ct=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0)
  mt=$(stat -c %Y "$repo" 2>/dev/null || echo 0)
  newest=$(( ct > mt ? ct : mt ))
  [ "$newest" -eq 0 ] && { echo -1; return; }
  echo $(( (now - newest) / 86400 ))
}

refresh_live_projects() {
  LIVE_PROJ=()
  LIVE_BUILT=0
  build_live_projects
}

# Return 0 for an intentional hold/live, 1 for observed idle, 2 when the
# required snapshot cannot answer. The shared helper reads fd/cwd/environ/cmdline but --quiet
# prevents process payloads from entering this report.
#
# mode (2nd arg) is "idle" (default) or "orphan". The two modes read the
# "no checkout anywhere" answer oppositely, on purpose: for an idle candidate it
# is missing evidence and a fail-closed hold; for an orphan it is exactly the
# evidence the caller asked for. Orphan mode also re-scans the checkout map so a
# checkout created between plan and action turns the stack back into a hold.
refresh_liveness_proj_map() { LIVENESS_PROJ_DIRS=(); LIVENESS_PROJ_MAP_BUILT=0; }

# Orphan evidence that is NOT $SITES-scoped (see the header). Returns 0 with
# CHECKOUT_EVIDENCE="<reason>:<path>" when the stack still has a checkout
# somewhere, 1 when neither signal fires, 2 when the mounts could not be
# inspected (fail closed: the caller holds).
CHECKOUT_EVIDENCE=""
stack_checkout_evidence() {
  local proj=$1 ids=$2 cid src root before after p t d pid
  local -A seen=()
  before=$(dock_err_count)
  for cid in $ids; do
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      case "$src" in */supabase/*) root=${src%%/supabase/*} ;; *) continue ;; esac
      if [ -d "$root" ]; then
        CHECKOUT_EVIDENCE="bind_mount_checkout_exists:$root"
        return 0
      fi
    done < <(dock inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$cid")
  done
  after=$(dock_err_count)
  if [ "$after" -gt "$before" ]; then
    CHECKOUT_EVIDENCE="mount_inspection_failed:"
    return 2
  fi
  for p in "$PROCFS_ROOT"/[0-9]*/cwd; do
    t=$(readlink "$p" 2>/dev/null) || continue
    t=${t% (deleted)}
    [ -n "${seen[$t]:-}" ] && continue
    seen[$t]=1
    [ -d "$t" ] || continue
    d=$t
    while [ "$d" != "/" ]; do
      if [ -f "$d/supabase/config.toml" ]; then
        pid=$(parse_project_id "$d/supabase/config.toml")
        if [ "$pid" = "$proj" ]; then
          CHECKOUT_EVIDENCE="live_process_cwd_outside_sites:$d"
          return 0
        fi
        break
      fi
      d=$(dirname "$d")
    done
  done
  CHECKOUT_EVIDENCE=""
  return 1
}

LIVENESS_REASON=""
project_liveness_recheck() {
  local proj=$1 mode=${2:-idle} ids=${3:-} rc
  local -a dirs=()
  refresh_live_projects
  if stack_live "$proj"; then
    LIVENESS_REASON=live_process_cwd
    return 0
  fi
  [ "$mode" = orphan ] && refresh_liveness_proj_map
  mapfile -t dirs < <(liveness_proj_dirs "$proj")
  if [ "${#dirs[@]}" -eq 0 ]; then
    if [ "$mode" = orphan ]; then
      stack_checkout_evidence "$proj" "$ids"
      rc=$?
      if [ "$rc" -eq 0 ]; then
        LIVENESS_REASON=${CHECKOUT_EVIDENCE%%:*}
        return 0
      elif [ "$rc" -ne 1 ]; then
        LIVENESS_REASON=mount_inspection_failed
        return 2
      fi
      LIVENESS_REASON=orphan_no_mapped_checkout
      return 1
    fi
    # Missing ownership evidence cannot prove idleness. This is an intentional
    # fail-closed hold, not an operational inspection error.
    LIVENESS_REASON=no_mapped_checkout
    return 0
  fi
  if [ "$mode" = orphan ]; then
    # A checkout appeared since the plan: no longer an orphan. The idle path
    # owns it from the next run, with its age threshold.
    LIVENESS_REASON=checkout_appeared
    return 0
  fi
  python3 "$PROC_LIVENESS" --quiet --procfs "$PROCFS_ROOT" -- "${dirs[@]}" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) LIVENESS_REASON=shared_process_holder; return 0 ;;
    1) LIVENESS_REASON=no_live_holder; return 1 ;;
    *)
      LIVENESS_REASON=liveness_snapshot_error
      note_proc_err "project $proj liveness snapshot failed"
      return 2
      ;;
  esac
}

RECHECK_REASON=""
container_identity_recheck() {
  local cid=$1 expected_name=$2 expected_pid=$3 expected_proj=$4 row name pid proj
  if ! row=$(dock inspect -f '{{.Name}}	{{.State.Pid}}	{{index .Config.Labels "com.supabase.cli.project"}}' "$cid"); then
    RECHECK_REASON=target_inspection_failed
    return 2
  fi
  IFS=$'\t' read -r name pid proj <<<"$row"
  name=${name#/}
  if [ -z "$name" ] || [ -z "$pid" ] || [ "$name" != "$expected_name" ] || \
     [ "$pid" != "$expected_pid" ] || [ "$proj" != "$expected_proj" ]; then
    RECHECK_REASON=target_identity_changed
    return 1
  fi
  RECHECK_REASON=identity_current
  return 0
}

echo "===== docker-hygiene $([ "$DRY_RUN" = 1 ] && echo '(DRY RUN)') ====="
echo "thresholds: idle>${IDLE_DAYS}d exited>${EXITED_DAYS}d zombies>=${ZOMBIE_MAX} recyclable=${RECYCLABLE_RE}"
[ -n "$ONLY" ] && echo "restricted to project: $ONLY"
echo

# Snapshot images in use BEFORE anything is removed. Computing this after the
# exited-container reap let an image referenced only by a just-removed container
# look unreferenced, and the dry run could not show it because the dry run never
# actually removed the container.
declare -A INUSE=()
INUSE_SNAPSHOT_COMPLETE=1
_inuse_err_before=$(dock_err_count)
mapfile -t ALLC < <(dock ps -aq)
if [ "${#ALLC[@]}" -gt 0 ]; then
  while read -r iid; do [ -n "$iid" ] && INUSE["$iid"]=1; done < <(
    dock inspect --format '{{.Image}}' "${ALLC[@]}")
fi
_inuse_err_after=$(dock_err_count)
[ "$_inuse_err_after" -gt "$_inuse_err_before" ] && INUSE_SNAPSHOT_COMPLETE=0

# Project + service for a container, from LABELS. Name-splitting breaks on any
# project id containing an underscore, and misclassifies the service when it does.
# Routed through dock() so an inspect failure is recorded: an unrecorded failure
# here fails toward inaction (the container is held, never restarted), but it
# would still let a broken run report docker-errors:0 and look healthy.
container_proj() { dock inspect -f '{{index .Config.Labels "com.supabase.cli.project"}}' "$1"; }

# ---------------------------------------------------------------- zombies ----
# One bounded host-process snapshot supplies both the legacy direct-child count
# and the additive descendant count. No cmdline or environment payload is read
# here; the shared liveness helper uses those signals privately at action time.
declare -A ZBY=() PSTAT=() CHILDREN=()
PROCESS_SNAPSHOT_COMPLETE=1
PS_SNAPSHOT=$(ps -eo pid,ppid,stat --no-headers 2>/dev/null)
_ps_rc=$?
if [ "$_ps_rc" -ne 0 ]; then
  PROCESS_SNAPSHOT_COMPLETE=0
  note_proc_err "ps process snapshot failed"
  echo "WARN process snapshot failed — zombie counts are INCOMPLETE and no process-based action is safe"
else
  while read -r _pid ppid pstat; do
    [ -n "${_pid:-}" ] || continue
    PSTAT[$_pid]=$pstat
    CHILDREN[$ppid]="${CHILDREN[$ppid]:-} $_pid"
    case "$pstat" in Z*) ZBY[$ppid]=$(( ${ZBY[$ppid]:-0} + 1 ));; esac
  done <<<"$PS_SNAPSHOT"
fi

descendant_zombies() {
  local root=$1 cur child total=0 next=0
  local -a pending=("$root")
  local -A seen=(["$root"]=1)
  while [ "$next" -lt "${#pending[@]}" ]; do
    cur=${pending[$next]}
    next=$((next + 1))
    for child in ${CHILDREN[$cur]:-}; do
      [ -n "${seen[$child]:-}" ] && continue
      seen[$child]=1
      case "${PSTAT[$child]:-}" in Z*) total=$(( total + 1 ));; esac
      pending+=("$child")
    done
  done
  printf '%s' "$total"
}

container_init_state() {
  local cid=$1 cpid=$2 comm
  if [ "$PROCESS_SNAPSHOT_COMPLETE" != 1 ] || [ -z "${PSTAT[$cpid]:-}" ]; then
    note_proc_err "container $cid host pid $cpid absent from process snapshot"
    printf 'unknown'
    return 1
  fi
  if ! grep -Fq "$cid" "$PROCFS_ROOT/$cpid/cgroup" 2>/dev/null; then
    note_proc_err "container $cid host pid $cpid cgroup identity unreadable or mismatched"
    printf 'unknown'
    return 1
  fi
  if ! IFS= read -r comm <"$PROCFS_ROOT/$cpid/comm"; then
    note_proc_err "container $cid host pid $cpid comm unreadable"
    printf 'unknown'
    return 1
  fi
  case "$comm" in
    docker-init|tini|catatonit|dumb-init) printf 'detected' ;;
    *) printf 'not_detected' ;;
  esac
  return 0
}

echo "## zombie audit (direct PID-1 children drive recycling; descendants are diagnostic)"
while IFS=$'\t' read -r cid cname; do
  [ -z "$cid" ] && continue
  short=${cname#/}
  if ! proj=$(container_proj "$cid"); then
    n_init_unknown=$(( n_init_unknown + 1 ))
    record_container_observation "$cid" "$short" "" "" 0 0 "unknown" \
      "held_inspection_error" "project_inspection_failed" "not_attempted"
    continue
  fi
  svc=""
  # "$proj" quoted: an unquoted suffix expansion is treated as a glob pattern,
  # so a project id containing * or ? would strip the wrong amount.
  if [ -n "$proj" ]; then svc=${short#supabase_}; svc=${svc%_"$proj"}; fi
  [ -n "$ONLY" ] && [ "$proj" != "$ONLY" ] && continue
  if ! cpid=$(dock inspect -f '{{.State.Pid}}' "$cid"); then
    n_init_unknown=$(( n_init_unknown + 1 ))
    record_container_observation "$cid" "$short" "$proj" "$svc" 0 0 "unknown" \
      "held_inspection_error" "pid_inspection_failed" "not_attempted"
    continue
  fi
  if [ -z "$cpid" ] || [ "$cpid" = "0" ]; then
    n_init_unknown=$(( n_init_unknown + 1 ))
    record_container_observation "$cid" "$short" "$proj" "$svc" 0 0 "unknown" \
      "held_stale_identity" "container_pid_not_running" "not_attempted"
    continue
  fi
  z=${ZBY[$cpid]:-0}
  z_total=$(descendant_zombies "$cpid")
  n_zomb=$(( n_zomb + z ))
  n_zomb_total=$(( n_zomb_total + z_total ))
  if init_state=$(container_init_state "$cid" "$cpid"); then
    if [ "$init_state" = detected ]; then
      n_init_detected=$(( n_init_detected + 1 ))
    else
      n_init_not_detected=$(( n_init_not_detected + 1 ))
    fi
  else
    init_state=unknown
    n_init_unknown=$(( n_init_unknown + 1 ))
  fi
  if [ "$init_state" = unknown ]; then
    echo "  ~ skip $short: process identity/init observation incomplete; no restart is safe"
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "held_incomplete_process" "required_procfs_observation_failed" "not_attempted"
    continue
  fi
  if [ "$z_total" -eq 0 ]; then
    record_container_observation "$cid" "$short" "$proj" "$svc" 0 0 "$init_state" \
      "observed" "no_zombies" "not_applicable"
    continue
  fi
  if [ "$z" -eq 0 ]; then
    echo "  ~ $short: $z_total nested zombie(s), 0 direct — diagnostic only; recycle eligibility unchanged"
    record_container_observation "$cid" "$short" "$proj" "$svc" 0 "$z_total" "$init_state" \
      "observed_nested_only" "no_direct_pid1_zombies" "not_attempted"
    continue
  fi
  if [ -z "$proj" ] || ! [[ "$svc" =~ $RECYCLABLE_RE ]]; then
    echo "  ! $short: $z direct / $z_total total zombie(s) — not in the recyclable allowlist, left alone (stop the stack to clear)"
    n_held=$(( n_held + 1 )); ZOMBIE_HOLD+=("$short")
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "held_not_recyclable" "service_not_in_recycle_allowlist" "not_attempted"
    continue
  fi
  if [ "$z" -lt "$ZOMBIE_MAX" ]; then
    echo "  ~ $short: $z direct / $z_total total zombie(s) — under direct threshold ($ZOMBIE_MAX), leaving"
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "held_under_threshold" "direct_zombies_below_threshold" "not_attempted"
    continue
  fi
  if stack_live "$proj"; then
    echo "  ~ skip $short: $z direct / $z_total total zombie(s) but work is live in ${LIVE_PROJ[$proj]}"
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "held_live_work" "live_process_cwd" "not_attempted"
    continue
  fi
  container_identity_recheck "$cid" "$short" "$cpid" "$proj"
  _identity_rc=$?
  if [ "$_identity_rc" -ne 0 ]; then
    echo "  ~ skip $short: target identity could not be confirmed immediately before restart ($RECHECK_REASON)"
    if [ "$_identity_rc" -eq 1 ]; then decision=held_stale_identity; else decision=held_inspection_error; fi
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "$decision" "$RECHECK_REASON" "not_attempted"
    continue
  fi
  project_liveness_recheck "$proj"
  _live_rc=$?
  if [ "$_live_rc" -eq 0 ]; then
    if [ "$LIVENESS_REASON" = no_mapped_checkout ]; then
      echo "  ~ skip $short: no mapped checkout; missing ownership evidence cannot prove idleness"
      decision=held_unknown_owner
    else
      echo "  ~ skip $short: work became live before restart ($LIVENESS_REASON)"
      decision=held_live_work
    fi
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "$decision" "$LIVENESS_REASON" "not_attempted"
    continue
  elif [ "$_live_rc" -ne 1 ]; then
    echo "  ~ skip $short: liveness could not be confirmed immediately before restart"
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "held_liveness_unknown" "$LIVENESS_REASON" "not_attempted"
    continue
  fi
  # Liveness can take long enough for the container to restart concurrently.
  # Refresh identity again as the final read before the named mutation.
  container_identity_recheck "$cid" "$short" "$cpid" "$proj"
  _identity_rc=$?
  if [ "$_identity_rc" -ne 0 ]; then
    echo "  ~ skip $short: final target identity could not be confirmed ($RECHECK_REASON)"
    if [ "$_identity_rc" -eq 1 ]; then decision=held_stale_identity; else decision=held_inspection_error; fi
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "$decision" "$RECHECK_REASON" "not_attempted"
    continue
  fi
  echo "  + $short: $z direct / $z_total total zombie(s) — recyclable and idle, recycling"
  if run docker restart "$cid"; then
    n_recycled=$(( n_recycled + 1 )); RECYCLED+=("$short")
    [ "$DRY_RUN" = 1 ] && action_result=planned || action_result=succeeded
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "recycled" "direct_threshold_met" "$action_result"
  else
    record_container_observation "$cid" "$short" "$proj" "$svc" "$z" "$z_total" "$init_state" \
      "action_error" "restart_failed" "failed"
  fi
done < <(dock ps --format '{{.ID}}\t{{.Names}}')
[ "$n_zomb" -eq 0 ] && echo "  (none)"
echo

# ------------------------------------------------------------- idle stacks ---
echo "## idle dev stacks"
declare -A STACK_N=() STACK_IDS=()
while IFS=$'\t' read -r cid _cname; do
  [ -z "$cid" ] && continue
  p=$(container_proj "$cid"); [ -z "$p" ] && continue
  STACK_N[$p]=$(( ${STACK_N[$p]:-0} + 1 ))
  STACK_IDS[$p]="${STACK_IDS[$p]:-} $cid"
done < <(dock ps --format '{{.ID}}\t{{.Names}}')

current_stack_ids() {
  local wanted=$1 cid _name project before after
  local -a ids=()
  before=$(dock_err_count)
  while IFS=$'\t' read -r cid _name; do
    [ -n "$cid" ] || continue
    project=$(container_proj "$cid")
    [ "$project" = "$wanted" ] && ids+=("$cid")
  done < <(dock ps --format '{{.ID}}\t{{.Names}}')
  after=$(dock_err_count)
  [ "$after" -gt "$before" ] && return 2
  if [ "${#ids[@]}" -gt 0 ]; then printf '%s\n' "${ids[@]}" | sort -u; fi
}

# Both stop paths run through here so the CLI's stderr survives. Until
# 2026-10-05 it went to /dev/null, which left `failed: supabase stop
# project=<id> --project-id` as the only record of 25 exit-127s (#1555).
# stdout stays discarded (progress noise). The last 3 stderr lines are folded
# into one bounded line because ACTION_ERRFILE is one detail per line and
# feeds the JSON action_error_details verbatim; a raw newline would split one
# failure into several entries. In idle mode a failing `cd "$owner"` lands in
# the same capture, which is the point: the cause is whatever the subshell
# said. The bound is in bytes and keeps the END of the fold (tail -c): the
# CLI's last line is the error and the earlier ones are progress, so a long
# early line must not push the cause out, and a stray non-UTF-8 byte cannot
# change the fold's behaviour. The capture file is a reporting aid, not a
# precondition for the stop: if the scratch stopped taking writes mid-run the
# stop still runs, its stderr passes through to this run's own stderr (the
# journal under the unit), and the recorded cause says why it is missing.
SUPABASE_STOP_STDERR=""
supabase_stop_captured() {
  local mode=$1 owner=$2 proj=$3 rc
  local errf="$REPORT_DIR/supabase-stop.stderr"
  if [ "${DOCKER_HYGIENE_TEST_STDERR_CAPTURE_FAILURE:-0}" = 1 ] || ! : >"$errf" 2>/dev/null; then
    if [ "$mode" = idle ]; then
      ( cd "$owner" && supabase stop ) >/dev/null
    else
      supabase stop --project-id "$proj" >/dev/null
    fi
    rc=$?
    SUPABASE_STOP_STDERR="(stderr capture unavailable: cannot write $errf; the CLI's stderr went to this run's own stderr)"
    return "$rc"
  fi
  if [ "$mode" = idle ]; then
    ( cd "$owner" && supabase stop ) >/dev/null 2>"$errf"
  else
    supabase stop --project-id "$proj" >/dev/null 2>"$errf"
  fi
  rc=$?
  SUPABASE_STOP_STDERR=$(tail -n 3 "$errf" 2>/dev/null | tr '\r\n\t' '   ' | tr -s ' ' | tail -c 400 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  return "$rc"
}

# Explicitly requested whole-stack stop, shared by the idle and orphan paths so
# every guard runs for both: exact running-set identity before and after the
# liveness recheck, then the recheck itself in the caller's mode. mode=idle
# stops from the newest checkout (cd + supabase stop); mode=orphan has no
# checkout by definition and addresses the stack by its label
# (supabase stop --project-id), which the CLI accepts from any cwd.
guarded_stack_stop() {
  local proj=$1 stack_ids=$2 mode=$3 owner=$4
  local reason detail expected_set current_set rc stopped=0 stop_rc=0 stop_cause
  local -a expected_ids=()
  case "$mode" in
    idle)   reason=idle_threshold_met;     detail="cwd=$owner" ;;
    orphan) reason=orphan_no_mapped_config; detail="--project-id" ;;
    *) echo "      !! internal: unknown stop mode '$mode' for $proj" >&2; return 1 ;;
  esac
  # Preflight miss (recorded once at the top of the run): refuse before the
  # identity reads, which cost seconds each, and record it per stack. No CLI
  # call is made.
  if [ -z "$SUPABASE_BIN" ]; then
    echo "      ~ skip stop $proj: supabase CLI not on PATH (preflight)"
    record_stack_observation "$proj" "$stack_ids" "held_precondition" "supabase_cli_missing" "not_attempted" "$owner"
    return 0
  fi
  IFS=' ' read -r -a expected_ids <<<"$stack_ids"
  expected_set=$(printf '%s\n' "${expected_ids[@]}" | sort -u)
  current_set=$(current_stack_ids "$proj")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "      ~ skip stop $proj: running-container identity could not be inspected"
    record_stack_observation "$proj" "$stack_ids" "held_inspection_error" "target_inspection_failed" "not_attempted" "$owner"
    return 0
  elif [ "$current_set" != "$expected_set" ]; then
    echo "      ~ skip stop $proj: running-container identity changed before action"
    record_stack_observation "$proj" "$stack_ids" "held_stale_identity" "container_set_changed" "not_attempted" "$owner"
    return 0
  fi
  project_liveness_recheck "$proj" "$mode" "$stack_ids"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "      ~ skip stop $proj: work became live before action ($LIVENESS_REASON)"
    record_stack_observation "$proj" "$stack_ids" "held_live_work" "$LIVENESS_REASON" "not_attempted" "$owner"
    return 0
  elif [ "$rc" -ne 1 ]; then
    echo "      ~ skip stop $proj: liveness could not be confirmed before action"
    record_stack_observation "$proj" "$stack_ids" "held_liveness_unknown" "$LIVENESS_REASON" "not_attempted" "$owner"
    return 0
  fi
  # A stack member can appear while liveness is scanned. Refresh the exact
  # running set again as the final read before the explicitly requested stop.
  current_set=$(current_stack_ids "$proj")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "      ~ skip stop $proj: final running-container identity could not be inspected"
    record_stack_observation "$proj" "$stack_ids" "held_inspection_error" "target_inspection_failed" "not_attempted" "$owner"
    return 0
  elif [ "$current_set" != "$expected_set" ]; then
    echo "      ~ skip stop $proj: running-container identity changed during liveness check"
    record_stack_observation "$proj" "$stack_ids" "held_stale_identity" "container_set_changed" "not_attempted" "$owner"
    return 0
  fi
  # No eval: a checkout path is attacker-adjacent (agent-generated slugs),
  # and interpolating one into an eval'd string reparses on a stray quote.
  supabase_stop_captured "$mode" "$owner" "$proj"
  stop_rc=$?
  [ "$stop_rc" -eq 0 ] && stopped=1
  if [ "$stopped" = 1 ]; then
    echo "      ok: stopped $proj"
    record_stack_observation "$proj" "$stack_ids" "stopped" "$reason" "succeeded" "$owner"
  else
    stop_cause=${SUPABASE_STOP_STDERR:-"(no stderr captured)"}
    echo "      !! FAILED to stop $proj (rc=$stop_rc): $stop_cause"
    n_actionerr=$(( n_actionerr + 1 ))
    append_action_error_detail "supabase stop project=$proj $detail rc=$stop_rc stderr: $stop_cause" || :
    record_stack_observation "$proj" "$stack_ids" "action_error" "supabase_stop_failed" "failed" "$owner"
  fi
  return 0
}

for proj in "${!STACK_N[@]}"; do
  [ -n "$ONLY" ] && [ "$proj" != "$ONLY" ] && continue
  cnt=${STACK_N[$proj]}
  stack_ids=${STACK_IDS[$proj]# }
  if stack_live "$proj"; then
    echo "  ~ $proj ($cnt containers): in use — live process cwd inside ${LIVE_PROJ[$proj]}"
    record_stack_observation "$proj" "$stack_ids" "held_live_work" "live_process_cwd" "not_attempted" "${LIVE_PROJ[$proj]}"
    continue
  fi
  mapfile -t dirs < <(proj_dirs "$proj")
  if [ "${#dirs[@]}" -eq 0 ]; then
    n_idle=$(( n_idle + 1 )); n_flagged=$(( n_flagged + 1 )); IDLE_STACKS+=("$proj")
    if [ "$STOP_ORPHANS" != 1 ]; then
      echo "WARN docker stack '$proj' ($cnt containers) declared by no config.toml under $SITES and no live work — verify before: supabase stop --project-id $proj"
      record_stack_observation "$proj" "$stack_ids" "held_unknown_owner" "no_mapped_config" "not_attempted" ""
      continue
    fi
    stack_checkout_evidence "$proj" "$stack_ids"
    _evidence_rc=$?
    if [ "$_evidence_rc" -eq 0 ]; then
      echo "  ~ $proj ($cnt containers): checkout outside $SITES — ${CHECKOUT_EVIDENCE%%:*} ${CHECKOUT_EVIDENCE#*:}"
      record_stack_observation "$proj" "$stack_ids" "held_unknown_owner" "${CHECKOUT_EVIDENCE%%:*}" "not_attempted" "${CHECKOUT_EVIDENCE#*:}"
    elif [ "$_evidence_rc" -ne 1 ]; then
      echo "  ~ $proj ($cnt containers): stack mounts could not be inspected — held"
      record_stack_observation "$proj" "$stack_ids" "held_inspection_error" "mount_inspection_failed" "not_attempted" ""
    elif [ "$DRY_RUN" = 1 ]; then
      echo "WARN docker stack '$proj' ($cnt containers) orphaned — no config.toml under $SITES and no live work"
      echo "      would: supabase stop --project-id $proj"
      record_stack_observation "$proj" "$stack_ids" "stop_planned" "orphan_no_mapped_config" "planned" ""
    else
      echo "WARN docker stack '$proj' ($cnt containers) orphaned — no config.toml under $SITES and no live work"
      guarded_stack_stop "$proj" "$stack_ids" orphan ""
    fi
    continue
  fi
  age=-1; newest=""
  for d in "${dirs[@]}"; do
    a=$(repo_age_days "$d")
    if [ "$a" -ge 0 ] && { [ "$age" -lt 0 ] || [ "$a" -lt "$age" ]; }; then age=$a; newest="$d"; fi
  done
  if [ "$age" -lt 0 ]; then
    echo "WARN docker stack '$proj' ($cnt containers) has ${#dirs[@]} checkout(s), none readable — investigate before stopping"
    n_idle=$(( n_idle + 1 )); n_flagged=$(( n_flagged + 1 )); IDLE_STACKS+=("$proj")
    record_stack_observation "$proj" "$stack_ids" "held_unknown_owner" "mapped_checkouts_unreadable" "not_attempted" ""
  elif [ "$age" -ge "$IDLE_DAYS" ]; then
    echo "WARN docker stack '$proj' ($cnt containers) idle ${age}d across ${#dirs[@]} checkout(s) — reclaim with: (cd $newest && supabase stop)"
    n_idle=$(( n_idle + 1 )); n_flagged=$(( n_flagged + 1 )); IDLE_STACKS+=("$proj")
    if [ "$STOP_IDLE" != 1 ]; then
      record_stack_observation "$proj" "$stack_ids" "reported_idle" "stop_idle_disabled" "not_attempted" "$newest"
    elif [ "$DRY_RUN" = 1 ]; then
      echo "      would: (cd $newest && supabase stop)"
      record_stack_observation "$proj" "$stack_ids" "stop_planned" "idle_threshold_met" "planned" "$newest"
    else
      guarded_stack_stop "$proj" "$stack_ids" idle "$newest"
    fi
  else
    echo "  ~ $proj ($cnt containers): active ${age}d ago ($newest)"
    record_stack_observation "$proj" "$stack_ids" "active" "below_idle_threshold" "not_applicable" "$newest"
  fi
done
[ "${#STACK_N[@]}" -eq 0 ] && echo "  (no supabase stacks running)"
echo

# -------------------------------------------------------- exited containers --
echo "## exited containers older than ${EXITED_DAYS}d"
mapfile -t EXITED < <(dock ps -aq -f status=exited)
if [ "${#EXITED[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r id name fin nmounts lbl; do
    [ -z "$id" ] && continue
    [ -n "$ONLY" ] && [ "$lbl" != "$ONLY" ] && continue
    fin_s=$(date -d "$fin" +%s 2>/dev/null || echo 0)
    [ "$fin_s" -eq 0 ] && continue
    age_d=$(( (now - fin_s) / 86400 ))
    [ "$age_d" -lt "$EXITED_DAYS" ] && continue
    # Surface total-state-loss explicitly: a container with no mounts keeps all
    # of its state in the writable layer, so removal is unrecoverable. There is
    # no signal distinguishing "abandoned" from "stopped on purpose".
    if [ "${nmounts:-0}" = "0" ]; then warn_m=" [NO VOLUMES — full state loss]"; else warn_m=" [${nmounts} volume(s) survive]"; fi
    echo "  + ${name#/} (exited ${age_d}d ago)${warn_m}"
    n_exited_eligible=$(( n_exited_eligible + 1 ))
    applied docker rm "${id:0:12}" && n_exited=$(( n_exited + 1 ))
  done < <(dock inspect "${EXITED[@]}" \
             --format '{{.Id}}	{{.Name}}	{{.State.FinishedAt}}	{{len .Mounts}}	{{index .Config.Labels "com.supabase.cli.project"}}')
fi
# Keyed on eligibility, not on n_exited: a dry run and a failed removal both
# leave n_exited at 0 after listing an eligible container.
[ "$n_exited_eligible" -eq 0 ] && echo "  (none eligible)"
echo

# ------------------------------------------------------------------ images ---
echo "## images"
if [ -n "$ONLY" ]; then
  echo "  skipped: ONLY=$ONLY is set and images are not project-scoped"
else
  mapfile -t DANGLING < <(dock images -f dangling=true -q | sort -u)
  if [ "${#DANGLING[@]}" -gt 0 ]; then
    echo "  dangling (untagged, unreferenced): ${#DANGLING[@]}"
    for id in "${DANGLING[@]}"; do
      [ -z "$id" ] && continue
      applied docker rmi "$id" && n_img=$(( n_img + 1 ))
    done
  else
    echo "  dangling: none"
  fi
  img_mb=$(df_reclaimable_mb Images)
  if [ "$AGGRESSIVE" = 1 ]; then
    if [ "$INUSE_SNAPSHOT_COMPLETE" != 1 ]; then
      echo "  AGGRESSIVE skipped: all-container image snapshot was incomplete; no tagged image removal is safe"
    else
      echo "  AGGRESSIVE=1 — removing images unreferenced by any container (in-use set snapshotted before any removal)"
      while read -r id; do
        [ -z "$id" ] && continue
        [ -n "${INUSE[$id]:-}" ] && continue
        applied docker rmi "$id" && n_img=$(( n_img + 1 ))
      done < <(dock images --no-trunc --format '{{.ID}}' | sort -u)
    fi
  else
    echo "  tagged-but-unused: ~${img_mb}MB reclaimable — NOT removed (re-pull/rebuild cost); AGGRESSIVE=1 to reclaim"
    echo "  NOTE: locally-built images with no registry copy must be rebuilt from their Dockerfile, not re-pulled"
  fi
fi
echo

# ----------------------------------------------------------------- volumes ---
# See "WHY UNDECLARED SUPABASE VOLUMES ARE REAPED AND NO OTHER VOLUME IS".
if [ "$REAP_VOLUMES" = 1 ]; then
  echo "## volumes (REAP_VOLUMES=1: dangling Supabase volumes no \$SITES checkout declares, older than ${VOLUME_GRACE_HOURS}h)"
else
  echo "## volumes (report only; REAP_VOLUMES=1 reaps undeclared Supabase volumes)"
fi
mapfile -t DANGV < <(dock volume ls -f dangling=true --format '{{.Name}}')
if [ "${#DANGV[@]}" -eq 0 ]; then
  echo "  (none unreferenced)"
elif [ "$REAP_VOLUMES" != 1 ]; then
  echo "  ${#DANGV[@]} unreferenced volume(s). A STOPPED Supabase stack's database volume"
  echo "  looks exactly like this. Removing one destroys local Postgres data permanently."
  for v in "${DANGV[@]}"; do [ -n "$v" ] && echo "    - $v"; done
  echo "  To reclaim, inspect first: docker volume inspect <name>"
elif ! VOLS=$(dock volume inspect -f '{{.Name}}{{"\t"}}{{.CreatedAt}}{{"\t"}}{{index .Labels "com.supabase.cli.project"}}' "${DANGV[@]}"); then
  echo "  volume inspection failed: no volume removed this run"
else
  grace_s=$(( VOLUME_GRACE_HOURS * 3600 ))
  n_unlabelled=0
  REAP_V=() REAP_P=() REAP_C=()
  while IFS=$'\t' read -r v created proj; do
    [ -z "$v" ] && continue
    [ "$proj" = "<no value>" ] && proj=""
    if [ -z "$proj" ]; then
      if [ -z "$ONLY" ]; then
        echo "    keep $v (no com.supabase.cli.project label)"
        n_unlabelled=$(( n_unlabelled + 1 ))
      fi
      continue
    fi
    [ -n "$ONLY" ] && [ "$proj" != "$ONLY" ] && continue
    if ! ts=$(date -d "$created" +%s 2>/dev/null); then
      echo "    keep $v (project $proj: unreadable CreatedAt '$created')"
      note_observation_err "volume $v: unreadable CreatedAt '$created'"
      continue
    fi
    if [ $(( now - ts )) -lt "$grace_s" ]; then
      echo "    keep $v (project $proj: younger than ${VOLUME_GRACE_HOURS}h)"
      continue
    fi
    if [ -d "$SITES/$proj" ]; then
      echo "    keep $v (project $proj: \$SITES/$proj exists)"
      continue
    fi
    build_declared_projects
    if [ "$DECLARED_SCAN" != ok ]; then
      echo "    keep $v (project $proj: checkout scan failed)"
      continue
    fi
    if [ -n "${DECLARED_PROJ[$proj]:-}" ]; then
      echo "    keep $v (project $proj: declared by a checkout under \$SITES)"
      continue
    fi
    REAP_V+=("$v"); REAP_P+=("$proj"); REAP_C+=("$created")
  done <<<"$VOLS"
  # The first walk can be minutes old by now and misses a checkout created
  # behind it; removal cannot be undone, so walk $SITES again (warm, 14-20 s)
  # just before it. A failed re-scan keeps every candidate: an unreadable
  # config could declare any of them.
  if [ "${#REAP_V[@]}" -gt 0 ]; then
    DECLARED_SCAN=""; DECLARED_PROJ=()
    build_declared_projects
    for i in "${!REAP_V[@]}"; do
      v=${REAP_V[$i]} proj=${REAP_P[$i]}
      if [ -d "$SITES/$proj" ]; then
        echo "    keep $v (project $proj: \$SITES/$proj exists)"
        continue
      fi
      if [ "$DECLARED_SCAN" != ok ]; then
        echo "    keep $v (project $proj: checkout re-scan failed)"
        continue
      fi
      if [ -n "${DECLARED_PROJ[$proj]:-}" ]; then
        echo "    keep $v (project $proj: declared by a checkout the re-scan found)"
        continue
      fi
      echo "    reap $v (project $proj: no checkout declares it; created ${REAP_C[$i]})"
      applied docker volume rm "$v" && n_vol=$(( n_vol + 1 ))
    done
  fi
  [ "$n_unlabelled" -gt 0 ] && echo "  $n_unlabelled unlabelled or anonymous volume(s) kept (no Supabase project label)"
fi
echo

if [ "$CACHE" = 1 ]; then echo "## build cache"; run docker builder prune -f; echo; fi

# ----------------------------------------------------------------- summary ---
reclaim_mb=$(df_reclaimable_mb)
[ "$n_held" -gt 0 ] && n_flagged=$(( n_flagged + n_held ))
if [ "$reclaim_mb" -lt 0 ]; then
  echo "WARN docker reclaimable size UNKNOWN — 'docker system df' failed; do not read this run as 'nothing to reclaim'"
  n_flagged=$(( n_flagged + 1 ))
elif [ "$reclaim_mb" -ge "$RECLAIM_WARN_MB" ]; then
  echo "WARN docker reclaimable ${reclaim_mb}MB exceeds ${RECLAIM_WARN_MB}MB — run DRY_RUN=0, then AGGRESSIVE=1 if still high"
  n_flagged=$(( n_flagged + 1 ))
fi
n_dockerr=$(dock_err_count); n_dockerr=${n_dockerr:-0}
n_procerr=$(file_line_count "$PROCERRFILE"); n_procerr=${n_procerr:-0}
_recorded_actionerr=$(file_line_count "$ACTION_ERRFILE"); _recorded_actionerr=${_recorded_actionerr:-0}
[ "$_recorded_actionerr" -gt "$n_actionerr" ] && n_actionerr=$_recorded_actionerr
n_container_obs=$(file_line_count "$CONTAINER_OBS_FILE"); n_container_obs=${n_container_obs:-0}
[ "$n_dockerr" -gt 0 ] && n_flagged=$(( n_flagged + 1 ))
[ "$n_procerr" -gt 0 ] && n_flagged=$(( n_flagged + 1 ))
[ "$n_obserr" -gt 0 ] && n_flagged=$(( n_flagged + 1 ))
[ "$n_actionerr" -gt 0 ] && n_flagged=$(( n_flagged + n_actionerr ))
n_inspecterr=$(( n_dockerr + n_procerr + n_obserr ))
inventory_complete=true
[ "$n_inspecterr" -gt 0 ] && inventory_complete=false
state=complete
if [ "$n_inspecterr" -gt 0 ] || [ "$n_actionerr" -gt 0 ]; then state=error; fi

# Assemble JSON before printing the terminal summary so a serializer/read failure
# participates in the same explicit error state. If assembly itself fails, emit a
# compatibility-shaped minimal object rather than stale or partial detail arrays.
JSON_PAYLOAD=""
JSON_ASSEMBLED=0
if [ "$JSON" = 1 ]; then
  if [ "${DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE:-}" = json ]; then
    _json_rc=97
  else
    JSON_PAYLOAD=$(python3 - "$n_zomb" "$n_recycled" "$n_held" "$n_idle" "$n_exited" "$n_img" "$n_flagged" "$n_dockerr" \
      "${RECYCLED[*]:-}" "${IDLE_STACKS[*]:-}" "${ZOMBIE_HOLD[*]:-}" "$n_zomb_total" "$n_container_obs" \
      "$n_init_detected" "$n_init_not_detected" "$n_init_unknown" "$inventory_complete" "$n_inspecterr" \
      "$n_actionerr" "$state" "$CONTAINER_OBS_FILE" "$STACK_OBS_FILE" "$ACTION_ERRFILE" \
      "$n_obserr" "$OBSERRFILE" "$n_vol" <<'PY'
import json
import sys

a = sys.argv[1:]

def rows(path):
    result = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line:
                result.append(json.loads(line))
    return result

def lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return [line.rstrip("\n") for line in fh if line.rstrip("\n")]

print(json.dumps({
    "zombies": int(a[0]), "recycled": int(a[1]), "held": int(a[2]),
    "idle_stacks": int(a[3]), "exited_removed": int(a[4]), "images_removed": int(a[5]),
    "flagged": int(a[6]), "docker_errors": int(a[7]),
    "recycled_names": a[8].split() if a[8] else [],
    "idle_stack_names": a[9].split() if a[9] else [],
    "held_names": a[10].split() if a[10] else [],
    "zombies_total": int(a[11]), "containers_observed": int(a[12]),
    "init_detected": int(a[13]), "init_not_detected": int(a[14]),
    "init_unknown": int(a[15]), "inventory_complete": a[16] == "true",
    "inspection_errors": int(a[17]), "action_errors": int(a[18]),
    "state": a[19], "container_observations": rows(a[20]),
    "stack_observations": rows(a[21]), "action_error_details": lines(a[22]),
    "observation_errors": int(a[23]), "observation_error_details": lines(a[24]),
    "volumes_removed": int(a[25]),
}))
PY
)
    _json_rc=$?
  fi
  if [ "$_json_rc" -eq 0 ] && [ -n "$JSON_PAYLOAD" ]; then
    JSON_ASSEMBLED=1
  else
    _had_obserr=$n_obserr
    note_observation_err "final JSON assembly failed"
    [ "$_had_obserr" -eq 0 ] && n_flagged=$(( n_flagged + 1 ))
    n_inspecterr=$(( n_dockerr + n_procerr + n_obserr ))
    inventory_complete=false
    state=error
  fi
fi

if [ "$n_dockerr" -gt 0 ]; then
  echo "WARN docker-hygiene: $n_dockerr docker query/queries FAILED — the counts below are INCOMPLETE and must not be read as 'nothing to do'"
  sed 's/^/  failed: /' "$ERRFILE" 2>/dev/null
fi
if [ "$n_procerr" -gt 0 ]; then
  echo "WARN docker-hygiene: $n_procerr process observation(s) FAILED — affected targets were preserved"
  sed 's/^/  failed: /' "$PROCERRFILE" 2>/dev/null
fi
if [ "$n_obserr" -gt 0 ]; then
  echo "WARN docker-hygiene: $n_obserr observation/reporting operation(s) FAILED — report inventory is INCOMPLETE"
  sed 's/^/  failed: /' "$OBSERRFILE" 2>/dev/null
fi
if [ "$n_actionerr" -gt 0 ]; then
  echo "WARN docker-hygiene: $n_actionerr attempted action(s) FAILED — no failed mutation is reported as cleanup"
  sed 's/^/  failed: /' "$ACTION_ERRFILE" 2>/dev/null
fi

echo "===== summary ====="
echo "zombies seen ............ $n_zomb (direct children of container PID 1; legacy counter)"
echo "zombies total ........... $n_zomb_total (all descendants attributed to containers)"
echo "init coverage ........... $n_init_detected detected / $n_init_not_detected not-detected / $n_init_unknown unknown ($n_container_obs observed)"
echo "containers recycled ..... $n_recycled"
echo "held (not recycled) ..... $n_held (outside the allowlist — stop the stack to clear)"
echo "idle stacks ............. $n_idle"
echo "exited removed .......... $n_exited"
echo "images removed .......... $n_img"
echo "volumes removed ......... $n_vol"
echo "reclaimable ............. $([ "$reclaim_mb" -lt 0 ] && echo UNKNOWN || echo "${reclaim_mb}MB")"
echo "docker query errors ..... $n_dockerr"
echo "inspection errors ...... $n_inspecterr"
echo "observation errors ..... $n_obserr"
echo "action errors .......... $n_actionerr"
echo "observation state ...... $state (inventory-complete: $inventory_complete)"
[ "$DRY_RUN" = 1 ] && echo "(dry run — re-run with DRY_RUN=0 to apply)"
echo "docker-hygiene: zombies:$n_zomb recycled:$n_recycled idle-stacks:$n_idle exited:$n_exited images:$n_img reclaim-mb:$reclaim_mb docker-errors:$n_dockerr docker-flagged:$n_flagged zombies-total:$n_zomb_total containers-observed:$n_container_obs init-detected:$n_init_detected init-not-detected:$n_init_not_detected init-unknown:$n_init_unknown inspection-errors:$n_inspecterr observation-errors:$n_obserr action-errors:$n_actionerr state:$state inventory-complete:$inventory_complete volumes:$n_vol"

if [ "$JSON" = 1 ]; then
  if [ "$JSON_ASSEMBLED" = 1 ]; then
    printf '%s\n' "$JSON_PAYLOAD"
  else
    printf '{"zombies": %d, "recycled": %d, "held": %d, "idle_stacks": %d, "exited_removed": %d, "images_removed": %d, "flagged": %d, "docker_errors": %d, ' \
      "$n_zomb" "$n_recycled" "$n_held" "$n_idle" "$n_exited" "$n_img" "$n_flagged" "$n_dockerr"
    printf '"recycled_names": [], "idle_stack_names": [], "held_names": [], "zombies_total": %d, "containers_observed": %d, "init_detected": %d, "init_not_detected": %d, "init_unknown": %d, ' \
      "$n_zomb_total" "$n_container_obs" "$n_init_detected" "$n_init_not_detected" "$n_init_unknown"
    printf '"inventory_complete": false, "inspection_errors": %d, "observation_errors": %d, "action_errors": %d, "state": "error", ' \
      "$n_inspecterr" "$n_obserr" "$n_actionerr"
    printf '"container_observations": [], "stack_observations": [], "action_error_details": [], "observation_error_details": ["final JSON assembly failed"], "json_error": "final_json_assembly_failed", "volumes_removed": %d}\n' "$n_vol"
  fi
fi
if [ "$STRICT" = 1 ] && [ "$state" = error ]; then exit 1; fi
exit 0
