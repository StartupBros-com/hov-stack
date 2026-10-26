#!/usr/bin/env bash
# update-skills.sh — weekly refresh of `skills`-CLI-installed skill packs (e.g. mattpocock/skills)
# to their latest upstream versions. Updates ONLY the curated subset already installed via
# `skills add` — it does NOT re-add unselected skills, so it preserves your curation.
# Scheduled by skills-update.timer (Sunday 04:30); inspect with `journalctl -u skills-update.service`.
# Manual run: ~/.local/bin/update-skills.sh
#
# node/npx are mise-managed, so resolve them robustly (the service has no interactive shell activation).
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

if command -v mise >/dev/null 2>&1; then
  exec mise exec -- npx -y skills@latest update -g
fi

# Fallback: newest mise-installed node bin on PATH
NODE_BIN="$(ls -d "$HOME"/.local/share/mise/installs/node/*/bin 2>/dev/null | sort -V | tail -1)"
exec env PATH="${NODE_BIN}:$PATH" npx -y skills@latest update -g
