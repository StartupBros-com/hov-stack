#!/usr/bin/env bash
# Contract test for harness-doctor check 31's scanner (dotfiles#977):
# a retired MCP server's permission entries, registrations, and doc mentions
# must not survive its replacement CLI.
#
# PLANTED NEGATIVES, each naming the line that disappears if its guard is
# removed:
#   N1  the live drift of 2026-09-04 — `gsc` on PATH, no global
#       google-search-console server, and `mcp__google-search-console__*`
#       still allowed — must WARN. Drop the allow-list scan and it passes
#       silently. The same row's per-repo registration (a .mcp.json key
#       google-search-console-acme, the shape the GSC server actually had)
#       must WARN too; drop the repo-registry scan and only the global
#       ~/.claude.json is read, which never held a stdio server.
#   N2  a row whose CLI is NOT on PATH must stay dormant: the same `mcp__exa__`
#       allow entry that warns in N3 contributes nothing here. Drop the PATH
#       gate and the check turns red on every box before the CLI ships, which
#       defeats its purpose as a landing gate.
#   N3  once a stub `exa-cli` is on PATH, the allow entry, the global
#       registration, both harness-doc tokens, and a memory-mirror note each
#       WARN once. Drop the recursive --doc-tree scan and the memory note
#       (the real shape: memory/-home-user-hov-stack/web-retrieval-
#       provider-setup.md names all three tokens today) goes unreported.
#   N4  an --exception row is reported, never warned.
#       Firecrawl's three allow entries and registration warn without its
#       exception, then stay clean under the KTD11 coexistence decision.
#   N5  an unreadable settings file, a non-list permission value, an
#       unparseable repo .mcp.json, a missing doc dir or tree, no rows, or a
#       malformed row is exit 2 ("did NOT run"), never exit 0. A repo
#       .mcp.json that does not exist is skipped with an info line.
#   N6  the doctor wrapper: a scanner that exits 1 without a WARN line must be
#       reported as "exited 1 but named no finding — treat as did NOT run",
#       and must not print the section's clean line.
#
# Hermetic: every fixture is under /tmp, stub CLIs live on a private PATH, and
# nothing reads the operator's ~/.claude state. The doctor-level case runs the
# whole doctor under a scratch HOME with its test suites skipped.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCANNER=$REPO/scripts/cli-supersedes-mcp-audit.py
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/cli-supersedes-mcp.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle'" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'" ;; *) ok ;; esac
}
status_is() {
  local actual=$1 expected=$2 label=$3
  [ "$actual" -eq "$expected" ] && ok || bad "$label: expected exit $expected, got $actual"
}
count_is() {
  local output=$1 needle=$2 expected=$3 label=$4
  local n
  n=$(printf '%s\n' "$output" | grep -c -F -- "$needle")
  [ "$n" -eq "$expected" ] && ok || bad "$label: expected $expected line(s) matching '$needle', got $n"
}

PY_DIR=$(dirname "$(command -v python3)")
STUBBIN=$TMP/bin
mkdir -p "$STUBBIN" "$TMP/docs" "$TMP/repo" "$TMP/memory/-home-fixture"
printf '%s\n' '#!/usr/bin/env bash' 'echo stub-gsc' >"$STUBBIN/gsc"
chmod +x "$STUBBIN/gsc"
# A private PATH: the stub dir, python, and the base utils. No ~/.local/bin.
BASE_PATH=$STUBBIN:$PY_DIR:/usr/bin:/bin

SETTINGS=$TMP/settings.json
CONFIG=$TMP/claude.json
REPO_MCP=$TMP/repo/.mcp.json
NO_REPO_MCP=$TMP/norepo/.mcp.json
CLAUDE_MD=$TMP/CLAUDE.md
python3 - "$SETTINGS" "$CONFIG" "$REPO_MCP" <<'PY'
import json, sys
settings = {"permissions": {
    "allow": ["Bash(gsc query:*)", "mcp__google-search-console__*", "mcp__exa__web_search_exa",
              "mcp__firecrawl__firecrawl_search", "mcp__firecrawl__firecrawl_scrape",
              "mcp__firecrawl__firecrawl_developer_search"],
    "ask": [],
    "deny": ["mcp__x__create_users_bookmark"],
}}
config = {"mcpServers": {"exa": {"type": "http", "url": "https://example.invalid/mcp?exaApiKey=FIXTURE-NOT-A-KEY"},
                         "firecrawl": {"type": "http", "url": "https://example.invalid/firecrawl"},
                         "context7": {"type": "http", "url": "https://example.invalid/c7"}}}
