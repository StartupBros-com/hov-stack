#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# An unguarded command that fails under set -e would otherwise end the suite with no
# reason in the CI log; name the line and show the stderr the last case captured.
trap 'printf "not ok - unguarded command failed at line %s\n" "$LINENO" >&2; [ ! -s "$TMP/err" ] || cat "$TMP/err" >&2' ERR
PASS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass() { printf 'ok - %s\n' "$*"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
reject() {
  local reason="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then die "accepted: $reason"; fi
  grep -Fq -- "$reason" "$TMP/err" || { cat "$TMP/err"; die "missing reason: $reason"; }
}

commit() { git add -A; git -c user.name=t -c user.email=t@t commit -qm "${1:-fixture}"; }
plugin() {
  local name="$1" version="${2:-1.0.0}"
  mkdir -p "plugins/$name/.claude-plugin" "plugins/$name/skills/$name"
  printf '{"name":"%s","version":"%s"}\n' "$name" "$version" >"plugins/$name/.claude-plugin/plugin.json"
  printf '%s\n' "$version" >"plugins/$name/VERSION"
  printf 'fixture skill\n' >"plugins/$name/skills/$name/SKILL.md"
}
notes() {
  mkdir -p "plugins/$1/docs/release-notes"
  printf '## Highlights\n- Customers can install updates with a single command.\n' >"plugins/$1/docs/release-notes/v$2.md"
}

SCRIPT="$ROOT/release/scripts/release-stage.sh"
export FIX="$TMP/fix" CALLS="$TMP/calls" GITHUB_REPOSITORY=acme/repo GH_TOKEN=fake
export GATE_DEADLINE_SECS=0 GATE_POLL_SECS=0 REQUIRED_CHECKS="$TMP/required"
mkdir -p "$TMP/bin" "$FIX"; : >"$CALLS"; : >"$REQUIRED_CHECKS"
export PATH="$TMP/bin:$PATH"
cat >"$TMP/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
emit() { if [ -n "$expr" ]; then jq -r "$expr"; else cat; fi; }
if [ "$1" = release ]; then
  case "$2" in
    view)
      [ -f "$FIX/release.json" ] || exit 1
      if [ "${6:-}" = --jq ]; then jq -r "$7" "$FIX/release.json"; else cat "$FIX/release.json"; fi ;;
    create)
      # Positional files follow the tag; DROP_ASSET plays an upload that never landed.
      # CREATE_FAIL=before fails before any release exists; CREATE_FAIL=after keeps the
      # partial draft and then fails, as gh does for an explicit --draft.
      [ "${CREATE_FAIL:-}" != before ] || exit 1
      shift 3; names=(); pre=false
      while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do
        n="$(basename "$1")"; [ "$n" = "${DROP_ASSET:-}" ] || names+=("$n"); shift
      done
      for a in "$@"; do [ "$a" != --prerelease ] || pre=true; done
      [ "${IGNORE_PRERELEASE:-0}" != 1 ] || pre=false
      jq -nc --argjson pre "$pre" --args '{id:900,isDraft:true,isPrerelease:$pre,assets:[$ARGS.positional[]|{name:.}]}' "${names[@]}" >"$FIX/release.json"
      [ "${CREATE_FAIL:-}" != after ] || exit 1 ;;
    edit)
      [ "${EDIT_FAIL:-0}" != 1 ] || exit 1
      [ "$4" = --prerelease=false ] || exit 94
      [ "${EDIT_NOOP:-0}" = 1 ] || { jq -c '.isPrerelease = false' "$FIX/release.json" >"$FIX/edit.json"; mv "$FIX/edit.json" "$FIX/release.json"; } ;;
    delete) [ "${DELETE_FAIL:-0}" != 1 ] || exit 1; rm -f "$FIX/release.json" ;;
    *) exit 90 ;;
  esac
  exit 0
