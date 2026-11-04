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
#                 plus a `--version` check on the staged copy, run before anything is
#                 renamed into place, so a failed check leaves the previous copy untouched.
#   defect      — vendor installers fail open or edit shell startup files. tool-update.sh's
#                 header records four that skip verification; jsm's installer appends a PATH
#                 line to the shell's startup file by default; brew is absent on a fresh Mac.
#   delete-when — every one of these makers ships an installer that verifies and never
#                 edits startup files, or hov-stack stops offering them.
#
# The install record (receipt) is not ceremony: --update branches on it.
#   consumer    — `install-release.sh <tool> --update` (run by `./setup --update`).
#   gate        — --update touches a program only when every file in the record is still
#                 present and still has the recorded sha256.
#   defect      — replacing a copy the user put in ~/.local/bin some other way (uv's, cass's
#                 and jsm's own installers also install there) or edited by hand.
#   delete-when — this script is retired, or --update stops existing.
#
# Why this is not scripts/tool-update.sh: that script needs gh (this one installs gh), keeps
# its table test-only and its tool list is the author's own machine, and it leaves cass out on
# purpose because the author's machine tracks cass's main branch. A new user gets the tagged
# release, which is what the table below pins.
#
# Usage:  install-release.sh <tool> [--force]     tool: gh | uv | cass | jsm
#         install-release.sh <tool> --update      (not with --force: usage error)
# Exit:   0 installed (or, with --update, already current or updated); 1 download,
#         checksum, extract, install or --version check failed (the previous copy, if any,
#         and its record, stays or is put back); 2 bad usage; 3 unknown tool, or no release
#         for this platform;
#         4 a target file already exists (nothing changed; --force replaces it);
#         5 --update left the tool alone (nothing changed): not installed here, no install
#         record, a recorded file was removed or changed since this script installed it, or
#         the recorded version is newer than the pin (a pin never moves backwards)
# Record: each successful install writes ~/.local/state/hov-stack/install-release/<tool>
#         (version=, platform=, one `file=<abs path> <sha256>` line per installed file).
#         --update replaces a tool only when every recorded file still matches its sha256.
# Env:    HOV_SETUP_BIN_DIR        destination directory (default ~/.local/bin)
#         HOV_SETUP_STATE_DIR      test-only: directory holding the install records
#                                  (default ~/.local/state/hov-stack/install-release)
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
  echo "usage: install-release.sh <tool> [--force | --update]   (tool: gh | uv | cass | jsm)" >&2
  exit 2
}

fail() { echo "install-release: $*" >&2; exit 1; }

tool=""
force=0
update=0
for arg in "$@"; do
  case $arg in
    --force) force=1 ;;
    --update) update=1 ;;
    -*) usage ;;
    *) [ -z "$tool" ] || usage; tool=$arg ;;
  esac
done
[ -n "$tool" ] || usage
[ "$update" -eq 0 ] || [ "$force" -eq 0 ] || usage

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
row_version=""
while IFS="|" read -r t v p u s m; do
  [ -n "$t" ] || continue
  [ "$t" = "$tool" ] || continue
  tool_known=1
  platforms="${platforms:+$platforms, }$p"
  if [ "$p" = "$platform" ]; then
    row_version=$v; row_url=$u; row_sha=$s; row_members=$m
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
if [ -d "$dest" ]; then dest=$(cd "$dest" && pwd) || fail "cannot enter $dest"; fi   # absolute, to match the record
state_dir=${HOV_SETUP_STATE_DIR:-$HOME/.local/state/hov-stack/install-release}
receipt="$state_dir/$tool"

# --- helpers --------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  sha_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail "neither sha256sum nor shasum is available; cannot verify the download"
fi

