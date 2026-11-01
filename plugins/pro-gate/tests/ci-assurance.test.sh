#!/usr/bin/env bash
# Exercise the commands trusted CI actually invokes, including planted negatives.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
helper="$ROOT/scripts/validate-source.sh"
ci_script="$ROOT/tests/ci.sh"
grep -Fxq 'bash scripts/validate-source.sh' "$ci_script" || fail 'CI must invoke the tested validator'
test_command='bash tests/review-decision-adapters.test.sh'
grep -Fxq "  \"$test_command\"" "$ci_script" || fail 'trusted CI must invoke adapter conformance'

# The suites run as concurrent legs in tests/ci.sh. Splitting them must never drop or double a suite,
# so every tests/*.test.sh and tests/*.test.mjs file must be invoked by exactly one leg, and nothing
# else. A file that declares PG_TEST_SHARDS=N is instead invoked once per shard, PG_TEST_SHARD=1..N.
# ci.sh enforces this itself before it runs anything; this test runs that very block (the leg arrays
# through the closing `fi` of the coverage check) against the real script and against planted copies.
leg_coverage() { # ci.sh copy; prints the problem and returns 1 on any gap
  ( cd "$ROOT" && eval "$(sed -n '/^leg_engine_1=/,/^fi$/p' "$1")" ) 2>"$TDIR/coverage.err" || return 1
}
leg_coverage "$ci_script" || { cat "$TDIR/coverage.err" >&2; fail 'every test file must run in exactly one CI leg'; }
plant() { # name, sed program: a copy of ci.sh with a planted coverage gap
  sed "$2" "$ci_script" > "$TDIR/ci-$1.sh"
  cmp -s "$ci_script" "$TDIR/ci-$1.sh" && fail "planted $1 did not change ci.sh"
  if leg_coverage "$TDIR/ci-$1.sh"; then fail "planted $1 passed the leg coverage check"; fi
  grep -Fq 'do not run every test file exactly once' "$TDIR/coverage.err" || fail "planted $1 failed for another reason: $(cat "$TDIR/coverage.err")"
}
plant dropped-suite '/^  "bash tests\/round-continue.test.sh"$/d'
plant doubled-suite 's|^  "bash tests/trusted-data.test.sh"$|&\n  "bash tests/trusted-data.test.sh"|'
plant dropped-engine-shard 's|^leg_engine_2=.*|leg_engine_2=()|'
plant doubled-engine-shard 's|^leg_engine_3=.*|leg_engine_3=("PG_TEST_SHARD=1 bash tests/engine.test.sh")|'
echo 'ok - every test file runs in exactly one CI leg; a dropped or doubled suite or engine shard is rejected'

# The engine suite's shard regions must be numbered 1..PG_TEST_SHARDS in file order, and in_shard k
# must select region k and no other, so one leg per shard runs every region once; an in_shard that
# selected every region would keep coverage and silently undo the split. A shard outside
# 1..PG_TEST_SHARDS, including a pattern such as `.`, must refuse instead of running nothing.
engine_suite="$ROOT/tests/engine.test.sh"
engine_shards="$(sed -n 's/^PG_TEST_SHARDS=\([1-9][0-9]*\)$/\1/p' "$engine_suite")"
[ "$(sed -n 's/^if in_shard \([0-9][0-9]*\); then$/\1/p' "$engine_suite" | tr '\n' ' ')" = "$(seq -s ' ' 1 "$engine_shards") " ] \
  || fail 'engine shard regions must be numbered 1..PG_TEST_SHARDS in file order'
eval "$(sed -n '/^in_shard() {/p' "$engine_suite")"
[ "$(type -t in_shard)" = function ] || fail 'the engine suite must define in_shard() on one line'
for k in $(seq 1 "$engine_shards"); do
  for region in $(seq 1 "$engine_shards"); do
    selected=0; PG_TEST_SHARD="$k" in_shard "$region" && selected=1
    [ "$selected" = "$([ "$k" = "$region" ] && echo 1 || echo 0)" ] || fail "PG_TEST_SHARD=$k: in_shard $region returned selected=$selected"
  done
  PG_TEST_SHARD='' in_shard "$k" || fail "an unsharded engine run skips region $k"
done
for shard in $((engine_shards + 1)) .; do
  if PG_TEST_SHARD="$shard" bash "$engine_suite" > "$TDIR/shard-range.log" 2>&1; then
    fail "engine shard '$shard' ran instead of refusing"
  fi
  grep -Fq 'PG_TEST_SHARD must be' "$TDIR/shard-range.log" || fail "engine shard '$shard' refused for another reason"
done
echo 'ok - engine shard regions are numbered 1..PG_TEST_SHARDS, each shard selects only its own, and an invalid shard refuses'

