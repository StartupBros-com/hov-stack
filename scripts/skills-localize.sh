#!/usr/bin/env bash
# skills-localize.sh — re-assert local skill policy over the jsm-managed skill trees.
#
# WHY THIS EXISTS
#   Most of ~/.claude/skills is owned by jsm (jeffreys-skills.md). `jsm install-all`,
#   `jsm upgrade`, and the nightly auto-update re-add skills we retired and replace
#   local edits with pristine upstream copies. `pin` only freezes a *version*, not content.
#   This reconciler re-applies our local policy IDEMPOTENTLY so it survives jsm:
#     • retired skills stay uninstalled (re-trashed if jsm re-adds them)
#     • local forks stay deployed
#     • the local layer stays applied over kept jsm skills (LOCAL LAYER below)
#
# SOURCES OF TRUTH (version-controlled in this repository, except the host's patches)
#   retired-skills.txt           one skill name per line (# comments ok) → kept uninstalled.
#                                 `<name> replaced-by=<plugin>@<marketplace>` holds the
#                                 retirement (DRIFT, skill left in place) until
#                                 installed_plugins.json records that plugin at user scope,
#                                 so retiring never leaves a host with neither (#358)
#   plugins/hov-stack/skills/<name>/  full local (non-jsm) skills → deployed into ~/.claude/skills/
#   skills-patches/<name>/<rel>   content overlays, 3-way merged onto the installed jsm skill
#   skills-patches/<name>/.base/  the upstream files each overlay was written against, plus
#                                 VERSION; never deployed
#   <overlay>/skills-patches/     the host's patches, same layout (README.md, "The private
#                                 overlay"). They add files to this repository's, never
#                                 replace them: where both carry a file, this repository's
#                                 applies and a differing host copy is DRIFT.
#                                 SKILLS_HOST_PATCHES_DIR names another dir, or none when
#                                 empty; SKILLS_PATCHES_DIR alone means no host patches
#   local-tooling-note.md        one-line note put after the frontmatter of every jsm skill
#   local-tooling-note.codex.md  whose pristine text names beads/br/bv, NTM, Agent Mail or
#                                 idea-wizard (none installed here); the Codex trees get the
#                                 .codex one
#   codex-skills.txt             subset of plugins/hov-stack/skills/ that ALSO deploys to ~/.codex/skills/
#   skills-legacy-overlays.txt   hashes of the files the pre-#2091 layer wrote; a skill that
#                                 still holds one is reinstalled, never taken as pristine, and
#                                 only listed bytes let an overlay's .base stand in for pristine
#
# LOCAL LAYER (dotfiles#2091)
#   jsm refuses to upgrade a skill whose files differ from what it installed, so the layer
#   is reversible. `apply` saves the pristine copy of every file it changes, and the hash of
#   what it wrote, under $SKILLS_LOCALIZE_STATE (default ~/.local/state/skills-localize).
#   The jsm auto-update wrapper runs `unapply <skill>` before `jsm upgrade <skill>`: the
#   pristine copies go back wherever the live file still matches what apply wrote, jsm
#   upgrades a plain skill, and ExecStopPost re-applies. A file edited by hand after apply
#   is never overwritten: apply and check report it as DRIFT, and unapply exits 4 naming it.
#   Where upstream changed the same lines as an overlay, our side wins and the file is
#   listed in $SKILLS_LOCALIZE_STATE/conflicts, which the weekly jsm digest names; `rebase`
#   (from a worktree) then moves that overlay's base forward.
#   Runs serialize on $SKILLS_LOCALIZE_STATE/.lock. A caller already holding it exclusively
#   (the wrapper holds it from unapply until jsm has written) passes that fd as
#   SKILLS_LOCALIZE_LOCK_FD, and the run uses the caller's lock instead of waiting on it.
#
# THREE SKILL TREES, ONE POLICY
#   jsm installs into ~/.claude/skills and mirrors every skill into ~/.agents/skills (and
#   ~/.gemini/skills). Codex CLI reads ~/.agents/skills and its deprecated
#   $CODEX_HOME/skills (~/.codex/skills), and lists a skill found in both twice (codex
#   0.166.0, seen in its session logs 2026-10-29). Everything in THIS file was
#   Claude-only until codex-skills.txt: a fork added to the local skills never reached
#   Codex, so emil-design-eng and kill-ai-slop were live in Claude and simply absent from
#   Codex. codex-skills.txt is an explicit allowlist rather than a blanket sync — see that
#   file for why; it deploys to ~/.codex/skills.
#
#   The layer is NOT allowlisted: an overlay or note is a correction to a skill we keep,
#   and a correction that applies in Claude applies in Codex (2026-08-06: all 7 overlay
#   skills had diverged because only the Claude tree was patched). It runs over all three
#   trees (labels claude, codex, agents) and skips any tree where the skill is not
#   installed. jsm also refuses an upgrade when the ~/.agents/skills mirror holds local
#   edits, so unapply restores that tree too. Each label keeps its own saved state, so two
#   labels must never point at one directory.
#
# MODES
#   apply                 (default) enforce policy on ~/.claude/skills (+ ~/.codex/skills
#                         and ~/.agents/skills for the layer, ~/.codex/skills for
#                         allowlisted forks)
#   --dry-run             print what apply would do, change nothing. It is a mode, not a
#                         flag: `apply --dry-run` exits 2, as does any extra word after
#                         apply, --dry-run, check or audit
#   check                exit 1 + DRIFT: lines if a live tree diverges (consumed by
#                         harness-doctor)
#   audit                 read-only report (dotfiles#1202): for every file under
#                         plugins/hov-stack/skills/, print name | sha256 | deployed-claude
#                         (same/DIFFERS/missing) | deployed-codex (same/DIFFERS/missing/n/a,
#                         n/a when the skill is not in codex-skills.txt). No writes.
#   unapply <skill>...    put a skill's pristine files back in every tree. Exit 4 when a
#                         file was edited by hand (nothing changed), 3 when the skill has an
#                         overlay but no saved pristine copy, or still holds pre-#2091 overlay
#                         text (whose added files it removes): only `jsm install --force`
#                         restores either. 2 on a bad name, 1 on an error (state saved for
#                         another tree, a failed write).
#   forget <skill>...     drop a skill's saved state; the next apply treats the live files
#                         as pristine
#   rebase <skill> <ver>  from a worktree's copy of this script: make the installed
#                         pristine files the overlay's new base and the merged result its new
#                         overlay; review the diff before committing. Each file goes back to
#                         the root it came from, so a host patch is rewritten in place, outside
#                         this repository's review
#
# WIRING
#   1. dotup runs `skills-localize.sh apply` after install.sh (2026-09-02, #909;
#      deliberately dotup and not sync.sh install, which can be run from a worktree)
#   2. the jsm auto-update unit: the wrapper runs `unapply` per pending skill, and
#      ExecStopPost (jsm-auto-update.service.d/zz-skills-localize.conf) runs `apply`
#   3. harness-doctor runs `skills-localize.sh check` and warns on DRIFT
set -uo pipefail

