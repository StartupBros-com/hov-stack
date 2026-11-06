#!/usr/bin/env bash
# tests/repo/setup.test.sh: ./setup keeps the README's promises on a clean HOME.
#
#   - existing memory and credentials are byte-identical afterwards
#   - an existing CLAUDE.md is backed up, never deleted
#   - the seeded settings.json parses, names no home directory but this one, no API gateway, no login method
#   - every hook command in the seed runs under the temp HOME without a missing module or file
#   - a second run moves nothing and leaves an existing settings.json alone
#   - CLAUDE_CONFIG_DIR is honoured
#   - every skill in the plugin pack is linked except the ones a default plugin provides,
#     each skip is reported, and none linked is one the pinned record of the default
#     plugins says they ship; a checkout whose root skills link is a plain file links the
#     same set, and a filter that lost papercut is caught by name
#   - no linked file, and no file in the plugin pack, names a home directory or assumes
#     the checkout sits at ~/dotfiles (tests and fixtures aside)
#   - the dfs and gsc wrappers run the sibling implementation next to their own location
#   - the old repository token appears in no tracked file outside the two history docs
#   - the data commands (lib/manifest.sh's DATA_CLIS): a run links each into ~/.local/bin and
#     is the only thing setup leaves under ~/.local offline; a rerun moves nothing; a file or
#     a link of the user's own at one of those paths is left byte-identical, with no backup,
#     and named with ~/.claude/bin/<name>; a link to nothing is replaced and its old target
#     shown; --check on a never-run HOME names each one missing and makes no ~/.local; a
#     ~/.local/bin that is a file fails the row and the run; the PATH note shows only when
#     ~/.local/bin is not on PATH
#   - dcg (#57, restructure plan U15): its licence is shown before anything is fetched; with
#     no network it is reported skipped and the run goes on; --no-dcg fetches nothing and
#     says so; a platform with no build is a skip naming the release page; an archive that
#     fails its checksum is a failure that installs nothing, with the links and seed made;
#     once dcg is installed (#371), a rerun seeds an unedited settings.json again with dcg's
#     hook (the old one backed up, Claude Code's plugin keys kept) and leaves an edited one
#     alone, and the run and --check name a settings.json no hook in which runs dcg; a
#     reseed whose write fails puts the old file back, and one whose key copy fails says so
#   - plugins (U15): with a fake claude first on PATH the hov marketplace is added and each
#     plugin in lib/default-plugins.txt installed exactly once, at user scope; a rerun calls
#     neither; a CLI below the floor, or offline, is reported and the run goes on; --check is
#     green after a full run, names a default plugin removed since and a rerun installs only
#     that one, and names each missing step after a partial run, changing nothing
#   - tool instructions (#420): a tool on PATH gets its line in rules/hov-stack-tools.md,
#     a rerun moves nothing, a refresh drops a removed tool's line, and --check reports
#     stale and missing without writing; with ~/.local/bin on PATH the linked data commands
#     get their line (#440)
#   - auto-update (#395): the fake claude writes what Claude Code writes on an add and an
#     install; setup then turns auto-update on for hov in its own unedited seed and says
#     how to turn it off, a rerun leaves it on and writes nothing, and a settings.json of
#     the user's own keeps no autoUpdate key while setup says /hov-setup asks first
#   - the private overlay (U16, #65): settings.json merges into the seed (its keys win, lists
#     add without repeats across spellings, a null removes, its dcg hooks follow the template's
#     rule, another kind of value is refused with no seed); CLAUDE.md is imported from rules/
#     and the import kept in step; env is exported by claude-env.sh; only an absolute overlay
#     path counts; nothing is written through a rules file or a rules/ that is a symlink; and
#     --check names each problem, exits 1 on it alone, and changes nothing
#
# Runs with a PATH that has node, git and the base system only: no dcg, no claude,
# no user bin dirs, the way a fresh machine looks. curl and minisign are stubs, so no run
# reaches the network.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }
# The data commands setup links into ~/.local/bin (DATA_CLIS), from the file setup reads.
# shellcheck source=lib/manifest.sh
. "$ROOT/lib/manifest.sh"
[ "${#DATA_CLIS[@]}" -ge 13 ] && [[ " ${DATA_CLIS[*]} " == *" gsc "* ]] && [[ " ${DATA_CLIS[*]} " == *" vastai "* ]] \
  || fail "lib/manifest.sh's DATA_CLIS lost the data commands: ${DATA_CLIS[*]}"
