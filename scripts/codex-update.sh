#!/usr/bin/env bash
# codex-update.sh — verified stable Codex CLI updates through the existing pnpm install
# (dotfiles#1377).
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — codex-auto-update.timer (every 15 min, opt-in), better-ccflare's Codex
#                 client identity (it reads the verified-version record below),
#                 harness-weekly (`--report`), and the operator by hand.
#   gate        — exact stable dist-tag; candidate manifest and host native artifact
#                 checked before any install; the candidate is staged and must report
#                 EXACTLY `codex-cli <version>` with its native artifact before the live
#                 install moves; the live launcher is smoke-checked after, with an offline
#                 reinstall of the prior exact version when it fails.
#   defect      — OBSERVED (2026-09-23/24): nothing updated Codex; pnpm's 1440-minute
#                 cooldown held it at 0.156.0 while 0.156.1 was out; and better-ccflare's
#                 compiled client version lagged the CLI until GPT-6 Sol/Luna were rejected
#                 for 0.154.0 and accepted for 0.156.0 (better-ccflare#376/#378).
#   delete-when — Codex ships a self-updater that verifies and rolls back, or same-day
#                 Codex releases stop mattering.
#
# Why pnpm stays the owner: the live launcher (~/.local/bin/codex) is pnpm's shim, and the
# native binary arrives as an npm:-aliased optionalDependency that pnpm resolves. This
# script never writes the launcher or package dirs itself; every install is `pnpm add -g`.
# tool-update.sh is not extended because its daily timer is enabled by sync.sh install on
# every role, and this path must stay inert until codex-auto-update.timer is enabled.
#
# pnpm 11 only (it refuses any other major). pnpm 11 installs each `pnpm add -g` in its own
# dir, global/v11/<hash>/, and replaces that dir when the package is added again, so the
# installed package is found through `pnpm ls -g --json`, re-read after every install.
#
# The cooldown exception. pnpm checks minimumReleaseAge on the candidate AND on every
# platform alias it declares (measured 2026-09-26, pnpm 10.33.2: excluding only the host
# alias fails on 0.157.1-win32-x64). The exception is one per-run environment variable
#   pnpm_config_minimum_release_age_exclude=["@openai/codex@V || V-<suffix> ..."]
# naming exact versions of the one official package that the version's own manifest
# declares. Measured 2026-10-19 on pnpm 11.10.0: that JSON-array env form and a global
# config.yaml list are the only exclude forms that work. Every CLI --config form, an
# npm_config_userconfig rc line (the pnpm 10 mechanism this replaced) and a bare-string
# env value are silently ignored. The cooldown itself stays on (pnpm 11's built-in 1440
# minutes); every other package and every other install keeps it.
#
# Flow (DRY_RUN=0): lock → installed version (pnpm's own package.json) → stable `latest`
# (strict X.Y.Z; prereleases refused; never a downgrade) → candidate + host-artifact
# manifest checks → defer while a Codex process runs from the live package dir or a pnpm
# global/store operation runs → retain the installed version as a complete runnable copy
# in its own pnpm prefix under $LIB_DIR/retained/<v> (that prefix keeps its packages
# referenced, so `pnpm store prune` leaves them) → stage the candidate under
# $LIB_DIR/staging/<v> and verify it → recheck processes → promote with
# `pnpm add -g --offline`, drawing on what staging stored → smoke the live launcher →
# publish the record. A failed live smoke reinstalls the prior exact version --offline,
# verifies it, restores the record to match, and holds the failed candidate so the timer
# does not retry it every 15 minutes; a newer release clears the hold.
#
# Verified-version record ($STATE_DIR/verified-version.json), the contract that
# better-ccflare's CCFLARE_CODEX_VERIFIED_VERSION_FILE reader enforces:
#   {"schemaVersion":1,"packageName":"@openai/codex","version":"X.Y.Z","verifiedAt":"<UTC>Z"}
# A regular file under 4 KiB, replaced by rename because the reader opens it O_NOFOLLOW.
# A current install re-stamps it daily; the reader treats >30 days as stale, so a stopped
# updater shows up there too.
#
# Activation is manual and separate; sync.sh install deploys the units but never enables
# them:
#   systemctl --user enable --now codex-auto-update.timer
# and, for better-ccflare, CCFLARE_CODEX_VERIFIED_VERSION_FILE=<record path> on its unit.
#
# Usage:  codex-update.sh                 report only (default)
#         DRY_RUN=0 codex-update.sh       stage, verify, promote, publish the record
#         codex-update.sh --rollback [V]  reinstall a retained version (default: newest),
#                                         retain (offline, best effort) and hold the
#                                         version it replaced
#         codex-update.sh --report        staleness lines for harness-weekly
# Exit:   0 = current, promoted, deferred, held, rejected, or report-only
#         1 = failed; nothing promoted, or the prior version restored (see the output)
#
# A rejected candidate (prerelease on `latest`, a manifest or staged install that fails
# its checks) exits 0 with one notice and a hold: the gate worked, and a unit left red for
# correct behaviour is one nobody reads (dotfiles#518, cass-release-promote's reject()).
# Exit 1, and so OnFailure, is for a promoter that could not do its job.
#
# Linux only. The running-session check reads /proc, and the script relies on GNU date -d,
# mv -T, flock and timeout; on macOS it refuses rather than promote without that check.

