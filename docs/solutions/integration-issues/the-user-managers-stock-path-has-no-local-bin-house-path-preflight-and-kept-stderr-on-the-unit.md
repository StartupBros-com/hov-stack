---
title: "The user manager's stock PATH has no ~/.local/bin: give the unit the house PATH, preflight the binary, keep the CLI's stderr"
date: 2026-10-05
category: integration-issues
module: claude-systemd-docker-hygiene-unit-path
problem_type: integration_issue
component: development_workflow
severity: high
symptoms:
  - "docker-hygiene.timer's 2026-09-30 run paged the operator only as `Result=exit-code`; `journalctl --user -u docker-hygiene` showed zero `failed:` lines, while an unfiltered time window showed 25 `failed: supabase stop project=<id> --project-id` details with no CLI output, printed in a burst at the end of the run under a child PID"
  - "`systemd-run --user --pipe --wait --collect --quiet /usr/bin/env supabase stop --project-id probe-nonexistent-x` printed `No such file or directory` and exited 127 on 2026-10-04; the same command from a login shell exited 0"
  - "`systemctl --user show-environment` printed the stock system PATH with no `~/.local/bin`, where the supabase CLI lives, and `systemd/docker-hygiene.service` set DRY_RUN, AGGRESSIVE, STOP_ORPHANS and STRICT but no PATH"
  - "Eighteen days after STOP_ORPHANS=1 shipped, a `DRY_RUN=1` run on 2026-10-04 classified 36 of 41 running Supabase stacks as orphans (105 of 167 containers); the first signal was a report that the WSL host was thrashing"
root_cause: config_error
resolution_type: code_fix
related_components:
  - "docker-hygiene.service"
  - "docker-hygiene.timer"
  - "docker-hygiene.sh"
  - "docker-hygiene.test.sh"
  - "unit-path-coverage.test.sh"
tags: ["systemd", "user-manager", "path", "environment", "exit-127", "stderr", "preflight", "docker-hygiene"]
---

# The user manager's stock PATH has no ~/.local/bin: give the unit the house PATH, preflight the binary, keep the CLI's stderr

## Problem

