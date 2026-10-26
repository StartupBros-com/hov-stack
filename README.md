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

**What nobody else ships:** the permission lists. 291 allow, 75 ask and 70 deny entries, grown from refusals through `/denial-triage`, plus 12 hooks that run before a tool call lands. The other published stacks ship skills; this one ships the part that decides what an agent may run.

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

`./setup` needs git and node. Its plugin steps also need Claude Code 2.1.76 or later, since older releases refuse the `hov` marketplace's manifest. It symlinks this repo into `~/.claude`, so the checkout has to stay where you cloned it. It keeps your existing memory and secrets where they are, and moves anything it replaces to `~/.hov-stack-backups/`. If you already have a `settings.json` it is left alone and the seed lands next to it as `settings.hov-stack.json`. Your own settings, `CLAUDE.md` additions and environment variables go in the private overlay (below), which setup reads and never writes. It then installs `dcg` after checking its checksum and signature (it shows dcg's licence first; `./setup --no-dcg` leaves dcg out), adds the `hov` marketplace, and installs the default plugins (`papercut`, `skill-tuner`, `memory-dream`, `design-rails`). A step that cannot run (offline, no `claude` yet, a platform dcg has no build for) is reported with the command to run later, and `./setup --check` shows what is in place without changing anything. `tests/repo/setup.test.sh` checks these promises on every push, against a stand-in `claude` and a stubbed download, and `dcg/tests/install-test.sh` checks that a tampered archive or a signature from another key installs nothing.

Then start a new Claude Code session and type `/hov-setup`, setup's second stage. Five plugins need what a script cannot do for you: a login, a sudo or Windows prompt, or a paid plan. They are `pro-gate`, `wsl-cdp`, `token-eater`, `product-video` and `sign-it`. The skill shows which of them you have and installs the ones you pick. It then takes each through its own setup, one at a time, ending in a check the session runs. Passwords and tokens go only into each plugin's own login, never into the chat.

## Quick start

1. Run `./setup`
2. Run `claude agents` in any repo. That is the agents view, and it is how 90% of my Claude Code use happens.
3. Ask an agent to push to main. Watch `git-guard` refuse it and name the branch-and-pull-request route. The refusal comes from a hook, not a model call.
4. After a day of work, run `/denial-triage`. It turns the calls the guards refused into permission fixes, each behind its own approval, so the prompts get rarer every week.
5. Run `/memory-dream:dream` on your busiest project. `memory-dream` is one of the default plugins.
6. Stop there. You'll know if this is for you.

## What's here