# version_newer A B: dotted version A (digits and dots, optional leading v) is later than B.
# Anything else is not newer, so an unreadable record never blocks an update.
version_newer() {
  local a=${1#v} b=${2#v} x y
  case "$a" in "" | *[!0-9.]*) return 1 ;; esac
  case "$b" in "" | *[!0-9.]*) return 1 ;; esac
  while [ -n "$a" ] || [ -n "$b" ]; do
    x=${a%%.*} y=${b%%.*}
    case $a in *.*) a=${a#*.} ;; *) a="" ;; esac
    case $b in *.*) b=${b#*.} ;; *) b="" ;; esac
    # strip leading zeros so the comparison stays decimal
    x=${x#"${x%%[!0]*}"} y=${y#"${y%%[!0]*}"}
    x=${x:-0} y=${y:-0}
    if [ "${#x}" -ne "${#y}" ]; then [ "${#x}" -gt "${#y}" ]; return; fi
    if [ "$x" != "$y" ]; then [ "$x" \> "$y" ]; return; fi
  done
  return 1
}

# member list, one path per line; each installs under its basename
members=$(printf '%s' "$row_members" | tr ',' '\n')
first_base=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ -n "$first_base" ] || first_base=$(basename "$m")
done <<EOF
$members
EOF
[ -n "$first_base" ] || fail "table row for $tool/$platform lists no members"

# --- --update: decide from the install record whether this tool is ours to touch -----
old_version=""
if [ "$update" -eq 1 ]; then
  left_alone() { echo "$1" ; exit 5; }
  if [ ! -f "$receipt" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      b=$(basename "$m")
      if [ -e "$dest/$b" ] || [ -L "$dest/$b" ]; then
        left_alone "$tool: $dest/$b has no hov-stack install record (an install from before records, or another installer); nothing changed. To have hov-stack manage it: install-release.sh $tool --force"
      fi
    done <<EOF
$members
EOF
    left_alone "$tool: not installed here; nothing to update"
  fi
  while IFS= read -r line; do
    case $line in
      version=*) old_version=${line#version=} ;;
      file=*)
        rest=${line#file=}
        rpath=${rest% *}
        rsha=${rest##* }
        if [ ! -e "$rpath" ] && [ ! -L "$rpath" ]; then
          left_alone "$tool: $rpath was removed since hov-stack installed it; nothing changed (install-release.sh $tool --force reinstalls it)"
        fi
        if [ -L "$rpath" ] || [ ! -f "$rpath" ]; then
          left_alone "$tool: $rpath is no longer the file hov-stack installed (now a symlink or not a regular file); nothing changed (install-release.sh $tool --force replaces it)"
        fi
        if [ "$(sha_of "$rpath")" != "$rsha" ]; then
          # jsm and cass can replace themselves; say so, or every self-update reads as tampering.
          case $tool in
            jsm) left_alone "$tool: $rpath changed since hov-stack installed it, most likely by jsm's own auto-update; nothing changed (jsm update updates it; install-release.sh jsm --force puts the pinned copy back)" ;;
            cass) left_alone "$tool: $rpath changed since hov-stack installed it, possibly by cass upgrade; nothing changed (cass upgrade updates it; install-release.sh cass --force puts the pinned copy back)" ;;
            *) left_alone "$tool: $rpath changed since hov-stack installed it; nothing changed (install-release.sh $tool --force replaces it)" ;;
          esac
        fi
        ;;
    esac
  done < "$receipt"
  [ -n "$old_version" ] || left_alone "$tool: the hov-stack install record $receipt has no version; nothing changed (install-release.sh $tool --force reinstalls it)"
  # never move backwards: a checkout older than the one that installed the tool pins less
  if version_newer "$old_version" "$row_version"; then
    left_alone "$tool: $old_version is newer than the $row_version this checkout pins; nothing changed"
  fi
  # a member this release adds must not silently replace a file the record does not cover
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    b=$(basename "$m")
    if { [ -e "$dest/$b" ] || [ -L "$dest/$b" ]; } && ! grep -qF -- "file=$dest/$b " "$receipt"; then
      left_alone "$tool: $dest/$b is not in hov-stack's install record; nothing changed (install-release.sh $tool --force replaces it)"
    fi
  done <<EOF
$members
EOF
  if [ "$old_version" = "$row_version" ]; then
    echo "$tool: $row_version, current"
    exit 0
  fi
  force=1
fi

