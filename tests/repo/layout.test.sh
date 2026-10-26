#!/usr/bin/env bash
# tests/repo/layout.test.sh: the repo root mirrors ~/.claude and collides with nothing the
# marketplace tree brings at the flip. Runs against this checkout, then against planted
# trees that each break one rule.
#
#   - no tracked path sits under the old mirror prefix, release/, plugins/ or
#     .claude-plugin/ at the root (a plugin manifest inside mods/<name>/ is legal, and so
#     is plugins/hov-stack/, the skill pack; the rest of plugins/ stays reserved); in
#     merged mode (root marketplace manifest present), only the old prefix is forbidden
#   - no tracked file names the old skills directory; a longer name that starts with it
#     is not a reference, and history docs and fixtures are exempt (the pack's
#     provenance records are checked like any other file since #43)
#   - no tracked file refers to the old mirror prefix as a repo-relative path, bare,
#     behind a variable or behind ./; the restructure plan and decision records,
#     docs/layout.md (which records the move), this suite and
#     the jsm wrapper suite (it plants skill trees named after the agents' home
#     directories) are exempt, and a `<sha>:<path>` history reference, a `~/.<dir>/`
#     home path and a `.config/<dir>/` path are not repo paths
#   - no relative link in a tracked markdown file climbs above the repository root
#     (a moved file that kept its old `../` depth)
#   - against the pinned marketplace tree, the paths on both sides are exactly LICENSE
#     and README.md, and no file on either side is a directory on the other; this
#     collision check guards the staged tree before the flip, not the merged tree
#   - the fixture header pins the marketplace commit it was taken from
#   - every tracked root entry is accounted for in lib/manifest.sh (manifest_check's
#     completeness scan, the one harness-doctor §10c runs), every one outside
#     DOTFILES_HARNESS is named in docs/layout.md, and every entry the manifest declares
#     that this copy lacks is marked "absent from this copy" there
#   - planted trees: both modes name the old prefix; only staged mode names the
#     marketplace prefixes; plugins/hov-stack/ is not named; a
#     script naming the old skills directory is named with its lines; a script citing the
#     old prefix is named with its line; the exemptions hold; a fixture that lists one
#     of our directories as a file is named as a collision, and so is a file of ours at
#     the name of one of their directories; a moved markdown file that kept its old
#     link depth is named; a stray root entry is named as unaccounted and unnamed, a
#     longer name does not name a shorter one, and a declared entry the tree lacks is
#     named unless its row marks it absent
#
# Takes an optional root to check instead of this checkout.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
ROOT=${1:-$REPO}
FIXTURE=$REPO/tests/fixtures/marketplace-tree.txt
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/home"
# shellcheck source=/dev/null
. "$REPO/lib/check.sh"   # manifest_check
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

# The old mirror prefix, spelled in two pieces so this file does not trip its own scan.
OLD='cl''aude/'

# The skills directory before it became the plugin pack (#37), spelled in two pieces too.
OLD_SKILLS='skills-''local'

