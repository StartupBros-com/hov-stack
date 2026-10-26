#!/usr/bin/env bash
# skills-localize.sh — re-assert local skill policy over the jsm-managed ~/.claude/skills tree.
#
# WHY THIS EXISTS
#   Most of ~/.claude/skills is owned by jsm (jeffreys-skills.md). `jsm install-all`,
#   `jsm upgrade`, and the daily auto-update will re-add skills we retired and overwrite
#   local edits with pristine upstream copies. `pin` only freezes a *version*, not content.
#   This reconciler re-applies our local policy IDEMPOTENTLY so it survives jsm:
#     • retired skills stay uninstalled (re-trashed if jsm re-adds them)
#     • local forks stay deployed
#     • per-file patch overlays stay applied over kept jsm skills
#   Re-run it after any jsm operation. Once wired (see WIRING below) that happens
#   automatically; until then, run `skills-localize.sh apply` by hand after `jsm upgrade`.
#
# SOURCES OF TRUTH (all version-controlled in this repository)
#   retired-skills.txt          one skill name per line (# comments ok) → kept uninstalled
#   plugins/hov-stack/skills/<name>/  full local (non-jsm) skills → deployed into ~/.claude/skills/
#   skills-patches/<name>/<rel>  file overlays copied over the matching jsm skill file,
#                                in BOTH the Claude and Codex trees (wherever installed)
#   codex-skills.txt            subset of plugins/hov-stack/skills/ that ALSO deploys to ~/.codex/skills/
#
# TWO SKILL TREES, ONE POLICY
#   jsm manages ~/.claude/skills AND ~/.codex/skills (plus cursor/gemini/hermes) as
#   independent targets. Everything in THIS file was Claude-only until codex-skills.txt:
#   a fork added to the local skills never reached Codex, so emil-design-eng and
#   kill-ai-slop were live in Claude and simply absent from Codex. codex-skills.txt is
#   an explicit allowlist rather than a blanket sync — see that file for why.
#
#   Patch overlays had the same hole for longer, and it was worse: the skill IS installed
#   in both trees, so Codex silently kept serving the pristine upstream text a patch was
#   written to replace (2026-08-06: all 7 overlay skills diverged). Unlike forks, overlays
#   are NOT allowlisted — an overlay is a correction to a skill we keep, and a correction
#   that applies in Claude applies in Codex. patch_tree() runs over both trees and skips
#   any tree where that skill is not installed.
#
# MODES
#   apply        (default) enforce policy on ~/.claude/skills (+ ~/.codex/skills for
#                overlays and allowlisted forks)
#   --dry-run    print what apply would do, change nothing
#   check        exit 1 + DRIFT: lines if live tree diverges (consumed by harness-doctor)
#   audit        read-only report (dotfiles#1202, pstack vet 2026-09-18): for every file
#                under plugins/hov-stack/skills/, print name | sha256 | deployed-claude
#                (same/DIFFERS/missing) | deployed-codex (same/DIFFERS/missing/n/a — n/a
#                when the skill is not in codex-skills.txt). No deploy, no writes; a
#                cheaper cousin of pstack's parity.py hash inventory for this repo's
#                own two skill trees.
#
# WIRING (proposed, not auto-installed — see the PR description)
#   1. dotup → runs `skills-localize.sh apply` after install.sh (WIRED 2026-09-02, #909;
#      deliberately dotup and not sync.sh install, which can be run from a worktree)
#   2. harness-doctor  → run `skills-localize.sh check`, warn on DRIFT
#   3. shell rc        → a `jsm()` wrapper that runs `apply` after upgrade/install/install-all/sync
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
# Overridable so tests can point at a fixture tree instead of this repo's real
# plugins/hov-stack/skills/ and codex-skills.txt (audit mode's fixture suite does this).
LOCAL="${SKILLS_LOCAL_DIR:-$HERE/plugins/hov-stack/skills}"
PATCHES="$HERE/skills-patches"
CODEX_SKILLS="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
CODEX_LIST="${CODEX_SKILLS_LIST:-$HERE/codex-skills.txt}"

