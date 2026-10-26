#!/usr/bin/env bash
# Sourced PR-owner state contract (U1). Paths and v1 fields are shared with
# recovery and the completion check. Heartbeat deadlines are Unix seconds.
# All durable writes go through this library; readers see old or new JSON,
# never a partially written record. No credentials belong in these records.

pr_owner_key() {
  local slug=$1 pr=$2
  [[ "$slug" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
  slug=${slug,,}
  printf '%s--%s\n' "${slug/\//--}" "$pr"
}

pr_owner_state_dir() {
  local key
  key=$(pr_owner_key "$1" "$2") || return 1
  printf '%s/.claude/.loop-state/pr-owner/%s\n' "$HOME" "$key"
}

pr_owner_unit() {
  local key
  key=$(pr_owner_key "$1" "$2") || return 1
  printf 'pr-owner-%s\n' "$key"
}

pr_owner_unit_active() { systemctl --user is-active --quiet "$1" >/dev/null 2>&1; }

# pr_owner_code_id <scripts-dir> [<file>=<path>]...: the digests of the files a
# running owner executes from memory, both scripts and the libraries they
# source. bash keeps reading the copy it opened, so a merge that replaces one
# reaches a live owner only through a new process (dotfiles#1635). Each
# <file>=<path> reads that file from <path> instead, a descriptor holding the
# copy the caller loaded. Prints nothing when a digest cannot be made, an
# unreadable <path> included; callers then skip the comparison.
pr_owner_code_id() {
  local dir=$1 file from over sum ids=''
  shift
  for file in pr-owner.sh pr-owner-merge-evidence.sh lib/pr-owner-review-select.py pro-gate-loop.sh lib/pr-owner-state.sh lib/ci-current-check-runs.sh lib/ci-stall-classify.sh lib/headless-gateway-model.sh; do
    from=$dir/$file sum=absent
    for over; do
      if [ "${over%%=*}" = "$file" ]; then from=${over#*=}; [ -e "$from" ] || return 0; fi
    done
    if [ -e "$from" ]; then sum=$(sha256sum 2>/dev/null <"$from") || return 0; fi
    ids+="${sum%% *}:$file "
  done
  printf '%s\n' "$ids"
}

# The owner runs the installed harness scripts, never a PR checkout's copy:
# a fenced fix session can edit and push its worktree, and the owner holds
# merge authority outside that fence.
pr_owner_installed_script() {
  local dir
  dir=$(readlink -f -- "$HOME/.claude/scripts") || return 1
  [ -f "$dir/$1" ] || return 1
  printf '%s/%s\n' "$dir" "$1"
}

pr_owner_prepare() (
  umask 077
  mkdir -p -- "$1" && chmod 700 -- "$1"
)

# pr_owner_new_record <repo> <pr> <head> <worktree> <environment-JSON> <now>
pr_owner_new_record() {
  local unit
  unit=$(pr_owner_unit "$1" "$2") || return 1
  jq -c --arg repo "$1" --argjson pr "$2" --arg head "$3" --arg worktree "$4" \
    --arg unit "$unit" --argjson now "$6" \
    '. as $environment | {schema:"pr-owner/v1",repo:$repo,pr:$pr,state:"owned",head:$head,unit:$unit,
      worktree:$worktree,environment:$environment,restart_log:[],totals:{restarts:0,rounds:0,fixes:0},
      created_at:$now,updated_at:$now,ended_at:null}' <<<"$5"
}

# pr_owner_write_record <directory> <record> <JSON>
pr_owner_write_record() (
  local dir=$1 record=$2 payload=$3 tmp
  case "$record" in owner|handoff|heartbeat|loop-state|stop|ci-progress) ;; *) return 1 ;; esac
  umask 077
  pr_owner_prepare "$dir" || return 1
  tmp=$(mktemp "$dir/.$record.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  printf '%s\n' "$payload" | jq -e 'select(type == "object")' >"$tmp" || return 1
  mv -f -- "$tmp" "$dir/$record.json" || return 1
  # Only a running owner installs this observer. Existing launcher and loop
  # callers remain inert. Synchronous observation lets the owner stop a fix
  # or Pro dispatch when its pre-effect heartbeat sees a closed/merged PR.
  if [ -n "${PR_OWNER_OBSERVER:-}" ]; then
    case "$record" in
      heartbeat|loop-state) bash "$PR_OWNER_OBSERVER" observe "$dir" "$record" ;;
    esac
  fi
)

