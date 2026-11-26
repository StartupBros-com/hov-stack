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

tmp=$(mktemp -d /tmp/open-deliverable-test.XXXXXX) || exit 1
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

# ---- Markdown is rendered before it opens -------------------------------------------------
# WHY: from 2026-10-19 agents wrote most reports as .md and the opener handed the raw text to
# the browser (383 .md launches against 221 .html by 2026-11-25). The page it renders now is
# the floor under every report, so these cases read the page itself, not only the printed line.
REPO=$(cd -P "$(dirname "$SELF")/.." && pwd)
export XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$tmp/docs/img"
printf 'x' > "$tmp/docs/img/a.png"
cat > "$tmp/docs/report.md" <<'MD'
---
title: fixture
owner: nobody
---
# Fixture report

Lead line.

## Findings

| What | Verdict |
|---|---|
| one | right |

- [x] shipped
- [ ] pending

> [!WARNING]
> Mind the gap.

<script>alert(1)</script> and <b>bold</b>

![chart](img/a.png) and [next](other.md#part) and [site](https://example.com/)

## Findings

```mermaid
graph TD; A-->B
```
MD

page_of() { sed -n 's/^would open: \(.*\) via .*$/\1/p; s/^no viewer on this host[^:]*: \([^ ]*\).*$/\1/p' <<<"$1" | head -1; }
local_path() {
  local u=$1
  u=${u#file://wsl.localhost/}; [ "$u" != "$1" ] && u=/${u#*/}
  u=${u#file://}
  printf '%b' "${u//%/\\x}"
}

if command -v node >/dev/null 2>&1; then
  # 11. A .md opens as a rendered page, and the line still names the source for anyone counting
  #     what was shown (the census that found the regression reads these lines).
  out=$("$BIN" --print "$tmp/docs/report.md" 2>&1); rc=$?
  { [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && ok || bad "md print: rc=$rc out=$out"
  grep -Fq "(rendered from $tmp/docs/report.md)" <<<"$out" && ok || bad "md print: source not named: $out"
  page=$(local_path "$(page_of "$out")")
  case $page in "$tmp/cache/hov-stack/deliverables/report.md."*.html) ok ;; *) bad "md page not in the cache: $page ($out)" ;; esac
  [ -s "$page" ] && ok || bad "md page missing: $page"
  html=$(cat "$page" 2>/dev/null)

  # 12. Structure a reader needs: title, table, outline anchors, task boxes, callout.
  grep -Fq '<title>Fixture report</title>' <<<"$html" && ok || bad "md page: title"
  grep -Fq '<div class="table-wrap"><table>' <<<"$html" && ok || bad "md page: table"
  grep -Fq '<h2 id="findings">' <<<"$html" && grep -Fq '<h2 id="findings-1">' <<<"$html" && ok || bad "md page: duplicate headings need distinct ids"
  grep -Fq 'class="task task-done"' <<<"$html" && grep -Fq 'class="task"' <<<"$html" && ok || bad "md page: task list"
  grep -Fq 'callout callout-warning' <<<"$html" && ok || bad "md page: callout"
  grep -Fq 'Diagram source (Mermaid)' <<<"$html" && ok || bad "md page: mermaid fence label"

  # 13. Quoted web content cannot act: raw HTML is text, the page has no script and a policy
  #     that allows none, and a remote image cannot load.
  grep -Fq '&lt;script&gt;alert(1)&lt;/script&gt;' <<<"$html" && ok || bad "md page: raw html not escaped"
  grep -Fqi '<script' <<<"$html" && bad "md page carries a script element" || ok
  grep -Fq "default-src 'none'; img-src data: file:; style-src 'unsafe-inline'" <<<"$html" && ok || bad "md page: content security policy"

  # 14. Front matter is not rendered as a rule and a paragraph.
  grep -Fq '<details class="front-matter">' <<<"$html" && ok || bad "md page: front matter block"
  grep -Fq '<p>title: fixture' <<<"$html" && bad "md page: front matter leaked into the body" || ok

  # 15. The page lives in the cache, so a relative reference must point back at the source folder.
  grep -Eq "src=\"file://[^\"]*$tmp/docs/img/a\.png\"" <<<"$html" && ok || bad "md page: relative image not rewritten"
  grep -Eq "href=\"file://[^\"]*$tmp/docs/other\.md#part\"" <<<"$html" && ok || bad "md page: relative link not rewritten"
  grep -Fq 'href="https://example.com/" rel="noopener noreferrer"' <<<"$html" && ok || bad "md page: external link"

  # 16. An edited source is never shown stale: the page is rewritten on every open.
  printf '\nSecond edition marker.\n' >> "$tmp/docs/report.md"
  "$BIN" --print "$tmp/docs/report.md" >/dev/null 2>&1
  grep -Fq 'Second edition marker.' "$page" && ok || bad "md page not re-rendered after an edit"
else
  echo "skip: node not on PATH, rendered-page cases 11-16 not run" >&2
fi

# 17. --raw, DELIVERABLE_RAW=1 and non-Markdown files open unchanged.
out=$("$BIN" --print --raw "$tmp/docs/report.md" 2>&1)
grep -Fq 'report.md' <<<"$out" && ! grep -Fq 'rendered from' <<<"$out" && ok || bad "--raw still rendered: $out"
out=$(DELIVERABLE_RAW=1 "$BIN" --print "$tmp/docs/report.md" 2>&1)
grep -Fq 'rendered from' <<<"$out" && bad "DELIVERABLE_RAW=1 still rendered: $out" || ok
out=$("$BIN" --print "$tmp/page.html" 2>&1)
grep -Fq 'rendered from' <<<"$out" && bad "html was rendered: $out" || ok

# 18. Extension match ignores case and covers .markdown.
cp "$tmp/docs/report.md" "$tmp/docs/UPPER.MD"; cp "$tmp/docs/report.md" "$tmp/docs/long.markdown"
out=$("$BIN" --print "$tmp/docs/UPPER.MD" 2>&1); grep -Fq 'rendered from' <<<"$out" && ok || bad ".MD not rendered: $out"
out=$("$BIN" --print "$tmp/docs/long.markdown" 2>&1); grep -Fq 'rendered from' <<<"$out" && ok || bad ".markdown not rendered: $out"

# 19. Without the renderer (a bare copy of the script, as on a host with no checkout or no
#     node) the text still opens as an escaped page, never as a download or a script.
mkdir -p "$tmp/alone/bin" && cp "$BIN" "$tmp/alone/bin/open-deliverable"
out=$("$tmp/alone/bin/open-deliverable" --print "$tmp/docs/report.md" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && grep -Fq 'showing plain text' <<<"$out" && ok || bad "fallback: rc=$rc out=$out"
page=$(local_path "$(page_of "$(grep -v 'showing plain text' <<<"$out")")")
grep -Fq '&lt;script&gt;alert(1)&lt;/script&gt;' "$page" 2>/dev/null && ok || bad "fallback page did not escape html: $page"
grep -Fqi '<script' "$page" 2>/dev/null && bad "fallback page carries a script element" || ok

# 20. No writable cache: the source opens as before instead of the open failing.
out=$(XDG_CACHE_HOME=/proc/nope "$BIN" --print "$tmp/docs/report.md" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && grep -Fq 'report.md' <<<"$out" && ! grep -Fq 'rendered from' <<<"$out" && ok || bad "unwritable cache: rc=$rc out=$out"

# 21. The vendored parser is the build recorded in UPSTREAM.md (a silent swap is a supply-chain
#     change, so it has to show up as an edit to that record).
want=$(sed -n 's/^sha256: `\([0-9a-f]\{64\}\)`.*/\1/p' "$REPO/lib/vendor/markdown-it/UPSTREAM.md" | head -1)
got=$( { sha256sum "$REPO/lib/vendor/markdown-it/markdown-it.umd.min.js" 2>/dev/null || shasum -a 256 "$REPO/lib/vendor/markdown-it/markdown-it.umd.min.js"; } | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] && ok || bad "vendored markdown-it hash: recorded=$want actual=$got"

if [ "$fail" -eq 0 ]; then
  echo "ok — open-deliverable: $pass passed, $fail failed"
else
  echo "FAIL — open-deliverable: $pass passed, $fail failed" >&2
  exit 1
fi
