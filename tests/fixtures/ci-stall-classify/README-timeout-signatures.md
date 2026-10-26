# Timeout-signature fixtures

`job-112732924539.json` and `job-112742237694.json` are real records from
StartupBros-com/hov-stack run 37603350460 attempt 1, the ready run of PR
#1660 on 2026-10-07. Each is slimmed to the fields the filter reads, and its
check run's annotations sit beside it. Both were fetched on 2026-10-13 at
20:58Z. The core job was cancelled by its 20-minute cap at 10:15:48Z with
step 129 in progress since 10:14:49Z and sixty later steps pending. The gate
started at 10:15:50Z and failed because a shard concluded `cancelled`.

`job-112732924539-no-steps.json` is the same job as GitHub also served it:
identical except for an empty `steps` list. The jobs endpoint returned it
with no steps at 20:47:56Z, with 189 steps at 20:58:09Z, and with no steps
on five fetches from 20:58:44Z to 20:59:11Z. The #1568 mid-step job
111637998248 also came back with no steps in that window, and the #1597
finalize stall 111987568844 came back with 181 every time. Both jobs that
lost their steps have a step left in progress; the cause is not known.

`job-111637998248-no-steps.json` is the #1568 mid-step stall as GitHub also
served it, captured whole on 2026-10-14 at 00:21:28Z, 00:21:29Z and 00:21:30Z
(three identical reads, the jobs endpoint): the same job as
`job-111637998248.json` with an empty `steps` list and its runner intact
(`runner_id` 110679, `runner_name` linux-x64-light-fssk9-runner-qv5hl) and
`started_at` 06:12:39Z, 135 seconds after its `created_at` 06:10:24Z. This is
the capture pro-gate round 1's #1770 asked for: a glitch read keeps the job's
runner and its distinct timestamps and loses only the steps, so the fields
below tell a job that never started from a finished job served without its
steps. The record is slimmed to the fields the filter reads, `runner_id`,
`runner_name` and `created_at` now among them; the with-steps sibling and
`job-112732924539-no-steps.json` were slimmed before the filter read those
three keys and do not carry them, so the two records of this job differ in
those keys as well as in `steps`.

`job-115594417972.json` is a real job that never started: `Install smoke`
of StartupBros-com/hov-stack run 38484390722 attempt 1, cancelled while still
queued on 2026-10-13 when a newer run for the same pull request pre-empted
it. Fetched 2026-10-14 00:40Z and again at 00:50Z with `runner_id`,
`runner_name` and `created_at` kept. GitHub serves it with an empty `steps`
list, `runner_id` 0, an empty `runner_name`, `started_at` equal to its
`created_at` (23:27:51Z, the queue time), and one failure annotation,
"Canceling since a higher priority waiting request for
install-smoke-refs/pull/1769/merge exists". On that evidence the filter reads
it as never started (`ci_never_started_job`): alone it is a test red, no
stall; beside a stalled sibling of its own run that ended before it was queued
it is downstream of the stall, the annotation reading as a cancellation.

`job-112919103444.json` is a real job that never started with no runner at
all: the core shard of StartupBros-com/hov-stack run 37658273294 attempt 1,
cancelled on 2026-10-07 as it was created (`completed_at` 17:20:43Z, one
second before its `created_at` and `started_at` of 17:20:44Z). Fetched
2026-10-14 00:50Z. GitHub serves it with an empty `steps` list, `runner_id`
and `runner_name` null, and no annotation at all, which is the common shape:
of the 29 cancelled step-less jobs in the repo's 40 most recent cancelled runs
on 2026-10-14, every one had `started_at` equal to `created_at`, 27 had
`runner_id` 0 and two (this job and its sibling 112919103163) had null, and
only the four a newer run pre-empted carried an annotation, the "Canceling
since a higher priority waiting request ... exists" one above. A never-started
job's annotations are therefore no part of the never-started reading.

`job-112732924539-hung.json` is synthetic. It is the 189-step record with
step 129 concluded `cancelled` at the cut, which is what a live runner writes
when the cap interrupts a hung step. No real capture of that shape exists:
none of the 38 most recent cancelled Harness Tests runs on 2026-10-13 had
one. Its annotations file copies the real cap annotation.