# stray_local <home> <checkout>: anything under <home>/.local but bin/ and the data commands'
# links into <checkout>/bin, one per line.
stray_local() {
  local h=$1 r=$2 e name
  [ -d "$h/.local" ] || return 0
  find "$h/.local" -mindepth 1 | while IFS= read -r e; do
    [ "$e" != "$h/.local/bin" ] || continue
    name=${e#"$h/.local/bin/"}
    if [[ " ${DATA_CLIS[*]} " == *" $name "* ]] && [ -L "$e" ] && [ "$(readlink "$e")" = "$r/bin/$name" ]; then continue; fi
    echo "$e"
  done
}

mkdir -p "$WORK/bin"
real_node=$(mise which node 2>/dev/null || command -v node)
ln -s "$(readlink -f "$real_node")" "$WORK/bin/node"
ln -s "$(readlink -f "$(command -v git)")" "$WORK/bin/git"
export PATH=$WORK/bin:/usr/bin:/bin
export HOME=$WORK/home
unset CLAUDE_CONFIG_DIR XDG_CONFIG_HOME HOV_STACK_OVERLAY
# The downloader, stubbed so dcg/install.sh never reaches GitHub. Each call is logged. By
# default it fails the way curl does offline; CURL_MODE=garbage "downloads" junk instead.
# minisign is a stub too, so install.sh's tool check passes on a host without it; no case
# here gets as far as a signature.
export STUB_LOG=$WORK/stub
mkdir -p "$STUB_LOG"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:?}/curl"
if [ "${CURL_MODE:-}" = garbage ]; then
  out=
  while [ $# -gt 0 ]; do
    if [ "$1" = --output ]; then out=$2; fi
    shift
  done
  printf 'not a release asset\n' > "$out"
  exit 0
fi
echo "curl: (6) Could not resolve host: github.com" >&2
exit 6
EOF
printf '#!/bin/sh\necho "minisign stub: no case in this test verifies a signature" >&2\nexit 1\n' > "$WORK/bin/minisign"
chmod +x "$WORK/bin/curl" "$WORK/bin/minisign"
curl_calls() { if [ -f "$STUB_LOG/curl" ]; then wc -l < "$STUB_LOG/curl" | tr -d ' '; else echo 0; fi; }

mkdir -p "$HOME/.claude/projects/-home-someone-app/memory" "$HOME/.claude/memory"
echo "# My notes" > "$HOME/.claude/projects/-home-someone-app/memory/MEMORY.md"
echo "keep me" > "$HOME/.claude/memory/notes.md"
echo '{"claudeAiOauth":{"accessToken":"not-a-real-token"}}' > "$HOME/.claude/.credentials.json"
echo "# their rules" > "$HOME/.claude/CLAUDE.md"
mem_before=$(cat "$HOME/.claude/projects/-home-someone-app/memory/MEMORY.md" "$HOME/.claude/memory/notes.md" | sha256sum)
cred_before=$(sha256sum < "$HOME/.claude/.credentials.json")

t0=$(date +%s%N)
bash "$ROOT/setup" > "$WORK/run1.log" 2>&1 || { cat "$WORK/run1.log"; fail "setup exited non-zero"; }
t1=$(date +%s%N)
echo "setup took $(( (t1 - t0) / 1000000 )) ms on a clean HOME"
sed 's/^/    | /' "$WORK/run1.log"

# dcg on a machine with no network: the licence first, then one failed fetch, a skip, and
# the run carries on (restructure plan OQ4, U15).
lic=$(grep -n -F "is MIT-licensed with an added rider" "$WORK/run1.log" | head -n1 | cut -d: -f1) || true
dl=$(grep -n -F "dcg: downloading " "$WORK/run1.log" | head -n1 | cut -d: -f1) || true
[ -n "$lic" ] && [ -n "$dl" ] && [ "$lic" -lt "$dl" ] || fail "dcg's licence was not shown before its download (licence line '$lic', download line '$dl')"
grep -q -F "https://github.com/Dicklesworthstone/destructive_command_guard/blob/main/LICENSE" "$WORK/run1.log" || fail "the licence notice does not link the LICENSE"
grep -q -F "To leave dcg out, run ./setup --no-dcg instead." "$WORK/run1.log" || fail "the licence notice does not name --no-dcg"
ok "dcg's licence, its link and --no-dcg are shown before anything is downloaded"
grep -q -F "dcg: skipped: could not download " "$WORK/run1.log" || fail "an offline dcg download was not reported skipped"
[ "$(curl_calls)" = 1 ] || fail "expected one download attempt, got $(curl_calls)"
stray=$(stray_local "$HOME" "$ROOT")
[ -z "$stray" ] || fail "an offline run left files under ~/.local besides the data commands' links: $stray"
for want_row in 'links +ok ' 'commands +ok ' 'dcg +skipped ' 'settings +ok ' 'claude +missing ' 'marketplace +skipped ' 'plugins +skipped '; do
  grep -q -E "^  $want_row" "$WORK/run1.log" || fail "the status block has no '$want_row' row"
done
ok "offline: one download attempt, dcg reported skipped, nothing under ~/.local but the data commands' links, and every step has its status row"

[ "$(cat "$HOME/.claude/projects/-home-someone-app/memory/MEMORY.md" "$HOME/.claude/memory/notes.md" | sha256sum)" = "$mem_before" ] || fail "memory changed"
ok "memory untouched"
[ "$(sha256sum < "$HOME/.claude/.credentials.json")" = "$cred_before" ] || fail "credentials changed"
ok "credentials untouched"

[ -L "$HOME/.claude/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink"
[ "$(readlink -f "$HOME/.claude/CLAUDE.md")" = "$ROOT/CLAUDE.md" ] || fail "CLAUDE.md points elsewhere"
backup=$(ls -d "$HOME"/.hov-stack-backups/*/ | head -1)
grep -q "their rules" "$backup/.claude/CLAUDE.md" || fail "previous CLAUDE.md not in backup"
ok "previous CLAUDE.md backed up under $backup"
for name in agents bin commands hooks mods scripts workflows claude-env.sh memory-dream.json; do
  [ -L "$HOME/.claude/$name" ] || fail "$name not linked"
done
[ "$(readlink -f "$HOME/.claude/memory-dream.json")" = "$ROOT/memory-dream.json" ] || fail "memory-dream.json points elsewhere"
ok "10 harness links, memory-dream.json among them (the memory-dream plugin reads its config there)"
# Skills (#37, restructure plan KTD12): one link per skill in the pack and in skills-stack/
# (R21's exception), except the ones lib/default-plugin-skills.txt says a default plugin
# provides, and each skip is reported.
FILTER=$ROOT/lib/default-plugin-skills.txt
RECORD=$ROOT/tests/fixtures/default-plugin-skills.txt
filter_names() { awk '$1 !~ /^#/ && NF { print $1 }' "$1" | LC_ALL=C sort -u; }
want_skills() {  # $1 = a checkout root: its pack's and skills-stack/'s skill names minus its filter's
  find "$1/plugins/hov-stack/skills" "$1/skills-stack" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | LC_ALL=C sort \
    | LC_ALL=C comm -23 - <(filter_names "$1/lib/default-plugin-skills.txt")
}
linked_skills() { find "$1/skills" -mindepth 1 -maxdepth 1 -type l | sed 's|.*/||' | LC_ALL=C sort; }
got=$(linked_skills "$HOME/.claude")
want=$(want_skills "$ROOT")
[ -n "$want" ] || fail "the pack minus the filter is empty"
[ "$got" = "$want" ] || { diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true; fail "linked skills are not the pack minus the default-plugin skills"; }
n_skipped=0
while read -r name plugin _; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -d "$ROOT/plugins/hov-stack/skills/$name" ] || continue
  grep -q -x -F "  skipped $name: the $plugin plugin provides it" "$WORK/run1.log" || fail "setup did not report skipping $name ($plugin)"
  n_skipped=$((n_skipped + 1))
done < "$FILTER"
[ "$n_skipped" -gt 0 ] || fail "no pack skill is on the filter, so the skip report went untested"
ok "$(printf '%s\n' "$got" | wc -l) skills linked; the $n_skipped a default plugin provides were skipped and named"

# What each default plugin ships is recorded from the plugin trees at their marketplace
# pins, apart from the filter, so a name dropped from the filter fails here instead of
# passing: no linked skill is one a default plugin ships, and every recorded name is on
# the filter (a pack skill added under such a name is then skipped, not duplicated).
head -n1 "$RECORD" | grep -qE '^# commit [0-9a-f]{40}$' || fail "$RECORD does not pin the marketplace commit"
awk '$1 !~ /^#/ && NF && ($2 !~ /^[0-9a-f]+$/ || length($2) != 40 || NF != 3) { print; bad = 1 } END { exit bad }' "$RECORD" \
  || fail "$RECORD has a line that is not <plugin> <40-hex pin> <skill>"
dup_names() {  # $1 = a config dir, $2 = the record; prints "<skill> (the <plugin> plugin ships it)"
  local plugin name
  while read -r plugin _ name; do
    case "$plugin" in ''|'#'*) continue ;; esac
    if [ -e "$1/skills/$name" ] || [ -L "$1/skills/$name" ]; then echo "$name (the $plugin plugin ships it)"; fi
  done < "$2"
}
found=$(dup_names "$HOME/.claude" "$RECORD")
[ -z "$found" ] || { printf '%s\n' "$found"; fail "setup linked a skill a default plugin ships"; }
missing=$(LC_ALL=C comm -23 <(awk '$1 !~ /^#/ && NF { print $3 }' "$RECORD" | LC_ALL=C sort -u) <(filter_names "$FILTER"))
[ -z "$missing" ] || fail "default plugins ship skills the filter does not skip: $missing"
ok "no linked skill is one the pinned record says a default plugin ships, and every recorded name is on the filter"
# The filter skips a skill because setup installs the plugin that provides it, so every
# plugin it names must be one lib/default-plugins.txt lists.
DEFAULTS=$ROOT/lib/default-plugins.txt
default_names() { awk '$1 !~ /^#/ && NF { print $1 }' "$DEFAULTS"; }
stray_plugins() {  # $1 = a skills filter: the plugins it names that setup does not install
  LC_ALL=C comm -23 <(awk '$1 !~ /^#/ && NF { print $2 }' "$1" | LC_ALL=C sort -u) <(default_names | LC_ALL=C sort -u)
}
stray=$(stray_plugins "$FILTER")
[ -z "$stray" ] || fail "lib/default-plugin-skills.txt names plugins lib/default-plugins.txt does not install: $stray"
printf 'tune  sometool\n' > "$WORK/filter-stray"
[ "$(stray_plugins "$WORK/filter-stray")" = sometool ] || fail "the plugin check did not name a planted plugin setup does not install"
ok "every plugin the skills filter names is one setup installs (a planted sometool is named)"

# A checkout made without symlink support holds the root `skills` link as a plain file
# naming its target. setup reads the pack from its real path, so it links the same set.
copy=$WORK/copy
mkdir -p "$copy"
(cd "$ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$copy"
rm "$copy/skills"
printf 'plugins/hov-stack/skills' > "$copy/skills"
if [ ! -f "$copy/skills" ] || [ -L "$copy/skills" ]; then fail "the scratch copy's skills entry is not a plain file"; fi
HOME=$WORK/home-plain bash "$copy/setup" --no-dcg > "$WORK/run-plain.log" 2>&1 || { cat "$WORK/run-plain.log"; fail "setup failed in a checkout whose skills link is a plain file"; }
[ "$(linked_skills "$WORK/home-plain/.claude")" = "$want" ] || fail "a plain-file skills link changed the linked set"
ok "a checkout whose root skills link is a plain file links the same $(printf '%s\n' "$want" | wc -l) skills"
# A filter whose last line lost its newline still skips that line's skill.
last=$(tail -n1 "$copy/lib/default-plugin-skills.txt" | awk '{print $1}')
[ -d "$copy/plugins/hov-stack/skills/$last" ] || fail "the filter's last entry ($last) is not a pack skill, so this case tests nothing"
printf '%s' "$(cat "$copy/lib/default-plugin-skills.txt")" > "$WORK/filter-nonl"
cp "$WORK/filter-nonl" "$copy/lib/default-plugin-skills.txt"
[ -n "$(tail -c1 "$copy/lib/default-plugin-skills.txt")" ] || fail "the planted filter still ends in a newline"
HOME=$WORK/home-nonl bash "$copy/setup" --no-dcg > "$WORK/run-nonl.log" 2>&1 || { cat "$WORK/run-nonl.log"; fail "setup failed with a filter missing its final newline"; }
[ "$(linked_skills "$WORK/home-nonl/.claude")" = "$want" ] || fail "a filter missing its final newline changed the linked set"
ok "a filter whose last line has no newline still skips $last"
# Planted negative: a filter that lost papercut links the pack's papercut, and both record
# checks name it.
grep -v -E '^papercut[[:space:]]' "$copy/lib/default-plugin-skills.txt" > "$WORK/filter-planted"
cp "$WORK/filter-planted" "$copy/lib/default-plugin-skills.txt"
HOME=$WORK/home-planted bash "$copy/setup" --no-dcg > "$WORK/run-planted.log" 2>&1 || { cat "$WORK/run-planted.log"; fail "setup failed with the planted filter"; }
found=$(dup_names "$WORK/home-planted/.claude" "$RECORD")
[ "$found" = "papercut (the papercut plugin ships it)" ] || { printf '%s\n' "$found"; fail "the record check did not name the planted duplicate"; }
missing=$(LC_ALL=C comm -23 <(awk '$1 !~ /^#/ && NF { print $3 }' "$RECORD" | LC_ALL=C sort -u) <(filter_names "$copy/lib/default-plugin-skills.txt"))
[ "$missing" = "papercut" ] || fail "the filter check did not name the planted gap: '$missing'"
ok "a filter missing papercut links it, and both record checks name papercut"

# Every file setup just linked now runs, or is read, on the adopter's machine, so
# none may name a home directory as a path (#7 was one hook, #16 the rest; the
# tracked tree spells home paths with a literal $HOME/ that the seed renders) or
# assume the checkout sits at $HOME/dotfiles rather than where it resolves (#17).
# Test, fixture and provenance files are data and skipped. A placeholder user
# (a doc that shows /home/ubuntu, a test slug -home-user-...) names nobody: the
# list is the public-safety scan's own, read from it so the two cannot drift.
# The allowlist names the files that carry such a literal on purpose, pinned to
# a match count so an added one is still caught. It is empty: its one entry, the
# README clone check, stopped naming the old checkout path with U19 (#69). The loop
# stays for the next file that needs a pin.
HOST_PLACEHOLDERS=$(sed -n "s/^PH='\(.*\)'\$/\1/p" "$ROOT/scripts/public-safety-scan.sh")
[ -n "$HOST_PLACEHOLDERS" ] || fail "could not read the placeholder list (PH=) from scripts/public-safety-scan.sh"
scan_host_literals() {  # $1 = a config dir laid out like ~/.claude; prints offenders, returns 1 on any
  local root=$1 bad=0 entry f want n hits name roots=()
  for name in CLAUDE.md agents bin commands hooks mods scripts workflows claude-env.sh memory-dream.json skills; do
    [ -e "$root/$name" ] && roots+=("$root/$name")
  done
  hits=$(find -L "${roots[@]}" -type f \
      ! -path '*/tests/*' ! -path '*/test/*' ! -path '*/fixtures/*' ! -name 'fixtures.*' \
      ! -name '*.test.*' ! -path '*/node_modules/*' ! -path '*/dcg-contract/*' \
      ! -name 'UPSTREAM.md' ! -name 'PROVENANCE.md' -print0 \
    | xargs -0 grep -n -H -o -E -e '/home/[A-Za-z][A-Za-z0-9_.-]*' -e '~/dotfiles' \
        -e '(^|[^A-Za-z0-9_])-home-[A-Za-z][A-Za-z0-9_]*' \
        -e '\$HOME/dotfiles' -e '\$\{HOME\}/dotfiles' -e '"\$HOME"/dotfiles' 2>/dev/null \
    | grep -v -E "(/home/|-home-)($HOST_PLACEHOLDERS)\$") || true
  local -a pins=()
  for entry in ${pins[@]+"${pins[@]}"}; do
    f=${entry%=*}; want=${entry#*=}
    [ -e "$root/$f" ] || continue
    n=$(printf '%s\n' "$hits" | grep -c -F "/$f:" || true)
    [ "$n" = "$want" ] || { echo "$f: $n host literals, the allowlist pins $want"; bad=1; }
    hits=$(printf '%s\n' "$hits" | grep -v -F "/$f:" || true)
  done
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; bad=1; fi
  return "$bad"
}
scan_host_literals "$HOME/.claude" > "$WORK/scan.out" 2>&1 || { cat "$WORK/scan.out"; fail "linked harness files name a home directory"; }
ok "no home-directory literal or ~/dotfiles layout path in the linked harness files (tests and fixtures aside)"
# The plugin installs the whole pack, the skills setup skips included, so scan all of it.
scan_host_literals "$ROOT/plugins/hov-stack" > "$WORK/scan-pack.out" 2>&1 || { cat "$WORK/scan-pack.out"; fail "the plugin pack names a home directory"; }
ok "no home-directory literal or ~/dotfiles layout path in the plugin pack, skipped skills included"
# Planted negative: the same scan over a tree holding one offending line must fail and name it.
planted=$WORK/planted
mkdir -p "$planted/bin"
printf '#!/usr/bin/env bash\nexec python3 /home/jdoe/.claude/bin/x.py "$@"\n' > "$planted/bin/x"
printf 'REPO="${DOTFILES:-$HOME/dotfiles}"\n' > "$planted/bin/y"
if scan_host_literals "$planted" > "$WORK/planted.out" 2>&1; then fail "the scan passed a planted home path"; fi
grep -q -F "$planted/bin/x:2:" "$WORK/planted.out" || { cat "$WORK/planted.out"; fail "the scan did not name the planted home-path file"; }
grep -q -F "$planted/bin/y:1:" "$WORK/planted.out" || { cat "$WORK/planted.out"; fail "the scan did not name the planted layout-path file"; }
ok 'the scan names a planted host literal (planted/bin/x) and a planted $HOME/dotfiles path (planted/bin/y)'

# The repository token was renamed (#27, restructure plan U12). The decision record and the
# plan under docs/ keep the old one as history and are the only tracked files allowed to
# carry it; anywhere else it is a regression, and a public tree must not name the private
# staging repo. The token is spelled in two parts so this file does not match itself.
old_token='w''stack'
scan_old_token() {  # $1 = a checkout root; prints offenders, returns 1 on any
  local hits
  hits=$(cd "$1" && git ls-files -z | grep -z -v -E '^docs/(decisions|plans)/' \
    | xargs -0 grep -n -H -i -F -- "$old_token" 2>/dev/null) || true
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; return 1; fi
}
scan_old_token "$ROOT" > "$WORK/token.out" 2>&1 || { cat "$WORK/token.out"; fail "the old repository token survives outside docs/decisions and docs/plans"; }
ok "no old repository token in the tracked tree outside the two history docs"
# Planted negative: a tracked file carrying the token fails the scan by name.
planted_repo=$WORK/planted-token
git init -q "$planted_repo"
printf 'BACKUP=$HOME/.%s-backups\n' "$old_token" > "$planted_repo/setup"
git -C "$planted_repo" add setup
if scan_old_token "$planted_repo" > "$WORK/planted-token.out" 2>&1; then fail "the scan passed a planted old token"; fi
grep -q -F "setup:1:" "$WORK/planted-token.out" || { cat "$WORK/planted-token.out"; fail "the scan did not name the planted token file"; }
ok 'the scan names a planted old repository token (planted-token/setup)'

# The bin wrappers reach their Python siblings through their own resolved
# location, never a fixed path (#16): copied beside stub siblings they run the
# stubs. gsc's venv comes from HOME, which here holds a stub python.
wrap=$WORK/wrap
mkdir -p "$wrap/bin" "$wrap/elsewhere" "$HOME/.local/share/gsc-cli/venv/bin"
printf 'print("SIBLING-DFS")\n' > "$wrap/bin/dfs.py"
printf 'print("ELSEWHERE")\n' > "$wrap/elsewhere/dfs.py"
printf 'print("SIBLING-GSC")\n' > "$wrap/bin/gsc.py"
printf '#!/bin/sh\necho VENV-FROM-HOME\nexec python3 "$@"\n' > "$HOME/.local/share/gsc-cli/venv/bin/python"
chmod +x "$HOME/.local/share/gsc-cli/venv/bin/python"
cp "$HOME/.claude/bin/dfs" "$HOME/.claude/bin/gsc" "$wrap/bin/"
got=$(bash "$wrap/bin/dfs")
[ "$got" = "SIBLING-DFS" ] || fail "dfs ran something other than its sibling dfs.py: $got"
got=$(bash "$wrap/bin/gsc")
[ "$got" = "$(printf 'VENV-FROM-HOME\nSIBLING-GSC')" ] || fail "gsc did not use the HOME venv and its sibling gsc.py: $got"
ok "dfs and gsc run the sibling implementation next to their own location"
# Planted negative: the pre-#16 wrapper shape, a fixed absolute path, runs whatever
# sits at that path instead, which is exactly what the two checks above reject.
printf '#!/usr/bin/env bash\nexec python3 %s/dfs.py "$@"\n' "$wrap/elsewhere" > "$wrap/bin/dfs-fixed-path"
got=$(bash "$wrap/bin/dfs-fixed-path")
[ "$got" = "ELSEWHERE" ] || fail "planted fixed-path wrapper did not run the elsewhere copy: $got"
ok "a fixed-path wrapper runs the elsewhere copy, which the sibling check rejects"

S=$HOME/.claude/settings.json
[ -f "$S" ] || fail "settings.json not seeded"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$S" || fail "settings.json does not parse"
if grep -E '/home/[A-Za-z]' "$S" | grep -q -v -F "$HOME/"; then fail "settings.json names a home directory other than this HOME"; fi
! grep -q -F '$HOME/' "$S" || fail "settings.json carries an unrendered \$HOME/ template path"
for bad in ANTHROPIC_BASE_URL CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY CLAUDE_CODE_WEBSEARCH_USE_CCR_PROXY forceLoginMethod '"model"' enabledPlugins extraKnownMarketplaces statusLine WACLI_STORE_DIR; do
  ! grep -q -F "$bad" "$S" || fail "settings.json carries $bad"
done
node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  for (const groups of Object.values(s.hooks)) for (const g of groups) for (const h of g.hooks)
    if (/\/dcg\b/.test(h.command)) { console.log(h.command); process.exit(1); }
' "$S" || fail "dcg hook kept although dcg is not installed"
ok "settings.json parses and carries no machine-bound keys"
# No overlay (both variables are cleared above, and this HOME has no ~/.config): the seed is
# exactly lib/settings-seed.js's without one, and no rules file is written.
node "$ROOT/lib/settings-seed.js" "$ROOT/settings.json" "$WORK/seed-direct.json" "$HOME/.claude" "$HOME" "" > /dev/null
cmp -s "$S" "$WORK/seed-direct.json" || fail "with no overlay the seed differs from lib/settings-seed.js run without one"
[ ! -e "$HOME/.claude/rules" ] || fail "with no overlay setup made a rules directory"
grep -q -x -E "  overlay +ok +nothing at $HOME/\.config/hov-stack \(settings\.json, CLAUDE\.md and env there are optional\)" "$WORK/run1.log" \
  || fail "with no overlay the status block has no 'overlay ok nothing at' row"
ok "with no overlay the seed is the plain seed, no rules file is written, and the overlay row says there is nothing"
grep -q -F "$HOME/.claude/hooks/" "$S" || fail "hook paths were not rewritten"
counts=$(node -e '
  const fs = require("fs");
  const parse = (p) => { const t = fs.readFileSync(p, "utf8"); try { return JSON.parse(t); } catch { return JSON.parse(t.slice(0, t.lastIndexOf("}") + 1)); } };
  const a = parse(process.argv[1]).permissions, b = parse(process.argv[2]).permissions;
  for (const k of ["allow", "ask", "deny"]) if (a[k].length !== b[k].length) { console.log(`${k} ${a[k].length} != ${b[k].length}`); process.exit(1); }
  console.log(`allow ${a.allow.length} ask ${a.ask.length} deny ${a.deny.length}`);
' "$S" "$ROOT/settings.json") || fail "permission lists differ from the source: $counts"
ok "permission lists intact ($counts)"

node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  for (const groups of Object.values(s.hooks)) for (const g of groups) for (const h of g.hooks) console.log(h.command);
' "$S" > "$WORK/cmds"
n_cmds=0
while IFS= read -r cmd; do
  n_cmds=$((n_cmds + 1))
  set +e
  out=$(cd "$HOME" && echo '{}' | bash -c "$cmd" 2>&1)
  rc=$?
  set -e
  if grep -q -E "Cannot find module|ENOENT|No such file" <<<"$out"; then
    fail "hook command broke on a clean HOME: $cmd :: $out"
  fi
  echo "    rc=$rc  ${cmd:0:100}"
done < "$WORK/cmds"
ok "$n_cmds hook commands run on a clean HOME (no missing module or file)"

# The `{}` run above does not start node for a gated hook: loop-guard skips unless
# CLAUDE_LOOP_GUARD=1 (env gate), settings-guard and auto-format skip unless stdin holds one of
# their literals or a JSON \uXXXX escape prefix of them (hooks/bin/node-hook). A missing module in
# those hooks would pass unseen. So run every command again ARMED: CLAUDE_LOOP_GUARD=1 and a
# payload that opens every stdin gate (it holds \u002 and \u006, valid JSON, no file_path), with a
# counting `node` first on PATH, and require that every node hook really started node. A future
# gate this payload does not open turns this red instead of silently dropping the module check.
bs=$(printf '\134')
armed_payload="{\"a\":\"${bs}u0020${bs}u0061\"}"
[ "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).a)' <<<"$armed_payload")" = " a" ] \
  || fail "the armed payload is not the JSON it should be: $armed_payload"
real_node=$(command -v node)
mkdir -p "$WORK/countbin"
printf '#!/bin/sh\necho start >> "%s"\nexec "%s" "$@"\n' "$WORK/node-starts" "$real_node" > "$WORK/countbin/node"
chmod +x "$WORK/countbin/node"
: > "$WORK/node-starts"
n_armed=0
n_armed_node=0
unstarted=
while IFS= read -r cmd; do
  n_armed=$((n_armed + 1))
  starts_before=$(wc -l < "$WORK/node-starts")
  set +e
  out=$(cd "$HOME" && printf '%s' "$armed_payload" | PATH="$WORK/countbin:$PATH" CLAUDE_LOOP_GUARD=1 timeout 120 bash -c "$cmd" 2>&1)
  rc=$?
  set -e
  if grep -q -E "Cannot find module|ENOENT|No such file" <<<"$out"; then
    fail "hook command broke on a clean HOME when armed: $cmd :: $out"
  fi
  case $cmd in
    *hooks/bin/node-hook* | "node "*)
      n_armed_node=$((n_armed_node + 1))
      starts_after=$(wc -l < "$WORK/node-starts")
      [ "$starts_after" -gt "$starts_before" ] || unstarted="$unstarted"$'\n'"  $cmd"
      ;;
  esac
  echo "    armed rc=$rc  ${cmd:0:100}"
done < "$WORK/cmds"
[ -z "$unstarted" ] \
  || fail "node hook(s) never started node on the armed payload (a gate the payload does not open hides its module check):$unstarted"
[ "$n_armed_node" -ge 1 ] || fail "armed run found no node hook command"
ok "$n_armed_node of $n_armed hook commands are node hooks; each started node on the armed payload with no missing module or file"

# Second run against a settings.json the user customized: it must survive byte-for-byte,
# with the seed written beside it, and nothing moved to a backup.
printf '{\n  "permissions": {"allow": ["Bash(echo theirs)"]},\n  "theirOwnKey": true\n}\n' > "$S"
theirs_before=$(sha256sum < "$S")
n_backups=$(ls -d "$HOME"/.hov-stack-backups/*/ | wc -l)
bash "$ROOT/setup" > "$WORK/run2.log" 2>&1 || { cat "$WORK/run2.log"; fail "second setup run exited non-zero"; }
[ "$(ls -d "$HOME"/.hov-stack-backups/*/ | wc -l)" = "$n_backups" ] || fail "second run created a backup"
grep -q "settings.json already exists" "$WORK/run2.log" || fail "second run did not notice the existing settings.json"
[ "$(sha256sum < "$S")" = "$theirs_before" ] || fail "customized settings.json was modified"
W=$HOME/.claude/settings.hov-stack.json
[ -f "$W" ] || fail "seed not written beside the existing settings.json"
grep -q -F '"allow"' "$W" && ! grep -q -F 'theirOwnKey' "$W" || fail "settings.hov-stack.json is not the seed"
ok "second run moved nothing; a customized settings.json survived byte-for-byte with the seed beside it"

# The data commands (DATA_CLIS) in ~/.local/bin. Both runs above linked each one to this
# checkout; the second changed none and replaced nothing.
n_cli=${#DATA_CLIS[@]}
for name in "${DATA_CLIS[@]}"; do
  [ -L "$HOME/.local/bin/$name" ] && [ "$(readlink "$HOME/.local/bin/$name")" = "$ROOT/bin/$name" ] \
    || fail "$HOME/.local/bin/$name is not a link to $ROOT/bin/$name"
done
for log in run1 run2; do
  grep -q -E "^  commands +ok +$n_cli data commands linked into ~/\.local/bin; ~/\.local/bin is not on this shell's PATH" "$WORK/$log.log" \
    || { cat "$WORK/$log.log"; fail "$log has no 'commands ok' row with the PATH note"; }
done
! grep -q -F 'which is gone; it now runs' "$WORK/run2.log" || fail "the second run replaced a link"
ok "each of the $n_cli data commands is linked into ~/.local/bin, the row says ~/.local/bin is not on PATH, and a rerun replaces nothing"
# A file of the user's own, a link of theirs and a link to nothing, each at one of those paths.
HCL=$WORK/home-cmds
mkdir -p "$HCL/.local/bin" "$HCL/elsewhere"
printf '#!/bin/sh\necho my-own-vastai\n' > "$HCL/.local/bin/vastai"
printf '#!/bin/sh\necho my-own-gsc\n' > "$HCL/elsewhere/gsc"
ln -s "$HCL/elsewhere/gsc" "$HCL/.local/bin/gsc"
ln -s "$HCL/gone/dfs" "$HCL/.local/bin/dfs"
vastai_before=$(sha256sum < "$HCL/.local/bin/vastai")
HOME=$HCL PATH=$HCL/.local/bin:$PATH bash "$ROOT/setup" --no-dcg > "$WORK/run-cmds.log" 2>&1 || { cat "$WORK/run-cmds.log"; fail "setup with commands of the user's own exited non-zero"; }
[ -f "$HCL/.local/bin/vastai" ] && [ ! -L "$HCL/.local/bin/vastai" ] && [ "$(sha256sum < "$HCL/.local/bin/vastai")" = "$vastai_before" ] \
  || fail "the user's own vastai was moved or changed"
[ "$(readlink "$HCL/.local/bin/gsc")" = "$HCL/elsewhere/gsc" ] || fail "the user's own gsc link was replaced"
[ "$(readlink "$HCL/.local/bin/dfs")" = "$ROOT/bin/dfs" ] || fail "a link to nothing was not replaced with hov-stack's dfs"
grep -q -x -F "  ~/.local/bin/dfs pointed at $HCL/gone/dfs, which is gone; it now runs hov-stack's" "$WORK/run-cmds.log" \
  || { cat "$WORK/run-cmds.log"; fail "the replaced link's old target was not shown"; }
[ ! -e "$HCL/.hov-stack-backups" ] || fail "leaving the user's commands alone made a backup"
grep -q -x -E "  commands +ok +$((n_cli - 2)) of $n_cli data commands linked into ~/\.local/bin; left alone, not hov-stack's: gsc, vastai \(ours runs as ~/\.claude/bin/<name>\)" "$WORK/run-cmds.log" \
  || { cat "$WORK/run-cmds.log"; fail "the commands row does not name gsc and vastai as left alone with the fallback, or still has the PATH note"; }
rc=0; HOME=$HCL PATH=$HCL/.local/bin:$PATH bash "$ROOT/setup" --check --no-dcg > "$WORK/check-cmds.log" 2>&1 || rc=$?
grep -q -E "^  commands +ok +$((n_cli - 2)) of $n_cli .*left alone, not hov-stack's: gsc, vastai" "$WORK/check-cmds.log" \
  || { cat "$WORK/check-cmds.log"; fail "--check does not count the commands left alone as in place"; }
ok "a vastai file and a gsc link of the user's own are left byte-identical, unbacked-up and named with ~/.claude/bin/<name>; a link to nothing is replaced and its old target shown; --check counts them in place"
# --check on a HOME setup never ran in: every one is named missing, and nothing is made.
HCN=$WORK/home-cmds-never
rc=0; HOME=$HCN bash "$ROOT/setup" --check --no-dcg > "$WORK/check-cmds-never.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-cmds-never.log"; fail "--check on a never-run HOME exited $rc, not 1"; }
grep -q -E "^  commands +missing +0 of $n_cli data commands linked into ~/\.local/bin; not linked: ${DATA_CLIS[*]}; run \./setup" "$WORK/check-cmds-never.log" \
  || { cat "$WORK/check-cmds-never.log"; fail "--check on a never-run HOME did not name every data command missing"; }
[ ! -e "$HCN/.local" ] || fail "--check made ~/.local"
ok "--check on a never-run HOME names all $n_cli data commands missing and makes no ~/.local"
# A ~/.local/bin that is a file: the row fails, the run exits 1, and the file is untouched.
HCF=$WORK/home-cmds-file
mkdir -p "$HCF/.local"
echo "not a directory" > "$HCF/.local/bin"
rc=0; HOME=$HCF bash "$ROOT/setup" --no-dcg > "$WORK/run-cmds-file.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/run-cmds-file.log"; fail "a ~/.local/bin that is a file exited $rc, not 1"; }
grep -q -E "^  commands +failed +could not make ~/\.local/bin, so no data command was linked; each still runs as ~/\.claude/bin/<name>" "$WORK/run-cmds-file.log" \
  || { cat "$WORK/run-cmds-file.log"; fail "a ~/.local/bin that is a file has no 'commands failed' row naming it"; }
[ "$(cat "$HCF/.local/bin")" = "not a directory" ] || fail "the file at ~/.local/bin was changed"
[ -L "$HCF/.claude/hooks" ] || fail "a failed commands step stopped the other links"
ok "a ~/.local/bin that is a file fails the commands row and the run, is left as it was, and the other steps still run"

# The command line: --help prints the header and an unknown option is refused, both
# before anything is made.
bash "$ROOT/setup" --help > "$WORK/help.log" 2>&1 || { cat "$WORK/help.log"; fail "./setup --help exited non-zero"; }
head -n1 "$WORK/help.log" | grep -q '^hov-stack setup: ' || fail "--help does not start with the header"
grep -q -F './setup --check' "$WORK/help.log" || fail "--help does not show --check"
rc=0; HOME=$WORK/home-bogus bash "$ROOT/setup" --bogus > "$WORK/bogus.log" 2>&1 || rc=$?
[ "$rc" = 2 ] || { cat "$WORK/bogus.log"; fail "an unknown option exited $rc, not 2"; }
grep -q -F 'unknown option --bogus' "$WORK/bogus.log" || fail "the unknown option was not named"
[ ! -e "$WORK/home-bogus" ] || fail "an unknown option still made files"
ok "--help prints the header; an unknown option exits 2 and makes nothing"

# dcg, the other ways it can go (U15). Each run has a fresh HOME and no claude on PATH.
n=$(curl_calls)
HOME=$WORK/home-nodcg bash "$ROOT/setup" --no-dcg > "$WORK/run-nodcg.log" 2>&1 || { cat "$WORK/run-nodcg.log"; fail "setup --no-dcg exited non-zero"; }
[ "$(curl_calls)" = "$n" ] || fail "--no-dcg still tried a download"
grep -q -x -F 'dcg: skipped (--no-dcg). Run ./dcg/install.sh to add it later, then re-run ./setup.' "$WORK/run-nodcg.log" || fail "--no-dcg did not say dcg was skipped"
! grep -q -F 'MIT-licensed' "$WORK/run-nodcg.log" || fail "--no-dcg still showed the licence notice"
grep -q -E '^  dcg +off ' "$WORK/run-nodcg.log" || fail "--no-dcg has no 'dcg off' status row"
[ -L "$WORK/home-nodcg/.claude/hooks" ] || fail "--no-dcg skipped the links"
ok "--no-dcg fetches nothing, says dcg was skipped, and still links"
n=$(curl_calls)
rc=0; DCG_UNAME_S=FreeBSD DCG_UNAME_M=amd64 HOME=$WORK/home-bsd bash "$ROOT/setup" > "$WORK/run-bsd.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-bsd.log"; fail "a platform with no dcg build exited $rc"; }
grep -q -F 'ships no build for FreeBSD/amd64' "$WORK/run-bsd.log" || { cat "$WORK/run-bsd.log"; fail "the unsupported platform was not named"; }
grep -q -F 'https://github.com/Dicklesworthstone/destructive_command_guard/releases/tag/' "$WORK/run-bsd.log" || fail "the unsupported-platform skip does not link the release page"
[ "$(curl_calls)" = "$n" ] || fail "an unsupported platform still tried a download"
[ -L "$WORK/home-bsd/.claude/hooks" ] && [ -f "$WORK/home-bsd/.claude/settings.json" ] || fail "an unsupported platform stopped the links or the seed"
ok "a platform with no dcg build is a skip naming the release page; links and seed still made"
rc=0; CURL_MODE=garbage HOME=$WORK/home-bad bash "$ROOT/setup" > "$WORK/run-bad.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/run-bad.log"; fail "an archive that fails its checksum exited $rc, not 1"; }
grep -q -F 'dcg: error: checksum mismatch for ' "$WORK/run-bad.log" || { cat "$WORK/run-bad.log"; fail "the checksum failure was not reported"; }
grep -q -E '^  dcg +failed ' "$WORK/run-bad.log" || fail "the checksum failure has no 'dcg failed' status row"
stray=$(stray_local "$WORK/home-bad" "$ROOT")
[ -z "$stray" ] || fail "a refused archive left files under ~/.local: $stray"
[ -L "$WORK/home-bad/.claude/hooks" ] && [ -f "$WORK/home-bad/.claude/settings.json" ] || fail "a refused archive stopped the links or the seed"
grep -q -F 'hov-stack: status' "$WORK/run-bad.log" || fail "a refused archive cut the run short"
ok "an archive that fails its checksum exits 1, installs nothing, and the links and seed are still made"

