#!/usr/bin/env bash
# shellcheck shell=bash
# SC2034: this file is pure data. Every array here is consumed by a script that
# sources it (install.sh, harness-doctor.sh §10c, the test suite), never locally.
# shellcheck disable=SC2034
#
# manifest.sh — the single source of truth for what install.sh puts in $HOME.
#
# Why this file exists (dotfiles#204): the link set used to live only as inline
# arguments inside install.sh, which meant it had exactly one consumer and could
# never be checked. Two whole classes of defect hid in that gap, both observed
# live on 2026-08-06:
#
#   1. Links that silently stopped being links. ~/.bashrc, ~/.config/ru/config
#      and ~/.config/ru/repos.d had all degraded from symlink to a real copy
#      (identical content, so zero visible symptom) while their siblings stayed
#      linked. Edits on either side would have diverged in silence.
#   2. Repo content nothing installs. config/dcg/config.toml, config/zellij and
#      harnesses/pi-lens/config.json were all live in $HOME as HAND-MADE symlinks that no
#      installer creates — so a fresh machine would silently come up without
#      them, falling back to tool defaults.
#
# Deliberately NOT holman-style glob-by-convention (`*.symlink` -> ~/.<name>).
# This repo carries DCG and a root-owned managed-settings lock; an explicit,
# reviewable manifest beats magic discovery. The point of centralizing is not to
# make adding a topic automatic — it still takes an edit here — but to make a
# SKIPPED edit detectable. harness-doctor.sh §10c reads this file and warns.
#
# Consumers:
#   install.sh                       — creates the links (via lib/link.sh)
#   scripts/harness-doctor.sh — §10c verifies them, read-only
#
# Paths are repo-relative on the left, $HOME-relative on the right. No leading
# slashes, no ~, no $HOME — both consumers prefix their own roots so the whole
# manifest can be exercised against a temp dir in tests.

# Linked from <repo>/<name> to $HOME/<name>, name unchanged.
DOTFILES_ROOT_FILES=(
  .bashrc
  .inputrc
  .editorconfig
  .gitignore_global
  .gitmessage
  .ripgreprc
)