repo = {"mcpServers": {"google-search-console-acme": {"command": "uvx", "args": ["mcp-gsc"]},
                       "supabase": {"command": "npx", "args": ["supabase-mcp"]}}}
json.dump(settings, open(sys.argv[1], "w"))
json.dump(config, open(sys.argv[2], "w"))
json.dump(repo, open(sys.argv[3], "w"))
PY
printf '%s\n' '# Web retrieval' 'Exa exposes exactly `web_search_exa` and `web_fetch_exa`.' 'Firecrawl pages come from `firecrawl_scrape`.' >"$TMP/docs/cc-mcp.md"
printf '%s\n' '# Unrelated' 'nothing to see' >"$TMP/docs/other.md"
printf '%s\n' '# CLAUDE' '- Search Console: use gsc' >"$CLAUDE_MD"
printf '%s\n' '---' 'name: fixture' '---' 'Exa is allowlisted to Web_Search_Advanced_Exa.' >"$TMP/memory/-home-fixture/web-retrieval.md"

ROW_EXA='--row exa-cli|exa|mcp__exa__|web_search_exa,web_fetch_exa,web_search_advanced_exa'
ROW_DFS='--row dfs|seo-mcp|mcp__seo-mcp__|'
ROW_GSC='--row gsc|google-search-console|mcp__google-search-console__|'
ROW_FIRECRAWL='--row firecrawl-cli|firecrawl|mcp__firecrawl__|firecrawl_search,firecrawl_scrape,firecrawl_developer_search'

run_scanner() {
  PATH="$BASE_PATH" python3 "$SCANNER" --settings "$SETTINGS" --claude-json "$CONFIG" \
    --repo-mcp-json "$REPO_MCP" --repo-mcp-json "$NO_REPO_MCP" \
    --doc-dir "$TMP/docs" --doc "$CLAUDE_MD" --doc-tree "$TMP/memory" "$@" 2>&1
}

# N1 + N2: gsc on PATH, exa-cli absent, dfs absent.
OUT=$(run_scanner $ROW_EXA $ROW_DFS $ROW_GSC); ST=$?
status_is "$ST" 1 "N1 live drift is a finding"
count_is "$OUT" "WARN " 2 "N1 exactly two findings (gsc allow entry + gsc repo registration)"
contains "$OUT" "allow entry 'mcp__google-search-console__*' survives the google-search-console -> gsc retirement" "N1 names the entry"
contains "$OUT" "$REPO_MCP: mcpServers.google-search-console-acme is still registered while gsc is on PATH (delete mcpServers.google-search-console-acme from this file and commit it in its repo)" "N1 per-repo registration under a suffixed key"
contains "$OUT" "info: repo mcp config missing, skipped: $NO_REPO_MCP" "N5 missing repo config is skipped with an info line"
contains "$OUT" "info: exa-cli not on PATH; exa row dormant" "N2 exa row dormant"
contains "$OUT" "info: dfs not on PATH; seo-mcp row dormant" "N2 dfs row dormant"
omits "$OUT" "mcp__exa__web_search_exa" "N2 dormant row contributes no finding"
omits "$OUT" "mcpServers.exa" "N2 dormant row ignores the registration"
omits "$OUT" "web_search_exa' (repoint" "N2 dormant row ignores the docs"
omits "$OUT" "supabase" "N1 unrelated repo server untouched"
contains "$OUT" "3 row(s), 1 checked, 2 dormant, 0 excepted, 2 registries, 4 doc(s) scanned, 2 finding(s)" "N1 summary counts"