# dcg installed after a run that seeded settings.json without it (#371). A dcg on PATH stands
# in for the install; the download stays stubbed, so dcg/install.sh still skips offline.
# OBSERVED 2026-11-03 on a clean Mac: the rerun put the hook only in settings.hov-stack.json,
# and --check said settings ok while no hook ran dcg.
mkdir -p "$WORK/dcg-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/dcg-bin/dcg"
chmod +x "$WORK/dcg-bin/dcg"
dcg_hooks() {  # dcg_hooks <settings file>: how many PreToolUse hook commands run the stand-in dcg
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    let n = 0;
    for (const g of (s.hooks && s.hooks.PreToolUse) || []) for (const h of g.hooks || []) if (h.command === process.argv[2]) n += 1;
    console.log(n);
  ' "$1" "$WORK/dcg-bin/dcg"
}
HU=$WORK/home-upgrade
HOME=$HU bash "$ROOT/setup" --no-dcg > "$WORK/run-up1.log" 2>&1 || { cat "$WORK/run-up1.log"; fail "setup --no-dcg before dcg exited non-zero"; }
SU=$HU/.claude/settings.json
[ "$(dcg_hooks "$SU")" = 0 ] || fail "a run without dcg seeded a dcg hook"
# What Claude Code did to the seed during that first run's plugin step, as OBSERVED on the
# Mac: it added the two plugin keys and rewrote the file in its own key order. That is
# still setup's unedited seed. (Written by hand here; the fake claude below writes the same
# keys on its own add and install.)
claude_writes() {  # claude_writes <settings.json>
  node -e '
    const fs = require("fs"), s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    s.enabledPlugins = { "papercut@hov": true, "skill-tuner@hov": true };
    s.extraKnownMarketplaces = { hov: { source: { source: "github", repo: "StartupBros-com/hov-stack" } } };
    const out = {};
    for (const k of Object.keys(s).reverse()) out[k] = s[k];
    fs.writeFileSync(process.argv[1], JSON.stringify(out, null, 2) + "\n");
  ' "$1"
}
claude_writes "$SU"
seed_before=$(sha256sum < "$SU")
rc=0; HOME=$HU PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" --check > "$WORK/check-up1.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-up1.log"; fail "--check with dcg installed and no hook exited $rc, not 1"; }
grep -q -E '^  settings +missing .*no PreToolUse hook that runs dcg.*run \./setup' "$WORK/check-up1.log" || { cat "$WORK/check-up1.log"; fail "--check did not say the unedited seed lacks the hook and that ./setup fixes it"; }
[ "$(sha256sum < "$SU")" = "$seed_before" ] || fail "--check changed settings.json"
rc=0; HOME=$HU PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" > "$WORK/run-up2.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-up2.log"; fail "the rerun with dcg installed exited $rc"; }
[ "$(dcg_hooks "$SU")" = 1 ] || { cat "$WORK/run-up2.log"; fail "the unedited seed did not get dcg's hook once dcg was installed"; }
backup=$(find "$HU/.hov-stack-backups" -path '*/.claude/settings.json' -type f)
[ -n "$backup" ] && [ "$(sha256sum < "$backup")" = "$seed_before" ] || fail "the replaced seed is not in ~/.hov-stack-backups byte for byte (found '$backup')"
grep -q -F "backed up ~/.claude/settings.json -> $HU/.hov-stack-backups/" "$WORK/run-up2.log" || { cat "$WORK/run-up2.log"; fail "the rerun did not say where the old settings.json went"; }
[ ! -e "$HU/.claude/settings.hov-stack.json" ] || fail "the rerun wrote settings.hov-stack.json instead of seeding settings.json"
node -e '
  const fs = require("fs"), a = JSON.parse(fs.readFileSync(process.argv[1], "utf8")), b = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  for (const k of ["enabledPlugins", "extraKnownMarketplaces"]) if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) { console.log(k); process.exit(1); }
' "$SU" "$backup" || fail "the reseed dropped a plugin key Claude Code had written"
grep -q -F 'kept what Claude Code had written there: enabledPlugins, extraKnownMarketplaces' "$WORK/run-up2.log" || { cat "$WORK/run-up2.log"; fail "the rerun did not say it kept the plugin keys"; }
grep -q -E '^  settings +ok ' "$WORK/run-up2.log" || { cat "$WORK/run-up2.log"; fail "the rerun's settings row is not ok"; }
rc=0; HOME=$HU PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" --check > "$WORK/check-up2.log" 2>&1 || rc=$?
grep -q -E '^  settings +ok ' "$WORK/check-up2.log" || { cat "$WORK/check-up2.log"; fail "--check does not show settings ok once the hook is in"; }
ok "dcg installed after the first run: --check names the missing hook, and a rerun backs up the unedited seed (Claude Code's plugin keys and key order included) and seeds it again with the hook, keeping those keys"

# Planted negative: one permission taken out of the seed is an edit, whatever else matches.
HN=$WORK/home-narrowed
HOME=$HN bash "$ROOT/setup" --no-dcg > "$WORK/run-nr1.log" 2>&1 || { cat "$WORK/run-nr1.log"; fail "setup --no-dcg before dcg exited non-zero"; }
node -e '
  const fs = require("fs"), s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  s.permissions.allow.pop();
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");
' "$HN/.claude/settings.json"
narrowed=$(sha256sum < "$HN/.claude/settings.json")
HOME=$HN PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" > "$WORK/run-nr2.log" 2>&1 || { cat "$WORK/run-nr2.log"; fail "the rerun over a narrowed seed exited non-zero"; }
[ "$(sha256sum < "$HN/.claude/settings.json")" = "$narrowed" ] || fail "a seed missing one permission was taken for setup's own and replaced"
grep -q "settings.json already exists" "$WORK/run-nr2.log" || fail "the rerun did not leave the narrowed settings.json alone"
ok "a seed missing one permission entry counts as edited and is left alone"

# A node that fails the two writes an upgrade makes, and runs everything else for real:
# NODE_FAIL=seed fails lib/settings-seed.js writing ~/.claude/settings.json after leaving half
# a file there (a full disk); NODE_FAIL=carry fails the copy of Claude Code's plugin keys.
real_node=$(command -v node)
mkdir -p "$WORK/node-fail"
cat > "$WORK/node-fail/node" <<EOF
#!/bin/sh
if [ "\$NODE_FAIL" = seed ]; then
  case "\$1:\$3" in
    *lib/settings-seed.js:*/.claude/settings.json) printf '{"permissions": {' > "\$3"; echo "node stub: seed write failed" >&2; exit 1 ;;
  esac
fi
if [ "\$NODE_FAIL" = carry ] && [ "\$1" = -e ]; then
  case "\$2" in *"kept what Claude Code had written"*) echo "node stub: carry failed" >&2; exit 1 ;; esac
fi
exec "$real_node" "\$@"
EOF
chmod -- 0755 "$WORK/node-fail/node"

# An upgrade whose new seed is not written puts the old settings.json back over the half
# file, byte for byte, and says so.
HP=$WORK/home-putback
HOME=$HP bash "$ROOT/setup" --no-dcg > "$WORK/run-pb1.log" 2>&1 || { cat "$WORK/run-pb1.log"; fail "setup --no-dcg before dcg exited non-zero"; }
claude_writes "$HP/.claude/settings.json"
pb_before=$(sha256sum < "$HP/.claude/settings.json")
rc=0; HOME=$HP NODE_FAIL=seed PATH=$WORK/node-fail:$WORK/dcg-bin:$PATH bash "$ROOT/setup" > "$WORK/run-pb2.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/run-pb2.log"; fail "a failed reseed exited $rc, not 1"; }
grep -q -F 'node stub: seed write failed' "$WORK/run-pb2.log" || { cat "$WORK/run-pb2.log"; fail "the stub never failed the seed write, so this case tested nothing"; }
[ "$(sha256sum < "$HP/.claude/settings.json")" = "$pb_before" ] || { cat "$WORK/run-pb2.log"; fail "a failed reseed left settings.json other than the old seed"; }
grep -q -F "put ~/.claude/settings.json back from $HP/.hov-stack-backups/" "$WORK/run-pb2.log" || { cat "$WORK/run-pb2.log"; fail "the failed reseed did not say it put the old settings.json back"; }
grep -q -E '^  settings +failed ' "$WORK/run-pb2.log" || { cat "$WORK/run-pb2.log"; fail "the failed reseed's settings row is not failed"; }
ok "an upgrade whose new seed is not written puts the old settings.json back over the half-written file"

# An upgrade that seeds the hook but cannot copy Claude Code's plugin keys says so, and the
# backup still holds them.
HC=$WORK/home-carryfail
HOME=$HC bash "$ROOT/setup" --no-dcg > "$WORK/run-cf1.log" 2>&1 || { cat "$WORK/run-cf1.log"; fail "setup --no-dcg before dcg exited non-zero"; }
claude_writes "$HC/.claude/settings.json"
cf_before=$(sha256sum < "$HC/.claude/settings.json")
rc=0; HOME=$HC NODE_FAIL=carry PATH=$WORK/node-fail:$WORK/dcg-bin:$PATH bash "$ROOT/setup" > "$WORK/run-cf2.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/run-cf2.log"; fail "a failed carry-over exited $rc, not 1"; }
grep -q -F 'node stub: carry failed' "$WORK/run-cf2.log" || { cat "$WORK/run-cf2.log"; fail "the stub never failed the carry-over, so this case tested nothing"; }
grep -q -E '^  settings +failed .*could not copy the plugin keys' "$WORK/run-cf2.log" || { cat "$WORK/run-cf2.log"; fail "the failed carry-over's settings row does not say the plugin keys were not copied"; }
[ "$(dcg_hooks "$HC/.claude/settings.json")" = 1 ] || fail "the failed carry-over lost the new seed's dcg hook"
cf_backup=$(find "$HC/.hov-stack-backups" -path '*/.claude/settings.json' -type f)
[ -n "$cf_backup" ] && [ "$(sha256sum < "$cf_backup")" = "$cf_before" ] || fail "the failed carry-over's backup is not the old seed byte for byte (found '$cf_backup')"
ok "an upgrade that cannot copy Claude Code's plugin keys says so, keeps the hook, and leaves them in the backup"

# The same with a settings.json someone edited: left alone, the hook goes to
# settings.hov-stack.json, and both the run and --check say settings.json still lacks it.
HE=$WORK/home-edited
HOME=$HE bash "$ROOT/setup" --no-dcg > "$WORK/run-ed1.log" 2>&1 || { cat "$WORK/run-ed1.log"; fail "setup --no-dcg before dcg exited non-zero"; }
SE=$HE/.claude/settings.json
node -e '
  const fs = require("fs"), s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  s.theirOwnKey = true;
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");
' "$SE"
edited=$(sha256sum < "$SE")
n_backups=$(find "$HE" -maxdepth 1 -name .hov-stack-backups | wc -l)
rc=0; HOME=$HE PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" > "$WORK/run-ed2.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-ed2.log"; fail "the rerun over an edited settings.json exited $rc"; }
[ "$(sha256sum < "$SE")" = "$edited" ] || fail "an edited settings.json was changed"
[ "$(find "$HE" -maxdepth 1 -name .hov-stack-backups | wc -l)" = "$n_backups" ] || fail "an edited settings.json was backed up"
[ "$(dcg_hooks "$HE/.claude/settings.hov-stack.json")" = 1 ] || fail "settings.hov-stack.json does not carry dcg's hook"
grep -q -E '^  settings +missing .*no PreToolUse hook that runs dcg.*copy the entry .*settings\.hov-stack\.json' "$WORK/run-ed2.log" || { cat "$WORK/run-ed2.log"; fail "the rerun did not say the edited settings.json lacks dcg's hook"; }
rc=0; HOME=$HE PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" --check > "$WORK/check-ed.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ed.log"; fail "--check over an edited settings.json with no dcg hook exited $rc, not 1"; }
grep -q -E '^  settings +missing .*no PreToolUse hook that runs dcg.*copy the entry' "$WORK/check-ed.log" || { cat "$WORK/check-ed.log"; fail "--check did not name the missing dcg hook"; }
rc=0; HOME=$HE PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" --check --no-dcg > "$WORK/check-ed-nodcg.log" 2>&1 || rc=$?
grep -q -E '^  settings +ok ' "$WORK/check-ed-nodcg.log" || { cat "$WORK/check-ed-nodcg.log"; fail "--check --no-dcg still held settings.json to dcg's hook"; }
[ "$(sha256sum < "$SE")" = "$edited" ] || fail "--check changed an edited settings.json"
ok "an edited settings.json is left alone: the hook goes to settings.hov-stack.json, and the run and --check name it missing (--no-dcg leaves it out)"

# What counts as a hook that runs dcg: the command's own word dcg, at any path, and nothing
# that merely has dcg in its name.
probe_hook() {  # probe_hook <command>: --check's settings row for a settings.json with that one PreToolUse hook
  node -e '
    const hook = { type: "command", command: process.argv[2] };
    require("fs").writeFileSync(process.argv[1], JSON.stringify({ hooks: { PreToolUse: [{ matcher: "Bash", hooks: [hook] }] } }) + "\n");
  ' "$SE" "$1"
  HOME=$HE PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" --check > "$WORK/probe.log" 2>&1 || true
  grep -E '^  settings ' "$WORK/probe.log" | awk '{ print $2 }'
}
[ "$(probe_hook 'bash $HOME/.claude/hooks/dcg-reap.sh')" = missing ] || fail "a hook named dcg-reap.sh was taken for dcg"
[ "$(probe_hook '/opt/somewhere/dcg-wrapper')" = missing ] || fail "a hook named dcg-wrapper was taken for dcg"
[ "$(probe_hook '$HOME/.local/bin/dcg')" = ok ] || fail "the template's own \$HOME/.local/bin/dcg hook was not taken for dcg"
[ "$(probe_hook "\"$WORK/dcg-bin/dcg\" --robot")" = ok ] || fail "a quoted dcg path with an argument was not taken for dcg"
printf '{ "hooks":\n' > "$SE"
HOME=$HE PATH=$WORK/dcg-bin:$PATH bash "$ROOT/setup" --check > "$WORK/probe.log" 2>&1 || true
grep -q -E '^  settings +missing .*does not parse' "$WORK/probe.log" || { cat "$WORK/probe.log"; fail "--check did not say an unparseable settings.json runs no dcg hook"; }
ok "a hook runs dcg only when its command is dcg itself (dcg-reap.sh and dcg-wrapper do not count); an unparseable settings.json is named"

# The plugin steps, against a stand-in for the claude CLI: just the subcommands setup calls,
# its state in files under $FAKE (version, marketplace, plugins, offline) and every call
# appended to $FAKE/calls. The runs use the scratch copy.
mkdir -p "$WORK/fake-bin"
cat > "$WORK/fake-bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
F=${FAKE:?}
printf '%s\n' "$*" >> "$F/calls"
case "$*" in
  --version) printf '%s (Claude Code)\n' "$(cat "$F/version")" ;;
  'plugin marketplace list --json')
    # hov once added, then any marketplaces of other publishers the test lists in $F/extra
    # (one JSON object per line).
    items=
    if [ -f "$F/marketplace" ]; then
      items=$(printf '{"name":"hov","source":"github","repo":"StartupBros-com/hov-stack","installLocation":"%s"}' "$(cat "$F/marketplace")")
    fi
    if [ -f "$F/extra" ]; then
      while read -r obj; do items="${items:+$items,}$obj"; done < "$F/extra"
    fi
    printf '[%s]\n' "$items" ;;
  'plugin marketplace update '?*)
    # Exactly `plugin marketplace update <name>`: the bare form, or any flag, is not accepted.
    [ $# -eq 4 ] || { echo "fake claude: unexpected call: $*" >&2; exit 64; }
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    echo "Successfully updated marketplace: $4" ;;
  'plugin update '*' --scope user')
    # Exactly `plugin update <id> --scope user`: -y or --accept-command would not match.
    [ $# -eq 5 ] || { echo "fake claude: unexpected call: $*" >&2; exit 64; }
    if [ -f "$F/update-refuse" ] && grep -q -x -F "$3" "$F/update-refuse"; then
      echo "Error: $3 declares a command and needs --accept-command to update" >&2
      exit 1
    fi
    echo "$3 is up to date" ;;
  'plugin marketplace add '*)
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    printf '%s\n' "$F/mkt" > "$F/marketplace"
    # What Claude Code 2.1.318 writes on an add (OBSERVED for #395): the marketplace's entry
    # in settings.json, replaced whole, so an autoUpdate set before is dropped; and its record
    # in plugins/known_marketplaces.json.
    node -e '
      const fs = require("fs"), path = require("path");
      const [cfg, repo] = process.argv.slice(1);
      const source = { source: "github", repo };
      const sp = path.join(cfg, "settings.json");
      let s = {};
      try { if (fs.existsSync(sp)) s = JSON.parse(fs.readFileSync(sp, "utf8")); } catch { s = null; }
      if (s) {
        s.extraKnownMarketplaces = { ...(s.extraKnownMarketplaces || {}), hov: { source } };
        fs.writeFileSync(sp, JSON.stringify(s, null, 2) + "\n");
      }
      const kp = path.join(cfg, "plugins", "known_marketplaces.json");
      let k = {};
      if (fs.existsSync(kp)) k = JSON.parse(fs.readFileSync(kp, "utf8"));
      k.hov = { source, installLocation: path.join(cfg, "plugins", "marketplaces", "hov"), lastUpdated: new Date().toISOString() };
      fs.mkdirSync(path.dirname(kp), { recursive: true });
      fs.writeFileSync(kp, JSON.stringify(k, null, 2) + "\n");
    ' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$4" ;;
  'plugin list --json')
    sep=
    printf '['
    while read -r id v scope; do
      printf '%s{"id":"%s","version":"%s","scope":"%s","enabled":true}' "$sep" "$id" "$v" "$scope"
      sep=,
    done < "$F/plugins"
    if [ -f "$F/skills-dir" ]; then
      while read -r id; do
        printf '%s{"id":"%s","version":"1.0.0","scope":"user","enabled":true}' "$sep" "$id"
        sep=,
      done < "$F/skills-dir"
    fi
    echo ']' ;;
  'plugin install '*'@hov --scope user')
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    v=$(awk -v p="${3%@hov}" '$1 == p { print $2 }' "$F/versions")
    [ -n "$v" ] || { echo "fake claude: hov has no plugin $3" >&2; exit 1; }
    printf '%s %s user\n' "$3" "$v" >> "$F/plugins"
    # Claude Code also enables the plugin in settings.json.
    node -e '
      const fs = require("fs"), sp = require("path").join(process.argv[1], "settings.json");
      let s = {};
      try { if (fs.existsSync(sp)) s = JSON.parse(fs.readFileSync(sp, "utf8")); } catch { process.exit(0); }
      s.enabledPlugins = { ...(s.enabledPlugins || {}), [process.argv[2]]: true };
      fs.writeFileSync(sp, JSON.stringify(s, null, 2) + "\n");
    ' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$3" ;;
  *) echo "fake claude: unexpected call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$WORK/fake-bin/claude"
