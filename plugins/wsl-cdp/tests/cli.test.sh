#!/usr/bin/env bash
# Behavioral tests for the wsl-cdp bash CLI: argument parsing, flag rejection,
# exit-code contract, detection seams, and machine (--json) output. Portable —
# no WSL interop required (detection is bypassed via WSL_CDP_WINUSER override).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CLI="$WSL_CDP_BIN"

# --- help is success on stdout; a typo is an error (contract for capability probes)
out="$("$CLI" --help)"; rc=$?
assert_eq "--help exits 0" 0 "$rc"
assert_contains "--help prints usage" "$out" "usage: wsl-cdp"
assert_exit "help subcommand exits 0" 0 "$CLI" help
assert_exit "unknown command -> 2" 2 "$CLI" frobnicate

# --- unknown flags / stray args are rejected loudly, never silently swallowed
assert_exit "status --xml -> 2" 2 "$CLI" status --xml
assert_exit "tabs --verbose -> 2" 2 "$CLI" tabs --verbose
assert_exit "doctor positional -> 2" 2 "$CLI" doctor stray
assert_exit "up extra arg -> 2" 2 "$CLI" up extra
assert_exit "url extra arg -> 2" 2 "$CLI" url extra

# --- ports are validated numeric before they reach any URL / jq program / pgrep
assert_exit "PORT=abc -> 2" 2 env WSL_CDP_PORT=abc "$CLI" url
assert_exit "PROXY_PORT=9x -> 2" 2 env WSL_CDP_PROXY_PORT=9x "$CLI" url

# --- url honors the port
u="$(WSL_CDP_PORT=9333 "$CLI" url)"
assert_eq "url reflects PORT" "http://127.0.0.1:9333" "$u"

# --- required args are validated (exit 2) BEFORE any network call
assert_exit "open (no URL) -> 2" 2 "$CLI" open
assert_exit "close (no ID) -> 2" 2 "$CLI" close
assert_exit "eval (no JS) -> 2" 2 "$CLI" eval

# --- close tab-id is validated: path traversal / shell metacharacters rejected
assert_exit "close ../etc/passwd -> 2" 2 "$CLI" close '../etc/passwd'
assert_exit "close 'zzz;rm' -> 2" 2 "$CLI" close 'zzz;rm'

# --- detection seam: print-launch under a fixture root, no interop, and the
#     debug port + dedicated profile are emitted as an inseparable unit
fx="$(make_fixture)"; brave="$(fixture_brave "$fx")"
argv="$(WSL_CDP_USERS_ROOT="$fx/users" WSL_CDP_WINUSER=test \
        WSL_CDP_BROWSER="$brave" WSL_CDP_PORT=9333 HOME="$fx/home" \
        "$CLI" print-launch)"; rc=$?
assert_eq "print-launch exits 0" 0 "$rc"
assert_contains "print-launch carries the debug port" "$argv" "--remote-debugging-port=9333"
assert_contains "print-launch pairs the dedicated profile" "$argv" 'user-data-dir=C:\Users\test\.wsl-cdp\profile'

# --- launch argv suppresses in-process updater/background churn (v0.3.1:
#     a fresh agent profile must not kick off update churn; Brave relaunch loop)
assert_contains "argv disables browser sync" "$argv" "--disable-sync"
assert_contains "argv disables background networking" "$argv" "--disable-background-networking"
assert_contains "argv stretches the component-update interval" "$argv" "--component-update-interval-in-sec="
assert_contains "argv stretches the staged-update poll" "$argv" "--check-for-update-interval="

# --- profile-browser affinity: the browser recorded next to the profile
#     outranks autodetect (v0.3.1: an autodetect reorder must never reopen an
#     existing profile with a different vendor); a stale record falls through
detect_argv(){ WSL_CDP_USERS_ROOT="$fx/users" WSL_CDP_WINUSER=test \
  WSL_CDP_PROGRAMFILES="$fx/pf" WSL_CDP_PROGRAMFILES_X86="$fx/pf86" \
  HOME="$fx/home" "$CLI" print-launch 2>/dev/null; }
