#!/usr/bin/env bash
# harness-doctor check 5 audits own repos cloned directly under $HOME as well as ~/SITES,
# and skips nested instruction files named in <overlay>/instruction-file-exempt.
#
# EXTRACTION: the real helpers and the real section 5 body are sed-extracted from
# harness-doctor.sh (sourcing the whole doctor would audit this machine); HOME and the
# overlay are scratch trees.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/doctor-instruction-scope.XXXXXX) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
has() { grep -qxF -- "$2" <<<"$1" && ok_ || bad "$3: expected line '$2' in: $1"; }
lacks() { grep -qxF -- "$2" <<<"$1" && bad "$3: '$2' should be absent in: $1" || ok_; }
hasfrag() { case $1 in *"$2"*) ok_ ;; *) bad "$3: expected '$2' in: $1" ;; esac; }
lacksfrag() { case $1 in *"$2"*) bad "$3: '$2' should be absent in: $1" ;; *) ok_ ;; esac; }

for fn in sites_repos home_repos check5_repos instruction_exempt_load instruction_exempt; do
  sed -n "/^$fn() {/,/^}/p" "$DOCTOR" >> "$TMP/helpers.sh"
  grep -q "^$fn() {" "$TMP/helpers.sh" || { echo "FAIL: $fn not found in $DOCTOR" >&2; exit 1; }
done
echo 'INSTRUCTION_EXEMPT=()' >> "$TMP/helpers.sh"
sed -n '/^echo "== 5\. /,/^echo "== 6\. /p' "$DOCTOR" | sed '$d' > "$TMP/section5.sh"
grep -q 'CHECK5_REPOS' "$TMP/section5.sh" || { echo "FAIL: section 5 not found" >&2; exit 1; }

# Driver: the doctor's own warn/note/ok, the extracted helpers, then the extracted
# section 5 with HD_ROOT pointing at this checkout (for lib/overlay.sh).
cat > "$TMP/list.sh" <<'SH'
. "$HD_ROOT/lib/overlay.sh"
. "$1"
mapfile -t SITES_REPOS < <(sites_repos)
check5_repos
SH
cat > "$TMP/section.sh" <<'SH'
WARNS=0 NOTES=0
warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
ok()   { echo "  ok: $*"; }
note() { echo "  note: $*"; NOTES=$((NOTES + 1)); }
. "$HD_ROOT/lib/overlay.sh"
. "$1"
mapfile -t SITES_REPOS < <(sites_repos)
. "$2"
SH

