# Whether a head's red CI is only a runner stall (dotfiles#1605). Included by
# ci-stall-classify.sh as `include "ci-stall-classify"`.

# GitHub writes job and step times with or without fractional seconds.
def ci_stall_epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;

# Job records arrive with `annotations`, the messages of the job's check-run
# annotations. GitHub writes "The job has exceeded the maximum execution time
# of 20m0s" when timeout-minutes cancels a job; a person's cancel writes none.
def ci_cap_cancelled: any(.annotations[]?; test("exceeded the maximum execution time"));

# A job whose runner stopped reporting: cancelled by the cap after its steps
# succeeded, either after `Complete job` (the finalize stall) or with one step
# left open and no verdict (the mid-step variant). A step that concluded
# failure, cancelled or timed_out is a live runner's verdict, never a stall:
# a hung test the cap interrupts on a live runner has its step cancelled.
def ci_stalled_job:
  .conclusion == "cancelled"
  and ci_cap_cancelled
  and any(.steps[]?; .conclusion == "success")
  and all(.steps[]?; (.conclusion // "") | IN("failure", "cancelled", "timed_out") | not);

# A red job downstream of a stall: it started after a stalled job of its own
# run ended, so it waited on that job (`needs:`), and its own annotations say
# it failed on a cancellation, as an aggregate gate that requires every shard
# green does ("a harness shard concluded 'cancelled'"). A job that ran beside
# the stalled one, or failed for any reason it did not attribute to a
# cancellation, failed on its own evidence.
def ci_stall_downstream($stalled):
  . as $job
  | .started_at != null
    and any(.annotations[]?; test("cancel"; "i"))
    and any($stalled[]; .run_id == $job.run_id and .completed_at != null
            and (.completed_at | ci_stall_epoch) <= ($job.started_at | ci_stall_epoch));

# Input: one entry per red check run, its Actions job record, or null for a
# check that is not an Actions job. Stall-only when there is at least one and
# each is a stalled job or downstream of one. The caller owns repair policy;
# this filter never grants a head move, retry request or merge.
def ci_stall_only:
  [.[] | select(. != null and ci_stalled_job)] as $stalled
  | length > 0
    and all(.[]; . != null and (ci_stalled_job or ci_stall_downstream($stalled)));

# A job cancelled before any runner took it ran no step and never will. GitHub
# serves it with no runner (`runner_id` 0, or null when the run was cancelled
# as the job was created) and `started_at` equal to `created_at`, the queue
# time: 29 of 29 such jobs in the repo's 40 most recent cancelled runs, read
# 2026-10-14 (fixtures 115594417972 and 112919103444). A finished job served
# without its steps keeps its runner and a start after its creation: job
# 111637998248 came back step-less on 2026-10-14 with runner 110679 and a
# start 135 seconds after its creation (fixture 111637998248-no-steps). A shape
# this does not model (a missing key, another conclusion) stays unreadable.
def ci_never_started_job:
  .status == "completed" and .conclusion == "cancelled"
  and (.steps | type == "array" and length == 0)
  and has("runner_id") and (.runner_id == 0 or .runner_id == null)
  and (.runner_name == "" or .runner_name == null)
  and (.created_at | type == "string") and .started_at == .created_at;

# A record served without its steps carries none of the evidence that tells a
# stall from a hang or a lost runner: GitHub served #1660's finished core job
# with all 189 steps and with none within one minute (2026-10-13). Such a
# record is unreadable, not a verdict, with the two readings that need no
# steps: a job that never started (ci_never_started_job), whose steps will
# never arrive and which is on its own evidence no stall, and downstream of a
# stalled sibling, which is also how a job cancelled while still queued behind
# that stall reads (its cancellation annotation and a start after the stall
# ended, with no step ever run). Input: the job list.
def ci_steps_unreadable:
  [.[] | select(. != null and ci_stalled_job)] as $stalled
  | any(.[]; . != null
      and ((.steps | type == "array" and length > 0) | not)
      and (ci_never_started_job | not)
      and (ci_stall_downstream($stalled) | not));

# #1722: opt-in evidence for same-head failed-only retries. The default
# ci_stall_only above still governs the older head-moving recovery caller.
# Keep severity: notices/warnings cannot prove a loss, and another failure
# annotation or any explicit bad step verdict makes this a real failure.
def ci_retry_annotations_valid:
  (.annotation_records | type == "array")
  and all(.annotation_records[]; type == "object"
    and (.annotation_level | IN("notice", "warning", "failure"))
    and (.message | type == "string"));
def ci_retry_failures:
  [.annotation_records[]? | select(.annotation_level == "failure") | .message];
def ci_retry_bad_steps:
  [.steps[]? | select((.conclusion // "") | IN("failure", "cancelled", "timed_out")) | {name, conclusion}];
def ci_retry_steps_valid:
  (.steps | type == "array" and length > 0)
  and all(.steps[]; type == "object" and (.name | type == "string" and length > 0)
    and (if .status == "completed" then
      (.conclusion | IN("success", "neutral", "skipped", "failure", "cancelled", "timed_out"))
    else (.status | IN("pending", "in_progress")) and .conclusion == null end));
def ci_lost_runner_job:
  .status == "completed" and .conclusion == "failure"
  and ci_retry_steps_valid
  and ci_retry_annotations_valid
  and (ci_retry_failures | length > 0 and all(.[]; contains("lost communication with the server")))
  and (ci_retry_bad_steps | length == 0);

# These two jobs in a private app repository can propagate a lost upstream job. The final gate
# also runs a migration-order check: only its judge may fail, never that
# later check. Messages must attribute the failure to the dependency result;
# the runner's automatic exit-code annotation is the only extra one allowed.
def ci_lost_runner_judge($step; $message):
  .status == "completed" and .conclusion == "failure"
  and ci_retry_steps_valid and ci_retry_annotations_valid
  and ci_retry_bad_steps == [{name:$step,conclusion:"failure"}]
  and (ci_retry_failures | index($message) != null
    and all(.[]; . == $message or . == "Process completed with exit code 1."));
# Compare whole seconds and a zero-padded fractional string, not a floating
# epoch or truncated seconds. GitHub UTC timestamps up to nanosecond precision
# are supported; malformed dates or unsupported precision fail closed.
def ci_retry_time:
  (capture("^(?<whole>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]{1,9}))?Z$")
    // error("unsupported CI retry timestamp")) as $time
  | ($time.whole + "Z" | fromdateiso8601) as $epoch
  | if ($epoch | todateiso8601) == ($time.whole + "Z") then
      [$epoch, (($time.fraction // "") + "000000000" | .[0:9])]
    else error("invalid CI retry timestamp") end;
def ci_lost_runner_downstream($explained; $repo):
  . as $job
  | ($repo | ascii_downcase) == "acme-org/announce-bot"
    and (if .name == "🧪 Test Run" then
      ci_lost_runner_judge("Require every test suite to have succeeded";
        "the 🧪 Test Run matrix did not succeed (result: failure, any_app=true, any_suite=true). With fail-fast disabled this means at least one suite failed, was cancelled, or never ran - failing the required check.")
    elif .name == "⚫️ Test" then
      ci_lost_runner_judge("Judge leaf results against live PR state";
        "a leaf job failed - failing the required check")
    else false end)
    and (.started_at | type == "string")
    and any($explained[];
      .run_id == $job.run_id and .run_attempt == $job.run_attempt and .head_sha == $job.head_sha
      and (.completed_at | type == "string")
      and (try ((.completed_at | ci_retry_time) <= ($job.started_at | ci_retry_time)) catch false)
      and (if $job.name == "🧪 Test Run" then
        (.name | startswith("🧪 Test Run (") and endswith(")"))
      else (.name | IN("🔍 Detect Affected", "🧪 Test Run", "🧪 Test Unit")) end));

# Walk upstream first so a lost matrix leaf explains Test Run, which then
# explains Test. A loss in an unrelated job explains neither. Every other
# red still has to satisfy the original stall rule or be independently lost.
def ci_lost_runner_explained($repo):
  . as $jobs
  | [.[] | select(. != null and ci_lost_runner_job)]
  | reduce ["🧪 Test Run", "⚫️ Test"][] as $name
      (.; . as $explained | . + [$jobs[] | select(. != null and .name == $name
        and (ci_lost_runner_job | not) and ci_lost_runner_downstream($explained; $repo))]);
def ci_retry_only($explained):
  [.[] | select(. != null and ci_stalled_job)] as $stalled
  | length > 0 and all(.[]; . as $job | . != null
    and (ci_stalled_job or ci_stall_downstream($stalled) or any($explained[]; .id == $job.id)));
