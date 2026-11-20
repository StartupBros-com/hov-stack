#!/usr/bin/env bash
# Live checks of firecrawl-cli's Firecrawl Local tier (#807) against the real pinned
# firecrawl-local 0.1.1 and the system Chrome. MANUAL-ONLY: it needs the binary, Chrome,
# unprivileged user namespaces and, for part 2, the internet. It spends no credits: the
# vendor firecrawl on PATH is a stub that logs any call and fails, so a page the tier did
# not serve shows up as a vendor call, never as a cloud charge.
#
# Part 1, offline, in a private network namespace (nothing leaves the host): "public"
# addresses on the namespace's loopback serve fixture pages, localtest.me resolves to
# 127.0.0.1, and Firecrawl's hosts resolve to a listener that counts connections.
#   acceptance 3: three pages served locally through the wrapper, zero cloud connections
#   acceptance 4: under --public-only, a Chrome-rendered page's <img>, fetch() and meta
#                 refresh to localtest.me reach nothing, while the same page without
#                 --public-only reaches the listener; 302s to localtest.me and to
#                 169.254.169.254 are refused with zero listener hits
#   acceptance 5: the first pass's hidden Chrome (/bin/false) still yields the
#                 JavaScript warning for a script-built page
# Part 2, internet, through the wrapper:
#   three public pages served locally; four script-built public pages served in Chrome
#   (acceptance 6) with the summed PSS of the whole process tree under 2 GB
#
# Run:   FIRECRAWL_LOCAL_LIVE_TEST=1 bash tests/firecrawl-local-live.test.sh
# Knobs: FIRECRAWL_CLI_LOCAL_BIN (default ~/.local/share/firecrawl-local/bin/firecrawl-local);
#        FIRECRAWL_LOCAL_LIVE_PAGES and FIRECRAWL_LOCAL_LIVE_BROWSER_PAGES, space-separated
#        URLs replacing the defaults below when a page changes.
set -uo pipefail

