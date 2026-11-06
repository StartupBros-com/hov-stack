# Run it now: verify scheduled work by hand instead of waiting

The CLAUDE.md Autonomy bullet "Run it now; don't wait for a schedule" links here. That line
keeps the rule; this doc holds the safe forms, the recipes and the waits that stay correct.

## Ceremony Test

- **Consumer:** an agent whose next step, or whose check of finished work, is left to a timer,
  cron line, queue tick, workflow schedule, nightly run, the next session or a date it set.
- **Defect it exists for:** sessions that close with "unverified until the next scheduled run"
  or "gated until <date>" when the same command could run now. In the 60 days to 2026-11-04 the
  operator typed a run-it-now nudge about 21 times in 17 sessions (a phrase-match floor, verified
  by an independent recount). Most were "verify after the 16:00 run" closeouts and self-set date
  gates, and the same stock sentence was pasted into four sessions on one day.
- **Gate:** none. A Stop-hook detector for deferral language was ruled out: the hand-back Stop
  gate it would copy flagged mid-task stops, 40 of its 44 flagged PRs merged later, and it was
  deleted (hov-stack #387). The lever is the always-on line plus this doc.
- **Measured:** a replay A/B on 2026-11-04 compared the CLAUDE.md and overlay text from before and
  after this rule, without this doc loaded. One model, 5 trials per case, each a single completion
  with regex-graded tool calls, so read it as a ceiling, not a field rate. On 11 real decision
  points where the operator had to nudge, the agent ran the check in 15% of trials before the rule
  and 69% after (5% and 65% in a date-anchored rerun). On 11 real decision points where waiting or
  asking was right, 2 cases fell. One brief had left out its prompt's "do not merge" line; with the
  line restored, the case held 5/5. In the other, the agent posted an early probe result on the
  issue a scheduled measurement owns, which wait item 2 now rules out. The controls for live money,
  timer enables, service restarts and history-deleting changes held in both arms, apart from one
  trial that named no tool calls.
- **Delete when:** a 60-day transcript scan finds no run-it-now nudges from the operator, or the
  CLAUDE.md line is removed.

## The rule

A schedule is a backstop, never the reason work is open. Before writing "will be verified by the
next run", ask what the schedule does that you cannot do now. If the answer is "run a command",
run it, read what it did, and continue. If a constraint seems to block you (a market closed, an
API that only accepts the call at night), test the constraint once before scheduling around it.

The same goes for a date you set yourself. A soak period or "revisit on <date>" is only real when
the result needs that much elapsed time to exist. Otherwise drive the work to its check now.

## Pick the safe form by effect

Read the unit before you start it: `systemctl --user cat <unit>` shows the unit file and its
drop-ins, and `systemctl --user show <unit> -p Environment -p ExecStart` shows the mode it runs
in. Do not print an `EnvironmentFile`; it can hold secrets.

1. **Read-only or local-write** (updaters, backups, health and drift checks, collectors that only
   write local state): start the unit, or run its script. Starting a unit through `systemctl`
   cannot double-run it: if its timer already started it, `start` waits on that run. Running the
   script directly can collide, so check the script for a lock first.
2. **Deletion-capable** (hov-stack's `wt-sweep`, `reclaim-sweep`, `pkg-cache-prune` and
   `docker-hygiene`, and anything else that removes files): run the plan form. That is
   `DRY_RUN=1` in front of the script, or `reclaim-sweep.py` without `--apply`. A host's hygiene
   posture can make the installed unit live (`DRY_RUN=0`, `RECLAIM_SWEEP_APPLY=1`), and then
   `systemctl --user start` deletes. Run the live form only when the deletion is the task.
3. **External send or mutation** (Discord or webhook posts, emails, leaderboard submits, changes
   to a third-party account, deploys, migrations): run the dry-run or plan form, or the
   collect step without its announce step, or point it at a scratch input. Run the live form only
   when that effect is the task, and the CLAUDE.md pause on ungated effects still applies.
4. **Spend** (paid API reads, rented compute): one extra run of a job the schedule already pays
   for is fine; name its cost in the report. Check the job's run-once guard so the timer's own run
   does not bill twice. Anything bigger is a decision for the operator.
5. **Unknown:** read the script header and the unit first. Do not start it blind.

A host's overlay CLAUDE.md names its own live-by-default units and their safe forms.

## Recipes

1. **User systemd from a headless shell.** If `systemctl --user` prints `Failed to connect to
   bus: No medium found`, user systemd is not missing; the shell has no `XDG_RUNTIME_DIR`. Put
   `export XDG_RUNTIME_DIR=/run/user/$(id -u)` in the same command, since shell state resets
   between tool calls.
2. **Oneshot unit.** `systemctl --user start X.service` (it blocks until the run ends), then
   `systemctl --user show X.service -p Result -p ExecMainStatus` and
   `journalctl --user -u X.service -n 50 --no-pager`.
3. **Long unit** (a start timeout of an hour or more). `systemctl --user start --no-block
   X.service`, then follow it with the Monitor tool or a bounded
   `timeout 300 journalctl --user -u X.service -f --no-pager`. A blocking start can outlast the
   tool's own time limit.
4. **Plan mode of a live unit.** Copy the `ExecStart` argv from `systemctl --user show` and run it
   in your shell with `DRY_RUN=1` in front, or without `--apply`. Do not edit the unit or use
   `systemctl --user set-environment` to flip its mode; that is a schedule edit.
5. **Cron line.** Copy the exact command from `crontab -l`, including any `env` prefix, run it,
   and read the log it appends to. Never open `crontab -e` to test a job.
6. **GitHub scheduled workflow.** `gh workflow run <file>.yml --repo <owner/repo> --ref <branch>`,
   then `gh run watch <id> --exit-status`. It needs a `workflow_dispatch` trigger and the file on
   that ref. Without one, run the workflow's script locally, or add the trigger in a PR. A failed
   run: `gh run rerun --failed <id>`, unless a fix has landed on that ref since. A rerun replays
   the run's own commit, so dispatch a new run instead.
7. **HTTP cron route** (a hosted app's scheduled endpoint). Call it with its cron secret from the
   secrets store, then read the result back from the data store it writes.
8. **Queue or dispatcher tick.** Enqueue or trigger the item yourself with the same command the
   tick would run, then read its result.

## Read the result

`Result=success` is not the whole answer. An exit 0 with a skip line (lock held, not due, deferred
while another job runs, nothing qualifies) means the code path did not run. Read the journal text,
and if nothing qualified, feed it an input that does (a scratch row, a seeded fixture, a plan run
that lists what it would do). A start that hangs may be waiting on a lock another run holds.

## Waits that stay correct

1. **A run already going:** CI on the PR, a workflow you dispatched, a background job or
   subagent you started. Wait on that run with `gh pr checks --watch`, `gh run watch` or the
   task notification, and run the same checks locally while it queues.
2. **Elapsed time the result needs:** a 14-day count, an email that sends at a fixed hour, a real
   event that has not happened. Do every offline part now (tests, a scratch or synthetic proof),
   then say which part waits and why. Put that proof in your report, not on the issue or channel
   the scheduled run owns. `CronCreate` and `ScheduleWakeup` die with the session; use a one-shot
   systemd timer if the later readback matters.
3. **Rate limits and host-pressure guards.**
4. **Live money or sends tied to market hours or an operator approval.** Dry run first.
5. **Human-only steps:** enabling a persistent timer, restarting a shared service that would kill
   live sessions, a retention change that deletes history. Start the service once by hand to
   prove it works, then ask for the enable.
6. **A job that is itself the hazard** (one known to exhaust the host). Say so in one sentence and
   name the safer proof.
7. **Safety timers** (a cost reaper on rented compute). Keep them armed and also prove them once
   by hand.

## Report

Say "ran X by hand: exit 0, <what you read>". "Will be verified by the 16:00 run" is not a
finished report. When part of the check really must wait, name that part, the reason, and the
offline proof you ran in its place.