fi
[ "$1" = api ] || exit 91
shift
expr='' path='' paginate=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --jq) expr="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
[ "$paginate" = true ] && [ -n "$expr" ] || exit 92
case "$path" in
  */actions/workflows/*/runs\?*)
    file="${path#*/actions/workflows/}"; file="${file%%/runs*}"
    if [ "${PENDING_ONCE:-0}" = 1 ] && [ ! -f "$FIX/seen" ]; then
      touch "$FIX/seen"
      printf '{"workflow_runs":[{"id":999,"head_sha":"%s","head_branch":"main","event":"push","status":"in_progress"}]}\n' "$SHA" | emit
    elif [ -f "$FIX/$file" ]; then emit <"$FIX/$file"; else printf '{"workflow_runs":[]}\n' | emit; fi ;;
  */actions/runs/*/jobs\?*)
    id="${path#*/actions/runs/}"; id="${id%%/*}"
    emit <"$FIX/jobs-$id" ;;
  */actions/runs\?*) emit <"$FIX/all" ;;
  *) exit 93 ;;
esac
FAKEGH
chmod +x "$TMP/bin/gh"
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"; cd "$TMP/repo"
git remote add origin "$TMP/origin.git"
plugin a; notes a 1.0.0; commit
git push -q origin main
git tag a--v1.0.0; git tag ghost--v1.0.0
export RELEASE_TAG=ghost--v1.0.0
reject 'unknown plugin ghost: no plugins/ghost/ at ghost--v1.0.0' bash "$SCRIPT"
[ ! -s "$CALLS" ] || die 'unknown plugin called gh'
pass 'unknown plugin exits before any gh call'
export RELEASE_TAG=v1.0.0
reject 'is not a <name>--v<version> tag' bash "$SCRIPT"
[ ! -s "$CALLS" ] || die 'malformed tag called gh'
pass 'malformed tag is annotated before gh'
git switch -qc side
plugin a 2.0.0; notes a 2.0.0; commit; git tag a--v2.0.0
export RELEASE_TAG=a--v2.0.0
reject 'not on main' bash "$SCRIPT"
[ ! -s "$CALLS" ] || die 'side branch called gh'
pass 'tag off main is refused before gh'
git switch -q main
export RELEASE_TAG=a--v1.0.0 SHA
SHA="$(git rev-parse HEAD)"
git tag a--v0.9.0
printf 'different\n' >seed; commit
reject 'checkout HEAD is not a--v1.0.0' bash "$SCRIPT"
pass 'checkout must equal tag commit'
git switch -q --detach a--v1.0.0
cp plugins/a/VERSION "$TMP/version"
printf '9.0.0\n' >plugins/a/VERSION
reject 'does not match VERSION 9.0.0' bash "$SCRIPT"
pass 'tag and VERSION must match'
cp "$TMP/version" plugins/a/VERSION
cp plugins/a/.claude-plugin/plugin.json "$TMP/manifest"
printf '{"name":"a","version":"9.0.0"}\n' >plugins/a/.claude-plugin/plugin.json
reject 'manifest version 9.0.0' bash "$SCRIPT"
pass 'manifest version must match'
printf '{"name":"other","version":"1.0.0"}\n' >plugins/a/.claude-plugin/plugin.json
reject 'manifest name other does not match plugin a' bash "$SCRIPT"
pass 'manifest name must match'
cp "$TMP/manifest" plugins/a/.claude-plugin/plugin.json
mv plugins/a/docs/release-notes/v1.0.0.md "$TMP/notes"
reject 'requires release notes plugins/a/docs/release-notes/v1.0.0.md' bash "$SCRIPT"
pass 'missing notes never fall back'
printf '## Highlights\n- branch-name\n' >plugins/a/docs/release-notes/v1.0.0.md
reject 'looks like a branch name' bash "$SCRIPT"
pass 'bad notes never fall back'
cp "$TMP/notes" plugins/a/docs/release-notes/v1.0.0.md
printf '{"workflow_runs":[]}\n' >"$FIX/all"
: >"$CALLS"
reject "a--v1.0.0 CI release gate failed on $SHA" bash "$SCRIPT"
grep -Fq "no plugins-ci.yml run found for $SHA on main" "$TMP/err" || die 'missing gate reason'
if grep -q '^release create' "$CALLS"; then die 'absent CI run still staged a draft'; fi
pass 'an absent CI run blocks the draft at a zero deadline'
printf '{"workflow_runs":[{"id":10,"head_sha":"%s","head_branch":"main","event":"push","status":"completed"}]}\n' "$SHA" >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"a","conclusion":"failure"},{"name":"ci","conclusion":"success"}]}\n' >"$FIX/jobs-10"
: >"$CALLS"
reject "a--v1.0.0 CI release gate failed on $SHA" bash "$SCRIPT"
grep -Fq 'job a in plugins-ci.yml run 10 concluded failure' "$TMP/err" || die 'missing red job reason'
if grep -q '^release create' "$CALLS"; then die 'red plugin job still staged a draft'; fi
pass 'a red plugin job blocks the draft even with a green aggregate'
printf '{"jobs":[{"name":"a","conclusion":"success"}]}\n' >"$FIX/jobs-10"
: >"$CALLS"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'valid stage failed'; }
grep -Fq '::notice::staged draft a--v1.0.0 (id 900)' "$TMP/out" || die 'draft notice/id'
grep -Fxq 'release create a--v1.0.0 --draft --verify-tag --title a v1.0.0 --notes-file plugins/a/docs/release-notes/v1.0.0.md' "$CALLS" || die 'draft create args'
if grep -q '^release edit' "$CALLS"; then die 'hookless draft was edited'; fi
pass 'green exact plugin job stages a draft with authored notes'
: >"$CALLS"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || die 'rerun failed'
grep -Fq 'already exists (id 900, draft true); nothing to stage' "$TMP/out" || die 'idempotent notice'
if grep -Eq '^api |^release create' "$CALLS"; then die 'rerun consulted gate or created release'; fi
pass 'existing draft returns before the gate and writes nothing'
printf '{"id":900,"isDraft":false}\n' >"$FIX/release.json"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || die 'published release rerun failed'
grep -Fq 'draft false' "$TMP/out" || die 'published state'
pass 'existing published release is left untouched'
printf '{"id":900,"isDraft":true,"isPrerelease":true}\n' >"$FIX/release.json"
: >"$CALLS"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || die 'hookless prerelease draft rerun failed'
grep -Fq 'already exists (id 900, draft true); nothing to stage' "$TMP/out" || die 'hookless prerelease notice'
if grep -Eq '^release (create|delete|edit)' "$CALLS"; then die 'hookless prerelease draft was rewritten'; fi
pass 'a plugin without an asset hook never deletes a prerelease draft it did not stage'

