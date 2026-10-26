#!/usr/bin/env bash
# unit-health.test.sh — contract tests for scripts/unit-health.sh
#
# The contract this suite pins is the one the script exists to hold: it must
# never report "clean" from a query that did not run. Every fail-closed path is
# asserted by making the corresponding policy source unreadable and demanding
# exit 2, because exit 0 on an unaskable box is the exact silence the tool was
# written to end.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/unit-health.sh"
# The register's second half is the host's <overlay>/foreign-units. Point it at an
# absolute directory that does not exist, so no case reads this machine's overlay
# unless it sets one.
export HOV_STACK_OVERLAY=/nonexistent/unit-health-test-overlay

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

check_exit() {
  local label=$1 want=$2 got=$3
  if [ "$got" -eq "$want" ]; then ok "$label (exit $got)"; else bad "$label (want exit $want, got $got)"; fi
}

printf 'unit-health.test.sh\n'

# --- 1. the script is executable and syntactically valid ---------------------
if [ -x "$SCRIPT" ]; then ok "script is executable"; else bad "script is not executable"; fi
bash -n "$SCRIPT" 2>/dev/null && ok "script parses" || bad "script has a syntax error"

# --- 2. --help exits 0 and names the exit codes ------------------------------
help_out=$(bash "$SCRIPT" --help 2>&1); check_exit "--help" 0 $?
case "$help_out" in
  *"Exit codes"*) ok "--help documents exit codes" ;;
  *) bad "--help does not document exit codes" ;;
esac

# --- 3. an unknown flag is rejected, not ignored ------------------------------
bash "$SCRIPT" --nope >/dev/null 2>&1; check_exit "unknown flag rejected" 2 $?

# --- 4. a non-numeric threshold is rejected before any query runs -------------
bash "$SCRIPT" --threshold abc >/dev/null 2>&1; check_exit "non-numeric --threshold rejected" 2 $?

# --- 5. FAIL CLOSED: unreadable policy sources must exit 2, never 0 -----------
# The register is pointed at a directory that does not exist. An earlier version
# of this test redirected HOME instead, which stopped proving anything the
# moment the script began resolving its policy sources relative to itself --
# the assertion still passed, for the wrong reason, until CI disagreed.
# A tool that answered "no problems" here would be reporting coverage it never
# read: the exact failure mode this suite exists to prevent.
tmp_dir=$(mktemp -d)
out=$(UNIT_HEALTH_SYSD="$tmp_dir/nonexistent" UNIT_HEALTH_SYNC="$tmp_dir/nonexistent.sh" bash "$SCRIPT" 2>&1); rc=$?
check_exit "fail-closed when the unit register is unreadable" 2 "$rc"
case "$out" in
  *"cannot read the unit register"*) ok "fail-closed path names the missing register" ;;
  # On a runner without a systemd --user manager (the ARC pods, dotfiles#958)
  # the script fails closed one check earlier, on the systemd probe. Same exit
  # code, same "no report" guarantee; the register path is simply unreachable
  # there and is proven on hosts that do have a manager.
  *"no reachable systemd --user manager"*) ok "fail-closed path explains itself (no systemd --user manager here; register check unreachable)" ;;
  *) bad "fail-closed path does not explain itself: $out" ;;
esac

# --- 6. fail-closed writes to stderr, and emits no report on stdout ----------
stdout_only=$(UNIT_HEALTH_SYSD="$tmp_dir/nonexistent" UNIT_HEALTH_SYNC="$tmp_dir/nonexistent.sh" bash "$SCRIPT" 2>/dev/null)
if [ -z "$stdout_only" ]; then ok "fail-closed leaves stdout empty (no partial report)"; else bad "fail-closed wrote a partial report to stdout"; fi

# --- 6b. a sync.sh with no UNITS_FOREIGN line is also unreadable policy -------
# Present-but-empty is the harder case: the file opens, the register does not.
printf 'UNITS_NOT_FOREIGN="x"\n' > "$tmp_dir/empty-register.sh"
UNIT_HEALTH_SYNC="$tmp_dir/empty-register.sh" bash "$SCRIPT" >/dev/null 2>&1
check_exit "fail-closed when UNITS_FOREIGN is absent from sync.sh" 2 $?
rm -rf "$tmp_dir"

