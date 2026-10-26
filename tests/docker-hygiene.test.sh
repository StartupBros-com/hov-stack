#!/usr/bin/env bash
# Hermetic contract for docker-hygiene.sh. Every external Docker, Supabase, ps,
# and procfs observation is supplied by this fixture; the operator daemon and
# process table are never queried. The one exception is the final section,
# which asks the real systemd user manager to run the unit's own Environment=
# block (issue #1555) and prints an explicit SKIP line where no manager
# answers (CI pods, containers), never a silent pass.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/docker-hygiene.sh
TMP=$(mktemp -d /tmp/docker-hygiene-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
BIN=$TMP/bin
CALLS=$TMP/calls.tsv
mkdir -p "$BIN" "$TMP/home/SITES" "$TMP/proc/1/fd"
ln -s / "$TMP/proc/1/cwd"
: >"$TMP/proc/1/cmdline"
: >"$TMP/proc/1/environ"
printf 'init\n' >"$TMP/proc/1/comm"
printf '0::/\n' >"$TMP/proc/1/cgroup"
: >"$CALLS"

pass=0
fail=0
skips=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
# A section that cannot run here says so on stdout and in the final summary;
# it never counts as a pass.
skip() { skips=$((skips + 1)); printf 'SKIP: %s\n' "$*"; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle'"$'\n'"$output" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'"$'\n'"$output" ;; *) ok ;; esac
}
equals() {
  local got=$1 want=$2 label=$3
  if [ "$got" = "$want" ]; then
    ok
  else
    bad "$label: got '$got', wanted '$want'"
  fi
}
assert_json_field() {
  local output=$1 key=$2 want=$3 label=$4 json_line
  json_line=$(printf '%s\n' "$output" | tail -1)
  if python3 - "$json_line" "$key" "$want" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
value = obj[sys.argv[2]]
if isinstance(value, bool):
    value = str(value).lower()
else:
    value = str(value)
assert value == sys.argv[3], (value, sys.argv[3])
PY
  then ok; else bad "$label: wanted $key=$want"; fi
}
# Exactly one entry of a JSON list field contains the needle: one failure is
# one detail, even when the CLI wrote several stderr lines.
assert_json_list_contains() {
  local output=$1 key=$2 needle=$3 label=$4 json_line
  json_line=$(printf '%s\n' "$output" | tail -1)
  if python3 - "$json_line" "$key" "$needle" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
items = obj[sys.argv[2]]
assert isinstance(items, list), items
hits = [item for item in items if sys.argv[3] in item]
assert len(hits) == 1, (len(hits), items)
PY
  then ok; else bad "$label: wanted exactly one $key entry containing '$needle'"$'\n'"$output"; fi
}

cat >"$BIN/docker" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
scenario=${DOCKER_HYGIENE_TEST_SCENARIO:-clean}
printf 'docker' >>"$DOCKER_HYGIENE_TEST_CALLS"
printf '\t%s' "$@" >>"$DOCKER_HYGIENE_TEST_CALLS"
printf '\n' >>"$DOCKER_HYGIENE_TEST_CALLS"

container_name() {
  case "$1" in
    aaaaaaaaaaaa)
      case "$scenario" in
        unknown-old-test|unknown-zombie|orphan-stop-fail|orphan-checkout-appears|orphan-bind-mount|orphan-live-outside) printf 'supabase_studio_verify-old' ;;
        *) printf 'supabase_studio_alpha' ;;
      esac
      ;;
    bbbbbbbbbbbb) printf 'supabase_db_alpha' ;;
  esac
}
container_project() {
  case "$1" in
    aaaaaaaaaaaa)
      case "$scenario" in
        unknown-old-test|unknown-zombie|orphan-stop-fail|orphan-checkout-appears|orphan-bind-mount|orphan-live-outside) printf 'verify-old' ;;
        *) printf 'alpha' ;;
      esac
      ;;
    bbbbbbbbbbbb) printf 'alpha' ;;
  esac
}
container_pid() {
  case "$1" in
    aaaaaaaaaaaa) printf '100' ;;
    bbbbbbbbbbbb) printf '200' ;;
  esac
}
add_fake_holder() {
  local signal=$1
  mkdir -p "$PROCFS_ROOT/900/fd"
  ln -sfn / "$PROCFS_ROOT/900/cwd"
  : >"$PROCFS_ROOT/900/cmdline"
  : >"$PROCFS_ROOT/900/environ"
  printf 'worker\n' >"$PROCFS_ROOT/900/comm"
  printf '0::/user.slice\n' >"$PROCFS_ROOT/900/cgroup"
  case "$signal" in
    cwd) ln -sfn "$SITES/alpha" "$PROCFS_ROOT/900/cwd" ;;
    cmdline) printf 'worker\0--cwd\0%s\0DO_NOT_LOG_RAW\0' "$SITES/alpha" >"$PROCFS_ROOT/900/cmdline" ;;
  esac
}
# A live cwd in a checkout OUTSIDE $SITES: invisible to the $SITES-scoped
# liveness map, visible only to the unscoped orphan-evidence walk.
add_fake_outside_holder() {
  mkdir -p "$PROCFS_ROOT/900/fd"
  ln -sfn "$DOCKER_HYGIENE_TEST_ROOT/outside-live/verify-old" "$PROCFS_ROOT/900/cwd"
  : >"$PROCFS_ROOT/900/cmdline"
  : >"$PROCFS_ROOT/900/environ"
  printf 'worker\n' >"$PROCFS_ROOT/900/comm"
  printf '0::/user.slice\n' >"$PROCFS_ROOT/900/cgroup"
}
add_fake_worktree_holder() {
  local checkout="$SITES/monorepo/.claude/worktrees/x/apps/app"
  mkdir -p "$PROCFS_ROOT/900/fd" "$SITES/../detached"
  ln -sfn "$SITES/../detached" "$PROCFS_ROOT/900/cwd"
  ln -sfn "$checkout/held.txt" "$PROCFS_ROOT/900/fd/7"
  printf 'worker\0--cwd\0%s\0DO_NOT_LOG_RAW\0' "$checkout" >"$PROCFS_ROOT/900/cmdline"
  printf 'CLAUDE_JOB_DIR=%s\0' "$checkout" >"$PROCFS_ROOT/900/environ"
  printf 'worker\n' >"$PROCFS_ROOT/900/comm"
  printf '0::/user.slice\n' >"$PROCFS_ROOT/900/cgroup"
}

case "${1:-}" in
  info)
    [ "$scenario" = daemon-down ] && exit 1
    [ "$scenario" = holder-cmdline ] && add_fake_holder cmdline
    [ "$scenario" = worktree-holder ] && add_fake_worktree_holder
    [ "$scenario" = orphan-live-outside ] && add_fake_outside_holder
    if [ "$scenario" = monorepo-root ]; then
      add_fake_holder cwd
      ln -sfn "$SITES/monorepo" "$PROCFS_ROOT/900/cwd"
    fi
    exit 0
    ;;
  ps)
    if [ "$scenario" = inuse-snapshot-fail ] && [ "${2:-}" = -aq ] && [ -z "${3:-}" ]; then
      exit 1
    fi
    if [ "${2:-}" = -aq ] && [ "${3:-}" = -f ]; then
      case "$scenario" in rm-fail|exited) printf 'aaaaaaaaaaaa\n' ;; esac
      exit 0
    fi
    case "$scenario" in
      zombies)
        if [ "${2:-}" = -aq ]; then
          printf 'aaaaaaaaaaaa\nbbbbbbbbbbbb\n'
        elif [ "${2:-}" = --format ]; then
          printf 'aaaaaaaaaaaa\tsupabase_studio_alpha\nbbbbbbbbbbbb\tsupabase_db_alpha\n'
        fi
        ;;
      holder-cmdline|worktree-holder|raced-live|stale-identity|late-stale-identity|proc-error|restart-fail|inspect-fail|stop-fail|stop-raced-live|stop-stale-set|stop-late-stale-set|unknown-old-test|unknown-zombie|nested-only|monorepo-root|ps-fail|orphan-stop-fail|orphan-checkout-appears|orphan-bind-mount|orphan-live-outside)
        if [ "${2:-}" = -aq ]; then
          printf 'aaaaaaaaaaaa\n'
        elif [ "${2:-}" = --format ]; then
          count_file=$DOCKER_HYGIENE_TEST_CALLS.ps-format-count
          count=0
          [ -f "$count_file" ] && count=$(<"$count_file")
          count=$((count + 1))
          printf '%s' "$count" >"$count_file"
          [ "$scenario" = stop-raced-live ] && [ "$count" -ge 3 ] && add_fake_holder cwd
          # A checkout for the orphan's project appears at the first identity
          # read, at a path only the re-scanned config map can see (not
          # $SITES/<project>, which liveness_proj_dirs checks directly).
          if [ "$scenario" = orphan-checkout-appears ] && [ "$count" -ge 3 ]; then
            mkdir -p "$SITES/late-checkout/supabase"
            printf 'project_id = "verify-old"\n' >"$SITES/late-checkout/supabase/config.toml"
          fi
          if { [ "$scenario" = stop-stale-set ] && [ "$count" -ge 3 ]; } || \
             { [ "$scenario" = stop-late-stale-set ] && [ "$count" -ge 4 ]; }; then
            printf 'bbbbbbbbbbbb\tsupabase_db_alpha\n'
          else
            printf '%s\t%s\n' aaaaaaaaaaaa "$(container_name aaaaaaaaaaaa)"
          fi
        fi
        ;;
      rm-fail|exited|aggressive)
        [ "${2:-}" = -aq ] && printf 'aaaaaaaaaaaa\n'
        ;;
    esac
    exit 0
    ;;
  inspect)
    shift
    if { [ "$scenario" = rm-fail ] || [ "$scenario" = exited ]; } && [ "${1:-}" = aaaaaaaaaaaa ]; then
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t/supabase_old_alpha\t2020-01-01T00:00:00Z\t0\talpha\n'
      exit 0
    fi
    if [ "${1:-}" = --format ]; then
      shift 2
      for id in "$@"; do printf 'sha256:image-%s\n' "$id"; done
      exit 0
    fi
    if [ "${1:-}" = -f ]; then
      fmt=$2
      id=$3
      if [ "$scenario" = inspect-fail ] && [[ "$fmt" == *'.Config.Labels'* ]]; then
        exit 1
      fi
      if [[ "$fmt" == *'.Mounts'* ]]; then
        # Only the bind-mount scenario reports a mount; its source sits under a
        # checkout OUTSIDE $SITES that the fixture creates on disk.
        [ "$scenario" = orphan-bind-mount ] && printf '%s/outside-checkout/supabase/snippets\n' "$DOCKER_HYGIENE_TEST_ROOT"
        exit 0
      fi
      if [[ "$fmt" == *'.Name'* && "$fmt" == *'.State.Pid'* ]]; then
        [ "$scenario" = raced-live ] && add_fake_holder cwd
        if [ "$scenario" = proc-error ]; then
          mv "$PROCFS_ROOT" "$PROCFS_ROOT.unreadable"
          mkdir -p "$PROCFS_ROOT"
        fi
        if [ "$scenario" = stale-identity ]; then
          printf '/supabase_studio_alpha\t999\talpha\n'
        elif [ "$scenario" = late-stale-identity ]; then
          count_file=$DOCKER_HYGIENE_TEST_CALLS.identity-count
          count=0
          [ -f "$count_file" ] && count=$(<"$count_file")
          count=$((count + 1))
          printf '%s' "$count" >"$count_file"
          if [ "$count" -ge 2 ]; then
            printf '/supabase_studio_alpha\t999\talpha\n'
          else
            printf '/%s\t%s\t%s\n' "$(container_name "$id")" "$(container_pid "$id")" "$(container_project "$id")"
          fi
        else
          printf '/%s\t%s\t%s\n' "$(container_name "$id")" "$(container_pid "$id")" "$(container_project "$id")"
        fi
      elif [[ "$fmt" == *'.Config.Labels'* ]]; then
        container_project "$id"
        printf '\n'
      elif [[ "$fmt" == *'.State.Pid'* ]]; then
        container_pid "$id"
        printf '\n'
      fi
      exit 0
    fi
    exit 0
    ;;
  restart)
    [ "${2:-}" = aaaaaaaaaaaa ] || exit 92
    [ "$scenario" = restart-fail ] && exit 1
    case "$scenario" in zombies|holder-cmdline|worktree-holder|raced-live|stale-identity|proc-error) exit 0 ;; esac
    exit 91
    ;;
  rm)
    [ "$scenario" = rm-fail ] && [ "${2:-}" = aaaaaaaaaaaa ] && exit 1
    [ "$scenario" = exited ] && [ "${2:-}" = aaaaaaaaaaaa ] && exit 0
    exit 93
    ;;
  images)
    case "$scenario" in rmi-fail|dangling) printf 'sha256:deadbeef\n' ;; esac
    [ "$scenario" = inuse-snapshot-fail ] && [ "${2:-}" = --no-trunc ] && printf 'sha256:live-image\n'
    # One image the snapshotted container (aaaaaaaaaaaa) references, one nothing does.
    [ "$scenario" = aggressive ] && [ "${2:-}" = --no-trunc ] && printf 'sha256:image-aaaaaaaaaaaa\nsha256:unused-image\n'
    exit 0
    ;;
  rmi)
    [ "$scenario" = rmi-fail ] && [ "${2:-}" = sha256:deadbeef ] && exit 1
    [ "$scenario" = dangling ] && [ "${2:-}" = sha256:deadbeef ] && exit 0
    [ "$scenario" = aggressive ] && [ "${2:-}" = sha256:unused-image ] && exit 0
    exit 94
    ;;
  volume)
    # Volume fixture (#1627): two volumes of a project nothing declares, one each
    # declared by $SITES/<project>, a worktree config and an _archive config, a
    # project created an hour ago, one unlabelled anonymous volume, and one
    # Supabase-named volume without the label (the label decides, not the name).
    case "$scenario" in volumes|volume-rm-fail|volume-inspect-fail|volume-bad-created) ;; *) exit 0 ;; esac
    case "${2:-}" in
      ls)
        printf '%s\n' supabase_db_gone-tmp supabase_storage_gone-tmp supabase_db_alpha \
          supabase_db_wt-only supabase_db_arch-only supabase_db_fresh-tmp supabase_db_nolabel \
          0123456789abcdef
        ;;
      inspect)
        [ "$scenario" = volume-inspect-fail ] && exit 1
        shift 4
        young=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
        for v in "$@"; do
          created=2020-01-01T00:00:00Z
          case "$v" in
            supabase_db_nolabel) proj='<no value>' ;;
            supabase_*) proj=${v#supabase_}; proj=${proj#*_} ;;
            *) proj='<no value>' ;;
          esac
          [ "$proj" = fresh-tmp ] && created=$young
          [ "$scenario" = volume-bad-created ] && [ "$v" = supabase_db_gone-tmp ] && created=not-a-date
          printf '%s\t%s\t%s\n' "$v" "$created" "$proj"
        done
        ;;
      rm)
        [ "$scenario" = volume-rm-fail ] && [ "${3:-}" = supabase_db_gone-tmp ] && exit 1
        ;;
    esac
    exit 0
    ;;
  system)
    if [ "${2:-}" = df ]; then
      printf 'Images\t0B (0%%)\nContainers\t0B (0%%)\nBuild Cache\t0B (0%%)\n'
      exit 0
    fi
    ;;
