#!/usr/bin/env bash
# lib/overlay.sh, and the scheduled script that reads a host value through it.
#
# A systemd unit runs without <overlay>/env in its environment, and `sync.sh install`
# copies the shipped unit files over the live ones, so a value edited into a unit does not
# last. update-mcp-servers.sh is the first scheduled script that needs a host value: the
# GitHub origin its checkout must match. Before lib/overlay.sh it read only an exported
# EXPECTED_ORIGIN, which no shipped unit sets, so the weekly run exited 2 on every host.
#
# Each case runs the real functions or the real updater. The updater's git, uv and rm are
# stubs, so nothing touches the network or a real checkout.
#
# shellcheck disable=SC2016 # the single-quoted strings are code for the inner shell
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=$REPO/lib/overlay.sh
MCP_SCRIPT=$REPO/scripts/update-mcp-servers.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
is_eq() { if [ "$1" = "$2" ]; then ok; else bad "$3 (got '$1', want '$2')"; fi; }

# in_shell VARS... -- CODE: run CODE in a clean bash that sourced the library, with only
# HOME, PATH and the named assignments in its environment.
in_shell() {
  local -a vars=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  env -i HOME="$TMP/home" PATH=/usr/bin:/bin "${vars[@]}" \
    bash -c '. "$1"; shift; eval "$1"' _ "$LIB" "$1"
}
mkdir -p "$TMP/home/.config/hov-stack"

# -- overlay_dir: the resolution setup and claude-env.sh use ----------------------------
is_eq "$(in_shell -- 'overlay_dir')" "$TMP/home/.config/hov-stack" \
  "overlay_dir: with nothing set, the overlay is ~/.config/hov-stack"
is_eq "$(in_shell XDG_CONFIG_HOME=/x/cfg -- 'overlay_dir')" /x/cfg/hov-stack \
  "overlay_dir: an absolute XDG_CONFIG_HOME holds the overlay"
is_eq "$(in_shell XDG_CONFIG_HOME=rel/cfg -- 'overlay_dir')" "$TMP/home/.config/hov-stack" \
  "overlay_dir: a relative XDG_CONFIG_HOME is ignored, as the XDG spec says"
is_eq "$(in_shell XDG_CONFIG_HOME=/x/cfg HOV_STACK_OVERLAY=/y/ov -- 'overlay_dir')" /y/ov \
  "overlay_dir: HOV_STACK_OVERLAY wins over XDG_CONFIG_HOME"
is_eq "$(in_shell HOV_STACK_OVERLAY=rel/ov -- 'overlay_dir; echo "rc=$?"')" "rc=1" \
  "overlay_dir: a relative HOV_STACK_OVERLAY prints nothing and returns 1"

# -- overlay_env_get --------------------------------------------------------------------
OV=$TMP/ov
mkdir -p "$OV"
cat > "$OV/env" <<'EOF'
HOV_MCP_EXPECTED_ORIGIN=acme-org/admin-tool
SPACED="a value with  two spaces"
STATE_DIR=$HOME/.local/state/tool
OTHER=from-the-file
echo noise on stdout
echo noise on stderr >&2
EOF
get() { in_shell HOV_STACK_OVERLAY="$OV" "$@"; }

is_eq "$(get -- 'overlay_env_get HOV_MCP_EXPECTED_ORIGIN')" acme-org/admin-tool \
  "overlay_env_get: reads a plain value, and the file's output stays out of the answer"
is_eq "$(get -- 'overlay_env_get SPACED')" "a value with  two spaces" \
  "overlay_env_get: a quoted value keeps its spaces"
is_eq "$(get -- 'overlay_env_get STATE_DIR')" "$TMP/home/.local/state/tool" \
  "overlay_env_get: \$HOME expands, as when claude-env.sh sources the file"
is_eq "$(get -- 'printf "[%s]" "$(overlay_env_get NOT_IN_FILE)"; echo " rc=$?"')" "[] rc=0" \
  "overlay_env_get: a name the file does not set prints nothing and returns 0"
is_eq "$(get OTHER=caller -- 'overlay_env_get HOV_MCP_EXPECTED_ORIGIN >/dev/null; echo "$OTHER"')" caller \
  "overlay_env_get: nothing else the file sets reaches the caller"
is_eq "$(get NOT_IN_FILE=ambient -- 'overlay_env_get NOT_IN_FILE')" "" \
  "overlay_env_get: an inherited value never answers for the file"
for name in '' 9LIVES 'BAD-NAME' 'A B' 'X;id'; do
  is_eq "$(get -- "overlay_env_get '$name' >/dev/null; echo \"rc=\$?\"")" "rc=2" \
    "overlay_env_get: '$name' is not a variable name and returns 2"
done
is_eq "$(in_shell HOV_STACK_OVERLAY="$TMP/absent" -- 'printf "[%s]" "$(overlay_env_get OTHER)"; echo " rc=$?"')" "[] rc=0" \
  "overlay_env_get: a missing overlay prints nothing and returns 0"
is_eq "$(in_shell HOV_STACK_OVERLAY=rel/ov -- 'printf "[%s]" "$(overlay_env_get OTHER)"; echo " rc=$?"')" "[] rc=0" \
  "overlay_env_get: a relative overlay is never read"

