#!/usr/bin/bash
# Install the reviewed wacli release without invoking an upstream installer.
#
# Account credentials and message data are deliberately outside this path under
# ~/.local/state/wacli. This script manages only the executable.

set -euo pipefail

PIN_VERSION=0.17.1
PIN_URL=https://github.com/openclaw/wacli/releases/download/v0.17.1/wacli_0.17.1_linux_amd64.tar.gz
PIN_ARCHIVE_SHA256=cbd5e74d5b805550cc36c7479aca552970cc1b314c5c08e02367e08b785714fd
PIN_BINARY_SHA256=c71d7cb1395b228ac82d063a1b7d315e379d660f41654d08aacf9200bdb95527

MODE=${1:-install}
case $MODE in
  install|--install) MODE=install ;;
  check|--check) MODE=check ;;
  preflight|--preflight) MODE=preflight ;;
  *) echo "usage: wacli-install.sh [install|check|preflight]" >&2; exit 64 ;;
esac

fail() {
  echo "wacli-install: $*" >&2
  exit 1
}

if [ "${WACLI_INSTALL_TEST_MODE:-0}" = 1 ]; then
  CURL_BIN=$(command -v curl 2>/dev/null || true)
  SYSTEMCTL_BIN=$(command -v systemctl 2>/dev/null || true)
else
  PATH=/usr/bin:/bin
  LC_ALL=C
  export PATH LC_ALL
  unset BASH_ENV ENV CDPATH TAR_OPTIONS TAPE GZIP BZIP BZIP2 XZ_OPT \
        LD_PRELOAD LD_LIBRARY_PATH
  CURL_BIN=/usr/bin/curl
  SYSTEMCTL_BIN=/usr/bin/systemctl
fi
[ -x "$SYSTEMCTL_BIN" ] || SYSTEMCTL_BIN=

for dependency in "$CURL_BIN" /usr/bin/sha256sum /usr/bin/tar /usr/bin/install \
                  /usr/bin/realpath /usr/bin/readlink /usr/bin/uname /usr/bin/awk \
                  /usr/bin/grep /usr/bin/mkdir /usr/bin/mktemp /usr/bin/rm \
                  /usr/bin/cp /usr/bin/date /usr/bin/mv /usr/bin/ln /usr/bin/chmod \
                  /usr/bin/id /usr/bin/stat; do
  [ -x "$dependency" ] || fail "required executable not found: $dependency"
done

if [ "$(/usr/bin/uname -s)" != Linux ] || [ "$(/usr/bin/uname -m)" != x86_64 ]; then
  fail "the reviewed pin supports Linux x86_64 only (found $(/usr/bin/uname -s) $(/usr/bin/uname -m))"
fi

VERSION=$PIN_VERSION
URL=$PIN_URL
ARCHIVE_SHA256=$PIN_ARCHIVE_SHA256
BINARY_SHA256=$PIN_BINARY_SHA256
LIB_ROOT=$HOME/.local/lib/wacli
BIN_DIR=$HOME/.local/bin
BACKUP_ROOT=$HOME/.local/lib/tool-backups/wacli
PROC_ROOT=/proc

