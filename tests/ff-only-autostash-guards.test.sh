#!/usr/bin/env bash
# Behavioral contract for the unattended fast-forward updater that runs
# under this repo's global git config (dotfiles#481).
#
# git/config.shared sets merge.autoStash, rebase.autoStash and pull.rebase to
# true. Under that config a bare `git pull --ff-only` on a checkout whose local
# edit overlaps the incoming diff does not refuse: it stashes, fast-forwards,
# pops -- and when the pop conflicts it STILL EXITS 0, leaving a UU entry and
# conflict markers in the tree and the stash undropped. Automation gating on
# $? logs that as success (the #210 shape; repo_ff_update failed its own
# planted negative this way until #383).
#
# PRECONDITION FIRST: the control case runs the raw trap under the same
# GIT_CONFIG_GLOBAL and must reproduce it. If git ever changes that behavior
# the control fails and says so, instead of the guard cases passing vacuously
# against a trap that no longer exists. Reproduced on git 2.43.0 (this box)
# and 2.34.1 (inward vet, Docker); the Blacksmith runner ships 2.52.0.
#
# PLANTED NEGATIVES: each guard case names the observable the guard produces
# -- the SKIP line or required failure, HEAD not advanced, no UU entry, no
# stash, the local edit byte-intact -- so reverting update-mcp-servers.sh to
# `pull --ff-only` fails a named assertion here.
#
# Hermetic: scratch $HOME and GIT_CONFIG_GLOBAL (GIT_CONFIG_NOSYSTEM=1),
# fixture bare upstreams + clones under mktemp, uv/rm stubbed on
# PATH, no network, nothing under the operator's real ~/.pi or ~/SITES.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MCP_SCRIPT=$REPO/scripts/update-mcp-servers.sh
TMP=$(mktemp -d /tmp/ff-only-guards.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() { case "$1" in *"$2"*) ok ;; *) bad "$3: missing '$2'" ;; esac; }
omits()    { case "$1" in *"$2"*) bad "$3: unexpectedly contained '$2'" ;; *) ok ;; esac; }
is_eq()    { if [ "$1" = "$2" ]; then ok; else bad "$3: expected '$2', got '$1'"; fi; }

REAL_GIT=$(command -v git)
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$TMP/gitconfig

# The three keys the trap needs. Asserted against the repo's own config.shared
# so this suite tracks the config it guards against: if a key is ever dropped
# there, the precondition below names it and the guards can be re-evaluated.
for key in merge.autoStash rebase.autoStash pull.rebase; do
  val=$(git config --file "$REPO/git/config.shared" --get "$key" 2>/dev/null)
  is_eq "$val" true "git/config.shared still sets $key=true (the trap this suite guards against)"
done
cat >"$GIT_CONFIG_GLOBAL" <<'CFG'
[user]
	name = ff-only-guards test
	email = test@example.invalid
[init]
	defaultBranch = main
[merge]
	autoStash = true
[rebase]
	autoStash = true
[pull]
	rebase = true
CFG

# make_fixture <name> <clone_path>: upstream has commit A then B (both touch
# f.txt); the clone is left at A knowing origin/main only up to A, so the next
# fetch brings B and any local edit to f.txt overlaps it.
make_fixture() {
  local clone=$2 up=$TMP/$1-upstream.git seed=$TMP/$1-seed
  git init -q --bare "$up"
  git init -q "$seed"
  printf 'one\n' >"$seed/f.txt"
  printf 'x\n' >"$seed/other.txt"
  git -C "$seed" add . && git -C "$seed" commit -q -m A && git -C "$seed" push -q "$up" HEAD:main
  git clone -q "$up" "$clone"
  printf 'two\n' >"$seed/f.txt"
  git -C "$seed" commit -q -am B && git -C "$seed" push -q "$up" HEAD:main
}
head_subject() { git -C "$1" log -1 --format=%s; }
stash_count()  { git -C "$1" stash list | wc -l | tr -d ' '; }
porcelain()    { git -C "$1" status --porcelain | tr '\n' ' '; }

# -- control: the trap reproduces on this git --------------------------------
echo "-- control: $(git --version) under the config.shared keys --"
CTRL=$TMP/control
make_fixture control "$CTRL"
printf 'local\n' >"$CTRL/f.txt"
git -C "$CTRL" pull --ff-only origin main >"$TMP/control.out" 2>&1
is_eq "$?" 0 "control: bare pull --ff-only over an overlapping edit exits 0 (the trap)"
is_eq "$(head_subject "$CTRL")" B "control: it fast-forwarded anyway"
contains "$(porcelain "$CTRL")" "UU f.txt" "control: the conflicted autostash pop left an unmerged entry"
is_eq "$(stash_count "$CTRL")" 1 "control: the autostash survived undropped"
contains "$(cat "$CTRL/f.txt")" "<<<<<<<" "control: conflict markers landed in the tree"
if [ "$fail" -ne 0 ]; then
  echo "precondition failed: the autostash trap did not reproduce on this git; the guard cases below would pass vacuously. Re-evaluate #481 against this git version." >&2
  echo "ff-only-autostash-guards: $pass passed, $fail failed"
  exit 1
fi

# -- update-mcp-servers.sh: fetch + merge --ff-only --no-autostash -------------
echo "-- update-mcp-servers.sh --"
export EXPECTED_ORIGIN=acme-org/admin-tool  # the updater reads its approved origin from this variable
MCP_BIN=$TMP/mcp-bin
mkdir -p "$MCP_BIN"
cat >"$MCP_BIN/git" <<'STUB'
#!/usr/bin/env bash
# Hybrid: answers the origin-identity probe with the approved remote so the
# updater reaches its fast-forward step; every other call is the real git.
case " $* " in
  *' remote get-url origin '*) printf 'git@github.com:acme-org/admin-tool.git\n' ;;
  *) exec "${REAL_GIT:?}" "$@" ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$MCP_BIN/uv"
