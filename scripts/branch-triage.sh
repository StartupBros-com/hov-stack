#!/usr/bin/env bash
# branch-triage — classify (and optionally dispose of) stale LOCAL branches.
# The sibling of wt-sweep.sh: wt-sweep reclaims worktrees; this reclaims the
# branch graveyard squash-merges leave behind (content shipped, SHAs orphaned).
#
#   DRY_RUN=1 (default) classify + print plan; DRY_RUN=0 apply disposals.
#   ROOT=~/SITES  ONLY=<repo>  MIN_AGE_DAYS=2 (never touch younger branches
#   unless their PR merged)  PR_LIMIT=1000 (merged-PR head names fetched/repo)
#
# Funnel (cheapest test first; first match wins):
#   PROTECTED  default branch / checked out in a worktree / OPEN PR head  -> skip
#   MERGED     reachable from origin/<def>            -> delete (upstream has it)
#   SYNCED     has upstream, 0 commits ahead of it    -> delete (remote has it)
#   TREE-SAME  empty three-dot diff vs origin/<def>   -> bundle + delete
#   PR-SHIPPED head-name matches a MERGED PR          -> bundle + delete
#   CHERRY     git cherry: all commits equivalent     -> bundle + delete
#   RESIDUE    real unique content                    -> keep, list for deep triage
#
# Bundles: one incremental bundle per repo per run under
#   ~/.claude/git-archive/<repo>/<date>-branch-triage/  — restore any branch with
#   `git fetch <bundle> <branch>:<branch>`.
set -uo pipefail
DRY_RUN="${DRY_RUN:-1}"; ROOT="${ROOT:-$HOME/SITES}"; ONLY="${ONLY:-}"
MIN_AGE_DAYS="${MIN_AGE_DAYS:-2}"; PR_LIMIT="${PR_LIMIT:-1000}"
STAMP="$(date +%Y%m%d)"; now=$(date +%s)
declare -A seen
t_merged=0; t_synced=0; t_tree=0; t_pr=0; t_cherry=0; t_residue=0; t_prot=0; t_young=0

def_of(){ local r="$1" d
  d=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
  [ -z "$d" ] && for c in main master; do
    git -C "$r" rev-parse --verify -q "origin/$c" >/dev/null 2>&1 && { d=$c; break; }
  done
  echo "$d"; }

