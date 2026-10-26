#!/usr/bin/env bash
# open-deliverable.test.sh — the cross-platform opener resolves the right branch and URL
# without launching anything (--print), and fails loudly on bad input.
#
# WHY THIS EXISTS
#   Two skills ended with `open <file>` and, under Claude Code's BROWSER=true, showed the
#   operator nothing while exiting 0 (dotfiles #908). The opener is the one place per-host
#   logic lives; if its branch detection or URL shape regresses, every deliverable-producing
#   skill regresses with it. Everything here runs with --print, so CI never opens a browser.
#   The WSL and macOS branches are not exercised by CI (ubuntu runner, no display): run this
#   file by hand on those hosts before trusting a change to their branches.
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
BIN=$(cd -P "$(dirname "$SELF")/.." && pwd)/bin/open-deliverable
[ -x "$BIN" ] || { echo "FAIL: $BIN missing or not executable"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }

tmp=$(mktemp -d /tmp/open-deliverable-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '<!doctype html><title>t</title>\n' > "$tmp/page.html"
on_wsl=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then on_wsl=1; fi

# 1. --print on a real file: exit 0 (viewer host) or 3 (headless), names the file, launches nothing.
out=$("$BIN" --print "$tmp/page.html" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && ok || bad "print on file: rc=$rc out=$out"
grep -Eq '(would open: |no viewer on this host)' <<<"$out" && ok || bad "print on file: no branch line: $out"
grep -Fq 'page.html' <<<"$out" && ok || bad "print on file: path missing: $out"

# 2. --print on an http URL passes it through untouched.
out=$("$BIN" --print 'https://example.com/a?b=1' 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && grep -Fq 'https://example.com/a?b=1' <<<"$out" && ok || bad "print on url: rc=$rc out=$out"

# 3. Missing file: exit 2, says so.
out=$("$BIN" --print "$tmp/nope.html" 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -Fq 'no such file' <<<"$out" && ok || bad "missing file: rc=$rc out=$out"

# 4. No argument: exit 2 with usage.
out=$("$BIN" 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -Fq 'usage' <<<"$out" && ok || bad "no arg: rc=$rc out=$out"

# 5. DELIVERABLE_BROWSER override is honoured on every host, headless included: an executable
#    override means --print reports it and the exit is 0, never 3.
out=$(DELIVERABLE_BROWSER=/bin/true "$BIN" --print "$tmp/page.html" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -Fq 'true' <<<"$out" && ok || bad "override: rc=$rc out=$out"

# 6. WSL branch shape: the URL must use the wsl.localhost form, never file:///.
if [ "$on_wsl" = 1 ]; then
  out=$("$BIN" --print "$tmp/page.html" 2>&1)
  grep -Fq 'file://wsl.localhost/' <<<"$out" && ok || bad "wsl url shape: $out"
  grep -Fq 'file:///' <<<"$out" && bad "wsl branch leaked a file:/// url: $out" || ok
fi

# 7. --help prints the usage header and exits 0.
out=$("$BIN" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -Fq 'open-deliverable' <<<"$out" && ok || bad "help: rc=$rc"

# 8. Path characters that break URLs are percent-encoded: space, '#', '?', '%'.
mkdir -p "$tmp/with space" && printf '<!doctype html>\n' > "$tmp/with space/p#q?r%s.html"
out=$("$BIN" --print "$tmp/with space/p#q?r%s.html" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && ok || bad "special path: rc=$rc out=$out"
grep -Fq 'with%20space/p%23q%3Fr%25s.html' <<<"$out" && ok || bad "special chars not encoded: $out"

# 9. A file:// URL naming a local file is treated as that file (so the WSL rewrite applies).
out=$("$BIN" --print "file://$tmp/page.html" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && ok || bad "file url: rc=$rc out=$out"
if [ "$on_wsl" = 1 ]; then
  grep -Fq 'file://wsl.localhost/' <<<"$out" && ok || bad "file url not rewritten on wsl: $out"
else
  grep -Fq 'page.html' <<<"$out" && ok || bad "file url lost the path: $out"
fi

# 10. A file:// URL naming a missing file exits 2 like any missing path.
out=$("$BIN" --print "file://$tmp/absent.html" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok || bad "file url to missing path: rc=$rc out=$out"

if [ "$fail" -eq 0 ]; then
  echo "ok — open-deliverable: $pass passed, $fail failed"
else
  echo "FAIL — open-deliverable: $pass passed, $fail failed" >&2
  exit 1
fi