# Resolve THROUGH symlinks. The canonical invocation path is ~/.claude/scripts/, which
# sync.sh symlinks to dotfiles/scripts/. A logical `cd ../` from a symlinked dir
# collapses to ~/.claude (WRONG — the tool would find no manifest and silently no-op).
# readlink -f + `cd -P` resolves to the real dotfiles dir regardless of how we were invoked.
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(cd -P "$(dirname "$SELF")/.." && pwd) || { echo "skills-localize: cannot resolve script directory" >&2; exit 1; }
SKILLS="${SKILLS_DIR:-$HOME/.claude/skills}"
TRASH="$SKILLS/.trash"
RETIRED="$HERE/retired-skills.txt"
# Claude Code's record of installed plugins, read for replaced-by= entries. Overridable
# so tests can point at a fixture.
INSTALLED_PLUGINS="${SKILLS_INSTALLED_PLUGINS:-$HOME/.claude/plugins/installed_plugins.json}"
# Overridable so tests can point at fixture trees instead of this repo's real
# plugins/hov-stack/skills/, codex-skills.txt, overlays, notes and saved layer state.
LOCAL="${SKILLS_LOCAL_DIR:-$HERE/plugins/hov-stack/skills}"
PATCHES="${SKILLS_PATCHES_DIR:-$HERE/skills-patches}"
NOTE_CLAUDE="${SKILLS_NOTE_FILE:-$HERE/local-tooling-note.md}"
NOTE_CODEX="${SKILLS_NOTE_FILE_CODEX:-$HERE/local-tooling-note.codex.md}"
STATE="${SKILLS_LOCALIZE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/skills-localize}"
CODEX_SKILLS="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
CODEX_LIST="${CODEX_SKILLS_LIST:-$HERE/codex-skills.txt}"
AGENTS_SKILLS="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
LEGACY="${SKILLS_LEGACY_LIST:-$HERE/skills-legacy-overlays.txt}"

# The note's opening words: a line starting with them right after the frontmatter is ours.
MARKER='> **Local tooling on this machine.**'
# Vocabulary that earns a skill the note, matched case-insensitively against its pristine
# *.md text with the note line itself excluded.
# Covers every command skills-beads-sweep-check.py flags, so a skill it would call CRITICAL
# always earns the note.
VOCAB='\bbr (create|list|close|update|ready|show|sync|dep)\b|\bbv (--|robot|prioritize\b)|\bbd (onboard|ready|show|update|close|sync)\b|\bbeads\b|\bbeads-|\bntm\b|agent mail|agent-mail|mcp_agent_mail|file_reservation|idea-wizard'

usage() { echo "usage: skills-localize.sh [apply|--dry-run|check|audit|unapply <skill>...|forget <skill>...|rebase <skill> <version>]" >&2; }

# apply, --dry-run, check and audit take no further arguments. A trailing word used to
# be ignored, so `apply --dry-run` did a real apply; refuse it before anything changes.
# Checked on the original argv, before the modes below shift theirs.
if [ "$#" -gt 1 ]; then
  case "$1" in
    apply|--dry-run|check|audit)
      echo "skills-localize: '$1' takes no further arguments (got: ${*:2}). For a dry run, run 'skills-localize.sh --dry-run' with nothing after it." >&2
      usage; exit 2 ;;
  esac
fi

MODE="apply"; DRY=0
case "${1:-apply}" in
  apply)          MODE="apply" ;;
  --dry-run)      MODE="apply"; DRY=1 ;;
  check)          MODE="check" ;;
  audit)          MODE="audit" ;;
  unapply|forget) MODE="$1"; shift; [ "$#" -gt 0 ] || { usage; exit 2; } ;;
  rebase)         MODE="rebase"; shift; [ "$#" -eq 2 ] || { usage; exit 2; } ;;
  -h|--help)      awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$SELF"; exit 0 ;;
  *)              usage; exit 2 ;;
esac

drift=0; errors=0
say()  { [ "$MODE" = check ] || echo "$@"; }
note() { echo "$@"; }               # always shown (dry-run plan / drift / errors)
ts()   { date +%Y%m%d%H%M%S 2>/dev/null || echo manual; }

WORK=""
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

# The host's patches (SOURCES OF TRUTH). A unit runs without a session's environment,
# so the overlay is found the way lib/overlay.sh finds it, from HOME.
HOST_PATCHES=""
if [ -n "${SKILLS_HOST_PATCHES_DIR+set}" ]; then
  HOST_PATCHES=$SKILLS_HOST_PATCHES_DIR
elif [ -z "${SKILLS_PATCHES_DIR+set}" ] && [ "$MODE" != audit ] && [ "$MODE" != forget ]; then
  if [ -f "$HERE/lib/overlay.sh" ]; then
    # shellcheck source=lib/overlay.sh
    . "$HERE/lib/overlay.sh"
    HOST_PATCHES=$(overlay_dir) && HOST_PATCHES=$HOST_PATCHES/skills-patches
  else
    note "ERROR: $HERE/lib/overlay.sh is missing — the host's skill patches were not read"
    errors=1; drift=1
  fi
fi

