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
number='' head='' state='' fields='' filter='' path='' match='' comment='' paginate=false
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
    jq -n --argjson n "$number" --arg h "$head" --arg oid "$oid" '{number:$n,headRefName:$h,headRefOid:$oid,
      state:"OPEN",author:{login:"app/startupbros-hov-marketplace-bot"},isCrossRepository:false,autoMergeRequest:null}' > "$tmp"
    mv "$tmp" "$STATE/pr-$number.json"
    printf 'https://github.com/acme/market/pull/%s\n' "$number" ;;
  'pr view')
    if [ "$fields" = files ]; then
      oid="$(jq -r '.headRefOid' "$STATE/pr-$number.json")"
      git -C "$TEST_REPO" diff-tree --no-commit-id --name-only -r "$oid" \
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
assert_state 1 '.state == "CLOSED" and .deleteBranch == true and .closeComment == "Superseded by #2, the reconciler\u0027s repin against current main."'
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

# The repeat left its generated manifest on main. Restore main's fixture bytes
# before merging the already committed PR branch.
git -C "$TEST_REPO" show main:.claude-plugin/marketplace.json > "$TEST_REPO/.claude-plugin/marketplace.json"
git -C "$TEST_REPO" merge -q --ff-only "$branch2"
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