mkdir -p "$fx/users/test/.wsl-cdp"
printf '%s' "$(fixture_brave "$fx")" >"$fx/users/test/.wsl-cdp/browser"
assert_contains "recorded profile browser outranks autodetect" "$(detect_argv)" "BraveSoftware"
printf '%s' "$fx/uninstalled.exe" >"$fx/users/test/.wsl-cdp/browser"
assert_contains "stale profile record falls back to autodetect" "$(detect_argv)" "pf/Google/Chrome"
rm -f "$fx/users/test/.wsl-cdp/browser"

# --- autodetect waterfall: the FULL documented order — Chrome (system, user),
#     Edge (x86, 64-bit), Brave (user, system) — asserted by deleting the
#     winner one rank at a time (v0.3.1: Brave last, updater contention)
i=0
while IFS= read -r exe; do
  i=$((i+1))
  assert_contains "autodetect rank $i is ${exe#"$fx"/}" "$(detect_argv)" "${exe#"$fx"/}"
  rm "$exe"
done < <(fixture_rank "$fx")

# --- a WSL_CDP_WINUSER override must NOT persist into the winuser cache
h="$fx/home2"
WSL_CDP_USERS_ROOT="$fx/users" WSL_CDP_WINUSER=test \
  WSL_CDP_BROWSER="$brave" WSL_CDP_PORT=9333 HOME="$h" \
  "$CLI" print-launch >/dev/null 2>&1
if [ -f "$h/.local/state/wsl-cdp/winuser" ]; then
  _no "override poisoned the winuser cache"
else
  _ok "override leaves the winuser cache unwritten"
fi

# --- browsers verb (v0.3.2): rank-ordered enumeration, flags, machine shape.
#     Fresh fixture: the waterfall above deleted $fx's browsers. A shimmed
#     no-output tasklist.exe ("interop down") makes `running` deterministic on
#     real WSL boxes, where the genuine tasklist would answer.
fx2="$(make_fixture)"
mkdir -p "$fx2/bin-down"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fx2/bin-down/tasklist.exe"
chmod +x "$fx2/bin-down/tasklist.exe"
browsers_run(){ PATH="$fx2/bin-down:$PATH" WSL_CDP_USERS_ROOT="$fx2/users" \
  WSL_CDP_WINUSER=test \
  WSL_CDP_PROGRAMFILES="$fx2/pf" WSL_CDP_PROGRAMFILES_X86="$fx2/pf86" \
  HOME="$fx2/home" "$CLI" browsers "$@" 2>/dev/null; }
bt="$(browsers_run)"
assert_eq "browsers lists all six installs" 6 "$(printf '%s\n' "$bt" | wc -l)"
assert_contains "browsers rank 1 is system Chrome" "$(printf '%s\n' "$bt" | head -1)" "pf/Google/Chrome"
assert_contains "browsers rank 1 carries recommended" "$(printf '%s\n' "$bt" | head -1)" "recommended"
assert_exit "browsers --xml -> 2" 2 "$CLI" browsers --xml
assert_exit "browsers stray positional -> 2" 2 "$CLI" browsers stray

bj="$(browsers_run --json)"
if printf '%s' "$bj" | jq -e --arg p "$(fixture_chrome "$fx2")" '
     (.browsers|length)==6 and .browsers[0].name=="chrome"
     and .browsers[0].recommended==true and .browsers[0].running==null
     and .source=="autodetect" and .selected==$p' >/dev/null 2>&1; then
  _ok "browsers --json well-shaped (running null when interop absent)"
else
  _no "browsers --json shape wrong: $bj"
fi

# --- browsers: a recorded profile owner is flagged and wins selection
mkdir -p "$fx2/users/test/.wsl-cdp"
printf '%s' "$(fixture_brave "$fx2")" >"$fx2/users/test/.wsl-cdp/browser"
bj="$(browsers_run --json)"
if printf '%s' "$bj" | jq -e --arg p "$(fixture_brave "$fx2")" '
     .source=="recorded" and .selected==$p
     and ([.browsers[]|select(.recorded)] | length==1 and all(.name=="brave"))' >/dev/null 2>&1; then
  _ok "browsers --json surfaces the recorded profile owner"
else
  _no "browsers --json recorded shape wrong: $bj"
fi
rm -f "$fx2/users/test/.wsl-cdp/browser"

# --- browsers: running flags through a tasklist.exe seam (brave live, rest not)
mkdir -p "$fx2/bin"
cat >"$fx2/bin/tasklist.exe" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *brave.exe*) printf '"brave.exe","4242","Console","1","123,456 K"\n' ;;
  *) printf 'INFO: No tasks are running which match the specified criteria.\n' ;;
