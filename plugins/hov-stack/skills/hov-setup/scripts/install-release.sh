#!/usr/bin/env bash
# install-release.sh — install a fixed, checked release of gh, uv, cass or jsm.
#
# Downloads one pinned release archive, checks its sha256 against the value pinned in
# this file, and installs the program(s) into $HOV_SETUP_BIN_DIR (default ~/.local/bin).
# It never calls sudo, never runs a vendor installer, and never edits a shell startup file.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — /hov-setup's gh, uv, cass and jeffreys-skills sections, run after the
#                 user says yes.
#   gate        — the sha256 pinned in this file, computed from the downloaded bytes on
#                 2026-11-03 and matching each maker's published checksum, fail-closed;
#                 plus a post-install `--version` check that removes what this run
#                 installed if it fails.
#   defect      — vendor installers fail open or edit shell startup files. tool-update.sh's
#                 header records four that skip verification; jsm's installer appends a PATH
#                 line to the shell's startup file by default; brew is absent on a fresh Mac.
#   delete-when — every one of these makers ships an installer that verifies and never
#                 edits startup files, or hov-stack stops offering them.
#
# Why this is not scripts/tool-update.sh: that script needs gh (this one installs gh), keeps
# its table test-only and its tool list is the author's own machine, and it leaves cass out on
# purpose because the author's machine tracks cass's main branch. A new user gets the tagged
# release, which is what the table below pins.
#
# Usage:  install-release.sh <tool> [--force]     tool: gh | uv | cass | jsm
# Exit:   0 installed; 1 download, checksum, extract, install or --version check failed
#         (nothing this run installed is left behind); 2 bad usage; 3 unknown tool, or no
#         release for this platform; 4 a target file already exists (nothing changed;
#         --force replaces it)
# Env:    HOV_SETUP_BIN_DIR        destination directory (default ~/.local/bin)
#         HOV_SETUP_PLATFORM       test-only: darwin-arm64 | linux-x86_64 | linux-aarch64
#         HOV_SETUP_RELEASE_TABLE  test-only: replaces the table below. Production never
#                                  sets it; a table swappable from the environment is a place
#                                  to hide an install source, so it exists solely so
#                                  install-release.test.mjs can drive fake releases through
#                                  the real logic.
#
# Runs under macOS's /bin/bash 3.2: no associative arrays, no mapfile, no ${var,,}, and no
# expansion of a possibly-empty array under `set -u`.

set -euo pipefail
umask 022