set -uo pipefail

DRY_RUN=${DRY_RUN:-1}
PNPM=${CODEX_UPDATE_PNPM:-pnpm}
REGISTRY=${CODEX_UPDATE_REGISTRY:-https://registry.npmjs.org}
STATE_DIR=${CODEX_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-update}
LIB_DIR=${CODEX_UPDATE_LIB_DIR:-$HOME/.local/lib/codex-update}
PROC_ROOT=${CODEX_UPDATE_PROC_ROOT:-/proc}
KEEP=${CODEX_UPDATE_KEEP:-2}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NOTIFY=${CODEX_UPDATE_NOTIFY:-$HERE/notify.sh}
# Test seams: production sets none of these, so pnpm's own configured live prefix,
# store and cache apply.
GLOBAL_DIR=${CODEX_UPDATE_GLOBAL_DIR:-}
BIN_DIR=${CODEX_UPDATE_BIN_DIR:-}
STORE_DIR=${CODEX_UPDATE_STORE_DIR:-}
CACHE_DIR=${CODEX_UPDATE_CACHE_DIR:-}

PKG=@openai/codex
RECORD=$STATE_DIR/verified-version.json
STATUS=$STATE_DIR/status.json
HOLD=$STATE_DIR/hold
# Same shape better-ccflare's reader accepts.
STABLE_RE='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$'

say() { "$NOTIFY" "$1" "${2:-default}" >/dev/null 2>&1 || echo "WARN notify failed: $1"; return 0; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
is_stable() { [[ ${1:-} =~ $STABLE_RE ]]; }
ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]; }

detect_platform() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; *) return 1 ;; esac
  case "$(uname -m)" in x86_64 | amd64) arch=x64 ;; aarch64 | arm64) arch=arm64 ;; *) return 1 ;; esac
  echo "$os-$arch"
}
PLATFORM=${CODEX_UPDATE_PLATFORM:-$(detect_platform)} || PLATFORM=""

for need in "$PNPM" jq curl flock timeout; do
  command -v "$need" >/dev/null 2>&1 || { echo "codex-update: missing $need"; exit 1; }
done
[ -n "$PLATFORM" ] || { echo "codex-update: unsupported platform $(uname -sm)"; exit 1; }

# Scratch for fetched manifests, and the neutral cwd every pnpm call runs from: corepack
# picks pnpm's version from the cwd's packageManager field.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/codex-update.XXXXXX") || { echo "codex-update: no scratch dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# The layout and exception form above are pnpm 11's. pnpm 10 still sits in
# ~/.local/share/pnpm, and a PATH that puts it first would run every step wrong.
PNPM_VERSION=$(cd "$WORK" && timeout 60 "$PNPM" --version 2>/dev/null | tail -n 1)
case "$PNPM_VERSION" in
  11.*) ;;
  *) echo "codex-update: needs pnpm 11; $PNPM reports '${PNPM_VERSION:-nothing}'"; exit 1 ;;
esac

# The one exact cooldown exception a pnpm_g call carries, set per call:
#   EXCLUDE=<exclude_for output> pnpm_g ...
EXCLUDE=""

# pnpm_g <global-dir> <bin-dir> args...: pnpm against one global prefix, from a neutral
# cwd, carrying $EXCLUDE and nothing inherited. Empty dirs mean pnpm's configured live
# prefix. The global virtual store stays off, as config/pnpm/config.yaml sets it: with it
# on, the package lives in the shared store/v11/links tree instead of its install dir's
# own node_modules/.pnpm, where blockers() looks for running sessions.
pnpm_g() {
  local gdir=$1 bdir=$2
  shift 2
  local -a cfg=(--config.enable-global-virtual-store=false) env=(-u pnpm_config_minimum_release_age_exclude)
  [ -n "$gdir" ] && cfg+=("--config.global-dir=$gdir")
  [ -n "$bdir" ] && cfg+=("--config.global-bin-dir=$bdir")
  [ -n "$STORE_DIR" ] && cfg+=("--config.store-dir=$STORE_DIR")
  [ -n "$CACHE_DIR" ] && cfg+=("--config.cache-dir=$CACHE_DIR")
  [ -n "$EXCLUDE" ] && env+=("pnpm_config_minimum_release_age_exclude=$(jq -cn --arg e "$EXCLUDE" '[$e]')")
  (cd "$WORK" && env "${env[@]}" PATH="${bdir:+$bdir:}$PATH" \
    timeout 900 "$PNPM" "$@" "${cfg[@]}")
}