esac
printf 'unexpected fake docker argv:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 97
SH

cat >"$BIN/ps" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf 'ps' >>"$DOCKER_HYGIENE_TEST_CALLS"
printf '\t%s' "$@" >>"$DOCKER_HYGIENE_TEST_CALLS"
printf '\n' >>"$DOCKER_HYGIENE_TEST_CALLS"
scenario=${DOCKER_HYGIENE_TEST_SCENARIO:-clean}
[ "$scenario" = ps-fail ] && exit 1
case "$scenario" in
  zombies) printf '100 1 S\n101 100 Z\n102 100 S\n103 102 Z\n200 1 S\n201 200 Z\n' ;;
  holder-cmdline|worktree-holder|raced-live|stale-identity|late-stale-identity|proc-error|restart-fail|unknown-zombie|monorepo-root) printf '100 1 S\n101 100 Z\n' ;;
  nested-only) printf '100 1 S\n102 100 S\n103 102 Z\n' ;;
  inspect-fail|stop-fail|stop-raced-live|stop-stale-set|stop-late-stale-set|unknown-old-test|orphan-stop-fail|orphan-checkout-appears|orphan-bind-mount|orphan-live-outside) printf '100 1 S\n' ;;
esac
exit 0
SH

cat >"$BIN/supabase" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf 'supabase' >>"$DOCKER_HYGIENE_TEST_CALLS"
printf '\t%s' "$@" >>"$DOCKER_HYGIENE_TEST_CALLS"
printf '\n' >>"$DOCKER_HYGIENE_TEST_CALLS"
case "${DOCKER_HYGIENE_TEST_SCENARIO:-}" in
  stop-fail|orphan-stop-fail)
    if [ "${DOCKER_HYGIENE_TEST_SUPABASE_STDERR:-}" = long ]; then
      # A 450-byte progress line, then the cause: the 400-byte bound must keep
      # the end of the fold, not the start.
      printf 'stub-supabase: %0450d\nstub-supabase: final cause (simulated)\n' 0 >&2
      exit 1
    fi
    # Four stderr lines: the script keeps the last three, so the first must be
    # absent from the recorded detail and the other three present, in order.
    # A tab inside line two and a CRLF ending on line three must fold to single
    # spaces for the assertions' needles to match.
    printf 'stub-supabase: line-one-beyond-the-bound\nstub-supabase:\tconnecting\nstub-supabase: cannot stop (simulated)\r\nstub-supabase: exit 1 (simulated)\n' >&2
    exit 1 ;;
esac
exit 0
SH

cat >"$BIN/mktemp" <<'SH'
#!/usr/bin/env bash
if [ "${DOCKER_HYGIENE_TEST_MKTEMP_FAILURE:-0}" = 1 ]; then
  exit 1
fi
exec /usr/bin/mktemp "$@"
SH
chmod +x "$BIN/docker" "$BIN/ps" "$BIN/supabase" "$BIN/mktemp"
# A second PATH dir with every fixture EXCEPT supabase, for the preflight cases.
NOSUPA=$TMP/bin-nosupabase
mkdir -p "$NOSUPA"
ln -s "$BIN/docker" "$NOSUPA/docker"
ln -s "$BIN/ps" "$NOSUPA/ps"
ln -s "$BIN/mktemp" "$NOSUPA/mktemp"

make_proc_entry() {
  local pid=$1 ppid=$2 comm=$3 cgroup=$4
  mkdir -p "$TMP/proc/$pid/fd"
  ln -s / "$TMP/proc/$pid/cwd"
  : >"$TMP/proc/$pid/cmdline"
  : >"$TMP/proc/$pid/environ"
  printf '%s\n' "$comm" >"$TMP/proc/$pid/comm"
  printf '0::/%s\n' "$cgroup" >"$TMP/proc/$pid/cgroup"
  printf '%s\n' "$ppid" >"$TMP/proc/$pid/fixture-ppid"
}
make_proc_entry 100 1 docker-init docker-aaaaaaaaaaaa.scope
make_proc_entry 101 100 dead-child docker-aaaaaaaaaaaa.scope
make_proc_entry 102 100 node docker-aaaaaaaaaaaa.scope
make_proc_entry 103 102 dead-nested docker-aaaaaaaaaaaa.scope
make_proc_entry 200 1 postgres docker-bbbbbbbbbbbb.scope
make_proc_entry 201 200 dead-db docker-bbbbbbbbbbbb.scope
mkdir -p "$TMP/home/SITES/alpha/supabase" \
  "$TMP/home/SITES/monorepo/apps/app/supabase" \
  "$TMP/home/SITES/monorepo/.claude/worktrees/x/apps/app/supabase"
printf 'project_id = "alpha"\n' >"$TMP/home/SITES/alpha/supabase/config.toml"
printf 'project_id = "alpha"\n' >"$TMP/home/SITES/monorepo/apps/app/supabase/config.toml"
printf 'project_id = "alpha"\n' >"$TMP/home/SITES/monorepo/.claude/worktrees/x/apps/app/supabase/config.toml"
: >"$TMP/home/SITES/monorepo/.claude/worktrees/x/apps/app/held.txt"

run_hygiene() {
  if [ -d "$TMP/proc.unreadable" ]; then
    rm -rf "$TMP/proc"
    mv "$TMP/proc.unreadable" "$TMP/proc"
  fi
  rm -rf "$TMP/proc/900"
  rm -f "$CALLS.ps-format-count" "$CALLS.identity-count"
  local -a settings=(
    "PATH=$BIN:/usr/bin:/bin"
    "HOME=$TMP/home"
    "SITES=$TMP/home/SITES"
    "PROCFS_ROOT=$TMP/proc"
    "DOCKER_HYGIENE_TEST_ROOT=$TMP"
    "DOCKER_HYGIENE_TEST_CALLS=$CALLS"
    "PYTHONDONTWRITEBYTECODE=1"
  )
  : >"$CALLS"
  RUN_OUT=$(env "${settings[@]}" "$@" bash "$SCRIPT" 2>&1)
  RUN_RC=$?
}

# Characterization: preserve the established defaults, trailing counters, JSON
# keys, and default exit-zero contract before adding stricter opt-in behavior.
run_hygiene

equals "$RUN_RC" 0 "legacy default exits zero"
contains "$RUN_OUT" "===== docker-hygiene (DRY RUN) =====" "DRY_RUN defaults to one"
contains "$RUN_OUT" "thresholds: idle>7d exited>7d zombies>=5" "threshold defaults remain compatible"
contains "$RUN_OUT" "docker-hygiene: zombies:0 recycled:0 idle-stacks:0 exited:0 images:0 reclaim-mb:0 docker-errors:0 docker-flagged:0" "legacy summary counters remain present"
omits "$RUN_OUT" '"zombies"' "JSON defaults off"
omits "$(cat "$CALLS")" "supabase" "clean default never invokes Supabase"