# "<repo-relative source>|<$HOME-relative destination>"
# A source may be a file or a directory; the destination becomes a symlink to it.
DOTFILES_LINKS=(
  "config/starship.toml|.config/starship.toml"
  "config/bat|.config/bat"
  "config/mise/config.toml|.config/mise/config.toml"
  # pnpm global rc. Adopted 2026-08-07 after its build-script allowlist sat silently
  # malformed for months in an unmanaged config layer — variant 3 of the defects above:
  # not a degraded link and not uninstalled repo content, but live config nothing owned.
  "config/pnpm/rc|.config/pnpm/rc"
  "config/zellij|.config/zellij"
  "config/dcg/config.toml|.config/dcg/config.toml"
  # ru (repo_updater): config + curated repo lists; ru writes no state here.
  "config/ru/config|.config/ru/config"
  "config/ru/repos.d|.config/ru/repos.d"
  # SSH config only — never keys.
  "ssh/config|.ssh/config"
  "harnesses/pi/agent/settings.json|.pi/agent/settings.json"
  "harnesses/pi/agent/AGENTS.md|.pi/agent/AGENTS.md"
  "harnesses/pi/agent/maintenance.repos.json|.pi/agent/maintenance.repos.json"
  "harnesses/pi/agent/extensions|.pi/agent/extensions"
  "harnesses/pi/agent/prompts|.pi/agent/prompts"
  "harnesses/pi/agent/bin|.pi/agent/bin"
  # Self-healing local-champion SSH tunnel used by pi-local.
  "harnesses/pi/systemd/user/pi-local-champion-tunnel.service|.config/systemd/user/pi-local-champion-tunnel.service"
  "harnesses/pi-lens/config.json|.pi-lens/config.json"
  # gsc and dfs. This comment used to claim they were already
  # "versioned-then-symlinked". They were not, and neither was the claim in
  # CLAUDE.md or in the dfs wrapper's own header. Both wrappers existed
  # only as loose files in ~/.local/bin, and bin/dfs.py was untracked
  # entirely, so a rebuild lost dfs outright and left gsc's impl without a
  # launcher. That is this file's own defect class read backwards: not repo
  # content nothing installs, but $HOME content the repo never had. Found
  # 2026-08-07 while checking whether dfs survived a machine loss. It did not.
  # One read-only pre-commit/review snapshot for the three Git commands agents
  # assembled explicitly 357 times in the 90-day transcript sample.
  "bin/git-preflight|.local/bin/git-preflight"
  "scripts/unit-health.sh|.local/bin/unit-health"
  "bin/gsc|.local/bin/gsc"
  "bin/ga4|.local/bin/ga4"
  "bin/discord-cli|.local/bin/discord-cli"
  "bin/resend-cli|.local/bin/resend-cli"
  "bin/stripe-api|.local/bin/stripe-api"
  "bin/posthog-api|.local/bin/posthog-api"
  "bin/supabase-api|.local/bin/supabase-api"
  "bin/fal-api|.local/bin/fal-api"
  "bin/dfs|.local/bin/dfs"
  "bin/exa-cli|.local/bin/exa-cli"
  "bin/firecrawl-cli|.local/bin/firecrawl-cli"
  "bin/vastai|.local/bin/vastai"
  "bin/vast-ssh|.local/bin/vast-ssh"
  # codex-pick: the Codex best-available-model resolver for scripts, cron, and
  # the Codex host, none of which pass through Claude Code's PreToolUse guard
  # (dotfiles#991). Node, no deps; reaches hooks/lib through its own
  # real path, so it works from a worktree before deploy.
  "bin/codex-pick|.local/bin/codex-pick"
  # Explicit Gemini sandbox injection. The key is no longer sourced into every
  # shell, Claude/Codex session, or worktree; only the child command receives it.
  "bin/with-gemini-sandbox|.local/bin/with-gemini-sandbox"
  # tokscale custom pricing — the $0 overrides that keep local-model tokens in
  # leaderboard submissions (dotfiles#446). pnpm-rc precedent: live config nothing
  # owned. settings.json is deliberately ABSENT: tokscale rewrites it via atomic
  # rename, which replaces a symlink with a plain file (config set / autosubmit /
  # TUI all save; plain submit never does) — it stays vendor-owned and is
  # surveilled field-level by harness-weekly instead (plan R14).
  "config/tokscale/custom-pricing.json|.config/tokscale/custom-pricing.json"
  # ccusage pricing overrides for better-ccflare route aliases that Codex logs
  # as its model (priced $0 otherwise, which makes straude.com abort a whole
  # push window; better-ccflare #343). ccusage's user config path is
  # ~/.config/claude/ccusage.json.
  "config/ccusage/ccusage.json|.config/claude/ccusage.json"
  # Omarchy desktop pieces written on satellite-host on 2026-10-10
  # (the author's infrastructure repository's #688). Until now they existed only on the XPS, so a
  # rebuild would have lost them without any warning. They are inert on every
  # other machine: only omarchy-hook and nautilus-python read these paths, and
  # workstation has neither.
  # - Blip is a git-managed Omarchy plugin that `omarchy update` never moves.
  #   This post-update hook posts a toast when upstream has new commits, and a
  #   click runs the reviewed update. The file is linked, not the directory,
  #   because the XPS has other hooks in the same directory.
  # - taildrop.py adds a Nautilus right-click "Send via Taildrop" menu that lists
  #   the online tailnet peers.
  "config/omarchy/hooks/post-update.d/blip-update-reminder.hook|.config/omarchy/hooks/post-update.d/blip-update-reminder.hook"
  "config/nautilus-python/extensions/taildrop.py|.local/share/nautilus-python/extensions/taildrop.py"
  # Live hand-made links found undeclared by the #210 audit — the exact class
  # §10c(c) exists to catch. Declared here so a fresh machine gets them.
  "harnesses/pi/agent/optional-extensions|.pi/agent/optional-extensions"
  "ssh/bin/pishosts|.local/bin/pishosts"
  "ssh/bin/pissh|.local/bin/pissh"
  # python -> python3 shim (papercut dotfiles#577): agents keep generating
  # `python ...` in non-interactive shells and this box ships only python3 —
  # 50 failed calls / 19 sessions in the 7d triage window. NOTE removal of this
  # entry is invisible to the generic checker: scan (c) in lib/check.sh skips
  # harness-domain link targets, so install-manifest.test.sh case 19 and the
  # install-smoke probe steps are the fail-if-absent gates, not manifest_check.
  "bin/python|.local/bin/python"
)

# Destinations whose mode must be tightened after linking: "<dst>|<mode>".
# chmod follows the symlink, so this sets the mode of the file IN THE REPO —
# which is the pre-existing behavior for ssh/config and is intentional.
DOTFILES_MODES=(
  ".ssh/config|600"
)