# Every skill name here arrives from a hand-edited manifest and is then interpolated
# into a path that gets `rsync --delete`d or `mv`d. A name is a single path SEGMENT —
# reject anything that could climb out of the tree. `..` is the dangerous one and the
# most plausible typo: it survives an `[ -d "$LOCAL/$name" ]` existence check (the
# parent dir does exist), and `$SKILLS/..` is ~/.claude, so an unvalidated `..` would
# rsync over — or move to .trash — the entire config directory.
valid_skill_name() {
  local name="$1"
  case "$name" in
    ""|.|..)      return 1 ;;
    */*|*\\*)     return 1 ;;      # no separators — a name is one segment
    -*)           return 1 ;;      # never let a name become a command flag
  esac
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  return 0
}

# Reject and account for a bad manifest entry, so a typo is loud instead of destructive.
reject_name() {
  local name="$1" src="$2"
  note "ERROR: $src entry '$name' is not a valid skill name — refusing to touch it"
  errors=1; drift=1
}

# Prefer jsm's own uninstall (keeps jsm.db consistent + archives to .trash); fall
# back to a manual move so the tool still works offline or if jsm is absent.
# plugin_installed <name@marketplace> → 0 when installed_plugins.json records the plugin at
# user or managed scope, so its skills load in every session; 1 when it does not (a
# project-scoped install loads in one project only); 2 when the record cannot be read (no
# jq, malformed JSON). retire_one holds the retirement on anything but 0.
plugin_installed() {
  local out
  [ -f "$INSTALLED_PLUGINS" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  out=$(jq -r --arg p "$1" '(.plugins[$p] // []) | map(select(.scope == "user" or .scope == "managed")) | length' \
    "$INSTALLED_PLUGINS" 2>/dev/null) || return 2
  case "$out" in
    0)          return 1 ;;
    ''|*[!0-9]*) return 2 ;;
    *)          return 0 ;;
  esac
}

# retire_one <name> [<plugin>@<marketplace>] — the second argument is the entry's
# replaced-by= plugin. While that plugin is not installed, the skill stays and the hold
# is DRIFT in every mode, so harness-doctor's `check` surfaces it (#358).
retire_one() {
  local name="$1" replacement="${2:-}"; local dir="$SKILLS/$name"
  [ -n "$name" ] || return 0                      # never operate on an empty name
  valid_skill_name "$name" || { reject_name "$name" "retired-skills.txt"; return 0; }
  [ -e "$dir" ] || return 0                       # already gone → idempotent no-op
  if [ -n "$replacement" ]; then
    local rc=0 why
    plugin_installed "$replacement" || rc=$?
    if [ "$rc" -ne 0 ]; then
      why="its replacement plugin $replacement is not installed at user scope"
      [ "$rc" -eq 2 ] && why="$INSTALLED_PLUGINS could not be read (jq missing or malformed JSON), so its replacement plugin $replacement is unconfirmed"
      note "DRIFT: retired skill '$name' is held in ~/.claude/skills: $why. Run 'claude plugin install $replacement --scope user'; the next apply then retires it"
      drift=1; return 0
    fi
  fi
  if [ "$MODE" = check ]; then
    note "DRIFT: retired skill '$name' is present in ~/.claude/skills (jsm re-added it?)"; drift=1; return 0
  fi
  if [ "$DRY" = 1 ]; then note "would retire: $name"; return 0; fi
  # jsm list is a padded table — match the FIRST column, not the whole line.
  if command -v jsm >/dev/null 2>&1 && JSM_OFFLINE=true jsm list 2>/dev/null | awk '{print $1}' | grep -qx -- "$name"; then
    if JSM_OFFLINE=true jsm uninstall --json "$name" >/dev/null 2>&1; then note "retired (jsm): $name"; return 0; fi
    note "WARN: jsm uninstall failed for '$name' — falling back to .trash"
  fi
  mkdir -p "$TRASH"
  if mv "$dir" "$TRASH/${name}-localize-$(ts)"; then note "retired (moved to .trash): $name"
  else note "ERROR: could not retire '$name'"; errors=1; fi
}

# Each line is `<name> [replaced-by=<plugin>@<marketplace>]`, # comments allowed. Any
# other field, or a malformed replacement, is an ERROR and the entry is left alone: a
# typo must never retire a skill under looser rules than the line meant.
enforce_retired() {
  [ -f "$RETIRED" ] || return 0
  local line name rest tok replacement
  local -a fields
  while IFS= read -r line; do
    line="${line%%#*}"
    name=""; rest=""
    read -r name rest <<<"$line"
    [ -n "$name" ] || continue
    replacement=""
    fields=()
    read -r -a fields <<<"$rest"
    for tok in ${fields[@]+"${fields[@]}"}; do
      case "$tok" in
        replaced-by=*)
          [ -z "$replacement" ] || {
            note "ERROR: retired-skills.txt entry '$name' names more than one replaced-by= — refusing to touch it"
            errors=1; drift=1; continue 2; }
          replacement="${tok#replaced-by=}"
          [[ "$replacement" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
            note "ERROR: retired-skills.txt entry '$name' has a malformed '$tok' (want replaced-by=<plugin>@<marketplace>) — refusing to touch it"
            errors=1; drift=1; continue 2; } ;;
        *)
          note "ERROR: retired-skills.txt entry '$name' has an unknown field '$tok' — refusing to touch it"
          errors=1; drift=1; continue 2 ;;
      esac
    done
    retire_one "$name" "$replacement"
  done < "$RETIRED"
}

# Deploy ONE fork dir into ONE target skills tree. Shared by the Claude tree and the
# Codex tree so both get identical copy/drift semantics; $4 labels the tree in output
# so a DRIFT line says which one moved.
sync_fork() {
  local src="$1" dstroot="$2" name="$3" label="$4"
  # Chokepoint guard: this is the only place `rsync --delete` runs, so validate here
  # too even though callers already do. Defence in depth on a destructive operation.
  # node_modules is excluded in both directions: a skill with a package.json gets
  # `pnpm install` run once in the deployed copy, and neither --delete nor `check`
  # may touch that tree (sign-pdf, 2026-09-11; skills-localize-node-modules.test.sh).
  valid_skill_name "$name" || { reject_name "$name" "$label deploy"; return 0; }
  # If the live entry is a SYMLINK (the pre-existing convention: ~/.claude/skills/<x>
  # → <checkout>/plugins/hov-stack/skills/<x>), it already IS the deployment. `rsync --delete` would
  # follow the symlink and destroy the real target — so never touch symlinked forks.
  [ -L "$dstroot/$name" ] && return 0
  if [ "$MODE" = check ]; then
    rsync -rcln --delete --exclude=node_modules --out-format='%n' "$src" "$dstroot/$name/" 2>/dev/null | grep -q . &&
      { note "DRIFT: $label fork '$name' differs from the skill pack (run apply)"; drift=1; }
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    rsync -rcln --delete --exclude=node_modules --out-format='%n' "$src" "$dstroot/$name/" 2>/dev/null | grep -q . &&
      note "would deploy $label fork: $name"
    return 0
  fi
  mkdir -p "$dstroot/$name"
  if rsync -a --delete --exclude=node_modules "$src" "$dstroot/$name/"; then note "deployed $label fork: $name"
  else note "ERROR: failed to deploy $label fork '$name'"; errors=1; fi
}

deploy_forks() {
  [ -d "$LOCAL" ] || return 0
  local d name
  for d in "$LOCAL"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ -n "$name" ] || continue
    [ -f "$d/SKILL.md" ] || { note "WARN: plugins/hov-stack/skills/$name has no SKILL.md — skipped"; continue; }
    sync_fork "$d" "$SKILLS" "$name" "claude"
  done
}

# Codex keeps its own skills tree; jsm installs into it independently and nothing here
# reached it before codex-skills.txt existed. Allowlist only — see that file.
deploy_codex() {
  [ -f "$CODEX_LIST" ] || return 0
  if [ ! -d "$CODEX_SKILLS" ]; then
    say "codex: $CODEX_SKILLS absent — skipping (Codex not installed here)"
    return 0
  fi
  local line name
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    name="$line"
    valid_skill_name "$name" || { reject_name "$name" "codex-skills.txt"; continue; }
    if [ ! -d "$LOCAL/$name" ]; then
      note "WARN: codex-skills.txt lists '$name' but plugins/hov-stack/skills/$name does not exist"
      continue
    fi
    # Codex ignores Claude's `disable-model-invocation`; its gate is agents/openai.yaml
    # (see codex-skills.txt). A fork demoted in Claude but missing that file is silently
    # model-invocable in Codex — the exact gap #219 fixed for six forks. Advisory ONLY:
    # this is a repo-level policy omission, not live-tree drift, and harness-doctor
    # consumes check's exit code, so it must never set drift=1.
    if [ ! -f "$LOCAL/$name/agents/openai.yaml" ] &&
       grep -qs '^disable-model-invocation:[[:space:]]*true' "$LOCAL/$name/SKILL.md"; then
      note "WARN: codex fork '$name' is invoke-only in Claude but ships no agents/openai.yaml — it is model-invocable in Codex"
    fi
    sync_fork "$LOCAL/$name/" "$CODEX_SKILLS" "$name" "codex"
  done < "$CODEX_LIST"
}

# A dangling symlink in a skills tree is pure breakage: the skill cannot load, and the
# dead entry still occupies the name so nothing will reinstall it. Three were found in
# ~/.codex/skills on 2026-08-05 (agent-browser, last30days, skill-developer), all
# pointing at ~/.claude/skills entries that no longer exist. Top level only — never
# descend, so a skill's own internal symlinks are left alone.
reap_broken_links() {
  local root="$1" label="$2" link
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' link; do
    if [ "$MODE" = check ]; then
      note "DRIFT: $label has a broken symlink '$(basename "$link")' → $(readlink "$link")"; drift=1; continue
    fi
    if [ "$DRY" = 1 ]; then note "would remove broken $label symlink: $(basename "$link") → $(readlink "$link")"; continue; fi
    if rm "$link"; then note "removed broken $label symlink: $(basename "$link")"
    else note "ERROR: could not remove broken symlink '$link'"; errors=1; fi
  done < <(find "$root" -maxdepth 1 -type l ! -exec test -e {} \; -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------------------
# Local layer (dotfiles#2091). State per tree label (claude|codex|agents) under $STATE/<label>/:
#   root                the tree path this state belongs to
#   manifest/<skill>    one line per file the layer changed: rel<TAB>sha256 of what apply
#                       wrote<TAB>file|absent (whether pristine had the file). After a
#                       failed write the hash field also lists, space-separated, what the
#                       last apply wrote, and a file no longer layered keeps its line
#   pristine/<skill>/   the pristine copies
#   migrated/<skill>    apply has layered this overlay skill here, so a live file equal to
#                       one of its overlays is upstream's, not a pre-#2091 copy
# $STATE/conflicts lists "<label> <skill>/<rel>" where our side won a conflict.

LABELS=(claude codex agents)
tree_root() { case "$1" in claude) echo "$SKILLS" ;; codex) echo "$CODEX_SKILLS" ;; agents) echo "$AGENTS_SKILLS" ;; esac; }
note_file() { case "$1" in claude) echo "$NOTE_CLAUDE" ;; codex|agents) echo "$NOTE_CODEX" ;; esac; }
sha_of()    { sha256sum "$1" | awk '{print $1}'; }

# take_lock exclusive|shared — dotup and the jsm unit can run this at the same time. A
# lock the caller holds comes in as SKILLS_LOCALIZE_LOCK_FD: locking a new open of the file
# would wait on the caller, and re-locking the inherited fd would let a waiter in between.
take_lock() {
  local flag=-x fd="${SKILLS_LOCALIZE_LOCK_FD:-}"
  if [ "$1" = exclusive ]; then
    mkdir -p "$STATE" || { note "ERROR: cannot create $STATE"; exit 1; }
  else
    [ -d "$STATE" ] || return 0               # nothing saved yet; a read must not create state
    flag=-s
  fi
  if [ -n "$fd" ]; then
    [[ "$fd" =~ ^[0-9]+$ ]] && [ /proc/self/fd/"$fd" -ef "$STATE/.lock" ] && return 0
    note "ERROR: SKILLS_LOCALIZE_LOCK_FD=$fd is not open on $STATE/.lock"; exit 1
  fi
  exec 9>>"$STATE/.lock" || { note "ERROR: cannot open $STATE/.lock"; exit 1; }
  flock "$flag" -w 120 9 || { note "ERROR: timed out waiting for $STATE/.lock"; exit 1; }
}

# state_owns <label> <root> — the saved state for this label belongs to this tree. A run
# with SKILLS_DIR pointed at a fixture but the default state dir would otherwise read the
# real skills as missing and drop their saved pristine copies.
state_owns() {
  local f="$STATE/$1/root"
  [ -f "$f" ] || return 0
  [ "$(cat "$f")" = "$2" ] && return 0
  note "ERROR: $STATE/$1 holds state for $(cat "$f"), not $2 — $1 layer skipped (set SKILLS_LOCALIZE_STATE)"
  errors=1; drift=1
  return 1
}

# A manifest path: relative, no `..` segment, no leading dash.
valid_rel() {
  case "$1" in ""|/*|-*|..|../*|*/..|*/../*) return 1 ;; esac
  return 0
}

# frontmatter_end <file> — the line number of the `---` closing a leading frontmatter.
frontmatter_end() {
  awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { print NR; exit }' "$1" 2>/dev/null
}

# note_insert <in> <out> <note> — the note as its own paragraph right after the frontmatter.
note_insert() {
  local n; n=$(frontmatter_end "$1"); [ -n "$n" ] || return 1
  [ "$(wc -l < "$1")" -ge "$n" ] || return 1          # closing line must end in a newline
  { head -n "$n" "$1"; printf '\n%s\n' "$3"; tail -n +"$((n + 1))" "$1"; } > "$2"
}

# note_strip <in> <out> — the exact inverse of note_insert; fails when no note is present.
note_strip() {
  local n l1 l2; n=$(frontmatter_end "$1"); [ -n "$n" ] || return 1
  [ "$(wc -l < "$1")" -ge "$((n + 2))" ] || return 1
  l1=$(sed -n "$((n + 1))p" "$1"); l2=$(sed -n "$((n + 2))p" "$1")
  [ -z "$l1" ] && [[ "$l2" == "$MARKER"* ]] || return 1
  { head -n "$n" "$1"; tail -n +"$((n + 3))" "$1"; } > "$2"
}

# note_line <label> — the validated one-line note for that tree.
note_line() {
  local f line=""; f=$(note_file "$1")
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" || [ -n "$line" ] || return 1
  [[ "$line" == "$MARKER"* ]] || return 1
  printf '%s' "$line"
}

# names_vocab <file> — the file names the uninstalled tool vocabulary. grep -c reads to
# the end, so pipefail never sees the first grep die of SIGPIPE.
names_vocab() { grep -vF -- "$MARKER" "$1" 2>/dev/null | grep -Eic -- "$VOCAB" >/dev/null; }

# root_rels <root> <skill> — one root's overlay files for a skill, relative to its dir,
# .base/ excluded. An empty root (no host patches) has none.
root_rels() {
  local dir="$1/$2"
  [ -n "$1" ] && [ -d "$dir" ] || return 0
  find "$dir" -path "$dir/.base" -prune -o -type f -printf '%P\n'
}

# overlay_rels <skill> — the skill's overlay: this repository's files plus the host's.
overlay_rels() { { root_rels "$PATCHES" "$1"; root_rels "$HOST_PATCHES" "$1"; } | LC_ALL=C sort -u; }

# has_patch <skill> — either root patches the skill.
has_patch() { [ -d "$PATCHES/$1" ] || { [ -n "$HOST_PATCHES" ] && [ -d "$HOST_PATCHES/$1" ]; }; }

# patch_root <skill> <rel> — the root whose copy of rel, and whose .base/rel, applies:
# this repository's whenever it carries the file, else the host's when it does.
patch_root() {
  if [ -n "$HOST_PATCHES" ] && [ ! -f "$PATCHES/$1/$2" ] && [ -f "$HOST_PATCHES/$1/$2" ]; then
    printf '%s' "$HOST_PATCHES"
  else
    printf '%s' "$PATCHES"
  fi
}

# same_file <a> <b> — both absent, or both files with the same bytes.
same_file() {
  { [ ! -e "$1" ] && [ ! -e "$2" ]; } || { [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"; }
}

# report_shadowed — a host file this repository also carries never applies. Name each
# one whose bytes or base differ from this repository's, once per run rather than once
# per tree; an identical copy is silent.
report_shadowed() {
  local d skill rel
  [ -n "$HOST_PATCHES" ] && [ -d "$HOST_PATCHES" ] || return 0
  for d in "$HOST_PATCHES"/*/; do
    skill=$(basename "$d")
    valid_skill_name "$skill" && [ -d "$PATCHES/$skill" ] || continue
    while IFS= read -r rel; do
      [ -n "$rel" ] && [ -f "$PATCHES/$skill/$rel" ] || continue
      same_file "$HOST_PATCHES/$skill/$rel" "$PATCHES/$skill/$rel" &&
        same_file "$HOST_PATCHES/$skill/.base/$rel" "$PATCHES/$skill/.base/$rel" && continue
      note "DRIFT: host patch $HOST_PATCHES/$skill/$rel differs from this repository's copy, which applies instead — delete the host copy, or move its change into this repository"
      drift=1
    done < <(root_rels "$HOST_PATCHES" "$skill" | LC_ALL=C sort)
  done
}