# Asset hook: plugins/<name>/release/stage-assets.sh builds files the draft must carry.
git switch -q main
plugin b; notes b 1.0.0
mkdir -p plugins/b/release
cat >plugins/b/release/stage-assets.sh <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "$RELEASE_TAG" "$RELEASE_VERSION" "$(ls -A "$1" | wc -l)" >>"$HOOK_LOG"
case "${HOOK_MODE:-}" in fail) echo 'packaging broke' >&2; exit 3 ;; empty) exit 0 ;; esac
printf 'runtime\n' >"$1/b-runtime-$RELEASE_VERSION.tar.gz"
printf 'digest\n' >"$1/b-runtime-$RELEASE_VERSION.tar.gz.sha256"
HOOK
chmod +x plugins/b/release/stage-assets.sh
commit; git push -q origin main
git tag b--v1.0.0; git switch -q --detach b--v1.0.0
SHA="$(git rev-parse HEAD)"; export RELEASE_TAG=b--v1.0.0 HOOK_LOG="$TMP/hook.log"
rm -f "$FIX/release.json"
printf '{"workflow_runs":[{"id":11,"head_sha":"%s","head_branch":"main","event":"push","status":"completed"}]}\n' "$SHA" >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"b","conclusion":"success"}]}\n' >"$FIX/jobs-11"
chmod -x plugins/b/release/stage-assets.sh
: >"$CALLS"
reject 'asset hook plugins/b/release/stage-assets.sh is not executable' bash "$SCRIPT"
[ ! -s "$CALLS" ] || die 'non-executable hook called gh'
pass 'a non-executable hook is refused, never skipped'
chmod +x plugins/b/release/stage-assets.sh
HOOK_MODE=fail reject 'asset hook plugins/b/release/stage-assets.sh failed' bash "$SCRIPT"
grep -Fq 'packaging broke' "$TMP/err" || die 'hook stderr not shown'
[ ! -s "$CALLS" ] || die 'failed hook called gh'
pass 'a failing hook stops the stage before gh'
HOOK_MODE=empty reject 'asset hook plugins/b/release/stage-assets.sh produced no files' bash "$SCRIPT"
[ ! -s "$CALLS" ] || die 'empty hook called gh'
pass 'a hook that builds nothing stops the stage before gh'
: >"$HOOK_LOG"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'hooked stage failed'; }
[ "$(cat "$HOOK_LOG")" = 'b--v1.0.0 1.0.0 0' ] || die "hook env or outdir: $(cat "$HOOK_LOG")"
grep -Eq '^release create b--v1\.0\.0 [^ ]+/b-runtime-1\.0\.0\.tar\.gz [^ ]+/b-runtime-1\.0\.0\.tar\.gz\.sha256 --draft --prerelease --verify-tag --title b v1\.0\.0 --notes-file plugins/b/docs/release-notes/v1\.0\.0\.md$' "$CALLS" \
  || { cat "$CALLS"; die 'hooked create args'; }
