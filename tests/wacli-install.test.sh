#!/usr/bin/env bash
# Hermetic regression tests for the pinned wacli installer.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER=$REPO/plugins/hov-stack/skills/hov-setup/scripts/wacli-install.sh
TMP=$(mktemp -d /tmp/wacli-install-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
failures=0
ok() { pass=$((pass + 1)); }
bad() { failures=$((failures + 1)); echo "FAIL: $*" >&2; }

mkdir -p "$TMP/bin" "$TMP/fixtures"
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=
[ -z "${WACLI_TEST_CURL_LOG:-}" ] || printf 'curl invoked\n' >>"$WACLI_TEST_CURL_LOG"
while (($#)); do
  if [ "$1" = -o ]; then
    shift
    out=$1
  fi
  shift
done
[ -n "$out" ]
[ "${CURL_SHOULD_FAIL:-0}" != 1 ]
cp "$FIXTURE_ARCHIVE" "$out"
SH
chmod +x "$TMP/bin/curl"

write_inactive_systemctl() {
  cat >"$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 3
SH
  chmod +x "$TMP/bin/systemctl"
}
write_inactive_systemctl

make_binary() {
  local path=$1 version=$2 fts=${3:-true}
  cat >"$path" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  echo 'wacli $version'
  exit 0
fi
case " \$* " in
  *' doctor ')
    printf 'STORE             fixture\\nFTS5              $fts\\n'
    exit 0
    ;;
esac
exit 64
SH
  chmod +x "$path"
}

make_archive() {
  local name=$1 version=$2 fts=${3:-true} root
  root=$TMP/fixtures/$name
  mkdir -p "$root"
  make_binary "$root/wacli" "$version" "$fts"
  printf 'fixture license\n' >"$root/LICENSE"
  printf 'fixture readme\n' >"$root/README.md"
  tar -czf "$TMP/fixtures/$name.tar.gz" -C "$root" ./
}

run_installer_mode() {
  local mode=$1
  shift
  local root=$1 archive=$2 archive_sha=$3 binary_sha=$4 version=${5:-9.9.9}
  shift 5 || true
  if [ "${WACLI_TEST_SKIP_PROC_FIXTURE:-0}" != 1 ]; then
    mkdir -p "$root/proc/1111"
    [ -L "$root/proc/1111/exe" ] || ln -s /usr/bin/bash "$root/proc/1111/exe"
  fi
  PATH="$TMP/bin:/usr/bin:/bin" \
  FIXTURE_ARCHIVE="$archive" \
  WACLI_INSTALL_TEST_MODE=1 \
  WACLI_INSTALL_TEST_ROOT="$root" \
  WACLI_INSTALL_TEST_PROC_ROOT="$root/proc" \
  WACLI_INSTALL_TEST_VERSION="$version" \
  WACLI_INSTALL_TEST_URL=https://fixture.invalid/wacli.tar.gz \
  WACLI_INSTALL_TEST_ARCHIVE_SHA256="$archive_sha" \
  WACLI_INSTALL_TEST_BINARY_SHA256="$binary_sha" \
  "$@" "$INSTALLER" "$mode"
}

run_installer() {
  run_installer_mode install "$@"
}

make_archive good 9.9.9 true
GOOD_ARCHIVE=$TMP/fixtures/good.tar.gz
GOOD_ARCHIVE_SHA=$(sha256sum "$GOOD_ARCHIVE" | awk '{print $1}')
GOOD_BINARY_SHA=$(sha256sum "$TMP/fixtures/good/wacli" | awk '{print $1}')

# 1. First install verifies the fixture and exposes one atomic live symlink.
ROOT=$TMP/case-first
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "first install exited $status: $out"; fi
if [ -L "$ROOT/bin/wacli" ] && [ "$(readlink -f "$ROOT/bin/wacli")" = "$ROOT/lib/wacli/v9.9.9/wacli" ]; then ok; else bad "live symlink does not resolve to pinned target"; fi
if [ "$("$ROOT/bin/wacli" --version)" = 'wacli 9.9.9' ]; then ok; else bad "installed binary failed version smoke"; fi

# 2. A converged install is a no-op and never reaches curl again.
out=$(CURL_SHOULD_FAIL=1 run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ] && [[ $out == *'installed and verified'* ]]; then ok; else bad "idempotent rerun reached download or failed: $out"; fi

# 3. Check mode succeeds only for the converged tuple.
out=$(run_installer_mode check "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "check mode rejected converged install: $out"; fi

# 4. Archive checksum mismatch refuses before touching an existing live binary.
ROOT=$TMP/case-checksum
mkdir -p "$ROOT/bin"
printf '#!/usr/bin/env bash\necho foreign-live\n' >"$ROOT/bin/wacli"
chmod +x "$ROOT/bin/wacli"
before=$(sha256sum "$ROOT/bin/wacli" | awk '{print $1}')
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$(printf '%064d' 0)" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
after=$(sha256sum "$ROOT/bin/wacli" | awk '{print $1}')
if [ "$status" -ne 0 ] && [[ $out == *'archive checksum mismatch'* ]]; then ok; else bad "checksum mismatch was not refused: $out"; fi
if [ "$before" = "$after" ] && [ ! -L "$ROOT/bin/wacli" ]; then ok; else bad "checksum failure changed the existing live binary"; fi

# 5. A traversal member is rejected even when the archive hash is accepted.
UNSAFE=$TMP/fixtures/unsafe.tar.gz
python3 - "$UNSAFE" <<'PY'
import io, tarfile, sys
with tarfile.open(sys.argv[1], 'w:gz') as tf:
    for name, data, mode in [
        ('wacli', b'#!/bin/sh\necho wacli 9.9.9\n', 0o755),
        ('../escape', b'bad', 0o644),
    ]:
        item = tarfile.TarInfo(name)
        item.mode = mode
        item.size = len(data)
        tf.addfile(item, io.BytesIO(data))
PY
UNSAFE_SHA=$(sha256sum "$UNSAFE" | awk '{print $1}')
out=$(run_installer "$TMP/case-unsafe" "$UNSAFE" "$UNSAFE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'unsafe member'* ]]; then ok; else bad "unsafe archive was not refused: $out"; fi
if [ ! -e "$TMP/escape" ]; then ok; else bad "unsafe archive escaped its extraction root"; fi

# 5b. A link under an otherwise allowed member name is rejected before extraction.
LINK_ARCHIVE=$TMP/fixtures/link.tar.gz
python3 - "$LINK_ARCHIVE" <<'PY'
import io, tarfile, sys
with tarfile.open(sys.argv[1], 'w:gz') as tf:
    data = b'#!/bin/sh\necho wacli 9.9.9\n'
    binary = tarfile.TarInfo('wacli')
    binary.mode = 0o755
    binary.size = len(data)
    tf.addfile(binary, io.BytesIO(data))
    link = tarfile.TarInfo('README.md')
    link.type = tarfile.SYMTYPE
    link.linkname = '/etc/passwd'
    tf.addfile(link)
PY
LINK_ARCHIVE_SHA=$(sha256sum "$LINK_ARCHIVE" | awk '{print $1}')
out=$(run_installer "$TMP/case-link" "$LINK_ARCHIVE" "$LINK_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'non-file member'* ]]; then ok; else bad "archive link was not refused: $out"; fi

# 6. A hash-valid candidate that lacks FTS5 fails before promotion.
make_archive nofts 9.9.9 false
NOFTS_ARCHIVE=$TMP/fixtures/nofts.tar.gz
NOFTS_ARCHIVE_SHA=$(sha256sum "$NOFTS_ARCHIVE" | awk '{print $1}')
NOFTS_BINARY_SHA=$(sha256sum "$TMP/fixtures/nofts/wacli" | awk '{print $1}')
out=$(run_installer "$TMP/case-nofts" "$NOFTS_ARCHIVE" "$NOFTS_ARCHIVE_SHA" "$NOFTS_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'candidate failed version/FTS5 smoke checks'* ]]; then ok; else bad "FTS5-negative candidate was promoted or misdiagnosed: $out"; fi
if [ ! -e "$TMP/case-nofts/bin/wacli" ]; then ok; else bad "failed candidate created a live binary"; fi

# 7. A successful promotion preserves a foreign live binary before switching.
ROOT=$TMP/case-backup
mkdir -p "$ROOT/bin"
printf '#!/usr/bin/env bash\necho foreign-live\n' >"$ROOT/bin/wacli"
chmod +x "$ROOT/bin/wacli"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "promotion over foreign live binary failed: $out"; fi
backup=$(find "$ROOT/backups" -type f -name live-wacli -print -quit 2>/dev/null)
if [ -n "$backup" ] && grep -q 'foreign-live' "$backup"; then ok; else bad "foreign live binary was not preserved"; fi
if [ -L "$ROOT/bin/wacli" ] && [ "$("$ROOT/bin/wacli" --version)" = 'wacli 9.9.9' ]; then ok; else bad "promoted live path is not the verified binary"; fi

# 7b. A candidate that fails only after publication rolls both paths back.
FLAKY_ROOT=$TMP/fixtures/flaky
FLAKY_COUNT=$TMP/flaky-doctor-count
mkdir -p "$FLAKY_ROOT"
cat >"$FLAKY_ROOT/wacli" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then echo 'wacli 9.9.9'; exit 0; fi
case " \$* " in
  *' doctor ')
    count=0
    [ ! -f "$FLAKY_COUNT" ] || count=\$(cat "$FLAKY_COUNT")
    count=\$((count + 1))
    printf '%s\n' "\$count" >"$FLAKY_COUNT"
    if [ "\$count" -eq 1 ]; then
      printf 'FTS5              true\\n'
    else
      printf 'FTS5              false\\n'
    fi
    exit 0
    ;;
esac
exit 64
SH
chmod +x "$FLAKY_ROOT/wacli"
printf 'fixture\n' >"$FLAKY_ROOT/LICENSE"
printf 'fixture\n' >"$FLAKY_ROOT/README.md"
FLAKY_ARCHIVE=$TMP/fixtures/flaky.tar.gz
tar -czf "$FLAKY_ARCHIVE" -C "$FLAKY_ROOT" ./
FLAKY_ARCHIVE_SHA=$(sha256sum "$FLAKY_ARCHIVE" | awk '{print $1}')
FLAKY_BINARY_SHA=$(sha256sum "$FLAKY_ROOT/wacli" | awk '{print $1}')
ROOT=$TMP/case-rollback
mkdir -p "$ROOT/bin"
printf '#!/usr/bin/env bash\necho rollback-live\n' >"$ROOT/bin/wacli"
chmod +x "$ROOT/bin/wacli"
out=$(run_installer "$ROOT" "$FLAKY_ARCHIVE" "$FLAKY_ARCHIVE_SHA" "$FLAKY_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'previous installation restored'* ]]; then ok; else bad "post-publication smoke failure did not report rollback: $out"; fi
if [ ! -L "$ROOT/bin/wacli" ] && grep -q rollback-live "$ROOT/bin/wacli"; then ok; else bad "post-publication failure did not restore the prior live executable"; fi
if [ ! -e "$ROOT/lib/wacli/v9.9.9/wacli" ]; then ok; else bad "post-publication failure left a rejected target live"; fi

# 7c. Unexpected target types are rejected before any publication.
ROOT=$TMP/case-target-directory
mkdir -p "$ROOT/lib/wacli/v9.9.9/wacli" "$ROOT/bin"
printf '#!/usr/bin/env bash\necho directory-live\n' >"$ROOT/bin/wacli"
chmod +x "$ROOT/bin/wacli"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'unexpected pinned target type'* ]]; then ok; else bad "target directory was not rejected before promotion: $out"; fi
if grep -q directory-live "$ROOT/bin/wacli"; then ok; else bad "target-type refusal changed the live executable"; fi

# 7d. A mutable intermediate symlink is not accepted as converged.
mkdir -p "$TMP/alias"
ln -s "$TMP/case-first/lib/wacli/v9.9.9/wacli" "$TMP/alias/current"
rm "$TMP/case-first/bin/wacli"
ln -s "$TMP/alias/current" "$TMP/case-first/bin/wacli"
out=$(run_installer_mode check "$TMP/case-first" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'installation is not converged'* ]]; then ok; else bad "indirect live symlink was accepted as immutable state: $out"; fi

# 7e. An active old daemon is identified by its process executable, not by the
# mutable convenience link, and blocks automatic pin promotion.
ROOT=$TMP/case-active-old-daemon
mkdir -p "$ROOT/bin" "$ROOT/proc/4242"
printf '#!/usr/bin/env bash\necho old-daemon-live\n' >"$ROOT/bin/wacli"
chmod +x "$ROOT/bin/wacli"
ln -s "$ROOT/bin/wacli" "$ROOT/proc/4242/exe"
cat >"$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '--user is-active wacli-sync.service') exit 0 ;;
  '--user show wacli-sync.service --property MainPID --value')
    printf '%s\n' "${SYSTEMCTL_MAIN_PID:-4242}"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'not pinned target'* ]]; then ok; else bad "active old daemon did not block pin promotion: $out"; fi
