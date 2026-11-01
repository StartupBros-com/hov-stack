#!/usr/bin/env bash
# Tests for scripts/tool-smoke.sh.
#
# The point of this suite is that a smoke check must see the copies PATH resolution HIDES.
# Cases 3, 4 and 6 are the planted negatives, one per defect that motivated the script:
#
#   3 — probe only `command -v` instead of walking $PATH and the broken-but-shadowed copy
#       goes unreported. That is the exact shape of the 2026-08-07 ast-grep incident: a dead
#       ~/.local/bin/ast-grep behind a healthy mise one, failing in every session whose PATH
#       lacked mise activation while `which ast-grep` looked fine.
#   4 — enumerate copies with `which -a`/`type -a` instead of walking $PATH and the dangling
#       symlink becomes invisible; both silently omit a link whose target is missing.
#   6 — drop the reject-regex arm and a tool that exits 0 while printing only an error reads
#       as healthy, because a version number inside the error text satisfies the expect arm.
#
# Each was verified failing in the inverted state before this suite was called done.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ if eval "$1"; then ok; else bad "$2"; fi; }

# Source the helpers only — the guard stops the file before it probes the real machine.
TOOL_SMOKE_SOURCED=1
# shellcheck source=/dev/null
. "$REPO/scripts/tool-smoke.sh"

# Two fixture bin dirs standing in for "mise's copy" and "pnpm's copy". Order matters:
# EARLY is what PATH selects, LATE is what it shadows.
EARLY=$TMP/early; LATE=$TMP/late
mkdir -p "$EARLY" "$LATE"
PATH="$EARLY:$LATE:/usr/bin:/bin"
export PATH

# make_bin <dir> <name> <exit-code> <stdout...>
make_bin() {
  local dir=$1 name=$2 rc=$3; shift 3
  { printf '#!/bin/sh\n'; printf 'cat <<%s\n' "EOF_FIXTURE"; printf '%s\n' "$*"; printf 'EOF_FIXTURE\n'; printf 'exit %s\n' "$rc"; } >"$dir/$name"
  chmod +x "$dir/$name"
}

# Sets two globals: $out (captured report) and $FLAGGED (the counter).
# Deliberately NOT `out=$(run ...)` — a command substitution is a subshell, so every
# FLAGGED increment would be discarded and each counter assertion below would silently
# pass against zero. Redirect to a file and read it back instead.
run() { FLAGGED=0; smoke_cmd "$@" >"$TMP/last-out" 2>&1; out=$(cat "$TMP/last-out"); }

# ── 1. healthy single copy: reports ok, flags nothing ────────────────────────────────────
make_bin "$EARLY" toolA 0 "toolA 1.2.3"
run toolA '^toolA [0-9]+\.[0-9]+\.[0-9]+' - - --version
check '[ "$FLAGGED" -eq 0 ]'                    "healthy tool was flagged"
check 'grep -q "ok" <<<"$out"'         "healthy tool did not report ok"

# ── 2. broken SELECTED copy: flagged, and named as the live one ──────────────────────────
make_bin "$EARLY" toolB 1 "toolB shim was executed. Did your package manager run postinstall?"
run toolB '^toolB [0-9]' - - --version
check '[ "$FLAGGED" -eq 1 ]'                              "broken selected copy was not flagged"
check 'grep -q "SELECTED copy is BROKEN" <<<"$out"' "broken selected copy was not named as selected"

# ── 3. PLANTED NEGATIVE: broken SHADOWED copy behind a healthy one ───────────────────────
# `command -v toolC` returns the healthy EARLY copy. A check that trusts it reports all-clear.
make_bin "$EARLY" toolC 0 "toolC 2.0.0"
make_bin "$LATE"  toolC 1 "toolC shim file was executed."
run toolC '^toolC [0-9]' - - --version
check '[ "$FLAGGED" -eq 1 ]'                             "broken SHADOWED copy went unreported (the ast-grep incident)"
check 'grep -q "shadowed copy is BROKEN" <<<"$out"' "shadowed breakage was not labelled as shadowed"
check 'grep -q "Latent" <<<"$out"'              "shadowed breakage did not explain it goes live on a PATH change"

# ── 4. PLANTED NEGATIVE: dangling symlink is invisible to which -a / type -a ─────────────
ln -s "$TMP/definitely-not-here/toolD" "$EARLY/toolD"
make_bin "$LATE" toolD 0 "toolD 3.1.4"
check '! type -a toolD 2>/dev/null | grep -q "early"'  "fixture invalid: type -a unexpectedly saw the dangling link"
run toolD '^toolD [0-9]' - - --version
check '[ "$FLAGGED" -eq 1 ]'                            "dangling symlink on PATH went undetected"
check 'grep -q "dangling symlink" <<<"$out"'   "dangling symlink was not reported as such"
check 'grep -q "definitely-not-here" <<<"$out"' "dangling report did not name the missing target"

# ── 5. exit 0 with wrong output is still broken ──────────────────────────────────────────
make_bin "$EARLY" toolE 0 "some unrelated banner"
run toolE '^toolE [0-9]' - - --version
check '[ "$FLAGGED" -eq 1 ]'                          "exit 0 with non-matching output was not flagged"
check 'grep -q "exit 0 but output did not match" <<<"$out"' "exit-0 mismatch was misreported"

