#!/usr/bin/env bash
# candidate_smoke() must distinguish a CANDIDATE fault from an ENVIRONMENT fault.
#
# All four gating checks now interrogate the binary alone, so a failure in any of
# them is attributable to the candidate and refusing it is honest. --version and
# capabilities are inherently hermetic; status and search are pointed at a
# scratch --db, which carries the lexical index, raw-mirror, checkpoints and
# locks with it (upstream #403), so they exercise real code paths without the
# live archive.
#
# Before the split every check returned 1, the caller refused, and refuse()
# exits 0. A local environment fault therefore read as "upstream shipped a bad
# release", the unit stayed green, and OnFailure= could never fire for it. That
# is the integrity-vs-refusal confusion dcg-update.sh once had, in a second place.
#
# Then the opposite failure arrived. Routing shared-state faults to 1 meant a
# degraded archive HARD-FAILED the lane, and on 2026-09-07 that latched it shut:
# the live index worsens monotonically, so the gate refused v0.7.1 every night
# while v0.7.1 was the fix. Fail-closed is right for an input that can recover
# and a latch for one that cannot. Nothing touching shared state gates any more.
#
# The live archive is still probed and still NOTIFIES -- case 6 -- because
# removing it from the verdict removed the only signal a wedged archive made.
#
# Contract: 0 pass · 2 candidate fault · 1 promoter could not build the test.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/cass-release-promote.sh
HERE=$REPO/scripts
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

# Extract only the functions; sourcing the script would attempt a promote.
# live_archive_advisory is extracted too: candidate_smoke calls it, so without it
# every case would eat a "command not found" and the advisory path would be
# untested precisely where this change moved the risk.
sed -n '/^smoke_fail() {/,/^}/p'             "$SCRIPT" >  "$TMP/fn.sh"
sed -n '/^candidate_smoke() {/,/^}/p'        "$SCRIPT" >> "$TMP/fn.sh"
sed -n '/^live_archive_advisory() {/,/^}/p'  "$SCRIPT" >> "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract candidate_smoke" >&2; exit 1; }
grep -q '^live_archive_advisory() {' "$TMP/fn.sh" \
  || { echo "FAIL: could not extract live_archive_advisory" >&2; exit 1; }
# Record notifications instead of sending them, so case 6 can assert one fired.
say() { printf '%s\n' "$*" >> "$TMP/said"; return 0; }
# shellcheck source=/dev/null
. "$TMP/fn.sh"
for fn in smoke_fail candidate_smoke live_archive_advisory; do
  declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn" >&2; exit 1; }
done

# stub <name> <break-at>
#   break-at: none|version|mismatch|capabilities|status|search|live
#
# The stub must model --db, because that flag is what makes status/search
# hermetic: real cass reports the scratch parent as .data_dir, and the smoke
# asserts it to prove isolation held. A stub that ignored --db would let the
# isolation assertion pass vacuously.
#
# `live` is the deadlock case: scratch probes healthy, live archive wedged.
stub() {
  local f=$TMP/$1 brk=$2
  cat > "$f" <<EOS
#!/usr/bin/env bash
# Extract --db without a loop; derive the data dir real cass would report.
# \$* must be assigned to a scalar first: \${*#pat} applies the removal to EACH
# positional parameter and rejoins, so it silently yields the whole arg list back
# and dirname then reports ".".
all="\$*"
db=""
case "\$all" in
  *"--db "*) db=\${all#*--db }; db=\${db%% *} ;;
esac
scratch=0; [ -n "\$db" ] && scratch=1
# Global flags may lead the subcommand (canonical form for cass 0.8.0), so the
# verb is not reliably \$1 -- scan for it the same way --db is scanned above.
verb=""
case " \$all " in
  *" --version "*) verb=--version ;;
  *" capabilities "*) verb=capabilities ;;
  *" status "*) verb=status ;;
  *" search "*) verb=search ;;
esac
case "\$verb" in
  --version)
      [ "$brk" = version ] && exit 3
      [ "$brk" = mismatch ] && { printf 'cass 1.2.3\n'; exit 0; }
      printf 'cass 9.9.9\n'; exit 0 ;;
  capabilities) [ "$brk" = capabilities ] && exit 4; printf '%s\n' '{"ok":true}'; exit 0 ;;
  status)
      if [ "\$scratch" = 1 ]; then
        [ "$brk" = status ] && exit 5
        [ "$brk" = isolation ] && { printf '{"data_dir":"/not-scratch"}\n'; exit 0; }
        printf '{"ok":true,"data_dir":"%s"}\n' "\$(dirname "\$db")"; exit 0
      fi
      [ "$brk" = live ] && exit 5
      printf '%s\n' '{"ok":true}'; exit 0 ;;
  search)
      if [ "\$scratch" = 1 ]; then
        [ "$brk" = search ] && exit 6
        [ "$brk" = missing-index ] && { printf '{"error":{"kind":"missing-index"}}\n' >&2; exit 3; }
        printf '%s\n' '{"ok":true}'; exit 0
      fi
      [ "$brk" = live ] && exit 6
      printf '%s\n' '{"hits":[{}]}'; exit 0 ;;
