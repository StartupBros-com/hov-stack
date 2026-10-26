#!/usr/bin/env bash
# Every managed .service must either page on failure or say why it does not.
#
# Context (measured on workstation, 2026-08-27): three units were sitting in `failed` and
# none had OnFailure= wired, although harness-unit-failure-alert@.service existed
# and covered ten others. pkg-cache-prune had been failing since 08-25. The alert
# mechanism was real; its coverage was arbitrary, and nothing reported the gap.
#
# This suite makes the gap unrepresentable: a new unit either wires the alert or
# carries an explicit "NO OnFailure= ON PURPOSE" note. There is deliberately no
# third state, because silence is what let the original gap persist.
#
# Case 3 is the planted negative: strip the note from any skipped unit and it
# fails. Verified in the inverted state before this suite shipped.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYSD=$REPO/systemd
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

MARK='NO OnFailure= ON PURPOSE'
# Any OnFailure= target counts. A unit may route to its own alerter rather than
# the generic one, and demanding one specific target would have flagged a unit
# that alerts correctly.
ALERT='OnFailure='

# 1. Zero-run-green guard: there must BE units to check.
n=$(find "$SYSD" -name '*.service' ! -name '*alert@*' | wc -l)
[ "$n" -ge 10 ] && ok || bad "expected >=10 managed .service units, found $n"

# 2. No unit is silent — it pages, or it documents why not.
silent=""
for f in "$SYSD"/*.service; do
  b=$(basename "$f"); case "$b" in *alert@*) continue ;; esac
  grep -qE "^OnFailure=" "$f" && continue
  grep -qF "$MARK"  "$f" && continue
  silent="$silent $b"
done
[ -z "$silent" ] && ok || bad "unit neither pages nor documents why not:$silent"

# 3. A documented skip must give a REASON, not just the marker. The marker alone
#    would let "NO OnFailure= ON PURPOSE" become a mute button.
thin=""
for f in "$SYSD"/*.service; do
  b=$(basename "$f"); grep -qF "$MARK" "$f" || continue
  # Count only the CONTIGUOUS comment block starting at the marker. A naive
  # `grep -A6 | grep -c '^#'` counts comments from inside [Service] too, so it
  # passed even with the rationale deleted -- verified, then fixed.
  r=$(awk -v m="$MARK" '
        index($0, m) { inblock = 1; n = 1; next }
        inblock && /^#/ { n++; next }
        inblock { exit }
        END { print n + 0 }' "$f")
  [ "${r:-0}" -ge 3 ] || thin="$thin $b"
done
[ -z "$thin" ] && ok || bad "skip marker without a stated reason:$thin"

# 4. The alerter the units reference must itself exist and be declared.
[ -f "$SYSD/harness-unit-failure-alert@.service" ] \
  && grep -q 'harness-unit-failure-alert@.service' "$REPO/sync.sh" \
  && ok || bad "harness-unit-failure-alert@.service missing or undeclared"

# 5. A unit whose exit 1 means "found something" must NOT page. disk-watermark
#    deliberately uses failed-state as a signal and already notifies itself;
#    paging them would restore the noise this whole change removes.
#
#    dcg-auto-update WAS on this list and is not any more, because this PR
#    changed what its exit 1 means. It used to conflate "candidate REJECTED"
#    with "promote FAILED", which made it a finding-signal by accident: paging
#    it would have paged for the gate correctly refusing a bad upstream release.
#    Refusals now exit 0 and notify, and exit 1 is reserved for a broken updater
#    -- a tampered artifact, a failed signature, a contract suite that could not
#    run. Those are exactly what OnFailure= is for, so the exclusion would now
#    suppress the alerts this PR exists to enable. Case 6 pins the new position.
#
#    disk-watermark REMAINS here, deliberately. It has no break class to
#    separate: the script only ever exits 0 or 1, so making a breach exit 0
#    would leave it exiting 0 on every ordinary path and give OnFailure= nothing
#    to fire on but an interpreter-level abort. Converting it means first
#    introducing an error exit code, which is a change of its own and not a
#    side effect of this one.
wrong=""
for b in disk-watermark; do
  grep -qE "^OnFailure=" "$SYSD/$b.service" 2>/dev/null && wrong="$wrong $b"
done
[ -z "$wrong" ] && ok || bad "finding-signals wired to page:$wrong"

# 6. And the converse, so case 5 cannot be satisfied by simply never wiring
#    anything: now that a refusal exits 0, the dcg updater MUST page on a real
#    error. Without this, deleting the OnFailure= line passes case 5 silently.
grep -qE "^OnFailure=harness-unit-failure-alert@%n\.service$" "$SYSD/dcg-auto-update.service" \
  && ok || bad "dcg-auto-update no longer pages, but its exit 1 now means the updater is broken"

if [ "$fail" -eq 0 ]; then
  echo "ok — OnFailure coverage: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — OnFailure coverage: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
