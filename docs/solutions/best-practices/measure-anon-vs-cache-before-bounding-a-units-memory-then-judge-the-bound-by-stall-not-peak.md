---
title: "Measure anon vs. page cache before bounding a systemd unit's memory, and judge the bound by stall, not peak"
date: 2026-09-26
category: best-practices
module: wsl-memory-bounds
problem_type: best_practice
component: infrastructure
severity: high
applies_when:
  - "Before adding MemoryHigh, MemoryMax, or MemorySwapMax to a systemd unit whose anon-vs-cache memory mix has not been measured in a capped, swap-disabled scope"
  - "Choosing bounds for a batch oneshot unit whose failure path does not handle an OOM kill or a run stalled into its timeout"
  - "Judging whether a bound already in place is costing a unit time, when memory.peak and the memory.events high count are the only signals on hand"
  - "The unit is a oneshot whose cgroup and counters are removed when it exits, so stall has to be sampled while it runs"
symptoms:
  - "cass-index was SIGTERMed by earlyoom night after night, with swap full, under a MemoryHigh=12G bound on an anon-heavy working set"
  - "oracle-chrome review renderers wedged in reclaim under MemoryHigh=4G while host-wide free RAM looked healthy"
  - "A first-revision harness-weekly memory alarm keyed on 90% of peak would have fired on every cache-heavy run"
root_cause: missing_validation
resolution_type: workflow_improvement
related_components:
  - cass-index
  - oracle-chrome
  - harness-weekly
  - leaderboard-submit
  - tokscale-submit
  - ccflare-stack
tags:
  - systemd
  - cgroup
  - memoryhigh
  - page-cache
  - psi-stall
  - swap
  - wsl
  - memory-bounds
---

# Measure anon vs. page cache before bounding a systemd unit's memory, and judge the bound by stall, not peak

## Context

On 2026-09-24 the journal's `Consumed … memory peak` lines ranked the unbounded units that read the whole `~/.claude/projects` corpus: `leaderboard-submit@board-a` at 26.8G, `leaderboard-submit@board-b` at 15.0G, `tokscale-submit` at 9.6G and `harness-weekly` at 5.8G. None had a bound, and each run pushed idle agent processes into swap that never faulted back (`harness/wsl-memory-bounds.md:68-74`). The obvious fix, a cap sized to the peak, would have been wrong. Most of that peak was page cache from reading the corpus, and two units on the same host already showed what a bound does to memory that is *not* cache.

- **cass-index** carries `MemoryHigh=12G` and `MemoryMax=26G` (`systemd/cass-index.service.d/memory-experiment.conf:41-43`) on a working set of roughly 20-34G of anonymous memory. On 2026-09-21 its nightly run was SIGTERMed at 12.6G RSS with a 22.1G swap peak. It never reached `MemoryMax`, so this was not a cgroup OOM. earlyoom (`-m 6,3 -s 6,3`) chose it once free RAM and free swap were both low, and its deliberate `OOMScoreAdjust=300` made it the preferred victim. Tightening the bound to 8G on a relaunch did lower RSS, but it moved the difference into swap: a 24.0G swap peak, with free swap at 0 MB five times. In the session's own words, "I throttled it into swap exhaustion" (issue #1235, comment of 2026-09-21; session history). That diagnosis read peaks and `free -g` and never split cache from anon or read a stall figure (session history). The nightly kills continued and are tracked on open issue #1220.
- **oracle-chrome**, pro-gate's review browser, originally ran under `MemoryHigh=4G`. That wedged renderers in reclaim instead of bounding them, and host-wide free RAM never showed it because the stall was local to the cgroup (pro-gate issue #212). Its drop-in now sets `MemoryHigh=infinity`, `MemoryMax=10G`, `MemorySwapMax=4G` and `OOMPolicy=continue` (`systemd-system/oracle-chrome.service.d/memory.conf:1-13`).

The #1394 investigation turned this into a practice. First, measure what a unit's excess memory is. Bound only cache-heavy units, and bound them with `MemoryHigh`. Then judge what the bound costs by the cgroup's `memory.pressure` stall, sampled while the unit runs.

## Guidance

**1. Measure anon vs. file in a capped scope with swap disabled.** Run the unit's heavy step in a transient scope and sample the scope's own `memory.stat`. With `MemorySwapMax=0`, anything the step cannot fit in RAM shows up as an OOM kill or a slow run instead of disappearing into swap:

