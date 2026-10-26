#!/usr/bin/env bash
# candidate_smoke() must name WHICH of its five checks failed.
#
# It previously returned a bare 1 from all five, so a rejection logged one line
# -- "candidate read-only smoke failed" -- and discarded the evidence at the
# moment it had it. cass v0.6.26 was refused on 2026-08-27 and the log
# could not say why; reproducing it required the machine, its index, and a
# hand-run of every step. A gate that refuses without saying what it saw turns
# each rejection into a fresh investigation.
#
# Every case is its own planted negative: collapse any branch back to a bare
# `return 1` and that case fails, because the step name disappears.
# OBSERVED negative-run output, recorded rather than described (house doctrine:
# measured, not claimed). Captured from case 5's stub on 2026-08-28:
#
#     smoke step FAILED: search probe (not JSON)
#     output: this is not json
#
# and with both stderr lines deleted the suite drops to 2/7, which is the
# regression the previous version could not see at all.
#
# Cases 1-4 drive
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERE=$REPO/scripts
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

# Extract just the functions; sourcing the script would run a promote.
# live_archive_advisory is included because candidate_smoke calls it: without it
# every case absorbs a "command not found" on stderr, which this suite greps.
sed -n '/^smoke_fail() {/,/^}/p'            "$REPO/scripts/cass-release-promote.sh" >  "$TMP/fn.sh"
sed -n '/^candidate_smoke() {/,/^}/p'       "$REPO/scripts/cass-release-promote.sh" >> "$TMP/fn.sh"
sed -n '/^live_archive_advisory() {/,/^}/p' "$REPO/scripts/cass-release-promote.sh" >> "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract smoke functions" >&2; exit 1; }
grep -q '^live_archive_advisory() {' "$TMP/fn.sh" \
  || { echo "FAIL: could not extract live_archive_advisory" >&2; exit 1; }
say() { printf '%s\n' "$*" >> "$TMP/said"; return 0; }
# shellcheck source=/dev/null
. "$TMP/fn.sh"
for fn in smoke_fail candidate_smoke live_archive_advisory; do
  declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn" >&2; exit 1; }
done

# stub <name> <version-line> <capabilities> <status> <search>
# Each payload is valid JSON, the literal NOTJSON, or FAIL:<code>.
stub() {
  local name=$1 ver=$2 caps=$3 st=$4 se=$5
  local f=$TMP/$name
  cat > "$f" <<EOS
#!/usr/bin/env bash
emit() {
  case "\$1" in
    NOTJSON) printf 'this is not json\n'; return 0 ;;
    FAIL:*)  printf 'stub failure detail\n' >&2; return "\${1#FAIL:}" ;;
    *)       printf '%s\n' "\$1"; return 0 ;;
  esac
}
# status/search are now probed against a scratch --db. A healthy stub must report
# .data_dir as the scratch parent, because the smoke asserts it to prove the
# isolation held. \$* is assigned to a scalar first: \${*#pat} applies the removal
# to EACH positional parameter, silently yielding the whole arg list back.
all="\$*"
db=""
case "\$all" in
  *"--db "*) db=\${all#*--db }; db=\${db%% *} ;;
esac
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
  --version)    printf '%s\n' '$ver'; exit 0 ;;
  capabilities) emit '$caps'; exit \$? ;;
  status)
      case '$st' in
        NOTJSON|FAIL:*) emit '$st'; exit \$? ;;
      esac
      [ -n "\$db" ] && { printf '{"ok":true,"data_dir":"%s"}\n' "\$(dirname "\$db")"; exit 0; }
      emit '$st'; exit \$? ;;
  search)
      [ -z "\$db" ] && { printf '{"hits":[{}]}\n'; exit 0; }
      emit '$se'; exit \$? ;;
esac
exit 0
EOS
  chmod +x "$f"
  printf '%s\n' "$f"
}

