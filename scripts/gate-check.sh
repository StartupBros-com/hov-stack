#!/usr/bin/env bash
# gate-check.sh: assert a PR's required checks actually RAN and SUCCEEDED before merge.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer  — any agent or human about to merge; harness-weekly reads nothing here.
#   gate      — merge. Non-zero exit means do not merge.
#   defect    — OBSERVED: the members app's #1251 merged untested 2026-07-29 with `⚫️ Test = skipped`.
#               GitHub counts a *skipped* required check as satisfied, so branch protection
#               permitted the merge and the green tick was truthful but meaningless.
#               OBSERVED: dotfiles#193 2026-08-06 — this script reported UNPROTECTED
#               ("nothing gates this merge") for its own repo while two active RULESETS
#               protected main, one requiring the `Harness suites` context. Classic
#               protection 404s when a branch is ruleset-protected; reading only that
#               endpoint made the tool blind to the mechanism actually in force.
#   delete-when — GitHub distinguishes skipped from successful in branch protection, or
#               required checks stop being expressible as conclusions.
#
# The general law this enforces (not the single instance above): a green aggregate is not
# evidence that anything ran. Closure requires the REQUIRED set to equal the PASSED set over
# named checks. An empty required set is a FAILURE, never a vacuous pass.
#
# Usage:
#   gate-check.sh <owner/repo> <pr-number>
#   gate-check.sh --fixture <file.json>      # offline; see FIXTURE FORMAT below
#
# Exit codes:
#   0  every required check has conclusion=success
#   1  at least one required check is missing, skipped, or otherwise not success
#   2  usage error
#   3  nothing could be asserted — either UNAVAILABLE (check set unreadable) or UNPROTECTED
#      (neither branch protection NOR a ruleset requires a check). Never a pass:
#      "nothing gates this" and "the gate passed" are different facts.
#
# TWO protection mechanisms, and a branch may use either. Classic branch protection answers
# on /branches/{b}/protection; RULESETS do not — that endpoint 404s "Branch not protected"
# even while a ruleset actively requires checks. So `absent` is only concluded after
# /repos/{o}/{r}/rules/branches/{b} (which reports the rules in force from every ruleset)
# has also come back clean. A ruleset-derived required set is as binding as a classic one.
#
# FIXTURE FORMAT (testing; no network):
#   {"draft": true,                              # optional; a draft PR fails before any check is read
#    "required": ["Test"],                       # optional; omit to exercise the fallback
#    "protection": "present"|"ruleset"|"absent"|"unreadable",  # optional; drives the 4-way
#    "check_runs": [{"name":"Test","status":"completed","conclusion":"skipped"}],
#    "statuses":   [{"context":"ci/legacy","state":"success"}]}
set -uo pipefail

case "${1:-}" in
  -h|--help)
    echo 'usage: gate-check.sh <owner/repo> <pr-number> | gate-check.sh --fixture <file.json>'
    exit 0 ;;
esac