new_fake() {  # new_fake <state dir> <version>: a claude with hov not added yet
  mkdir -p "$1"
  echo "$2" > "$1/version"
  # What hov serves. A project-scope papercut and another marketplace's plugin are already
  # installed; neither counts as a default plugin being in place.
  printf 'papercut 0.4.0\nskill-tuner 1.0.0\nmemory-dream 0.9.0\ndesign-rails 0.13.0\n' > "$1/versions"
  printf 'papercut@hov 0.3.0 project\nother@elsewhere 1.0.0 user\n' > "$1/plugins"
  : > "$1/calls"
}
fake_setup() {  # fake_setup <state dir> <home> <log> [args]: the copy's setup, the fake claude first on PATH
  local f=$1 h=$2 log=$3
  shift 3
  FAKE=$f HOME=$h PATH=$WORK/fake-bin:$PATH bash "$copy/setup" "$@" > "$log" 2>&1
}
calls_of() { grep -c -x -F "$2" "$1/calls" || true; }  # calls_of <state dir> <exact call>
FK=$WORK/fake
new_fake "$FK" 2.1.310
[ "$(default_names | LC_ALL=C sort)" = "$(awk '{ print $1 }' "$FK/versions" | LC_ALL=C sort)" ] \
  || fail "the fake hov marketplace does not serve exactly lib/default-plugins.txt's plugins; update new_fake"
cp "$ROOT/lib/default-plugin-skills.txt" "$copy/lib/default-plugin-skills.txt"
HF=$WORK/home-fake
mkdir -p "$WORK/tool-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/tool-bin/cass"
chmod +x "$WORK/tool-bin/cass"
# cass on PATH, and no extra install dirs, for these runs only: a tool off PATH gets no line.
tools_setup() { HOV_SETUP_EXTRA_BIN_DIRS='' PATH=$WORK/tool-bin:$PATH fake_setup "$@"; }
tools_setup "$FK" "$HF" "$WORK/run-fake.log" --no-dcg || { cat "$WORK/run-fake.log"; fail "setup with a fake claude exited non-zero"; }
TOOLS=$HF/.claude/rules/hov-stack-tools.md
[ -f "$TOOLS" ] && [ ! -L "$TOOLS" ] || fail "no regular generated tool rules file"
grep -q -F 'Search past agent sessions with' "$TOOLS" || fail "installed cass has no instruction"
grep -q -E '^  instructions +ok +rules/hov-stack-tools.md updated; mentions .*cass' "$WORK/run-fake.log" || fail "the instructions row does not say the file was written for cass"
tools_before=$(sha256sum < "$TOOLS")
tools_mtime=$(stat -c %y "$TOOLS")
tools_setup "$FK" "$HF" "$WORK/tools-rerun.log" --no-dcg || fail "tool rules rerun exited non-zero"
! grep -q 'backed up' "$WORK/tools-rerun.log" || fail "tool rules rerun moved something"
[ "$(sha256sum < "$TOOLS")" = "$tools_before" ] && [ "$(stat -c %y "$TOOLS")" = "$tools_mtime" ] || fail "tool rules rerun changed bytes or mtime"
tools_setup "$FK" "$HF" "$WORK/tools-check.log" --check --no-dcg || fail "tool rules check is not green"
rm "$WORK/tool-bin/cass"
rc=0; tools_setup "$FK" "$HF" "$WORK/tools-stale.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || fail "removed tool did not fail check"
grep -q -E '^  instructions +stale +rules/hov-stack-tools.md ' "$WORK/tools-stale.log" || fail "check did not name stale tool rules"
[ "$(sha256sum < "$TOOLS")" = "$tools_before" ] && [ "$(stat -c %y "$TOOLS")" = "$tools_mtime" ] || fail "stale check wrote tool rules"
tools_setup "$FK" "$HF" "$WORK/tools-refresh.log" --no-dcg || fail "tool rules refresh exited non-zero"
! grep -q -F 'Search past agent sessions with' "$TOOLS" 2>/dev/null || fail "the refresh kept the removed tool's line"
printf '#!/bin/sh\nexit 0\n' > "$WORK/tool-bin/cass"
chmod +x "$WORK/tool-bin/cass"
rm -f "$TOOLS"
rc=0; tools_setup "$FK" "$HF" "$WORK/tools-missing.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || fail "a missing tool rules file did not fail check"
grep -q -E '^  instructions +missing +rules/hov-stack-tools.md is not written yet' "$WORK/tools-missing.log" || fail "check did not name the missing tool rules"
[ ! -e "$TOOLS" ] || fail "the missing check wrote tool rules"
rm "$WORK/tool-bin/cass"
ok "tool rules follow installed tools, reruns move nothing, and check reports stale and missing without writing"
# The data commands those runs linked into ~/.local/bin get one line once it is on PATH (#440).
HOV_SETUP_EXTRA_BIN_DIRS='' PATH=$HF/.local/bin:$PATH fake_setup "$FK" "$HF" "$WORK/tools-data.log" --no-dcg \
  || { cat "$WORK/tools-data.log"; fail "setup with the data commands on PATH exited non-zero"; }
grep -q -E '^  instructions +ok +rules/hov-stack-tools.md updated; mentions .*data-commands$' "$WORK/tools-data.log" \
  || { cat "$WORK/tools-data.log"; fail "the instructions row does not name the data commands"; }
grep -q -F -e '- Data sources: use these CLIs before an MCP server' "$TOOLS" || fail "the data commands have no line"
for name in "${DATA_CLIS[@]}"; do
  grep -q -F -e "\`$name\`" "$TOOLS" || fail "the data commands' line does not name $name"
done
ok "with ~/.local/bin on PATH, the data commands setup linked get their line, naming each of them"
sed 's/^/    | /' "$WORK/run-fake.log"
[ "$(calls_of "$FK" 'plugin marketplace add StartupBros-com/hov-stack')" = 1 ] || { cat "$FK/calls"; fail "the hov marketplace was not added exactly once"; }
while read -r p; do
  [ "$(calls_of "$FK" "plugin install $p@hov --scope user")" = 1 ] || { cat "$FK/calls"; fail "$p@hov was not installed exactly once at user scope"; }
done < <(default_names)
[ "$(grep -c '^plugin install ' "$FK/calls")" = "$(default_names | wc -l | tr -d ' ')" ] || { cat "$FK/calls"; fail "setup installed a plugin lib/default-plugins.txt does not list"; }
ok "a fake claude was asked to add hov once and to install each of the $(default_names | wc -l | tr -d ' ') default plugins once, at user scope"
grep -q -E '^  marketplace +ok +added from StartupBros-com/hov-stack$' "$WORK/run-fake.log" || fail "no 'marketplace ok' row"
grep -q -x -E "  plugins +ok +installed: $(default_names | tr '\n' ' ' | sed 's/ $//')" "$WORK/run-fake.log" || fail "the plugins row does not name each default plugin installed"
grep -q -x -F "  hov: auto-update turned on in $HF/.claude/settings.json. To turn it off, set \"autoUpdate\" to false under extraKnownMarketplaces.hov there." "$WORK/run-fake.log" \
  || { cat "$WORK/run-fake.log"; fail "setup did not say it turned auto-update on for hov and how to turn it off"; }
au_of() {  # au_of <settings.json>: hov's autoUpdate value, or 'none'
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const e = s.extraKnownMarketplaces && s.extraKnownMarketplaces.hov;
    process.stdout.write(e && "autoUpdate" in e ? String(e.autoUpdate) : "none");
  ' "$1"
}
[ "$(au_of "$HF/.claude/settings.json")" = true ] || { cat "$HF/.claude/settings.json"; fail "setup's own seed did not get autoUpdate true for hov"; }
grep -q -x -F '  - Auto-update for the hov plugins: Claude Code fetches their new versions by itself.' "$WORK/run-fake.log" \
  || { tail -n 12 "$WORK/run-fake.log"; fail "the ending does not say the hov plugins update themselves"; }
ok "the marketplace and plugins rows name what was added, and setup turns auto-update on in its own seed"
# The ending in plain words (U26, 2026-11-03): what is in place, then one next step. A first
# run had told the user to start a session for /hov-setup and then, from it, another.
grep -q -x -F 'What you have now:' "$WORK/run-fake.log" || fail "the ending does not say what is in place"
grep -q -x -F '  - The rules and safety checks every new Claude Code session loads, linked from this folder.' "$WORK/run-fake.log" \
  || fail "the ending does not name the linked rules"
plain_names=$(default_names | awk 'NR == 1 { s = $0; next } { a[NR] = $0; n = NR }
  END { for (i = 2; i < n; i++) s = s ", " a[i]; if (n) s = s " and " a[n]; print s }')
grep -q -x -F "  - The plugins setup installs for everyone: $plain_names. /hov-setup shows what each does." "$WORK/run-fake.log" \
  || { tail -n 12 "$WORK/run-fake.log"; fail "the ending does not name the default plugins ($plain_names) in plain words"; }
! grep -q -F 'dcg, which stops' "$WORK/run-fake.log" || fail "a --no-dcg run claims dcg is in place"
grep -q -x -F 'Next: open a new Claude Code session (it reads the rules and checks only when it starts)' "$WORK/run-fake.log" \
  || fail "the ending does not give the one next step"
! grep -q -E 'steps? above (is|are) not finished' "$WORK/run-fake.log" || fail "a run with every step in place says some are not finished"
! grep -q -i -F '/hov-setup again' "$WORK/run-fake.log" || fail "the ending asks for a second /hov-setup"
ok "the ending says in plain words what is in place and gives one next step, /hov-setup in a new session"
grep -q -x -F 'Next: get Claude Code working (the claude row above says how) and run ./setup again.' "$WORK/run1.log" \
  || { tail -n 12 "$WORK/run1.log"; fail "with no claude, the ending does not say to get Claude Code working first"; }
grep -q -E '^  [0-9]+ steps above are not finished; each row says how to finish it, then run \./setup again\.$' "$WORK/run1.log" \
  || fail "with steps skipped, the ending does not say so"
ok "with no claude on PATH, the ending says to get Claude Code working before /hov-setup"
fake_setup "$FK" "$HF" "$WORK/run-fake2.log" --no-dcg || { cat "$WORK/run-fake2.log"; fail "a rerun with a fake claude exited non-zero"; }
[ "$(calls_of "$FK" 'plugin marketplace add StartupBros-com/hov-stack')" = 1 ] || fail "a rerun added the marketplace again"
[ "$(grep -c '^plugin install ' "$FK/calls")" = "$(default_names | wc -l | tr -d ' ')" ] || fail "a rerun installed a plugin again"
grep -q -E '^  plugins +ok +.* were already installed$' "$WORK/run-fake2.log" || fail "a rerun did not report the plugins already installed"
[ ! -e "$HF/.hov-stack-backups" ] || fail "a run on a fresh HOME moved something to a backup"
grep -q -x -F "  hov: auto-update is on, set in $HF/.claude/settings.json" "$WORK/run-fake2.log" \
  || { cat "$WORK/run-fake2.log"; fail "a rerun did not say auto-update is on"; }
ok "a rerun adds and installs nothing, says the plugins were already installed and auto-update is on, and moves nothing"
# A settings.json of the user's own: the README promises setup leaves it alone, so auto-update
# stays as Claude Code left it and setup says /hov-setup asks first.
FKO=$WORK/fake-own
new_fake "$FKO" 2.1.310
HOWN=$WORK/home-own
mkdir -p "$HOWN/.claude"
printf '{\n  "theme": "dark"\n}\n' > "$HOWN/.claude/settings.json"
fake_setup "$FKO" "$HOWN" "$WORK/run-own.log" --no-dcg || { cat "$WORK/run-own.log"; fail "setup with a settings.json of the user's own exited non-zero"; }
[ "$(au_of "$HOWN/.claude/settings.json")" = none ] || { cat "$HOWN/.claude/settings.json"; fail "setup set auto-update in a settings.json of the user's own"; }
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).theme === "dark" ? 0 : 1)' "$HOWN/.claude/settings.json" \
  || fail "the user's own setting is gone"
grep -q -x -F "  hov: auto-update is off, Claude Code's default for a marketplace from another publisher" "$WORK/run-own.log" \
  || { cat "$WORK/run-own.log"; fail "setup did not report auto-update off for a settings.json of the user's own"; }
grep -q -x -F '  setup does not change a settings.json you already have; /hov-setup asks before it does.' "$WORK/run-own.log" \
  || fail "setup did not say /hov-setup asks before turning auto-update on"
! grep -q -F 'Auto-update for the hov plugins' "$WORK/run-own.log" || fail "the ending claims auto-update is on when it was left off"
[ ! -e "$HOWN/.hov-stack-backups" ] || fail "a settings.json of the user's own was backed up"
ok "a settings.json of the user's own gets no autoUpdate key, and setup says /hov-setup asks first"
# With dcg found, the seed carries dcg's hook, and that is still setup's own seed.
FKD=$WORK/fake-dcg
new_fake "$FKD" 2.1.310
HFD=$WORK/home-fake-dcg
PATH=$WORK/dcg-bin:$PATH fake_setup "$FKD" "$HFD" "$WORK/run-fake-dcg.log" --no-dcg \
  || { cat "$WORK/run-fake-dcg.log"; fail "setup with a fake claude and dcg found exited non-zero"; }
[ "$(dcg_hooks "$HFD/.claude/settings.json")" != 0 ] || fail "with dcg found, the seed has no dcg hook, so this case tests nothing"
[ "$(au_of "$HFD/.claude/settings.json")" = true ] || { cat "$WORK/run-fake-dcg.log"; fail "setup's own seed with dcg's hook did not get auto-update turned on"; }
ok "with dcg found, setup's own seed (dcg's hook in it) gets auto-update turned on too"
tree_state() { ls -lAR "$1" | sha256sum; }  # -A: '..' would carry $WORK's mtime
tree_before=$(tree_state "$HF")
calls_before=$(wc -l < "$FK/calls")
rc=0; fake_setup "$FK" "$HF" "$WORK/check-green.log" --check --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/check-green.log"; fail "--check after a full run exited $rc"; }
grep -q -x -F 'hov-stack --check: every step is in place.' "$WORK/check-green.log" || fail "--check did not report every step in place"
[ "$(tree_state "$HF")" = "$tree_before" ] || fail "--check changed the config dir"
! tail -n +"$((calls_before + 1))" "$FK/calls" | grep -q -E '^plugin (marketplace add|install) ' || fail "--check added or installed something"
ok "--check after a full run is green and changes nothing"
# A default plugin removed since: --check names it, and a rerun installs that one only.
awk '!($1 == "skill-tuner@hov" && $3 == "user")' "$FK/plugins" > "$FK/plugins.new"
mv "$FK/plugins.new" "$FK/plugins"
rc=0; fake_setup "$FK" "$HF" "$WORK/check-removed.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-removed.log"; fail "--check after a plugin was removed exited $rc, not 1"; }
grep -q -x -E '  plugins +missing +not installed: skill-tuner; run \./setup' "$WORK/check-removed.log" \
  || { cat "$WORK/check-removed.log"; fail "--check did not name the removed plugin"; }
n_installs=$(grep -c '^plugin install ' "$FK/calls")
fake_setup "$FK" "$HF" "$WORK/run-removed.log" --no-dcg || { cat "$WORK/run-removed.log"; fail "the rerun after a plugin was removed exited non-zero"; }
[ "$(calls_of "$FK" 'plugin install skill-tuner@hov --scope user')" = 2 ] || { cat "$FK/calls"; fail "the rerun did not install skill-tuner again"; }
[ "$(grep -c '^plugin install ' "$FK/calls")" = "$((n_installs + 1))" ] || { cat "$FK/calls"; fail "the rerun installed more than skill-tuner"; }
fake_setup "$FK" "$HF" "$WORK/check-removed2.log" --check --no-dcg || { cat "$WORK/check-removed2.log"; fail "--check after the reinstall is not green"; }
ok "--check names a removed default plugin (skill-tuner); a rerun installs only it and --check is green again"
# --check after a partial run: the --no-dcg run without claude, minus one link.
rm "$WORK/home-plain/.claude/hooks"
rc=0; HOME=$WORK/home-plain bash "$copy/setup" --check > "$WORK/check-partial.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-partial.log"; fail "--check after a partial run exited $rc, not 1"; }
for want_row in 'links +missing +not linked: hooks; run \./setup$' 'commands +ok ' 'dcg +missing ' 'claude +missing '; do
  grep -q -E "^  $want_row" "$WORK/check-partial.log" || { cat "$WORK/check-partial.log"; fail "--check after a partial run has no '$want_row' row"; }
done
[ ! -e "$WORK/home-plain/.claude/hooks" ] || fail "--check made the missing link"
ok "--check after a partial run names the missing link, dcg and claude, and makes nothing"
# A CLI below the floor: named with the fix, nothing asked of it, the run goes on.
FO=$WORK/fake-old
new_fake "$FO" 2.1.75
rc=0; fake_setup "$FO" "$WORK/home-old" "$WORK/run-old.log" --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-old.log"; fail "an old claude exited $rc"; }
grep -q -F '2.1.75 is below the 2.1.76 floor' "$WORK/run-old.log" || { cat "$WORK/run-old.log"; fail "the floor was not named for 2.1.75"; }
[ "$(cat "$FO/calls")" = "--version" ] || { cat "$FO/calls"; fail "setup asked an old claude for more than its version"; }
[ -L "$WORK/home-old/.claude/hooks" ] || fail "an old claude stopped the links"
ok "claude 2.1.75 is named below the 2.1.76 floor; the run goes on and asks it nothing else"
# Offline when adding the marketplace: reported with the command to run later.
FN=$WORK/fake-offline
new_fake "$FN" 2.1.310
touch "$FN/offline"
rc=0; fake_setup "$FN" "$WORK/home-offline" "$WORK/run-offline.log" --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-offline.log"; fail "an offline claude exited $rc"; }
grep -q -E "^  marketplace +skipped +'claude plugin marketplace add StartupBros-com/hov-stack' exited 1 \(offline\?\): run it when online, then re-run \./setup$" "$WORK/run-offline.log" \
  || { cat "$WORK/run-offline.log"; fail "the offline marketplace add was not reported with its command"; }
grep -q -E '^  plugins +skipped ' "$WORK/run-offline.log" || fail "the plugins were not reported skipped"
[ "$(grep -c '^plugin install ' "$FN/calls" || true)" = 0 ] || fail "setup tried installs without the marketplace"
ok "offline: the marketplace step is skipped with the command to run later, and no install is tried"
# Offline once the marketplace is there: each install is tried once and the failures listed.
FI=$WORK/fake-offline-install
new_fake "$FI" 2.1.310
printf '%s\n' "$FI/mkt" > "$FI/marketplace"
touch "$FI/offline"
rc=0; fake_setup "$FI" "$WORK/home-offline-install" "$WORK/run-offline-install.log" --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-offline-install.log"; fail "offline installs exited $rc"; }
grep -q -E "^  plugins +skipped +not installed: $(default_names | tr '\n' ' ' | sed 's/ $//') \(offline\?\)" "$WORK/run-offline-install.log" \
  || { cat "$WORK/run-offline-install.log"; fail "the offline installs were not listed"; }
[ "$(grep -c '^plugin install ' "$FI/calls")" = "$(default_names | wc -l | tr -d ' ')" ] || fail "offline installs were not each tried once"
ok "offline installs: each default plugin is tried once and the ones not installed are listed"