# Hermetic tests may replace the artifact tuple, but can write only below /tmp.
# Production callers cannot redirect the install destination or source.
if [ "${WACLI_INSTALL_TEST_MODE:-0}" = 1 ]; then
  TEST_ROOT=${WACLI_INSTALL_TEST_ROOT:?WACLI_INSTALL_TEST_ROOT is required in test mode}
  TEST_ROOT=$(/usr/bin/realpath -m "$TEST_ROOT")
  case $TEST_ROOT in
    /tmp/*) ;;
    *) fail "test root must stay below /tmp (got $TEST_ROOT)" ;;
  esac
  VERSION=${WACLI_INSTALL_TEST_VERSION:-$VERSION}
  URL=${WACLI_INSTALL_TEST_URL:-$URL}
  ARCHIVE_SHA256=${WACLI_INSTALL_TEST_ARCHIVE_SHA256:-$ARCHIVE_SHA256}
  BINARY_SHA256=${WACLI_INSTALL_TEST_BINARY_SHA256:-$BINARY_SHA256}
  LIB_ROOT=$TEST_ROOT/lib/wacli
  BIN_DIR=$TEST_ROOT/bin
  BACKUP_ROOT=$TEST_ROOT/backups
  if [ "${WACLI_INSTALL_TEST_NO_SYSTEMCTL:-0}" = 1 ]; then
    SYSTEMCTL_BIN=
  fi
  if [ -n "${WACLI_INSTALL_TEST_PROC_ROOT:-}" ]; then
    PROC_ROOT=$(/usr/bin/realpath -m "$WACLI_INSTALL_TEST_PROC_ROOT")
    case $PROC_ROOT in
      "$TEST_ROOT"/*) ;;
      *) fail "test proc root must stay below test root (got $PROC_ROOT)" ;;
    esac
  fi
fi

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid pinned version: $VERSION"
[[ $ARCHIVE_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid archive SHA-256 pin"
[[ $BINARY_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid binary SHA-256 pin"

TARGET_DIR=$LIB_ROOT/v$VERSION
TARGET=$TARGET_DIR/wacli
LIVE=$BIN_DIR/wacli

if [ -L "$TARGET" ] || { [ -e "$TARGET" ] && [ ! -f "$TARGET" ]; }; then
  fail "refusing unexpected pinned target type: $TARGET"
fi
if [ -e "$LIVE" ] && [ -d "$LIVE" ]; then
  fail "refusing directory at live path: $LIVE"
fi
versioned_wacli_process_state() {
  local allowed_pid=${1:-} current_uid process_dir owner exe pid resolved
  local comm argv0 state readable=0
  current_uid=$(/usr/bin/id -u) || return 2
  for process_dir in "$PROC_ROOT"/[0-9]*; do
    [ -d "$process_dir" ] || continue
    owner=$(/usr/bin/stat -c %u "$process_dir" 2>/dev/null) || {
      [ -d "$process_dir" ] && return 2
      continue
    }
    [ "$owner" = "$current_uid" ] || continue
    pid=${process_dir##*/}
    exe=$process_dir/exe
    if resolved=$(/usr/bin/readlink "$exe" 2>/dev/null); then
      readable=$((readable + 1))
      resolved=${resolved% (deleted)}
      case $resolved in
        */wacli)
          [ -n "$allowed_pid" ] && [ "$pid" = "$allowed_pid" ] && continue
          return 0
          ;;
      esac
      continue
    fi
    [ -d "$process_dir" ] || continue

    # Some same-UID services are non-dumpable, so /proc/<pid>/exe is unreadable.
    # Require both comm and argv0 to rule out wacli; hidepid-style loss of those
    # peer signals remains an incomplete proof and fails closed.
    comm=
    IFS= read -r comm <"$process_dir/comm" 2>/dev/null || return 2
    argv0=
    if IFS= read -r -d '' argv0 <"$process_dir/cmdline" 2>/dev/null; then
      case $argv0 in
        wacli|*/wacli) return 0 ;;
      esac
      [ "$comm" = wacli ] && return 0
      readable=$((readable + 1))
      continue
    fi
    state=$(/usr/bin/awk '/^State:/{print $2}' "$process_dir/status" 2>/dev/null) || return 2
    if [ "$state" = Z ]; then
      readable=$((readable + 1))
      continue
    fi
    return 2
  done
  [ "$readable" -gt 0 ] && return 1
  return 2
}

require_no_versioned_wacli_process() {
  local context=$1 allowed_pid=${2:-} state
  if versioned_wacli_process_state "$allowed_pid"; then
    fail "$context and another wacli process is running; stop it before promotion"
  else
    state=$?
  fi
  case $state in
    1) return 0 ;;
    *) fail "$context and /proc could not prove that no versioned wacli process is running" ;;
  esac
}

active_service_preflight() {
  local active_rc main_pid running_exe running_sha target_exe
  if [ -z "$SYSTEMCTL_BIN" ]; then
    require_no_versioned_wacli_process "systemctl is unavailable"
    return 0
  fi
  if "$SYSTEMCTL_BIN" --user is-active wacli-sync.service >/dev/null 2>&1; then
    active_rc=0
  else
    active_rc=$?
  fi
  case $active_rc in
    0) ;;
    3|4)
      require_no_versioned_wacli_process "wacli-sync.service is inactive or absent"
      return 0
      ;;
    *)
      require_no_versioned_wacli_process "user manager is unreachable"
      return 0
      ;;
  esac

  main_pid=$("$SYSTEMCTL_BIN" --user show wacli-sync.service --property MainPID --value 2>/dev/null) \
    || fail "wacli-sync.service is active but MainPID could not be queried; stop it before promoting v$VERSION"
  [[ $main_pid =~ ^[1-9][0-9]*$ ]] \
    || fail "wacli-sync.service is active but reported invalid MainPID '$main_pid'; stop it before promoting v$VERSION"
  [ -L "$PROC_ROOT/$main_pid/exe" ] \
    || fail "wacli-sync.service MainPID $main_pid has no resolvable executable; stop it before promoting v$VERSION"
  running_exe=$(/usr/bin/readlink -f "$PROC_ROOT/$main_pid/exe" 2>/dev/null) \
    || fail "wacli-sync.service MainPID $main_pid executable cannot be resolved; stop it before promoting v$VERSION"
  target_exe=$(/usr/bin/realpath -m "$TARGET")
  [ "$running_exe" = "$target_exe" ] \
    || fail "wacli-sync.service runs $running_exe, not pinned target $target_exe; stop it before promoting v$VERSION"
  running_sha=$(/usr/bin/sha256sum "$PROC_ROOT/$main_pid/exe" 2>/dev/null | /usr/bin/awk '{print $1}') \
    || fail "wacli-sync.service MainPID $main_pid executable cannot be hashed; stop it before promoting v$VERSION"
  [ "$running_sha" = "$BINARY_SHA256" ] \
    || fail "wacli-sync.service MainPID $main_pid does not run the reviewed v$VERSION binary; stop it before promotion"
  require_no_versioned_wacli_process "wacli-sync.service is active" "$main_pid"
}

