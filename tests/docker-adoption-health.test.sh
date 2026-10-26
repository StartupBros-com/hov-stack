#!/usr/bin/env bash
# Focused contract test for harness-doctor's Docker adoption health helper.
#
# The real helper function is extracted from harness-doctor.sh; the whole doctor
# is never sourced or run. The Docker policy helper, sudo, host role table, and
# unit file are fixtures, so this suite performs no Docker or systemd operation.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
PROFILE_LIB=$REPO/lib/profile.sh
TMP=$(mktemp -d /tmp/docker-adoption-health.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

good() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
contains() {
  local text=$1 expected=$2 label=$3
  if [[ $text == *"$expected"* ]]; then good; else bad "$label: expected '$expected', got: $text"; fi
}
omits() {
  local text=$1 forbidden=$2 label=$3
  if [[ $text != *"$forbidden"* ]]; then good; else bad "$label: unexpectedly contained '$forbidden': $text"; fi
}
empty_file() {
  local file=$1 label=$2
  if [ ! -s "$file" ]; then good; else bad "$label: unexpected invocation(s): $(tr '\n' ';' < "$file")"; fi
}

# Extract the production helper rather than copying its decisions into the test.
sed -n '/^docker_adoption_health() {/,/^}/p' "$DOCTOR" > "$TMP/function.sh"
if ! grep -q '^docker_adoption_health() {' "$TMP/function.sh"; then
  printf 'FAIL: docker_adoption_health not found in %s\n' "$DOCTOR" >&2
  exit 1
fi

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nprintf "fixture\\n"\n' > "$TMP/bin/hostname"
chmod +x "$TMP/bin/hostname"

cat > "$TMP/helper.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["DOCKER_HELPER_LOG"], "a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")

mode = os.environ.get("HELPER_MODE", "pending")
if mode == "pending":
    print("docker-init: pending adoption; candidate valid; runtime not verified")
elif mode == "desired":
    print("docker-init: desired config present; pending adoption; runtime not verified")
elif mode == "adopted":
    print("docker-init: desired config present; adopted; runtime not verified")
elif mode == "rolled-back":
    print("docker-init: pending adoption after rollback; runtime not verified")
elif mode == "privilege" and os.environ.get("DOCTOR_STUB_PRIVILEGED") == "1":
    print("docker-init: desired config present; adopted; runtime not verified")
elif mode in {"privilege", "privilege-fail"}:
    print("docker-init: ERROR: privilege is required to read adoption state", file=sys.stderr)
    raise SystemExit(4)
elif mode == "error":
    print("docker-init: ERROR: adoption state is not a private owned file", file=sys.stderr)
    raise SystemExit(1)
else:
    print("docker-init: surprising output")
PY
chmod +x "$TMP/helper.py"

cat > "$TMP/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_SUDO_LOG"
[ "$1" = -n ] && shift
if [ "${SUDO_MODE:-pass}" = fail ]; then
  printf '%s\n' 'sudo: a password is required' >&2
  exit 1
fi
DOCTOR_STUB_PRIVILEGED=1 "$@"
SH
chmod +x "$TMP/bin/sudo"

: > "$TMP/forbidden-actions.log"
for tool in docker systemctl docker-hygiene.sh sync.sh install.sh cleanup; do
  cat > "$TMP/bin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$FORBIDDEN_ACTION_LOG"
exit 99
SH
  chmod +x "$TMP/bin/$tool"
done

write_service() {
  local path=$1 shape=$2
  case "$shape" in
    valid)
      printf '%s\n' '[Service]' 'Environment=DRY_RUN=0' 'Environment=AGGRESSIVE=1' \
        'Environment=STRICT=1' 'ExecStart=%h/.claude/scripts/docker-hygiene.sh' > "$path"
      ;;
    missing-strict)
      printf '%s\n' '[Service]' 'Environment=DRY_RUN=0' 'Environment=AGGRESSIVE=1' \
        'ExecStart=%h/.claude/scripts/docker-hygiene.sh' > "$path"
      ;;
    stop-idle)
      printf '%s\n' '[Service]' 'Environment=DRY_RUN=0' 'Environment=AGGRESSIVE=1' \
        'Environment=STRICT=1' 'Environment=STOP_IDLE=1' \
        'ExecStart=%h/.claude/scripts/docker-hygiene.sh' > "$path"
      ;;
  esac
}

cat > "$TMP/failing-profile.sh" <<'SH'
profile_role() {
  printf '%s\n' 'profile fixture: hosts table parse failed' >&2
  return 23
}
SH