# --- 7. THE GATE MUST BE ABLE TO PASS, NOT ONLY TO FAIL ----------------------
# The first version of this suite guarded only on "is a --user manager
# reachable". CI has one, so the live assertions ran -- against a runner with no
# user timers and no $HOME/dotfiles, where the tool exited 2. Six assertions
# failed on an environment that was behaving correctly. A clean box is a PASS
# case and has to be asserted as one, or the only thing this suite proves is
# that the tool can refuse.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show -p Version >/dev/null 2>&1; then
  bash "$SCRIPT" >/dev/null 2>&1; live_rc=$?
  if [ "$live_rc" -eq 2 ]; then
    bad "live run exited 2 on a box with a reachable --user manager (policy sources should resolve relative to the script)"
  fi

  # Zero timers and zero loaded services alone do not establish a clean host: a
  # service that failed in the window and was unloaded remains reportable from
  # the journal. The truly empty case is hermetic below.

  json=$(bash "$SCRIPT" --json 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then ok "live run exits 0 or 1"; else bad "live run exited $rc"; fi

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -e . >/dev/null 2>&1 && ok "--json emits parseable JSON" || bad "--json output is not valid JSON"
    printf '%s' "$json" | jq -e '.units | type == "array"' >/dev/null 2>&1 && ok "--json .units is an array" || bad "--json .units is not an array"
    printf '%s' "$json" | jq -e 'all(.units[]; .coverage | test("^(ALERTED|EXEMPT|UNALERTED|FOREIGN|UNOWNED)$"))' >/dev/null 2>&1 \
      && ok "every coverage class is one of the five policy classes" \
      || bad "a coverage class fell outside the policy vocabulary"
    printf '%s' "$json" | jq -e 'all(.units[]; .health | test("^(OK|FAILED|HOT_LOOP)$"))' >/dev/null 2>&1 \
      && ok "every health class is one of the three health classes" \
      || bad "a health class fell outside the vocabulary"
  else
    printf '  skip jq absent; JSON shape assertions not run\n'
  fi

  # A threshold of 1 must classify at least as many units HOT_LOOP as the
  # default threshold does — the rate axis has to be monotonic in the threshold,
  # or the number it reports means nothing.
  if command -v jq >/dev/null 2>&1; then
    hi=$(bash "$SCRIPT" --json --threshold 1000000 2>/dev/null | jq '[.units[] | select(.health == "HOT_LOOP")] | length' 2>/dev/null)
    lo=$(bash "$SCRIPT" --json --threshold 1 2>/dev/null | jq '[.units[] | select(.health == "HOT_LOOP")] | length' 2>/dev/null)
    # Empty means the JSON assertion above already failed; do not compare
    # unset values and report a second, misleading failure for one cause.
    case "${hi:-}${lo:-}" in
      ''|*[!0-9]*) bad "HOT_LOOP monotonicity not evaluable (hi='${hi:-}' lo='${lo:-}')" ;;
      *) if [ "$lo" -ge "$hi" ]; then ok "HOT_LOOP count is monotonic in --threshold ($lo >= $hi)"; else bad "HOT_LOOP count is not monotonic ($lo < $hi)"; fi ;;
    esac
  fi
else
  printf '  skip no reachable systemd --user manager; live assertions not run\n'
fi

