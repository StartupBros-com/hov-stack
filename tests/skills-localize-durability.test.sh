#!/usr/bin/env bash
# Behaviour tests for the durability of skills-localize.sh's saved layer state
# (hov-stack#593): each saved pristine copy's own sha256 beside it, a damaged or
# missing copy reported as damage rather than as a merge conflict, unapply
# refusing to restore one, state saved without sums gaining them only once its
# copies reproduce the live files, sync before every rename, and checked copies
# into the working directory. A stubbed sync proves the calls and their order
# and that a failed one keeps the old state; no test here can simulate a crash.
# Runs the real script against fixture trees with every path pinned into a temp dir.
set -uo pipefail
unset HOV_STACK_OVERLAY XDG_CONFIG_HOME
export CODEX_SKILLS_HOST_LIST="" RETIRED_SKILLS_HOST_LIST="" SKILL_PLUGINS_LIST=""

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$CLAUDE_DIR/scripts/skills-localize.sh
[ -x "$SCRIPT" ] || { echo "FAIL: executable skills-localize.sh not found at $SCRIPT" >&2; exit 1; }
command -v git >/dev/null || { echo "FAIL: git is required (git merge-file)" >&2; exit 1; }
REAL_SYNC=$(command -v sync) || { echo "FAIL: sync is required" >&2; exit 1; }
REAL_CP=$(command -v cp)

T=$(mktemp -d /tmp/skills-localize-durability.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

real_state_sum() {
  local dir=${XDG_STATE_HOME:-$HOME/.local/state}/skills-localize
  if [ -e "$dir" ]; then find "$dir" -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort | sha256sum
  else echo absent; fi
}
REAL_STATE_BEFORE=$(real_state_sum)
REAL_HOME=$HOME REAL_XDG=${XDG_STATE_HOME:-}

if grep -q '^zzd-' "$CLAUDE_DIR/retired-skills.txt" 2>/dev/null; then
  echo "FAIL: retired-skills.txt lists a zzd- name; rename the fixtures" >&2; exit 1
fi

mkdir -p "$T/bin" "$T/home" "$T/syncbin" "$T/failbin"
cat >"$T/bin/jsm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${JSM_CALLED:?}"
exit 1
STUB
chmod +x "$T/bin/jsm"
export PATH="$T/bin:$PATH" JSM_CALLED="$T/jsm-called" HOME="$T/home" XDG_STATE_HOME="$T/xdg" \
  SKILLS_DIR="$T/claude" CODEX_SKILLS_DIR="$T/codex" AGENTS_SKILLS_DIR="$T/agents" SKILLS_LOCAL_DIR="$T/local" \
  SKILLS_PATCHES_DIR="$T/patches" SKILLS_NOTE_FILE="$T/note.md" SKILLS_NOTE_FILE_CODEX="$T/note.codex.md" \
  CODEX_SKILLS_LIST="$T/codex-skills.txt" SKILLS_LOCALIZE_STATE="$T/state" SKILLS_LEGACY_LIST="$T/legacy.txt"
: >"$T/legacy.txt"
printf '%s\n' '> **Local tooling on this machine.** Track work in GitHub issues. (claude)' >"$T/note.md"
printf '%s\n' '> **Local tooling on this machine.** Track work in GitHub issues. (codex)' >"$T/note.codex.md"
: >"$T/codex-skills.txt"
C=$T/claude X=$T/codex A=$T/agents P=$T/patches S=$T/state U=$T/upstream
SC=$S/claude SA=$S/agents
SUMS=.skills-localize.sums
HEADER='# skills-localize pristine sha256 v1'

# sync stub: logs "<exists|gone> <path>" per argument, fails when an argument
# contains $SYNC_FAIL or equals $SYNC_FAIL_EXACT, else runs the real sync.
cat >"$T/syncbin/sync" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = -- ] && continue
  if [ -e "$a" ]; then printf 'exists %s\n' "$a"; else printf 'gone %s\n' "$a"; fi >>"${SYNC_LOG:?}"
  if [ -n "${SYNC_FAIL:-}" ] && [[ "$a" == *"$SYNC_FAIL"* ]]; then echo "sync: injected failure on $a" >&2; exit 1; fi
  if [ -n "${SYNC_FAIL_EXACT:-}" ] && [ "$a" = "$SYNC_FAIL_EXACT" ]; then echo "sync: injected failure on $a" >&2; exit 1; fi
