#!/usr/bin/env bash

# Manage only DCG's user allowlist. The pinned binary is installed separately.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REF=$HERE/allowlist.toml
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
LIVE=$CONFIG_HOME/dcg/allowlist.toml
DCG_BIN=${DCG_BIN:-$HOME/.local/bin/dcg}
MODE=${1:-check}

validate_reference() {
  local tmp status=0
  [ -x "$DCG_BIN" ] || {
    echo "DCG allowlist sync requires an executable binary at $DCG_BIN" >&2
    return 1
  }
  tmp=$(mktemp -d) || return 1
  mkdir -p "$tmp/config/dcg" || status=$?
  if [ "$status" -eq 0 ]; then
    cp "$REF" "$tmp/config/dcg/allowlist.toml" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    env -i HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" PATH=/usr/bin:/bin \
      "$DCG_BIN" allowlist validate --user --strict --quiet --no-color || status=$?
  fi
  case "$tmp" in
    /tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf "$tmp" ;;
    *) echo "refusing unexpected validation cleanup path: $tmp" >&2; status=1 ;;
  esac
  return "$status"
}

check() {
  validate_reference || return 1
  [ -f "$LIVE" ] || {
    echo "DRIFT: DCG user allowlist is missing: $LIVE"
    return 1
  }
  cmp -s "$REF" "$LIVE" || {
    echo "DRIFT: $LIVE differs from canonical dcg/allowlist.toml"
    return 1
  }
  echo "DCG allowlist in sync"
}

install_allowlist() {
  local tmp backup
  validate_reference || return 1
  mkdir -p "$(dirname "$LIVE")" || return 1

  if [ -f "$LIVE" ] && cmp -s "$REF" "$LIVE"; then
    echo "DCG allowlist already in sync"
    return 0
  fi
  if [ -e "$LIVE" ] && [ ! -f "$LIVE" ]; then
    echo "$LIVE exists but is not a regular file; refusing to replace it" >&2
    return 1
  fi
  if [ -e "$LIVE" ]; then
    backup=$(mktemp -d "$(dirname "$LIVE")/backup-allowlist-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    cp -a "$LIVE" "$backup/allowlist.toml" || return 1
    echo "Backed up existing DCG allowlist to $backup/allowlist.toml"
  fi

  tmp=$(mktemp "$(dirname "$LIVE")/.allowlist.toml.XXXXXX") || return 1
  install -m 0600 "$REF" "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$LIVE" || {
    rm -f "$tmp"
    return 1
  }
  echo "Installed canonical DCG allowlist at $LIVE"
}

case "$MODE" in
  check) check ;;
  install) install_allowlist ;;
  *) echo "usage: sync.sh check|install" >&2; exit 2 ;;
esac
