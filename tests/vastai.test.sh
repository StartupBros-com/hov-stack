#!/usr/bin/env bash
# Tests for bin/vastai (vastai_wrap.py) and bin/vast-ssh (dotfiles#1767).
#
# Wrapper contract: the vendor process receives VAST_API_KEY in its environment
# and never in argv; the credential chain is env -> bws -> ~/.secrets, with env
# winning without a bws call; --where names the source and never the value;
# --version, --help, `help` and a bare invocation resolve no credential and run
# with VAST_URL pointed at a closed loopback port; `set api-key`, `--api-key`,
# `--explain`, `--curl`, a non-loopback `--url` or VAST_URL, `update`, and
# `destroy instance(s)` without -y are refused (exit 2) before any exec; --full
# is added unless --raw or --full is present; VASTAI_NO_UPDATE_CHECK=1 is set;
# a vendor exit 0 after a stderr "Failed with error" line or a --raw
# {"error": true} object becomes exit 1, any non-zero vendor status passes
# through; a plaintext key file draws a warning; a missing venv is exit 3 with
# the recreate commands; nothing found is exit 4; a failing or hung bws is exit
# 5 (never the exit-4 "missing", whose fix would re-seed a key that may still
# exist). Planted negatives: the fake venv binary records what it received, so
# a wrapper that leaked the key into argv, or forwarded the test-only
# VASTAI_BWS_TIMEOUT_SECONDS, fails here.
#
# vast-ssh contract: resolves ssh://user@host:port through the sibling wrapper,
# execs ssh with the agent key, BatchMode, a per-instance known_hosts file and
# the trailing command; relays a non-URL answer with exit 3.
#
# Hermetic: a scratch HOME per scenario, a fake `bws`, a fake venv `vastai` and
# a fake `ssh` on a private PATH, VAST_API_KEY/VASTAI_VENV/VAST_SSH_KEY/VAST_URL
# unset in the parent shell. Nothing here reads the operator's ~/.secrets or
# Bitwarden vault, and no network call is made.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAP="$REPO/bin/vastai"
VSSH="$REPO/bin/vast-ssh"
TMP=$(mktemp -d /tmp/vastai-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
unset VAST_API_KEY VASTAI_VENV VAST_SSH_KEY VASTAI_BWS_TIMEOUT_SECONDS VAST_URL XDG_CONFIG_HOME VASTAI_NO_UPDATE_CHECK

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) ok ;; *) bad "$label: missing '$needle' in: $output" ;; esac
}
omits() {
  local output=$1 needle=$2 label=$3
  case "$output" in *"$needle"*) bad "$label: unexpectedly contained '$needle'" ;; *) ok ;; esac
}
status_is() {
  local actual=$1 expected=$2 label=$3
  [ "$actual" -eq "$expected" ] && ok || bad "$label: expected exit $expected, got $actual"
}
equals() {
  local actual=$1 expected=$2 label=$3
  [ "$actual" = "$expected" ] && ok || bad "$label: expected '$expected', got '$actual'"
}

HOMEDIR=$TMP/home
FAKEBIN=$TMP/bin
VENV=$TMP/venv
CALLS=$TMP/bws-calls.log
VENDOR_LOG=$TMP/vendor.log
SSH_LOG=$TMP/ssh-args.log
mkdir -p "$HOMEDIR" "$FAKEBIN" "$VENV/bin"
: >"$CALLS"

PY_DIR=$(dirname "$(command -v python3)")
BASE_PATH="$FAKEBIN:$PY_DIR:/usr/bin:/bin"

ENV_KEY=envkey00000000000000000000000000000000000000000000000000000001
BWS_KEY=bwskey00000000000000000000000000000000000000000000000000000002
FILE_KEY=filekey0000000000000000000000000000000000000000000000000000003
INSTANCE_KEY=instkey0000000000000000000000000000000000000000000000000004