for dir in "$ROOT"/*/; do
  dir="${dir%/}"; git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || continue
  cdir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null); case "$cdir" in /*) ;; *) cdir="$dir/$cdir";; esac
  cdir=$(realpath -m "$cdir" 2>/dev/null); [ -n "${seen[$cdir]:-}" ] && continue; seen[$cdir]=1
  repo=$(dirname "$cdir"); name=$(basename "$repo")
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  def=$(def_of "$repo"); [ -n "$def" ] || continue
  git -C "$repo" rev-parse --verify -q "origin/$def" >/dev/null 2>&1 || continue

  n_br=$(git -C "$repo" for-each-ref refs/heads --format='x' | wc -l)
  (( n_br > 1 )) || continue
  echo "### $name (def=$def, $n_br local branches)"

  # one-shot PR head-name sets (empty on gh failure -> conservative fallthrough)
  merged_heads=$(gh pr list --repo "$(git -C "$repo" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
    --state merged --limit "$PR_LIMIT" --json headRefName --jq '.[].headRefName' 2>/dev/null | sort -u)
  open_heads=$(gh pr list --repo "$(git -C "$repo" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
    --state open --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null | sort -u)
  wt_branches=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^branch /{print $2}' | sed 's@refs/heads/@@')

  del_plain=(); del_bundle=()
  while IFS= read -r br; do
    [ "$br" = "$def" ] && continue
    # HERE-STRINGS, NOT PIPES. `printf ... | grep -q` is unsafe under this
    # script's `set -o pipefail`: grep -q exits the instant it matches and closes
    # the pipe, the still-writing printf dies of SIGPIPE, and pipefail returns
    # that 141 — so the test reports NOT-FOUND precisely because it WAS found.
    # It is a race against the ~64KB pipe buffer, so it passes until it doesn't.
    #
    # `$merged_heads` is why this one mattered: it is gh's merged-PR head names,
    # measured 12.2KB at 471 PRs and ~26KB at the PR_LIMIT=1000 cap, and it grows
    # every week with no code change here. Reproduced at 349KB: the piped form
    # missed a needle present on line 3 in 10 runs out of 10 — past the buffer it
    # is not flaky, it is reliably wrong. Here that inverts pr_shipped to 0, which
    # WITHHOLDS shipped branches from del_bundle rather than deleting live ones —
    # the safe direction, and therefore the kind that goes unnoticed for a year.
    #
    # `<<<` supplies the same trailing newline `printf '%s\n'` did, so -x
    # exact-line matching is unchanged. Same bug class as the members app's #1379.
    if grep -qxF -- "$br" <<<"$wt_branches"; then t_prot=$((t_prot+1)); continue; fi
    if grep -qxF -- "$br" <<<"$open_heads"; then echo "  = open-PR (kept): $br"; t_prot=$((t_prot+1)); continue; fi

    pr_shipped=0
    grep -qxF -- "$br" <<<"$merged_heads" && pr_shipped=1

    age_days=$(( (now - $(git -C "$repo" log -1 --format=%ct "$br" 2>/dev/null || echo "$now")) / 86400 ))
    if (( age_days < MIN_AGE_DAYS )) && [ "$pr_shipped" = 0 ]; then
      echo "  = too young (kept, ${age_days}d): $br"; t_young=$((t_young+1)); continue
    fi

    if git -C "$repo" merge-base --is-ancestor "$br" "origin/$def" 2>/dev/null; then
      echo "  - MERGED: $br"; del_plain+=("$br"); t_merged=$((t_merged+1)); continue
    fi
    if u=$(git -C "$repo" rev-parse --verify -q "$br@{u}" 2>/dev/null); then
      ahead=$(git -C "$repo" rev-list --count "$u..$br" 2>/dev/null || echo 1)
      if [ "$ahead" = 0 ]; then echo "  - SYNCED: $br"; del_plain+=("$br"); t_synced=$((t_synced+1)); continue; fi
    fi
    if git -C "$repo" diff --quiet "origin/$def...$br" 2>/dev/null; then
      echo "  - TREE-SAME: $br"; del_bundle+=("$br"); t_tree=$((t_tree+1)); continue
    fi
    if [ "$pr_shipped" = 1 ]; then
      echo "  - PR-SHIPPED: $br"; del_bundle+=("$br"); t_pr=$((t_pr+1)); continue
    fi
    # Same SIGPIPE hazard as the membership tests above, in a different spelling:
    # `git cherry | grep -q` inverts identically, and `git cherry` on a long-lived
    # divergent branch is exactly the unbounded output that triggers it. Worth
    # noting a printf-only lint would not have flagged this line — the hazard is
    # "pipe into grep -q under pipefail", not any one producer.
    #
    # Captured once rather than twice: the old form ran the same 15s-timeout git
    # call a second time just to count its lines.
    cherry_out=$(timeout 15 git -C "$repo" cherry "origin/$def" "$br" 2>/dev/null || true)
    if grep -q '^+' <<<"$cherry_out"; then
      :
    elif [ -n "$cherry_out" ]; then
      echo "  - CHERRY-MERGED: $br"; del_bundle+=("$br"); t_cherry=$((t_cherry+1)); continue
    fi
    echo "  ? RESIDUE (${age_days}d): $br"; t_residue=$((t_residue+1))
  done < <(git -C "$repo" for-each-ref refs/heads --format='%(refname:short)')

  if [ "$DRY_RUN" = 1 ]; then
    echo "  (dry) would delete ${#del_plain[@]} remote-covered + ${#del_bundle[@]} bundled"
  else
    if [ "${#del_bundle[@]}" -gt 0 ]; then
      arch="$HOME/.claude/git-archive/$(basename "$repo")/$STAMP-branch-triage"; mkdir -p "$arch"
      if git -C "$repo" bundle create "$arch/branches.bundle" "${del_bundle[@]}" "^origin/$def" >/dev/null 2>&1; then
        git -C "$repo" branch -D "${del_bundle[@]}" >/dev/null && echo "  deleted ${#del_bundle[@]} (bundled to $arch)"
      else
        echo "  !! bundle failed — ${#del_bundle[@]} branches KEPT"
      fi
    fi
    [ "${#del_plain[@]}" -gt 0 ] && git -C "$repo" branch -D "${del_plain[@]}" >/dev/null && echo "  deleted ${#del_plain[@]} (remote-covered, no bundle needed)"
  fi
done
echo
echo "===== branch-triage $([ "$DRY_RUN" = 1 ] && echo '(DRY RUN)') ====="
echo "merged:$t_merged synced:$t_synced tree-same:$t_tree pr-shipped:$t_pr cherry:$t_cherry | residue:$t_residue protected:$t_prot young:$t_young"
[ "$DRY_RUN" = 1 ] && echo "(re-run with DRY_RUN=0 to apply; residue needs deep triage)"
exit 0