mkdir -p "$TDIR/data/nested space" "$TDIR/data/.git"
bash "$helper" "$TDIR/data" || fail 'empty set'
printf '{"ok":true}\n' > "$TDIR/data/nested space/good file.json"
printf 'ok: true\n' > "$TDIR/data/nested space/good file.yaml"
printf 'bad: [\n' > "$TDIR/data/.git/ignored.yml"
bash "$helper" "$TDIR/data" || fail 'valid files and ignored git metadata'
for suffix in json yaml yml; do
  bad="$TDIR/data/nested space/bad file.$suffix"
  printf '[}\n' > "$bad"
  if bash "$helper" "$TDIR/data" > "$TDIR/parser.log" 2>&1; then fail "malformed $suffix passed"; fi
  rm "$bad"
done
echo 'ok - actual CI validator accepts empty/valid files and rejects malformed JSON/YAML with spaces'

# #295: bash 5 parses a case pattern without its leading parenthesis inside a process substitution;
# stock macOS bash 3.2 does not. The validator must reject it outside tests/, leave the suites
# (which need bash 4 or later) alone, and accept the parenthesized form.
bash32_bad='while read -r m; do echo "$m"; done < <(for m in a.tmp.1 b; do case "$m" in *.tmp.*) continue ;; esac; echo "$m"; done)'
bash32_good='while read -r m; do echo "$m"; done < <(for m in a.tmp.1 b; do case "$m" in (*.tmp.*) continue ;; esac; echo "$m"; done)'
planted="$TDIR/data/nested space/old bash.sh"
printf '#!/usr/bin/env bash\n%s\n' "$bash32_bad" > "$planted"
[ "$(bash "$planted")" = b ] || fail 'the planted bash 3.2 case must run under this bash'
if bash "$helper" "$TDIR/data" > "$TDIR/bash32.log" 2>&1; then fail 'planted bash 3.2 parse error passed'; fi
grep -q 'old bash.sh: line 2: syntax error' "$TDIR/bash32.log" || fail 'the bash 3.2 failure must name the file and line'
mkdir -p "$TDIR/data/tests"
mv "$planted" "$TDIR/data/tests/old bash.sh"
bash "$helper" "$TDIR/data" || fail 'the suites under tests/ must be left to bash 4 or later'
rm "$TDIR/data/tests/old bash.sh"
printf '#!/usr/bin/env bash\n%s\n' "$bash32_good" > "$planted"
[ "$(bash "$planted")" = b ] || fail 'the parenthesized case must behave the same'
bash "$helper" "$TDIR/data" || fail 'the parenthesized case pattern must parse under bash 3.2'
rm "$planted"
echo 'ok - actual CI validator rejects a bash 3.2 parse error outside tests/ and accepts the parenthesized form'

# Copy only the adapter test's dependencies; never mutate the working tree's identity.
mkdir -p "$TDIR/repo/tests" "$TDIR/repo/daemon" "$TDIR/repo/bin" "$TDIR/repo/scripts"
cp -R "$ROOT/lib" "$ROOT/skills" "$ROOT/agents" "$ROOT/.claude-plugin" "$TDIR/repo/"
cp -R "$ROOT/tests/fixtures" "$TDIR/repo/tests/"
cp "$ROOT/tests/review-decision-adapters.test.sh" "$TDIR/repo/tests/"
cp "$ROOT/daemon/daemon.sh" "$TDIR/repo/daemon/"
cp "$ROOT/bin/oracle-review.sh" "$TDIR/repo/bin/"
cp "$ROOT/scripts/regenerate-review-decision.mjs" "$TDIR/repo/scripts/"
cd "$TDIR/repo"
$test_command > "$TDIR/adapters-valid.log" 2>&1 || { cat "$TDIR/adapters-valid.log"; fail 'unmodified adapter fixture'; }
identity=skills/pro-gate/review-decision-v1.json
cp "$identity" "$TDIR/identity"
jq -cjS '.corpus_digest="0000000000000000000000000000000000000000000000000000000000000000"' "$TDIR/identity" > "$identity"
if $test_command > "$TDIR/adapters-bad-identity.log" 2>&1; then fail 'planted bad identity passed CI command'; fi
grep -Fq 'not ok - plugin identity' "$TDIR/adapters-bad-identity.log" || fail 'identity did not fail for expected reason'
cp "$TDIR/identity" "$identity"
corpus=tests/fixtures/review-decision/v1/corpus.json
cp "$corpus" "$TDIR/corpus"
jq -cjS '.cases[0].expected.action="invented-action"' "$TDIR/corpus" > "$corpus"
if $test_command > "$TDIR/adapters-bad-corpus.log" 2>&1; then fail 'planted bad corpus passed CI command'; fi
grep -Fq 'not ok - frozen corpus' "$TDIR/adapters-bad-corpus.log" || fail 'corpus did not fail for expected reason'
echo 'ok - CI-invoked adapter suite rejects planted identity and corpus corruption'