declare -A MH=() MK=() XK=() EK=() CONF=() CARRY=() LEG_SHA=() LEG_KIND=() LEG_SKILL=()
RELS=(); FOREIGN=(); CONFLICT_LINES=(); LEGACY_HITS=(); NOTED=0; W=""

# load_legacy — skills-legacy-overlays.txt into LEG_SHA/LEG_KIND keyed by skill/rel. A
# path may be listed once per old overlay version, so LEG_SHA holds every listed hash,
# space-separated. A missing file is an empty list.
load_legacy() {
  local sha kind path skill rel
  [ -f "$LEGACY" ] || return 0
  while read -r sha kind path _; do
    case "$sha" in ""|\#*) continue ;; esac
    skill="${path%%/*}"; rel="${path#*/}"
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]] || { [ "$kind" != swapped ] && [ "$kind" != added ]; } ||
       [ "$rel" = "$path" ] || ! valid_skill_name "$skill" || ! valid_rel "$rel" ||
       { [ -n "${LEG_KIND[$path]:-}" ] && [ "${LEG_KIND[$path]}" != "$kind" ]; }; then
      note "WARN: ignoring bad line in $LEGACY: $sha $kind $path"; continue
    fi
    LEG_SHA[$path]="${LEG_SHA[$path]:+${LEG_SHA[$path]} }$sha"; LEG_KIND[$path]=$kind; LEG_SKILL[$skill]=1
  done < "$LEGACY"
}