FIXTURE=""
if [ "${1:-}" = "--fixture" ]; then
  # Deliberately NOT ${2:?...}: bash's :? expansion exits 1, and this script's own contract
  # reserves 1 for "a required check is not success". A mistyped invocation must never be
  # mistakable for a real gate failure, so arity errors are checked by hand and exit 2.
  [ $# -ge 2 ] || { echo 'gate-check: --fixture needs a file' >&2; exit 2; }
  FIXTURE="$2"
elif [ $# -eq 2 ]; then
  REPO="$1"; PR="$2"
else
  echo 'usage: gate-check.sh <owner/repo> <pr-number> | gate-check.sh --fixture <file.json>' >&2
  exit 2
fi

if [ -n "$FIXTURE" ]; then
  [ -r "$FIXTURE" ] || { echo "gate-check: cannot read fixture $FIXTURE" >&2; exit 2; }
  PAYLOAD=$(cat "$FIXTURE")
else
  command -v gh >/dev/null 2>&1 || { echo "gate-check: gh not found" >&2; exit 3; }
  GATE_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
  # shellcheck source=lib/ci-current-check-runs.sh
  source "$GATE_DIR/lib/ci-current-check-runs.sh" \
    || { echo "gate-check: UNAVAILABLE — cannot load lib/ci-current-check-runs.sh" >&2; exit 3; }
  SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null)
  BASE=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
  if [ -z "$SHA" ]; then
    echo "gate-check: UNAVAILABLE — could not resolve head SHA for $REPO#$PR" >&2
    exit 3
  fi
  if [ -z "$BASE" ]; then
    # Without a base branch the protection URL collapses to .../branches//protection, which
    # 404s — and a 404 would otherwise be read as "this branch has no protection rule". The
    # gate would then report UNPROTECTED ("nothing gates this merge") when the truth is that
    # it never managed to look. Fail as UNAVAILABLE instead.
    echo "gate-check: UNAVAILABLE — could not resolve base branch for $REPO#$PR" >&2
    exit 3
  fi
  # A draft's required checks do not run until it is marked ready for review (dotfiles#1598),
  # so reading them would report MISSING for a head that was never tested. Say so, and fail
  # before any check is evaluated. An unreadable draft state is UNAVAILABLE, never not-draft.
  # This holds in every repository, gated or not: GitHub never merges a draft. Exit 1 is
  # shared with red checks; the stderr line says which.
  DRAFT=$(gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)
  case "$DRAFT" in
    true)
      echo "gate-check: FAIL - $REPO#$PR is a draft; its required checks run when it is marked ready for review (dotfiles#1598)." >&2
      exit 1 ;;
    false) ;;
    *)
      echo "gate-check: UNAVAILABLE — could not read draft state for $REPO#$PR" >&2
      exit 3 ;;
  esac
  # Required contexts come from branch protection. Three outcomes, and they are NOT the same:
  #   present    — we know the required set; assert exactly it.
  #   absent     — 404 "Branch not protected". That is a determinate answer: no required
  #                checks exist, so nothing gates a merge. Widening to all observed checks
  #                here cries wolf on every optional/inactive bot check (found live on
  #                dotfiles#173, where an inactive `[code]smith` read as a failure).
  #   unreadable — 403/scope. The set is genuinely UNKNOWN; widen and say so.
  PROT_OUT=$(gh api "repos/$REPO/branches/$BASE/protection/required_status_checks" \
               --jq '.contexts // [] | @json' 2>&1)
  PROT_RC=$?
  if [ "$PROT_RC" -eq 0 ]; then
    REQUIRED="$PROT_OUT"; PROTECTION=present
  elif grep -qi 'branch not protected' <<<"$PROT_OUT"; then
    # Match ONLY GitHub's specific "Branch not protected" message. Any other 404 (renamed or
    # deleted base branch, a repo the token cannot see) is an unknown required set, not a
    # known-empty one: classifying it `absent` would WAIVE the gate, whereas `unreadable`
    # widens it. The misclassification must never run in the permissive direction.
    #
    # But "Branch not protected" is ONLY about classic protection. A ruleset-protected
    # branch answers exactly the same way, so concluding `absent` here is the same
    # permissive misclassification one layer down — it is what made this script report
    # "nothing gates this merge" on its own repo (dotfiles#193). Ask the rules endpoint
    # before believing it.
    RULES_OUT=$(gh api "repos/$REPO/rules/branches/$BASE" \
                  --jq '[.[] | select(.type=="required_status_checks")
                             | .parameters.required_status_checks[].context] | @json' 2>&1)
    RULES_RC=$?
    if [ "$RULES_RC" -ne 0 ]; then
      # Classic says unprotected, rulesets unreadable. The union is unknown, not empty.
      REQUIRED=""; PROTECTION=unreadable
    elif [ "$RULES_OUT" = "[]" ]; then
      REQUIRED=""; PROTECTION=absent
    else
      REQUIRED="$RULES_OUT"; PROTECTION=ruleset
    fi
  else
    REQUIRED=""; PROTECTION=unreadable
  fi
  # --paginate with --jq applies the filter PER PAGE and concatenates the resulting
  # documents, which stops being valid JSON past page 1. --slurp returns one array of page
  # objects instead; the builder below flattens it. A failed query is UNAVAILABLE — never
  # silently "zero checks observed", which would let an empty set stand in for a real answer.
  # Only the suites that describe the head now: one a newer run of its workflow superseded
  # drops out, so the name-keyed last-wins below cannot keep that older run's verdict
  # (dotfiles#1595). Projected small, since the builder reads it from one environment
  # string, which the kernel caps near 128 KB.
  RUNS=$(ci_current_check_runs "$REPO" "$SHA" 2>/dev/null | jq -c '[{check_runs: [.[] | {name, status, conclusion}]}]')
  RUNS_RC=$?
  if [ "$RUNS_RC" -ne 0 ]; then
    echo "gate-check: UNAVAILABLE — could not read check runs for $SHA" >&2
    exit 3
  fi
  STATUSES=$(gh api "repos/$REPO/commits/$SHA/status" \
               --jq '[.statuses[] | {context, state}] | @json' 2>/dev/null)
  STATUSES_RC=$?
  if [ "$STATUSES_RC" -ne 0 ]; then
    echo "gate-check: UNAVAILABLE — could not read commit statuses for $SHA" >&2
    exit 3
  fi
  PAYLOAD=$(REQ="$REQUIRED" RUNS="$RUNS" ST="$STATUSES" PROT="$PROTECTION" python3 -c '
import json, os, sys

def strict(raw, what):
    """Parse or refuse. An unreadable response is UNAVAILABLE, never an empty result."""
    raw = (raw or "").strip()
    if not raw:
        print(f"gate-check: UNAVAILABLE - empty {what} response", file=sys.stderr)
        sys.exit(3)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"gate-check: UNAVAILABLE - unparseable {what} response ({e})", file=sys.stderr)
        sys.exit(3)

