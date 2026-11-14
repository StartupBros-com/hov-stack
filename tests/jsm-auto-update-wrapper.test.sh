#!/usr/bin/env bash
# Hermetic contract tests for the tracked JSM nightly update wrapper.
set -uo pipefail

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER=$CLAUDE_DIR/scripts/jsm-auto-update-wrapper.sh
[ -x "$WRAPPER" ] || { echo "FAIL: executable wrapper not found at $WRAPPER" >&2; exit 1; }

TMP=$(mktemp -d /tmp/jsm-wrapper-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMPDIR=$TMP
FIXTURE=$TMP/fixture
CALLS=$TMP/calls.log
MARKER=$TMP/marker
FAKE_JSM=$TMP/fake-jsm
LOC_CALLS=$TMP/localize-calls.log
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

# skills-localize.sh stand-in: logs each call, replays unapply-<skill>.stdout
# and .rc from the fixture (empty and 0 when absent), and on 0 takes the
# skill's LAYERED file away, which the fake jsm below refuses to upgrade over.
# Exported with the state path, so no run reaches the real script or its state.
cat >"$TMP/bin/localize" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_LOC_CALLS:?}"
[ "$#" -eq 2 ] && [ "$1" = unapply ] || exit 64
if [ -n "${FAKE_LOCK_LOG:-}" ]; then
  fd=${SKILLS_LOCALIZE_LOCK_FD:-none} on=fd-not-on-lock held=unlocked
  [ "$fd" = none ] || [ ! /proc/self/fd/"$fd" -ef "$SKILLS_LOCALIZE_STATE/.lock" ] || on=fd-on-lock
  flock -n -x "$SKILLS_LOCALIZE_STATE/.lock" true 2>/dev/null || held=locked
  printf 'unapply %s %s %s\n' "$2" "$on" "$held" >>"$FAKE_LOCK_LOG"
fi
F=${FAKE_FIXTURE:?}
[ ! -f "$F/unapply-$2.stdout" ] || cat "$F/unapply-$2.stdout"
rc=0
[ ! -f "$F/unapply-$2.rc" ] || rc=$(cat "$F/unapply-$2.rc")
[ "$rc" -ne 0 ] || rm -f "${FAKE_TREES:-/nonexistent}"/*/"$2"/LAYERED
exit "$rc"
STUB
chmod +x "$TMP/bin/localize"
export FAKE_LOC_CALLS="$LOC_CALLS" JSM_LOCALIZE="$TMP/bin/localize" \
  SKILLS_LOCALIZE_STATE="$TMP/localize-state"

# The real localizer state must come out of this suite untouched.
real_state_sum() {
  local dir=${XDG_STATE_HOME:-$HOME/.local/state}/skills-localize
  if [ -e "$dir" ]; then
    find "$dir" -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort | sha256sum
  else
    echo absent
  fi
}
REAL_STATE_BEFORE=$(real_state_sum)

# Answers only the calls the wrapper makes, logs each one, and replays
# <key>.stdout/.stderr/.rc from the fixture (empty and 0 when absent). Like jsm
# 0.3.36 it refuses an upgrade, with rc 0 and a Failed: block, when the skill
# carries __pycache__ or a LAYERED file (our layer still on) in any tree.
cat >"$FAKE_JSM" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_CALLS:?}"
case "$#:$*" in
  '3:upgrade --list --json') key=list ;;
  '3:config show --json') key=config ;;
  2:upgrade\ *) key=upgrade-$2 ;;
  3:install\ *\ --force) key=install-$2 ;;
  *) exit 64 ;;
esac
F=${FAKE_FIXTURE:?}
if [ -n "${FAKE_LOCK_LOG:-}" ] && { [ "$key" = "upgrade-$2" ] || [ "$key" = "install-$2" ]; }; then
  fd8=fd8-closed held=unlocked
  [ ! -e /proc/self/fd/8 ] || fd8=fd8-open
  flock -n -x "${SKILLS_LOCALIZE_STATE:?}/.lock" true 2>/dev/null || held=locked
  printf 'jsm %s %s %s\n' "$key" "$fd8" "$held" >>"$FAKE_LOCK_LOG"
fi
if [ "$key" = "upgrade-$2" ] && [ -n "${FAKE_TREES:-}" ] &&
  find "$FAKE_TREES"/*/"$2" \( -name __pycache__ -o -name LAYERED \) 2>/dev/null | grep -q .; then
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

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