# Real copies into the Windows user profile. Windows cannot consume WSL
# symlinks, so install.sh deploys these with backup-before-replace semantics and
# manifest_check reports byte drift. Destinations are Windows-home-relative.
DOTFILES_COPIES=(
  "windows/.wslconfig|.wslconfig"
  "windows/wezterm.lua|.wezterm.lua"
  # vast.ai hops for native Windows shells: each execs the WSL wrapper through
  # `wsl.exe -e`; the venv, credential chain and guards stay in WSL. The sh
  # twins serve Git Bash (Claude Code's Bash tool), the .cmd twins cmd/PowerShell.
  "windows/bin/vastai|.local/bin/vastai"
  "windows/bin/vastai.cmd|.local/bin/vastai.cmd"
  "windows/bin/vast-ssh|.local/bin/vast-ssh"
  "windows/bin/vast-ssh.cmd|.local/bin/vast-ssh.cmd"
)

# The harness tree: the directories and files that sit at the repo root because
# the root mirrors ~/.claude (the former mirror directory, flattened 2026-10).
# sync.sh installs them under ~/.claude or reads them in place, and harness-doctor
# §10 checks those links; manifest_check only counts the entries as covered (§10c)
# and skips live links that point into them (scan c). skills-stack is linked only by
# ./setup, one link per skill into ~/.claude/skills, the way it links the pack under
# plugins/hov-stack/skills; sync.sh leaves both alone. config/ is deliberately
# absent: it holds the harness's policy files beside the tool configs that
# DOTFILES_LINKS installs, so it stays a link source and its live links stay checked.
DOTFILES_HARNESS=(
  CLAUDE.md
  HARNESS.md
  agents
  bin
  claude-env.sh
  codex-skills.txt
  commands
  harness
  hooks
  keybindings.json
  managed-settings.json
  memory-dream.json
  memory-filename-allowlist.txt
  mods
  plugins
  retired-skills.txt
  scripts
  settings.json
  skills
  skills-patches
  skills-stack
  statusline-stack
  sync.sh
  systemd
  systemd-system
  tests
  windows-stub
  workflows
)

# Top-level directories that own their own installer. install.sh invokes these
# in an explicit, hand-ordered sequence — DCG must land before anything that
# references it, and the Pi DCG doctor must run after the harnesses/pi links
# exist. That ordering is security-relevant, so it stays imperative in install.sh
# and is NOT driven from this list. Named here only so §10c can count them as
# covered. harnesses/ holds the codex, fx, pi and pi-lens harnesses: codex and fx
# carry their own sync scripts; pi and pi-lens are DOTFILES_LINKS sources above.
DOTFILES_TOPICS=(
  dcg
  harnesses
  windows
)

# Top-level entries that are deliberately repo-only and install nowhere.
# Both consumers enumerate via `git ls-files`, so untracked local scratch (.claude/worktrees,
# .pytest_cache, .pi) never reaches this list and neither does .git — only repo content does.
DOTFILES_UNLINKED=(
  .claude-plugin   # marketplace manifest; joins at the flip, links nowhere
  release          # marketplace release tooling; joins at the flip, links nowhere
  .compound-engineering  # config.yaml for the compound-engineering plugin; read
                         # in place from the repo root (git rev-parse
                         # --show-toplevel); links nowhere. refs #1345
  .github          # CI config
  .gitignore       # governs this repo, not $HOME (.gitignore_global is the linked one)
  .gitleaks.toml   # gitleaks config for the CI secret scan; read in place
  .public-safety-allow   # exceptions the public-safety scan grants, each with its reason; read in place
  .public-safety-repos   # the public repositories the scan's private-repo shape allows; read in place
  CONCEPTS.md      # shared domain vocabulary for this repo; read in place, links nowhere
  CONTRIBUTING.md  # contributor guide; read in place
  LICENSE
  NOTICE.md        # third-party attributions; read in place
  README.md
  SECURITY.md
  STRATEGY.md
  docs
  git             # config.shared is referenced IN PLACE by ~/.gitconfig include.path
                  # (git-setup.sh registers it once); nothing to link. §10c(e) verifies
                  # the splice resolves.
  git-setup.sh     # registers the include.path bootstrap; idempotent, run by hand
  install.sh
  hosts.tsv        # host -> role table. Read in place by lib/profile.sh; links
                   # nowhere. Deliberately NOT a $HOME dotfile: a machine that
                   # declared its own role locally would be config nothing owns,
                   # the class this manifest exists to make detectable.
  lib
  setup            # the public installer: links the harness tree into ~/.claude; run by hand
)
