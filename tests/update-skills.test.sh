#!/usr/bin/env bash
# scripts/update-skills.sh takes no arguments. It used to ignore them and start a real
# `npx skills@latest update -g`, so an agent probing it with --help updated every globally
# installed skill. Hermetic: HOME and PATH point at a stub mise that records its argv.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$HERE/scripts/update-skills.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/update-skills-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

mkdir -p "$TMP/home/.local/bin"
cat >"$TMP/home/.local/bin/mise" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/mise-calls"
EOF
chmod +x "$TMP/home/.local/bin/mise"
run() { HOME="$TMP/home" PATH="/usr/bin:/bin" bash "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err"; }

# 1. Any argument is refused before anything runs: exit 2, usage on stderr, no update.
for arg in --help -h --dry-run; do
  : > "$TMP/mise-calls"
  run "$arg"; rc=$?
  [ "$rc" = 2 ] && ok || bad "update-skills.sh $arg exited $rc (want 2)"
  grep -qF 'usage: update-skills.sh' "$TMP/err" && ok || bad "update-skills.sh $arg printed no usage: $(cat "$TMP/err")"
  [ ! -s "$TMP/mise-calls" ] && ok || bad "update-skills.sh $arg started an update: $(cat "$TMP/mise-calls")"
done

# 2. With no arguments it still runs the update, through mise.
: > "$TMP/mise-calls"
run; rc=$?
[ "$rc" = 0 ] && ok || bad "update-skills.sh with no arguments exited $rc :: $(cat "$TMP/err")"
[ "$(cat "$TMP/mise-calls")" = 'exec -- npx -y skills@latest update -g' ] && ok \
  || bad "update-skills.sh with no arguments did not run the update: $(cat "$TMP/mise-calls")"

if [ "$fail" -eq 0 ]; then
  echo "ok — update-skills: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — update-skills: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