# pkg_dir <global-dir> <bin-dir>: the @openai/codex dir pnpm lists in that prefix.
pkg_dir() {
  pnpm_g "$1" "$2" ls -g --depth=0 --json 2>/dev/null |
    jq -er --arg pkg "$PKG" '.[0].dependencies[$pkg].path // empty' 2>/dev/null
}

fetch() { curl -fsS --max-time 30 --proto '=https,file' "$1" -o "$2" 2>/dev/null; }

# show_log <lines> <file>: the tail of a pnpm log for the journal, credentials masked. The
# journal feeds OnFailure's page (unit-failure-alert.sh sends its last lines to Discord),
# and pnpm can echo a registry URL or auth header it took from ~/.npmrc.
show_log() {
  tail -n "$1" "$2" | sed -E -e 's#(://)[^/@[:space:]]+@#\1[redacted]@#g' \
    -e 's#((_authToken|_auth|_password|token)[=:][[:space:]]*)[^[:space:]]+#\1[redacted]#gI' \
    -e 's#((Bearer|Basic)[[:space:]]+)[^[:space:]]+#\1[redacted]#gI' -e 's/^/    /'
}

# exclude_for <package.json|manifest> <version>: the exact cooldown exception a version
# needs. Fails unless every declared native alias is exactly npm:@openai/codex@<v>-<suffix>
# and the host's alias is among them.
exclude_for() {
  jq -er --arg v "$2" --arg pkg "$PKG" --arg host "$PKG-$PLATFORM" '
    (.optionalDependencies // {}) as $o
    | if .name != $pkg or .version != $v then error("name or version") else . end
    | if ($o | has($host)) then . else error("no host alias") end
    | [$o | to_entries[]
        | (.key | ltrimstr("@openai/codex-")) as $s
        | if (.key | test("^@openai/codex-[a-z0-9]+-[a-z0-9]+$")) and .value == "npm:\($pkg)@\($v)-\($s)"
          then $s else error("alias \(.key)") end]
    | sort
    | "\($pkg)@\($v)" + (map(" || \($v)-\(.)") | join(""))
  ' "$1" 2>/dev/null
}

# smoke <global-dir> <bin-dir> <version>: exact version, --help, host native artifact, for
# the prefix pnpm_g takes those two dirs as (empty = live; its launcher is in $LIVE_BIN).
smoke() {
  local gdir=$1 bdir=$2 v=$3 launcher=${2:-$LIVE_BIN}/codex got pkg real nat
  got=$(cd "$WORK" && timeout 60 "$launcher" --version 2>/dev/null | head -n 1)
  if [ "$got" != "codex-cli $v" ]; then
    echo "  smoke: $launcher reports '${got:-nothing}', expected 'codex-cli $v'"
    return 1
  fi
  if ! (cd "$WORK" && timeout 60 "$launcher" --help >/dev/null 2>&1); then
    echo "  smoke: $launcher --help failed"
    return 1
  fi
  if ! pkg=$(pkg_dir "$gdir" "$bdir") || ! real=$(cd "$pkg" 2>/dev/null && pwd -P); then
    echo "  smoke: pnpm lists no $PKG in ${gdir:-the live prefix}"
    return 1
  fi
  if [ "$(jq -r .version "$real/package.json" 2>/dev/null)" != "$v" ]; then
    echo "  smoke: $real/package.json is not $v"
    return 1
  fi
  nat=$(jq -r .version "$real/../codex-$PLATFORM/package.json" 2>/dev/null)
  if [ "$nat" != "$v-$PLATFORM" ]; then
    echo "  smoke: native artifact codex-$PLATFORM is '${nat:-missing}', expected $v-$PLATFORM"
    return 1
  fi
}

# resolve_live: LIVE_BIN, LIVE_PKG, INSTALLED, VSTORE (the live install dir's own
# virtual store, global/v11/<hash>/node_modules/.pnpm on this host).
resolve_live() {
  local real root
  LIVE_BIN=$BIN_DIR
  [ -n "$LIVE_BIN" ] || LIVE_BIN=$(pnpm_g "" "" bin -g 2>/dev/null | tail -n 1)
  if ! LIVE_PKG=$(pkg_dir "$GLOBAL_DIR" "$BIN_DIR") || [ ! -f "$LIVE_PKG/package.json" ]; then
    root=$(pnpm_g "$GLOBAL_DIR" "$BIN_DIR" root -g 2>/dev/null | tail -n 1)
    echo "no pnpm-owned $PKG install under ${root:-<pnpm root -g failed>}; install it with pnpm 11 first"
    return 1
  fi
  INSTALLED=$(jq -r .version "$LIVE_PKG/package.json" 2>/dev/null)
  if ! is_stable "$INSTALLED"; then
    echo "installed $PKG is '$INSTALLED', not a stable release; not managing it"
    return 1
  fi
  real=$(cd "$LIVE_PKG" && pwd -P)
  VSTORE=${real%%/@openai+codex@*}
}

# check_launcher: which installation owns `codex` on PATH. Recorded, never changed.
LAUNCHER="" LAUNCHER_OWNED=false
check_launcher() {
  LAUNCHER=$(command -v codex 2>/dev/null || true)
  if [ -n "$LAUNCHER" ] && [ "$(readlink -f "$LAUNCHER")" = "$(readlink -f "$LIVE_BIN/codex")" ]; then
    LAUNCHER_OWNED=true
  else
    LAUNCHER_OWNED=false
    echo "WARN active codex launcher is ${LAUNCHER:-<none on PATH>}, not the pnpm shim $LIVE_BIN/codex; only the pnpm install is updated"
  fi
}

# pnpm_global_op <exe> <cmdline>: a pnpm process doing global or store/cache work.
pnpm_global_op() {
  local seen=0 tok
  local -a toks
  case "${1##*/}" in pnpm) seen=1 ;; esac
  read -ra toks <<<"$2"
  for tok in "${toks[@]}"; do
    if [ "$seen" = 0 ]; then
      case "${tok##*/}" in pnpm | pnpm.cjs | pnpm.js | pnpm.mjs) seen=1 ;; esac
      continue
    fi
    case "$tok" in -g | --global | store | cache) return 0 ;; esac
  done
  return 1
}