# reserved_paths <root>: tracked paths under a prefix the flip reserves or the mirror left.
# plugins/hov-stack/ is the skill pack (restructure plan KTD11); the rest of plugins/ is
# kept for the marketplace's plugins.
reserved_paths() {
  if [ -f "$1/.claude-plugin/marketplace.json" ]; then
    git -C "$1" ls-files | grep -E "^$OLD" || true
    return
  fi
  git -C "$1" ls-files | grep -E "^($OLD|release/|plugins/|\.claude-plugin/)" \
    | grep -v -E '^plugins/hov-stack/' || true
}
# old_skills_refs <root>: file:line of every tracked reference to the old skills directory.
# A longer name that starts with it (the localizer script, a suite key) is not one. Exempt:
# the history docs (vets, solutions, plans, decisions) and fixtures. Every pack file is checked,
# its UPSTREAM.md and PROVENANCE.md provenance records included (#43 rewrote the ones
# that named the author's dotfiles and dropped their exemption).
old_skills_refs() {
  git -C "$1" grep -nIE "${OLD_SKILLS}([^-i]|\$)" -- . \
    ':!docs/vets' ':!docs/solutions' ':!docs/plans' ':!docs/decisions' \
    ':!tests/fixtures' ':!harness/vet-fixtures' || true
}
# old_prefix_refs <root>: file:line of every repo-relative reference to the old prefix:
# bare (`see <old>x`), behind a variable (`$REPO/<old>x`, `${REPO}/<old>x`) or behind
# `./`. A `~/.<dir>/` home path, a `.config/<dir>/` path and a `<sha>:<old>x` history
# reference are not repo paths.
old_prefix_refs() {
  local re
  re="(^|[^.[:alnum:]_/-])$OLD"'|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|(^|[^[:alnum:]_/.~-])\.)/'"$OLD"
  git -C "$1" grep -nIE "$re" -- . \
    ':!docs/plans' ':!docs/decisions' ':!docs/layout.md' \
    ':!tests/repo/layout.test.sh' ':!tests/jsm-auto-update-wrapper.test.sh' \
    | grep -vE "[0-9a-f]{7,40}:$OLD" || true
}
# dirs_of: every ancestor directory of each path on stdin, once each.
dirs_of() {
  awk -F/ '{ p = ""; for (i = 1; i < NF; i++) { p = (p == "" ? $i : p "/" $i); print p } }' \
    | LC_ALL=C sort -u
}
# collisions <root> <fixture>: paths that cannot coexist with the marketplace tree: a file
# on both sides, or a file on one side that is a directory on the other. A directory on
# both sides merges as a union and is not a collision.
collisions() {
  local ours=$WORK/ours theirs=$WORK/theirs
  git -C "$1" ls-files | LC_ALL=C sort -u >"$ours"
  grep -v '^#' "$2" | grep -v '^$' | LC_ALL=C sort -u >"$theirs"
  {
    LC_ALL=C comm -12 "$ours" "$theirs"
    LC_ALL=C comm -12 <(dirs_of <"$ours") "$theirs"
    LC_ALL=C comm -12 "$ours" <(dirs_of <"$theirs")
  } | LC_ALL=C sort -u
}
# escaping_links <root>: file -> link for every relative markdown link whose leading
# `../` run climbs above the repository root (a moved file that kept its old depth).
escaping_links() {
  local f depth link rest ups
  git -C "$1" ls-files -- '*.md' | while IFS= read -r f; do
    depth=$(printf '%s' "$f" | tr -cd / | wc -c)
    { grep -oE '\]\((\.\./)+[^)[:space:]]*' "$1/$f" 2>/dev/null || true; } | LC_ALL=C sort -u | while IFS= read -r link; do
      rest=${link#](}; ups=0
      while [ "${rest#../}" != "$rest" ]; do rest=${rest#../}; ups=$((ups + 1)); done
      [ "$ups" -le "$depth" ] || printf '%s -> %s\n' "$f" "${link#](}"
    done
  done
}
# plant <name> <path>...: a scratch repo with one empty tracked file at each path.
plant() {
  local t=$WORK/$1 p; shift
  mkdir -p "$t"
  git -C "$t" init -q
  for p in "$@"; do mkdir -p "$t/$(dirname "$p")"; : >"$t/$p"; done
  git -C "$t" add -A
  printf '%s\n' "$t"
}
# uncovered_entries <root>: tracked root entries nothing in <root>/lib/manifest.sh installs
# or excludes, from manifest_check's completeness scan. The scratch home keeps its link
# scans off the real one, and a Windows home that does not exist skips the copy scan.
uncovered_entries() {
  local out line prefix='top-level dotfiles entry nothing installs or excludes: '
  out=$(DOTFILES_WINDOWS_HOME=$WORK/no-windows-home manifest_check "$1" "$WORK/home") \
    || fail "manifest_check could not run on $1: $out"
  while IFS= read -r line; do
    case "$line" in "$prefix"*) line=${line#"$prefix"}; printf '%s\n' "${line%% *}" ;; esac
  done <<<"$out"
}
# undocumented_entries <root> <doc>: tracked root entries outside DOTFILES_HARNESS that <doc>
# never names as `name` or `name/...`. The doc cites the manifest for the harness entries
# instead of repeating them; the closing backtick keeps `.gitignore_global` from naming
# `.gitignore`.
undocumented_entries() {
  local root=$1 doc=$2 e
  (
    # shellcheck source=/dev/null
    . "$root/lib/manifest.sh"
    git -C "$root" ls-files | cut -d/ -f1 | LC_ALL=C sort -u | while IFS= read -r e; do
      case " ${DOTFILES_HARNESS[*]} " in *" $e "*) continue ;; esac
      grep -qF -e "\`$e\`" -e "\`$e/" -- "$doc" || printf '%s\n' "$e"
    done
  )
}
# absent_entries <root>: the top-level name of every path <root>/lib/manifest.sh declares
# (root files, link and copy sources, harness, topic and unlinked entries) with no tracked
# file at or under it.
absent_entries() {
  local root=$1 p
  (
    # shellcheck source=/dev/null
    . "$root/lib/manifest.sh"
    for p in "${DOTFILES_ROOT_FILES[@]}" "${DOTFILES_LINKS[@]%%|*}" "${DOTFILES_COPIES[@]%%|*}" \
      "${DOTFILES_HARNESS[@]}" "${DOTFILES_TOPICS[@]}" "${DOTFILES_UNLINKED[@]}"; do
      [ -n "$(git -C "$root" ls-files -- "$p")" ] || printf '%s\n' "${p%%/*}"
    done | LC_ALL=C sort -u
  )
}
# unmarked_absences <root> <doc>: each absent entry whose rows in <doc> never say "absent
# from this copy", the way the hosts.tsv row does.
unmarked_absences() {
  local root=$1 doc=$2 e rows
  absent_entries "$root" | while IFS= read -r e; do
    rows=$(grep -F -e "\`$e\`" -e "\`$e/" -- "$doc" || true)
    case "$rows" in *'absent from this copy'*) ;; *) printf '%s\n' "$e" ;; esac
  done
}

