#!/usr/bin/env bash
# KTD11 / AE14: controlled offline help, exact allow set, and doctor crash guard.
# Every fixture lives under /tmp. No operator state or vendor data is read.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCANNER=$REPO/scripts/firecrawl-cli-drift-audit.py
MAP=$REPO/bin/firecrawl-cli-verbmap.json
DOCTOR=$REPO/scripts/harness-doctor.sh
TMP=$(mktemp -d /tmp/firecrawl-cli-drift.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
PYTHON=$(command -v python3)
mkdir -p "$TMP/bin" "$TMP/empty"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  case "$1" in *"$2"*) ok ;; *) bad "$3: missing '$2'" ;; esac
}
omits() {
  case "$1" in *"$2"*) bad "$3: unexpectedly contained '$2'" ;; *) ok ;; esac
}
status_is() {
  [ "$1" -eq "$2" ] && ok || bad "$3: expected exit $2, got $1"
}
count_is() {
  local n
  n=$(printf '%s\n' "$1" | grep -c '^WARN ')
  [ "$n" -eq "$2" ] && ok || bad "$3: expected $2 WARN lines, got $n"
}
SETTINGS=$TMP/settings.json
"$PYTHON" - "$MAP" "$TMP" <<'PY'
import json
from pathlib import Path
import sys
mapping = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
# The Firecrawl MCP is retired (#1178): a clean settings file carries no
# mcp__firecrawl__ allow entry, and any survivor is a finding.
for name, entries in [("settings", []), ("survivor", ["mcp__firecrawl__firecrawl_agent"])]:
    (root / (name + ".json")).write_text(json.dumps({
        "permissions": {"allow": entries + ["Bash(safe:*)"], "deny": ["mcp__firecrawl__ignored"]},
        "unrelated": "DO-NOT-PRINT-THIS-VALUE"}))
helps = {}
for command in ["", *mapping["commands"]]:
    lines = [f"Usage: firecrawl {command} [options]", "", "Options:"]
    row = mapping["commands"].get(command, {"flags": ["--help"], "defaults": {}})
    for flag in row["flags"]:
        default = row["defaults"].get(flag)
        # Independent Commander formatting details: aliases, wrapped defaults,
        # numeric range before default, and misleading mentions of other flags.
        prefix = "  -f, " if flag == "--format" else "  "
        description = " <value>  Description mentioning --not-a-real-option"
        if default is not None:
            description += f" (default:\n                             {default})"
        if command == "interact" and flag == "--timeout":
            description = " <seconds>  Timeout in seconds (1-300, default: 30)"
        lines.append(prefix + flag + description)
    if command in mapping["command_groups"]:
        lines += ["", "Commands:"]
        lines += [f"  {name} [options]  Description" for name in mapping["command_groups"][command]]
    lines += ["", "Examples:", "  $ firecrawl ignored --not-a-real-option"]
    helps[command] = "\n".join(lines) + "\n"
(root / "help.json").write_text(json.dumps(helps))
PY
# Absolute interpreter plus an entirely private PATH: even /usr/bin/firecrawl
# on a future CI image cannot defeat the missing-vendor scenario.
printf '#!%s\n' "$PYTHON" >"$TMP/bin/firecrawl"
cat >>"$TMP/bin/firecrawl" <<'PY'
import json
import os
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
args = sys.argv[1:]
if not args or args[-1] != "--help":
    sys.exit("fixture refuses non-help invocation")
command = " ".join(args[:-1])
helps = json.loads((root / "help.json").read_text())
text = helps.get(command, "")
mode = os.environ.get("DRIFT_FIXTURE", "clean")
if mode == "failure":
    sys.exit(7)
if mode == "malformed":
    print("not help")
    sys.exit(0)
if mode == "renamed" and command == "scrape":
    text = text.replace("--only-main-content", "--renamed-content")
if mode == "default" and command == "parse":
    text = text.replace("--only-main-content <value>  Description mentioning --not-a-real-option (default:\n                             false)",
                        "--only-main-content <value>  Description (default: true)")
if mode == "unstated" and command == "agent":
    text = text.replace("--max-credits <value>", "--max-credits <value> (default: 2500)")
if mode == "new" and command == "":
    text = text.replace("Commands:\n", "Commands:\n  brand-new [options]  New capability\n")
if mode == "removed" and command == "":
    text = text.replace("  parse [options]  Description\n", "")
if mode == "nested" and command == "interact":
    text = text.replace("  stop [options]  Description\n", "")
if mode == "alias" and command == "":
    text = text.replace("  experimental [options]", "  experimental|x [options]")
