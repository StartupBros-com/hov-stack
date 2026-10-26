#!/usr/bin/env bash
# scripts/public-safety-scan.sh: the tree that becomes public names no private path,
# address, host or repository. CI runs it on every push and pull request; the same script
# gates the public push (restructure plan U18, requirement R28, issue #31).
#
# Every tracked file and every tracked path is scanned, the suites the runner skips
# included, for shapes that
# need no private list to recognise:
#
#   linux-home    /home/<name>, and the -home-<name> project-directory form, for any
#                 <name> outside the placeholder set below
#   macos-home    /Users/<name>
#   windows-home  C:\Users\<name> (either slash, single or doubled) and /mnt/<drive>/Users/<name>
#   email         an address whose domain is not reserved for documentation (example.*,
#                 .test, .invalid, .example, .localhost) and not a git host
#   private-host  a hostname under a tailnet (.ts.net), .lan, .home.arpa, .internal or
#                 .local (mDNS)
#   private-repo  <owner>/<name> for an owner the public-repository list watches, when
#                 <owner>/<name> is not itself on that list
#
# A seventh shape, private-token, is the list of fixed strings this tree must never carry:
# the author's username, addresses, hostnames and private repository names. The list is
# never in the tree. It comes from HOV_STACK_PRIVATE_TOKENS (newline-separated) or from
# <overlay>/private-tokens, the overlay directory being HOV_STACK_OVERLAY or
# ~/.config/hov-stack (restructure plan U16). Without it the scan is structural only and
# says so; --require-tokens makes the missing list a failure, which the pre-push gate
# uses. A public repository's CI cannot carry the list: a fork's pull request sees no
# variables or secrets, so CI runs the structural shapes and the author's pre-push run
# adds the list.
#
# Exceptions live in .public-safety-allow: one TAB-separated line per exception, a path
# pattern, a match pattern (both unanchored EREs), the reason, and optionally the one
# shape the row applies to. A row that matched nothing is reported, not failed; a
# private-token row cannot match while the list is not configured and is reported apart
# from the stale ones. The public-repository list is .public-safety-repos: one
# <owner>/<name> per line, a trailing # comment allowed.
# Hits print as path:line with the shape, or path:path for a hit in the file's own name;
# the matched text is redacted unless --show.
#
# usage: scripts/public-safety-scan.sh [--root DIR] [--rev REV] [--allow FILE]
#          [--repos FILE] [--require-tokens] [--show] [--all]
# exit:  0 clean, 1 a hit outside the allowlist, 2 usage or a missing input
set -uo pipefail

usage() { sed -n '/^# usage:/,/^# exit:/p' "$0" | sed 's/^# //'; }