# Fake vendor binary: records argv and the environment it received (the key is
# a fixture value, so printing it here is safe). Scenario cases mirror the real
# vendor: errors go to stderr and exit 0, `ssh-url` prints the URL on its own
# stdout line, `--version` prints a version.
cat >"$VENV/bin/vastai" <<EOF
#!/usr/bin/env bash
{
  printf 'argv:%s\n' "\$*"
  printf 'env_key:%s\n' "\${VAST_API_KEY:-absent}"
  printf 'timeout_env:%s\n' "\${VASTAI_BWS_TIMEOUT_SECONDS:-absent}"
  printf 'url_env:%s\n' "\${VAST_URL:-absent}"
  printf 'noupdate_env:%s\n' "\${VASTAI_NO_UPDATE_CHECK:-absent}"
} | tee -a "$VENDOR_LOG" >&2
case " \$* " in
  *" ssh-url 123 "*) echo "Session notice on stdout, not a URL"; echo "ssh://root@203.0.113.9:40000" ;;
  *" ssh-url 456 "*) echo "ssh://root@ssh5.vast.ai:12345" ;;
  *" ssh-url 998 "*) echo "error: ssh port not found"; exit 0 ;;
  *" ssh-url 999 "*) echo "failed with error 404: Instance 999 not found"; exit 1 ;;
  *" --version "*) echo "9.9.9" ;;
  *" show instance 404 "*) echo "Failed with error 404: Instance not found" >&2; exit 0 ;;
  *" show instance 405 "*) echo '{"error": true, "status_code": 405, "msg": "no such instance"}' >&2; exit 0 ;;
  *" show instance 7 "*) echo "vendor failed" >&2; exit 7 ;;
  *" show instance 200 "*) echo '{"instances": [{"id": 200, "error": "a field named error is not a failure"}]}' ;;
  *" show instances "*) echo '[{"id": 300, "label": "job", "actual_status": "running", "jupyter_token": "0000000000000000000000000000000000000000", "ssh_host": "ssh3.vast.ai"}]' ;;
  *" create instance 111 "*) echo '{"success": true, "new_contract": 55829021, "instance_api_key": "$INSTANCE_KEY"}' ;;
  *" create instance 112 "*) echo "Started. {'success': True, 'new_contract': 55829022, 'instance_api_key': '$INSTANCE_KEY'}" ;;
  *" create instance 113 "*) echo '{"success": true, "new_contract": 55829023, "instance_api_key": "$INSTANCE_KEY"}' >&2; echo '{"ssh_key": "ssh-ed25519 AAAA agent", "api_key_hint": "x"}' ;;
esac
EOF
chmod +x "$VENV/bin/vastai"

cat >"$FAKEBIN/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$SSH_LOG"
echo "fake-ssh-ran"
exit 7
EOF
chmod +x "$FAKEBIN/ssh"

reset_home() {
  rm -rf "$HOMEDIR"
  mkdir -p "$HOMEDIR"
  : >"$CALLS"
  : >"$VENDOR_LOG"
  rm -f "$FAKEBIN/bws" "$SSH_LOG"
}

configure_bws_files() {
  mkdir -p "$HOMEDIR/.config/bws"
  printf 'fixture-token\n' >"$HOMEDIR/.config/bws/token"
  printf 'fixture-project\n' >"$HOMEDIR/.config/bws/sb-project-id"
}

make_bws_empty() {
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
echo '[]'
EOF
  chmod +x "$FAKEBIN/bws"
}

make_bws_with_key() {
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
printf '[{"key": "OTHER_KEY", "value": "other"}, {"key": "VAST_API_KEY", "value": "%s"}]\n' "$1"
EOF
  chmod +x "$FAKEBIN/bws"
}

make_bws_failing() {
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
echo 'Error: access token invalid' >&2
exit 1
EOF
  chmod +x "$FAKEBIN/bws"
}

make_bws_sleep() {
  cat >"$FAKEBIN/bws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
sleep $1
echo '[]'
EOF
  chmod +x "$FAKEBIN/bws"
}

