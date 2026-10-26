#!/usr/bin/env bash
# Proves route fences run before freshen/sweep mutations. Every protected repo
# has reachable mutation state so removing a fence makes this suite fail.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" REPO_ROUTE_HOST_ID=maintenance-test
mkdir -p "$HOME" "$TMP/sites" "$TMP/bin"
export REPO_ROUTE_CONFIG="$TMP/routes.json" REPO_ROUTE_STATE="$TMP/state.json"
cat >"$REPO_ROUTE_CONFIG" <<'EOF'
{"version":1,"routes":[{"id":"r","identities":["github.com/o/r"],"directWorktreeDefaultMode":"warn"}]}
EOF
R="$HERE/scripts/repo-route.py"
for d in canonical independent; do
  git init -q "$TMP/sites/$d"
  git -C "$TMP/sites/$d" config user.email test@example.test
  git -C "$TMP/sites/$d" config user.name test
  git -C "$TMP/sites/$d" commit --allow-empty -qm init
  git -C "$TMP/sites/$d" branch -M main
  git -C "$TMP/sites/$d" remote add origin https://github.com/o/r.git
  git -C "$TMP/sites/$d" update-ref refs/remotes/origin/main HEAD
  git -C "$TMP/sites/$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
done
# Real preservation pair: the canonical lineage has one clean, old-enough
# worktree that is genuinely eligible for the existing removal path. The
# independent clone has its own linked worktree with unique untracked content;
# without the route exclusion it would reach prune and the preserve/remove path.
git -C "$TMP/sites/canonical" worktree add -q -b task "$TMP/task-worktree"
git -C "$TMP/sites/independent" worktree add -q -b independent-task "$TMP/independent-worktree"
printf 'independent unique work\n' >"$TMP/independent-worktree/keep.txt"
python3 "$R" bootstrap --route r --canonical-path "$TMP/sites/canonical" --mode warn >/dev/null
cp "$REPO_ROUTE_STATE" "$TMP/state.registered.json"
REAL_GIT=$(command -v git); export REAL_GIT GIT_LOG="$TMP/git.log"
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'GIT_OPTIONAL_LOCKS=%s %s\n' "${GIT_OPTIONAL_LOCKS-}" "$*" >>"$GIT_LOG"
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TMP/bin/git"

independent_registration=$(git -C "$TMP/sites/independent" worktree list --porcelain)
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 \
  "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep.out" 2>&1
[ ! -d "$TMP/task-worktree" ] || { echo "FAIL: eligible canonical worktree was not removed" >&2; exit 1; }
[ -d "$TMP/independent-worktree" ] || { echo "FAIL: independent worktree was removed" >&2; exit 1; }
grep -qx 'independent unique work' "$TMP/independent-worktree/keep.txt"
[ "$independent_registration" = "$(git -C "$TMP/sites/independent" worktree list --porcelain)" ] || {
  echo "FAIL: independent worktree registration changed" >&2; exit 1;
}
grep -F -- "-C $TMP/sites/canonical worktree prune" "$TMP/git.log" >/dev/null
if grep -F -- "-C $TMP/sites/independent worktree prune" "$TMP/git.log" >/dev/null || \
   grep -F -- "worktree remove --force $TMP/independent-worktree" "$TMP/git.log" >/dev/null; then
  echo "FAIL: collision sweep mutated the independent lineage" >&2; exit 1
fi
grep -Fq 'removed:1  preserved-local:1  dropped:0  bundled:0  kept-in-place:0  skipped-active:0  stale-workspaces:0  skipped-route:1' "$TMP/sweep.out"

# The rollout mode changes reporting, not canonical cleanup authority. Exercise
# fresh eligible canonical worktrees in the other two modes while the same
# independent worktree remains protected.
for mode in observe enforce; do
  python3 "$R" set-mode --route r --mode "$mode" >/dev/null
  git -C "$TMP/sites/canonical" worktree add -q -b "task-$mode" "$TMP/task-$mode"
  : >"$TMP/git.log"
  PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 \
    "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-$mode.out" 2>&1
  [ ! -d "$TMP/task-$mode" ] || { echo "FAIL: $mode mode did not remove eligible canonical worktree" >&2; exit 1; }
  [ -d "$TMP/independent-worktree" ] || { echo "FAIL: $mode mode removed independent worktree" >&2; exit 1; }
  grep -Fq 'skipped-active:0  stale-workspaces:0  skipped-route:1' "$TMP/sweep-$mode.out"
