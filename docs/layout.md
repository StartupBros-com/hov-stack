# Layout: the root mirrors `~/.claude`

The repository root is the Claude Code harness. Its directories and files are the
ones `./setup` links or copies into `~/.claude`, so a path in the repo is the same
path in the installed tree, and any PC can restore the full setup:

```bash
git clone --depth 1 https://github.com/StartupBros-com/hov-stack ~/hov-stack
cd ~/hov-stack && ./setup                     # symlinks the harness into ~/.claude; see the root README
```

| What                                                                | Where               | Mechanism                                                                                                                                  |
| ------------------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| CLAUDE.md, hooks/, scripts/, bin/, commands/, agents/               | repo root           | **symlinked** into `~/.claude`, edits are git-visible instantly                                                                            |
| settings.json, keybindings.json                                     | repo root           | **copied** (Claude Code rewrites these; symlinks would break), refresh with `sync.sh push`                                                 |
| Skills: the pack and the ones that run this checkout's scripts      | `plugins/hov-stack/skills/`, `skills-stack/` | one **symlink** per skill into `~/.claude/skills` by `./setup`, except a skill a default plugin provides     |
| Per-project memory                                                  | `memory/<project>/` | copied via `sync.sh push`; absent from this copy until a push creates it                                                                  |
| Systemd units and timers                                            | `systemd/`          | copied and enabled by hand; see `systemd/README.md` for what each one does, which lines to edit, and the plan-only defaults                |
| Two cron-ownership-gated timers (mcp-servers-update, skills-update) | `systemd/`          | copied on install; admitted on the workstation one job at a time only when the matching cron owner is absent; never admitted on satellites |
| Windows break-glass stubs                                           | `windows-stub/`     | reference copies of `/mnt/c/Users/<user>/.claude` stubs                                                                                    |

The full list of harness entries is `DOTFILES_HARNESS` in `lib/manifest.sh`;
`sync.sh` installs them, except the skill directories `./setup` links, and
harness-doctor §10 checks the links.

**Deliberately NOT here:** credentials (`claude login` manually), `~/.claude.json`
(runtime + oauth state), third-party skills (`jsm sync` restores them), plugin installs
(`claude plugin`; the `enabledPlugins` list is inside settings.json), session
history. Never add those.

Drift detection: `~/.claude/scripts/harness-doctor.sh` runs `sync.sh check`
(check 10); run it on demand (the Monday `harness-weekly` timer retired
2026-10-17). When it warns:
`sync.sh push`, then commit and push this repo.

## Outside the mirror

These root entries are repository plumbing or the author's other dotfiles. They
install nowhere under `~/.claude` and `./setup` never touches them:

| Entry                                                                   | What it is                                                                                                 |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `.bashrc`, `.inputrc`, `.ripgreprc`, `.editorconfig`, `.gitignore_global` | shell and editor dotfiles, linked into `$HOME` by `install.sh` (`DOTFILES_ROOT_FILES`)                     |
| `.gitmessage`, `ssh/`                                                   | the author's commit template and ssh config and helpers, which `install.sh` would link (`DOTFILES_ROOT_FILES`, `DOTFILES_LINKS`); absent from this copy, so `manifest_check` names them as missing sources |
| `git/`, `git-setup.sh`                                                  | shared git config, spliced into `~/.gitconfig` once by `git-setup.sh`                                      |
| `install.sh`, `lib/`                                                    | the author's full installer and its link, check and manifest libraries                                     |
| `setup`                                                                 | the guided installer for a fresh clone: links the harness into `~/.claude`, seeds `settings.json` once    |
| `CONCEPTS.md`                                                           | the shared vocabulary the docs and skills cite                                                             |
| `.gitignore`                                                            | ignores the transient `.claude/` worktree state and the split's bookkeeping file                          |
| `config/`                                                               | tool configs `install.sh` links (`DOTFILES_LINKS`) beside the harness's policy files `sync.sh` reads in place |
| `dcg/`, `windows/`                                                      | the DCG guard install and the Windows-side copies, each with its own installer                             |
| `harnesses/`                                                            | the author's codex, fx, pi and pi-lens harnesses: untested here, see `harnesses/README.md`                 |
| `hosts.tsv`                                                             | the host-to-role table `lib/profile.sh` reads in place; absent from this copy                              |
| `tests/repo/`                                                           | suites about the repository itself (`setup`, the suite runner, this layout), run by CI directly            |
| `docs/`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `STRATEGY.md`, `LICENSE`, `NOTICE.md`, `.github/`, `.gitleaks.toml`, `.public-safety-allow`, `.public-safety-repos`, `.compound-engineering/` | repository docs and CI config, read in place (`DOTFILES_UNLINKED`)                                         |