BROKEN=$TMP/broken
mkdir -p "$BROKEN"
printf '%s\n' 'EARLY=kept' 'read -r line' 'false' 'LATE=also-kept' 'exit 7' 'NEVER=reached' > "$BROKEN/env"
out=$(in_shell HOV_STACK_OVERLAY="$BROKEN" -- 'set -euo pipefail
  a=$(overlay_env_get EARLY); b=$(overlay_env_get LATE); c=$(overlay_env_get NEVER)
  echo "$a|$b|$c|survived"')
# With exit 7 in the file, the subshell ends before it prints, so every read is empty;
# the point is that the caller, under set -e, carries on, and that `read` did not hang.
is_eq "$out" "|||survived" "overlay_env_get: a file that exits ends only the reader's subshell"
printf '%s\n' 'EARLY=kept' 'read -r line' 'false' 'LATE=also-kept' > "$BROKEN/env"
is_eq "$(in_shell HOV_STACK_OVERLAY="$BROKEN" -- 'set -euo pipefail; overlay_env_get LATE')" also-kept \
  "overlay_env_get: a failing command in the file does not stop the lines after it"

# -- update-mcp-servers.sh: where the origin comes from ---------------------------------
STUBS=$TMP/stubs
mkdir -p "$STUBS"
cat > "$STUBS/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${MCP_CALLS:?}"
case " $* " in
  *' remote get-url origin '*) printf 'git@github.com:acme-org/admin-tool.git\n' ;;
  *' rev-parse '*) printf 'origin/main\n' ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/ok"
chmod +x "$STUBS/git" "$STUBS/ok"

# run_mcp OVERLAY [VAR=value...]: run the updater with only HOME, the stubs and the named
# assignments; sets rc, out and calls.
run_mcp() {
  local overlay=$1 home=$TMP/mcp-home
  shift
  mkdir -p "$home/SITES/mcp" "$home/.npm/_npx"
  : > "$TMP/mcp-calls"
  rc=0
  env -i HOME="$home" PATH=/usr/bin:/bin HOV_STACK_OVERLAY="$overlay" MCP_CALLS="$TMP/mcp-calls" \
    MCP_TARGET="$home/SITES/mcp" GIT_BIN="$STUBS/git" UV_BIN="$STUBS/ok" RM_BIN="$STUBS/ok" "$@" \
    bash "$MCP_SCRIPT" > "$TMP/mcp-out" 2>&1 || rc=$?
  out=$(cat "$TMP/mcp-out")
  calls=$(cat "$TMP/mcp-calls")
}
mk_overlay() { mkdir -p "$TMP/$1"; printf 'HOV_MCP_EXPECTED_ORIGIN=%s\n' "$2" > "$TMP/$1/env"; }
mk_overlay ov-match acme-org/admin-tool
mk_overlay ov-other acme-org/other-tool
mkdir -p "$TMP/ov-empty"

run_mcp "$TMP/ov-match"
is_eq "$rc" 0 "updater: the overlay's origin is used when nothing is exported ($out)"
case $calls in *'merge --ff-only --no-autostash origin/main'*) ok ;; *) bad "updater: the overlay origin did not reach the fast-forward: $calls" ;; esac

# Planted negative: an overlay origin that differs from the checkout's must be refused,
# which proves the overlay value is the one compared, not a default.
run_mcp "$TMP/ov-other"
is_eq "$rc" 1 "updater: an overlay origin that does not match the checkout is refused"
case $out in *'MCP target origin is not approved'*) ok ;; *) bad "updater: the mismatch was not named: $out" ;; esac
case $calls in *fetch*) bad "updater: fetched from an unapproved origin: $calls" ;; *) ok ;; esac

run_mcp "$TMP/ov-other" EXPECTED_ORIGIN=acme-org/admin-tool
is_eq "$rc" 0 "updater: an exported EXPECTED_ORIGIN wins over the overlay ($out)"

run_mcp "$TMP/ov-match" EXPECTED_ORIGIN=acme-org/other-tool
is_eq "$rc" 1 "updater: an exported EXPECTED_ORIGIN is compared even when the overlay would match"

for overlay in "$TMP/ov-empty" "$TMP/absent" relative/overlay; do
  run_mcp "$overlay"
  is_eq "$rc" 2 "updater: no origin anywhere ($overlay) exits 2"
  case $out in *'EXPECTED_ORIGIN is not set'*HOV_MCP_EXPECTED_ORIGIN*) ok ;; *) bad "updater: the refusal does not name both places: $out" ;; esac
  is_eq "$calls" "" "updater: no origin anywhere ($overlay) never runs git"
done

# claude-env.sh exports the overlay's env to every session command, so the overlay name is
# namespaced and only the file answers for it: an ambient copy without the file is not an
# approval.
run_mcp "$TMP/ov-empty" HOV_MCP_EXPECTED_ORIGIN=acme-org/admin-tool
is_eq "$rc" 2 "updater: an exported HOV_MCP_EXPECTED_ORIGIN without the overlay file is not read"

if [ "$fail" -eq 0 ]; then
  echo "ok — overlay env: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — overlay env: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