done
python3 "$R" set-mode --route r --mode warn >/dev/null

# Route eligibility only reaches the historical safety gates. A genuinely recent
# canonical worktree remains present and is counted separately from the route
# exclusion of the independent common-dir.
git -C "$TMP/sites/canonical" worktree add -q -b active-task "$TMP/active-worktree"
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=120 \
  "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-active.out" 2>&1
[ -d "$TMP/active-worktree" ] || { echo "FAIL: recent canonical worktree was removed" >&2; exit 1; }
grep -Fq 'skipped-active:1  stale-workspaces:0  skipped-route:1' "$TMP/sweep-active.out"
git -C "$TMP/sites/canonical" worktree remove --force "$TMP/active-worktree"

# Dry-run must predict the existing cleanup path without executing any Git write.
# Include old, missing worktree metadata so an unconditional `worktree prune`
# would be observably destructive, rather than merely appearing in an argv log.
git -C "$TMP/sites/canonical" worktree add -q -b dry-task "$TMP/dry-worktree"
git -C "$TMP/sites/canonical" worktree add -q --detach "$TMP/prunable-worktree"
prunable_gitdir=$(git -C "$TMP/prunable-worktree" rev-parse --absolute-git-dir)
mv "$TMP/prunable-worktree" "$TMP/prunable-worktree-gone"
touch -d '200 days ago' "$prunable_gitdir/gitdir"
canonical_registration=$($REAL_GIT -C "$TMP/sites/canonical" worktree list --porcelain)
canonical_refs=$($REAL_GIT -C "$TMP/sites/canonical" show-ref)
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=1 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 \
  "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-dry.out" 2>&1
grep -Fq "would: git -C '$TMP/sites/canonical' worktree prune" "$TMP/sweep-dry.out"
grep -Fq "would: git -C '$TMP/sites/canonical' worktree remove --force '$TMP/dry-worktree'" "$TMP/sweep-dry.out"
[ -d "$TMP/dry-worktree" ] || { echo "FAIL: dry run removed canonical worktree" >&2; exit 1; }
[ -d "$prunable_gitdir" ] || { echo "FAIL: dry run pruned stale worktree metadata" >&2; exit 1; }
[ "$canonical_registration" = "$($REAL_GIT -C "$TMP/sites/canonical" worktree list --porcelain)" ] || {
  echo "FAIL: dry run changed canonical worktree registrations" >&2; exit 1;
}
[ "$canonical_refs" = "$($REAL_GIT -C "$TMP/sites/canonical" show-ref)" ] || {
  echo "FAIL: dry run changed canonical refs" >&2; exit 1;
}
if grep -E -- ' (fetch|reset|update-ref)( |$)|worktree (prune|remove)| branch -[dD]( |$)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: dry run invoked a mutating Git command" >&2; exit 1
fi
if grep -v '^GIT_OPTIONAL_LOCKS=0 ' "$TMP/git.log" >/dev/null; then
  echo "FAIL: dry-run Git read omitted GIT_OPTIONAL_LOCKS=0" >&2; exit 1
fi
[ -d "$TMP/independent-worktree" ] || { echo "FAIL: dry run removed independent worktree" >&2; exit 1; }

# Planted negatives: a canonical label is insufficient. Missing trust fields or
# a recorded/common-dir disagreement must protect both common-dirs before prune.
CANONICAL_COMMON=$($REAL_GIT -C "$TMP/sites/canonical" rev-parse --absolute-git-dir)
INDEPENDENT_COMMON=$($REAL_GIT -C "$TMP/sites/independent" rev-parse --absolute-git-dir)
export CANONICAL_COMMON INDEPENDENT_COMMON
cat >"$TMP/proof-scan.py" <<'PY'
#!/usr/bin/env python3
import json, os
common = os.environ["CANONICAL_COMMON"]
canonical = os.path.dirname(common)
entry = {
    "schema": "repo-route.v1", "repo": canonical, "top_level": canonical,
    "common_dir": common, "git_dir": common, "route": "r", "mode": "warn",
    "canonical_identity": "github.com/o/r", "canonical_path": canonical,
    "recorded_common_dir": common, "classification": "canonical",
    "verified": True, "authority_registered": True, "canonical_missing": False,
}
case = os.environ["PROOF_CASE"]
if case == "incomplete":
    del entry["authority_registered"]