run_hygiene JSON=1
json_line=$(printf '%s\n' "$RUN_OUT" | tail -1)
if python3 - "$json_line" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
expected = {
    "zombies": 0,
    "recycled": 0,
    "held": 0,
    "idle_stacks": 0,
    "exited_removed": 0,
    "images_removed": 0,
    "flagged": 0,
    "docker_errors": 0,
    "recycled_names": [],
    "idle_stack_names": [],
    "held_names": [],
}
for key, value in expected.items():
    assert key in obj, key
    assert obj[key] == value, (key, obj[key], value)
PY
then
  ok
else
  bad "legacy JSON keys or values changed: $json_line"
fi

# Prove the harness itself intercepted every prohibited live command class.
contains "$(cat "$CALLS")" $'docker\tinfo' "fake Docker received the daemon probe"
contains "$(cat "$CALLS")" $'ps\t-eo\tpid,ppid,stat\t--no-headers' "fake ps received the process snapshot"
omits "$(cat "$CALLS")" "docker\trestart" "clean characterization performs no mutation"

# Operational inspection failure is explicit in both modes. Legacy invocation
# still exits zero; STRICT=1 turns the same observed error into service failure.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=daemon-down JSON=1
legacy_down_rc=$RUN_RC
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=daemon-down JSON=1 STRICT=1
strict_down_out=$RUN_OUT
strict_down_rc=$RUN_RC

equals "$legacy_down_rc" 0 "daemon failure preserves legacy default exit"
equals "$strict_down_rc" 1 "strict daemon failure exits nonzero"
contains "$strict_down_out" "docker-errors:1" "daemon failure preserves legacy error counter"
strict_json=$(printf '%s\n' "$strict_down_out" | tail -1)
if python3 - "$strict_json" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
assert obj["state"] == "error"
assert obj["inventory_complete"] is False
assert obj["inspection_errors"] == 1
assert obj["action_errors"] == 0
assert obj["docker_errors"] == 1
PY
then
  ok
else
  bad "strict daemon failure omitted additive error state: $strict_down_out"
fi

# Direct PID-1 zombies retain the legacy meaning. Descendant zombies are an
# additive diagnostic and never widen the restart allowlist/threshold decision.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies DRY_RUN=0 ZOMBIE_MAX=1 JSON=1
zombie_out=$RUN_OUT
zombie_calls=$(grep -E $'^docker\t(restart|rm|rmi|stop|builder)' "$CALLS" || true)
equals "$RUN_RC" 0 "successful recycle exits zero"
equals "$zombie_calls" $'docker\trestart\taaaaaaaaaaaa' "only the allowlisted exact container is mutated"
contains "$zombie_out" "docker-hygiene: zombies:2 recycled:1" "legacy direct-zombie and recycle counters remain"
omits "$zombie_calls" "bbbbbbbbbbbb" "non-allowlisted zombie container is preserved"
volume_calls=$(grep -E $'^docker\tvolume\t' "$CALLS" || true)
equals "$volume_calls" $'docker\tvolume\tls\t-f\tdangling=true\t--format\t{{.Name}}' "volume handling remains one read-only inventory call"
zombie_json=$(printf '%s\n' "$zombie_out" | tail -1)
if python3 - "$zombie_json" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
assert obj["zombies"] == 2
assert obj["zombies_total"] == 3
assert obj["recycled"] == 1
assert obj["held"] == 1
assert obj["init_detected"] == 1
assert obj["init_unknown"] == 0
assert obj["inventory_complete"] is True
assert obj["state"] == "complete"
by_id = {row["id"]: row for row in obj["container_observations"]}
assert by_id["aaaaaaaaaaaa"]["direct_zombies"] == 1
assert by_id["aaaaaaaaaaaa"]["total_zombies"] == 2
assert by_id["aaaaaaaaaaaa"]["init"] == "detected"
assert by_id["aaaaaaaaaaaa"]["decision"] == "recycled"
assert by_id["bbbbbbbbbbbb"]["direct_zombies"] == 1
assert by_id["bbbbbbbbbbbb"]["total_zombies"] == 1
assert by_id["bbbbbbbbbbbb"]["init"] == "not_detected"
assert by_id["bbbbbbbbbbbb"]["decision"] == "held_not_recyclable"
PY
then
  ok
else
  bad "container-attributed zombie/init report is incomplete: $zombie_json"
fi

assert_container_decision() {
  local output=$1 want=$2 label=$3 json_line
  json_line=$(printf '%s\n' "$output" | tail -1)
  if python3 - "$json_line" "$want" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
rows = [row for row in obj["container_observations"] if row["id"] == "aaaaaaaaaaaa"]
assert len(rows) == 1, rows
assert rows[0]["decision"] == sys.argv[2], rows[0]
PY
  then ok; else bad "$label: wanted decision $want"; fi
}

# A holder visible only through the shared fd/cwd/environ/cmdline snapshot is
# live work. The helper stays quiet so no raw process payload enters the report.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=holder-cmdline DRY_RUN=0 ZOMBIE_MAX=1 JSON=1
holder_calls=$(grep -E $'^docker\t(restart|rm|rmi|stop|builder)' "$CALLS" || true)
equals "$holder_calls" "" "cmdline-only checkout holder prevents every mutation"
assert_container_decision "$RUN_OUT" held_live_work "cmdline holder is reported as an intentional hold"
omits "$RUN_OUT" "DO_NOT_LOG_RAW" "raw cmdline payload is not logged"

# AE3: work appearing only after initial classification is caught by the fresh
# action-boundary check, not raced by a stale startup snapshot.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=raced-live DRY_RUN=0 ZOMBIE_MAX=1 JSON=1
race_calls=$(grep -E $'^docker\t(restart|rm|rmi|stop|builder)' "$CALLS" || true)
equals "$race_calls" "" "new live cwd at the action boundary prevents restart"
assert_container_decision "$RUN_OUT" held_live_work "raced live work is reported as a hold"

# The named container's PID/project/name tuple must still be identical just
# before restart. A recreated or PID-reused target is preserved.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stale-identity DRY_RUN=0 ZOMBIE_MAX=1 JSON=1
stale_calls=$(grep -E $'^docker\t(restart|rm|rmi|stop|builder)' "$CALLS" || true)
equals "$stale_calls" "" "stale target identity prevents restart"
assert_container_decision "$RUN_OUT" held_stale_identity "stale identity has a distinct reason"

# Identity is refreshed after the liveness scan as the final restart boundary;
# a concurrent restart during that scan changes the host PID and must hold.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=late-stale-identity DRY_RUN=0 ZOMBIE_MAX=1 JSON=1 STRICT=1
late_stale_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$late_stale_calls" "" "identity changing during liveness prevents restart"
equals "$RUN_RC" 0 "late stale-identity restart hold is not a strict error"
assert_container_decision "$RUN_OUT" held_stale_identity "late identity race has a distinct reason"

# An answerless required procfs snapshot cannot look idle. It is an inspection
# error (strict fails), while the candidate remains untouched.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=proc-error DRY_RUN=0 ZOMBIE_MAX=1 JSON=1 STRICT=1
proc_error_calls=$(grep -E $'^docker\t(restart|rm|rmi|stop|builder)' "$CALLS" || true)
equals "$proc_error_calls" "" "unreadable action-boundary procfs prevents restart"
equals "$RUN_RC" 1 "strict procfs inspection error exits nonzero"
contains "$RUN_OUT" "state:error" "procfs inspection error cannot report complete"
assert_container_decision "$RUN_OUT" held_liveness_unknown "unreadable liveness has a distinct hold reason"

# Every attempted mutation reports its result. Failed restart/rm/rmi/stop never
# increments a success counter, and strict mode returns failure.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=restart-fail DRY_RUN=0 ZOMBIE_MAX=1 JSON=1 STRICT=1
restart_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$restart_fail_calls" $'docker\trestart\taaaaaaaaaaaa' "failed restart attempted only the exact eligible target"
equals "$RUN_RC" 1 "failed restart makes strict mode fail"
contains "$RUN_OUT" "recycled:0" "failed restart is not counted as recycled"
contains "$RUN_OUT" "action-errors:1" "failed restart has an action-error counter"
assert_container_decision "$RUN_OUT" action_error "failed restart has a per-target result"

# The in-process counter, not the best-effort detail file, controls strict state.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=restart-fail DOCKER_HYGIENE_TEST_ACTION_DETAIL_FAILURE=1 DRY_RUN=0 ZOMBIE_MAX=1 JSON=1 STRICT=1
equals "$RUN_RC" 1 "failed restart survives action-detail write failure"
assert_json_field "$RUN_OUT" action_errors 1 "restart counter survives action-detail write failure"
assert_json_field "$RUN_OUT" action_error_details "[]" "failed restart tolerates unavailable action detail"

assert_stack_decision() {
  local output=$1 want=$2 label=$3 json_line
  json_line=$(printf '%s\n' "$output" | tail -1)
  if python3 - "$json_line" "$want" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
rows = obj["stack_observations"]
assert len(rows) == 1, rows
assert rows[0]["decision"] == sys.argv[2], rows[0]
PY
  then ok; else bad "$label: wanted decision $want"; fi
}

# A detached process can hold only a sibling worktree while its real cwd is
# outside SITES. The liveness-only checkout map must include that worktree for
# both restart and explicit stop gates without making it participate in age.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=worktree-holder DRY_RUN=0 ZOMBIE_MAX=1 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
worktree_holder_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$worktree_holder_calls" "" "detached worktree fd/env/argv holder prevents restart and stop"
equals "$RUN_RC" 0 "detached worktree hold is not a strict operational error"
contains "$RUN_OUT" "across 2 checkout(s)" "worktree checkout remains excluded from age retention"
assert_container_decision "$RUN_OUT" held_live_work "detached worktree holder blocks restart"
assert_stack_decision "$RUN_OUT" held_live_work "detached worktree holder blocks explicit stop"
omits "$RUN_OUT" "DO_NOT_LOG_RAW" "detached worktree argv payload is not logged"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-fail DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
stop_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$stop_fail_calls" $'supabase\tstop' "failed explicit stop invokes only Supabase stop with exact argv"
equals "$RUN_RC" 1 "failed Supabase stop makes strict mode fail"
contains "$RUN_OUT" "action-errors:1" "failed Supabase stop has an action-error counter"
assert_stack_decision "$RUN_OUT" action_error "failed Supabase stop has a per-stack result"
# The CLI's stderr survives into the FAILED line, the terminal detail and the
# JSON detail; the fold keeps the last three lines as one entry (issue #1555).
contains "$RUN_OUT" "!! FAILED to stop alpha (rc=1): stub-supabase: connecting stub-supabase: cannot stop (simulated) stub-supabase: exit 1 (simulated)" "failed idle stop names the CLI's exit code and stderr"
contains "$RUN_OUT" "failed: supabase stop project=alpha cwd=" "failed idle stop detail keeps the cwd it stopped from"
contains "$RUN_OUT" "rc=1 stderr: stub-supabase: connecting stub-supabase: cannot stop (simulated) stub-supabase: exit 1 (simulated)" "failed idle stop detail carries the folded stderr"
omits "$RUN_OUT" "line-one-beyond-the-bound" "idle stderr capture is bounded to the last lines"
assert_json_list_contains "$RUN_OUT" action_error_details "project=alpha cwd=" "JSON action detail names the idle stop's project and cwd"
assert_json_list_contains "$RUN_OUT" action_error_details "rc=1 stderr: stub-supabase: connecting stub-supabase: cannot stop (simulated)" "JSON action detail carries the idle stop's exit code and stderr as one entry"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-fail DOCKER_HYGIENE_TEST_ACTION_DETAIL_FAILURE=1 DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
equals "$RUN_RC" 1 "failed Supabase stop survives action-detail write failure"
assert_json_field "$RUN_OUT" action_errors 1 "stop counter survives action-detail write failure"
assert_json_field "$RUN_OUT" action_error_details "[]" "failed stop tolerates unavailable action detail"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-raced-live DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
stop_race_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$stop_race_calls" "" "work appearing before explicit stop prevents every mutation"
equals "$RUN_RC" 0 "live-work stop hold is not a strict error"
assert_stack_decision "$RUN_OUT" held_live_work "raced explicit stop reports an intentional hold"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-stale-set DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
stop_stale_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$stop_stale_calls" "" "changed stack container set prevents explicit stop"
equals "$RUN_RC" 0 "changed target set is an intentional strict-mode hold"
assert_stack_decision "$RUN_OUT" held_stale_identity "changed stack set has a distinct reason"

