---
title: journalctl -u drops lines whose writing process exited before journald read them
date: 2026-11-19
last_updated: "2026-11-20"
category: integration-issues
module: systemd-user-unit-journal
problem_type: integration_issue
component: development_workflow
symptoms:
  - "journalctl --user -u <unit> shows the run and its result, but some or all of the lines the script printed are missing"
  - The same lines appear when the journal is read by syslog identifier (-t) or by time window without -u
  - Lines printed through a short-lived pipeline child (| sed) or replayed in one burst at exit go missing; lines a long-lived process prints survive
  - A unit failure alert page names the failed run's result but carries fewer of the script's lines than the run printed
root_cause: wrong_api
resolution_type: code_fix
severity: medium
tags: [systemd, journald, journalctl, unit-attribution, syslog-identifier, user-units, logging, unit-failure-alert]
---

# journalctl -u drops lines whose writing process exited before journald read them

## Problem

`journalctl --user -u <unit>` is the house way to read a unit's output (`harness/run-it-now.md:73-78`). It shows only records journald attributed to that unit. A line whose writing process has exited by the time journald reads it can carry no unit at all, so `-u` never shows it, even though the line is in the journal. Three times a reader took the gap as "the script printed nothing" or "it printed no reason".

The same records also lack the run's invocation id. The unit failure alert (`scripts/unit-failure-alert.sh`), which pages a failed run's last lines, selects them by that id. So the page for a failure can miss the very lines that explain it, and the alert, unlike a person, has no second read to fall back on.

## Symptoms

- `-u` shows the manager's own lines ("Started", "Finished", "Failed with result") but not some of the script's lines. The manager writes those records with the unit's name in a `USER_UNIT` field, so they always match.
- The missing lines are in the journal. They turn up when the same window is read by syslog identifier (`-t`) or by time alone.
- The failure page shows the same gap: the result is there, and so are the lines the script's own shell printed, but not the lines a short-lived child printed.

## What Didn't Work

Each case was solved locally, and the lesson stayed where it was found:

- **jsm-auto-update, 2026-09-19 (dotfiles#1215).**
  - The wrapper wrote each stage's output to a file and printed it with `cat` once the stage had finished. All of it came out in one burst as the process exited.
  - `-u` matched 0 "already up to date" lines; 89 were in the same window without it.
  - The unit failed five nights running with the reason missing from `-u`.
  - The fix (stream through `| tee`) and the mechanism live in a comment at `scripts/jsm-auto-update-wrapper.sh:88`.
- **docker-hygiene, the 2026-09-30 run (dotfiles#1555).**
  - `-u` had the summary and the exit status and "none of the 25 details" (`docs/solutions/integration-issues/the-user-managers-stock-path-has-no-local-bin-house-path-preflight-and-kept-stderr-on-the-unit.md:41`).
  - That learning blames a script that "buffers its per-stack failure lines and prints them at exit" (`:41`). That is one way to get there, not the cause.
- **wt-sweep, 2026-11-19 (hov-stack#793).**
  - wt-sweep printed each Claude-session hold line through `printf | sed`, and `journalctl --user -u wt-sweep.service` showed about half of them.
  - `journalctl --user -t wt-sweep.sh` showed all of them.
  - The parent script was alive the whole time, so a burst at exit does not explain this case. The writer of each lost line was a `sed` that exited at once.
- **Relying on the reader-side fallback, 2026-11-19 (PR #811).**
  - The first version of this learning listed five unit scripts that still printed through `| sed` or `| head`, and called them "harmless while readers know to fall back to `-t`".
  - The failure page is a reader that cannot fall back. Measured with its own selector, those print sites delivered 0–40% of their lines (Solution).

## Solution

**Measure it in a transient unit.** This probe printed 20 lines through a short-lived `sed` and 20 with a builtin loop:

```bash
for i in $(seq 1 20); do
  printf 'probe-sed %s\n' "$i" | sed 's/^/  ~ /'
  hold="probe-builtin $i"
  while IFS= read -r l; do echo "  ~ $l"; done <<<"$hold"
done
```

Run as `systemd-run --user --wait --unit=<name> bash probe.sh`, `journalctl --user -u <name>` showed 10 of the 20 `sed` lines and 20 of the 20 builtin lines in that run. `journalctl --user -t bash --since '-5 min'` showed 20 of 20 of each: all 40 lines, the 10 that `-u` missed included, carry `SYSLOG_IDENTIFIER=bash`.

**Measure what the failure page sees.** For PR #811, each of six print sites in unit-run scripts was driven 20 times inside a transient `systemd-run --user` unit: three runs on the old scripts and three on the fixed ones. Lines were counted with the alert's own selector, `journalctl --user _SYSTEMD_INVOCATION_ID=<id>`. The unit slept 3 s before exiting, so loss at exit is not in these counts.

| Site (lines expected per run) | old print path, runs 1/2/3 | builtin loop, runs 1/2/3 |
|---|---|---|
| `scripts/wt-sweep.sh` `run()` failure reason (100) | 0 / 20 / 20 | 100 / 100 / 100 |
| `scripts/lib/wt-preserve.sh` pin failure reason (20) | 0 / 7 / 8 | 20 / 20 / 20 |
| `scripts/pkg-cache-prune.sh` command output (60) | 0 / 0 / 3 | 60 / 60 / 60 |
| `scripts/codex-update.sh` `show_log` (60) | 0 / 0 / 3 | 60 / 60 / 60 |
| `scripts/backup-harness.sh` memory-push replay (60) | 6 / 0 / 0 | 60 / 60 / 60 |
| `scripts/backup-harness.sh` push summary line (20) | 2 / 0 / 2 | 20 / 20 / 20 |

A second probe, on 2026-11-20, printed 20 lines in each of three styles per run, three runs, and counted each style both ways:

| Print style | invocation-id selector, runs 1/2/3 | `-t bash`, runs 1/2/3 |
|---|---|---|
| `printf … \| sed …` | 9 / 8 / 12 | 20 / 20 / 20 |
| `printf … \| while IFS= read -r l; do echo …; done` | 12 / 10 / 16 | 20 / 20 / 20 |
| `while IFS= read -r l; do echo …; done <<<"$x"` | 20 / 20 / 20 | 20 / 20 / 20 |

**Writer side: print reporting lines from the script's own long-lived shell.**

- In bash, use builtins (`echo`, `printf`, a `while IFS= read -r` loop) at the point of output instead of piping into `sed`, `awk`, `cut` or `head`.
- **Feed the loop; never pipe into it.** Write `done < <(cmd)` or `done <<<"$out"`. In `cmd | while read …`, bash runs the loop in a forked subshell (each part of a pipeline gets its own unless `lastpipe` is set). That subshell exits when its input ends and loses lines the same way `sed` does (second table).
- A filter that must stay, such as credential masking, goes on the loop's input side. `show_log` in `scripts/codex-update.sh:177-184` feeds `tail | sed -E <redaction>` into the loop through `< <( … )`, so `sed` writes only into the pipe and the shell writes to the journal.
- Stream long output with `| tee` instead of capturing it and replaying it at the end.
- Done so far:
  - PR #796: the hold lines, `scripts/wt-sweep.sh:359` and `scripts/wt-done.sh:392`.
  - PR #811: the six sites in the first table, `scripts/backup-harness.sh:100` and `:105`, `scripts/codex-update.sh:179`, `scripts/pkg-cache-prune.sh:125`, `scripts/wt-sweep.sh:222` and `scripts/lib/wt-preserve.sh:233`. Each carries a comment naming the alert.
  - The jsm wrapper, earlier.

**Reader side: when a unit's lines look missing, change the selector, not the conclusion.**

```bash
journalctl --user -t wt-sweep.sh --since '-1 day' --no-pager      # by syslog identifier
journalctl --user --since '<run start>' --until '<run end>' --no-pager   # by time
```

The syslog identifier belongs to the unit's stdout stream, not to the process that wrote the line, so a line that lost its unit still carries it. By default it is the name of the ExecStart program: `bash` for the probe, `wt-sweep.sh` for wt-sweep.

**Why the fix is on the writer side, not in the alert.** The alert scopes its lines to one invocation on purpose. Unit history (`-u`) prints oldest first, so a FAILED page could end on a later run's "Finished … successfully" (the measured case is in the comment at `scripts/unit-failure-alert.sh:201-210`). Reading by `-t` or by time would bring back other runs, and other units whose ExecStart program has the same name. When the invocation id is empty the alert falls back to `-u` (`:218-224`), which loses the same lines. For jsm-auto-update only, the page adds a "Journal:" hint with the invocation-id command (`:330-332`); an operator following it gets the same short view and should read `-t` around the run as well.

## Why This Works

The wrapper's comment records the mechanism found in dotfiles#1215: "journald resolves a stdout record's originating unit from the sending process's cgroup at the moment it DRAINS the pipe; by then the process was gone, so the records carried no _SYSTEMD_USER_UNIT at all" (`scripts/jsm-auto-update-wrapper.sh:92-94`).

The probes' records show it:

- **The first probe.** The 10 lines `-u` missed have neither `_SYSTEMD_CGROUP` nor `_SYSTEMD_USER_UNIT`, the field `-u` matches a unit's own lines on. Eight of them still name `_COMM=sed`, and two carry no process metadata at all. The 10 `sed` lines `-u` kept and all 20 builtin lines carry the unit's cgroup.
- **The 2026-11-20 probe.** Every one of the 53 lines the invocation-id selector missed lacks `_SYSTEMD_INVOCATION_ID`, `_SYSTEMD_CGROUP` and `_SYSTEMD_USER_UNIT` alike. Of the 31 `sed` lines, 30 name `_COMM=sed`; of the 22 pipe-into-loop lines, 19 name `_COMM=bash` (the forked subshell); the other four carry no process name. So `-u` and the failure page lose the same records.

A short-lived writer races journald's read. How many lines it loses is a race outcome, not a rate: half in the first probe, 40–60% of the `sed` lines in the 2026-11-20 probe, and 60–100% in the #811 runs on the old scripts. A builtin's line comes from the long-lived shell, which is still in the unit's cgroup when journald reads it. Selecting by `-t` or by time does not depend on any of the cgroup-derived fields, so it finds the record either way.

## Prevention

- **Reach, as of 2026-11-20.**
  - `scripts/wt-done.sh:160` (`| head | sed`) and `:511` (`git diff --stat | sed`) still print through a short-lived child. They do not reach a journal today: no unit runs `wt-done.sh` directly, and wt-sweep captures its output in `rec_out=$(…)` (`scripts/wt-sweep.sh:399`) and never prints it. A unit that runs wt-done directly, or a sweep that starts printing `rec_out`, needs the same fix.
  - Not swept: any other external command that writes straight to a unit's stdout, such as a bare `git`, `docker` or `rsync` whose output is not captured, has the same exposure.
  - Not fixed: loss at exit. A script's last lines can still lose attribution when the script itself exits before journald reads them.
- **The `-t` fallback is for people, not for the failure page.** Treat a reporting line in a unit-run script as missing from the page unless the script's long-lived shell prints it.
- **Advice that reads only `-u`:** the long-unit follow command at `harness/run-it-now.md:81`, and the post-merge activation learning's "`journalctl --user -u dotup-refresh.service` names the reason". When `-u` looks short, read again by `-t` or by time before concluding anything. (`harness/run-it-now.md:75-78` already says so.)
- **Unaffected:** checks that count the manager's own lines through `-u`, such as `scripts/unit-health.sh`'s `Failed with result` count. Those records carry `USER_UNIT`.
- **No automated check.**
  - A static rule for "output through a pipeline child in a unit script" cannot tell a reporting line from a captured value (`$(... | sed)` is fine).
  - CI has no journald, so a test can pin a line's printed format but not its attribution.
  - After changing how a unit-run script prints, re-run the transient-unit probe on the host and count with the invocation-id selector.

## Related Issues

- dotfiles#1215 (jsm-auto-update) and dotfiles#1555 (docker-hygiene): the two earlier cases.
- hov-stack#793 and PR #796: the wt-sweep case and the builtin-loop fix.
- PR #811: the failure-page measurement and the six-site fix.
- [The user manager's stock PATH](the-user-managers-stock-path-has-no-local-bin-house-path-preflight-and-kept-stderr-on-the-unit.md): its "time window, not only `-u`" bullet is the reader-side fallback with a narrower stated cause.
- [Drive post-merge activation](drive-post-merge-activation-instead-of-handing-back.md): points readers at `-u` for dotup's refusal reason.
- `CONCEPTS.md` → "Unit failure alert": what the failure page is for.
