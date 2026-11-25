#!/usr/bin/env bash
# merge-freeze.sh: hold merges into one repository still for a bounded time.
#
# A session that needs main to stand still (a deploy from main, a release cut, a sequence of
# PRs that must land in order) records that here instead of messaging every live peer. Before
# each merge, pr-land.sh asks `check`: while another holder's freeze is active, it waits for
# the freeze to end inside its own check wait, then exits pending naming the holder. Nobody is
# woken and nobody has to read a message; the freeze lapses on its own at its end time.
#
# Usage:
#   merge-freeze.sh hold    [--repo OWNER/NAME] --minutes N --reason TEXT [--allow-pr N]...
#   merge-freeze.sh show    [--repo OWNER/NAME] [--json]      (status is the same command)
#   merge-freeze.sh release [--repo OWNER/NAME] [--force]
#   merge-freeze.sh check    --repo OWNER/NAME [--pr N]
#
#   --repo       default: the current checkout's GitHub repo (`gh repo view`); check needs it given
#   --minutes N  how long the freeze lasts, 1 to 1440; hold again to extend your own
#   --reason     one line naming why, printed to every merge it holds
#   --allow-pr N a PR that may merge through the freeze (repeatable), e.g. the fix being deployed
#   --force      release a freeze someone else holds, or a file that does not parse
#
# The holder is the Claude Code session ($CLAUDE_CODE_SESSION_ID), else shell:$USER. A freeze
# never holds its own holder's merges. `hold` refuses while someone else's freeze is active.
#
# check exit: 0 nothing holds this merge; 1 frozen (one stdout line: holder, end, reason);
# 2 the freeze file does not parse (fail closed: the line names the file and how to clear it).
# Other commands: 0 done; 1 refused; 2 a read failed; 64 usage.
#
# What it does not bind: a merge that does not go through pr-land.sh (a direct
# `gh pr merge`, an auto-merge armed before the freeze, a PR already in a merge queue), or a
# merge on another host. Files: one JSON object per repository in $MERGE_FREEZE_DIR, else
# $XDG_STATE_HOME/merge-freeze, else ~/.local/state/merge-freeze.
set -euo pipefail
say() { printf 'merge-freeze: %s\n' "$1" >&2; }
usage() {
  say 'usage: merge-freeze.sh hold [--repo OWNER/NAME] --minutes N --reason TEXT [--allow-pr N]... | show|status [--repo OWNER/NAME] [--json] | release [--repo OWNER/NAME] [--force] | check --repo OWNER/NAME [--pr N]'
  exit 64
}
DIR=${MERGE_FREEZE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/merge-freeze}
ME=${CLAUDE_CODE_SESSION_ID:-shell:${USER:-unknown}}

[ "$#" -gt 0 ] || usage
CMD=$1; shift
# `status` is `show`: sessions reach for that word first.
case "$CMD" in hold|show|release|check) ;; status) CMD=show ;; -h|--help) usage ;; *) usage ;; esac
REPO="" MINUTES="" REASON="" ALLOW=() PR="" JSON=0 FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [[ "${2:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage; REPO=$2; shift 2 ;;
    --minutes) [[ "${2:-}" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$2" -le 1440 ] || usage; MINUTES=$2; shift 2 ;;
    --reason) [ -n "${2:-}" ] || usage; REASON=$2; shift 2 ;;
    --allow-pr) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage; ALLOW+=("$2"); shift 2 ;;
    --pr) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage; PR=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --force) FORCE=1; shift ;;
    *) usage ;;
  esac
done