print(text)
PY
chmod +x "$TMP/bin/firecrawl"
run_scanner() {
  PATH="$TMP/bin" "$PYTHON" "$SCANNER" --settings "$SETTINGS" "$@" 2>&1
}
OUT=$(run_scanner); ST=$?
status_is "$ST" 0 "matching help"
contains "$OUT" "firecrawl-cli-drift: 26 subcommand(s), 41 flag(s), 18 default(s) checked, 0 finding(s)" "summary"
omits "$OUT" "WARN" "matching help"
omits "$OUT" "DO-NOT-PRINT" "settings values stay private"
OUT=$(DRIFT_FIXTURE="alias" run_scanner); ST=$?
status_is "$ST" 0 "Commander command alias"
for mode in renamed default unstated new removed nested; do
  OUT=$(DRIFT_FIXTURE=$mode run_scanner); ST=$?
  status_is "$ST" 1 "$mode finding"
  count_is "$OUT" 1 "$mode exactly one warning"
  case "$mode" in
    renamed) contains "$OUT" "scrape: missing flag --only-main-content" "renamed flag" ;;
    default) contains "$OUT" "parse --only-main-content: default changed from 'false' to 'true'" "AE14 both texts" ;;
    unstated) contains "$OUT" "agent --max-credits: default changed from <not stated> to '2500'" "newly stated default" ;;
    new) contains "$OUT" "new subcommand 'brand-new'; update the verb map" "new command" ;;
    removed) contains "$OUT" "missing subcommand 'parse'" "removed command" ;;
    nested) contains "$OUT" "missing subcommand 'interact stop'" "removed nested command" ;;
  esac
done
OUT=$(run_scanner --settings "$TMP/survivor.json"); ST=$?
status_is "$ST" 1 "surviving allow entry"
count_is "$OUT" 1 "survivor one warning"
contains "$OUT" "surviving permissions.allow entry 'mcp__firecrawl__firecrawl_agent' (the Firecrawl MCP is retired, #1178)" "survivor named"
printf '%s\n' '{"permissions":{"allow":"not a list"}}' >"$TMP/notlist.json"
printf '%s\n' '{not json' >"$TMP/broken.json"
printf '%s\n' '{"permissions":{"allow":[{}]}}' >"$TMP/notstring.json"
for fixture in nonexistent notlist broken notstring; do
  OUT=$(run_scanner --settings "$TMP/$fixture.json"); ST=$?
  status_is "$ST" 2 "$fixture settings"
  contains "$OUT" "did NOT run:" "$fixture is not clean"
done
OUT=$(run_scanner --verb-map "$TMP/notlist.json"); ST=$?
status_is "$ST" 2 "invalid map"
for mode in failure malformed; do
  OUT=$(DRIFT_FIXTURE=$mode run_scanner); ST=$?
  status_is "$ST" 2 "$mode vendor help"
  contains "$OUT" "did NOT run:" "$mode is not clean"
done
OUT=$(PATH="$TMP/empty" "$PYTHON" "$SCANNER" --settings "$TMP/nonexistent.json" 2>&1); ST=$?
status_is "$ST" 0 "missing vendor"
contains "$OUT" "info: firecrawl not on PATH; drift check dormant" "dormant message"

# Doctor-level guards run the full script with isolated HOME and no suites.
HOMEFIX=$TMP/home
mkdir -p "$HOMEFIX/.claude" "$HOMEFIX/windows-home/.claude" "$HOMEFIX/dotfiles/harness" \
  "$HOMEFIX/dotfiles/memory"