active_service_preflight

if [ "$MODE" = preflight ]; then
  echo "wacli v$VERSION preflight — unit/binary cutover may proceed"
  exit 0
fi

binary_hash() {
  /usr/bin/sha256sum "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
}

binary_smoke() {
  local candidate=$1 scratch=$2 version doctor
  [ -x "$candidate" ] || return 1
  [ "$(binary_hash "$candidate")" = "$BINARY_SHA256" ] || return 1
  version=$("$candidate" --version 2>&1) || return 1
  [ "$version" = "wacli $VERSION" ] || return 1
  /usr/bin/mkdir -p "$scratch"
  doctor=$("$candidate" --store "$scratch/store" doctor 2>&1) || return 1
  /usr/bin/grep -Eq '^FTS5[[:space:]]+true$' <<<"$doctor"
}

is_converged() {
  local scratch=$1
  binary_smoke "$TARGET" "$scratch" || return 1
  [ -L "$LIVE" ] || return 1
  # A direct link is part of the accepted state. readlink -f alone would accept
  # LIVE -> mutable-alias -> TARGET, which can be repointed after verification.
  [ "$(/usr/bin/readlink "$LIVE" 2>/dev/null)" = "$TARGET" ]
}

CHECK_TMP=$(/usr/bin/mktemp -d /tmp/wacli-check.XXXXXX) || exit 1
cleanup_check() { /usr/bin/rm -rf "$CHECK_TMP"; }
trap cleanup_check EXIT

if is_converged "$CHECK_TMP"; then
  echo "wacli $VERSION — installed and verified ($TARGET)"
  exit 0
fi

if [ "$MODE" = check ]; then
  [ -x "$TARGET" ] || echo "wacli-install: missing pinned target $TARGET" >&2
  [ -L "$LIVE" ] || echo "wacli-install: live path is not a symlink: $LIVE" >&2
  fail "installation is not converged; run wacli-install.sh install"
fi

WORK=$(/usr/bin/mktemp -d /tmp/wacli-install.XXXXXX) || exit 1
TARGET_TMP=
LIVE_TMP=
cleanup_all() {
  [ -z "$TARGET_TMP" ] || /usr/bin/rm -f -- "$TARGET_TMP"
  [ -z "$LIVE_TMP" ] || /usr/bin/rm -f -- "$LIVE_TMP"
  /usr/bin/rm -rf "$WORK" "$CHECK_TMP"
}
trap cleanup_all EXIT
ARCHIVE=$WORK/wacli.tar.gz
EXTRACT=$WORK/extract

"$CURL_BIN" -q --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
  "$URL" -o "$ARCHIVE" || fail "could not download pinned release $URL"

GOT_ARCHIVE_SHA256=$(binary_hash "$ARCHIVE")
[ "$GOT_ARCHIVE_SHA256" = "$ARCHIVE_SHA256" ] || {
  echo "wacli-install: archive checksum mismatch" >&2
  echo "  expected $ARCHIVE_SHA256" >&2
  echo "  got      $GOT_ARCHIVE_SHA256" >&2
  exit 1
}

# Validate every member before extraction. Reject links/devices, absolute paths,
# traversal, backslash spellings, and archives without exactly one root payload.
while IFS= read -r mode rest; do
  case ${mode:0:1} in
    -|d) ;;
    *) fail "archive contains non-file member: $rest" ;;
  esac
done < <(/usr/bin/tar -tvzf "$ARCHIVE")