# The exact running set is refreshed again after liveness, immediately before
# stop, so a container appearing during that scan cannot be stopped implicitly.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-late-stale-set DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
stop_late_stale_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$stop_late_stale_calls" "" "stack set changing during liveness prevents explicit stop"
equals "$RUN_RC" 0 "late changed target set is an intentional strict-mode hold"
assert_stack_decision "$RUN_OUT" held_stale_identity "late stack-set race has a distinct reason"

# The exact-set recheck compares container identities, not serialization. A
# stable multi-container stack remains eligible for one explicitly requested
# Supabase stop.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
stable_stack_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$stable_stack_calls" $'supabase\tstop' "stable multi-container set permits exactly one explicit stop"
equals "$RUN_RC" 0 "successful multi-container stop exits zero in strict mode"
assert_stack_decision "$RUN_OUT" stopped "stable multi-container set is not a stale-identity hold"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=unknown-old-test DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
unknown_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$unknown_calls" "" "old test-like stack with no owner is preserved"
equals "$RUN_RC" 0 "unknown-owner hold is not a strict error"
assert_stack_decision "$RUN_OUT" held_unknown_owner "missing owner is explicit, not idle eligibility"

# STOP_ORPHANS: a stack with no config.toml anywhere and no live cwd is an
# orphan. Off by default, so the hold above is unchanged. On, it is stopped by
# label through the same guarded path as an idle stop.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=unknown-old-test DRY_RUN=1 STOP_ORPHANS=1 JSON=1 STRICT=1
orphan_plan_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$orphan_plan_calls" "" "orphan dry run never invokes Supabase"
equals "$RUN_RC" 0 "orphan dry run exits zero in strict mode"
contains "$RUN_OUT" "would: supabase stop --project-id verify-old" "orphan dry run names the exact stop"
assert_stack_decision "$RUN_OUT" stop_planned "orphan dry run is a planned stop, not a hold"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=unknown-old-test DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
orphan_stop_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$orphan_stop_calls" $'supabase\tstop\t--project-id\tverify-old' "orphan stop addresses the stack by label with exact argv"
contains "$RUN_OUT" "docker-hygiene: supabase CLI: $BIN/supabase (stack stops enabled)" "an acting run logs the resolved supabase binary"
equals "$RUN_RC" 0 "successful orphan stop exits zero in strict mode"
contains "$RUN_OUT" "ok: stopped verify-old" "orphan stop reports success"
assert_stack_decision "$RUN_OUT" stopped "orphan stop has a per-stack result"

# STOP_ORPHANS is independent of STOP_IDLE: enabling it does not widen the idle
# path, and a live holder still holds an idle candidate.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-raced-live DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 STOP_ORPHANS=1 JSON=1 STRICT=1
orphan_idle_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$orphan_idle_calls" "" "STOP_ORPHANS does not relax the idle path's live-work hold"
assert_stack_decision "$RUN_OUT" held_live_work "idle candidate with a live holder still holds under STOP_ORPHANS"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=orphan-stop-fail DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
equals "$RUN_RC" 1 "failed orphan stop makes strict mode fail"
contains "$RUN_OUT" "action-errors:1" "failed orphan stop has an action-error counter"
assert_stack_decision "$RUN_OUT" action_error "failed orphan stop has a per-stack result"
contains "$RUN_OUT" "!! FAILED to stop verify-old (rc=1): stub-supabase: connecting stub-supabase: cannot stop (simulated) stub-supabase: exit 1 (simulated)" "failed orphan stop names the CLI's exit code and stderr"
contains "$RUN_OUT" "failed: supabase stop project=verify-old --project-id rc=1 stderr: stub-supabase: connecting stub-supabase: cannot stop (simulated) stub-supabase: exit 1 (simulated)" "failed orphan stop detail carries the folded stderr"
omits "$RUN_OUT" "line-one-beyond-the-bound" "orphan stderr capture is bounded to the last lines"
assert_json_list_contains "$RUN_OUT" action_error_details "project=verify-old --project-id rc=1 stderr: stub-supabase: connecting stub-supabase: cannot stop (simulated) stub-supabase: exit 1 (simulated)" "JSON action detail carries the orphan stop's exit code and stderr as one entry"
assert_json_field "$RUN_OUT" action_errors 1 "multi-line stderr is still one action error"

# The byte bound keeps the END of the fold: a long progress line before the
# error must not push the error line out of the recorded cause.
long_line=$(printf '%0450d' 0)
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=orphan-stop-fail DOCKER_HYGIENE_TEST_SUPABASE_STDERR=long DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
contains "$RUN_OUT" "stub-supabase: final cause (simulated)" "the bound keeps the CLI's final line after a long earlier line"
omits "$RUN_OUT" "stub-supabase: $long_line" "the bound drops the start of a long earlier line"
assert_json_list_contains "$RUN_OUT" action_error_details "stub-supabase: final cause (simulated)" "JSON detail keeps the final cause past a long earlier line"

# The capture file is a reporting aid, not a precondition: when it cannot be
# written the stop still runs, the CLI's stderr passes through to the run's
# own stderr, and the recorded cause says why it is missing.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=orphan-stop-fail DOCKER_HYGIENE_TEST_STDERR_CAPTURE_FAILURE=1 DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
capture_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$capture_fail_calls" $'supabase\tstop\t--project-id\tverify-old' "an unwritable capture file does not prevent the stop"
equals "$RUN_RC" 1 "a failed stop without capture is still a strict failure"
contains "$RUN_OUT" "!! FAILED to stop verify-old (rc=1): (stderr capture unavailable: cannot write " "missing capture is named in the FAILED line"
contains "$RUN_OUT" "stub-supabase: cannot stop (simulated)" "without a capture file the CLI's stderr passes through to the run's own stderr"
assert_json_list_contains "$RUN_OUT" action_error_details "stderr: (stderr capture unavailable: cannot write " "JSON detail says why the cause is missing"

# A checkout declaring the project can appear between plan and action (someone
# runs `supabase init` for the same project_id elsewhere). Orphan mode re-scans
# the checkout map at action time and turns that into a hold; the idle path
# owns the stack from the next run.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=orphan-checkout-appears DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
orphan_late_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$orphan_late_calls" "" "a checkout appearing before action prevents the orphan stop"
equals "$RUN_RC" 0 "late checkout is an intentional strict-mode hold"
contains "$RUN_OUT" "checkout_appeared" "late checkout hold names its reason"
assert_stack_decision "$RUN_OUT" held_live_work "late checkout is recorded as a live-work hold"
rm -rf "$TMP/home/SITES/late-checkout"

# "No checkout anywhere" must mean more than $SITES. Two unscoped signals hold
# an orphan candidate: a stack bind mount whose checkout still exists on disk,
# and a live process cwd (anywhere) that walks up to this project's config.toml.
# Both fixtures live OUTSIDE $SITES, where the plan-time scan and the liveness
# map cannot see them.
mkdir -p "$TMP/outside-checkout/supabase" "$TMP/outside-live/verify-old/supabase"
printf 'project_id = "verify-old"\n' >"$TMP/outside-live/verify-old/supabase/config.toml"
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=orphan-bind-mount DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
orphan_bind_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$orphan_bind_calls" "" "a bind-mounted checkout outside SITES prevents the orphan stop"
equals "$RUN_RC" 0 "bind-mount evidence is an intentional strict-mode hold"
contains "$RUN_OUT" "bind_mount_checkout_exists" "bind-mount hold names its evidence"
assert_stack_decision "$RUN_OUT" held_unknown_owner "bind-mounted checkout is an owner hold, not an orphan"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=orphan-live-outside DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
orphan_outside_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$orphan_outside_calls" "" "a live cwd in a checkout outside SITES prevents the orphan stop"
equals "$RUN_RC" 0 "outside-SITES live cwd is an intentional strict-mode hold"
contains "$RUN_OUT" "live_process_cwd_outside_sites" "outside-SITES hold names its evidence"
assert_stack_decision "$RUN_OUT" held_unknown_owner "outside-SITES live cwd is an owner hold, not an orphan"

# Planted negative: a missing checkout cannot serve as proof that a zombie-choked
# container is idle. Unknown ownership is a successful fail-closed hold.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=unknown-zombie DRY_RUN=0 ZOMBIE_MAX=1 JSON=1 STRICT=1
unknown_zombie_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$unknown_zombie_calls" "" "missing checkout evidence prevents zombie restart"
equals "$RUN_RC" 0 "unknown-owner restart hold is not a strict operational error"
assert_container_decision "$RUN_OUT" held_unknown_owner "missing checkout is an explicit container hold"
contains "$RUN_OUT" "no mapped checkout" "unknown-owner restart hold names the missing evidence"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=rm-fail DRY_RUN=0 EXITED_DAYS=0 JSON=1 STRICT=1
rm_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$rm_fail_calls" $'docker\trm\taaaaaaaaaaaa' "failed removal targets only the named exited container"
equals "$RUN_RC" 1 "failed exited-container removal makes strict mode fail"
contains "$RUN_OUT" "exited:0" "failed removal is not counted as removed"
contains "$RUN_OUT" "action-errors:1" "failed removal has an action-error counter"
omits "$RUN_OUT" "(none eligible)" "a failed removal was still an eligible container"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=rmi-fail DRY_RUN=0 JSON=1 STRICT=1
rmi_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$rmi_fail_calls" $'docker\trmi\tsha256:deadbeef' "failed image removal targets only the named dangling image"
equals "$RUN_RC" 1 "failed image removal makes strict mode fail"
contains "$RUN_OUT" "images:0" "failed image removal is not counted as removed"
contains "$RUN_OUT" "action-errors:1" "failed image removal has an action-error counter"