# --- 8. journal failures are not zero failures (hermetic, even without systemd) ---
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/systemd" "$fixture/tmp"
printf 'UNITS_FOREIGN="fixture"\n' > "$fixture/sync.sh"
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  '--user show -p Version') echo 'Version=fixture' ;;
  '--user list-timers '*)
    [ "${INVENTORY_CASE:-}" != empty ] || exit 0
    case "${JOURNAL_CASE:-}" in no-units|restarted-no-timers) exit 0 ;; esac
    echo 'n/a n/a clean.timer clean.service'
    echo 'n/a n/a later.timer later.service'
    ;;
  '--user list-units --state=failed '*) ;;
  '--user list-units --type=service '*)
    case "${INVENTORY_CASE:-}" in
      active|incomplete)
        echo 'daemon.service loaded active running Untimed daemon'
        echo 'clean.service loaded inactive dead Timer target'
        ;;
      escaped) printf '%s\n' 'worker\x2dname.service loaded active running Escaped daemon' ;;
      restarted-loaded) echo 'restarted.service loaded active running Still-loaded daemon' ;;
      error) exit 1 ;;
    esac
    ;;
  '--user is-active daemon.service') echo active ;;
  '--user is-active restarted.service') echo active ;;
  '--user is-active '*) echo inactive; exit 3 ;;
  '--user show -p Id '*)
    [ "${INVENTORY_CASE:-}" != properties-error ] || exit 1
    # Extra records are harmless; a record missing for an inventoried unit is
    # the fail-closed case INVENTORY_CASE=incomplete pins.
    for unit in clean.service later.service; do
      printf 'Result=success\nId=%s\nActiveState=inactive\n\n' "$unit"
    done
    if [ "${INVENTORY_CASE:-}" = active ]; then
      printf 'Result=success\nId=daemon.service\nActiveState=active\n\n'
    elif [ "${INVENTORY_CASE:-}" = escaped ]; then
      printf '%s\n' 'Result=success' 'Id=worker\x2dname.service' 'ActiveState=active' ''
    fi
    case "${JOURNAL_CASE:-}" in
      restarted*) printf 'Result=success\nId=restarted.service\nActiveState=active\n\n' ;;
    esac
    ;;
  '--user show '*) echo success ;;
  *) exit 99 ;;
esac
STUB
cat > "$fixture/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *MESSAGE_ID=*)
    case "$JOURNAL_CASE" in
      restarted|restarted-no-timers)
        printf '%s\n' '{"USER_UNIT":"restarted.service"}' '{"USER_UNIT":"restarted.service"}' \
          '{"USER_UNIT":"ignored.scope"}' '{"UNIT":"system-only.service"}'
        ;;
      discovery-error) exit 1 ;;
      discovery-partial) echo '{"USER_UNIT":"restarted.service"}'; exit 1 ;;
      discovery-malformed) echo '{"USER_UNIT":' ;;
    esac
    exit 0
    ;;
esac
if [ "${3:-}" = restarted.service ] && [[ "$JOURNAL_CASE" = restarted* ]]; then
  printf '%s\n' 'Failed with result exit-code.' 'Failed with result timeout.'
  exit 0
fi
if [ "${3:-}" = daemon.service ]; then
  for _ in {1..12}; do printf '%s\n' 'Failed with result exit-code.'; done
  exit 0
fi
# The clean unit is processed first; failure of the later read must also
# suppress the earlier row, not publish an incomplete successful report.
[ "${3:-}" = later.service ] || exit 0
case "$JOURNAL_CASE" in
  empty|restarted|discovery-*) ;;
  clean) echo 'Finished successfully.' ;;
  failures) printf '%s\n' 'Failed with result exit-code.' 'Finished successfully.' 'Failed with result timeout.' ;;
  error) exit 1 ;;
  partial-error) echo 'Failed with result exit-code.'; exit 1 ;;
  *) exit 99 ;;
esac
STUB
cat > "$fixture/bin/column" <<'STUB'
#!/usr/bin/env bash
cat
STUB
chmod +x "$fixture/bin/"*

journal_fixture() {
  local scenario=$1
  shift
  TMPDIR="$fixture/tmp" PATH="$fixture/bin:$PATH" UNIT_HEALTH_SYSD="$fixture/systemd" \
    UNIT_HEALTH_SYNC="$fixture/sync.sh" JOURNAL_CASE="$scenario" \
    bash "$SCRIPT" "$@" > "$fixture/stdout" 2> "$fixture/stderr"
}

for scenario in empty clean; do
  journal_fixture "$scenario" --json
  check_exit "successful $scenario journal is healthy" 0 $?
  jq -e '.problems == 0 and (.units | length) == 2 and
    all(.units[]; .health == "OK" and .failures == 0)' "$fixture/stdout" >/dev/null \
    && ok "$scenario journal reports two real zero-count rows" \
    || bad "$scenario journal lost rows or fabricated failures"
done

