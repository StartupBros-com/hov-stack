---
title: "network-online.target does not exist in the user manager; gate readiness in the script instead"
date: 2026-09-28
category: integration-issues
module: claude-systemd-network-online-target
problem_type: integration_issue
component: development_workflow
severity: high
symptoms:
  - "`systemctl --user show network-online.target -p LoadState -p ActiveState` prints `LoadState=not-found` and `ActiveState=inactive` on host workstation (2026-09-28), so `After=`/`Wants=network-online.target` in a `--user` unit orders nothing"
  - "A `Persistent=true` timer catch-up at login or boot starts the service before the network is up, the exact race the two directives were written to prevent, and its first network calls fail"
  - "`systemd-analyze verify` stays green in CI because this unit's suite, like its sibling unit suites, verifies in system mode, where the target resolves"
  - "pro-gate round 1 on PR #1455 flagged the dead pair on systemd/claim-reap.service; a grep then found it in twelve more units under systemd/ (dotfiles #1458)"
root_cause: config_error
resolution_type: code_fix
related_components:
  - "claim-reap.service"
  - "claim-reap.timer"
  - "claim-reap.sh"
  - "claim-reap.test.sh"
  - "claim-reap-timer.test.sh"
tags: ["systemd", "network-online-target", "user-manager", "readiness-probe", "systemd-timer", "ci-blind-spot", "dead-directive", "timeout"]
---

# network-online.target does not exist in the user manager; gate readiness in the script instead

> **Retired machinery (2026-10-18).** The claim reaper this lesson was learned on (`claim-reap.sh`, `claim-reap.service`/`.timer` and their test suites) was deleted with issue claims in #1902 (teardown move 7b). Every `claim-reap` path and the `wait_for_github` listing below no longer resolve and are history. The lesson still holds for every `--user` unit: `net-ready.sh` and `tests/systemd-network-online.test.sh` are live.

## Problem

A `--user` systemd unit ordered its start on `network-online.target` with `After=` and `Wants=`, but that target belongs to the system manager and does not exist in the user manager, so the ordering was a silent no-op: a `Persistent=true` catch-up run could start the unit before the network was up, the exact race the two directives were written to prevent.

## Symptoms

- `systemd-analyze verify` on the unit passes green in CI.
- A `Persistent=true` timer catch-up at login or boot runs the service before connectivity is up, and the service's first network calls fail (for the reaper, that meant a WARN per repo and nothing ruled).
- Asking the user manager for the target shows it is not there. On host workstation, 2026-09-28, `systemctl --user show network-online.target -p LoadState -p ActiveState` printed `LoadState=not-found` and `ActiveState=inactive`. That single-host measurement is the primary evidence for the platform claim here; no systemd documentation is cited.
- The same dead `After=network-online.target` / `Wants=network-online.target` pair sits in sibling units once you look. Twelve units under `systemd/` carry it: cass-release-promote, codex-auto-update, dcg-auto-update, mcp-servers-update, memory-mine-batch, pi-auto-update, skills-update, tools-auto-update and four other units (for example `systemd/tools-auto-update.service:12-13`). Filed as dotfiles #1458 and closed by the repo-wide test and the shared `ExecStartPre=-` probe described under Prevention.

## What Didn't Work

1. **Shipping the unit with the copied ordering pair.** `systemd/claim-reap.service` first carried `After=network-online.target` and `Wants=network-online.target`, copied from the sibling units, and the unit suite's `systemd-analyze verify` passed. It passed because `tests/claim-reap-timer.test.sh` runs `verify` in system mode on purpose, the pattern its sibling unit suites settled on after `--user` verify failed on PR #1100's CI run, and in system mode `network-online.target` is real. Not every suite does this: `tests/cass-index-unit.test.sh` owns an `XDG_RUNTIME_DIR` and verifies in `--user` mode (its header attributes the `--user` failure on CI to that missing directory), and whether a `--user` verify would have flagged the missing target was not measured. As this unit's suite runs it, the check validates the directive's syntax and the graph in a scope the unit never runs in. pro-gate round 1 on PR #1455 flagged it.
2. **An unbounded readiness probe.** The first replacement moved readiness into the script but bounded only the overall wait. `gh` has no request timeout, so a probe issued while the network was half up could stall past the wait's own deadline and into the unit's `TimeoutStartSec=20m` without ever reaching the WARN-and-exit path. pro-gate round 2 on PR #1455 caught this; the fix bounds each attempt, rechecks the deadline before accepting a late success, and caps the sleep to the time left.
3. **Giving each attempt all the time left, timed on the wall clock.** pro-gate round 1 on PR #1465 reproduced two gaps in that fix as carried into the shared `net-ready.sh`. A `date` shim stepping back 5s let a 2s wait accept a success at 3.05s, because the time left grew with the clock. A server that stalled its first connection while answering later ones held a `--wait 4 --interval 1` probe on that one attempt until the deadline, because the attempt was given the whole wait. `net-ready.sh` now reads its deadline from `/proc/uptime` and caps each attempt with `--attempt-timeout` (default 20s). `claim-reap.sh`'s `wait_for_github` had both gaps too; dotfiles#1469 gave it the same two bounds, shown below.