mkrepo() { # mkrepo <dir> [origin-url]
  mkdir -p "$1"
  git init -q "$1"
  [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"
}

home=$TMP/home
mkdir -p "$home/SITES" "$TMP/overlay"
mkrepo "$home/SITES/sitesrepo" "git@github.com:StartupBros-com/hov-stack.git"
mkrepo "$home/ownhome" "git@github.com:StartupBros-com/hov-stack.git"
mkrepo "$home/foreignhome" "https://github.com/someone-else/foreignhome.git"
mkrepo "$home/noremote"
mkdir -p "$home/plaindir"                              # not a repo
ln -s "$home/SITES/sitesrepo" "$home/sitesalias"       # home entry resolving to a SITES repo
ln -s "$home/ownhome" "$home/ownhome-again"            # same repo twice under HOME

export HOME=$home HD_ROOT=$REPO HOV_STACK_OVERLAY=$TMP/overlay
list=$(bash "$TMP/list.sh" "$TMP/helpers.sh")
has "$list" "$home/SITES/sitesrepo/" "SITES repo kept"
n=$(printf '%s\n' "$list" | grep -c 'sitesrepo/$')
[ "$n" -eq 1 ] && ok_ || bad "SITES repo reached through a home alias should be visited once, got $n: $list"
n=$(printf '%s\n' "$list" | grep -c 'ownhome')
[ "$n" -eq 1 ] && ok_ || bad "own home repo and its alias should be visited once, got $n: $list"
hasfrag "$list" "$home/ownhome/" "home-level own-origin repo is included"
lacksfrag "$list" "foreignhome" "home-level foreign-origin repo is excluded"
lacksfrag "$list" "noremote" "home-level repo with no remote is excluded"
lacksfrag "$list" "plaindir" "non-repo home dir is excluded"

# SITES keeps today's behaviour: a SITES repo with no remote is still listed.
mkrepo "$home/SITES/siteslocal"
list=$(bash "$TMP/list.sh" "$TMP/helpers.sh")
hasfrag "$list" "$home/SITES/siteslocal/" "SITES repo with no remote still counts"

# Section 5 end to end. fixture: nested CLAUDE.md twins and a dead nested AGENTS.md.
fx() { # fx <repo-dir>: root pointer plus two non-stub nested CLAUDE.md and one dead nested AGENTS.md
  local r=$1
  mkdir -p "$r/overlay" "$r/pkg/keep" "$r/frozen" "$r/other"
  printf '%s\n' '# dead' > "$r/other/AGENTS.md"
  printf '%s\n' '# root' > "$r/AGENTS.md"
  printf '%s\n' '@AGENTS.md' > "$r/CLAUDE.md"
  printf '%s\n' '# real content' > "$r/overlay/CLAUDE.md"
  printf '%s\n' '# real content' > "$r/pkg/keep/CLAUDE.md"
  printf '%s\n' '# dead' > "$r/frozen/AGENTS.md"
  printf '%s\n' '# dead' > "$r/pkg/keep/AGENTS.md"
  git -C "$r" add -A
}
fx "$home/ownhome"
mkdir -p "$home/foreignhome/pkg"
printf '%s\n' '# real content' > "$home/foreignhome/pkg/CLAUDE.md"
printf '%s\n' '# root' > "$home/foreignhome/AGENTS.md"
printf '%s\n' '@AGENTS.md' > "$home/foreignhome/CLAUDE.md"
git -C "$home/foreignhome" add -A

run5() { bash "$TMP/section.sh" "$TMP/helpers.sh" "$TMP/section5.sh" 2>"$TMP/stderr"; }

# 1. No list file: nothing exempt. ownhome: 2 nested CLAUDE.md, 2 dead nested AGENTS.md.
out=$(run5)
hasfrag "$out" "  note: ownhome: 2 nested CLAUDE.md not '@AGENTS.md' stubs" "absent list exempts nothing (CLAUDE.md)"
hasfrag "$out" "  note: ownhome: 2 nested AGENTS.md with no sibling CLAUDE.md pointer" "absent list exempts nothing (AGENTS.md)"
lacksfrag "$out" "foreignhome" "foreign home repo is never audited"
[ ! -s "$TMP/stderr" ] && ok_ || bad "absent list wrote to stderr: $(cat "$TMP/stderr")"

# 2. Empty list behaves like an absent one.
: > "$TMP/overlay/instruction-file-exempt"
out2=$(run5)
[ "$out2" = "$out" ] && ok_ || bad "empty list changed the output: $out2"

# 3. Exempt one nested CLAUDE.md and one nested AGENTS.md; the others still report.
printf '%s\n' '# comment' '   # indented comment' '' \
  'ownhome:overlay/CLAUDE.md' \
  'ownhome:frozen/*' \
  'otherrepo:pkg/*' > "$TMP/overlay/instruction-file-exempt"
out3=$(run5)
hasfrag "$out3" "  note: ownhome: 1 nested CLAUDE.md not '@AGENTS.md' stubs" "exempt nested CLAUDE.md skipped, other still reported"
hasfrag "$out3" "  note: ownhome: 1 nested AGENTS.md with no sibling CLAUDE.md pointer" "exempt nested AGENTS.md skipped, other still reported"
[ ! -s "$TMP/stderr" ] && ok_ || bad "valid list wrote to stderr: $(cat "$TMP/stderr")"

# 4. A glob's star crosses slashes; exempting everything leaves the repo quiet.
printf '%s\n' 'ownhome:*' > "$TMP/overlay/instruction-file-exempt"
out4=$(run5)
lacksfrag "$out4" "ownhome:" "star crosses / and exempts every nested file"

# 5. Malformed lines are reported and ignored; the valid line still applies.
printf '%s\n' 'no-colon-here' ':glob-without-name' 'name-without-glob:' 'bad name:x' \
  'ownhome:overlay/CLAUDE.md' > "$TMP/overlay/instruction-file-exempt"
out5=$(run5)
err=$(cat "$TMP/stderr")
for l in 'no-colon-here' ':glob-without-name' 'name-without-glob:' 'bad name:x'; do
  hasfrag "$err" "instruction-file-exempt: malformed line: $l" "malformed '$l' reported"
done
lacksfrag "$err" "malformed line: ownhome:overlay/CLAUDE.md" "valid line not reported"
hasfrag "$out5" "  note: ownhome: 1 nested CLAUDE.md not '@AGENTS.md' stubs" "valid line applies beside malformed ones"

# 6. A relative overlay is ignored: nothing exempt.
printf '%s\n' 'ownhome:*' > "$TMP/overlay/instruction-file-exempt"
out6=$(HOV_STACK_OVERLAY=relative/overlay run5)
hasfrag "$out6" "  note: ownhome: 2 nested CLAUDE.md" "relative overlay is ignored"

# 7. Active own home repo with no AGENTS.md at all is noted (the original defect).
mkrepo "$home/noagents" "git@github.com:StartupBros-com/hov-stack.git"
printf '%s\n' 'x' > "$home/noagents/README"
git -C "$home/noagents" add -A
git -C "$home/noagents" -c user.name=t -c user.email=t@example.com commit -q -m init
rm -f "$TMP/overlay/instruction-file-exempt"
out7=$(run5)
hasfrag "$out7" "active repo(s) missing AGENTS.md" "home-level repo without AGENTS.md is noted"
hasfrag "$out7" "noagents" "the note names the home-level repo"
hasfrag "$out7" "or list '<name>:AGENTS.md' in <overlay>/instruction-file-exempt" "the note says how to record a repo that needs none"

# 8. "<name>:AGENTS.md" in the overlay means the repo needs none; nothing else exempts it.
printf '%s\n' 'noagents:other/*' 'otherrepo:AGENTS.md' > "$TMP/overlay/instruction-file-exempt"
out8=$(run5)
hasfrag "$out8" "noagents" "a nested glob or another repo's root entry does not exempt the root"
printf '%s\n' 'noagents:AGENTS.md' > "$TMP/overlay/instruction-file-exempt"
out8=$(run5)
lacksfrag "$out8" "missing AGENTS.md" "a root entry stops the missing-AGENTS note for that repo"
rm -f "$TMP/overlay/instruction-file-exempt"

# 9. The repo whose root CLAUDE.md is the live global file is skipped; a repo with an
# ordinary root CLAUDE.md, or a global file that points elsewhere, is not.
printf '%s\n' '# real content' > "$home/noagents/CLAUDE.md"
mkdir -p "$home/.claude"
out9=$(CLAUDE_CONFIG_DIR=$home/.claude run5)
hasfrag "$out9" "noagents" "an ordinary root CLAUDE.md does not exempt the repo"
ln -s "$home/ownhome/CLAUDE.md" "$home/.claude/CLAUDE.md"
out9=$(CLAUDE_CONFIG_DIR=$home/.claude run5)
hasfrag "$out9" "noagents" "a global file in another repo does not exempt this one"
rm -f "$home/.claude/CLAUDE.md"
ln -s "$home/noagents/CLAUDE.md" "$home/.claude/CLAUDE.md"
out9=$(CLAUDE_CONFIG_DIR=$home/.claude run5)
lacksfrag "$out9" "missing AGENTS.md" "the repo holding the live global CLAUDE.md is skipped"
rm -f "$home/.claude/CLAUDE.md" "$home/noagents/CLAUDE.md"

# Static: all four check-5 loops read the widened list, and both nested loops consult the exemption list.
n=$(grep -cF 'for repo in "${CHECK5_REPOS[@]}"; do' "$DOCTOR")
[ "$n" -eq 4 ] && ok_ || bad "expected 4 CHECK5_REPOS loops, got $n"
n=$(grep -c '^    instruction_exempt "\$name" "\$[ca]" && continue$' "$DOCTOR")
[ "$n" -eq 2 ] && ok_ || bad "expected 2 instruction_exempt call sites, got $n"

echo "doctor instruction scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
