# hov-stack

I'm [Will Mitchell](https://x.com/startupbros). I'm not the president of YC and I'm not on the React core team. I'm a marketer who has been vibe coding full time for almost four years, shipping solo on Windows. **hov-stack is my answer.** This is the Claude Code harness I work in every day, not a copy of it. My Codex and Pi setups load skills from it too.

Fork it. Improve it. Make it yours.

**Receipts, not adjectives:**

<!-- Screenshots return when the PNGs land in docs/images/ (none are in the repo yet):
     ![Skill usage across 20,610 Claude Code sessions](docs/images/skill-usage.png)
     ![30 agents running in the Claude Code agents view during a live workshop](docs/images/agents-view.png)
-->

In the 60 days to 2026-10-19: 4,302 pull requests merged across 17 repos. Everything that got there is in this repo: the rules, the guards, the permission lists, the skills.

<!-- ![GitHub contributions, 2026](docs/images/github-2026.png) -->

**What nobody else ships:** the permission lists. 292 allow, 75 ask and 70 deny entries, grown from refusals through `/denial-triage`, plus 10 hooks that run before a tool call lands. The other published stacks ship skills; this one ships the part that decides what an agent may run.

## Who this is for

- **Non-technical builders** who want a working setup without learning any of it. Paste the sentence below and you are done.
- **Solo operators** running several businesses on one machine. The guards and the permission lists exist so parallel agents stop colliding.
- **Claude Code users with a setup already** who want to cherry-pick the guards, the rules file, or the memory workflow.

## Install, about a minute

Builders:

```bash
git clone --depth 1 https://github.com/StartupBros-com/hov-stack ~/hov-stack && cd ~/hov-stack && ./setup
```

Everyone else, open Claude Code anywhere and paste:

> Set me up from https://github.com/StartupBros-com/hov-stack. Read its README and HARNESS.md first, run its setup, apply what fits this machine, and tell me what you skipped and why.