run_wrap() {
  # Remaining args = argv for the wrapper. Sets $OUT (stdout+stderr), $ST.
  OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" timeout 20 "$WRAP" "$@" 2>&1)
  ST=$?
}

run_wrap_env() {
  # $1 = VAST_API_KEY value; remaining = argv.
  local key=$1
  shift
  OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_API_KEY="$key" timeout 20 "$WRAP" "$@" 2>&1)
  ST=$?
}

run_wrap_stdout() {
  # Like run_wrap_env but keeps stdout and stderr apart: $OUT is stdout, $ERR is stderr.
  local key=$1
  shift
  ERR=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_API_KEY="$key" timeout 20 "$WRAP" "$@" 2>&1 1>"$TMP/stdout")
  ST=$?
  OUT=$(cat "$TMP/stdout")
}

# ── --where: source, never value ─────────────────────────────────────────────
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap_env "$ENV_KEY" --where
status_is "$ST" 0 "where/env exit"
equals "$OUT" "env:VAST_API_KEY" "where/env prints the source only"
omits "$OUT" "$ENV_KEY" "where/env never prints the key"
equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "where/env makes no bws call"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --where
status_is "$ST" 0 "where/bws exit"
equals "$OUT" "bws:VAST_API_KEY" "where/bws prints the source only"
omits "$OUT" "$BWS_KEY" "where/bws never prints the key"
equals "$(cat "$CALLS")" "--color no secret list fixture-project" "where/bws calls bws with --color no and the project id"

# A non-login caller (the Windows hop shims through `wsl.exe -e`, a systemd user
# timer) arrives without ~/.local/bin on PATH, which is where bws lives. The
# shim puts it back; without that the chain reported bws unreadable (exit 5)
# although the same command worked from an interactive shell.
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
mkdir -p "$HOMEDIR/.local/bin"
mv "$FAKEBIN/bws" "$HOMEDIR/.local/bin/bws"
OUT=$(HOME="$HOMEDIR" PATH="$PY_DIR:/usr/bin:/bin" VASTAI_VENV="$VENV" timeout 20 "$WRAP" --where 2>&1)
ST=$?
status_is "$ST" 0 "where/bare-path exit (bws only under ~/.local/bin, no login PATH)"
equals "$OUT" "bws:VAST_API_KEY" "where/bare-path finds bws under ~/.local/bin"
equals "$(cat "$CALLS")" "--color no secret list fixture-project" "where/bare-path called bws once"

reset_home; configure_bws_files; make_bws_empty
printf 'export VAST_API_KEY="%s" # comment\n' "$FILE_KEY" >"$HOMEDIR/.secrets"
run_wrap --where
status_is "$ST" 0 "where/secrets exit"
equals "$OUT" "~/.secrets" "where/secrets prints the source only"
omits "$OUT" "$FILE_KEY" "where/secrets never prints the key"

reset_home; configure_bws_files; make_bws_empty
run_wrap --where
status_is "$ST" 4 "where/none is exit 4"
contains "$OUT" "env VAST_API_KEY" "where/none names env"
contains "$OUT" "bws VAST_API_KEY" "where/none names bws"
contains "$OUT" "~/.secrets" "where/none names ~/.secrets"
contains "$OUT" "Store the key in bws as VAST_API_KEY or export VAST_API_KEY" "where/none says how to configure the key"

reset_home; configure_bws_files; make_bws_failing
run_wrap --where
status_is "$ST" 5 "where/bws-failing is exit 5, not missing"
contains "$OUT" "do not re-seed" "where/bws-failing warns against re-seeding"
equals "$(wc -l <"$CALLS" | tr -d ' ')" 2 "where/bws-failing retried bws once"

reset_home; configure_bws_files; make_bws_sleep 5
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VASTAI_BWS_TIMEOUT_SECONDS=1 timeout 20 "$WRAP" --where 2>&1)
ST=$?
status_is "$ST" 5 "where/bws-hang is exit 5"
contains "$OUT" "did not respond within 1s" "where/bws-hang names the bound"

