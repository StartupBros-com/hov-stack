#!/usr/bin/env bash
# Real, disposable Docker proof for effective init and its direct-child limit.
# This suite is intentionally absent from hermetic CI: a missing runtime lane is
# not a passing result. It never adopts daemon policy or operates on non-fixtures.
# harness-doctor-skip: needs operator-supplied --allow-real-docker, socket, images and containers (see --help)
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  DOCKER_INIT_RUNTIME_TEST=1 tests/docker-init-runtime.test.sh \
    --allow-real-docker --phase pre --socket unix:///absolute/docker.sock \
    --studio-image LOCAL_IMAGE --pg-meta-image LOCAL_IMAGE \
    --studio-container SOURCE_CONTAINER --pg-meta-container SOURCE_CONTAINER

The pre phase creates only labeled disposable containers from already-local
images. It performs no daemon/config/systemd operation and never pulls images.
Post-activation inheritance (especially create-before-activation) belongs to the
approved U4 activation window and is deliberately not simulated here.
USAGE
}

preflight_incomplete() {
  printf 'INCOMPLETE: %s\n' "$1" >&2
  printf 'RESULT status=INCOMPLETE phase=pre reason=%s runtime_proof=false\n' "$2"
  exit 1
}

OPT_IN_FLAG=0
PHASE=
DOCKER_SOCKET=
STUDIO_IMAGE=
PG_META_IMAGE=
STUDIO_CONTAINER=
PG_META_CONTAINER=
CYCLES=20
RESPONSE_DELAY_MS=250
SETTLE_SECONDS=5
RUN_TIMEOUT_SECONDS=60
DOCKER_COMMAND_TIMEOUT_SECONDS=20

while (($# > 0)); do
  case "$1" in
    --allow-real-docker) OPT_IN_FLAG=1; shift ;;
    --phase) PHASE=${2-}; shift 2 ;;
    --socket) DOCKER_SOCKET=${2-}; shift 2 ;;
    --studio-image) STUDIO_IMAGE=${2-}; shift 2 ;;
    --pg-meta-image) PG_META_IMAGE=${2-}; shift 2 ;;
    --studio-container) STUDIO_CONTAINER=${2-}; shift 2 ;;
    --pg-meta-container) PG_META_CONTAINER=${2-}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'REFUSED: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

# This gate precedes command discovery, socket inspection, and every Docker call.
if [[ ${DOCKER_INIT_RUNTIME_TEST-} != 1 || $OPT_IN_FLAG -ne 1 ]]; then
  printf '%s\n' 'REFUSED: real Docker proof requires DOCKER_INIT_RUNTIME_TEST=1 and --allow-real-docker.' >&2
  exit 64
fi
if [[ $PHASE != pre ]]; then
  printf '%s\n' 'REFUSED: --phase pre is required; post-activation inheritance is owned by U4.' >&2
  exit 64
fi
if [[ -z $STUDIO_IMAGE || -z $PG_META_IMAGE || -z $STUDIO_CONTAINER || -z $PG_META_CONTAINER ]]; then
  printf '%s\n' 'REFUSED: both image and source-container arguments are required; source containers are inspected only.' >&2
  exit 64