if grep -q old-daemon-live "$ROOT/bin/wacli"; then ok; else bad "refused active-daemon promotion changed the live binary"; fi

# An active service with no usable MainPID or process executable fails closed.
ROOT=$TMP/case-active-invalid-pid
out=$(SYSTEMCTL_MAIN_PID=0 run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *"invalid MainPID '0'"* ]]; then ok; else bad "active service with MainPID 0 did not fail closed: $out"; fi
ROOT=$TMP/case-active-missing-exe
out=$(SYSTEMCTL_MAIN_PID=777 run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'has no resolvable executable'* ]]; then ok; else bad "active service with missing process executable did not fail closed: $out"; fi

# An inactive/absent unit does not vouch for a manually-started daemon.
write_inactive_systemctl
ROOT=$TMP/case-inactive-manual-daemon
mkdir -p "$ROOT/proc/4242" "$ROOT/lib/wacli/v8.8.8"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/lib/wacli/v8.8.8/wacli"
chmod +x "$ROOT/lib/wacli/v8.8.8/wacli"
ln -s "$ROOT/lib/wacli/v8.8.8/wacli" "$ROOT/proc/4242/exe"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'wacli process is running'* ]]; then ok; else bad "inactive managed daemon did not block promotion: $out"; fi

# A readable self/dummy entry cannot hide another same-UID process whose exe is
# inaccessible (hidepid/ptrace-shaped). Incomplete peer visibility fails closed.
ROOT=$TMP/case-incomplete-peer-proc
mkdir -p "$ROOT/proc/2222"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'/proc could not prove'* ]]; then ok; else bad "incomplete peer process visibility did not fail closed: $out"; fi