ROOT=. REV="" ALLOW="" REPOS="" REQUIRE=0 SHOW=0 ALL=0
while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --rev) REV=$2; shift 2 ;;
    --allow) ALLOW=$2; shift 2 ;;
    --repos) REPOS=$2; shift 2 ;;
    --require-tokens) REQUIRE=1; shift ;;
    --show) SHOW=1; shift ;;
    --all) ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) || { echo "no such directory: $ROOT" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git checkout: $ROOT" >&2; exit 2; }
: "${ALLOW:=$ROOT/.public-safety-allow}"
: "${REPOS:=$ROOT/.public-safety-repos}"
[ -f "$ALLOW" ] || { echo "allowlist missing: $ALLOW" >&2; exit 2; }
[ -f "$REPOS" ] || { echo "public repository list missing: $REPOS" >&2; exit 2; }

SHA=""
if [ -n "$REV" ]; then
  SHA=$(git -C "$ROOT" rev-parse --verify --quiet "$REV^{commit}") || { echo "no such revision: $REV" >&2; exit 2; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/public-safety.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- the private-token list -----------------------------------------------------------
TOKENS=$WORK/tokens
TOKEN_SOURCE=""
if [ -n "${HOV_STACK_PRIVATE_TOKENS:-}" ]; then
  printf '%s\n' "$HOV_STACK_PRIVATE_TOKENS" > "$TOKENS"
  TOKEN_SOURCE="HOV_STACK_PRIVATE_TOKENS"
else
  overlay=${HOV_STACK_OVERLAY:-${XDG_CONFIG_HOME:-$HOME/.config}/hov-stack}
  if [ -f "$overlay/private-tokens" ]; then
    cp "$overlay/private-tokens" "$TOKENS"
    TOKEN_SOURCE="<overlay>/private-tokens"  # a role, never the path: the report is pasted into PRs
  fi
fi
if [ -n "$TOKEN_SOURCE" ]; then
  grep -v -E '^[[:space:]]*(#|$)' "$TOKENS" > "$TOKENS.clean" || true
  mv "$TOKENS.clean" "$TOKENS"
  TOKEN_COUNT=$(wc -l < "$TOKENS")
  [ "$TOKEN_COUNT" -gt 0 ] || TOKEN_SOURCE=""
fi
if [ -z "$TOKEN_SOURCE" ] && [ "$REQUIRE" -eq 1 ]; then
  echo "private-token list missing: set HOV_STACK_PRIVATE_TOKENS or write <overlay>/private-tokens" >&2
  echo "  (--require-tokens: the gate before a public push does not run without it)" >&2
  exit 2
fi

# ---- the shapes ------------------------------------------------------------------------
# Placeholder names a fixture or a document may use under a profile directory, matched
# case-insensitively. After /home/ or /Users/ a name may contain hyphens; in the
# -home-<name> project-directory form the name is the first hyphen-separated segment.
PH='user|u|op|x|tester|ubuntu|private|someone|someone-else|probe|example|alice|bob|runner|fixture|name|username|me|you|your|dev|demo|test|ci'
# An all-caps segment (NAME, USER, SITES under a fixture's home root) is a placeholder too.
CAPS='[A-Z0-9_]+'
NOT_PH_SLASH='(?!(?:(?i:'"$PH"')|'"$CAPS"')(?![A-Za-z0-9_-]))'
NOT_PH_SEG='(?!(?:(?i:'"$PH"')|'"$CAPS"')(?![A-Za-z0-9_]))'
NOT_PH_DOT='(?!(?:(?i:'"$PH"'|Shared|Public|Default)|'"$CAPS"')(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-]))'
# A dotted name never ends in a dot, so a sentence-final mention is matched without its period.
DOTNAME='[A-Za-z](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?'
# Slashes may be regex-escaped (\/home\/name) in JavaScript and Python sources, so each
# slash admits a preceding backslash.
RE_LINUX='\\?/home\\?/'"$NOT_PH_SLASH"'[A-Za-z][A-Za-z0-9_-]*'
RE_LINUX_PROJECT='(?<![A-Za-z0-9_-])-home-'"$NOT_PH_SEG"'[A-Za-z][A-Za-z0-9_]*'
RE_MACOS='\\?/Users\\?/'"$NOT_PH_DOT""$DOTNAME"
RE_WINDOWS='(?<![A-Za-z0-9])[A-Za-z]:[\\/]+[Uu]sers[\\/]+'"$NOT_PH_DOT""$DOTNAME"
RE_WINDOWS_MNT='\\?/mnt\\?/[a-z]\\?/Users\\?/'"$NOT_PH_DOT""$DOTNAME"
RE_EMAIL='(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?![A-Za-z0-9.-])'
# A shell variable with a dotted suffix ($edges.internal) is a file name, not a host, and
# a label never carries an underscore, so an attribute (self.local_remaining) is not one
# either; a dotted file name (config.local.json) is saved by its extension.
RE_HOST='(?<![A-Za-z0-9.$}-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:ts\.net|lan|home\.arpa|internal|local)(?![A-Za-z0-9._-])'

# The public-repository list: every <owner>/<name> on it is fine to cite; every other
# <name> under one of its owners is a hit.
PUBLIC=$WORK/public
sed -E 's/#.*$//; s/[[:space:]]+$//; /^$/d' "$REPOS" | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' > "$PUBLIC" || true
if [ ! -s "$PUBLIC" ]; then echo "public repository list has no <owner>/<name> entries: $REPOS" >&2; exit 2; fi
pcre_escape() { sed -E 's/[.]/\\./g'; }
PUBLIC_ALT=$(pcre_escape < "$PUBLIC" | paste -sd '|' -)
OWNER_ALT=$(cut -d/ -f1 "$PUBLIC" | sort -u | pcre_escape | paste -sd '|' -)
# Owners are case-insensitive only in a github.com URL; elsewhere a lowercase spelling is a
# directory name (SITES/<project>/scripts), not a repository. A hyphen before the owner
# makes it part of a hyphenated word, except the `:-` of a shell parameter default
# (`${ORIGIN:-owner/name}`), which is an operator: that default is a mention. The colon-less
# `${V-owner/name}` form is not caught (a fixed-length lookbehind cannot see past the variable
# name) and does not occur in this tree; `word-owner/name` is a hyphenated word (tested).
RE_REPO='(?i)(?:(?<![A-Za-z0-9_.@-])|(?<=:-))(?<!(?<!github\.com)/)(?!(?:'"$PUBLIC_ALT"')(?![A-Za-z0-9_-]))(?:'"$OWNER_ALT"')/[A-Za-z0-9][A-Za-z0-9_.-]*'

# ---- scanning ---------------------------------------------------------------------------
# Hits are TAB-separated rows: shape, path, line, match. git grep -o prints one row per
# match; in --rev mode the leading "<sha>:" is dropped. git grep exits 1 for no match and
# 2 or more on a failure (a bad pattern, a git without PCRE support); a failure stops the
# scan with exit 2, it never passes it.
HITS=$WORK/hits
: > "$HITS"
strip_rev() { if [ -n "$SHA" ]; then sed "s/^$SHA://"; else cat; fi; }
to_rows() { # $1 = shape; stdin = path:line:match
  awk -v shape="$1" -F: '{ path=$1; line=$2; match_text=substr($0, length($1) + length($2) + 3); printf "%s\t%s\t%s\t%s\n", shape, path, line, match_text }'
}
run_grep() { # $1 = shape; the rest = git grep arguments after -nIo
  local shape=$1 rc; shift
  if [ -n "$SHA" ]; then
    git -C "$ROOT" grep -nIo "$@" "$SHA" -- . > "$WORK/grep.out" 2> "$WORK/grep.err"; rc=$?
  else
    git -C "$ROOT" grep -nIo "$@" -- . > "$WORK/grep.out" 2> "$WORK/grep.err"; rc=$?
  fi
  if [ "$rc" -ge 2 ]; then
    echo "git grep failed for shape $shape (exit $rc): $(tr '\n' ' ' < "$WORK/grep.err")" >&2
    exit 2
  fi
  strip_rev < "$WORK/grep.out" | to_rows "$shape" >> "$HITS"
}
run_grep linux-home -P -e "$RE_LINUX"
run_grep linux-home -P -e "$RE_LINUX_PROJECT"
run_grep macos-home -P -e "$RE_MACOS"
run_grep windows-home -P -e "$RE_WINDOWS"
run_grep windows-home -P -e "$RE_WINDOWS_MNT"
run_grep email -P -e "$RE_EMAIL"
run_grep private-host -P -e "$RE_HOST"
run_grep private-repo -P -e "$RE_REPO"
if [ -n "$TOKEN_SOURCE" ]; then run_grep private-token -iF -f "$TOKENS"; fi

# A file's name is published with it, so the same shapes run over the tracked paths. A
# grep failure here stops the scan with exit 2, as it does for the contents.
PATHS=$WORK/paths
if [ -n "$SHA" ]; then git -C "$ROOT" ls-tree -r -z --name-only "$SHA" > "$PATHS.z"; rc=$?
else git -C "$ROOT" ls-files -z > "$PATHS.z"; rc=$?; fi
[ "$rc" -eq 0 ] || { echo "git could not list the tracked paths (exit $rc)" >&2; exit 2; }
tr '\0' '\n' < "$PATHS.z" > "$PATHS"
# A path's bytes need not be valid in the locale. The shapes are ASCII, so the list is read
# as bytes (LC_ALL=C) and as text (-a): no grep may set it aside as binary data.
path_grep() { # $1 = shape; the rest = grep arguments, run over the path list
  local shape=$1 rc; shift
  LC_ALL=C grep -a -no "$@" "$PATHS" > "$WORK/paths.out" 2> "$WORK/paths.err"; rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "grep over the tracked paths failed for shape $shape (exit $rc): $(tr '\n' ' ' < "$WORK/paths.err")" >&2
    exit 2
  fi
  LC_ALL=C awk -v shape="$shape" 'FILENAME == ARGV[1] { p[FNR] = $0; next }
    { i = index($0, ":"); printf "%s\t%s\tpath\t%s\n", shape, p[substr($0, 1, i - 1)], substr($0, i + 1) }' \
    "$PATHS" "$WORK/paths.out" >> "$HITS"
}
path_grep linux-home -P -e "$RE_LINUX"
path_grep linux-home -P -e "$RE_LINUX_PROJECT"
path_grep macos-home -P -e "$RE_MACOS"
path_grep windows-home -P -e "$RE_WINDOWS"
path_grep windows-home -P -e "$RE_WINDOWS_MNT"
path_grep email -P -e "$RE_EMAIL"
path_grep private-host -P -e "$RE_HOST"
path_grep private-repo -P -e "$RE_REPO"
if [ -n "$TOKEN_SOURCE" ]; then path_grep private-token -iF -f "$TOKENS"; fi

# Addresses at documentation-reserved domains and git hosts are not personal, and a
# systemd template instance (name@instance.service) is not an address at all.
awk -F'\t' 'BEGIN { OFS = "\t" }
  $1 != "email" { print; next }
  { d = tolower($4); sub(/^.*@/, "", d)
    if (d ~ /(^|\.)example\.(com|net|org)$/ || d ~ /\.(test|invalid|example|localhost)$/ || d ~ /(^|\.)(github|gitlab)\.com$/) next
    if (d ~ /\.(service|timer|socket|target|slice|mount|path|device|swap|scope)$/) next
    print }' "$HITS" > "$HITS.kept" && mv "$HITS.kept" "$HITS"

# The allowlist: path pattern, match pattern, reason, and an optional shape that confines
# the row. Unused entries are reported, not failed, so a stale exception is visible
# without blocking the push.
bad_shape=$(awk -F'\t' '
  /^[[:space:]]*(#|$)/ { next }
  NF >= 4 && $4 !~ /^(linux-home|macos-home|windows-home|email|private-host|private-repo|private-token)$/ { print NR ": " $4 }' "$ALLOW")
if [ -n "$bad_shape" ]; then
  echo "allowlist $ALLOW names a shape the scan does not have (line: shape):" >&2
  printf '  %s\n' "$bad_shape" >&2
  exit 2
fi
ALLOWED=$WORK/allowed; OPEN=$WORK/open; USED=$WORK/used
awk -F'\t' -v allow="$ALLOW" -v allowed="$ALLOWED" -v open="$OPEN" -v used="$USED" '
  BEGIN { OFS = "\t"; n = 0
    while ((getline line < allow) > 0) {
      if (line ~ /^[[:space:]]*(#|$)/) continue
      k = split(line, f, "\t"); if (k < 3) continue
      n++; P[n] = f[1]; M[n] = f[2]; R[n] = f[3]; S[n] = (k >= 4 ? f[4] : ""); hits[n] = 0 }
    close(allow) }
  { for (i = 1; i <= n; i++) if ((S[i] == "" || S[i] == $1) && $2 ~ P[i] && $4 ~ M[i]) { hits[i]++; print > allowed; next }
    print > open }
  END { for (i = 1; i <= n; i++) print i, hits[i], P[i], M[i], R[i], S[i] > used }' "$HITS"
touch "$ALLOWED" "$OPEN" "$USED"

# ---- report -----------------------------------------------------------------------------
if [ -n "$SHA" ]; then where="revision $SHA"; else where="working tree"; fi
echo "public-safety scan: $(basename "$ROOT") ($where)"
if [ -n "$TOKEN_SOURCE" ]; then echo "private-token list: active ($TOKEN_COUNT entries from $TOKEN_SOURCE)"
else echo "private-token list: not configured (structural shapes only; --require-tokens makes this a failure)"; fi

skips=""
if [ -n "$SHA" ]; then skips=$(git -C "$ROOT" show "$SHA:tests/claude-tests.skips" 2>/dev/null || true)
elif [ -f "$ROOT/tests/claude-tests.skips" ]; then skips=$(cat "$ROOT/tests/claude-tests.skips"); fi
rows=$(printf '%s\n' "$skips" | grep -E '^(xfail|skip)[[:space:]]' || true)
if [ -n "$rows" ]; then
  echo "excluded from the test run by tests/claude-tests.skips, sources scanned like any other tracked file:"
  printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %-5s %s\n", $1, $2 }'
fi

redact() { # $1 = match
  if [ "$SHOW" -eq 1 ]; then printf '%s' "$1"; else printf '[redacted, %d chars]' "${#1}"; fi
}
open_count=$(wc -l < "$OPEN")
if [ "$open_count" -gt 0 ]; then
  echo "hits outside the allowlist:"
  for shape in linux-home macos-home windows-home email private-host private-repo private-token; do
    shown=0; total=$(awk -F'\t' -v s="$shape" '$1 == s' "$OPEN" | wc -l)
    [ "$total" -gt 0 ] || continue
    while IFS=$'\t' read -r _ path line text; do
      if [ "$ALL" -eq 0 ] && [ "$shown" -ge 10 ]; then
        echo "  ... and $((total - shown)) more $shape hits (--all lists them)"; break
      fi
      echo "  $path:$line  $shape  $(redact "$text")"
      shown=$((shown + 1))
    done < <(awk -F'\t' -v s="$shape" '$1 == s' "$OPEN")
  done
fi
if [ -n "$TOKEN_SOURCE" ]; then tokens_on=1; else tokens_on=0; fi
unexercised=$(awk -F'\t' -v on="$tokens_on" 'on == 0 && $2 == 0 && $6 == "private-token" { printf "  %s\t%s\t%s\n", $3, $4, $5 }' "$USED")
if [ -n "$unexercised" ]; then
  echo "allowlist entries for the private-token shape, not exercised because the list is not configured:"
  printf '%s\n' "$unexercised"
fi
unused=$(awk -F'\t' -v on="$tokens_on" '$2 == 0 && !(on == 0 && $6 == "private-token") { printf "  %s\t%s\t%s\n", $3, $4, $5 }' "$USED")
if [ -n "$unused" ]; then echo "allowlist entries that matched nothing (stale?):"; printf '%s\n' "$unused"; fi

echo "summary (matches, files, allowlisted):"
for shape in linux-home macos-home windows-home email private-host private-repo private-token; do
  o=$(awk -F'\t' -v s="$shape" '$1 == s' "$OPEN" | wc -l)
  f=$(awk -F'\t' -v s="$shape" '$1 == s { print $2 }' "$OPEN" | sort -u | wc -l)
  a=$(awk -F'\t' -v s="$shape" '$1 == s' "$ALLOWED" | wc -l)
  printf '  %-14s %6d %6d %6d\n' "$shape" "$o" "$f" "$a"
done
files=$(cut -f2 "$OPEN" | sort -u | wc -l)
if [ "$open_count" -gt 0 ]; then
  echo "result: FAIL ($open_count hits in $files files)"
  exit 1
fi
echo "result: PASS (0 hits outside the allowlist)"
exit 0