esac
exit 0
EOS
  chmod +x "$f"; printf '%s\n' "$f"
}

rc_of() { candidate_smoke "$1" 9.9.9 >/dev/null 2>>"$TMP/stderr"; printf '%s\n' "$?"; }

# 0. Zero-run-green guard: a healthy stub must return 0, or every assertion
#    below is satisfied by a smoke that always fails.
[ "$(rc_of "$(stub good none)")" = 0 ] && ok || bad "healthy candidate did not return 0"

# 1-2. CANDIDATE faults -> 2 (refusable). The binary itself is wrong.
[ "$(rc_of "$(stub v version)")" = 2 ]        && ok || bad "--version failure should be 2 (candidate)"
[ "$(rc_of "$(stub m mismatch)")" = 2 ]       && ok || bad "version mismatch should be 2 (candidate)"
[ "$(rc_of "$(stub c capabilities)")" = 2 ]   && ok || bad "capabilities failure should be 2 (candidate)"

# 3-4. SCRATCH status/search faults -> 2 (candidate). These used to run against
#      the live archive and return 1. They now run against an isolated --db, so
#      the candidate IS implicated and refusing it is honest.
[ "$(rc_of "$(stub s status)")" = 2 ] && ok || bad "scratch status failure should be 2 (candidate)"
[ "$(rc_of "$(stub q search)")" = 2 ] && ok || bad "scratch search failure should be 2 (candidate)"

[ "$(rc_of "$(stub isolation isolation)")" = 2 ] && ok || bad "scratch isolation failure should be 2"
[ "$(rc_of "$(stub missing missing-index)")" = 0 ] && ok || bad "empty scratch missing-index stderr should pass"
setup_cass=$(stub setup none)
rc=$(TMPDIR="$TMP/nonexistent-parent" rc_of "$setup_cass")
[ "$rc" = 1 ] && ok || bad "scratch setup failure should be 1 (promoter), got $rc"
grep -qF 'scratch dir (mktemp failed)' "$TMP/stderr" && ok || bad "setup failure did not reach mktemp gate"

# 5. THE DEADLOCK REGRESSION -- the reason this file changed.
#    A wedged live archive must NOT block promotion. On 2026-09-07 it did: the
#    live Quill index had ~900 unmerged segments, the search probe failed every
#    night, and v0.7.1 -- which carries the upstream fix for that exact bug --
#    could never be promoted. A broken index blocked the upgrade that repairs it,
#    and segment count only grows, so it could never clear on its own.
[ "$(rc_of "$(stub l live)")" = 0 ] && ok || bad "wedged live archive must not block promotion (the 2026-09-07 deadlock)"

# 6. ...but it must still reach the operator. Removing the live checks from the
#    verdict removed the only signal a wedged archive produced -- a red unit. A
#    degradation that reaches nobody is how cass-rerank returned "no results"
#    silently for weeks. Advisory to the exit code, not to the operator.
: > "$TMP/said"
candidate_smoke "$(stub l2 live)" 9.9.9 >/dev/null 2>>"$TMP/stderr"
grep -q 'live archive degraded' "$TMP/said" 2>/dev/null \
  && ok || bad "wedged live archive did not notify the operator"

# 7. The promote call site must route 1 to a hard failure, not to reject().
#    reject() exits 0, which is exactly how a promoter fault would disappear.
#    1 now means the promoter could not construct the test (mktemp), which is
#    still a real failure and still must not read as "upstream shipped a bad
#    release". Checked structurally because reaching that line needs a release.
blk=$(sed -n '/^candidate_smoke "\$cand"/,/^esac/p' "$SCRIPT")
[ -n "$blk" ] || bad "promote call site not found in expected form"
case "$blk" in
  *"2) reject"*) ok ;;
  *) bad "candidate fault (2) does not route to reject()" ;;
esac
case "$blk" in
  *"fail "*"exit 1"*) ok ;;
  *) bad "environment fault does not route to a hard failure" ;;
esac

if grep -qF 'command not found' "$TMP/stderr"; then
  bad "smoke called an unextracted function or missing tool: $(cat "$TMP/stderr")"
else
  ok
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — cass smoke classification: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — cass smoke classification: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