esac
SHIM
chmod +x "$fx2/bin/tasklist.exe"
bj="$(PATH="$fx2/bin:$PATH" WSL_CDP_USERS_ROOT="$fx2/users" WSL_CDP_WINUSER=test \
  WSL_CDP_PROGRAMFILES="$fx2/pf" WSL_CDP_PROGRAMFILES_X86="$fx2/pf86" \
  HOME="$fx2/home" "$CLI" browsers --json 2>/dev/null)"
if printf '%s' "$bj" | jq -e '
     ([.browsers[]|select(.name=="brave")] | length==2 and all(.running==true))
     and ([.browsers[]|select(.name!="brave")] | length==4 and all(.running==false))' >/dev/null 2>&1; then
  _ok "browsers running flags via tasklist seam"
else
  _no "browsers running flags wrong: $bj"
fi

# --- browsers: a non-executable env override is previewed with a loud WARN
#     (selected/source document what `up` would use, and `up` would FAIL here)
b_err="$(WSL_CDP_USERS_ROOT="$fx2/users" WSL_CDP_WINUSER=test \
  WSL_CDP_PROGRAMFILES="$fx2/pf" WSL_CDP_PROGRAMFILES_X86="$fx2/pf86" \
  HOME="$fx2/home" WSL_CDP_BROWSER="$fx2/nope.exe" \
  "$CLI" browsers --json 2>&1 >/dev/null)"
assert_contains "browsers warns on a non-executable override" "$b_err" "not executable"

# --- browsers: zero installs is a loud exit 1, not an empty success
fx3="$(mktemp -d "${TMPDIR:-/tmp}/wslcdp-none.XXXXXX")"
mkdir -p "$fx3/users/test/AppData/Local/Temp" "$fx3/home"
assert_exit "browsers with no installs -> 1" 1 env WSL_CDP_USERS_ROOT="$fx3/users" \
  WSL_CDP_WINUSER=test WSL_CDP_PROGRAMFILES="$fx3/pf" \
  WSL_CDP_PROGRAMFILES_X86="$fx3/pf86" HOME="$fx3/home" "$CLI" browsers

# --- harden / profile hygiene (v0.3.3): pref seeding, merge-not-clobber,
#     password scrub that spares sessions, empty-store no-op
fx4="$(make_fixture)"
harden_run(){ WSL_CDP_USERS_ROOT="$fx4/users" WSL_CDP_WINUSER=test \
  WSL_CDP_PROGRAMFILES="$fx4/pf" WSL_CDP_PROGRAMFILES_X86="$fx4/pf86" \
  HOME="$fx4/home" "$CLI" harden 2>/dev/null; }
prefs="$fx4/users/test/.wsl-cdp/profile/Default/Preferences"
pdefault="$fx4/users/test/.wsl-cdp/profile/Default"

assert_exit "harden extra arg -> 2" 2 "$CLI" harden extra

h_out="$(harden_run)"; h_rc=$?
assert_eq "harden exits 0" 0 "$h_rc"
assert_contains "harden reports what it did" "$h_out" "hardened"
if jq -e '.credentials_enable_service==false and .credentials_enable_autosignin==false
          and .signin.allowed_on_next_startup==false' "$prefs" >/dev/null 2>&1; then
  _ok "harden seeds the hygiene prefs"
else
  _no "harden prefs wrong: $(cat "$prefs" 2>/dev/null)"
fi

python3 - "$prefs" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["homepage"] = "https://example.com"
json.dump(d, open(sys.argv[1], "w"))
PY
harden_run >/dev/null
if jq -e '.homepage=="https://example.com" and .credentials_enable_service==false' "$prefs" >/dev/null 2>&1; then
  _ok "harden merges into existing Preferences (no clobber)"
else
  _no "harden clobbered Preferences: $(cat "$prefs" 2>/dev/null)"
fi

fixture_login_store "$pdefault/Login Data" "https://github.com" "https://example.com"
touch "$pdefault/Cookies"
h_out="$(harden_run)"
assert_contains "harden scrubs and counts saved passwords" "$h_out" "scrubbed 2 saved password"
if [ -f "$pdefault/Login Data" ]; then _no "Login Data survived the scrub"; else _ok "Login Data removed by the scrub"; fi
if [ -f "$pdefault/Cookies" ]; then _ok "Cookies (sessions) untouched by the scrub"; else _no "scrub deleted Cookies"; fi

