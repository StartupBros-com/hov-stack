#!/usr/bin/env bash
# Contract: harness-doctor detects a rotting cass lexical index INDEPENDENTLY of
# cass's own .healthy aggregate.
#
# WHY THIS EXISTS
# cass's run_status/run_health exclude index.partial and index.hollow from the
# aggregate they report as .healthy. So an index whose lexical checkpoint is
# incomplete answers healthy:true. Section 8b already fetched `cass status
# --json` and already read .index.partial -- but only to decorate a message
# inside the `.healthy != true` branch, which such an index never enters. The
# result: 2026-09-07..10 the lexical index rotted, `cass index` exited 0 against
# the deferred-repair size gate, no systemd unit failed, and search degraded to
# hangs for three days with the doctor reporting clean.
#
# PLANTED NEGATIVE: delete the `.index.partial == true or .index.hollow == true`
# test from harness-doctor.sh section 8b and assertion 1 fails -- the predicate
# is read out of the live script, so this test cannot pass against a version
# that no longer ships the check.
#
# Hermetic: no cass binary, no network, no operator state. Fixtures are literal
# JSON run through the predicate extracted from the script under test.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
[ -r "$DOCTOR" ] || { echo "FAIL: cannot read $DOCTOR" >&2; exit 1; }

# 1. The check must EXIST in the script under test, and must not be nested under
#    a .healthy guard. Extract the literal predicate so the fixtures below
#    exercise the same expression the doctor ships.
PRED='.index.partial == true or .index.hollow == true'
if grep -qF -- "$PRED" "$DOCTOR"; then ok; else
  bad "harness-doctor.sh no longer contains the rot predicate: $PRED"
fi

# 2. It must be reachable when .healthy is true. The regression being pinned is
#    the check living INSIDE the `! .healthy == true` branch, where a rotting
#    index cannot reach it. Assert the predicate's line is not inside that elif
#    by checking it appears AFTER the elif's own warn line.
healthy_warn_line=$(grep -nF 'cass index unhealthy (level=' "$DOCTOR" | head -1 | cut -d: -f1)
pred_line=$(grep -nF -- "$PRED" "$DOCTOR" | head -1 | cut -d: -f1)
if [ -n "$healthy_warn_line" ] && [ -n "$pred_line" ] && [ "$pred_line" -gt "$healthy_warn_line" ]; then
  ok
else
  bad "rot predicate (line ${pred_line:-?}) is not after the unhealthy branch (line ${healthy_warn_line:-?}) — it may be nested inside it"
fi

# 3. Behaviour, against the exact predicate the script ships.
#    fires <label> <json> <want:fire|quiet>
fires() {
  local label=$1 json=$2 want=$3 got
  if printf '%s' "$json" | jq -e "$PRED" >/dev/null 2>&1; then got=fire; else got=quiet; fi
  if [ "$got" = "$want" ]; then ok; else bad "$label: wanted $want, got $got"; fi
}

# The exact shape that rotted: healthy true, checkpoint incomplete.
fires "partial=true with healthy=true" \
  '{"healthy":true,"status":"healthy","index":{"partial":true,"hollow":false,"checkpoint":{"completed":false}}}' \
  fire

fires "hollow=true with healthy=true" \
  '{"healthy":true,"status":"healthy","index":{"partial":false,"hollow":true,"checkpoint":{"completed":true}}}' \
  fire

fires "both true" \
  '{"healthy":true,"index":{"partial":true,"hollow":true}}' \
  fire

# Must stay quiet on a genuinely healthy index, or the doctor cries wolf weekly.
fires "clean index" \
  '{"healthy":true,"status":"healthy","index":{"partial":false,"hollow":false,"checkpoint":{"completed":true}}}' \
  quiet

# Absent fields must not fire: cass omits them in some states, and `null == true`
# is false in jq, but pin it so a future rewrite to `!= false` is caught.
fires "fields absent" \
  '{"healthy":true,"index":{}}' \
  quiet

fires "index key absent entirely" \
  '{"healthy":true}' \
  quiet

# 4. The warn text must name a repair path that exists, not a bare `cass index
#    --full` the operator would run in the foreground and have killed. The
#    rebuild script carries the memory bounds and the detach instruction.
if grep -qF 'cass-index-rebuild.sh' "$DOCTOR"; then ok; else
  bad "rot warn does not point at scripts/cass-index-rebuild.sh"
fi
[ -x "$REPO/scripts/cass-index-rebuild.sh" ] && ok \
  || bad "scripts/cass-index-rebuild.sh missing or not executable"

# 5. Advisory only. A prior version of section 8b ran `cass index --full` inline
#    and wedged the doctor for 23+ minutes; the rot branch must not reintroduce
#    that. Assert no unescaped command substitution of a cass index invocation.
if grep -nF 'cass index --full' "$DOCTOR" | grep -qv '\\`'; then
  # Any occurrence must be inside an escaped-backtick advisory string.
  if grep -nF 'cass index --full' "$DOCTOR" | grep -q '$(cass index'; then
    bad "harness-doctor appears to RUN cass index --full rather than name it"
  else ok; fi
else ok; fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
  echo "ok — harness-doctor cass rot detection: $pass/$total assertions passed"
  exit 0
fi
echo "FAIL — harness-doctor cass rot detection: $fail of $total assertions failed" >&2
exit 1