journal_fixture failures --json
check_exit "genuine journal failures retain exit 1" 1 $?
jq -e '.problems == 1 and (.units | length) == 2 and
  .units[1].health == "FAILED" and .units[1].failures == 2' "$fixture/stdout" >/dev/null \
  && ok "failure count remains exact" || bad "failure count changed"
journal_fixture failures --json --threshold 2
check_exit "hot-loop threshold still applies" 1 $?
jq -e '.units[1].health == "HOT_LOOP" and .units[1].failures == 2' "$fixture/stdout" >/dev/null \
  && ok "threshold classifies the same journal count" || bad "hot-loop classification changed"

for scenario in error partial-error; do
  for format in text json quiet; do
    args=()
    case "$format" in json) args=(--json) ;; quiet) args=(--quiet) ;; esac
    journal_fixture "$scenario" "${args[@]}"
    check_exit "$scenario journal ($format) fails closed" 2 $?
    [ ! -s "$fixture/stdout" ] \
      && ok "$scenario ($format) emits no partial report" \
      || bad "$scenario ($format) emitted a report after an unreadable journal"
    grep -qF 'could not read journal for later.service' "$fixture/stderr" \
      && ok "$scenario ($format) identifies the unreadable unit" \
      || bad "$scenario ($format) did not identify the unreadable unit"
  done
done

INVENTORY_CASE=active journal_fixture empty --json
check_exit "active untimed daemon contributes a hot loop" 1 $?
jq -e '[.units[] | select(.unit == "daemon.service")] | length == 1 and
  .[0].active == "active" and .[0].health == "HOT_LOOP" and .[0].failures == 12' \
  "$fixture/stdout" >/dev/null \
  && ok "active untimed daemon is not hidden by its current state" \
  || bad "active untimed daemon was omitted or misclassified"
# The overlay half of the register: a host's own unit named in <overlay>/foreign-units
# is FOREIGN, and the same unit is UNOWNED without it.
mkdir -p "$fixture/overlay"
printf '# host units\ndaemon\n' > "$fixture/overlay/foreign-units"
INVENTORY_CASE=active HOV_STACK_OVERLAY="$fixture/overlay" journal_fixture empty --json
jq -e '[.units[] | select(.unit == "daemon.service")] | length == 1 and .[0].coverage == "FOREIGN"' \
  "$fixture/stdout" >/dev/null \
  && ok "a unit named in the overlay's foreign-units is FOREIGN" \
  || bad "the overlay's foreign-units was not read"
INVENTORY_CASE=active journal_fixture empty --json
jq -e '[.units[] | select(.unit == "daemon.service")] | length == 1 and .[0].coverage == "UNOWNED"' \
  "$fixture/stdout" >/dev/null \
  && ok "without the overlay the same unit is UNOWNED" \
  || bad "a unit nothing declares was not UNOWNED"
INVENTORY_CASE=error journal_fixture empty --json
check_exit "service enumeration failure refuses incomplete inventory" 2 $?
[ ! -s "$fixture/stdout" ] && ok "inventory failure emits no report" \
  || bad "inventory failure emitted partial report"

INVENTORY_CASE=properties-error journal_fixture empty --json
check_exit "property query failure refuses incomplete report" 2 $?
[ ! -s "$fixture/stdout" ] && ok "property failure emits no report" \
  || bad "property failure emitted partial report"
INVENTORY_CASE=error journal_fixture error --dry-run --json
check_exit "dry-run does not contact broken systemd or journal" 0 $?
jq -e '.dry_run == true and .since == "24 hours ago"' "$fixture/stdout" >/dev/null \
  && ok "dry-run produces valid JSON" || bad "dry-run JSON invalid"
[ ! -s "$fixture/stderr" ] && ok "dry-run has no query errors" || bad "dry-run queried the host"

INVENTORY_CASE=incomplete journal_fixture empty --json
check_exit "missing service property record fails closed" 2 $?
[ ! -s "$fixture/stdout" ] && ok "incomplete properties emit no report" \
  || bad "incomplete properties emitted a report"