run_case() {
  local name=$1 role=$2 mode=$3 service_shape=$4 role_override=${5:-} sudo_mode=${6:-pass}
  local case_profile_lib=${7:-$PROFILE_LIB}
  local dir=$TMP/$name
  mkdir -p "$dir"
  : > "$dir/helper.log"
  : > "$dir/sudo.log"
  if [ "$role" != undeclared ]; then
    printf 'fixture\t%s\n' "$role" > "$dir/hosts.tsv"
  else
    printf '%s\n' '# deliberately undeclared' > "$dir/hosts.tsv"
  fi
  if [ "$service_shape" != missing ]; then
    write_service "$dir/docker-hygiene.service" "$service_shape"
  fi
  cat > "$dir/probe.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
WARNS=0
warn() { printf 'WARN: %s\n' "$*"; WARNS=$((WARNS + 1)); }
ok() { printf '  ok: %s\n' "$*"; }
. "$DOCTOR_FUNCTION"
docker_adoption_health \
  "$PROFILE_LIB" "$DOCKER_HELPER" "$SERVICE_FILE" "$PATCH_FILE" \
  "$TARGET_FILE" "$STATE_FILE" "$BACKUP_FILE" "$LOCK_FILE" "$DOCKERD_FILE"
printf 'WARNS=%s\n' "$WARNS"
SH
  chmod +x "$dir/probe.sh"
  PATH="$TMP/bin:$PATH" \
    DOCTOR_FUNCTION="$TMP/function.sh" \
    DOTFILES_ROLE_FILE="$dir/hosts.tsv" DOTFILES_ROLE="$role_override" \
    PROFILE_LIB="$case_profile_lib" DOCKER_HELPER="$TMP/helper.py" \
    SERVICE_FILE="$dir/docker-hygiene.service" \
    PATCH_FILE="$dir/docker-daemon.patch.json" TARGET_FILE="$dir/daemon.json" \
    STATE_FILE="$dir/adoption.json" BACKUP_FILE="$dir/original.json" \
    LOCK_FILE="$dir/policy.lock" DOCKERD_FILE="$dir/dockerd" \
    DOCKER_HELPER_LOG="$dir/helper.log" DOCKER_SUDO_LOG="$dir/sudo.log" \
    FORBIDDEN_ACTION_LOG="$TMP/forbidden-actions.log" \
    HELPER_MODE="$mode" SUDO_MODE="$sudo_mode" \
    bash "$dir/probe.sh" > "$dir/output" 2>&1
  CASE_DIR=$dir
  CASE_OUT=$(<"$dir/output")
}

# An undeclared host cannot self-assert workstation authority through the env.
run_case undeclared-env undeclared pending valid workstation
contains "$CASE_OUT" 'authoritative host role unavailable; workstation policy check not run' \
  'undeclared workstation override fails closed'
empty_file "$CASE_DIR/helper.log" 'undeclared workstation override does not invoke policy helper'
omits "$CASE_OUT" 'desired setting present and adopted' 'undeclared host never reads as adopted'

# Resolver failures retain the authoritative profile diagnostic and stop before policy inspection.
run_case profile-error workstation pending valid '' pass "$TMP/failing-profile.sh"
contains "$CASE_OUT" \
  'authoritative host role unavailable; workstation policy check not run: profile fixture: hosts table parse failed' \
  'profile failure warning preserves the resolver diagnostic'
contains "$CASE_OUT" 'WARNS=1' 'profile failure increments warnings once'
empty_file "$CASE_DIR/helper.log" 'profile failure does not invoke policy helper'

# A declared satellite remains a satellite even when environment text disagrees.
run_case satellite satellite pending valid workstation
contains "$CASE_OUT" 'not applicable (authoritative role: satellite); no workstation ownership claimed' \
  'satellite reports non-ownership explicitly'
empty_file "$CASE_DIR/helper.log" 'satellite does not invoke workstation policy helper'
omits "$CASE_OUT" 'adoption: pending; candidate valid' 'satellite does not claim workstation policy state'

# Unknown declared roles also fail closed rather than becoming workstations.
run_case unknown mystery pending valid
contains "$CASE_OUT" "unsupported authoritative role 'mystery'; workstation policy check not run" \
  'unknown role reports unsupported authority'
empty_file "$CASE_DIR/helper.log" 'unknown role does not invoke workstation policy helper'

# The table wins over contradictory env text, and the only helper verb is check.
run_case pending workstation pending valid satellite
contains "$CASE_OUT" 'adoption: pending; candidate valid; runtime not verified (first adoption remains explicit)' \
  'pending adoption is visible and explicit'
expected="check --profile workstation --patch $CASE_DIR/docker-daemon.patch.json --target $CASE_DIR/daemon.json --state $CASE_DIR/adoption.json --backup $CASE_DIR/original.json --lock $CASE_DIR/policy.lock --dockerd $CASE_DIR/dockerd"
actual=$(<"$CASE_DIR/helper.log")
if [ "$actual" = "$expected" ]; then good; else bad "policy helper argv mismatch: $actual"; fi
omits "$actual" 'reconcile' 'pending inspection never reconciles'
omits "$actual" 'adopt ' 'pending inspection never adopts'
omits "$actual" 'rollback' 'pending inspection never rolls back'

