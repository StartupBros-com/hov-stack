#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
export STATE="$TMP/state" FIX="$TMP/fix" TEST_REPO="$TMP/repo"
export MONOREPO_SOURCE_URL=https://github.com/acme/mono.git
mkdir -p "$STATE" "$FIX/acme/widget" "$FIX/acme/mono" "$TMP/bin" "$TEST_REPO/.claude-plugin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command="$1"; shift
operation=''
if [ "$command" = pr ]; then operation="$1"; shift; fi
number='' head='' state='' fields='' filter='' path='' match='' comment='' paginate=false method='' field=''
case "$operation" in view|merge|close) number="$1"; shift; [[ "$number" =~ ^[1-9][0-9]*$ ]] || exit 90 ;; esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --head) head="$2"; shift 2 ;;
    --state) state="$2"; shift 2 ;;
    --json) fields="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    --match-head-commit) match="$2"; shift 2 ;;
    --comment) comment="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -f) field="$2"; shift 2 ;;
    --repo|--limit|--base|--title|--body-file) shift 2 ;;
    --auto|--squash|--delete-branch) shift ;;
    repos/*) path="$1"; shift ;;
    *) printf 'unexpected gh argument: %s\n' "$1" >&2; exit 91 ;;
  esac
done
emit() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
update_pr() {
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$STATE/pr-$number.json" > "$tmp"
  mv "$tmp" "$STATE/pr-$number.json"
}
case "$command $operation" in
  'pr list')
    shopt -s nullglob
    records=("$STATE"/pr-*.json)
    if [ "${#records[@]}" -eq 0 ]; then printf '[]\n'; else
      jq -s --arg head "$head" --arg state "$state" '
        map(select(($head == "" or .headRefName == $head) and
          ($state == "" or $state == "all" or (.state | ascii_downcase) == $state)))
        | sort_by(.number)' "${records[@]}"
    fi | emit ;;
  'pr create')
    shopt -s nullglob
    records=("$STATE"/pr-*.json)
    number=1
    if [ "${#records[@]}" -gt 0 ]; then
      number="$(jq -s 'map(.number) | max + 1' "${records[@]}")"
    fi
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || exit 92
    oid="$(git -C "$TEST_REPO" rev-parse "$head")"
    tmp="$(mktemp)"
    jq -n --argjson n "$number" --arg h "$head" --arg oid "$oid" '{number:$n,headRefName:$h,headRefOid:$oid,baseRefName:"main",
      state:"OPEN",author:{login:"app/startupbros-hov-marketplace-bot"},isCrossRepository:false,autoMergeRequest:null}' > "$tmp"
    mv "$tmp" "$STATE/pr-$number.json"
    printf 'https://github.com/acme/market/pull/%s\n' "$number" ;;
  'pr view')
    if [ "$fields" = files ]; then
      # GitHub lists a PR's files against the merge base with its base, so a card that
      # main was merged into still shows only the manifest.
      oid="$(jq -r '.headRefOid' "$STATE/pr-$number.json")"
      git -C "$TEST_REPO" diff --name-only "main...$oid" \
        | jq -R . | jq -s '{files:map({path:.})}' | emit
    else emit < "$STATE/pr-$number.json"; fi ;;
  'pr merge')
    [ "$match" = "$(jq -r '.headRefOid' "$STATE/pr-$number.json")" ] || exit 93
    update_pr --arg match "$match" '.autoMergeRequest = {mergeMethod:"SQUASH",head:$match}' ;;
  'pr close') update_pr --arg comment "$comment" '.state = "CLOSED" | .closeComment = $comment | .deleteBranch = true' ;;
  'api ')
    case "$path" in
      'repos/acme/market/contents/.claude-plugin/marketplace.json?ref='*)
        ref="${path##*?ref=}"
        blob="$(git -C "$TEST_REPO" rev-parse "$ref:.claude-plugin/marketplace.json")"
        jq -n --arg sha "$blob" '{sha:$sha}' | emit ;;
      repos/acme/widget/releases\?per_page=100|repos/acme/mono/releases\?per_page=100)
        repo="${path#repos/}"; repo="${repo%/releases*}"
        if [ "$paginate" = true ]; then
          for page in "$FIX/$repo"/page-*.json; do cat "$page"; done
        else cat "$FIX/$repo/page-1.json"; fi ;;
      repos/acme/widget/git/ref/tags/*|repos/acme/mono/git/ref/tags/*)
        tag="${path##*/}"
        sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        case "$tag" in *2.0.0) sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;; esac
        jq -n --arg sha "$sha" '{object:{type:"commit",sha:$sha}}' | emit ;;
      repos/acme/widget/compare/*|repos/acme/mono/compare/*) printf '{"status":"behind"}\n' | emit ;;
      # main's one required check, and its runs: ci passes at every head except one
      # whose $STATE/checks-<sha> file names another conclusion.
      'repos/acme/market/rules/branches/main?per_page=100')
        printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]}}]\n' | emit ;;
      'repos/acme/market/commits/'*'/check-runs?filter=latest&per_page=100')
        sha="${path#repos/acme/market/commits/}"; sha="${sha%%/*}"
        conclusion=success
        [ ! -e "$STATE/checks-$sha" ] || conclusion="$(cat "$STATE/checks-$sha")"
        jq -n --arg c "$conclusion" '{total_count:1,check_runs:[{name:"ci",status:"completed",conclusion:$c}]}' | emit ;;
      # Counted by git, so a compare made the wrong way round counts the wrong commits.
      'repos/acme/market/compare/'*)
        range="${path#repos/acme/market/compare/}"
        ahead="$(git -C "$TEST_REPO" rev-list --count "${range%%...*}..${range#*...}")"
        jq -n --argjson n "$ahead" '{ahead_by:$n}' | emit ;;
      # update-branch merges main into the PR's branch, and is refused unless the PR is
      # still at the head the caller names.
      'repos/acme/market/pulls/'*'/update-branch')
        [ "$method" = PUT ] || exit 96
        number="${path#repos/acme/market/pulls/}"; number="${number%%/*}"
        oid="$(jq -r '.headRefOid' "$STATE/pr-$number.json")"
        [ "$field" = "expected_head_sha=$oid" ] || exit 97
        branch="$(jq -r '.headRefName' "$STATE/pr-$number.json")"
        tree="$(git -C "$TEST_REPO" merge-tree --write-tree "$oid" main)" || exit 98
        merged="$(git -C "$TEST_REPO" commit-tree "$tree" -p "$oid" -p main -m "Merge branch 'main' into $branch")"
        git -C "$TEST_REPO" update-ref "refs/heads/$branch" "$merged" "$oid"
        git -C "$TEST_REPO" push -q origin "$branch"
        update_pr --arg oid "$merged" '.headRefOid = $oid'
        printf '%s\n' "$number" >> "$STATE/updates"
        printf '{"message":"Updating pull request branch."}\n' ;;
      repos/acme/widget|repos/acme/mono) printf '{"default_branch":"main"}\n' | emit ;;
      *) printf 'unexpected API: %s\n' "$path" >&2; exit 94 ;;
    esac ;;
  *) exit 95 ;;
esac
STUB
chmod 755 "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# All git writes in this suite are isolated under mktemp, including the bare origin.
git init -q --bare "$TMP/origin.git"
git -C "$TEST_REPO" init -q -b main
git -C "$TEST_REPO" config user.name Fixture
git -C "$TEST_REPO" config user.email fixture@example.com
git -C "$TEST_REPO" config commit.gpgsign false
git -C "$TEST_REPO" config core.hooksPath /dev/null
git -C "$TEST_REPO" remote add origin "$TMP/origin.git"
jq -n --arg sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '{plugins:[
  {name:"widget",source:{source:"url",url:"https://github.com/acme/widget.git",sha:$sha},metadata:{version:"1.0.0",releaseId:10,releaseTag:"v1.0.0"}},
  {name:"gadget",source:{source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/gadget",sha:$sha},metadata:{version:"1.0.0",releaseId:20,releaseTag:"gadget--v1.0.0"}}
]}' > "$TEST_REPO/.claude-plugin/marketplace.json"
git -C "$TEST_REPO" add .claude-plugin/marketplace.json
git -C "$TEST_REPO" commit -qm base
git -C "$TEST_REPO" push -q origin main
base="$(git -C "$TEST_REPO" rev-parse main)"

release_page() { # repo prefix version id
  jq -n --arg t "$2$3" --argjson id "$4" '[{id:$id,tag_name:$t,draft:true,prerelease:false,created_at:"2026-10-21T10:00:00Z"}]' > "$FIX/$1/page-1.json"
}
export PLAN_FILE="$TMP/plan.tsv"
reconcile() {
  (cd "$TEST_REPO" && bash "$ROOT/release/scripts/repin-reconcile.sh") >"$TMP/reconcile-out" 2>"$TMP/reconcile-err"
}
# Reuse the workflow's actual line: changes to its branch rule must break this suite.
key_line="$(yq -r '.jobs.reconcile.steps[] | select(.id == "reconcile") | .run' "$ROOT/.github/workflows/repin-reconcile.yml" | grep -E '^[[:space:]]*key=')"
[ -n "$key_line" ] || die 'workflow has no key assignment'
compute_key() { local key=''; (cd "$TEST_REPO" && eval "$key_line" && printf '%s\n' "$key"); }
open_repin() {
  local branch="$1" existing
  existing="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty')"
  [ -z "$existing" ] || return 0
  git -C "$TEST_REPO" switch -q -c "$branch"
  git -C "$TEST_REPO" add .claude-plugin/marketplace.json
  git -C "$TEST_REPO" commit -qm repin
  git -C "$TEST_REPO" push -q origin "$branch"
  gh pr create --base main --head "$branch" --title repin --body-file "$PLAN_FILE" >"$TMP/create-out"
}
land() {
  env REPO=acme/market BOT_SLUG=startupbros-hov-marketplace-bot "$@" \
    bash "$ROOT/release/scripts/repin-land.sh" >"$TMP/land-out" 2>"$TMP/land-err"
}
assert_state() { jq -e "$2" "$STATE/pr-$1.json" >/dev/null || die "PR $1 state: $2"; }
pr_count() { jq -s 'length' "$STATE"/pr-*.json; }

# Tick 1: widget bumps, and main remains unchanged while PR 1 waits.
release_page acme/widget v 2.0.0 11
release_page acme/mono gadget--v 1.0.0 20
reconcile || die "tick 1 reconcile: $(cat "$TMP/reconcile-err")"
[ "$(cut -f1 "$PLAN_FILE")" = widget ] || die 'tick 1 drift differs'
key1="$(compute_key)"
branch1="repin/auto-$key1"
blob1="$(git -C "$TEST_REPO" hash-object .claude-plugin/marketplace.json)"
open_repin "$branch1"
land DESIRED_BRANCH="$branch1" EXPECTED_BLOB="$blob1" || die "tick 1 land: $(cat "$TMP/land-err")"
assert_state 1 '.state == "OPEN" and .autoMergeRequest.head == .headRefOid and (has("closeComment") | not)'
[ "$(pr_count)" -eq 1 ] || die 'tick 1 opened extra PRs'
pass 'tick 1 queues widget PR 1 for auto-merge and closes nothing'

# Tick 2: within the same hour, on the same main, gadget bumps too.
git -C "$TEST_REPO" switch -q main
[ "$(git -C "$TEST_REPO" rev-parse HEAD)" = "$base" ] || die 'tick 2 main moved'
release_page acme/mono gadget--v 2.0.0 21
reconcile || die 'tick 2 reconcile failed'
[ "$(cut -f1 "$PLAN_FILE")" = $'widget\ngadget' ] || die 'unmerged widget drift was lost'
key2="$(compute_key)"
[ "$key2" != "$key1" ] || die 'different drift reused the key'
branch2="repin/auto-$key2"
blob2="$(git -C "$TEST_REPO" hash-object .claude-plugin/marketplace.json)"
open_repin "$branch2"
land DESIRED_BRANCH="$branch2" EXPECTED_BLOB="$blob2" || die 'tick 2 land failed'
assert_state 2 '.state == "OPEN" and .autoMergeRequest.head == .headRefOid'
assert_state 1 '.state == "CLOSED" and .deleteBranch == true and .closeComment == "Superseded by #2, which carries the current plan."'
[ "$(pr_count)" -eq 2 ] || die 'tick 2 PR count differs'
pass 'tick 2 queues both plugin bumps in PR 2 and supersedes PR 1 with its recorded comment'

git -C "$TEST_REPO" switch -q main
reconcile || die 'tick 2 repeat failed'
[ "$(compute_key)" = "$key2" ] || die 'same main and drift changed key'
[ "$(gh pr list --head "$branch2" --state open --json number --jq '.[0].number // empty')" = 2 ] || die 'head lookup did not find PR 2'
open_repin "$branch2"
[ "$(pr_count)" -eq 2 ] || die 'tick 2 repeat opened a PR'
assert_state 2 '.state == "OPEN" and .autoMergeRequest != null'
pass 'repeating tick 2 has the same key, finds PR 2 open and creates no third PR'

# PR 2's required check fails while main has not moved: there is nothing to retry it
# with, so land leaves it as it is.
head2="$(jq -r '.headRefOid' "$STATE/pr-2.json")"
printf 'failure\n' > "$STATE/checks-$head2"
land DESIRED_BRANCH="$branch2" EXPECTED_BLOB="$blob2" || die "failed-card land on an unmoved main: $(cat "$TMP/land-err")"
[ "$(jq -r '.headRefOid' "$STATE/pr-2.json")" = "$head2" ] || die 'a failed card was refreshed though main had nothing newer'
[ ! -e "$STATE/updates" ] || die "a branch update was made: $(cat "$STATE/updates")"
grep -q 'main has nothing newer' "$TMP/land-out" || die "the hold was not reported: $(cat "$TMP/land-out")"
rm "$STATE/checks-$head2"
pass 'a failed PR 2 on an unmoved main is left: main has nothing newer to retry it with'

# Main moves under the waiting card without touching the manifest, as any other merge
# does. The key must hold: the run finds PR 2 open, land keeps it and closes nothing,
# and PR 2 stays behind main for the merge queue to land on top of it. Keyed on main's
# sha, this push replaced PR 2 and restarted its checks.
git -C "$TEST_REPO" checkout -q -- .claude-plugin/marketplace.json
printf 'unrelated\n' > "$TEST_REPO/NOTES.txt"
git -C "$TEST_REPO" add NOTES.txt
git -C "$TEST_REPO" commit -qm 'unrelated merge'
git -C "$TEST_REPO" push -q origin main
moved="$(git -C "$TEST_REPO" rev-parse main)"
[ "$moved" != "$base" ] || die 'main did not move'
reconcile || die "moved-main reconcile: $(cat "$TMP/reconcile-err")"
cp "$PLAN_FILE" "$TMP/plan-moved"
[ "$(compute_key)" = "$key2" ] || die "a main push that left the manifest alone changed the key"
blob_moved="$(git -C "$TEST_REPO" hash-object .claude-plugin/marketplace.json)"
[ "$blob_moved" = "$blob2" ] || die "the reconciled manifest changed although main's manifest did not"
# A reconciler change that rebuilds different bytes from the same plan and main manifest
# must change the key, or the kept card would fail repin-land.sh's blob proof every run.
cp "$TEST_REPO/.claude-plugin/marketplace.json" "$TMP/rebuilt.json"
printf '\n' >>"$TEST_REPO/.claude-plugin/marketplace.json"
[ "$(compute_key)" != "$key2" ] || die 'different rebuilt bytes from the same plan and main manifest kept the key'
cp "$TMP/rebuilt.json" "$TEST_REPO/.claude-plugin/marketplace.json"
open_repin "$branch2"
[ "$(pr_count)" -eq 2 ] || die 'a main push that left the manifest alone opened a PR'
land DESIRED_BRANCH="$branch2" EXPECTED_BLOB="$blob_moved" || die "moved-main land: $(cat "$TMP/land-err")"
assert_state 2 '.state == "OPEN" and .autoMergeRequest != null and (has("closeComment") | not)'
if git -C "$TEST_REPO" merge-base --is-ancestor "$moved" "$branch2"; then die 'PR 2 was rebuilt on the moved main'; fi
[ ! -e "$STATE/updates" ] || die "a passing card was refreshed from main: $(cat "$STATE/updates")"
pass 'a main push that leaves the manifest alone keeps the key, and PR 2 stays open behind main with nothing closed'

# A push that edits main's manifest must change the key, or a card cut from the older
# manifest would be kept and then conflict. Checked on a scratch branch, so main stays
# as the merge queue sees it.
git -C "$TEST_REPO" checkout -q -- .claude-plugin/marketplace.json
git -C "$TEST_REPO" switch -q -c manifest-edit
jq '.owner = {name: "Fixture"}' "$TEST_REPO/.claude-plugin/marketplace.json" > "$TMP/edited.json"
cp "$TMP/edited.json" "$TEST_REPO/.claude-plugin/marketplace.json"
git -C "$TEST_REPO" commit -qam 'hand edit of the manifest'
reconcile || die "manifest-edit reconcile: $(cat "$TMP/reconcile-err")"
cmp -s "$PLAN_FILE" "$TMP/plan-moved" || die 'the manifest edit changed the plan, so this case proves nothing'
[ "$(compute_key)" != "$key2" ] || die 'a main push that edited the manifest kept the key'
git -C "$TEST_REPO" checkout -q -- .claude-plugin/marketplace.json
git -C "$TEST_REPO" switch -q main
git -C "$TEST_REPO" branch -q -D manifest-edit
pass 'a main push that edits the manifest changes the key with the plan unchanged'

# PR 2's required check fails, and main then fixes the cause without touching the plan
# or the manifest (as a CI-only repair does). The key holds, so no new card opens, and
# the merge queue would never admit PR 2 with its failed check. Land merges main into
# PR 2 at the head it proved: same number, a new head holding main's fix, same manifest.
head2="$(jq -r '.headRefOid' "$STATE/pr-2.json")"
printf 'failure\n' > "$STATE/checks-$head2"
printf 'fixed\n' > "$TEST_REPO/FIX.txt"
git -C "$TEST_REPO" add FIX.txt
git -C "$TEST_REPO" commit -qm 'fix the failing check on main'
git -C "$TEST_REPO" push -q origin main
fixed="$(git -C "$TEST_REPO" rev-parse main)"
reconcile || die "fixed-main reconcile: $(cat "$TMP/reconcile-err")"
[ "$(compute_key)" = "$key2" ] || die 'a fix on main that left the manifest alone changed the key'
open_repin "$branch2"
[ "$(pr_count)" -eq 2 ] || die 'a fix on main opened a new card'
land DESIRED_BRANCH="$branch2" EXPECTED_BLOB="$blob2" || die "failed-card land: $(cat "$TMP/land-err")"
refreshed="$(jq -r '.headRefOid' "$STATE/pr-2.json")"
[ "$refreshed" != "$head2" ] || die "the failed card was not refreshed: $(cat "$TMP/land-out")"
git -C "$TEST_REPO" merge-base --is-ancestor "$fixed" "$refreshed" || die "the refreshed card lacks main's fix"
git -C "$TEST_REPO" merge-base --is-ancestor "$head2" "$refreshed" || die 'the refresh dropped the proved head'
[ "$(git -C "$TEST_REPO" rev-parse "$refreshed:.claude-plugin/marketplace.json")" = "$blob2" ] || die 'the refresh changed the manifest'
[ "$(git -C "$TMP/origin.git" rev-parse "refs/heads/$branch2")" = "$refreshed" ] || die 'the refreshed head was not pushed'
[ "$(cat "$STATE/updates")" = 2 ] || die "expected one update, of PR 2: $(cat "$STATE/updates")"
assert_state 2 '.state == "OPEN" and .autoMergeRequest != null and (has("closeComment") | not)'
grep -q 'ci failed at' "$TMP/land-out" || die "the refresh did not name the failed check: $(cat "$TMP/land-out")"
pass "a failed PR 2 gets main's fix by a branch update: same PR, a new head holding the fix and the proved head, same manifest"

# The next run proves the refreshed head, manifest blob and all. Were ci to fail there
# too, main has nothing newer, so a second refresh waits for main to move again.
printf 'failure\n' > "$STATE/checks-$refreshed"
land DESIRED_BRANCH="$branch2" EXPECTED_BLOB="$blob2" || die "refreshed-card land: $(cat "$TMP/land-err")"
[ "$(jq -r '.headRefOid' "$STATE/pr-2.json")" = "$refreshed" ] || die 'the refreshed card was refreshed again'
[ "$(cat "$STATE/updates")" = 2 ] || die "a second update was made: $(cat "$STATE/updates")"
grep -q 'main has nothing newer' "$TMP/land-out" || die "the second run did not hold: $(cat "$TMP/land-out")"
rm "$STATE/checks-$refreshed"
pass 'the next run proves the refreshed head and refreshes nothing until main moves again'

# The runs left their generated manifest in the work tree. Restore main's fixture bytes,
# then land PR 2 on main as the merge queue does; it now holds main, so it lands as is.
git -C "$TEST_REPO" show main:.claude-plugin/marketplace.json > "$TEST_REPO/.claude-plugin/marketplace.json"
git -C "$TEST_REPO" merge -q --no-edit "$branch2"
state_tmp="$(mktemp)" || exit 1
jq '.state = "MERGED"' "$STATE/pr-2.json" > "$state_tmp"
mv "$state_tmp" "$STATE/pr-2.json"
reconcile || die 'tick 3 reconcile failed'
grep -q 'manifest already matches' "$TMP/reconcile-out" || die 'tick 3 did not converge'
[ ! -e "$PLAN_FILE" ] || die 'converged tick left a plan'
before="$(jq -sc '.' "$STATE"/pr-*.json)"
land DESIRED_BRANCH= || die 'tick 3 land failed'
[ "$(jq -sc '.' "$STATE"/pr-*.json)" = "$before" ] || die 'tick 3 closed or mutated a PR'
assert_state 2 '.state == "MERGED" and (has("closeComment") | not)'
pass 'tick 3 converges after PR 2 merges and no-drift land closes zero PRs'

gh pr create --base main --head "$branch1" --title stale --body-file "$TMP/reconcile-out" >"$TMP/create-out"
assert_state 3 '.state == "OPEN" and .autoMergeRequest == null'
before="$(jq -sc '.' "$STATE"/pr-*.json)"
land DESIRED_BRANCH= ONLY_PLUGIN=widget || die 'targeted land failed'
[ "$(jq -sc '.' "$STATE"/pr-*.json)" = "$before" ] || die 'targeted run changed a stale PR'
assert_state 3 '.state == "OPEN" and (has("closeComment") | not)'
pass 'planted negative: ONLY_PLUGIN=widget leaves a stale open repin PR untouched'
printf '%s repin convergence checks passed\n' "$PASS"
