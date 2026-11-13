#!/usr/bin/env bash
# hov's own checks, run by release/scripts/plugin-ci.sh from the plugin root.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
test -x scripts/hov || { echo "scripts/hov is not executable" >&2; exit 1; }
test ! -e bin || { echo "top-level bin/ is rejected by claude.ai plugin distribution" >&2; exit 1; }
python3 -I -m py_compile scripts/hov
python3 -I - <<'EOF'
import json, os, re, sys
h = json.load(open("hooks/hooks.json"))
events = set(h["hooks"])
assert events == {"SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"}, events
# The Stop hook is the idle watcher (`hov wake`): it runs in the background for up to its timeout, and only its
# private exit code may become the 2 that wakes the session.
src = open("scripts/hov").read()
ttl = re.search(r"^WAKE_TTL_S = (.+?)  #", src, re.M).group(1)
wake_exit = re.search(r"^WAKE_EXIT = (\d+)", src, re.M).group(1)
STOP = ("sh -c 'python3 -I \"$0\" wake; [ $? -eq %s ] && exit 2; exit 0' \"${CLAUDE_PLUGIN_ROOT}/scripts/hov\"" % wake_exit)
for ev, groups in h["hooks"].items():
    for g in groups:
        for hook in g["hooks"]:
            assert hook["type"] == "command", hook
            m = re.search(r'\$\{CLAUDE_PLUGIN_ROOT\}/(\S+)"', hook["command"])
            assert m, hook["command"]
            assert os.path.exists(m.group(1)), m.group(1)
            if ev == "Stop":
                assert hook["command"] == STOP, hook["command"]
                assert hook.get("asyncRewake") is True and not hook.get("async"), hook
                assert hook.get("timeout") == eval(ttl, {}) + 60, (hook.get("timeout"), ttl)
                assert hook.get("rewakeMessage") and hook.get("rewakeSummary"), hook
                continue
            assert hook["command"].rstrip().endswith("hook " + ev), (ev, hook["command"])
            assert not hook.get("async") and not hook.get("asyncRewake"), hook
            assert 0 < hook.get("timeout", 0) <= 10, hook
m = json.load(open(".claude-plugin/plugin.json"))
assert m["name"] == "hov" and m["hooks"] == "./hooks/hooks.json", m
assert m["version"] == open("VERSION").read().strip(), (m["version"], open("VERSION").read())
print("hooks.json and plugin.json ok")
import ast
mods = set()
for n in ast.walk(ast.parse(open("scripts/hov").read())):
    if isinstance(n, ast.Import):
        mods.update(a.name.split(".")[0] for a in n.names)
    elif isinstance(n, ast.ImportFrom) and n.level == 0:
        mods.add(n.module.split(".")[0])
bad = sorted(m for m in mods if m not in sys.stdlib_module_names)
assert not bad, "non-stdlib imports: %s" % bad
print("stdlib only:", " ".join(sorted(mods)))
EOF
python3 -m unittest discover -s tests -p 'test_*.py' -v
