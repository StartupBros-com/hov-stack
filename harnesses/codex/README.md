# codex/ — stable WSL Codex hooks

This directory owns only the global `~/.codex/hooks.json` file. It installs the
two enforcement guards — DCG and git-guard — as standalone `PreToolUse` Bash
hooks. Codex launches matching hooks concurrently, so file order is
organizational rather than an enforcement dependency.

```bash
bash ~/dotfiles/codex/sync.sh check
bash ~/dotfiles/codex/sync.sh install
```

Installation validates both JSON files, backs up a differing live hooks file,
and replaces it atomically. It never reads or writes `config.toml`, credentials,
sessions, runtime state, or Codex's hook-trust records.

The tracked `hooks.json` is a template that spells every home path with a
literal `$HOME/`; `sync.sh install` renders it for the installing user's home
and `check` compares the live file against that rendered form.

After installing, open a **new** Codex session, run `/hooks`, inspect the exact
`~/.local/bin/dcg` command, and approve it interactively. Existing
sessions are not restarted. DCG is an additional command guard, not a sandbox;
Codex hook coverage for compound/unified execution paths may be incomplete.

When the active ChatGPT account's Codex window is out, `codex-pick --exec --
codex exec …` (on PATH via `~/.local/bin`, dotfiles#991) runs the command on
the best model OpenAI's live catalog and usage endpoints say is actually
available — better-ccflare's Codex OAuth account pool (addressed by route profile: `-m claude-bccf-route-codex-pool-<tier>
-c model_provider=better_ccflare`), a separately metered model on the same
account, or another caam isolated profile (an API-key lane exists but is off
unless `CODEX_PICK_API_LANE=1` is set: OAuth subscription limits only, no API
spend) — and exits 3 without spending when nothing is. A run that already
names a `model_provider` is left alone. `codex-pick --json -- codex exec …` prints
the receipt instead of running. Claude Code's own `codex exec` calls get the
same treatment from the PreToolUse quota guard; scripts and cron on this host
do not pass through that guard, which is what `codex-pick` is for. Details:
`harness/codex-delegation-setup.md`.

Codex reaches the harness's data sources through the same CLIs Claude Code
uses — `gsc` (Search Console), `dfs` (DataForSEO), `exa-cli` (Exa web
search/contents), and `firecrawl-cli` (Firecrawl documents, extraction,
screenshots, and browser tasks) — all on PATH via `~/.local/bin`. Put
`--json` and other global flags after the subcommand. Verbs, the JSON envelope, exit codes, and
credential order live in `harness/data-source-clis.md`. The
`workspace-write` sandbox has no network egress by default; on this machine
the `auto` profile (`~/.codex/auto.config.toml`, unversioned by design) sets
`network_access = true` under `[sandbox_workspace_write]` since 2026-09-04 so
delegated runs can reach the providers. That toggle is sandbox-wide (every
command in the sandbox gets egress, not only these CLIs) and per machine: a
new host needs the same line before `exa-cli` works from Codex.