`./setup` needs git and node, and `dcg` also needs `minisign` to check its signature (`brew install minisign`, or `mise use -g minisign`; without it dcg is skipped, and setup prints the command). Its plugin steps also need Claude Code 2.1.76 or later, since older releases refuse the `hov` marketplace's manifest. It symlinks this repo into `~/.claude`, so the checkout has to stay where you cloned it. It keeps your existing memory and secrets where they are, and moves anything it replaces to `~/.hov-stack-backups/`. It also links the data commands in `bin/` (`gsc`, `dfs`, `stripe-api` and ten more, which the `data-source-clis` skill teaches agents to call) into `~/.local/bin`, so they run by name; a path there that already holds something of yours is left alone and named, and hov-stack's copy still runs as `~/.claude/bin/<name>`. Once `~/.local/bin` is on PATH, `rules/hov-stack-tools.md` gets one line naming the data commands that run hov-stack's copy, so agents reach for them before an MCP server. If you already have a `settings.json` it is left alone and the seed lands next to it as `settings.hov-stack.json`, unless it is setup's own seed from a run before dcg was installed and nothing but Claude Code's plugin entries has changed it: then it is backed up and seeded again with dcg's hook, keeping those plugin entries. Your own settings, `CLAUDE.md` additions and environment variables go in the private overlay (below), which setup reads and never writes. It then installs `dcg` after checking its checksum and signature (it shows dcg's licence first; `./setup --no-dcg` leaves dcg out), adds the `hov` marketplace, and installs the default plugins (`papercut`, `skill-tuner`, `memory-dream`, `design-rails`). When `settings.json` is setup's own seed, it also turns on auto-update for `hov`, so those plugins get new versions by themselves; in a `settings.json` you already had, it only reports whether auto-update is on, and `/hov-setup` asks before turning it on. Last, it writes `rules/hov-stack-tools.md` in the config dir: a line telling Claude when to use each of `gh`, `ast-grep`, `codex`, `pro-gate` and `cass` that is installed and whose program is on PATH, so Claude is never told to use a tool you lack. `./setup --update` and `/hov-setup` rewrite it, and it is removed when none of them is installed. A file of yours at that path, or a symlink, is left alone; into a `rules/` that is a symlink setup writes nothing, and names the files whose lines to add there. A step that cannot run (offline, no `claude` yet, a platform dcg has no build for) is reported with the command to run later, and `./setup --check` shows what is in place without changing anything. `tests/repo/setup.test.sh` checks these promises on every push, against a stand-in `claude` and a stubbed download, and `dcg/tests/install-test.sh` checks that a tampered archive or a signature from another key installs nothing.

Setup ends by saying, in plain words, what it put in place. Then open a new Claude Code session, which loads the rules and safety checks setup just linked, and type `/hov-setup`, setup's second stage. Five plugins need what a script cannot do for you: a login, a sudo or Windows prompt, or a paid plan. They are `sign-it`, `wsl-cdp`, `product-video`, `token-eater` and `pro-gate`. For each one, `/hov-setup` says what it does for you, what it costs, what you would have to do yourself, and whether it recommends it. It installs the ones you pick, asks you to type `/reload-plugins` once so nothing restarts, and does every step it can itself; you only type logins and passwords, each into that service's own prompt and never into the chat. Each plugin ends with a check the session runs. It also offers the tuning plugins below, which need no setup, and the plugins and programs from other publishers listed under [More that `/hov-setup` offers](#more-that-hov-setup-offers), and finishes with a short tour of everything setup installed.

## Updating

Run `./setup --update` in the checkout. It fast-forwards the checkout to the latest `main`, runs the new copy of setup, and then updates what setup and `/hov-setup` installed:

- `dcg`, to the version the checkout now names (never to an older one).
- The `hov` plugins, and the other publishers' plugins `/hov-setup` offers that you installed.
- `gh`, `uv`, `cass` and `jsm`, where `/hov-setup` installed them, to the versions the checkout now names. Each new copy has to match its checksum and start before it replaces the old one, and an update that fails part way puts the old one back.
- `ast-grep` and `synthetic-panel`, where uv installed them.

It leaves alone anything you installed some other way, a program that changed since `/hov-setup` installed it (jsm updates itself, and `cass upgrade` updates cass), and a checkout with commits or changes of yours that a fast-forward would lose, and says what it left and why. Plugin updates reach sessions started after it. Claude Code updates itself, and `jsm upgrade` updates the jeffreys-skills skills: setup prints that line rather than running it, since those skills come from your own subscription.

## Quick start

1. Run `./setup`
2. Run `claude agents` in any repo. That is the agents view, and it is how 90% of my Claude Code use happens.
3. Ask an agent to push to main. Watch `git-guard` refuse it and name the branch-and-pull-request route. The refusal comes from a hook, not a model call.
4. After a day of work, run `/denial-triage`. It turns the calls the guards refused into permission fixes, each behind its own approval, so the prompts get rarer every week.
5. Run `/memory-dream:dream` on your busiest project. `memory-dream` is one of the default plugins.
6. Stop there. You'll know if this is for you.

## What's here

- `CLAUDE.md`, the global rules file every session and subagent loads (14 KB), and `HARNESS.md` with 35 detail docs in `harness/` explaining the decisions behind it
- `hooks/`: 16 hook scripts that `settings.json` registers across 6 hook events; 10 of them run before a tool call (`git-guard`, `settings-guard`, `loop-guard`, `runner-guard` and the rest), and `dcg` runs beside them when it is installed. The papercut plugin registers its own on top: failure capture, the Read ceiling guard and the StructuredOutput unwrap. The hook suite is the 45 test files in `hooks/tests/`.
- `settings.json`: the allow / ask / deny lists I run under bypass-permissions mode (292 / 75 / 70 entries)
- `plugins/hov-stack/skills/` (also reachable as `skills/`): 45 skills, 31 of them slash-command only so they never cost tokens until called, plus patches to 3 third-party skills in `skills-patches/` (papers, de-slopify's fact-check scripts, and security-audit-for-saas's lockfile-history, worm-sweep and EOL-check scripts), each with a note of its upstream
- `skills-stack/`: 2 more slash-command skills (memory-mine, review-adversarial-first) that run this repo's scripts, so `./setup` links them and the plugin does not ship them
- `harnesses/`: my Codex, fx, Pi and pi-lens config, which `install.sh` installs and `./setup` leaves alone. Nothing under it runs in this repo's CI.
- `windows/`: the Windows side of a WSL2 machine (WezTerm and Windows Terminal config, `.wslconfig`, and the disk and Defender scripts)
- `install.sh` and `sync.sh` are the full installers for my own machines (systemd units, the destructive-command guard, the managed deny floor). `./setup` is the one for yours. The systemd units that make sense without them are documented, with copy-and-enable commands, in `systemd/README.md`.

## The plugins

This repository is the `hov` marketplace, and `./setup` adds it. To add it by hand, in Claude Code: `/plugin marketplace add StartupBros-com/hov-stack`, then `/plugin install <name>@hov`. Claude Code leaves auto-update off for a third-party marketplace, so `./setup` turns it on for `hov` in the `settings.json` it seeds, and `/hov-setup` offers to in yours. By hand: open `/plugin`, select **Marketplaces**, choose `hov` and select **Enable auto-update**. To turn it off, set `autoUpdate` to `false` under `extraKnownMarketplaces.hov` in `settings.json`; that setting wins over the `/plugin` switch. With it on, Claude Code fetches new versions in the background, and sessions started after that use them.

### Installed by `./setup`

- `papercut`: logs every hard tool failure from a hook, ranks them by how many distinct sessions hit each, and carries one family at a time into a tracked work item whose verification refuses to call it fixed on silence alone.
- `skill-tuner`: tells whether a change to a `SKILL.md`, `AGENTS.md` or `CLAUDE.md` worked, by paired comparison with a confidence interval. `/skill-tuner:tune` fixes what three independent skeptics confirm and checks the description still routes.
- `memory-dream`: the sleep cycle for Claude Code's auto-memory. `/memory-dream:dream` finds superseded, stale and oversized notes and drafts the fixes, and you approve each change before anything is written. `/memory-dream:eval` measures whether recall improved.
- `design-rails`: keeps agents on your design system. It checks whether one exists and is enforced, derives a `DESIGN.md` under `design/` from the code you already ship, and ratchets drift budgets that only move down. It never edits application source.

### Set up through `/hov-setup`

- `sign-it`: `/sign-it` finds a document's signature line, stamps your stored signature and today's date, and writes `<file>-signed.pdf`. It refuses to guess a missing or ambiguous line and never draws a signature for you.
- `wsl-cdp`: lets Claude Code in WSL2 drive your logged-in Windows browser (Chrome, Edge or Brave) over the Chrome DevTools Protocol. Its setup has one elevated Windows step, and the agent's browser profile keeps sessions, never passwords.
- `product-video`: records a product tour in a real, logged-in browser and renders a checked MP4.
- `token-eater`: puts expiring AI credits to work on code cleanup. It works in an isolated copy, verifies and reviews the result, and opens a draft pull request; it never merges. It runs shell commands unsandboxed on the target repository, after its first run asks for your consent, and its reviews need Every's compound-engineering plugin (`/plugin marketplace add EveryInc/compound-engineering-plugin`, then `/plugin install compound-engineering`).
- `pro-gate`: a final pull-request review by the Pro model your ChatGPT account selects. It fixes what it safely can, leaves a report and never merges. It needs a ChatGPT Pro plan.

### Offered by `/hov-setup`, with nothing to set up

- `harness-vet`: an adoption gate that vets a skill, plugin, MCP server or repo against your own harness, reading it the way an adversary would.
- `rent-check`: audits what `CLAUDE.md` and always-on skills cost per prompt, measures which rules earn their tokens from real transcripts, and proposes demotions for the ones that do not.
- `harness-optimizer`: investigates recurring problems in your Claude Code setup across six evidence lanes, then has independent agents challenge its diagnosis, proposed changes and reported outcome. It runs only when you invoke it.

## More that `/hov-setup` offers

These are not part of this repository. `/hov-setup` offers each one with its publisher, cost and what it needs, installs only the ones you pick, and gets each working in the same session. Plugins come from their publishers' own marketplaces, which it adds after a yes. Programs go into `~/.local/bin` without sudo: `gh`, `uv`, `cass` and `jsm` are release binaries checked against a SHA-256 written in `install-release.sh`, and `synthetic-panel` and `ast-grep` install through uv.

- `last30days` (Matt Van Horn): a plugin that researches what people said about a topic in the last 30 days on Reddit, X, YouTube, Hacker News, GitHub and the web. Most sources are free; TikTok and Instagram go through ScrapeCreators, free for 10,000 calls and then paid. It needs Python 3.12 or later, which `/hov-setup` can add with uv.
- `synthetic-panel` (StartupBros): ranks headlines, offers or product ideas by how a simulated customer panel reacts, scored locally with no account. On Linux it installs the CPU build of PyTorch (about 1.3 GB, against about 5.6 GB for the default CUDA build), and its skill is fetched at a fixed commit.
- `gh` (GitHub): the GitHub CLI, which token-eater and pro-gate need. The login runs in the browser through `gh auth login --web`.
- `ast-grep` (Herrington Darkholme): structural code search and rewrite. Once it is installed and on PATH, `rules/hov-stack-tools.md` tells agents to prefer it over line-based grep.
- `compound-engineering` (Every): Every's plan, build, review and learn loop, which token-eater's reviews use. MIT.
- `codex` (OpenAI): OpenAI's plugin for handing tasks and reviews to Codex. It needs a ChatGPT plan with Codex or OpenAI credits, and its stop-time review gate stays off unless you turn it on.
- `skill-creator` (Anthropic): Anthropic's skill for writing, testing and tuning your own skills.
- `cass` (Jeffrey Emanuel): searches past agent sessions on this machine; the `cass-rerank-local` skill builds on it. Its MIT licence carries a rider barring OpenAI, Anthropic and anyone acting for them.
- `jeffreys-skills` (Jeffrey Emanuel): a paid skill library ($20 a month or $216 a year, no trial) and its manager, `jsm`. This repository never redistributes those skills: `/hov-setup` installs `jsm`, the login runs in the browser through `jsm login --remote`, and you choose which skills to install.

## What's not here

- My memory notes, secrets, and business-specific skills. Those live in a private sibling.
- The private overlay. Values the tree cannot carry live in `~/.config/hov-stack/` (or `$XDG_CONFIG_HOME/hov-stack/`, or `$HOV_STACK_OVERLAY`). `./setup` and `claude-env.sh` count only an absolute overlay path: a relative `$HOV_STACK_OVERLAY` is reported and read by nothing, and a relative `$XDG_CONFIG_HOME` is ignored. The scripts read:
  - `private-tokens`, the public-safety scan's fixed-string layer;
  - `foreign-units`, one externally owned unit stem per line, excluded from sync's undeclared-unit findings (blank lines and `#` comments ignored);
  - `hosts.tsv`, this host's copy of the fleet's host-to-role table (`<hostname><TAB><workstation|satellite>` lines), which `lib/profile.sh` reads when the tree carries none. The `workstation` row is the one host allowed to push canonical state, so the operator writes it, and `sync.sh check` reports a host whose live tree has no roster;
  - `hygiene-posture`, the hygiene timers this host runs and their settings (deletion on, schedule), one `<unit-stem> [KEY=value]` per line; `sync.sh install` applies it and `sync.sh check` reports drift (`systemd/README.md`);
  - `memory-filename-allowlist.txt`, the memory audit's reviewed-name list (the tracked copy ships no entries);
  - `ga4-properties.json`, `posthog-projects.json`, `resend-bws-bindings.json`, `stripe-accounts.json`, `supabase-projects.json` and `migration-targets.json`, whose shapes `config/*.example.json` show;
  - `repo-routes.json`, which replaces the tracked placeholder;
  - `reclaim-sweep-keep`, paths `reclaim-sweep` never removes, one absolute glob per line (`systemd/README.md`). Without it there is no keep list; one that cannot be read or parsed makes the sweep refuse to plan or apply.

  Without one of the others, its consumer fails closed and names it. `./setup` also reads these, each optional, and does nothing without them:
  - `settings.json`, merged into the seed setup writes. Its keys win, its lists add to the template's without repeats, a `null` removes a key, and a hook of its that runs dcg is left out when dcg is not installed, as the template's is. It never changes a `settings.json` you already have. One that gives a setting another kind of value than the template's, such as a string where the template has an object, gets no seed written, and the run exits 1.
  - `CLAUDE.md`, imported in every project by the `rules/hov-stack-overlay.md` setup writes in the config dir. Into a `rules/` that is a symlink setup writes nothing, and names the line to add there yourself.
  - `env`, `NAME=value` lines that `claude-env.sh` exports before each Bash call.

  `config/settings.example.json`, `config/CLAUDE.example.md` and `config/env.example` show each, and `./setup --check` names an import not yet written, out of step with the overlay or whose file is gone, an `env` that does not parse, and a `settings.json` setup would refuse.

  `scripts/skills-localize.sh` reads one more optional entry: `skills-patches/`, laid out like this repository's. Each file there adds to this repository's patch for that skill and never replaces one: where both carry a file, this repository's applies and `skills-localize.sh check` reports a differing host copy. Setting `SKILLS_PATCHES_DIR` leaves the host's patches out; `SKILLS_HOST_PATCHES_DIR` names another directory, or none when it is empty.
- A release train for the harness. It changes when my setup changes: `main` is its only version, `./setup --update` is the update, and no editions or support are owed. Each plugin carries its own version, which the `hov` marketplace serves.
- The private repo's test dispatcher. CI here runs the three repository suites under `tests/repo/` (the fresh-HOME setup test, the layout and marketplace-collision check, the suite runner's own test), the hook tests, every unit suite `tests/run-claude-tests.sh` finds in the tree, a secrets scan (gitleaks) and the public-safety scan: `scripts/public-safety-scan.sh` fails on a home-directory path, a personal address, a private-network host or a private repository name anywhere in the tree, the skipped suites' sources included, and `.public-safety-allow` names each exception and why. `tests/claude-tests.skips` names the 5 suites that cannot pass from this repo and why: 4 read the author's host roster, install manifest or install-smoke launcher, 1 needs real Docker. The runner still runs the first 4, each with the failure signature its log must match, and fails the day one of them passes, times out, or fails for a different reason, so the list cannot go stale quietly.
- A ccflare gateway. `scripts/reclaim-sweep.py` and `scripts/dispatcher-cost.py` assume one (better-ccflare, state under `~/.config/better-ccflare/`) and have nothing to read without it.

## Where it came from

- The two-hour walkthrough of this setup is the House of Vibe workshop "Steal My Whole Claude Code Setup" (Aug 5, 2026). houseofvibe.ai
- `dcg`, the third-party destructive-command guard this harness runs alongside its own hooks: https://github.com/Dicklesworthstone/destructive_command_guard
- `cass`, the third-party coding-agent session search that `scripts/cass-rerank`, `scripts/cass-search-health.sh`, `scripts/cass-release-promote.sh` and `scripts/cass-index-rebuild.sh` drive: https://github.com/Dicklesworthstone/coding_agent_session_search. Those scripts call an installed `cass` and carry none of its code.
- Both tools are Jeffrey Emanuel's and ship under the MIT License with an OpenAI/Anthropic rider; read each project's `LICENSE` before you install it.

MIT. Copyright (c) 2026 StartupBros LLC. Built by Will Mitchell for House of Vibe.