INVENTORY_CASE=empty journal_fixture error --json
check_exit "empty successful inventory never queries a per-unit journal" 0 $?
jq -e '.problems == 0 and .units == []' "$fixture/stdout" >/dev/null \
  && ok "empty inventory is clean" || bad "empty inventory misreported"
[ -z "$(ls -A "$fixture/tmp")" ] && ok "no temporary or partial files remain" \
  || bad "collection leaked temporary files"

ln -s "$SCRIPT" "$fixture/bin/unit-health"
PATH="$fixture/bin:$PATH" UNIT_HEALTH_SYSD="$fixture/systemd" \
  UNIT_HEALTH_SYNC="$fixture/sync.sh" JOURNAL_CASE=empty \
  unit-health --json >"$fixture/stdout" 2>"$fixture/stderr"
check_exit "PATH symlink resolves its journal helper" 0 $?
jq -e '.units | length == 2' "$fixture/stdout" >/dev/null \
  && ok "PATH entry produces the full report" || bad "PATH entry lost its resources"

# Keep the original sequential path usable on hosts without xargs. jq stays on
# PATH: journal discovery made it a runtime dependency (#1759).
INVENTORY_CASE=active journal_fixture failures --json
cp "$fixture/stdout" "$fixture/parallel.json"
mkdir "$fixture/sequential-bin"
for tool in bash dirname readlink mktemp rm sed grep awk sort jq; do
  ln -s "$(command -v "$tool")" "$fixture/sequential-bin/$tool"
done
ln -s "$fixture/bin/systemctl" "$fixture/sequential-bin/systemctl"
ln -s "$fixture/bin/journalctl" "$fixture/sequential-bin/journalctl"
PATH="$fixture/sequential-bin" UNIT_HEALTH_SYSD="$fixture/systemd" \
  UNIT_HEALTH_SYNC="$fixture/sync.sh" JOURNAL_CASE=failures INVENTORY_CASE=active \
  bash "$SCRIPT" --json >"$fixture/sequential.json" 2>"$fixture/stderr"
check_exit "without xargs the original checks still run" 1 $?
cmp -s "$fixture/parallel.json" "$fixture/sequential.json" \
  && ok "parallel and sequential reports match exactly" \
  || bad "sequential fallback changed report semantics"

INVENTORY_CASE=escaped journal_fixture empty --json
check_exit "escaped active daemon report completes" 0 $?
jq -e '[.units[] | select(.unit == "worker\\x2dname.service")] | length == 1' \
  "$fixture/stdout" >/dev/null \
  && ok "JSON preserves escaped service identity" || bad "JSON changed escaped service identity"
INVENTORY_CASE=escaped journal_fixture empty
check_exit "escaped daemon human report completes" 0 $?
grep -qF 'worker\x2dname.service' "$fixture/stdout" \
  && ok "human output preserves escaped service identity" || bad "human output changed escaped service identity"

journal_fixture restarted --json --threshold 2
check_exit "active non-timer failure remains visible" 1 $?
jq -e '.problems == 1 and (.units | length) == 3 and
  ([.units[] | select(.unit == "restarted.service" and .active == "active" and
    .health == "HOT_LOOP" and .failures == 2)] | length) == 1' "$fixture/stdout" >/dev/null \
  && ok "journal discovery adds and deduplicates the restarted service only" \
  || bad "active service vanished or non-user/non-service units leaked into inventory"

for scenario in discovery-error discovery-partial discovery-malformed; do
  journal_fixture "$scenario" --json
  check_exit "$scenario refuses an incomplete inventory" 2 $?
  [ ! -s "$fixture/stdout" ] && ok "$scenario leaves stdout empty" || bad "$scenario emitted a partial report"
  grep -qF 'could not discover failed user services' "$fixture/stderr" \
    && ok "$scenario names the discovery failure" || bad "$scenario has no discovery diagnostic"
done

journal_fixture no-units --json
check_exit "empty timer, failure and journal inventories report clean" 0 $?
if jq -e '.problems == 0 and .units == []' "$fixture/stdout" >/dev/null; then
  ok "empty host has no invented units"
else
  bad "empty host report is not empty and clean"
fi

