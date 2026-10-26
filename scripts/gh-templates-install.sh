#!/usr/bin/env bash
# gh-templates-install.sh: seed the canonical issue/PR templates into repos.
#
# Payload (single source of truth): scripts/gh-templates/payload/.github/
#   ISSUE_TEMPLATE/{work-spec.yml,quick-capture.yml,config.yml} + PULL_REQUEST_TEMPLATE.md
#
# Env:
#   DRY_RUN=1 (default) print the plan only; DRY_RUN=0 apply.
#   ROOT=~/SITES        directory of repos to consider.
#   ONLY=<repo-name>    limit to one repo.
#
# Per target repo WITHOUT its own .github/ISSUE_TEMPLATE: creates a throwaway
# worktree on branch chore/add-issue-pr-templates off origin/<default>, copies
# the payload, pushes, opens a draft PR (review surface stays the normal one),
# and removes the worktree. Repos that already have ISSUE_TEMPLATE
# are never touched (GitHub folder inheritance is all-or-nothing; reconcile by
# hand if the canonical shape should replace a custom one).
#
# Rate-limit hygiene: sleeps 1s between repos (content-creation secondary limit).
# Summary line: "gh-templates-install: installed:N skipped-existing:N would-install:N"
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/gh-repo-helpers.sh"
SRC="$HERE/gh-templates/payload"
[ -d "$SRC/.github" ] || { echo "payload missing: $SRC/.github" >&2; exit 2; }

DRY_RUN="${DRY_RUN:-1}"
ROOT="${ROOT:-$HOME/SITES}"
ONLY="${ONLY:-}"
installed=0 skipped=0 would=0

seed_repo() {
  local repo="$1" name="$2" slug def br wt
  if [ -d "$repo/.github/ISSUE_TEMPLATE" ]; then
    echo "$name: has own templates, skipped"; skipped=$((skipped+1)); return
  fi
  slug=$(owner_repo_of "$repo")
  if [ -z "$slug" ]; then
    echo "$name: no origin remote, skipped"; skipped=$((skipped+1)); return
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "$name: (dry) would add templates via draft PR"; would=$((would+1)); return
  fi
  git -C "$repo" fetch origin --quiet || { echo "$name: fetch failed, skipped"; skipped=$((skipped+1)); return; }
  def=$(def_of "$repo")
  br="chore/add-issue-pr-templates"
  wt="$repo/.claude/worktrees/gh-templates-rollout-$(date +%Y%m%d)"
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$br" \
     || git -C "$repo" show-ref --verify --quiet "refs/heads/$br"; then
    echo "$name: branch $br already exists, skipped (PR pending?)"; skipped=$((skipped+1)); return
  fi
  git -C "$repo" worktree add "$wt" -b "$br" "origin/$def" >/dev/null 2>&1 \
    || { echo "$name: worktree add failed, skipped"; skipped=$((skipped+1)); return; }
  mkdir -p "$wt/.github"
  cp -r "$SRC/.github/." "$wt/.github/"
  git -C "$wt" add .github
  git -C "$wt" commit --quiet -m "chore: add issue/PR templates (work-spec form + PR pre-completion checklist)"
  if git -C "$wt" push -u origin "$br" --quiet 2>/dev/null; then
    gh pr create --repo "$slug" --draft --head "$br" \
      --title "chore: add issue/PR templates" \
      --body "Additive docs-only change: canonical work-spec + quick-capture issue forms and the PR template (DoD + pre-completion checklist) from dotfiles scripts/gh-templates/payload. Mechanism doc: harness/gh-tracking-and-claims.md." \
      >/dev/null 2>&1 && echo "$name: draft PR opened ($br)" \
      || echo "$name: PR create failed (branch $br pushed; open the PR by hand)"
    installed=$((installed+1))
  else
    echo "$name: push failed, skipped"; skipped=$((skipped+1))
  fi
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  sleep 1
}

for_each_repo "$ROOT" seed_repo "$ONLY"
echo "gh-templates-install: installed:$installed skipped-existing:$skipped would-install:$would"
[ "$skipped" -gt 0 ] && exit 1 || exit 0
