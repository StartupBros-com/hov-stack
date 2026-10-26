---
title: "A host-only drop-in pinned to a pre-merge release copy outlives the merge and hides later features"
date: 2026-10-02
category: integration-issues
module: claude-systemd-host-drop-ins
problem_type: integration_issue
component: development_workflow
severity: medium
symptoms:
  - "`systemctl --user show viberank-submit.service -p ExecStart -p DropInPaths` showed an ExecStart under `~/.local/share/codex-cloud-usage/releases/<sha>/`, set by a drop-in that no tracked file creates"
  - "Both copies of `viberank-submit` ran cleanly. Without `--submit`, for `--since 2026-10-02`, the pinned copy reported 3,222,149,064 tokens and the live copy 3,504,073,694"
  - "Per-account cloud ledgers reached tokscale and the shared leaderboard runner, but viberank's next scheduled run would have sent the primary ledger only"
  - "`~/.local/bin/viberank-submit` and the tracked unit file both pointed at the canonical checkout, so reading either one showed live code"
root_cause: missing_workflow_step
resolution_type: config_change
related_components:
  - "viberank-submit"
  - "tokscale-submit"
  - "with-cloud-usage"
  - "wt-done.sh"
  - "dotup-refresh.service"
tags: ["systemd", "drop-in", "pre-merge-activation", "release-copy", "host-drift", "activation-receipt", "with-cloud-usage", "viberank"]
---

# A host-only drop-in pinned to a pre-merge release copy outlives the merge and hides later features

> **Timer retired (2026-10-18 note).** `viberank-submit.timer` was retired by dotfiles #1893 on 2026-10-17, so `viberank-submit.service` no longer runs on a schedule. The unit file and `bin/viberank-submit` stay tracked, a host drop-in can still pin either submitter, and the procedure below still finds and removes such a pin.

## Problem

A scheduled unit was pinned to a copy of reviewed, unmerged code so that the code could run before its merge. Nothing removed the pin after the merge. A later feature, exporting every account's Codex cloud ledger, reached every reader except the pinned one, and nothing failed or warned.

## Symptoms

- On 2026-10-02, a check of whether the second account's usage had reached viberank exposed the gap. viberank had last run on 09-27 and 09-30, before any account ledger existed. Its next weekly run would have sent the primary ledger only, even though `codex-cloud-usage@alt` had been recording since 14:28 EDT that day.
- Everything visible from the repo looked current:
  - `~/.local/bin/viberank-submit` links to the canonical checkout, and `sync.sh:2439` creates that link.
  - The tracked unit `systemd/viberank-submit.service` runs that link.
  - The pin lived only in `~/.config/systemd/user/viberank-submit.service.d/40-codex-cloud-usage.conf`.
- The pinned copy logged success. With and without `--submit` it exited 0, and its only output difference was a smaller total for the same window.

## What Didn't Work

1. **Trusting the Activation receipt.** `wt-done` prints `activation: live` once the canonical checkout includes the merge commit (`scripts/wt-done.sh:571`; CONCEPTS.md, "Activation receipt"). That receipt checks the checkout, not what each unit executes. The receipt for PR #1501 would have read `live` whether or not the pin existed.
2. **Reading the script or its link.** Both show the checkout. Only the unit's effective command, `systemctl --user show <unit> -p ExecStart -p DropInPaths`, exposes the drop-in.
3. **Repointing the drop-in to the live path.** That fixed the next run, but it left a drop-in whose effective `ExecStart` matched the base unit's. The drop-in spelled the home directory with systemd's `%h` specifier and the base unit spelled it out, so the two lines matched only after expansion. An override that restates its base is a no-op, and it hides whatever the next session pins there. Removing the drop-in is the fix.
4. **Assuming the release copies had no other users.** The first cleanup plan would have deleted all four release directories. A reference sweep found two untracked links into one release: `~/.local/bin/fx-usage-bridge` and `~/.local/bin/viberank-captured-submit`. They had to be repointed before that directory could move.
5. **Suspecting a double count in tokscale.** The tokscale drop-in added an outer `with-cloud-usage tokscale` around `tokscale-submit`, which wraps its own scan and submit (`bin/tokscale-submit:178`, `:195`). It did not double-count: `append_root` in `bin/with-cloud-usage` skips an entry already in the list "when launchers nest". The outer wrapper only re-ran the export.

## Solution

How the pin came about, per the activation record and this session's investigation:
- The operator approved activating PR #1490 after review and before merge. At 13:29 EDT on 2026-09-30, 25 minutes before #1490 merged (17:54Z), the activating session made a full release tree of the reviewed branch commit under `~/.local/share/codex-cloud-usage/releases/<sha>/` and recorded per-file hashes in `deployments/<sha>/release.json`.
- It pointed viberank's scheduled entrypoint at that copy through a host-only drop-in, and it recorded `canonical_managed_link_preserved: true`: the sync-managed `~/.local/bin/viberank-submit` link was deliberately left on the checkout.
- `viberank-submit` resolves its siblings through its own real path (`bin/viberank-submit:55`, `readlink -f`). So the pinned copy also ran the release's `with-cloud-usage` (`:165`), which exported the primary ledger only.
- PR #1501 later switched the live wrapper to `codex-cloud-usage export-roots` (`bin/with-cloud-usage:166`). The pinned copy never received that change.

