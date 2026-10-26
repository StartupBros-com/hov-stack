#!/usr/bin/env bash
# run_arm.sh - run one arm of a harness-vet phase-4 comparison.
#
# NOT a quality gate. Nothing scores its output. Its exit status says only
# whether the invocation produced a usable result: 0 when `claude` exited 0
# and result.json is a non-error envelope with a non-empty result, 1
# otherwise (dotfiles#1690; a failed invocation used to leave this script
# exiting with the tool-log pass's status). It exists so arms differ only in
# the skill under test, and so what each arm actually reached for is recorded
# instead of inferred later.
#
# Two defects it fixes, both found the hard way in the 2026-09-05 SEO vet:
#
#   1. No per-arm CLAUDE_CONFIG_DIR, so every arm inherited the operator's whole
#      harness. In that run exactly one arm reached for the Workflow tool, and
#      it was the control. A confound landing on the baseline alone is worse
#      than one landing on every arm equally.
#   2. Nobody recorded per-arm tool use, so settling the question afterwards
#      took transcript forensics across six sessions. One pass at the end turns
#      it into a fact printed beside the result.
#
# Isolation removes the operator's skills, plugins and settings from the arm.
# It does not remove built-in tools, so the tool log is what catches the rest.
#
# Usage: run_arm.sh <arm-dir> [extra-path-prepend]
#
#   <arm-dir>/prompt.txt   the arm's prompt. A leading /slash token loads the
#                          skill under test, so the control arm is the same
#                          text with no prefix.
#   <arm-dir>/config/      created if absent and used as CLAUDE_CONFIG_DIR.
#                          Put the skill under test in config/skills/<n>/SKILL.md
#                          and leave it empty for the bare arm.
#
# Writes into <arm-dir>: result.json, stderr.txt, tools.txt

set -uo pipefail

ARM_DIR="${1:?usage: run_arm.sh <arm-dir> [extra-path-prepend]}"
EXTRA_PATH="${2:-}"

cd "$ARM_DIR" || exit 1
[ -f prompt.txt ] || { echo "run_arm: no prompt.txt in $ARM_DIR" >&2; exit 1; }

mkdir -p config
CLAUDE_CONFIG_DIR="$PWD/config"
export CLAUDE_CONFIG_DIR

if [ -n "$EXTRA_PATH" ]; then
  PATH="$EXTRA_PATH:$PATH"
  export PATH
fi

PROMPT="$(cat prompt.txt)"

rc=0
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$PROMPT" \
  --model sonnet --max-turns 60 --output-format json \
  --allowedTools "Bash,Read,Glob,Grep,WebFetch,Write,Edit" \
  --permission-mode acceptEdits \
  > result.json 2> stderr.txt || rc=$?
echo "EXIT_CODE=$rc" >> stderr.txt

# What this arm actually reached for. An arm that used a tool its siblings did
# not is the confound; read this before comparing any scores.
python3 - "$CLAUDE_CONFIG_DIR" > tools.txt <<'PY'
import json, os, sys

root = os.path.join(sys.argv[1], "projects")
counts, turns = {}, 0
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") != "assistant":
                    continue
                content = (rec.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                turns += 1
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        counts[block.get("name", "?")] = counts.get(block.get("name", "?"), 0) + 1

if not os.path.isdir(root):
    print("no transcript found under CLAUDE_CONFIG_DIR; tool use unknown")
else:
    print("assistant_turns=%d" % turns)
    for name in sorted(counts):
        print("%s=%d" % (name, counts[name]))
    if not counts:
        print("(no tool_use recorded)")
PY

echo "run_arm: wrote result.json, stderr.txt, tools.txt in $ARM_DIR" >&2

# The tool log above is written whatever happened, so a failed arm still has
# its forensics. The exit status is the invocation's: 0 only when `claude`
# exited 0 and result.json is a non-error envelope with a non-empty result.
if ! python3 -I - "$rc" result.json <<'PY'
import json
import sys

rc, path = sys.argv[1], sys.argv[2]
if rc != "0":
    print("run_arm: claude exited %s; see stderr.txt" % rc, file=sys.stderr)
    sys.exit(1)
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print("run_arm: %s lacks a valid result (%s)" % (path, exc), file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict) or data.get("is_error") is not False:
    shown = data.get("is_error") if isinstance(data, dict) else type(data).__name__
    flag = "true" if shown is True else shown
    print("run_arm: %s: is_error=%s" % (path, flag), file=sys.stderr)
    sys.exit(1)
result = data.get("result")
if not isinstance(result, str) or not result.strip():
    print("run_arm: %s lacks a valid result" % path, file=sys.stderr)
    sys.exit(1)
PY
then
  exit 1
fi
