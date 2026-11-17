#!/usr/bin/env bash
# Fail a release whose notes would announce developer shorthand to customers.
#
# The canonical marketplace announcer reads a "## Highlights" section from the release body
# and falls back to GitHub's auto-generated PR titles when it is absent — which is exactly how
# two earlier releases announced branch-name shorthand to customers. This check makes that
# failure loud at release time instead of silent in front of customers.
#
# Usage: check-release-notes.sh <notes-file|-> [--members-version <v>] [--carry <notes-file>]...
#   "-" reads the body on stdin.
#   --members-version  the version the marketplace lists, which is what members have; a
#                      "Changes since vX" line naming a newer X fails.
#   --carry            notes of an earlier version that has not reached members; each of
#                      its Highlights bullets must appear in these Highlights (#702).
# plugin-ci.sh passes both on a bump. Conventions in docs/release/plugin-release-recipe.md,
# section "Release notes".
set -euo pipefail
# shellcheck source=release/scripts/plugin-tag.sh
source "$(dirname "${BASH_SOURCE[0]}")/plugin-tag.sh"

usage() { echo "usage: check-release-notes.sh <notes-file|-> [--members-version <v>] [--carry <notes-file>]..." >&2; exit 2; }
src="${1:-}"
[ -n "$src" ] || usage
shift
members=''; carry=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --members-version)
      if [ "$#" -lt 2 ] || ! is_release_semver "$2"; then usage; fi
      members="$2"; shift 2 ;;
    --carry) [ "$#" -ge 2 ] || usage; carry+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done
if [ "$src" = "-" ]; then notes="$(cat)"; else
  [ -f "$src" ] || { echo "::error::no such release notes file: $src" >&2; exit 2; }
  notes="$(cat "$src")"
fi
notes="$(printf '%s' "$notes" | tr -d '\r')"

fails=0
problem() { printf '::error::%s: %s\n' "$src" "$*" >&2; fails=$((fails + 1)); }

# Mirror the canonical marketplace announcer's Highlights extraction so this checks the text
# customers receive rather than a lookalike.
highlights="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -E '^[*•-][[:space:]]' || true)"

# NEVER `printf ... | grep -q` here (a review finding). `grep -q` exits the moment it matches,
# so printf takes SIGPIPE and, under `set -o pipefail`, the pipeline reports 141 — the
# "Highlights missing" branch then fires on notes that DO have the section. Verified: a body
# with a long Details section failed 20/20 runs, which would have published auto-generated
# branch-name copy for a perfectly good release. Match against the variable instead, which
# consumes nothing and cannot break.
case "$notes" in
  '##'*Highlights*|*$'\n##'*Highlights*) has_highlights=1 ;;
  *) has_highlights=0 ;;
esac
if [ "$has_highlights" = 0 ]; then
  problem "no '## Highlights' section — customers would receive auto-generated PR titles instead of release notes"
elif [ -z "$highlights" ]; then
  problem "'## Highlights' section has no bullets"
fi

# Wrapped bullets are a silent truncation (a review finding): the canonical announcer keeps only
# physical lines starting with a marker, so a bullet continued on an indented next line reaches
# customers as its first clause alone — grammatical, plausible, and missing the point. Reject
# rather than join, because joining would change what the announcer sends. Authors write one
# bullet per line.
while IFS= read -r hl; do
  case "$hl" in
    '  '*|$'\t'*) problem "a Highlights bullet is wrapped onto a continuation line; the announcement keeps only the first line — put each bullet on ONE line: ${hl#"${hl%%[![:space:]]*}"}" ;;
  esac
done <<EOF
$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -vE '^[[:space:]]*$' | grep -vE '^##')
EOF

if [ -n "$highlights" ]; then
  n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    # TWO views of each bullet (a review finding):
    #   raw  — the marker stripped only, so a conventional-commit prefix is still visible and
    #          can be reported as "this is a commit subject, not customer copy";
    #   text — normalized as the canonical marketplace summary will normalize it, so every OTHER rule
    #          inspects the bytes customers actually receive. Checking only the raw line let
    #          "feat!: memo-crossbind" pass and still ship as bare "memo-crossbind"; checking
    #          only the normalized text would hide raw subjects entirely.
    # Keep this transform aligned with hov-marketplace's canonical summary normalization.
    raw="$(printf '%s' "$line" | sed -E 's/^[*•-][[:space:]]+//')"
    text="$(printf '%s' "$raw" | sed -E '
      s/[[:space:]]+by @[A-Za-z0-9_[:punct:]]+ in http[^[:space:]]*[[:space:]]*$//
      s/^(feat|fix|perf|chore|docs|refactor|test|ci|build)(\([^)]*\))?!?:[[:space:]]*//
      s/[[:space:]]*\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$//
      s/[[:space:]]+$//
    ')"
    # Prefix check on the RAW line (normalization already stripped the known types).
    # GENERIC, not an allowlist (a review finding): Conventional Commit types are open-ended, so
    # `revert:`, `deps:` or any project-specific type sailed through a fixed nine-type list and
    # reached customers verbatim. Match the SHAPE instead — a lowercase token, optional
    # (scope), optional !, then ": " — which is what a commit subject looks like and what
    # customer prose never does.
    # All matches use grep <<< (here-string): the producer is bash itself, so an early -q exit
    # cannot SIGPIPE a printf and poison $? under pipefail (same class of bug as the Highlights
    # detection above).
    if grep -qE '^[a-z][a-z0-9_-]*(\([^)]*\))?!?:[[:space:]]' <<<"$raw"; then
      problem "bullet $n is a raw commit subject: ${raw:0:60}"
    fi
    if grep -qE ' by @[A-Za-z0-9_-]+ in http' <<<"$text"; then
      problem "bullet $n still carries a 'by @user in <url>' tail: ${text:0:60}"
    fi
    if grep -qE '(^|[[:space:]])#[0-9]+([[:space:]]|$|\))' <<<"$text"; then
      problem "bullet $n references an issue/PR number — link it under Details instead: ${text:0:60}"
    fi
    # A bare branch-name bullet: no spaces, dash/slash separated. "governor-rounds" exactly.
    if grep -qE '^[A-Za-z0-9]+([-/][A-Za-z0-9]+)+$' <<<"$text"; then
      problem "bullet $n looks like a branch name, not a sentence: ${text:0:60}"
    fi
    # Count what the FEED counts (a review finding). The canonical announcer truncates each bullet
    # with utf16_prefix(line, 180) — astral characters (emoji) cost 2 units — while bash
    # ${#text} counts code points. A bullet of 145 characters including 45 emoji is 190 units:
    # it passed here and still reached customers with its tail silently removed. python3 is
    # already required by the release path, and is what the announcer itself uses.
    units="$(printf '%s' "$text" | python3 -c 'import sys