printf '#!/usr/bin/env bash\nexit 0\n' >"$MCP_BIN/rm"
chmod +x "$MCP_BIN/"*
HOME_MCP=$TMP/home-mcp
mkdir -p "$HOME_MCP/.npm/_npx"

run_mcp() { # $1 = target clone
  REAL_GIT=$REAL_GIT HOME=$HOME_MCP MCP_TARGET=$1 NPX_CACHE_PATH=$HOME_MCP/.npm/_npx \
    GIT_BIN=$MCP_BIN/git UV_BIN=$MCP_BIN/uv RM_BIN=$MCP_BIN/rm \
    bash "$MCP_SCRIPT" >"$TMP/mcp.out" 2>&1
}

# Planted negative: without EXPECTED_ORIGIN the updater refuses before touching git. The
# shipped default used to name one private checkout, which a public tree cannot carry.
M_UNSET=$TMP/mcp-unset
make_fixture m-unset "$M_UNSET"
unset_rc=0
env -u EXPECTED_ORIGIN REAL_GIT="$REAL_GIT" HOME="$HOME_MCP" MCP_TARGET="$M_UNSET" NPX_CACHE_PATH="$HOME_MCP/.npm/_npx" \
  GIT_BIN="$MCP_BIN/git" UV_BIN="$MCP_BIN/uv" RM_BIN="$MCP_BIN/rm" \
  bash "$MCP_SCRIPT" >"$TMP/mcp-unset.out" 2>&1 || unset_rc=$?
is_eq "$unset_rc" 2 "EXPECTED_ORIGIN unset: the updater exits 2 (usage) instead of trusting a built-in origin"
contains "$(cat "$TMP/mcp-unset.out")" "EXPECTED_ORIGIN is not set" "EXPECTED_ORIGIN unset: the refusal names the variable"
is_eq "$(head_subject "$M_UNSET")" A "EXPECTED_ORIGIN unset: HEAD was not advanced"

M_OVERLAP=$TMP/mcp-overlap
make_fixture m-overlap "$M_OVERLAP"
printf 'local\n' >"$M_OVERLAP/f.txt"
run_mcp "$M_OVERLAP"
is_eq "$?" 1 "overlapping edit: the updater exits 1 (required failure), not 0"
MCP_OUT=$(cat "$TMP/mcp.out")
contains "$MCP_OUT" "ERROR: MCP target fast-forward merge failed" "overlapping edit: the refusal is a named required failure"
contains "$MCP_OUT" "would be overwritten by merge" "overlapping edit: git's own refusal reaches the journal"
is_eq "$(head_subject "$M_OVERLAP")" A "overlapping edit: HEAD was not advanced"
is_eq "$(stash_count "$M_OVERLAP")" 0 "overlapping edit: no autostash was created"
omits "$(porcelain "$M_OVERLAP")" "UU" "overlapping edit: no unmerged entry"
is_eq "$(cat "$M_OVERLAP/f.txt")" local "overlapping edit is byte-intact"

M_UNREL=$TMP/mcp-unrelated
make_fixture m-unrel "$M_UNREL"
printf 'local\n' >"$M_UNREL/other.txt"
run_mcp "$M_UNREL"
is_eq "$?" 0 "unrelated edit: the updater exits 0 (the fast-forward tolerates it)"
contains "$(cat "$TMP/mcp.out")" "MCP update completed successfully" "unrelated edit: success is reported"
is_eq "$(head_subject "$M_UNREL")" B "unrelated edit: fast-forwarded to B"
is_eq "$(stash_count "$M_UNREL")" 0 "unrelated edit: no autostash was created"
is_eq "$(cat "$M_UNREL/other.txt")" local "unrelated edit is byte-intact"

M_CLEAN=$TMP/mcp-clean
make_fixture m-clean "$M_CLEAN"
run_mcp "$M_CLEAN"
is_eq "$?" 0 "clean clone: the updater exits 0"
is_eq "$(head_subject "$M_CLEAN")" B "clean clone: fast-forwarded to B"

# Inward-vet regression: a branch tracking a remote other than origin. A bare
# `pull` fast-forwarded from that remote through never-vetted tracking info;
# `fetch origin` + merge '@{u}' would have reported "Already up to date" and
# silently stayed stale. Now it is named and refused.
M_OTHER=$TMP/mcp-other-remote
make_fixture m-other "$M_OTHER"
git -C "$M_OTHER" remote add mirror "$TMP/m-other-upstream.git"
git -C "$M_OTHER" fetch -q mirror
git -C "$M_OTHER" branch -q --set-upstream-to=mirror/main
run_mcp "$M_OTHER"
is_eq "$?" 1 "branch tracking a non-origin remote: the updater exits 1"
contains "$(cat "$TMP/mcp.out")" "tracks mirror/main, not origin" "non-origin upstream is named"
is_eq "$(head_subject "$M_OTHER")" A "non-origin upstream: HEAD was not advanced"

M_DETACHED=$TMP/mcp-detached
make_fixture m-detached "$M_DETACHED"
git -C "$M_DETACHED" checkout -q --detach
run_mcp "$M_DETACHED"
is_eq "$?" 1 "detached HEAD: the updater exits 1"
contains "$(cat "$TMP/mcp.out")" "no upstream branch" "detached HEAD is named as having no upstream"
is_eq "$(head_subject "$M_DETACHED")" A "detached HEAD: nothing was merged"

echo "ff-only-autostash-guards: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