while IFS= read -r m; do
  [ -n "$m" ] || continue
  if [ -e "$dest/$(basename "$m")" ] || [ -L "$dest/$(basename "$m")" ]; then
    if [ "$force" -eq 0 ]; then
      echo "install-release: $dest/$(basename "$m") already exists; nothing changed (--force replaces it)" >&2
      exit 4
    fi
  fi
done <<EOF
$members
EOF



work=$(mktemp -d)
stage=""       # staging directory inside dest; removed on every exit path
installed=""   # newline-separated absolute paths this run moved into place
displaced=""   # newline-separated basenames whose previous copy waits in $stage/<name>.prev
done_ok=0      # set to 1 only once the install has succeeded
tmpnames=""    # newline-separated temp files not yet moved into place
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  local f
  # A failed run leaves nothing it moved into place: an earlier member of a multi-member
  # install must not survive a later member's failure, and a copy it moved aside to make
  # room (--force, --update) goes back. done_ok is set only on success.
  if [ "$done_ok" -eq 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && rm -f -- "$f"
    done <<EOF
$installed
EOF
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      mv -f "$stage/$f.prev" "$dest/$f" || echo "install-release: could not put the previous $f back; it is at $stage/$f.prev" >&2
    done <<EOF
$displaced
EOF
    # keep the stage directory when a previous copy is still in it
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -e "$stage/$f.prev" ] || [ -L "$stage/$f.prev" ]; then stage=""; break; fi
    done <<EOF
$displaced
EOF
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f -- "$f"
  done <<EOF
$tmpnames
EOF
  [ -z "$stage" ] || rm -rf "$stage"
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

# --- stage, check, then swap -------------------------------------------------------------
# Every member is staged under its real basename in a directory inside dest (same filesystem,
# so the final rename is atomic). --version runs on the staged first member; only a passing
# check renames anything into place, so a failed check leaves the previous copy untouched.
run_version() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$1" --version
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm 30; exec @ARGV' "$1" --version
  else
    "$1" --version
  fi
}

mkdir -p "$dest"
dest=$(cd "$dest" && pwd) || fail "cannot enter $dest"   # absolute, so installed: lines are
stage="$dest/.hov-setup.$$"
mkdir -p "$stage" || fail "could not create $stage"
while IFS= read -r m; do
  [ -n "$m" ] || continue
  b=$(basename "$m")
  install -m 0755 "$work/x/$m" "$stage/$b" || fail "could not write $stage/$b"
done <<EOF
$members
EOF

if ! run_version "$stage/$first_base" >/dev/null 2>&1; then
  echo "install-release: $first_base --version failed; nothing changed" >&2
  exit 1
fi

# The install record is written from the staged copies before anything moves, and renamed
# into place last (atomic: temp file, then rename), so a run that fails at any point leaves
# the previous record next to the previous copy.
mkdir -p "$state_dir" || fail "could not create $state_dir"
rtmp="$state_dir/.$tool.$$"
tmpnames="$rtmp"
{
  echo "version=$row_version"
  echo "platform=$platform"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    b=$(basename "$m")
    echo "file=$dest/$b $(sha_of "$stage/$b")"
  done <<EOF
$members
EOF
} > "$rtmp" || fail "could not write $rtmp"

# The swap: each previous copy moves aside into the stage directory (same filesystem), then
# the new one moves in. A failure puts every previous copy back (cleanup).
while IFS= read -r m; do
  [ -n "$m" ] || continue
  b=$(basename "$m")
  if [ -e "$dest/$b" ] || [ -L "$dest/$b" ]; then
    mv -f "$dest/$b" "$stage/$b.prev" || fail "could not move the previous $b aside"
    displaced="${displaced:+$displaced
}$b"
  fi
  mv -f "$stage/$b" "$dest/$b" || fail "could not move $b into $dest"
  installed="${installed:+$installed
}$dest/$b"
done <<EOF
$members
EOF

mv -f "$rtmp" "$receipt" || fail "could not write $receipt"
tmpnames=""
done_ok=1   # from here on the new copy and its record stand; nothing is rolled back

if [ "$update" -eq 1 ]; then
  echo "$tool: $old_version -> $row_version"
  exit 0
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
exit 0