if [ "${FIRECRAWL_LOCAL_LIVE_TEST:-}" != 1 ]; then
  echo "skipped: set FIRECRAWL_LOCAL_LIVE_TEST=1 (runs the real firecrawl-local and Chrome)"
  exit 0
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI=$REPO/bin/firecrawl-cli
HELPER=$REPO/tests/fixtures/firecrawl-cli/local-live.py
BIN=${FIRECRAWL_CLI_LOCAL_BIN:-$HOME/.local/share/firecrawl-local/bin/firecrawl-local}
PYTHON=$(command -v python3)
PAGES=${FIRECRAWL_LOCAL_LIVE_PAGES:-https://example.com/ https://www.rfc-editor.org/rfc/rfc2606.html https://docs.python.org/3/library/json.html}
BROWSER_PAGES=${FIRECRAWL_LOCAL_LIVE_BROWSER_PAGES:-https://www.kaggle.com/competitions/squares-in-squares https://www.kaggle.com/learn https://help.twilio.com/articles/1260803965530-What-pricing-and-fees-are-associated-with-the-A2P-10DLC-service- https://www.reddit.com/r/ClaudeCode/comments/1xq6xyb/built_a_free_ai_prompt_generator_with_claude_code/}
TMP=$(mktemp -d /tmp/firecrawl-local-live.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
# check <label> <json file> <python expression over r>
check() {
  "$PYTHON" -I -c 'import json, sys
r = json.load(open(sys.argv[1]))
exec(sys.argv[2])' "$2" "$3" >/dev/null 2>"$TMP/check.err" && ok || bad "$1: $(tail -1 "$TMP/check.err")"
}

[ -x "$BIN" ] || { echo "FAIL: no firecrawl-local at $BIN; install it as harness/data-source-clis.md describes" >&2; exit 1; }
VERSION=$("$BIN" --version 2>&1)
[ "$VERSION" = "firecrawl-local 0.1.1" ] || { echo "FAIL: $BIN reports '$VERSION', not the pinned 0.1.1" >&2; exit 1; }
command -v unshare >/dev/null || { echo "FAIL: unshare (util-linux) is required" >&2; exit 1; }

echo "== part 1: private network namespace =="
mkdir -p "$TMP/ns"
if ! timeout 900 unshare -r -n -m "$PYTHON" -I "$HELPER" ns "$CLI" "$BIN" "$TMP/ns" >"$TMP/ns.json" 2>"$TMP/ns.err"; then
  echo "FAIL: namespace run did not finish: $(tail -3 "$TMP/ns.err")" >&2
  exit 1
fi
SERVED="local: served by Firecrawl Local 0.1.1"
check 'three pages: exit 0, all served locally' "$TMP/ns.json" "t=r['three']; assert t['rc']==0, t['stderr']; i=t['json']['data']['items']; assert len(i)==3 and all(x['ok'] and x['credits_spent']==0 for x in i), i"
check 'three pages: plain fetch and Chrome both used, no fall-through' "$TMP/ns.json" "g=r['three']['json']['degraded']; assert '$SERVED (local-fetch); no credits spent' in g and '$SERVED (local-browser); no credits spent' in g, g; assert not any('ran on Firecrawl' in n for n in g), g"
check 'three pages: no vendor call, no cloud connection' "$TMP/ns.json" "t=r['three']; assert t['vendor_calls']==0 and t['hits']['cloud']==0, t['hits']"
check 'probe under --public-only rendered in Chrome' "$TMP/ns.json" "p=r['probe_public_only']; assert p['rc']==0 and p['json']['data']['metadata']['engine']=='local-browser', p"
check 'probe under --public-only reached no local listener' "$TMP/ns.json" "h=r['probe_public_only']['hits']; assert h['localtest']==0 and h['metadata']==0, h"
check 'control: the same page without --public-only reaches the listener' "$TMP/ns.json" "h=r['probe_control']['hits']; assert r['probe_control']['rc']==0 and h['localtest']>=1, h"
for case in redirect_local redirect_metadata; do
  check "$case: refused, never sent to the cloud" "$TMP/ns.json" "x=r['$case']; assert x['rc']==1 and x['json']['error']['code']=='local_blocked_target', x['stdout']; assert x['vendor_calls']==0, x"
  check "$case: zero listener hits" "$TMP/ns.json" "h=r['$case']['hits']; assert h['localtest']==0 and h['metadata']==0 and h['public']==1, h"
done
check 'hidden Chrome still yields the JavaScript warning' "$TMP/ns.json" "d=r['chrome_hidden']['json']['data']; assert 'builds its content with JavaScript' in d['warning'] and not d['markdown'].strip(), d.get('warning')"
check 'four fixture pages served in Chrome under 2 GB' "$TMP/ns.json" "f=r['four_browser']; assert f['rc']==0 and all(x['ok'] for x in f['json']['data']['items']), f['stdout'][:300]; assert f['vendor_calls']==0 and f['peak_pss_mb']<2048, f"
check 'no connection to a Firecrawl host in the whole run' "$TMP/ns.json" "assert r['cloud_connections_total']==0, r['cloud_connections_total']"

echo "== part 2: public pages through the wrapper =="
mkdir -p "$TMP/stubs" "$TMP/home"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/vendor.log\nexit 1\n' "$TMP" >"$TMP/stubs/firecrawl"
chmod +x "$TMP/stubs/firecrawl"
wrapper() {
  local out=$1; shift
  : >"$TMP/vendor.log"
  "$PYTHON" -I "$HELPER" measure "$out" -- env -i PATH="$TMP/stubs:$(dirname "$PYTHON"):/usr/bin:/bin" \
    HOME="$TMP/home" LANG=C.UTF-8 FIRECRAWL_CLI_KEYLESS=0 FIRECRAWL_CLI_LOCAL_BIN="$BIN" \
    "$CLI" fetch "$@" --full --json
  "$PYTHON" -I -c 'import json, sys
r = json.load(open(sys.argv[1]))
r["vendor_calls"] = open(sys.argv[2]).read().count("\n")
try:
    r["json"] = json.loads(r["stdout"])
except ValueError:
    r["json"] = None
json.dump(r, open(sys.argv[1], "w"))' "$out" "$TMP/vendor.log"
}
read -r -a page_list <<<"$PAGES"
wrapper "$TMP/plain.json" "${page_list[@]}"
check 'public pages: exit 0, every page served locally' "$TMP/plain.json" "assert r['rc']==0, r['stderr']; j=r['json']; i=j['data']['items'] if 'items' in (j['data'] or {}) else [j]; assert all(x['ok'] for x in i), i; assert j['credits_spent']==0, j['credits_spent']; assert any(n.startswith('$SERVED') for n in j['degraded']) and not any('ran on Firecrawl' in n for n in j['degraded']), j['degraded']; assert r['vendor_calls']==0, r['vendor_calls']"
read -r -a browser_list <<<"$BROWSER_PAGES"
wrapper "$TMP/browser.json" "${browser_list[@]}"
check 'script-built public pages: every page served in Chrome' "$TMP/browser.json" "assert r['rc']==0, r['stderr']; j=r['json']; assert all(x['ok'] for x in j['data']['items']), j['data']['items']; assert j['degraded']==['$SERVED (local-browser); no credits spent'], j['degraded']; assert r['vendor_calls']==0, r['vendor_calls']"
check 'script-built public pages: summed PSS under 2 GB' "$TMP/browser.json" "assert r['peak_pss_mb']<2048, r['peak_pss_mb']"
"$PYTHON" -I -c 'import json, os, sys
rows = [(os.path.basename(n), json.load(open(n))) for n in sys.argv[2:]]
rows.append(("namespace four_browser", json.load(open(sys.argv[1]))["four_browser"]))
for name, r in rows:
    print("  %s: peak PSS %s MB, summed RSS %s MB, %s processes"
          % (name, r["peak_pss_mb"], r["peak_rss_mb"], r["peak_procs"]))' \
  "$TMP/ns.json" "$TMP/plain.json" "$TMP/browser.json"

echo "firecrawl-local-live: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