# Issue #1630: run() succeeds under DRY_RUN=1, so each would-rm/would-rmi used
# to count as removed, and the weekly DRY_RUN=1 JSON=1 report's exited_removed
# and images_removed counted would-removals (the defect #1628 fixed for
# volumes). A dry run plans, counts nothing, and does not call a planned
# container "none eligible"; the real run counts exactly what it removed.
mutation_calls() { grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true; }
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=exited DRY_RUN=1 EXITED_DAYS=0 JSON=1 STRICT=1
equals "$(mutation_calls)" "" "#1630: exited-container dry run removes nothing"
equals "$RUN_RC" 0 "#1630: exited-container dry run is clean under STRICT"
contains "$RUN_OUT" "would: docker rm aaaaaaaaaaaa" "#1630: exited-container dry run previews the removal"
omits "$RUN_OUT" "(none eligible)" "#1630: a previewed exited container is eligible"
contains "$RUN_OUT" "exited removed .......... 0" "#1630: dry-run summary table counts no exited container as removed"
contains "$RUN_OUT" " exited:0 " "#1630: dry-run summary line counts no exited container as removed"
assert_json_field "$RUN_OUT" exited_removed 0 "#1630: dry-run JSON exited_removed stays zero"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=exited DRY_RUN=0 EXITED_DAYS=0 JSON=1 STRICT=1
equals "$(mutation_calls)" $'docker\trm\taaaaaaaaaaaa' "#1630: exited-container real run removes exactly the eligible container"
equals "$RUN_RC" 0 "#1630: a clean exited-container removal exits zero under STRICT"
contains "$RUN_OUT" "ok: docker rm aaaaaaaaaaaa" "#1630: the real removal is reported"
omits "$RUN_OUT" "(none eligible)" "#1630: a removed exited container was eligible"
contains "$RUN_OUT" "exited removed .......... 1" "#1630: summary table counts the real exited removal"
contains "$RUN_OUT" " exited:1 " "#1630: summary line counts the real exited removal"
assert_json_field "$RUN_OUT" exited_removed 1 "#1630: JSON counts the real exited removal"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=dangling DRY_RUN=1 JSON=1 STRICT=1
equals "$(mutation_calls)" "" "#1630: dangling-image dry run removes nothing"
contains "$RUN_OUT" "would: docker rmi sha256:deadbeef" "#1630: dangling-image dry run previews the removal"
contains "$RUN_OUT" "images removed .......... 0" "#1630: dry-run summary table counts no image as removed"
contains "$RUN_OUT" " images:0 " "#1630: dry-run summary line counts no image as removed"
assert_json_field "$RUN_OUT" images_removed 0 "#1630: dry-run JSON images_removed stays zero"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=dangling DRY_RUN=0 JSON=1 STRICT=1
equals "$(mutation_calls)" $'docker\trmi\tsha256:deadbeef' "#1630: dangling-image real run removes exactly the dangling image"
equals "$RUN_RC" 0 "#1630: a clean dangling-image removal exits zero under STRICT"
contains "$RUN_OUT" "images removed .......... 1" "#1630: summary table counts the real image removal"
contains "$RUN_OUT" " images:1 " "#1630: summary line counts the real image removal"
assert_json_field "$RUN_OUT" images_removed 1 "#1630: JSON counts the real image removal"

# AGGRESSIVE shares the counter: only the image no container references is a
# candidate, a dry run previews it without counting, a real run counts it.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=aggressive DRY_RUN=1 AGGRESSIVE=1 JSON=1 STRICT=1
equals "$(mutation_calls)" "" "#1630: AGGRESSIVE dry run removes nothing"
contains "$RUN_OUT" "would: docker rmi sha256:unused-image" "#1630: AGGRESSIVE dry run previews the unreferenced image"
omits "$RUN_OUT" "would: docker rmi sha256:image-aaaaaaaaaaaa" "AGGRESSIVE dry run keeps the in-use image"
contains "$RUN_OUT" "images removed .......... 0" "#1630: AGGRESSIVE dry-run summary table counts no image as removed"
contains "$RUN_OUT" " images:0 " "#1630: AGGRESSIVE dry-run summary line counts no image as removed"
assert_json_field "$RUN_OUT" images_removed 0 "#1630: AGGRESSIVE dry-run JSON images_removed stays zero"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=aggressive DRY_RUN=0 AGGRESSIVE=1 JSON=1 STRICT=1
equals "$(mutation_calls)" $'docker\trmi\tsha256:unused-image' "#1630: AGGRESSIVE real run removes exactly the unreferenced image"
equals "$RUN_RC" 0 "#1630: a clean AGGRESSIVE removal exits zero under STRICT"
contains "$RUN_OUT" "images removed .......... 1" "#1630: summary table counts the real AGGRESSIVE removal"
assert_json_field "$RUN_OUT" images_removed 1 "#1630: JSON counts the real AGGRESSIVE removal"

# Mid-inventory Docker inspection failures produce an incomplete/error report,
# never a clean no-op, and perform no mutation.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=inspect-fail DRY_RUN=0 JSON=1 STRICT=1
inspect_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$inspect_fail_calls" "" "inspection failure performs no mutation"
equals "$RUN_RC" 1 "mid-inventory Docker failure makes strict mode fail"
contains "$RUN_OUT" "docker-errors:" "inspection failure retains Docker error counter"
contains "$RUN_OUT" "state:error" "inspection failure cannot report a complete state"
assert_container_decision "$RUN_OUT" held_inspection_error "container inspection failure has a per-target reason"

# Aggressive image decisions require a complete all-container image snapshot.
# A failed prerequisite read cannot turn every tagged image into a candidate.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=inuse-snapshot-fail DRY_RUN=0 AGGRESSIVE=1 JSON=1 STRICT=1
inuse_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$inuse_fail_calls" "" "failed in-use image snapshot prevents aggressive removal"
equals "$RUN_RC" 1 "failed in-use image snapshot makes strict mode fail"
contains "$RUN_OUT" "AGGRESSIVE skipped" "failed prerequisite names the suppressed image action"

# A full/unavailable scratch filesystem fails admission before any mutation.
# Reporting remains valid and explicit, with strict additive to legacy exit zero.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=rm-fail DOCKER_HYGIENE_TEST_MKTEMP_FAILURE=1 DRY_RUN=0 EXITED_DAYS=0 JSON=1 STRICT=1
scratch_strict_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$scratch_strict_calls" "" "scratch allocation failure prevents every mutation"
equals "$RUN_RC" 1 "scratch allocation failure makes strict mode fail"
contains "$RUN_OUT" "reporting scratch unavailable; no actions attempted" "scratch allocation failure is explicit"
assert_json_field "$RUN_OUT" state error "scratch allocation failure cannot report complete state"
assert_json_field "$RUN_OUT" inventory_complete false "scratch allocation failure marks inventory incomplete"
assert_json_field "$RUN_OUT" observation_errors 1 "scratch allocation failure has a reporting error"
assert_json_field "$RUN_OUT" action_errors 0 "scratch admission does not claim an attempted action"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=rm-fail DOCKER_HYGIENE_TEST_MKTEMP_FAILURE=1 DRY_RUN=0 EXITED_DAYS=0 JSON=1
scratch_legacy_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$scratch_legacy_calls" "" "legacy scratch failure also prevents every mutation"
equals "$RUN_RC" 0 "scratch allocation failure preserves the legacy exit contract"
assert_json_field "$RUN_OUT" state error "legacy scratch failure remains a valid error report"

# Observation writes and terminal JSON serialization are required reporting
# operations. Either failure must make the report explicit/incomplete; strict is
# additive, so the legacy/default invocation still returns success.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE=all JSON=1 STRICT=1
observation_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$observation_fail_calls" "" "failed observation writes perform no mutation"
equals "$RUN_RC" 1 "failed observation writes make strict mode fail"
contains "$RUN_OUT" "observation/reporting operation(s) FAILED" "failed observation writes are explicit"
assert_json_field "$RUN_OUT" observation_errors 3 "container and stack write failures have an additive error count"
assert_json_field "$RUN_OUT" state error "failed observation writes cannot report complete state"
assert_json_field "$RUN_OUT" inventory_complete false "failed observation writes mark inventory incomplete"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE=all JSON=1
equals "$RUN_RC" 0 "failed observation writes preserve the legacy exit contract"

run_hygiene DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE=json JSON=1 STRICT=1
equals "$RUN_RC" 1 "failed final JSON assembly makes strict mode fail"
contains "$RUN_OUT" "final JSON assembly failed" "failed final JSON assembly is explicit"
assert_json_field "$RUN_OUT" json_error final_json_assembly_failed "assembly failure emits a valid typed fallback"
assert_json_field "$RUN_OUT" state error "assembly failure fallback cannot report complete state"
assert_json_field "$RUN_OUT" inventory_complete false "assembly failure fallback marks inventory incomplete"

run_hygiene DOCKER_HYGIENE_TEST_OBSERVATION_FAILURE=json JSON=1
equals "$RUN_RC" 0 "failed final JSON assembly preserves the legacy exit contract"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=ps-fail DRY_RUN=0 ZOMBIE_MAX=1 JSON=1 STRICT=1
ps_fail_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$ps_fail_calls" "" "failed process snapshot cannot trigger mutation"
equals "$RUN_RC" 1 "failed process snapshot makes strict mode fail"
contains "$RUN_OUT" "inventory-complete:false" "failed process snapshot is incomplete"

# A descendant-only zombie is visible but cannot satisfy the direct-PID-1
# threshold that governs recycling.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=nested-only DRY_RUN=0 ZOMBIE_MAX=1 JSON=1
nested_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$nested_calls" "" "nested-only zombie does not widen restart eligibility"
contains "$RUN_OUT" "zombies:0 recycled:0" "nested-only case preserves direct legacy counters"
contains "$RUN_OUT" "zombies-total:1" "nested-only zombie remains visible"
assert_container_decision "$RUN_OUT" observed_nested_only "nested-only target names the diagnostic decision"

# Existing downward cwd discovery protects a stack nested under a monorepo.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=monorepo-root DRY_RUN=0 ZOMBIE_MAX=1 JSON=1
monorepo_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$monorepo_calls" "" "monorepo-root cwd protects nested stack"
assert_container_decision "$RUN_OUT" held_live_work "downward monorepo discovery remains positive"

# Compatibility controls retain their old scope and default safety.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies DRY_RUN=0 ZOMBIE_MAX=1 ONLY=beta JSON=1
only_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$only_calls" "" "ONLY excludes every alpha mutation"
contains "$RUN_OUT" "zombies:0 recycled:0 idle-stacks:0 exited:0 images:0" "ONLY leaves excluded counters zero"
contains "$RUN_OUT" "skipped: ONLY=beta is set" "ONLY still suppresses unscoped image cleanup"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies ZOMBIE_MAX=1 JSON=1
plan_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$plan_calls" "" "dry run performs no mutation"
contains "$RUN_OUT" "would: docker restart aaaaaaaaaaaa" "dry run still names exact planned restart"
plan_json=$(printf '%s\n' "$RUN_OUT" | tail -1)
if python3 - "$plan_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
row = next(row for row in obj["container_observations"] if row["id"] == "aaaaaaaaaaaa")
assert row["action_result"] == "planned"
assert obj["zombies"] == 2
PY
then ok; else bad "dry-run JSON does not distinguish planned action"; fi

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=stop-fail DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=0 JSON=1 STRICT=1
stop_disabled_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
equals "$stop_disabled_calls" "" "STOP_IDLE=0 never invokes Supabase"
equals "$RUN_RC" 0 "reported idle stack is not a strict error"
assert_stack_decision "$RUN_OUT" reported_idle "disabled stop remains a report-only decision"

