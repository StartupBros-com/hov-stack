#!/usr/bin/env bash
# tool-update.sh — verified installer for the upstream binaries whose OWN installers fail open.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — tools-auto-update.timer (daily), and the operator by hand.
#   gate        — sha256 against the release's published checksum, fail-closed, plus a
#                 post-install smoke check that rolls back if the new binary won't run.
#   defect      — OBSERVED (2026-08-07): every vendor installer here fails OPEN.
#                 xf's resolve_version() falls back to VERSION=v0.1.0 with a `warn` when
#                 it cannot reach the API, and its checksum step sets CHECKSUM=SKIP and
#                 proceeds when SHA256SUMS is unfetchable — one rate-limited call yields
#                 an UNVERIFIED install of the first release ever. ubs ships a minisign
#                 signature and defines fetch_checksum_bundle()/verify_download_checksum()
#                 that NOTHING calls, then fetches its payload from raw main. ru and
#                 csctf both log "Proceeding without verification." and continue. tru
#                 verifies nothing and falls back to `cargo install --git` off unpinned
#                 HEAD. Four separate upstreams, one shared failure mode.
#   delete-when — upstream installers fail closed and we trust them again.
#
#   NOTE 2026-09-21: `ubs` was dropped from the TOOLS table below and uninstalled
#   (dotfiles docs/vets/2026-09-20-ubs-harness-vet.md — 0 true positives across
#   ~24 critical + 24 warning samples and 70+ PR-evaluations). The defect narrative
#   above still names it because that is the 2026-08-07 observation as recorded;
#   it is history, not a claim that ubs is still covered here.
#
#   NOTE 2026-10-01: `tru` was dropped from the TOOLS table below and uninstalled.
#   Its only consumer was cass-memory (`cm`), retired after a retest of cm 0.4.0
#   found no recall gain over the 2026-07 memory face-off. Same history caveat
#   as ubs: the narrative above still names tru as observed on 2026-08-07.
#
# The insight this file is built on: the ARTIFACTS are fine — every one of these repos
# publishes a checksummed release asset (ubs even signs it). Only the installers are
# broken. So we never invoke a vendor installer or self-updater; we download the pinned
# release asset ourselves, verify it, and install it under the name WE want.
#
# NOT handled here, deliberately:
#   dcg  — has its own gated updater (dcg-update.sh) with a 65-case behavioural contract.
#          A guard needs more than a checksum; leave it there.
#   cass — deliberately tracks upstream MAIN, ahead of its newest tag, because the
#          nightly reindex needs the unreleased large-archive fixes. Installing a tagged
#          release would DOWNGRADE it. Hash-pinned in tool-staleness.sh instead.
#
# Usage:  tool-update.sh [tool...]      report only (default)
#         DRY_RUN=0 tool-update.sh      download, verify, install, smoke-check
# Exit:   0 = all current or promoted, 1 = at least one failed (nothing left broken)

set -uo pipefail

DRY_RUN=${DRY_RUN:-1}
BIN_DIR=${TOOL_UPDATE_BIN_DIR:-$HOME/.local/bin}
BACKUP_DIR=${TOOL_UPDATE_BACKUP_DIR:-$HOME/.local/lib/tool-backups}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

say() { [ -x "$HERE/notify.sh" ] && "$HERE/notify.sh" "$1" "${2:-default}" >/dev/null 2>&1; return 0; }

for t in gh sha256sum tar; do
  command -v "$t" >/dev/null 2>&1 || { echo "tool-update: missing $t"; exit 1; }
done