# blockers: why promotion must wait right now (empty = clear). A Codex process running
# from the live package dir would lose its helper binaries when pnpm prunes that dir.
# A process table with nothing in it is unreadable, not idle: wait rather than promote blind.
blockers() {
  local p exe cmd n=0 seen=0 busy=""
  for p in "$PROC_ROOT"/[0-9]*; do
    [ -d "$p" ] || continue
    seen=$((seen + 1))
    exe=$(readlink "$p/exe" 2>/dev/null) || exe=""
    cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || cmd=""
    case "$exe $cmd" in *"$VSTORE/@openai+codex@"*)
      n=$((n + 1))
      continue
      ;;
    esac
    pnpm_global_op "$exe" "$cmd" && busy=${p##*/}
  done
  [ "$seen" -eq 0 ] && echo "cannot inspect running processes under $PROC_ROOT"
  [ "$n" -gt 0 ] && echo "$n active codex process(es) run from the live package dir"
  [ -n "$busy" ] && echo "a pnpm global/store operation is running (pid $busy)"
  return 0
}

# write_json_atomic <dest> <json>: temp file in the same dir, then rename over dest
# (never through a symlink planted at dest).
write_json_atomic() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX") || return 1
  if printf '%s\n' "$2" >"$tmp" && chmod 644 "$tmp" && mv -fT "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

publish_record() {
  write_json_atomic "$RECORD" "$(jq -cn --arg v "$1" --arg t "$(now_utc)" \
    '{schemaVersion: 1, packageName: "@openai/codex", version: $v, verifiedAt: $t}')" \
    || { echo "WARN could not publish $RECORD"; return 1; }
}

# record_is_fresh <version>: the record names <version> and was stamped under a day ago.
record_is_fresh() {
  local v t age
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  v=$(jq -r .version "$RECORD" 2>/dev/null)
  t=$(jq -r .verifiedAt "$RECORD" 2>/dev/null)
  [ "$v" = "$1" ] || return 1
  age=$(($(date -u +%s) - $(date -u -d "$t" +%s 2>/dev/null || echo 0)))
  [ "$age" -lt 86400 ] && [ "$age" -gt -300 ]
}