# Init coverage includes a denominator and every state, not just successes.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=zombies JSON=1
coverage_json=$(printf '%s\n' "$RUN_OUT" | tail -1)
if python3 - "$coverage_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
assert obj["containers_observed"] == 2
assert obj["init_detected"] == 1
assert obj["init_not_detected"] == 1
assert obj["init_unknown"] == 0
PY
then ok; else bad "init coverage omits its denominator or a state: $coverage_json"; fi

# Supabase preflight (issue #1555): with DRY_RUN=0 and a stop mode on, a PATH
# that cannot resolve `supabase` is recorded once as an observation error
# before the first docker call (cause, PATH searched, remedy), every stop is
# refused per stack with no CLI call, exited-container and image reclaim
# continue, and STRICT turns the run into service failure. Dry runs and runs
# with both stop modes off never exec the CLI and are not gated.
nosupa_path="$NOSUPA:/usr/bin:/bin"
# Behavioural planted negative (issue #1555): a script that resolved supabase
# through a hard-coded home ($HOME/.local/bin or the mise shims) instead of
# PATH would find these copies and pass; the preflight must still fail with
# them present, because run_hygiene points HOME at $TMP/home.
mkdir -p "$TMP/home/.local/bin" "$TMP/home/.local/share/mise/shims"
cp "$BIN/supabase" "$TMP/home/.local/bin/supabase"
cp "$BIN/supabase" "$TMP/home/.local/share/mise/shims/supabase"
if ( PATH=$nosupa_path; command -v supabase ) >/dev/null 2>&1; then
  skip "supabase resolves under $nosupa_path on this host (a system package?); the preflight-failure cases cannot discriminate and did not run"
else
  run_hygiene PATH="$nosupa_path" DOCKER_HYGIENE_TEST_SCENARIO=orphan-stop-fail DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
  preflight_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
  equals "$RUN_RC" 1 "missing supabase fails the run under STRICT"
  contains "$RUN_OUT" "supabase CLI not found on PATH=$nosupa_path" "preflight names the binary and the PATH searched (and ignores a copy under HOME)"
  contains "$RUN_OUT" "Remedy: install the CLI, add its directory to the unit's Environment=PATH, or set STOP_ORPHANS=0" "preflight names the remedy"
  omits "$RUN_OUT" "set STOP_IDLE=0" "round 3 P2 control: orphan-only preflight miss does not name STOP_IDLE=0 in the remedy"
  contains "$RUN_OUT" "~ skip stop verify-old: supabase CLI not on PATH (preflight)" "the orphan stop is refused per stack"
  assert_stack_decision "$RUN_OUT" held_precondition "refused orphan stop has a per-stack held_precondition row"
  equals "$preflight_calls" "" "preflight miss makes no supabase call and no docker mutation"
  contains "$(cat "$CALLS")" $'docker\tinfo' "the run still reaches docker after a preflight miss (reclaim continues)"
  contains "$RUN_OUT" "observation-errors:1 action-errors:0 state:error" "preflight miss is an observation error, not an attempted action"
  assert_json_field "$RUN_OUT" state error "preflight miss is an error in JSON"
  assert_json_field "$RUN_OUT" action_errors 0 "preflight miss claims no attempted action in JSON"
  assert_json_list_contains "$RUN_OUT" observation_error_details "supabase CLI not found on PATH=$nosupa_path" "JSON carries the preflight cause"

  run_hygiene PATH="$nosupa_path" DOCKER_HYGIENE_TEST_SCENARIO=orphan-stop-fail DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=0
  nonstrict_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
  equals "$RUN_RC" 0 "missing supabase stays exit zero outside strict mode"
  contains "$RUN_OUT" "supabase CLI not found on PATH=" "non-strict run still reports the preflight cause"
  equals "$nonstrict_calls" "" "non-strict preflight miss still makes no supabase call"

  run_hygiene PATH="$nosupa_path" DOCKER_HYGIENE_TEST_SCENARIO=stop-fail DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 JSON=1 STRICT=1
  idle_preflight_calls=$(grep -E $'^(docker\t(restart|rm|rmi|stop|builder)|supabase\t)' "$CALLS" || true)
  equals "$RUN_RC" 1 "the idle stop path is gated by the same preflight"
  equals "$idle_preflight_calls" "" "idle-mode preflight miss makes no supabase call"
  contains "$RUN_OUT" "~ skip stop alpha: supabase CLI not on PATH (preflight)" "the idle stop is refused per stack"
  assert_stack_decision "$RUN_OUT" held_precondition "refused idle stop has a per-stack held_precondition row"
  # pro-gate round 3 P2 (#1562): the remedy named STOP_ORPHANS=0 for every
  # miss, which an idle-only run (STOP_IDLE=1 STOP_ORPHANS=0) already
  # satisfies, so following it changed nothing. The remedy must name the
  # stop mode(s) that are actually on.
  contains "$RUN_OUT" "or set STOP_IDLE=0 / disable docker-hygiene.timer" "round 3 P2: idle-only preflight miss names STOP_IDLE=0 as the stop-mode remedy"
  omits "$RUN_OUT" "set STOP_ORPHANS=0" "round 3 P2: idle-only preflight miss does not prescribe an already-satisfied STOP_ORPHANS=0"

  run_hygiene PATH="$nosupa_path" DRY_RUN=0 IDLE_DAYS=0 STOP_IDLE=1 STOP_ORPHANS=1 JSON=1 STRICT=1
  both_supabase_calls=$(grep -cE $'^supabase\t' "$CALLS" || true)
  equals "$RUN_RC" 1 "round 3 P2: a preflight miss with both stop modes on fails under STRICT"
  equals "$both_supabase_calls" 0 "round 3 P2: both-modes preflight miss makes no supabase call"
  contains "$RUN_OUT" "stack stops are enabled (STOP_IDLE=1 STOP_ORPHANS=1)" "round 3 P2: both-modes miss reports both modes as enabled"
  contains "$RUN_OUT" "or set STOP_IDLE=0 STOP_ORPHANS=0 / disable docker-hygiene.timer" "round 3 P2: both-modes preflight miss names both modes in the remedy"

  # Eager, not lazy: a host that enabled the timer with STOP_ORPHANS=1 and no
  # CLI is misconfigured and pages even when nothing needed stopping; the
  # remedy text names the fix. No stack is refused because none was due.
  run_hygiene PATH="$nosupa_path" DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
  noorphan_supabase_calls=$(grep -cE $'^supabase\t' "$CALLS" || true)
  equals "$RUN_RC" 1 "a preflight miss fails the run under STRICT even with no stack to stop"
  contains "$RUN_OUT" "supabase CLI not found on PATH=$nosupa_path" "no-orphan run still reports the preflight cause"
  omits "$RUN_OUT" "held_precondition" "no stack is refused when none was due"
  equals "$noorphan_supabase_calls" 0 "no-orphan preflight miss makes no supabase call"

  # pro-gate round 2 P2 (#1562): the preflight miss is recorded before the
  # daemon gate, and that gate's early exit used to print a fixed
  # observation_errors:0 with an empty detail list, contradicting the cause
  # printed a few lines above it. The gate's own record must carry the miss:
  # count, detail, inspection sum and flag, in the summary line and the JSON.
  run_hygiene PATH="$nosupa_path" DOCKER_HYGIENE_TEST_SCENARIO=daemon-down DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
  gate_supabase_calls=$(grep -cE $'^supabase\t' "$CALLS" || true)
  equals "$RUN_RC" 1 "round 2 P2: a preflight miss plus an unreachable daemon fails under STRICT"
  contains "$RUN_OUT" "supabase CLI not found on PATH=$nosupa_path" "round 2 P2: the preflight cause is still printed ahead of the gate"
  contains "$RUN_OUT" "docker daemon unreachable" "round 2 P2: the run still stops at the daemon gate"
  equals "$gate_supabase_calls" 0 "round 2 P2: no supabase call on either side of the gate"
  contains "$RUN_OUT" "  failed: supabase CLI not found on PATH=$nosupa_path" "round 2 P2: the daemon-gate exit lists the preflight cause in its text record"
  contains "$RUN_OUT" "docker-errors:1 docker-flagged:2" "round 2 P2: the daemon-gate summary flags the daemon and the preflight miss"
  contains "$RUN_OUT" "inspection-errors:2 observation-errors:1 action-errors:0 state:error inventory-complete:false" "round 2 P2: the daemon-gate summary carries the observation error"
  assert_json_field "$RUN_OUT" docker_errors 1 "round 2 P2: daemon-gate JSON keeps the daemon error"
  assert_json_field "$RUN_OUT" observation_errors 1 "round 2 P2: daemon-gate JSON counts the preflight observation error"
  assert_json_field "$RUN_OUT" inspection_errors 2 "round 2 P2: daemon-gate JSON inspection_errors is the daemon plus the preflight"
  assert_json_field "$RUN_OUT" flagged 2 "round 2 P2: daemon-gate JSON flagged counts the preflight miss"
  assert_json_field "$RUN_OUT" action_errors 0 "round 2 P2: a miss refused before any attempt is still not an action error at the gate"
  assert_json_field "$RUN_OUT" state error "round 2 P2: daemon-gate JSON state stays error"
  assert_json_list_contains "$RUN_OUT" observation_error_details "supabase CLI not found on PATH=$nosupa_path" "round 2 P2: daemon-gate JSON observation_error_details carries the preflight cause"
fi

# Control for round 2 P2: the same gate with the CLI present records the
# daemon error alone, and its summary line names the zero so the two runs are
# distinguishable by the same grep.
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=daemon-down DRY_RUN=0 STOP_ORPHANS=1 JSON=1 STRICT=1
equals "$RUN_RC" 1 "round 2 P2 control: an unreachable daemon alone fails under STRICT"
contains "$RUN_OUT" "docker-hygiene: supabase CLI: " "round 2 P2 control: the preflight passed before the gate"
contains "$RUN_OUT" "docker-errors:1 docker-flagged:1" "round 2 P2 control: the daemon-gate summary flags the daemon only"
contains "$RUN_OUT" "inspection-errors:1 observation-errors:0 action-errors:0 state:error inventory-complete:false" "round 2 P2 control: the daemon-gate summary carries a zero observation count"
omits "$RUN_OUT" "observation/reporting operation(s) FAILED" "round 2 P2 control: no observation WARN without a miss"
assert_json_field "$RUN_OUT" observation_errors 0 "round 2 P2 control: daemon-gate JSON records no observation error"
assert_json_field "$RUN_OUT" inspection_errors 1 "round 2 P2 control: daemon-gate JSON inspection_errors is the daemon error alone"
assert_json_field "$RUN_OUT" flagged 1 "round 2 P2 control: daemon-gate JSON flagged counts the daemon alone"