pr_owner_write() { pr_owner_write_record "$1" owner "$2"; }
pr_owner_read() { jq -e 'select(type == "object")' "$1/owner.json"; }

# owner.json is the handoff commit point. Until it selects a new immutable
# generation, recovery keeps the old context/check, including legacy records.
pr_owner_handoff_path() {
  local dir=$1 owner generation
  if [ "$#" -ge 2 ]; then owner=$2; else owner=$(pr_owner_read "$dir") || return 1; fi
  generation=$(jq -er '
    if has("handoff_generation") then .handoff_generation | select(type == "string" and test("^handoff\\.[A-Za-z0-9]+$"))
    else "legacy" end' <<<"$owner") || return 1
  if [ "$generation" = legacy ]; then printf '%s/handoff.json\n' "$dir";
  else printf '%s/%s/handoff.json\n' "$dir" "$generation"; fi
}

# The loop's comments are local; only the owner may publish them to the PR.
pr_owner_comment() (
  local dir=$1 name=$2 tmp
  [[ "$name" =~ ^[a-z-]+$ ]] || return 1
  umask 077
  pr_owner_prepare "$dir" || return 1
  tmp=$(mktemp "$dir/.comment.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  cat >"$tmp" && mv -f -- "$tmp" "$dir/comment-$name.md"
)

pr_owner_clear_stop() { rm -f -- "$1/stop.json"; }

# Terminal cleanup belongs here too; durable records and stop evidence remain.
pr_owner_clear_work() { rm -rf -- "$1/work"; }

# A new handoff after a terminal outcome starts a fresh loop: the old run's
# counters, CI watch, stop record and local comments must not carry over.
pr_owner_clear_run() {
  rm -f -- "$1/loop-state.json" "$1/ci-progress.json" "$1/stop.json" "$1"/comment-*.md
  pr_owner_clear_work "$1"
}

pr_owner_heartbeat() {
  local payload
  [[ "$3" =~ ^[0-9]+$ ]] || return 1
  payload=$(jq -nc --arg phase "$2" --argjson deadline "$3" \
    '{phase:$phase, deadline:$deadline}') || return 1
  pr_owner_write_record "$1" heartbeat "$payload"
}

# The heartbeat deadline as a non-negative integer, or failure.
pr_owner_deadline() {
  local deadline
  deadline=$(jq -er '.deadline | select(type == "number")' "$1/heartbeat.json" 2>/dev/null) || return 1
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$deadline"
}

pr_owner_live() {
  local unit deadline
  unit=$(jq -er '.unit | select(type == "string" and startswith("pr-owner-"))' "$1/owner.json" 2>/dev/null) || return 1
  deadline=$(pr_owner_deadline "$1") || return 1
  [ "$deadline" -gt "$(date +%s)" ] && pr_owner_unit_active "$unit"
}

# CI check-run watch shared by the owned loop and the merge wait. A check's
# clock restarts whenever its status or conclusion changes; a head with no
# run, or a pending run unchanged this long, becomes a CI finding.
PR_OWNER_CI_NO_RUN_SECS=1800
PR_OWNER_CI_STALE_SECS=21600
# pr_owner_ci_track <dir> <sha> <since> <old-tracks> <checks> <now>
# Records ci-progress and prints the new per-check tracks.
pr_owner_ci_track() {
  local tracks payload
  # Shell builtins write the variable-sized arrays/maps to stdin: neither a
  # single check output nor a many-check map may become an exec argument.
  tracks=$(printf '%s\n' "$4" "$5" | jq -sc --argjson now "$6" '
    .[0] as $old | .[1] as $checks |
    reduce $checks[] as $c ({};
      ($c.id // $c.name // "unknown check" | tostring) as $key |
      ($c | {status,conclusion} | tojson) as $fingerprint |
      .[$key] = {fingerprint:$fingerprint,since:(if $old[$key].fingerprint == $fingerprint then $old[$key].since else $now end)})') || return 1
  payload=$(jq -c --arg head "$2" --argjson since "$3" '{head:$head,since:$since,checks:.}' <<<"$tracks") || return 1
  pr_owner_write_record "$1" ci-progress "$payload" || return 1
  printf '%s\n' "$tracks"
}
# pr_owner_ci_no_run <total> <since> <now>: no run past the no-run bound.
pr_owner_ci_no_run() { [ "$1" = 0 ] && [ "$(($3 - $2))" -ge "$PR_OWNER_CI_NO_RUN_SECS" ]; }
# Check runs that stay unreadable this long (expired auth, a renamed repo)
# end the wait as a typed stop instead of polling forever while heartbeating.
PR_OWNER_CI_UNREADABLE_SECS=3600
# pr_owner_ci_unreadable <failing-since> <now>
pr_owner_ci_unreadable() { [ "$(($2 - $1))" -ge "$PR_OWNER_CI_UNREADABLE_SECS" ]; }
# Completed runs that did not pass, one JSON object per line.
pr_owner_ci_red() {
  jq -c '.[] | select(.status == "completed" and (.conclusion | IN("success","neutral","skipped") | not))' <<<"$1"
}
# pr_owner_ci_stale <checks> <tracks> <now>: pending runs past the stale bound.
pr_owner_ci_stale() {
  printf '%s\n' "$2" "$1" | jq -sc --argjson now "$3" --argjson limit "$PR_OWNER_CI_STALE_SECS" '
    .[0] as $tracks | .[1][] | select(.status != "completed") |
    (.id // .name // "unknown check" | tostring) as $key |
    select($now - $tracks[$key].since >= $limit)'
}

# Used at handoff and before recovery replays the snapshot. Print only the
# offending key, never its value. Resolve HOME from the service user's
# account, not from the environment being validated. A PATH entry inside the
# owned worktree is refused: fix sessions edit and push that tree, and the
# owner resolves gh and git through PATH with merge authority.
pr_owner_validate_environment() {
  local snapshot=$1 worktree=${2:-} service_home settings expected_home expected_url path entry actual
  service_home=$(getent passwd "$(id -u)" | cut -d: -f6) || return 1
  actual=$(jq -er '.HOME | select(type == "string")' <<<"$snapshot") || { echo HOME; return 1; }
  [ -n "$service_home" ] && [ "$actual" = "$service_home" ] || { echo HOME; return 1; }
  settings="$service_home/.claude/settings.json"
  expected_home="$service_home/.pro-review-daemon" expected_url=""
  if [ -f "$settings" ]; then
    expected_home=$(jq -er --arg default "$expected_home" '.env.PRO_GATE_HOME // $default | select(type == "string")' "$settings") || { echo PRO_GATE_HOME; return 1; }
    expected_url=$(jq -er '.env.ANTHROPIC_BASE_URL // "" | select(type == "string")' "$settings") || { echo ANTHROPIC_BASE_URL; return 1; }
  fi
  jq -e 'type == "object" and (keys - ["PATH","HOME","PRO_GATE_HOME","PRO_GATE_ROUND_GUARD","ANTHROPIC_BASE_URL","XDG_RUNTIME_DIR"] | length) == 0 and all(.[]; type == "string")' \
    <<<"$snapshot" >/dev/null || { echo 'environment keys'; return 1; }
  # Optional, so records written before the owner carried it still recover.
  # When present it must be the service user's own runtime directory.
  if jq -e 'has("XDG_RUNTIME_DIR")' <<<"$snapshot" >/dev/null; then
    actual=$(jq -r '.XDG_RUNTIME_DIR' <<<"$snapshot")
    [ "$actual" = "/run/user/$(id -u)" ] || { echo XDG_RUNTIME_DIR; return 1; }
  fi
  path=$(jq -er '.PATH | select(type == "string" and length > 0)' <<<"$snapshot") || { echo PATH; return 1; }
  # Empty components (including a trailing colon) mean the current directory.
  while :; do
    entry=${path%%:*}
    [[ "$entry" = /* ]] || { echo PATH; return 1; }
    [[ -z "$worktree" || ( "$entry" != "$worktree" && "$entry" != "$worktree"/* ) ]] || { echo PATH; return 1; }
    [[ "$path" = *:* ]] || break
    path=${path#*:}
  done
  actual=$(jq -r '.PRO_GATE_HOME // ""' <<<"$snapshot")
  [ "$actual" = "$expected_home" ] || { echo PRO_GATE_HOME; return 1; }
  actual=$(jq -r '.ANTHROPIC_BASE_URL // ""' <<<"$snapshot")
  [ "$actual" = "$expected_url" ] || { echo ANTHROPIC_BASE_URL; return 1; }
}

# pr_owner_command <validated-environment-JSON> <owner-script> <state-dir>
# NUL-delimited argv, shared with recovery. --setenv alone cannot clear the
# systemd user manager's environment; env -i is the allowlist boundary.
pr_owner_command() {
  jq -j --arg script "$2" --arg dir "$3" \
    '["/usr/bin/env","-i"] + (to_entries | map(.key + "=" + .value)) +
     [$script,"run",$dir] | .[] + "\u0000"' <<<"$1"
}

# Recovery runs a short transaction under the same directory lock as handoff.
# Re-read before writing: a lifecycle owner may have already ended the record.
pr_owner_recovery_restart() {
  local dir=$1 now=$2 payload
  payload=$(pr_owner_read "$dir") || return 1
  [ "$(jq -r '.state' <<<"$payload")" = owned ] || return 1
  payload=$(jq -c --argjson now "$now" '
    .restart_log = ((.restart_log // []) + [$now]) |
    .totals.restarts = ((.totals.restarts // 0) + 1) | .updated_at = $now' <<<"$payload") || return 1
  pr_owner_write "$dir" "$payload"
}

# A refused service start is not a relaunch; preserve any lifecycle edits.
pr_owner_recovery_unstarted() {
  local dir=$1 now=$2 payload
  payload=$(pr_owner_read "$dir") || return 1
  payload=$(jq -c --argjson now "$now" '
    if .restart_log[-1] == $now then
      .restart_log = .restart_log[:-1] | .totals.restarts -= 1
    else . end' <<<"$payload") || return 1
  pr_owner_write "$dir" "$payload"
}

# Resumes a stop-merge park may spend (R5): the recovery pass, this lib and
# the resumed owner all read the cap from here.
PR_OWNER_RESUME_MAX=2

# pr_owner_resume_begin <dir> <now> <head> <cause> <run-id>: turn a finished
# stop-merge park back into an owner, at most PR_OWNER_RESUME_MAX times per
# record. The caller holds the directory lock. The new owner starts with a
# fresh ready-flip budget and a spent merge rerun budget, so a resumed head
# gets one ready cycle and no rerun. Prints the record it replaced for
# pr_owner_resume_unstarted; a refusal prints and writes nothing.
pr_owner_resume_begin() {
  local dir=$1 now=$2 head=$3 cause=$4 run=$5 payload next
  payload=$(pr_owner_read "$dir") || return 1
  jq -e --argjson max "$PR_OWNER_RESUME_MAX" '.state == "parked" and .park_pending != true and ((.resume_log // []) | length) < $max' \
    <<<"$payload" >/dev/null || return 1
  next=$(jq -c --argjson now "$now" --arg head "$head" --arg cause "$cause" --arg run "$run" '
    (if $run == "" then null else ($run | tonumber) end) as $run_id |
    (((.resume_log // []) | length) + 1) as $attempt |
    {attempt: $attempt, head: $head, cause: $cause, run_id: $run_id, at: $now} as $entry |
    .state = "owned" | .ended_at = null | .updated_at = $now |
    .resume = ($entry | .active = true | {active, attempt, head, cause, run_id, at}) |
    .resume_log = ((.resume_log // []) + [$entry]) |
    .ready_flips = {head: $head, count: 0} |
    .merge_ci_retry = {head: $head, count: 2, active: false} |
    del(.reason, .recovery_notified, .stop_merge.interrupted)' <<<"$payload") || return 1
  pr_owner_write "$dir" "$next" || return 1
  printf '%s\n' "$payload"
}

# A refused service start is not a resume: put back the record begin replaced.
pr_owner_resume_unstarted() { pr_owner_write "$1" "$2"; }

# pr_owner_resume_class <dir> <now> <verdict> <run-id>: cache the recovery
# verdict for the stored red, so a later pass need not read GitHub again.
# An empty run id records a null run. The park clock is left alone.
pr_owner_resume_class() {
  local dir=$1 now=$2 verdict=$3 run=$4 payload
  payload=$(pr_owner_read "$dir") || return 1
  payload=$(jq -c --argjson now "$now" --arg verdict "$verdict" --arg run "$run" '
    .resume_class = {head: .ready_red.head, flip: .ready_red.flip, verdict: $verdict,
      run_id: (if $run == "" then null else ($run | tonumber) end), at: $now} |
    .updated_at = $now' <<<"$payload") || return 1
  pr_owner_write "$dir" "$payload"
}

pr_owner_recovery_notified() {
  local payload
  payload=$(pr_owner_read "$1") || return 1
  payload=$(jq -c '.recovery_notified = true' <<<"$payload") || return 1
  pr_owner_write "$1" "$payload"
}

# Caller holds the directory transaction lock. A newer handoff supersedes an
# old terminal record even if its owner record has not been installed yet.
pr_owner_expire() {
  local dir=$1 now=$2 owner handoff='{}'
  owner=$(pr_owner_read "$dir") || return 1
  [ ! -f "$dir/handoff.json" ] || handoff=$(jq -e 'select(type == "object")' "$dir/handoff.json") || return 1
  printf '%s\n' "$handoff" "$owner" | jq -se --argjson now "$now" '
    .[0] as $handoff | .[1] |
    (.state | IN("merged","closed","parked","escalated","failed")) and
    (.ended_at | type == "number") and ($now - .ended_at > 2592000) and
    (($handoff.created_at // 0) <= .ended_at)' >/dev/null || return 0
  rm -rf -- "$dir"
}

# Read-only sweep predicate. Ownership outlives processes and timer pauses.
pr_owner_worktree_owned() {
  local record root="$HOME/.claude/.loop-state/pr-owner"
  [ -d "$root" ] || return 1
  for record in "$root"/*/owner.json; do
    [ -f "$record" ] || continue
    if jq -e --arg path "$1" '.state == "owned" and .worktree == $path' "$record" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# pr_owner_deferral_allow <dir> <head>: 0 when the typed stop is the runtime's
# FIX-FIRST allow with every open finding a deferred P2/P3 (pro-gate reason
# fix-first-deferred-p2-only, dotfiles#1863) at <head>. The loop records no
# SHIP status for it (pro-gate-loop.sh record_verdict), so the owner merges it
# on review-stop evidence (pr-owner-merge-evidence.sh) instead. The decision
# only routes: the evidence reader still takes the counts from the runtime's
# own review facts. A SHIP allow, or a decision missing, symlinked, outside
# <dir> or for another head, returns 1 and keeps the status path.
pr_owner_deferral_allow() {
  local dir=$1 head=$2 path root
  path=$(jq -er 'select(.exit_code == 0 and .reason == "allow-existing-merge-workflow") |
    .decision_path | select(type == "string" and startswith("/"))' "$dir/stop.json" 2>/dev/null) || return 1
  root=$(realpath -e -- "$dir") || return 1
  # A symlink anywhere on the path, not just at the leaf, refuses.
  if [ ! -f "$path" ] || [ -L "$path" ] || [ "$(realpath -m -s -- "$path")" != "$(realpath -m -- "$path")" ]; then return 1; fi
  case "$(realpath -m -- "$path")" in "$root"/*) ;; *) return 1 ;; esac
  jq -e --arg head "$head" '.action == "allow-existing-merge-workflow" and .reason == "fix-first-deferred-p2-only" and
    .facts.open_blocking == 0 and .facts.target.head_oid == $head' "$path" >/dev/null 2>&1
}
