# WSL memory bounds

Kernel-enforced ceilings on the two things that were eating the VM on
2026-09-16 (Docker containers and a headless review browser), plus the
lifecycle fix for why one of them grew. Read this when
`vmmemWSL` is fat, `free` looks fine, and "we're only running a few agents".

## What was actually holding the memory

Guest at 15 days uptime, 2 live agent sessions (407 MB combined):

| consumer | RAM | swapped | why |
|---|---|---|---|
| 87 Docker containers | 2.9 GB | 7.0 GB | 24 Supabase stacks whose worktree was gone (up to 2 weeks) |
| headless review browser | 3.6 GB | 3.0 GB | 28 review-conversation tabs never closed |
| zram holding evicted pages | 4.2 GB | — | working as designed; `free` does not show it |

Three sweepers existed and all three ran: `docker-hygiene` WARNed on the 24
orphans and stopped none (`STOP_IDLE=0`, and orphans were a separate
report-only class); `wsl-watchdog` could not fire because its swap-% gate was
computed against a `SwapTotal` inflated to 84 GB by a stale 48 GB scratch
swapfile; `wt-sweep` removed 170 worktrees and has no container awareness.
Sweepers need heuristics; heuristics drift. Bounds do not.

## The bounds (shipped via `SYSTEM_UNITS` in `sync.sh`)

A bound on a job that can stall must degrade it gracefully, and the first
policy tried on the review browser did not: a low `MemoryHigh` with a swap cap
and `OOMPolicy=stop` stalled its renderers in reclaim while host-wide free RAM
looked healthy. The repair that held was `MemoryHigh=infinity` (explicitly no
cgroup throttling), a `MemoryMax` bound on resident memory, a separate
`MemorySwapMax`, and `OOMPolicy=continue`, so that a child killed by the OOM
killer does not take every sibling process down with it. Change a managed
bound through the repository, not only `/etc`: a host-only repair is
overwritten by the next install of the unchanged source, and a byte-identical
copy of the wrong policy passes a copy check, so assert the deployed values.
A bound does not fix a leak (here, tabs that were never closed); it only
limits the damage.