run_hygiene PATH="$nosupa_path" DOCKER_HYGIENE_TEST_SCENARIO=unknown-old-test DRY_RUN=1 STOP_ORPHANS=1 JSON=1 STRICT=1
equals "$RUN_RC" 0 "a dry run is not gated by the supabase preflight"
omits "$RUN_OUT" "supabase CLI not found" "dry run does not report a preflight failure"
contains "$RUN_OUT" "would: supabase stop --project-id verify-old" "dry run still prints the plan without the CLI"

run_hygiene PATH="$nosupa_path" DRY_RUN=0 EXITED_DAYS=0 JSON=1 STRICT=1
omits "$RUN_OUT" "supabase CLI not found" "a run with both stop modes off is not gated"
contains "$(cat "$CALLS")" "docker" "an ungated run proceeds to docker"

# Planted negatives from the issue: a hard-coded operator home passes on one
# host and fails every mise-shim host; a stop that still discards stderr passes
# the PATH test and fails the capture criterion on the first real CLI error.
if grep -nE '/(home|Users)/[A-Za-z0-9._-]+' "$SCRIPT" >/dev/null; then
  bad "script hard-codes a home directory, which resolves on one host only: $(grep -nE '/(home|Users)/[A-Za-z0-9._-]+' "$SCRIPT")"
else
  ok
fi
if grep -nE 'supabase stop[^#]*2>&1' "$SCRIPT" >/dev/null; then
  bad "a supabase stop still discards its stderr: $(grep -nE 'supabase stop[^#]*2>&1' "$SCRIPT")"
else
  ok
fi

