# The check runs that describe a head now (dotfiles#1595).
#
# GitHub keeps every check suite a commit has had. A re-trigger at the same
# head (an `edited` or `ready_for_review` event, a reopen) adds a suite beside
# the old one, and a concurrency group then cancels the old run. Counting
# every suite reads those cancellations as red at a head whose newest run is
# green; keeping one run per name in API order (newest first, last wins)
# keeps the oldest, which can be a green that no longer describes the head.
#
# Input: {check_runs: [...], workflow_runs: [...]}, unfiltered, from
# commits/<sha>/check-runs and actions/runs?head_sha=<sha>. A GitHub Actions
# check run is dropped only when its suite belongs to a listed workflow run
# that a newer-created run of the same workflow and event superseded. Check
# runs from other apps pass through unchanged; an Actions suite no listed
# workflow run claims means the listing is incomplete, and the read gives no
# verdict (below). Within a suite the check-runs endpoint already keeps the latest
# attempt; creation time, not the attempt's start, picks the run, so a re-run
# of a superseded run never displaces the run that replaced it.
#
# A finished run whose every check run was skipped (an `edited` run whose
# jobs filter that action out) tested nothing, so it supersedes nothing: the
# newest run that did not skip everything decides, and a group of only such
# runs falls back to its newest.
#
# A deciding run that has not finished, and whose listed check runs have all
# finished, stands in as one pending entry beside them: a job that `needs:`
# another gets its check run only once that job is done, so a finished green
# setup job alone would otherwise read as a green head while the jobs it gates
# are still to come. While a listed check run is pending it holds the head
# itself and no stand-in joins it, so a caller's stall clock (pr-owner-state.sh
# pr_owner_ci_track) follows rows that change as jobs move, not one row held
# constant for as long as the run lasts.
#
# A finished deciding run with no check run stands in too: pending when it
# finished green with no job listed (GitHub lists a check run for every job,
# skipped ones included, so that is a listing gap), so the suite it superseded
# cannot vouch for the head meanwhile; red when it finished failed (a startup
# failure, a run awaiting approval), so a broken workflow file never reads as
# an absent one. Each stand-in names its run in output.summary, the field a CI
# fixer is shown.
#
# $settle, GitHub epoch seconds: the PR update (a ready flip, a body edit)
# that starts new runs on repositories triggering on ready_for_review or
# edited. While $hold is true and no workflow run created at or after $settle
# is listed, one pending entry holds the head. The caller ends $hold on its own
# clock, so a repository with no such trigger waits a bounded time and a
# skewed local clock never compares against GitHub's.
#
# A listing that leaves a GitHub Actions suite unclaimed gives no verdict
# (dotfiles#1636). Every Actions suite at a head belongs to a run that
# actions/runs?head_sha= lists: none of 80 recent PR heads in a private app
# repository and dotfiles had one unclaimed on 2026-10-06. Five PR-owner reads
# on the members app's #4290 twice, #4302, #4263 and #4284 read a superseded run's cancelled rows as red, and an
# incomplete listing is the one way found for this filter to keep them: with
# the newer run missing, the cancelled run decides its group; with the older
# one missing, its suite passes through. Those reads' responses were not
# saved, so that cause is inferred. current_check_runs refuses such a pair,
# and the shell helper reads again.
# Rows from another app pass through as before, and so do rows naming no app,
# which the API never returns but the loop's test fixtures do. One gap stays
# invisible here: a listing that omits a newly created run with no check run
# yet leaves the run it superseded deciding, and nothing is unclaimed. None of
# the five reads is known to have had that shape.
def unclaimed_actions_suites:
  [(.workflow_runs // [])[].check_suite_id] as $known |
  [(.check_runs // [])[] | select(.app.slug? == "github-actions") | .check_suite.id] |
  unique | map(select(IN($known[]) | not));

def tested_something($checks):
  .check_suite_id as $suite |
  [$checks[] | select(.check_suite.id == $suite)] as $own |
  .status != "completed" or ($own | length) == 0 or any($own[]; .conclusion != "skipped");

def current_check_runs($settle; $hold):
  unclaimed_actions_suites as $gap |
  if $gap != [] then
    error("no listed workflow run claims GitHub Actions suites \($gap | map(tostring) | join(", ")); the workflow-runs listing is incomplete")
  else . end |
  (.check_runs // []) as $checks |
  (.workflow_runs // []) as $workflows |
  [$workflows[].check_suite_id] as $known |
  [$workflows | group_by([.workflow_id, .event])[] | sort_by([.created_at, .id]) | reverse |
    (map(select(tested_something($checks))) | first) // first] as $latest |
  [$latest[].check_suite_id] as $current |
  [$checks[] | select((.check_suite.id // null) as $suite |
    (($suite | IN($known[])) | not) or ($suite | IN($current[])))] as $kept |
  $kept
  + [$latest[] | . as $run |
      [$kept[] | select(.check_suite.id == $run.check_suite_id)] as $own |
      ($own | length) as $listed |
      select($listed == 0 or (.status != "completed" and all($own[]; .status == "completed"))) |
      "workflow run \(.id) (\(.event))" as $what |
      if .status != "completed" then
        {name: "workflow run: \(.name)", status: .status, conclusion: null,
         summary: (if $listed == 0 then "\($what) is \(.status) and lists no job yet"
                   else "\($what) is \(.status), and every job it lists so far (\($listed)) has finished" end)}
      elif (.conclusion // "") | IN("success", "neutral", "skipped") then
        {name: "workflow run: \(.name), awaiting its check runs", status: "pending", conclusion: null,
         summary: "\($what) concluded \(.conclusion) but lists no job"}
      # A completed run carries a conclusion; failing closed covers one without.
      else
        {name: "workflow run: \(.name)", status: "completed", conclusion: (.conclusion // "failure"),
         summary: "\($what) concluded \(.conclusion // "without a conclusion") before any job ran"}
      end |
      {id: "workflow-run-\($run.id)", name, status, conclusion,
       head_sha: $run.head_sha, check_suite: {id: $run.check_suite_id},
       details_url: ($run.html_url // null), output: {summary}}]
  + (if $hold and
        ([$workflows[] | select((.created_at | fromdateiso8601) >= $settle)] | length) == 0
     then [{id: "ready-flip-settle", name: "the workflow run a ready flip starts",
            status: "queued", conclusion: null, head_sha: null}]
     else [] end);

# Input: the two documents `gh api --paginate --slurp` returns, check runs
# then workflow runs, each an array of page objects. Anything else (an empty
# or unparsable response, a page without its array) is an error, never a
# shorter list: a missing document would shift the other into its place.
def pages_doc:
  if length != 2 or any(.[]; type != "array") then
    error("want two page arrays: check runs, then workflow runs")
  else
    {check_runs: [.[0][] | .check_runs[]], workflow_runs: [.[1][] | .workflow_runs[]],
     total_count: (.[1][0].total_count // null)}
  end;

def current_check_runs_from_pages($settle; $hold): pages_doc | current_check_runs($settle; $hold);

# The shell helper's question before it trusts a read, over the same pages:
# why the listing gives no verdict, or nothing when it claims every suite.
def listing_gap_from_pages:
  pages_doc | unclaimed_actions_suites as $gap | select($gap != []) |
  "no listed workflow run claims GitHub Actions suite\(if ($gap | length) > 1 then "s" else "" end)" +
  " \($gap | map(tostring) | join(", ")) (\(.workflow_runs | length) runs listed, total_count \(.total_count // "absent"))";