# The private overlay (restructure plan U16, #65): <overlay>/settings.json is merged into the
# seed, <overlay>/CLAUDE.md is imported from the rules directory, and <overlay>/env is read by
# claude-env.sh before every Bash call. The overlay is HOV_STACK_OVERLAY, else
# $XDG_CONFIG_HOME/hov-stack, else ~/.config/hov-stack; both variables are cleared at the
# top, so every run above saw none. The fake claude keeps --check's other rows green.
OV=$WORK/overlay
HO=$WORK/home-overlay
FOV=$WORK/fake-overlay
new_fake "$FOV" 2.1.310
mkdir -p "$OV"
cat > "$OV/settings.json" <<'EOF'
{
  "model": "overlay-model",
  "autoCompactWindow": 123456,
  "env": { "MY_OVERLAY_DIR": "$HOME/.local/state/mine", "API_TIMEOUT_MS": "1" },
  "permissions": { "allow": ["Bash(overlay-tool:*)"] },
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "sh $HOME/.claude/hooks/overlay-stop.sh" } ] } ] },
  "sandbox": null
}
EOF
printf '# This machine\n\n- OVERLAY-RULE-PROBE\n' > "$OV/CLAUDE.md"
printf 'OVERLAY_PROBE=from-overlay\n' > "$OV/env"
# --check before any run: the import is named missing, and nothing is made.
rc=0; HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/check-ov-first.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ov-first.log"; fail "--check before the first run exited $rc, not 1"; }
grep -q -x -E "  overlay +missing +$OV/CLAUDE\.md is not imported by rules/hov-stack-overlay\.md: run \./setup" "$WORK/check-ov-first.log" \
  || { cat "$WORK/check-ov-first.log"; fail "--check before the first run did not name the missing import"; }
[ ! -e "$HO/.claude/rules" ] || fail "--check made the rules directory"
ok "--check before the first run names the overlay's CLAUDE.md as not imported and makes no rules directory"
HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/run-ov.log" --no-dcg || { cat "$WORK/run-ov.log"; fail "setup with an overlay exited non-zero"; }
node "$ROOT/lib/settings-seed.js" "$ROOT/settings.json" "$WORK/seed-ov-base.json" "$HO/.claude" "$HO" "" > /dev/null
node -e '
  const fs = require("fs");
  const [base, got] = process.argv.slice(1, 3).map((p) => JSON.parse(fs.readFileSync(p, "utf8")));
  const [cfg, home] = process.argv.slice(3);
  const bad = [];
  const want = (c, m) => { if (!c) bad.push(m); };
  want(got.model === "overlay-model", "a key the allow-list drops did not come back from the overlay");
  want(got.autoCompactWindow === 123456, "a kept scalar did not take the overlay value");
  want(got.env.MY_OVERLAY_DIR === home + "/.local/state/mine", "an overlay env path was not rendered to HOME");
  want(got.env.API_TIMEOUT_MS === "1", "a kept env var did not take the overlay value");
  want(got.permissions.allow.length === base.permissions.allow.length + 1 && got.permissions.allow.at(-1) === "Bash(overlay-tool:*)",
    "permissions.allow is not the template list plus the overlay rule");
  want(got.hooks.Stop.length === base.hooks.Stop.length + 1 && got.hooks.Stop.at(-1).hooks[0].command === "sh " + cfg + "/hooks/overlay-stop.sh",
    "hooks.Stop is not the template hooks plus the overlay hook rendered to the config dir");
  want("sandbox" in base && !("sandbox" in got), "a null in the overlay did not remove sandbox");
  want(!JSON.stringify(got).includes("$HOME/"), "an unrendered $HOME/ survived");
  // With what the overlay touched put back, the seed is the no-overlay seed.
  const canon = (v) => Array.isArray(v) ? v.map(canon)
    : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v;
  const g = structuredClone(got), b = structuredClone(base);
  delete g.model; g.autoCompactWindow = b.autoCompactWindow; delete g.env.MY_OVERLAY_DIR; g.env.API_TIMEOUT_MS = b.env.API_TIMEOUT_MS;
  g.permissions.allow.pop(); g.hooks.Stop.pop(); delete b.sandbox;
  // The two keys Claude Code writes (by the fake claude add and installs) do not come from the overlay:
  // they hold what those wrote, plus the auto-update setup turns on in its own seed (#395).
  const hovEntry = { hov: { source: { source: "github", repo: "StartupBros-com/hov-stack" }, autoUpdate: true } };
  want(JSON.stringify(canon(g.extraKnownMarketplaces)) === JSON.stringify(canon(hovEntry)),
    "extraKnownMarketplaces is not the entry the add wrote, with auto-update turned on");
  const enabled = Object.entries(g.enabledPlugins || {});
  want(enabled.length > 0 && enabled.every(([id, on]) => id.endsWith("@hov") && on === true), "enabledPlugins is not what the installs wrote");
  delete g.extraKnownMarketplaces; delete g.enabledPlugins;
  want(JSON.stringify(canon(g)) === JSON.stringify(canon(b)), "the overlay changed something it does not name");
  if (bad.length) { console.log(bad.join("\n")); process.exit(1); }
' "$WORK/seed-ov-base.json" "$HO/.claude/settings.json" "$HO/.claude" "$HO" || fail "the overlay seed is wrong (above)"
ok "an overlay's keys win, its lists add to the template's, a null removes a key, its \$HOME/ paths render, and nothing else changes"
grep -q -x -F "    from the overlay $OV/settings.json: model, autoCompactWindow, env.MY_OVERLAY_DIR, env.API_TIMEOUT_MS, permissions.allow +1, hooks.Stop +1, sandbox removed" "$WORK/run-ov.log" \
  || { cat "$WORK/run-ov.log"; fail "the seed report does not name what the overlay set"; }
ov_row=$(grep -E '^  overlay +ok +' "$WORK/run-ov.log") || { cat "$WORK/run-ov.log"; fail "no 'overlay ok' row"; }
for part in "$OV: " "settings.json merged into the seed at $HO/.claude/settings.json" 'CLAUDE.md imported by rules/hov-stack-overlay.md' 'env read before each Bash call'; do
  grep -q -F "$part" <<<"$ov_row" || fail "the overlay row does not say '$part': $ov_row"
done
ok "the seed report names each key the overlay set, and the status row names the overlay's three files"
# CLAUDE.md: one import in the rules directory, which a rerun leaves alone.
R=$HO/.claude/rules/hov-stack-overlay.md
[ -f "$R" ] && [ ! -L "$R" ] || fail "no rules file imports the overlay's CLAUDE.md"
[ "$(wc -l < "$R" | tr -d ' ')" = 2 ] && [ "$(sed -n 2p "$R")" = "@$OV/CLAUDE.md" ] || { cat "$R"; fail "the rules file is not one header line and one import of $OV/CLAUDE.md"; }
rule_before=$(ls -l --time-style=+%s.%N "$R" | sha256sum)
HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/run-ov2.log" --no-dcg || { cat "$WORK/run-ov2.log"; fail "a rerun with an overlay exited non-zero"; }
[ "$(ls -l --time-style=+%s.%N "$R" | sha256sum)" = "$rule_before" ] || fail "a rerun rewrote the rules file"
[ ! -e "$HO/.hov-stack-backups" ] || fail "an overlay run on a fresh HOME moved something to a backup"
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).model === "overlay-model" ? 0 : 1)' "$HO/.claude/settings.hov-stack.json" \
  || fail "the seed beside an existing settings.json does not carry the overlay"
ok "CLAUDE.md is imported by rules/hov-stack-overlay.md; a rerun leaves it alone, moves nothing, and merges the overlay into the seed beside settings.json"
rc=0; HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/check-ov.log" --check --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/check-ov.log"; fail "--check with the overlay in place exited $rc"; }
grep -q -E "^  overlay +ok +$OV: settings\.json merged only into a seed \./setup writes, never an existing settings\.json; CLAUDE\.md imported by rules/hov-stack-overlay\.md; env read before each Bash call$" "$WORK/check-ov.log" \
  || { cat "$WORK/check-ov.log"; fail "--check with the overlay in place has no 'overlay ok' row naming its three files"; }
ok "--check with the overlay in place is green and says the overlay's settings reach only a seed setup writes"
# The overlay's CLAUDE.md removed: --check names the dangling import and changes nothing; a
# rerun takes the import away, and --check is green again.
rm "$OV/CLAUDE.md"
tree_before=$(tree_state "$HO")
rc=0; HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/check-ov-gone.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ov-gone.log"; fail "--check with a dangling import exited $rc, not 1"; }
grep -q -x -E "  overlay +stale +rules/hov-stack-overlay\.md imports $OV/CLAUDE\.md, which is gone: run \./setup" "$WORK/check-ov-gone.log" \
  || { cat "$WORK/check-ov-gone.log"; fail "--check did not name the dangling import"; }
[ "$(tree_state "$HO")" = "$tree_before" ] || fail "--check changed the config dir"
HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/run-ov-gone.log" --no-dcg || { cat "$WORK/run-ov-gone.log"; fail "setup after the overlay's CLAUDE.md was removed exited non-zero"; }
[ ! -e "$R" ] || fail "a rerun left an import of a CLAUDE.md that is gone"
grep -q -F "removed ~/.claude/rules/hov-stack-overlay.md: it imported $OV/CLAUDE.md, and there is no $OV/CLAUDE.md" "$WORK/run-ov-gone.log" \
  || { cat "$WORK/run-ov-gone.log"; fail "the rerun did not say it took the import away"; }
rc=0; HOV_STACK_OVERLAY=$OV fake_setup "$FOV" "$HO" "$WORK/check-ov-gone2.log" --check --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/check-ov-gone2.log"; fail "--check after the import was taken away exited $rc"; }
ok "--check names an import whose CLAUDE.md is gone and changes nothing; a rerun takes the import away and --check is green"
# --check's exit status turns on the overlay alone: $HO is green with a good overlay, so each
# overlay below is the only thing that can make --check exit 1.
OVC=$WORK/overlay-check
mkdir -p "$OVC"
printf 'OVERLAY_PROBE=fine\n' > "$OVC/env"
printf '{ "model": "fine" }\n' > "$OVC/settings.json"
tree_before=$(tree_state "$HO")
rc=0; HOV_STACK_OVERLAY=$OVC fake_setup "$FOV" "$HO" "$WORK/check-ovc-good.log" --check --no-dcg || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/check-ovc-good.log"; fail "--check with a good env and settings.json exited $rc"; }
printf 'OVERLAY_PROBE=(\n' > "$OVC/env"
rc=0; HOV_STACK_OVERLAY=$OVC fake_setup "$FOV" "$HO" "$WORK/check-ovc-env.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ovc-env.log"; fail "--check with an env that does not parse exited $rc, not 1"; }
grep -q -E "^  overlay +invalid +$OVC/env does not parse under bash " "$WORK/check-ovc-env.log" || { cat "$WORK/check-ovc-env.log"; fail "--check did not name the env that does not parse"; }
rm "$OVC/env"
printf '{ "model":\n' > "$OVC/settings.json"
rc=0; HOV_STACK_OVERLAY=$OVC fake_setup "$FOV" "$HO" "$WORK/check-ovc-json.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ovc-json.log"; fail "--check with a settings.json that is not JSON exited $rc, not 1"; }
grep -q -x -E "  overlay +invalid +$OVC/settings\.json is not a JSON object \(.+\), so \./setup writes no seed" "$WORK/check-ovc-json.log" \
  || { cat "$WORK/check-ovc-json.log"; fail "--check did not name the settings.json that is not JSON"; }
printf '{ "permissions": "x" }\n' > "$OVC/settings.json"
rc=0; HOV_STACK_OVERLAY=$OVC fake_setup "$FOV" "$HO" "$WORK/check-ovc-kind.log" --check --no-dcg || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ovc-kind.log"; fail "--check with a settings.json the merge refuses exited $rc, not 1"; }
grep -q -x -E "  overlay +invalid +the overlay $OVC/settings\.json gives permissions a plain value where the template has an object, so \./setup writes no seed" "$WORK/check-ovc-kind.log" \
  || { cat "$WORK/check-ovc-kind.log"; fail "--check did not name the setting given another kind of value"; }
# A relative HOV_STACK_OVERLAY, from a directory where it names a whole overlay.
mkdir -p "$WORK/relcwd/ovrel"
printf '# relative\n' > "$WORK/relcwd/ovrel/CLAUDE.md"
printf '{ "model": "relative" }\n' > "$WORK/relcwd/ovrel/settings.json"
printf 'OVERLAY_PROBE=from-relative\n' > "$WORK/relcwd/ovrel/env"
rel_row='  overlay +invalid +HOV_STACK_OVERLAY is ovrel, not an absolute path, so \./setup reads nothing there and claude-env\.sh reads no env from it'
rc=0; (cd "$WORK/relcwd" && HOV_STACK_OVERLAY=ovrel fake_setup "$FOV" "$HO" "$WORK/check-ov-rel.log" --check --no-dcg) || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ov-rel.log"; fail "--check with a relative HOV_STACK_OVERLAY exited $rc, not 1"; }
grep -q -x -E "$rel_row" "$WORK/check-ov-rel.log" || { cat "$WORK/check-ov-rel.log"; fail "--check did not name the relative HOV_STACK_OVERLAY"; }
[ "$(tree_state "$HO")" = "$tree_before" ] || fail "--check with a bad overlay changed the config dir"
ok "--check, green with a good overlay, exits 1 on an env that does not parse, a settings.json that is not JSON or gives a setting another kind of value, or a relative HOV_STACK_OVERLAY, naming each and changing nothing"
# A rules file at that path that setup did not write, or one setup wrote and someone edited,
# is moved to the backup before the import replaces it.
printf '# This machine\n' > "$OV/CLAUDE.md"
HF2=$WORK/home-overlay-foreign
mkdir -p "$HF2/.claude/rules"
echo "my own rule" > "$HF2/.claude/rules/hov-stack-overlay.md"
HOV_STACK_OVERLAY=$OV HOME=$HF2 bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-foreign.log" 2>&1 || { cat "$WORK/run-ov-foreign.log"; fail "setup over a foreign rules file exited non-zero"; }
grep -q -x -F "my own rule" "$HF2"/.hov-stack-backups/*/.claude/rules/hov-stack-overlay.md || fail "the foreign rules file was not backed up"
[ "$(sed -n 2p "$HF2/.claude/rules/hov-stack-overlay.md")" = "@$OV/CLAUDE.md" ] || fail "the foreign rules file was not replaced by the import"
HF3=$WORK/home-overlay-edited
HOV_STACK_OVERLAY=$OV HOME=$HF3 bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-edited1.log" 2>&1 || { cat "$WORK/run-ov-edited1.log"; fail "setup for the edited-import case exited non-zero"; }
echo "a line I added" >> "$HF3/.claude/rules/hov-stack-overlay.md"
HOV_STACK_OVERLAY=$OV HOME=$HF3 bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-edited2.log" 2>&1 || { cat "$WORK/run-ov-edited2.log"; fail "the rerun over an edited import exited non-zero"; }
grep -q -x -F "a line I added" "$HF3"/.hov-stack-backups/*/.claude/rules/hov-stack-overlay.md || fail "an edited import was replaced without a backup"
[ "$(wc -l < "$HF3/.claude/rules/hov-stack-overlay.md" | tr -d ' ')" = 2 ] || fail "the edited import was not rewritten"
ok "a rules file setup did not write, or an edited import, is moved to the backup before the import replaces it"
# Setup's own rules file importing another overlay's CLAUDE.md: --check names it stale, and a
# run rewrites it in place, with nothing to back up.
OVY=$WORK/overlay-other
mkdir -p "$OVY"
printf '# Another machine\n' > "$OVY/CLAUDE.md"
HXY=$WORK/home-overlay-switch
RXY=$HXY/.claude/rules/hov-stack-overlay.md
HOV_STACK_OVERLAY=$OV HOME=$HXY bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-switch1.log" 2>&1 || { cat "$WORK/run-ov-switch1.log"; fail "setup for the switched-overlay case exited non-zero"; }
rule_head=$(sed -n 1p "$RXY")
rc=0; HOV_STACK_OVERLAY=$OVY HOME=$HXY bash "$ROOT/setup" --check --no-dcg > "$WORK/check-ov-switch.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/check-ov-switch.log"; fail "--check with an import of another overlay's CLAUDE.md exited $rc, not 1"; }
grep -q -x -E "  overlay +stale +rules/hov-stack-overlay\.md imports $OV/CLAUDE\.md, not $OVY/CLAUDE\.md: run \./setup" "$WORK/check-ov-switch.log" \
  || { cat "$WORK/check-ov-switch.log"; fail "--check did not name the import of another overlay's CLAUDE.md"; }
HOV_STACK_OVERLAY=$OVY HOME=$HXY bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-switch2.log" 2>&1 || { cat "$WORK/run-ov-switch2.log"; fail "the rerun with another overlay exited non-zero"; }
[ "$(wc -l < "$RXY" | tr -d ' ')" = 2 ] && [ "$(sed -n 1p "$RXY")" = "$rule_head" ] && [ "$(sed -n 2p "$RXY")" = "@$OVY/CLAUDE.md" ] \
  || { cat "$RXY"; fail "the import of another overlay's CLAUDE.md was not rewritten to $OVY/CLAUDE.md"; }