# name|repo|asset|checksum-asset|kind|install-as
#
# kind: raw = the asset IS the executable; targz / tarxz = extract, then take the file
# named in the "member" position (which is NOT always the install-as name; toon_rust's
# `toon`, installed as `tru` until 2026-10-01, was the case that needed it).
# TOOL_UPDATE_TABLE overrides this for tests. Production never sets it — a table that
# could be swapped from the environment at runtime is a place to hide an install source,
# so it exists solely so tool-update.test.sh can drive fake releases past the real logic.
TOOLS=${TOOL_UPDATE_TABLE:-'
xf|Dicklesworthstone/xf|xf-x86_64-unknown-linux-gnu.tar.gz|SHA256SUMS|targz|xf|xf
csctf|Dicklesworthstone/chat_shared_conversation_to_file|csctf-linux-x64|csctf-linux-x64.sha256|raw|csctf-linux-x64|csctf
ru|Dicklesworthstone/repo_updater|ru|checksums.txt|raw|ru|ru
'}

want=("$@")
selected() {
  [ ${#want[@]} -eq 0 ] && return 0
  local w; for w in "${want[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1
}

# Resolve a tool by ABSOLUTE path under $BIN_DIR first, PATH only as a fallback.
#
# `command -v` alone is wrong here and failed silently in production: a systemd user
# service gets PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin with
# NO ~/.local/bin, which is where every one of these tools lives. The 2026-08-07 first
# live run reported "not installed — skipped" for all five and exited 0 — a green
# service that did nothing, which is the same failure shape as the cosmetic dcg promote
# this suite already had. The unit now also sets PATH, but resolving explicitly means
# the script is correct even if that is edited away.
tool_path() {
  [ -x "$BIN_DIR/$1" ] && { printf '%s' "$BIN_DIR/$1"; return 0; }
  command -v "$1" 2>/dev/null
}

installed_ver() {
  local p; p=$(tool_path "$1") || return 1
  [ -n "$p" ] || return 1
  timeout 20 "$p" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Pull the hash for $2 out of checksum file $1. Handles both shapes upstream uses:
# a sha256sum-format table (`<hash>  <name>`), and a bare single-hash sidecar.
hash_for() {
  local file=$1 asset=$2 h
  h=$(grep -E "[ *]${asset}\$" "$file" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -z "$h" ]; then
    # Bare sidecar: exactly one field on the only line.
    if [ "$(wc -w <"$file")" = "1" ]; then h=$(tr -d '[:space:]' <"$file"); fi
  fi
  printf '%s' "$h"
}

# reap_tool_backups() -- keep the newest two backups per tool, by mtime. These
# tools do not share a version scheme (xf/csctf/ru each carry their own
# upstream's numbering), so recency by mtime is the only ordering that holds
# across all of them (a sort -V over tags would not hold across them).
# Called once after the tools loop, unconditionally: one tool's checksum
# failure or missing binary must not skip rotation for the others
# (dotfiles#1279). Live host state before this: 12 files / 184MB, six of them
# ubs-*, and nothing ever read a prior run's backup but that run's own
# rollback at :195-198.
reap_tool_backups() {
  [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ] || return 0

  local tool f count
  for tool in "$@"; do
    [ -n "$tool" ] || continue
    count=0
    for f in $(ls -1t "$BACKUP_DIR/$tool"-* 2>/dev/null); do
      count=$((count + 1))
      [ "$count" -le 2 ] && continue
      case $f in "$BACKUP_DIR"/*) ;; *) continue ;; esac   # must live under $BACKUP_DIR
      [ -f "$f" ] || continue
      if [ "${DRY_RUN:-1}" != 0 ]; then
        echo "  would reap $(basename "$f")"
      else
        rm -f -- "$f" && echo "  reaped $(basename "$f")"
      fi
    done
  done
  return 0
}

rc=0
promoted=()
skipped=0
seen=0
all_as=()

while IFS='|' read -r name repo asset ck kind member as; do
  [ -z "$name" ] && continue
  selected "$name" || continue
  all_as+=("$as")

  cur=$(installed_ver "$as")
  seen=$((seen + 1))
  [ -z "${cur:-}" ] && { echo "$as: not installed — skipped"; skipped=$((skipped + 1)); continue; }

  tag=$(timeout 30 gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null)
  if [ -z "${tag:-}" ]; then
    echo "$as: $cur (latest unknown — offline); leaving in place"
    continue
  fi
  latest=${tag##* }; latest=${latest#[vV]}

  if [ "$cur" = "$latest" ]; then echo "$as: $cur — current"; continue; fi
  if [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)" = "$cur" ]; then
    echo "$as: $cur (newest tag $latest) — ahead of release, leaving alone"
    continue
  fi

  if [ "$DRY_RUN" != "0" ]; then
    echo "WARN $as behind: $cur -> $latest (promote: DRY_RUN=0 $HOME/.claude/scripts/tool-update.sh $name)"
    continue
  fi

  echo "$as: $cur -> $latest"
  tmp=$(mktemp -d) || { rc=1; continue; }

  # --- 1. fetch, pinned to the resolved tag -----------------------------------
  # Pinned on purpose: an unpinned "latest" download is exactly the path where xf's
  # installer substitutes v0.1.0 when resolution fails. Here, resolution already
  # succeeded above or we never got here.
  if ! timeout 300 gh release download "$tag" --repo "$repo" --dir "$tmp" \
        --pattern "$asset" --pattern "$ck" >/dev/null 2>&1; then
    echo "  FAIL: could not download $asset / $ck from $tag"
    say "$as update FAILED: download error ($tag)" input; rc=1; rm -rf "$tmp"; continue
  fi

  # --- 2. verify, fail closed --------------------------------------------------
  # The whole reason this file exists. Every upstream installer here treats a missing
  # or unreadable checksum as "carry on"; a missing checksum is a HARD failure.
  want_hash=$(hash_for "$tmp/$ck" "$asset")
  if [ -z "$want_hash" ]; then
    echo "  FAIL: no checksum for $asset in $ck — refusing to install unverified"
    say "$as update REFUSED: no checksum in $ck" input; rc=1; rm -rf "$tmp"; continue
  fi
  got_hash=$(sha256sum "$tmp/$asset" | awk '{print $1}')
  if [ "$want_hash" != "$got_hash" ]; then
    echo "  FAIL: checksum mismatch for $asset"
    echo "        expected $want_hash"
    echo "        got      $got_hash"
    say "$as update REFUSED: CHECKSUM MISMATCH — possible tampering" input; rc=1; rm -rf "$tmp"; continue
  fi
  echo "  checksum verified ($got_hash)"

  # --- 3. extract --------------------------------------------------------------
  case $kind in
    raw)   payload=$tmp/$asset ;;
    targz) tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null; payload=$(find "$tmp" -type f -name "$member" | head -1) ;;
    tarxz) tar -xJf "$tmp/$asset" -C "$tmp" 2>/dev/null; payload=$(find "$tmp" -type f -name "$member" | head -1) ;;
    *)     echo "  FAIL: unknown kind $kind"; rc=1; rm -rf "$tmp"; continue ;;
  esac
  if [ -z "${payload:-}" ] || [ ! -f "$payload" ]; then
    echo "  FAIL: could not locate '$member' in $asset"
    say "$as update FAILED: payload '$member' not found in archive" input; rc=1; rm -rf "$tmp"; continue
  fi

  # --- 4. back up, install, smoke-check, roll back on failure -------------------
  # ru and csctf overwrite a live script with no backup and no rollback in their own
  # installers. Ours keeps the outgoing binary before writing, and restores it if the
  # incoming one cannot even report its own version.
  mkdir -p "$BACKUP_DIR"
  live=$(tool_path "$as")
  backup=$BACKUP_DIR/$as-$cur
  cp -p "$live" "$backup" 2>/dev/null || { echo "  FAIL: could not back up $live"; rc=1; rm -rf "$tmp"; continue; }

  if ! install -m 0755 "$payload" "$BIN_DIR/$as" 2>/dev/null; then
    echo "  FAIL: could not install to $BIN_DIR/$as"
    say "$as update FAILED: install error" input; rc=1; rm -rf "$tmp"; continue
  fi

  new=$(installed_ver "$as")
  if [ "$new" != "$latest" ]; then
    # Covers both "won't execute at all" and "is not the version we just verified".
    # A tool may report a crate name rather than the tag (tru did, until 2026-10-01).
    if [ -z "${new:-}" ]; then
      echo "  SMOKE FAILED: $as does not run after install — rolling back to $cur"
      cp -p "$backup" "$BIN_DIR/$as" && echo "  rolled back to $cur"
      say "$as update ROLLED BACK: new binary would not run" input; rc=1; rm -rf "$tmp"; continue
    fi
    echo "  note: reports $new (expected $latest) — kept; version string differs from tag"
  fi

  echo "  INSTALLED $as $cur -> $new (backup: $backup)"
  promoted+=("$as $cur->$new")
  rm -rf "$tmp"
done <<<"$TOOLS"

# Runs regardless of $rc and regardless of the all-tools-missing check below:
# rotation is independent of whether any install this run actually succeeded.
reap_tool_backups "${all_as[@]}"

if [ ${#promoted[@]} -gt 0 ]; then
  say "tools auto-updated: ${promoted[*]}" complete
fi

# Every tool missing means the environment is wrong, not that the box has no tools.
# Exiting 0 here is how the first live systemd run looked healthy while doing nothing.
if [ "$seen" -gt 0 ] && [ "$skipped" -eq "$seen" ]; then
  echo "FAIL: none of the $seen tools were found under $BIN_DIR or on PATH."
  echo "      PATH=$PATH"
  echo "      This is an environment fault (systemd units get a minimal PATH), not an"
  echo "      empty tool list — refusing to report success."
  say "tool-update found NO tools — PATH/environment fault, nothing was checked" input
  exit 1
fi
exit $rc