elif case == "mismatch":
    entry["recorded_common_dir"] = common + "-other"
independent_top = os.path.dirname(os.environ["INDEPENDENT_COMMON"])
independent = {
    "schema": "repo-route.v1", "repo": independent_top, "top_level": independent_top,
    "common_dir": os.environ["INDEPENDENT_COMMON"], "git_dir": os.environ["INDEPENDENT_COMMON"],
    "route": "r", "mode": "warn", "canonical_identity": "github.com/o/r",
    "canonical_path": canonical, "recorded_common_dir": common,
    "classification": "noncanonical-independent-clone", "verified": True,
    "authority_registered": True, "canonical_missing": False,
}
if case == "contradictory":
    independent["canonical_path"] = canonical + "-other"
print(json.dumps({
    "schema": "repo-route-scan.v1", "verified": True,
    "routes": [{"route": "r", "collision": True, "unverified": False,
                "authority_missing": False, "canonical_missing": False,
                "entries": [entry, independent]}],
}))
PY
chmod +x "$TMP/proof-scan.py"
for proof_case in incomplete mismatch contradictory; do
  proof_independent_registration=$($REAL_GIT -C "$TMP/sites/independent" worktree list --porcelain)
  proof_independent_content=$(<"$TMP/independent-worktree/keep.txt")
  : >"$TMP/git.log"
  PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 \
    PROOF_CASE="$proof_case" REPO_ROUTE_RESOLVER="$TMP/proof-scan.py" \
    "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-$proof_case.out" 2>&1
  [ -d "$TMP/dry-worktree" ] || { echo "FAIL: $proof_case proof reached canonical removal" >&2; exit 1; }
  [ -d "$TMP/independent-worktree" ] || { echo "FAIL: $proof_case proof removed independent worktree" >&2; exit 1; }
  [ "$proof_independent_content" = "$(<"$TMP/independent-worktree/keep.txt")" ] || {
    echo "FAIL: $proof_case proof changed independent worktree content" >&2; exit 1;
  }
  [ "$proof_independent_registration" = "$($REAL_GIT -C "$TMP/sites/independent" worktree list --porcelain)" ] || {
    echo "FAIL: $proof_case proof changed independent worktree registration" >&2; exit 1;
  }
  if grep -F -- "-C $TMP/sites/canonical worktree prune" "$TMP/git.log" >/dev/null; then
    echo "FAIL: $proof_case proof reached canonical prune" >&2; exit 1
  fi
  if grep -F -- "-C $TMP/sites/independent worktree prune" "$TMP/git.log" >/dev/null || \
     grep -F -- "worktree remove --force $TMP/independent-worktree" "$TMP/git.log" >/dev/null; then
    echo "FAIL: $proof_case proof mutated the independent lineage" >&2; exit 1
  fi
done

# Restore the canonical fixture topology before the authority-loss scenarios.
mv "$TMP/prunable-worktree-gone" "$TMP/prunable-worktree"
git -C "$TMP/sites/canonical" worktree remove --force "$TMP/prunable-worktree"
git -C "$TMP/sites/canonical" worktree remove --force "$TMP/dry-worktree"

