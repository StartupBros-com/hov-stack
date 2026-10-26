#!/usr/bin/env bash
# Hermetic tests for scripts/notify.sh's PowerShell quoting (issue #1211).
#
# notify.sh splices the message and the subtitle into PowerShell SINGLE-quoted
# string literals. Such a literal has exactly one metacharacter -- the
# apostrophe -- escaped by doubling it. The original code escaped `"` (to a
# backtick form that PowerShell does not want inside '...') and left `'` alone,
# so a single apostrophe terminated the literal, the whole -Command failed to
# parse, and the toast silently never appeared. Reproduced before the fix:
# exit 1, "The string is missing the terminator: '."
#
# That is not hypothetical: tool-update.sh:174 emits literal apostrophes
# unconditionally -- say "$as update FAILED: payload '$member' not found in
# archive" -- i.e. precisely on a failure path whose whole job is to reach a
# human.
#
# No Windows and no balloon required: NOTIFY_POWERSHELL_BIN redirects the
# interop call at a stub that captures the generated script text, so this runs
# on a CI box with no /mnt/c at all. Assertions decode the captured literal
# back with the inverse rule ('' -> ') and require it to equal the input
# exactly -- testing notify.sh's real transform, not a copy of it.
#
# Planted negatives:
#  - N3: "payload 'lib/dcg' not found" must decode back with SINGLE apostrophes.
#    A fix that doubles and never unescapes yields ''lib/dcg''; one that strips
#    apostrophes yields lib/dcg. Both pass a bare "exit code is 0" assertion and
#    both fail here.
#  - N6: a subtitle carrying an apostrophe (a repo directory named will's-repo)
#    must be escaped too -- the subtitle goes through the same splice and was
#    equally broken, so fixing only the message leaves half the bug live.
#  - N7: the stub must actually have been invoked. A capture file that is never
#    written makes every assertion above vacuously true.
#
# Test-suite guard (cases 10-12, the 2026-09-28 recurrence of #1211): on the
# real interop path notify.sh must not launch PowerShell when an ancestor's argv
# names a test runner. The launch is observed through `timeout`, which notify.sh
# resolves via PATH, so a broken guard records a line instead of popping a real
# balloon. Each case runs in an orphan, reparented away from this suite, so this
# suite's own argv cannot satisfy a case whose runner form the guard misses.
# Case 11 is the precondition for case 10: an orphan with no runner form must
# reach the launch.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
SCRIPT="$HERE/scripts/notify.sh"
TMP=$(mktemp -d)
# An orphan still running at exit is killed by process group (setsid made it a
# leader) before its PATH stub disappears, so it cannot fall through to the
# real `timeout` and pop a real balloon.
cleanup() {
  local f
  for f in "$TMP"/*.pid; do
    [ -f "$f" ] && [ ! -f "${f%.pid}.rc" ] && kill -- "-$(cat "$f")" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

Q="'"
CAP="$TMP/captured.ps1"
CALLS="$TMP/calls.log"

# Stub standing in for powershell.exe: records that it ran, and keeps the
# -Command payload verbatim.
cat > "$TMP/ps-stub" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >> "${PS_CALLS:?}"
prev=""
for a in "$@"; do
  [ "$prev" = "-Command" ] && printf '%s' "$a" > "${PS_CAPTURE:?}"
  prev="$a"
done
exit 0
STUB
chmod +x "$TMP/ps-stub"

# render <workdir> <message> -> notify.sh's exit status; script text lands in $CAP
render() {
  local wd=$1 msg=$2
  : > "$CAP"
  ( cd "$wd" && PS_CAPTURE="$CAP" PS_CALLS="$CALLS" \
      NOTIFY_POWERSHELL_BIN="$TMP/ps-stub" bash "$SCRIPT" "$msg" none >/dev/null 2>&1 )
  printf '%s\n' "$?"
}

# decode_field <ps-property> -> the literal's text with the inverse escape rule
decode_field() {
  local prop=$1 line body stripped
  line=$(grep -F "$prop = " "$CAP" | head -1)
  [ -n "$line" ] || { printf '__NO_SUCH_LINE__\n'; return; }
  body=${line#*"$prop = $Q"}
  body=${body%"$Q"}
  # Well-formedness: with every escaped pair removed, no bare apostrophe may
  # survive inside the literal. A bare one is exactly the parse break.
  stripped=${body//$Q$Q/}
  case $stripped in
    *"$Q"*) printf '__UNBALANCED__\n'; return ;;
  esac
  printf '%s\n' "${body//$Q$Q/$Q}"
}

# A non-git working dir keeps SUBTITLE deterministic ("Claude Code").
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"

# 1. A message with no metacharacters must round-trip untouched.
rc=$(render "$PLAIN" "dcg auto-updated: v0.14.3 -> v0.14.4")
[ "$rc" = 0 ] && ok || bad "plain message exited $rc"
got=$(decode_field 'BalloonTipText')
[ "$got" = "dcg auto-updated: v0.14.3 -> v0.14.4" ] && ok \
  || bad "plain message did not round-trip :: $got"

# 2. THE BUG. An apostrophe must survive, and the literal must stay balanced.
APOS="dcg update FAILED: payload 'lib/dcg' not found in archive"
rc=$(render "$PLAIN" "$APOS")
[ "$rc" = 0 ] && ok || bad "apostrophe message exited $rc"
got=$(decode_field 'BalloonTipText')
[ "$got" != "__UNBALANCED__" ] && ok \
  || bad "apostrophe left an unbalanced PowerShell literal — this is the parse break"

# 3. PLANTED NEGATIVE: decoded text must carry SINGLE apostrophes. Doubling
#    without unescaping, or stripping them, both fail here and only here.
[ "$got" = "$APOS" ] && ok \
  || bad "apostrophe round-trip is not exact :: want [$APOS] got [$got]"

# 4. The raw captured literal must contain the DOUBLED form -- proof the
#    escape happened in notify.sh rather than the apostrophe merely surviving
#    by luck of a different quoting style.
grep -qF "payload ${Q}${Q}lib/dcg${Q}${Q} not found" "$CAP" && ok \
  || bad "captured script does not show a doubled-apostrophe escape :: $(grep -F 'BalloonTipText' "$CAP" | head -1)"

# 5. A double quote must round-trip intact, with no stray backtick. The old
#    transform rewrote " to a backtick form that is not an escape inside
#    '...', corrupting the rendered text.
DQ='cass candidate "v1.2.3" REJECTED'
rc=$(render "$PLAIN" "$DQ")
[ "$rc" = 0 ] && ok || bad "double-quote message exited $rc"
got=$(decode_field 'BalloonTipText')
[ "$got" = "$DQ" ] && ok || bad "double quote did not round-trip :: want [$DQ] got [$got]"
case $got in
  *'`'*) bad "a stray backtick was injected into the rendered text :: $got" ;;
  *) ok ;;
esac

# 6. The em-dash the dcg/tool-update messages actually use must survive the
#    splice. (How Windows RENDERS it under a non-UTF-8 console codepage is a
#    separate concern and explicitly out of scope.)
EM="dcg REFUSED v0.14.5: contract cases failed — still on v0.14.4"
rc=$(render "$PLAIN" "$EM")
[ "$rc" = 0 ] && ok || bad "em-dash message exited $rc"
got=$(decode_field 'BalloonTipText')
[ "$got" = "$EM" ] && ok || bad "em-dash did not round-trip :: want [$EM] got [$got]"

# 7. Both metacharacters at once, the realistic tool-update.sh:174 shape.
BOTH="tool-update FAILED: payload 'dcg' not in \"archive.tar.xz\""
rc=$(render "$PLAIN" "$BOTH")
[ "$rc" = 0 ] && ok || bad "mixed-metacharacter message exited $rc"
got=$(decode_field 'BalloonTipText')
[ "$got" = "$BOTH" ] && ok || bad "mixed metacharacters did not round-trip :: want [$BOTH] got [$got]"

# 8. PLANTED NEGATIVE: the SUBTITLE takes the same splice and was equally
#    broken. notify.sh derives it from the git repo directory name, so a repo
#    path containing an apostrophe is a live trigger. Fixing only the message
#    leaves this half of the bug in place.
APOSREPO="$TMP/will's-repo"
mkdir -p "$APOSREPO"
( cd "$APOSREPO" && git init -q 2>/dev/null && git config user.email t@t && git config user.name t ) || true
if [ -d "$APOSREPO/.git" ]; then
  rc=$(render "$APOSREPO" "subtitle check")
  [ "$rc" = 0 ] && ok || bad "apostrophe-subtitle run exited $rc"
  got=$(decode_field 'BalloonTipTitle')
  [ "$got" != "__UNBALANCED__" ] && ok \
    || bad "apostrophe in the repo name left an unbalanced literal in the TITLE"
  [ "$got" = "will's-repo" ] && ok \
    || bad "subtitle did not round-trip :: want [will's-repo] got [$got]"
else
  echo "note: git unavailable, skipping the subtitle planted negative" >&2
fi

# 9. PLANTED NEGATIVE: everything above is vacuous if the stub never ran.
[ -s "$CALLS" ] && ok || bad "the powershell stub was never invoked — every assertion above is vacuous"

# --- Test-suite guard ----------------------------------------------------------
# orphan.sh waits until its parent (the subshell that launched it) has exited
# and it has been reparented, so its ancestry no longer includes this suite. Its
# own argv carries one runner form. It runs middle.sh, which stands in for the
# script under test (its argv matches nothing), and middle.sh runs notify.sh. A
# match therefore needs the walk to climb two levels.
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TIMEOUT_LOG:?}"
exit 0
STUB
chmod +x "$STUBS/timeout"
cat > "$TMP/middle.sh" <<'MIDDLE'
#!/usr/bin/env bash
bash "$1" "$2" none
exit $?
MIDDLE
cat > "$TMP/orphan.sh" <<'ORPHAN'
#!/usr/bin/env bash
# orphan.sh <launching-parent-pid> <out-prefix> <runner-form> <middle> <notify> <message>
echo $$ > "$2.pid"
for _ in $(seq 1 100); do
  ppid=""
  while read -r key val; do [ "$key" = "PPid:" ] && { ppid=$val; break; }; done < "/proc/$$/status"
  [ "$ppid" != "$1" ] && break
  sleep 0.05
done
bash "$4" "$5" "$6" 2>"$2.err"
echo $? > "$2.rc"
ORPHAN
REAL_PS="15 /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile"

# orphan <name> <runner-form> [NAME=VALUE...]: run one guarded call, wait up to 10 s.
orphan() {
  local name=$1 form=$2; shift 2
  local out="$TMP/$name"
  : > "$out.log"
  (
    cd "$PLAIN" || exit 1
    launcher=$BASHPID
    env -u NOTIFY_POWERSHELL_BIN PATH="$STUBS:$PATH" TIMEOUT_LOG="$out.log" "$@" \
      setsid bash "$TMP/orphan.sh" "$launcher" "$out" "$form" "$TMP/middle.sh" "$SCRIPT" "guard $name" \
      </dev/null >/dev/null 2>&1 &
  )
  for _ in $(seq 1 100); do [ -s "$out.rc" ] && break; sleep 0.1; done
}

# 10. Every runner form, found two levels up, suppresses: exit 0, the notice
#     naming that form, and no launch. notify.test.sh is harness-doctor.sh's
#     bare-basename launch; unittest and test_*.py are its Python launch.
n=0
for form in "$HERE/tests/notify.test.sh" notify.test.sh tests/notify.test.sh tests \
            claude.tests.test_notify unittest pytest test_notify.py; do
  n=$((n + 1)); out="$TMP/g$n"
  orphan "g$n" "$form"
  if [ "$(cat "$out.rc" 2>/dev/null)" = 0 ] \
     && grep -qF "suppressed under a test suite ($form)" "$out.err" 2>/dev/null \
     && [ ! -s "$out.log" ]; then
    ok
  else
    bad "runner form [$form] was not suppressed :: rc=$(cat "$out.rc" 2>/dev/null) err=$(cat "$out.err" 2>/dev/null) launch=$(head -1 "$out.log" 2>/dev/null)"
  fi
done

# 11. Precondition for 10, and the whitespace rule: an orphan whose only mention
#     of a runner sits inside a whitespace-containing element must launch.
orphan control "please run tests/notify.test.sh"
if grep -qF "$REAL_PS" "$TMP/control.log" && ! grep -qF 'suppressed' "$TMP/control.err" 2>/dev/null; then
  ok
else
  bad "an orphan with no runner form did not reach the interop launch, so case 10 proves nothing :: rc=$(cat "$TMP/control.rc" 2>/dev/null) err=$(cat "$TMP/control.err" 2>/dev/null)"
fi

# 12. A caller that sets NOTIFY_POWERSHELL_BIN keeps its stub, even under a runner.
orphan override notify.test.sh NOTIFY_POWERSHELL_BIN="$TMP/ps-stub"
if grep -qF "15 $TMP/ps-stub -NoProfile" "$TMP/override.log" && ! grep -qF 'suppressed' "$TMP/override.err" 2>/dev/null; then
  ok
else
  bad "NOTIFY_POWERSHELL_BIN was not honoured under a runner :: err=$(cat "$TMP/override.err" 2>/dev/null) launch=$(head -1 "$TMP/override.log" 2>/dev/null)"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — notify.sh PowerShell quoting: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — notify.sh PowerShell quoting: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