# A readable wacli executable outside the managed install tree also blocks;
# renamed copies remain part of the documented full-trust laundering boundary.
write_inactive_systemctl
ROOT=$TMP/case-external-wacli-process
mkdir -p "$ROOT/proc/3333" "$TMP/external-wacli"
printf '#!/usr/bin/bash\nexit 0\n' >"$TMP/external-wacli/wacli"
chmod +x "$TMP/external-wacli/wacli"
ln -s "$TMP/external-wacli/wacli" "$ROOT/proc/3333/exe"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'another wacli process is running'* ]]; then ok; else bad "external wacli process did not block promotion: $out"; fi

# A non-dumpable-shaped peer may fall back to readable comm+argv0 metadata.
ROOT=$TMP/case-readable-peer-fallback
mkdir -p "$ROOT/proc/2223"
printf 'systemd\n' >"$ROOT/proc/2223/comm"
printf '/usr/lib/systemd/systemd\0--user\0' >"$ROOT/proc/2223/cmdline"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "readable non-wacli peer metadata blocked install: $out"; fi

# A zombie cannot execute and legitimately has an empty cmdline/exe. Readable
# State=Z is positive evidence that the peer can no longer execute.
ROOT=$TMP/case-readable-zombie-peer
mkdir -p "$ROOT/proc/2224"
printf 'zombie\n' >"$ROOT/proc/2224/comm"
: >"$ROOT/proc/2224/cmdline"
printf 'Name:\tzombie\nState:\tZ (zombie)\n' >"$ROOT/proc/2224/status"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "readable zombie peer blocked install: $out"; fi