- `CLAUDE.md`, the global rules file every session and subagent loads (15 KB), and `HARNESS.md` with 34 detail docs in `harness/` explaining the decisions behind it
- `hooks/`: 20 hook scripts that `settings.json` registers across 7 hook events; 12 of them run before a tool call (`git-guard`, `settings-guard`, `loop-guard`, `read-ceiling-chunk` and the rest), and `dcg` runs beside them when it is installed. The hook suite is the 46 test files in `hooks/tests/`.
- `settings.json`: the allow / ask / deny lists I run under bypass-permissions mode (291 / 75 / 70 entries)
- `plugins/hov-stack/skills/` (also reachable as `skills/`): 45 skills, 31 of them slash-command only so they never cost tokens until called, plus patches to 2 third-party skills in `skills-patches/` (papers, and de-slopify's fact-check scripts), each with a note of its upstream
- `skills-stack/`: 2 more slash-command skills (memory-mine, review-adversarial-first) that run this repo's scripts, so `./setup` links them and the plugin does not ship them
- `harnesses/`: my Codex, fx, Pi and pi-lens config, which `install.sh` installs and `./setup` leaves alone. Nothing under it runs in this repo's CI.
- `windows/`: the Windows side of a WSL2 machine (WezTerm and Windows Terminal config, `.wslconfig`, and the disk and Defender scripts)
- `install.sh` and `sync.sh` are the full installers for my own machines (systemd units, the destructive-command guard, the managed deny floor). `./setup` is the one for yours. The systemd units that make sense without them are documented, with copy-and-enable commands, in `systemd/README.md`.

## The plugins

This repository is the `hov` marketplace, and `./setup` adds it. To add it by hand, in Claude Code: `/plugin marketplace add StartupBros-com/hov-stack`, then `/plugin install <name>@hov`. Claude Code leaves auto-update off for a third-party marketplace. To turn it on, open `/plugin`, select **Marketplaces**, choose `hov` and select **Enable auto-update**; updates then apply at the start of a session.

### Installed by `./setup`

- `papercut`: logs every hard tool failure from a hook, ranks them by how many distinct sessions hit each, and carries one family at a time into a tracked work item whose verification refuses to call it fixed on silence alone.
- `skill-tuner`: tells whether a change to a `SKILL.md`, `AGENTS.md` or `CLAUDE.md` worked, by paired comparison with a confidence interval. `/skill-tuner:tune` fixes what three independent skeptics confirm and checks the description still routes.
- `memory-dream`: the sleep cycle for Claude Code's auto-memory. `/memory-dream:dream` finds superseded, stale and oversized notes and drafts the fixes, and you approve each change before anything is written. `/memory-dream:eval` measures whether recall improved.
- `design-rails`: keeps agents on your design system. It checks whether one exists and is enforced, derives a `DESIGN.md` under `design/` from the code you already ship, and ratchets drift budgets that only move down. It never edits application source.

### Set up through `/hov-setup`

- `pro-gate`: a final pull-request review by the Pro model your ChatGPT account selects. It fixes what it safely can, leaves a report and never merges. It needs a ChatGPT Pro plan.
- `wsl-cdp`: lets Claude Code in WSL2 drive your logged-in Windows browser (Chrome, Edge or Brave) over the Chrome DevTools Protocol. Its setup has one elevated Windows step, and the agent's browser profile keeps sessions, never passwords.
- `token-eater`: puts expiring AI credits to work on code cleanup. It works in an isolated copy, verifies and reviews the result, and opens a draft pull request; it never merges. It runs shell commands unsandboxed on the target repository, after its first run asks for your consent, and its reviews need Every's compound-engineering plugin (`/plugin marketplace add EveryInc/compound-engineering-plugin`, then `/plugin install compound-engineering`).
- `product-video`: records a product tour in a real, logged-in browser and renders a checked MP4.
- `sign-it`: `/sign-it` finds a document's signature line, stamps your stored signature and today's date, and writes `<file>-signed.pdf`. It refuses to guess a missing or ambiguous line and never draws a signature for you.

### On request

- `harness-vet`: an adoption gate that vets a skill, plugin, MCP server or repo against your own harness, reading it the way an adversary would.
- `rent-check`: audits what `CLAUDE.md` and always-on skills cost per prompt, measures which rules earn their tokens from real transcripts, and proposes demotions for the ones that do not.
- `harness-optimizer`: investigates recurring problems in your Claude Code setup across six evidence lanes, then has independent agents challenge its diagnosis, proposed changes and reported outcome. It runs only when you invoke it.

## What's not here

- My memory notes, secrets, and business-specific skills. Those live in a private sibling.
- The private overlay. Values the tree cannot carry live in `~/.config/hov-stack/` (or `$XDG_CONFIG_HOME/hov-stack/`, or `$HOV_STACK_OVERLAY`). `./setup` and `claude-env.sh` count only an absolute overlay path: a relative `$HOV_STACK_OVERLAY` is reported and read by nothing, and a relative `$XDG_CONFIG_HOME` is ignored. The scripts read:
  - `private-tokens`, the public-safety scan's fixed-string layer;
  - `foreign-units`, one externally owned unit stem per line, excluded from sync's undeclared-unit findings (blank lines and `#` comments ignored);
  - `memory-filename-allowlist.txt`, the memory audit's reviewed-name list (the tracked copy ships no entries);
  - `supabase-projects.json` and `migration-targets.json`, whose shapes `config/*.example.json` show;
  - `repo-routes.json`, which replaces the tracked placeholder.

  Without one of those, its consumer fails closed and names it. `./setup` also reads these, each optional, and does nothing without them:
  - `settings.json`, merged into the seed setup writes. Its keys win, its lists add to the template's without repeats, a `null` removes a key, and a hook of its that runs dcg is left out when dcg is not installed, as the template's is. It never changes a `settings.json` you already have. One that gives a setting another kind of value than the template's, such as a string where the template has an object, gets no seed written, and the run exits 1.
  - `CLAUDE.md`, imported in every project by the `rules/hov-stack-overlay.md` setup writes in the config dir. Into a `rules/` that is a symlink setup writes nothing, and names the line to add there yourself.
  - `env`, `NAME=value` lines that `claude-env.sh` exports before each Bash call.

  `config/settings.example.json`, `config/CLAUDE.example.md` and `config/env.example` show each, and `./setup --check` names an import not yet written, out of step with the overlay or whose file is gone, an `env` that does not parse, and a `settings.json` setup would refuse.
- A release train for the harness. It changes when my setup changes: `main` is its only version, `git pull` is the update, and no editions or support are owed. Each plugin carries its own version, which the `hov` marketplace serves.
- The private repo's test dispatcher. CI here runs the three repository suites under `tests/repo/` (the fresh-HOME setup test, the layout and marketplace-collision check, the suite runner's own test), the hook tests, every unit suite `tests/run-claude-tests.sh` finds in the tree, a secrets scan (gitleaks) and the public-safety scan: `scripts/public-safety-scan.sh` fails on a home-directory path, a personal address, a private-network host or a private repository name anywhere in the tree, the skipped suites' sources included, and `.public-safety-allow` names each exception and why. `tests/claude-tests.skips` names the 5 suites that cannot pass from this repo and why: 4 read the author's host roster, install manifest or install-smoke launcher, 1 needs real Docker. The runner still runs the first 4, each with the failure signature its log must match, and fails the day one of them passes, times out, or fails for a different reason, so the list cannot go stale quietly.

## Where it came from

- The two-hour walkthrough of this setup is the House of Vibe workshop "Steal My Whole Claude Code Setup" (Aug 5, 2026). houseofvibe.ai
- `dcg`, the third-party destructive-command guard this harness runs alongside its own hooks: https://github.com/Dicklesworthstone/destructive_command_guard

MIT. Copyright (c) 2026 StartupBros LLC. Built by Will Mitchell for House of Vibe.