# write_status <outcome> <detail> <candidate>: what the last run saw, for --report.
write_status() {
  local gap=null prev_inst prev_gap
  if [ "$INSTALLED" != "$3" ]; then
    prev_inst=$(jq -r '.installed // empty' "$STATUS" 2>/dev/null)
    prev_gap=$(jq -r '.gapSince // empty' "$STATUS" 2>/dev/null)
    if [ "$prev_inst" = "$INSTALLED" ] && [ -n "$prev_gap" ]; then gap=\"$prev_gap\"; else gap=\"$(now_utc)\"; fi
  fi
  write_json_atomic "$STATUS" "$(jq -cn --arg t "$(now_utc)" --arg i "$INSTALLED" --arg c "$3" \
    --arg o "$1" --arg d "$2" --argjson g "$gap" --arg l "$LAUNCHER" --argjson lo "$LAUNCHER_OWNED" \
    '{checkedAt: $t, installed: $i, candidate: $c, outcome: $o, detail: $d, gapSince: $g,
      launcher: $l, launcherOwned: $lo}')" || echo "WARN could not write $STATUS"
}

# retain <version> [--offline]: a complete runnable copy in its own pnpm prefix, plus the
# exact exception its reinstall needs (it may itself be under a day old). --prefer-offline
# by default; a rollback passes --offline so it never waits on the network.
# A copy retained under pnpm 10 (global/5 layout, 0.162.0 and 0.162.1 on this host) fails
# the check below, so retaining that version again replaces it. Rolling back to one still
# works, but online: pnpm 11's store does not hold its files.
retain() {
  local v=$1 net=${2:---prefer-offline} d="$LIB_DIR/retained/$1" excl
  excl=$(exclude_for "$LIVE_PKG/package.json" "$v") || excl=""
  if smoke "$d/global" "$d/bin" "$v" >/dev/null; then
    [ -d "$d/metadata" ] || snapshot_meta "$d/metadata" || true
    return 0
  fi
  rm -rf "$d"
  mkdir -p "$d/global" "$d/bin" || return 1
  if ! EXCLUDE=$excl pnpm_g "$d/global" "$d/bin" add -g "$PKG@$v" "$net" >"$WORK/retain.log" 2>&1; then
    echo "  retain: pnpm add $PKG@$v failed:"
    show_log 3 "$WORK/retain.log"
    return 1
  fi
  smoke "$d/global" "$d/bin" "$v" || return 1
  printf '%s\n' "$excl" >"$d/exclude"
  # The install just refreshed pnpm's metadata, so it lists this version.
  snapshot_meta "$d/metadata" ||
    echo "WARN no pnpm metadata to snapshot for $v; an offline rollback after a store prune would need the network"
}

# stage <version> <exclude>: install the candidate into a scratch prefix and verify it.
stage() {
  local v=$1 d="$LIB_DIR/staging/$1"
  rm -rf "$LIB_DIR/staging"
  mkdir -p "$d/global" "$d/bin" || return 1
  if ! EXCLUDE=$2 pnpm_g "$d/global" "$d/bin" add -g "$PKG@$v" >"$WORK/stage.log" 2>&1; then
    echo "staging failed: pnpm add $PKG@$v:"
    show_log 3 "$WORK/stage.log"
    STAGE_TRANSIENT=1
    return 1
  fi
  smoke "$d/global" "$d/bin" "$v" || { echo "staged candidate $v failed verification; not promoting"; return 1; }
}

# install_live <version> <exclude>: pnpm add into the live prefix, offline first. pnpm
# replaces the live install dir, so it re-reads LIVE_PKG after a successful install.
install_live() {
  if EXCLUDE=$2 pnpm_g "$GLOBAL_DIR" "$BIN_DIR" add -g "$PKG@$1" --offline >"$WORK/live.log" 2>&1; then
    LIVE_PKG=$(pkg_dir "$GLOBAL_DIR" "$BIN_DIR")
    return 0
  fi
  echo "  offline install of $1 failed; retrying with --prefer-offline"
  show_log 2 "$WORK/live.log"
  if EXCLUDE=$2 pnpm_g "$GLOBAL_DIR" "$BIN_DIR" add -g "$PKG@$1" --prefer-offline >>"$WORK/live.log" 2>&1; then
    LIVE_PKG=$(pkg_dir "$GLOBAL_DIR" "$BIN_DIR")
    return 0
  fi
  show_log 3 "$WORK/live.log"
  return 1
}

