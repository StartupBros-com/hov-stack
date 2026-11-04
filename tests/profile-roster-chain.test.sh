#!/usr/bin/env bash
# lib/profile.sh's roster chain, and the check that reports a host without one.
#
# A host whose ~/.claude was switched from a private checkout to this public tree has no
# roster in the tree and no $DOTFILES, so profile_role found nothing and every
# role-dependent sync.sh verb refused while `check` stayed quiet (#404). The chain is an
# explicit DOTFILES_ROLE_FILE, then $DOTFILES/hosts.tsv, then the tree's own copy when it
# is readable, then <overlay>/hosts.tsv.
#
# Each role case sources the real library from a fixture tree in a clean shell; the check
# cases run the real sync.sh from a fixture tree with a stub systemctl. Planted
# negatives, run against the code before this change: without the overlay fallback in
# lib/profile.sh, cases 1, 6, 7 and 9 and check cases 1-3 fail; without check's new
# branch, check case 1 fails. The other cases hold on both, and guard the order.
#
# shellcheck disable=SC2016 # the single-quoted strings are code for the inner shell
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
is_eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }

# A fixture tree holds the real lib/; a case writes a roster into it only when it needs one.
TREE=$TMP/tree
mkdir -p "$TREE/lib" "$TMP/home"
cp "$REPO/lib/profile.sh" "$REPO/lib/overlay.sh" "$TREE/lib/"
OV=$TMP/overlay
mkdir -p "$OV"
printf '# the overlay copy\nfixture-host\toverlay-role\nfixture-ws\tworkstation\n' >"$OV/hosts.tsv"
EMPTY_OV=$TMP/empty-overlay
mkdir -p "$EMPTY_OV"

# in_shell [TREE=dir] VARS... -- CODE: a clean bash with only HOME, PATH and the named
# assignments in its environment, which sourced <tree>/lib/profile.sh, then runs CODE.
in_shell() {
  local tree=$TREE
  case ${1:-} in TREE=*) tree=${1#TREE=}; shift ;; esac
  local -a vars=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  env -i HOME="$TMP/home" PATH=/usr/bin:/bin "${vars[@]}" \
    bash -c '. "$1"; shift; eval "$1"' _ "$tree/lib/profile.sh" "$1"
}
# role VARS...: fixture-host's role and profile_role's status, as "<role> rc=<n>".
role() { in_shell "$@" -- 'r=$(profile_role fixture-host 2>/dev/null); echo "$r rc=$?"'; }
role_file() { in_shell "$@" -- 'printf "%s" "$DOTFILES_ROLE_FILE"'; }

# -- the chain --------------------------------------------------------------------------
# 1. A tree with no roster reads the overlay's copy.
is_eq "$(role HOV_STACK_OVERLAY="$OV")" "overlay-role rc=0" \
  "a tree without a roster does not read the overlay copy"
is_eq "$(role_file HOV_STACK_OVERLAY="$OV")" "$OV/hosts.tsv" \
  "DOTFILES_ROLE_FILE does not name the overlay copy"

# 2. The tree's own roster beats the overlay, so a hermetic fixture keeps the table it wrote.
printf 'fixture-host\ttree-role\n' >"$TREE/hosts.tsv"
is_eq "$(role HOV_STACK_OVERLAY="$OV")" "tree-role rc=0" \
  "the overlay copy displaced the tree's own roster"
rm "$TREE/hosts.tsv"

# 3. $DOTFILES beats the overlay.
mkdir -p "$TMP/dotfiles"
printf 'fixture-host\tdotfiles-role\n' >"$TMP/dotfiles/hosts.tsv"
is_eq "$(role HOV_STACK_OVERLAY="$OV" DOTFILES="$TMP/dotfiles")" "dotfiles-role rc=0" \
  "the overlay copy displaced \$DOTFILES/hosts.tsv"

# 4. An explicit DOTFILES_ROLE_FILE is final. /dev/null is readable and declares no
#    host, so the overlay copy must not answer for it.
is_eq "$(role HOV_STACK_OVERLAY="$OV" DOTFILES_ROLE_FILE=/dev/null)" " rc=1" \
  "an explicit DOTFILES_ROLE_FILE=/dev/null fell through to the overlay copy"

# 5. A relative HOV_STACK_OVERLAY is read by nothing, as lib/overlay.sh says.
is_eq "$(role HOV_STACK_OVERLAY=rel/overlay)" " rc=1" \
  "a relative HOV_STACK_OVERLAY supplied a role"

# 6. With nothing set, the overlay is ~/.config/hov-stack, the path a switched host has.
mkdir -p "$TMP/home/.config/hov-stack"
cp "$OV/hosts.tsv" "$TMP/home/.config/hov-stack/hosts.tsv"
is_eq "$(role)" "overlay-role rc=0" "the default overlay's roster was not read"
rm "$TMP/home/.config/hov-stack/hosts.tsv"

# 7. The overlay copy is a table, so the table still wins for a host it declares: it can
#    grant workstation, and an environment that contradicts it is reported, not obeyed.
out=$(in_shell HOV_STACK_OVERLAY="$OV" DOTFILES_ROLE=satellite -- 'profile_role fixture-ws 2>&1')
is_eq "${out##*$'\n'}" workstation "the overlay roster's workstation row did not resolve"
case "$out" in
  *"ignoring DOTFILES_ROLE=satellite"*) ok ;;
  *) bad "a DOTFILES_ROLE contradicting the overlay roster was not reported: $out" ;;