# Mutate only fake /proc files immediately after the real Bash read.
# This makes exit races deterministic without sleeps or timing assumptions in
# the tests, and does not replace any installer decision or read result.
cat >"$TMP/proc-race-env" <<'SH'
read() {
  local read_status=0 reads=0
  builtin read "$@" || read_status=$?
  if [ "$#" -eq 2 ] && [ "$1" = -r ] && [ "$2" = comm ]; then
    [ ! -f "$WACLI_INSTALL_TEST_ROOT/metadata-reads" ] \
      || reads=$(cat "$WACLI_INSTALL_TEST_ROOT/metadata-reads")
    reads=$((reads + 1))
    printf '%s\n' "$reads" >"$WACLI_INSTALL_TEST_ROOT/metadata-reads"
    case $WACLI_PROC_EVENT in
      vanished) rm -rf "$WACLI_INSTALL_TEST_ROOT/proc/2225" ;;
      dead-on-retry)
        if [ "$reads" -eq 2 ]; then
          printf 'State:\tX (dead)\n' >"$WACLI_INSTALL_TEST_ROOT/proc/2225/status"
        fi
        ;;
      wacli-on-retry)
        if [ "$reads" -eq 2 ]; then
          printf '/opt/wacli\0sync\0' >"$WACLI_INSTALL_TEST_ROOT/proc/2225/cmdline"
        fi
        ;;
      readable-on-retry)
        if [ "$reads" -eq 2 ]; then
          printf '/usr/bin/peer\0' >"$WACLI_INSTALL_TEST_ROOT/proc/2225/cmdline"
        fi
        ;;
    esac
  fi
  return "$read_status"
}
SH