# bws unconfigured (no token files) and no bws binary: plain missing, exit 4.
reset_home
run_wrap --where
status_is "$ST" 4 "where/unconfigured bws is exit 4"

# ── pass-through: key in env only, argv untouched when --raw is given ────────
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap show instances --raw
status_is "$ST" 0 "passthrough exit"
contains "$OUT" "argv:show instances --raw" "passthrough keeps argv verbatim under --raw"
contains "$OUT" "env_key:$BWS_KEY" "passthrough injects the bws key into the child env"
omits "$OUT" "--api-key" "passthrough never adds --api-key to argv"
contains "$OUT" "timeout_env:absent" "passthrough strips the test-only timeout override"
contains "$OUT" "url_env:absent" "passthrough leaves VAST_URL unset for an authenticated command"
contains "$OUT" "noupdate_env:1" "passthrough sets VASTAI_NO_UPDATE_CHECK=1"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap_env "$ENV_KEY" show user --raw
contains "$OUT" "env_key:$ENV_KEY" "env wins over bws"
equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "env present: bws not consulted"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VASTAI_BWS_TIMEOUT_SECONDS=9 timeout 20 "$WRAP" show user 2>&1)
contains "$OUT" "timeout_env:absent" "VASTAI_BWS_TIMEOUT_SECONDS never reaches the vendor process"

# Vendor global flags before the command still resolve the command words; a
# loopback --url is the one accepted form.
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --url http://127.0.0.1:1 --retry 2 --raw show instance 123
contains "$OUT" "argv:--url http://127.0.0.1:1 --retry 2 --raw show instance 123" "global flags pass through in order"
contains "$OUT" "env_key:$BWS_KEY" "global flags before the command still inject the key"

# ── headless default: --full unless --raw/--full is present ──────────────────
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap show instances
status_is "$ST" 0 "full-default exit"
contains "$OUT" "argv:--full --no-color show instances" "non-raw command gets --full prepended"
run_wrap show instances --full
contains "$OUT" "argv:--no-color show instances --full" "an explicit --full is not doubled"
run_wrap --raw show instances
contains "$OUT" "argv:--raw show instances" "an explicit --raw gets no --full"

# ── no-credential paths: no key, no bws, catalog fetch pointed at loopback ──
for args in "--version" "--help" "show instances --help" "help" ""; do
  reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
  # shellcheck disable=SC2086
  run_wrap $args
  status_is "$ST" 0 "no-cred '$args' exit"
  contains "$OUT" "env_key:absent" "no-cred '$args' resolves no key"
  contains "$OUT" "url_env:http://127.0.0.1:9" "no-cred '$args' points VAST_URL at a closed loopback port"
  omits "$OUT" "argv:--full" "no-cred '$args' gets no --full"
  equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "no-cred '$args' makes no bws call"
done
reset_home
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_URL=http://localhost:1 timeout 20 "$WRAP" --version 2>&1)
contains "$OUT" "url_env:http://localhost:1" "no-cred keeps a caller's loopback VAST_URL"

# ── refusals, before any exec ────────────────────────────────────────────────
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap set api-key "$ENV_KEY"
status_is "$ST" 2 "set api-key refused"
contains "$OUT" "refused" "set api-key says refused"
contains "$OUT" "plaintext key file" "set api-key names the reason"
equals "$(cat "$VENDOR_LOG")" "" "set api-key never reaches the vendor"
equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "set api-key resolves no credential"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --url http://127.0.0.1:1 set api-key "$ENV_KEY"
status_is "$ST" 2 "set api-key behind a value flag still refused"
equals "$(cat "$VENDOR_LOG")" "" "set api-key behind a value flag never reaches the vendor"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --api-key "$ENV_KEY" show user
status_is "$ST" 2 "--api-key refused"
contains "$OUT" "argv" "--api-key names the leak"
equals "$(cat "$VENDOR_LOG")" "" "--api-key never reaches the vendor"
run_wrap "--api-key=$ENV_KEY" show user
status_is "$ST" 2 "--api-key= refused"