# named <binary> <expected-version> <substring> [expected-rc]
#
# Asserts THREE things, because the previous version asserted only the first and
# was therefore satisfied by a smoke that never failed and printed nothing:
#   1. SMOKE_FAILURE names the step
#   2. the smoke actually returned NONZERO (and the right class when given one)
#   3. the stderr diagnostics — the entire point of the feature — were emitted
#
# stderr is redirected to a FILE rather than captured with $(...): a command
# substitution runs candidate_smoke in a subshell, so SMOKE_FAILURE would never
# reach this scope and case 1 would silently test an empty string.
LAST_WHY=""
named() {
  local want_rc=${4:-} rc
  : > "$TMP/stderr"
  candidate_smoke "$1" "$2" >/dev/null 2>"$TMP/stderr"; rc=$?
  cat "$TMP/stderr" >> "$TMP/all-stderr"
  if [ "$rc" -eq 0 ]; then LAST_WHY="smoke returned 0"; return 1; fi
  if [ -n "$want_rc" ] && [ "$rc" -ne "$want_rc" ]; then
    LAST_WHY="rc=$rc, wanted $want_rc"; return 1; fi
  case "${SMOKE_FAILURE:-}" in
    *"$3"*) ;;
    *) LAST_WHY="SMOKE_FAILURE='${SMOKE_FAILURE:-}'"; return 1 ;;
  esac
  # -e is load-bearing: a substring like "--version" is otherwise parsed as a
  # grep FLAG, which prints grep's own version and silently matches nothing.
  if ! grep -qF -e "$3" "$TMP/stderr"; then
    LAST_WHY="stderr did not name the step: $(tr '\n' ' ' < "$TMP/stderr")"; return 1
  fi
  return 0
}

J='{"ok":true}'

# 0. Zero-run-green guard: a fully healthy stub must PASS, or every "named"
#    assertion below would be satisfied by a smoke that always fails.
b=$(stub good 'cass 9.9.9' "$J" "$J" "$J")
candidate_smoke "$b" 9.9.9 >/dev/null 2>>"$TMP/all-stderr" && ok || bad "a healthy stub was rejected"

# 1. --version non-zero exit
b=$(stub v_exit 'cass 9.9.9' "$J" "$J" "$J"); printf '#!/usr/bin/env bash\nexit 7\n' > "$b"; chmod +x "$b"
named "$b" 9.9.9 '--version' 2 && ok || bad "version exit not named (${LAST_WHY:-no reason})"

# 2. --version reports the wrong release
b=$(stub v_mismatch 'cass 1.2.3' "$J" "$J" "$J")
named "$b" 9.9.9 'mismatch' 2 && ok || bad "version mismatch not named (${LAST_WHY:-no reason})"

# 3. capabilities returns non-JSON
b=$(stub caps 'cass 9.9.9' NOTJSON "$J" "$J")
named "$b" 9.9.9 'capabilities' 2 && ok || bad "capabilities not named (${LAST_WHY:-no reason})"

# 4. scratch status exits non-zero. Class is 2, not 1: the probe runs against an
#    isolated --db now, so the failure is the candidate's.
b=$(stub st 'cass 9.9.9' "$J" FAIL:4 "$J")
named "$b" 9.9.9 'scratch status' 2 && ok || bad "scratch status not named (${LAST_WHY:-no reason})"

# 5. the search probe returns non-JSON -- the step cass v0.6.26 most likely hit.
#    It no longer touches the live index (that is now advisory), so a failure
#    here means the candidate cannot search a scratch archive it just created.
b=$(stub se 'cass 9.9.9' "$J" "$J" NOTJSON)
named "$b" 9.9.9 'scratch search probe' 2 && ok || bad "scratch search probe not named (${LAST_WHY:-no reason})"

# 6. The detail must carry a slice of what the binary actually said, bounded so
#    it can safely reach a notification.
b=$(stub det 'cass 9.9.9' "$J" "$J" NOTJSON)
candidate_smoke "$b" 9.9.9 >/dev/null 2>>"$TMP/all-stderr"
[ -n "${SMOKE_DETAIL:-}" ] && [ "${#SMOKE_DETAIL}" -le 200 ] \
  && ok || bad "detail empty or unbounded (len=${#SMOKE_DETAIL})"

if grep -qF 'command not found' "$TMP/all-stderr"; then
  bad "smoke called an unextracted function or missing tool: $(cat "$TMP/all-stderr")"
else
  ok
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — cass smoke diagnostics: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — cass smoke diagnostics: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