```bash
systemd-run --user --scope --unit=memprobe-<name> \
  -p MemoryMax=<cap> -p MemorySwapMax=0 <cmd> &
sleep 0.3   # let the scope's cgroup appear
CG=/sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/app.slice/memprobe-<name>.scope
while kill -0 $! 2>/dev/null; do
  awk '$1=="anon"{a=$2} $1=="file"{f=$2} END{print a+0, f+0}' "$CG/memory.stat"   # anon, file bytes
  cat "$CG/memory.current"; tr '\n' ' ' <"$CG/memory.events"; echo
  sleep 0.5
done
```

Record the anon peak, the file peak, wall time, the exit code and whether `oom_kill` fired. Re-run with `-p MemoryHigh=<cap>` in place of `MemoryMax` and compare wall time with an unbounded run. This is how #1394 found that the steps it measured need only 2.0-4.6G anon, with everything above that being page cache: ccusage (which board-a's submitter runs internally) took 4.0-4.3G, the board-b preview 4.6G and the tokscale scan 2.0G. They showed no slowdown under a 6G bound (`systemd/leaderboard-submit@.service:31-39`, `systemd/tokscale-submit.service:22-25`).

**2. Choose the bound from the split first, then fit it to the unit's failure path.** The split decides whether `MemoryHigh` belongs on the unit at all. The kind of unit does not override it.

- **Excess is mostly anon: no `MemoryHigh`, whatever kind of unit it is.** Above the line, anon either goes to swap (no swap cap) or the unit is throttled in reclaim (swap capped or full). cass-index is the first case, and it is itself a batch oneshot (`systemd/cass-index.service:7`, `Type=oneshot`). oracle-chrome's old policy is the second case. `ccflare-stack` is about 99% anon and already restarts itself at 4 GiB RSS, so it stays unbounded: `MemoryHigh` would stall every agent's API traffic, and `MemoryMax` with `OOMPolicy=stop` would take the gateway down (`harness/wsl-memory-bounds.md:101-108`). For an anon-heavy unit the lever is its own working set or restart logic, not a cgroup line.
- **Excess is mostly cache:** set `MemoryHigh` above the measured anon, with headroom. The kernel drops clean cache pages at the line almost for free.
- **A cache-heavy batch oneshot gets `MemoryHigh` only,** with no `MemoryMax` and no `MemorySwapMax`. Check the unit's own failure path before adding either:
  - **An OOM kill** turns off a leaderboard board's timer after three failures in a row, or goes unreported if `OOMPolicy=stop` stops the runner first, because the timeout alerters page only on `Result=timeout`. harness-weekly is watched by nothing else (`systemd/leaderboard-submit@.service:40-44`, `systemd/tokscale-submit.service:26-29`, `systemd/harness-weekly.service:34-36`).
  - **A swap cap** gives anon above the line nowhere to go, so the unit is throttled until its 300s per-call timeout. harness-weekly has no start timeout at all, so it would just keep running slower (`systemd/leaderboard-submit@.service:45-47`, `systemd/tokscale-submit.service:30-33`, `systemd/harness-weekly.service:36-38`).
  - **Spilling to swap** is the better failure for these units, because that swap is freed when the unit exits (`systemd/leaderboard-submit@.service:48-50`).

**3. Judge the bound's cost by stall, never by peak or the `high` count.** Both `memory.peak` and the `high` line of `memory.events` count page cache. A cache-heavy unit pins them at the bound even when trimming costs nothing. Only `memory.pressure` separates cheap cache trimming from real throttling: its `some`/`full` `total=` fields are cumulative microseconds of stall. This scope probe reproduces the difference without dropping host caches, because a freshly `fallocate`d file has never been read into the page cache:

```bash
report='c=/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup); cat $c/memory.peak; grep ^high $c/memory.events; cat $c/memory.pressure'
fallocate -l 1G f
systemd-run --user --scope --expand-environment=no -p MemoryHigh=64M bash -c "cat f >/dev/null; $report"                              # cache only
systemd-run --user --scope --expand-environment=no -p MemoryHigh=64M bash -c "x=\$(head -c 300000000 /dev/zero | tr '\\0' a); $report"  # anon overflow
```