## Solution

Drop the ordering directives from the unit and move readiness into the script, bounded on both the overall wait and each attempt.

Before, the dead ordering the twelve #1458 units carried until #1465 removed it (`systemd/tools-auto-update.service:12-13` at `401acab0^`):

```
After=network-online.target
Wants=network-online.target
```

After, `systemd/claim-reap.service:1-8` (deleted with the reaper in dotfiles #1902) had no ordering line and said why:

```
[Unit]
Description=Stale gh-claim reap (claim-reap.sh DRY_RUN=0: releases claims by content, fleet-wide)
Documentation=https://github.com/StartupBros-com/hov-stack/blob/main/harness/gh-tracking-and-claims.md
# Every effect is a gh call and a Persistent catch-up can fire before the
# network is up. There is no network-online.target to order after in the
# user manager (LoadState=not-found on workstation, 2026-09-28; it belongs to the
# system manager), so readiness is the script's job: see
# CLAIM_REAP_READY_WAIT below (pro-gate on dotfiles#1455).
```

The `[Service]` block sets the knob only the unit uses (`systemd/claim-reap.service:40`):

```
Environment=CLAIM_REAP_READY_WAIT=600
```

The readiness function, `wait_for_github` in `scripts/claim-reap.sh`, as dotfiles#1469 left it:

```
CLAIM_REAP_READY_WAIT="${CLAIM_REAP_READY_WAIT:-0}"
CLAIM_REAP_READY_INTERVAL="${CLAIM_REAP_READY_INTERVAL:-15}"
CLAIM_REAP_READY_ATTEMPT="${CLAIM_REAP_READY_ATTEMPT:-20}"
# The uptime clock's path. Only the suite sets it, to reach the unreadable and
# malformed clock paths; production reads /proc/uptime.
CLAIM_REAP_CLOCK="${CLAIM_REAP_CLOCK:-/proc/uptime}"
# Two more bounds came from pro-gate on dotfiles#1465, which found both gaps
# in the shared net-ready.sh probe this function's first shape was copied into
# (dotfiles#1469). The deadline runs on /proc/uptime, which never steps
# backward: timed with `date +%s`, a backward wall-clock step (an NTP or WSL
# resync) grew the time left past the wait. Each attempt gets
# CLAIM_REAP_READY_ATTEMPT seconds (default 20) or the time left, whichever is
# shorter: given the whole wait, one stalled connection blocked the retry that
# a fresh connection would have answered.
#
# uptime_cs: centiseconds since boot into NOW_CS. /proc/uptime carries two
# decimals, and keeping them holds a short wait's deadline to the hundredth
# instead of rounding it by up to a second.
uptime_cs() {
  local up rest whole frac
  read -r up rest 2>/dev/null < "$CLAIM_REAP_CLOCK" || return 1
  whole=${up%%.*}
  frac=${up#"$whole"}
  frac=${frac#.}00
  frac=${frac:0:2}
  # Each field on its own: a reading with no whole part (".5", or a blank
  # line) would pass a check of the two joined, then fail 10# on the empty
  # operand, and that error skips the caller's `if` instead of failing it.
  case $whole in
    ''|*[!0-9]*) return 1 ;;
  esac
  case $frac in
    ''|*[!0-9]*) return 1 ;;
  esac
  NOW_CS=$(( 10#$whole * 100 + 10#$frac ))
}
# cs_secs <centiseconds>: seconds with two decimals, for timeout and sleep.
cs_secs() { printf '%d.%02d' $(( $1 / 100 )) $(( $1 % 100 )); }
wait_for_github() {
  local wait_cs attempt_cs deadline left budget interval
  # Digits only, then base 10: bash arithmetic reads a leading 0 as octal. The
  # old wait hit an arithmetic error on 08 and the run read GitHub unprobed,
  # and 010 would have meant eight (pro-gate on #1465 found it in the probe).
  case $CLAIM_REAP_READY_WAIT in
    ''|*[!0-9]*) return 0 ;;
  esac
  wait_cs=$(( 10#$CLAIM_REAP_READY_WAIT * 100 ))
  [ "$wait_cs" -gt 0 ] || return 0
  case $CLAIM_REAP_READY_ATTEMPT in
    ''|*[!0-9]*) attempt_cs=2000 ;;
    *) attempt_cs=$(( 10#$CLAIM_REAP_READY_ATTEMPT * 100 )) ;;
  esac
  [ "$attempt_cs" -gt 0 ] || attempt_cs=2000
  # The retry interval is a positive number of seconds, fractions allowed (the
  # suite uses 0.2). Anything else falls back to 15: a 0 or negative interval
  # made the loop spin, about 180 probes in a one-second wait.
  interval=$CLAIM_REAP_READY_INTERVAL
  case $interval in
    ''|.|*[!0-9.]*|*.*.*) interval=15 ;;
  esac
  awk -v i="$interval" 'BEGIN { exit !(i + 0 > 0) }' || interval=15
  if ! uptime_cs; then
    # No clock to time a deadline on. Read without a probe: every read still
    # fails closed, so an unreachable GitHub still skips with WARNs.
    warn "readiness wait skipped: $CLAIM_REAP_CLOCK unreadable, so GitHub is read without a probe"
    return 0
  fi
  deadline=$(( NOW_CS + wait_cs ))
  # From here, return 1 means only that the deadline passed without an answer,
  # the one case the caller reports as GitHub unreachable. A clock that stops
  # reading mid-wait ends the loop to its own WARN and reads GitHub, as one
  # that never read does above (ce-code-review on #1472).
  while uptime_cs; do
    left=$(( deadline - NOW_CS ))
    [ "$left" -gt 0 ] || return 1
    budget=$attempt_cs
    if [ "$left" -lt "$budget" ]; then
      budget=$left
    fi
    # gh has no request timeout, so each attempt is bounded: TERM at the
    # budget, KILL two seconds later. The budget is never 0 here (left and
    # attempt_cs are both positive), which matters because timeout reads a 0
    # duration as no limit at all. A success that lands on the deadline is not
    # accepted (pro-gate on #1455).
    if timeout -k 2 "$(cs_secs "$budget")" gh api rate_limit >/dev/null 2>&1; then
      uptime_cs || break
      [ "$NOW_CS" -lt "$deadline" ] && return 0
      return 1
    fi
    uptime_cs || break
    left=$(( deadline - NOW_CS ))
    [ "$left" -gt 0 ] || return 1
    # Sleep the interval or what remains, whichever is shorter.
    sleep "$(awk -v a="$interval" -v b="$(cs_secs "$left")" 'BEGIN { print (a < b) ? a : b }')"
  done
  warn "readiness wait cut short: $CLAIM_REAP_CLOCK stopped reading, so GitHub is read without a probe"
  return 0
}
```

and its call site in the same file:

```
if ! wait_for_github; then
  # Abandon, out loud, with the counters line the report's extraction expects;
  # exit 0 is the unit's contract (WARNs exit clean, only a crash alerts).
  warn "GitHub unreachable for ${CLAIM_REAP_READY_WAIT}s (gh api rate_limit never succeeded); run abandoned, nothing ruled"
  echo "claim-reap: claimed:0 stale-claims:0 active-pr-kept:0 claim-reap-flagged:0"
  exit 0
fi
```

`CLAIM_REAP_READY_WAIT` defaulted to `0`, no probe, so interactive runs and the weekly `DRY_RUN=1` plan were untouched; only the timer-driven unit set `600`. Each `gh api rate_limit` probe runs under `timeout -k 2` for `CLAIM_REAP_READY_ATTEMPT` seconds (default 20) or the time left, whichever is shorter, because `gh` has no request timeout of its own. The deadline and the time left come from `/proc/uptime` in hundredths of a second, so a backward wall-clock step cannot stretch the wait. The remaining time is recomputed before each attempt and checked again before a success that lands on the boundary is accepted, and the sleep between attempts is capped to what remains. The wait is read as decimal digits, so `08` means eight seconds rather than an octal error. A clock that cannot be read, before the wait or during it, gets its own `WARN` and the run reads GitHub without a probe, so a clock failure is never reported as GitHub's. On the deadline the script prints a column-0 `WARN`, the zero-valued counters line, and exits `0`. That is the unit's contract: a WARN is a clean exit that reaches the Monday report's toast, and only a crash fires `OnFailure=harness-unit-failure-alert@%n.service`. The script and its unit were retired in dotfiles #1902; the readiness pattern is what carries forward.

## Why This Works

`network-online.target` is a system-manager concept. A `--user` unit lives in a separate manager instance that never defines it, so ordering on it waits for nothing, while the directive looks correct in the file and passes `systemd-analyze verify` as this unit's suite runs it, in system mode, where the target is real. Nothing in that path asks whether the target exists in the scope the unit will run in, so the gap is invisible to CI by construction.

Readiness in the script runs in the scope that matters: a live check of the network the unit is about to use, not a systemd concept the user manager lacks. Bounding both the total wait and each attempt closes the second failure: without a per-attempt timeout, one hung `gh` call could consume the whole wait and then the unit's start timeout without ever reaching the abandonment path that makes the failure visible.

## Prevention

- Pin the unit with a fixed-string, whole-line grep so a comment that merely mentions the target cannot false-positive. `tests/claim-reap-timer.test.sh` section 3 (lines 129-131; deleted with the reaper in dotfiles #1902, so the repo-wide `systemd-network-online.test.sh` below now carries the rule):

  ```
  { grep -qxF 'After=network-online.target' "$SVC" || grep -qxF 'Wants=network-online.target' "$SVC"; } \
    && bad "3: service orders on network-online.target, which the user manager does not have (LoadState=not-found): the ordering is a no-op" \
    || ok "3: no network-online.target ordering (user scope has none; readiness is the script's wait)"
  ```

  The suite's planted negative (`CLAIM_REAP_TIMER_INVERT=1`) is how that assertion proves it can go red; see the falsifiable-assertion learning linked below before copying the shape.
- dotfiles #1458 shipped the repo-wide form: `tests/systemd-network-online.test.sh` fails when any unit under `systemd/` or `systemd/user/` carries either directive line, and each of the thirteen units that carried it either waits through the shared probe, `ExecStartPre=-%h/.claude/scripts/net-ready.sh --wait 300 --url <the host its script asks first>`, or carries a `# No network-readiness probe:` comment saying why none is needed (a reconnecting daemon and an SSH tunnel under `Restart=always`). The leading `-` is the contract: on the deadline the probe warns, its exit is ignored, and the script runs and fails or skips exactly as it did before, so the probe moves the start and never the outcome. The suite also pins each wait to at most half the unit's `TimeoutStartSec`, which `ExecStartPre=` time counts against. Because it counts, each probe unit's `TimeoutStartSec` rose by the 300s wait wherever the script's own bound did not already clear the remainder (dcg-auto-update, tools-auto-update, cass-release-promote, memory-mine-batch, three other units, mcp-servers-update, skills-update), so a fully spent wait never shortens the budget the script had; the review round that found this saw two runners whose own timeout equalled the unit's budget, which a spent wait would have let the manager kill before the runner could report.
- Rule for authoring or reviewing any `--user` unit: never order on `network-online.target`. If the unit's first action needs the network, wire the shared probe as `ExecStartPre=-` against the host the script uses, or put the wait in the script itself (the `wait_for_github` shape above) when the unit's contract is a WARN-and-abandon rather than a run; either way measure the deadline on a clock that never steps backward (`/proc/uptime`, not `date +%s`), cap each attempt with `timeout` well below the wait so one stalled connection cannot spend it all, recheck the deadline before accepting a success, and cap retry sleeps to the time remaining. When the wait is an `ExecStartPre=`, add it to the unit's `TimeoutStartSec` rather than carving it out of the script's budget.
- To check whether a unit's ordering on any target is real, ask the manager the unit runs in: `systemctl --user show <target> -p LoadState -p ActiveState`. `LoadState=not-found` means the ordering is a no-op whatever system-mode `systemd-analyze verify` says.

## Related Issues

- dotfiles #1458: the twelve remaining units and the repo-wide test; shipped (PR #1465) as the shared `net-ready.sh` probe wired `ExecStartPre=-` in eleven units, a stated reason in a reconnecting daemon and in an SSH-tunnel unit under `systemd/user/` (the tunnel is a thirteenth carrier outside the issue's list, caught when the round-1 lens found the rule sentence promising wider coverage than the test had), and `tests/systemd-network-online.test.sh`.
- dotfiles PR #1455 (merged 2026-09-28, closes #1449): the unit, the probe, and the two pro-gate rounds that found the dead ordering and the unbounded probe; a third round shipped clean before merge.
- `docs/solutions/best-practices/a-grepped-implementation-string-in-a-test-is-an-invisible-caller.md`: the section 3 assertion above is another exact-literal anchor in a test; give the anchor its own assertion if the directive lines are ever reworded.
- `docs/solutions/best-practices/make-test-assertions-falsifiable-by-the-defect-they-guard.md`: plant the negative before trusting the green.
- `docs/solutions/best-practices/enable-consent-gated-daemons-with-two-keys-not-one.md`: the same shape one step over, a status surface that reads healthy while an unchecked second condition makes the unit inert.
- `docs/solutions/best-practices/measure-anon-vs-cache-before-bounding-a-units-memory-then-judge-the-bound-by-stall-not-peak.md`: sibling `systemd/` learning; a signal that looks the same under two causes needs a purpose-built check.
- `docs/solutions/logic-errors/a-run-ledgers-mtime-is-not-a-liveness-signal-for-an-idle-dispatcher.md`: how to read a `--user` timer's own last trigger when diagnosing whether it fired at all.