# N3: a stub exa-cli appears on PATH -> every exa surface warns.
printf '%s\n' '#!/usr/bin/env bash' 'echo stub-exa-cli' >"$STUBBIN/exa-cli"
chmod +x "$STUBBIN/exa-cli"
OUT=$(run_scanner $ROW_EXA $ROW_DFS $ROW_GSC); ST=$?
status_is "$ST" 1 "N3 findings exit 1"
count_is "$OUT" "WARN " 7 "N3 seven findings (2 gsc + exa allow, global registration, two doc tokens, memory note)"
contains "$OUT" "allow entry 'mcp__exa__web_search_exa' survives the exa -> exa-cli retirement" "N3 exa allow entry"
contains "$OUT" "$CONFIG: mcpServers.exa is still registered while exa-cli is on PATH (claude mcp remove --scope user exa)" "N3 global registration"
contains "$OUT" "cc-mcp.md: names retired MCP tool 'web_search_exa' (repoint to exa-cli)" "N3 doc token"
count_is "$OUT" "web_fetch_exa" 1 "N3 second doc token found once"
contains "$OUT" "web-retrieval.md: names retired MCP tool 'web_search_advanced_exa' (repoint to exa-cli)" "N3 memory-tree note, matched case-insensitively"
omits "$OUT" "other.md" "N3 clean doc is silent"
omits "$OUT" "FIXTURE-NOT-A-KEY" "N3 never prints a registration value"
omits "$OUT" "mcp__firecrawl__" "N3 unrelated prefix untouched"
contains "$OUT" "3 row(s), 2 checked, 1 dormant, 0 excepted, 2 registries, 4 doc(s) scanned, 7 finding(s)" "N3 summary counts"

# N3b: each registry kind names its own remedy (user / local / tracked repo file).
LOCAL_CONFIG=$TMP/claude-local.json
printf '%s\n' '{"mcpServers":{},"projects":{"/fixture/proj":{"mcpServers":{"google-search-console":{"command":"uvx"}}}}}' >"$LOCAL_CONFIG"
OUT=$(PATH="$BASE_PATH" python3 "$SCANNER" --settings "$SETTINGS" --claude-json "$LOCAL_CONFIG" --repo-mcp-json "$REPO_MCP" $ROW_GSC 2>&1)
contains "$OUT" "$LOCAL_CONFIG:projects[/fixture/proj]: mcpServers.google-search-console is still registered while gsc is on PATH (claude mcp remove --scope local google-search-console, run from that project)" "N3b project-local registration names --scope local"
contains "$OUT" "$REPO_MCP: mcpServers.google-search-console-acme is still registered while gsc is on PATH (delete mcpServers.google-search-console-acme from this file and commit it in its repo)" "N3b tracked repo registration names a commit, not claude mcp remove"
omits "$OUT" "--scope project" "N3b no registry kind is told to use --scope project"

# N4: exceptions are reported, never warned.
OUT=$(run_scanner $ROW_EXA $ROW_DFS $ROW_GSC --exception exa --exception google-search-console); ST=$?
status_is "$ST" 0 "N4 excepted rows are clean"
count_is "$OUT" "WARN " 0 "N4 no findings"
contains "$OUT" "info: exa row excepted (documented coexistence with exa-cli)" "N4 exa excepted line"
contains "$OUT" "info: google-search-console row excepted (documented coexistence with gsc)" "N4 gsc excepted line"
contains "$OUT" "0 checked, 1 dormant, 2 excepted" "N4 summary counts"

# N4b: the Firecrawl MCP retired on 2026-09-13 (#1178). Its row, doc tokens
# included, warns on every planted survivor; the --exception mechanism still
# silences a row when a documented coexistence asks for it.
printf '%s\n' '#!/usr/bin/env bash' 'echo stub-firecrawl-cli' >"$STUBBIN/firecrawl-cli"
chmod +x "$STUBBIN/firecrawl-cli"
OUT=$(run_scanner $ROW_FIRECRAWL); ST=$?
status_is "$ST" 1 "N4b Firecrawl survivors warn"
count_is "$OUT" "WARN " 5 "N4b three Firecrawl allow entries, the registration, and a doc token survive"
contains "$OUT" "cc-mcp.md: names retired MCP tool 'firecrawl_scrape' (repoint to firecrawl-cli)" "N4b Firecrawl doc token"
OUT=$(run_scanner $ROW_FIRECRAWL --exception firecrawl); ST=$?
status_is "$ST" 0 "N4b an exception still silences the row"
count_is "$OUT" "WARN " 0 "N4b excepted row never warns"
contains "$OUT" "info: firecrawl row excepted (documented coexistence with firecrawl-cli)" "N4b excepted line"
contains "$OUT" "1 row(s), 0 checked, 0 dormant, 1 excepted, 2 registries, 4 doc(s) scanned, 0 finding(s)" "N4b excepted summary counts"

