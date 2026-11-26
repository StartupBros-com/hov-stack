#!/bin/sh
# comment-check-hook.sh: Bash hook entry for `comment-check.py --hook`, PreToolUse or PostToolUse.
#
# Registered host-only, in the overlay's settings.json, not in this repo's settings.json
# template: the check costs one Haiku call per branch, and it was chosen for the operator's
# own hosts only (issue #895). Since issue #911 it runs before the command, where it holds a
# branch's first push once when the comments it adds look like clutter. An install that wants
# it adds the same registration, which runs this file only when it exists, since an overlay can
# reach a host before the checkout that ships this file does:
#   "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "timeout": 180,
#     "command": "[ ! -x \"$HOME/.claude/scripts/comment-check-hook.sh\" ] || exec \"$HOME/.claude/scripts/comment-check-hook.sh\""}]}]
# The same line under "PostToolUse" gives the older mode: context after `gh pr create`.
# It lives under scripts/, not hooks/, because harness-doctor warns about any file under
# hooks/ that the live settings.json does not register, and on an install without the
# registration this file would read as an orphan.
#
# The gate: a Bash call runs this on every command, so Python starts only when the payload can
# matter. Before the command (PreToolUse), that is a payload naming `push` or a `.sh` script,
# which may push. After it, that is a payload holding both `create` and `pull`, as a successful
# `gh pr create` does (the command, and the pull request URL it prints). Claude Code writes the
# payload with JSON.stringify, which never escapes an ASCII letter, so no literal can hide
# behind an escape. Everything else exits 0 here, printing nothing: no Python start, no
# version-manager shim. The check itself fails open: any error, timeout or missing tool prints
# nothing and the command runs, or its result stands.
_cc_raw=$(cat; printf x) || exit 0
_cc_raw=${_cc_raw%x}
case $_cc_raw in
*PreToolUse*push*|*push*PreToolUse*|*PreToolUse*.sh*|*.sh*PreToolUse*) ;;
*create*pull*|*pull*create*) ;;
*) exit 0 ;;
esac
printf '%s' "$_cc_raw" | python3 -I "$(dirname "$0")/comment-check.py" --hook
exit 0