for flag in --explain --curl; do
  reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
  run_wrap "$flag" show user --raw
  status_is "$ST" 2 "$flag refused"
  contains "$OUT" "prints the full API key" "$flag names the leak"
  equals "$(cat "$VENDOR_LOG")" "" "$flag never reaches the vendor"
  equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "$flag resolves no credential"
done

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --url https://collector.example.test show user --raw
status_is "$ST" 2 "non-loopback --url refused"
contains "$OUT" "would send the API key" "non-loopback --url names the exfiltration"
equals "$(cat "$VENDOR_LOG")" "" "non-loopback --url never reaches the vendor"
run_wrap --url=https://collector.example.test show user --raw
status_is "$ST" 2 "non-loopback --url= refused"

# argparse accepts any unambiguous prefix of a long option, so the guards must
# read `--cur` as `--curl` and `--ur` as `--url` (adversarial round 1, P1).
for flag in --cur --c --expl --e; do
  reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
  run_wrap "$flag" show user --raw
  status_is "$ST" 2 "abbreviated $flag refused"
  contains "$OUT" "prints the full API key" "abbreviated $flag names the leak"
  contains "$OUT" "argparse reads it as" "abbreviated $flag names the canonical flag"
  equals "$(cat "$VENDOR_LOG")" "" "abbreviated $flag never reaches the vendor"
  equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "abbreviated $flag resolves no credential"
done
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --api "$ENV_KEY" show user
status_is "$ST" 2 "abbreviated --api refused as --api-key"
equals "$(cat "$VENDOR_LOG")" "" "abbreviated --api never reaches the vendor"
run_wrap "--api-k=$ENV_KEY" show user
status_is "$ST" 2 "abbreviated --api-k= refused as --api-key"
run_wrap --ur https://collector.example.test show user --raw
status_is "$ST" 2 "abbreviated non-loopback --ur refused"
contains "$OUT" "would send the API key" "abbreviated --ur names the exfiltration"
equals "$(cat "$VENDOR_LOG")" "" "abbreviated --ur never reaches the vendor"
run_wrap --ur=https://collector.example.test show user --raw
status_is "$ST" 2 "abbreviated non-loopback --ur= refused"
run_wrap --ret 2 set api-key "$ENV_KEY"
status_is "$ST" 2 "set api-key behind an abbreviated value flag still refused"
equals "$(cat "$VENDOR_LOG")" "" "set api-key behind --ret never reaches the vendor"
run_wrap --ur http://127.0.0.1:1 --raw show instance 123
status_is "$ST" 0 "abbreviated loopback --ur accepted"
contains "$OUT" "argv:--ur http://127.0.0.1:1 --raw show instance 123" "abbreviated loopback --ur passes through unchanged"
run_wrap --r show instance 123
status_is "$ST" 0 "ambiguous --r is left to the vendor's parser"
contains "$OUT" "argv:--full --no-color --r show instance 123" "ambiguous --r is not read as --raw"
run_wrap --ra show instance 123
contains "$OUT" "argv:--ra show instance 123" "abbreviated --ra is read as --raw, so no --full or --no-color"
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap --vers
status_is "$ST" 0 "abbreviated --vers exits 0"
equals "$(wc -l <"$CALLS" | tr -d ' ')" 0 "abbreviated --vers resolves no credential"
contains "$OUT" "url_env:http://127.0.0.1:9" "abbreviated --vers runs on the closed loopback port"
run_wrap --url console.vast.ai show user --raw
status_is "$ST" 2 "a bare host without a scheme is refused too"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_URL=https://collector.example.test timeout 20 "$WRAP" show user --raw 2>&1)
ST=$?
status_is "$ST" 2 "non-loopback VAST_URL env refused"
contains "$OUT" "VAST_URL" "VAST_URL refusal names the variable"
equals "$(cat "$VENDOR_LOG")" "" "non-loopback VAST_URL never reaches the vendor"
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_URL=http://127.0.0.1:1 timeout 20 "$WRAP" show user --raw 2>&1)
contains "$OUT" "url_env:http://127.0.0.1:1" "loopback VAST_URL passes through to the vendor"

reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap update
status_is "$ST" 2 "update refused"
contains "$OUT" "uv pip install" "update prints the recreate command"
equals "$(cat "$VENDOR_LOG")" "" "update never reaches the vendor"

# destroy without -y: the vendor would print "Aborted." and exit 0 headless.
reset_home; configure_bws_files; make_bws_with_key "$BWS_KEY"
run_wrap destroy instance 123
status_is "$ST" 2 "destroy instance without -y refused"
contains "$OUT" "Aborted." "destroy refusal explains the vendor's silent abort"
contains "$OUT" "Pass -y" "destroy refusal says what to do"
equals "$(cat "$VENDOR_LOG")" "" "destroy without -y never reaches the vendor"
run_wrap --raw destroy instances 1 2 3
status_is "$ST" 2 "destroy instances without -y refused"
run_wrap destroy instance 123 -y
status_is "$ST" 0 "destroy instance -y passes"
contains "$OUT" "argv:--full --no-color destroy instance 123 -y" "destroy instance -y reaches the vendor with --full"
run_wrap --raw destroy instances 1 2 --yes
status_is "$ST" 0 "destroy instances --yes passes"
contains "$OUT" "argv:--raw destroy instances 1 2 --yes" "destroy instances --yes reaches the vendor verbatim"

# A malformed env key is refused rather than forwarded.
reset_home
run_wrap_env "not a key" show user
[ "$ST" -ne 0 ] && ok || bad "malformed env key: expected non-zero exit"
contains "$OUT" "not a plausible key" "malformed env key names the problem"
equals "$(cat "$VENDOR_LOG")" "" "malformed env key never reaches the vendor"

# ── exit status repair: vendor exit 0 after an API error becomes 1 ──────────
reset_home
run_wrap_stdout "$ENV_KEY" show instance 404
status_is "$ST" 1 "stderr 'Failed with error' + exit 0 becomes exit 1"
contains "$ERR" "Failed with error 404: Instance not found" "vendor stderr is relayed"
contains "$ERR" "exited 0; exiting 1" "wrapper says why the status changed"
equals "$OUT" "" "stdout stays clean on the error path"

reset_home
run_wrap_stdout "$ENV_KEY" --raw show instance 405
status_is "$ST" 1 "stderr --raw error object + exit 0 becomes exit 1"
contains "$ERR" '"status_code": 405' "the raw error object is relayed intact"

reset_home
run_wrap_stdout "$ENV_KEY" --raw show instance 7
status_is "$ST" 7 "a non-zero vendor status passes through unchanged"
contains "$ERR" "vendor failed" "vendor stderr relayed on non-zero exit"
omits "$ERR" "exiting 1" "no status rewrite on a non-zero vendor exit"

reset_home
run_wrap_stdout "$ENV_KEY" --raw show instance 200
status_is "$ST" 0 "a success body with an 'error' field is not an error"
contains "$OUT" '"id": 200' "stdout passes through on success"

