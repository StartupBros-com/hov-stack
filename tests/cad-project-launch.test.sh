#!/usr/bin/env bash
# cad: preserve the current-directory launcher while adding named-repo routing.
#
# Planted negative: an unknown repository must exit non-zero without invoking the
# fake claude binary. If cad silently falls back to forwarding the name, this
# suite records the call and fails.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASHRC=$REPO/.bashrc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOME_FIXTURE=$TMP/home
BIN=$TMP/bin
CALLS=$TMP/claude-calls
EXPECTED=$TMP/expected-calls
DIRENV_CALLS=$TMP/direnv-calls
ENV_CALLS=$TMP/environment-calls
FUNCTION_DIRENV_CALLS=$TMP/function-direnv-calls
ERR=$TMP/stderr
TYPE_FILE=$TMP/cad-type
PWD_AFTER=$TMP/pwd-after
NO_DIRENV_BIN=$TMP/no-direnv-bin
RELATIVE_SOURCE=$TMP/relative-source
export DIRENV_CALLS ENV_CALLS FUNCTION_DIRENV_CALLS
mkdir -p "$HOME_FIXTURE/.cargo" "$HOME_FIXTURE/SITES/acme-app" "$BIN" "$NO_DIRENV_BIN" \
  "$TMP/current/project" "$TMP/cdpath/project" "$TMP/explicit" "$TMP/stale/original" \
  "$TMP/hostile-python" "$TMP/deleted" "$RELATIVE_SOURCE/relbin"
: > "$HOME_FIXTURE/.cargo/env"
: > "$HOME_FIXTURE/.hushlogin"
: > "$CALLS"

cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
printf 'cwd=%s\n' "$PWD" >> "$CALLS"
for arg in "$@"; do
  printf 'arg=%s\n' "$arg" >> "$CALLS"
done
if [ "${CAPTURE_ENV:-0}" = 1 ]; then
  printf 'source=%s\ntarget=%s\n' "${SOURCE_ONLY-unset}" "${TARGET_ONLY-unset}" > "$ENV_CALLS"
fi
exit "${CLAUDE_EXIT:-0}"
FAKE
chmod +x "$BIN/claude"
cp "$BIN/claude" "$NO_DIRENV_BIN/claude"

cat > "$BIN/direnv" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  hook) exit 0 ;;
  exec)
    directory=$2
    shift 2
    printf 'directory=%s\n' "$directory" >> "$DIRENV_CALLS"
    [ -z "${DIRENV_EXIT:-}" ] || exit "$DIRENV_EXIT"
    unset SOURCE_ONLY
    export TARGET_ONLY=loaded
    unset -f "${1:-}" 2>/dev/null || true
    exec "$@"
    ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$BIN/direnv"
cp "$BIN/direnv" "$RELATIVE_SOURCE/relbin/direnv"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
assert_calls() {
  printf '%s\n' "$@" > "$EXPECTED"
  if cmp -s "$EXPECTED" "$CALLS"; then
    ok
  else
    bad "claude call transcript differed"
    printf '%s\n' '--- expected ---' >&2
    command cat "$EXPECTED" >&2
    printf '%s\n' '--- actual ---' >&2
    command cat "$CALLS" >&2
  fi
}
assert_empty_calls() {
  [ ! -s "$CALLS" ] && ok || bad "claude was invoked unexpectedly: $(tr '\n' ' ' < "$CALLS")"
}
run_cad() {
  local test_path=${CAD_TEST_PATH:-$BIN:/usr/bin:/bin}
  HOME=$HOME_FIXTURE PATH=$test_path CALLS=$CALLS \
    bash --noprofile --rcfile "$BASHRC" -ic 'cad "$@"' cad "$@" 2>"$ERR"
}

bash -n "$BASHRC" && ok || bad ".bashrc does not parse"

: > "$TYPE_FILE"
HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin BASHRC=$BASHRC TYPE_FILE=$TYPE_FILE \
  bash --noprofile --norc -ic \
    'alias cad="claude agents --dangerously-skip-permissions"; source "$BASHRC"; type -t cad > "$TYPE_FILE"' \
    2>"$ERR" || bad "reloading .bashrc over the old cad alias failed"
[ "$(< "$TYPE_FILE")" = function ] && ok || bad "reloading left cad as $(< "$TYPE_FILE") instead of a function"