Re-run exactly as printed here while this learning was written (2026-09-26, output in PR #1402's test plan), the probe gave 2,100 vs. 22,078 `high` events and 0.03 s vs. 1.42 s of stall. The separation held.

Measured 2026-09-24:

| Workload at `MemoryHigh=64M` | Peak | `high` events | Memory stall | Wall |
|---|---|---|---|---|
| 1 GiB cache read | 100% of the bound | 2,107 | 0.04 s | 0.28 s |
| 300 MB anon overflow | 100% of the bound | 21,841 | 1.87 s | 6.76 s |

Peak and `high` saturate for both workloads, and only the stall tells them apart. harness-weekly's self-check follows this rule (its Monday timer was retired by dotfiles #1893 on 2026-10-17, so `scripts/harness-weekly.sh` now runs on demand). It WARNs on 60 s or more of `some` stall while `high` is above 0 (`scripts/harness-weekly.sh:909-945`). Its first revision WARNed at 90% of peak, which would have fired on every cache-heavy weekly run.

**4. Sample a oneshot's stall while it runs.** A oneshot unit's cgroup, and every counter in it, is removed when the unit exits (`harness/wsl-memory-bounds.md:79-81`). Neither the journal nor `systemctl show` preserves the stall. The journal's `memory peak` cannot stand in for it either. systemd 255 on this host logs none for most leaderboard runs, or an implausible 3.6-9.5M (`harness/wsl-memory-bounds.md:75-78`). On 2026-09-26 it logged `9.0M memory peak` for two units whose cgroups actually peaked at 12.01G and 10.47G. So poll the unit's own cgroup directory while it exists, and keep the last sample:

```bash
APP=/sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/app.slice
# A template instance lives one level down, e.g. $APP/'app-leaderboard\x2dsubmit.slice'/leaderboard-submit@<board>.service
while true; do
  for d in "$APP/<unit>.service" "$APP"/'app-<template>.slice'/<template>@*.service; do
    [ -d "$d" ] || continue
    { printf '%s peak=%s swap=%s ' "$(date -Iseconds)" "$(cat "$d/memory.peak")" "$(cat "$d/memory.swap.current")"
      awk '$1=="high"{printf "high_events=%s ", $2}' "$d/memory.events"
      awk '{printf "%s_%s ", $1, $5}' "$d/memory.pressure"; echo; } >>"/tmp/<dir>/${d##*/}.log"
  done
  sleep 2
done
```

Confirm the directory shape with `systemctl --user show -p ControlGroup <unit>` while the unit is running. The counters are cumulative from the cgroup's creation, so a log's last line holds that run's totals, minus at most the final polling interval. Poll for the directory rather than `systemctl is-active`. A running `Type=oneshot` unit reports `activating`, not `active`, so an `is-active` loop exits before it has sampled anything. On this host's systemd 255, a transient `Type=oneshot` `sleep` printed `activating` and `is-active` exited 3 while it ran. Its `ControlGroup` was empty and its cgroup directory gone once it exited (2026-09-26, PR #1402's test plan).

## Why This Matters

The two signals that are easy to read are the ones that mislead. A peak-sized cap on a cache-heavy job binds on memory the kernel could have dropped for free. A `MemoryHigh` on an anon-heavy job converts memory pressure into swap exhaustion or a reclaim stall. Both cost a working service, and on this host they did: cass-index was killed nightly, and pro-gate reviews wedged. After the fact, `memory.peak` and the `high` count look identical for a harmless cache trim and a harmful anon stall, and the journal's own peak figure for these units is missing or wrong. Without the anon/file split up front and a stall sample during the run, you cannot tell whether a bound is working, doing nothing, or hurting.

The corpus batch units are the positive case. The steps measured for leaderboard-submit@ and tokscale-submit took 2.0-4.6G anon, a fraction of those units' journal peaks (9.6-26.8G). So `MemoryHigh` there trims cache and stays clear of the working set. harness-weekly's anon was never measured. Its 12G sits above its whole 5.8G peak, so it is a ceiling against growth rather than a trim (`systemd/harness-weekly.service:31-34`). PR #1395 shipped `leaderboard-submit@` at 12G, `tokscale-submit` at 8G and `harness-weekly` at 12G (`systemd/leaderboard-submit@.service:51`, `systemd/tokscale-submit.service:34`, `systemd/harness-weekly.service:42`), and PR #1398 corrected the peak figures their comments carry. `tests/batch-unit-memory-bounds.test.sh:52-68` asserts that each unit has exactly that `MemoryHigh` and no `MemoryMax` or `MemorySwapMax`.

## When to Apply

- Before adding any cgroup memory property to a unit, service or scope. This matters most for one that reads a large corpus, cache directory or repo tree, because its peak will look dramatic and be mostly cache.
- When a memory balloon is being triaged from the journal's `memory peak` lines. Use them to decide which unit to measure next, not as the size of a cap.
- When those lines show no fat unit but the host still dipped under 4 GiB available. Agent-spawned single processes in `init.scope` (a whole-tree shellcheck reached 13.6 GB in under a minute) leave no unit peak and no cgroup accounting; catch them with the 5-second sampler described in `harness/wsl-memory-bounds.md`. A "stopped because the system is running low on memory" notice in a session is Claude Code's own background-shell reap (#1442), not a unit kill.
- When deciding whether a shipped bound is slowing a unit. Read that unit's cgroup while it runs, not the journal after it exits.
- When a unit is anon-heavy, whether a nightly oneshot like cass-index or a long-running gateway like ccflare. There, `MemoryHigh` is the wrong lever; rely on the workload's own working set, restart or backpressure.

## Examples

**The first full day of per-run stall readings (2026-09-26, #1394).** A read-only watcher polled each bounded unit's cgroup every 2 s, as in step 4. All eight units succeeded, and every board receipt reads `ok`.

| Unit (bound) | Peak | `high` events | Stall some / full |
|---|---|---|---|
| `tokscale-submit` (8G) | 5.85G | 0 | <0.01 / <0.01 s |
| `leaderboard-submit@board-a` (12G) | 12.01G | 49,373 | 10.27 / 9.55 s |
| `leaderboard-submit@board-b` (12G) | 12.00G | 97,603 | 10.70 / 9.84 s |
| `leaderboard-submit@board-c` (12G) | 12.00G | 41,074 | 4.57 / 4.37 s |
| `leaderboard-submit@board-d` (12G) | 12.01G | 174,292 | 7.69 / 7.40 s |
| `leaderboard-submit@board-e` (12G) | 12.00G | 12,681 | 6.47 / 6.19 s |
| `leaderboard-submit@board-f` (12G) | 12.00G | 40,075 | 14.09 / 12.68 s |
| `leaderboard-submit@board-g` (12G) | 10.47G | 0 | 4.21 / 4.04 s |

Six of the eight reached their bound, with 12,681 to 174,292 `high` events each. Judged by peak or `high`, each of those six looks throttled. Judged by stall, the bound cost at most 4-14 s per run. Some of that is host-wide reclaim, as the next paragraph shows.

board-g also shows that stall and `high` measure different things. Its own bound never engaged (0 `high` events), yet it stalled 4.2 s. That time came from host-wide reclaim, since every ancestor cgroup up to `user.slice` has `memory.high` = `max`.

**Eliminating the bound as a suspect.** On 2026-09-25, its first bounded run, board-b used 4m07s of CPU against 2m08s-2m34s over its previous seven runs, on the same pin (0.6.0). On 09-26 it used 4m21s. The bound was the obvious suspect, since the step began the day it shipped, and peak and `high` (12.00G, 97,603 events) seemed to agree. The stall rules it out as the likely cause:

- The 10.7 s stall is about a tenth of the extra CPU.
- Five other boards reached the same 12G bound, with 12,681 to 174,292 `high` events, and showed no CPU step.
- The 09-26 reading on #1394 also ruled out overlap with another board and package drift.

The cause is still unidentified, somewhere inside the vendor's own sync. Reading only peak and `high` would have pinned it on the bound and led to raising `MemoryHigh` for every board, since `leaderboard-submit@` is a shared template.

**Evidence limits.**

- Only three steps had their anon measured: ccusage, the board-b preview and the tokscale scan. The other five boards got the 12G bound as instances of the shared `leaderboard-submit@` template, without being measured one by one. harness-weekly's 12G is set above its whole journal peak.
- board-a's Go parse of other agents' sessions was never measured, because its `-dry-run` skips usage (`systemd/leaderboard-submit@.service:48-49`). Its 12G bound engaged on 09-26 at a 10.27 s stall.
- harness-weekly's first bounded run was Monday 2026-09-28. Whether the WARN path fired on a scheduled run before the timer's retirement (dotfiles #1893, 2026-10-17) was not re-checked; since then the script runs only by hand.
- The 60 s WARN threshold is a starting value, "about 7% of a 15-minute run", not a measured boundary. The report prints the stall on every run (weekly until 2026-10-17, on demand since) so the threshold can be tuned (`scripts/harness-weekly.sh:918-921`).
- A 2 s poll can miss up to 2 s of stall at the end of a run, so the figures above are lower bounds.
- The anon measurements are one run per step on 2026-09-24, and they will drift as the corpus grows. Re-measure before tightening a bound.

## Related

- `harness/wsl-memory-bounds.md`: the shipped bounds for oracle-chrome, docker-containers.slice and the corpus batch units, and the reasoning behind each.
- #1394 (bounded-unit first-run and per-run stall readings), PR #1395 (the bounds), PR #1398 (peak-figure corrections).
- #1220 and #1098 (cass-index kills), #1235 (the 8G relaunch that drove swap to exhaustion), pro-gate #212 (MemoryHigh wedging the review browser).
- #1193 (the bg-spare pool, an adjacent unbounded consumer).
- `docs/solutions/runtime-errors/eliminate-supabase-zombies-without-restarting-wsl.md`: another WSL host-resource fix made at the lifecycle layer rather than by restarting.