fixture_login_store "$pdefault/Login Data"
h_out="$(harden_run)"
case "$h_out" in *scrubbed*) _no "harden scrub-noticed an empty store" ;; *) _ok "empty password store: no scrub notice" ;; esac
if [ -f "$pdefault/Login Data" ]; then _ok "empty store left in place"; else _no "empty store was deleted"; fi

# --- harden failure honesty: a broken Preferences write must NOT report success
printf 'not json{' >"$prefs"
h_out="$(harden_run)"; h_rc=$?
assert_eq "harden with corrupt Preferences -> 1" 1 "$h_rc"
case "$h_out" in *hardened:*) _no "harden claimed success over a failed prefs write" ;; *) _ok "harden withholds success on a failed prefs write" ;; esac

# a mangled-but-valid file with .signin as a non-object is coerced, not fatal
printf '{"signin": true}' >"$prefs"
h_out="$(harden_run)"; h_rc=$?
assert_eq "harden coerces a non-object .signin -> 0" 0 "$h_rc"
if jq -e '.signin.allowed_on_next_startup==false' "$prefs" >/dev/null 2>&1; then
  _ok "non-object .signin coerced and pref set"
else
  _no "signin coercion failed: $(cat "$prefs" 2>/dev/null)"
fi

# mixed counts: readable store + unreadable store — count is qualified, not silently low
rm -f "$pdefault/Login Data"
fixture_login_store "$pdefault/Login Data" "https://github.com" "https://example.com"
printf 'garbage-not-sqlite' >"$pdefault/Login Data For Account"
h_out="$(harden_run)"
assert_contains "mixed scrub reports the known count" "$h_out" "scrubbed 2 saved password"
assert_contains "mixed scrub qualifies the unreadable store" "$h_out" "count was unreadable"
if [ -f "$pdefault/Login Data For Account" ]; then _no "unreadable store survived"; else _ok "unreadable store removed too"; fi

# --- up over an already-live bridge with WSL_CDP_BROWSER set: the explicit
#     choice must not be DISCARDED silently (v0.3.2 review blocker). Fake
#     /json/version server on a scratch port makes up return at step 0 —
#     nothing is launched, no Windows state is touched.
srv_port=9345
python3 - "$srv_port" >/dev/null 2>&1 <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = json.dumps({"Browser": "FakeBrowser/1.0"}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
srv_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf -m 1 "http://127.0.0.1:$srv_port/json/version" >/dev/null 2>&1 && break
  sleep 0.2
done
up_err="$(WSL_CDP_PORT=$srv_port WSL_CDP_PROXY_PORT=9346 \
  WSL_CDP_BROWSER=/mnt/c/fake/browser.exe "$CLI" up 2>&1 >/dev/null)"
up_rc=$?
up_out="$(WSL_CDP_PORT=$srv_port WSL_CDP_PROXY_PORT=9346 "$CLI" up 2>/dev/null)"
# no-launch path + saved passwords present: up must flag pending hygiene
rm -f "$pdefault/Login Data"
fixture_login_store "$pdefault/Login Data" "https://github.com"
up_hyg="$(WSL_CDP_PORT=$srv_port WSL_CDP_PROXY_PORT=9346 \
  WSL_CDP_USERS_ROOT="$fx4/users" WSL_CDP_WINUSER=test \
  HOME="$fx4/home" "$CLI" up 2>&1 >/dev/null)"
assert_contains "up (no launch) flags pending hygiene" "$up_hyg" "hygiene applies at launch"
kill "$srv_pid" 2>/dev/null
assert_eq "up over a live bridge exits 0" 0 "$up_rc"
assert_contains "up warns when the browser override is not applied" "$up_err" "WSL_CDP_BROWSER is set"
assert_contains "up without an override stays note-free" "$up_out" "bridge up: FakeBrowser"

# --- interop-outage immunity (v0.3.4): a wedged vsock channel HANGS Windows
#     exes instead of failing them; every verb must survive via win_exec
#     timeouts and say the true thing instead of misdiagnosing
# The PATH-held exe shims are the established interop seam. Retain one real
# sleep under win_exec in the text doctor: it has the broadest public contract
# (survival, diagnostic, and no false netsh conclusion). The other callers need
# only the documented timeout result: empty output with status 124.
fx5="$(make_fixture)"
fixture_log="$fx5/interop-timeout-calls"
mkdir -p "$fx5/hang" "$fx5/timed-out"
for exe in cmd.exe netsh.exe powershell.exe tasklist.exe wsl.exe; do
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "real:%s\n" "$WSL_CDP_TIMEOUT_FIXTURE_CASE" >>"$WSL_CDP_TIMEOUT_FIXTURE_LOG"' \
    'sleep 60' >"$fx5/hang/$exe"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "deterministic:%s\n" "$WSL_CDP_TIMEOUT_FIXTURE_CASE" >>"$WSL_CDP_TIMEOUT_FIXTURE_LOG"' \
    'exit 124' >"$fx5/timed-out/$exe"
  chmod +x "$fx5/hang/$exe" "$fx5/timed-out/$exe"
done
doc_out="$(WSL_CDP_TIMEOUT_FIXTURE_CASE=doctor \
  WSL_CDP_TIMEOUT_FIXTURE_LOG="$fixture_log" \
  WSL_CDP_WIN_EXEC_TIMEOUT=1 PATH="$fx5/hang:$PATH" \
  WSL_CDP_USERS_ROOT="$fx5/users" WSL_CDP_WINUSER=test HOME="$fx5/home" \
  WSL_CDP_PORT=9333 WSL_CDP_PROXY_PORT=9334 timeout 60 "$CLI" doctor 2>&1)"
doc_rc=$?
if [ "$doc_rc" = 124 ]; then _no "doctor HUNG under wedged interop"; else _ok "doctor survives wedged interop"; fi
assert_contains "doctor names the interop outage" "$doc_out" "WARN interop"
assert_contains "doctor refuses the no-rule misread" "$doc_out" "unverifiable: interop down"
case "$doc_out" in *"no v4tov4 rule"*) _no "doctor still claims no-rule under dead netsh" ;; *) _ok "no false no-rule claim under dead netsh" ;; esac

