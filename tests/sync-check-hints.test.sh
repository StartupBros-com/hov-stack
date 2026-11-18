#!/usr/bin/env bash
# sync.sh check's DRIFT hints name the fix for both directions.
#
# Each differing copy can be wrong on either side, so the hint must name the
# step that takes the repo's copy as well as `sync.sh push`, which records the
# live one in this public repo. A push-only hint once pointed at a live
# claude-env.sh that held a hand-run codex hook's session exports. The hints
# must also not name `sync.sh install`, which #720 removed.
#
# Runs the real `sync.sh check` against a fake HOME with one drifted item per
# kind, and asserts on its actual output.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# line_for <fixed-string> -> the one DRIFT line containing it
line_for() { grep -F -- "$1" "$TMP/out" | grep '^DRIFT' | head -n 1; }
has()  { case "$2" in *"$3"*) ok ;; *) bad "$1: wanted '$3' in: ${2:-<no such DRIFT line>}" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: did not want '$3' in: $2" ;; *) ok ;; esac; }

home=$TMP/home cfg=$TMP/home/.claude sys=$TMP/home/.config/systemd/user etc=$TMP/etc
mkdir -p "$cfg" "$sys" "$etc" "$TMP/elsewhere" "$TMP/stub"

# A stub systemctl keeps the undeclared-unit check off the real user bus.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/systemctl"
chmod +x "$TMP/stub/systemctl"

# A real directory that differs (not linked, so ./setup or push).
cp -R "$REPO/hooks" "$cfg/hooks"
echo x > "$cfg/hooks/live-only-file"
# A directory linked somewhere else.
mkdir -p "$TMP/elsewhere/bin"
ln -s "$TMP/elsewhere/bin" "$cfg/bin"
# A linked file left as a real file that differs: the claude-env.sh case.
cp "$REPO/claude-env.sh" "$cfg/claude-env.sh"
echo "export CODEX_COMPANION_SESSION_ID='probe-fixture'" >> "$cfg/claude-env.sh"
# A linked file pointing somewhere else and differing: push skips links.
echo "# not the repo's" > "$TMP/elsewhere/CLAUDE.md"
ln -s "$TMP/elsewhere/CLAUDE.md" "$cfg/CLAUDE.md"
# A copied file that differs, which no setup step copies back.
echo '{"bindings": []}' > "$cfg/keybindings.json"
# A user unit and a system unit that differ.
printf '[Unit]\nDescription=live edit\n' > "$sys/backup-harness.timer"
printf '[Unit]\nDescription=live edit\n' > "$etc/zram-swap.service"

HOME=$home CLAUDE_SYNC_SYSTEM_SYS_DIR=$etc PATH="$TMP/stub:$PATH" \
  bash "$REPO/sync.sh" check > "$TMP/out" 2>&1 </dev/null
rc=$?
[ "$rc" -ne 0 ] && ok || bad "check exits nonzero on drift (got $rc)"

l=$(line_for 'hooks/ differs from repo')
has  "differing dir" "$l" "./setup links the repo's copy"
has  "differing dir" "$l" "sync.sh push"

l=$(line_for '~/.claude/bin is a symlink pointing outside the repo')
has  "dir linked elsewhere" "$l" "(./setup relinks it)"

l=$(line_for 'claude-env.sh differs from repo copy')
has  "unlinked claude-env.sh" "$l" "./setup links the repo's copy"
has  "unlinked claude-env.sh" "$l" "sync.sh push to record an intended live edit"

l=$(line_for '~/.claude/CLAUDE.md links outside the repo')
has  "CLAUDE.md linked elsewhere" "$l" "(./setup relinks it)"
lacks "CLAUDE.md linked elsewhere" "$l" "sync.sh push"

l=$(line_for 'keybindings.json differs from repo copy')
has  "copied keybindings.json" "$l" "cp $REPO/keybindings.json $cfg/keybindings.json takes the repo's"
has  "copied keybindings.json" "$l" "sync.sh push"

l=$(line_for 'systemd/backup-harness.timer differs')
has  "user unit" "$l" "./setup --enable-units installs the repo's copy"
has  "user unit" "$l" "sync.sh push"

l=$(line_for 'systemd-system/zram-swap.service differs')
has  "system unit" "$l" "./setup --root installs the repo's copy"
has  "system unit" "$l" "sync.sh push"

# No hint names the removed command, and no "differs" hint is push-only.
drift=$(grep '^DRIFT' "$TMP/out")
lacks "removed install command" "$drift" "sync.sh push or install"
lacks "removed install command" "$drift" "sync.sh install"
lacks "push-only hint" "$drift" "differs (sync.sh push)"
lacks "push-only hint" "$drift" "differs from repo copy (sync.sh push)"

if [ "$fail" -ne 0 ]; then
  echo "--- sync.sh check output" >&2
  grep '^DRIFT' "$TMP/out" | cut -c1-300 >&2
  echo "FAILED: $fail of $((pass + fail)) checks" >&2
  exit 1
fi
echo "all $pass checks passed"