fi
if [[ $DOCKER_SOCKET != unix:///* ]]; then
  preflight_incomplete '--socket must be an explicit absolute local unix:// Docker socket' wrong-docker-endpoint
fi
SOCKET_PATH=${DOCKER_SOCKET#unix://}
if [[ $SOCKET_PATH != /* || $SOCKET_PATH == *$'\n'* || ! -S $SOCKET_PATH ]]; then
  preflight_incomplete "Docker endpoint is not a local Unix socket: $DOCKER_SOCKET" wrong-docker-endpoint
fi
if ! DOCKER_BIN=$(command -v docker); then
  preflight_incomplete 'Docker CLI is unavailable' docker-cli-unavailable
fi
if ! command -v timeout >/dev/null; then
  preflight_incomplete 'timeout(1) is required to bound Docker operations' timeout-command-unavailable
fi
if ! command -v python3 >/dev/null; then
  preflight_incomplete 'python3 is required to validate image healthcheck metadata' python3-unavailable
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE_FILE=$REPO/tests/fixtures/docker-init-runtime.js
if [[ ! -r $FIXTURE_FILE ]]; then
  preflight_incomplete "fixture source is unreadable: $FIXTURE_FILE" fixture-source-unreadable
fi
FIXTURE_SOURCE=$(<"$FIXTURE_FILE")
TMP=$(mktemp -d /tmp/docker-init-runtime.XXXXXX)
PRE_CONTAINERS_FILE=$TMP/preexisting-containers
PRE_VOLUMES_FILE=$TMP/preexisting-volumes

IFS= read -r RANDOM_UUID </proc/sys/kernel/random/uuid
OWNER_TOKEN=docker-init-runtime-$RANDOM_UUID
OWNER_LABEL=com.startupbros.docker-init-runtime.owner
ROLE_LABEL=com.startupbros.docker-init-runtime.role
SUITE_LABEL=com.startupbros.docker-init-runtime.suite

declare -a OWNED_IDS=()
declare -a PREEXISTING_CONTAINERS=()
declare -a PREEXISTING_VOLUMES=()
declare -A OWNED_ROLES=()
declare -A IMAGE_IDS=()
SNAPSHOT_READY=0
CLEANUP_DONE=0
RESULT_STATUS=INCOMPLETE
RESULT_REASON=unexpected-exit
CREATED_ID=
PENDING_FIXTURE_NAME=
PENDING_FIXTURE_ROLE=
PROC_PID1=
PROC_TOTAL_ZOMBIES=0
PROC_PID1_ZOMBIES=0
PROC_NESTED_LIVE_PARENT_ZOMBIES=0

STUDIO_PROBE="node --eval=\"fetch('http://127.0.0.1:3000/api/platform/profile').then((r) => {if (!r.ok) throw new Error(r.status)})\""
PG_META_PROBE="node --eval=\"fetch('http://127.0.0.1:8080/health').then((r) => {if (!r.ok) throw new Error(r.status)})\""

docker_cli() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    timeout --foreground "${DOCKER_COMMAND_TIMEOUT_SECONDS}s" \
    "$DOCKER_BIN" --host "$DOCKER_SOCKET" "$@"
}

mark_incomplete() {
  RESULT_STATUS=INCOMPLETE
  RESULT_REASON=$1
  printf 'INCOMPLETE: %s\n' "$1" >&2
}

abort_incomplete() {
  mark_incomplete "$1"
  exit 1
}

abort_void() {
  RESULT_STATUS=VOID
  RESULT_REASON=$1
  printf 'VOID: %s\n' "$1" >&2
  exit 2
}

assert_owned() {
  local id=$1 role=${OWNED_ROLES[$1]-} observed observed_id observed_owner observed_role
  if [[ -z $role ]]; then
    printf 'OWNERSHIP_REFUSED id=%s reason=unrecorded-id\n' "$id" >&2
    return 1
  fi
  if ! observed=$(docker_cli container inspect --format \
    '{{.Id}}{{"\t"}}{{index .Config.Labels "com.startupbros.docker-init-runtime.owner"}}{{"\t"}}{{index .Config.Labels "com.startupbros.docker-init-runtime.role"}}' \
    "$id"); then
    printf 'OWNERSHIP_REFUSED id=%s role=%s reason=inspect-failed\n' "$id" "$role" >&2
    return 1
  fi
  IFS=$'\t' read -r observed_id observed_owner observed_role <<<"$observed"
  if [[ $observed_id != "$id" || $observed_owner != "$OWNER_TOKEN" || $observed_role != "$role" ]]; then
    printf 'OWNERSHIP_REFUSED id=%s role=%s reason=identity-or-label-mismatch\n' "$id" "$role" >&2
    return 1
  fi
}

cleanup_owned() {
  local id failed=0
  if [[ $CLEANUP_DONE -eq 1 ]]; then
    return 0
  fi
  for id in "${OWNED_IDS[@]}"; do
    if ! assert_owned "$id"; then
      printf 'CLEANUP_REFUSED id=%s reason=ownership-recheck-failed\n' "$id" >&2
      failed=1
      continue
    fi
    if ! docker_cli container rm -f "$id" >/dev/null; then
      printf 'CLEANUP_FAILED id=%s role=%s\n' "$id" "${OWNED_ROLES[$id]}" >&2
      failed=1
    else
      printf 'CLEANUP removed_id=%s role=%s\n' "$id" "${OWNED_ROLES[$id]}"
    fi
  done
  CLEANUP_DONE=1
  if [[ $failed -ne 0 ]]; then
    return 1
  fi
}

verify_preexisting_identities() {
  local id name observed preserved_containers=0 preserved_volumes=0 failed=0
  if [[ $SNAPSHOT_READY -ne 1 ]]; then
    return 0
  fi
  for id in "${PREEXISTING_CONTAINERS[@]}"; do
    if observed=$(docker_cli container inspect --format '{{.Id}}' "$id") && [[ $observed == "$id" ]]; then
      preserved_containers=$((preserved_containers + 1))
    else
      printf 'COUNTERCHECK_FAILED object=container expected_id=%s\n' "$id" >&2
      failed=1
    fi
  done
  for name in "${PREEXISTING_VOLUMES[@]}"; do
    if observed=$(docker_cli volume inspect --format '{{.Name}}' "$name") && [[ $observed == "$name" ]]; then
      preserved_volumes=$((preserved_volumes + 1))
    else
      printf 'COUNTERCHECK_FAILED object=volume expected_name=%s\n' "$name" >&2
      failed=1
    fi
  done
  printf 'COUNTERCHECK preexisting_containers=%d preserved_containers=%d preexisting_volumes=%d preserved_volumes=%d unrelated_new_objects=allowed\n' \
    "${#PREEXISTING_CONTAINERS[@]}" "$preserved_containers" \
    "${#PREEXISTING_VOLUMES[@]}" "$preserved_volumes"
  if [[ $failed -ne 0 ]]; then
    return 1
  fi
}

finish() {
  local original_rc=$?
  local final_rc=$original_rc cleanup_rc=0 countercheck_rc=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ -n $PENDING_FIXTURE_NAME && -n $PENDING_FIXTURE_ROLE ]]; then
    if recover_created_id "$PENDING_FIXTURE_NAME" "$PENDING_FIXTURE_ROLE"; then
      PENDING_FIXTURE_NAME=
      PENDING_FIXTURE_ROLE=
    fi
  fi
  cleanup_owned
  cleanup_rc=$?
  verify_preexisting_identities
  countercheck_rc=$?
  rm -rf -- "$TMP"
  if [[ $cleanup_rc -ne 0 ]]; then
    RESULT_STATUS=INCOMPLETE
    RESULT_REASON=owned-cleanup-failed-or-refused
  elif [[ $countercheck_rc -ne 0 ]]; then
    RESULT_STATUS=INCOMPLETE
    RESULT_REASON=preexisting-identity-countercheck-failed
  elif [[ $RESULT_STATUS == PASS && $original_rc -ne 0 ]]; then
    RESULT_STATUS=INCOMPLETE
    RESULT_REASON=unexpected-nonzero-exit
  fi
  case "$RESULT_STATUS" in
    PASS) final_rc=0 ;;
    VOID) final_rc=2 ;;
    *) final_rc=1 ;;
  esac
  printf 'RESULT status=%s phase=pre reason=%s runtime_proof=%s\n' \
    "$RESULT_STATUS" "$RESULT_REASON" "$([[ $RESULT_STATUS == PASS ]] && printf true || printf false)"
  exit "$final_rc"
}

interrupted() {
  RESULT_STATUS=INCOMPLETE
  RESULT_REASON=interrupted
  exit 130
}
trap finish EXIT
trap interrupted INT TERM HUP

validate_image() {
  local class=$1 reference=$2 expected_probe=$3 source_container=$4 image_id source_image volumes entrypoint health
  if ! image_id=$(docker_cli image inspect --format '{{.Id}}' "$reference"); then
    abort_incomplete "$class image is unavailable locally (no pull was attempted)"
  fi
  if [[ ! $image_id =~ ^sha256:[0-9a-f]{64}$ ]]; then
    abort_incomplete "$class image resolved to an invalid image ID"
  fi
  if ! volumes=$(docker_cli image inspect --format '{{json (index .Config "Volumes")}}' "$image_id"); then
    abort_incomplete "$class image volume metadata is unreadable"
  fi
  if [[ $volumes != null && $volumes != '{}' ]]; then
    abort_incomplete "$class image declares volumes; fixture creation refused"
  fi
  if ! entrypoint=$(docker_cli image inspect --format '{{json .Config.Entrypoint}}' "$image_id"); then
    abort_incomplete "$class image entrypoint metadata is unreadable"
  fi
  if [[ $entrypoint != '["docker-entrypoint.sh"]' ]]; then
    abort_incomplete "$class image entrypoint is not exactly docker-entrypoint.sh"
  fi
  # Supabase CLI overrides the image's default probe at container creation.
  # Bind the fixture to that deployed command, without operating the source.
  if ! source_image=$(docker_cli container inspect --format '{{.Image}}' "$source_container") || [[ $source_image != "$image_id" ]]; then
    abort_incomplete "$class source container does not use the declared image"
  fi
  if ! health=$(docker_cli container inspect --format '{{json .Config.Healthcheck.Test}}' "$source_container"); then
    abort_incomplete "$class deployed healthcheck metadata is unreadable"
  fi
  if ! python3 - "$health" "$expected_probe" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
expected = ["CMD-SHELL", sys.argv[2]]
raise SystemExit(0 if actual == expected else 1)
PY
  then
    abort_incomplete "$class deployed healthcheck does not match the controlled shell/Node probe"
  fi
  IMAGE_IDS[$class]=$image_id
  printf 'IMAGE class=%s reference=%s exact_id=%s volumes=absent entrypoint=docker-entrypoint.sh healthcheck=matched\n' \
    "$class" "$reference" "$image_id"
}

snapshot_preexisting_identities() {
  local id name
  if ! docker_cli container ls -aq --no-trunc >"$PRE_CONTAINERS_FILE"; then
    abort_incomplete 'could not snapshot pre-existing container identities'
  fi
  if ! docker_cli volume ls -q >"$PRE_VOLUMES_FILE"; then
    abort_incomplete 'could not snapshot pre-existing volume identities'
  fi
  mapfile -t PREEXISTING_CONTAINERS <"$PRE_CONTAINERS_FILE"
  mapfile -t PREEXISTING_VOLUMES <"$PRE_VOLUMES_FILE"
  for id in "${PREEXISTING_CONTAINERS[@]}"; do
    if [[ ! $id =~ ^[0-9a-f]{64}$ ]]; then
      abort_incomplete 'pre-existing container snapshot contained an invalid identity'
    fi
  done
  for name in "${PREEXISTING_VOLUMES[@]}"; do
    if [[ -z $name || $name == *$'\n'* ]]; then
      abort_incomplete 'pre-existing volume snapshot contained an invalid identity'
    fi
  done
  SNAPSHOT_READY=1
  printf 'SNAPSHOT preexisting_containers=%d preexisting_volumes=%d\n' \
    "${#PREEXISTING_CONTAINERS[@]}" "${#PREEXISTING_VOLUMES[@]}"
}

record_owned_id() {
  local id=$1 role=$2 recorded_role=${OWNED_ROLES[$1]-}
  if [[ -n $recorded_role && $recorded_role != "$role" ]]; then
    printf 'OWNERSHIP_REFUSED id=%s role=%s reason=recorded-role-mismatch\n' "$id" "$role" >&2
    return 1
  fi
  if [[ -z $recorded_role ]]; then
    OWNED_IDS+=("$id")
    OWNED_ROLES[$id]=$role
  fi
  CREATED_ID=$id
}

recover_created_id() {
  local name=$1 role=$2 observed id owner observed_role
  if ! observed=$(docker_cli container inspect --format \
    '{{.Id}}{{"\t"}}{{index .Config.Labels "com.startupbros.docker-init-runtime.owner"}}{{"\t"}}{{index .Config.Labels "com.startupbros.docker-init-runtime.role"}}' \
    "$name"); then
    return 1
  fi
  IFS=$'\t' read -r id owner observed_role <<<"$observed"
  if [[ $id =~ ^[0-9a-f]{64}$ && $owner == "$OWNER_TOKEN" && $observed_role == "$role" ]] \
    && record_owned_id "$id" "$role"; then
    printf 'CREATE_RECOVERED id=%s role=%s\n' "$id" "$role" >&2
    return 0
  fi
  printf 'CREATE_COLLISION name=%s expected_role=%s cleanup=refused\n' "$name" "$role" >&2
  return 1
}

create_fixture() {
  local class=$1 mode=$2 init_value=$3 role=$4 name id output probe
  case "$class" in
    studio) probe=$STUDIO_PROBE ;;
    pg_meta) probe=$PG_META_PROBE ;;
    *) abort_incomplete "unknown fixture image class: $class" ;;
  esac
  name=sb-docker-init-${RANDOM_UUID}-${class}-${role}
  PENDING_FIXTURE_NAME=$name
  PENDING_FIXTURE_ROLE=$role
  if ! output=$(docker_cli container create \
    --pull never \
    --name "$name" \
    --label "$OWNER_LABEL=$OWNER_TOKEN" \
    --label "$ROLE_LABEL=$role" \
    --label "$SUITE_LABEL=docker-init-runtime" \
    --network none \
    --cpus 0.25 \
    --memory 256m \
    --memory-swap 256m \
    --pids-limit 64 \
    --read-only \
    --security-opt no-new-privileges=true \
    --cap-drop ALL \
    --no-healthcheck \
    --init="$init_value" \
    --entrypoint node \
    "${IMAGE_IDS[$class]}" \
    --eval "$FIXTURE_SOURCE" "$class" "$mode" "$CYCLES" "$RESPONSE_DELAY_MS" "$probe"); then
    if recover_created_id "$name" "$role"; then
      PENDING_FIXTURE_NAME=
      PENDING_FIXTURE_ROLE=
    fi
    abort_incomplete "fixture creation failed for $role"
  fi
  id=${output//$'\n'/}
  if [[ ! $id =~ ^[0-9a-f]{64}$ ]]; then
    recover_created_id "$name" "$role" || abort_incomplete "fixture creation returned no valid ID for $role"
  else
    record_owned_id "$id" "$role" || abort_incomplete "fixture creation returned a conflicting ID for $role"
  fi
  PENDING_FIXTURE_NAME=
  PENDING_FIXTURE_ROLE=
  if ! assert_owned "$CREATED_ID"; then
    abort_incomplete "new fixture failed ownership verification for $role"
  fi
}

verify_fixture_constraints() {
  local id=$1 expected_init=$2 observed network pid_mode binds mounts init_value read_only pids memory memory_swap nano_cpus
  if ! observed=$(docker_cli container inspect --format \
    '{{.HostConfig.NetworkMode}}{{"\t"}}{{json (index .HostConfig "PidMode")}}{{"\t"}}{{json (index .HostConfig "Binds")}}{{"\t"}}{{json (index . "Mounts")}}{{"\t"}}{{.HostConfig.Init}}{{"\t"}}{{.HostConfig.ReadonlyRootfs}}{{"\t"}}{{.HostConfig.PidsLimit}}{{"\t"}}{{.HostConfig.Memory}}{{"\t"}}{{.HostConfig.MemorySwap}}{{"\t"}}{{.HostConfig.NanoCpus}}' \
    "$id"); then
    abort_incomplete "fixture constraints are unreadable for ${OWNED_ROLES[$id]}"
  fi
  IFS=$'\t' read -r network pid_mode binds mounts init_value read_only pids memory memory_swap nano_cpus <<<"$observed"
  if [[ $network != none || ($pid_mode != '""' && $pid_mode != null) || ($binds != null && $binds != '[]') || \
        ($mounts != '[]' && $mounts != null) || $init_value != "$expected_init" || $read_only != true || \
        $pids != 64 || $memory != 268435456 || $memory_swap != 268435456 || \
        $nano_cpus != 250000000 ]]; then
    abort_incomplete "fixture safety constraints differ from the requested values for ${OWNED_ROLES[$id]}"
  fi
}

start_owned_fixture() {
  local id=$1
  if ! assert_owned "$id"; then
    abort_incomplete "start refused after ownership mismatch for $id"
  fi
  if ! docker_cli container start "$id" >/dev/null; then
    abort_incomplete "fixture failed to start (including possible missing init binary): ${OWNED_ROLES[$id]}"
  fi
}

wait_for_marker() {
  local id=$1 marker=$2 deadline logs state
  deadline=$((SECONDS + RUN_TIMEOUT_SECONDS))
  while ((SECONDS <= deadline)); do
    if ! logs=$(docker_cli container logs "$id"); then
      return 1
    fi
    if [[ $logs == *"$marker"* ]]; then
      return 0
    fi
    if ! state=$(docker_cli container inspect --format '{{.State.Status}}' "$id"); then
      return 1
    fi
    if [[ $state == exited || $state == dead ]]; then
      printf 'FIXTURE_TERMINATED id=%s role=%s state=%s\n' "$id" "${OWNED_ROLES[$id]}" "$state" >&2
      docker_cli container logs "$id" || true
      return 1
    fi
    sleep 0.2
  done
  printf 'FIXTURE_TIMEOUT id=%s role=%s marker=%s\n' "$id" "${OWNED_ROLES[$id]}" "$marker" >&2
  docker_cli container logs "$id" || true
  return 1
}

inspect_processes() {
  local id=$1 observed
  if ! assert_owned "$id"; then
    abort_incomplete "process inspection refused after ownership mismatch for $id"
  fi
  if ! observed=$(docker_cli container exec "$id" node --eval "$FIXTURE_SOURCE" process_snapshot); then
    abort_incomplete "namespace process inspection failed for ${OWNED_ROLES[$id]}"
  fi
  IFS=$'\t' read -r PROC_PID1 PROC_TOTAL_ZOMBIES PROC_PID1_ZOMBIES PROC_NESTED_LIVE_PARENT_ZOMBIES <<<"$observed"
  if [[ ! $PROC_TOTAL_ZOMBIES =~ ^[0-9]+$ || ! $PROC_PID1_ZOMBIES =~ ^[0-9]+$ || \
        ! $PROC_NESTED_LIVE_PARENT_ZOMBIES =~ ^[0-9]+$ ]]; then
    abort_incomplete "namespace process inspection returned malformed counts for ${OWNED_ROLES[$id]}"
  fi
}

run_image_class() {
  local class=$1 control_id treatment_id direct_id marker

  create_fixture "$class" orphans false "$class-control-false"
  control_id=$CREATED_ID
  verify_fixture_constraints "$control_id" false
  start_owned_fixture "$control_id"
  marker="DOCKER_INIT_RUNTIME_COMPLETE class=$class mode=orphans attempted=$CYCLES completed=$CYCLES"
  wait_for_marker "$control_id" "$marker" || abort_incomplete "$class explicit-false control did not complete $CYCLES cycles"
  sleep "$SETTLE_SECONDS"
  inspect_processes "$control_id"
  if [[ $PROC_PID1 != node ]]; then
    abort_incomplete "$class explicit-false control did not run the Node fixture as namespace PID 1"
  fi
  if ((PROC_PID1_ZOMBIES < 1)); then
    abort_void "$class explicit-false control retained no PID-1-adopted zombie; reaping experiment is invalid"
  fi
  printf 'FIXTURE class=%s role=control init=false id=%s image_id=%s cycles_attempted=%d cycles_completed=%d pid1=%s total_zombies=%d pid1_adopted_zombies=%d\n' \
    "$class" "$control_id" "${IMAGE_IDS[$class]}" "$CYCLES" "$CYCLES" "$PROC_PID1" \
    "$PROC_TOTAL_ZOMBIES" "$PROC_PID1_ZOMBIES"

  create_fixture "$class" orphans true "$class-treatment-true"
  treatment_id=$CREATED_ID
  verify_fixture_constraints "$treatment_id" true
  start_owned_fixture "$treatment_id"
  wait_for_marker "$treatment_id" "$marker" || abort_incomplete "$class explicit-init treatment did not complete $CYCLES cycles"
  sleep "$SETTLE_SECONDS"
  inspect_processes "$treatment_id"
  case "$PROC_PID1" in docker-init|tini) ;; *) abort_incomplete "$class treatment has no effective init at namespace PID 1" ;; esac
  if ((PROC_TOTAL_ZOMBIES != 0 || PROC_PID1_ZOMBIES != 0)); then
    abort_incomplete "$class init treatment retained zombies after the bounded settle"
  fi
  printf 'FIXTURE class=%s role=treatment init=true id=%s image_id=%s cycles_attempted=%d cycles_completed=%d pid1=%s total_zombies=%d pid1_adopted_zombies=%d settle_seconds=%d\n' \
    "$class" "$treatment_id" "${IMAGE_IDS[$class]}" "$CYCLES" "$CYCLES" "$PROC_PID1" \
    "$PROC_TOTAL_ZOMBIES" "$PROC_PID1_ZOMBIES" "$SETTLE_SECONDS"

  create_fixture "$class" direct true "$class-direct-counterexample"
  direct_id=$CREATED_ID
  verify_fixture_constraints "$direct_id" true
  start_owned_fixture "$direct_id"
  marker="DOCKER_INIT_RUNTIME_COMPLETE class=$class mode=direct"
  wait_for_marker "$direct_id" "$marker" || abort_incomplete "$class direct-child counterexample did not materialize"
  inspect_processes "$direct_id"
  case "$PROC_PID1" in docker-init|tini) ;; *) abort_incomplete "$class counterexample has no effective init at namespace PID 1" ;; esac
  if ((PROC_NESTED_LIVE_PARENT_ZOMBIES < 1)); then
    abort_incomplete "$class direct child of a living non-reaper was unexpectedly credited to init"
  fi
  printf 'COUNTEREXAMPLE class=%s init=true id=%s image_id=%s pid1=%s total_zombies=%d pid1_adopted_zombies=%d direct_children_of_live_nonreapers=%d\n' \
    "$class" "$direct_id" "${IMAGE_IDS[$class]}" "$PROC_PID1" "$PROC_TOTAL_ZOMBIES" \
    "$PROC_PID1_ZOMBIES" "$PROC_NESTED_LIVE_PARENT_ZOMBIES"
}

if ! engine=$(docker_cli version --format '{{.Server.Version}}|{{.Server.GitCommit}}'); then
  abort_incomplete 'Docker engine is unavailable through the declared local socket'
fi
IFS='|' read -r ENGINE_VERSION ENGINE_REVISION <<<"$engine"
if [[ -z $ENGINE_VERSION || -z $ENGINE_REVISION ]]; then
  abort_incomplete 'Docker engine version or revision is unavailable'
fi
printf 'ENGINE socket=%s version=%s revision=%s owner_token=%s\n' \
  "$DOCKER_SOCKET" "$ENGINE_VERSION" "$ENGINE_REVISION" "$OWNER_TOKEN"
printf '%s\n' 'BOUNDARY fixture_endpoint=local-test-input historical-303-cause=not-proven daemon_operations=none'

validate_image studio "$STUDIO_IMAGE" "$STUDIO_PROBE" "$STUDIO_CONTAINER"
validate_image pg_meta "$PG_META_IMAGE" "$PG_META_PROBE" "$PG_META_CONTAINER"
snapshot_preexisting_identities
run_image_class studio
run_image_class pg_meta

RESULT_STATUS=PASS
RESULT_REASON=matched-control-treatment-and-counterexample
exit 0