done
exec "${REAL_SYNC:?}" "$@"
STUB
chmod +x "$T/syncbin/sync"
# cp stub: fails when the destination (last argument) matches the glob $FAIL_CP_GLOB.
cat >"$T/failbin/cp" <<'STUB'
#!/usr/bin/env bash
for last; do :; done
# shellcheck disable=SC2053
[[ "$last" != ${FAIL_CP_GLOB:?} ]] || { echo "cp: injected failure writing $last" >&2; exit 1; }
exec "${REAL_CP:?}" "$@"
STUB
chmod +x "$T/failbin/cp"

reset() {
  rm -rf "$C" "$X" "$A" "$P" "$S" "$U" "$T/local"
  mkdir -p "$C" "$X" "$A" "$P" "$U" "$T/local"
}
run() {
  OUT=$T/out.$1
  shift
  "$SCRIPT" "$@" >"$OUT" 2>&1
  RC=$?
}
# srun TAG FAIL-SUBSTRING ARGS... — run with the logging sync stub ("" fails nothing);
# a non-empty SYNC_EXACT also fails the sync of exactly that path.
SYNC_EXACT=""
srun() {
  local tag=$1 failon=$2
  shift 2
  : >"$T/sync.log"
  OUT=$T/out.$tag
  SYNC_LOG="$T/sync.log" SYNC_FAIL="$failon" SYNC_FAIL_EXACT="$SYNC_EXACT" REAL_SYNC="$REAL_SYNC" \
    PATH="$T/syncbin:$PATH" "$SCRIPT" "$@" >"$OUT" 2>&1
  RC=$?
}
# crun TAG GLOB ARGS... — run with every cp onto a destination matching GLOB failing.
crun() {
  local tag=$1 glob=$2
  shift 2
  OUT=$T/out.$tag
  FAIL_CP_GLOB="$glob" REAL_CP="$REAL_CP" PATH="$T/failbin:$PATH" "$SCRIPT" "$@" >"$OUT" 2>&1
  RC=$?
}

assert_rc() { if [ "$RC" -eq "$1" ]; then ok; else bad "$2: exit $RC, expected $1: $(head -c 600 "$OUT")"; fi; }
assert_same() { if cmp -s "$1" "$2"; then ok; else bad "$3: $1 differs from $2"; fi; }
assert_has() { if grep -qF -- "$1" "$OUT"; then ok; else bad "$2: output lacks: $1"; fi; }
assert_line() { if grep -qxF -- "$1" "$OUT"; then ok; else bad "$2: missing line: $1"; fi; }
assert_lacks() { if grep -qE -- "$1" "$OUT"; then bad "$2: output has /$1/: $(grep -E -- "$1" "$OUT" | head -3)"; else ok; fi; }
assert_exists() { if [ -e "$1" ]; then ok; else bad "$2: $1 does not exist"; fi; }
assert_gone() { if [ ! -e "$1" ]; then ok; else bad "$2: $1 still exists"; fi; }
sha() { sha256sum "$1" | awk '{print $1}'; }