echo "== 1: no tracked path under a reserved prefix =="
found=$(reserved_paths "$ROOT")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "tracked paths under a reserved prefix"; }
if [ -f "$ROOT/.claude-plugin/marketplace.json" ]; then
  ok "no tracked path under the old prefix (merged tree)"
else
  ok "no tracked path under the old prefix, release/, plugins/ or .claude-plugin/"
fi

echo "== 2: no repo-relative reference to the old prefix =="
found=$(old_prefix_refs "$ROOT")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "references to the old mirror prefix remain"; }
ok "no file refers to the old prefix as a repo path"

echo "== 3: the only paths shared with the marketplace tree are LICENSE and README.md =="
if [ -f "$ROOT/.claude-plugin/marketplace.json" ]; then
  echo "skip - the collision check guards the staged tree before the flip; this is the merged tree"
else
  [ -r "$FIXTURE" ] || fail "$FIXTURE is missing"
  found=$(collisions "$ROOT" "$FIXTURE")
  want=$'LICENSE\nREADME.md'
  [ "$found" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$found" "$want"; fail "collision set differs"; }
  ok "collisions with the marketplace tree are exactly LICENSE and README.md"
fi

echo "== 4: the fixture pins its commit =="
head -n1 "$FIXTURE" | grep -qE '^# commit [0-9a-f]{40}$' || fail "fixture header does not pin a 40-hex commit"
ok "fixture header pins the marketplace commit"

echo "== 5: a tracked file under each reserved prefix is named =="
for p in release/x plugins/x plugins/hov-stack-old/x "${OLD}x" .claude-plugin/plugin.json; do
  T=$(plant "reserved-${p//\//_}" "$p" mods/m/.claude-plugin/plugin.json \
    plugins/hov-stack/.claude-plugin/plugin.json README.md)
  found=$(reserved_paths "$T")
  [ "$found" = "$p" ] || { printf '%s\n' "$found"; fail "planted $p: reserved_paths reported '$found'"; }
done
T=$(plant merged-reserved .claude-plugin/marketplace.json release/x plugins/x "${OLD}x")
found=$(reserved_paths "$T")
[ "$found" = "${OLD}x" ] || { printf '%s\n' "$found"; fail "merged reserved_paths must name only the old-prefix file"; }
ok "release/x, plugins/x, plugins/hov-stack-old/x, a file under the old prefix and a root plugin manifest are each named; merged mode names only the old prefix; mods/<name>/.claude-plugin/ and plugins/hov-stack/ are not"

echo "== 6: a script citing the old prefix is named with its line =="
T=$(plant cites scripts/w.sh scripts/y.sh docs/plans/p.md)
# shellcheck disable=SC2016  # the planted script must contain a literal $REPO
printf 'R=$REPO/%slib/x.sh\n. ./%slib/y.sh\n' "$OLD" "$OLD" >"$T/scripts/w.sh"
printf '#!/usr/bin/env bash\n# see %sscripts/x.sh\necho hi\n' "$OLD" >"$T/scripts/y.sh"
printf 'the plan may say %sscripts/x.sh freely\n' "$OLD" >"$T/docs/plans/p.md"
git -C "$T" add -A
found=$(old_prefix_refs "$T" | LC_ALL=C sort)
want="scripts/w.sh:1:R=\$REPO/${OLD}lib/x.sh
scripts/w.sh:2:. ./${OLD}lib/y.sh
scripts/y.sh:2:# see ${OLD}scripts/x.sh"
[ "$found" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$found" "$want"; fail "planted citations differ"; }
ok "a bare, a \$VAR/ and a ./ citation are each named with their line; docs/plans/ is exempt"

echo "== 7: a history reference, a home path and a .config path are not repo paths =="
T=$(plant exempt scripts/z.sh)
printf 'git show abc1234:%sx\nls ~/.%s\ncp -r ~/.%sprojects .\nln -s cfg ~/.config/%sccusage.json\n' \
  "$OLD" "$OLD" "$OLD" "$OLD" >"$T/scripts/z.sh"
git -C "$T" add -A
found=$(old_prefix_refs "$T")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "exemptions: got '$found'"; }
ok "a <sha>:path reference, ~/.<dir>/ and .config/<dir>/ paths are not reported"

echo "== 8: a fixture naming one of our directories as a file is a collision =="
cp "$FIXTURE" "$WORK/fixture-plus"
echo docs/solutions >>"$WORK/fixture-plus"
found=$(collisions "$ROOT" "$WORK/fixture-plus")
grep -qx 'docs/solutions' <<<"$found" || { printf '%s\n' "$found"; fail "docs/solutions (our directory, their file) not named"; }
ok "docs/solutions is named when the fixture lists it as a file"

echo "== 9: a file of ours at the name of one of their directories is a collision =="
T=$(plant filedir docs LICENSE)
found=$(collisions "$T" "$FIXTURE")
grep -qx 'docs' <<<"$found" || { printf '%s\n' "$found"; fail "docs (our file, their directory) not named"; }
ok "a file of ours at the name of one of their directories is named"

echo "== 10: no relative link in a tracked markdown file climbs above the repository root =="
found=$(escaping_links "$ROOT")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "relative links escape the repository (a moved file kept its old depth)"; }
ok "every ../ run in a markdown link stays inside the repository"