To find and confirm a pin:

```bash
systemctl --user show viberank-submit.service tokscale-submit.service -p Id -p ExecStart -p DropInPaths
grep -rnF 'codex-cloud-usage/releases' ~/.config/systemd/user
find ~/.local/bin -maxdepth 1 -lname '*codex-cloud-usage/releases*'
# Run both copies without --submit for the same --since window and compare totals.
```

To remove it, change consumers before their targets so that nothing dangles if the work stops partway:
1. Repoint the two links at the checkout copies, after `cmp` showed those copies byte-identical.
2. Move both drop-ins (plus the viberank drop-in's `.bak` copy) into a trash directory under `/tmp`, so the change can be undone, then run `systemctl --user daemon-reload`.
3. Confirm that nothing still uses a release directory. A reload changes only future starts, so a submitter that is already running keeps executing from the release tree, and its sibling lookups fail if that tree moves. Continue only when all five checks are clear:

   ```bash
   grep -rn 'codex-cloud-usage/[r]eleases' ~/.config/systemd/user                # no unit or drop-in refers to it
   find ~/.local/bin -maxdepth 1 -lname '*codex-cloud-usage/[r]eleases*'         # no link points into it
   systemctl --user is-active viberank-submit.service tokscale-submit.service    # both inactive
   pgrep -af 'codex-cloud-usage/[r]eleases'                                      # no process runs from it
   systemctl --user list-timers viberank-submit.timer tokscale-submit.timer      # no run due before you finish
   ```

   The bracketed `[r]` in each pattern stops a check from matching its own command line, so `pgrep` reports nothing even when all five run as one command.
4. Move the now-unused release directories into the same trash directory.
5. Verify the result:

   ```bash
   systemctl --user show viberank-submit.service tokscale-submit.service -p ExecStart -p DropInPaths
   # Expect DropInPaths= empty and ExecStart equal to the tracked unit's line.
   with-cloud-usage ccusage printenv CODEX_HOME | tr ',' '\n' | grep -F /accounts/
   # viberank's reader branch: expect one accounts/<name>/codex root per collector.
   with-cloud-usage tokscale printenv TOKSCALE_EXTRA_DIRS | tr ',' '\n' | grep -F /accounts/
   # tokscale's branch: the same accounts, as codex:<root>/sessions entries.
   ```

   The ccusage branch refreshes the archive bridge before it runs the command. It is slower, and it fails closed with `live file changed during scan` when a session writes during the scan. Re-run it then. On 2026-10-02 both checks listed both extra accounts.

On the next viberank submission (2026-10-02 15:00 EDT), the 2026-10-02 row carried 268,092,619 `codex-cloud-unattributed` tokens. Only account 2's imported history accounts for that many.

## Why This Works

Once the drop-in is removed, the unit runs the tracked command. That command runs the sync-linked script in the canonical checkout, and the script calls its sibling wrapper there, so the next merge reaches viberank the same way it reaches every other reader. The tracked scripts already wrap their readers (`bin/viberank-submit:165`, `bin/tokscale-submit:178` and `:195`), so no drop-in is needed to add cloud usage.

The pin captured more than one file because of sibling resolution. Pinning `viberank-submit` pinned the whole toolchain it calls, including `with-cloud-usage`, `codex-cloud-usage` and `fx-usage-bridge`.

## Prevention

- **Record and remove every host change a pre-merge activation makes.** If an activation pins host config to a release copy, list each host path it writes (drop-ins, `~/.local/bin` links, release directories) in the PR. Remove them as part of that PR's merge closeout. `wt-done` and `dotup` cannot see these paths.
- **Check a consumer's effective command after a merge.** When a merge changes a wrapper or a script's siblings, check what each consuming unit runs before claiming it runs the merged code:

  ```bash
  systemctl --user show <unit> -p ExecStart -p DropInPaths
  grep -rnF '/releases/' ~/.config/systemd/user
  find ~/.local/bin -maxdepth 1 -lname '*/releases/*'
  ```
- **Delete a drop-in instead of repointing it at the base command.** An override identical to its base does nothing, and it hides the next pin.
- **Keep needed overrides tracked.** `sync.sh` already ships tracked drop-ins through its unit lists, for example a privacy drop-in under `systemd/` and the files in `systemd/cass-index.service.d/`. Tracked overrides update with the repo, and a reviewer can see them.

## Related Issues

- `docs/solutions/integration-issues/drive-post-merge-activation-instead-of-handing-back.md`: making merged code live in the canonical checkout. This doc covers a host consumer that does not run the checkout at all.
- `docs/solutions/best-practices/diagnose-against-installed-versions-not-plugin-caches.md`: the same shape of lesson. Resolve what actually runs before trusting the source.
- `harness/codex-cloud-usage.md`, "Which leaderboards receive cloud usage".
- PR #1490 (the pre-merge activation), PR #1501 (per-account ledgers), and issue #1487 (closed).