grep -Fq '::notice::staged draft b--v1.0.0 (id 900)' "$TMP/out" || die 'hooked draft notice'
if grep -q '^release delete' "$CALLS"; then die 'complete draft was deleted'; fi
[ "$(jq -r '[.assets[].name] | join(",")' "$FIX/release.json")" = 'b-runtime-1.0.0.tar.gz,b-runtime-1.0.0.tar.gz.sha256' ] || die 'assets not on the draft'
pass 'a hook runs with the tag and an empty outdir, and every file it builds rides the draft'
# The flag clears only after the asset check, so the draft turns eligible only when complete.
[ "$(grep -nE '^release (view b--v1\.0\.0 --json assets|edit)' "$CALLS" | cut -d: -f2- | paste -sd '|' -)" = 'release view b--v1.0.0 --json assets --jq .assets[].name|release edit b--v1.0.0 --prerelease=false' ] \
  || { cat "$CALLS"; die 'flag cleared before the asset check'; }
[ "$(jq -r '[.isDraft, .isPrerelease] | join(",")' "$FIX/release.json")" = 'true,false' ] || die 'staged draft is not an eligible draft'
pass 'a hooked draft stays a prerelease until its assets check out, then becomes an eligible draft'
: >"$CALLS"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'hooked rerun failed'; }
grep -Fq 'already exists (id 900, draft true); nothing to stage' "$TMP/out" || die 'hooked idempotent notice'
if grep -Eq '^api |^release (create|delete|edit)' "$CALLS"; then die 'hooked rerun wrote or consulted the gate'; fi
pass 'a rerun over a draft with every asset stages nothing'
printf '{"id":900,"isDraft":true,"isPrerelease":false,"assets":[{"name":"b-runtime-1.0.0.tar.gz"}]}\n' >"$FIX/release.json"
: >"$CALLS"
reject 'release b--v1.0.0 already exists (id 900, draft true) but lacks b-runtime-1.0.0.tar.gz.sha256' bash "$SCRIPT"
grep -Fq 'it may already be pinned, so it is left alone' "$TMP/err" || die 'eligible short draft reason'
if grep -Eq '^release (create|delete|edit)' "$CALLS"; then die 'incomplete existing release was rewritten'; fi
pass 'an eligible release missing a hook asset fails, names it, and is left alone'
rm -f "$FIX/release.json"
: >"$CALLS"
DROP_ASSET=b-runtime-1.0.0.tar.gz.sha256 reject 'draft b--v1.0.0 lacked b-runtime-1.0.0.tar.gz.sha256 after upload and was deleted' bash "$SCRIPT"
grep -Fxq 'release delete b--v1.0.0 --yes' "$CALLS" || die 'short draft not deleted'
if grep -q '^release edit' "$CALLS"; then die 'short draft was made eligible'; fi
[ ! -f "$FIX/release.json" ] || die 'short draft still exists'
pass 'a draft that comes back short of an asset is deleted while still ineligible, keeping the tag'
: >"$CALLS"
CREATE_FAIL=after DROP_ASSET=b-runtime-1.0.0.tar.gz.sha256 reject 'could not stage draft b--v1.0.0; the partial staging draft was deleted' bash "$SCRIPT"
grep -Fxq 'release delete b--v1.0.0 --yes' "$CALLS" || die 'partial draft from a failed create not deleted'
if grep -q '^release edit' "$CALLS"; then die 'failed create was made eligible'; fi
[ ! -f "$FIX/release.json" ] || die 'partial draft from a failed create still exists'
pass 'a create that keeps a partial draft and then fails deletes that draft before exiting'
: >"$CALLS"
CREATE_FAIL=before reject 'could not stage draft b--v1.0.0' bash "$SCRIPT"
if grep -q '^release delete' "$CALLS"; then die 'a create that made nothing still deleted'; fi
pass 'a create that made no release fails without deleting anything'
: >"$CALLS"
IGNORE_PRERELEASE=1 DROP_ASSET=b-runtime-1.0.0.tar.gz.sha256 reject 'staging draft b--v1.0.0 lacks b-runtime-1.0.0.tar.gz.sha256 and could not be deleted' bash "$SCRIPT"
if grep -q '^release delete' "$CALLS"; then die 'an eligible draft was deleted'; fi
[ -f "$FIX/release.json" ] || die 'eligible draft vanished'
pass 'cleanup refuses to delete a draft that is not still a prerelease'
rm -f "$FIX/release.json"
: >"$CALLS"
EDIT_FAIL=1 reject 'staging draft b--v1.0.0 has every asset but its prerelease flag could not be cleared' bash "$SCRIPT"
[ "$(jq -r .isPrerelease "$FIX/release.json")" = true ] || die 'failed edit left an eligible draft'
pass 'a flag that will not clear leaves the draft ineligible and fails'
: >"$CALLS"
bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'rerun over an unfinished staging draft failed'; }
grep -Fq '::notice::deleted unfinished staging draft b--v1.0.0 (id 900); staging it again' "$TMP/out" || die 'unfinished draft notice'
[ "$(grep -E '^release (delete|create|edit)' "$CALLS" | cut -d' ' -f1-2 | paste -sd ',' -)" = 'release delete,release create,release edit' ] || { cat "$CALLS"; die 'unfinished draft rerun order'; }
[ "$(jq -r '[.isDraft, .isPrerelease] | join(",")' "$FIX/release.json")" = 'true,false' ] || die 'restaged draft is not eligible'
pass 'a rerun over an unfinished staging draft deletes it and stages a complete one'
printf '{"id":900,"isDraft":true,"isPrerelease":true,"assets":[]}\n' >"$FIX/release.json"
: >"$CALLS"
DELETE_FAIL=1 reject 'release b--v1.0.0 is an unfinished staging draft (id 900) and could not be deleted' bash "$SCRIPT"
if grep -Eq '^api |^release create' "$CALLS"; then die 'undeletable unfinished draft still staged'; fi
pass 'an unfinished staging draft that cannot be deleted stops the rerun before the gate'
rm -f "$FIX/release.json"
: >"$CALLS"
EDIT_NOOP=1 reject 'staging draft b--v1.0.0 still reads prerelease true after clearing the flag' bash "$SCRIPT"
pass 'a flag clear that does not take is caught, not reported as staged'

printf '%s release-stage checks passed\n' "$PASS"
