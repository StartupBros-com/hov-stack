#!/usr/bin/env bash
# harness-doctor's live failed-unit sweep, proven by RUNNING it.
#
# WHY THIS SUITE EXISTS. The gap it guards is the one the sweep was written for:
# every other systemd check in this harness starts from a list of units named in
# advance, so none of them can see a unit the repo does not ship. A sweep that
# silently classified an unowned unit as "fine" would restore that silence while
# looking like coverage, so every class below is asserted against the REAL
# function extracted from harness-doctor.sh — not a copy, which would drift.
#
# The failure directions that matter, and the cases that pin them:
#   - a query that could not run must NOT read as a clean box   (case 7)
#   - a clean box must still return 0, and stay quiet           (case 8)
#   - a unit declared nowhere must NOT be silently tolerated    (case 5)
#
# PLANTED NEGATIVES, run against a copied harness-doctor.sh before this shipped.
# Each neuters one branch of the classifier; the measured result is recorded so
# a later reader can tell which assertions are load-bearing for which branch:
#   OnFailure= grep disabled        -> 8/10  (wired + template instance)
#   exemption marker ignored        -> 9/10  (documented exemption)
#   UNITS_FOREIGN not consulted     -> 9/10  (foreign unit)
#   template resolution removed     -> 9/10  (instance reads as unowned)
#   broken query returns 0          -> 9/10  (dead manager reads as clean)
# No branch is unguarded, and no single assertion covers two branches except
# case 4, which the first plant also trips — deliberately, since a template
# instance depends on both the file lookup and the OnFailure= read.
# Case 9 runs section 29 itself; measured once it had 13 assertions:
#   section 29 reads only sync.sh's line  -> 12/13 (overlay unit reads as foreign)
#   lib/foreign-units.sh drops the overlay -> 12/13 (same assertion)
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# Extract the real function. Sourcing harness-doctor.sh would execute a full
# read-only audit of this machine, which is slow and host-dependent.
sed -n '/^failed_unit_sweep() {/,/^}/p' "$DOCTOR" > "$TMP/fn.sh"
grep -q 'UNOWNED' "$TMP/fn.sh" || { echo "FAIL: could not extract failed_unit_sweep" >&2; exit 1; }

# ---- fixture unit tree, one file per class -----------------------------------
SYSD=$TMP/systemd
mkdir -p "$SYSD"
printf '[Unit]\nDescription=wired\nOnFailure=harness-unit-failure-alert@%%n.service\n' \
  > "$SYSD/wired.service"
printf '[Unit]\nDescription=exempt\n# NO OnFailure= ON PURPOSE.\n# exit 1 means a FINDING here, and the script already notifies.\n# Paging would double-report it.\n' \
  > "$SYSD/exempt.service"
printf '[Unit]\nDescription=silent, wired to nothing\n' \
  > "$SYSD/silent.service"
printf '[Unit]\nDescription=template\nOnFailure=harness-unit-failure-alert@%%n.service\n' \
  > "$SYSD/tmpl@.service"

FOREIGN="check-fleet-drift someforeign voxtype"

# stub_systemctl <exit-code> <unit-rows...>
# Mimics `list-units --state=failed --no-legend --plain`: unit name first,
# then the load/active/sub columns and a description.
stub_systemctl() {
  local rc=$1; shift
  mkdir -p "$TMP/bin"
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  *list-units*)\n'
    printf '      [ %s -ne 0 ] && exit %s\n' "$rc" "$rc"
    local u
    for u in "$@"; do
      printf '      printf "%%s loaded failed failed a description\\n" %q\n' "$u"
    done
    printf '      exit 0 ;;\n'
    printf 'esac\n'
    printf 'exit 0\n'
  } > "$TMP/bin/systemctl"
  chmod +x "$TMP/bin/systemctl"
}

# sweep -> the function's stdout, with $TMP/bin first on PATH
sweep() {
  printf '. %q\nfailed_unit_sweep %q %q\n' "$TMP/fn.sh" "$SYSD" "$FOREIGN" > "$TMP/probe"
  PATH="$TMP/bin:$PATH" bash "$TMP/probe" 2>/dev/null
}
sweep_rc() {
  printf '. %q\nfailed_unit_sweep %q %q >/dev/null 2>&1\necho $?\n' \
    "$TMP/fn.sh" "$SYSD" "$FOREIGN" > "$TMP/probe"
  PATH="$TMP/bin:$PATH" bash "$TMP/probe"
}
class_of() { sweep | awk -F'\t' -v u="$1" '$2==u {print $1; exit}'; }

# ---- 1-6: one assertion per class -------------------------------------------
stub_systemctl 0 wired.service exempt.service silent.service \
                 tmpl@inst.service someforeign.service mystery.service

[ "$(class_of wired.service)" = BROKEN_ALERTED ] && ok \
  || bad "a shipped unit carrying OnFailure= classified as $(class_of wired.service)"

