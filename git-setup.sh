#!/bin/bash
# Git configuration bootstrap — registers the tracked config, sets nothing else.
#
# All shared settings live in git/config.shared (tracked, reviewed, drift-checked
# by harness-doctor §10c via lib/check.sh (e)). This script only splices that file
# into ~/.gitconfig
# via include.path and reports what remains genuinely machine-local. Re-running
# is always safe; the include is registered exactly once.
#
# Why not imperative `git config --global` lines for everything (the previous
# shape): run-once scripts drift. Observed (dotfiles#210): live config carried
# init.defaultbranch=master while this script asserted main — for months,
# silently. A tracked include self-heals on every `git pull` instead.

set -euo pipefail

SHARED="${DOTFILES:-$HOME/dotfiles}/git/config.shared"

[ -f "$SHARED" ] || { echo "missing $SHARED — run from a machine with the dotfiles repo at ~/dotfiles (or set DOTFILES)" >&2; exit 1; }

echo "Configuring git..."

# Register the include once. Appended at the END of ~/.gitconfig so the shared
# file overrides stale machine-local values; deliberate per-machine overrides
# belong below the include line.
if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$SHARED"; then
    git config --global include.path "$SHARED"
    echo "  Registered include.path -> $SHARED"
fi

# Prove the splice took. A wrong path in include.path is SILENT (git ignores
# missing includes by design), so assert a sentinel value actually resolves —
# this is the planted-negative guard from the #210 work spec.
resolved=$(git config --global --includes --get diff.algorithm || true)
if [ "$resolved" != "histogram" ]; then
    echo "  ERROR: include.path registered but git/config.shared is not resolving (got diff.algorithm='$resolved')" >&2
    exit 1
fi
echo "  Shared config resolving (diff.algorithm=$resolved)"

# Machine-local remainder: identity + credentials. Report, never guess.
git config --global user.name  >/dev/null 2>&1 || echo '  TODO: git config --global user.name  "Your Name"'
git config --global user.email >/dev/null 2>&1 || echo '  TODO: git config --global user.email "you@example.com"'

echo "Git configured."
