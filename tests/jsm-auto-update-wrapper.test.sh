#!/usr/bin/env bash
# Hermetic contract tests for the tracked JSM nightly update wrapper.
set -uo pipefail

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER=$CLAUDE_DIR/scripts/jsm-auto-update-wrapper.sh
[ -x "$WRAPPER" ] || { echo "FAIL: executable wrapper not found at $WRAPPER" >&2; exit 1; }

TMP=$(mktemp -d /tmp/jsm-wrapper-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR=$TMP
FIXTURE=$TMP/fixture
CALLS=$TMP/calls.log
MARKER=$TMP/marker
FAKE_JSM=$TMP/fake-jsm
PATCHES=$TMP/patches
TREES=$TMP/trees
mkdir -p "$FIXTURE" "$TMP/bin"

# Every invocation, including ones inheriting a systemd environment, is local.
cat >"$TMP/bin/logger" <<'STUB'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = --journald ] || exit 64
cat >>"${FAKE_MARKER:?}"
if [ "${FAKE_LOGGER_HANG:-0}" = 1 ]; then
  trap '' TERM
  sleep 5
fi
exit "${FAKE_LOGGER_RC:-0}"
STUB
chmod +x "$TMP/bin/logger"
cat >"$TMP/bin/tee" <<'STUB'
#!/usr/bin/env bash
/usr/bin/tee "$@" || exit "$?"
[ "${FAKE_REMOVE_CAPTURE:-0}" != 1 ] || rm -f "$1"
exit "${FAKE_TEE_RC:-0}"
STUB
chmod +x "$TMP/bin/tee"
export PATH="$TMP/bin:$PATH" FAKE_MARKER="$MARKER"
export INVOCATION_ID=282b9a9bf6eb486aaa4dc81424feb4db

# Answers only the calls the wrapper makes, logs each one, and replays
# <key>.stdout/.stderr/.rc from the fixture (empty and 0 when absent). Like jsm
# 0.3.36 it refuses an upgrade, with rc 0 and a Failed: block, when the skill
# carries __pycache__ in any tree.
cat >"$FAKE_JSM" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_CALLS:?}"
case "$#:$*" in
  '3:upgrade --list --json') key=list ;;
  '3:config show --json') key=config ;;
  2:upgrade\ *) key=upgrade-$2 ;;
  3:install\ *\ --force) key=install-$2 ;;
  3:diff\ *\ --json) key=diff-$2 ;;
  *) exit 64 ;;
