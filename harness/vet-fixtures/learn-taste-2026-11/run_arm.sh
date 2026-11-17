#!/usr/bin/env bash
# run_arm.sh <run-dir> - run one blinded arm of the learn-taste-2026-11 fixture.
#
# Not a quality gate: the eval note scores the output. Exit 0 means only that
# both `claude` turns exited 0 and left a non-error result.
#
# <run-dir> (built by make_runs.py) holds:
#   prompt.txt   turn 1, the ask
#   turn2.txt    turn 2, the approval ("write all"); optional
#   model.txt    the --model alias (default sonnet)
#   user/        the arm's HOME; user/.claude is its config dir, so skills sit
#                in user/.claude/skills and planted transcripts in
#                user/.claude/projects/<encoded cwd>/
#   user/code/acme-notes   the working copy, used as cwd (a git repo)
#
# Isolation: the environment is emptied except PATH and the model-route
# variables, which pass through by name only when set (`env -u` for the rest,
# so no secret value is ever written into argv). HOME, TMPDIR, XDG_CONFIG_HOME,
# XDG_CACHE_HOME and CLAUDE_CONFIG_DIR all point inside <run-dir>, and
# CLAUDE_CONFIG_DIR is HOME/.claude so a skill that reads ~/.claude/projects
# and Claude Code itself agree on one transcript store. The operator's skills,
# plugins, hooks, settings and memory never load. Managed settings still apply,
# equally to every arm.

set -uo pipefail

RUN="${1:?usage: run_arm.sh <run-dir>}"
RUN="$(cd "$RUN" && pwd)" || exit 1
REPO="$RUN/user/code/acme-notes"
[ -f "$RUN/prompt.txt" ] || { echo "run_arm: no prompt.txt in $RUN" >&2; exit 1; }
[ -d "$REPO" ] || { echo "run_arm: no repo at $REPO" >&2; exit 1; }
mkdir -p "$RUN/user/.claude" "$RUN/tmp" "$RUN/xdg-config" "$RUN/xdg-cache" "$RUN/out"

KEEP=" PATH ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "
UNSET=()
while IFS= read -r name; do
  case "$KEEP" in
    *" $name "*) ;;
    *) UNSET+=(-u "$name") ;;
  esac
done < <(compgen -e)

SET=(
  HOME="$RUN/user"
  TMPDIR="$RUN/tmp"
  XDG_CONFIG_HOME="$RUN/xdg-config"
  XDG_CACHE_HOME="$RUN/xdg-cache"
  CLAUDE_CONFIG_DIR="$RUN/user/.claude"
  DISABLE_AUTOUPDATER=1
)

MODEL=sonnet
[ -f "$RUN/model.txt" ] && MODEL="$(cat "$RUN/model.txt")"
TOOLS="Bash,Read,Glob,Grep,Write,Edit,Skill,Agent,TodoWrite"

# Names only, never values: proof of what the arm's environment held.
env "${UNSET[@]}" "${SET[@]}" python3 -I -c 'import os; print("env_names=" + ",".join(sorted(os.environ)))' > "$RUN/out/env-names.txt"

snapshot() {
  # What changed in the working copy and in the arm's config dir since the seed.
  local tag="$1"
  {
    echo "== repo status"
    git -C "$REPO" status --porcelain --untracked-files=all
    echo "== repo diff"
    git -C "$REPO" diff
    echo "== new or changed files under home (transcripts and git internals left out; check_runs.py sorts rule writes from housekeeping)"
    find "$RUN/user" -type f -newer "$RUN/prompt.txt" -not -name '*.jsonl' -not -path '*/.git/*' \
      | sed "s|$RUN/||" | sort
  } > "$RUN/out/changes-$tag.txt" 2>&1
  for f in DESIGN.md design/DESIGN.md CLAUDE.md AGENTS.md; do
    if [ -f "$REPO/$f" ]; then
      mkdir -p "$RUN/out/files-$tag/$(dirname "$f")"
      cp "$REPO/$f" "$RUN/out/files-$tag/$f"
    fi
  done
  if [ -f "$RUN/user/.claude/CLAUDE.md" ]; then
    mkdir -p "$RUN/out/files-$tag/global"
    cp "$RUN/user/.claude/CLAUDE.md" "$RUN/out/files-$tag/global/CLAUDE.md"
  fi
}

turn() {
  # turn <tag> <prompt-file> [session-id]
  local tag="$1" pfile="$2" sid="${3:-}"
  local resume=()
  [ -n "$sid" ] && resume=(--resume "$sid")
  local prompt rc=0
  prompt="$(cat "$pfile")"
  ( cd "$REPO" && env "${UNSET[@]}" "${SET[@]}" claude -p "$prompt" "${resume[@]}" \
      --model "$MODEL" --max-turns 80 --max-budget-usd 4 --output-format json \
      --allowedTools "$TOOLS" --permission-mode acceptEdits \
      > "$RUN/out/result-$tag.json" 2> "$RUN/out/stderr-$tag.txt" ) || rc=$?
  echo "EXIT_CODE=$rc" >> "$RUN/out/stderr-$tag.txt"
  snapshot "$tag"
  return "$rc"
}

rc1=0
turn t1 "$RUN/prompt.txt" || rc1=$?
SID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_id",""))' "$RUN/out/result-t1.json" 2>/dev/null)"
rc2=0
if [ "$rc1" = 0 ] && [ -n "$SID" ] && [ -f "$RUN/turn2.txt" ]; then
  turn t2 "$RUN/turn2.txt" "$SID" || rc2=$?
fi

# What the arm reached for: tool counts, skills invoked, every file read, every
# path a tool touched outside the run dir. Read before comparing any scores.
python3 -I - "$RUN" > "$RUN/out/tools.txt" <<'PY'
import json, os, sys

run = sys.argv[1]
root = os.path.join(run, "user", ".claude", "projects")
planted = set()
if os.path.exists(os.path.join(run, "planted.txt")):
    planted = set(open(os.path.join(run, "planted.txt")).read().split())
counts, skills, reads, outside, cmds, bash = {}, [], [], [], [], []
turns = 0
for dirpath, _dirs, files in os.walk(root):
    for name in sorted(files):
        if not name.endswith(".jsonl"):
            continue
        if name[: -len(".jsonl")] in planted:
            continue  # a planted transcript, not this arm's own
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="replace") as fh:
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
                    for key in ("file_path", "path"):
                        p = str(inp.get(key) or "")
                        if p:
                            if tool == "Read":
                                reads.append(p.replace(run, "$RUN"))
                            if p.startswith("/") and not p.startswith(run):
                                outside.append("%s:%s" % (tool, p))
                    if tool == "Bash":
                        c = str(inp.get("command", ""))
                        bash.append(c.replace(run, "$RUN")[:200].replace("\n", " "))
if not os.path.isdir(root):
    print("no transcript found; tool use unknown")
else:
    print("assistant_turns=%d" % turns)
    for name in sorted(counts):
        print("%s=%d" % (name, counts[name]))
    print("slash_commands=" + "|".join(cmds))
    print("skills=" + "|".join(skills))
    print("reads=" + "|".join(reads))
    print("paths_outside_run=" + "|".join(outside))
    print("bash:")
    for c in bash:
        print("  " + c)
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
