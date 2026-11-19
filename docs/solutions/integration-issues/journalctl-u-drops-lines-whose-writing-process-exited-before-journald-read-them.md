---
title: journalctl -u drops lines whose writing process exited before journald read them
date: 2026-11-19
category: integration-issues
module: systemd-user-unit-journal
problem_type: integration_issue
component: development_workflow
symptoms:
  - "journalctl --user -u <unit> shows the run and its result, but some or all of the lines the script printed are missing"
  - The same lines appear when the journal is read by syslog identifier (-t) or by time window without -u
  - Lines printed through a short-lived pipeline child (| sed) or replayed in one burst at exit go missing; lines a long-lived process prints survive
root_cause: wrong_api
resolution_type: code_fix
severity: medium
tags: [systemd, journald, journalctl, unit-attribution, syslog-identifier, user-units, logging]
---

# journalctl -u drops lines whose writing process exited before journald read them

## Problem

`journalctl --user -u <unit>` is the house way to read a unit's output (`harness/run-it-now.md:75`). It shows only records journald attributed to that unit. A line whose writing process has exited by the time journald reads it can carry no unit at all, so `-u` never shows it, even though the line is in the journal. Three times a reader took the gap as "the script printed nothing" or "it printed no reason".

## Symptoms

- `-u` shows the manager's own lines ("Started", "Finished", "Failed with result") but not some of the script's lines. The manager writes those records with the unit's name in a `USER_UNIT` field, so they always match.
- The missing lines are in the journal. They turn up when the same window is read by syslog identifier (`-t`) or by time alone.

## What Didn't Work

Each case was solved locally, and the lesson stayed where it was found:

- **jsm-auto-update, 2026-09-19 (dotfiles#1215).**
  - The wrapper wrote each stage's output to a file and printed it with `cat` once the stage had finished. All of it came out in one burst as the process exited.
  - `-u` matched 0 "already up to date" lines; 89 were in the same window without it.
  - The unit failed five nights running with the reason missing from `-u`.
  - The fix (stream through `| tee`) and the mechanism live in a comment at `scripts/jsm-auto-update-wrapper.sh:88`.
- **docker-hygiene, the 2026-09-30 run (dotfiles#1555).**
  - `-u` had the summary and the exit status and "none of the 25 details" (`docs/solutions/integration-issues/the-user-managers-stock-path-has-no-local-bin-house-path-preflight-and-kept-stderr-on-the-unit.md:41`).
  - That learning blames a script that "prints its failure lines in a burst at exit" (`:117`). That is one way to get there, not the cause.
- **wt-sweep, 2026-11-19 (hov-stack#793).**
  - wt-sweep printed each Claude-session hold line through `printf | sed`, and `journalctl --user -u wt-sweep.service` showed about half of them.
  - `journalctl --user -t wt-sweep.sh` showed all of them.
  - The parent script was alive the whole time, so a burst at exit does not explain this case. The writer of each lost line was a `sed` that exited at once.

## Solution

**Measure it in a transient unit.** This probe printed 20 lines through a short-lived `sed` and 20 with a builtin loop:

```bash
for i in $(seq 1 20); do
  printf 'probe-sed %s\n' "$i" | sed 's/^/  ~ /'
  hold="probe-builtin $i"
  while IFS= read -r l; do echo "  ~ $l"; done <<<"$hold"
done
```

Run as `systemd-run --user --wait --unit=<name> bash probe.sh`, `journalctl --user -u <name>` showed 10 of the 20 `sed` lines and 20 of the 20 builtin lines. `journalctl --user -t bash -t sed --since '-5 min'` showed 20 of 20 of each.

**Writer side: print reporting lines from a process that stays alive.**

- In bash, use builtins (`echo`, `printf`, a `while IFS= read -r` loop) at the point of output instead of piping into `sed`, `awk`, `cut` or `head`.
- Stream long output with `| tee` instead of capturing it and replaying it at the end.
- PR #796 did this for the hold lines in `scripts/wt-sweep.sh:353-356` and `scripts/wt-done.sh:392`. The jsm wrapper did it earlier.

**Reader side: when a unit's lines look missing, change the selector, not the conclusion.**

```bash
journalctl --user -t wt-sweep.sh --since '-1 day' --no-pager      # by syslog identifier
journalctl --user --since '<run start>' --until '<run end>' --no-pager   # by time
```

A unit's stdout records carry its syslog identifier, which by default is the name of the ExecStart program. For wt-sweep, every attributed line had `SYSLOG_IDENTIFIER=wt-sweep.sh`.

## Why This Works

The wrapper's comment records the mechanism found in dotfiles#1215: "journald resolves a stdout record's originating unit from the sending process's cgroup at the moment it DRAINS the pipe; by then the process was gone, so the records carried no _SYSTEMD_USER_UNIT at all" (`scripts/jsm-auto-update-wrapper.sh:92-94`).

The probe fits it. A `sed` that writes one line and exits races journald's read, and about half the time it has exited first. A builtin's line comes from the long-lived shell, which is still in the unit's cgroup when journald reads it. Selecting by `-t` or by time does not depend on the unit field, so it finds the record either way.

## Prevention

- **Reach, as of this writing.**
  - These unit scripts still print reporting lines through a short-lived pipeline child: `scripts/backup-harness.sh:97` and `:101`, `scripts/pkg-cache-prune.sh:123`, `scripts/codex-update.sh:176` (`tail | sed`, run by `codex-auto-update.service`), and wt-sweep's failure path at `scripts/wt-sweep.sh:220`.
  - Each can lose lines from `-u` the same way; this was not measured per script. That is harmless while readers know to fall back to `-t`, and costly when they don't.
- **Advice that reads only `-u`:** `harness/run-it-now.md:75` and `:78`, and the post-merge activation learning's "`journalctl --user -u dotup-refresh.service` names the reason". When `-u` looks short, read again by `-t` or by time before concluding anything.
- **Unaffected:** checks that count the manager's own lines through `-u`, such as `scripts/unit-health.sh`'s `Failed with result` count. Those records carry `USER_UNIT`.
- **No automated check.** A static rule for "output through a pipeline child in a unit script" cannot tell a reporting line from a captured value (`$(... | sed)` is fine). The reader-side fallback is what holds.

## Related Issues

- dotfiles#1215 (jsm-auto-update) and dotfiles#1555 (docker-hygiene): the two earlier cases.
- hov-stack#793 and PR #796: the wt-sweep case and the builtin-loop fix.
- [The user manager's stock PATH](the-user-managers-stock-path-has-no-local-bin-house-path-preflight-and-kept-stderr-on-the-unit.md): its "time window, not only `-u`" bullet is the reader-side fallback with a narrower stated cause.
- [Drive post-merge activation](drive-post-merge-activation-instead-of-handing-back.md): points readers at `-u` for dotup's refusal reason.
