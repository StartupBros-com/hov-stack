---
title: "du overstates what deleting a hard-linked tree frees: size by single-link bytes, claim only the free-space delta"
date: 2026-11-18
category: best-practices
module: disk-reclaim
problem_type: best_practice
component: infrastructure
severity: medium
applies_when:
  - "Ranking folders to delete on a nearly full disk from du output, including the du hint the disk-watermark alert prints"
  - "Estimating what deleting a package-manager cache (uv, a pnpm store), a pnpm-installed node_modules tree or agent scratch will free"
  - "Reading or writing a script line that prints a size before and after a prune or delete"
  - "Explaining why free space rose less than a delete or a cache-clean command reported"
related_components:
  - reclaim-sweep
  - pkg-cache-prune
  - disk-watermark
tags: [du, hard-links, disk-reclaim, single-link-bytes, statvfs, df, uv-cache, pnpm-store, disk-full]
---

# du overstates what deleting a hard-linked tree frees: size by single-link bytes, claim only the free-space delta

## Context

During the 2026-11-14 to 11-18 root-disk audit on the WSL host, hand-run `du` sizing overstated three reclaim candidates. Each folder was large by `du` and held much less of its own:

- An ideation run's `/tmp` folder read 26 GiB by `du`. It was mostly hard links to live session transcripts, and its single-link files came to 0.8 GiB.
- Another job's `/tmp` scratch folders read 17.0 GiB by `du`, of which 11.1 GiB was single-link.
- The uv cache read 26G by `du -sh`. 12.86 GiB of it was single-link. Of the 12.41 GiB in multi-link files, 1.27 GiB was linked only from inside the cache. Deleting the whole cache would free about 14.1 GiB, and the weekly prune, which removes only part of it, frees an unmeasured amount less.

Earlier sessions saw the same gap from the other side (session history). A `uv cache clean` on a Windows drive reported 35.0 GiB removed while the drive's free space rose 1.98 GiB. That session put the gap down to cache files still linked from Python environments, without confirming it. Deleting a pnpm-installed `node_modules` tree listed at 4.41 GiB raised free space by 3.17 GiB, with other writers active during the 21-minute delete.

The automated sweep already handles this. `scripts/reclaim-sweep.py` counts single-link bytes as `unshared`, documented as "a floor on what removal frees" (`TreeScan`, line 745; summed at line 879). It prints them next to the apparent size (lines 1887 and 1894-1897) and claims freed bytes only from the statvfs change across the run (lines 1854-1857). The gap was the hand-run audit. The disk-watermark alert's own hint starts it with `du -x --max-depth=2 ~ | sort -h | tail` (`scripts/disk-watermark.sh:216`), and until 2026-11-18 nothing at that point said what `du` cannot see. The hint now prints recipe 1 below right after that line (`scripts/disk-watermark.sh:220-221`).

## Guidance

**What `du` counts.** `du` adds the blocks of every inode its walk reaches, whether or not another hard link to that inode lives outside the walk. Within one run it counts each inode once and charges it to whichever argument or directory reaches it first, so changing the argument order moves bytes between folders. `du` never reports how many links an inode has or where they are.

**1. Size a candidate by its single-link bytes.** No other path shares these bytes, so deleting the tree frees them, unless a process still holds a file open (see 4):

```bash
find DIR -xdev -type f -links 1 -printf '%b\n' |
  awk '{s+=$1} END {printf "%.2f GiB\n", s*512/2^30}'
```

`%b` counts allocated 512-byte blocks, so a sparse file counts what it occupies, not its length.

**2. For a whole-tree delete, add the inodes whose every link is inside the tree.** A file with two hard links inside the tree goes with it; a file also linked from outside stays. Comparing the links seen for each inode with its link count gives the exact figure:

```bash
find DIR -xdev -type f -printf '%i %n %b\n' |
  awk '{c[$1]++; n[$1]=$2; b[$1]=$3}
       END {for (i in c) if (c[i] >= n[i]) s += b[i]; printf "%.2f GiB\n", s*512/2^30}'
```

`-xdev` matters here too: inode numbers are unique only within one filesystem.

**3. A prune is not a whole-tree delete.** `uv cache prune`, `pnpm store prune` and similar commands remove part of a tree, and the part they remove may be mostly multi-link files. Neither recipe predicts their yield. Measure it (step 4) or say it is unmeasured.

**4. Claim freed bytes only from the filesystem's free space, before and after.** Read `df -B1 --output=avail <mount>` (or `os.statvfs`) around the delete, on the filesystem that held the tree. Other writers move that number in both directions, so report it as "free space rose X while Y ran", not "freed X". A deleted file that some process still has open keeps its blocks until that process closes it; `lsof +L1` lists those files.

**5. Read a tool's "removed N" message, or a before-and-after `du`, as tree size, not disk freed.** `scripts/pkg-cache-prune.sh` prints `current:` and `after:` lines from `du -shH` (`size_of`, line 162). The script claims no freed figure, and its lines are accurate as cache sizes. Subtracting them still overstates what the disk got back, by every file a venv or `node_modules` tree still links.

## Why This Matters

On a nearly full disk, the size ranking decides what an agent investigates and what it asks the operator to approve deleting. One `du` ranking listed a folder at 26 GiB that held 0.8 GiB of its own. A size written into an issue during the same audit called the single-link floor an upper bound (since corrected). A yield read from `du` or from a tool's own message tells the operator the problem shrank by more than it did, so the next alert comes sooner than they expect.

## When to Apply

- Any hand-run disk audit, especially one started from the disk-watermark alert's `du` hint.
- Before putting a size in an issue, a report or a deletion request.
- Reading output from `pkg-cache-prune`, a package manager's clean or prune command, or any script that prints sizes around a delete.
- It can be skipped for a tree with no hard links, such as a source checkout without a pnpm or uv install in it. `find DIR -xdev -type f -links +1 -print -quit` prints nothing for such a tree.

## Examples

A three-file tree built and measured on ext4. A has a 4 MiB file with one link, an 8 MiB file whose second link is in the sibling folder B, and a 2 MiB file with both of its links inside A.

| Measure | Result |
|---|---|
| `du -s -BM A` on its own | 15M |
| `du -s -BM A B`, then `du -s -BM B A` | A 15M, B 1M; then B 9M, A 7M |
| Single-link bytes of A (recipe 1) | 4.00 MiB |
| Whole-tree figure for A (recipe 2) | 6.00 MiB |

Deleting A frees 6 MiB, because the 8 MiB file survives through B. `du` puts A at 15M or 7M depending on argument order.

## Related

- `scripts/reclaim-sweep.py`: the automated sweep, which already sizes by single-link bytes and claims freed bytes from statvfs.
- `scripts/pkg-cache-prune.sh`: the weekly cache prune; its `current:` and `after:` lines are `du` sizes.
- `scripts/disk-watermark.sh:215-221`: the alert hint that starts hand-run audits with `du`, then prints recipe 1 for sizing a candidate. `tests/disk-watermark.test.sh` runs the printed recipe on a hard-linked tree.
- #697: the open item to measure what the weekly uv prune actually reclaims. Its 2026-11-18 comment records why the prune reports BUSY: long-running `uv run` processes hold a shared lock on uv's cache.
- #644: the issue that added the hourly disk-watermark alert.
- `docs/solutions/best-practices/measure-anon-vs-cache-before-bounding-a-units-memory-then-judge-the-bound-by-stall-not-peak.md`: the same move for memory, finding out which bytes are which before acting on a total.