# legacy_copy <skill> <rel> <file> — the file holds bytes the pre-#2091 layer wrote there.
legacy_copy() {
  case " ${LEG_SHA[$1/$2]:-} " in *" $(sha_of "$3") "*) return 0 ;; esac
  return 1
}

# migrated <label> <skill> — apply has already layered this overlay skill in that tree, so
# the pre-#2091 copies are gone and bytes equal to an overlay, old or current, are
# upstream adopting it. Written by layer_skill; unapply and forget keep it.
migrated() { [ -e "$STATE/$1/migrated/$2" ]; }

# legacy_hits <label> <dir> <skill> — true when the installed skill still holds bytes the
# pre-#2091 layer wrote; LEGACY_HITS names those files. Such text is neither pristine nor
# ours to merge, so only a forced install clears it. A file the current overlay ships
# byte for byte is not a hit: compute_skill takes that overlay's .base as its pristine.
legacy_hits() {
  local label="$1" dir="$2" skill="$3" path rel live
  LEGACY_HITS=()
  [ -n "${LEG_SKILL[$skill]:-}" ] && ! migrated "$label" "$skill" || return 1
  while IFS= read -r path; do
    [ "${path%%/*}" = "$skill" ] || continue
    rel="${path#*/}"; live="$dir/$rel"
    [ -f "$live" ] && [ ! -L "$live" ] || continue
    legacy_copy "$skill" "$rel" "$live" || continue
    cmp -s "$live" "$(patch_root "$skill" "$rel")/$skill/$rel" && continue
    LEGACY_HITS+=("$rel")
  done < <(printf '%s\n' "${!LEG_SHA[@]}" | LC_ALL=C sort)
  [ "${#LEGACY_HITS[@]}" -gt 0 ]
}

legacy_drift() {
  note "DRIFT: $1 $2 still holds pre-#2091 overlay text (${LEGACY_HITS[*]}) — not layered until reinstalled: skills-localize.sh unapply $2; jsm install $2 --force; skills-localize.sh apply (the nightly does this when jsm next updates $2)"
  drift=1
}

load_manifest() {
  local f="$STATE/$1/manifest/$2" rel h k
  MH=(); MK=()
  [ -f "$f" ] || return 1
  while IFS=$'\t' read -r rel h k; do
    valid_rel "$rel" || { note "WARN: ignoring bad path '$rel' in $f"; continue; }
    MH[$rel]=$h; MK[$rel]=$k
  done < "$f"
  return 0
}

# recorded_as <rel> <file> — the file is one of the outputs the manifest records for rel.
recorded_as() {
  [ -f "$2" ] || return 1
  case " ${MH[$1]:-} " in *" $(sha_of "$2") "*) return 0 ;; esac
  return 1
}