cat >"$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WACLI_INSTALL_TEST_ROOT/systemctl-calls"
[ "$*" = '--user is-active wacli-sync.service' ] && exit 3
exit 91
SH

make_ambiguous_peer() {
  mkdir -p "$ROOT/proc/2225"
  printf 'peer\n' >"$ROOT/proc/2225/comm"
  : >"$ROOT/proc/2225/cmdline"
  printf 'State:\tD (disk sleep)\n' >"$ROOT/proc/2225/status"
}

run_peer_preflight() {
  out=$(run_installer_mode preflight "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" \
    "$GOOD_BINARY_SHA" 9.9.9 env BASH_ENV="$TMP/proc-race-env" \
    WACLI_PROC_EVENT="${1:-none}" CURL_SHOULD_FAIL=1 \
    WACLI_TEST_CURL_LOG="$ROOT/curl-called" 2>&1); status=$?
  if [ ! -e "$ROOT/curl-called" ] && [ ! -e "$ROOT/bin" ] \
     && [ ! -e "$ROOT/lib" ] && [ ! -e "$ROOT/backups" ] \
     && [ "$(cat "$ROOT/systemctl-calls")" = '--user is-active wacli-sync.service' ]; then
    ok
  else
    bad "preflight fixture ${ROOT##*/} downloaded, installed, or controlled a service"
  fi
}

peer_ok() { ok; printf 'ok — %s\n' "$1"; }