reset_fixture() {
  : >"$CALLS"
  : >"$MARKER"
  : >"$LOC_CALLS"
  rm -rf "$FIXTURE" "$TREES" "$TMP/localize-state"
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

run_wrapper() {
  local name=$1
  LAST_OUTPUT=$TMP/$name.output
  FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
    "$WRAPPER" >"$LAST_OUTPUT" 2>&1
  LAST_RC=$?
}

run_wrapper_default() {
  local name=$1
  LAST_OUTPUT=$TMP/$name.output
  FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" HOME="$TMP/home" \
    env -u JSM_BIN "$WRAPPER" >"$LAST_OUTPUT" 2>&1
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

assert_line() {
  if grep -qxF -- "$1" "$LAST_OUTPUT"; then ok; else bad "$2: missing line: $1"; fi
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

# Our local layer comes off every pending skill before jsm sees it, so a
# localized skill upgrades by name like any other (dotfiles#2091). The fake jsm
# refuses a skill that still carries LAYERED, so an upgrade run before the
# unapply fails this case.
reset_fixture
set_updates ov-skill skill-a
mkdir -p "$TREES/claude/ov-skill" "$TREES/codex/ov-skill"
: >"$TREES/claude/ov-skill/LAYERED"
: >"$TREES/codex/ov-skill/LAYERED"
run_wrapper layer-off
assert_rc 0 "localized skill upgrades"
assert_calls "localized skill is upgraded by name" "$LIST" "$CONFIG" 'upgrade ov-skill' 'upgrade skill-a'
printf '%s\n' 'unapply ov-skill' 'unapply skill-a' >"$TMP/loc.expected"
assert_text "$TMP/loc.expected" "$LOC_CALLS" "every pending skill is unapplied, once, by name"
if [ ! -e "$TREES/claude/ov-skill/LAYERED" ] && [ ! -e "$TREES/codex/ov-skill/LAYERED" ]; then ok
else bad "the layer was still on when jsm ran"; fi
assert_no_marker "localized skill upgrades"
if grep -Eq 'held|jsm diff' "$LAST_OUTPUT"; then bad "the hold path is back"; else ok; fi

# The skills-localize lock is held from each unapply until jsm has written, so no
# dotup apply lands in between: the unapply reuses the held lock through
# SKILLS_LOCALIZE_LOCK_FD, jsm runs without the fd, and the lock is free after.
reset_fixture
set_updates ov-skill ov2
printf '3\n' >"$FIXTURE/unapply-ov2.rc"
: >"$TMP/lock.log"
FAKE_LOCK_LOG="$TMP/lock.log" run_wrapper layer-lock
assert_rc 0 "layer lock"
printf '%s\n' 'unapply ov-skill fd-on-lock locked' 'jsm upgrade-ov-skill fd8-closed locked' \
  'unapply ov2 fd-on-lock locked' 'jsm install-ov2 fd8-closed locked' >"$TMP/lock.expected"
assert_text "$TMP/lock.expected" "$TMP/lock.log" "the lock is held from each unapply until jsm has written"
if flock -n -x "$TMP/localize-state/.lock" true; then ok; else bad "the wrapper left the skills-localize lock held"; fi

# A layer still on when jsm runs (an unapply that put nothing back) makes jsm
# refuse that skill, and the night fails, not passes.
cat >"$TMP/bin/localize-noop" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOC_CALLS"
STUB
chmod +x "$TMP/bin/localize-noop"
reset_fixture
set_updates ov-skill
mkdir -p "$TREES/claude/ov-skill"
: >"$TREES/claude/ov-skill/LAYERED"
JSM_LOCALIZE="$TMP/bin/localize-noop" run_wrapper layer-left-on
assert_rc 1 "layer left on"
assert_calls "layer left on: jsm is asked and refuses" "$LIST" "$CONFIG" 'upgrade ov-skill'
assert_marker 'JSM_CAUSE=reported-failure' "layer left on cause"

# No saved pristine copy (exit 3): only a forced install restores pristine, and
# ExecStopPost merges the overlay back afterwards. Not a failure.
reset_fixture
set_updates ov-skill
printf '3\n' >"$FIXTURE/unapply-ov-skill.rc"
printf 'unrecorded: claude ov-skill has an overlay but no saved pristine copy\n' >"$FIXTURE/unapply-ov-skill.stdout"
run_wrapper layer-unrecorded
assert_rc 0 "unrecorded layer"
assert_calls "unrecorded layer is force-installed" "$LIST" "$CONFIG" 'install ov-skill --force'
assert_line 'unrecorded: claude ov-skill has an overlay but no saved pristine copy' "unapply output reaches the journal"
assert_line 'jsm-auto-update: ov-skill has no pristine copy to put back; reinstalling it with --force' "unrecorded layer"
assert_no_marker "unrecorded layer"

# A hand edit (exit 4) is a person's call: jsm never touches that skill, the
# other skills still update, and the night fails with the recipe in the journal.
reset_fixture
set_updates ov-skill skill-a
printf '4\n' >"$FIXTURE/unapply-ov-skill.rc"
printf 'hand-edited claude ov-skill/SKILL.md\n' >"$FIXTURE/unapply-ov-skill.stdout"
run_wrapper layer-hand-edited
assert_rc 1 "hand-edited layer fails the night"
assert_calls "a hand-edited skill never reaches jsm; the others still update" "$LIST" "$CONFIG" 'upgrade skill-a'
assert_line 'hand-edited claude ov-skill/SKILL.md' "the hand-edited file is named"
assert_line 'jsm-auto-update: ov-skill was not updated: a file above was edited by hand after skills-localize wrote it; to discard the edit run skills-localize.sh forget ov-skill, jsm install ov-skill --force, then skills-localize.sh apply' "hand edit recipe"
assert_marker 'JSM_STAGE=upgrade' "hand-edited stage"
assert_marker 'JSM_CAUSE=reported-failure' "hand-edited cause"

# A damaged saved pristine copy (exit 5, hov-stack#593) is a person's call too:
# there is no pristine to put back, so jsm never touches that skill.
reset_fixture
set_updates ov-skill skill-a
printf '5\n' >"$FIXTURE/unapply-ov-skill.rc"
printf 'damaged: the saved pristine copy of agents ov-skill/SKILL.md is not the file apply saved; not restoring it\n' >"$FIXTURE/unapply-ov-skill.stdout"
run_wrapper layer-damaged
assert_rc 1 "damaged saved copy fails the night"
assert_calls "a skill with a damaged saved copy never reaches jsm; the others still update" "$LIST" "$CONFIG" 'upgrade skill-a'
assert_line 'damaged: the saved pristine copy of agents ov-skill/SKILL.md is not the file apply saved; not restoring it' "the damaged copy is named"
assert_line 'jsm-auto-update: ov-skill was not updated: its saved pristine copy above is damaged, so there is nothing to put back; run skills-localize.sh forget ov-skill, jsm install ov-skill --force, then skills-localize.sh apply' "damaged copy recipe"
assert_marker 'JSM_CAUSE=reported-failure' "damaged copy cause"
assert_marker 'JSM_STAGE=upgrade' "damaged copy stage"

# Any other exit, or no localizer at all, decides nothing: that skill is not
# updated and the first such exit becomes the unit's.
for case_rc in 2 127; do
  reset_fixture
  set_updates ov-skill skill-a
  if [ "$case_rc" -eq 2 ]; then
    printf '2\n' >"$FIXTURE/unapply-ov-skill.rc"
    run_wrapper layer-unapply-error
    expected_calls=('upgrade skill-a')
  else
    JSM_LOCALIZE="$TMP/no-such-localizer" run_wrapper layer-missing-localizer
    expected_calls=()
  fi
  assert_rc "$case_rc" "unapply exit $case_rc"
  assert_calls "unapply exit $case_rc: that skill never reaches jsm" "$LIST" "$CONFIG" "${expected_calls[@]}"
  assert_line "jsm-auto-update: ov-skill was not updated: skills-localize.sh unapply exited $case_rc" "unapply exit $case_rc"
  assert_marker 'JSM_CAUSE=stage-failed' "unapply exit $case_rc cause"
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

# The localizer is the skills-localize.sh beside the wrapper's real path, found
# through the ~/.claude/scripts symlink the unit runs. A stand-in sits there, so
# the real script never runs here.
mkdir -p "$TMP/install/scripts" "$TMP/home/.claude/scripts"
cp "$WRAPPER" "$TMP/install/scripts/"
cat >"$TMP/install/scripts/skills-localize.sh" <<'STUB'
#!/usr/bin/env bash
printf 'beside %s\n' "$*" >>"$FAKE_LOC_CALLS"
STUB
chmod +x "$TMP/install/scripts/skills-localize.sh"
ln -s "$TMP/install/scripts/jsm-auto-update-wrapper.sh" "$TMP/home/.claude/scripts/jsm-auto-update-wrapper.sh"
reset_fixture
set_updates ov-skill
LAST_OUTPUT=$TMP/symlinked.output
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
  env -u JSM_LOCALIZE "$TMP/home/.claude/scripts/jsm-auto-update-wrapper.sh" >"$LAST_OUTPUT" 2>&1
LAST_RC=$?
assert_rc 0 "symlinked wrapper"
assert_calls "symlinked wrapper upgrades after the unapply" "$LIST" "$CONFIG" 'upgrade ov-skill'
printf 'beside unapply ov-skill\n' >"$TMP/loc.expected"
assert_text "$TMP/loc.expected" "$LOC_CALLS" "symlinked wrapper finds skills-localize.sh beside its real path"

# Files where an overlay kept our side of a conflict (skills-localize state)
# go to the journal every night; malformed lines are dropped, more than 20 are
# counted, and no file means no line.
reset_fixture
mkdir -p "$TMP/localize-state"
printf '%s\n' 'agents gh-cli/SKILL.md' 'claude gh-cli/SKILL.md' '@everyone x/y' 'claude ../escape/x' \
  'claude bad name/x' 'gemini gh-cli/SKILL.md' 'codex papers/scripts/workflow.py' >"$TMP/localize-state/conflicts"
run_wrapper conflicts
assert_rc 0 "conflicts"
assert_line 'jsm-auto-update: overlay conflicts, our side kept: agents gh-cli/SKILL.md; claude gh-cli/SKILL.md; codex papers/scripts/workflow.py' "nightly conflict line"
reset_fixture
mkdir -p "$TMP/localize-state"
for ((i=1; i<=22; i++)); do printf 'claude s%s/SKILL.md\n' "$i"; done >"$TMP/localize-state/conflicts"
run_wrapper conflicts-capped
assert_rc 0 "capped conflicts"
if grep -q '^jsm-auto-update: overlay conflicts, our side kept: claude s1/SKILL.md; .*claude s20/SKILL.md; and 2 more$' "$LAST_OUTPUT"; then ok
else bad "more than 20 conflicts are not capped and counted"; fi
if grep -q 's21/' "$LAST_OUTPUT"; then bad "conflict 21 printed past the cap"; else ok; fi
reset_fixture
run_wrapper conflicts-none
if grep -q 'overlay conflicts' "$LAST_OUTPUT"; then bad "a conflict line without a conflicts file"; else ok; fi

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
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" JSM_BIN="$FAKE_JSM" \
  FAKE_LOGGER_HANG=1 timeout 4 "$WRAPPER" >"$TMP/logger-hang.output" 2>&1
LAST_RC=$?
assert_rc 23 "hung journal write is bounded and keeps real exit"

# The first line must arrive while JSM is still running, before we release it.
reset_fixture
set_updates skill-a
printf 'first streamed line\n' >"$FIXTURE/upgrade-skill-a.stdout"
LAST_OUTPUT=$TMP/streaming.output
FAKE_CALLS="$CALLS" FAKE_FIXTURE="$FIXTURE" FAKE_TREES="$TREES" JSM_BIN="$FAKE_JSM" \
  FAKE_STREAM_KEY=upgrade-skill-a \
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

if [ "$(real_state_sum)" = "$REAL_STATE_BEFORE" ]; then ok
else bad "the real skills-localize state changed during this suite"; fi

assertion_floor=127
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
