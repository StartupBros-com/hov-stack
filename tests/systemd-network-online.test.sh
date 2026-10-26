#!/usr/bin/env bash
# systemd-network-online.test.sh: no --user unit under systemd/ or
# systemd/user/ orders on network-online.target, and the five units that
# did (dotfiles#1458) carry a user-scope readiness mechanism or say why none
# is needed.
#
# WHY: network-online.target belongs to the system manager. In the user
# manager it is LoadState=not-found (workstation, 2026-09-28), so After=/Wants= on it
# order nothing and a Persistent=true catch-up at login starts the script
# before connectivity, the exact race the two lines were written for. CI
# never saw it because the unit suites run systemd-analyze verify in system
# mode, where the target is real. pro-gate found it on #1455
# (the since-retired claim-reap.service); a grep then found the same dead pair in thirteen more.
#
# What this pins, and the failure each assertion is for:
#  1. No directive line `After=network-online.target` or
#     `Wants=network-online.target` under systemd/ or systemd/user/
#     (drop-ins included, systemd/system/ excluded: the target is real
#     in system scope).
#     Anchored at column 0 and bounded on both sides of the token, so a
#     comment that names the target to say why it is absent cannot
#     false-positive, and a multi-value line (`After=network-online.target
#     basic.target`), trailing whitespace or a CRLF cannot slip past; a
#     scratch file of those three shapes proves the detector sees them.
#  2. Each of the five #1458 units, and systemd/user/pi-local-champion-
#     tunnel.service which carried the same pair, has either the shared probe
#     (ExecStartPre=-%h/.claude/scripts/net-ready.sh ...) or a
#     `# No network-readiness probe:` comment stating why none is needed.
#  3. A probe line carries the `-` prefix (its exit status must never fail
#     the unit, so the script keeps its own failure contract), and its
#     --wait is at most half the unit's TimeoutStartSec, because ExecStartPre
#     time counts against that budget.
#  4. net-ready.sh: exits 0 silently when the URL answers (and the server
#     saw the request, so a do-nothing probe cannot pass); exits 1 with a
#     column-0 WARN, within the bound, both when the port refuses and when a
#     peer accepts but never answers; exits 0 from a later attempt when the
#     first connection stalls and later ones answer (each attempt is capped
#     below the wait, so one stall cannot spend it all); still ends within
#     the wait when the wall clock steps back 5s mid-wait (a date shim: the
#     deadline runs on /proc/uptime); reads a zero-padded --wait (08, 010)
#     as decimal, not octal; exits 2 without --url or with a non-numeric
#     --wait; exits 3 with a WARN when curl is not on PATH. pro-gate rounds
#     1 and 2 on #1465 reproduced the stall, clock and octal failures.
#  5. systemd-analyze verify accepts the five services and their timers
#     after the edit. System mode, because --user needs a manager the CI
#     runner lacks; Exec* lines are rewritten to /bin/true because the
#     verifier resolves executables on the current host.
# Planted negative: SYSTEMD_NETWORK_ONLINE_INVERT=1 points the unit directory
# at a scratch copy in which tools-auto-update.service has the two directive
# lines restored and its probe line removed, and points the probe at an
# empty executable; assertions 1, 2 and 4 must then fail (5 reads the same
# copy and may fail too).
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel); cd "$ROOT"
TMP=$(mktemp -d /tmp/systemd-network-online-test.XXXXXX)
pids=()
cleanup() {
  local p
  for p in "${pids[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

SYSD=systemd
USERD=systemd/user
SCRIPT=scripts/net-ready.sh
UNITS=(
  codex-auto-update
  dcg-auto-update
  mcp-servers-update
  skills-update
  tools-auto-update
)
PROBE_RE='^ExecStartPre=-%h/\.claude/scripts/net-ready\.sh '
# A directive line: column-0 After= or Wants=, the target as a whole token
# anywhere in the value (systemd takes several per line), then whitespace
# (a CR is whitespace) or the end of the line.
DIRECTIVE_RE='^(After|Wants)=(.*[[:space:]])?network-online\.target([[:space:]]|$)'

if [ "${SYSTEMD_NETWORK_ONLINE_INVERT:-0}" = 1 ]; then
  mkdir -p "$TMP/inverted"
  cp -r "$SYSD"/. "$TMP/inverted/"
  awk '{ print } /^\[Unit\]$/ { print "After=network-online.target"; print "Wants=network-online.target" }' \
    "$SYSD/tools-auto-update.service" | grep -vF 'net-ready.sh' > "$TMP/inverted/tools-auto-update.service"
  SYSD=$TMP/inverted
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/empty-probe.sh"; chmod +x "$TMP/empty-probe.sh"
  SCRIPT=$TMP/empty-probe.sh
fi

# ── 1. no directive line anywhere under systemd or systemd/user ───────
hits=$(grep -rlE "$DIRECTIVE_RE" --exclude-dir=system "$SYSD" "$USERD" || true)
if [ -n "$hits" ]; then
  bad "1: unit(s) order on network-online.target, which the user manager does not have (LoadState=not-found): After=/Wants= on it order nothing and a Persistent catch-up starts the script before connectivity; use ExecStartPre=-%h/.claude/scripts/net-ready.sh or say why none is needed: $(printf '%s' "$hits" | tr '\n' ' ')"
else
  ok "1: no After=/Wants=network-online.target directive line under $SYSD or $USERD (user scope has none; readiness is net-ready.sh's job)"
fi
# The detector must see the shapes it claims to (a blind grep and a clean
# tree both report nothing): three planted lines, exactly two hits.
mkdir -p "$TMP/shape"
printf 'After=network-online.target basic.target\n' > "$TMP/shape/multi.service"
printf 'Wants=network-online.target \r\n' > "$TMP/shape/crlf.service"
printf '# After=network-online.target is absent here: the user manager has none\n' > "$TMP/shape/comment.service"
shape_hits=$(grep -rlE "$DIRECTIVE_RE" "$TMP/shape" | sort | tr '\n' ' ' || true)
if [ "$shape_hits" = "$TMP/shape/crlf.service $TMP/shape/multi.service " ]; then
  ok "1: the directive detector flags a multi-value line and a CRLF line and ignores a comment"
else
  bad "1: the directive detector saw '$shape_hits'; expected the multi-value and CRLF files only"
fi

# ── 2. each of the five units: probe, or a stated reason for none ───────
for u in "${UNITS[@]}"; do
  f=$SYSD/$u.service
  if [ ! -f "$f" ]; then
    bad "2: $u.service is missing"
    continue
  fi
  if grep -q "$PROBE_RE" "$f"; then
    ok "2: $u.service waits for its host through net-ready.sh"
  elif grep -q '^# No network-readiness probe:' "$f"; then
    ok "2: $u.service states why it has no readiness probe"
  else
    bad "2: $u.service has neither a net-ready.sh ExecStartPre nor a '# No network-readiness probe:' comment (dotfiles#1458 acceptance: a user-scope readiness mechanism or a reason for none)"
  fi
done
# The one unit outside systemd/ that carried the pair: the pi harness's
# tunnel unit (symlinked into ~/.config/systemd/user by lib/manifest.sh).
f=harnesses/pi/systemd/user/pi-local-champion-tunnel.service
if [ ! -f "$f" ]; then
  bad "2: $f is missing"
elif grep -q "$PROBE_RE" "$f"; then
  ok "2: pi-local-champion-tunnel.service waits for its host through net-ready.sh"
elif grep -q '^# No network-readiness probe:' "$f"; then
  ok "2: pi-local-champion-tunnel.service states why it has no readiness probe"
else
  bad "2: pi-local-champion-tunnel.service has neither a net-ready.sh ExecStartPre nor a '# No network-readiness probe:' comment (it carried the dead pair outside systemd/)"
fi

# ── 3. probe lines: `-` prefix, and a wait that leaves the script its budget ─
timeout_seconds() {
  # TimeoutStartSec= value in seconds; a bare number is seconds already.
  # Only the forms the units use are parsed; anything else (a compound
  # span such as 1h30m, an alias such as 2d) returns 1 so the caller reports
  # it instead of tripping a bash arithmetic error under set -e.
  local v=$1 n mult
  case $v in
    infinity) echo 999999; return 0 ;;
    *h)   n=${v%h};   mult=3600 ;;
    *min) n=${v%min}; mult=60 ;;
    *m)   n=${v%m};   mult=60 ;;
    *s)   n=${v%s};   mult=1 ;;
    *)    n=$v;       mult=1 ;;
  esac
  case $n in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Base 10 explicitly: bash arithmetic reads a leading 0 as octal.
  echo $(( 10#$n * mult ))
}
for u in "${UNITS[@]}"; do
  f=$SYSD/$u.service
  [ -f "$f" ] || continue
  if grep -q '^ExecStartPre=%h/\.claude/scripts/net-ready\.sh' "$f"; then
    bad "3: $u.service runs net-ready.sh without the - prefix; on the deadline the probe's exit 1 would fail the unit and page, changing the script's own failure contract"
  fi
  line=$(grep -m1 "$PROBE_RE" "$f" || true)
  [ -n "$line" ] || continue
  wait=$(printf '%s' "$line" | sed -n 's/.*--wait \([0-9][0-9]*\).*/\1/p')
  [ -n "$wait" ] || wait=300
  wait=$(( 10#$wait ))
  tss=$(grep -m1 '^TimeoutStartSec=' "$f" | cut -d= -f2 || true)
  if [ -z "$tss" ]; then
    # Type=oneshot disables the start timeout by default (systemd.service(5));
    # any other type gets DefaultTimeoutStartSec, 90s.
    if grep -qxF 'Type=oneshot' "$f"; then tss=infinity; else tss=90s; fi
  fi
  if ! tss_s=$(timeout_seconds "$tss"); then
    bad "3: $u.service TimeoutStartSec=$tss is not a form this suite parses (bare seconds, Ns, Nm, Nmin, Nh, infinity); extend timeout_seconds() before using it"
    continue
  fi
  if [ $(( wait * 2 )) -le "$tss_s" ]; then
    ok "3: $u.service probe waits ${wait}s of a ${tss_s}s TimeoutStartSec (ExecStartPre time counts against it)"
  else
    bad "3: $u.service probe waits ${wait}s but TimeoutStartSec is ${tss_s}s; the wait must be at most half so the script keeps its budget"
  fi
done

# ── 4. net-ready.sh behaviour ────────────────────────────────────────────────
[ -x "$SCRIPT" ] && ok "4: $SCRIPT is executable" || bad "4: $SCRIPT is not executable"

cat > "$TMP/answer.py" <<'EOF_ANSWER'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Record the hit: the reachable-URL assertion checks this file, so a
        # probe that exits 0 without asking anything cannot pass it.
        with open(sys.argv[1], "a") as f:
            f.write("hit\n")
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
EOF_ANSWER
cat > "$TMP/hang.py" <<'EOF_HANG'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
print(s.getsockname()[1], flush=True)
held = []
while True:
    c, _ = s.accept()
    held.append(c)
EOF_HANG
cat > "$TMP/freeport.py" <<'EOF_FREE'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
EOF_FREE
cat > "$TMP/stall.py" <<'EOF_STALL'
import socket, sys
# Holds its first connection open without answering (a stalled probe on a
# half-up link) and answers every later one at once, recording each answer.
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(8)
print(s.getsockname()[1], flush=True)
held = []
while True:
    c, _ = s.accept()
    if not held:
        held.append(c)
        continue
    c.recv(65536)
    with open(sys.argv[1], "a") as f:
        f.write("hit\n")
    c.sendall(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    c.close()
EOF_STALL
port_of() {
  # Wait for the server's first stdout line (its bound port).
  local file=$1 n=0
  while [ ! -s "$file" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  head -n1 "$file"
}

python3 "$TMP/answer.py" "$TMP/answer.hits" > "$TMP/answer.port" 2>"$TMP/answer.err" &
pids+=($!)
python3 "$TMP/hang.py" > "$TMP/hang.port" 2>"$TMP/hang.err" &
pids+=($!)
python3 "$TMP/stall.py" "$TMP/stall.hits" > "$TMP/stall.port" 2>"$TMP/stall.err" &
pids+=($!)
answer_port=$(port_of "$TMP/answer.port")
hang_port=$(port_of "$TMP/hang.port")
stall_port=$(port_of "$TMP/stall.port")
if ! refused_port=$(python3 "$TMP/freeport.py" 2>"$TMP/freeport.err"); then
  bad "4: freeport.py did not run (python3 missing?): $(cat "$TMP/freeport.err")"
  refused_port=9
fi

if [ -n "$answer_port" ]; then
  set +e
  out=$("$SCRIPT" --url "http://127.0.0.1:$answer_port/" --wait 5 --interval 1 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -s "$TMP/answer.hits" ]; then
    ok "4: reachable URL: exit 0, silent on the first attempt, and the server saw the request"
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    bad "4: reachable URL: exit 0 and silent, but the server saw no request (exit-and-silence alone passes a probe that asks nothing)"
  else
    bad "4: reachable URL: expected exit 0 with no output, got exit $rc: $out"
  fi
else
  bad "4: local answering server did not start: $(cat "$TMP/answer.err")"
fi

set +e
t0=$(date +%s)
out=$("$SCRIPT" --url "http://127.0.0.1:$refused_port/" --wait 2 --interval 1 2>&1); rc=$?
elapsed=$(( $(date +%s) - t0 ))
set -e
if [ "$rc" -eq 1 ] && grep -q '^WARN net-ready: http://127.0.0.1:'"$refused_port"'/ unreachable for 2s' <<<"$out" && [ "$elapsed" -le 6 ]; then
  ok "4: refused port: exit 1 with a column-0 WARN after the 2s wait (${elapsed}s)"
else
  bad "4: refused port: expected exit 1 with 'WARN net-ready: ... unreachable for 2s' within 6s, got exit $rc after ${elapsed}s: $out"
fi

if [ -n "$hang_port" ]; then
  set +e
  t0=$(date +%s)
  out=$("$SCRIPT" --url "http://127.0.0.1:$hang_port/" --wait 3 --interval 1 2>&1); rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  set -e
  if [ "$rc" -eq 1 ] && grep -q '^WARN net-ready: ' <<<"$out" && [ "$elapsed" -le 9 ]; then
    ok "4: peer that never answers: each attempt bounded, exit 1 after ${elapsed}s (wait 3s)"
  else
    bad "4: peer that never answers: expected exit 1 with a column-0 WARN within 9s, got exit $rc after ${elapsed}s: $out"
  fi
else
  bad "4: local hanging listener did not start: $(cat "$TMP/hang.err")"
fi

if [ -n "$stall_port" ]; then
  set +e
  t0=$(date +%s)
  out=$("$SCRIPT" --url "http://127.0.0.1:$stall_port/" --wait 8 --interval 1 --attempt-timeout 1 2>&1); rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  set -e
  if [ "$rc" -eq 0 ] && grep -q '^net-ready: http://127.0.0.1:'"$stall_port"'/ reachable after [0-9]*s (attempt [2-9]' <<<"$out" \
     && [ -s "$TMP/stall.hits" ] && [ "$elapsed" -le 6 ]; then
    ok "4: first connection stalls, later ones answer: a later attempt succeeds after ${elapsed}s (wait 8s, attempt cap 1s)"
  else
    bad "4: first connection stalls, later ones answer: expected exit 0 from a later attempt within 6s, got exit $rc after ${elapsed}s: $out"
  fi
else
  bad "4: local stalling server did not start: $(cat "$TMP/stall.err")"
fi

# A wall clock that steps back 5s after its first reading, the NTP or WSL
# resync case. A probe that timed its deadline with date would see its time
# left grow past --wait and hold the stalled attempt that much longer.
mkdir -p "$TMP/backclock"
cat > "$TMP/backclock/date" <<'EOF_DATE'
#!/usr/bin/env bash
marker=$(dirname "$0")/stepped
if [ -e "$marker" ]; then
  echo $(( $(command -p date +%s) - 5 ))
else
  : > "$marker"
  command -p date "$@"
fi
EOF_DATE
chmod +x "$TMP/backclock/date"
if [ -n "$hang_port" ]; then
  set +e
  t0=$(date +%s)
  out=$(PATH="$TMP/backclock:$PATH" "$SCRIPT" --url "http://127.0.0.1:$hang_port/" --wait 2 --interval 1 2>&1); rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  set -e
  if [ "$rc" -eq 1 ] && grep -q '^WARN net-ready: ' <<<"$out" && [ "$elapsed" -le 5 ]; then
    ok "4: wall clock steps back 5s mid-wait: still exit 1 after ${elapsed}s of a 2s wait (the deadline does not follow the wall clock)"
  else
    bad "4: wall clock steps back 5s mid-wait: expected exit 1 within 5s, got exit $rc after ${elapsed}s: $out"
  fi
fi

# Leading zeros pass validation, so base-10 arithmetic is the probe's job: in
# bash arithmetic 08 is an invalid octal constant and 010 is 8 (pro-gate
# round 2 on #1465).
if [ -n "$answer_port" ]; then
  : > "$TMP/answer.hits"
  set +e
  out=$("$SCRIPT" --url "http://127.0.0.1:$answer_port/" --wait 08 --interval 1 2>&1); rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -s "$TMP/answer.hits" ]; then
    ok "4: --wait 08: read as eight seconds; the probe ran and the server saw the request"
  else
    bad "4: --wait 08: expected exit 0, no output and a recorded request, got exit $rc: $out"
  fi
fi
set +e
t0=$(date +%s)
out=$("$SCRIPT" --url "http://127.0.0.1:$refused_port/" --wait 010 --interval 1 2>&1); rc=$?
elapsed=$(( $(date +%s) - t0 ))
set -e
if [ "$rc" -eq 1 ] && grep -q '^WARN net-ready: http://127.0.0.1:'"$refused_port"'/ unreachable for 10s' <<<"$out" \
   && [ "$elapsed" -ge 9 ] && [ "$elapsed" -le 14 ]; then
  ok "4: --wait 010: read as ten seconds, not octal eight (exit 1 after ${elapsed}s)"
else
  bad "4: --wait 010: expected exit 1 with 'unreachable for 10s' after 9-14s, got exit $rc after ${elapsed}s: $out"
fi

set +e
"$SCRIPT" --wait 1 >/dev/null 2>&1; rc_nourl=$?
"$SCRIPT" --url "http://127.0.0.1:$refused_port/" --wait x >/dev/null 2>&1; rc_badwait=$?
set -e
[ "$rc_nourl" -eq 2 ] && ok "4: missing --url exits 2" || bad "4: missing --url exited $rc_nourl, expected 2"
[ "$rc_badwait" -eq 2 ] && ok "4: non-numeric --wait exits 2" || bad "4: non-numeric --wait exited $rc_badwait, expected 2"

mkdir -p "$TMP/nocurl"
for tool in bash timeout date sleep tr cut; do
  ln -s "$(command -v "$tool")" "$TMP/nocurl/$tool"
done
set +e
out=$(PATH=$TMP/nocurl "$SCRIPT" --url "http://127.0.0.1:$refused_port/" --wait 1 2>&1); rc=$?
set -e
if [ "$rc" -eq 3 ] && grep -q '^WARN net-ready: curl not on PATH' <<<"$out"; then
  ok "4: curl missing: exit 3 with a column-0 WARN, nothing probed"
else
  bad "4: curl missing: expected exit 3 with 'WARN net-ready: curl not on PATH', got exit $rc: $out"
fi

# ── 5. systemd accepts the units ─────────────────────────────────────────────
if command -v systemd-analyze >/dev/null 2>&1; then
  mkdir -p "$TMP/verify"
  cp "$SYSD/harness-unit-failure-alert@.service" "$TMP/verify/"
  verify_args=()
  for u in "${UNITS[@]}"; do
    cp "$SYSD/$u.service" "$TMP/verify/"
    verify_args+=("$TMP/verify/$u.service")
    if [ -f "$SYSD/$u.timer" ]; then
      cp "$SYSD/$u.timer" "$TMP/verify/"
      verify_args+=("$TMP/verify/$u.timer")
    fi
  done
  for f in "$TMP"/verify/*.service; do
    sed -i ':a; /\\$/ { N; s/\\\n[[:space:]]*/ /; ba; }' "$f"
    sed -i -e 's|^ExecStart=.*|ExecStart=/bin/true|' \
           -e 's|^ExecStartPre=-\?.*|ExecStartPre=/bin/true|' \
           -e 's|^ExecCondition=.*|ExecCondition=/bin/true|' "$f"
  done
  if systemd-analyze verify "${verify_args[@]}" "$TMP/verify/harness-unit-failure-alert@.service" 2>"$TMP/verify.err"; then
    ok "5: systemd-analyze verify accepts the five services and their timers"
  else
    bad "5: systemd-analyze verify rejected a unit: $(cat "$TMP/verify.err")"
  fi
else
  echo "  skip: systemd-analyze not installed; assertion 5 not run"
fi

echo "systemd-network-online: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
