#!/usr/bin/env bash
# Hermetic tests for .github/install-smoke/start-container.sh's binfmt guard
# (issue #1643).
#
# On WSL kernels before 6.7 binfmt_misc is one kernel-global table, and a
# --privileged /sbin/init container whose systemd runs systemd-binfmt empties
# the HOST's handlers when it starts and stops (2026-10-02: WSL interop down
# for four days). The launcher must refuse an image that does not mask the
# three binfmt units, and must fail when a booted container still shows them
# unmasked or has binfmt_misc mounted. CI boots only the real, masked image,
# so these refusal paths never run there: a broken guard would stay green.
#
# Nothing real is touched: a PATH stub stands in for `docker`, records every
# call, and answers per PRE_STATES (offline `systemctl is-enabled` before the
# boot), BOOT_STATES (the same, inside the booted container) and MOUNTS.
#
# Planted negatives:
#  - case 1: one unit `static` before boot must refuse with no privileged run.
#  - case 2: a docker error on that check is not a pass.
#  - case 3: masks lost after boot must fail even though the image was masked.
#  - case 4: binfmt_misc mounted inside the container must fail.
#  - case 5: a failed `docker exec` on the mount check is not "unmounted"; a
#    guard that trusts a nonzero `mountpoint` exit passes here.
#  - every case asserts the stub was called, so a launcher that died early
#    cannot satisfy a "no privileged run" assertion.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
LAUNCHER="$HERE/.github/install-smoke/start-container.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$LAUNCHER" ] || { echo "FAIL: $LAUNCHER does not exist" >&2; exit 1; }
bash -n "$LAUNCHER" || { echo "FAIL: $LAUNCHER does not parse" >&2; exit 1; }

STUBS="$TMP/stubs"
mkdir -p "$STUBS"

# Fake docker. States are comma-separated `systemctl is-enabled` answers, one
# per unit asked for, in order (`masked` past the end), or `error` for a docker
# failure. MOUNTS: clean | mounted | fail.
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_CALLS:?}"
# states SPEC ARGS...: answer for each unit after `is-enabled` in ARGS.
states() {
  local spec=$1 seen=0 i=0 arg
  shift
  if [ "$spec" = error ]; then
    echo "docker: Error response from daemon: no such image" >&2
    exit 125
  fi
  IFS=, read -r -a answers <<< "$spec"
  for arg in "$@"; do
    if [ "$seen" = 1 ]; then
      printf '%s\n' "${answers[$i]:-masked}"
      i=$((i + 1))
    fi
    [ "$arg" = is-enabled ] && seen=1
  done
  exit 1  # is-enabled exits nonzero for masked units
}
case "$1" in
  build) exit 0 ;;
  run)
    case " $* " in
      *" -d "*) exit 0 ;;
      *" is-enabled "*) states "${PRE_STATES:?}" "$@" ;;
    esac
    exit 0
    ;;
  exec)
    shift 2  # exec NAME
    case "$*" in
      "systemctl is-system-running") echo running; exit 0 ;;
      "systemctl is-enabled "*) states "${BOOT_STATES:?}" "$@" ;;
      "cat /proc/self/mountinfo"|"mountpoint -q /proc/sys/fs/binfmt_misc")
        case "${MOUNTS:?}" in
          fail)
            echo "Error response from daemon: container is not running" >&2
            exit 126
            ;;
          mounted)
            [ "$1" = mountpoint ] && exit 0
            echo '22 1 0:21 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw'
            echo '76 22 0:33 / /proc/sys/fs/binfmt_misc rw,relatime - binfmt_misc binfmt_misc rw'
            ;;
          clean)
            [ "$1" = mountpoint ] && exit 32
            echo '22 1 0:21 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw'
            ;;
        esac
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUBS/docker"

MASKED='masked,masked,masked'

# launch NAME [VAR=value ...]: run the launcher as CI does; sets RC and C.
launch() {
  C="$TMP/$1"
  shift
  mkdir -p "$C/ws"
  env PATH="$STUBS:$PATH" DOCKER_CALLS="$C/docker.calls" \
    PRE_STATES="$MASKED" BOOT_STATES="$MASKED" MOUNTS=clean \
    "$@" bash "$LAUNCHER" smoke "$C/ws" > "$C/out" 2> "$C/err"
  RC=$?
}

called()     { [ -s "$C/docker.calls" ]; }
booted()     { grep -q '^run -d ' "$C/docker.calls" 2>/dev/null; }
line_of()    { grep -n -- "$1" "$C/docker.calls" | head -1 | cut -d: -f1; }

# 1. An image with one binfmt unit left `static` is refused before any boot.
launch unmasked PRE_STATES=masked,masked,static
if [ "$RC" -eq 1 ] && called && ! booted && grep -q 'refusing a --privileged boot' "$C/err"; then ok; else bad "unmasked image: rc=$RC booted=$(booted && echo yes || echo no) err=$(cat "$C/err")"; fi

# 2. A docker error on the offline check is a refusal, not a pass.
launch checkerror PRE_STATES=error
if [ "$RC" -eq 1 ] && called && ! booted; then ok; else bad "docker error on the mask check: rc=$RC booted=$(booted && echo yes || echo no)"; fi

# 3. Masks that are gone once the container has booted fail the launch.
launch bootunmasked BOOT_STATES=masked,static,masked
if [ "$RC" -eq 1 ] && booted && grep -q 'after boot' "$C/err"; then ok; else bad "units unmasked after boot: rc=$RC err=$(cat "$C/err")"; fi

# 4. binfmt_misc mounted inside the container fails the launch.
launch mounted MOUNTS=mounted
if [ "$RC" -eq 1 ] && booted && grep -q 'binfmt_misc is mounted' "$C/err"; then ok; else bad "mounted binfmt_misc: rc=$RC err=$(cat "$C/err")"; fi

# 5. A docker exec failure on the mount check fails closed.
launch execfail MOUNTS=fail
if [ "$RC" -eq 1 ] && booted && grep -q 'cannot be shown to be unmounted' "$C/err"; then ok; else bad "failed mount check passed: rc=$RC err=$(cat "$C/err")"; fi

# 6. A masked image boots: offline, unprivileged check first, then the
#    privileged boot with systemd as PID 1, and the launcher reaches the end.
launch clean
check=$(line_of '^run --rm .* is-enabled ')
boot=$(line_of '^run -d ')
if [ "$RC" -eq 0 ] && [ -n "$check" ] && [ -n "$boot" ] && [ "$check" -lt "$boot" ]; then ok; else bad "masked image: rc=$RC check=${check:-none} boot=${boot:-none} err=$(cat "$C/err")"; fi
if grep '^run --rm .* is-enabled ' "$C/docker.calls" | grep -q -- '--network none' && ! grep '^run --rm .* is-enabled ' "$C/docker.calls" | grep -q -- '--privileged'; then ok; else bad "the mask check must run offline and unprivileged: $(grep 'is-enabled' "$C/docker.calls")"; fi
if grep '^run -d ' "$C/docker.calls" | grep -q -- '--init=false'; then ok; else bad "the privileged boot lacks --init=false: $(grep '^run -d ' "$C/docker.calls")"; fi
# Both checks, before and after boot, ask about all three units.
want='is-enabled systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount$'
if [ "$(grep -c -- "$want" "$C/docker.calls")" = 2 ]; then ok; else bad "the mask checks do not name all three binfmt units twice: $(grep 'is-enabled' "$C/docker.calls")"; fi

if [ "$fail" -eq 0 ]; then
  echo "ok — install-smoke-launcher: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — install-smoke-launcher: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
