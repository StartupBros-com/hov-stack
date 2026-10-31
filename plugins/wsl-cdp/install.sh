#!/usr/bin/env bash
# wsl-cdp installer
#
#   curl -fsSL "https://raw.githubusercontent.com/StartupBros-com/hov-stack/main/plugins/wsl-cdp/install.sh?$(date +%s)" | bash
#
# Flags (pass after `bash -s --`):
#   --force      skip the "already installed" note (install always overwrites in place)
#   --quiet      errors only
#   --uninstall  remove installed files and symlink
# Env: WSL_CDP_REF=<branch|tag|sha> (default main; release tags look like wsl-cdp--v0.3.6), HTTPS_PROXY/HTTP_PROXY honored.
#
# What it does: resolves the current commit of the repo, downloads the four
# scripts pinned to that commit (so a mid-install push can't tear the set),
# installs them to ~/.local/share/wsl-cdp, symlinks wsl-cdp into ~/.local/bin.
# No checksum/signature verification yet: there are no signed releases to
# verify against — the commit pin is a consistency guarantee, not authenticity.
set -euo pipefail
umask 022

OWNER_REPO="StartupBros-com/hov-stack"
PLUGIN_DIR="plugins/wsl-cdp"
REF="${WSL_CDP_REF:-main}"
DEST="$HOME/.local/share/wsl-cdp"
BIN="$HOME/.local/bin"
FILES=(wsl-cdp wsl-cdp-forward.py wsl-cdp-drive.mjs wsl-cdp-setup.ps1)
FORCE=0 QUIET=0 UNINSTALL=0
for a in "$@"; do case "$a" in
  --force) FORCE=1 ;; --quiet) QUIET=1 ;; --uninstall) UNINSTALL=1 ;;
  *) echo "unknown flag: $a (see header for flags)" >&2; exit 2 ;;
esac; done

_log() { [ "$QUIET" = 1 ] && [ "$1" != err ] && return 0
  local c=39; case "$1" in ok) c=42 ;; warn) c=214 ;; err) c=196 ;; esac
  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then printf 'wsl-cdp: %s\n' "${*:2}"
  else printf '\033[38;5;%sm%s\033[0m %s\n' "$c" "wsl-cdp:" "${*:2}"; fi; }
info() { _log info "$@"; }; ok() { _log ok "$@"; }; warn() { _log warn "$@"; }; err() { _log err "$@"; }

PROXY_ARGS=()
[ -n "${HTTPS_PROXY:-}" ] && PROXY_ARGS=(--proxy "$HTTPS_PROXY")
[ -z "${HTTPS_PROXY:-}" ] && [ -n "${HTTP_PROXY:-}" ] && PROXY_ARGS=(--proxy "$HTTP_PROXY")

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$BIN/wsl-cdp"; rm -rf "$DEST"
  ok "uninstalled ($BIN/wsl-cdp symlink + $DEST removed)"
  info "Windows-side leftovers, remove in elevated PowerShell if desired:"
  info "  netsh interface portproxy delete v4tov4 listenport=9224 listenaddress=0.0.0.0"
  info "  Remove-NetFirewallRule -DisplayName 'wsl-cdp bridge*'   (wildcard: rules are port-scoped)"
  info "  and the agent profile dir %USERPROFILE%\\.wsl-cdp"
  exit 0
fi

# Preflight. WSL2 is the tool's platform, so non-WSL is a hard stop, not a warn.
grep -qi microsoft "${WSL_CDP_PROC_VERSION:-/proc/version}" 2>/dev/null || { err "this tool only makes sense inside WSL2 (Windows browser + WSL agent)"; exit 1; }
for dep in curl jq python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "missing dependency: $dep"; exit 1; }
done
nv="$(node --version 2>/dev/null | tr -dc '0-9.' | cut -d. -f1 || true)"
[ "${nv:-0}" -ge 22 ] 2>/dev/null || warn "node >=22 not found: eval/text/screenshot verbs will be unavailable (bridge itself works)"
mkdir -p "$DEST" "$BIN" || { err "cannot write $DEST / $BIN"; exit 1; }
if [ -e "$DEST/wsl-cdp" ] && [ "$FORCE" != 1 ]; then
  info "already installed at $DEST — reinstalling from $REF (use --force to silence this note)"
fi

# Local mode: when the scripts sit beside this installer (git clone or Claude
# Code plugin cache), install from them directly — no network, no tear risk.
# Piped `curl | bash` has no usable BASH_SOURCE, so it falls through to download.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || true)"
LOCAL=1
for f in "${FILES[@]}"; do [ -f "$SRC_DIR/$f" ] || { LOCAL=0; break; }; done

if [ "$LOCAL" = 1 ]; then
  info "installing from local files in $SRC_DIR"
  INSTALL_SOURCE="$SRC_DIR"
else
  TMP="$(mktemp -d)"
  cleanup() { rm -rf "$TMP"; }
  trap cleanup EXIT

  # Pin to a single commit so all four files come from one tree.
  # `|| true` is load-bearing: under `set -euo pipefail` with pipefail, a failed
  # `curl -f` (rate limit / offline) makes the whole substitution non-zero and
  # would abort the script HERE — before the fallback below could ever run.
  SHA="$(curl -fsSL --connect-timeout 10 "${PROXY_ARGS[@]}" \
    "https://api.github.com/repos/$OWNER_REPO/commits/$REF" 2>/dev/null \
    | jq -r '.sha // empty')" || true
  [ -n "$SHA" ] || { warn "could not resolve $REF via GitHub API (rate limit?); falling back to ref-addressed downloads"; SHA="$REF"; }
  info "installing $OWNER_REPO@${SHA:0:12}"

  for f in "${FILES[@]}"; do
    curl -fsSL "${PROXY_ARGS[@]}" \
      "https://raw.githubusercontent.com/$OWNER_REPO/$SHA/$PLUGIN_DIR/$f" -o "$TMP/$f" \
      || { err "download failed: $f"; exit 1; }
    [ -s "$TMP/$f" ] || { err "downloaded $f is empty"; exit 1; }
  done
  INSTALL_SOURCE="$TMP"
fi

for f in "${FILES[@]}"; do install -m 0755 "$INSTALL_SOURCE/$f" "$DEST/$f"; done
ln -sf "$DEST/wsl-cdp" "$BIN/wsl-cdp"
ok "installed to $DEST (entry: $BIN/wsl-cdp)"

case ":$PATH:" in
  *":$BIN:"*) : ;;
  *) warn "$BIN is not on your PATH — add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

info "next: wsl-cdp setup-windows   (once, elevated UAC)"
info "then: wsl-cdp up && wsl-cdp doctor"
info "uninstall: curl -fsSL https://raw.githubusercontent.com/$OWNER_REPO/main/$PLUGIN_DIR/install.sh | bash -s -- --uninstall"