: > "$CALLS"
(
  cd "$TMP/current" || exit 1
  run_cad
) || bad "no-argument cad failed"
assert_calls \
  "cwd=$TMP/current" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"
[ ! -s "$DIRENV_CALLS" ] && ok || bad "no-target cad unexpectedly re-entered direnv"

: > "$CALLS"
(
  cd "$TMP/stale/original" || exit 1
  HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS RENAMED=$TMP/stale/renamed \
    bash --noprofile --rcfile "$BASHRC" -ic 'mv -- "$PWD" "$RENAMED"; cad' 2>"$ERR"
) || bad "no-target cad failed after current directory rename"
assert_calls \
  "cwd=$TMP/stale/renamed" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"

: > "$CALLS"
run_cad --help || bad "flag-only cad failed"
assert_calls \
  "cwd=$PWD" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions" \
  "arg=--help"

: > "$CALLS"
run_cad --json || bad "legacy JSON flag forwarding failed"
assert_calls \
  "cwd=$PWD" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions" \
  "arg=--json"

: > "$CALLS"
run_cad --cwd "$TMP/explicit" || bad "Claude option operand forwarding failed"
assert_calls \
  "cwd=$PWD" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions" \
  "arg=--cwd" \
  "arg=$TMP/explicit"

: > "$CALLS"
wrapper_help=$(run_cad --cad-help) || bad "wrapper help failed"
case "$wrapper_help" in
  *"usage: cad"*) ok ;;
  *) bad "wrapper help omitted usage: $wrapper_help" ;;
esac
assert_empty_calls

: > "$CALLS"
: > "$DIRENV_CALLS"
: > "$ENV_CALLS"
export SOURCE_ONLY=source CAPTURE_ENV=1
run_cad acme-app || bad "named-repo cad failed"
unset SOURCE_ONLY CAPTURE_ENV
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"
printf 'directory=.\n' > "$EXPECTED"
cmp -s "$EXPECTED" "$DIRENV_CALLS" && ok || bad "named-repo cad did not route through target direnv"
printf 'source=unset\ntarget=loaded\n' > "$EXPECTED"
cmp -s "$EXPECTED" "$ENV_CALLS" && ok || bad "named-repo cad kept source env or missed target env"

: > "$CALLS"
: > "$DIRENV_CALLS"
HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS DIRENV_CALLS=$DIRENV_CALLS BASHRC=$BASHRC \
  bash --noprofile --norc -ic \
    'zd() { printf "noisy-zd\n"; builtin cd "$@"; }; zp() { printf "noisy-pwd\n"; builtin pwd "$@"; }; alias cd=zd; alias pwd=zp; source "$BASHRC"; cad acme-app' \
    2>"$ERR" || bad "named-repo cad failed with a preloaded cd alias"
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"
printf 'directory=.\n' > "$EXPECTED"
cmp -s "$EXPECTED" "$DIRENV_CALLS" && ok || bad "aliased-cd launch did not reach target direnv"

: > "$CALLS"
: > "$FUNCTION_DIRENV_CALLS"
HOME=$HOME_FIXTURE PATH=$NO_DIRENV_BIN:/usr/bin:/bin CALLS=$CALLS \
  FUNCTION_DIRENV_CALLS=$FUNCTION_DIRENV_CALLS BASHRC=$BASHRC \
  bash --noprofile --norc -ic \
    'direnv() { case "${1:-}" in hook) return 0 ;; *) printf "called\n" >> "$FUNCTION_DIRENV_CALLS"; return 97 ;; esac; }; source "$BASHRC"; cad acme-app' \
    2>"$ERR" || bad "function-only direnv should use the no-direnv fallback"
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"
[ ! -s "$FUNCTION_DIRENV_CALLS" ] && ok || bad "cad invoked a direnv shell function"

: > "$CALLS"
CAD_TEST_PATH=$NO_DIRENV_BIN:/usr/bin:/bin run_cad acme-app \
  || bad "named-repo cad failed without direnv"
unset CAD_TEST_PATH
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"