# tool|version|platform|url|sha256|members
# members: comma-separated paths inside the archive; each is installed under its basename.
TABLE=${HOV_SETUP_RELEASE_TABLE:-'
gh|2.103.3|linux-x86_64|https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_linux_amd64.tar.gz|4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d|gh_2.103.3_linux_amd64/bin/gh
gh|2.103.3|linux-aarch64|https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_linux_arm64.tar.gz|ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63|gh_2.103.3_linux_arm64/bin/gh
gh|2.103.3|darwin-arm64|https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_macOS_arm64.zip|d700207eae9ae98fe2b89535c2c087c07823d4628c56364695a5a07ef311c062|gh_2.103.3_macOS_arm64/bin/gh
uv|0.13.7|linux-x86_64|https://github.com/astral-sh/uv/releases/download/0.13.7/uv-x86_64-unknown-linux-gnu.tar.gz|c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83|uv-x86_64-unknown-linux-gnu/uv,uv-x86_64-unknown-linux-gnu/uvx
uv|0.13.7|linux-aarch64|https://github.com/astral-sh/uv/releases/download/0.13.7/uv-aarch64-unknown-linux-gnu.tar.gz|71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc|uv-aarch64-unknown-linux-gnu/uv,uv-aarch64-unknown-linux-gnu/uvx
uv|0.13.7|darwin-arm64|https://github.com/astral-sh/uv/releases/download/0.13.7/uv-aarch64-apple-darwin.tar.gz|81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731|uv-aarch64-apple-darwin/uv,uv-aarch64-apple-darwin/uvx
cass|0.10.0|linux-x86_64|https://github.com/Dicklesworthstone/coding_agent_session_search/releases/download/v0.10.0/cass-linux-amd64.tar.gz|638ea8a8a9023c2e046bf8868392e6191218b89cf006e81af3ca205b546c4681|cass
cass|0.10.0|linux-aarch64|https://github.com/Dicklesworthstone/coding_agent_session_search/releases/download/v0.10.0/cass-linux-arm64.tar.gz|529412e7e1f85f5a2c8f5e5fda1604b65ca90ed8acd68dbf286f63384b4baf09|cass
cass|0.10.0|darwin-arm64|https://github.com/Dicklesworthstone/coding_agent_session_search/releases/download/v0.10.0/cass-darwin-arm64.tar.gz|1d922fd59b252bc3b4af63dbce5e4007c2f505ba1d6a8cec0a7280b169200580|cass
jsm|0.3.46|linux-x86_64|https://jeffreys-skills.md/api/v1/downloads/jsm/v0.3.46/jsm-x86_64-unknown-linux-musl.tar.gz|57bf04440db6e3fed7e518c9cda4b0dbdcc87ab9fc20050b86132f91be511b70|jsm
jsm|0.3.46|linux-aarch64|https://jeffreys-skills.md/api/v1/downloads/jsm/v0.3.46/jsm-aarch64-unknown-linux-gnu.tar.gz|157dcf73a67660cdac5edf7c68d857625adfce85292abc2604c2f8f6f92a211b|jsm
jsm|0.3.46|darwin-arm64|https://jeffreys-skills.md/api/v1/downloads/jsm/v0.3.46/jsm-aarch64-apple-darwin.tar.gz|6617ef809c2827307fe1e848aa94224bbf2c103739527f5b5f930e388646ed99|jsm
'}

usage() {
  echo "usage: install-release.sh <tool> [--force]   (tool: gh | uv | cass | jsm)" >&2
  exit 2
}

fail() { echo "install-release: $*" >&2; exit 1; }

tool=""
force=0
for arg in "$@"; do
  case $arg in
    --force) force=1 ;;
    -*) usage ;;
    *) [ -z "$tool" ] || usage; tool=$arg ;;
  esac
done
[ -n "$tool" ] || usage

# --- platform -----------------------------------------------------------------
if [ -n "${HOV_SETUP_PLATFORM:-}" ]; then
  platform=$HOV_SETUP_PLATFORM
else
  os=$(uname -s)
  arch=$(uname -m)
  case "$os/$arch" in
    Darwin/arm64) platform=darwin-arm64 ;;
    Linux/x86_64) platform=linux-x86_64 ;;
    Linux/aarch64 | Linux/arm64) platform=linux-aarch64 ;;
    *) platform="$os-$arch" ;;
  esac
fi

# --- table lookup --------------------------------------------------------------
tool_known=0
platforms=""
row_url=""
row_sha=""
row_members=""
while IFS="|" read -r t _ p u s m; do
  [ -n "$t" ] || continue
  [ "$t" = "$tool" ] || continue
  tool_known=1
  platforms="${platforms:+$platforms, }$p"
  if [ "$p" = "$platform" ]; then
    row_url=$u; row_sha=$s; row_members=$m
  fi
done <<EOF
$TABLE
EOF

if [ "$tool_known" -eq 0 ]; then
  echo "install-release: unknown tool '$tool' (tools: gh, uv, cass, jsm)" >&2
  exit 3
fi
if [ -z "$row_url" ]; then
  echo "install-release: $tool has no release for $platform (platforms: $platforms)" >&2
  exit 3
fi

dest=${HOV_SETUP_BIN_DIR:-$HOME/.local/bin}

