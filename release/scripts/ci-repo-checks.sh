#!/usr/bin/env bash
set -euo pipefail

baseline="${BASELINE_SHA:-08f7d22f3a5b59b1658ab2e96a20d0d3c352869c}"
workflows="${WORKFLOWS_DIR:-.github/workflows}"
owners="${CODEOWNERS_FILE:-.github/CODEOWNERS}"
plugins="${PLUGINS_DIR:-plugins}"
required="${REQUIRED_CHECKS:-release/required-checks.tsv}"
failed=0
problem() { printf '::error::%s\n' "$*" >&2; failed=1; }

if ! git cat-file -e "$baseline^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$baseline" HEAD; then
  problem "hardened baseline $baseline is not an ancestor of HEAD"
fi
pins="$(grep -rhoE 'hov-tool-drop-announce\.yml@[0-9a-f]{40}' "$workflows" | sed 's/.*@//' | sort -u || true)"
count="$(grep -c . <<<"$pins" || true)"
if [ "$count" -ne 1 ]; then problem "announce helper has $count distinct pinned shas in $workflows; expected exactly one";
else
  if ! git cat-file -e "$pins^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$pins" HEAD; then
    problem "announce helper pinned sha $pins is not an ancestor of HEAD"
  fi
  for file in release/scripts/tool-drop-announce.sh .github/workflows/hov-tool-drop-announce.yml; do
    if ! git cat-file -e "$pins:$file" 2>/dev/null; then problem "announce helper $file is missing at the pinned sha $pins"; fi
  done
fi
if [ ! -f "$owners" ]; then problem "CODEOWNERS file $owners does not exist";
else
  for pattern in '/.github/' '/release/' '/.claude-plugin/' '**/VERSION' '/setup' '/hooks/' '/plugins/hov-stack/'; do
    if ! awk -v pattern="$pattern" '$1 == pattern && $2 ~ /^@/ { found=1 } END { exit !found }' "$owners"; then
      problem "CODEOWNERS $owners is missing required entry $pattern with an @owner"
    fi
  done
  if [ -d "$plugins" ]; then
    while read -r pattern _ || [ -n "$pattern" ]; do
      case "$pattern" in ''|\#*|*\**) continue ;; esac
      path="${pattern#/}"
      if [[ "$path" == */ ]]; then
        [ -d "$path" ] || problem "CODEOWNERS lists $pattern, which does not exist"
      else [ -e "$path" ] || problem "CODEOWNERS lists $pattern, which does not exist"; fi
    done <"$owners"
  fi
fi
while IFS= read -r -d '' workflow; do
  # Secret names are case-insensitive and may be spelled secrets['NAME']; longer
  # names that merely contain a forbidden one (RELEASE_PATH) are not matches.
  for token in RELEASE_PAT secrets.GH_PAT secrets.PAT secrets.GITHUB_PAT; do
    name="${token#secrets.}"
    if [ "$name" = "$token" ]; then pattern="(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|$)"
    else pattern="secrets(\\.|\\[['\"]?)$name([^A-Za-z0-9_]|$)"; fi
    if grep -qiE "$pattern" "$workflow"; then problem "workflow $workflow contains forbidden user token $token"; fi
  done
  if ! doc="$(yq -o=json '.' "$workflow")" || ! mint_jobs="$(jq -r '
      (.jobs // {}) | to_entries | map(select(any(.value.steps[]?;
        (.uses // "") | startswith("actions/create-github-app-token"))))
      | .[] | [.key, (if (.value.environment | type) == "object"
        then .value.environment.name else (.value.environment // "") end)] | @tsv' <<<"$doc")"; then
    problem "cannot parse jobs in workflow $workflow"
    mint_jobs=''
  fi
  while IFS=$'\t' read -r job environment; do
    [ -n "$job" ] || continue
    if [ "$environment" != release ]; then problem "workflow $workflow job $job mints an App token outside environment: release"; fi
  done <<<"$mint_jobs"
done < <(find "$workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
if [ -d "$plugins" ]; then
  for path in "$plugins"/* "$plugins"/.[!.]* "$plugins"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ ! -d "$path" ] || [ ! -f "$path/.claude-plugin/plugin.json" ]; then
      problem "plugin path $path is not a directory carrying .claude-plugin/plugin.json"
    fi
  done
fi
if [ ! -f "$required" ]; then problem "required checks file $required does not exist";
elif ! awk -F '\t' '/^[[:space:]]*(#|$)/ {next}
    NF != 2 || $1 !~ /^[^/[:space:]]+\.yml$/ || $2 !~ /[^[:space:]]/ {bad=1; print "invalid required check at line " NR > "/dev/stderr"}
    END {exit bad}' "$required"; then problem "required checks $required must have exactly two non-empty tab-separated fields: workflow basename.yml and job name"; fi
# Every repository-root docs path a release script or workflow names must exist:
# comments and CI error text send readers there, and a moved document (the recipe
# at U11) otherwise points them at nothing. Matched: docs/<path>.md on its own,
# with or without a leading ./ and with a sentence-ending period allowed after it.
# Not matched: a docs directory inside another path (plugins/<name>/docs/..., a URL),
# a variable or longer name in front (${dir}docs/x.md, my-docs/x.md), or a longer
# suffix behind (docs/x.mdx, docs/x.md.bak).
scripts="${SCRIPTS_DIR:-release/scripts}"
while IFS=: read -r file doc; do
  [ -n "$doc" ] || continue
  if [ ! -f "$doc" ]; then problem "$file names $doc, which does not exist"; fi
done < <({ find "$scripts" -type f -name '*.sh' 2>/dev/null;
           find "$workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null; } | sort \
  | while IFS= read -r file; do
      grep -oP '(?<![/$}.[:alnum:]_-])(?:\./)?docs/[A-Za-z0-9_./-]+\.md(?![A-Za-z0-9_-]|\.[A-Za-z0-9])' "$file" 2>/dev/null \
        | sed 's#^\./##' | sort -u | sed "s#^#$file:#" || true
    done)
if [ "$failed" -eq 0 ]; then printf 'ok - repository release checks passed\n'; fi
exit "$failed"