for dead_state in X x; do
  ROOT=$TMP/case-dead-peer-$dead_state
  make_ambiguous_peer
  printf 'State:\t%s (dead)\n' "$dead_state" >"$ROOT/proc/2225/status"
  run_peer_preflight
  if [ "$status" -eq 0 ]; then
    peer_ok "dead State=$dead_state peer completes proof"
  else
    bad "dead State=$dead_state peer blocked preflight: $out"
  fi
done

# A process can lose comm before the dead state becomes observable, too.
ROOT=$TMP/case-dead-peer-missing-comm
make_ambiguous_peer
rm "$ROOT/proc/2225/comm"
printf 'State:\tX (dead)\n' >"$ROOT/proc/2225/status"
run_peer_preflight
if [ "$status" -eq 0 ]; then peer_ok 'dead peer with missing comm completes proof'; else bad "dead peer with missing comm blocked preflight: $out"; fi

for comm_result in success failure; do
  ROOT=$TMP/case-vanished-peer-$comm_result
  make_ambiguous_peer
  # No newline makes Bash read return 1, with the directory removed afterward.
  [ "$comm_result" != failure ] || printf 'peer' >"$ROOT/proc/2225/comm"
  run_peer_preflight vanished
  if [ "$status" -eq 0 ] && [ ! -d "$ROOT/proc/2225" ]; then
    peer_ok "vanished peer after comm read $comm_result completes proof"
  else
    bad "vanished peer after comm read $comm_result blocked preflight: $out"
  fi
done

ROOT=$TMP/case-vanished-only-peer
make_ambiguous_peer
WACLI_TEST_SKIP_PROC_FIXTURE=1 run_peer_preflight vanished
if [ "$status" -ne 0 ] && [ ! -d "$ROOT/proc/2225" ] \
   && [[ $out == *'/proc could not prove'* ]]; then
  peer_ok 'vanished-only proc tree still requires readable evidence'
else
  bad "vanished-only proc tree was not refused: $out"
fi

for event in dead-on-retry readable-on-retry; do
  ROOT=$TMP/case-peer-$event
  make_ambiguous_peer
  run_peer_preflight "$event"
  if [ "$status" -eq 0 ] && [ "$(cat "$ROOT/metadata-reads")" -eq 2 ]; then
    peer_ok "$event completes proof after rereading"
  else
    bad "$event did not resolve on the second read: $out"
  fi
done

ROOT=$TMP/case-persistent-ambiguous-peer
make_ambiguous_peer
run_peer_preflight
if [ "$status" -ne 0 ] && [ "$(cat "$ROOT/metadata-reads")" -eq 3 ] \
   && [[ $out == *'pid 2225: empty or unreadable cmdline, state D after 3 reads'* ]] \
   && [[ $out == *'/proc could not prove'* ]]; then
  peer_ok 'persistent ambiguity fails closed with bounded reads and PID/reason'
else
  bad "persistent ambiguity did not fail closed after three reads with details: $out"
fi

# No dead state or readable comm means an incomplete proof, even with argv0.
ROOT=$TMP/case-persistent-missing-comm
make_ambiguous_peer
rm "$ROOT/proc/2225/comm"
printf '/usr/bin/peer\0' >"$ROOT/proc/2225/cmdline"
run_peer_preflight
if [ "$status" -ne 0 ] && [[ $out == *'pid 2225: unreadable comm after 3 reads'* ]] \
   && [[ $out == *'/proc could not prove'* ]]; then
  peer_ok 'persistent missing comm still fails closed'
else
  bad "persistent missing comm was not refused: $out"
fi

