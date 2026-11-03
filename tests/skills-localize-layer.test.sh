#!/usr/bin/env bash
# Behaviour tests for skills-localize.sh's local layer (dotfiles#2091): the
# local-tooling note, overlays merged onto whatever jsm installed, the saved
# pristine state, and unapply / forget / rebase / check. Runs the real script
# against fixture trees with every path it could touch pinned into a temp dir.
set -uo pipefail

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$CLAUDE_DIR/scripts/skills-localize.sh
[ -x "$SCRIPT" ] || { echo "FAIL: executable skills-localize.sh not found at $SCRIPT" >&2; exit 1; }
command -v git >/dev/null || { echo "FAIL: git is required (git merge-file)" >&2; exit 1; }

T=$(mktemp -d /tmp/skills-localize-layer.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# The real saved state must come out of this suite untouched.
real_state_sum() {
  local dir=${XDG_STATE_HOME:-$HOME/.local/state}/skills-localize
  if [ -e "$dir" ]; then find "$dir" -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort | sha256sum
  else echo absent; fi
}
REAL_STATE_BEFORE=$(real_state_sum)
REAL_HOME=$HOME REAL_XDG=${XDG_STATE_HOME:-}

# Fixture names must never match a real retired skill: enforce_retired reads
# the repo's own retired-skills.txt.
if grep -q '^zzl-' "$CLAUDE_DIR/retired-skills.txt" 2>/dev/null; then
  echo "FAIL: retired-skills.txt lists a zzl- name; rename the fixtures" >&2; exit 1
fi

mkdir -p "$T/bin" "$T/home"
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

NOTE='> **Local tooling on this machine.** Track work in GitHub issues. (claude)'
NOTE_CODEX='> **Local tooling on this machine.** Track work in GitHub issues. (codex)'
printf '%s\n' "$NOTE" >"$T/note.md"
printf '%s\n' "$NOTE_CODEX" >"$T/note.codex.md"
: >"$T/codex-skills.txt"
C=$T/claude X=$T/codex A=$T/agents P=$T/patches S=$T/state U=$T/upstream LBL=claude

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

assert_rc() { if [ "$RC" -eq "$1" ]; then ok; else bad "$2: exit $RC, expected $1: $(head -c 600 "$OUT")"; fi; }
assert_same() { if cmp -s "$1" "$2"; then ok; else bad "$3: $1 differs from $2"; fi; }
assert_has() { if grep -qF -- "$1" "$OUT"; then ok; else bad "$2: output lacks: $1"; fi; }
assert_line() { if grep -qxF -- "$1" "$OUT"; then ok; else bad "$2: missing line: $1"; fi; }
assert_lacks() { if grep -qE -- "$1" "$OUT"; then bad "$2: output has /$1/: $(grep -E -- "$1" "$OUT" | head -3)"; else ok; fi; }
assert_gone() { if [ ! -e "$1" ]; then ok; else bad "$2: $1 still exists"; fi; }

# skill_md NAME BODY... -> a SKILL.md with frontmatter, one body line per arg.
skill_md() {
  local name=$1
  shift
  printf -- '---\nname: %s\ndescription: Fixture skill.\n---\n\n' "$name"
  printf '%s\n' "$@"
}

# install TREE NAME — copy the upstream fixture in, as jsm would.
install() { rm -rf "${1:?}/$2"; cp -r "$U/$2" "$1/$2"; }

# noted FILE NOTE — the file with NOTE as its own paragraph after the frontmatter,
# built independently of the script's note_insert.
noted() {
  awk -v note="$2" '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm && $0 == "---" { print; print ""; print note; fm = 0; next }
    { print }' "$1"
}

BASE_LINES=('line a' 'line b' 'line c' 'line d' 'line e' 'line f' 'line g')
lines_with() {   # lines_with NAME SEARCH=REPLACE... -> SKILL.md text
  local name=$1 l kv
  shift
  local out=()
  for l in "${BASE_LINES[@]}"; do
    for kv in "$@"; do [ "$l" = "${kv%%=*}" ] && l=${kv#*=}; done
    out+=("$l")
  done
  skill_md "$name" "${out[@]}"
}

sha() { sha256sum "$1" | awk '{print $1}'; }

# fail_cp DEST CMD... — run CMD with every `cp` onto DEST failing, as a full disk or a
# permission error would; works as root, unlike chmod.
REAL_CP=$(command -v cp)
mkdir -p "$T/failbin"
cat >"$T/failbin/cp" <<'STUB'
#!/usr/bin/env bash
for last; do :; done
[ "$last" != "${FAIL_CP_DEST:?}" ] || { echo "cp: injected failure writing $last" >&2; exit 1; }
exec "${REAL_CP:?}" "$@"
STUB
chmod +x "$T/failbin/cp"
fail_cp() {
  local dest=$1
  shift
  FAIL_CP_DEST=$dest REAL_CP=$REAL_CP PATH="$T/failbin:$PATH" "$@"
}

# ---------------------------------------------------------------------------
# 1. The note: added after the frontmatter of a skill whose pristine markdown
#    names the uninstalled vocabulary, in both trees with each tree's text, and
#    removed byte-exactly by unapply. Plain skills and forks are never touched.
reset
mkdir -p "$U/zzl-noted/references" "$U/zzl-refvocab/references" "$U/zzl-plain" "$U/zzl-npm/node_modules/dep" \
  "$U/zzl-bd" "$U/zzl-bvp"
skill_md zzl-noted '# Noted' 'Run br create to file the issue.' >"$U/zzl-noted/SKILL.md"
# Every command skills-beads-sweep-check.py flags earns the note, bd and bv prioritize too.
skill_md zzl-bd '# Bd' 'Start with bd ready.' >"$U/zzl-bd/SKILL.md"
skill_md zzl-bvp '# Bvp' 'Then bv prioritize the queue.' >"$U/zzl-bvp/SKILL.md"
printf 'No vocabulary here.\n' >"$U/zzl-noted/references/guide.md"
skill_md zzl-refvocab '# Ref' 'See the guide.' >"$U/zzl-refvocab/SKILL.md"
printf 'Coordinate through Agent Mail.\n' >"$U/zzl-refvocab/references/guide.md"
skill_md zzl-plain '# Plain' 'Use gh issue create.' >"$U/zzl-plain/SKILL.md"
skill_md zzl-npm '# Npm' 'Nothing to see.' >"$U/zzl-npm/SKILL.md"
printf 'This dependency mentions beads.\n' >"$U/zzl-npm/node_modules/dep/README.md"
for s in zzl-noted zzl-refvocab zzl-plain zzl-npm zzl-bd zzl-bvp; do install "$C" "$s"; done
install "$X" zzl-noted
install "$A" zzl-noted
mkdir -p "$T/local/zzl-fork"
skill_md zzl-fork '# Fork' 'Run br create here too.' >"$T/local/zzl-fork/SKILL.md"

run dry --dry-run
assert_rc 0 "dry run"
assert_line 'would localize (claude): zzl-noted/SKILL.md' "dry run names the claude note"
assert_line 'would localize (codex): zzl-noted/SKILL.md' "dry run names the codex note"
assert_line 'would localize (agents): zzl-noted/SKILL.md' "dry run names the agents note"
assert_line 'would localize (claude): zzl-refvocab/SKILL.md' "vocabulary in a reference file earns the note"
assert_line 'would localize (claude): zzl-bd/SKILL.md' "a bd command earns the note"
assert_line 'would localize (claude): zzl-bvp/SKILL.md' "bv prioritize earns the note"
assert_same "$U/zzl-noted/SKILL.md" "$C/zzl-noted/SKILL.md" "dry run changes no file"
assert_gone "$S/claude" "dry run saves no state"

run apply apply
assert_rc 0 "apply"
noted "$U/zzl-noted/SKILL.md" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-noted/SKILL.md" "claude note lands right after the frontmatter"
noted "$U/zzl-noted/SKILL.md" "$NOTE_CODEX" >"$T/expect"
assert_same "$T/expect" "$X/zzl-noted/SKILL.md" "codex gets its own note text"
assert_same "$T/expect" "$A/zzl-noted/SKILL.md" "the agents mirror Codex reads gets the codex note text"
noted "$U/zzl-refvocab/SKILL.md" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-refvocab/SKILL.md" "reference vocabulary noted in SKILL.md"
assert_same "$U/zzl-noted/references/guide.md" "$C/zzl-noted/references/guide.md" "other files untouched"
assert_same "$U/zzl-plain/SKILL.md" "$C/zzl-plain/SKILL.md" "a skill without the vocabulary is untouched"
assert_same "$U/zzl-npm/SKILL.md" "$C/zzl-npm/SKILL.md" "vocabulary under node_modules does not count"
assert_same "$T/local/zzl-fork/SKILL.md" "$C/zzl-fork/SKILL.md" "a fork is deployed as written, never noted"
assert_gone "$S/$LBL/manifest/zzl-plain" "no state for an untouched skill"
if [ -f "$S/$LBL/manifest/zzl-noted" ] && [ -f "$S/codex/manifest/zzl-noted" ] &&
   [ -f "$S/agents/manifest/zzl-noted" ]; then ok
else bad "apply saved no state for the noted skill"; fi
if [ -f "$S/conflicts" ] && [ ! -s "$S/conflicts" ]; then ok; else bad "apply with no conflicts must leave an empty conflicts file"; fi

run apply-again apply
assert_rc 0 "second apply"
noted "$U/zzl-noted/SKILL.md" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-noted/SKILL.md" "apply is idempotent: one note, not two"
assert_lacks '^(localized|restored|removed) ' "second apply writes nothing"

run check check
assert_rc 0 "check after apply"
assert_line 'skills policy in sync' "check after apply"

run unapply unapply zzl-noted zzl-refvocab
assert_rc 0 "unapply noted skills"
assert_same "$U/zzl-noted/SKILL.md" "$C/zzl-noted/SKILL.md" "unapply restores claude byte-exactly"
assert_same "$U/zzl-noted/SKILL.md" "$X/zzl-noted/SKILL.md" "unapply restores codex byte-exactly"
assert_same "$U/zzl-noted/SKILL.md" "$A/zzl-noted/SKILL.md" "unapply restores agents byte-exactly"
assert_same "$U/zzl-refvocab/SKILL.md" "$C/zzl-refvocab/SKILL.md" "unapply restores the reference-noted skill"
assert_gone "$S/$LBL/manifest/zzl-noted" "unapply drops claude state"
assert_gone "$S/codex/manifest/zzl-noted" "unapply drops codex state"
assert_gone "$S/agents/manifest/zzl-noted" "unapply drops agents state"
if [ ! -s "$JSM_CALLED" ]; then ok; else bad "the layer called jsm: $(cat "$JSM_CALLED")"; fi

# State lost on a noted skill: unapply strips the note it can recognise.
run apply-3 apply
rm -rf "$S"
run unapply-lost-note unapply zzl-noted
assert_rc 0 "unapply with lost state on a noted skill"
assert_same "$U/zzl-noted/SKILL.md" "$C/zzl-noted/SKILL.md" "a note with no saved state is stripped byte-exactly"

# ---------------------------------------------------------------------------
# 2. Overlays merge onto the installed version. A clean merge keeps both sides;
#    an added file (no base) is ours to add and to take away again.
reset
mkdir -p "$P/zzl-merge/.base" "$P/zzl-merge/scripts" "$U/zzl-merge"
lines_with zzl-merge >"$P/zzl-merge/.base/SKILL.md"
lines_with zzl-merge 'line b=line b OURS' >"$P/zzl-merge/SKILL.md"
printf 'echo ours\n' >"$P/zzl-merge/scripts/extra.sh"
lines_with zzl-merge 'line f=line f THEIRS' >"$U/zzl-merge/SKILL.md"
install "$C" zzl-merge
install "$X" zzl-merge
run merge apply
assert_rc 0 "clean merge apply"
lines_with zzl-merge 'line b=line b OURS' 'line f=line f THEIRS' >"$T/expect"
assert_same "$T/expect" "$C/zzl-merge/SKILL.md" "clean merge keeps both sides (claude)"
assert_same "$T/expect" "$X/zzl-merge/SKILL.md" "clean merge keeps both sides (codex)"
assert_same "$P/zzl-merge/scripts/extra.sh" "$C/zzl-merge/scripts/extra.sh" "an added overlay file is laid down"
assert_lacks '^conflict ' "a clean merge reports no conflict"
if [ ! -s "$S/conflicts" ]; then ok; else bad "a clean merge recorded a conflict: $(cat "$S/conflicts")"; fi
run unapply-merge unapply zzl-merge
assert_rc 0 "unapply merged skill"
assert_same "$U/zzl-merge/SKILL.md" "$C/zzl-merge/SKILL.md" "unapply puts upstream back"
assert_gone "$C/zzl-merge/scripts" "unapply takes the added file and its empty dir away"
assert_same "$U/zzl-merge/SKILL.md" "$X/zzl-merge/SKILL.md" "unapply puts upstream back in codex"

# ---------------------------------------------------------------------------
# 3. A conflict keeps our side, only where the two sides collide, and is
#    recorded for the weekly digest; a reapply keeps recording it.
reset
mkdir -p "$P/zzl-conf/.base" "$U/zzl-conf"
lines_with zzl-conf >"$P/zzl-conf/.base/SKILL.md"
lines_with zzl-conf 'line d=line d OURS' >"$P/zzl-conf/SKILL.md"
lines_with zzl-conf 'line d=line d THEIRS' 'line g=line g THEIRS' >"$U/zzl-conf/SKILL.md"
install "$C" zzl-conf
install "$X" zzl-conf
install "$A" zzl-conf
run conflict apply
assert_rc 0 "conflict apply"
lines_with zzl-conf 'line d=line d OURS' 'line g=line g THEIRS' >"$T/expect"
assert_same "$T/expect" "$C/zzl-conf/SKILL.md" "our side wins the conflict; the clean upstream change still lands"
assert_line 'conflict (claude): zzl-conf/SKILL.md — upstream changed lines the overlay also changes; kept our side' "conflict is reported"
printf '%s\n' 'agents zzl-conf/SKILL.md' 'claude zzl-conf/SKILL.md' 'codex zzl-conf/SKILL.md' >"$T/expect"
assert_same "$T/expect" "$S/conflicts" "conflicts file names the file in every tree"
run conflict-again apply
assert_same "$T/expect" "$S/conflicts" "a reapply keeps recording an unrebased conflict"
run check-conflict check
assert_rc 0 "a kept conflict is not drift"
run dry-conflict --dry-run
assert_same "$T/expect" "$S/conflicts" "a dry run leaves the conflicts file alone"
# A skill apply leaves alone (here, hand-edited in one tree) keeps its recorded conflict.
cp "$C/zzl-conf/SKILL.md" "$T/conf-live"
printf 'a hand edit\n' >>"$C/zzl-conf/SKILL.md"
run conflict-skipped apply
assert_has 'DRIFT: claude zzl-conf/SKILL.md was edited after skills-localize wrote it' "the hand-edited conflict skill is skipped"
assert_same "$T/expect" "$S/conflicts" "a skipped skill keeps its conflict line"
cp "$T/conf-live" "$C/zzl-conf/SKILL.md"
run conflict-unskipped apply
assert_same "$T/expect" "$S/conflicts" "the conflict is still recorded once the skill is layered again"

# rebase refuses outside a worktree checkout of the script.
mkdir -p "$T/plain/claude/scripts" "$T/wt/.claude/worktrees/x/claude/scripts"
cp "$SCRIPT" "$T/plain/claude/scripts/skills-localize.sh"
cp "$SCRIPT" "$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh"
cp -r "$P/zzl-conf" "$T/conf-before"
OUT=$T/out.rebase-guard
"$T/plain/claude/scripts/skills-localize.sh" rebase zzl-conf 2 >"$OUT" 2>&1
RC=$?
assert_rc 2 "rebase outside a worktree"
assert_has "ERROR: rebase rewrites skills-patches/zzl-conf — run a worktree's copy of this script" "rebase guard message"
if diff -r "$T/conf-before" "$P/zzl-conf" >/dev/null; then ok; else bad "a refused rebase changed the overlay"; fi
OUT=$T/out.rebase-version
"$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh" rebase zzl-conf latest >"$OUT" 2>&1
RC=$?
assert_rc 2 "rebase with a non-numeric version"

# rebase from a worktree: the installed pristine becomes the base, the merge the overlay.
OUT=$T/out.rebase
"$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh" rebase zzl-conf v2 >"$OUT" 2>&1
RC=$?
assert_rc 0 "rebase from a worktree"
assert_same "$U/zzl-conf/SKILL.md" "$P/zzl-conf/.base/SKILL.md" "rebase makes upstream the new base"
lines_with zzl-conf 'line d=line d OURS' 'line g=line g THEIRS' >"$T/expect"
assert_same "$T/expect" "$P/zzl-conf/SKILL.md" "rebase makes the merge the new overlay"
if [ "$(cat "$P/zzl-conf/.base/VERSION")" = 2 ]; then ok; else bad "rebase did not record base version 2"; fi
assert_has 'kept our side in zzl-conf/SKILL.md' "rebase names the kept conflict for review"
run after-rebase apply
assert_rc 0 "apply after rebase"
if [ ! -s "$S/conflicts" ]; then ok; else bad "the conflict outlived the rebase: $(cat "$S/conflicts")"; fi
assert_same "$T/expect" "$C/zzl-conf/SKILL.md" "apply after rebase keeps the same live text"

# ---------------------------------------------------------------------------
# 4. A hand edit is never overwritten: apply and check report it, unapply
#    exits 4 naming it and changes nothing in either tree, and forget plus a
#    forced install plus apply converges.
reset
mkdir -p "$P/zzl-merge/.base" "$P/zzl-merge/scripts" "$U/zzl-merge"
lines_with zzl-merge >"$P/zzl-merge/.base/SKILL.md"
lines_with zzl-merge 'line b=line b OURS' >"$P/zzl-merge/SKILL.md"
printf 'echo ours\n' >"$P/zzl-merge/scripts/extra.sh"
lines_with zzl-merge 'line f=line f THEIRS' >"$U/zzl-merge/SKILL.md"
install "$C" zzl-merge
install "$X" zzl-merge
install "$A" zzl-merge
run hand-apply apply
printf 'a hand edit\n' >>"$C/zzl-merge/SKILL.md"
cp -r "$C/zzl-merge" "$T/claude-edited"
cp -r "$X/zzl-merge" "$T/codex-before"
cp -r "$A/zzl-merge" "$T/agents-before"
cp -r "$S" "$T/state-before"
run hand-check check
assert_rc 1 "check sees the hand edit"
assert_has 'DRIFT: claude zzl-merge/SKILL.md was edited after skills-localize wrote it — left alone. To discard the edit and take upstream: skills-localize.sh forget zzl-merge && jsm install zzl-merge --force && skills-localize.sh apply' "check names the hand edit and the recipe"
run hand-apply-2 apply
assert_has 'DRIFT: claude zzl-merge/SKILL.md was edited after skills-localize wrote it' "apply names the hand edit"
if diff -r "$T/claude-edited" "$C/zzl-merge" >/dev/null; then ok; else bad "apply overwrote a hand edit"; fi
run hand-unapply unapply zzl-merge
assert_rc 4 "unapply on a hand edit"
assert_line 'hand-edited claude zzl-merge/SKILL.md' "unapply names the hand-edited file"
if diff -r "$T/claude-edited" "$C/zzl-merge" >/dev/null && diff -r "$T/codex-before" "$X/zzl-merge" >/dev/null &&
   diff -r "$T/agents-before" "$A/zzl-merge" >/dev/null && diff -r "$T/state-before" "$S" >/dev/null; then ok
else bad "unapply changed something although a file was hand-edited"; fi
run hand-forget forget zzl-merge
assert_rc 0 "forget"
assert_line 'forgot claude layer state: zzl-merge' "forget names what it dropped"
assert_gone "$S/$LBL/manifest/zzl-merge" "forget drops claude state"
assert_gone "$S/codex/pristine/zzl-merge" "forget drops codex state"
assert_gone "$S/agents/pristine/zzl-merge" "forget drops agents state"
install "$C" zzl-merge
install "$X" zzl-merge
install "$A" zzl-merge
run hand-reapply apply
assert_rc 0 "apply after forget and a forced install"
run hand-check-2 check
assert_rc 0 "check converges after the recipe"

# ---------------------------------------------------------------------------
# 5. Lost state on an overlay skill: unapply cannot know pristine, says so,
#    exits 3 and changes nothing.
rm -rf "$S"
cp -r "$C/zzl-merge" "$T/claude-lost"
run lost unapply zzl-merge
assert_rc 3 "unapply with lost state"
assert_has 'unrecorded: claude zzl-merge has an overlay but no saved pristine copy; only jsm install zzl-merge --force restores it' "lost state is named"
if diff -r "$T/claude-lost" "$C/zzl-merge" >/dev/null; then ok; else bad "unapply with lost state changed the skill"; fi

# Bad names never reach a path.
run bad-name unapply ../zzl-merge
assert_rc 2 "unapply with a bad name"
assert_has "ERROR: unapply entry '../zzl-merge' is not a valid skill name" "bad name is refused"

# ---------------------------------------------------------------------------
# 6. State saved for another tree is refused, not read: that tree's layer is
#    skipped and nothing in it changes.
reset
mkdir -p "$U/zzl-noted"
skill_md zzl-noted '# Noted' 'Run br create to file the issue.' >"$U/zzl-noted/SKILL.md"
install "$C" zzl-noted
install "$X" zzl-noted
mkdir -p "$S/claude"
printf '/some/other/tree\n' >"$S/$LBL/root"
run owns apply
assert_rc 1 "apply against state for another tree"
assert_has "ERROR: $S/claude holds state for /some/other/tree, not $C — claude layer skipped (set SKILLS_LOCALIZE_STATE)" "mismatched state is named"
assert_same "$U/zzl-noted/SKILL.md" "$C/zzl-noted/SKILL.md" "the refused tree is untouched"
noted "$U/zzl-noted/SKILL.md" "$NOTE_CODEX" >"$T/expect"
assert_same "$T/expect" "$X/zzl-noted/SKILL.md" "the other tree is still localized"
run owns-unapply unapply zzl-noted
assert_rc 1 "unapply against state for another tree is an error, not a hand edit"
run owns-check check
assert_rc 1 "check against state for another tree"

# A missing or foreign note file skips that tree's layer loudly.
reset
mkdir -p "$U/zzl-noted"
skill_md zzl-noted '# Noted' 'Run br create to file the issue.' >"$U/zzl-noted/SKILL.md"
install "$C" zzl-noted
printf 'not the marker\n' >"$T/bad-note.md"
OUT=$T/out.bad-note
SKILLS_NOTE_FILE="$T/bad-note.md" "$SCRIPT" apply >"$OUT" 2>&1
RC=$?
assert_rc 1 "apply with a note file that lacks the marker"
assert_has "ERROR: $T/bad-note.md is missing or does not start with" "bad note file is named"
assert_same "$U/zzl-noted/SKILL.md" "$C/zzl-noted/SKILL.md" "no note is written from a bad note file"

# ---------------------------------------------------------------------------
# 7. The first apply after this change meets pre-#2091 trees: whole-file
#    overlay copies and an old renamed text, with no state. Nothing is lost,
#    state is recorded, and unapply -> forced install -> apply converges.
#    The legacy list names the overlay's own files, as the real list does: only
#    listed bytes let an overlay's .base stand in for pristine. The renamed text
#    is unlisted here (section 8 covers listed renamed text).
reset
mkdir -p "$P/zzl-legacy/.base" "$P/zzl-legacy/scripts" "$U/zzl-legacy" "$U/zzl-renamed"
lines_with zzl-legacy >"$U/zzl-legacy/SKILL.md"
cp "$U/zzl-legacy/SKILL.md" "$P/zzl-legacy/.base/SKILL.md"
lines_with zzl-legacy 'line c=line c OURS' >"$P/zzl-legacy/SKILL.md"
printf 'module.exports = 1\n' >"$P/zzl-legacy/scripts/added.js"
{
  echo "$(sha "$P/zzl-legacy/SKILL.md") swapped zzl-legacy/SKILL.md"
  echo "$(sha "$P/zzl-legacy/scripts/added.js") added zzl-legacy/scripts/added.js"
} >"$T/legacy.txt"
skill_md zzl-renamed '# Renamed' 'Run br create, then read beads docs.' >"$U/zzl-renamed/SKILL.md"
for tree in "$C" "$X" "$A"; do
  mkdir -p "$tree/zzl-legacy/scripts" "$tree/zzl-renamed"
  cp "$P/zzl-legacy/SKILL.md" "$tree/zzl-legacy/SKILL.md"
  cp "$P/zzl-legacy/scripts/added.js" "$tree/zzl-legacy/scripts/added.js"
  skill_md zzl-renamed '# Renamed' 'Run gh issue create, then read beads docs.' >"$tree/zzl-renamed/SKILL.md"
done
cp "$C/zzl-renamed/SKILL.md" "$T/renamed-old"
run legacy apply
assert_rc 0 "legacy first apply"
assert_lacks '^(ERROR|DRIFT)' "legacy first apply raises nothing"
assert_same "$P/zzl-legacy/SKILL.md" "$C/zzl-legacy/SKILL.md" "legacy overlay text survives the first apply"
assert_same "$P/zzl-legacy/scripts/added.js" "$C/zzl-legacy/scripts/added.js" "legacy added file survives the first apply"
assert_same "$U/zzl-legacy/SKILL.md" "$S/$LBL/pristine/zzl-legacy/SKILL.md" "legacy pristine is the overlay's base"
noted "$T/renamed-old" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-renamed/SKILL.md" "an old renamed text is noted as found"
run legacy-check check
assert_rc 0 "check after the legacy first apply"
run legacy-unapply unapply zzl-legacy zzl-renamed
assert_rc 0 "unapply after the legacy first apply"
assert_same "$U/zzl-legacy/SKILL.md" "$C/zzl-legacy/SKILL.md" "unapply gives back the base"
assert_gone "$C/zzl-legacy/scripts" "unapply removes the legacy added file"
assert_same "$T/renamed-old" "$C/zzl-renamed/SKILL.md" "unapply gives back the renamed text it found"
for tree in "$C" "$X" "$A"; do install "$tree" zzl-legacy; install "$tree" zzl-renamed; done
run legacy-reapply apply
assert_rc 0 "apply after the forced install"
assert_same "$P/zzl-legacy/SKILL.md" "$C/zzl-legacy/SKILL.md" "overlay back on after the forced install"
noted "$U/zzl-renamed/SKILL.md" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-renamed/SKILL.md" "upstream text noted after the forced install"
run legacy-check-2 check
assert_rc 0 "check converges after the migration"
run legacy-unapply-2 unapply zzl-legacy zzl-renamed
assert_same "$U/zzl-legacy/SKILL.md" "$C/zzl-legacy/SKILL.md" "after migration unapply is upstream exactly"
assert_same "$U/zzl-renamed/SKILL.md" "$X/zzl-renamed/SKILL.md" "after migration unapply is upstream exactly (codex)"
assert_same "$U/zzl-legacy/SKILL.md" "$A/zzl-legacy/SKILL.md" "after migration unapply is upstream exactly (agents)"
: >"$T/legacy.txt"

# ---------------------------------------------------------------------------
# 8. Text the legacy list names is never taken as pristine: apply, dry run and
#    check leave the skill alone with a DRIFT line, unapply removes the old
#    added files and exits 3, rebase refuses, and a forced install converges.
#    A kept overlay whose live files ARE the current overlay is not legacy,
#    even when the list holds their hashes: it takes the .base path.
reset
mkdir -p "$U/zzl-oldren" "$U/zzl-kept" "$U/zzl-kept2" "$P/zzl-kept/.base" "$P/zzl-kept2/.base" "$P/zzl-kept2/scripts"
skill_md zzl-oldren '# Old' 'Run br create, then read beads docs.' >"$U/zzl-oldren/SKILL.md"
lines_with zzl-kept >"$U/zzl-kept/SKILL.md"
printf 'upstream agents\n' >"$U/zzl-kept/AGENTS.md"
cp "$U/zzl-kept/SKILL.md" "$P/zzl-kept/.base/SKILL.md"
lines_with zzl-kept 'line c=line c OURS' >"$P/zzl-kept/SKILL.md"
lines_with zzl-kept2 >"$U/zzl-kept2/SKILL.md"
cp "$U/zzl-kept2/SKILL.md" "$P/zzl-kept2/.base/SKILL.md"
lines_with zzl-kept2 'line e=line e OURS' >"$P/zzl-kept2/SKILL.md"
printf 'echo kept\n' >"$P/zzl-kept2/scripts/add.sh"
for tree in "$C" "$X" "$A"; do
  mkdir -p "$tree/zzl-oldren/references" "$tree/zzl-kept" "$tree/zzl-kept2/scripts"
  skill_md zzl-oldren '# Old' 'Run gh issue create, then read beads docs.' >"$tree/zzl-oldren/SKILL.md"
  printf 'gh notes\n' >"$tree/zzl-oldren/references/GH.md"
  cp "$P/zzl-kept/SKILL.md" "$tree/zzl-kept/SKILL.md"
  printf 'old renamed agents\n' >"$tree/zzl-kept/AGENTS.md"
  cp "$P/zzl-kept2/SKILL.md" "$tree/zzl-kept2/SKILL.md"
  cp "$P/zzl-kept2/scripts/add.sh" "$tree/zzl-kept2/scripts/add.sh"
done
# The agents mirror still holds an older version of the same overlay file: the list
# names both versions of one path, and a line giving that path a second kind is bad.
skill_md zzl-oldren '# Old' 'Run gh issue create (older wording), then read beads docs.' >"$A/zzl-oldren/SKILL.md"
{
  echo '# fixture legacy list'
  echo "$(sha "$C/zzl-oldren/SKILL.md") swapped zzl-oldren/SKILL.md"
  echo "$(sha "$C/zzl-oldren/references/GH.md") added zzl-oldren/references/GH.md"
  echo "$(sha "$A/zzl-oldren/SKILL.md") swapped zzl-oldren/SKILL.md"
  echo "$(printf '%064d' 0) added zzl-oldren/SKILL.md"
  echo "$(sha "$P/zzl-kept/SKILL.md") swapped zzl-kept/SKILL.md"
  echo "$(sha "$C/zzl-kept/AGENTS.md") swapped zzl-kept/AGENTS.md"
  echo "$(sha "$P/zzl-kept2/SKILL.md") swapped zzl-kept2/SKILL.md"
  echo "$(sha "$P/zzl-kept2/scripts/add.sh") added zzl-kept2/scripts/add.sh"
  echo 'not-a-hash swapped zzl-oldren/SKILL.md'
} >"$T/legacy.txt"
cp -r "$C" "$T/claude-legacy-before"

run leg-dry --dry-run
assert_rc 0 "dry run over legacy text"
assert_line 'DRIFT: claude zzl-oldren still holds pre-#2091 overlay text (SKILL.md references/GH.md) — not layered until reinstalled: skills-localize.sh unapply zzl-oldren; jsm install zzl-oldren --force; skills-localize.sh apply (the nightly does this when jsm next updates zzl-oldren)' "dry run names the legacy skill and the recipe"
assert_line 'DRIFT: agents zzl-oldren still holds pre-#2091 overlay text (SKILL.md references/GH.md) — not layered until reinstalled: skills-localize.sh unapply zzl-oldren; jsm install zzl-oldren --force; skills-localize.sh apply (the nightly does this when jsm next updates zzl-oldren)' "an older listed version of the same file is legacy too"
assert_has 'WARN: ignoring bad line in' "a malformed list line is named"
assert_has "WARN: ignoring bad line in $T/legacy.txt: $(printf '%064d' 0) added zzl-oldren/SKILL.md" "a second kind for one path is refused"
assert_lacks 'would localize \((claude|agents)\): zzl-oldren' "dry run plans nothing for a legacy skill"

run leg-apply apply
assert_rc 0 "apply over legacy text is not an error"
assert_has 'DRIFT: codex zzl-oldren still holds pre-#2091 overlay text' "both trees are checked"
assert_has 'DRIFT: claude zzl-kept still holds pre-#2091 overlay text (AGENTS.md)' "a file the kept overlay no longer ships is legacy"
assert_lacks 'zzl-kept2 still holds' "live files equal to the current overlay are not legacy"
if diff -r "$T/claude-legacy-before/zzl-oldren" "$C/zzl-oldren" >/dev/null &&
   diff -r "$T/claude-legacy-before/zzl-kept" "$C/zzl-kept" >/dev/null; then ok
else bad "apply changed a legacy skill"; fi
assert_gone "$S/$LBL/manifest/zzl-oldren" "no state is saved from legacy text"
assert_gone "$S/$LBL/pristine/zzl-kept" "no pristine is saved from legacy text"
assert_same "$U/zzl-kept2/SKILL.md" "$S/$LBL/pristine/zzl-kept2/SKILL.md" "the kept overlay takes its .base as pristine"

run leg-check check
assert_rc 1 "check fails while legacy text remains"
assert_has 'DRIFT: claude zzl-oldren still holds pre-#2091 overlay text' "check names the legacy skill"

OUT=$T/out.leg-rebase
mkdir -p "$T/wt/.claude/worktrees/x/claude/scripts"
cp "$SCRIPT" "$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh"
cp -r "$P/zzl-kept" "$T/kept-before"
"$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh" rebase zzl-kept 3 >"$OUT" 2>&1
RC=$?
assert_rc 4 "rebase refuses legacy text"
assert_has 'ERROR: zzl-kept still holds pre-#2091 overlay text (AGENTS.md)' "rebase names the legacy file"
if diff -r "$T/kept-before" "$P/zzl-kept" >/dev/null; then ok; else bad "a refused rebase changed the overlay"; fi

run leg-unapply unapply zzl-oldren zzl-kept zzl-kept2
assert_rc 3 "unapply on legacy text exits 3"
assert_line 'legacy: claude zzl-oldren still holds pre-#2091 overlay text (SKILL.md references/GH.md); only jsm install zzl-oldren --force replaces it' "unapply names the legacy files"
assert_line 'unapplied (claude): zzl-oldren/references/GH.md (pre-#2091 file removed)' "unapply removes the old added file"
assert_gone "$C/zzl-oldren/references" "the added file and its empty dir are gone"
assert_gone "$X/zzl-oldren/references/GH.md" "the added file is gone from codex too"
assert_gone "$A/zzl-oldren/references/GH.md" "the added file is gone from agents too"
assert_same "$T/claude-legacy-before/zzl-oldren/SKILL.md" "$C/zzl-oldren/SKILL.md" "unapply leaves the swapped legacy file for the forced install"
assert_same "$U/zzl-kept2/SKILL.md" "$C/zzl-kept2/SKILL.md" "the kept overlay unapplies as usual alongside"
assert_gone "$C/zzl-kept2/scripts" "the kept overlay's added file goes with it"

# A forced install that leaves extra files in place, as jsm may.
for tree in "$C" "$X" "$A"; do
  for s in zzl-oldren zzl-kept zzl-kept2; do cp -r "$U/$s/." "$tree/$s/"; done
done
run leg-reapply apply
assert_rc 0 "apply after the forced install"
assert_lacks 'pre-#2091' "nothing is legacy after the forced install"
noted "$U/zzl-oldren/SKILL.md" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-oldren/SKILL.md" "upstream text is noted after the forced install"
assert_same "$P/zzl-kept/SKILL.md" "$C/zzl-kept/SKILL.md" "the kept overlay merges back on"
assert_same "$U/zzl-kept/AGENTS.md" "$C/zzl-kept/AGENTS.md" "upstream AGENTS.md is left as installed"
run leg-check-2 check
assert_rc 0 "check converges after the migration"
run leg-unapply-2 unapply zzl-oldren zzl-kept zzl-kept2
assert_rc 0 "unapply after the migration"
assert_same "$U/zzl-oldren/SKILL.md" "$C/zzl-oldren/SKILL.md" "after the migration unapply is upstream exactly"
assert_same "$U/zzl-kept/SKILL.md" "$X/zzl-kept/SKILL.md" "after the migration unapply is upstream exactly (codex)"
assert_same "$U/zzl-oldren/SKILL.md" "$A/zzl-oldren/SKILL.md" "after the migration unapply is upstream exactly (agents)"
: >"$T/legacy.txt"

# ---------------------------------------------------------------------------
# 9. A skill whose layer is no longer wanted gets its files back before its
#    state goes: when the restore fails, the state stays for the next run.
reset
mkdir -p "$P/zzl-drop/.base" "$U/zzl-drop"
lines_with zzl-drop >"$U/zzl-drop/SKILL.md"
cp "$U/zzl-drop/SKILL.md" "$P/zzl-drop/.base/SKILL.md"
lines_with zzl-drop 'line a=line a OURS' >"$P/zzl-drop/SKILL.md"
install "$C" zzl-drop
run drop-apply apply
rm -rf "$P/zzl-drop"
if [ "$(id -u)" -ne 0 ]; then
  chmod 444 "$C/zzl-drop/SKILL.md"
  run drop-fail apply
  assert_rc 1 "a failed restore is an error"
  assert_has "ERROR: kept claude layer state for 'zzl-drop' until its files are restored" "the kept state is named"
  if [ -f "$S/$LBL/manifest/zzl-drop" ] && [ -f "$S/$LBL/pristine/zzl-drop/SKILL.md" ]; then ok
  else bad "state was dropped although the restore failed"; fi
  chmod 644 "$C/zzl-drop/SKILL.md"
else
  echo "note: running as root, the failed-restore case is skipped" >&2
fi
run drop-retry apply
assert_rc 0 "the next apply restores and drops the state"
assert_same "$U/zzl-drop/SKILL.md" "$C/zzl-drop/SKILL.md" "the skill is upstream again"
assert_gone "$S/$LBL/manifest/zzl-drop" "the state is dropped once the files are back"
assert_gone "$S/$LBL/pristine/zzl-drop" "the pristine copy is dropped once the files are back"

# ---------------------------------------------------------------------------
# 10. A failed live write never loses what the last apply recorded: its hashes and
#     pristine copies stay until the files they describe are written, so a retry
#     finishes the job and unapply still knows pristine.
reset
mkdir -p "$U/zzl-keep/references" "$P/zzl-keep/.base/references" "$P/zzl-keep/references"
skill_md zzl-keep '# Keep' 'Run br create to file the issue.' >"$U/zzl-keep/SKILL.md"
printf 'ref one\nref two\nref three\n' >"$U/zzl-keep/references/ref.md"
cp "$U/zzl-keep/references/ref.md" "$P/zzl-keep/.base/references/ref.md"
printf 'ref one\nref two OURS\nref three\n' >"$P/zzl-keep/references/ref.md"
cp "$P/zzl-keep/references/ref.md" "$T/keep-overlay"
install "$C" zzl-keep
run keep-apply apply
assert_rc 0 "apply with a note and an overlay"
assert_same "$T/keep-overlay" "$C/zzl-keep/references/ref.md" "the overlay is on"

# (a) The overlay is retired while the note stays, and its restore fails.
rm -rf "$P/zzl-keep"
OUT=$T/out.keep-drop-fail
fail_cp "$C/zzl-keep/references/ref.md" "$SCRIPT" apply >"$OUT" 2>&1
RC=$?
assert_rc 1 "a failed restore of a retired overlay is an error"
assert_has "ERROR: kept claude layer state for 'zzl-keep' until its files are restored" "the kept state is named"
if grep -q "^references/ref.md	" "$S/$LBL/manifest/zzl-keep" 2>/dev/null &&
   [ -f "$S/$LBL/pristine/zzl-keep/references/ref.md" ]; then ok
else bad "the record of the retired overlay went before its file was restored"; fi
assert_same "$T/keep-overlay" "$C/zzl-keep/references/ref.md" "the failed restore left the overlay text"
run keep-drop-check check
assert_rc 1 "check sees the unfinished restore"
assert_line 'DRIFT: claude zzl-keep/references/ref.md is not the localized copy (run apply)' "check names the file still to restore"
run keep-drop-retry apply
assert_rc 0 "the retry restores the file"
assert_same "$U/zzl-keep/references/ref.md" "$C/zzl-keep/references/ref.md" "the retired overlay is gone after the retry"
if grep -q "^references/ref.md	" "$S/$LBL/manifest/zzl-keep"; then bad "the restored file is still recorded"; else ok; fi
assert_gone "$S/$LBL/pristine/zzl-keep/references" "its pristine copy goes once the file is back"
run keep-drop-check-2 check
assert_rc 0 "check converges after the retry"

# (b) The note changes and writing it fails: the next apply still recognises what
#     the last one wrote, and so does unapply.
printf '%s\n' "$NOTE v2" >"$T/note.md"
OUT=$T/out.keep-note-fail
fail_cp "$C/zzl-keep/SKILL.md" "$SCRIPT" apply >"$OUT" 2>&1
RC=$?
assert_rc 1 "a failed note update is an error"
run keep-note-retry apply
assert_rc 0 "apply after a failed note update"
assert_lacks 'edited after' "the last applied note is not taken for a hand edit"
noted "$U/zzl-keep/SKILL.md" "$NOTE v2" >"$T/expect"
assert_same "$T/expect" "$C/zzl-keep/SKILL.md" "the new note lands on the retry"
if [ "$(cut -f2 "$S/$LBL/manifest/zzl-keep")" = "$(sha "$T/expect")" ]; then ok
else bad "the manifest kept more than the hash apply wrote: $(cat "$S/$LBL/manifest/zzl-keep")"; fi
printf '%s\n' "$NOTE v3" >"$T/note.md"
OUT=$T/out.keep-note-fail-2
fail_cp "$C/zzl-keep/SKILL.md" "$SCRIPT" apply >"$OUT" 2>&1
RC=$?
assert_rc 1 "a second failed note update"
run keep-note-unapply unapply zzl-keep
assert_rc 0 "unapply after a failed note update"
assert_same "$U/zzl-keep/SKILL.md" "$C/zzl-keep/SKILL.md" "unapply after a failed note update gives back upstream"
assert_gone "$S/$LBL/manifest/zzl-keep" "unapply drops the state"
printf '%s\n' "$NOTE" >"$T/note.md"

# ---------------------------------------------------------------------------
# 11. Upstream adopting an overlay verbatim is upstream, not a pre-#2091 copy. Once
#     apply has layered a skill here, a live file equal to its overlay is taken as
#     pristine, so unapply leaves the new upstream file alone. A skill never layered
#     here takes the overlay's base only for bytes the legacy list names.
reset
mkdir -p "$U/zzl-adopt/references" "$P/zzl-adopt/.base/references" "$P/zzl-adopt/references" "$P/zzl-adopt/scripts"
skill_md zzl-adopt '# Adopt' 'Run br create to file the issue.' >"$U/zzl-adopt/SKILL.md"
printf 'ref one\nref two\nref three\n' >"$U/zzl-adopt/references/ref.md"
cp "$U/zzl-adopt/references/ref.md" "$P/zzl-adopt/.base/references/ref.md"
printf 'ref one\nref two OURS\nref three\n' >"$P/zzl-adopt/references/ref.md"
printf 'echo ours\n' >"$P/zzl-adopt/scripts/add.sh"
{
  echo "$(sha "$P/zzl-adopt/references/ref.md") swapped zzl-adopt/references/ref.md"
  echo "$(sha "$P/zzl-adopt/scripts/add.sh") added zzl-adopt/scripts/add.sh"
} >"$T/legacy.txt"
install "$C" zzl-adopt
run adopt-apply apply
assert_rc 0 "apply before upstream adopts the overlay"
run adopt-unapply unapply zzl-adopt
assert_rc 0 "unapply before the upgrade"
mkdir -p "$U/zzl-adopt/scripts"
cp "$P/zzl-adopt/references/ref.md" "$U/zzl-adopt/references/ref.md"
cp "$P/zzl-adopt/scripts/add.sh" "$U/zzl-adopt/scripts/add.sh"
install "$C" zzl-adopt
run adopt-apply-2 apply
assert_rc 0 "apply over an upstream that adopted the overlay"
assert_lacks '^(ERROR|DRIFT|conflict)' "adoption raises nothing"
if grep -Eq "^(references/ref.md|scripts/add.sh)	" "$S/$LBL/manifest/zzl-adopt" 2>/dev/null; then
  bad "adopted upstream files were recorded as the layer's: $(cat "$S/$LBL/manifest/zzl-adopt")"
else ok; fi
run adopt-check check
assert_rc 0 "check after adoption"
run adopt-unapply-2 unapply zzl-adopt
assert_rc 0 "unapply after adoption"
assert_same "$U/zzl-adopt/references/ref.md" "$C/zzl-adopt/references/ref.md" "unapply leaves the adopted upstream file"
assert_same "$U/zzl-adopt/scripts/add.sh" "$C/zzl-adopt/scripts/add.sh" "unapply leaves an adopted added file"
assert_same "$U/zzl-adopt/SKILL.md" "$C/zzl-adopt/SKILL.md" "the note still comes off"

mkdir -p "$U/zzl-fresh/references" "$P/zzl-fresh/.base/references" "$P/zzl-fresh/references"
skill_md zzl-fresh '# Fresh' 'Run br create to file the issue.' >"$U/zzl-fresh/SKILL.md"
printf 'fresh one\nfresh OURS\n' >"$U/zzl-fresh/references/ref.md"
cp "$U/zzl-fresh/references/ref.md" "$P/zzl-fresh/references/ref.md"
printf 'fresh one\nfresh two\n' >"$P/zzl-fresh/.base/references/ref.md"
install "$C" zzl-fresh
run fresh-apply apply
assert_rc 0 "apply on a never-layered skill equal to its overlay"
if grep -q "^references/ref.md	" "$S/$LBL/manifest/zzl-fresh" 2>/dev/null; then
  bad "unlisted bytes equal to the overlay were taken as a pre-#2091 copy"
else ok; fi
run fresh-unapply unapply zzl-fresh
assert_rc 0 "unapply on the never-layered skill"
assert_same "$U/zzl-fresh/references/ref.md" "$C/zzl-fresh/references/ref.md" "unapply leaves the unlisted upstream file"
: >"$T/legacy.txt"

# ---------------------------------------------------------------------------
# 12. A caller holding the state lock hands it down through SKILLS_LOCALIZE_LOCK_FD,
#     so the jsm unit keeps every apply out from its unapply until jsm has written.
#     An fd that is not open on the lock is refused.
reset
mkdir -p "$U/zzl-locked" "$S"
skill_md zzl-locked '# Locked' 'Run br create to file the issue.' >"$U/zzl-locked/SKILL.md"
install "$C" zzl-locked
run lock-apply apply
exec 8>>"$S/.lock"
flock -x 8
OUT=$T/out.lock-unapply
SKILLS_LOCALIZE_LOCK_FD=8 timeout 20 "$SCRIPT" unapply zzl-locked >"$OUT" 2>&1
RC=$?
assert_rc 0 "unapply under a lock handed down"
assert_same "$U/zzl-locked/SKILL.md" "$C/zzl-locked/SKILL.md" "the handed-down unapply ran"
"$SCRIPT" apply >"$T/out.lock-wait" 2>&1 8>&- &
waiter=$!
sleep 1
if kill -0 "$waiter" 2>/dev/null; then ok; else bad "an apply ran while the lock was held"; fi
assert_same "$U/zzl-locked/SKILL.md" "$C/zzl-locked/SKILL.md" "nothing is layered while the lock is held"
flock -u 8
exec 8>&-
wait "$waiter"
RC=$?
OUT=$T/out.lock-wait
assert_rc 0 "the waiting apply runs once the lock is released"
noted "$U/zzl-locked/SKILL.md" "$NOTE" >"$T/expect"
assert_same "$T/expect" "$C/zzl-locked/SKILL.md" "the waiting apply layers the skill"
OUT=$T/out.lock-bad
SKILLS_LOCALIZE_LOCK_FD=7 timeout 20 "$SCRIPT" unapply zzl-locked >"$OUT" 2>&1 7>/dev/null
RC=$?
assert_rc 1 "an fd not open on the lock is refused"
assert_has "ERROR: SKILLS_LOCALIZE_LOCK_FD=7 is not open on $S/.lock" "the bad fd is named"
assert_same "$T/expect" "$C/zzl-locked/SKILL.md" "a refused unapply changes nothing"

# ---------------------------------------------------------------------------
# 9. The host's patches (<overlay>/skills-patches) add files to this repository's
#    patches and never replace them. A file only the host carries applies; where
#    both carry one, this repository's applies and a differing host copy is drift.
#    rebase writes each file back to the root it came from and never copies a host
#    file into this repository. SKILLS_PATCHES_DIR alone keeps its old meaning, the
#    only patch source, so every section above ran without the host's patches.
H=$T/home/.config/hov-stack/skills-patches
hrun() {
  OUT=$T/out.$1
  shift
  SKILLS_HOST_PATCHES_DIR=$H "$SCRIPT" "$@" >"$OUT" 2>&1
  RC=$?
}
# overlay_run TAG [NAME=VALUE...] ARGS... — the script as installed: no patch-dir
# override, so this repository's own patches (no zzl- skill among them) plus the
# overlay's, found from HOME.
overlay_run() {
  local tag=$1
  local -a envs=()
  shift
  while [ "$#" -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  OUT=$T/out.$tag
  env -u SKILLS_PATCHES_DIR -u SKILLS_HOST_PATCHES_DIR -u HOV_STACK_OVERLAY -u XDG_CONFIG_HOME \
    "${envs[@]}" "$SCRIPT" "$@" >"$OUT" 2>&1
  RC=$?
}
nlines() {   # nlines SEARCH=REPLACE... -> notes.md text
  local l kv
  for l in 'n a' 'n b' 'n c' 'n d' 'n e' 'n f' 'n g'; do
    for kv in "$@"; do [ "$l" = "${kv%%=*}" ] && l=${kv#*=}; done
    printf '%s\n' "$l"
  done
}

# A skill only the host patches, found through the overlay.
reset
rm -rf "$T/home/.config"
mkdir -p "$H/zzl-hostonly/.base" "$U/zzl-hostonly"
lines_with zzl-hostonly >"$H/zzl-hostonly/.base/SKILL.md"
lines_with zzl-hostonly 'line c=line c HOST' >"$H/zzl-hostonly/SKILL.md"
lines_with zzl-hostonly 'line f=line f THEIRS' >"$U/zzl-hostonly/SKILL.md"
install "$C" zzl-hostonly
install "$X" zzl-hostonly
run host-ignored apply
assert_rc 0 "apply with SKILLS_PATCHES_DIR alone"
assert_same "$U/zzl-hostonly/SKILL.md" "$C/zzl-hostonly/SKILL.md" "SKILLS_PATCHES_DIR alone keeps the host's patches out"
overlay_run host-default apply
assert_rc 0 "apply as installed, with an overlay"
lines_with zzl-hostonly 'line c=line c HOST' 'line f=line f THEIRS' >"$T/expect"
assert_same "$T/expect" "$C/zzl-hostonly/SKILL.md" "a skill only the host patches is layered (claude)"
assert_same "$T/expect" "$X/zzl-hostonly/SKILL.md" "a skill only the host patches is layered (codex)"
if [ -e "$S/$LBL/migrated/zzl-hostonly" ]; then ok; else bad "a host-only patch did not mark its skill migrated"; fi
overlay_run host-default-check check
assert_rc 0 "check as installed, with an overlay"
assert_line 'skills policy in sync' "check as installed, with an overlay"
# Moved out of HOME, the overlay is found only through XDG_CONFIG_HOME.
mkdir -p "$T/xdgcfg"
mv "$T/home/.config/hov-stack" "$T/xdgcfg/hov-stack"
overlay_run host-xdg XDG_CONFIG_HOME="$T/xdgcfg" check
assert_rc 0 "an absolute XDG_CONFIG_HOME names the overlay"
assert_line 'skills policy in sync' "an absolute XDG_CONFIG_HOME names the overlay"
overlay_run host-xdg-unset check
assert_rc 1 "check without XDG_CONFIG_HOME once the overlay left HOME"
assert_has 'DRIFT: claude zzl-hostonly/SKILL.md is not the localized copy' "without XDG_CONFIG_HOME the moved overlay is not read"
mv "$T/xdgcfg/hov-stack" "$T/home/.config/hov-stack"
overlay_run host-relative HOV_STACK_OVERLAY=relative/overlay check
assert_rc 1 "check with a relative overlay"
assert_has 'DRIFT: claude zzl-hostonly/SKILL.md is not the localized copy' "a relative overlay is ignored"
overlay_run host-missing HOV_STACK_OVERLAY="$T/no-overlay" check
assert_rc 1 "check with a missing overlay"
assert_has 'DRIFT: claude zzl-hostonly/SKILL.md is not the localized copy' "a missing overlay adds nothing"
overlay_run host-empty SKILLS_HOST_PATCHES_DIR= check
assert_rc 1 "check with SKILLS_HOST_PATCHES_DIR empty"
assert_has 'DRIFT: claude zzl-hostonly/SKILL.md is not the localized copy' "an empty SKILLS_HOST_PATCHES_DIR reads no host patches"
OUT=$T/out.host-nolib
env -u SKILLS_PATCHES_DIR -u SKILLS_HOST_PATCHES_DIR -u HOV_STACK_OVERLAY -u XDG_CONFIG_HOME \
  "$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh" check >"$OUT" 2>&1
RC=$?
assert_rc 1 "check from a copy without lib/overlay.sh"
assert_has "ERROR: $T/wt/.claude/worktrees/x/claude/lib/overlay.sh is missing — the host's skill patches were not read" "a missing overlay library is named"
overlay_run host-unapply unapply zzl-hostonly
assert_rc 0 "unapply a skill only the host patches"
assert_same "$U/zzl-hostonly/SKILL.md" "$C/zzl-hostonly/SKILL.md" "unapply puts upstream back under a host-only patch"
overlay_run host-reapply apply
rm -rf "$S"
overlay_run host-unrecorded unapply zzl-hostonly
assert_rc 3 "unapply a host-patched skill with no saved state"
assert_has 'unrecorded: claude zzl-hostonly has an overlay but no saved pristine copy' "a host-only patch counts as an overlay"

# Both roots patch one skill: disjoint files both apply, each from its own base; a
# file both carry applies once, from this repository.
reset
rm -rf "$T/home/.config"
mkdir -p "$P/zzl-both/.base" "$H/zzl-both/.base" "$H/zzl-both/scripts" "$U/zzl-both"
lines_with zzl-both >"$P/zzl-both/.base/SKILL.md"
lines_with zzl-both 'line b=line b REPO' >"$P/zzl-both/SKILL.md"
nlines >"$H/zzl-both/.base/notes.md"
nlines 'n b=n b HOST' >"$H/zzl-both/notes.md"
printf 'echo host\n' >"$H/zzl-both/scripts/host.sh"
lines_with zzl-both 'line f=line f V2' >"$U/zzl-both/SKILL.md"
nlines 'n f=n f V2' >"$U/zzl-both/notes.md"
install "$C" zzl-both
mkdir -p "$P/zzl-shadow/.base" "$H/zzl-shadow/.base" "$U/zzl-shadow"
lines_with zzl-shadow >"$P/zzl-shadow/.base/SKILL.md"
lines_with zzl-shadow 'line c=line c REPO' >"$P/zzl-shadow/SKILL.md"
cp "$P/zzl-shadow/.base/SKILL.md" "$H/zzl-shadow/.base/SKILL.md"
cp "$P/zzl-shadow/SKILL.md" "$H/zzl-shadow/SKILL.md"
lines_with zzl-shadow >"$U/zzl-shadow/SKILL.md"
install "$C" zzl-shadow
install "$X" zzl-shadow
hrun host-both apply
assert_rc 0 "apply with host files beside this repository's"
lines_with zzl-both 'line b=line b REPO' 'line f=line f V2' >"$T/expect"
assert_same "$T/expect" "$C/zzl-both/SKILL.md" "this repository's file applies beside the host's"
nlines 'n b=n b HOST' 'n f=n f V2' >"$T/expect"
assert_same "$T/expect" "$C/zzl-both/notes.md" "the host's file merges onto upstream from the host's base"
assert_same "$H/zzl-both/scripts/host.sh" "$C/zzl-both/scripts/host.sh" "a file only the host adds is laid down"
lines_with zzl-shadow 'line c=line c REPO' >"$T/expect"
assert_same "$T/expect" "$C/zzl-shadow/SKILL.md" "a file both roots carry applies once"
assert_lacks 'DRIFT' "a host copy identical to this repository's is not drift"
hrun host-both-check check
assert_rc 0 "check with an identical host copy"
lines_with zzl-shadow 'line c=line c HOST' >"$H/zzl-shadow/SKILL.md"
hrun host-shadow-check check
assert_rc 1 "check with a differing host copy"
assert_line "DRIFT: host patch $H/zzl-shadow/SKILL.md differs from this repository's copy, which applies instead — delete the host copy, or move its change into this repository" "the differing host copy is named"
if [ "$(grep -c 'DRIFT: host patch' "$OUT")" = 1 ]; then ok; else bad "the differing host copy was named more than once in one run"; fi
hrun host-shadow-apply apply
assert_rc 0 "apply with a differing host copy"
lines_with zzl-shadow 'line c=line c REPO' >"$T/expect"
assert_same "$T/expect" "$C/zzl-shadow/SKILL.md" "this repository's copy beats a differing host copy (claude)"
assert_same "$T/expect" "$X/zzl-shadow/SKILL.md" "this repository's copy beats a differing host copy (codex)"
assert_has "DRIFT: host patch $H/zzl-shadow/SKILL.md" "apply names the differing host copy too"
cp "$P/zzl-shadow/SKILL.md" "$H/zzl-shadow/SKILL.md"
lines_with zzl-shadow 'line a=line a OLD' >"$H/zzl-shadow/.base/SKILL.md"
hrun host-shadow-base check
assert_rc 1 "check with a differing host base"
assert_has "DRIFT: host patch $H/zzl-shadow/SKILL.md" "a host copy whose base differs is named"
rm -rf "$H/zzl-shadow"

# rebase from a worktree writes each file back to the root it came from.
OUT=$T/out.host-rebase
SKILLS_HOST_PATCHES_DIR=$H "$T/wt/.claude/worktrees/x/claude/scripts/skills-localize.sh" rebase zzl-both 2 >"$OUT" 2>&1
RC=$?
assert_rc 0 "rebase a skill both roots patch"
assert_same "$U/zzl-both/SKILL.md" "$P/zzl-both/.base/SKILL.md" "rebase moves this repository's base forward"
lines_with zzl-both 'line b=line b REPO' 'line f=line f V2' >"$T/expect"
assert_same "$T/expect" "$P/zzl-both/SKILL.md" "rebase writes this repository's merge here"
assert_same "$U/zzl-both/notes.md" "$H/zzl-both/.base/notes.md" "rebase moves the host's base forward on the host"
nlines 'n b=n b HOST' 'n f=n f V2' >"$T/expect"
assert_same "$T/expect" "$H/zzl-both/notes.md" "rebase writes the host's merge on the host"
printf 'echo host\n' >"$T/expect"
assert_same "$T/expect" "$H/zzl-both/scripts/host.sh" "rebase keeps a file only the host adds"
for f in notes.md .base/notes.md scripts/host.sh .base/scripts/host.sh; do
  assert_gone "$P/zzl-both/$f" "rebase never copies a host file into this repository ($f)"
done
for f in SKILL.md .base/SKILL.md .base/scripts/host.sh; do
  assert_gone "$H/zzl-both/$f" "rebase never copies this repository's file to the host ($f)"
done
if [ "$(cat "$P/zzl-both/.base/VERSION" 2>/dev/null)" = 2 ] && [ "$(cat "$H/zzl-both/.base/VERSION" 2>/dev/null)" = 2 ]; then ok
else bad "rebase did not record version 2 in both roots"; fi
assert_has "$H/zzl-both" "rebase names the host files it wrote"
hrun host-after-rebase apply
assert_rc 0 "apply after a two-root rebase"
assert_lacks '^(localized|restored|removed) ' "a two-root rebase leaves the live files as they were"
hrun host-after-rebase-check check
assert_rc 0 "check after a two-root rebase"

# ---------------------------------------------------------------------------
if [ ! -s "$JSM_CALLED" ]; then ok; else bad "the layer called jsm: $(cat "$JSM_CALLED")"; fi
HOME=$REAL_HOME XDG_STATE_HOME=$REAL_XDG
[ -n "$XDG_STATE_HOME" ] || unset XDG_STATE_HOME
if [ "$(real_state_sum)" = "$REAL_STATE_BEFORE" ]; then ok
else bad "the real skills-localize state changed during this suite"; fi

assertion_floor=100
assertion_total=$((pass + fail))
[ "$assertion_total" -ge "$assertion_floor" ] || bad "assertion floor: ran $assertion_total, expected at least $assertion_floor"
if [ "$fail" -eq 0 ]; then
  echo "ok — skills-localize layer: $pass/$assertion_total assertions passed (floor $assertion_floor)"
else
  echo "FAIL — skills-localize layer: $fail of $assertion_total assertions failed" >&2
  exit 1
fi
