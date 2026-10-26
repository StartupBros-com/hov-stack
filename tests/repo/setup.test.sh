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
#   - dcg (#57, restructure plan U15): its licence is shown before anything is fetched; with
#     no network it is reported skipped and the run goes on; --no-dcg fetches nothing and
#     says so; a platform with no build is a skip naming the release page; an archive that
#     fails its checksum is a failure that installs nothing, with the links and seed made
#   - plugins (U15): with a fake claude first on PATH the hov marketplace is added and each
#     plugin in lib/default-plugins.txt installed exactly once, at user scope; a rerun calls
#     neither; a CLI below the floor, or offline, is reported and the run goes on; --check is
#     green after a full run, names a default plugin removed since and a rerun installs only
#     that one, and names each missing step after a partial run, changing nothing
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
[ ! -e "$HOME/.local" ] || fail "an offline dcg run left files under ~/.local"
for want_row in 'links +ok ' 'dcg +skipped ' 'settings +ok ' 'claude +missing ' 'marketplace +skipped ' 'plugins +skipped '; do
  grep -q -E "^  $want_row" "$WORK/run1.log" || fail "the status block has no '$want_row' row"
done
ok "offline: one download attempt, dcg reported skipped, nothing under ~/.local, and every step has its status row"

[ "$(cat "$HOME/.claude/projects/-home-someone-app/memory/MEMORY.md" "$HOME/.claude/memory/notes.md" | sha256sum)" = "$mem_before" ] || fail "memory changed"
ok "memory untouched"
[ "$(sha256sum < "$HOME/.claude/.credentials.json")" = "$cred_before" ] || fail "credentials changed"
ok "credentials untouched"

[ -L "$HOME/.claude/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink"
[ "$(readlink -f "$HOME/.claude/CLAUDE.md")" = "$ROOT/CLAUDE.md" ] || fail "CLAUDE.md points elsewhere"
backup=$(ls -d "$HOME"/.hov-stack-backups/*/ | head -1)
grep -q "their rules" "$backup/.claude/CLAUDE.md" || fail "previous CLAUDE.md not in backup"
ok "previous CLAUDE.md backed up under $backup"
for name in agents bin commands hooks mods scripts workflows claude-env.sh; do
  [ -L "$HOME/.claude/$name" ] || fail "$name not linked"
done
ok "9 harness links"
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
  for name in CLAUDE.md agents bin commands hooks mods scripts workflows claude-env.sh skills; do
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
[ ! -e "$WORK/home-bad/.local" ] || fail "a refused archive left files under ~/.local"
[ -L "$WORK/home-bad/.claude/hooks" ] && [ -f "$WORK/home-bad/.claude/settings.json" ] || fail "a refused archive stopped the links or the seed"
grep -q -F 'hov-stack: status' "$WORK/run-bad.log" || fail "a refused archive cut the run short"
ok "an archive that fails its checksum exits 1, installs nothing, and the links and seed are still made"

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
    if [ -f "$F/marketplace" ]; then
      printf '[{"name":"hov","source":"github","repo":"StartupBros-com/hov-stack","installLocation":"%s"}]\n' "$(cat "$F/marketplace")"
    else
      echo '[]'
    fi ;;
  'plugin marketplace add '*)
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    printf '%s\n' "$F/mkt" > "$F/marketplace" ;;
  'plugin list --json')
    sep=
    printf '['
    while read -r id v scope; do
      printf '%s{"id":"%s","version":"%s","scope":"%s","enabled":true}' "$sep" "$id" "$v" "$scope"
      sep=,
    done < "$F/plugins"
    echo ']' ;;
  'plugin install '*'@hov --scope user')
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    v=$(awk -v p="${3%@hov}" '$1 == p { print $2 }' "$F/versions")
    [ -n "$v" ] || { echo "fake claude: hov has no plugin $3" >&2; exit 1; }
    printf '%s %s user\n' "$3" "$v" >> "$F/plugins" ;;
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
fake_setup "$FK" "$HF" "$WORK/run-fake.log" --no-dcg || { cat "$WORK/run-fake.log"; fail "setup with a fake claude exited non-zero"; }
sed 's/^/    | /' "$WORK/run-fake.log"
[ "$(calls_of "$FK" 'plugin marketplace add StartupBros-com/hov-stack')" = 1 ] || { cat "$FK/calls"; fail "the hov marketplace was not added exactly once"; }
while read -r p; do
  [ "$(calls_of "$FK" "plugin install $p@hov --scope user")" = 1 ] || { cat "$FK/calls"; fail "$p@hov was not installed exactly once at user scope"; }
done < <(default_names)
[ "$(grep -c '^plugin install ' "$FK/calls")" = "$(default_names | wc -l | tr -d ' ')" ] || { cat "$FK/calls"; fail "setup installed a plugin lib/default-plugins.txt does not list"; }
ok "a fake claude was asked to add hov once and to install each of the $(default_names | wc -l | tr -d ' ') default plugins once, at user scope"
grep -q -E '^  marketplace +ok +added from StartupBros-com/hov-stack$' "$WORK/run-fake.log" || fail "no 'marketplace ok' row"
grep -q -x -E "  plugins +ok +installed: $(default_names | tr '\n' ' ' | sed 's/ $//')" "$WORK/run-fake.log" || fail "the plugins row does not name each default plugin installed"
grep -q -F 'select hov, then Enable auto-update' "$WORK/run-fake.log" || fail "the auto-update note is missing"
ok "the marketplace and plugins rows name what was added, and the auto-update note is shown"
fake_setup "$FK" "$HF" "$WORK/run-fake2.log" --no-dcg || { cat "$WORK/run-fake2.log"; fail "a rerun with a fake claude exited non-zero"; }
[ "$(calls_of "$FK" 'plugin marketplace add StartupBros-com/hov-stack')" = 1 ] || fail "a rerun added the marketplace again"
[ "$(grep -c '^plugin install ' "$FK/calls")" = "$(default_names | wc -l | tr -d ' ')" ] || fail "a rerun installed a plugin again"
grep -q -E '^  plugins +ok +.* were already installed$' "$WORK/run-fake2.log" || fail "a rerun did not report the plugins already installed"
[ ! -e "$HF/.hov-stack-backups" ] || fail "a run on a fresh HOME moved something to a backup"
ok "a rerun adds and installs nothing, says the plugins were already installed, and moves nothing"
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
for want_row in 'links +missing +not linked: hooks; run \./setup$' 'dcg +missing ' 'claude +missing '; do
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

export CLAUDE_CONFIG_DIR=$WORK/cfg
bash "$ROOT/setup" > "$WORK/run3.log" 2>&1 || { cat "$WORK/run3.log"; fail "setup with CLAUDE_CONFIG_DIR exited non-zero"; }
[ -L "$CLAUDE_CONFIG_DIR/hooks" ] || fail "CLAUDE_CONFIG_DIR not used for links"
grep -q -F "$CLAUDE_CONFIG_DIR/hooks/" "$CLAUDE_CONFIG_DIR/settings.json" || fail "CLAUDE_CONFIG_DIR not used in hook paths"
ok "CLAUDE_CONFIG_DIR honoured"

echo "all $pass checks passed"