up_err2="$(WSL_CDP_TIMEOUT_FIXTURE_CASE=up-rescue \
  WSL_CDP_TIMEOUT_FIXTURE_LOG="$fixture_log" \
  WSL_CDP_WIN_EXEC_TIMEOUT=1 PATH="$fx5/timed-out:$PATH" \
  WSL_CDP_USERS_ROOT="$fx5/users" WSL_CDP_WINUSER=test HOME="$fx5/home" \
  WSL_CDP_PORT=9333 WSL_CDP_PROXY_PORT=9334 timeout 60 "$CLI" up 2>&1 >/dev/null)"
up_rc2=$?
assert_eq "up under wedged interop -> 1" 1 "$up_rc2"
assert_contains "up hands the Windows-side rescue" "$up_err2" "print-launch --windows"
if [ -f "$fx5/users/test/.wsl-cdp/wsl-cdp-setup.ps1" ]; then
  _ok "up staged the elevated setup script via 9p"
else
  _no "rescue did not stage wsl-cdp-setup.ps1"
fi

# --- print-launch --windows: PowerShell-paste-ready
pw="$(WSL_CDP_USERS_ROOT="$fx5/users" WSL_CDP_WINUSER=test HOME="$fx5/home" \
  WSL_CDP_BROWSER="$(fixture_brave "$fx5")" WSL_CDP_PORT=9333 "$CLI" print-launch --windows)"
case "$pw" in '& "'*) _ok "print-launch --windows uses the call operator" ;; *) _no "unexpected --windows prefix: $pw" ;; esac
assert_contains "--windows quotes wildcard args" "$pw" '"--remote-allow-origins=*"'
assert_exit "print-launch --bogus -> 2" 2 "$CLI" print-launch --bogus

# --- upload: argument validation fires before any network dependency
assert_exit "upload (no args) -> 2" 2 "$CLI" upload
assert_exit "upload (one arg) -> 2" 2 "$CLI" upload /tmp/x
assert_exit "upload missing file -> 2" 2 "$CLI" upload /nonexistent-file.png "input"

# --- v0.3.4 review fixes: config validation, JSON parity, gated latency,
#     honest rescue without a resolvable user, staged-upload hygiene
assert_exit "WIN_EXEC_TIMEOUT=abc -> 2" 2 env WSL_CDP_WIN_EXEC_TIMEOUT=abc "$CLI" url