: > "$CALLS"
: > "$DIRENV_CALLS"
(
  cd "$RELATIVE_SOURCE" || exit 1
  HOME=$HOME_FIXTURE PATH=relbin:$NO_DIRENV_BIN:/usr/bin:/bin CALLS=$CALLS \
    DIRENV_CALLS=$DIRENV_CALLS BASHRC=$BASHRC \
    bash --noprofile --rcfile "$BASHRC" -ic 'cad acme-app' 2>"$ERR"
) || bad "relative-PATH direnv failed after target cwd switch"
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"
printf 'directory=.\n' > "$EXPECTED"
cmp -s "$EXPECTED" "$DIRENV_CALLS" && ok || bad "relative-PATH direnv was not reused by absolute path"

: > "$CALLS"
run_cad "$TMP/explicit" --resume session-123 || bad "explicit-path cad failed"
assert_calls \
  "cwd=$TMP/explicit" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions" \
  "arg=--resume" \
  "arg=session-123"

: > "$CALLS"
HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS BASHRC=$BASHRC \
  START=$TMP/current TARGET=$TMP/explicit PWD_AFTER=$PWD_AFTER \
  bash --noprofile --norc -ic \
    'builtin cd -- "$START"; source "$BASHRC"; cad "$TARGET"; builtin pwd -P > "$PWD_AFTER"' \
    2>"$ERR" || bad "same-shell target launch failed"
[ "$(< "$PWD_AFTER")" = "$TMP/current" ] && ok || bad "cad changed the caller working directory"

export CLAUDE_EXIT=17
if run_cad acme-app >/dev/null; then
  bad "cad swallowed a Claude failure"
else
  rc=$?
  [ "$rc" -eq 17 ] && ok || bad "cad returned $rc for Claude exit 17"
fi
unset CLAUDE_EXIT

export DIRENV_EXIT=19
if run_cad acme-app >/dev/null; then
  bad "cad swallowed a direnv failure"
else
  rc=$?
  [ "$rc" -eq 19 ] && ok || bad "cad returned $rc for direnv exit 19"
fi
unset DIRENV_EXIT

: > "$CALLS"
export CDPATH=$TMP/cdpath
(
  cd "$TMP/current" || exit 1
  run_cad project
) || bad "relative-path cad failed with CDPATH set"
unset CDPATH
assert_calls \
  "cwd=$TMP/current/project" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"

: > "$CALLS"
HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS BASHRC=$BASHRC TARGET=$TMP/explicit \
  bash --noprofile --norc -ic \
    'CDPATH=/tmp; readonly CDPATH; source "$BASHRC"; cad "$TARGET"' \
    2>"$ERR" || bad "readonly CDPATH blocked an absolute target"
assert_calls \
  "cwd=$TMP/explicit" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"

newline_dir=$TMP/$'project\n'
mkdir -p -- "$newline_dir"
newline_json=$(
  HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS BASHRC=$BASHRC TARGET=$newline_dir \
    bash --noprofile --norc -ic 'readonly IFS; source "$BASHRC"; cad --cad-json "$TARGET"' 2>"$ERR"
) || bad "newline-suffixed directory JSON failed with readonly IFS"
JSON_PLAN=$newline_json EXPECTED_DIRECTORY=$newline_dir python3 -I -S - <<'PY' && ok || bad "newline-suffixed directory was not preserved"
import json
import os

payload = json.loads(os.environ["JSON_PLAN"])
assert payload["directory"] == os.environ["EXPECTED_DIRECTORY"]
PY

: > "$CALLS"
human_plan=$(run_cad --dry-run acme-app) || bad "human dry-run failed"
case "$human_plan" in
  *"$HOME_FIXTURE/SITES/acme-app"*"claude"*"agents"*) ok ;;
  *) bad "human dry-run omitted the target or command: $human_plan" ;;
esac
assert_empty_calls

: > "$CALLS"
HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS PLAN=$human_plan \
  START=$TMP/current PWD_AFTER=$PWD_AFTER \
  bash --noprofile --norc -ic \
    'builtin cd -- "$START"; zd() { return 41; }; alias cd=zd; claude() { return 42; }; export -f claude; eval "$PLAN"; builtin pwd -P > "$PWD_AFTER"' \
    2>"$ERR" || bad "human dry-run plan did not reproduce the hardened launch"
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"
[ "$(< "$PWD_AFTER")" = "$TMP/current" ] && ok || bad "executing dry-run plan changed the caller directory"

: > "$CALLS"
json_plan=$(run_cad --dry-run --json acme-app --resume session-123) || bad "JSON dry-run failed"
JSON_PLAN=$json_plan HOME_FIXTURE=$HOME_FIXTURE python3 - <<'PY' && ok || bad "JSON dry-run payload was wrong"
import json
import os