[ ! -e "$HXY/.hov-stack-backups" ] || fail "rewriting setup's own import moved something to a backup"
grep -q -E "^  overlay +ok +$OVY: CLAUDE\.md imported by rules/hov-stack-overlay\.md$" "$WORK/run-ov-switch2.log" || { cat "$WORK/run-ov-switch2.log"; fail "the rerun's overlay row does not say the import is in place"; }
ok "an import of another overlay's CLAUDE.md is named stale by --check, and a run rewrites setup's own file in place with nothing backed up"
# A rules file that is a symlink is never written through, even one that reads like setup's
# own: it is moved to the backup, and the file it points at is left as it was.
HSL=$WORK/home-overlay-rulelink
mkdir -p "$HSL/.claude/rules"
printf '%s\n@%s\n' "$rule_head" "$OVY/CLAUDE.md" > "$WORK/shared-rule.md"
cp "$WORK/shared-rule.md" "$WORK/shared-rule.orig"
ln -s "$WORK/shared-rule.md" "$HSL/.claude/rules/hov-stack-overlay.md"
HOV_STACK_OVERLAY=$OV HOME=$HSL bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-rulelink.log" 2>&1 || { cat "$WORK/run-ov-rulelink.log"; fail "setup over a symlinked rules file exited non-zero"; }
cmp -s "$WORK/shared-rule.md" "$WORK/shared-rule.orig" || fail "setup wrote through a rules file that is a symlink"
bk=("$HSL"/.hov-stack-backups/*/.claude/rules/hov-stack-overlay.md)
[ -L "${bk[0]}" ] && [ "$(readlink "${bk[0]}")" = "$WORK/shared-rule.md" ] || fail "the symlinked rules file was not moved to the backup"
RSL=$HSL/.claude/rules/hov-stack-overlay.md
[ -f "$RSL" ] && [ ! -L "$RSL" ] && [ "$(sed -n 2p "$RSL")" = "@$OV/CLAUDE.md" ] || fail "the symlinked rules file was not replaced by setup's import"
ok "a rules file that is a symlink, even one that reads like setup's own, is moved to the backup and replaced; the file it points at is unchanged"
# A rules/ that is a symlink leads into another tree: setup writes nothing there and names the
# line to add, --check is green once a rules file there has it, and an import setup wrote there
# is left for its owner to remove.
HSR=$WORK/home-overlay-rulesdir
SR=$WORK/shared-rules
mkdir -p "$HSR/.claude" "$SR"
ln -s "$SR" "$HSR/.claude/rules"
dir_row="  overlay +missing +rules/ is a symlink, so \./setup writes no import into it: add the line @$OV/CLAUDE\.md to a rules file there"
HOV_STACK_OVERLAY=$OV HOME=$HSR bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-rulesdir.log" 2>&1 || { cat "$WORK/run-ov-rulesdir.log"; fail "setup with a symlinked rules/ exited non-zero"; }
[ -z "$(ls -A "$SR")" ] || fail "setup wrote into a rules/ that is a symlink: $(ls -A "$SR")"
grep -q -x -E "$dir_row" "$WORK/run-ov-rulesdir.log" || { cat "$WORK/run-ov-rulesdir.log"; fail "the run did not name the line to add under a symlinked rules/"; }
rc=0; HOV_STACK_OVERLAY=$OV HOME=$HSR bash "$ROOT/setup" --check --no-dcg > "$WORK/check-ov-rulesdir.log" 2>&1 || rc=$?
grep -q -x -E "$dir_row" "$WORK/check-ov-rulesdir.log" || { cat "$WORK/check-ov-rulesdir.log"; fail "--check did not name the line to add under a symlinked rules/"; }
printf '# mine\n@%s\n' "$OV/CLAUDE.md" > "$SR/mine.md"
rc=0; HOV_STACK_OVERLAY=$OV HOME=$HSR bash "$ROOT/setup" --check --no-dcg > "$WORK/check-ov-rulesdir2.log" 2>&1 || rc=$?
grep -q -E "^  overlay +ok +$OV: .*CLAUDE\.md imported by a rules file under rules/, a symlink" "$WORK/check-ov-rulesdir2.log" \
  || { cat "$WORK/check-ov-rulesdir2.log"; fail "--check did not see the import in a rules file under a symlinked rules/"; }
rm "$SR/mine.md"
printf '%s\n@%s\n' "$rule_head" "$OV/CLAUDE.md" > "$SR/hov-stack-overlay.md"
OVN=$WORK/overlay-no-claude
mkdir -p "$OVN"
printf 'OVERLAY_PROBE=x\n' > "$OVN/env"
HOV_STACK_OVERLAY=$OVN HOME=$HSR bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-rulesdir3.log" 2>&1 || { cat "$WORK/run-ov-rulesdir3.log"; fail "setup with a symlinked rules/ and no CLAUDE.md exited non-zero"; }
[ -f "$SR/hov-stack-overlay.md" ] || fail "setup removed a rules file through a rules/ that is a symlink"
grep -q -x -E "  overlay +missing +rules/ is a symlink, so \./setup leaves rules/hov-stack-overlay\.md, which imports $OV/CLAUDE\.md, for you to remove" "$WORK/run-ov-rulesdir3.log" \
  || { cat "$WORK/run-ov-rulesdir3.log"; fail "the run did not say it left the import under a symlinked rules/"; }
ok "a symlinked rules/ gets nothing written or removed: setup names the line to add, --check is green once a rules file there has it, and an old import there is left for its owner"

# env: claude-env.sh, sourced before every Bash call, exports the overlay's assignments.
probe='. "$1"; sh -c "printf %s \"\$OVERLAY_PROBE\""'
envsh=$HF3/.claude/claude-env.sh
[ "$(HOV_STACK_OVERLAY=$OV bash -c "$probe" _ "$envsh" 2>&1)" = from-overlay ] || fail "claude-env.sh did not export the overlay env"
mkdir -p "$WORK/xdg/hov-stack" "$WORK/home-envdefault/.config/hov-stack"
printf 'OVERLAY_PROBE=from-xdg\n' > "$WORK/xdg/hov-stack/env"
printf 'OVERLAY_PROBE=from-default\n' > "$WORK/home-envdefault/.config/hov-stack/env"
[ "$(XDG_CONFIG_HOME=$WORK/xdg bash -c "$probe" _ "$envsh" 2>&1)" = from-xdg ] || fail "claude-env.sh did not read \$XDG_CONFIG_HOME/hov-stack/env"
[ "$(HOME=$WORK/home-envdefault bash -c "$probe" _ "$envsh" 2>&1)" = from-default ] || fail "claude-env.sh did not read ~/.config/hov-stack/env"
[ -z "$(HOME=$WORK/home-noenv bash -c "$probe; case \$- in *a*) echo allexport-on;; esac" _ "$envsh" 2>&1)" ] || fail "claude-env.sh without an overlay set or printed something"
[ "$(HOV_STACK_OVERLAY=$OV bash -c 'set -a; . "$1"; case $- in *a*) printf on;; *) printf off;; esac' _ "$envsh" 2>&1)" = on ] \
  || fail "claude-env.sh turned off an allexport its caller had on"
ok "claude-env.sh exports the overlay env from HOV_STACK_OVERLAY, XDG_CONFIG_HOME or ~/.config, leaves a caller's allexport alone, and without an overlay sets and prints nothing"
mkdir -p "$WORK/relcwd/xdgrel/hov-stack"
printf 'OVERLAY_PROBE=from-relative-xdg\n' > "$WORK/relcwd/xdgrel/hov-stack/env"
[ -z "$(cd "$WORK/relcwd" && HOV_STACK_OVERLAY=ovrel bash -c "$probe" _ "$envsh" 2>&1)" ] || fail "claude-env.sh read the env of a relative HOV_STACK_OVERLAY"
[ "$(cd "$WORK/relcwd" && XDG_CONFIG_HOME=xdgrel HOME=$WORK/home-envdefault bash -c "$probe" _ "$envsh" 2>&1)" = from-default ] \
  || fail "claude-env.sh did not ignore a relative XDG_CONFIG_HOME for ~/.config/hov-stack"
ok "claude-env.sh reads no env through a relative HOV_STACK_OVERLAY, and ignores a relative XDG_CONFIG_HOME for ~/.config"
OVB=$WORK/overlay-bad-env
mkdir -p "$OVB"
printf 'OVERLAY_PROBE=(\n' > "$OVB/env"
rc=0; HOV_STACK_OVERLAY=$OVB HOME=$WORK/home-ov-badenv bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-badenv.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-ov-badenv.log"; fail "an overlay env that does not parse made setup exit $rc"; }
grep -q -E "^  overlay +invalid +$OVB/env does not parse under bash \(.+\); claude-env\.sh sources it before every Bash call$" "$WORK/run-ov-badenv.log" \
  || { cat "$WORK/run-ov-badenv.log"; fail "an overlay env that does not parse was not named"; }
rc=0; HOV_STACK_OVERLAY=$OVB HOME=$WORK/home-ov-badenv bash "$ROOT/setup" --check --no-dcg > "$WORK/check-ov-badenv.log" 2>&1 || rc=$?
grep -q -E "^  overlay +invalid +$OVB/env does not parse under bash " "$WORK/check-ov-badenv.log" || { cat "$WORK/check-ov-badenv.log"; fail "--check did not name the overlay env that does not parse"; }
ok "an overlay env that does not parse is named by the run, without failing it, and by --check"

# An overlay settings.json that is not a JSON object: no seed, a failed row, and the rest of
# the run goes on.
OVJ=$WORK/overlay-bad-json
mkdir -p "$OVJ"
printf '{ "model":\n' > "$OVJ/settings.json"
rc=0; HOV_STACK_OVERLAY=$OVJ HOME=$WORK/home-ov-badjson bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-badjson.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/run-ov-badjson.log"; fail "an overlay settings.json that is not JSON exited $rc, not 1"; }
grep -q -F "settings-seed: the overlay $OVJ/settings.json is not readable JSON" "$WORK/run-ov-badjson.log" || { cat "$WORK/run-ov-badjson.log"; fail "the bad overlay settings.json was not named"; }
grep -q -E '^  settings +failed +lib/settings-seed\.js wrote no seed' "$WORK/run-ov-badjson.log" || fail "the refused seed has no 'settings failed' row"
grep -q -E "^  overlay +invalid +$OVJ/settings\.json is not a JSON object \(.+\), so \./setup writes no seed$" "$WORK/run-ov-badjson.log" \
  || { cat "$WORK/run-ov-badjson.log"; fail "the overlay row does not name the bad settings.json"; }
[ ! -e "$WORK/home-ov-badjson/.claude/settings.json" ] || fail "a seed was written from a bad overlay"
[ -L "$WORK/home-ov-badjson/.claude/hooks" ] && grep -q -F 'hov-stack: status' "$WORK/run-ov-badjson.log" || fail "a bad overlay stopped the links or cut the run short"
printf '[1]\n' > "$OVJ/settings.json"
rc=0; HOV_STACK_OVERLAY=$OVJ HOME=$WORK/home-ov-array bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-array.log" 2>&1 || rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/home-ov-array/.claude/settings.json" ] || { cat "$WORK/run-ov-array.log"; fail "an overlay settings.json that is a JSON array was merged"; }
grep -q -x -F "settings-seed: the overlay $OVJ/settings.json is not a JSON object; no seed was written" "$WORK/run-ov-array.log" \
  || { cat "$WORK/run-ov-array.log"; fail "an overlay settings.json that is a JSON array was not named as not an object"; }
ok "an overlay settings.json that is not a JSON object writes no seed and exits 1 with a 'settings failed' row; the links still go in"
# A setting given another kind of value than the template's: no seed, the reason named, and
# the run exits 1 with the overlay row failed.
OVK=$WORK/overlay-kind
mkdir -p "$OVK"
printf '{ "permissions": "x" }\n' > "$OVK/settings.json"
rc=0; HOV_STACK_OVERLAY=$OVK HOME=$WORK/home-ov-kind bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-kind.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/run-ov-kind.log"; fail "an overlay giving permissions a string exited $rc, not 1"; }
grep -q -x -F "settings-seed: the overlay $OVK/settings.json gives permissions a plain value where the template has an object; no seed was written" "$WORK/run-ov-kind.log" \
  || { cat "$WORK/run-ov-kind.log"; fail "the refused setting was not named"; }
grep -q -E '^  settings +failed +lib/settings-seed\.js wrote no seed' "$WORK/run-ov-kind.log" || fail "the refused seed has no 'settings failed' row"
grep -q -x -E "  overlay +failed +$OVK/settings\.json was not merged: lib/settings-seed\.js wrote no seed \(see above\)" "$WORK/run-ov-kind.log" \
  || { cat "$WORK/run-ov-kind.log"; fail "the overlay row does not say the settings.json was not merged"; }
[ ! -e "$WORK/home-ov-kind/.claude/settings.json" ] || fail "a seed was written from an overlay giving a setting another kind of value"
! grep -q -F '    kept:' "$WORK/run-ov-kind.log" || fail "a refused overlay still printed a seed summary"
ok "an overlay giving a setting another kind of value writes no seed, names it, and exits 1 with the settings and overlay rows failed"

# The default location, with neither variable set, and the XDG one.
HD=$WORK/home-ov-default
mkdir -p "$HD/.config/hov-stack"
printf '{ "model": "default-location" }\n' > "$HD/.config/hov-stack/settings.json"
HOME=$HD bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-default.log" 2>&1 || { cat "$WORK/run-ov-default.log"; fail "setup with an overlay at the default location exited non-zero"; }
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).model === "default-location" ? 0 : 1)' "$HD/.claude/settings.json" \
  || fail "the overlay at ~/.config/hov-stack was not read"
XDG_CONFIG_HOME=$WORK/xdg HOME=$WORK/home-ov-xdg bash "$ROOT/setup" --no-dcg > "$WORK/run-ov-xdg.log" 2>&1 || { cat "$WORK/run-ov-xdg.log"; fail "setup with an XDG overlay exited non-zero"; }
grep -q -E "^  overlay +ok +$WORK/xdg/hov-stack: env read before each Bash call$" "$WORK/run-ov-xdg.log" || { cat "$WORK/run-ov-xdg.log"; fail "the overlay under XDG_CONFIG_HOME was not found"; }
ok "setup finds the overlay at ~/.config/hov-stack and under XDG_CONFIG_HOME"
# Only an absolute overlay path counts. A relative HOV_STACK_OVERLAY is named and read by
# nothing, even from a directory where it names an overlay; a relative XDG_CONFIG_HOME is
# ignored, as the XDG spec says, for ~/.config.
HR=$WORK/home-ov-rel
rc=0; (cd "$WORK/relcwd" && HOV_STACK_OVERLAY=ovrel HOME=$HR bash "$ROOT/setup" --no-dcg) > "$WORK/run-ov-rel.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/run-ov-rel.log"; fail "setup with a relative HOV_STACK_OVERLAY exited $rc"; }
grep -q -x -E "$rel_row" "$WORK/run-ov-rel.log" || { cat "$WORK/run-ov-rel.log"; fail "the run did not name the relative HOV_STACK_OVERLAY"; }
[ ! -e "$HR/.claude/rules" ] || fail "a relative HOV_STACK_OVERLAY got an import"
node -e 'process.exit("model" in JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")) ? 1 : 0)' "$HR/.claude/settings.json" \
  || fail "a relative HOV_STACK_OVERLAY was merged into the seed"
HX=$WORK/home-ov-relxdg
mkdir -p "$HX/.config/hov-stack"
printf '{ "model": "relative-xdg" }\n' > "$WORK/relcwd/xdgrel/hov-stack/settings.json"
printf '{ "model": "home-default" }\n' > "$HX/.config/hov-stack/settings.json"
(cd "$WORK/relcwd" && XDG_CONFIG_HOME=xdgrel HOME=$HX bash "$ROOT/setup" --no-dcg) > "$WORK/run-ov-relxdg.log" 2>&1 || { cat "$WORK/run-ov-relxdg.log"; fail "setup with a relative XDG_CONFIG_HOME exited non-zero"; }
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).model === "home-default" ? 0 : 1)' "$HX/.claude/settings.json" \
  || fail "a relative XDG_CONFIG_HOME was not ignored for ~/.config/hov-stack"
ok "a relative HOV_STACK_OVERLAY is named and read by nothing, and a relative XDG_CONFIG_HOME is ignored for ~/.config"
# Own plugin folders use manifest names and never adopt unrelated skills (#476).
OSP=$WORK/overlay-skill-plugins
HSP=$WORK/home-skill-plugins
FSP=$WORK/fake-skill-plugins
P1=$WORK/folder-basename
mkdir -p "$OSP" "$P1/.claude-plugin" "$P1/skills/alpha" "$HSP/.claude/skills/foreign" "$WORK/foreign-target"
printf '{"name":"my-skills"}\n' > "$P1/.claude-plugin/plugin.json"
printf '# alpha\n' > "$P1/skills/alpha/SKILL.md"
printf '# foreign\n' > "$HSP/.claude/skills/foreign/SKILL.md"
printf 'note\n' > "$HSP/.claude/skills/note.md"
ln -s "$WORK/foreign-target" "$HSP/.claude/skills/foreign-link"
printf '  %s # comment, no final newline' "$P1" > "$OSP/skill-plugins"
new_fake "$FSP" 2.1.310
printf 'my-skills@skills-dir\n' > "$FSP/skills-dir"
HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-run.log" --no-dcg || { cat "$WORK/sp-run.log"; fail 'plugin setup failed'; }
[ "$(readlink -f "$HSP/.claude/skills/my-skills")" = "$P1" ] || fail 'plugin link does not use manifest name'
grep -Eq '^  skill-plugins +ok ' "$WORK/sp-run.log" || fail 'plugin row not ok'
[ "$(cat "$HSP/.claude/skills/foreign/SKILL.md")" = '# foreign' ] || fail 'foreign skill changed'
[ "$(cat "$HSP/.claude/skills/note.md")" = note ] || fail 'foreign file changed'
[ "$(readlink "$HSP/.claude/skills/foreign-link")" = "$WORK/foreign-target" ] || fail 'foreign link changed'
[ ! -e "$HSP/.hov-stack-backups" ] || fail 'foreign entries backed up'
before=$(tree_state "$HSP/.claude/skills")
HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-rerun.log" --no-dcg || fail 'plugin rerun failed'
[ "$before" = "$(tree_state "$HSP/.claude/skills")" ] || fail 'plugin rerun changed skills tree'
[ ! -e "$HSP/.hov-stack-backups" ] || fail 'plugin rerun made a backup'
before=$(tree_state "$HSP")
HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-green.log" --check --no-dcg || { cat "$WORK/sp-green.log"; fail 'plugin check not green'; }
[ "$before" = "$(tree_state "$HSP")" ] || fail 'green check changed tree'
mkdir "$P1/skills/my-skills"
printf '# self\n' > "$P1/skills/my-skills/SKILL.md"
HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-self.log" --check --no-dcg || { cat "$WORK/sp-self.log"; fail 'an inner skill named like its plugin was reported as a clash with its own link'; }
rm "$P1/skills/my-skills/SKILL.md"
rmdir "$P1/skills/my-skills"
ok 'own plugin linked by manifest name, rerun stable, unrelated entries left alone, an inner skill may share the plugin name'

sp_check_bad() {
  local needle=$1 before rc=0
  before=$(tree_state "$HSP")
  HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-check.log" --check --no-dcg || rc=$?
  [ "$rc" = 1 ] || { cat "$WORK/sp-check.log"; fail "plugin check expected 1: $needle"; }
  grep -F "$needle" "$WORK/sp-check.log" >/dev/null || { cat "$WORK/sp-check.log"; fail "plugin check missing: $needle"; }
  [ "$before" = "$(tree_state "$HSP")" ] || fail 'plugin check changed tree'
}
rm "$HSP/.claude/skills/my-skills"
sp_check_bad 'skills/my-skills is not linked: run ./setup'
ln -s "$WORK/foreign-target" "$HSP/.claude/skills/my-skills"
sp_check_bad 'skills/my-skills points at'
HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-relink.log" --no-dcg || fail 'wrong plugin link not replaced'
[ ! -e "$HSP/.hov-stack-backups" ] || fail 'wrong link backed up'
rm "$HSP/.claude/skills/my-skills"
mkdir "$HSP/.claude/skills/my-skills"
printf 'keep\n' > "$HSP/.claude/skills/my-skills/keep"
sp_check_bad 'which moves it to the backup first'
HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$HSP" "$WORK/sp-adopt.log" --no-dcg || fail 'plugin folder not adopted'
bk=("$HSP"/.hov-stack-backups/*/.claude/skills/my-skills/keep)
[ "$(cat "${bk[0]}")" = keep ] || fail 'plugin folder data not backed up'
mkdir "$HSP/.claude/skills/alpha"
printf '# plain\n' > "$HSP/.claude/skills/alpha/SKILL.md"
sp_check_bad "skills/alpha shares the bare name /alpha with my-skills's skill (which one /alpha runs is not established)"
rm "$HSP/.claude/skills/alpha/SKILL.md"
rmdir "$HSP/.claude/skills/alpha"
cp "$HSP/.claude/settings.json" "$WORK/sp-settings.json"
node -e 'const fs=require("fs"),p=process.argv[1],x=JSON.parse(fs.readFileSync(p)); x.enabledPlugins["my-skills@skills-dir"]=false; fs.writeFileSync(p,JSON.stringify(x))' "$HSP/.claude/settings.json"
sp_check_bad 'my-skills@skills-dir is turned off in settings.json'
cp "$WORK/sp-settings.json" "$HSP/.claude/settings.json"
: > "$FSP/skills-dir"
sp_check_bad 'Claude Code does not list my-skills@skills-dir'
ok 'plugin check names missing/wrong/real links, shared names, disabled and unlisted plugins without writes'