pages = strict(os.environ["RUNS"], "check-runs")
runs = []
for page in (pages if isinstance(pages, list) else [pages]):
    if isinstance(page, dict):
        runs.extend(page.get("check_runs") or [])
    elif isinstance(page, list):
        runs.extend(page)

statuses = strict(os.environ["ST"], "commit status")
if isinstance(statuses, dict):
    statuses = statuses.get("statuses") or []

out = {"check_runs": [{"name": r.get("name"), "status": r.get("status"),
                       "conclusion": r.get("conclusion")}
                      for r in runs if isinstance(r, dict)],
       "statuses": [{"context": s.get("context"), "state": s.get("state")}
                    for s in statuses if isinstance(s, dict)],
       "protection": os.environ["PROT"]}
req = (os.environ["REQ"] or "").strip()
if req:
    try:
        out["required"] = json.loads(req)
    except json.JSONDecodeError:
        pass
print(json.dumps(out))
')
  BUILD_RC=$?
  [ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"
fi

printf '%s' "$PAYLOAD" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f"gate-check: UNAVAILABLE - unparseable payload ({e})", file=sys.stderr)
    sys.exit(3)

# Fixture-mode twin of the live draft read above: same FAIL, before any check is evaluated.
if d.get("draft") is True:
    print("gate-check: FAIL - fixture is a draft; its required checks run when it is marked ready for review (dotfiles#1598).", file=sys.stderr)
    sys.exit(1)

runs     = d.get("check_runs") or []
statuses = d.get("statuses") or []
required = d.get("required")           # None => required set not enumerated
protection = d.get("protection")       # present | ruleset | absent | unreadable | None

# "Branch not protected" is a determinate answer ONLY once rulesets have also been checked
# (see the shell above): there are then no required checks, so nothing gates a merge. Saying
# FAIL here would flag every optional bot check; saying PASS would be worse - it would imply
# a gate was verified. Neither is true.
if protection == "absent" and required is None:
    print("gate-check: UNPROTECTED - neither branch protection nor a ruleset requires")
    print("  a check on the base branch, so nothing gates this merge.")
    print("  This is NOT a pass: no check was proven to have run. Merge on other grounds,")
    print("  or add branch protection if this repo should gate.")
    sys.exit(3)

# Normalise both surfaces into (name, conclusion). A check-run that has not completed has
# no conclusion yet; represent that as "pending" so it can never read as success.
observed = {}
for r in runs:
    name = r.get("name")
    if not name:
        continue
    concl = r.get("conclusion")
    if r.get("status") != "completed" or concl is None:
        concl = "pending"
    observed[name] = concl
for s in statuses:
    ctx = s.get("context")
    if ctx and ctx not in observed:
        observed[ctx] = s.get("state") or "pending"

if required is None:
    scope = "ALL observed checks (required set UNKNOWN - branch protection unreadable)"
    targets = sorted(observed)
else:
    source = "repository ruleset" if protection == "ruleset" else "branch protection"
    scope = f"{len(required)} required check(s) from {source}"
    targets = sorted(required)

print(f"gate-check scope: {scope}")

# Empty set is never a pass: it is indistinguishable from "nothing ran".
if not targets:
    print("gate-check: FAIL - no checks to assert over. An empty check set is not green.")
    sys.exit(1)

bad = []
for name in targets:
    concl = observed.get(name)
    if concl is None:
        print(f"  {name}: MISSING (required but never reported)")
        bad.append(name)
        continue
    mark = "ok" if concl == "success" else "NOT SUCCESS"
    print(f"  {name}: {concl}  [{mark}]")
    if concl != "success":
        bad.append(name)

if bad:
    joined = ", ".join(bad)
    print(f"gate-check: FAIL - {len(bad)} of {len(targets)} not success: {joined}")
    print("  A skipped required check satisfies branch protection but proves nothing.")
    sys.exit(1)

print(f"gate-check: PASS - {len(targets)}/{len(targets)} required checks ran and succeeded")
if required is None:
    print("  NOTE: asserted over all observed checks; the required set could not be read.")
sys.exit(0)
'
