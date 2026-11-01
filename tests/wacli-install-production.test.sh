#!/usr/bin/env bash
# Production PATH regression (#1065). Production preflight scans the real /proc,
# which the hermetic wacli-install.test.sh cannot fake, so a live wacli anywhere
# on the host would fail it. The suite re-executes itself in a fresh user+PID
# namespace with its own /proc, which isolates the process table without
# stopping anything. Where no namespace can be created it says so and runs
# against the host /proc; a fresh CI pod has no wacli process to find.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF=$REPO/tests/wacli-install-production.test.sh
INSTALLER=$REPO/scripts/wacli-install.sh

if [ "${1:-}" = --in-namespace ]; then
  # Internal re-exec marker. It is honoured only as PID 1 of a fresh PID
  # namespace, so no caller argument or inherited environment can skip the
  # isolation on a host whose /proc holds a live wacli.
  if [ "$$" -ne 1 ]; then
    printf 'FAIL: --in-namespace is internal; this shell is not PID 1 of a fresh PID namespace\n' >&2
    exit 1
  fi
else
  # Probe first: a failed namespace setup and a failed assertion would
  # otherwise both surface as the same non-zero exit from unshare.
  if probe_err=$(/usr/bin/unshare --user --map-root-user --pid --fork --mount-proc /bin/true 2>&1); then
    exec /usr/bin/unshare --user --map-root-user --pid --fork --mount-proc \
      /usr/bin/bash "$SELF" --in-namespace
  fi
  printf 'note — no PID namespace available (%s); running against host /proc\n' \
    "${probe_err:-unshare exited non-zero}"
fi

TMP=$(mktemp -d /tmp/wacli-install-production-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Production ignores caller PATH even when every proof helper is poisoned.
POISON=$TMP/poison-path
POISON_MARKER=$TMP/poison-path-called
/usr/bin/mkdir -p "$POISON"
cat >"$POISON/helper" <<'SH'
#!/usr/bin/bash
printf 'poison helper invoked\n' >>"${POISON_MARKER:?}"
exit 99
SH
/usr/bin/chmod +x "$POISON/helper"
for helper in bash curl sha256sum tar install realpath readlink systemctl uname awk grep \
              mkdir mktemp rm cp date mv ln chmod id stat; do
  /usr/bin/ln -s "$POISON/helper" "$POISON/$helper"
done

# A PID namespace does not isolate the host user bus. Clear inherited test-mode
# overrides and point systemctl at an absent bus so preflight must prove /proc.
status=0
out=$(/usr/bin/env -i HOME="$TMP/home" PATH="$POISON:/usr/bin:/bin" \
  XDG_RUNTIME_DIR="$TMP/no-runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/no-bus" \
  POISON_MARKER="$POISON_MARKER" "$INSTALLER" preflight 2>&1) || status=$?
if [ "$status" -eq 0 ] && [ ! -e "$POISON_MARKER" ] \
   && [[ $out == *'preflight — unit/binary cutover may proceed'* ]]; then
  printf 'ok — wacli production installer: 1 assertion passed\n'
else
  printf 'FAIL: production preflight trusted caller PATH or failed (requires clean /proc): %s\n' "$out" >&2
  exit 1
fi
