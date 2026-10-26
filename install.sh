#!/usr/bin/bash
# Dotfiles installer — creates symlinks from ~ into this repo.
#
# What lives where:
#   lib/manifest.sh  the link set (single source of truth; harness-doctor §10c verifies it)
#   lib/link.sh      link_file(), the one chokepoint that backs up before it replaces
#   this file        the hand-ordered sequence of sub-installers, which is security-relevant
#                    and deliberately NOT data-driven (DCG must land before anything that
#                    references it; the Pi DCG doctor must run after the harnesses/pi links exist)
#
# Idempotent: a second consecutive run prints almost nothing and creates no backup directory.

set -e

# Overridable so the test suite can exercise the real code against a temp tree.
# Production callers pass neither and get the canonical locations.
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES_HOME="${DOTFILES_HOME:-$HOME}"
cd "$DOTFILES"

# shellcheck source=lib/manifest.sh
. "$DOTFILES/lib/manifest.sh"
# shellcheck source=lib/link.sh
. "$DOTFILES/lib/link.sh"
# shellcheck source=lib/windows.sh
. "$DOTFILES/lib/windows.sh"

# Preflight: every external command a full install needs, checked in ONE pass.
#
# Defect this closes (observed 2026-08-27, bootstrapping satellite-host): install.sh
# is `set -e`, so it aborted at the first missing DCG verifier -- then cosign --
# with no indication that anything else was also missing, or that a verifier is a
# dotfiles prerequisite at all. The operator then fixes one tool, re-runs, and
# hits the next. Report the whole set at once, with a fix.
#
# Minisign is the mandatory verifier for the current pinned release; cosign is
# conditional inside dcg/install.sh, for a pin that turns Sigstore verification on.
preflight() {
    local missing=() c
    # cosign is absent here on purpose: dcg/install.sh needs it only when the
    # pin sets DCG_SIGSTORE_BUNDLE=1, and the current pin does not (its bundle
    # fails verification; see dcg/common.sh). minisign is the mandatory verifier.
    for c in git curl tar xz jq rsync sha256sum minisign python3 node; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    echo "install.sh: missing required commands: ${missing[*]}" >&2
    echo >&2
    if command -v mise >/dev/null 2>&1; then
        echo "  Most are declared in config/mise/config.toml. Install them with:" >&2
        echo "      mise install" >&2
    else
        echo "  mise is not installed; see https://mise.jdx.dev  (then: mise install)" >&2
    fi
    echo "  minisign verifies the pinned dcg release; the install refuses without it." >&2
    echo >&2
    echo "  Re-run ./install.sh once they resolve." >&2
    return 1
}
preflight

echo "Installing dotfiles..."

# Install the pinned, provenance-verified DCG binary before any agent config
# begins referencing it. Agent hook composition remains owned by this repo.
/usr/bin/bash "$DOTFILES/dcg/install.sh"
echo "  Installed destructive-command guard"
/usr/bin/bash "$DOTFILES/dcg/sync.sh" install
echo "  Installed DCG exact-command allowlist"

# Every $HOME symlink this repo owns, in one manifest-driven pass. A destination
# holding a real file or directory is MOVED to ~/backups/dotfiles-adopt-<ts>/,
# never deleted — see lib/link.sh for the defect that guarantee exists to prevent.
install_manifest_links "$DOTFILES" "$DOTFILES_HOME"
echo "  Linked $(( ${#DOTFILES_ROOT_FILES[@]} + ${#DOTFILES_LINKS[@]} )) manifest paths"

# The Pi doctor asserts LIVE-MACHINE wiring (it greps ~/SITES/pi-subagents source
# and pins absolute home paths in checked-in config), so it has no meaning on a CI
# runner. Skip must be explicit and logged — never auto-detected, which would
# also mask a genuinely broken box.
if [ "${INSTALL_SKIP_PI_DOCTOR:-0}" = 1 ]; then
    echo "  Skipped Pi parent/child DCG doctor (INSTALL_SKIP_PI_DOCTOR=1)"
else
    /usr/bin/bash "$DOTFILES_HOME/.pi/agent/bin/pi-dcg-doctor"
    echo "  Verified Pi parent/child DCG wiring"
fi

# Install Claude Code harness — symlink stable parts, reconcile the WhatsApp
# effect gate, then deploy the units. Credentials remain host-local and are
# never restored.
HOME="$DOTFILES_HOME" /usr/bin/bash "$DOTFILES/sync.sh" install
echo "  Installed harness"

# Manage only Codex's stable hooks file. Runtime config and hook trust remain
# owned by Codex; review the new command hook with /hooks in a fresh session.
/usr/bin/bash "$DOTFILES/harnesses/codex/sync.sh" install
echo "  Installed harnesses/codex hooks (trust review still required)"

# Codex App runs on Windows, but the canonical skill sources stay in WSL.
# Install the curated links/alias caches without importing plugin sprawl.
if /usr/bin/bash "$DOTFILES/windows/sync-claude-skills-to-codex.sh"; then
    echo "  Synced Codex skills from the WSL Claude harness"
else
    echo "  WARN: Codex skill bridge is incomplete; rerun ~/dotfiles/windows/sync-claude-skills-to-codex.sh after restoring skills/plugins" >&2
fi

# fx has no plugin system of its own. Bridge Claude Code plugin skills
# (compound-engineering, pro-gate) into ~/.fx/skills/ by resolving the current
# user-scope version from installed_plugins.json and rsync-copying each skill
# (fx does not follow symlinks for skill discovery). Also seed ~/.fx/settings.json
# with the context_limits needed for all bridged skills to surface in the catalog.
# Guarded like the codex bridge above: this script runs under `set -e`, and an
# unguarded call means one failed skill copy (including the bridge's own
# deliberate refusal to overwrite a non-bridge-managed dir) aborts the whole
# installer mid-run — repeatably, since the collision doesn't self-clear.
if /usr/bin/bash "$DOTFILES/harnesses/fx/sync.sh" install; then
    echo "  Installed harnesses/fx harness (skill bridge + settings seed)"
else
    echo "  WARN: fx harness install incomplete; fix the skills reported above, then rerun ~/dotfiles/harnesses/fx/sync.sh install" >&2
fi

# Set up gitconfig (not symlinked - contains user-specific data)
echo ""
echo "Run these commands to configure git:"
echo "  git config --global user.name \"Your Name\""
echo "  git config --global user.email \"you@example.com\""
echo ""
echo "Then run: ~/dotfiles/git-setup.sh"

# Windows configs are real copies, not symlinks: Windows cannot read WSL
# symlinks. One manifest drives both deployment and the read-only drift check.
if WINDOWS_HOME=$(dotfiles_windows_home); then
    WINDOWS_BACKUP_ROOT="$DOTFILES_HOME/backups/dotfiles-adopt-$(date +%Y%m%d-%H%M%S)"
    install_windows_copies "$DOTFILES" "$WINDOWS_HOME" "$WINDOWS_BACKUP_ROOT"
    echo "  Windows configs in sync"

    echo ""
    echo "To install Windows Terminal settings:"
    echo "  cp ~/dotfiles/windows/windows-terminal.json \"\$LOCALAPPDATA/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json\""
fi

echo ""
echo "Done! Run 'exec bash' to reload."
