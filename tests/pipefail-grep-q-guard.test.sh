#!/usr/bin/env bash
# pipefail-grep-q-guard.test.sh — Structural guard: no shell-builtin writer piped into
# `grep -q` in any pipefail shell file in this repository (dotfiles#1460, #1463).
#
# WHY THIS EXISTS
#   Under `set -o pipefail`, `printf '%s' "$v" | grep -q PAT` (or echo) races. bash's
#   printf and echo builtins issue one write() per line into the pipe, grep -q exits
#   on its first match, and a later write lands on a closed pipe, so the pipeline
#   carries the writer's failure: a silent SIGPIPE locally, "printf: write error:
#   Broken pipe" exit 1 on the Actions runner where SIGPIPE is ignored. A positive
#   assertion flakes; a negated one (`! … | grep -q`) silently false-passes whenever
#   the pattern sits on a non-last line. It is a timing race that only shows under
#   CPU contention (0 failures in 4,000 uncontended iterations, 5 in 18,000 with 12
#   copies pinned to one core), so it cannot be caught by running the code; the only
#   durable guard is structural. #1464 rewrote 416 sites in tests and #1463's
#   PR the 22 in runtime scripts. This keeps the count at zero.
#
#   The safe form is a here-string, `grep -q PAT <<<"$v"`: bash writes the expanded
#   text itself before grep runs, so there is no writer process to signal. For an
#   array, `printf -v joined '%s\n' "${arr[@]}"` first, then the here-string.
#
# SCOPE
#   Every tracked file that contains `pipefail` and is a shell script (a .sh
#   extension, or a sh/bash shebang on line 1 for extensionless tools such as
#   bin/*). Comment lines are skipped, because the rule is documented in code
#   next to the sites it replaced, and the writer must carry a `$` expansion, so a
#   quoted description of the shape inside a message string does not fire the guard.
#   Without pipefail the pipeline's status is grep's own and the shape is harmless,
#   so those files are out of scope on purpose.
#
# The scanner is exercised on a fixture tree first (four planted positives across
# the .sh, `command grep`, /usr/bin/grep and extensionless-shebang spellings; five
# planted negatives), so a clean live tree is a verdict and not a blind scanner.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# Writer (printf/echo with a $-expansion), pipe, reader: grep with a q flag in any of its
# spellings -- bare, `command grep`, a path such as /usr/bin/grep, or the alias-dodging \grep.
# (The first review round of #1463 found wacli-install.sh's /usr/bin/grep site hiding from a
# bare-grep regex.)
SHAPE='(printf|echo)[[:space:]][^|]*\$[^|]*\|[[:space:]]*(command[[:space:]]+)?(\\|[^[:space:]|]*/)?grep[[:space:]]+(-[A-Za-z]*q|-[A-Za-z]+[[:space:]]+-[A-Za-z]*q|--quiet|--silent)'

# shell_files <dir>: pipefail-bearing files that are shell scripts, sorted.
shell_files() {
  local f
  grep -rl --exclude-dir=node_modules --exclude-dir=.git -- 'pipefail' "$1" 2>/dev/null | sort | while IFS= read -r f; do
    case $f in
      *.sh) ;;
      *) head -n1 -- "$f" 2>/dev/null | grep -qE '^#!.*(ba)?sh([[:space:]]|$)' || continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# scan <dir>: file:line:text for every offending non-comment line.
scan() {
  local f
  shell_files "$1" | while IFS= read -r f; do
    grep -nE -- "$SHAPE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done
}

# ---- 1. Scanner self-test on a fixture tree ----------------------------------
FX="$TMP/fx"
mkdir -p "$FX/bin" "$FX/docs"
P='|'   # the pipe is spliced in so these source lines never match SHAPE themselves
{
  echo 'set -uo pipefail'
  echo 'printf '"'"'%s'"'"' "$out" '"$P"' grep -q needle && ok'
} > "$FX/pos-printf.sh"
{
  echo 'set -euo pipefail'
  echo 'if ! echo "$x" '"$P"' command grep -qF needle; then bad; fi'
} > "$FX/pos-command-grep.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -o pipefail'
  echo 'elif printf '"'"' %s '"'"' "$FOREIGN" '"$P"' grep -qF " $base "; then'
} > "$FX/bin/pos-extensionless"
{
  echo '#!/usr/bin/bash'
  echo 'set -euo pipefail'
  echo 'printf '"'"'%s\n'"'"' "$doctor" '"$P"' /usr/bin/grep -Eq '"'"'^FTS5'"'"' || exit 1'
} > "$FX/pos-path-grep.sh"
{
  echo 'set -uo pipefail'
  echo 'grep -q needle <<<"$out" && ok'
  echo '# printf '"'"'%s'"'"' "$out" '"$P"' grep -q needle is unsafe here; see #1460'
  echo 'fail "found '"'"'printf '"$P"' grep -q'"'"' in $S"'
  echo 'n=$(printf '"'"'%s'"'"' "$out" '"$P"' grep -c needle)'
  echo 'printf '"'"'%s'"'"' "$out" '"$P"' grep needle'
} > "$FX/neg-safe-forms.sh"
{
  echo 'set -u'
  echo 'printf '"'"'%s'"'"' "$out" '"$P"' grep -q needle && ok'
} > "$FX/neg-no-pipefail.sh"
{
  echo 'set -o pipefail'
  echo 'printf '"'"'%s'"'"' "$out" '"$P"' grep -q needle'
} > "$FX/docs/neg-not-a-shell-file.md"
{
  echo 'no shebang, no extension'
  echo 'set -o pipefail'
  echo 'printf '"'"'%s'"'"' "$out" '"$P"' grep -q needle'
} > "$FX/bin/neg-no-shebang"

FX_HITS=$(scan "$FX")
FX_EXPECT="$FX/bin/pos-extensionless:3:elif printf ' %s ' \"\$FOREIGN\" $P grep -qF \" \$base \"; then
$FX/pos-command-grep.sh:2:if ! echo \"\$x\" $P command grep -qF needle; then bad; fi
$FX/pos-path-grep.sh:3:printf '%s\n' \"\$doctor\" $P /usr/bin/grep -Eq '^FTS5' || exit 1
$FX/pos-printf.sh:2:printf '%s' \"\$out\" $P grep -q needle && ok"
[ "$FX_HITS" = "$FX_EXPECT" ] && ok || bad "fixture scan: expected exactly the four planted positives; got:
$FX_HITS"

FX_FILES=$(shell_files "$FX" | wc -l)
[ "$FX_FILES" -eq 5 ] && ok || bad "fixture file discovery: expected 5 pipefail shell files (4 positives + neg-safe-forms.sh; no-pipefail, .md and no-shebang files stay out), got $FX_FILES"

# ---- 2. The live tree ---------------------------------------------------------
LIVE_FILES=$(shell_files "$ROOT" | wc -l)
[ "$LIVE_FILES" -ge 50 ] && ok || bad "live discovery reached only $LIVE_FILES pipefail shell files under $ROOT; the scanner is not seeing the tree"

LIVE_HITS=$(scan "$ROOT")
[ -z "$LIVE_HITS" ] && ok || bad "builtin writer piped into grep -q under pipefail (SIGPIPE race, dotfiles#1460): rewrite as grep -q PAT <<<\"\$var\"
$LIVE_HITS"

echo "pipefail-grep-q-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