# compute_skill <label> <root> <skill> <note> — for every file the layer touches in this
# skill, work out its pristine copy (XK, files under $W/x), the merged copy before the
# note ($W/m) and the expected live copy (EK, $W/e). Pristine is:
#   recorded, live == what apply wrote   → the saved copy
#   recorded, live == the saved copy     → live (jsm put pristine back)
#   recorded, anything else              → foreign: edited by hand, the skill is left alone
#   unrecorded                           → live minus our note. Before the first apply in
#                                          this tree (migrated), a live file identical to
#                                          its overlay in bytes the legacy list names is a
#                                          pre-#2091 whole-file copy, whose pristine is the
#                                          overlay's base; any other match is upstream
#                                          adopting the overlay
# Returns 2 when any file is foreign (FOREIGN names them).
compute_skill() {
  local label="$1" root="$2" skill="$3" noteline="$4"
  local dir="$root/$skill" rel live copy o b c f pr
  XK=(); EK=(); CONF=(); RELS=(); FOREIGN=(); NOTED=0
  W="$WORK/$label/$skill"; rm -rf "$W"; mkdir -p "$W/x" "$W/m" "$W/e"
  load_manifest "$label" "$skill"
  while IFS= read -r rel; do
    [ -n "$rel" ] && RELS+=("$rel")
  done < <({ overlay_rels "$skill"; printf '%s\n' "${!MH[@]}"; echo SKILL.md; } | LC_ALL=C sort -u)

  for rel in "${RELS[@]}"; do
    pr=$(patch_root "$skill" "$rel")
    live="$dir/$rel"; copy="$STATE/$label/pristine/$skill/$rel"; o="$pr/$skill/$rel"
    mkdir -p "$(dirname "$W/x/$rel")" "$(dirname "$W/m/$rel")" "$(dirname "$W/e/$rel")"
    if [ -L "$live" ]; then
      XK[$rel]=foreign; FOREIGN+=("$rel")
    elif [ -n "${MH[$rel]:-}" ]; then
      if recorded_as "$rel" "$live" && { [ "${MK[$rel]}" = absent ] || [ -f "$copy" ]; }; then
        if [ "${MK[$rel]}" = file ]; then cp "$copy" "$W/x/$rel"; XK[$rel]="file"
        else XK[$rel]=absent; fi
      elif [ "${MK[$rel]}" = absent ] && [ ! -e "$live" ]; then
        XK[$rel]=absent
      elif [ "${MK[$rel]}" = file ] && [ -f "$live" ] && cmp -s "$live" "$copy"; then
        cp "$live" "$W/x/$rel"; XK[$rel]="file"
      else
        XK[$rel]=foreign; FOREIGN+=("$rel")
      fi
    elif [ -f "$o" ] && [ -f "$live" ] && ! migrated "$label" "$skill" && cmp -s "$live" "$o" &&
         legacy_copy "$skill" "$rel" "$live"; then
      if [ -f "$pr/$skill/.base/$rel" ]; then cp "$pr/$skill/.base/$rel" "$W/x/$rel"; XK[$rel]="file"
      else XK[$rel]=absent; fi
    elif [ -f "$live" ]; then
      { [ "$rel" = SKILL.md ] && note_strip "$live" "$W/x/$rel"; } || cp "$live" "$W/x/$rel"
      XK[$rel]="file"
    else
      XK[$rel]=absent
    fi
  done
  [ "${#FOREIGN[@]}" -eq 0 ] || return 2

  # The note goes on any skill whose pristine markdown names the vocabulary.
  if [ -n "$noteline" ] && [ "${XK[SKILL.md]}" = file ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$dir/"}"
      if [ -n "${XK[$rel]:-}" ]; then
        [ "${XK[$rel]}" = file ] && names_vocab "$W/x/$rel" && { NOTED=1; break; }
      else
        names_vocab "$f" && { NOTED=1; break; }
      fi
    done < <(find "$dir" -name node_modules -prune -o -type f -name '*.md' -print0)
  fi

  for rel in "${RELS[@]}"; do
    pr=$(patch_root "$skill" "$rel"); o="$pr/$skill/$rel"; b="$pr/$skill/.base/$rel"
    if [ -f "$o" ]; then
      cp "$o" "$W/m/$rel"
      if [ "${XK[$rel]}" = absent ]; then
        [ -f "$b" ] && CONF[$rel]="upstream no longer ships this file"
      elif [ ! -f "$b" ]; then
        cmp -s "$W/x/$rel" "$o" || CONF[$rel]="upstream now ships this file"
      elif ! cmp -s "$W/x/$rel" "$b"; then
        # Plain -p exits with the conflict count; -p --ours resolves them to our side but
        # exits 0, so it cannot report them (probed 2026-10-29).
        git merge-file -p "$o" "$b" "$W/x/$rel" > /dev/null 2>&1; c=$?
        if [ "$c" -ge 128 ] || ! git merge-file -p --ours "$o" "$b" "$W/x/$rel" > "$W/m/$rel" 2>/dev/null; then
          note "WARN: could not merge $label $skill/$rel — kept our copy"
          cp "$o" "$W/m/$rel"; c=1
        fi
        [ "$c" -eq 0 ] || CONF[$rel]="upstream changed lines the overlay also changes"
      fi
    elif [ "${XK[$rel]}" = file ]; then
      cp "$W/x/$rel" "$W/m/$rel"
    fi
    if [ ! -f "$W/m/$rel" ]; then
      EK[$rel]=absent
    elif [ "$rel" = SKILL.md ] && [ "$NOTED" = 1 ]; then
      note_insert "$W/m/$rel" "$W/e/$rel" "$noteline" || {
        say "WARN: $label $skill/SKILL.md has no frontmatter — local-tooling note not added"
        cp "$W/m/$rel" "$W/e/$rel"; }
      EK[$rel]="file"
    else
      cp "$W/m/$rel" "$W/e/$rel"; EK[$rel]="file"
    fi
  done
  return 0
}

# owned <rel> — the expected copy differs from pristine, so the layer must record it.
owned() {
  [ "${EK[$1]}" = "${XK[$1]}" ] || return 0
  [ "${EK[$1]}" = file ] && ! cmp -s "$W/e/$1" "$W/x/$1"
}

# put_file <skilldir> <rel> <src|""> — make the live file a copy of src, or remove it.
put_file() {
  local dir="$1" rel="$2" src="$3" live="$1/$2" d
  if [ -n "$src" ]; then
    mkdir -p "$(dirname "$live")" && cp "$src" "$live"
  else
    rm -f "$live" || return 1
    d=$(dirname "$live")
    while [ "$d" != "$dir" ] && rmdir "$d" 2>/dev/null; do d=$(dirname "$d"); done
    return 0
  fi
}

# write_state <label> <root> <skill> [manifest] — install a manifest ($W/manifest by
# default) and its pristine copies from $W/x; an empty manifest drops the skill's state.
write_state() {
  local label="$1" skill="$3" mf="${4:-$W/manifest}" sd="$STATE/$1" rel h k
  mkdir -p "$sd/manifest" "$sd/pristine" || return 1
  [ -f "$sd/root" ] || printf '%s\n' "$2" > "$sd/root" || return 1
  if [ ! -s "$mf" ]; then
    rm -rf "${sd:?}/pristine/$skill" "$sd/manifest/$skill"; return 0
  fi
  rm -rf "$sd/pristine/.$skill.new"; mkdir -p "$sd/pristine/.$skill.new" || return 1
  while IFS=$'\t' read -r rel h k; do
    [ "$k" = file ] || continue
    mkdir -p "$(dirname "$sd/pristine/.$skill.new/$rel")" && cp "$W/x/$rel" "$sd/pristine/.$skill.new/$rel" || return 1
  done < "$mf"
  cp "$mf" "$sd/manifest/.$skill.new" || return 1
  rm -rf "${sd:?}/pristine/$skill" &&
    mv "$sd/pristine/.$skill.new" "$sd/pristine/$skill" &&
    mv "$sd/manifest/.$skill.new" "$sd/manifest/$skill"
}

# manifest_differs <new> <saved> — saving <new> would change the saved state.
manifest_differs() { if [ -s "$1" ]; then ! cmp -s "$1" "$2"; else [ -e "$2" ]; fi; }

drop_state() {
  local label="$1" skill="$2"
  [ -e "$STATE/$label/manifest/$skill" ] || [ -e "$STATE/$label/pristine/$skill" ] || return 0
  if [ "$MODE" = check ]; then note "DRIFT: $label layer state for '$skill' is stale (run apply)"; drift=1; return 0; fi
  if [ "$DRY" = 1 ]; then note "would drop $label layer state: $skill"; return 0; fi
  rm -rf "${STATE:?}/$label/manifest/$skill" "$STATE/$label/pristine/$skill" && say "dropped $label layer state: $skill"
}

# layer_skill <label> <root> <skill> <note> — apply, dry-run or check one skill.
layer_skill() {
  local label="$1" root="$2" skill="$3" noteline="$4" dir="$2/$3" rel live old stale=0
  local -a towrite=()
  valid_skill_name "$skill" || return 0
  if [ ! -d "$dir" ] || [ -L "$dir" ] || [ -f "$LOCAL/$skill/SKILL.md" ]; then
    drop_state "$label" "$skill"; return 0
  fi
  if [ ! -e "$STATE/$label/manifest/$skill" ] && legacy_hits "$label" "$dir" "$skill"; then
    legacy_drift "$label" "$skill"; CARRY["$label $skill"]=1; return 0
  fi
  # Fast path: nothing recorded, no overlay, no note, no vocabulary.
  if ! has_patch "$skill" && [ ! -e "$STATE/$label/manifest/$skill" ] &&
     ! grep -qF -- "$MARKER" "$dir/SKILL.md" 2>/dev/null &&
     ! grep -rEiq --include='*.md' --exclude-dir=node_modules -- "$VOCAB" "$dir" 2>/dev/null; then
    return 0
  fi
  if ! compute_skill "$label" "$root" "$skill" "$noteline"; then
    for rel in "${FOREIGN[@]}"; do
      note "DRIFT: $label $skill/$rel was edited after skills-localize wrote it — left alone. To discard the edit and take upstream: skills-localize.sh forget $skill && jsm install $skill --force && skills-localize.sh apply"
    done
    drift=1; CARRY["$label $skill"]=1; return 0
  fi

  # $W/manifest is the state once every write lands; $W/manifest.tx is the state while
  # they run: the same lines plus what the saved state records that they drop or change.
  local h oh
  local -a olds
  : > "$W/manifest"; : > "$W/manifest.tx"
  for rel in "${RELS[@]}"; do
    if owned "$rel"; then
      h=$(sha_of "$W/e/$rel")
      printf '%s\t%s\t%s\n' "$rel" "$h" "${XK[$rel]}" >> "$W/manifest"
      read -ra olds <<< "${MH[$rel]:-}"
      for oh in "${olds[@]}"; do case " $h " in *" $oh "*) ;; *) h="$h $oh" ;; esac; done
      printf '%s\t%s\t%s\n' "$rel" "$h" "${XK[$rel]}" >> "$W/manifest.tx"
    elif [ -n "${MH[$rel]:-}" ]; then
      printf '%s\t%s\t%s\n' "$rel" "${MH[$rel]}" "${MK[$rel]}" >> "$W/manifest.tx"
    fi
  done
  old="$STATE/$label/manifest/$skill"
  ! manifest_differs "$W/manifest" "$old" || stale=1
  for rel in "${RELS[@]}"; do
    live="$dir/$rel"
    if [ "${EK[$rel]}" = file ]; then [ -f "$live" ] && cmp -s "$live" "$W/e/$rel" && continue
    else [ -e "$live" ] || continue; fi
    towrite+=("$rel")
  done

  if [ "$MODE" = check ]; then
    for rel in "${towrite[@]}"; do note "DRIFT: $label $skill/$rel is not the localized copy (run apply)"; drift=1; done
    [ "${#towrite[@]}" -gt 0 ] || [ "$stale" = 0 ] || { note "DRIFT: $label layer state for '$skill' is not recorded (run apply)"; drift=1; }
    return 0
  fi
  for rel in "${!CONF[@]}"; do
    say "conflict ($label): $skill/$rel — ${CONF[$rel]}; kept our side"
    [ "$DRY" = 1 ] || CONFLICT_LINES+=("$label $skill/$rel")
  done
  if [ "$DRY" = 1 ]; then
    for rel in "${towrite[@]}"; do note "would localize ($label): $skill/$rel"; done
    [ "$stale" = 0 ] || note "would record $label layer state: $skill"
    return 0
  fi
  # The transitional state goes first, so every file stays recognisable whichever writes
  # land: a new pristine copy is saved before the file it guards changes, and an old hash
  # or pristine copy stays until its file is written. Only once every write has landed
  # does the state become $W/manifest; otherwise a later run would take layered text it
  # no longer recognises as pristine, or as a hand edit.
  if manifest_differs "$W/manifest.tx" "$old" && ! write_state "$label" "$root" "$skill" "$W/manifest.tx"; then
    note "ERROR: could not save $label layer state for '$skill' — left unchanged"; errors=1; return 0
  fi
  local src verb failed=0
  for rel in "${towrite[@]}"; do
    if [ "${EK[$rel]}" = absent ]; then src=""; verb="removed"
    elif owned "$rel"; then src="$W/e/$rel"; verb="localized"
    else src="$W/e/$rel"; verb="restored"; fi
    if put_file "$dir" "$rel" "$src"; then say "$verb ($label): $skill/$rel"
    else note "ERROR: could not write $label $skill/$rel"; errors=1; failed=1; fi
  done
  if manifest_differs "$W/manifest" "$old"; then
    if [ "$failed" = 1 ]; then note "ERROR: kept $label layer state for '$skill' until its files are restored"
    elif ! write_state "$label" "$root" "$skill"; then note "ERROR: could not update $label layer state for '$skill'"; errors=1; fi
  fi
  # This tree has now been layered once, so its pre-#2091 copies are behind it.
  if has_patch "$skill" && ! migrated "$label" "$skill"; then
    { mkdir -p "$STATE/$label/migrated" && : > "$STATE/$label/migrated/$skill"; } ||
      { note "ERROR: could not record $label $skill as migrated"; errors=1; }
  fi
}