[ "$(class_of exempt.service)" = EXPECTED_FINDING ] && ok \
  || bad "a documented NO-OnFailure exemption classified as $(class_of exempt.service)"

[ "$(class_of silent.service)" = BROKEN_UNALERTED ] && ok \
  || bad "a shipped unit wired to nothing classified as $(class_of silent.service)"

# The instance must resolve through its TEMPLATE file; looking up the instance
# name finds nothing and would misreport a declared unit as unowned.
[ "$(class_of tmpl@inst.service)" = BROKEN_ALERTED ] && ok \
  || bad "a template instance classified as $(class_of tmpl@inst.service), not via its @.service file"

[ "$(class_of someforeign.service)" = FOREIGN ] && ok \
  || bad "a unit named in UNITS_FOREIGN classified as $(class_of someforeign.service)"

# 5. The whole point: a unit nobody declares must be named, not tolerated.
[ "$(class_of mystery.service)" = UNOWNED ] && ok \
  || bad "a unit declared nowhere classified as $(class_of mystery.service) — the sweep's reason to exist"

# ---- 6b: substring matching must not make a foreign name promiscuous ---------
# `voxtype` is in the register; `voxtype-extra` is not, and a bare substring
# test would have silently adopted it.
stub_systemctl 0 voxtype-extra.service
[ "$(class_of voxtype-extra.service)" = UNOWNED ] && ok \
  || bad "voxtype-extra matched the foreign register by substring ($(class_of voxtype-extra.service))"

# ---- 7: a query that could not run must NOT look like a clean box -----------
stub_systemctl 3
[ "$(sweep_rc)" != 0 ] && ok \
  || bad "a failed systemctl query returned 0 — a dead manager would read as 'no failed units'"

# ---- 8: zero-run-green guard -- a genuinely clean box must return 0 and be quiet
stub_systemctl 0
[ "$(sweep_rc)" = 0 ] && ok || bad "a clean box did not return 0"
[ -z "$(sweep)" ]    && ok || bad "a clean box emitted rows: $(sweep)"

# ---- 9: the doctor builds the register it passes, overlay half included ------
# The cases above hand the function a register. Section 29 builds its own, from
# sync.sh's UNITS_FOREIGN line and the host's <overlay>/foreign-units, so run the
# real section: a unit named only in the overlay must read as foreign, as a unit
# nothing declares without the overlay, and a missing helper must fail closed.
sed -n '/^echo "== 29\. /,/^echo "== 30\. /p' "$DOCTOR" | sed '$d' > "$TMP/check29.sh"
grep -qF 'failed_unit_sweep "' "$TMP/check29.sh" \
  || { echo "FAIL: could not extract section 29" >&2; exit 1; }
ROOT29=$TMP/root29
mkdir -p "$ROOT29/systemd" "$ROOT29/lib" "$TMP/overlay29"
printf 'UNITS_FOREIGN="check-fleet-drift voxtype"\n' > "$ROOT29/sync.sh"
ln -s "$REPO/lib/foreign-units.sh" "$ROOT29/lib/foreign-units.sh"
printf 'hostowned\n' > "$TMP/overlay29/foreign-units"
# The doctor's own warn/ok, as the section expects to find them.
# shellcheck disable=SC2016  # the stubs are written literally, expanded when sourced
printf '%s\n' 'WARNS=0' \
  'warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }' \
  'ok() { echo "  ok: $*"; }' > "$TMP/stubs29.sh"
run29() { # $1 = the overlay directory
  ( export HD_ROOT=$ROOT29 HOV_STACK_OVERLAY=$1 PATH="$TMP/bin:$PATH"
    # shellcheck disable=SC1091
    . "$TMP/stubs29.sh"
    # shellcheck disable=SC1091
    . "$TMP/fn.sh"
    # shellcheck disable=SC1091
    . "$TMP/check29.sh" 2>&1 )
}
stub_systemctl 0 hostowned.service
out29=$(run29 "$TMP/overlay29")
case "$out29" in *"failed foreign unit: hostowned.service"*) ok ;;
  *) bad "section 29 did not read the overlay's foreign-units: $out29" ;; esac
out29=$(run29 "$TMP/no-overlay29")
case "$out29" in *"failed unit nothing declares: hostowned.service"*) ok ;;
  *) bad "without the overlay, section 29 did not name the unit as undeclared: $out29" ;; esac
rm "$ROOT29/lib/foreign-units.sh"
out29=$(run29 "$TMP/overlay29")
case "$out29" in *"cannot read the unit register"*) ok ;;
  *) bad "a missing lib/foreign-units.sh did not fail closed: $out29" ;; esac

if [ "$fail" -eq 0 ]; then
  echo "ok — failed-unit sweep: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — failed-unit sweep: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