esac
F=${FAKE_FIXTURE:?}
if [ "$key" = "upgrade-$2" ] && [ -n "${FAKE_TREES:-}" ] &&
  find "$FAKE_TREES"/*/"$2" -name __pycache__ 2>/dev/null | grep -q .; then
  printf 'Failed:\n  • %s - Local edits or untracked data detected in managed skill directory. Nothing was changed.\n' "$2"
  exit 0
fi
[ ! -f "$F/$key.stdout" ] || cat "$F/$key.stdout"
if [ "$key" = "${FAKE_STREAM_KEY:-}" ] && [ -n "${FAKE_STREAM_GATE:-}" ]; then
  for ((attempt=0; attempt<100; attempt++)); do
    [ -f "$FAKE_STREAM_GATE" ] && break
    sleep 0.02
  done
  [ -f "$FAKE_STREAM_GATE" ] || exit 88
fi
[ ! -f "$F/$key.stderr" ] || cat "$F/$key.stderr" >&2
rc=0
[ ! -f "$F/$key.rc" ] || rc=$(cat "$F/$key.rc")
exit "$rc"
STUB
chmod +x "$FAKE_JSM"
mkdir -p "$TMP/home/.local/bin"
cp "$FAKE_JSM" "$TMP/home/.local/bin/jsm"

# One overlay skill: our copies of SKILL.md and references/GUIDE.md.
mkdir -p "$PATCHES/ov-skill/references"
printf 'ours\n' >"$PATCHES/ov-skill/SKILL.md"
printf 'ours\n' >"$PATCHES/ov-skill/references/GUIDE.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

reset_fixture() {
  : >"$CALLS"
  : >"$MARKER"
  rm -rf "$FIXTURE" "$TREES"
  mkdir -p "$FIXTURE" "$TREES/claude" "$TREES/codex"
  printf '{"status":"ok","count":0,"updates":[]}\n' >"$FIXTURE/list.stdout"
  # Only absolute *_dir values are trees; the other two keys must be ignored.
  printf '{"values":{"skills":{"claude_dir":"%s","codex_dir":"%s","relative_dir":"rel/skills","note":"/not/a/tree"}}}\n' \
    "$TREES/claude" "$TREES/codex" >"$FIXTURE/config.stdout"
}

# set_updates NAME[:pinned|:pinned-updatable]... writes the pending list, plus
# one current skill. jsm 0.3.36 caps a pinned skill's latest_version at the pin
# and reports update_available false, which :pinned reproduces; :pinned-updatable
# is the shape jsm does not print today, kept to prove a pin is never upgraded.
set_updates() {
  local entry name pinned latest available json=""
  for entry in "$@"; do
    name=${entry%%:*} pinned=false latest=2 available=true
    case $entry in
      *:pinned) pinned=true latest=1 available=false ;;
      *:pinned-updatable) pinned=true ;;
    esac
    json="$json${json:+,}{\"name\":$(jq -Rn --arg n "$name" '$n'),\"installed_version\":1,\"latest_version\":$latest,\"pinned\":$pinned,\"update_available\":$available}"
  done
  printf '{"status":"ok","count":%s,"updates":[%s,{"name":"current-skill","installed_version":3,"latest_version":3,"pinned":false,"update_available":false}]}\n' \
    "$(($# + 1))" "$json" >"$FIXTURE/list.stdout"
}

# set_diff NAME ADDED REMOVED MODIFIED (JSON arrays), as `jsm diff --json` prints.
set_diff() {
  printf '{"skill":"%s","from_version":6,"to_version":12,"added":%s,"removed":%s,"modified":%s}\n' \
    "$1" "$2" "$3" "$4" >"$FIXTURE/diff-$1.stdout"
}

run_wrapper() {
  local name=$1
  LAST_OUTPUT=$TMP/$name.output
  FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
    JSM_SKILLS_PATCHES="$PATCHES" "$WRAPPER" >"$LAST_OUTPUT" 2>&1
  LAST_RC=$?
}

run_wrapper_default() {
  local name=$1
  LAST_OUTPUT=$TMP/$name.output
  FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" HOME="$TMP/home" \
    JSM_SKILLS_PATCHES="$PATCHES" env -u JSM_BIN "$WRAPPER" >"$LAST_OUTPUT" 2>&1
  LAST_RC=$?
}

assert_rc() {
  local expected=$1 label=$2
  if [ "$LAST_RC" -eq "$expected" ]; then ok; else bad "$label: exit $LAST_RC, expected $expected"; fi
}

assert_text() {
  local expected=$1 actual=$2 label=$3
  if cmp -s "$expected" "$actual"; then ok; else bad "$label differs"; fi
}

assert_calls() {
  local label=$1
  shift
  printf '%s\n' "$@" >"$TMP/calls.expected"
  assert_text "$TMP/calls.expected" "$CALLS" "$label"
}

assert_marker() {
  local expected=$1 label=$2
  if grep -qxF "$expected" "$MARKER"; then ok; else bad "$label: missing $expected"; fi
}

assert_no_marker() {
  if [ ! -s "$MARKER" ]; then ok; else bad "$1 wrote a failure marker"; fi
}

LIST='upgrade --list --json'
CONFIG='config show --json'

# Clean run: one list call, then each pending skill by name. jsm's own output
# streams; the list JSON is summarised, not replayed. No `jsm sync`.
reset_fixture
set_updates skill-a
printf 'upgrade stdout\n' >"$FIXTURE/upgrade-skill-a.stdout"
printf 'upgrade stderr\n' >"$FIXTURE/upgrade-skill-a.stderr"
printf 'jsm-auto-update: 1 skill update(s) available: skill-a\nupgrade stdout\nupgrade stderr\n' >"$TMP/clean.expected"
run_wrapper_default clean
assert_rc 0 "clean run"
assert_calls "clean call order" "$LIST" "$CONFIG" 'upgrade skill-a'
assert_text "$TMP/clean.expected" "$LAST_OUTPUT" "clean output stream"
assert_no_marker "clean run"

# Nothing pending: no further jsm calls.
reset_fixture
run_wrapper none-pending
assert_rc 0 "nothing pending"
assert_calls "nothing pending makes no further calls" "$LIST"
if grep -qxF 'jsm-auto-update: no skill updates to apply' "$LAST_OUTPUT"; then ok
else bad "nothing pending is not reported"; fi
if grep -qF 'pinned' "$LAST_OUTPUT"; then bad "nothing pinned still printed a pinned line"; else ok; fi

# A failed list call stops before any update.
reset_fixture
printf 'list failed\n' >"$FIXTURE/list.stderr"
printf '23\n' >"$FIXTURE/list.rc"
run_wrapper list-failed
assert_rc 23 "list failure"
assert_calls "list failure call order" "$LIST"
if grep -qxF 'list failed' "$LAST_OUTPUT"; then ok; else bad "list failure output was swallowed"; fi
assert_marker 'JSM_STAGE=list' "list failure stage"
assert_marker 'JSM_CAUSE=stage-failed' "list failure cause"

# A list that is not the expected JSON stops too.
for garbled in 'Sync error: not json' '{"updates":null}'; do
  reset_fixture
  printf '%s\n' "$garbled" >"$FIXTURE/list.stdout"
  run_wrapper list-garbled
  assert_rc 1 "garbled list"
  assert_calls "garbled list call order" "$LIST"
  assert_marker 'JSM_STAGE=list' "garbled list stage"
  assert_marker 'JSM_CAUSE=output-unavailable' "garbled list cause"
done

# One failed skill does not stop the rest; its exit and cause are kept.
reset_fixture
set_updates skill-a skill-b
printf 'upgrade failed\n' >"$FIXTURE/upgrade-skill-a.stderr"
printf '47\n' >"$FIXTURE/upgrade-skill-a.rc"
run_wrapper upgrade-failed
assert_rc 47 "upgrade failure"
assert_calls "upgrade failure still updates the next skill" "$LIST" "$CONFIG" 'upgrade skill-a' 'upgrade skill-b'
assert_marker 'JSM_STAGE=upgrade' "upgrade failure stage"
assert_marker 'JSM_CAUSE=stage-failed' "upgrade failure cause"

# Pinned skills are left to their pin.
reset_fixture
set_updates skill-a skill-p:pinned
run_wrapper pinned
assert_rc 0 "pinned skill"
assert_calls "pinned skill is not upgraded" "$LIST" "$CONFIG" 'upgrade skill-a'
if grep -qxF 'jsm-auto-update: pinned, not updated: skill-p (unpin to update)' "$LAST_OUTPUT"; then ok
else bad "pinned skill is not named in the journal"; fi
if grep -qxF 'jsm-auto-update: 1 skill update(s) available: skill-a' "$LAST_OUTPUT"; then ok
else bad "pinned skill counted as an available update"; fi

# A pinned skill alone, as jsm lists it tonight: named, and nothing else runs.
reset_fixture
set_updates skill-p:pinned
run_wrapper pinned-only
assert_rc 0 "pinned-only"
assert_calls "pinned-only makes no further calls" "$LIST"
if grep -qxF 'jsm-auto-update: pinned, not updated: skill-p (unpin to update)' "$LAST_OUTPUT"; then ok
else bad "pinned-only skill is not named in the journal"; fi

# A pin wins even if jsm ever flags the pinned skill as updatable.
reset_fixture
set_updates skill-a skill-q:pinned-updatable
run_wrapper pinned-updatable
assert_rc 0 "pinned-updatable"
assert_calls "pinned-updatable skill is not upgraded" "$LIST" "$CONFIG" 'upgrade skill-a'
if grep -qxF 'jsm-auto-update: pinned, not updated: skill-q (unpin to update)' "$LAST_OUTPUT"; then ok
else bad "pinned-updatable skill is not named in the journal"; fi

# A name that is not a plain skill name never reaches jsm or a path.
reset_fixture
set_updates skill-a ../escape @everyone Skill_A
run_wrapper unsafe-names
assert_rc 1 "unsafe names fail the run"
assert_calls "unsafe names are skipped" "$LIST" "$CONFIG" 'upgrade skill-a'
if grep -Eq 'escape|everyone|Skill_A' "$LAST_OUTPUT"; then bad "unsafe name echoed to the journal"; else ok; fi
assert_marker 'JSM_CAUSE=reported-failure' "unsafe names cause"

# JSM's false-green shape: an anchored Failed: heading with rc 0 is failure.
reset_fixture
set_updates skill-a
printf 'summary\n  Failed:  \n' >"$FIXTURE/upgrade-skill-a.stdout"
run_wrapper printed-failure
assert_rc 1 "printed Failed heading"
assert_marker 'JSM_STAGE=upgrade' "printed failure stage"
assert_marker 'JSM_CAUSE=reported-failure' "printed failure cause"
assert_marker 'JSM_SKILLS=' "printed failure has no invented skills"

# Failed: lookalikes are not failures.
reset_fixture
set_updates skill-a
printf 'Failed: 2 overlay updates require review\n' >"$FIXTURE/upgrade-skill-a.stdout"
run_wrapper lookalike
assert_rc 0 "Failed: lookalike"

# Preserve the known non-TTY cause without forwarding arbitrary JSM output.
reset_fixture
set_updates skill-a
cat >"$FIXTURE/upgrade-skill-a.stdout" <<'OUT'
https://discord.invalid/private-token
Failed:
  skill-z - User prompt error: IO error: not a terminal
  skill-a - User prompt error: IO error: not a terminal
  skill-z - User prompt error: IO error: not a terminal
OUT
printf '47\n' >"$FIXTURE/upgrade-skill-a.rc"
run_wrapper prompt-failure
assert_rc 47 "prompt failure keeps real exit"
cat >"$TMP/prompt-marker.expected" <<'OUT'
MESSAGE_ID=8e4f3a61b7c24df0a9d6502e1384c5ab
JSM_INVOCATION_ID=282b9a9bf6eb486aaa4dc81424feb4db
JSM_STAGE=upgrade
JSM_CAUSE=manual-attention
JSM_SKILLS=skill-a,skill-z
MESSAGE=JSM maintenance failed; manual review is required.
OUT
assert_text "$TMP/prompt-marker.expected" "$MARKER" "closed-vocabulary prompt marker"

reset_fixture
set_updates skill-a
printf 'Failed:\nskill-a - User prompt error: IO error: not a terminal\n' >"$FIXTURE/upgrade-skill-a.stdout"
run_wrapper unindented-prompt-failure
assert_rc 1 "unindented prompt failure stays failed"
assert_marker 'JSM_CAUSE=manual-attention' "unindented prompt failure cause"
assert_marker 'JSM_SKILLS=skill-a' "unindented affected skill"

# The live v0.3.22 failure list uses bullets, unlike the plain-name fixtures.
reset_fixture
set_updates skill-a
cat >"$FIXTURE/upgrade-skill-a.stdout" <<'OUT'
Failed:
  • mock-code-finder - User prompt error: IO error: not a terminal
  • security-audit-for-saas - User prompt error: IO error: not a terminal
  • @everyone - User prompt error: IO error: not a terminal
  • ../private-token - User prompt error: IO error: not a terminal
OUT
run_wrapper bulleted-prompt-failure
assert_rc 1 "bulleted prompt failure stays failed"
assert_marker 'JSM_CAUSE=manual-attention' "live bulleted prompt failure cause"
assert_marker 'JSM_SKILLS=mock-code-finder,security-audit-for-saas' "live bulleted affected skills exclude unsafe names"

# The public marker contains at most eight sorted names, never unchecked text.
reset_fixture
set_updates skill-a
printf 'Failed:\n' >"$FIXTURE/upgrade-skill-a.stdout"
for skill in skill-i skill-h skill-g skill-f skill-e skill-d skill-c skill-b skill-a skill-a; do
  printf '  %s - User prompt error: IO error: not a terminal\n' "$skill" >>"$FIXTURE/upgrade-skill-a.stdout"
done
cat >>"$FIXTURE/upgrade-skill-a.stdout" <<'OUT'
  ../private-token - User prompt error: IO error: not a terminal
  @everyone - User prompt error: IO error: not a terminal
  skill_A - User prompt error: IO error: not a terminal
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa - User prompt error: IO error: not a terminal
  skill-secret - https://discord.invalid/private-token
OUT
run_wrapper bounded-names
assert_rc 1 "bounded summary keeps false-green failure"
assert_marker 'JSM_SKILLS=skill-a,skill-b,skill-c,skill-d,skill-e,skill-f,skill-g,skill-h' "bounded validated skill names"
if grep -Eq 'private-token|everyone|skill_A|skill-secret|aaaaaaaaa' "$MARKER"; then
  bad "unchecked JSM content escaped into marker"
else ok; fi

reset_fixture
set_updates skill-a
printf 'Failed:\n  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa - User prompt error: IO error: not a terminal\n' >"$FIXTURE/upgrade-skill-a.stdout"
run_wrapper max-name
assert_marker 'JSM_SKILLS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "64-byte skill name"

# Prompt text outside the failure section cannot manufacture this cause.
reset_fixture
set_updates skill-a
cat >"$FIXTURE/upgrade-skill-a.stdout" <<'OUT'
  skill-before - User prompt error: IO error: not a terminal
Failed:
  skill-a - unrelated failure
Finished:
  skill-after - User prompt error: IO error: not a terminal
OUT
run_wrapper unrelated-prompt
assert_marker 'JSM_CAUSE=reported-failure' "prompt text outside failure section"
assert_marker 'JSM_SKILLS=' "unrelated prompt has no affected skills"

# An overlay skill whose update leaves every overlaid file alone is reinstalled
# over our copies (skills-localize.sh puts them back), never plain-upgraded.
reset_fixture
set_updates ov-skill
set_diff ov-skill '["references/NEW.md"]' '[]' '["references/OTHER.md","GUIDE.md"]'
run_wrapper overlay-safe
assert_rc 0 "untouched overlay skill"
assert_calls "untouched overlay skill is force-installed" "$LIST" "$CONFIG" 'diff ov-skill --json' 'install ov-skill --force'
assert_no_marker "untouched overlay skill"

# An update that changes or removes a file we overlay is held, not failed:
# laying our copy back would throw the upstream change away.
for touched in modified removed; do
  reset_fixture
  set_updates ov-skill skill-a
  if [ "$touched" = modified ]; then
    set_diff ov-skill '[]' '[]' '["references/GUIDE.md","SKILL.md","references/OTHER.md"]'
    held_files='SKILL.md references/GUIDE.md'
  else
    set_diff ov-skill '[]' '["references/GUIDE.md"]' '[]'
    held_files='references/GUIDE.md'
  fi
  run_wrapper "overlay-held-$touched"
  assert_rc 0 "overlay skill held ($touched)"
  assert_calls "held overlay skill is neither installed nor upgraded ($touched)" \
    "$LIST" "$CONFIG" 'diff ov-skill --json' 'upgrade skill-a'
  if grep -qxF "jsm-auto-update: held ov-skill (v6 to v12): the update changes $held_files, which skills-patches/ov-skill replaces; rebase the overlay onto v12, merge it, then run jsm install ov-skill --version 12 --force and skills-localize.sh apply (the rebase alone never releases the hold), or retire the skill" "$LAST_OUTPUT"; then ok
  else bad "held overlay skill is not reported in plain words ($touched)"; fi
  assert_no_marker "held overlay skill ($touched)"
done

# A failed diff decides nothing, so nothing is installed.
reset_fixture
set_updates ov-skill
printf '9\n' >"$FIXTURE/diff-ov-skill.rc"
run_wrapper overlay-diff-failed
assert_rc 9 "overlay diff failure"
assert_calls "failed diff installs nothing" "$LIST" "$CONFIG" 'diff ov-skill --json'
assert_marker 'JSM_CAUSE=stage-failed' "overlay diff failure cause"

# A diff of an unexpected shape could hide an overlaid file, so it fails too.
for shape in '{"added":[],"removed":[],"modified":[{"path":"SKILL.md"}]}' '{"modified":["references/OTHER.md"]}' 'not json'; do
  reset_fixture
  set_updates ov-skill
  printf '%s\n' "$shape" >"$FIXTURE/diff-ov-skill.stdout"
  run_wrapper overlay-diff-shape
  assert_rc 1 "unexpected diff shape"
  assert_calls "unexpected diff shape installs nothing" "$LIST" "$CONFIG" 'diff ov-skill --json'
  assert_marker 'JSM_CAUSE=output-unavailable' "unexpected diff shape cause"
done

# Python bytecode in a pending skill is cleared in every tree before jsm sees
# it; other skills, and a skill dir that is a symlink, are left alone.
reset_fixture
set_updates skill-a linked-skill
mkdir -p "$TREES/claude/skill-a/scripts/__pycache__" "$TREES/codex/skill-a/__pycache__" \
  "$TREES/claude/other-skill/__pycache__" "$TMP/outside/linked-skill/__pycache__"
touch "$TREES/claude/skill-a/scripts/__pycache__/x.pyc" "$TREES/claude/skill-a/scripts/run.py"
ln -s "$TMP/outside/linked-skill" "$TREES/claude/linked-skill"
run_wrapper bytecode
assert_rc 0 "bytecode cleared before upgrade"
if [ ! -e "$TREES/claude/skill-a/scripts/__pycache__" ] && [ ! -e "$TREES/codex/skill-a/__pycache__" ]; then ok
else bad "pending skill kept its bytecode cache"; fi
if [ -f "$TREES/claude/skill-a/scripts/run.py" ]; then ok; else bad "bytecode cleanup removed a source file"; fi
if [ -d "$TREES/claude/other-skill/__pycache__" ]; then ok; else bad "cleanup touched a skill with no pending update"; fi
if [ -d "$TMP/outside/linked-skill/__pycache__" ]; then ok; else bad "cleanup followed a symlinked skill dir"; fi
rm -rf "$TMP/outside"

# The overlay set is found through the ~/.claude/scripts symlink the unit runs.
mkdir -p "$TMP/install/scripts" "$TMP/install/skills-patches/ov-skill" "$TMP/home/.claude/scripts"
cp "$WRAPPER" "$TMP/install/scripts/"
printf 'ours\n' >"$TMP/install/skills-patches/ov-skill/SKILL.md"
ln -s "$TMP/install/scripts/jsm-auto-update-wrapper.sh" "$TMP/home/.claude/scripts/jsm-auto-update-wrapper.sh"
reset_fixture
set_updates ov-skill
set_diff ov-skill '[]' '[]' '["SKILL.md"]'
LAST_OUTPUT=$TMP/symlinked.output
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
  env -u JSM_SKILLS_PATCHES "$TMP/home/.claude/scripts/jsm-auto-update-wrapper.sh" >"$LAST_OUTPUT" 2>&1
LAST_RC=$?
assert_rc 0 "symlinked wrapper"
assert_calls "symlinked wrapper finds the tracked overlay set" "$LIST" "$CONFIG" 'diff ov-skill --json'
if grep -qF 'no overlay directory' "$LAST_OUTPUT"; then bad "a present overlay set warned as missing"; else ok; fi

# A missing overlay set still upgrades, plainly, and says so (#42).
reset_fixture
set_updates ov-skill
LAST_OUTPUT=$TMP/no-overlay.output
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
  JSM_SKILLS_PATCHES="$TMP/no-such-overlay" "$WRAPPER" >"$LAST_OUTPUT" 2>&1
LAST_RC=$?
assert_rc 0 "missing overlay set"
assert_calls "missing overlay set upgrades the skill plainly" "$LIST" "$CONFIG" 'upgrade ov-skill'
if grep -qF "jsm-auto-update: warning: no overlay directory at $TMP/no-such-overlay" "$LAST_OUTPUT"; then ok
else bad "missing overlay set gave no warning"; fi

# No marker may carry an absent, malformed, or injectable invocation ID.
for invocation in '' unknown $'282b9a9bf6eb486aaa4dc81424feb4db\nJSM_CAUSE=manual-attention'; do
  reset_fixture
  printf '23\n' >"$FIXTURE/list.rc"
  INVOCATION_ID="$invocation" run_wrapper invalid-invocation
  assert_rc 23 "invalid invocation keeps failure exit"
  assert_no_marker "invalid invocation"
done

# tee failure must remain a service failure, even when JSM itself succeeds.
reset_fixture
set_updates skill-a skill-b
FAKE_TEE_RC=34 run_wrapper tee-failure
assert_rc 34 "tee failure exit"
assert_calls "tee failure still updates the next skill" "$LIST" "$CONFIG" 'upgrade skill-a' 'upgrade skill-b'
assert_marker 'JSM_CAUSE=output-unavailable' "tee failure cause"

# A real JSM error wins over tee's exit, but incomplete output is never parsed.
reset_fixture
set_updates skill-a
printf 'Failed:\n  skill-a - User prompt error: IO error: not a terminal\n' >"$FIXTURE/upgrade-skill-a.stdout"
printf '23\n' >"$FIXTURE/upgrade-skill-a.rc"
FAKE_TEE_RC=34 run_wrapper jsm-and-tee-failure
assert_rc 23 "JSM exit wins over tee exit"
assert_marker 'JSM_CAUSE=output-unavailable' "failed capture is not trusted"
assert_marker 'JSM_SKILLS=' "failed capture has no skill claim"

reset_fixture
set_updates skill-a
FAKE_REMOVE_CAPTURE=1 run_wrapper scan-failure
assert_rc 2 "unreadable capture exit"
assert_marker 'JSM_CAUSE=output-unavailable' "unreadable capture cause"

# An unavailable journal must not replace the real failure, or hang the unit.
reset_fixture
printf '23\n' >"$FIXTURE/list.rc"
FAKE_LOGGER_RC=72 run_wrapper logger-failure
assert_rc 23 "failed journal write keeps real exit"
if grep -qxF 'jsm-auto-update: failure summary could not be written to journal' "$LAST_OUTPUT"; then
  ok
else bad "failed journal write has no local diagnostic"; fi
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" JSM_BIN="$FAKE_JSM" JSM_SKILLS_PATCHES="$PATCHES" \
  FAKE_LOGGER_HANG=1 timeout 4 "$WRAPPER" >"$TMP/logger-hang.output" 2>&1
LAST_RC=$?
assert_rc 23 "hung journal write is bounded and keeps real exit"

# The first line must arrive while JSM is still running, before we release it.
reset_fixture
set_updates skill-a
printf 'first streamed line\n' >"$FIXTURE/upgrade-skill-a.stdout"
LAST_OUTPUT=$TMP/streaming.output
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
  JSM_SKILLS_PATCHES="$PATCHES" FAKE_STREAM_KEY=upgrade-skill-a \
  FAKE_STREAM_GATE="$TMP/stream-gate" "$WRAPPER" >"$LAST_OUTPUT" 2>&1 &
stream_pid=$!
stream_seen=0
for ((attempt=0; attempt<100; attempt++)); do
  if grep -qxF 'first streamed line' "$LAST_OUTPUT" && kill -0 "$stream_pid" 2>/dev/null; then
    stream_seen=1
    break
  fi
  sleep 0.01
done
if [ "$stream_seen" -eq 1 ]; then ok; else bad "JSM output was withheld until exit"; fi
: >"$TMP/stream-gate"
wait "$stream_pid"
LAST_RC=$?
assert_rc 0 "streaming handshake completes"

# The unit must PAGE on failure (issue #1215). It had no OnFailure= and no
# "NO OnFailure= ON PURPOSE" rationale, which cost five silent nightly failures
# (Sep 15-19 2026, exit 1 at 03:00). jsm's own installer owns the .service file,
# so the wire has to live in the tracked drop-in or an installer rewrite drops it.
DROPIN=$CLAUDE_DIR/systemd/jsm-auto-update.service.d/override.conf
if [ -f "$DROPIN" ]; then ok; else bad "tracked drop-in missing at $DROPIN"; fi
if [ "$(grep -cFx 'OnFailure=harness-unit-failure-alert@%n.service' "$DROPIN")" = 1 ]; then ok
else bad "drop-in does not carry exactly one OnFailure= wire — the unit can fail silently again"; fi
# Inert unless it sits under [Unit]: systemd ignores OnFailure= in [Service]
# without erroring, which looks identical to a correct file.
if awk '/^\[Unit\]/{u=1;next} /^\[/{u=0} u && /^OnFailure=/{f=1} END{exit !f}' "$DROPIN"; then ok
else bad "OnFailure= is not under [Unit] — systemd silently ignores it there"; fi
# The drop-in must still carry the wrapper override it was created for.
if grep -qF 'jsm-auto-update-wrapper.sh' "$DROPIN"; then ok
else bad "drop-in lost its ExecStart= override — the vendor's deadlocking auto-update path would return"; fi

assertion_floor=111
assertion_total=$((pass + fail))
if [ "$assertion_total" -lt "$assertion_floor" ]; then
  bad "assertion floor: ran $assertion_total, expected at least $assertion_floor"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — jsm auto-update wrapper: $pass/$((pass + fail)) assertions passed (floor $assertion_floor)"
else
  echo "FAIL — jsm auto-update wrapper: $fail of $((pass + fail)) assertions failed (floor $assertion_floor)" >&2
  exit 1
fi