# The canonical checkout need not be under the scanned root. Resolver evidence on
# a linked sibling still grants only that recorded common-dir; an independent
# clone discovered beside it remains protected.
mkdir -p "$TMP/cross-root"
git -C "$TMP/sites/canonical" worktree add -q -b cross-task "$TMP/cross-root/canonical-sibling"
git init -q "$TMP/cross-root/independent"
git -C "$TMP/cross-root/independent" config user.email test@example.test
git -C "$TMP/cross-root/independent" config user.name test
git -C "$TMP/cross-root/independent" commit --allow-empty -qm init
git -C "$TMP/cross-root/independent" branch -M main
git -C "$TMP/cross-root/independent" remote add origin https://github.com/o/r.git
git -C "$TMP/cross-root/independent" update-ref refs/remotes/origin/main HEAD
git -C "$TMP/cross-root/independent" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$TMP/cross-root/independent" worktree add -q -b cross-independent-task "$TMP/cross-root/independent-worktree"
printf 'cross-root independent work\n' >"$TMP/cross-root/independent-worktree/keep.txt"
cross_independent_registration=$(git -C "$TMP/cross-root/independent" worktree list --porcelain)
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" ROOT="$TMP/cross-root" DRY_RUN=0 WT_SWEEP_ALLOW_TMP=1 ACTIVE_MIN=0 \
  "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-cross-root.out" 2>&1
[ ! -d "$TMP/cross-root/canonical-sibling" ] || { echo "FAIL: cross-root canonical sibling was not removed" >&2; exit 1; }
[ -d "$TMP/cross-root/independent-worktree" ] || { echo "FAIL: cross-root independent worktree was removed" >&2; exit 1; }
grep -qx 'cross-root independent work' "$TMP/cross-root/independent-worktree/keep.txt"
[ "$cross_independent_registration" = "$(git -C "$TMP/cross-root/independent" worktree list --porcelain)" ] || {
  echo "FAIL: cross-root independent registration changed" >&2; exit 1;
}
grep -Fq 'removed:1  preserved-local:1  dropped:0  bundled:0  kept-in-place:0  skipped-active:0  stale-workspaces:0  skipped-route:1' "$TMP/sweep-cross-root.out"

# An independent launchpad has a default ref and would fetch if its route gate
# were removed. Network/state effects must remain absent.
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" FRESHEN_FETCH_TIMEOUT=1 "$HERE/scripts/launchpad-freshen.sh" \
  --repo "$TMP/sites/independent" >"$TMP/freshen-collision.out" 2>&1 || true
if grep -E -- '(^| )((fetch)|(merge)|(switch))( |$)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: collision freshen reached fetch/merge/switch" >&2; exit 1
fi
grep -q 'noncanonical-independent-clone.*skipped mutation' "$TMP/freshen-collision.out"

# Portable warn/enforce with no local authority also suppresses automated
# maintenance; it is not permission to crown whichever checkout ran first.
rm "$REPO_ROUTE_STATE"
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-unregistered.out" 2>&1
if grep -E 'worktree (prune|remove)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: authority-missing sweep reached prune/removal" >&2; exit 1
fi
grep -q 'repo-route authority/collision guard; skipped before prune/removal' "$TMP/sweep-unregistered.out"
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" FRESHEN_FETCH_TIMEOUT=1 "$HERE/scripts/launchpad-freshen.sh" \
  --repo "$TMP/sites/canonical" >"$TMP/freshen-unregistered.out" 2>&1 || true
if grep -E -- '(^| )((fetch)|(merge)|(switch))( |$)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: authority-missing freshen reached fetch/merge/switch" >&2; exit 1
fi
grep -q 'has no authority registered on this host; skipped mutation' "$TMP/freshen-unregistered.out"

# Observe is the non-blocking rollout stage for reversible freshening before any
# host authority has been bootstrapped. The scan/advisory reports this state;
# warn is the first mode that suppresses it.
printf '%s\n' '{"version":1,"routes":[{"id":"r","identities":["github.com/o/r"],"directWorktreeDefaultMode":"observe"}]}' >"$REPO_ROUTE_CONFIG"
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" FRESHEN_FETCH_TIMEOUT=1 "$HERE/scripts/launchpad-freshen.sh" \
  --repo "$TMP/sites/canonical" >"$TMP/freshen-unregistered-observe.out" 2>&1 || true
if ! command grep -E -- '(^| )fetch( |$)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: observe rollout unexpectedly blocked reversible authority-missing freshen" >&2; exit 1
fi

# Resolve the real authority-loss state: in observe mode an independent clone
# must not become the replacement launchpad merely because the canonical path
# disappeared.
cp "$TMP/state.registered.json" "$REPO_ROUTE_STATE"
python3 "$R" set-mode --route r --mode observe >/dev/null
mv "$TMP/sites/canonical" "$TMP/removed-canonical"
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" FRESHEN_FETCH_TIMEOUT=1 "$HERE/scripts/launchpad-freshen.sh" \
  --repo "$TMP/sites/independent" >"$TMP/freshen-missing-independent.out" 2>&1 || true