# Clean corpus: entries pruned, registrations gone, docs repointed -> exit 0.
python3 - "$SETTINGS" "$CONFIG" "$REPO_MCP" <<'PY'
import json, sys
json.dump({"permissions": {"allow": ["Bash(gsc query:*)", "Bash(exa-cli search:*)"], "ask": [], "deny": []}}, open(sys.argv[1], "w"))
json.dump({"mcpServers": {"context7": {"type": "http", "url": "https://example.invalid/c7"}}}, open(sys.argv[2], "w"))
json.dump({"mcpServers": {"supabase": {"command": "npx", "args": ["supabase-mcp"]}}}, open(sys.argv[3], "w"))
PY
printf '%s\n' '# Web retrieval' 'Exa: use `exa-cli search`.' >"$TMP/docs/cc-mcp.md"
printf '%s\n' '---' 'name: fixture' '---' 'Exa: exa-cli is canonical.' >"$TMP/memory/-home-fixture/web-retrieval.md"
OUT=$(run_scanner $ROW_EXA $ROW_DFS $ROW_GSC); ST=$?
status_is "$ST" 0 "clean corpus exits 0"
count_is "$OUT" "WARN " 0 "clean corpus has no finding"
contains "$OUT" "2 checked, 1 dormant, 0 excepted, 2 registries, 4 doc(s) scanned, 0 finding(s)" "clean summary counts"

# N5: did-NOT-run shapes are exit 2, never 0.
scan_with() { PATH="$BASE_PATH" python3 "$SCANNER" "$@" 2>&1; }
OUT=$(scan_with --settings "$TMP/missing.json" --claude-json "$CONFIG" --doc-dir "$TMP/docs" $ROW_GSC); ST=$?
status_is "$ST" 2 "N5 missing settings"
contains "$OUT" "did NOT run: settings could not be read/parsed" "N5 missing settings message"
printf '%s\n' '{not json' >"$TMP/broken.json"
OUT=$(scan_with --settings "$TMP/broken.json" --claude-json "$CONFIG" --doc-dir "$TMP/docs" $ROW_GSC); ST=$?
status_is "$ST" 2 "N5 unparseable settings"
# A permission list that is not a list holds real drift the scanner cannot
# iterate; that is did-NOT-run, never a clean (refute-lens finding, #978).
printf '%s\n' '{"permissions":{"allow":"mcp__google-search-console__*","deny":[]}}' >"$TMP/notlist.json"
OUT=$(scan_with --settings "$TMP/notlist.json" --claude-json "$CONFIG" --doc-dir "$TMP/docs" $ROW_GSC); ST=$?
status_is "$ST" 2 "N5 non-list permission value"
contains "$OUT" "did NOT run: settings permissions.allow is not a list" "N5 non-list message"
OUT=$(scan_with --settings "$SETTINGS" --claude-json "$CONFIG" --repo-mcp-json "$TMP/broken.json" --doc-dir "$TMP/docs" $ROW_GSC); ST=$?
status_is "$ST" 2 "N5 unparseable repo mcp config"
contains "$OUT" "did NOT run: repo mcp config could not be read/parsed" "N5 unparseable repo mcp message"
OUT=$(scan_with --settings "$SETTINGS" --claude-json "$CONFIG" --doc-dir "$TMP/no-such-docs" $ROW_GSC); ST=$?
status_is "$ST" 2 "N5 missing doc dir"
contains "$OUT" "did NOT run: doc dir missing" "N5 missing doc dir message"
OUT=$(scan_with --settings "$SETTINGS" --claude-json "$CONFIG" --doc-dir "$TMP/docs" --doc-tree "$TMP/no-such-tree" $ROW_GSC); ST=$?
status_is "$ST" 2 "N5 missing doc tree"
contains "$OUT" "did NOT run: doc tree missing" "N5 missing doc tree message"
OUT=$(scan_with --settings "$SETTINGS" --claude-json "$CONFIG" --doc-dir "$TMP/docs"); ST=$?
status_is "$ST" 2 "N5 no rows"
contains "$OUT" "did NOT run: no retirement rows" "N5 no rows message"
OUT=$(scan_with --settings "$SETTINGS" --claude-json "$CONFIG" --doc-dir "$TMP/docs" --row 'gsc|only-two'); ST=$?
status_is "$ST" 2 "N5 malformed row"
contains "$OUT" "malformed row" "N5 malformed row message"

