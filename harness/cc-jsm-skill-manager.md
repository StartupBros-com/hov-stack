---
name: cc-jsm-skill-manager
description: jsm (jeffreys-skills.md) manages most ~/.claude/skills; how to prune durably and why skills proliferate
metadata:
  node_type: memory
  type: project
  originSessionId: 81d85012-96cf-4e40-afe7-8220afea6378
---

Most of Will's `~/.claude/skills/` are managed by **`jsm`** (jeffreys-skills.md CLI, `~/.local/bin/jsm`, config `~/.config/jsm/config.toml`). As of 2026-06-17: 112 of ~119 skill dirs are jsm-managed; only ~9 are "saved (cloud)" — his deliberate keep-set that `jsm sync` restores.

**Root cause of skill sprawl:** `[auto_update] install_new = true` + daily 03:00 schedule auto-installed every newly-published Jeffrey skill. Set to **`install_new = false`** on 2026-06-17 to stop the inflow (auto-update still refreshes kept skills). If sprawl returns, re-check this flag.

**Prune durably via jsm, NOT by deleting dirs** — a naked `rm` of a skill dir can be re-added by auto-update/`jsm sync`. Correct: `jsm uninstall <skill> --offline` — works headless, **auto-archives to `~/.claude/skills/.trash/<skill>-v1-<ts>/`** (fully reversible), updates jsm's local DB. Reinstall anytime with `jsm install <skill>`.

**Headless limits:** network ops (`jsm list --saved`, `jsm login`, non-offline uninstall) can fail with "Not authenticated" in non-interactive shells (creds are encrypted, need interactive passphrase). Use `--offline` for uninstalls.

**Nightly updates and overlays:** jsm refuses to update a skill whose files differ from what it installed (0.3.22 prompted, `User prompt error: IO error: not a terminal`; 0.3.36 prints `Local edits ... Nothing was changed`), and every `skills-patches` overlay skill differs on purpose. So the wrapper lists pending updates once (`jsm upgrade --list --json`), names every pinned skill (`pinned, not updated`), clears `__pycache__` from those skills in every jsm tree (jsm counts it as a local edit), upgrades each plain skill by name, and decides each overlay skill from `jsm diff --json`: `jsm install --force` when the update leaves every overlaid file alone (ExecStopPost's `skills-localize.sh apply` puts the overlay back), otherwise a `held <skill>` journal line and no change. A held skill stays on its version until someone acts, and rebasing the overlay alone does not release it: the nightly compares jsm's installed-vs-latest file list against the overlay's file names, and a rebase changes neither. To release one, rebase the overlay onto the new upstream files (3-way `git merge-file` with our overlay, the installed upstream as base and the new upstream as theirs; the version zips are in `~/.cache/jsm/skills/`), merge that, then run `jsm install <skill> --version <N> --force` with N the version it was rebased onto and `skills-localize.sh apply`. A bare `--force` installs whatever is latest that day, which can lay a vN overlay over vN+1. The held line names the exact command. The alternative is retiring the skill. A refusal on a plain skill still fails the unit. `jsm sync` no longer runs nightly; run it by hand after saving a skill to the cloud list from elsewhere.

**Failure alerts:** `jsm-auto-update-wrapper.sh` streams output and emits a bounded native journal marker with the invocation ID, stage, fixed cause and up to eight validated skill names. `unit-failure-alert.sh` retrieves that invocation's marker even after successful `ExecStopPost` cleanup fills the journal tail. Discord gets fixed explanations and a local journal probe, never arbitrary JSM output. An unavailable or invalid marker produces a generic failure alert. `UNIT_ALERT_JOURNAL_LINES=0` bypasses all journal reads, including markers.

JSM retains the existing per-unit alert cooldown. Repeated failures can page after that cooldown expires; there is no persistent incident dedup because wrapper success alone does not verify the later cleanup succeeded. Manual remediation and a verified successful service run remain necessary. Backup and other unit failure alerts retain their existing diagnostics and cooldowns.

Jeffrey's skills degrade gracefully when their CLI tools (ntm/beads/cass/ubs/slb/giil) or sibling skills are absent — they fall back to Claude-native alternatives (Task tool, manual tracking) and never hard-block. So removing tool-gated skills doesn't break the ~52 skills that reference them. See [[cc-mcp-architecture]].