`systemd/docker-hygiene.service` had run its weekly `STOP_ORPHANS=1` pass since 2026-09-16 (PR #1191) without stopping a single stack. The systemd user manager's stock PATH has no `~/.local/bin`, so every `supabase stop` the script ran was exit 127, and the script sent the CLI's stderr to `/dev/null`, so nothing recorded why. The unit had been verified from a shell, deployed under systemd, and listed as a deliberate exemption in the PATH guard. Orphan Supabase stacks accumulated until a person noticed the WSL host thrashing. Fixed by PR #1562 (issue #1555), opened 2026-10-04 and merged 2026-10-05; the issue stays open until the first scheduled run after the fix (Wed 2026-10-07 01:50 EDT) shows `ok: stopped` lines or a captured cause.

## Symptoms

- The 2026-09-30 run's only operator-visible record was `Result=exit-code` from the unit's failure alert. `journalctl --user -u docker-hygiene` showed zero `failed:` lines; an unfiltered time window showed 25. The per-stack detail is printed in a burst at the end of the run, and journald attributed that burst to a child PID with no unit field (auto memory [claude]).
- Each detail said only `failed: supabase stop project=<id> --project-id`. The CLI's stderr had gone to `/dev/null` at the call site, so the exit 127 was never written anywhere. For the 09-30 run the PATH cause is inference from the mechanism reproduced on 10-04, not a captured message.
- `systemd-run --user --pipe --wait --collect --quiet /usr/bin/env supabase stop --project-id probe-nonexistent-x` printed `No such file or directory` and exited 127; the same command from a shell exited 0 with nothing matched (2026-10-04).
- `systemctl --user show-environment` printed the stock system PATH. The unit set `DRY_RUN`, `AGGRESSIVE`, `STOP_ORPHANS` and `STRICT` and no PATH, while 27 of the repo's 36 service units already carried one.
- A `DRY_RUN=1 docker-hygiene.sh` run on 2026-10-04 classified 36 of 41 running Supabase stacks as orphans, 105 of 167 containers, eighteen days after the stop pass was switched on.

## What Didn't Work

1. **Reading the unit's own journal for the cause.** `journalctl --user -u docker-hygiene` had the summary and the exit status and none of the 25 details, because the script buffers its per-stack failure lines and prints them at exit, and journald lost the unit attribution on that burst. Widening to a time window found the lines, and they still carried no cause, because the stop call discarded stderr. Two independent losses, journal attribution and discarded stderr, had to be worked around before the 127 could even be hypothesised.

2. **Trusting the PATH guard's exemption.** The guard exists for exactly this failure: `tests/unit-path-coverage.test.sh:2` states that every directly executed managed-path service must declare a systemd PATH. docker-hygiene sat in its `PATH_EXEMPTIONS` registry as `docker maintenance dependency audit is outside this outage fix`, a deferral, not an audit (the guard and its registry arrived with PR #544; PR #653, the harness-weekly outage fix of 2026-08-29, lifted that unit's entry and left docker-hygiene's standing). The same registry already recorded two deferrals lifted after the same not-found failure (`unit-path-coverage.test.sh:45-53` and `:62-71`): dispatcher-tick's first timer-fired dispatch on 2026-08-30 died in one second on `env: 'claude': No such file or directory`, and harness-weekly's version checks took their not-found branch every Monday while Claude Code drifted eight patches unreported. docker-hygiene was the third unit through the same hole, each time because "outside this fix" was read as "audited".

3. **Interactive verification.** The script had been exercised from a login shell, where `~/.local/bin` is on PATH, and the unit was deployed as if that proved it. A user unit runs with the manager's environment, the stock system PATH plus whatever the unit file sets; the login shell's PATH never reaches it. Verification that does not run under the manager cannot see a PATH-class failure, the same scope gap as the sibling [network-online.target doc](network-online-target-does-not-exist-in-the-user-manager-gate-readiness-in-the-script-instead.md), where a directive verified green in system mode did nothing in the user manager.

4. **A preflight that failed the whole run closed.** The first draft of the fix refused the entire run when the CLI was missing. The operational review lens and the advisor overturned it: aggressive reclaim of exited containers and dangling images is the disk-full lever this unit exists for, and a PATH regression must not switch that off for weeks. The shipped preflight refuses stops only and lets reclaim run.

5. **Reordering the preflight after the daemon gate.** Pro review round 1 found that when the Docker daemon was also unreachable, the daemon-unreachable early exit printed a fixed `observation_errors: 0` and an empty detail list, contradicting the preflight warning printed a few lines above it. Its first suggested fix, running the preflight after the gate, would have defeated the suite's systemd probe, which isolates itself with `DOCKER_HOST` at a dead socket and relies on the preflight running before the gate. The fix folds the recorded count and detail into the gate's exit instead. The script's comment on that exit (`docker-hygiene.sh:374`) labels it round 2: the script's comments count gate-loop rounds, a fix session followed by its review, so each runs one ahead of the review round that raised the finding.

6. **A remedy naming the wrong knob.** Pro review round 2 (the script's comment at `docker-hygiene.sh:357` labels the fix round 3, by the same count): the preflight's remedy said to set `STOP_ORPHANS=0` even on an idle-only run, where that was already true, so an operator following it changed nothing. The remedy now names the stop modes actually on.

## Solution

**The unit carries the house PATH** (`systemd/docker-hygiene.service:58`), the same line `systemd/harness-weekly.service:30` carries (its timer was disabled in dotfiles #1893; `systemd/claim-reap.service` carried it too until #1902 deleted it):

```
Environment=PATH=%h/.local/bin:%h/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**The script preflights the binary before its first docker call** (`scripts/docker-hygiene.sh:349` onward; the rationale is the header comment at `:76-95`):

```bash
SUPABASE_BIN=""
if [ "$DRY_RUN" != 1 ] && { [ "$STOP_IDLE" = 1 ] || [ "$STOP_ORPHANS" = 1 ]; }; then
  SUPABASE_BIN=$(command -v supabase 2>/dev/null || :)
  if [ -z "$SUPABASE_BIN" ]; then
    _cause="supabase CLI not found on PATH=${PATH:-}"
    echo "docker-hygiene: !! $_cause"
    _off=""
    [ "$STOP_IDLE" = 1 ] && _off="STOP_IDLE=0"
    [ "$STOP_ORPHANS" = 1 ] && _off="${_off}${_off:+ }STOP_ORPHANS=0"
    echo "docker-hygiene: stack stops are enabled (...) and will be refused this run; exited-container and image reclaim continue. Remedy: install the CLI, add its directory to the unit's Environment=PATH, or set $_off ..."
    note_observation_err "$_cause"
  else
    echo "docker-hygiene: supabase CLI: $SUPABASE_BIN (stack stops enabled)"
  fi
fi
```

A miss records one observation error, so `STRICT=1` exits 1 and the unit's failure alert carries the cause, PATH searched and remedy. It is recorded eagerly rather than at the first refused stop: a host with the timer enabled, a stop mode on and no CLI is misconfigured and should page even on a week with nothing to stop. Dry runs and runs with both stop modes off never exec the CLI and are not gated. Every stop that run is then refused before its identity reads, with a per-stack row and no CLI call (`docker-hygiene.sh:949-953`):

```bash
  if [ -z "$SUPABASE_BIN" ]; then
    echo "      ~ skip stop $proj: supabase CLI not on PATH (preflight)"
    record_stack_observation "$proj" "$stack_ids" "held_precondition" "supabase_cli_missing" "not_attempted" "$owner"
    return 0
  fi
```

Exited-container and image reclaim still run on a miss.

**The CLI's stderr survives** (`docker-hygiene.sh:908-928`, `supabase_stop_captured`). Before the fix both stop paths ran `supabase stop ... >/dev/null 2>&1`. Now stderr goes to a capture file and its last three lines are folded into one bounded line (400 bytes, tail kept, so the CLI's final error line survives a long earlier progress line) in the `!! FAILED to stop <proj>` line and the JSON `action_error_details` entry; the fold keeps one entry per failure because that file is one detail per line. If the capture file cannot be written, the stop still runs, its stderr passes through to the unit's own journal, and the recorded detail says so.

**The daemon-unreachable exit carries the preflight's error** (`docker-hygiene.sh:369` onward): the summary line and the JSON report the observation count, the detail lines, the inspection sum and the flagged count from the run's ledger instead of a fixed zero, so the terminal record never contradicts the warning printed above it.

**The suite runs the unit's own environment under the real manager** (`tests/docker-hygiene.test.sh:1044-1127`). It parses every `Environment=` line of the unit file (one bare `KEY=VALUE` per line, `%h` the only specifier; a quoted value, a line carrying two assignments, or another specifier fails loudly), passes them as `--setenv=` to `systemd-run --user --pipe --wait --collect`, exec's the repo's copy of the script with `DOCKER_HOST` at a dead socket and `ONLY=` a project that cannot exist, and asserts the run reaches the daemon gate. A negative probe under the stock manager PATH must fail under STRICT, name the PATH it searched, and still reach the gate, proving reclaim is not withheld. Where no manager answers, `systemd-run` or `timeout` is missing, no CLI is on the suite's own PATH, or the stock PATH already resolves the CLI so the negative probe cannot discriminate, the section prints an explicit SKIP line that the summary counts. The unit's `ExecStart=` is asserted rather than executed because it names the installed copy under `%h`, which lags until sync.

**The exemption is lifted with its audit on record** (`tests/unit-path-coverage.test.sh:54-61`), so the guard now fails CI if the PATH line disappears.

**Proof, as this session measured it.** The same script under `systemd-run --user` with the unit's `Environment=` block plus the house PATH stopped 28 of 28 orphan stacks on 2026-10-04 (0 failed, 906 s, running containers 159 to 99). The extended suite ran 247 of 247 with the systemd probes live and 238 of 238 with them skipped; run against the pre-fix script and unit it failed 31 assertions, every one a #1555 case. PR #1562 went through three Pro review rounds (two P2 findings, items 5 and 6 above, each fixed with pinned tests) and was merged at its reviewed head. The closeout's `activation:` line was live (the canonical checkout advanced to the merge), and on top of that `systemctl --user show docker-hygiene.service -p Environment` on the host has listed the PATH since 2026-10-05 02:02 with `NeedDaemonReload=no`.

## Why This Works

PATH is per manager. A user unit inherits the user manager's environment, which `systemctl --user show-environment` prints, not the login shell's; on this host that was the stock system PATH. A shell's exports are not inherited by the manager by themselves; something has to write them into its environment (for example `environment.d` files, which the manager's generator reads at startup and on reload; or, at runtime, `systemctl --user set-environment` or `import-environment`, or `dbus-update-activation-environment --systemd`), so the host check beats any assumption that the two match. The house line puts `~/.local/bin` and the mise shims first, so user-installed and mise-managed binaries resolve the way they do interactively.

The preflight turns an implicit dependency into an explicit, fail-loud one at the only moment it is cheap to check, before the first docker call, and records it where the unit's failure alert will carry it. Refusing the dependent actions while letting the independent ones run keeps the unit's main lever working through a dependency regression. Keeping the CLI's stderr makes the next 127, or the next anything, self-diagnosing from the journal alone. The probe test runs the unit's real `Environment=` block under the real manager, so the test scope is the runtime scope: a unit that resolves its binary only on a developer's shell PATH fails CI instead of failing on Wednesday. Lifting the exemption makes the guard enforce what the probe proves.

## Prevention

- **A unit whose script calls anything outside `/usr/bin` declares a PATH, and the house line is the default.** On this host `docker`, `python3`, `ps`, `sed` and `awk` resolve under `/usr/bin`; `supabase`, `claude`, `codex`, `pnpm`, `node` and the mise-managed tools do not, and a mise-managed `python3` or `node` is a different build from the `/usr/bin` one. Start from the line at `systemd/docker-hygiene.service:58`; it puts `~/.local/bin` and the mise shims ahead of `/usr/bin`, so check what it shadows before copying it, and some units are deliberately narrower (`/usr/bin:/bin` on the failure-alert and wacli units) or wider (pnpm or bun added), so do not overwrite a PATH that differs on purpose. After PR #1562, 28 of the repo's 36 services declare a PATH, 17 of them this exact line; the 8 that declare none are the 7 in `PATH_EXEMPTIONS` (six still reading "outside this outage fix": backup-harness, two database-backup units, disk-watermark, supabase-migration-drift, wt-sweep; plus cass-index as an adopted live config) and `reclaim-sweep.service`, whose `ExecStart=` runs `/usr/bin/python3` by absolute path, which keeps it outside the guard's discovery rather than exempt. At least two of the exempted scripts (`scripts/supabase-migration-drift.sh` and a database-backup script) export their own PATH.
- **An entry in `PATH_EXEMPTIONS` is a deferral with an audit due, not a verdict.** Three units have now been lifted from it after the same not-found failure. Before adding or keeping one, run the unit's binary under the manager: `systemd-run --user --pipe --wait --collect --quiet /usr/bin/env <binary> --version`. The not-found verdict is `env`'s own diagnostic on stderr, which `--pipe` carries back: a line from `env` itself that names the binary and says `No such file or directory` (the prefix is the path `env` was invoked by, and the quotes follow the locale). With that line, the unit's environment cannot resolve the binary: lift the exemption unless the script exports its own PATH before first use (read the script, then say so in the reason). An exit 127 without it is inconclusive, because `env` passes on the status of a program it did start, and a wrapper whose own inner command is missing also exits 127. Probe a binary the script actually calls, and treat any other failure as inconclusive when the binary has no `--version`.
- **Preflight user-local binaries with `command -v` before the first action**, record a miss as an observation error under STRICT with the PATH searched and a remedy that names the knobs actually set, and refuse only the actions that depend on the binary. The idle stop path at `docker-hygiene.sh` shares the same guard as the orphan path, so there is one preflight and one refusal path, emitted per stack, not one per caller.
- **Do not discard a CLI's stderr on an action path.** Capture it and fold the last lines into the failure detail, bounded in bytes with the tail kept, and mind what the CLI may print there, because the fold lands in the report and the JSON. `>/dev/null 2>&1` on a stop, delete or restart is how 25 failures become one `Result=exit-code`.
- **Test the unit's `Environment=` block under the user manager**, not the script from a shell. The probe shape in `tests/docker-hygiene.test.sh:1044-1127` (parse the unit's lines, `systemd-run --user --setenv=...`, a dead `DOCKER_HOST` for isolation, a negative probe on the stock PATH, explicit counted SKIP lines) ports to any unit whose script has a cheap, side-effect-free early exit. The section SKIPs whenever `systemd-run --user /bin/true` fails (`:1084`), the CLI is off the suite's own PATH, or the stock PATH already resolves it; a headless session usually needs `XDG_RUNTIME_DIR`, and often the bus address, exported for the manager to answer (auto memory [claude], not asserted by the test).
- **Verify activation on the host, not the merge.** The installed unit changes only when sync activates the checkout. Report the `activation:` line `wt-done` prints, per the [post-merge activation doc](drive-post-merge-activation-instead-of-handing-back.md); that line proves the checkout advanced, not that install succeeded, so also read `systemctl --user show <unit> -p Environment` and `NeedDaemonReload=no`.
- **Read a unit's failures with a time window, not only `-u`.** A script that prints its failure lines in a burst at exit can lose unit attribution in journald; `journalctl --user --since ... --until ...` around the run finds what `-u <unit>` drops.

## Related Issues

- dotfiles #1555 (work-spec, open until the first post-fix scheduled run is read) and PR #1562 (the fix, merged 2026-10-05).
- PR #1191 switched `STOP_ORPHANS=1` on without the PATH; PR #544 created the PATH guard and its exemption registry, and PR #653 lifted harness-weekly's exemption during the 2026-08-29 outage; dotfiles #1444 is the remaining liveness gap (run-scoped stacks under `/tmp` held by directory existence), untouched by this fix.
- [network-online.target does not exist in the user manager](network-online-target-does-not-exist-in-the-user-manager-gate-readiness-in-the-script-instead.md): the sibling scope gap, a directive that verifies green outside the user manager and does nothing inside it.
- [A grepped implementation string in a test is an invisible caller](../best-practices/a-grepped-implementation-string-in-a-test-is-an-invisible-caller.md): names `unit-path-coverage.test.sh` as the guard that catches a PATH-less managed-path service.
- [Drive and verify post-merge activation](drive-post-merge-activation-instead-of-handing-back.md): the `activation:` receipt that proves the checkout advanced; the `show -p Environment` check on top of it is this doc's addition.