# ── 6. PLANTED NEGATIVE: exit 0, expect-regex MATCHES, but output is an error ────────────
# The live gemini case: the only version-looking string is inside a docs URL in the error.
make_bin "$EARLY" toolF 0 "Invalid configuration in settings.json:" "See: https://example.com/docs/reference/configuration/0.32.1"
run toolF '[0-9]+\.[0-9]+\.[0-9]+' 'Invalid configuration|Error in:' - --version
check '[ "$FLAGGED" -eq 1 ]'                        "exit 0 + version-in-error-text passed as healthy"
check 'grep -q "also matched" <<<"$out"'   "reject-regex hit was not explained"
# ...and the same binary with no reject pattern is exactly the false negative being guarded.
run toolF '[0-9]+\.[0-9]+\.[0-9]+' - - --version
check '[ "$FLAGGED" -eq 0 ]'                        "fixture invalid: expect-arm alone should have passed here"

# ── 7. owner-hint skips an unrelated binary of the same name ─────────────────────────────
# Real case: ast-grep installs `sg`, and util-linux ships an unrelated /usr/bin/sg.
make_bin "$EARLY" toolG 1 "Usage: toolG group [[-c] command]"
run toolG '^ourtool [0-9]' - ast-grep --version
check '[ "$FLAGGED" -eq 0 ]'                             "unrelated same-named binary was miscounted as broken"
check 'grep -q "unrelated binary" <<<"$out"'    "unrelated binary was not reported as skipped"

# ── 8. a tool that is simply absent is skipped, not flagged ──────────────────────────────
run toolH '^toolH' - - --version
check '[ "$FLAGGED" -eq 0 ]'                       "absent tool was flagged instead of skipped"
check 'grep -q "not on PATH" <<<"$out"'   "absent tool was not reported as skipped"

# ── 9. err_line surfaces the meaningful line, not the first ──────────────────────────────
# A node stack trace opens with an internal loader path that says nothing useful.
stack='node:internal/modules/cjs/loader:1424
  throw err;
Error: Cannot find module '"'"'../build/Release/keytar.node'"'"''
check '[ "$(err_line "$stack")" = "Error: Cannot find module '"'"'../build/Release/keytar.node'"'"'" ]' \
                                                   "err_line returned the useless first line of a stack trace"

# ── 10. path_copies finds every copy, in PATH order, including the dangling one ──────────
mapfile -t found < <(path_copies toolD)
check '[ "${#found[@]}" -eq 2 ]'                   "path_copies did not find both copies of toolD"
check '[ "${found[0]}" = "$EARLY/toolD" ]'         "path_copies did not return copies in PATH order"

# ── 12. an ANCHORED expect-regex catches the version-in-a-URL case on its own ────────────
# Same fixture as case 6 but with NO reject pattern. Unanchored, the semver inside the docs
# URL matches and the tool reads as healthy; anchored to a whole line, it cannot. This is why
# the real gemini probe anchors rather than relying on the reject list being exhaustive.
run toolF '^[0-9]+\.[0-9]+\.[0-9]+$' - - --version
check '[ "$FLAGGED" -eq 1 ]'                       "anchored expect-regex still matched a version inside a URL"

# ── 11. production probe registration + trailing counter ────────────────────────────────
# A generic smoke helper test cannot prove a new production row was actually wired.
check 'grep -qE "^smoke_cmd wacli[[:space:]]" "$REPO/scripts/tool-smoke.sh"' \
                                                   "wacli has no production proof-of-life probe"
check 'grep -qE "^smoke_cmd gsc[[:space:]]" "$REPO/scripts/tool-smoke.sh"' \
                                                   "gsc has no production proof-of-life probe"
check 'grep -qE "^smoke_cmd dfs[[:space:]]" "$REPO/scripts/tool-smoke.sh"' \
                                                   "dfs has no production proof-of-life probe"
check 'grep -qE "^smoke_cmd firecrawl-cli[[:space:]]" "$REPO/scripts/tool-smoke.sh"' \
                                                   "firecrawl-cli has no production proof-of-life probe"
check 'grep -qF "\"\$installer\" --check" "$REPO/scripts/tool-smoke.sh"' \
                                                   "wacli proof-of-life omits exact hash/link verification"
saved_home=$HOME
HOME=$TMP/no-wacli-installer
FLAGGED=0
check_wacli_pin >"$TMP/missing-pin-out"
HOME=$saved_home
check '[ "$FLAGGED" -eq 1 ]'                    "missing wacli installer was not flagged"
check 'grep -q "pin/link verification unavailable" "$TMP/missing-pin-out"' \
                                                   "missing installer warning was not actionable"
real_out=$(bash "$REPO/scripts/tool-smoke.sh" 2>&1 || true)
check 'grep -qE "^toolsmoke-flagged:[0-9]+$" <<<"$real_out"' \
                                                   "script did not emit the toolsmoke-flagged counter"

if [ "$fail" -eq 0 ]; then
  echo "ok — tool-smoke shadowed/dangling/exit-0-lies detection: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — tool-smoke shadowed/dangling/exit-0-lies detection: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