MODE="apply"; DRY=0
case "${1:-apply}" in
  apply)     MODE="apply" ;;
  --dry-run) MODE="apply"; DRY=1 ;;
  check)     MODE="check" ;;
  audit)     MODE="audit" ;;
  -h|--help) sed -n '2,36p' "$SELF"; exit 0 ;;
  *) echo "usage: skills-localize.sh [apply|--dry-run|check|audit]" >&2; exit 2 ;;
esac

drift=0; errors=0
say()  { [ "$MODE" = check ] || echo "$@"; }
note() { echo "$@"; }               # always shown (dry-run plan / drift / errors)
ts()   { date +%Y%m%d%H%M%S 2>/dev/null || echo manual; }

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
retire_one() {
  local name="$1"; local dir="$SKILLS/$name"
  [ -n "$name" ] || return 0                      # never operate on an empty name
  valid_skill_name "$name" || { reject_name "$name" "retired-skills.txt"; return 0; }
  [ -e "$dir" ] || return 0                       # already gone → idempotent no-op
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

enforce_retired() {
  [ -f "$RETIRED" ] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -n "$line" ] && retire_one "$line"
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

# Patch ONE tree. jsm installs the same skill into ~/.claude/skills AND ~/.codex/skills
# as independent copies, so an overlay applied to only one of them leaves the other
# serving pristine upstream text. That was the state until 2026-08-06: all 7 overlay
# skills diverged, and Codex was still being handed working `br` command examples out
# of user-support-triage's BEADS-INTEGRATION.md — the exact file the Claude-side
# tombstone overlay exists to suppress. Same copy/idempotency semantics for both trees;
# $2 labels the tree in output so a DRIFT line says which one moved.
patch_tree() {
  local root="$1" label="$2"
  [ -d "$root" ] || return 0                      # tree absent (e.g. no Codex here) → skip
  local skilldir name rel src dst
  for skilldir in "$PATCHES"/*/; do
    [ -d "$skilldir" ] || continue
    name=$(basename "$skilldir")
    # Overlay names are directory basenames, so `..` cannot arrive via the glob — but
    # this is the last call site that interpolates a manifest-ish name into a path we
    # write to, and the rest of the file validates at every such site. Match that.
    valid_skill_name "$name" || { reject_name "$name" "skills-patches"; continue; }
    [ -d "$root/$name" ] || continue              # kept jsm skill absent here → nothing to patch
    while IFS= read -r -d '' src; do
      rel="${src#"$skilldir"}"; dst="$root/$name/$rel"
      cmp -s "$src" "$dst" 2>/dev/null && continue   # already applied → idempotent
      if [ "$MODE" = check ]; then
        note "DRIFT: $label patch overlay '$name/$rel' not applied (jsm reverted it?)"; drift=1; continue
      fi
      if [ "$DRY" = 1 ]; then note "would patch ($label): $name/$rel"; continue; fi
      mkdir -p "$(dirname "$dst")"
      if cp "$src" "$dst"; then note "patched ($label): $name/$rel"
      else note "ERROR: failed to apply $label patch '$name/$rel'"; errors=1; fi
    done < <(find "$skilldir" -type f -print0)
  done
}

apply_patches() {
  [ -d "$PATCHES" ] || return 0
  patch_tree "$SKILLS" "claude"
  patch_tree "$CODEX_SKILLS" "codex"
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

if [ "$MODE" = audit ]; then
  audit
  exit 0
fi

say "skills-localize: $MODE  (skills=$SKILLS, codex=$CODEX_SKILLS)"
enforce_retired
# Reap BEFORE deploying, so a run converges in one pass. sync_fork skips any entry that
# is a symlink — including a DANGLING one — so a fork whose symlink target vanished
# (the documented `sync.sh install` from a temp worktree trap) would otherwise stay
# broken until a second run: reap frees the name, and only then can deploy refill it.
reap_broken_links "$SKILLS" "claude-skills"
reap_broken_links "$CODEX_SKILLS" "codex-skills"
deploy_forks
apply_patches
deploy_codex
if [ "$MODE" = check ]; then
  [ "$drift" -eq 0 ] && echo "skills policy in sync" || true
  exit "$drift"
fi
[ "$errors" -eq 0 ] || { echo "skills-localize: completed WITH ERRORS" >&2; exit 1; }
say "skills-localize: done"