PAYLOAD_MEMBERS=0
while IFS= read -r member; do
  normalized=${member#./}
  case $normalized in
    ''|LICENSE|README.md) ;;
    wacli) PAYLOAD_MEMBERS=$((PAYLOAD_MEMBERS + 1)) ;;
    /*|..|../*|*/..|*/../*|*\\*) fail "archive contains unsafe member: $member" ;;
    *) fail "archive contains unexpected member: $member" ;;
  esac
done < <(/usr/bin/tar -tzf "$ARCHIVE")
[ "$PAYLOAD_MEMBERS" -eq 1 ] || fail "archive must contain exactly one root wacli payload"

/usr/bin/mkdir -p "$EXTRACT"
/usr/bin/tar -xzf "$ARCHIVE" --no-same-owner --no-same-permissions -C "$EXTRACT"
CANDIDATE=$EXTRACT/wacli
[ "$(binary_hash "$CANDIDATE")" = "$BINARY_SHA256" ] || fail "extracted binary checksum mismatch"
/usr/bin/chmod 0755 "$CANDIDATE"
binary_smoke "$CANDIDATE" "$WORK/doctor" || fail "candidate failed version/FTS5 smoke checks"

backup_existing() {
  local source=$1 label=$2 backup
  [ -e "$source" ] || [ -L "$source" ] || return 0
  backup=$BACKUP_ROOT/$(/usr/bin/date +%Y%m%d-%H%M%S)-$$
  /usr/bin/mkdir -p "$backup"
  /usr/bin/cp -a "$source" "$backup/$label"
  echo "  preserved existing $source at $backup/$label"
}

/usr/bin/mkdir -p "$TARGET_DIR" "$BIN_DIR"
if [ -e "$TARGET" ] && [ "$(binary_hash "$TARGET")" != "$BINARY_SHA256" ]; then
  backup_existing "$TARGET" pinned-target
fi
if [ -e "$LIVE" ] || [ -L "$LIVE" ]; then
  if [ ! -L "$LIVE" ] || [ "$(/usr/bin/readlink "$LIVE" 2>/dev/null)" != "$TARGET" ]; then
    backup_existing "$LIVE" live-wacli
  fi
fi

# Snapshot both publication points before changing either. Candidate smoke above
# is necessary but not sufficient: the live path is exercised after the switch,
# and any install/link/post-smoke failure restores the exact previous state.
ROLLBACK=$WORK/rollback
/usr/bin/mkdir -p "$ROLLBACK"
TARGET_HAD=0
LIVE_HAD=0
if [ -e "$TARGET" ]; then
  /usr/bin/cp -a "$TARGET" "$ROLLBACK/target"
  TARGET_HAD=1
fi
if [ -e "$LIVE" ] || [ -L "$LIVE" ]; then
  /usr/bin/cp -a "$LIVE" "$ROLLBACK/live"
  LIVE_HAD=1
fi

restore_snapshot() {
  local rc=0 restore_tmp
  /usr/bin/rm -f -- "$TARGET_TMP" "$LIVE_TMP" 2>/dev/null || rc=1
  TARGET_TMP=
  LIVE_TMP=

  if [ "$TARGET_HAD" -eq 1 ]; then
    restore_tmp=$TARGET.restore.$$
    /usr/bin/cp -a "$ROLLBACK/target" "$restore_tmp" && /usr/bin/mv -Tf "$restore_tmp" "$TARGET" || rc=1
  else
    /usr/bin/rm -f -- "$TARGET" || rc=1
  fi
  if [ "$LIVE_HAD" -eq 1 ]; then
    restore_tmp=$LIVE.restore.$$
    /usr/bin/cp -a "$ROLLBACK/live" "$restore_tmp" && /usr/bin/mv -Tf "$restore_tmp" "$LIVE" || rc=1
  else
    /usr/bin/rm -f -- "$LIVE" || rc=1
  fi
  return "$rc"
}

TARGET_TMP=$TARGET.tmp.$$
if ! /usr/bin/install -m 0755 "$CANDIDATE" "$TARGET_TMP" || ! /usr/bin/mv -Tf "$TARGET_TMP" "$TARGET"; then
  restore_snapshot || fail "candidate publication failed and rollback also failed"
  fail "candidate publication failed; previous installation restored"
fi
TARGET_TMP=

LIVE_TMP=$LIVE.tmp.$$
if ! /usr/bin/ln -s "$TARGET" "$LIVE_TMP" || ! /usr/bin/mv -Tf "$LIVE_TMP" "$LIVE"; then
  restore_snapshot || fail "live-link publication failed and rollback also failed"
  fail "live-link publication failed; previous installation restored"
fi
LIVE_TMP=

if ! is_converged "$WORK/final-doctor"; then
  restore_snapshot || fail "post-install verification failed and rollback also failed"
  fail "post-install verification failed; previous installation restored"
fi

echo "wacli $VERSION installed and verified -> $TARGET"