# pnpm's metadata cache is not ours to keep: `pnpm store prune` (pkg-cache-prune.timer,
# weekly) deletes all of it — "Removed all cached metadata files" on pnpm 10.33.2, and on
# 11.10.0 (measured 2026-10-19) it empties the whole cache dir — while the retained prefix
# keeps the package files. --offline then fails ERR_PNPM_NO_OFFLINE_META even for an
# exact version. So each retained copy carries a snapshot of the @openai/codex metadata
# (<cache>/v11/metadata*/<registry>/@openai/codex.jsonl), restored before an offline
# reinstall.
# pnpm 11 prints "undefined" for a cache dir nobody configured (measured 2026-10-19 on
# 11.10.0 in the unit's environment); its built-in default is $XDG_CACHE_HOME/pnpm, else
# ~/.cache/pnpm. Anything but an absolute path falls back to that default.
cache_root() {
  local c=$CACHE_DIR
  [ -n "$c" ] || c=$(pnpm_g "" "" config get cache-dir 2>/dev/null | tail -n 1)
  case "$c" in /*) ;; *) c=${XDG_CACHE_HOME:-$HOME/.cache}/pnpm ;; esac
  echo "$c"
}

# snapshot_meta <dest-dir>: copy every cached @openai/codex metadata file, keeping paths.
snapshot_meta() {
  local root f rel n=0
  root=$(cache_root)
  [ -n "$root" ] && [ -d "$root" ] || return 1
  while IFS= read -r f; do
    rel=${f#"$root"/}
    mkdir -p "$1/${rel%/*}" && cp -p "$f" "$1/$rel" && n=$((n + 1))
  done < <(find "$root" -path "$root/v11/metadata*/*/@openai/codex.jsonl" -type f 2>/dev/null)
  [ "$n" -gt 0 ]
}

# restore_meta <src-dir>: put back only the metadata files the cache has lost.
restore_meta() {
  local root f rel
  [ -d "$1" ] || return 0
  root=$(cache_root)
  [ -n "$root" ] || return 0
  while IFS= read -r f; do
    rel=${f#"$1"/}
    [ -e "$root/$rel" ] || { mkdir -p "$root/${rel%/*}" && cp -p "$f" "$root/$rel"; }
  done < <(find "$1" -type f -name codex.jsonl 2>/dev/null)
}

# rollback_to <version>: reinstall a retained exact version into the live prefix, verify it.
# An exclude file written under pnpm 10 is an rc line; its pattern follows the prefix.
rollback_to() {
  local excl=""
  [ -f "$LIB_DIR/retained/$1/exclude" ] && excl=$(cat "$LIB_DIR/retained/$1/exclude")
  excl=${excl#"minimum-release-age-exclude[]="}
  restore_meta "$LIB_DIR/retained/$1/metadata"
  install_live "$1" "$excl" && smoke "$GLOBAL_DIR" "$BIN_DIR" "$1"
}

others_list() {
  pnpm_g "$GLOBAL_DIR" "$BIN_DIR" ls -g --depth=0 --json 2>/dev/null |
    jq -r --arg pkg "$PKG" '[.[0].dependencies // {} | to_entries[] | select(.key != $pkg)
      | "\(.key)@\(.value.version)"] | sort | .[]' 2>/dev/null
}

# retained_versions: stable version dirs under retained/, newest first.
retained_versions() {
  local d
  for d in "$LIB_DIR"/retained/*/; do
    d=${d%/}
    d=${d##*/}
    is_stable "$d" && echo "$d"
  done | sort -rV
}

reap_retained() {
  local v
  retained_versions | tail -n +"$((KEEP + 1))" |
    while read -r v; do rm -rf "${LIB_DIR:?}/retained/$v"; done
}

hold() { printf '%s\n' "$1" >"$HOLD"; }

# reject <candidate> <why>: a bad CANDIDATE, not a broken promoter. Hold it, notify once
# (a candidate already held is not news again), record it, exit 0.
reject() {
  echo "REJECTED $PKG@$1: $2; staying on $INSTALLED"
  [ "$DRY_RUN" = 1 ] && exit 0
  if [ "$(cat "$HOLD" 2>/dev/null)" != "$1" ]; then
    hold "$1"
    say "codex candidate $1 REJECTED, staying on $INSTALLED: $2" input
  fi
  write_status rejected "$2" "$1"
  exit 0
}

take_lock() {
  mkdir -p "$STATE_DIR" "$LIB_DIR" || { echo "codex-update: cannot create $STATE_DIR"; exit 1; }
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { echo "another codex-update run holds the lock"; exit 0; }
}

