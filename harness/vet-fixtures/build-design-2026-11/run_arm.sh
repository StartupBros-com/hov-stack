#!/usr/bin/env bash
# run_arm.sh <run-dir> - run one blinded arm of the build-design-2026-11 fixture.
#
# Not a quality gate: score_runs.py and the graders score the output. Exit 0
# means only that every `claude` turn run exited 0 and left a non-error result.
#
# <run-dir> (built by make_runs.py) holds:
#   prompt.txt   turn 1, the ask
#   turn2.txt    sent only when turn 1 left the working copy unchanged (t1, t3, t4)
#   model.txt    the --model alias (default sonnet)
#   plugin-dir.txt  a pack arm's copy of the hov-stack plugin, loaded with --plugin-dir
#   user/        the arm's HOME; user/.claude is its config dir, so a skill sits
#                in user/.claude/skills
#   user/code/acme-console   the working copy, used as cwd (a git repo)
#
# Isolation, as in learn-taste-2026-11/run_arm.sh: the environment is emptied
# except PATH and the model-route variables (passed by name via `env -u`, never
# by value), and HOME, TMPDIR, XDG_CONFIG_HOME, XDG_CACHE_HOME and
# CLAUDE_CONFIG_DIR all point inside <run-dir>.
#
# No shell: --tools makes only the listed built-ins exist and --allowedTools
# pre-approves the same list, so no arm can start a dev server, install
# packages or open a browser. Every arm has the same means of looking at its own
# build: none. A claim that the build matches the design is therefore unverified
# by construction (README, item R3).

set -uo pipefail

RUN="${1:?usage: run_arm.sh <run-dir>}"
RUN="$(cd "$RUN" && pwd)" || exit 1
REPO="$RUN/user/code/acme-console"
[ -f "$RUN/prompt.txt" ] || { echo "run_arm: no prompt.txt in $RUN" >&2; exit 1; }
[ -d "$REPO" ] || { echo "run_arm: no repo at $REPO" >&2; exit 1; }
mkdir -p "$RUN/user/.claude" "$RUN/tmp" "$RUN/xdg-config" "$RUN/xdg-cache" "$RUN/out"
BASE="$(git -C "$REPO" rev-parse HEAD)" || exit 1

KEEP=" PATH ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "
UNSET=()
while IFS= read -r name; do
  case "$KEEP" in
    *" $name "*) ;;
    *) UNSET+=(-u "$name") ;;
  esac
done < <(compgen -e)

REAL_CLAUDE="$(command -v claude)" || { echo "run_arm: claude not on PATH" >&2; exit 1; }
SET=(
  HOME="$RUN/user"
  TMPDIR="$RUN/tmp"
  XDG_CONFIG_HOME="$RUN/xdg-config"
  XDG_CACHE_HOME="$RUN/xdg-cache"
  CLAUDE_CONFIG_DIR="$RUN/user/.claude"
  DISABLE_AUTOUPDATER=1
  BROWSER=true
)

PLUGIN=()
[ -f "$RUN/plugin-dir.txt" ] && PLUGIN=(--plugin-dir "$(cat "$RUN/plugin-dir.txt")")
MODEL=sonnet
[ -f "$RUN/model.txt" ] && MODEL="$(cat "$RUN/model.txt")"
TOOLS="Read,Glob,Grep,Write,Edit,Skill,TodoWrite"

env "${UNSET[@]}" "${SET[@]}" python3 -I -c 'import os; print("env_names=" + ",".join(sorted(os.environ)))' > "$RUN/out/env-names.txt"

snapshot() {
  local tag="$1"
  {
    echo "== repo status"
    git -C "$REPO" status --porcelain --untracked-files=all
    echo "== repo diff"
    git -C "$REPO" add -A -N
    git -C "$REPO" diff "$BASE"
  } > "$RUN/out/changes-$tag.txt" 2>&1
}

unchanged() {
  [ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ] && \
    git -C "$REPO" diff --quiet "$BASE"
}