esac

# 8. And an undeclared host still cannot claim workstation from the environment.
is_eq "$(in_shell HOV_STACK_OVERLAY="$OV" DOTFILES_ROLE=workstation -- \
  'r=$(profile_role no-such-host 2>/dev/null); echo "$r rc=$?"')" " rc=1" \
  "an undeclared host was granted workstation beside an overlay roster"

# 9. When no roster is readable, the refusal names the overlay copy: the one place a
#    switched host may add its row, never the public tree.
is_eq "$(role_file HOV_STACK_OVERLAY="$EMPTY_OV")" "$EMPTY_OV/hosts.tsv" \
  "with no roster anywhere, DOTFILES_ROLE_FILE does not name the overlay copy"
out=$(in_shell HOV_STACK_OVERLAY="$EMPTY_OV" -- 'profile_assert_known 2>&1')
case "$out" in
  *"in $EMPTY_OV/hosts.tsv"*) ok ;;
  *) bad "profile_assert_known does not name the overlay copy: $out" ;;
esac

# 10. A profile.sh copied without its overlay.sh keeps the chain it had, and sources
#     cleanly: the tree path, no role, no error.
LONE=$TMP/lone
mkdir -p "$LONE/lib"
cp "$REPO/lib/profile.sh" "$LONE/lib/"
out=$(in_shell TREE="$LONE" HOV_STACK_OVERLAY="$OV" -- \
  'r=$(profile_role fixture-host); echo "[$r] rc=$? file=$DOTFILES_ROLE_FILE"' 2>&1)
is_eq "$out" "[] rc=1 file=$LONE/lib/../hosts.tsv" \
  "profile.sh without overlay.sh did not keep its tree-only chain"

# -- sync.sh check ----------------------------------------------------------------------
# A fixture tree sync.sh runs from, a scratch live ~/.claude, and a systemctl that fails
# every call, so check never reaches the invoking user's systemd manager.
SYNC_TREE=$TMP/sync-tree
SYNC_HOME=$TMP/sync-home
STUB=$TMP/stub-bin
mkdir -p "$SYNC_TREE/scripts/lib" "$SYNC_TREE/hooks" "$SYNC_HOME/.claude" "$STUB" \
  "$TMP/mirror" "$TMP/system-system" "$TMP/system-user"
cp "$REPO/sync.sh" "$SYNC_TREE/sync.sh"
cp "$REPO/scripts/lib/floor-assert.sh" "$SYNC_TREE/scripts/lib/floor-assert.sh"
cp -a "$REPO/lib" "$SYNC_TREE/lib"
printf '#!/usr/bin/env bash\nexit 3\n' >"$STUB/systemctl"
chmod +x "$STUB/systemctl"
HOST=$(hostname -s 2>/dev/null || hostname)
run_check() { # VARS...: sync.sh check's output, nothing inherited that picks a roster
  env -u DOTFILES -u DOTFILES_ROLE -u DOTFILES_ROLE_FILE -u HOV_STACK_OVERLAY \
    HOME="$SYNC_HOME" CLAUDE_HOME="$SYNC_HOME/.claude" \
    CLAUDE_MEMORY_LIVE_ROOT="$SYNC_HOME/.claude/projects" \
    CLAUDE_MEMORY_MIRROR_ROOT="$TMP/mirror" \
    CLAUDE_SYNC_SYSTEM_SYS_DIR="$TMP/system-system" \
    XDG_CONFIG_HOME="$TMP/system-user" PATH="$STUB:$PATH" "$@" \
    bash "$SYNC_TREE/sync.sh" check 2>&1
}
ln -s "$SYNC_TREE/hooks" "$SYNC_HOME/.claude/hooks"   # the live ~/.claude runs from the tree

# check 1. The live tree has no roster anywhere, so check reports it.
out=$(run_check HOV_STACK_OVERLAY="$EMPTY_OV")
case "$out" in
  *"DRIFT: no host roster is readable ($EMPTY_OV/hosts.tsv)"*) ok ;;
  *) bad "a live tree with no roster was not reported: $out" ;;
esac

# check 2. The overlay's row declares this host: no roster drift, and the role resolved.
ROSTER_OV=$TMP/roster-overlay
mkdir -p "$ROSTER_OV"
printf '%s\tworkstation\n' "$HOST" >"$ROSTER_OV/hosts.tsv"
out=$(run_check HOV_STACK_OVERLAY="$ROSTER_OV")
case "$out" in
  *"no host roster is readable"* | *"has no role in hosts.tsv"*)
    bad "an overlay roster declaring this host still drew roster drift: $out" ;;
  *) ok ;;
esac

# check 3. An overlay roster that omits this host is the undeclared-host drift it always was.
printf 'some-other-host\tworkstation\n' >"$ROSTER_OV/hosts.tsv"
out=$(run_check HOV_STACK_OVERLAY="$ROSTER_OV")
case "$out" in
  *"has no role in hosts.tsv"*) ok ;;
  *) bad "an overlay roster without this host did not report the host undeclared: $out" ;;
esac

# check 4. A tree the live ~/.claude does not run from stays quiet, as a hermetic fixture
#          or partial checkout always has.
rm "$SYNC_HOME/.claude/hooks"
out=$(run_check HOV_STACK_OVERLAY="$EMPTY_OV")
case "$out" in
  *"no host roster is readable"*) bad "a tree the live ~/.claude does not run from reported roster drift" ;;
  *) ok ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "ok — profile roster chain: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — profile roster chain: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
