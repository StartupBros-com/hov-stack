---
title: Diff installed and patched sweep plans on the real host before shipping a session-hold change
date: 2026-11-19
category: best-practices
module: wt-sweep-session-hold
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A change to scripts/lib/wt_session_hold.py, scripts/lib/wt-preserve.sh or scripts/wt-sweep.sh can move a worktree's keep or remove verdict"
  - The session-hold index cache changes its format, file name or version
  - Fixture suites pass but the change's effect depends on state they never build, such as an index accumulated over weeks
tags: [wt-sweep, wt-session-hold, dry-run, plan-diff, cache-version, idle-release, countermetric]
---

# Diff installed and patched sweep plans on the real host before shipping a session-hold change

## Context

hov-stack#793 needed a per-transcript binding in the session-hold index, the cache of the paths each Claude Code transcript drives. The first version of PR #796 bumped `CACHE_VERSION` from 2 to 3 so every entry would be rebuilt with the new field. Every fixture suite passed. A dry-run plan diff on the real host showed something they could not: 44 worktrees moved from `idle:` (released by the `--idle-hours` rule, hov-stack#644) to held, 214 Claude-session skips against 170. The installed scripts and the branch's scripts were run back to back on the same host state.

The cause is a mechanism no fixture exercises:

- `_when()` gives a record without a parseable `timestamp` its `fallback` time (`scripts/lib/wt_session_hold.py:308`).
- `driven_paths()` passes the transcript's mtime at scan time as that fallback (`scripts/lib/wt_session_hold.py:534`).
- The incremental index dates each record once, close to when it was written.
- The version is part of the cache file name (`scripts/lib/wt_session_hold.py:456`), so a bump starts from an empty index and re-reads every transcript in full.
- That re-read dates every old undated record by the transcript's current mtime. For a transcript still being written, that is about now, so every worktree it ever named looks freshly named.

Idle release then stops until the window passes again, about a day. At the sweep's 6-hourly live cadence that is about four sweeps (session history).

An A/B with the installed helper alone confirmed it. On one affected worktree, the helper with the live incremental cache exited 3, `idle: … last named 92h ago`. Against an empty `--cache-dir`, the same helper on the same state exited 0, held. The re-dating itself is open as hov-stack#795. Fixtures build their cache from nothing on every run, so they never hold the accumulated index the defect needs.

## Guidance

1. **Diff the plans before shipping.** Run `DRY_RUN=1` with the installed `~/.claude/scripts/wt-sweep.sh` and with the branch's `scripts/wt-sweep.sh`, back to back.
   - Compare the verdict each worktree gets: its `  ~ skip (<reason>): <name>` line or its `  • <name> …` action line, plus the summary counts.
   - Account for every changed verdict as intended, as timing, or as a regression. Timing means a job's turn ended between the runs, or a worktree crossed the 120-minute `ACTIVE_MIN` line.
2. **Give the branch's run a copy of the live cache** through `WT_HOLD_CACHE_DIR`, which the helper reads as its `--cache-dir` default.
   - Never use an empty directory: that forces the rebuild this doc describes.
   - Never use the live directory: the installed timer reads it at its next run (step 5).
3. **Tell a rebuild from a logic change with an A/B on the installed helper.** Run it on one changed worktree with the live cache, then with an empty `--cache-dir`. If the empty-cache run moves the verdict as well, the cause is the rebuild, not the branch's logic.
4. **Extend the index; don't bump its version while #795 is open.**
   - Add an optional key and treat its absence as unknown.
   - Fill it from the bytes already indexed without touching any recorded time.
   - #796 did this with `bind`. Case 12b in `tests/wt-session-hold-resumable.test.sh` pins that an older entry learns its binding with its path times unchanged. The comment above `CACHE_VERSION` (`scripts/lib/wt_session_hold.py:147`) records why the version stayed at 2.
5. **When the branch writes something new into the cache under the same version, run the installed helper on a cache the branch wrote.** The old helper reads that file until the merge activates, and again after any revert. In #796 both dry runs used the live cache. Afterwards the installed helper still called a known idle worktree idle (exit 3) on the cache the branch had added `bind` keys to.

## Why This Matters

wt-sweep runs live every 6 hours and deletes worktrees. A hold regression either removes work under an agent (too few holds) or pins disk the sweep should have freed (too many). The v3 bump was the second kind, on a host whose root disk was 99% full that day.

The fixture suites cannot see a defect that only exists in an index accumulated over weeks. A green suite plus a one-line version bump read as safe. The plan diff was the only test that ran against the real index, and each of its two runs took about two minutes.

## When to Apply

- Any change to how `scripts/lib/wt_session_hold.py` decides a hold, a release or an idle verdict.
- Any change to the index cache: its key, its file name, its version or the fields an entry carries.
- Any change to `scripts/wt-sweep.sh` or `scripts/lib/wt-preserve.sh` that can change which worktrees are skipped, released or removed.

## Examples

The plan diff, with the branch's run on a copy of the live cache:

```bash
D=/tmp/plan-diff; mkdir -p "$D"
cp -a ~/.cache/hov-stack-wt-session-hold "$D/cache"
DRY_RUN=1 ~/.claude/scripts/wt-sweep.sh >"$D/installed.txt" 2>&1
DRY_RUN=1 WT_HOLD_CACHE_DIR="$D/cache" bash <worktree>/scripts/wt-sweep.sh >"$D/patched.txt" 2>&1
tail -n 2 "$D/installed.txt" "$D/patched.txt"   # summary counts: removed, released-idle, …
```

The A/B that separates a rebuild from a logic change:

```bash
H=~/SITES/hov-stack/scripts/lib/wt_session_hold.py
python3 "$H" --idle-hours 24 -- <changed-worktree>                            # live, incremental cache
python3 "$H" --idle-hours 24 --cache-dir "$(mktemp -d)" -- <changed-worktree> # forced full re-read
```

For #796's final version the diff showed 15 changed verdicts, each one accounted for:

- 13 were held in both plans under a different holder: one background job was working during the installed run (19:29:28Z) and ended its turn at 19:32:13Z, inside the patched run, so the patched plan named the live session that held them instead.
- 1 crossed the 120-minute recency line between the runs and became a removal (the extra `removed` and `preserved-local` in the summary).
- 1 moved from a live-session hold to a done-job hold.

## Related

- `harness/worktree-fleet-hygiene.md`: the idle-release (hov-stack#644) and resumable-hold (hov-stack#793) paragraphs.
- hov-stack#795: the re-dating defect. Once it is fixed, a version bump stops pausing idle release, and guidance step 4 can go.
- `docs/solutions/logic-errors/a-run-ledgers-mtime-is-not-a-liveness-signal-for-an-idle-dispatcher.md`: another case of a file mtime standing in for a time it does not measure.
