#!/usr/bin/env bash
# run_arm.sh <run-dir> - run one blinded arm of the pstack-2026-11 fixture.
#
# Not a quality gate: grade.py scores the output. Exit 0 means only that
# `claude` exited 0 and left a non-error result.
#
# <run-dir> holds prompt.txt and repo/ (the working copy, used as cwd), plus
# config/ (CLAUDE_CONFIG_DIR, so an arm's CLAUDE.md lives at config/CLAUDE.md)
# and, for the plugin arm only, plugin-dir.txt naming a --plugin-dir path.
# An optional model.txt names the --model alias (default sonnet).
#
# Isolation: the environment is emptied except PATH and the model-route
# variables, which pass through by name only when set. That is `env -i` with
# the route variables passed by name; it unsets the rest rather than writing
# `env -i NAME=value`, which would put the API key in this process's argv.
# HOME, TMPDIR, XDG_CONFIG_HOME, XDG_CACHE_HOME and CLAUDE_CONFIG_DIR all
# point inside <run-dir>, so the operator's skills, plugins, hooks, settings
# and memory never load. Managed settings (/etc/claude-code) still apply,
# equally to every arm.

set -uo pipefail

RUN="${1:?usage: run_arm.sh <run-dir>}"
RUN="$(cd "$RUN" && pwd)" || exit 1
[ -f "$RUN/prompt.txt" ] || { echo "run_arm: no prompt.txt in $RUN" >&2; exit 1; }
[ -d "$RUN/repo" ] || { echo "run_arm: no repo/ in $RUN" >&2; exit 1; }
mkdir -p "$RUN/config" "$RUN/home" "$RUN/tmp" "$RUN/xdg-config" "$RUN/xdg-cache"

KEEP=" PATH ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "
UNSET=()
while IFS= read -r name; do
  case "$KEEP" in
    *" $name "*) ;;
    *) UNSET+=(-u "$name") ;;
  esac
done < <(compgen -e)

SET=(
  HOME="$RUN/home"
  TMPDIR="$RUN/tmp"
  XDG_CONFIG_HOME="$RUN/xdg-config"
  XDG_CACHE_HOME="$RUN/xdg-cache"
  CLAUDE_CONFIG_DIR="$RUN/config"
  DISABLE_AUTOUPDATER=1
)

MODEL=sonnet
[ -f "$RUN/model.txt" ] && MODEL="$(cat "$RUN/model.txt")"

PLUGIN=()
if [ -f "$RUN/plugin-dir.txt" ]; then
  PLUGIN=(--plugin-dir "$(cat "$RUN/plugin-dir.txt")")
fi

# Names only, never values: proof of what the arm's environment held.
env "${UNSET[@]}" "${SET[@]}" python3 -I -c 'import os; print("env_names=" + ",".join(sorted(os.environ)))' > "$RUN/env-names.txt"

PROMPT="$(cat "$RUN/prompt.txt")"
cd "$RUN/repo" || exit 1
rc=0
env "${UNSET[@]}" "${SET[@]}" claude -p "$PROMPT" \
  --model "$MODEL" --max-turns 80 --max-budget-usd 4 --output-format json \
  --allowedTools "Bash,Read,Glob,Grep,Write,Edit,Skill,Agent,TodoWrite" \
  --permission-mode acceptEdits "${PLUGIN[@]}" \
  > "$RUN/result.json" 2> "$RUN/stderr.txt" || rc=$?
echo "EXIT_CODE=$rc" >> "$RUN/stderr.txt"

# What the arm reached for: tool counts, skills invoked, skill/doc files read,
# subagents spawned. Read before comparing any scores.
python3 -I - "$RUN/config" > "$RUN/tools.txt" <<'PY'
import json, os, sys

root = os.path.join(sys.argv[1], "projects")
counts, turns, skills, reads, agents, cmds = {}, 0, [], [], [], []
for dirpath, _dirs, files in os.walk(root):
    for name in sorted(files):
        if not name.endswith(".jsonl"):
            continue
        with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                content = (rec.get("message") or {}).get("content")
                if rec.get("type") == "user" and isinstance(content, str) and "<command-name>" in content:
                    cmds.append(content.split("<command-name>", 1)[1].split("</command-name>", 1)[0])
                if rec.get("type") != "assistant" or not isinstance(content, list):
                    continue
                turns += 1
                for block in content:
                    if not (isinstance(block, dict) and block.get("type") == "tool_use"):
                        continue
                    tool = block.get("name", "?")
                    counts[tool] = counts.get(tool, 0) + 1
                    inp = block.get("input") or {}
                    if tool == "Skill":
                        skills.append(str(inp.get("skill") or inp.get("command") or inp))
                    elif tool == "Read":
                        p = str(inp.get("file_path", ""))
                        if "/skills/" in p or "/docs/harness/" in p or "/agents/" in p:
                            reads.append(p.split("/claude-code/", 1)[-1])
                    elif tool in ("Agent", "Task"):
                        agents.append(str(inp.get("subagent_type", "general")))
if not os.path.isdir(root):
    print("no transcript found; tool use unknown")
else:
    print("assistant_turns=%d" % turns)
    for name in sorted(counts):
        print("%s=%d" % (name, counts[name]))
    print("slash_commands=" + "|".join(cmds))
    print("skills=" + "|".join(skills))
    print("skill_files_read=" + "|".join(reads))
    print("subagents=" + "|".join(agents))
PY

python3 -I - "$rc" "$RUN/result.json" <<'PY'
import json, sys
rc, path = sys.argv[1], sys.argv[2]
if rc != "0":
    sys.exit("run_arm: claude exited %s; see stderr.txt" % rc)
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError) as exc:
    sys.exit("run_arm: %s lacks a valid result (%s)" % (path, exc))
if not isinstance(data, dict) or data.get("is_error") is not False:
    sys.exit("run_arm: %s is an error envelope" % path)
if not str(data.get("result") or "").strip():
    sys.exit("run_arm: %s has an empty result" % path)
PY