echo "== 11: a moved markdown file that kept its old link depth is named =="
T=$(plant links harness/a.md docs/b.md)
printf '[in](../docs/b.md) and [out](../../docs/b.md)\n' >"$T/harness/a.md"
git -C "$T" add -A
found=$(escaping_links "$T")
[ "$found" = "harness/a.md -> ../../docs/b.md" ] || { printf '%s\n' "$found"; fail "planted escaping link: got '$found'"; }
ok "harness/a.md's ../../ link is named; its ../ link is not"

echo "== 12: no tracked file names the old skills directory =="
found=$(old_skills_refs "$ROOT")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "references to the old skills directory remain (it is plugins/hov-stack/skills now)"; }
ok "no file names the old skills directory outside the exempt history docs and fixtures"

echo "== 13: a script naming the old skills directory is named with its lines =="
T=$(plant skillrefs scripts/a.sh plugins/hov-stack/skills/x/UPSTREAM.md plugins/hov-stack/skills/x/PROVENANCE.md \
  plugins/hov-stack/skills/x/SKILL.md plugins/hov-stack/skills/code-slop/SKILL.md docs/plans/p.md)
# shellcheck disable=SC2016  # the planted script must contain a literal $ROOT
printf 'find "$ROOT/%s" -name x\n# see %s/x/SKILL.md\nbash scripts/%size.sh apply\n%s-node-suites:\nSKILLS_LOCAL_DIR=x\n  %s\n' \
  "$OLD_SKILLS" "$OLD_SKILLS" "$OLD_SKILLS" "$OLD_SKILLS" "$OLD_SKILLS" >"$T/scripts/a.sh"