payload = json.loads(os.environ["JSON_PLAN"])
assert payload == {
    "status": "ok",
    "dry_run": True,
    "directory": f'{os.environ["HOME_FIXTURE"]}/SITES/acme-app',
    "argv": ["claude", "agents", "--dangerously-skip-permissions", "--resume", "session-123"],
}
PY
assert_empty_calls

NOISY_VENV=$TMP/noisy-venv
python3 -m venv "$NOISY_VENV" || bad "could not build noisy Python fixture"
site_packages=$(
  "$NOISY_VENV/bin/python3" - <<'PY'
import sysconfig

print(sysconfig.get_path("purelib"))
PY
)
SITE_MARKER=$TMP/site-marker
export SITE_MARKER
cat > "$site_packages/cad-noise.pth" <<'PY'
import os; print("site-noise"); open(os.environ["SITE_MARKER"], "w", encoding="utf-8").write("executed")
PY
CAD_TEST_PATH=$NOISY_VENV/bin:$BIN:/usr/bin:/bin
site_json=$(run_cad --cad-json acme-app) || bad "JSON dry-run failed in noisy venv"
unset CAD_TEST_PATH
JSON_PLAN=$site_json HOME_FIXTURE=$HOME_FIXTURE python3 -I -S - <<'PY' && ok || bad "noisy-venv JSON payload was impure"
import json
import os

payload = json.loads(os.environ["JSON_PLAN"])
assert payload["directory"] == f'{os.environ["HOME_FIXTURE"]}/SITES/acme-app'
PY
[ ! -e "$SITE_MARKER" ] && ok || bad "JSON dry-run executed a venv .pth file"
unset SITE_MARKER

JSON_HIJACK=$TMP/json-hijack
export JSON_HIJACK
cat > "$TMP/hostile-python/json.py" <<'PY'
import os

with open(os.environ["JSON_HIJACK"], "w", encoding="utf-8") as marker:
    marker.write("executed")
raise RuntimeError("project-local json.py executed")
PY
hostile_json=$(cd "$TMP/hostile-python" && run_cad --dry-run --json acme-app) \
  || bad "JSON dry-run failed beside hostile json.py"
JSON_PLAN=$hostile_json HOME_FIXTURE=$HOME_FIXTURE python3 -I - <<'PY' && ok || bad "isolated JSON dry-run payload was wrong"
import json
import os

payload = json.loads(os.environ["JSON_PLAN"])
assert payload["directory"] == f'{os.environ["HOME_FIXTURE"]}/SITES/acme-app'
PY
[ ! -e "$JSON_HIJACK" ] && ok || bad "JSON dry-run executed project-local json.py"
unset JSON_HIJACK

DELETED_OUT=$TMP/deleted-output
if (
  cd "$TMP/deleted" || exit 1
  HOME=$HOME_FIXTURE PATH=$BIN:/usr/bin:/bin CALLS=$CALLS OUT=$DELETED_OUT BASHRC=$BASHRC \
    bash --noprofile --rcfile "$BASHRC" -ic 'rmdir -- "$PWD"; cad --cad-json > "$OUT"' 2>"$ERR"
); then
  bad "deleted current directory produced a successful JSON plan"
else
  ok
fi
[ ! -s "$DELETED_OUT" ] && ok || bad "deleted current directory emitted JSON"

non_utf8_dir=$TMP/$'non-utf8-\xff'
mkdir -p -- "$non_utf8_dir"
if non_utf8_json=$(run_cad --cad-json "$non_utf8_dir"); then
  bad "non-UTF-8 directory produced lossy JSON"
else
  ok
fi
[ -z "$non_utf8_json" ] && ok || bad "non-UTF-8 refusal emitted partial JSON"

REAL_PYTHON=$(command -v python3)
PYTHON_ARGS=$TMP/python-args
export REAL_PYTHON PYTHON_ARGS
cat > "$BIN/python3" <<'FAKE'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$PYTHON_ARGS"
exec "$REAL_PYTHON" "$@"
FAKE
chmod +x "$BIN/python3"
utf8_json=$(run_cad --cad-json acme-app) || bad "UTF-8-mode serializer invocation failed"
JSON_PLAN=$utf8_json python3 -I -S - <<'PY' && ok || bad "UTF-8-mode serializer emitted invalid JSON"
import json
import os