skill_md() {
  local name=$1
  shift
  printf -- '---\nname: %s\ndescription: Fixture skill.\n---\n\n' "$name"
  printf '%s\n' "$@"
}
BASE_LINES=('line a' 'line b' 'line c' 'line d' 'line e' 'line f' 'line g')
lines_with() {
  local name=$1 l kv
  shift
  local out=()
  for l in "${BASE_LINES[@]}"; do
    for kv in "$@"; do [ "$l" = "${kv%%=*}" ] && l=${kv#*=}; done
    out+=("$l")
  done
  skill_md "$name" "${out[@]}"
}
install() { rm -rf "${1:?}/$2"; cp -r "$U/$2" "$1/$2"; }

# The de-slopify shape: upstream is still the overlay's base, so the live file is
# the overlay; an added overlay file (no base) has no pristine copy. zzd-up's
# upstream moved on, so its pristine copy differs from the base.
fixture() {
  reset
  mkdir -p "$P/zzd-ov/.base" "$P/zzd-ov/scripts" "$U/zzd-ov" "$P/zzd-up/.base" "$U/zzd-up"
  lines_with zzd-ov >"$P/zzd-ov/.base/SKILL.md"
  lines_with zzd-ov 'line b=line b OURS' >"$P/zzd-ov/SKILL.md"
  printf 'echo ours\n' >"$P/zzd-ov/scripts/extra.sh"
  lines_with zzd-ov >"$U/zzd-ov/SKILL.md"
  lines_with zzd-up >"$P/zzd-up/.base/SKILL.md"
  lines_with zzd-up 'line b=line b OURS' >"$P/zzd-up/SKILL.md"
  lines_with zzd-up 'line f=line f THEIRS' >"$U/zzd-up/SKILL.md"
  install "$C" zzd-ov; install "$A" zzd-ov
  install "$C" zzd-up; install "$A" zzd-up
}
# snap NAME — copy the live trees and the state aside, to prove a run changed nothing.
snap() { rm -rf "$T/snap.$1"; mkdir -p "$T/snap.$1"; cp -a "$C" "$A" "$S" "$T/snap.$1/"; }
same_as_snap() {
  if diff -r "$T/snap.$1/claude" "$C" >/dev/null && diff -r "$T/snap.$1/agents" "$A" >/dev/null &&
     diff -r "$T/snap.$1/state" "$S" >/dev/null; then ok
  else bad "$2: the trees or the state changed: $(diff -rq "$T/snap.$1/state" "$S" 2>&1 | head -3) $(diff -rq "$T/snap.$1/agents" "$A" 2>&1 | head -3)"; fi
}

# ---------------------------------------------------------------------------
# 1. apply saves each pristine copy's own sha256 beside it, one line per file
#    pristine had, after a header; a second run has nothing to record.
fixture
run apply apply
assert_rc 0 "first apply"
for lbl in claude agents; do
  for s in zzd-ov zzd-up; do
    f=$S/$lbl/pristine/$s/$SUMS
    if [ "$(head -1 "$f" 2>/dev/null)" = "$HEADER" ]; then ok; else bad "$lbl $s: sums file lacks its header"; fi
    want=$(printf 'SKILL.md\t%s' "$(sha "$U/$s/SKILL.md")")
    if [ "$(sed -n '2p' "$f")" = "$want" ] && [ "$(wc -l <"$f")" -eq 2 ]; then ok
    else bad "$lbl $s: sums should hold exactly the upstream SKILL.md hash: $(cat "$f" 2>&1)"; fi
  done
done
lines_with zzd-up 'line b=line b OURS' 'line f=line f THEIRS' >"$T/expect"
assert_same "$T/expect" "$A/zzd-up/SKILL.md" "the merge still lands"
if grep -q "^scripts/extra.sh	" "$SC/manifest/zzd-ov" && ! grep -q 'extra.sh' "$SC/pristine/zzd-ov/$SUMS"; then ok
else bad "an added file is in the manifest but has no pristine copy to sum"; fi
run dry --dry-run
assert_rc 0 "dry run after apply"
assert_lacks '^(would |ERROR:|DRIFT:|WARN:|conflict )' "a dry run after apply has nothing to do"
run check check
assert_rc 0 "check after apply"

# ---------------------------------------------------------------------------
# 2. A truncated saved copy (the 2026-11-14 crash) is damage, not a conflict:
#    apply, dry run and check name it and leave the skill alone; unapply exits 5
#    and restores nothing, in any tree; the good bytes put back clear it.
cp "$SA/pristine/zzd-ov/SKILL.md" "$T/good-copy"
: >"$SA/pristine/zzd-ov/SKILL.md"
snap trunc
DMG="ERROR: the saved pristine copy of agents zzd-ov/SKILL.md is damaged or missing ($SA/pristine/zzd-ov/SKILL.md is not the file apply saved) — zzd-ov left alone. To recover: skills-localize.sh forget zzd-ov && jsm install zzd-ov --force && skills-localize.sh apply"
UDMG="damaged: the saved pristine copy of agents zzd-ov/SKILL.md is not the file apply saved; not restoring it"
run trunc-apply apply
assert_rc 1 "apply with a damaged saved copy"
assert_line "$DMG" "apply names the damaged copy and the recovery"
assert_lacks '^conflict ' "a damaged copy is not reported as a merge conflict"
assert_lacks 'claude zzd-ov' "the intact claude tree is not reported"
same_as_snap trunc "apply leaves a skill with a damaged copy alone"
if [ ! -s "$S/conflicts" ]; then ok; else bad "the damage was recorded as a conflict: $(cat "$S/conflicts")"; fi
run trunc-dry --dry-run
assert_line "$DMG" "the dry run names the damaged copy"
assert_lacks '^(would localize|conflict )' "the dry run plans no write for it"
run trunc-check check
assert_rc 1 "check with a damaged saved copy"
assert_line "$DMG" "check names the damaged copy"
run trunc-unapply unapply zzd-ov
assert_rc 5 "unapply refuses a damaged saved copy"
assert_line "$UDMG" "unapply names it"
same_as_snap trunc "unapply changes nothing in any tree"
# Damage outranks a hand edit in another tree, as it does in apply: the recovery for
# damage also clears the edit.
printf 'a hand edit\n' >>"$C/zzd-ov/SKILL.md"
run trunc-unapply-edit unapply zzd-ov
assert_rc 5 "damage outranks a hand edit in unapply"
assert_line "hand-edited claude zzd-ov/SKILL.md" "the hand edit is still named"
assert_line "$UDMG" "and so is the damage"
"$REAL_CP" "$T/snap.trunc/claude/zzd-ov/SKILL.md" "$C/zzd-ov/SKILL.md"
same_as_snap trunc "unapply changed nothing but the hand edit, now undone"
run trunc-unapply-other unapply zzd-up
assert_rc 0 "unapply of another skill still works"
assert_same "$U/zzd-up/SKILL.md" "$A/zzd-up/SKILL.md" "the other skill's pristine copy goes back"
"$REAL_CP" "$T/good-copy" "$SA/pristine/zzd-ov/SKILL.md"
run repaired apply
assert_rc 0 "apply once the good bytes are back"
assert_lacks '^(ERROR:|DRIFT:|conflict )' "the repaired copy is clean again"

# ---------------------------------------------------------------------------
# 3. A missing saved copy, or a sums file with no line for it, is damage too.
fixture
run apply3 apply
mv "$SC/pristine/zzd-up/SKILL.md" "$T/moved-copy"
run missing apply
assert_rc 1 "apply with a missing saved copy"
assert_has 'ERROR: the saved pristine copy of claude zzd-up/SKILL.md is damaged or missing' "a missing copy is damage"
run missing-unapply unapply zzd-up
assert_rc 5 "unapply refuses a missing saved copy"
"$REAL_CP" "$T/moved-copy" "$SC/pristine/zzd-up/SKILL.md"
printf '%s\n' "$HEADER" >"$SC/pristine/zzd-up/$SUMS"
run nosum apply
assert_rc 1 "apply with a sums file that lacks the copy"
assert_has 'ERROR: the saved pristine copy of claude zzd-up/SKILL.md is damaged or missing' "an unsummed copy in a sums file is damage"

# ---------------------------------------------------------------------------
# 4. State without sums — saved before #593, or rewritten by an older copy of
#    the script, which replaces the pristine directory — is unchecked: check is
#    quiet, a dry run plans the recording, apply records the same sums, and a
#    second dry run has nothing left to record.
fixture
run apply4 apply
cp "$SC/pristine/zzd-ov/$SUMS" "$T/sums-before"
rm -f "$S"/*/pristine/*/"$SUMS"
run legacy-check check
assert_rc 0 "check with no sums"
assert_lacks 'sums' "check says nothing about missing sums"
run legacy-dry --dry-run
assert_rc 0 "dry run with no sums"
assert_line 'would record claude pristine sums: zzd-ov' "the dry run plans the claude recording"
assert_line 'would record agents pristine sums: zzd-up' "the dry run plans the agents recording"
assert_lacks '^(ERROR:|DRIFT:|conflict |would localize)' "no sums is not a problem"
run legacy-apply apply
assert_rc 0 "apply records the sums"
assert_line 'recorded claude pristine sums: zzd-ov' "apply says it recorded them"
assert_lacks '^(localized|restored|removed) ' "recording sums writes no live file"
assert_same "$T/sums-before" "$SC/pristine/zzd-ov/$SUMS" "the recorded sums match what a full write saves"
run legacy-dry2 --dry-run
assert_lacks '^would ' "nothing is left to record"

# 5. ... but without sums a copy shaped like crash damage (missing, empty, or
#    holding a NUL byte; no layered file is any of those) is still damage, and any
#    other wrong copy is never vouched for: it reads as the conflict it always did,
#    and no sums are recorded over it.
rm -f "$S"/*/pristine/*/"$SUMS"
cp "$SA/pristine/zzd-ov/SKILL.md" "$T/good-copy5"
cp "$A/zzd-ov/SKILL.md" "$T/live5"
: >"$SA/pristine/zzd-ov/SKILL.md"
run legacy-empty apply
assert_rc 1 "apply over an empty copy with no sums"
assert_line "$DMG" "an empty copy is damage even without sums"
assert_lacks '^(conflict \(agents\)|recorded agents pristine sums: zzd-ov)' "an empty copy is neither a conflict nor vouched for"
assert_same "$T/live5" "$A/zzd-ov/SKILL.md" "the live file is left alone"
assert_gone "$SA/pristine/zzd-ov/$SUMS" "no sums for the damaged copy"
run legacy-empty-unapply unapply zzd-ov
assert_rc 5 "unapply refuses an empty copy with no sums"
assert_line "$UDMG" "unapply names the empty copy"
truncate -s "$(wc -c <"$T/good-copy5")" "$SA/pristine/zzd-ov/SKILL.md"
run legacy-nul apply
assert_rc 1 "apply over a NUL-filled copy with no sums"
assert_line "$DMG" "a NUL-filled copy the size of the good one is damage"
head -c 20 "$T/good-copy5" >"$SA/pristine/zzd-ov/SKILL.md"
run legacy-short apply
assert_line 'conflict (agents): zzd-ov/SKILL.md — upstream changed lines the overlay also changes; kept our side' "a short copy with no sums still shows as a conflict"
assert_lacks '^recorded agents pristine sums: zzd-ov' "sums are not recorded over a copy that reproduces nothing"
assert_gone "$SA/pristine/zzd-ov/$SUMS" "the short copy stays unchecked"

# 5b. A note-only skill (no overlay; its markdown names the vocabulary) whose
#     unsummed saved copy came back empty: the copy is what apply would write live,
#     so trusting it would empty the live SKILL.md. It is damage instead.
fixture
mkdir -p "$U/zzd-note"
skill_md zzd-note 'Track work with beads.' >"$U/zzd-note/SKILL.md"
install "$C" zzd-note; install "$A" zzd-note
run apply5b apply
assert_rc 0 "apply with a note-only skill"
assert_line 'localized (agents): zzd-note/SKILL.md' "the note is layered on"
if grep -qF -- '> **Local tooling on this machine.**' "$A/zzd-note/SKILL.md"; then ok
else bad "the note-only skill did not get the note"; fi
cp "$A/zzd-note/SKILL.md" "$T/note-live"
rm -f "$S"/*/pristine/*/"$SUMS"
: >"$SA/pristine/zzd-note/SKILL.md"
run note-empty apply
assert_rc 1 "apply over a note-only skill's empty copy"
assert_has 'ERROR: the saved pristine copy of agents zzd-note/SKILL.md is damaged or missing' "the empty copy is named"
assert_same "$T/note-live" "$A/zzd-note/SKILL.md" "the live SKILL.md is not emptied"
run note-empty-unapply unapply zzd-note
assert_rc 5 "unapply refuses the note-only skill's empty copy"
assert_same "$T/note-live" "$A/zzd-note/SKILL.md" "unapply does not empty it either"

# ---------------------------------------------------------------------------
# 6. Every new state file, and the new directory, is synced before it is renamed
#    into place, the parent directories after, and the live file before the run
#    is done with it.
fixture
srun sync-apply "" apply
assert_rc 0 "apply with the logging sync"
for p in "$SA/pristine/.zzd-ov.new/SKILL.md" "$SA/pristine/.zzd-ov.new/$SUMS" \
         "$SA/pristine/.zzd-ov.new" "$SA/manifest/.zzd-ov.new"; do
  if grep -qxF "exists $p" "$T/sync.log"; then ok; else bad "not synced before its rename: $p"; fi
done
for p in "$SA/pristine" "$SA/manifest" "$SA/root" "$A/zzd-ov/SKILL.md" "$A/zzd-ov/scripts/extra.sh"; do
  if grep -qxF "exists $p" "$T/sync.log"; then ok; else bad "not synced: $p"; fi
done
state_at=$(grep -nxF "exists $SA/pristine/.zzd-ov.new/SKILL.md" "$T/sync.log" | head -1 | cut -d: -f1)
live_at=$(grep -nxF "exists $A/zzd-ov/SKILL.md" "$T/sync.log" | head -1 | cut -d: -f1)
if [ -n "$state_at" ] && [ -n "$live_at" ] && [ "$state_at" -lt "$live_at" ]; then ok
else bad "the saved pristine copy must be on disk before the live file changes (state at ${state_at:-none}, live at ${live_at:-none})"; fi
srun sync-noop "" apply
assert_rc 0 "an apply with nothing to do"
if [ ! -s "$T/sync.log" ]; then ok; else bad "an apply with nothing to change still synced: $(head -3 "$T/sync.log")"; fi
# An overlay change saves twice: the transitional state, which still knows the old
# text, before the live file changes, and the final state only once the live file
# is on disk.
lines_with zzd-ov 'line b=line b OURS' 'line d=line d OURS' >"$P/zzd-ov/SKILL.md"
srun sync-order "" apply
assert_rc 0 "an overlay change with the logging sync"
mf="exists $SA/manifest/.zzd-ov.new"
n_mf=$(grep -cxF "$mf" "$T/sync.log")
first_mf=$(grep -nxF "$mf" "$T/sync.log" | head -1 | cut -d: -f1)
last_mf=$(grep -nxF "$mf" "$T/sync.log" | tail -1 | cut -d: -f1)
live_at=$(grep -nxF "exists $A/zzd-ov/SKILL.md" "$T/sync.log" | head -1 | cut -d: -f1)
if [ "$n_mf" -ge 2 ] && [ -n "$live_at" ] && [ "$first_mf" -lt "$live_at" ] && [ "$live_at" -lt "$last_mf" ]; then ok
else bad "transitional state, then the live file, then the final state (manifest syncs $n_mf at ${first_mf:-none}..${last_mf:-none}, live at ${live_at:-none})"; fi
assert_same "$P/zzd-ov/SKILL.md" "$A/zzd-ov/SKILL.md" "the overlay change lands"

# 7. A failed sync keeps the old state and the live files: nothing is renamed,
#    nothing live is written, and the next run finishes the job.
lines_with zzd-ov 'line b=line b OURS' 'line c=line c OURS TOO' >"$P/zzd-ov/SKILL.md"
snap syncfail
# A file the old pristine directory holds and no new one would: it survives only if
# that directory was never replaced.
for lbl in claude agents; do : >"$S/$lbl/pristine/zzd-ov/marker"; done
srun sync-fail "/pristine/.zzd-ov.new" apply
assert_rc 1 "apply when the sync fails"
assert_line "ERROR: could not save agents layer state for 'zzd-ov' — left unchanged" "the failed save is named"
assert_lacks '^localized \((claude|agents)\): zzd-ov/' "no live file is written once the state could not be saved"
for lbl in claude agents; do
  assert_same "$T/snap.syncfail/state/$lbl/manifest/zzd-ov" "$S/$lbl/manifest/zzd-ov" "$lbl manifest kept"
  assert_exists "$S/$lbl/pristine/zzd-ov/marker" "$lbl pristine directory not replaced"
  assert_same "$T/snap.syncfail/state/$lbl/pristine/zzd-ov/SKILL.md" "$S/$lbl/pristine/zzd-ov/SKILL.md" "$lbl pristine kept"
done
assert_same "$T/snap.syncfail/agents/zzd-ov/SKILL.md" "$A/zzd-ov/SKILL.md" "the live file is kept"
run sync-retry apply
assert_rc 0 "the next apply finishes the job"
assert_same "$P/zzd-ov/SKILL.md" "$A/zzd-ov/SKILL.md" "the new overlay lands on the retry"
assert_gone "$SA/pristine/zzd-ov/marker" "the retry saved a new pristine directory"
run sync-retry-dry --dry-run
assert_lacks '^(would |ERROR:|DRIFT:|conflict )' "the retry leaves nothing behind"

# 7b. Renames that land but cannot be synced: the new state is in place but not
#     known to be on disk, so no live file is written over it, the error says the
#     state was saved, and the next run finishes the job.
lines_with zzd-ov 'line b=line b OURS' 'line e=line e OURS' >"$P/zzd-ov/SKILL.md"
cp "$A/zzd-ov/SKILL.md" "$T/live7b"
SYNC_EXACT=$SA/pristine
srun sync-final-fail "" apply
SYNC_EXACT=""
assert_rc 1 "apply when the synced renames cannot be synced"
assert_line "ERROR: saved agents layer state for 'zzd-ov' but could not sync it — its files left unchanged" "the unsynced save is named as saved"
assert_lacks '^localized \(agents\): zzd-ov/' "no agents live file is written over unsynced state"
assert_same "$T/live7b" "$A/zzd-ov/SKILL.md" "the agents live file is kept"
assert_same "$P/zzd-ov/SKILL.md" "$C/zzd-ov/SKILL.md" "the claude tree goes ahead"
run sync-final-retry apply
assert_rc 0 "the next apply finishes the unsynced save"
assert_same "$P/zzd-ov/SKILL.md" "$A/zzd-ov/SKILL.md" "the overlay change lands on the retry"
run sync-final-retry-dry --dry-run
assert_lacks '^(would |ERROR:|DRIFT:|conflict )' "nothing is left behind"

# ---------------------------------------------------------------------------
# 8. A working copy that cannot be written leaves the skill alone. Before #593 a
#    failed copy of the overlay into the merge directory read as "remove the
#    live file", and apply deleted it.
fixture
run apply8 apply
snap stage
crun stage-fail "*/agents/zzd-ov/m/SKILL.md" apply
assert_rc 1 "apply when a working copy cannot be written"
assert_has 'ERROR: could not write the working copy of agents zzd-ov/SKILL.md under ' "the failed working copy is named"
assert_lacks '^removed ' "a failed working copy never removes the live file"
same_as_snap stage "the skill is left alone"
crun stage-fail-x "*/claude/zzd-up/x/SKILL.md" apply
assert_rc 1 "apply when the pristine working copy cannot be written"
assert_has 'ERROR: could not write the working copy of claude zzd-up/SKILL.md under ' "the failed pristine working copy is named"
same_as_snap stage "the skill is left alone again"

# ---------------------------------------------------------------------------
# 9. rebase refuses a damaged saved copy rather than make it the new base.
fixture
run apply9 apply
mkdir -p "$T/wt/.claude/worktrees/x/claude/scripts"
cp "$SCRIPT" "$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh"
cp -r "$P/zzd-up" "$T/up-before"
: >"$SC/pristine/zzd-up/SKILL.md"
OUT=$T/out.rebase
"$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh" rebase zzd-up 2 >"$OUT" 2>&1
RC=$?
assert_rc 5 "rebase refuses a damaged saved copy"
assert_has 'ERROR: the saved pristine copy of claude zzd-up/SKILL.md is damaged or missing' "rebase names it"
if diff -r "$T/up-before" "$P/zzd-up" >/dev/null; then ok; else bad "rebase rewrote the overlay from a damaged copy"; fi

# ---------------------------------------------------------------------------
# 10. unapply syncs the files it restores before it drops the state that is their
#     only record; when that sync fails, the tree's state stays and a second unapply
#     finishes the job.
fixture
run apply10 apply
srun unapply-sync "" unapply zzd-up
assert_rc 0 "unapply with the logging sync"
for p in "$C/zzd-up/SKILL.md" "$A/zzd-up/SKILL.md"; do
  if grep -qxF "exists $p" "$T/sync.log"; then ok; else bad "unapply did not sync the restored $p"; fi
done
assert_gone "$SA/manifest/zzd-up" "unapply drops the state once the files are on disk"
fixture
run apply10b apply
srun unapply-sync-fail "$A/zzd-up" unapply zzd-up
assert_rc 1 "unapply when the restored files cannot be synced"
assert_line "ERROR: could not sync the restored files of agents zzd-up — its layer state kept" "the failed sync is named"
assert_exists "$SA/manifest/zzd-up" "the agents state is kept"
assert_exists "$SA/pristine/zzd-up/SKILL.md" "the agents pristine copy is kept"
assert_same "$U/zzd-up/SKILL.md" "$A/zzd-up/SKILL.md" "the restore itself landed"
assert_gone "$SC/manifest/zzd-up" "the claude tree, synced, is done"
run unapply-again unapply zzd-up
assert_rc 3 "a second unapply finishes the agents tree and says claude has nothing left"
assert_line "unrecorded: claude zzd-up has an overlay but no saved pristine copy; only jsm install zzd-up --force restores it" "the claude tree has no saved copy left"
assert_gone "$SA/manifest/zzd-up" "the second unapply drops the agents state"
assert_same "$U/zzd-up/SKILL.md" "$A/zzd-up/SKILL.md" "the agents file is still pristine"

# ---------------------------------------------------------------------------
if [ ! -s "$JSM_CALLED" ]; then ok; else bad "the layer called jsm: $(cat "$JSM_CALLED")"; fi
HOME=$REAL_HOME XDG_STATE_HOME=$REAL_XDG
[ -n "$XDG_STATE_HOME" ] || unset XDG_STATE_HOME
if [ "$(real_state_sum)" = "$REAL_STATE_BEFORE" ]; then ok
else bad "the real skills-localize state changed during this suite"; fi

assertion_floor=130
assertion_total=$((pass + fail))
[ "$assertion_total" -ge "$assertion_floor" ] || bad "assertion floor: ran $assertion_total, expected at least $assertion_floor"
if [ "$fail" -eq 0 ]; then
  echo "ok — skills-localize durability: $pass/$assertion_total assertions passed (floor $assertion_floor)"
else
  echo "FAIL — skills-localize durability: $fail of $assertion_total assertions failed" >&2
  exit 1
fi
