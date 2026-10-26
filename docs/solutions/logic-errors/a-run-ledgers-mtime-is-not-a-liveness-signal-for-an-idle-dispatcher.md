---
title: "A run ledger's mtime is not a liveness signal; read the timer's own last trigger and check for a wedged run"
date: "2026-09-17"
category: logic-errors
module: deferral-watchlist-dispatcher-stalled
problem_type: logic_error
component: development_workflow
symptoms:
  - "The weekly harness-doctor WARN 'deferral trigger FIRED: dispatcher-stalled' appeared on a box whose dispatcher timer was enabled and ticking every 15 minutes"
  - "The dispatcher ledger had not been written for five days while every tick logged defer:no-eligible-issue to the journal"
  - "A first rewrite that read only the timer's last trigger stayed silent for a launched run whose process hangs but stays alive"
root_cause: logic_error
resolution_type: code_fix
severity: medium
related_components:
  - "dispatcher-tick"
  - "dispatcher-ledger"
  - "harness-doctor"
tags:
  - liveness
  - watchlist
  - dispatcher
  - false-alarm
  - systemd-timer
  - stall-detection
---

# A run ledger's mtime is not a liveness signal; read the timer's own last trigger and check for a wedged run

> **Retired machinery (2026-10-18).** The dispatcher was removed by #1873 (teardown move 3, 2026-10-17): `dispatcher-tick.sh`, `dispatcher-tick.{service,timer}` and `dispatcher-status.sh` are gone, and the `dispatcher-stalled` watchlist row is now marked resolved. The `systemctl`/`journalctl` commands for `dispatcher-tick` below no longer resolve; `dispatcher-ledger.sh` and `claude-loop.sh` remain. The lesson still holds for any idle-capable producer: never read a log's mtime as liveness.

## Problem

The `dispatcher-stalled` row in `harness/deferral-watchlist.tsv` treated the age of the dispatcher ledger file as proof the dispatcher was alive: older than 45 minutes meant "stalled". On 2026-09-17 it fired on a healthy box. `dispatcher-tick.timer` was enabled and had triggered minutes earlier, the journal showed a tick every 15 minutes, and the ledger was five days old. The Monday report carried a stall WARN for a dispatcher that was simply idle.

## Symptoms

- `harness-doctor.sh` section 27 printed `deferral trigger FIRED: dispatcher-stalled` while `systemctl --user list-timers dispatcher-tick.timer` showed a trigger within the last cadence.
- Every recent tick in `journalctl --user -u dispatcher-tick.service` ended with `defer:no-eligible-issue`; nothing was written to `~/.claude/logs/dispatcher-ledger.jsonl`.
- Silence from the row could not be trusted either: once the check read only the timer, a run whose process hung but stayed alive would never fire (see below).

## What Didn't Work

- Gating the ledger-age check on `systemctl --user is-enabled` alone. A disabled or masked timer went quiet, which was correct, but an enabled idle timer still fired every week.
- Replacing the ledger age with the timer's `LastTriggerUSec` alone. Adversarial review pointed out the gap: a launched run whose process hangs but stays alive keeps the timer fresh, because `dispatcher-tick.sh` launches the run detached and exits 0 on every tick, so the service's `OnFailure=` never pages, and `dispatcher-ledger.sh reconcile` marks a run broken only when its pid is dead. The old ledger-age check would have caught exactly that case.

## Solution

Two liveness signals, both required for silence (PR #1186):

1. The timer is enabled but its own last trigger is older than three cadences (45 minutes): the machinery stopped.
2. The timer is ticking but some run's latest ledger row is still `claimed` or `launched` after 7 hours: the work is wedged. Seven hours clears the loop's worst-case wall clock, about twice `CLAUDE_LOOP_MAX_MS`, which defaults to 3 hours in `bin/claude-loop.sh`.

Unreadable timer state, an empty or `n/a` last-trigger value, an unparseable timestamp, or an unreadable ledger all exit broken, never quiet. A missing ledger is quiet: no runs yet, and doctor check 28 owns that at rung 1 and above. The shape of the second signal, as committed in the row:

```bash
n=$(jq -rs --argjson cut "$((now - 25200))" \
  '[ group_by(.run_id)[] | sort_by(.ts) | .[-1]
     | select(.event == "launched" or .event == "claimed")
     | select((.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $cut) ] | length' "$f") || exit 3
[ "$n" -gt 0 ] && exit 0
```

## Why This Works

The ledger is run accounting, not a heartbeat. Rows are appended at claimed, launched, ended, kept, waste, and broken. An idle tick appends nothing, and a healthy run appends nothing between launched and ended, so ledger age measures "time since something happened", which is large in two normal states: an empty backlog and a long healthy run. The timer's own last trigger is the heartbeat for the machinery; the age of an unfinished run's latest row is the heartbeat for the work. Detection latency is bounded by how often the watchlist is read, which was the weekly harness-doctor run inside `scripts/harness-weekly.sh` (its timer was retired in dotfiles #1893, 2026-10-18), not by the row itself.

## Prevention

- Before using any log's mtime as liveness, list every event that writes to it and ask whether the healthy idle state writes at all. If it does not, read the producer's own state surface instead (`systemctl --user show <unit>.timer -p LastTriggerUSec --value` here).
- Keep both planted regressions in the trigger tests: the idle-backlog case (recent trigger, stale ledger, quiet) and the wedged case (recent trigger, a `launched` row 8 hours old with no terminal row, fired). `tests/test_deferral_watchlist_triggers.py` carries both and runs the committed row through the unchanged runner.
- When a review says a rewrite removed a detection, name the specific failure mode it lost and either restore a signal for it or write down which other component owns it and at what latency.

## Related Issues

- PR #1186 shipped the fix and the tests; PR #1195 is unrelated timing hardening from the same day.
- `docs/solutions/best-practices/verify-a-ledger-inferred-backlog-against-the-engines-state-surface.md` is the same family: ledger rows are not the engine's state.