apply_layer() {
  local label root noteline skill line
  for label in "${LABELS[@]}"; do
    root=$(tree_root "$label")
    [ -d "$root" ] || continue
    state_owns "$label" "$root" || { CARRY[$label]=1; continue; }
    if ! noteline=$(note_line "$label"); then
      note "ERROR: $(note_file "$label") is missing or does not start with '$MARKER' — $label layer skipped"
      errors=1; drift=1; CARRY[$label]=1; continue
    fi
    while IFS= read -r skill; do
      layer_skill "$label" "$root" "$skill" "$noteline"
    done < <({ find "$root" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n'
               [ -d "$STATE/$label/manifest" ] && find "$STATE/$label/manifest" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n'
             } | LC_ALL=C sort -u)
  done
  if [ "$MODE" = apply ] && [ "$DRY" = 0 ]; then
    # A skill or tree this run skipped keeps its conflicts from the last run.
    if [ -f "$STATE/conflicts" ]; then
      while IFS= read -r line; do
        [[ $line =~ ^(claude|codex|agents)\ ([^/[:space:]]+)/ ]] || continue
        [ -n "${CARRY[${BASH_REMATCH[1]}]:-}" ] ||
          [ -n "${CARRY["${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"]:-}" ] || continue
        CONFLICT_LINES+=("$line")
      done < "$STATE/conflicts"
    fi
    { [ "${#CONFLICT_LINES[@]}" -eq 0 ] || printf '%s\n' "${CONFLICT_LINES[@]}" | LC_ALL=C sort -u; } > "$STATE/.conflicts.new" &&
      mv "$STATE/.conflicts.new" "$STATE/conflicts"
  fi
}

# unapply_cmd <skill>... — pristine files back in every tree, all or nothing per skill.
unapply_cmd() {
  local skill label root dir rel live copy rc=0 foreign unrec mismatch
  for skill in "$@"; do
    valid_skill_name "$skill" || { reject_name "$skill" "unapply"; [ "$rc" -ge 2 ] || rc=2; continue; }
    foreign=0; unrec=0; mismatch=0
    # Pass 1: classify every recorded file in every tree and change nothing.
    for label in "${LABELS[@]}"; do
      root=$(tree_root "$label"); dir="$root/$skill"
      state_owns "$label" "$root" || { mismatch=1; continue; }
      if load_manifest "$label" "$skill"; then
        { [ -d "$dir" ] && [ ! -L "$dir" ]; } || continue
        for rel in "${!MH[@]}"; do
          live="$dir/$rel"; copy="$STATE/$label/pristine/$skill/$rel"
          if [ ! -L "$live" ] && recorded_as "$rel" "$live" &&
             { [ "${MK[$rel]}" = absent ] || [ -f "$copy" ]; }; then :
          elif [ "${MK[$rel]}" = absent ] && [ ! -e "$live" ]; then :
          elif [ "${MK[$rel]}" = file ] && [ -f "$live" ] && [ ! -L "$live" ] && cmp -s "$live" "$copy"; then :
          else note "hand-edited $label $skill/$rel"; foreign=1; fi
        done
      elif [ -d "$dir" ] && [ ! -L "$dir" ] && legacy_hits "$label" "$dir" "$skill"; then
        note "legacy: $label $skill still holds pre-#2091 overlay text (${LEGACY_HITS[*]}); only jsm install $skill --force replaces it"
        unrec=1
      elif [ -d "$dir" ] && [ ! -L "$dir" ] && has_patch "$skill"; then
        note "unrecorded: $label $skill has an overlay but no saved pristine copy; only jsm install $skill --force restores it"
        unrec=1
      fi
    done
    if [ "$foreign" = 1 ]; then rc=4; continue; fi
    # State saved for another tree is a setup error, not a hand edit: change nothing.
    if [ "$mismatch" = 1 ]; then [ "$rc" -ge 1 ] || rc=1; continue; fi
    # Pass 2: restore. Nothing changed since pass 1 (we hold the lock).
    for label in "${LABELS[@]}"; do
      root=$(tree_root "$label"); dir="$root/$skill"
      if load_manifest "$label" "$skill"; then
        if [ -d "$dir" ] && [ ! -L "$dir" ]; then
          for rel in "${!MH[@]}"; do
            live="$dir/$rel"; copy="$STATE/$label/pristine/$skill/$rel"
            recorded_as "$rel" "$live" || continue
            if [ "${MK[$rel]}" = file ]; then put_file "$dir" "$rel" "$copy"; else put_file "$dir" "$rel" ""; fi ||
              { note "ERROR: could not restore $label $skill/$rel"; errors=1; [ "$rc" -ge 1 ] || rc=1; continue 3; }
            say "unapplied ($label): $skill/$rel"
          done
        fi
        rm -rf "${STATE:?}/$label/manifest/$skill" "$STATE/$label/pristine/$skill"
      elif [ -d "$dir" ] && [ ! -L "$dir" ] && legacy_hits "$label" "$dir" "$skill"; then
        # Files the old layer added are not upstream's: take them away before the forced
        # install, which may leave files it does not ship in place.
        for rel in "${LEGACY_HITS[@]}"; do
          [ "${LEG_KIND[$skill/$rel]}" = added ] || continue
          put_file "$dir" "$rel" "" ||
            { note "ERROR: could not remove $label $skill/$rel"; errors=1; [ "$rc" -ge 1 ] || rc=1; continue 3; }
          say "unapplied ($label): $skill/$rel (pre-#2091 file removed)"
        done
      elif [ -d "$dir" ] && [ ! -L "$dir" ] && ! has_patch "$skill" && [ -f "$dir/SKILL.md" ] &&
           note_strip "$dir/SKILL.md" "$WORK/strip"; then
        # A note with no saved state (state lost): strip it, the inverse of note_insert.
        cp "$WORK/strip" "$dir/SKILL.md" && say "unapplied ($label): $skill/SKILL.md (note stripped)"
      fi
    done
    [ "$unrec" = 0 ] || [ "$rc" -ge 3 ] || rc=3
  done
  return "$rc"
}

forget_cmd() {
  local skill label rc=0
  for skill in "$@"; do
    valid_skill_name "$skill" || { reject_name "$skill" "forget"; rc=2; continue; }
    for label in "${LABELS[@]}"; do
      [ -e "$STATE/$label/manifest/$skill" ] || [ -e "$STATE/$label/pristine/$skill" ] || continue
      rm -rf "${STATE:?}/$label/manifest/$skill" "$STATE/$label/pristine/$skill" && say "forgot $label layer state: $skill"
    done
  done
  return "$rc"
}

# rebase_cmd <skill> <version> — run from a worktree; rewrites skills-patches/<skill>,
# and the host's files for the skill in place: the worktree guard covers only this
# repository's.
rebase_cmd() {
  local skill="$1" version="${2#v}" rel noteline="" lbl pr host=0
  case "$HERE" in
    */.claude/worktrees/*) ;;
    *) note "ERROR: rebase rewrites skills-patches/$skill — run a worktree's copy of this script (this one is $HERE)"; return 2 ;;
  esac
  valid_skill_name "$skill" || { reject_name "$skill" "rebase"; return 2; }
  [[ "$version" =~ ^[0-9]+$ ]] || { note "ERROR: version must be the jsm version number, e.g. 12"; return 2; }
  has_patch "$skill" || { note "ERROR: no overlay at $PATCHES/$skill${HOST_PATCHES:+ or $HOST_PATCHES/$skill}"; return 2; }
  [ -d "$SKILLS/$skill" ] || { note "ERROR: $skill is not installed in $SKILLS"; return 2; }
  lbl=claude; state_owns "$lbl" "$SKILLS" || return 2
  if [ ! -e "$STATE/$lbl/manifest/$skill" ] && legacy_hits "$lbl" "$SKILLS/$skill" "$skill"; then
    note "ERROR: $skill still holds pre-#2091 overlay text (${LEGACY_HITS[*]}), which is not upstream's — reinstall it first: skills-localize.sh unapply $skill; jsm install $skill --force"
    return 4
  fi
  noteline=$(note_line claude) || noteline=""
  if ! compute_skill claude "$SKILLS" "$skill" "$noteline"; then
    note "ERROR: hand-edited files in $skill: ${FOREIGN[*]} — resolve them first"; return 4
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    pr=$(patch_root "$skill" "$rel")
    [ "$pr" = "$PATCHES" ] || host=1
    if [ "${XK[$rel]}" = file ]; then
      mkdir -p "$(dirname "$pr/$skill/.base/$rel")" && cp "$W/x/$rel" "$pr/$skill/.base/$rel"
    else
      rm -f "$pr/$skill/.base/$rel"
    fi
    cp "$W/m/$rel" "$pr/$skill/$rel"
    [ -z "${CONF[$rel]:-}" ] || note "kept our side in $skill/$rel (${CONF[$rel]}) — review the diff"
  done < <(overlay_rels "$skill")
  for pr in "$PATCHES" ${HOST_PATCHES:+"$HOST_PATCHES"}; do
    [ -d "$pr/$skill" ] || continue
    mkdir -p "$pr/$skill/.base" && printf '%s\n' "$version" > "$pr/$skill/.base/VERSION"
  done
  [ "$host" = 0 ] || say "rewrote the host's patch for $skill in place at $HOST_PATCHES/$skill — it is outside this repository, so review it there"
  say "rebased $skill onto v$version — review git diff, then commit"
}

# audit_compare <src-file> <dst-file> -> same | DIFFERS | missing
audit_compare() {
  local src="$1" dst="$2"
  [ -e "$dst" ] || { echo "missing"; return 0; }
  if cmp -s "$src" "$dst"; then echo "same"; else echo "DIFFERS"; fi
}

# codex_wants <name> -> true if codex-skills.txt allowlists this skill for the Codex tree
codex_wants() {
  local name="$1" line entry
  [ -f "$CODEX_LIST" ] || return 1
  while IFS= read -r line; do
    entry="${line%%#*}"; entry="${entry//[[:space:]]/}"
    [ "$entry" = "$name" ] && return 0
  done < "$CODEX_LIST"
  return 1
}

# audit(): read-only report — never deploys, never writes. Compares every file under
# plugins/hov-stack/skills/ against its deployed copy in both trees (claude always; codex only when
# codex-skills.txt allowlists the skill, else the column reads n/a rather than
# "missing", since that skill was never meant to reach Codex).
audit() {
  [ -d "$LOCAL" ] || { note "audit: $LOCAL absent — nothing to audit"; return 0; }
  note "name | sha256 | deployed-claude | deployed-codex"
  local d name src rel sha claude_status codex_status wants_codex
  for d in "$LOCAL"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ -n "$name" ] || continue
    [ -f "$d/SKILL.md" ] || { note "WARN: plugins/hov-stack/skills/$name has no SKILL.md — skipped"; continue; }
    wants_codex=1; codex_wants "$name" || wants_codex=0
    while IFS= read -r -d '' src; do
      rel="${src#"$d"}"
      sha=$(sha256sum "$src" | awk '{print $1}')
      claude_status=$(audit_compare "$src" "$SKILLS/$name/$rel")
      if [ "$wants_codex" = 1 ]; then
        codex_status=$(audit_compare "$src" "$CODEX_SKILLS/$name/$rel")
      else
        codex_status="n/a"
      fi
      note "$name/$rel | $sha | $claude_status | $codex_status"
    done < <(find "$d" -name node_modules -type d -prune -o -type f -print0 | sort -z)
  done
}

case "$MODE" in
  audit)   audit; exit 0 ;;
  unapply)
    take_lock exclusive
    WORK=$(mktemp -d) || { note "ERROR: mktemp failed"; exit 1; }
    load_legacy
    unapply_cmd "$@"; exit $? ;;
  forget)  take_lock exclusive; forget_cmd "$@"; exit $? ;;
  rebase)
    take_lock shared
    WORK=$(mktemp -d) || { note "ERROR: mktemp failed"; exit 1; }
    load_legacy
    rebase_cmd "$1" "$2"; exit $? ;;
esac

if [ "$MODE" = check ] || [ "$DRY" = 1 ]; then take_lock shared; else take_lock exclusive; fi
WORK=$(mktemp -d) || { note "ERROR: mktemp failed"; exit 1; }
load_legacy
say "skills-localize: $MODE  (skills=$SKILLS, codex=$CODEX_SKILLS, agents=$AGENTS_SKILLS)"
enforce_retired
# Reap BEFORE deploying, so a run converges in one pass. sync_fork skips any entry that
# is a symlink — including a DANGLING one — so a fork whose symlink target vanished
# (the documented `sync.sh install` from a temp worktree trap) would otherwise stay
# broken until a second run: reap frees the name, and only then can deploy refill it.
reap_broken_links "$SKILLS" "claude-skills"
reap_broken_links "$CODEX_SKILLS" "codex-skills"
deploy_forks
report_shadowed
apply_layer
deploy_codex
if [ "$MODE" = check ]; then
  [ "$drift" -eq 0 ] && echo "skills policy in sync" || true
  exit "$drift"
fi
[ "$errors" -eq 0 ] || { echo "skills-localize: completed WITH ERRORS" >&2; exit 1; }
say "skills-localize: done"
