# Provenance of the security-audit-for-saas overlay

This directory is the public half of a patch that `skills-localize.sh apply` lays over the jsm-managed `security-audit-for-saas` skill (v11, Jeffrey Emanuel, proprietary jsm license). Until that runs, the paths the patch names under `~/.claude/skills/security-audit-for-saas/scripts/` do not exist.

The three scripts here were written for this harness on 2026-11-02 (issue #351). A vet that day of a licensed third-party security skill pack picked out these three checks as worth having. Nothing from that pack's code was copied.

This repository carries only the scripts. The text changes to `SKILL.md` and two reference files are modified copies of the proprietary upstream, so a public tree cannot carry them. They live in the host's patch, `<overlay>/skills-patches/security-audit-for-saas/`:
- `SKILL.md`
- `references/SUPPLY-CHAIN-DEEP.md`
- `references/INCIDENT-RESPONSE.md`
- their `.base/` copies and `.base/VERSION`

`skills-localize.sh` adds the host's patch to this one and 3-way merges it onto the installed skill. Without the host's patch the scripts still install, and the skill's text stays upstream's.

## Local changes in the host's patch (everything else is upstream v11 text)

- **`SKILL.md`, tooling table:** one row per script, plus one line telling the reader to run the scripts with `python3 -I`, which need only the standard library.
- **`references/SUPPLY-CHAIN-DEEP.md`:**
  - After the lockfile-scanning advice, one paragraph. It says a scan of today's lockfile misses a malicious version that was merged and later reverted, points to `lockfile-history.py`, and says which data leaves the machine (package names and versions, sent to api.osv.dev).
  - The same paragraph points to `eol-check.py`.
  - The compromise-recovery playbook grows from 7 steps to 9. Two steps are new: find every install with `lockfile-history.py`, then remove persistence with `worm-sweep.py` before rotating anything. That order matters because Shai-Hulud-family worms install a monitor that wipes the home directory when the stolen token is revoked, and their hooks re-steal whatever replaces it.
- **`references/INCIDENT-RESPONSE.md`:** the same sweep-before-rotate rule appears twice, at the leaked-credentials step and as a new bullet in the containment list.

## Scripts

All three use only the standard library, read their inputs as data and never execute them, and are meant to run with `python3 -I`.

- **`lockfile-history.py`** reads every lockfile version git holds, across all branches within `--since`. It also reads:
  - the version each in-window change replaced, and the version at every branch tip;
  - every uncommitted lockfile;
  - what is installed in `node_modules` and virtualenvs.

  It then asks OSV in batches, following paging, which of those package versions carry advisories. By default it reports malicious-package (`MAL-`) advisories only. Supported formats: npm v1–v3 (aliases included), pnpm v5–v9, bun, yarn classic and berry, uv, poetry, pipenv and requirements files. `--list-packages` and `--extract` make no network call.
- **`worm-sweep.py`** looks for the files, hooks, services and git traces that npm and PyPI worms leave behind:
  - in repos: payload and secret-dump file names, agent and editor auto-run config, and worm branches and workflows in history;
  - in the home directory: monitor services, LaunchAgents, user-level hooks and `.pth` start-up files;
  - in the temp directory: the worms' lock and log files.

  Every indicator cites the public write-up it came from. It is read-only. Nested checkouts are skipped unless `--include-nested` is given.
- **`eol-check.py`** reads the runtime, database and framework versions a repo declares and checks each against endoflife.date, or against the snapshots given with `--data`. Its sources are:
  - version files and mise config;
  - `package.json` engines and `next`;
  - `pyproject.toml` `requires-python`;
  - `go.mod`;
  - Supabase's Postgres major;
  - Dockerfile and compose images;
  - workflow setup versions.

  It opens only those files, never `.env`. A floor or range is judged by the lowest version it allows.

`tests/security-audit-overlay.test.sh` exercises all three offline under `env -i`, against the fixtures in `tests/fixtures/security-audit-overlay/`:
- lockfiles produced by the real tools, plus hand-written edge cases;
- endoflife.date snapshots taken 2026-11-02;
- a planted git history and worm tree that the test builds itself.

The lockfiles came from npm, pnpm, bun, yarn, uv and poetry runs. The hand-written cases are pnpm v5 and v6, pnpm v9 with peers, pipenv, requirements and npm aliases.

When jsm ships a new `security-audit-for-saas` version, `skills-localize.sh apply` merges the host's text changes onto it and lists any line both sides changed in its conflicts file. `skills-localize.sh rebase security-audit-for-saas <version>`, run from a worktree, then moves the host's base forward in place.