print(sum(2 if ord(c) > 0xFFFF else 1 for c in sys.stdin.read()))')"
    [ "$units" -gt 180 ] && problem "bullet $n is $units UTF-16 units; the feed truncates at 180"
    # Check what the CARD prints. The members' Tool Drop card shows the first three bullets
    # through the members site's sanitize(): it drops links and mentions, keeping a masked
    # link's words, then deletes every backtick and * _ ~ > | # [ ] { } ( ) without a word of
    # warning. So `MEMORY_DREAM_PASS_ROOT` reaches members as MEMORYDREAMPASSROOT and `<pdf>` as <pdf.
    # The link step runs first here too, so a masked link's brackets or a URL's underscores
    # never count. When this rule landed (2026-11-13), 32 of the 104 notes files on main had
    # such a bullet in their first three.
    # A bullet the card cleans down to nothing (only a link or mention, a "# " heading, a
    # "**Full Changelog**" line) is skipped, and the card fills its three from later bullets
    # that this check never looked at. Fail it instead, so the first three stay the card's.
    if [ "$n" -le 3 ]; then
      carded="$(printf '%s' "$text" | python3 -c 'import re, sys
t = sys.stdin.read()
if re.match(r"#+\s", t):
    t = ""
t = re.sub(r"\*\*Full Changelog\*\*.*$", "", t, flags=re.I)
t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)
t = re.sub(r"<https?://[^>]+>", "", t, flags=re.I)
t = re.sub(r"https?://\S+", "", t, flags=re.I)
t = re.sub(r"<@&?\d+>|<@!\d+>|<#[0-9]+>", "", t)
shown = re.sub(r"\s+", " ", re.sub(r"[`*_~>|#\[\]{}()]", "", t)).strip()
if not shown:
    print("drop")
elif re.search(r"[`*_~>|#\[\]{}()]", t):
    print("strip " + shown)')"
      case "$carded" in
        drop) problem "bullet $n is only a link, mention, heading or Full Changelog line; the Tool Drop card skips it and shows a later bullet in its place" ;;
        strip\ *) problem "bullet $n has characters the Tool Drop card deletes (backticks, * _ ~ > | # [ ] { } and parentheses); members would read: ${carded:6:120}" ;;
      esac
    fi
    [ "${#text}" -lt 15 ] && problem "bullet $n is too short to say anything useful: ${text:0:60}"
  done <<EOF
$highlights
EOF
  [ "$n" -gt 3 ] && printf '  ! %s\n' "note: $n bullets; only the first 3 reach the announcement feed" >&2
fi

# Each Highlights bullet of a body, with its marker and trailing space removed.
bullets_of() {
  printf '%s\n' "$1" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -E '^[*•-][[:space:]]' \
    | sed -E 's/^[*•-][[:space:]]+//; s/[[:space:]]+$//' || true
}

# A version that has not reached members when this one goes out may never be announced:
# the publisher publishes only the newest draft a card names, and the Tool Drop card reads
# only that release's Highlights. So v0.3.4's new skill went unannounced behind v0.3.5,
# whose notes said nothing changed (#702). Carry its bullets word for word, or, when one
# no longer holds, edit it in that version's notes file in the same change so they match.
if [ "${#carry[@]}" -gt 0 ]; then
  have="$(bullets_of "$notes")"
  for older in "${carry[@]}"; do
    if [ ! -f "$older" ]; then problem "no such notes file to carry: $older"; continue; fi
    ver="$(basename "$older" .md)"
    while IFS= read -r bullet; do
      [ -n "$bullet" ] || continue
      grep -Fxq -- "$bullet" <<<"$have" \
        || problem "$ver has not reached members, and the card announces only this release; put its Highlights bullet in these Highlights word for word, or edit it in $older to match: ${bullet:0:80}"
    done <<<"$(bullets_of "$(tr -d '\r' <"$older")")"
  done
fi

# A "Changes since vX" line describes the change from what members have, so X may not be
# newer than the version the marketplace lists.
if [ -n "$members" ]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^[Cc]hanges\ since\ v([0-9]+\.[0-9]+\.[0-9]+) ]] && release_semver_gt "${BASH_REMATCH[1]}" "$members"; then
      problem "'Changes since v${BASH_REMATCH[1]}' names a version members do not have; the marketplace lists v$members, so write 'Changes since v$members'"
    fi
  done <<<"$notes"
fi

if [ "$fails" -gt 0 ]; then
  printf '\n::error::release notes are not customer-ready (%d problem(s)). See docs/release/plugin-release-recipe.md, section "Release notes"\n' "$fails" >&2
  exit 1
fi
echo "release notes OK"