# ── --report ─────────────────────────────────────────────────────────────────────────
report() {
  local latest checked gap outcome age days
  resolve_live || return 0
  if ! fetch "$REGISTRY/-/package/$PKG/dist-tags" "$WORK/tags.json" ||
    ! latest=$(jq -er .latest "$WORK/tags.json" 2>/dev/null); then
    echo "codex staleness: registry unreachable; installed $INSTALLED"
    return 0
  fi
  if [ "$latest" = "$INSTALLED" ]; then
    echo "codex current: $INSTALLED"
  elif ! is_stable "$latest"; then
    echo "WARN codex latest dist-tag '$latest' is not a stable release; installed $INSTALLED"
  elif [ ! -f "$STATUS" ]; then
    echo "WARN codex behind: $INSTALLED -> $latest (the updater has not run; enable codex-auto-update.timer)"
  else
    checked=$(jq -r '.checkedAt // empty' "$STATUS")
    outcome=$(jq -r '.outcome // "unknown"' "$STATUS")
    gap=$(jq -r 'if .installed == $i then (.gapSince // empty) else empty end' --arg i "$INSTALLED" "$STATUS")
    age=$(($(date -u +%s) - $(date -u -d "${checked:-1970-01-01T00:00:00Z}" +%s 2>/dev/null || echo 0)))
    if [ "$age" -gt 7200 ]; then
      echo "WARN codex behind: $INSTALLED -> $latest (the updater has not run since ${checked:-never})"
    elif [ -n "$gap" ] && [ $(($(date -u +%s) - $(date -u -d "$gap" +%s))) -gt 86400 ]; then
      echo "WARN codex behind: $INSTALLED -> $latest (behind since $gap; last outcome $outcome)"
    elif [ "$outcome" = held ] || [ "$outcome" = rejected ]; then
      echo "WARN codex behind: $INSTALLED -> $latest ($outcome: $(jq -r '.detail // empty' "$STATUS"))"
    else
      echo "codex behind: $INSTALLED -> $latest (updating; last outcome $outcome)"
    fi
  fi
  if [ -f "$RECORD" ]; then
    age=$(($(date -u +%s) - $(date -u -d "$(jq -r .verifiedAt "$RECORD" 2>/dev/null)" +%s 2>/dev/null || echo 0)))
    days=$((age / 86400))
    [ "$days" -ge 7 ] &&
      echo "WARN codex verified-version record is $days days old (better-ccflare treats >30 days as stale)"
  fi
  return 0
}

# ── --rollback [V] ───────────────────────────────────────────────────────────────────
manual_rollback() {
  local target=${1:-} why
  take_lock
  resolve_live || exit 1
  check_launcher >/dev/null
  if [ -z "$target" ]; then
    target=$(retained_versions | grep -vxF "$INSTALLED" | head -n 1)
  fi
  if [ -z "$target" ] || [ ! -d "$LIB_DIR/retained/$target" ]; then
    echo "no retained version to roll back to under $LIB_DIR/retained"
    exit 1
  fi
  why=$(blockers)
  if [ -n "$why" ]; then
    echo "not rolling back while $why; close those sessions first"
    exit 1
  fi
  # Keep the version being replaced too, so this rollback can itself be undone offline.
  # It may be the broken one, so failing to retain it never blocks the rollback. Offline:
  # an online retain can recreate a pruned metadata file that restore_meta then skips.
  retain "$INSTALLED" --offline || echo "WARN could not retain $INSTALLED; rolling back anyway"
  if rollback_to "$target"; then
    hold "$INSTALLED"
    publish_record "$target"
    local from=$INSTALLED
    INSTALLED=$target
    write_status rolled-back "manual rollback from $from" "$from"
    echo "rolled back to $target (holding $from; a newer release clears the hold)"
    exit 0
  fi
  echo "ROLLBACK FAILED: $PKG@$target did not verify; emergency copy: $LIB_DIR/retained/$target/bin/codex"
  exit 1
}