# Each refusal coexists with a valid entry, which must still link.
pack_name=$(basename "$(printf '%s\n' "$copy"/plugins/hov-stack/skills/*/ | head -1)")
default_name=$(awk '!/^#/ && NF {print $1; exit}' "$copy/lib/default-plugin-skills.txt")
retired_name=$(awk '!/^#/ && NF {print $1; exit}' "$copy/retired-skills.txt")
market_name=$(node -e 'console.log(require(process.argv[1]).plugins[0].name)' "$copy/.claude-plugin/marketplace.json")
mod_manifest=$(printf '%s\n' "$copy"/mods/*/.claude-plugin/plugin.json | head -1)
mod_name=$(node -e 'console.log(require(process.argv[1]).name)' "$mod_manifest")
for kind in relative absent manifest json object invalid-name pack default retired synced marketplace mod duplicate overlay-retired; do
  badpath=$WORK/sp-bad-$kind
  reason="" name=bad-skills
  mkdir -p "$badpath/.claude-plugin"
  case $kind in
    relative) badpath=relative/plugin; reason='not an absolute path' ;;
    absent) badpath=$WORK/does-not-exist; reason='no folder there' ;;
    manifest) reason='no .claude-plugin/plugin.json' ;;
    json) printf 'not json\n' > "$badpath/.claude-plugin/plugin.json"; reason='JSON object with a valid name' ;;
    object) printf '[]\n' > "$badpath/.claude-plugin/plugin.json"; reason='JSON object with a valid name' ;;
    invalid-name) name='../bad'; reason='JSON object with a valid name' ;;
    pack) name=$pack_name; reason='skill-pack' ;;
    default) name=$default_name; reason='default-plugin-skills.txt' ;;
    retired) name=$retired_name; reason='retired-skills.txt' ;;
    synced) name=synced; reason='synced' ;;
    marketplace) name=$market_name; reason='marketplace' ;;
    mod) name=$mod_name; reason='mods' ;;
    duplicate) name=my-skills; reason='earlier accepted entry' ;;
    overlay-retired) name=old-own; reason='retired-skills.txt'; printf 'old-own # retired\n' > "$OSP/retired-skills.txt" ;;
  esac
  case $kind in relative|absent|manifest|json|object) ;; *) printf '{"name":"%s"}\n' "$name" > "$badpath/.claude-plugin/plugin.json" ;; esac
  printf '%s\n%s\n' "$P1" "$badpath" > "$OSP/skill-plugins"
  rc=0
  hp=$WORK/home-sp-refuse-$kind
  HOV_STACK_OVERLAY=$OSP fake_setup "$FSP" "$hp" "$WORK/sp-refuse.log" --no-dcg || rc=$?
  [ "$rc" = 1 ] || { cat "$WORK/sp-refuse.log"; fail "refusal $kind exited $rc"; }
  grep -F "skill-plugins: refused $badpath:" "$WORK/sp-refuse.log" | grep -F "$reason" >/dev/null || { cat "$WORK/sp-refuse.log"; fail "refusal $kind missing reason"; }
  [ "$(readlink -f "$hp/.claude/skills/my-skills")" = "$P1" ] || fail "refusal $kind prevented valid link"
  [ ! -e "$hp/.claude/skills/bad-skills" ] || fail "refused $kind linked"
done
ok 'plugin refusals name all conflicting lists and invalid paths/manifests, and valid entries still link'

# A missing fixed source is not a successful setup link.
missing_copy=$WORK/missing-source-copy
cp -a "$copy" "$missing_copy"
rm "$missing_copy/memory-dream.json"
rc=0
HOME=$WORK/home-sp-missing HOV_STACK_OVERLAY=$WORK/no-overlay bash "$missing_copy/setup" --no-dcg > "$WORK/sp-missing.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail 'missing setup source did not fail'
grep -Eq '^  links +failed ' "$WORK/sp-missing.log" || fail 'missing source links row not failed'
grep -F "skip (source missing): $missing_copy/memory-dream.json" "$WORK/sp-missing.log" >/dev/null || fail 'missing source not named'
if grep -F 'links in place' "$WORK/sp-missing.log"; then fail 'missing source claimed links in place'; fi
ok 'missing setup source fails the link row and the run'

# The tracked examples are overlays that work as they stand.
node "$ROOT/lib/settings-seed.js" "$ROOT/settings.json" "$WORK/seed-example.json" "$WORK/cfg-example" "$WORK/home-example" "" "$ROOT/config/settings.example.json" > "$WORK/seed-example.log" \
  || { cat "$WORK/seed-example.log"; fail "config/settings.example.json is refused as an overlay"; }
! grep -q -F '$HOME/' "$WORK/seed-example.json" || fail "config/settings.example.json leaves an unrendered \$HOME/ in the seed"
bash -n "$ROOT/config/env.example" || fail "config/env.example does not parse under bash"
[ -s "$ROOT/config/CLAUDE.example.md" ] || fail "config/CLAUDE.example.md is empty"
ok "config/settings.example.json merges as an overlay with every path rendered, and config/env.example parses"
# lib/settings-seed.js on a small template, case by case. The overlay spells two of the
# template's entries with the rendered path, repeats a new one, copies the dcg hook, adds a
# second dcg hook, nests nulls under a key the template lacks, and names __proto__.
U=$WORK/seed-unit
mkdir -p "$U"
cat > "$U/template.json" <<'EOF'
{
  "permissions": { "allow": ["Read($HOME/.claude/notes/**)", "Read($HOME/.cache/**)", "Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$HOME/.local/bin/dcg" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "sh $HOME/.claude/hooks/a.sh" } ] }
    ]
  },
  "env": { "API_TIMEOUT_MS": "5" }
}
EOF
cat > "$U/overlay.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(ls:*)", "Read(CFG/notes/**)", "Read(HOMEDIR/.cache/**)", "Bash(new:*)", "Bash(new:*)"],
    "ask": ["x", null]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$HOME/.local/bin/dcg" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "sh CFG/hooks/a.sh" } ] },
      { "matcher": "Edit", "hooks": [ { "type": "command", "command": "$HOME/.local/bin/dcg --edit" } ] }
    ]
  },
  "sandbox": { "enabled": null, "network": { "allow": null, "deny": ["x"] } },
  "statusLine": null,
  "__proto__": { "polluted": true }
}
EOF
node -e '
  const fs = require("fs"), { spawnSync } = require("child_process");
  const [seedJs, u] = process.argv.slice(1);
  const cfg = u + "/cfg", home = u + "/home", dcg = u + "/bin/dcg", tpl = u + "/template.json";
  const bad = [];
  const want = (c, m) => { if (!c) bad.push(m); };
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const run = (name, dcgPath, overlay) => {
    const dst = `${u}/seed-${name}.json`;
    const r = spawnSync(process.execPath, [seedJs, tpl, dst, cfg, home, dcgPath, overlay], { encoding: "utf8" });
    const seed = fs.existsSync(dst) ? JSON.parse(fs.readFileSync(dst, "utf8")) : null;
    return { status: r.status, out: r.stdout, err: r.stderr, seed };
  };
  const ov = u + "/overlay-rendered.json";
  fs.writeFileSync(ov, fs.readFileSync(u + "/overlay.json", "utf8").split("CFG/").join(cfg + "/").split("HOMEDIR/").join(home + "/"));

  const a = run("no-dcg", "", ov);
  want(a.status === 0, `the merge without dcg exited ${a.status}: ${a.err}`);
  const s = a.seed || {};
  want(same(s.permissions?.allow, [`Read(${cfg}/notes/**)`, `Read(${home}/.cache/**)`, "Bash(ls:*)", "Bash(new:*)"]),
    "permissions.allow is not the template list plus the one new rule (an entry spelled with the rendered path, or repeated, went in twice): " + JSON.stringify(s.permissions?.allow));
  want(same(s.permissions?.ask, ["x", null]), "a null in an overlay list was not kept as a value: " + JSON.stringify(s.permissions?.ask));
  want(same(s.hooks, { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: `sh ${cfg}/hooks/a.sh` }] }] }),
    "without dcg, the hooks are not the a.sh hook alone (both dcg hooks dropped, the overlay copy of a.sh deduped): " + JSON.stringify(s.hooks));
  want(a.out.includes("    dropped hook entries needing dcg: 2\n"), "without dcg, the two dcg hooks were not counted dropped: " + a.out);
  want(same(s.sandbox, { network: { deny: ["x"] } }), "the nulls under a key the template lacks were written: " + JSON.stringify(s.sandbox));
  want(!Object.hasOwn(s, "statusLine"), "a null for a key the template lacks was written");
  want(Object.hasOwn(s, "__proto__") && same(s["__proto__"], { polluted: true }), "the overlay key __proto__ was not kept as an own key");
  want(a.out.includes(`    from the overlay ${ov}: permissions.allow +1, permissions.ask, hooks.PreToolUse +1, sandbox, __proto__\n`),
    "the report does not name exactly what the overlay added: " + a.out);

  const b = run("dcg", dcg, ov);
  want(b.status === 0, `the merge with dcg exited ${b.status}: ${b.err}`);
  const cmds = (b.seed?.hooks?.PreToolUse || []).flatMap((g) => g.hooks.map((h) => h.command));
  want(same(cmds, [dcg, `sh ${cfg}/hooks/a.sh`, `${dcg} --edit`]),
    "with dcg, the hooks are not the dcg hook once, a.sh, and the overlay dcg hook, each dcg one at the dcg path: " + JSON.stringify(cmds));
  want(!b.out.includes("dropped hook entries needing dcg"), "with dcg, a dcg hook was dropped");

  const kinds = [
    [`{"permissions": "x"}`, "permissions a plain value where the template has an object"],
    [`{"hooks": []}`, "hooks a list where the template has an object"],
    [`{"permissions": {"allow": "Read"}}`, "permissions.allow a plain value where the template has a list"],
    [`{"permissions": {"allow": {"x": 1}}}`, "permissions.allow an object where the template has a list"],
    [`{"env": {"API_TIMEOUT_MS": {"a": 1}}}`, "env.API_TIMEOUT_MS an object where the template has a plain value"],
    [`{"env": {"API_TIMEOUT_MS": ["1"]}}`, "env.API_TIMEOUT_MS a list where the template has a plain value"],
  ];
  kinds.forEach(([text, says], i) => {
    const p = `${u}/kind-${i}.json`;
    fs.writeFileSync(p, text + "\n");
    const r = run(`kind-${i}`, "", p);
    want(r.status === 1 && r.seed === null && r.out === "" && r.err === `settings-seed: the overlay ${p} gives ${says}; no seed was written\n`,
      `the overlay ${text} was not refused with "${says}" and no seed: status ${r.status}, stdout ${JSON.stringify(r.out)}, stderr ${JSON.stringify(r.err)}`);
  });
  if (bad.length) { console.log(bad.join("\n")); process.exit(1); }
' "$ROOT/lib/settings-seed.js" "$U" || fail "lib/settings-seed.js on the small template is wrong (above)"
ok "settings-seed.js dedups across \$HOME/ and rendered spellings and within the overlay, gives the overlay's dcg hooks the template's rule, prunes nulls under a new key but keeps one in a list, keeps __proto__ as an own key, and refuses another kind of value in all six directions"

# ./setup --update (G2c, part 3 of #395). Nothing here touches the network or the real HOME:
# the upstream is a bare repository under $WORK, claude and uv are stand-ins that record their
# calls, and the program releases are file:// tarballs served through HOV_SETUP_RELEASE_TABLE
# by a curl that accepts only file:// URLs.
UP=$WORK/upd
mkdir -p "$UP/rel" "$WORK/uv-bin" "$WORK/file-curl"
IRS=$ROOT/plugins/hov-stack/skills/hov-setup/scripts/install-release.sh
gitc() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
cat > "$WORK/uv-bin/uv" <<'EOF'
#!/usr/bin/env bash
# A stand-in for uv: records calls in $FAKE_UV/calls, serves `tool list` and `tool dir` from
# fixtures there, and on `tool install ... git+URL@TAG` rewrites that tool's uv-receipt.toml the
# way uv does, with the revision in the git URL's query.
if [ "${1:-}" = --version ]; then echo "uv 0.0.0-fake"; exit 0; fi
F=${FAKE_UV:?}
printf '%s\n' "$*" >> "$F/calls"
case "$*" in
  'tool list') cat "$F/list" ;;
  'tool dir') echo "$F/tools" ;;
  'tool upgrade '?*) [ $# -eq 3 ] || exit 64; echo "Nothing to upgrade" ;;
  'tool install '*)
    last=${!#}
    case $last in
      git+*@*)
        url=${last#git+}; tag=${url##*@}; url=${url%@*}; name=${url##*/}
        mkdir -p "$F/tools/$name"
        printf 'requirements = [{ name = "%s", git = "%s?rev=%s" }]\n' "$name" "$url" "$tag" > "$F/tools/$name/uv-receipt.toml" ;;
    esac
    echo "Installed $last" ;;
  *) echo "fake uv: unexpected call: $*" >&2; exit 64 ;;
esac
EOF
cat > "$WORK/file-curl/curl" <<'EOF'
#!/usr/bin/env bash
out= url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    --retry|--connect-timeout) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
case $url in
  file://*) cp "${url#file://}" "$out" ;;
  *) echo "file-curl: $url is not a file:// URL" >&2; exit 6 ;;
esac
EOF
chmod +x "$WORK/uv-bin/uv" "$WORK/file-curl/curl"

# A release tarball of <tool> <version> and its row for HOV_SETUP_RELEASE_TABLE. The program
# prints "<tool> <version>"; uv's is the stand-in above.
mk_release() {
  local t=$1 v=$2 d=$UP/rel/$1-$2
  # Built once: a rebuild changes the archive's bytes (gzip and file times) and so its checksum.
  if [ ! -f "$UP/rel/$t-$v.tar.gz" ]; then
    mkdir -p "$d"
    if [ "$t" = uv ]; then cp "$WORK/uv-bin/uv" "$d/uv"; else printf '#!/bin/sh\necho "%s %s"\n' "$t" "$v" > "$d/$t"; fi
    chmod +x "$d/$t"
    tar -czf "$UP/rel/$t-$v.tar.gz" -C "$d" "$t"
  fi
  printf '%s|%s|linux-x86_64|file://%s|%s|%s\n' "$t" "$v" "$UP/rel/$t-$v.tar.gz" "$(sha256sum < "$UP/rel/$t-$v.tar.gz" | cut -d' ' -f1)" "$t"
}
T_SEED=$(mk_release gh 1.0.0; mk_release uv 1.0.0; mk_release jsm 1.0.0)
T_NEW=$(mk_release gh 2.0.0; mk_release uv 1.0.0; mk_release cass 2.0.0; mk_release jsm 1.0.0)
# The same, but gh 2.0.0 has a wrong pinned checksum: install-release.sh exits 1 for it.
BAD_SHA=$(printf '0%.0s' $(seq 64))
T_BADGH=$(printf 'gh|2.0.0|linux-x86_64|file://%s|%s|gh\n' "$UP/rel/gh-2.0.0.tar.gz" "$BAD_SHA"; mk_release uv 1.0.0; mk_release cass 2.0.0; mk_release jsm 1.0.0)
seed_programs() {  # seed_programs <home>: gh, uv and jsm 1.0.0 installed by install-release.sh, cass placed by hand
  local t
  for t in gh uv jsm; do
    HOME=$1 HOV_SETUP_PLATFORM=linux-x86_64 HOV_SETUP_RELEASE_TABLE=$T_SEED PATH=$WORK/file-curl:$PATH bash "$IRS" "$t" > /dev/null \
      || fail "could not seed $t 1.0.0 into $1"
  done
  printf '#!/bin/sh\necho by-hand\n' > "$1/.local/bin/cass"
  chmod +x "$1/.local/bin/cass"
}

# The offered git-tag uv tool, read from offers.json so the pin can move without this test.
OFFER_LINE=$(node -e '
  const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).offers.find((x) => x.name === "synthetic-panel");
  console.log(o.install["linux-x86_64"].replace("<uv> ", ""));
' "$ROOT/plugins/hov-stack/skills/hov-setup/scripts/offers.json")
OFFER_REPO=$(printf '%s\n' "$OFFER_LINE" | sed -E 's/.*git\+(https:[^@]*)@.*/\1/')
OFFER_TAG=${OFFER_LINE##*@}
[ -n "$OFFER_REPO" ] && [ -n "$OFFER_TAG" ] && [ "$OFFER_REPO" != "$OFFER_LINE" ] || fail "could not read the synthetic-panel offer from offers.json"
# uv's receipt for synthetic-panel, in the shape uv writes (the revision in the git URL's query,
# as uv 0.13 does), except old-field, the separate rev field setup also reads.
new_uvstate() {  # new_uvstate <dir> <old-rev|old-field|same-rev|newer-tag|branch|no-ref|other-repo|pypi> [no-ast-grep]: uv knows ast-grep-cli (unless told not to), synthetic-panel and an unoffered tool
  mkdir -p "$1/tools/synthetic-panel"
  : > "$1/calls"
  printf 'synthetic-panel v0.0.9\n- synthetic-panel\nother-tool v1.0.0\n- other\n' > "$1/list"
  if [ "${3:-}" != no-ast-grep ]; then printf 'ast-grep-cli v0.40.0\n- ast-grep\n- sg\n' >> "$1/list"; fi
  case "$2" in
    old-rev) printf 'requirements = [{ name = "synthetic-panel", git = "%s?rev=v0.0.9" }]\n' "$OFFER_REPO" ;;
    old-field) printf 'requirements = [{ name = "synthetic-panel", git = "%s.git", rev = "v0.0.9" }]\n' "$OFFER_REPO" ;;
    same-rev) printf 'requirements = [{ name = "synthetic-panel", git = "%s?rev=%s" }]\n' "$OFFER_REPO" "$OFFER_TAG" ;;
    newer-tag) printf 'requirements = [{ name = "synthetic-panel", git = "%s?rev=v99.0.0" }]\n' "$OFFER_REPO" ;;
    branch) printf 'requirements = [{ name = "synthetic-panel", git = "%s?branch=main" }]\n' "$OFFER_REPO" ;;
    no-ref) printf 'requirements = [{ name = "synthetic-panel", git = "%s" }]\n' "$OFFER_REPO" ;;
    other-repo) printf 'requirements = [{ name = "synthetic-panel", git = "https://github.com/someone/synthetic-panel?rev=%s" }]\n' "$OFFER_TAG" ;;
    pypi) printf 'requirements = [{ name = "synthetic-panel" }]\n' ;;
  esac > "$1/tools/synthetic-panel/uv-receipt.toml"
}
# The fake claude's state for an --update run: hov not added yet (setup adds it), two other
# publishers' marketplaces listed (last30days with its plugin installed, codex without), a
# marketplace of the user's own, and sign-it and last30days installed.
new_update_fake() {  # new_update_fake <state dir>
  new_fake "$1" 2.1.310
  printf '%s\n' \
    '{"name":"last30days-skill","source":"github","repo":"mvanhorn/last30days-skill"}' \
    '{"name":"openai-codex","source":"github","repo":"openai/codex-plugin-cc"}' \
    '{"name":"mine","source":"github","repo":"someone/else"}' > "$1/extra"
  printf 'sign-it@hov 0.2.0 user\nlast30days@last30days-skill 3.0.0 user\nsomething@mine 1.0.0 user\n' >> "$1/plugins"
}
expected_update_calls() {  # the only update calls a full run may make, sorted
  {
    echo 'plugin marketplace update hov'
    echo 'plugin marketplace update last30days-skill'
    echo 'plugin marketplace update openai-codex'
    echo 'plugin update sign-it@hov --scope user'
    echo 'plugin update last30days@last30days-skill --scope user'
    default_names | while read -r p; do echo "plugin update $p@hov --scope user"; done
  } | LC_ALL=C sort
}
UPD_TABLE=
UPD_PATH=
upd_run() {  # upd_run <checkout> <home> <claude state dir> <uv state dir> <log> [setup args]: the checkout's setup --update
  local c=$1 h=$2 f=$3 u=$4 log=$5
  shift 5
  FAKE=$f FAKE_UV=$u HOME=$h HOV_SETUP_PLATFORM=linux-x86_64 HOV_SETUP_RELEASE_TABLE=$UPD_TABLE \
    PATH=${UPD_PATH:+$UPD_PATH:}$WORK/file-curl:$WORK/fake-bin:$PATH bash "$c/setup" --update --no-dcg "$@" > "$log" 2>&1
}

# --update and --check together are a usage error and change nothing.
rc=0; HOME=$UP/home-usage bash "$copy/setup" --update --check > "$WORK/upd-usage.log" 2>&1 || rc=$?
[ "$rc" = 2 ] || { cat "$WORK/upd-usage.log"; fail "--update --check exited $rc, not 2"; }
grep -q -F -- '--update changes things and --check changes nothing' "$WORK/upd-usage.log" || fail "--update --check did not say why"
[ ! -e "$UP/home-usage" ] || fail "--update --check still made files"
ok "--update with --check exits 2 and makes nothing"

# An upstream, a seed clone that pushes to it, and clones that stay one commit behind.
UPSTREAM=$UP/origin.git
SEED=$UP/seed
git init -q --bare "$UPSTREAM"
git -C "$UPSTREAM" symbolic-ref HEAD refs/heads/main
mkdir -p "$SEED"
(cd "$ROOT" && git ls-files -z | grep -z -v -E '^(tests|docs|release)/' | tar --null -T - -cf -) | tar -xf - -C "$SEED"
git init -q "$SEED"
git -C "$SEED" symbolic-ref HEAD refs/heads/main
gitc -C "$SEED" add -A
gitc -C "$SEED" commit -q -m seed
git -C "$SEED" remote add origin "$UPSTREAM"
git -C "$SEED" push -q origin main
C0=$(git -C "$SEED" rev-parse HEAD)
for c in a s1 s2 s3 dv dt nu lc; do git clone -q "$UPSTREAM" "$UP/clone-$c"; done
# The README's install is a shallow clone; a local path ignores --depth, a file:// URL does not.
git clone -q --depth 1 "file://$UPSTREAM" "$UP/clone-sh"
[ "$(git -C "$UP/clone-sh" rev-parse --is-shallow-repository)" = true ] || fail "the shallow clone is not shallow"
# The commit the clones lack: the new setup says so as its first output line.
awk '{ print } /^set -euo pipefail$/ && !d { print "echo NEWER-SETUP-MARKER"; d = 1 }' "$SEED/setup" > "$SEED/setup.new"
mv "$SEED/setup.new" "$SEED/setup"
chmod +x "$SEED/setup"
gitc -C "$SEED" commit -q -am "newer setup"
git -C "$SEED" push -q origin main
C1=$(git -C "$SEED" rev-parse HEAD)
[ "$C0" != "$C1" ] || fail "the upstream did not move"