if [ -z "$REPO" ]; then
  [ "$CMD" != check ] || usage
  if [ "$CMD" != show ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
      || { say 'no --repo given and the current directory is not a GitHub checkout'; exit 64; }
  fi
fi
REPO=$(printf '%s' "$REPO" | tr 'A-Z' 'a-z')
# Owners cannot contain "_", so owner_name is one file per repository.
file_of() { printf '%s/%s.json' "$DIR" "$(printf '%s' "$1" | tr '/' '_')"; }
NOW=$(date +%s)
iso() { date -u -d "@$1" +%FT%TZ; }

# One freeze file as a line: "<repo> frozen until <iso> by <holder> (<where>): <reason>".
DESCRIBE='"\(.repo) frozen until \(.until | todate) by \(.holder)\(if (.branch // "") != "" then " (branch \(.branch))" else "" end): \(.reason)\(if (.allow_prs | length) > 0 then "; PRs that may merge: \(.allow_prs | map("#\(.)") | join(", "))" else "" end)"'
VALID='type == "object" and (.repo | type) == "string" and (.holder | type) == "string" and (.reason | type) == "string" and (.until | type) == "number" and (.allow_prs | type) == "array"'
# Prints the file's object when it parses as a freeze; fails otherwise.
read_freeze() { jq -ce "select($VALID)" "$1" 2>/dev/null; }

case "$CMD" in
  check)
    F=$(file_of "$REPO")
    [ -e "$F" ] || exit 0
    if ! FZ=$(read_freeze "$F"); then
      echo "the merge-freeze file $F does not parse; nothing merges to $REPO until it is fixed or cleared (merge-freeze.sh release --repo $REPO --force)"
      exit 2
    fi
    UNTIL=$(jq -r '.until' <<<"$FZ") HOLDER=$(jq -r '.holder' <<<"$FZ")
    if [ "$UNTIL" -le "$NOW" ]; then say "ignoring the freeze on $REPO by $HOLDER: it ended $(iso "$UNTIL")"; exit 0; fi
    if [ "$HOLDER" = "$ME" ]; then say "the freeze on $REPO is this session's own; it does not hold its merges"; exit 0; fi
    if [ -n "$PR" ] && jq -e --argjson pr "$PR" 'any(.allow_prs[]; . == $pr)' <<<"$FZ" >/dev/null; then
      say "PR #$PR may merge through the freeze on $REPO by $HOLDER"; exit 0
    fi
    jq -r "$DESCRIBE" <<<"$FZ"
    exit 1 ;;

  hold)
    [ -n "$MINUTES" ] && [ -n "$REASON" ] || usage
    REASON=$(printf '%s' "$REASON" | tr '\n\r\t' '   ' | cut -c1-300)
    F=$(file_of "$REPO")
    mkdir -p "$DIR"
    if [ -e "$F" ]; then
      if FZ=$(read_freeze "$F"); then
        if [ "$(jq -r '.until' <<<"$FZ")" -gt "$NOW" ] && [ "$(jq -r '.holder' <<<"$FZ")" != "$ME" ]; then
          say "refused: $(jq -r "$DESCRIBE" <<<"$FZ")"
          exit 1
        fi
      elif [ "$FORCE" = 0 ]; then
        say "refused: $F does not parse; clear it with release --force first"
        exit 1
      fi
    fi
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    TMPF=$(mktemp "$DIR/.hold.XXXXXX") || { say "could not create a temporary file in $DIR"; exit 2; }
    if ! jq -n --arg repo "$REPO" --arg holder "$ME" --arg session "${CLAUDE_CODE_SESSION_ID:-}" \
        --arg cwd "$PWD" --arg branch "$BRANCH" --arg reason "$REASON" \
        --argjson since "$NOW" --argjson until "$((NOW + MINUTES * 60))" \
        --argjson allow "$(printf '%s\n' "${ALLOW[@]}" | jq -R 'select(length > 0) | tonumber' | jq -s 'unique')" \
        '{repo: $repo, holder: $holder, session: (if $session == "" then null else $session end),
          cwd: $cwd, branch: $branch, reason: $reason, since: $since, until: $until, allow_prs: $allow}' >"$TMPF"; then
      rm -f "$TMPF"; say "writing the freeze failed"; exit 2
    fi
    mv -f "$TMPF" "$F"
    jq -r "$DESCRIBE" "$F" ;;

  release)
    F=$(file_of "$REPO")
    [ -e "$F" ] || { say "no freeze on $REPO"; exit 0; }
    if FZ=$(read_freeze "$F"); then
      HOLDER=$(jq -r '.holder' <<<"$FZ")
      if [ "$HOLDER" != "$ME" ] && [ "$FORCE" = 0 ] && [ "$(jq -r '.until' <<<"$FZ")" -gt "$NOW" ]; then
        say "refused: the freeze on $REPO is held by $HOLDER; pass --force to clear it anyway"
        exit 1
      fi
    elif [ "$FORCE" = 0 ]; then
      say "refused: $F does not parse; pass --force to remove it"
      exit 1
    fi
    rm -f "$F"
    say "released the freeze on $REPO" ;;

  show)
    FILES=()
    if [ -n "$REPO" ]; then
      F=$(file_of "$REPO"); [ ! -e "$F" ] || FILES=("$F")
    elif [ -d "$DIR" ]; then
      for f in "$DIR"/*.json; do [ ! -e "$f" ] || FILES+=("$f"); done
    fi
    if [ "$JSON" = 1 ]; then
      for f in "${FILES[@]}"; do
        read_freeze "$f" | jq -c --argjson now "$NOW" '. + {active: (.until > $now)}' \
          || jq -nc --arg file "$f" '{file: $file, unreadable: true}'
      done | jq -s '.'
      exit 0
    fi
    [ "${#FILES[@]}" -gt 0 ] || { echo 'no merge freezes'; exit 0; }
    for f in "${FILES[@]}"; do
      if FZ=$(read_freeze "$f"); then
        if [ "$(jq -r '.until' <<<"$FZ")" -gt "$NOW" ]; then jq -r "$DESCRIBE" <<<"$FZ"
        else echo "(ended) $(jq -r "$DESCRIBE" <<<"$FZ")"; fi
      else
        echo "(unreadable) $f: clear it with merge-freeze.sh release --repo OWNER/NAME --force"
      fi
    done ;;
esac