# member list, one path per line; each installs under its basename
members=$(printf '%s' "$row_members" | tr ',' '\n')
first_base=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ -n "$first_base" ] || first_base=$(basename "$m")
  if [ -e "$dest/$(basename "$m")" ] || [ -L "$dest/$(basename "$m")" ]; then
    if [ "$force" -eq 0 ]; then
      echo "install-release: $dest/$(basename "$m") already exists; nothing changed (--force replaces it)" >&2
      exit 4
    fi
  fi
done <<EOF
$members
EOF
[ -n "$first_base" ] || fail "table row for $tool/$platform lists no members"

# --- helpers --------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  sha_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "neither sha256sum nor shasum is available; cannot verify the download"
fi

work=$(mktemp -d)
installed=""   # newline-separated absolute paths this run put in place
done_ok=0      # set to 1 only once the install has succeeded
tmpnames=""    # newline-separated temp files not yet moved into place
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  local f
  # A failed run leaves nothing it installed: an earlier member of a multi-member install
  # must not survive a later member's failure. done_ok is set only on the success path.
  if [ "$done_ok" -eq 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && rm -f -- "$f"
    done <<EOF
$installed
EOF
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f -- "$f"
  done <<EOF
$tmpnames
EOF
  rm -rf "$work"
}
trap cleanup EXIT

# --- download and verify (fail closed) -------------------------------------------
archive=${row_url##*/}
curl -fsSL --retry 2 --connect-timeout 15 -o "$work/$archive" "$row_url" \
  || fail "download failed: $row_url"

got=$(sha_of "$work/$archive")
if [ "$got" != "$row_sha" ]; then
  echo "install-release: checksum mismatch for $archive" >&2
  echo "  expected $row_sha" >&2
  echo "  got      $got" >&2
  exit 1
fi

# --- extract ----------------------------------------------------------------------
mkdir -p "$work/x"
case $archive in
  *.tar.gz | *.tgz) tar -xzf "$work/$archive" -C "$work/x" || fail "could not extract $archive" ;;
  *.zip)
    command -v unzip >/dev/null 2>&1 || fail "unzip is required for $archive and was not found"
    unzip -q -o "$work/$archive" -d "$work/x" || fail "could not extract $archive"
    ;;
  *) fail "unsupported archive type: $archive" ;;
esac

while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ -f "$work/x/$m" ] || fail "$m is not in $archive"
done <<EOF
$members
EOF

# --- install: temp name in dest, then rename into place ------------------------------
mkdir -p "$dest"
dest=$(cd "$dest" && pwd) || fail "cannot enter $dest"   # absolute, so installed: lines are
while IFS= read -r m; do
  [ -n "$m" ] || continue
  b=$(basename "$m")
  tmpf="$dest/.$b.hov-setup.$$"
  tmpnames="$tmpf"
  install -m 0755 "$work/x/$m" "$tmpf" || fail "could not write $tmpf"
  mv -f "$tmpf" "$dest/$b" || fail "could not move $b into $dest"
  tmpnames=""
  installed="${installed:+$installed
}$dest/$b"
done <<EOF
$members
EOF

# --- post-install check ------------------------------------------------------------------
run_version() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$1" --version
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm 30; exec @ARGV' "$1" --version
  else
    "$1" --version
  fi
}

if ! run_version "$dest/$first_base" >/dev/null 2>&1; then
  # Remove what this run installed. Nothing is restored: with --force the previous file was
  # already replaced by the rename above, so a failed check leaves the tool absent, not old.
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f -- "$f"
  done <<EOF
$installed
EOF
  echo "install-release: $dest/$first_base --version failed; removed what this run installed" >&2
  exit 1
fi

while IFS= read -r f; do
  [ -n "$f" ] && echo "installed: $f"
done <<EOF
$installed
EOF

on_path=no
oldifs=$IFS
IFS=:
for d in $PATH; do
  if [ "$d" = "$dest" ]; then on_path=yes; fi
done
IFS=$oldifs
if [ "$on_path" = yes ]; then
  echo "on PATH: yes"
else
  echo "on PATH: no ($dest is not on PATH)"
fi
done_ok=1
exit 0