printf 'copied from %s/x at the pin\n' "$OLD_SKILLS" >"$T/plugins/hov-stack/skills/x/UPSTREAM.md"
printf 'vendored into %s/x\n' "$OLD_SKILLS" >"$T/plugins/hov-stack/skills/x/PROVENANCE.md"
printf 'run %s/x/scripts/go.sh\n' "$OLD_SKILLS" >"$T/plugins/hov-stack/skills/x/SKILL.md"
printf '<!-- LOCAL NOTE (dotfiles %s/code-slop) -->\n' "$OLD_SKILLS" >"$T/plugins/hov-stack/skills/code-slop/SKILL.md"
printf 'the plan may say %s/x freely\n' "$OLD_SKILLS" >"$T/docs/plans/p.md"
git -C "$T" add -A
found=$(old_skills_refs "$T" | LC_ALL=C sort)
want="plugins/hov-stack/skills/code-slop/SKILL.md:1:<!-- LOCAL NOTE (dotfiles ${OLD_SKILLS}/code-slop) -->
plugins/hov-stack/skills/x/PROVENANCE.md:1:vendored into ${OLD_SKILLS}/x
plugins/hov-stack/skills/x/SKILL.md:1:run ${OLD_SKILLS}/x/scripts/go.sh
plugins/hov-stack/skills/x/UPSTREAM.md:1:copied from ${OLD_SKILLS}/x at the pin
scripts/a.sh:1:find \"\$ROOT/${OLD_SKILLS}\" -name x
scripts/a.sh:2:# see ${OLD_SKILLS}/x/SKILL.md
scripts/a.sh:6:  ${OLD_SKILLS}"
[ "$found" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$found" "$want"; fail "planted skills-directory references differ"; }
ok "a quoted, a slashed and a bare line-end reference and every pack file, provenance records included, are named; the localizer and suite-key names, the env override and docs/plans/ are not"

echo "== 14: every tracked root entry is accounted for in lib/manifest.sh =="
found=$(uncovered_entries "$ROOT")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "root entries nothing installs or excludes (add each to lib/manifest.sh)"; }
ok "every tracked root entry is linked, owned by an installer, a harness entry or deliberately unlinked"

echo "== 15: every root entry outside the harness list is named in docs/layout.md =="
found=$(undocumented_entries "$ROOT" "$ROOT/docs/layout.md")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "root entries docs/layout.md never names"; }
ok "docs/layout.md names every tracked root entry outside DOTFILES_HARNESS"

echo "== 16: every entry the manifest declares and this copy lacks is marked absent =="
found=$(unmarked_absences "$ROOT" "$ROOT/docs/layout.md")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "declared entries this copy lacks that docs/layout.md does not mark absent"; }
ok "docs/layout.md marks every declared entry this copy lacks \"absent from this copy\""

echo "== 17: a stray, an unnamed and an unmarked entry are each named =="
T=$(plant manifest hooks/x lib/manifest.sh lib/windows.sh config/t docs/layout.md \
  .zrc .gitignore .gitignore_global stray.txt)
cp "$REPO/lib/windows.sh" "$T/lib/windows.sh"
cat >"$T/lib/manifest.sh" <<'MANIFEST'
DOTFILES_ROOT_FILES=(.zrc .gitignore_global .gone)
DOTFILES_LINKS=("config/t|.config/t" "ssh2/config|.ssh/config")
DOTFILES_COPIES=()
DOTFILES_MODES=()
DOTFILES_HARNESS=(hooks)
DOTFILES_TOPICS=()
DOTFILES_UNLINKED=(lib docs .gitignore hosts2.tsv)
MANIFEST
cat >"$T/docs/layout.md" <<'DOC'
| `.zrc`, `.gitignore_global` | dotfiles                              |
| `config/`, `lib/`, `docs/`   | plumbing                              |
| `.gone`                      | named, never marked                   |
| `hosts2.tsv`                 | the host table; absent from this copy |
DOC
git -C "$T" add -A
found=$(uncovered_entries "$T")
[ "$found" = stray.txt ] || { printf '%s\n' "$found"; fail "planted coverage: got '$found'"; }
found=$(undocumented_entries "$T" "$T/docs/layout.md")
want=$'.gitignore\nstray.txt'
[ "$found" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$found" "$want"; fail "planted doc coverage differs"; }
found=$(unmarked_absences "$T" "$T/docs/layout.md")
want=$'.gone\nssh2'
[ "$found" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$found" "$want"; fail "planted absences differ"; }
ok "stray.txt is unaccounted and unnamed, .gitignore_global does not name .gitignore, .gone (named, unmarked) and ssh2 (unnamed) are named; the marked hosts2.tsv and the harness's hooks/ are not"

echo "all $pass checks passed"
