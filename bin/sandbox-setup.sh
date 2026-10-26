#!/usr/bin/env bash
# Phase 2: install the OS sandbox backend and turn it on.
# Run this yourself (it needs sudo, which the agent session can't do):
#     bash ~/.claude/bin/sandbox-setup.sh
#
# After this completes, the OS sandbox (bubblewrap) confines Bash writes to the
# cwd and routes network through the allowlist in ~/.claude/settings.json.
# Combined with sandbox auto-allow mode, most Bash commands then run with ZERO
# permission prompts because the OS boundary contains them (~84% fewer prompts).
set -euo pipefail

echo "==> Installing bubblewrap + socat (Linux/WSL2 sandbox backend)…"
sudo apt-get update -qq
sudo apt-get install -y bubblewrap socat

echo "==> Installing optional unix-socket seccomp filter…"
npm install -g @anthropic-ai/sandbox-runtime || \
  echo "   (sandbox-runtime optional; skipping on failure)"

echo "==> Verifying bubblewrap can create a user namespace on this WSL2 kernel…"
if bwrap --ro-bind / / --unshare-all true 2>/dev/null; then
  echo "   bubblewrap OK."
else
  echo "   WARNING: bwrap could not unshare namespaces. On Ubuntu 24.04 you may"
  echo "   need an AppArmor profile for /usr/bin/bwrap. Check:"
  echo "     sysctl kernel.apparmor_restrict_unprivileged_userns"
  echo "   (was absent on your box at setup time, so this is unlikely.)"
fi

echo
echo "==> Backend installed. To turn the sandbox ON, set \"enabled\": true under"
echo "    the \"sandbox\" block in ~/.claude/settings.json, OR flip it per-project"
echo "    first with the /sandbox command (recommended: test in ONE project,"
echo "    verify npm/git/curl still work, then promote globally)."
echo
echo "    Recommended first test:"
echo "      cd ~/SITES/<your-project> && claude"
echo "      /sandbox            # enable + choose 'auto-allow' mode"
echo "      then run a build/test and confirm no breakage."