json.loads(os.environ["JSON_PLAN"])
PY
python_args=()
builtin mapfile -d '' -t python_args < "$PYTHON_ARGS"
if [ "${python_args[0]-}" = -I ] && [ "${python_args[1]-}" = -S ] \
   && [ "${python_args[2]-}" = -X ] && [ "${python_args[3]-}" = utf8 ] \
   && [ "${python_args[4]-}" = - ]; then
  ok
else
  bad "serializer did not force isolated UTF-8 mode"
fi

cat > "$BIN/python3" <<'FAKE'
#!/usr/bin/env bash
exit 23
FAKE
chmod +x "$BIN/python3"
if run_cad --cad-json acme-app >/dev/null; then
  bad "cad swallowed a Python serializer failure"
else
  rc=$?
  [ "$rc" -eq 23 ] && ok || bad "cad returned $rc for Python exit 23"
fi
rm -f "$BIN/python3"

: > "$CALLS"
: > "$DIRENV_CALLS"
if run_cad "" >/dev/null; then
  bad "empty repository target returned success"
else
  ok
fi
assert_empty_calls
[ ! -s "$DIRENV_CALLS" ] && ok || bad "empty repository target reached direnv"

: > "$CALLS"
if run_cad definitely-not-a-real-repository >/dev/null; then
  bad "unknown repository returned success"
else
  ok
fi
assert_empty_calls
command grep -Fq 'unknown project or directory' "$ERR" && ok || bad "unknown repository error was not useful"

: > "$CALLS"
: > "$DIRENV_CALLS"
run_cad --all || bad "--all failed"
assert_calls \
  "cwd=$HOME_FIXTURE/SITES" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions"

: > "$CALLS"
run_cad --all --model opus || bad "--all dropped forwarded claude args"
assert_calls \
  "cwd=$HOME_FIXTURE/SITES" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions" \
  "arg=--model" \
  "arg=opus"

: > "$CALLS"
if run_cad --all acme-app >/dev/null; then
  bad "--all combined with a target returned success"
else
  ok
fi
assert_empty_calls
command grep -Fq 'unexpected extra target' "$ERR" && ok || bad "--all + target error was not useful"

: > "$CALLS"
if run_cad --all --all >/dev/null; then
  bad "repeated --all returned success"
else
  ok
fi
assert_empty_calls
command grep -Fq 'cannot be combined with a target' "$ERR" && ok || bad "repeated --all error was not useful"

: > "$CALLS"
if run_cad acme-app --all >/dev/null; then
  ok
else
  bad "--all after a target should forward to claude, not error"
fi
assert_calls \
  "cwd=$HOME_FIXTURE/SITES/acme-app" \
  "arg=agents" \
  "arg=--dangerously-skip-permissions" \
  "arg=--all"

: > "$CALLS"
mkdir -p "$TMP/home-no-sites"
: > "$TMP/home-no-sites/.hushlogin"
if HOME=$TMP/home-no-sites PATH=$BIN:/usr/bin:/bin CALLS=$CALLS \
  bash --noprofile --rcfile "$BASHRC" -ic 'cad --all' cad 2>"$ERR"; then
  bad "--all returned success with no SITES root"
else
  ok
fi
assert_empty_calls
command grep -Fq 'needs' "$ERR" && ok || bad "--all missing-SITES error was not useful"

: > "$CALLS"
all_dry=$(run_cad --dry-run --all) || bad "--dry-run --all failed"
case "$all_dry" in
  *"$HOME_FIXTURE/SITES"*) ok ;;
  *) bad "--dry-run --all omitted the SITES root: $all_dry" ;;
esac
assert_empty_calls

: > "$CALLS"
all_help=$(run_cad --cad-help) || bad "wrapper help failed after --all"
case "$all_help" in
  *--all*) ok ;;
  *) bad "wrapper help omitted --all: $all_help" ;;
esac
assert_empty_calls

if [ "$fail" -eq 0 ]; then
  printf 'ok — cad project launcher: %d/%d assertions passed\n' "$pass" "$((pass + fail))"
else
  printf 'FAIL — cad project launcher: %d of %d assertions failed\n' "$fail" "$((pass + fail))" >&2
  exit 1
fi