# Positive argv0 evidence takes priority, even over a stale dead-state sample.
for argv0 in wacli /opt/wacli; do
  ROOT=$TMP/case-wacli-argv-${argv0##*/}-${#argv0}
  make_ambiguous_peer
  printf '%s\0sync\0' "$argv0" >"$ROOT/proc/2225/cmdline"
  printf 'State:\tX (dead)\n' >"$ROOT/proc/2225/status"
  run_peer_preflight
  if [ "$status" -ne 0 ] && [[ $out == *'another wacli process is running'* ]]; then
    peer_ok "running argv0 $argv0 still blocks preflight"
  else
    bad "running argv0 $argv0 was not detected: $out"
  fi
done

ROOT=$TMP/case-wacli-on-retry
make_ambiguous_peer
run_peer_preflight wacli-on-retry
if [ "$status" -ne 0 ] && [ "$(cat "$ROOT/metadata-reads")" -eq 2 ] \
   && [[ $out == *'another wacli process is running'* ]]; then
  peer_ok 'running wacli discovered on reread still blocks preflight'
else
  bad "running wacli on reread was not detected: $out"
fi

write_inactive_systemctl

# A host without systemctl uses the same process proof rather than skipping it.
ROOT=$TMP/case-no-systemctl-clean
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9   env WACLI_INSTALL_TEST_NO_SYSTEMCTL=1 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "clean no-systemctl process scan blocked install: $out"; fi

ROOT=$TMP/case-no-systemctl-running
mkdir -p "$ROOT/proc/4242" "$ROOT/lib/wacli/v8.8.8"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/lib/wacli/v8.8.8/wacli"
chmod +x "$ROOT/lib/wacli/v8.8.8/wacli"
ln -s "$ROOT/lib/wacli/v8.8.8/wacli" "$ROOT/proc/4242/exe"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9   env WACLI_INSTALL_TEST_NO_SYSTEMCTL=1 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'wacli process is running'* ]]; then ok; else bad "no-systemctl running process did not block promotion: $out"; fi

# A headless user manager falls back to a readable same-user /proc scan. A
# clean process table may proceed (CI/fresh install), a running versioned wacli
# blocks promotion, and an unreadable process table still fails closed.
cat >"$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/systemctl"
ROOT=$TMP/case-manager-unreachable-clean
mkdir -p "$ROOT/proc/self"
ln -s /usr/bin/bash "$ROOT/proc/self/exe"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ]; then ok; else bad "clean headless process scan blocked install: $out"; fi

ROOT=$TMP/case-manager-unreachable-running
mkdir -p "$ROOT/proc/self" "$ROOT/proc/4242" "$ROOT/lib/wacli/v8.8.8"
ln -s /usr/bin/bash "$ROOT/proc/self/exe"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/lib/wacli/v8.8.8/wacli"
chmod +x "$ROOT/lib/wacli/v8.8.8/wacli"
ln -s "$ROOT/lib/wacli/v8.8.8/wacli" "$ROOT/proc/4242/exe"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'wacli process is running'* ]]; then ok; else bad "headless running process did not block promotion: $out"; fi

ROOT=$TMP/case-manager-unreachable-unreadable-proc
out=$(WACLI_TEST_SKIP_PROC_FIXTURE=1 run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'/proc could not prove'* ]]; then ok; else bad "unreadable headless process scan did not fail closed: $out"; fi

# Matching path text is insufficient when the running inode is not the reviewed
# binary (for example, after an in-place replacement while the daemon stayed up).
write_inactive_systemctl
ROOT=$TMP/case-active-wrong-hash
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
printf '#!/usr/bin/env bash\necho wrong-running-inode\n' >"$ROOT/lib/wacli/v9.9.9/wacli"
chmod +x "$ROOT/lib/wacli/v9.9.9/wacli"
mkdir -p "$ROOT/proc/4242"
ln -s "$ROOT/lib/wacli/v9.9.9/wacli" "$ROOT/proc/4242/exe"
cat >"$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '--user is-active wacli-sync.service') exit 0 ;;
  '--user show wacli-sync.service --property MainPID --value') echo 4242 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'does not run the reviewed'* ]]; then ok; else bad "active process hash mismatch did not block promotion: $out"; fi