cp "$SETTINGS" "$HOMEFIX/.claude/settings.json"
cp "$SETTINGS" "$HOMEFIX/dotfiles/settings.json"
printf '%s\n' '{"mcpServers":{}}' >"$HOMEFIX/.claude.json"
printf '%s\n' '# fixture' >"$HOMEFIX/dotfiles/CLAUDE.md"
printf '%s\n' 'import sys' 'print("fixture crash", file=sys.stderr)' 'sys.exit(1)' >"$TMP/crash.py"
printf '%s\n' 'import sys' 'print("fixture cannot run", file=sys.stderr)' 'sys.exit(2)' >"$TMP/cannot.py"
printf '%s\n' 'print("info: fixture dormant")' 'print("fixture summary")' >"$TMP/dormant.py"
run_doctor() {
  HOME="$HOMEFIX" PATH="$TMP/bin:$(dirname "$PYTHON"):/usr/bin:/bin" \
  DOTFILES_REPO="$HOMEFIX/dotfiles" CLAUDE_HARNESS_REPO="$HOMEFIX/dotfiles" \
  CLAUDE_WINDOWS_HOME="$HOMEFIX/windows-home" DISPATCHER_CONFIG="$TMP/no-dispatcher" \
  CLAUDE_MEMORY_LIVE_ROOT="$HOMEFIX/.claude/projects" \
  CLAUDE_MEMORY_MIRROR_ROOT="$HOMEFIX/dotfiles/memory" \
  HARNESS_DOCTOR_SKIP_TESTS=1 timeout 600 bash "$DOCTOR" 2>&1 |
    sed -n '/^== 32\./,/^== 33\.\|^$/p'
}
OUT=$(CLAUDE_FIRECRAWL_DRIFT_AUDIT="$TMP/crash.py" run_doctor)
contains "$OUT" "exited 1 but named no finding — treat as did NOT run" "doctor crash guard"
omits "$OUT" "three-tool MCP allow list checked" "crash is never clean"
OUT=$(CLAUDE_FIRECRAWL_DRIFT_AUDIT="$TMP/cannot.py" run_doctor)
contains "$OUT" "audit did NOT run: fixture cannot run" "doctor exit 2"
omits "$OUT" "three-tool MCP allow list checked" "exit 2 never clean"
OUT=$(CLAUDE_FIRECRAWL_DRIFT_AUDIT="$TMP/dormant.py" run_doctor)
contains "$OUT" "info: fixture dormant" "doctor info pass-through"
contains "$OUT" "ok: fixture summary" "doctor summary"
OUT=$(DRIFT_FIXTURE=default run_doctor)
contains "$OUT" "WARN: firecrawl-cli-drift: parse --only-main-content: default changed from 'false' to 'true'" "doctor WARN pass-through"
omits "$OUT" "three-tool MCP allow list checked" "finding never clean"

# Review 2026-09-13: a deployed wrapper whose vendor is missing is a finding, never dormant.
mkdir -p "$TMP/deployed"
printf '#!/bin/sh\nexit 0\n' >"$TMP/deployed/firecrawl-cli"
chmod +x "$TMP/deployed/firecrawl-cli"
OUT=$(PATH="$TMP/deployed" "$PYTHON" "$SCANNER" --settings "$SETTINGS" 2>&1); ST=$?
status_is "$ST" 1 'deployed wrapper without vendor'
contains "$OUT" 'WARN firecrawl-cli-drift: firecrawl-cli is on PATH but the vendor firecrawl is not' 'deployed wrapper without vendor names the finding'
OUT=$(PATH="$TMP/empty" "$PYTHON" "$SCANNER" --settings "$SETTINGS" 2>&1); ST=$?
status_is "$ST" 0 'neither wrapper nor vendor stays dormant'
contains "$OUT" 'dormant' 'dormant when nothing is deployed'

# The tokenizer reads the vendor's real help (captured from firecrawl 1.19.26), so the
# generated fixtures above are not the only format it is ever proven against.
OUT=$("$PYTHON" - "$SCANNER" "$REPO/tests/fixtures/firecrawl-cli/vendor-help-1.19.26" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("drift", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
d = pathlib.Path(sys.argv[2])
commands, _ = mod.tokenize((d / "root.txt").read_text(), "root")
assert {"scrape", "crawl", "map", "parse", "search", "agent", "interact", "credit-usage"} <= commands, commands
_, scrape = mod.tokenize((d / "scrape.txt").read_text(), "scrape")
assert scrape.get("--only-main-content") == "false", scrape.get("--only-main-content")
assert "--format" in scrape and "--screenshot" in scrape, sorted(scrape)
_, parse = mod.tokenize((d / "parse.txt").read_text(), "parse")
assert "--only-main-content" in parse and "--timeout" in parse, sorted(parse)
_, interact = mod.tokenize((d / "interact.txt").read_text(), "interact")
assert interact.get("--timeout") == "30" and "--scrape-id" in interact, interact
# The shaped search flags are proven against the vendor's real search help, never
# against help generated from the verb map (review 2026-09-13).
_, search = mod.tokenize((d / "search.txt").read_text(), "search")
assert {"--limit", "--categories", "--sources", "--tbs", "--location"} <= set(search), sorted(search)
assert search.get("--sources") == "web", search.get("--sources")
print("OK")
PY
); ST=$?
status_is "$ST" 0 'real vendor help tokenizes'
contains "$OUT" 'OK' 'real vendor help assertions'

echo "firecrawl-cli-drift-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