if grep -E -- '(^| )((fetch)|(merge)|(switch))( |$)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: missing-canonical independent clone reached fetch/merge/switch" >&2; exit 1
fi
grep -q 'canonical launchpad is absent' "$TMP/freshen-missing-independent.out"

# A missing canonical path is a preservation event even in observe mode.
cat >"$TMP/missing-scan.py" <<'PY'
#!/usr/bin/env python3
import json, os
canonical = os.environ["MISSING_COMMON"]
independent = os.environ["INDEPENDENT_COMMON"]
print(json.dumps({
    "schema": "repo-route-scan.v1", "verified": True,
    "routes": [{
        "route": "r", "collision": True, "unverified": False,
        "authority_missing": False, "canonical_missing": True,
        "entries": [
            {"classification": "canonical-sibling", "mode": "observe", "common_dir": canonical},
            {"classification": "noncanonical-independent-clone", "mode": "observe", "common_dir": independent},
        ],
    }],
}))
PY
chmod +x "$TMP/missing-scan.py"
MISSING_COMMON=$(realpath "$TMP/removed-canonical/.git")
INDEPENDENT_COMMON=$(realpath "$TMP/sites/independent/.git")
export MISSING_COMMON INDEPENDENT_COMMON
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 REPO_ROUTE_RESOLVER="$TMP/missing-scan.py" \
  "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-missing.out" 2>&1
if grep -E 'worktree (prune|remove)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: canonical-missing sweep reached prune/removal" >&2; exit 1
fi

# Resolver absence must skip freshen before any git read or mutation.
: >"$TMP/git.log"
PATH="$TMP/bin:$PATH" REPO_ROUTE_RESOLVER="$TMP/no-resolver.py" SITES_ROOT="$TMP/sites" \
  "$HERE/scripts/launchpad-freshen.sh" >"$TMP/freshen.out" 2>&1 || true
if [ -s "$TMP/git.log" ]; then echo "FAIL: resolver-error freshen reached git path" >&2; exit 1; fi
grep -q 'resolver failed; skipped before mutation' "$TMP/freshen.out"

# A malformed policy has no route id, but must stop sweeping globally before
# prune/removal. Restore registered state so only policy validity is under test.
cp "$TMP/state.registered.json" "$REPO_ROUTE_STATE"
printf '%s\n' '{"version":1,"routes":[{"id":"broken","identities":[42]}]}' >"$REPO_ROUTE_CONFIG"
: >"$TMP/git.log"
if PATH="$TMP/bin:$PATH" ROOT="$TMP/sites" DRY_RUN=0 "$HERE/scripts/wt-sweep.sh" >"$TMP/sweep-broken.out" 2>&1; then
  echo "FAIL: malformed policy sweep unexpectedly succeeded" >&2; exit 1
fi
if grep -E 'worktree (prune|remove)' "$TMP/git.log" >/dev/null; then
  echo "FAIL: malformed policy sweep reached prune/removal" >&2; exit 1
fi
grep -q 'repo-route scan result unverified; refusing all mutations' "$TMP/sweep-broken.out"

# Weekly wiring order is itself an authority contract: scan and its named
# counter must precede launchpad mutation and the toast predicate must include it.
python3 - "$HERE/scripts/harness-weekly.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
umask = source.index('umask 077')
report = source.index('REPORT=$LOGDIR/')
secure_create = source.index(': >"$REPORT"')
report_append = source.index('} >>"$REPORT" 2>&1')
scan = source.index('## repository route scan')
freshen = source.index('## launchpad freshen')
extract = source.index('ROUTE=$(grep')
predicate = source.index('if [ "${WARNS:-0}"')
notify = source.index('repository route group(s) needing attention')
assert umask < report < secure_create < report_append
assert 'chmod 600 "$REPORT"' in source[secure_create:report_append]
assert scan < freshen
assert extract < predicate < notify
assert '${ROUTE:-0}' in source[predicate:notify + 200]
PY

echo "ok — repo route maintenance fences"