run_case desired workstation desired valid
contains "$CASE_OUT" 'desired setting present but unadopted; pending adoption; runtime not verified' \
  'desired-only state remains unadopted'
contains "$CASE_OUT" 'this is not daemon activation' \
  'desired-only state is not called activation'
contains "$CASE_OUT" 'WARNS=1' 'desired-only state remains a warning'

run_case adopted workstation adopted valid
contains "$CASE_OUT" 'desired setting present and adopted; runtime not verified by this check' \
  'adopted state preserves runtime boundary'
contains "$CASE_OUT" 'WARNS=0' 'adopted configuration with strict service is healthy at config scope'
omits "$CASE_OUT" 'activation verified' 'adopted state does not claim activation'

run_case rolled-back workstation rolled-back valid
contains "$CASE_OUT" 'pending after explicit rollback; runtime not verified' \
  'rolled-back state returns to pending adoption'
contains "$CASE_OUT" 'WARNS=1' 'rolled-back state remains a warning'

# Exit 4 receives the sync wrapper's same read-only sudo retry; failure stays loud.
run_case privilege-ok workstation privilege valid
contains "$CASE_OUT" 'desired setting present and adopted; runtime not verified by this check' \
  'privileged read retry can complete inspection'
if [ "$(wc -l < "$CASE_DIR/sudo.log")" -eq 1 ]; then good; else bad 'privilege retry did not invoke sudo exactly once'; fi
privilege_expected="check --profile workstation --patch $CASE_DIR/docker-daemon.patch.json --target $CASE_DIR/daemon.json --state $CASE_DIR/adoption.json --backup $CASE_DIR/original.json --lock $CASE_DIR/policy.lock --dockerd $CASE_DIR/dockerd"
privilege_calls=$(<"$CASE_DIR/helper.log")
if [ "$privilege_calls" = "$privilege_expected
$privilege_expected" ]; then good; else bad "privilege retry changed helper argv: $privilege_calls"; fi
sudo_expected="-n /usr/bin/python3 $TMP/helper.py $privilege_expected"
sudo_actual=$(<"$CASE_DIR/sudo.log")
if [ "$sudo_actual" = "$sudo_expected" ]; then good; else bad "sudo retry argv mismatch: $sudo_actual"; fi

run_case privilege-fail workstation privilege-fail valid '' fail
contains "$CASE_OUT" 'inspection failed or unreadable (exit 1): sudo: a password is required' \
  'privilege failure warns with failed inspection'
contains "$CASE_OUT" 'WARNS=1' 'privilege failure increments warnings'
omits "$CASE_OUT" 'ok: docker init adoption: desired setting present and adopted' \
  'privilege failure never looks healthy'

run_case helper-error workstation error valid
contains "$CASE_OUT" 'inspection failed or unreadable (exit 1): docker-init: ERROR: adoption state is not a private owned file' \
  'private-state inspection error warns'
omits "$CASE_OUT" 'ok: docker init adoption: desired setting present and adopted' \
  'private-state error never looks healthy'

run_case unexpected workstation unexpected valid
contains "$CASE_OUT" 'inspection returned an unrecognized result; runtime unverified' \
  'unexpected helper output fails closed'

run_case missing-strict workstation adopted missing-strict
contains "$CASE_OUT" 'strict-service wiring missing or unsafe: required Environment=STRICT=1' 'missing strict wiring warns'
contains "$CASE_OUT" 'Environment=STRICT=1' 'strict warning names the missing directive'

run_case stop-idle workstation adopted stop-idle
contains "$CASE_OUT" 'strict-service wiring missing or unsafe: Environment=STOP_IDLE=1 must remain absent' 'whole-stack stop wiring warns'
contains "$CASE_OUT" 'Environment=STOP_IDLE=1' 'STOP_IDLE invariant is named'

run_case missing-service workstation adopted missing
contains "$CASE_OUT" 'strict-service wiring unavailable: service unit unreadable at' 'missing service file warns'

# Aggregate action-set guard: every recorded helper invocation is exactly check;
# neither the helper nor this focused function may run Docker, hygiene, or systemd.
all_calls=$(find "$TMP" -name helper.log -type f -exec cat {} +)
if [ -n "$all_calls" ] && ! grep -qv '^check ' <<<"$all_calls"; then good; else bad 'a helper call used a verb other than check, or no calls were recorded'; fi
omits "$all_calls" 'docker-hygiene' 'doctor never invokes the hygiene script'
omits "$all_calls" 'systemctl' 'doctor never changes or queries timer activation'
empty_file "$TMP/forbidden-actions.log" 'doctor invokes no Docker, hygiene, installer, cleanup, or systemd command'
if ! grep -qF 'init policy adopted (runtime not verified)' "$DOCTOR"; then
  good
else
  bad 'section-level success text claims adoption even for a satellite role'
fi

printf 'docker-adoption-health: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