dj="$(WSL_CDP_TIMEOUT_FIXTURE_CASE=doctor-json \
  WSL_CDP_TIMEOUT_FIXTURE_LOG="$fixture_log" \
  WSL_CDP_WIN_EXEC_TIMEOUT=1 PATH="$fx5/timed-out:$PATH" \
  WSL_CDP_USERS_ROOT="$fx5/users" WSL_CDP_WINUSER=test HOME="$fx5/home" \
  WSL_CDP_PORT=9333 WSL_CDP_PROXY_PORT=9334 timeout 60 "$CLI" doctor --json 2>/dev/null)"
if printf '%s' "$dj" | jq -e '.env.interop == false' >/dev/null 2>&1; then
  _ok "doctor --json carries env.interop=false under the wedge"
else
  _no "doctor --json missing/wrong interop field: $(printf '%s' "$dj" | jq -c '.env // empty' 2>/dev/null)"
fi

# gated wedge latency: pre-gate code took >=16s at a 2s timeout (3x netsh retry
# + wsl.exe + stale netsh each independently re-probed); gated must stay well under
wedge_s=$(date +%s)
WSL_CDP_TIMEOUT_FIXTURE_CASE=gated-latency \
  WSL_CDP_TIMEOUT_FIXTURE_LOG="$fixture_log" \
  WSL_CDP_WIN_EXEC_TIMEOUT=2 PATH="$fx5/timed-out:$PATH" \
  WSL_CDP_USERS_ROOT="$fx5/users" WSL_CDP_WINUSER=test HOME="$fx5/home" \
  WSL_CDP_PORT=9333 WSL_CDP_PROXY_PORT=9334 timeout 60 "$CLI" doctor >/dev/null 2>&1
wedge_e=$(date +%s)
if [ $((wedge_e - wedge_s)) -lt 15 ]; then
  _ok "wedged doctor short-circuits on the interop verdict ($((wedge_e - wedge_s))s)"
else
  _no "wedged doctor too slow: $((wedge_e - wedge_s))s (gates not consulted?)"
fi

# rescue with NO resolvable Windows user: must not name a file it never staged
mkdir -p "$fx5/empty-users"
resc="$(WSL_CDP_TIMEOUT_FIXTURE_CASE=unresolvable-user \
  WSL_CDP_TIMEOUT_FIXTURE_LOG="$fixture_log" \
  WSL_CDP_WIN_EXEC_TIMEOUT=1 PATH="$fx5/timed-out:$PATH" \
  WSL_CDP_USERS_ROOT="$fx5/empty-users" HOME="$fx5/home2" \
  WSL_CDP_PORT=9333 WSL_CDP_PROXY_PORT=9334 timeout 60 "$CLI" up 2>&1 >/dev/null)"
assert_contains "unresolvable-user rescue says copy-it-yourself" "$resc" "copy "
case "$resc" in *'C:\Users\<you>'*) _no "rescue still prints a placeholder staged path" ;; *) _ok "no phantom staged-script path" ;; esac
assert_eq "one real and four deterministic timeout fixtures run in order" \
  "real:doctor,deterministic:up-rescue,deterministic:doctor-json,deterministic:gated-latency,deterministic:unresolvable-user" \
  "$(paste -sd, "$fixture_log")"

# staged uploads are cleared by harden and flagged by nothing afterwards
mkdir -p "$fx4/users/test/.wsl-cdp/uploads"
printf 'x' >"$fx4/users/test/.wsl-cdp/uploads/leftover.bin"
h_out="$(harden_run)"
assert_contains "harden clears staged uploads" "$h_out" "cleared 1 staged upload"
if [ -f "$fx4/users/test/.wsl-cdp/uploads/leftover.bin" ]; then
  _no "staged upload survived harden"
else
  _ok "staged upload removed by harden"
fi

# --- status --json: valid JSON, documented shape, ok:false when the chain is down
sj="$(WSL_CDP_PORT=9333 WSL_CDP_PROXY_PORT=9334 "$CLI" status --json 2>/dev/null)"
if printf '%s' "$sj" | jq -e '.ok==false and (.exit|type=="number") and (.checks|length==3) and (.checks[0]|has("status") and has("name") and has("detail"))' >/dev/null 2>&1; then
  _ok "status --json is valid and well-shaped"
else
  _no "status --json shape wrong: $sj"
fi

t_summary
