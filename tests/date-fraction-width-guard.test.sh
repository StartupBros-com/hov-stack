#!/usr/bin/env bash
# date-fraction-width-guard.test.sh: no `date` format in a shell script or workflow file asks for
# a fixed-width fraction of a second (%3N, %6N, %-3N and the like). Bare %N is the safe form.
#
# WHY THIS EXISTS
#   Ubuntu 26.04 ships uutils date (rust-coreutils 0.10.0-1ubuntu2~26.04.1). With a width, it
#   drops the fraction's leading zeros before cutting it, so `date +%s%3N` at 12.0967 s prints
#   12967 where GNU prints 12096 (uutils/coreutils#15697). For the first tenth of every second
#   the reading is up to 900 ms high and can run backwards. claude-loop's run window missed its
#   own gateway rows that way: tests/discord-notify.test.sh U4e2 failed 2 of 12 runs on
#   ubuntu:26.04. %N alone keeps all nine digits on GNU and uutils; trim six digits for ms.
#   GNU's tests pass either way, so the defect cannot be caught by running the code on a GNU
#   host. This structural check holds the count at zero.
#
# SCOPE AND RETIREMENT
#   Tracked files that are shell scripts (a .sh extension, or a sh/bash shebang on line 1) or
#   workflow YAML (.yml/.yaml, whose run: steps execute on the runner's date). Comment lines
#   are skipped, because the sites that were fixed cite the bad form next to the fix. Delete
#   this guard when every image the stack supports ships a date that keeps the leading zeros
#   (uutils/coreutils#15698 or later, in Ubuntu's rust-coreutils package).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# A percent sign, optional strftime flags, a width, then N. Bare %N has no width and passes.
SHAPE='%[-_0^#]*[0-9]+N'

# candidates <dir>: tracked files at the top of a git work tree (untracked nested worktrees on a
# dev host stay out); a recursive listing anywhere else, which the fixture below relies on.
candidates() {
  local top f
  if top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) &&
    [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ]; then
    git -C "$1" ls-files -z | while IFS= read -r -d '' f; do
      [ -f "$1/$f" ] && printf '%s\n' "$1/$f"
    done
  else
    find "$1" -type f -not -path '*/.git/*' -not -path '*/node_modules/*'
  fi
}

# in_scope <dir>: shell scripts and workflow YAML among the candidates, sorted.
in_scope() {
  local f
  candidates "$1" | sort | while IFS= read -r f; do
    case $f in
      *.sh | *.yml | *.yaml) ;;
      *) head -n1 -- "$f" 2>/dev/null | grep -qE '^#!.*(ba)?sh([[:space:]]|$)' || continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# scan <dir>: file:line:text for every non-comment line that uses the shape.
scan() {
  local f
  in_scope "$1" | while IFS= read -r f; do
    grep -nE -- "$SHAPE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done
}

# ---- 1. Scanner self-test on a fixture tree ----------------------------------
FX="$TMP/fx"
mkdir -p "$FX/bin" "$FX/docs" "$FX/.github/workflows"
P='%'   # spliced in so these source lines never match SHAPE themselves
printf '%s\n' 'set -euo pipefail' 'START_MS=$(date +%s'"$P"'3N)' > "$FX/pos-ms.sh"
printf '%s\n' '#!/usr/bin/env bash' 'now() { date -u +%H:%M:%S.'"$P"'-6NZ; }' > "$FX/bin/pos-extensionless"
printf '%s\n' 'jobs:' '  t:' '    steps:' '      - run: echo "$(date +'"$P"'_9N)"' > "$FX/.github/workflows/pos.yml"
{
  echo 'ns=$(date +%s%N); ms=${ns%??????}'
  echo '# date +%s'"$P"'3N reads high on uutils; see #15697'
  echo '  # indented comment: date +'"$P"'6N'
  echo 'printf "%3d %s\n" "$n" "$x"'
} > "$FX/neg-safe-forms.sh"
printf '%s\n' 'date +%s'"$P"'3N' > "$FX/docs/neg-not-a-script.md"
printf '%s\n' 'no shebang, no extension' 'date +%s'"$P"'3N' > "$FX/bin/neg-no-shebang"

FX_HITS=$(scan "$FX")
FX_EXPECT="$FX/.github/workflows/pos.yml:4:      - run: echo \"\$(date +${P}_9N)\"
$FX/bin/pos-extensionless:2:now() { date -u +%H:%M:%S.${P}-6NZ; }
$FX/pos-ms.sh:2:START_MS=\$(date +%s${P}3N)"
[ "$FX_HITS" = "$FX_EXPECT" ] && ok || bad "fixture scan: expected exactly the three planted positives; got:
$FX_HITS"

# ---- 2. The live tree --------------------------------------------------------
N_FILES=$(in_scope "$ROOT" | wc -l)
[ "$N_FILES" -gt 100 ] && ok || bad "only $N_FILES in-scope files under $ROOT; the scan is not reaching the tree"
LIVE=$(scan "$ROOT")
[ -z "$LIVE" ] && ok || bad "fixed-width date fraction (wrong on uutils date; use %N and trim):
$LIVE"

echo "date-fraction-width-guard: $pass passed, $fail failed (scanned $N_FILES files)"
[ "$fail" -eq 0 ]
