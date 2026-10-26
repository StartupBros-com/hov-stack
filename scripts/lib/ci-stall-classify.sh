#!/usr/bin/env bash
# Sourced. Whether a head's red CI is only a runner stall (dotfiles#1605,
# ci-stall-classify.jq): every red check run is an Actions job in a workflow
# run whose runner stopped reporting. This reports evidence only; the caller
# chooses whether to replay that run, move the head or send it to a fixer.

CI_STALL_LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# ci_stall_only <owner/repo> [retry]: reads the red check runs on stdin, one JSON
# object per line (pr_owner_ci_red's output). For each Actions job it reads
# the job record and its check run's annotations (an Actions check run's id
# is its job's id). Prints one JSON object: the decision and each job it
# judged. Exits 0 when the red is stall-only, 1 when it is not or a record
# cannot be read; an unreadable record prints nothing. The optional retry mode
# recognizes additional lost-runner evidence for pr-owner's bounded same-head
# retries, not head-moving repair.
ci_stall_only() {
  local check id job ann out mode=${2:-stall}
  # Only pr-owner's bounded same-head retry opts in. pro-gate-loop keeps
  # the original evidence contract for its separate head-moving repair.
  [ "$mode" = stall ] || [ "$mode" = retry ] || return 1
  local -a jobs=()
  while IFS= read -r check; do
    [ -n "$check" ] || continue
    id=$(jq -r '.details_url // "" | capture("/actions/runs/[0-9]+/job/(?<id>[0-9]+)").id // empty' <<<"$check") || return 1
    if [ -z "$id" ]; then jobs+=(null); continue; fi
    job=$(gh api "repos/$1/actions/jobs/$id") || return 1
    ann=$(gh api "repos/$1/check-runs/$id/annotations" --paginate --slurp) || return 1
    job=$(printf '%s\n%s\n' "$job" "$ann" | jq -sc '.[0] + {annotations: [.[1][][]? | .message], annotation_records: [.[1][][]?]}') || return 1
    jobs+=("$job")
  done
  [ "${#jobs[@]}" -gt 0 ] || return 1
  # A job's step list is what tells a stall from a hang, and GitHub has served
  # #1660's capped core job with all 189 steps and with none within one minute
  # (2026-10-13). A record read without its steps is unreadable, not a
  # verdict, unless it needs no steps to read (ci_steps_unreadable): a job
  # cancelled before any runner took it, which GitHub serves with no runner
  # and a start equal to its queue time, or a job cancelled while queued
  # behind a stalled sibling, downstream of it. An unreadable read prints
  # nothing.
  out=$(printf '%s\n' "${jobs[@]}" | jq -sc -L "$CI_STALL_LIB" --arg mode "$mode" --arg repo "$1" 'include "ci-stall-classify";
    if ci_steps_unreadable then empty else
    (if $mode == "retry" then ci_lost_runner_explained($repo) else [] end) as $explained |
    {stall_only: (if $mode == "retry" then ci_retry_only($explained) else ci_stall_only end),
     jobs: [.[] | if . == null then null else . as $job | {id, name, run_id, conclusion, capped: ci_cap_cancelled, stalled: ci_stalled_job,
       head_sha, run_attempt, status,
       failed_steps: [.steps[]? | select((.conclusion // "") | IN("failure", "cancelled", "timed_out")) | {name, conclusion}]}
       + (if $mode == "retry" then {retryable: any($explained[]; .id == $job.id)} else {} end) end]} end') || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
  jq -e '.stall_only' <<<"$out" >/dev/null
}