# The exact pinned process is accepted, and a converged install remains offline.
write_inactive_systemctl
ROOT=$TMP/case-active-current-daemon
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
mkdir -p "$ROOT/proc/4242"
ln -s "$ROOT/lib/wacli/v9.9.9/wacli" "$ROOT/proc/4242/exe"
cat >"$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '--user is-active wacli-sync.service') exit 0 ;;
  '--user show wacli-sync.service --property MainPID --value') echo 4242 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/systemctl"
out=$(CURL_SHOULD_FAIL=1 run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
if [ "$status" -eq 0 ] && [[ $out == *'installed and verified'* ]]; then ok; else bad "active current daemon was rejected or reached download: $out"; fi

# The verified service process does not vouch for a second manually started managed old daemon.
mkdir -p "$ROOT/proc/5252" "$ROOT/lib/wacli/v8.8.8"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/lib/wacli/v8.8.8/wacli"
chmod +x "$ROOT/lib/wacli/v8.8.8/wacli"
ln -s "$ROOT/lib/wacli/v8.8.8/wacli" "$ROOT/proc/5252/exe"
out=$(run_installer "$ROOT" "$GOOD_ARCHIVE" "$GOOD_ARCHIVE_SHA" "$GOOD_BINARY_SHA" 9.9.9 2>&1); status=$?
write_inactive_systemctl
if [ "$status" -ne 0 ] && [[ $out == *'another wacli process is running'* ]]; then ok; else bad "active service hid a second manually started managed daemon: $out"; fi

# 7g. The install-time and hook-time integrity pins are one reviewed fact.
installer_pin=$(awk -F= '/^PIN_BINARY_SHA256=/{print $2}' "$INSTALLER")
guard_pin=$(sed -n "s/^const REVIEWED_BINARY_SHA256 = '\([0-9a-f]\{64\}\)';$/\1/p" \
  "$REPO/hooks/PreToolUse/whatsapp-guard.js")
if [ -n "$installer_pin" ] && [ "$guard_pin" = "$installer_pin" ]; then
  ok
else
  bad "installer and runtime guard SHA-256 pins diverged"
fi

# Production PATH hardening reads real /proc and lives in the separate
# wacli-install-production.test.sh suite, which runs in its own PID namespace.

# 8. Test-mode source overrides cannot target the filesystem root, regardless
# of where the caller's HOME lives. Do not seed a fixture at this forbidden root.
out=$(PATH="$TMP/bin:/usr/bin:/bin" CURL_SHOULD_FAIL=1 WACLI_INSTALL_TEST_MODE=1 \
  WACLI_INSTALL_TEST_ROOT=/ WACLI_INSTALL_TEST_PROC_ROOT="$TMP/case-first/proc" \
  "$INSTALLER" install 2>&1); status=$?
if [ "$status" -ne 0 ] && [[ $out == *'test root must stay below /tmp'* ]]; then ok; else bad "test mode accepted a persistent destination: $out"; fi

# 9. The installer lives in the hov-setup skill so /hov-setup can run it from a plugin install.
# scripts/wacli-install.sh stays as a relative link to it: tool-smoke.sh and other callers reach it
# as ~/.claude/scripts/wacli-install.sh, and ~/.claude/scripts links the checkout's scripts/.
OLD=$REPO/scripts/wacli-install.sh
if [ -L "$OLD" ] && [ "$(readlink "$OLD")" = ../plugins/hov-stack/skills/hov-setup/scripts/wacli-install.sh ] \
  && [ "$(realpath "$OLD")" = "$(realpath "$INSTALLER")" ] && [ -x "$OLD" ]; then
  ok
else
  bad "scripts/wacli-install.sh is not a relative link to the hov-setup copy: $(ls -l "$OLD" 2>&1)"
fi

if [ "$failures" -eq 0 ]; then
  printf 'ok — wacli installer: %d assertions passed\n' "$pass"
else
  printf 'FAIL — wacli installer: %d of %d assertions failed\n' "$failures" "$((pass + failures))" >&2
  exit 1
fi