# The shipped service is a plan-only template (DRY_RUN=1, orphan stops and volume
# reap off) that opts into strict failures and never enables idle stops (a quiet
# checkout is still someone's); the weekly report requests additive JSON while retaining its
# named counter.
service=$(cat "$REPO/systemd/docker-hygiene.service")
weekly=$(cat "$REPO/scripts/harness-weekly.sh")
contains "$service" "Environment=STRICT=1" "scheduled hygiene opts into strict mode"
omits "$service" "Environment=STOP_IDLE=1" "scheduled hygiene does not enable idle-stack stop"
contains "$service" "Environment=DRY_RUN=1" "shipped template is plan-only: DRY_RUN=1, nothing is deleted until the reader flips it"
contains "$service" "Environment=STOP_ORPHANS=0" "shipped template is plan-only: orphan-stack stop is off"
contains "$service" "Environment=REAP_VOLUMES=0" "shipped template is plan-only: undeclared Supabase volume reap is off"
contains "$(cat "$REPO/systemd/docker-hygiene.timer")" "OnCalendar=*-*-* 01:50:00" "hygiene timer fires daily (#1627)"
contains "$service" "Environment=PATH=%h/.local/bin:%h/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "scheduled hygiene carries the house PATH so supabase resolves under the user manager (#1555)"
contains "$weekly" "DRY_RUN=1 JSON=1 \"\$SCRIPTS/docker-hygiene.sh\"" "weekly report surfaces additive hygiene JSON"
contains "$weekly" "docker-flagged:" "weekly report preserves existing Docker counter consumer"

# ---- REAP_VOLUMES (issue #1627) ----
# Only a dangling, Supabase-labelled volume whose project no checkout under
# $SITES declares, older than the grace, is removed. A worktree config and an
# _archive config each declare their project; so does $SITES/<project>.
mkdir -p "$TMP/home/SITES/monorepo/.claude/worktrees/y/apps/z/supabase" "$TMP/home/SITES/_archive/old/supabase"
printf 'project_id = "wt-only"\n' >"$TMP/home/SITES/monorepo/.claude/worktrees/y/apps/z/supabase/config.toml"
printf 'project_id = "arch-only"\n' >"$TMP/home/SITES/_archive/old/supabase/config.toml"
volume_rm_calls() { grep -E $'^docker\tvolume\trm\t' "$CALLS" | cut -f4 | sort | tr '\n' ' '; }

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes DRY_RUN=0
equals "$(grep -cE $'^docker\tvolume\t' "$CALLS")" 1 "REAP_VOLUMES unset: volume handling stays one read-only inventory call"
contains "$RUN_OUT" "## volumes (report only; REAP_VOLUMES=1 reaps undeclared Supabase volumes)" "REAP_VOLUMES unset: report-only header"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 JSON=1
equals "$(volume_rm_calls)" "" "REAP_VOLUMES dry run removes nothing"
contains "$RUN_OUT" "would: docker volume rm supabase_db_gone-tmp" "REAP_VOLUMES dry run previews the undeclared volume"
# pro-gate round 1 P2: run() succeeds under DRY_RUN=1, so each would-rm used to
# count as removed and the dry run reported volumes:2 / volumes_removed 2.
equals "$(printf '%s\n' "$RUN_OUT" | sed -n 's/^docker-hygiene: zombies:.* volumes:\([0-9]*\)$/\1/p')" 0 "round 1 P2: dry-run summary line counts no volume as removed"
contains "$RUN_OUT" "volumes removed ......... 0" "round 1 P2: dry-run summary table counts no volume as removed"
assert_json_field "$RUN_OUT" volumes_removed 0 "round 1 P2: dry-run JSON volumes_removed stays zero"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1
equals "$RUN_RC" 0 "REAP_VOLUMES clean reap exits zero under STRICT"
equals "$(volume_rm_calls)" "supabase_db_gone-tmp supabase_storage_gone-tmp " "REAP_VOLUMES removes exactly the undeclared, old Supabase volumes"
contains "$RUN_OUT" 'keep supabase_db_alpha (project alpha: $SITES/alpha exists)' "a \$SITES/<project> directory declares its volumes"
contains "$RUN_OUT" "keep supabase_db_wt-only (project wt-only: declared by a checkout under" "a worktree config declares its volumes"
contains "$RUN_OUT" "keep supabase_db_arch-only (project arch-only: declared by a checkout under" "an _archive config declares its volumes"
contains "$RUN_OUT" "keep supabase_db_fresh-tmp (project fresh-tmp: younger than 24h)" "a volume inside the grace is kept"
contains "$RUN_OUT" "2 unlabelled or anonymous volume(s) kept" "unlabelled volumes are never reaped"
contains "$RUN_OUT" "keep 0123456789abcdef (no com.supabase.cli.project label)" "each unlabelled volume gets its own keep line"
contains "$RUN_OUT" "keep supabase_db_nolabel (no com.supabase.cli.project label)" "a Supabase-named volume without the label is kept: the label decides, not the name"
contains "$RUN_OUT" "volumes:2" "summary line counts removed volumes"
assert_json_field "$RUN_OUT" volumes_removed 2 "JSON counts removed volumes"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 VOLUME_GRACE_HOURS=0
equals "$(volume_rm_calls)" "supabase_db_fresh-tmp supabase_db_gone-tmp supabase_storage_gone-tmp " "VOLUME_GRACE_HOURS=0 also reaps the young undeclared volume"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 ONLY=alpha
equals "$(volume_rm_calls)" "" "ONLY= scopes the volume reap to that project"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 "SITES=$TMP/home/user/no-such-sites"
equals "$(volume_rm_calls)" "" "a failed checkout scan reaps nothing"
contains "$RUN_OUT" "keep supabase_db_gone-tmp (project gone-tmp: checkout scan failed)" "a failed checkout scan keeps each volume and says why"
equals "$RUN_RC" 1 "a failed checkout scan fails the run under STRICT"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volume-inspect-fail REAP_VOLUMES=1 DRY_RUN=0 STRICT=1
equals "$(volume_rm_calls)" "" "a failed volume inspection reaps nothing"
contains "$RUN_OUT" "volume inspection failed: no volume removed this run" "a failed volume inspection is reported"
equals "$RUN_RC" 1 "a failed volume inspection fails the run under STRICT"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volume-bad-created REAP_VOLUMES=1 DRY_RUN=0 STRICT=1
equals "$(volume_rm_calls)" "supabase_storage_gone-tmp " "an unreadable CreatedAt keeps that volume"
equals "$RUN_RC" 1 "an unreadable CreatedAt fails the run under STRICT"

run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volume-rm-fail REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1
equals "$RUN_RC" 1 "a failed volume removal fails the run under STRICT"
assert_json_field "$RUN_OUT" volumes_removed 1 "a failed volume removal is not counted as removed"
assert_json_list_contains "$RUN_OUT" action_error_details "docker volume rm supabase_db_gone-tmp" "a failed volume removal is one action-error detail"

# pro-gate P1 at e3607005: parse_project_id swallowed a read error, so a config
# the scan found but could not read declared nothing, the scan still counted as
# complete, and the project's old volumes were removed. A found config.toml
# that cannot be read now fails the scan: no volume is reaped.
mkdir -p "$TMP/home/SITES/locked/supabase"
printf 'project_id = "gone-tmp"\n' >"$TMP/home/SITES/locked/supabase/config.toml"
chmod 000 "$TMP/home/SITES/locked/supabase/config.toml"
if [ "$(id -u)" -ne 0 ]; then
  run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1
  equals "$(volume_rm_calls)" "" "pro-gate P1 at e3607005: an unreadable config.toml reaps no volume"
  contains "$RUN_OUT" "keep supabase_db_gone-tmp (project gone-tmp: checkout scan failed)" "pro-gate P1 at e3607005: an unreadable config.toml keeps the volume and says why"
  equals "$RUN_RC" 1 "pro-gate P1 at e3607005: an unreadable config.toml fails the run under STRICT"
  assert_json_list_contains "$RUN_OUT" observation_error_details "checkout scan could not read $TMP/home/SITES/locked/supabase/config.toml" "pro-gate P1 at e3607005: the unreadable config.toml is named"
else
  skip "pro-gate P1 at e3607005: the unreadable config.toml fixture needs a non-root process (chmod 000 does not block root)"
fi
rm -rf "$TMP/home/SITES/locked"
# The same holds as root, where chmod 000 blocks nothing: a config.toml the
# scan found that is gone when it is read (a dangling link here) reaps nothing.
mkdir -p "$TMP/home/SITES/vanished/supabase"
ln -s "$TMP/home/SITES/vanished/supabase/moved.toml" "$TMP/home/SITES/vanished/supabase/config.toml"
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1
equals "$(volume_rm_calls)" "" "pro-gate P1 at e3607005: a config.toml gone at read time reaps no volume"
contains "$RUN_OUT" "keep supabase_db_gone-tmp (project gone-tmp: checkout scan failed)" "pro-gate P1 at e3607005: a config.toml gone at read time keeps the volume and says why"
equals "$RUN_RC" 1 "pro-gate P1 at e3607005: a config.toml gone at read time fails the run under STRICT"
assert_json_list_contains "$RUN_OUT" observation_error_details "checkout scan could not read $TMP/home/SITES/vanished/supabase/config.toml" "pro-gate P1 at e3607005: the config.toml gone at read time is named"
rm -rf "$TMP/home/SITES/vanished"
# pro-gate round 2 P1 at fe835c20: the checkout scan ran once per run and every
# docker volume rm trusted it, so a checkout created after the walk passed its
# directory lost its project's volumes. The walk takes 173 s cold over 1,000
# configs on workstation (2026-10-07). Candidates are now re-checked against a second
# walk just before removal. This find passes every call through and counts the
# declared-projects walk, the only one without _archive or -maxdepth. In plant
# mode it creates a checkout declaring gone-tmp as soon as the first walk
# returns; in fail-rescan mode the second walk fails.
mkdir -p "$TMP/findbin"
cat >"$TMP/findbin/find" <<'EOF'
#!/bin/bash
case " $* " in *' _archive '*|*' -maxdepth '*) exec /usr/bin/find "$@" ;; esac
case " $* " in *'*/supabase/config.toml'*) ;; *) exec /usr/bin/find "$@" ;; esac
n=$(( $(cat "$FIND_STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FIND_STUB_COUNT"
if [ "$n" -ge 2 ] && [ "${FIND_STUB_MODE:-}" = fail-rescan ]; then exit 1; fi
/usr/bin/find "$@"; rc=$?
if [ "$n" = 1 ] && [ "${FIND_STUB_MODE:-}" = plant ]; then
  mkdir -p "$FIND_STUB_PLANT/supabase"
  printf 'project_id = "gone-tmp"\n' >"$FIND_STUB_PLANT/supabase/config.toml"
fi
exit "$rc"
EOF
chmod +x "$TMP/findbin/find"
find_stub=("PATH=$TMP/findbin:$BIN:/usr/bin:/bin" "FIND_STUB_COUNT=$TMP/find-declared-count" "FIND_STUB_PLANT=$TMP/home/SITES/late-clone")

rm -f "$TMP/find-declared-count"
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1 "${find_stub[@]}"
equals "$(cat "$TMP/find-declared-count" 2>/dev/null)" 2 "round 2 P1: the checkout scan runs again before any volume is removed"
equals "$(volume_rm_calls)" "supabase_db_gone-tmp supabase_storage_gone-tmp " "round 2 P1 control: volumes still undeclared on the re-scan are removed"
equals "$RUN_RC" 0 "round 2 P1 control: the re-scan adds no error"

rm -f "$TMP/find-declared-count"
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1 "${find_stub[@]}" FIND_STUB_MODE=plant
[ -f "$TMP/home/SITES/late-clone/supabase/config.toml" ] && planted=yes || planted=no
equals "$planted" yes "round 2 P1: the late checkout was planted after the first scan"
equals "$(volume_rm_calls)" "" "round 2 P1: a checkout created after the first scan keeps its project's volumes"
contains "$RUN_OUT" "keep supabase_db_gone-tmp (project gone-tmp: declared by a checkout the re-scan found)" "round 2 P1: the re-scan keep says why"
contains "$RUN_OUT" "keep supabase_storage_gone-tmp (project gone-tmp: declared by a checkout the re-scan found)" "round 2 P1: every volume of that project is kept"
equals "$RUN_RC" 0 "round 2 P1: a volume kept by the re-scan is not an error"
rm -rf "$TMP/home/SITES/late-clone"

rm -f "$TMP/find-declared-count"
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1 "${find_stub[@]}" FIND_STUB_MODE=fail-rescan
equals "$(cat "$TMP/find-declared-count" 2>/dev/null)" 2 "round 2 P1: the failing re-scan was reached"
equals "$(volume_rm_calls)" "" "round 2 P1: a failed re-scan removes no volume"
contains "$RUN_OUT" "keep supabase_db_gone-tmp (project gone-tmp: checkout re-scan failed)" "round 2 P1: a failed re-scan keeps each candidate and says why"
equals "$RUN_RC" 1 "round 2 P1: a failed re-scan fails the run under STRICT"
rm -f "$TMP/find-declared-count"
# adversarial round 2 P3 at 7e40f395: find does not descend a symlinked
# starting point, so a $SITES moved to another disk and linked back read as a
# complete scan with no declarations, and wt-only's volumes were reaped.
ln -s "$TMP/home/SITES" "$TMP/sites-link"
run_hygiene DOCKER_HYGIENE_TEST_SCENARIO=volumes REAP_VOLUMES=1 DRY_RUN=0 STRICT=1 JSON=1 "SITES=$TMP/sites-link"
equals "$(volume_rm_calls)" "supabase_db_gone-tmp supabase_storage_gone-tmp " "round 2 P3: a symlinked \$SITES is walked, so only undeclared volumes are removed"
contains "$RUN_OUT" "keep supabase_db_wt-only (project wt-only: declared by a checkout under" "round 2 P3: a worktree config under a symlinked \$SITES declares its volumes"
rm -f "$TMP/sites-link"
rm -rf "$TMP/home/SITES/monorepo/.claude/worktrees/y" "$TMP/home/SITES/_archive"

# ---- systemd user-manager environment probe (issue #1555) ----
# The one non-hermetic section. The unit was verified interactively (PATH
# present) and deployed under systemd (PATH absent) for two weeks; this asks
# the real user manager to run the unit's own Environment= block, parsed from
# the unit file with %h expanded, and exec's the ExecStart target directly
# (shebang and exec bit included). The target is the REPO's copy of the
# script, which is what this PR changes; the unit's own ExecStart names the
# installed copy under %h, which lags until sync, so its value is asserted
# rather than executed. Where no manager answers, or no supabase CLI is
# installed at all, the section prints an explicit SKIP line and the static
# assertions above stand on their own.
unit_env=()
unit_path=""
while IFS= read -r line; do
  val=${line#Environment=}
  # The parser models one bare KEY=VALUE per line with %h as the only
  # specifier; anything else fails loudly rather than parsing to nonsense.
  case "$val" in
    *\"*|*\'*|*' '*) bad "unit Environment= line uses quoting or several assignments, which this parser does not model: $line"; continue ;;
  esac
  case "${val//%h/}" in
    *%*) bad "unit Environment= line uses a specifier other than %h, which this parser does not expand: $line"; continue ;;
  esac
  val=${val//%h/$HOME}
  case "$val" in PATH=*) unit_path=${val#PATH=} ;; esac
  unit_env+=("--setenv=$val")
done < <(grep -E '^Environment=' "$REPO/systemd/docker-hygiene.service")
equals "$(printf '%s\n' "${unit_env[@]}" | grep -c '^--setenv=PATH=')" 1 "unit declares exactly one PATH"
case "$unit_path" in
  "$HOME/.local/bin:$HOME/.local/share/mise/shims:"*) ok ;;
  *) bad "unit PATH does not lead with ~/.local/bin and the mise shims after %h expansion: $unit_path" ;;
esac
exec_start=$(sed -nE 's/^ExecStart=//p' "$REPO/systemd/docker-hygiene.service")
equals "$exec_start" '%h/.claude/scripts/docker-hygiene.sh' "unit ExecStart is the installed docker-hygiene.sh under %h"
if [ -x "$SCRIPT" ]; then ok; else bad "repo docker-hygiene.sh is not executable; the unit exec's it directly"; fi
probe_unit() { printf 'docker-hygiene-test-%s-%s-%s' "$1" "$$" "$RANDOM"; }
probe_isolation=(
  --setenv=DOCKER_HOST=unix:///nonexistent/docker-hygiene-test.sock
  --setenv=ONLY=docker-hygiene-unit-env-probe-no-such-project
  --setenv=JSON=1
  # The shipped template is plan-only (DRY_RUN=1, STOP_ORPHANS=0), which skips
  # the supabase preflight; the probes opt back in to the deleting configuration
  # so they still exercise the unit's PATH. Both belts above keep them read-only.
  --setenv=DRY_RUN=0
  --setenv=STOP_ORPHANS=1
)
if ! command -v systemd-run >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  skip "systemd-run or timeout is not installed here; the unit-environment probes did not run"
elif ! timeout 30 systemd-run --user --pipe --wait --collect --quiet --unit="$(probe_unit true)" /bin/true >/dev/null 2>&1; then
  skip "systemd user manager not reachable (systemd-run --user /bin/true failed); the unit-environment probes did not run"
else
  if ! command -v supabase >/dev/null 2>&1; then
    skip "supabase CLI is not installed on this host (not on the suite's own PATH); the positive unit-environment probes did not run"
  else
    ver_out=$(timeout 60 systemd-run --user --pipe --wait --collect --quiet --unit="$(probe_unit ver)" "${unit_env[@]}" /usr/bin/env supabase --version 2>&1)
    ver_rc=$?
    equals "$ver_rc" 0 "supabase --version resolves under the unit's Environment= block: $ver_out"
    # The ExecStart target (the repo's copy, exec'd directly) under the unit's
    # env. Two belts keep it read-only: DOCKER_HOST at a socket that does not
    # exist (docker info fails and the run exits before any action) and ONLY=
    # a project that does not exist (every section is empty even if a docker
    # wrapper ignored DOCKER_HOST). The daemon line is asserted: its absence
    # means the probe reached a real daemon.
    exec_out=$(timeout 120 systemd-run --user --pipe --wait --collect --quiet --unit="$(probe_unit exec)" "${unit_env[@]}" "${probe_isolation[@]}" "$SCRIPT" 2>&1)
    exec_rc=$?
    contains "$exec_out" "docker-hygiene: supabase CLI: " "repo ExecStart target under the unit env passes the supabase preflight and logs the resolved binary"
    omits "$exec_out" "supabase CLI not found" "repo ExecStart target under the unit env does not fail the preflight"
    contains "$exec_out" "docker daemon unreachable" "isolation belt held: the probe stopped at the daemon gate"
    equals "$exec_rc" 1 "probe exits 1 under the unit's STRICT at the daemon gate"
  fi
  stock_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  if ( PATH=$stock_path; command -v supabase ) >/dev/null 2>&1; then
    skip "supabase resolves on the stock manager PATH on this host; the negative probe cannot discriminate and did not run"
  else
    neg_env=()
    for e in "${unit_env[@]}"; do
      case "$e" in --setenv=PATH=*) neg_env+=("--setenv=PATH=$stock_path") ;; *) neg_env+=("$e") ;; esac
    done
    neg_out=$(timeout 120 systemd-run --user --pipe --wait --collect --quiet --unit="$(probe_unit neg)" "${neg_env[@]}" "${probe_isolation[@]}" "$SCRIPT" 2>&1)
    neg_rc=$?
    equals "$neg_rc" 1 "the stock manager PATH fails the run under STRICT"
    contains "$neg_out" "supabase CLI not found on PATH=$stock_path" "negative probe names the stock PATH it searched"
    contains "$neg_out" "docker daemon unreachable" "negative probe still proceeds to the daemon gate (reclaim is not withheld)"
    contains "$neg_out" "observation-errors:1 action-errors:0 state:error" "round 2 P2 (live manager): the daemon-gate record under the stock PATH keeps the preflight observation error"
  fi
fi

assertions=$((pass + fail))
if [ "$fail" -gt 0 ]; then
  printf 'FAILED — docker hygiene: %d of %d assertions failed\n' "$fail" "$assertions" >&2
  exit 1
fi
if [ "$skips" -gt 0 ]; then
  printf 'ok — docker hygiene: %d/%d assertions passed, %d section(s) skipped (see SKIP lines)\n' "$pass" "$assertions" "$skips"
else
  printf 'ok — docker hygiene: %d/%d assertions passed\n' "$pass" "$assertions"
fi