`systemd-system/docker-containers.slice` — `MemoryHigh=12G` and
`MemorySwapMax=6G` over every container (same reason: without the swap cap the
bound only caps RAM), no `MemoryMax` (never OOM-kill a database;
`unless-stopped` would just restart it) — a runaway stack is throttled, not
killed. Containers land in the slice via `"cgroup-parent":
"docker-containers.slice"` in `/etc/docker/daemon.json`; systemd parents the
unit under `docker.slice` because of the dash. Existing containers stay in
`system.slice` until recreated — the fleet migrates as stacks restart.
`live-restore: true` (PR #1149) is what makes the `dockerd` restart safe.

The `cgroup-parent` key is set on this host but not yet owned by
`docker-daemon-config.py`, whose state schema is `init`-specific (17 sites,
rollback path included). `reconcile` preserves foreign keys, so the value
survives; a fresh host would not get it. Tracked as a follow-up.

Activation after `sync.sh install` places a new drop-in or slice:
`sudo systemctl daemon-reload` — resource-control properties apply to the
running unit on reload, verified by reading `memory.high` under
`/sys/fs/cgroup/system.slice/<unit>/`.

## Batch jobs that read a large corpus (#1394)

On 2026-09-24 the journal's `Consumed ... memory peak` lines ranked the
oneshot units that read `~/.claude/projects`, at peaks from 5.8G to 26.8G.
None had a bound. Each run evicted idle agent processes to swap, and those
pages never faulted back, so swap climbed a little with every run. Snapshots
taken at night show only what is left over. Rank those journal peaks before
blaming whatever is live at the moment, but don't treat the ranking as
complete: systemd 255 logs no `memory peak` for some runs, or an implausible
3.6-9.5M, so a unit can go unranked until its first bounded run reaches the
bound. A oneshot unit's cgroup and its counters are gone once it exits, so
its memory stall can only be sampled while it runs.

Measured in a capped transient scope (`MemorySwapMax=0`), the heavy steps of
those jobs needed only 2.0-4.6G anon; the rest was page cache. So bound them
with `MemoryHigh` set well above the anon figure. None of them gets
`MemoryMax`, because each failure path handles an OOM kill badly: a job that
disables its own timer after three consecutive failures, an alerter that
pages only on `Result=timeout`, and a report that nothing else watches. They
get no swap cap either. With `MemoryHigh` and a swap cap, anon above the line
has nowhere to go, so the kernel keeps throttling the unit: a job with a
per-call timeout stalls into it, and a job with no timeout just runs slower
and slower. Throttling there would still be silent, so have the job (or its
report) read its own cgroup and WARN when it stalled 60s or more on memory
with the bound engaged. The stall (`memory.pressure`) is the signal, not the
peak or the `high` count: both count page cache, and at `MemoryHigh=64M` a
1 GiB cache read and a 300 MB anon overflow both peaked at the bound with
thousands of `high` events but stalled 0.04s and 1.87s.

Leave an anon-heavy job unbounded. One whose working set was roughly
20-34G, bounded at `MemoryHigh=12G` with no swap cap, pushed 22G into swap
until earlyoom (`-m 6,3 -s 6,3`) killed it every night; tightening to 8G was
worse (#1235). A gateway that is 99% anon and already restarts itself at
4 GiB RSS is the same case: `MemoryHigh` would stall every agent's API
traffic, and `MemoryMax` with `OOMPolicy=stop` would take it down. A bound
only helps a job whose excess is cache.

## The lifecycle fix

`docker-hygiene.sh` `STOP_ORPHANS=1` (on in the author's scheduled unit; the shipped unit is plan-only): a stack
with no checkout anywhere and no live process is stopped by label (`supabase
stop --project-id`, accepted from any cwd) through the same identity +
liveness guards as an idle stop, with the checkout map re-scanned at action
time so a checkout that appeared since the plan turns the stop into a hold.
"Anywhere" is enforced with two signals that are not `$SITES`-scoped, because
the plan-time scan and liveness map are: the stack's own bind mounts (a
source under a `supabase/` directory that still exists on disk is the
checkout, wherever it lives — the review of PR #1191 found a `/tmp`
verification checkout still bind-mounted by its studio container) and any
process cwd anywhere that walks up to a `config.toml` declaring the project.
Residual: a db-only stack (no bind mounts) whose checkout is outside `$SITES`
with no process inside it reads as an orphan. The stop itself keeps volumes;
`REAP_VOLUMES=1` (on in the author's scheduled unit since #1627) later removes a
stopped stack's volumes once no checkout under `$SITES` declares its project
and they are past the 24 h grace.
`STOP_IDLE` stays off: a quiet checkout is still someone's checkout.

`STOP_ORPHANS=1` stopped nothing from its enablement on 2026-09-16 until
#1555 (PR #1562, merged and installed 2026-10-05). The unit set no PATH, the
systemd user manager's stock PATH has no `~/.local/bin`, so every `supabase
stop` was exit 127 and the script discarded the CLI's stderr; the first stop
attempts, 25 of them on 2026-09-30, all failed and the alert said only
`Result=exit-code`.
The fix is the house `Environment=PATH=` line in the unit; a `command -v
supabase` preflight before the first docker call whose miss names the binary,
the PATH searched and the remedy, refuses every stop with a per-stack
`held_precondition` row, keeps the exited-container and image reclaim running
(AGGRESSIVE reclaim is the disk-full lever), and fails the run under `STRICT`
with the cause in `observation_error_details`; the CLI's stderr kept in the
FAILED line and the JSON action detail; and a test section that runs the
unit's own environment under `systemd-run --user`. A manual run with the
house PATH on 2026-10-04 stopped 28 of 28 orphan stacks (60 containers) and
took `docker-containers.slice` from 10.7 to 8.1 GiB. The installed unit's
first stop came on 2026-10-05, before its timer had fired again: `systemctl
--user start docker-hygiene.service` against a throwaway db-only stack
(`supabase start` in a scratch directory, then the directory deleted, so no
checkout or mount claims it) classified it `orphaned` and logged `ok:
stopped` with zero action errors.

## The watchdog

`bin/wsl-watchdog.sh` (cron, every 5 min) now gates on
`/proc/pressure/memory` `full avg60` (default 5%) or `MemAvailable` under 5%,
not swap-used %. PSI is the kernel's own stall signal and does not move when a
swap device is added.

## Claude Code's own background-shell reap (opted out, #1442)

"Background command X was stopped because the system is running low on
memory" is not earlyoom, the watchdog, or the heavy-job scope: it is Claude
Code's `LocalShellTask` memory-pressure reap (decoded from 2.1.284 on
2026-09-28). It kills the session's running background Bash task when Bun's
PSI trigger fires (`some 150000 2000000` on `/proc/pressure/memory`, so 150 ms
of stall in a 2 s window), `MemAvailable` is under 10% and under 4 GiB, the
session has had no terminal input for 30 minutes, and no turn or delegated
agent is running. The idle clock resets only on human input, never on task
notifications or subagent output, so every `--bg` job older than 30 minutes
qualifies, and the reap lands exactly when the model is waiting on its heavy
step. The notice tells the model not to restart the command, which is why
reaped agents stop with "say resume". Twelve days to 2026-09-28: at least 105
reaps across 36 sessions, while earlyoom, the watchdog and the heavy-job
`MemoryMax` scope killed nothing.

`CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` in the settings `env` block
turns it off; `reconcile-runtime-env` carries it to the live file, and it
reaches daemon-spawned `bg-spare` sessions. New sessions only: exporting it
inside a Bash call does nothing. The name is checkable without the decode:
`rg -a -c -F CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP "$(dirname "$(readlink -f "$(command -v claude)")")/claude.exe"`
prints 5 on 2.1.284, and the same file carries the notice text "setting it
from a shell command has no effect"; a release where that count is 0 has
renamed or removed the switch. Opting out removes the wrong response, not
the pressure. The bursts that cross the 4 GiB line are single processes
spawned by agent sessions in `init.scope`, invisible to the journal's memory
peaks and the 5-minute watchdog sample. The first one caught, pro-gate's
whole-tree shellcheck, reached 13.6 GB in 53 s (pro-gate#244); pro-gate#245
turned off ShellCheck's dataflow pass for the one 832 KB test file that
needed over 6 GB on its own, and the whole-tree lint now peaks near 2.3 GB
in 23 s (measured 2026-09-28 with ShellCheck 0.11.0). A "pressure but no
unit is fat" question therefore needs a 5-second sampler, not a snapshot: a
loop that every 5 s reads `MemAvailable` from `/proc/meminfo` and, whenever
it is under a threshold (6 GB caught this one), appends the timestamp, the
value and the top processes by RSS (`ps -eo pid,rss,etimes,comm --sort=-rss
| head`) to a log under `/tmp/<dir>/`, left running across the window where
the reap notices occur and read afterwards. Point-in-time `ps`, the journal's
`memory peak` lines and the watchdog's 5-minute sample all miss a process
that lives under a minute, and an `init.scope` process leaves no cgroup
accounting behind.

## What this does not fix

`vmmemWSL` on the Windows side keeps its high-water mark
(`autoMemoryReclaim=dropCache` returns only page cache; `gradual` was rejected
with citations in `.wslconfig`). It shrinks on a WSL restart or by lowering
`memory=` — a policy call, not a bug. Guest PSI at the time was `full
avg60=0.07`: the guest was not thrashing; the pressure was host-side.