turn() {
  # turn <tag> <prompt-file> [session-id]
  local tag="$1" pfile="$2" sid="${3:-}"
  local resume=()
  [ -n "$sid" ] && resume=(--resume "$sid")
  local prompt rc=0
  prompt="$(cat "$pfile")"
  ( cd "$REPO" && env "${UNSET[@]}" "${SET[@]}" "$REAL_CLAUDE" -p "$prompt" "${resume[@]}" "${PLUGIN[@]}" \
      --model "$MODEL" --max-turns 60 --max-budget-usd 4 --output-format json \
      --tools "$TOOLS" --allowedTools "$TOOLS" --permission-mode acceptEdits \
      > "$RUN/out/result-$tag.json" 2> "$RUN/out/stderr-$tag.txt" ) || rc=$?
  echo "EXIT_CODE=$rc" >> "$RUN/out/stderr-$tag.txt"
  snapshot "$tag"
  return "$rc"
}

rc1=0
turn t1 "$RUN/prompt.txt" || rc1=$?
SID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_id",""))' "$RUN/out/result-t1.json" 2>/dev/null)"
rc2=0
if [ "$rc1" = 0 ] && [ -n "$SID" ] && [ -f "$RUN/turn2.txt" ] && unchanged; then
  echo "turn 1 left the working copy unchanged; sending turn2.txt" > "$RUN/out/turn2-sent.txt"
  turn t2 "$RUN/turn2.txt" "$SID" || rc2=$?
fi

# What the arm reached for: tool counts, skills invoked, slash commands resolved,
# every file read, every path a tool touched outside the run dir, and any tool
# call the permission layer refused. Read before comparing any scores.
python3 -I - "$RUN" > "$RUN/out/tools.txt" <<'PY'
import json, os, sys

run = sys.argv[1]
root = os.path.join(run, "user", ".claude", "projects")
own = set()
for tag in ("t1", "t2"):
    try:
        own.add(json.load(open(os.path.join(run, "out", "result-%s.json" % tag))).get("session_id") or "")
    except (OSError, ValueError):
        pass
own.discard("")
counts, skills, reads, outside, cmds, unresolved, denied = {}, [], [], [], [], [], []
turns = nested = 0
for dirpath, _dirs, files in os.walk(root):
    for name in sorted(files):
        if not name.endswith(".jsonl"):
            continue
        sid = name[: -len(".jsonl")]
        if own and sid not in own and "/subagents/" not in os.path.join(dirpath, name):
            nested += 1
            continue
        with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                content = (rec.get("message") or {}).get("content")
                att = rec.get("attachment") if rec.get("type") == "attachment" else None
                if isinstance(att, dict) and att.get("type") == "unknown_command_fallback":
                    unresolved.append(str(att.get("commandName")))
                if rec.get("type") == "user" and isinstance(content, str) and "<command-name>" in content:
                    cmds.append(content.split("<command-name>", 1)[1].split("</command-name>", 1)[0])
                if rec.get("type") == "user" and isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error"):
                            text = json.dumps(block.get("content"))[:160]
                            if "permission" in text.lower() or "not available" in text.lower():
                                denied.append(text)
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
                    for key in ("file_path", "path"):
                        p = str(inp.get(key) or "")
                        if p:
                            if tool == "Read":
                                reads.append(p.replace(run, "$RUN"))
                            if p.startswith("/") and not p.startswith(run):
                                outside.append("%s:%s" % (tool, p))
if not os.path.isdir(root):
    print("no transcript found; tool use unknown")
else:
    print("assistant_turns=%d" % turns)
    print("nested_sessions=%d" % nested)
    for name in sorted(counts):
        print("%s=%d" % (name, counts[name]))
    print("slash_commands=" + "|".join(cmds))
    print("unresolved_commands=" + "|".join(unresolved))
    print("skills=" + "|".join(skills))
    print("reads=" + "|".join(reads))
    print("paths_outside_run=" + "|".join(outside))
    print("denied=" + "|".join(denied))
PY

python3 -I - "$rc1" "$RUN/out/result-t1.json" <<'PY'
import json, sys
rc, path = sys.argv[1], sys.argv[2]
if rc != "0":
    sys.exit("run_arm: turn 1 exited %s; see out/stderr-t1.txt" % rc)
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError) as exc:
    sys.exit("run_arm: %s lacks a valid result (%s)" % (path, exc))
if not isinstance(data, dict) or data.get("is_error") is not False:
    sys.exit("run_arm: %s is an error envelope" % path)
if not str(data.get("result") or "").strip():
    sys.exit("run_arm: %s has an empty result" % path)
PY
[ "$rc2" = 0 ] || { echo "run_arm: turn 2 exited $rc2; see out/stderr-t2.txt" >&2; exit 1; }