# ── the per-instance credential in `create instance` output is redacted ──────
reset_home
run_wrap_stdout "$ENV_KEY" --raw create instance 111 --image img --disk 50 --ssh --direct --label job --cancel-unavail
status_is "$ST" 0 "create instance --raw exits 0"
contains "$OUT" '"new_contract": 55829021' "create instance --raw keeps the contract id"
contains "$OUT" '"instance_api_key": "[redacted by the vastai wrapper]"' "create instance --raw redacts instance_api_key"
omits "$OUT" "$INSTANCE_KEY" "the per-instance key never reaches stdout"
omits "$ERR" "$INSTANCE_KEY" "the per-instance key never reaches stderr"
run_wrap_stdout "$ENV_KEY" create instance 112 --image img --disk 50 --ssh
contains "$OUT" "'instance_api_key': '[redacted by the vastai wrapper]'" "non-raw create redacts the single-quoted dict"
contains "$OUT" "'new_contract': 55829022" "non-raw create keeps the contract id"
omits "$OUT" "$INSTANCE_KEY" "non-raw create never prints the per-instance key"
run_wrap_stdout "$ENV_KEY" --raw create instance 113 --image img
contains "$ERR" '"instance_api_key": "[redacted by the vastai wrapper]"' "a key the vendor writes to stderr is redacted too"
omits "$ERR" "$INSTANCE_KEY" "the per-instance key never reaches stderr from a stderr write"
contains "$OUT" '"ssh_key": "ssh-ed25519 AAAA agent"' "ssh public keys are not redacted"
contains "$OUT" '"api_key_hint": "x"' "only fields named *api_key are redacted"
run_wrap_stdout "$ENV_KEY" --raw show instances
status_is "$ST" 0 "show instances --raw exits 0"
contains "$OUT" '"jupyter_token": "[redacted by the vastai wrapper]"' "show instances redacts jupyter_token"
omits "$OUT" "0000000000000000000000000000000000000000" "the Jupyter password never reaches stdout"
contains "$OUT" '"ssh_host": "ssh3.vast.ai"' "the other instance fields pass through"

# ── plaintext key files draw a warning and are never read ───────────────────
reset_home
mkdir -p "$HOMEDIR/.config/vastai"
printf 'filekey-should-never-be-used\n' >"$HOMEDIR/.config/vastai/vast_api_key"
run_wrap_env "$ENV_KEY" show user --raw
status_is "$ST" 0 "key-file warning does not fail the command"
contains "$OUT" "plaintext vast.ai key file present" "key file draws a warning"
contains "$OUT" "$HOMEDIR/.config/vastai/vast_api_key" "key-file warning names the path"
contains "$OUT" "env_key:$ENV_KEY" "env key still wins over the file"
[ -f "$HOMEDIR/.config/vastai/vast_api_key" ] && ok || bad "wrapper must never delete the key file"
reset_home
run_wrap_env "$ENV_KEY" show user --raw
omits "$OUT" "plaintext vast.ai key file" "no warning without a key file"

# ── missing venv: exit 3 with recreate commands ──────────────────────────────
reset_home
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$TMP/no-such-venv" VAST_API_KEY="$ENV_KEY" timeout 20 "$WRAP" show user 2>&1)
ST=$?
status_is "$ST" 3 "missing venv is exit 3"
contains "$OUT" "venv missing at $TMP/no-such-venv" "missing venv names the path"
contains "$OUT" "uv venv $TMP/no-such-venv --python 3.12" "missing venv prints uv venv"
contains "$OUT" "uv pip install --python $TMP/no-such-venv/bin/python vastai==" "missing venv prints the pinned install"

# ── vast-ssh ─────────────────────────────────────────────────────────────────
run_vssh() {
  OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_API_KEY="$ENV_KEY" timeout 20 "$VSSH" "$@" 2>&1)
  ST=$?
}