# ── update ───────────────────────────────────────────────────────────────────────────
update() {
  local latest excl why before after drift
  [ "$DRY_RUN" = 1 ] || take_lock
  resolve_live || exit 1
  check_launcher

  if ! fetch "$REGISTRY/-/package/$PKG/dist-tags" "$WORK/tags.json" ||
    ! latest=$(jq -er .latest "$WORK/tags.json" 2>/dev/null); then
    echo "codex-update: could not read the $PKG dist-tags from $REGISTRY"
    [ "$DRY_RUN" = 1 ] || write_status failed "registry unreachable" "$INSTALLED"
    exit 1
  fi
  if ! is_stable "$latest"; then
    reject "$latest" "the latest dist-tag is not a stable release"
  fi

  if [ "$latest" = "$INSTALLED" ] || ver_lt "$latest" "$INSTALLED"; then
    ver_lt "$latest" "$INSTALLED" &&
      echo "refusing downgrade: installed $INSTALLED is newer than stable $latest"
    if [ "$DRY_RUN" != 1 ]; then
      if ! smoke "$GLOBAL_DIR" "$BIN_DIR" "$INSTALLED"; then
        echo "the live codex install fails its smoke check; not publishing a record"
        write_status failed "live smoke failed" "$latest"
        say "codex-update: live codex $INSTALLED fails its smoke check" error
        exit 1
      fi
      record_is_fresh "$INSTALLED" || publish_record "$INSTALLED"
      write_status current "" "$INSTALLED"
    fi
    echo "codex current: $INSTALLED"
    exit 0
  fi

  if [ "$(cat "$HOLD" 2>/dev/null)" = "$latest" ]; then
    echo "holding $latest: it failed verification earlier; remove $HOLD to retry"
    [ "$DRY_RUN" = 1 ] || write_status held "$latest failed verification" "$latest"
    exit 0
  fi

  # A manifest that cannot be fetched says nothing against the release (registry
  # propagation, a network blip), so it defers; only one that fetches and fails is rejected.
  if ! fetch "$REGISTRY/$PKG/$latest" "$WORK/cand.json" ||
    ! fetch "$REGISTRY/$PKG/$latest-$PLATFORM" "$WORK/native.json"; then
    echo "deferred: could not fetch the $PKG@$latest or $latest-$PLATFORM manifest from $REGISTRY"
    [ "$DRY_RUN" = 1 ] || write_status deferred "manifest fetch failed" "$latest"
    exit 0
  fi
  if ! excl=$(exclude_for "$WORK/cand.json" "$latest") ||
    ! jq -e '.dist.integrity | startswith("sha512-")' "$WORK/cand.json" >/dev/null 2>&1; then
    echo "manifest check failed for $PKG@$latest: a native alias is not an exact $PKG version, or no sha512 integrity"
    reject "$latest" "manifest check failed"
  fi
  if ! jq -e --arg v "$latest-$PLATFORM" --arg os "${PLATFORM%-*}" --arg cpu "${PLATFORM#*-}" '
      .name == "@openai/codex" and .version == $v and (.os | index($os)) and (.cpu | index($cpu))
      and (.dist.integrity | startswith("sha512-"))' "$WORK/native.json" >/dev/null 2>&1; then
    echo "manifest check failed for $PKG@$latest-$PLATFORM: host native artifact malformed"
    reject "$latest" "host artifact check failed"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "would update codex $INSTALLED -> $latest"
    exit 0
  fi

  why=$(blockers)
  if [ -n "$why" ]; then
    echo "deferred: $why"
    write_status deferred "$why" "$latest"
    exit 0
  fi

  if ! retain "$INSTALLED"; then
    echo "cannot retain $INSTALLED as a rollback copy; not promoting $latest"
    write_status failed "retention of $INSTALLED failed" "$latest"
    say "codex-update: could not retain $INSTALLED; $latest not promoted" error
    exit 1
  fi

  STAGE_TRANSIENT=0
  if ! stage "$latest" "$excl"; then
    rm -rf "$LIB_DIR/staging"
    [ "$STAGE_TRANSIENT" = 1 ] || reject "$latest" "the staged install failed verification"
    write_status failed "staging $latest failed" "$latest"
    say "codex-update: staging $latest failed" error
    exit 1
  fi

  why=$(blockers)
  if [ -n "$why" ]; then
    rm -rf "$LIB_DIR/staging"
    echo "deferred: $why"
    write_status deferred "$why" "$latest"
    exit 0
  fi

  before=$(others_list)
  local prev=$INSTALLED
  if ! install_live "$latest" "$excl" || ! smoke "$GLOBAL_DIR" "$BIN_DIR" "$latest"; then
    rm -rf "$LIB_DIR/staging"
    hold "$latest"
    if rollback_to "$prev"; then
      publish_record "$prev"
      write_status rolled-back "$latest failed its live smoke check" "$latest"
      echo "ROLLED BACK to $prev after the promoted $latest failed its smoke check (holding $latest)"
      say "codex-update: $latest failed after promotion; rolled back to $prev" error
    else
      write_status rollback-failed "$latest failed and $prev did not reinstall" "$latest"
      echo "ROLLBACK FAILED: $PKG@$prev did not reinstall; emergency copy: $LIB_DIR/retained/$prev/bin/codex"
      say "codex-update: ROLLBACK FAILED; codex may be broken" error
    fi
    exit 1
  fi

  rm -rf "$LIB_DIR/staging"
  publish_record "$latest"
  INSTALLED=$latest
  after=$(others_list)
  reap_retained
  rm -f "$HOLD"
  echo "codex promoted: $prev -> $latest"
  say "codex updated: $prev -> $latest" complete
  if [ "$before" != "$after" ]; then
    drift=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^[<>]' | tr '\n' ' ')
    echo "WARN unrelated pnpm globals changed during promotion: $drift"
    write_status promoted "unrelated pnpm globals changed: $drift" "$latest"
    exit 1
  fi
  write_status promoted "" "$latest"
  exit 0
}

case "${1:-}" in
  --report) report ;;
  --rollback) manual_rollback "${2:-}" ;;
  "") update ;;
  *) echo "usage: codex-update.sh [--report | --rollback [VERSION]]"; exit 2 ;;
esac