journal_fixture restarted-no-timers --json --threshold 2
check_exit "zero timers with a recovered service is not a clean host" 1 $?
if jq -e '.problems == 1 and (.units | length) == 1 and
  .units[0].unit == "restarted.service" and .units[0].health == "HOT_LOOP"' "$fixture/stdout" >/dev/null; then
  ok "recovered non-timer service is reported without any timer targets"
else
  bad "recovered service vanished on a no-timer host"
fi

journal_fixture discovery-error --dry-run --json
check_exit "dry-run does not query an unavailable journal" 0 $?
jq -e '.dry_run == true and (.commands | length) > 0' "$fixture/stdout" >/dev/null \
  && ok "dry-run describes its reads as JSON" || bad "dry-run JSON plan missing"

# --- 9. merge of #1759 (pro-gate round 1, conflict 75e3519a) -----------------
# #1759 discovers restarted services from "Unit failed" journal events; this
# branch enumerates loaded services. Both inventories must survive the merge
# in one report: an active untimed daemon (loaded, no journal event) and a
# journal-only service (unloaded, no timer) each appear exactly once.
INVENTORY_CASE=active journal_fixture restarted --json --threshold 2
check_exit "merge #1759: loaded daemon and journal-discovered service both reported" 1 $?
jq -e '.problems == 2 and (.units | length) == 4 and
  ([.units[] | select(.unit == "daemon.service" and .active == "active" and
    .health == "HOT_LOOP" and .failures == 12)] | length) == 1 and
  ([.units[] | select(.unit == "restarted.service" and .active == "active" and
    .health == "HOT_LOOP" and .failures == 2)] | length) == 1' "$fixture/stdout" >/dev/null \
  && ok "merge #1759: loaded-service and journal inventories are unioned, not replaced" \
  || bad "merge #1759: one inventory source was dropped or duplicated"

# A service present in both the loaded inventory and the journal discovery is
# one row, not two: the union is de-duplicated across sources.
INVENTORY_CASE=restarted-loaded journal_fixture restarted --json --threshold 2
check_exit "merge #1759: service in both inventories is reported once" 1 $?
jq -e '.problems == 1 and (.units | length) == 3 and
  ([.units[] | select(.unit == "restarted.service")] | length) == 1' "$fixture/stdout" >/dev/null \
  && ok "merge #1759: loaded and journal-discovered copies de-duplicate to one row" \
  || bad "merge #1759: a service in both inventories was duplicated or lost"

# Journal discovery is a hard read like the three systemctl enumerations: its
# failure refuses the report even when the loaded inventory succeeded.
INVENTORY_CASE=active journal_fixture discovery-error --json
check_exit "merge #1759: discovery failure refuses a report with a loaded inventory" 2 $?
[ ! -s "$fixture/stdout" ] && ok "merge #1759: no partial report from a loaded inventory alone" \
  || bad "merge #1759: loaded inventory published without journal discovery"

# The dry-run plan carries both branches' fields: this branch's threshold and
# plan text, #1759's command list, and the loaded-service enumeration itself.
INVENTORY_CASE=error journal_fixture discovery-error --dry-run --json
check_exit "merge #1759: dry-run plan is the union of both branches" 0 $?
jq -e '.dry_run == true and .since == "24 hours ago" and .threshold == 10 and
  (.plan | type == "string") and (.commands | length) == 4 and
  any(.commands[]; index("--type=service") != null) and
  any(.commands[]; any(.[]; startswith("MESSAGE_ID=")))' "$fixture/stdout" >/dev/null \
  && ok "merge #1759: dry-run JSON names threshold, plan, service enumeration and journal discovery" \
  || bad "merge #1759: dry-run JSON lost a field from one branch"
[ ! -s "$fixture/stderr" ] && ok "merge #1759: dry-run has no query errors" \
  || bad "merge #1759: dry-run queried the host"
INVENTORY_CASE=error journal_fixture discovery-error --dry-run
check_exit "merge #1759: dry-run text plan completes" 0 $?
grep -qF -- '--type=service' "$fixture/stdout" && grep -qF 'MESSAGE_ID=' "$fixture/stdout" \
  && ok "merge #1759: dry-run text lists service enumeration and journal discovery" \
  || bad "merge #1759: dry-run text omits a read from one branch"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
