#!/bin/sh
# comment-check-hook.sh: PostToolUse (matcher Bash) entry for `comment-check.py --hook`.
#
# Registered host-only, in the overlay's settings.json, not in this repo's settings.json
# template: the check costs one Haiku call per pull request, and it was chosen for the
# operator's own hosts only (issue #895). An install that wants it adds the same registration:
#   "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "timeout": 180,
#     "command": "\"$HOME/.claude/scripts/comment-check-hook.sh\""}]}]
# It lives under scripts/, not hooks/, because harness-doctor warns about any file under
# hooks/ that the live settings.json does not register, and on an install without the
# registration this file would read as an orphan.
#
# The gate: a Bash call runs this on every command, so Python starts only when the payload
# holds both `create` and `pull`. A successful `gh pr create` has both (the command, and the
# pull request URL it prints). Claude Code writes the payload with JSON.stringify, which never
# escapes an ASCII letter, so neither literal can hide behind an escape. Everything else exits
# 0 here, printing nothing: no Python start, no version-manager shim. The check itself fails
# open: any error, timeout or missing tool prints nothing and the tool result stands.
_cc_raw=$(cat; printf x) || exit 0
_cc_raw=${_cc_raw%x}
case $_cc_raw in *create*) ;; *) exit 0 ;; esac
case $_cc_raw in *pull*) ;; *) exit 0 ;; esac
printf '%s' "$_cc_raw" | python3 -I "$(dirname "$0")/comment-check.py" --hook
exit 0