reset_home
run_vssh 123 -- nvidia-smi -L
status_is "$ST" 7 "vast-ssh relays ssh's exit status"
contains "$OUT" "fake-ssh-ran" "vast-ssh execs ssh"
SSH_ARGS=$(tr '\n' ' ' <"$SSH_LOG")
contains "$SSH_ARGS" "-i $HOMEDIR/.ssh/vastai_ed25519 " "vast-ssh uses the agent key"
contains "$SSH_ARGS" "-o IdentitiesOnly=yes " "vast-ssh pins the identity"
contains "$SSH_ARGS" "-o BatchMode=yes " "vast-ssh never prompts"
contains "$SSH_ARGS" "-o StrictHostKeyChecking=accept-new " "vast-ssh trusts on first use"
contains "$SSH_ARGS" "-o UserKnownHostsFile=$HOMEDIR/.ssh/known_hosts.vastai/123 " "vast-ssh keeps a per-instance known_hosts"
contains "$SSH_ARGS" "-o ConnectTimeout=20 " "vast-ssh bounds the connect"
contains "$SSH_ARGS" "-o LogLevel=ERROR " "vast-ssh silences the banner and the known-hosts notice"
contains "$SSH_ARGS" "-p 40000 root@203.0.113.9 nvidia-smi -L" "vast-ssh parses user, host, port and passes the command"
[ -d "$HOMEDIR/.ssh/known_hosts.vastai" ] && ok || bad "vast-ssh creates the known_hosts dir"
equals "$(stat -c %a "$HOMEDIR/.ssh/known_hosts.vastai")" 700 "vast-ssh known_hosts dir is 0700"
contains "$(cat "$VENDOR_LOG")" "argv:--full --no-color ssh-url 123" "vast-ssh asks the wrapper for ssh-url"
contains "$(cat "$VENDOR_LOG")" "env_key:$ENV_KEY" "vast-ssh's ssh-url call carries the key in env"

reset_home
run_vssh 456
status_is "$ST" 7 "vast-ssh proxy host exit"
SSH_ARGS=$(tr '\n' ' ' <"$SSH_LOG")
contains "$SSH_ARGS" "-p 12345 root@ssh5.vast.ai " "vast-ssh handles the proxy host form with no command"

reset_home
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_API_KEY="$ENV_KEY" VAST_SSH_KEY="$TMP/other_key" timeout 20 "$VSSH" 123 2>&1)
SSH_ARGS=$(tr '\n' ' ' <"$SSH_LOG")
contains "$SSH_ARGS" "-i $TMP/other_key " "VAST_SSH_KEY overrides the key path"

reset_home
run_vssh 999
status_is "$ST" 3 "vast-ssh non-URL answer is exit 3"
contains "$OUT" "Instance 999 not found" "vast-ssh relays the vendor text"
[ -f "$SSH_LOG" ] && bad "vast-ssh ran ssh after a failed ssh-url" || ok

reset_home
OUT=$(HOME="$HOMEDIR" PATH="$BASE_PATH" VASTAI_VENV="$VENV" VAST_API_KEY="$ENV_KEY" timeout 20 "$VSSH" 998 2>"$TMP/ssh-stderr")
ST=$?
ERR=$(cat "$TMP/ssh-stderr")
status_is "$ST" 3 "vast-ssh exit-zero non-URL answer is exit 3"
equals "$OUT" "" "vast-ssh missing-URL diagnostic leaves stdout empty"
contains "$ERR" "vast-ssh: ssh-url did not return an ssh:// URL: error: ssh port not found" "vast-ssh relays exit-zero vendor text to stderr"
[ -f "$SSH_LOG" ] && bad "vast-ssh ran ssh after an exit-zero non-URL answer" || ok
[ -d "$HOMEDIR/.ssh/known_hosts.vastai" ] && bad "vast-ssh created known_hosts after an exit-zero non-URL answer" || ok

reset_home
run_vssh abc
status_is "$ST" 2 "vast-ssh non-numeric id is exit 2"
run_vssh
status_is "$ST" 2 "vast-ssh no args is exit 2"
contains "$OUT" "usage: vast-ssh" "vast-ssh prints usage"
run_vssh --help
status_is "$ST" 0 "vast-ssh --help exit 0"
contains "$OUT" "vast-ssh <instance-id>" "vast-ssh --help prints the header"
contains "$OUT" "otherwise ssh's own exit status" "vast-ssh --help prints the whole header"
omits "$OUT" "set -euo pipefail" "vast-ssh --help stops at the end of the comment header"
equals "$(cat "$VENDOR_LOG")" "" "vast-ssh --help calls nothing"

echo "vastai.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