# 1. Fast-forward, then the new setup runs the rest: gh, uv, cass and jsm through
#    install-release.sh, the uv tools, the marketplaces and the plugins.
HA=$UP/home-a
FA=$UP/fake-a
UA=$UP/uv-a
new_update_fake "$FA"
new_uvstate "$UA" old-rev
mkdir -p "$HA/.local/bin"
seed_programs "$HA"
UPD_TABLE=$T_NEW
UPD_PATH=$HA/.local/bin
rc=0; upd_run "$UP/clone-a" "$HA" "$FA" "$UA" "$WORK/upd-a.log" || rc=$?
sed 's/^/    | /' "$WORK/upd-a.log"
[ "$rc" = 0 ] || fail "setup --update exited $rc"
[ "$(git -C "$UP/clone-a" rev-parse HEAD)" = "$C1" ] || fail "the checkout did not fast-forward to the upstream"
[ "$(grep -c -x -F NEWER-SETUP-MARKER "$WORK/upd-a.log")" = 1 ] || fail "the new setup did not run exactly once after the pull"
grep -q -x -F "hov-stack: ${C0:0:7} -> ${C1:0:7}" "$WORK/upd-a.log" || fail "the new setup did not say which commits it moved between"
grep -q -E "^  checkout +ok +updated ${C0:0:7} -> ${C1:0:7}\$" "$WORK/upd-a.log" || fail "no checkout row for the move"
[ "$(sed -n '1p' "$WORK/upd-a.log")" = "hov-stack: fetching origin/main" ] || fail "the old setup did not fetch first"
ok "--update fast-forwards the checkout and runs the new setup (it printed its marker once and the move ${C0:0:7} -> ${C1:0:7})"
got=$(grep -E '^plugin (marketplace )?update ' "$FA/calls" | LC_ALL=C sort)
[ "$got" = "$(expected_update_calls)" ] || { diff <(expected_update_calls) <(printf '%s\n' "$got") || true; fail "the update calls are not exactly the offered marketplaces and installed plugins"; }
! grep -q -E ' -y|--accept-command|-y$' "$FA/calls" || fail "a claude call carried -y or --accept-command"
! grep -q -x -E 'plugin marketplace update' "$FA/calls" || fail "the bare marketplace update was called"
grep -q -x -F 'plugin install papercut@hov --scope user' "$FA/calls" || fail "the normal steps did not run under --update"
grep -q -E '^  refresh +ok +refreshed 3 marketplaces, updated 6 plugins$' "$WORK/upd-a.log" || fail "no refresh row naming 3 marketplaces and 6 plugins"
grep -q -x -F 'hov-stack: Claude Code sessions started from now on load the new plugin versions.' "$WORK/upd-a.log" || fail "the ending does not say new sessions load the new plugin versions"
ok "marketplace and plugin updates are exactly hov, the two offered marketplaces that are added (not the user's own, not compound-engineering) and the 6 installed offered plugins, with no -y"
grep -q -E '^  gh +ok +gh: 1\.0\.0 -> 2\.0\.0$' "$WORK/upd-a.log" || fail "gh was not updated 1.0.0 -> 2.0.0"
[ "$("$HA/.local/bin/gh")" = "gh 2.0.0" ] || fail "the gh at ~/.local/bin is not 2.0.0"
grep -q -E '^  uv +ok +uv: 1\.0\.0, current$' "$WORK/upd-a.log" || fail "uv at the pin was not reported current"
grep -q -E '^  jsm +ok +jsm: 1\.0\.0, current$' "$WORK/upd-a.log" || fail "jsm at the pin was not reported current"
grep -q -E "^  cass +skipped +cass: $HA/\.local/bin/cass has no hov-stack install record" "$WORK/upd-a.log" || fail "a cass nobody recorded was not left alone with its reason"
[ "$("$HA/.local/bin/cass")" = by-hand ] || fail "the hand-placed cass was replaced"
! grep -q -E 'steps? above (is|are) not finished' "$WORK/upd-a.log" || fail "a program left alone counted as an unfinished step"
ok "gh moves 1.0.0 -> 2.0.0, uv and jsm are current, a cass hov-stack never installed is left alone, and none of that makes setup exit non-zero"
want_uv=$(printf '%s\n' 'tool upgrade ast-grep-cli' 'tool upgrade synthetic-panel' "$OFFER_LINE" | LC_ALL=C sort)
got_uv=$(grep -v -x -E 'tool (list|dir)' "$UA/calls" | LC_ALL=C sort)
[ "$got_uv" = "$want_uv" ] || { diff <(printf '%s\n' "$want_uv") <(printf '%s\n' "$got_uv") || true; fail "uv was not asked for exactly the two upgrades and the offer's own line"; }
grep -q -E '^  uvtools +ok +synthetic-panel upgraded; synthetic-panel moved to '"$OFFER_TAG"'; ast-grep-cli upgraded$' "$WORK/upd-a.log" || fail "no uvtools row for the upgrades and the move"
ok "uv tools: the two offered ones installed get 'uv tool upgrade'; the git-tag offer recorded at an older tag of its repository is re-installed with the offer's own line; other-tool is not touched"
grep -q -x -F "hov-stack: jsm's skills are not updated here. To update them, run: jsm upgrade" "$WORK/upd-a.log" || fail "no jsm upgrade line with jsm on PATH"
ok "with jsm on PATH the jsm upgrade line is printed, not run"

# A second run has nothing to do.
: > "$UA/calls"
rc=0; upd_run "$UP/clone-a" "$HA" "$FA" "$UA" "$WORK/upd-a2.log" || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/upd-a2.log"; fail "the second setup --update exited $rc"; }
grep -q -E "^  checkout +ok +up to date at ${C1:0:7}\$" "$WORK/upd-a2.log" || { cat "$WORK/upd-a2.log"; fail "a second run did not report the checkout up to date"; }
grep -q -E '^  gh +ok +gh: 2\.0\.0, current$' "$WORK/upd-a2.log" || fail "a second run did not find gh current"
! grep -q '^tool install ' "$UA/calls" || fail "a second run re-installed a uv tool that is at the offer's tag"
ok "a second --update finds the checkout up to date, gh current and the uv tool at its tag, and installs nothing"

# 1b. A shallow clone (the README's `git clone --depth 1`) fast-forwards the same way.
new_update_fake "$UP/fake-sh"
new_uvstate "$UP/uv-sh" same-rev
rc=0; UPD_TABLE=$T_NEW UPD_PATH='' upd_run "$UP/clone-sh" "$UP/home-sh" "$UP/fake-sh" "$UP/uv-sh" "$WORK/upd-sh.log" || rc=$?
[ "$rc" = 0 ] || { cat "$WORK/upd-sh.log"; fail "setup --update in a shallow clone exited $rc"; }
[ "$(git -C "$UP/clone-sh" rev-parse HEAD)" = "$C1" ] || { cat "$WORK/upd-sh.log"; fail "the shallow clone did not fast-forward to the upstream"; }
[ "$(grep -c -x -F NEWER-SETUP-MARKER "$WORK/upd-sh.log")" = 1 ] || fail "the new setup did not run exactly once after the shallow clone's pull"
grep -q -E "^  checkout +ok +updated ${C0:0:7} -> ${C1:0:7}\$" "$WORK/upd-sh.log" || { cat "$WORK/upd-sh.log"; fail "no checkout row for the shallow clone's move"; }
ok "a shallow clone (git clone --depth 1) one commit behind fast-forwards and runs the new setup"

# 2. A hand-off variable that is not a commit this checkout moved from never skips the pull.
for stray in s1 s2 s3; do
  case $stray in
    s1) val=not-a-commit-id ;;
    s2) val=0123456789abcdef0123456789abcdef01234567 ;;
    s3)
      gitc -C "$UP/clone-s3" checkout -q -b side
      echo side > "$UP/clone-s3/side.txt"
      gitc -C "$UP/clone-s3" add side.txt
      gitc -C "$UP/clone-s3" commit -q -m side
      val=$(git -C "$UP/clone-s3" rev-parse HEAD)
      git -C "$UP/clone-s3" checkout -q main ;;
  esac
  new_update_fake "$UP/fake-$stray"
  new_uvstate "$UP/uv-$stray" same-rev
  UPD_TABLE=$T_NEW UPD_PATH='' HOV_STACK_UPDATE_FROM=$val upd_run "$UP/clone-$stray" "$UP/home-$stray" "$UP/fake-$stray" "$UP/uv-$stray" "$WORK/upd-$stray.log" \
    || { cat "$WORK/upd-$stray.log"; fail "setup --update with a stray hand-off ($stray) exited non-zero"; }
  [ "$(git -C "$UP/clone-$stray" rev-parse HEAD)" = "$C1" ] || { cat "$WORK/upd-$stray.log"; fail "a stray HOV_STACK_UPDATE_FROM ($stray: $val) skipped the pull"; }
  grep -q -x -F NEWER-SETUP-MARKER "$WORK/upd-$stray.log" || fail "the pull happened but the new setup did not run ($stray)"
done
ok "a HOV_STACK_UPDATE_FROM that is not hex, not a known commit, or a commit that is not an ancestor of HEAD does not skip the pull"
# Nothing is installed in these homes: every program is left alone, uv is not found, jsm is not on PATH.
if [ ! -e /usr/local/bin/uv ] && [ ! -e /opt/homebrew/bin/uv ]; then
  grep -q -E '^  uvtools +skipped +uv is not installed here' "$WORK/upd-s1.log" || fail "with no uv, there was no skip row for the uv tools"
  [ ! -s "$UP/uv-s1/calls" ] || fail "uv was called although none was installed"
fi
for t in gh uv cass jsm; do
  grep -q -E "^  $t +skipped +$t: not installed here; nothing to update\$" "$WORK/upd-s1.log" || fail "$t, not installed, was not reported as nothing to update"
done
! grep -q 'jsm upgrade' "$WORK/upd-s1.log" || fail "the jsm upgrade line was printed with no jsm on PATH"
ok "with no programs installed each is a skip row, uv tools are skipped when uv is absent, and no jsm upgrade line is printed"

# 3. Each refusal is one row with its fix; the checkout is left as it is and the rest still runs.
gitc -C "$UP/clone-dv" commit -q --allow-empty -m "local commit"
LOCAL_DV=$(git -C "$UP/clone-dv" rev-parse HEAD)
git -C "$UP/clone-dt" checkout -q --detach
git -C "$UP/clone-nu" branch -q --unset-upstream
printf '# local edit\n' >> "$UP/clone-lc/setup"
lc_sha=$(sha256sum < "$UP/clone-lc/setup")
refuse_case() {  # refuse_case <clone> <row text fragment> <HEAD it must keep>
  local c=$1 frag=$2 keep=$3 log=$WORK/upd-refuse-$1.log rc=0
  new_update_fake "$UP/fake-r-$c"
  new_uvstate "$UP/uv-r-$c" same-rev
  UPD_TABLE=$T_NEW UPD_PATH=$WORK/uv-bin upd_run "$UP/clone-$c" "$UP/home-r-$c" "$UP/fake-r-$c" "$UP/uv-r-$c" "$log" || rc=$?
  [ "$rc" = 0 ] || { cat "$log"; fail "setup --update with a refused pull ($c) exited $rc"; }
  grep -q -E "^  checkout +skipped +.*$frag" "$log" || { cat "$log"; fail "no checkout skip row mentioning '$frag' ($c)"; }
  [ "$(git -C "$UP/clone-$c" rev-parse HEAD)" = "$keep" ] || fail "the refused pull moved HEAD ($c)"
  ! grep -q -x -F NEWER-SETUP-MARKER "$log" || fail "a refused pull still ran the new setup ($c)"
  grep -q -E '^  links +ok ' "$log" || fail "the links step did not run after a refused pull ($c)"
  [ "$(grep -c -x -E 'plugin marketplace update (hov|last30days-skill|openai-codex)' "$UP/fake-r-$c/calls")" = 3 ] || { cat "$UP/fake-r-$c/calls"; fail "the plugin refresh did not run after a refused pull ($c)"; }
  grep -q -E '^  gh +skipped ' "$log" || fail "the program updates did not run after a refused pull ($c)"
  grep -q -E '^  uvtools +ok ' "$log" || fail "the uv tools step did not run after a refused pull ($c)"
}
refuse_case dv 'cannot fast-forward' "$LOCAL_DV"
refuse_case dt 'HEAD is detached' "$C0"
refuse_case nu 'has no upstream branch' "$C0"
refuse_case lc 'would not fast-forward main to origin/main \(Your local changes' "$C0"
[ "$(sha256sum < "$UP/clone-lc/setup")" = "$lc_sha" ] || fail "the refused pull changed the locally edited file"
grep -q -F 'git -C ' "$WORK/upd-refuse-dt.log" || fail "the detached row does not give the fix"
ok "a diverged branch, a detached HEAD, no upstream and a local change git will not overwrite each give a skip row with its fix, leave the checkout alone, and the links, plugin refresh, programs and uv tools still run"
# Not a git checkout at all, and a copy that sits inside someone else's repository.
new_update_fake "$UP/fake-ng"
new_uvstate "$UP/uv-ng" same-rev
UPD_TABLE=$T_NEW UPD_PATH='' upd_run "$copy" "$UP/home-ng" "$UP/fake-ng" "$UP/uv-ng" "$WORK/upd-ng.log" || { cat "$WORK/upd-ng.log"; fail "setup --update outside a git checkout exited non-zero"; }
grep -q -E "^  checkout +skipped +$copy is not the top of a git checkout" "$WORK/upd-ng.log" || { cat "$WORK/upd-ng.log"; fail "no skip row for a directory that is not a git checkout"; }
mkdir -p "$UP/outer"
git init -q "$UP/outer"
mkdir -p "$UP/outer/inner"
cp -R "$SEED/." "$UP/outer/inner/"
rm -rf "$UP/outer/inner/.git"
UPD_TABLE=$T_NEW UPD_PATH='' upd_run "$UP/outer/inner" "$UP/home-ng2" "$UP/fake-ng" "$UP/uv-ng" "$WORK/upd-ng2.log" || { cat "$WORK/upd-ng2.log"; fail "setup --update inside another repository exited non-zero"; }
grep -q -E "^  checkout +skipped +$UP/outer/inner is not the top of a git checkout" "$WORK/upd-ng2.log" || { cat "$WORK/upd-ng2.log"; fail "a copy inside another repository would pull that repository"; }
ok "a directory that is not a git checkout, or sits inside another repository, is a skip row (setup never pulls the wrong repository)"

# 4. A refusal by Claude Code is relayed and the other updates go on; a program that fails is
#    a failed row and the exit status, and the steps after it still run.
git clone -q "$UPSTREAM" "$UP/clone-f"
FF=$UP/fake-f
UF=$UP/uv-f
HFX=$UP/home-f
new_update_fake "$FF"
echo 'papercut@hov' > "$FF/update-refuse"
new_uvstate "$UF" same-rev
mkdir -p "$HFX/.local/bin"
seed_programs "$HFX"
rc=0; UPD_TABLE=$T_BADGH UPD_PATH=$HFX/.local/bin upd_run "$UP/clone-f" "$HFX" "$FF" "$UF" "$WORK/upd-f.log" || rc=$?
[ "$rc" = 1 ] || { cat "$WORK/upd-f.log"; fail "a program whose update failed left the exit status at $rc, not 1"; }
grep -q -E '^  gh +failed +install-release\.sh gh --update exited 1: ' "$WORK/upd-f.log" || fail "no failed row for gh"
grep -q -F 'checksum mismatch for gh-2.0.0.tar.gz' "$WORK/upd-f.log" || fail "the checksum failure was not relayed"
[ "$("$HFX/.local/bin/gh")" = "gh 1.0.0" ] || fail "a failed update changed the gh you had"
for t in uv cass jsm; do grep -q -E "^  $t +(ok|skipped) " "$WORK/upd-f.log" || fail "$t's row is missing after gh failed"; done
grep -q -E '^  uvtools ' "$WORK/upd-f.log" || fail "the uv tools did not run after gh failed"
ok "a program whose update fails is a failed row and exit 1, the copy you had is untouched, and the rest still runs"
grep -q -F 'Error: papercut@hov declares a command and needs --accept-command to update' "$WORK/upd-f.log" || { cat "$WORK/upd-f.log"; fail "Claude Code's refusal was not relayed"; }
grep -q -E '^  refresh +skipped +refreshed 3 marketplaces, updated 5 plugins; 0 marketplace and 1 plugin commands did not finish' "$WORK/upd-f.log" || { cat "$WORK/upd-f.log"; fail "the refresh row does not count the refused update"; }
[ "$(grep -c -x -E 'plugin update .* --scope user' "$FF/calls")" = 6 ] || { cat "$FF/calls"; fail "the updates after the refused one did not go on"; }
! grep -q -E ' -y|--accept-command' "$FF/calls" || fail "setup retried a refused update with -y or --accept-command"
ok "a plugin update Claude Code refuses is relayed, never forced with -y, and the other 5 updates go on"

# 5. uv's own record decides whether the git-tag offer is re-installed.
git clone -q "$UPSTREAM" "$UP/clone-u"
for kind in same-rev newer-tag branch no-ref other-repo pypi; do
  new_update_fake "$UP/fake-u-$kind"
  new_uvstate "$UP/uv-u-$kind" "$kind" no-ast-grep
  UPD_TABLE=$T_NEW UPD_PATH=$WORK/uv-bin upd_run "$UP/clone-u" "$UP/home-u-$kind" "$UP/fake-u-$kind" "$UP/uv-u-$kind" "$WORK/upd-u-$kind.log" \
    || { cat "$WORK/upd-u-$kind.log"; fail "setup --update with uv's record '$kind' exited non-zero"; }
  ! grep -q '^tool install ' "$UP/uv-u-$kind/calls" || { cat "$UP/uv-u-$kind/calls"; fail "uv's record '$kind' did not stop the offer's install line"; }
  grep -q -x -F 'tool upgrade synthetic-panel' "$UP/uv-u-$kind/calls" || fail "synthetic-panel was not upgraded in place with record '$kind'"
done
! grep -q 'ast-grep' "$UP"/uv-u-*/calls || fail "uv was asked about ast-grep-cli although uv does not list it (an offered tool you lack is never installed)"
grep -q -E '^  uvtools .*synthetic-panel is at '"$OFFER_TAG" "$WORK/upd-u-same-rev.log" || fail "a tool already at the offer's tag was not reported"
for kind in other-repo pypi; do
  grep -q -F "synthetic-panel: uv's record says it was installed from somewhere other than $OFFER_REPO, so it stays on that source" "$WORK/upd-u-$kind.log" || fail "no reason given for leaving a '$kind' synthetic-panel alone"
done
for kind in newer-tag branch no-ref; do
  grep -q -F "synthetic-panel: uv's record says it was installed from $OFFER_REPO at a revision other than an older tag, so it stays there" "$WORK/upd-u-$kind.log" || fail "no reason given for leaving a '$kind' synthetic-panel alone"
  grep -q -E '^  uvtools +ok +.*synthetic-panel left at the revision you chose' "$WORK/upd-u-$kind.log" || fail "the uvtools row does not say a '$kind' synthetic-panel was left at the user's revision"
done
# The separate rev field (and a .git suffix on the URL) is read as well: an older tag there is moved on.
new_update_fake "$UP/fake-u-old-field"
new_uvstate "$UP/uv-u-old-field" old-field no-ast-grep
UPD_TABLE=$T_NEW UPD_PATH=$WORK/uv-bin upd_run "$UP/clone-u" "$UP/home-u-old-field" "$UP/fake-u-old-field" "$UP/uv-u-old-field" "$WORK/upd-u-old-field.log" \
  || { cat "$WORK/upd-u-old-field.log"; fail "setup --update with uv's record 'old-field' exited non-zero"; }
grep -q -x -F "$OFFER_LINE" "$UP/uv-u-old-field/calls" || { cat "$UP/uv-u-old-field/calls"; fail "an older tag in a separate rev field was not moved to the offer's tag"; }
ok "the git-tag uv tool is re-installed only when uv's record names the offer's repository at an older tag; at its tag, at a newer tag, a branch or no revision, from another repository, or from PyPI it is left where it is, with the reason"

export CLAUDE_CONFIG_DIR=$WORK/cfg
bash "$ROOT/setup" > "$WORK/run3.log" 2>&1 || { cat "$WORK/run3.log"; fail "setup with CLAUDE_CONFIG_DIR exited non-zero"; }
[ -L "$CLAUDE_CONFIG_DIR/hooks" ] || fail "CLAUDE_CONFIG_DIR not used for links"
grep -q -F "$CLAUDE_CONFIG_DIR/hooks/" "$CLAUDE_CONFIG_DIR/settings.json" || fail "CLAUDE_CONFIG_DIR not used in hook paths"
ok "CLAUDE_CONFIG_DIR honoured"

echo "all $pass checks passed"
