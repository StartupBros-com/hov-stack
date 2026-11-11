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
assert events == {"SessionStart", "UserPromptSubmit", "PostToolUse"}, events
for ev, groups in h["hooks"].items():
    for g in groups:
        for hook in g["hooks"]:
            assert hook["type"] == "command", hook
            m = re.search(r'\$\{CLAUDE_PLUGIN_ROOT\}/(\S+)"', hook["command"])
            assert m, hook["command"]
            assert os.path.exists(m.group(1)), m.group(1)
            assert hook["command"].rstrip().endswith("hook " + ev), (ev, hook["command"])
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