# N6 (doctor level): the wrapper treats a crash as did-NOT-run, and reports
# the live-drift finding when the real scanner runs. The stub exa-cli from N3
# comes off PATH first so the doctor sees this box's shape: gsc present,
# exa-cli not yet shipped.
rm -f "$STUBBIN/exa-cli"
HOMEFIX=$TMP/home
mkdir -p "$HOMEFIX/.claude" "$HOMEFIX/dotfiles/harness" "$HOMEFIX/dotfiles/scripts" \
  "$HOMEFIX/dotfiles/memory" "$HOMEFIX/SITES/fixture-repo" "$HOMEFIX/windows-home/.claude"
python3 - "$HOMEFIX/.claude/settings.json" "$HOMEFIX/SITES/fixture-repo/.mcp.json" <<'PY'
import json, sys
json.dump({"permissions": {"allow": ["mcp__google-search-console__*"], "ask": [], "deny": [], "defaultMode": "acceptEdits", "disableAutoMode": "disable"}, "hooks": {}, "env": {}}, open(sys.argv[1], "w"))
json.dump({"mcpServers": {"google-search-console-fixture": {"command": "uvx", "args": ["mcp-gsc"]}}}, open(sys.argv[2], "w"))
PY
cp "$HOMEFIX/.claude/settings.json" "$HOMEFIX/dotfiles/settings.json"
printf '%s\n' '{"mcpServers":{}}' >"$HOMEFIX/.claude.json"
printf '%s\n' '# CLAUDE fixture' >"$HOMEFIX/dotfiles/CLAUDE.md"
printf '%s\n' '# harness fixture' >"$HOMEFIX/dotfiles/harness/current.md"
printf '%s\n' '{"permissions":{"allow":[],"deny":[],"ask":[],"disableAutoMode":"disable"}}' >"$HOMEFIX/windows-home/.claude/settings.json"
cat >"$TMP/cs-crash.py" <<'PY'
import sys
print("Traceback (most recent call last):", file=sys.stderr)
print("RuntimeError: fixture crash", file=sys.stderr)
sys.exit(1)
PY
run_doctor() {
  HOME="$HOMEFIX" PATH="$BASE_PATH" DOTFILES_REPO="$HOMEFIX/dotfiles" \
  CLAUDE_CLI_SUPERSEDES_AUDIT="${CLAUDE_CLI_SUPERSEDES_AUDIT:-}" \
  CLAUDE_MEMORY_LIVE_ROOT="$HOMEFIX/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$HOMEFIX/dotfiles/memory" \
  CLAUDE_HARNESS_REPO="$HOMEFIX/dotfiles" \
  CLAUDE_WINDOWS_HOME="$HOMEFIX/windows-home" \
  HARNESS_DOCTOR_SKIP_TESTS=1 \
    timeout 600 bash "$DOCTOR" 2>&1
}
CRASH_OUT=$(CLAUDE_CLI_SUPERSEDES_AUDIT="$TMP/cs-crash.py" run_doctor)
contains "$CRASH_OUT" "cli-supersedes-mcp audit exited 1 but named no finding" "N6 crashed scanner is not a verdict"
omits "$CRASH_OUT" "no retired MCP server survives its CLI" "N6 crashed scanner false clean"
LIVE_OUT=$(run_doctor)
contains "$LIVE_OUT" "== 31. CLI-supersedes-MCP" "N6 section header"
contains "$LIVE_OUT" "WARN: $HOMEFIX/.claude/settings.json: allow entry 'mcp__google-search-console__*' survives the google-search-console -> gsc retirement" "N6 doctor reports the live-drift finding"
contains "$LIVE_OUT" "WARN: $HOMEFIX/SITES/fixture-repo/.mcp.json: mcpServers.google-search-console-fixture is still registered while gsc is on PATH" "N6 doctor globs repo .mcp.json files"
contains "$LIVE_OUT" "info: exa-cli not on PATH; exa row dormant" "N6 doctor passes info lines through"
omits "$LIVE_OUT" "firecrawl row excepted" "N6 doctor no longer excepts Firecrawl (#1178)"
omits "$LIVE_OUT" "no retired MCP server survives its CLI" "N6 finding is not also a clean"

echo "cli-supersedes-mcp-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
