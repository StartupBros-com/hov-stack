#!/usr/bin/bash
# discord-notify.sh: the harness's one off-machine alert primitive (issue
# #438). Anything that pages the operator posts via Discord #agent-ops
# (standing preference since 2026-07-21; Telegram is unwatched). This script
# owns the mechanics every caller used to re-derive inline:
#   - jq builds the payload: raw printf JSON 400s on multiline/quoted content
#     (measured on an earlier inline sender).
#   - explicit User-Agent: Discord's edge 403s generic default UAs (fleet
#     memory, 2026-07-21).
#   - content bounded to Discord's 2000-char limit, and a truncated message
#     SAYS SO with the omitted count — a silent cut permanently acknowledged
#     omitted content in a past incident; #996 is the corrective doctrine.
#
# Usage: discord-notify.sh [--title TEXT] [--webhook-env VAR] [--] MESSAGE...
#        ... | discord-notify.sh [--title TEXT] -
# Webhook resolution: $DISCORD_WEBHOOK_URL (or $VAR via --webhook-env), else
# sourcing ~/.secrets IN A SUBSHELL, else exit 3. The URL is never echoed on
# any path.
# Exit: 0 sent (HTTP 2xx) · 1 send failed · 2 usage · 3 no webhook.
set -uo pipefail

# Length and slice ops below must count CODEPOINTS, not bytes: under a byte
# locale (LC_ALL=C) a multibyte message truncates early with a wrong
# omitted-count and ${CONTENT:0:1900} can slice mid-character into invalid
# UTF-8 (inward-vet finding). C.UTF-8 is built into glibc on every host this
# harness runs (WSL2 Ubuntu, Blacksmith 24.04).
export LC_ALL=C.UTF-8

usage() { echo "usage: discord-notify.sh [--title TEXT] [--webhook-env VAR] [--] MESSAGE... | -" >&2; exit 2; }

TITLE="" WEBHOOK_ENV="DISCORD_WEBHOOK_URL" MSG="" FROM_STDIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --title)       [ $# -ge 2 ] || usage; TITLE="$2"; shift 2 ;;
    --webhook-env) [ $# -ge 2 ] || usage; WEBHOOK_ENV="$2"; shift 2 ;;
    --)            shift; break ;;
    -)             FROM_STDIN=1; shift ;;
    --*)           usage ;;
    *)             break ;;
  esac
done
# ${!VAR} on an invalid identifier is a hard bash error whose exit code (1)
# collides with "send failed" — validate before ever expanding (inward-vet).
case "$WEBHOOK_ENV" in
  ''|[0-9]*|*[!A-Za-z0-9_]*) echo "discord-notify: --webhook-env is not a valid variable name" >&2; exit 2 ;;
esac
if [ "$FROM_STDIN" = 1 ]; then
  MSG=$(cat)
else
  MSG="$*"
fi
[ -n "$MSG" ] || { echo "discord-notify: empty message" >&2; exit 2; }

URL="${!WEBHOOK_ENV:-}"
if [ -z "$URL" ] && [ -f "$HOME/.secrets" ]; then
  # Sourced in a SUBSHELL, never this shell: a ~/.secrets that calls exit,
  # references an unset var (this script runs set -u), or fails to parse must
  # not kill the notifier mid-flight with no output (inward-vet blocker) —
  # the worst it may do is yield no URL, which lands on the documented
  # exit-3 path below.
  URL=$(set +u; . "$HOME/.secrets" >/dev/null 2>&1; printf '%s' "${!WEBHOOK_ENV:-}" 2>/dev/null) || URL=""
fi
[ -n "$URL" ] || { echo "discord-notify: no webhook (\$$WEBHOOK_ENV unset and ~/.secrets did not provide it)" >&2; exit 3; }

CONTENT="$MSG"
[ -n "$TITLE" ] && CONTENT="**${TITLE}** — ${MSG}"
# Discord hard-caps content at 2000 chars. Cut at 1900 and NAME the omission.
if [ "${#CONTENT}" -gt 2000 ]; then
  OMITTED=$(( ${#CONTENT} - 1900 ))
  CONTENT="${CONTENT:0:1900}
… [truncated: ${OMITTED} chars omitted]"
fi

PAYLOAD=$(jq -cn --arg c "$CONTENT" '{content: $c}') || { echo "discord-notify: jq payload build failed" >&2; exit 1; }
if curl -sf -m 15 -X POST \
     -H 'Content-Type: application/json' \
     -H 'User-Agent: harness-discord-notify/1.0 (dotfiles)' \
     -d "$PAYLOAD" "$URL" >/dev/null 2>&1; then
  exit 0
fi
echo "discord-notify: send failed (curl non-2xx or network error)" >&2
exit 1