`tests/run-claude-tests.sh` discovers the harness suites directly under `tests/` and
`scripts/tests/` and never descends into `tests/repo/`, so the repository suites
run only from `.github/workflows/ci.yml`.

## Reserved for the flip

At the public flip this repository's tree is merged into the marketplace
repository's. Three prefixes stay reserved here so that merge has nothing to resolve:

- `plugins/` — the marketplace's plugins, except `plugins/hov-stack/`, the skill
  pack, which is this repository's own (the root `skills` link points into it).
  The in-tree copy of the optimiser plugin left with the flatten; it ships on its
  own as `harness-optimizer@hov`.
- `release/` — the marketplace's release tooling; absent from this copy until the flip.
- `.claude-plugin/` at the root — the marketplace manifest; absent from this copy
  until the flip. A plugin manifest inside `mods/<name>/` is a mod's own and stays.

`tests/fixtures/marketplace-tree.txt` pins the marketplace's tracked paths at one
commit, and `tests/repo/layout.test.sh` checks the two trees against each other:
a file on both sides, or a file on one side that is a directory on the other, is a
collision. The expected set is exactly `LICENSE` and `README.md`, both resolved by
hand at the flip. Directories on both sides (`.github/workflows/`, `docs/`,
`docs/plans/`) merge as a union; the plan file names and workflow file names do not
overlap. Refresh the fixture from a newer marketplace commit with the command in its
header.

## Where things came from

This repository is a hand-maintained copy of the author's private dotfiles, where
the harness sat one directory down. The flatten of 2026-10 moved it to the root;
the mapping, for anyone reading an older commit or a path in the history docs:

| Private layout                     | Here                                      |
| ---------------------------------- | ----------------------------------------- |
| `claude/<x>`                       | `<x>`                                     |
| `claude/README.md`                 | `docs/layout.md` (this file)              |
| `claude/config/*`                  | `config/`                                 |
| `claude/tests/setup.test.sh`, `claude/tests/run-claude-tests.test.sh` | `tests/repo/`          |
| `codex/`, `fx/`, `pi/`, `pi-lens/` | `harnesses/<name>/`                       |
| `systemd/user/` (the tunnel unit)  | `harnesses/pi/systemd/user/`              |
| `claude/plugins/harness-optimizer` | gone; `harness-optimizer@hov`             |

## Cron-ownership-gated reliability timers

The repository manages these two replacement timers and their services:

- `mcp-servers-update.timer`
- `skills-update.timer`

`sync.sh install` always deploys the unit files byte-for-byte. On the workstation,
it reads and classifies the active crontab under the shared cutover lock and admits
each timer only when that job's direct legacy command is absent. A legacy owner
that remains or reappears disables only its replacement. A read/parser failure or
concurrent crontab drift fails closed; satellites admit neither. Routine
install therefore deploys a cron-owned replacement without activating it.

This does not migrate the WSL watchdog or any private control-plane job: those
remain cron-owned and unchanged. Repository tests and install support also do not
mean the two live jobs have been activated. Scheduler ownership transfers in a
separate post-merge cutover, independently per job, after canonical deployment and
live proof; see `harness/wsl-crontab-and-cookie-sync.md`.

`settings.json` contains a standalone DCG `PreToolUse` Bash hook. On an
already-configured machine, `sync.sh install` (or the narrower
`sync.sh reconcile-dcg`) backs up the live file and merges only that hook. It
does not replace other hooks, permissions, environment values, or runtime-owned
settings. DCG must be installed at `~/.local/bin/dcg` before opening a
new Claude Code session.

## Project memory audit and sync

The live source is `~/.claude/projects/<project-key>/memory/`. The tracked mirror is
`memory/<project-key>/`, absent from this copy until a push creates it. Project keys stay flat and are discovered from direct
`*/memory` directories. The mirror is a reviewed backup, not a second live store.

Run the dependency-free, read-only auditor before syncing:

```bash
python3 ~/hov-stack/scripts/memory-audit.py
python3 ~/hov-stack/scripts/memory-audit.py --format json --as-of 2026-07-15
bash ~/hov-stack/sync.sh memory-preview
bash ~/hov-stack/sync.sh memory-push

git -C ~/hov-stack diff -- memory
# Inspect every change, then commit and push manually.
```

`memory-preview` and `memory-check` exit 1 when live memory has something the mirror
does not — a file to copy, or a live symlink that blocks the push.
`memory-push` always prints a preview first, then copies live files without deleting
mirror-only projects or files. General `sync.sh push` uses the same non-destructive
memory copy. There is deliberately no prune command. Review `KEEP mirror-only` paths
and remove them manually only after deciding they should not remain restorable.

`KEEP mirror-only` is printed but is **not** drift, and does not affect the exit code.
Because the push never deletes, those paths are append-only history: no command in
this script can clear one, so counting them as drift produced a `DRIFT: memory differs`
that was on permanently and therefore told you nothing. The one mirror-only shape that
_is_ drift is `LOST live store <project>` — the mirror holds a project's notes and its
live store directory has vanished outright. That distinguishes deliberate note deletion
from an unmounted home or a wiped `~/.claude`, and it matters because the corpus floor
counts mirrored files too: without it, a live root that disappeared would walk only the
mirror, satisfy the floor, and report "memory in sync". Resolve a `LOST` line by
restoring the live store, or by `git rm -r memory/<project>` if the project is
genuinely retired (the archive is versioned, so that stays recoverable).

`sync.sh install` restores mirrored projects only when their live memory directory is
missing. It never overwrites an existing live memory directory. To restore a missing
project, run install. To restore selected older or mirror-only files into an existing
project, inspect and copy those files manually.

The auditor validates `MEMORY.md` coverage and links, the existing note frontmatter
contract (`name`, `description`, and either `type` or `metadata.type`), mirror hashes,
duplicate names, size thresholds, sensitive indicators, symlinks, truncated
descriptions (the unquoted `#` YAML-comment bug), and injected-date review candidates. It scans for high-signal credential signatures by default but never
prints note bodies or detected values. Memory pushes refuse sensitive indicators and
symlinks. Exit codes are 0 for no actionable findings, 1 for actionable findings or
sync drift, and 2 for usage or runtime errors. Stale-date review candidates alone do
not fail the audit, which keeps the weekly doctor concise.

## Memory dream pass (consolidation)

The auditor detects rot; the dream pass remediates it, operator-gated. It has three
layers, all reusing the auditor's helpers:

```bash
python3 ~/hov-stack/scripts/memory-audit.py triage        # score notes, read-only
python3 ~/hov-stack/scripts/memory-audit.py fix            # mechanical repairs, dry-run
python3 ~/hov-stack/scripts/memory-audit.py fix --apply    # apply repairs (gated on the pushed backup branch)
python3 ~/hov-stack/scripts/memory-audit.py rehook         # hook bare index fragments, rank-split under the load cap (dry-run)
python3 ~/hov-stack/scripts/memory-audit.py rehook --apply # write MEMORY.md + archive tier (gated on the pushed backup branch)
```

`triage` scores every live note on structure only (supersession markers, body size,
mtime age, inbound wikilinks) and prints a project-level summary ending in a
`flagged:N` line; it never shows filenames or bodies. `fix` performs the mechanical,
one-answer repairs (single-candidate wikilink rewrites, `MEMORY.md` index
reconciliation), dry-run by default; `--apply` preserves each repaired file's mtime and,
like `rehook --apply`, refuses unless live memory matches the pushed backup branch, so
run `systemctl --user start backup-harness.service` first.

The full consolidation runs through the `memory-dream@hov` plugin's operator-invocable
`/memory-dream:dream` command: triage, then a Glob-only drafter subagent proposes
consolidations per cluster, verification stages check every proposed file against its
sources, you review one patch set in the browser and approve item by item, the plugin's
apply snapshots every file it touches and writes only approved changes behind its
safety stack. The harness supplies the plugin's config (`memory-dream.json`:
preview opener). Every
semantic change is proposal-only. The `harness-weekly` report (on demand since its timer
retired 2026-10-17) ends with the same `flagged:N` line, so it tells you when a pass is
worth running.

Apply is single-flight and per-project atomic, so a re-run never double-applies. Full operating procedure and the safety-stack rationale:
`harness/memory-dream-pass.md`.
