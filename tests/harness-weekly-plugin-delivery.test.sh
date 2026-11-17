#!/usr/bin/env bash
# Regression contract for the "plugin delivery" section of scripts/harness-weekly.sh.
#
# THE DEFECT: a fix merged under plugins/<name>/ without a VERSION bump reaches
# no install, because a card pins a commit and only a release moves it. The
# weekly report's only check covered papercut, and since #309 it answered
# UNKNOWN on a line with no WARN prefix, so the toast count never saw it (#645).
#
# EXTRACTION: sed the shipped section out of harness-weekly.sh and run it, as
# harness-weekly-papercut.test.sh does, so this exercises the shipped block. The
# section calls "$SCRIPTS/plugin-delivery-report.py", so pointing SCRIPTS at a
# scratch directory is the whole seam. Cases 1-6 put a stub there to drive each
# exit path; case 7 puts the real report in a real temporary repository and
# counts WARN lines the way harness-weekly's toast gate does.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/scripts/harness-weekly.sh
TMP=$(mktemp -d /tmp/hw-plugin-delivery-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
contains() {
  case "$1" in
    *"$2"*) ok ;;
    *) bad "$3: missing [$2]"$'\n'"$1" ;;
  esac
}
omits() {
  case "$1" in
    *"$2"*) bad "$3: unexpectedly contained [$2]"$'\n'"$1" ;;
    *) ok ;;
  esac
}
warn_count() { printf '%s\n' "$1" | grep -c '^WARN' || true; }
warns_are() {
  local n
  n=$(warn_count "$1")
  if [ "$n" -eq "$2" ]; then ok; else bad "$3 (counted $n)"$'\n'"$1"; fi
}

sed -n '/^  echo "## plugin delivery/,/^  echo "## papercuts rollup/p' "$SRC" \
  | sed '$d' > "$TMP/section.sh"
if [ ! -s "$TMP/section.sh" ]; then
  echo "FAIL: extraction produced nothing - did the section header change?" >&2
  exit 1
fi
grep -q 'plugin-delivery-report.py' "$TMP/section.sh" || {
  echo "FAIL: extracted section no longer runs plugin-delivery-report.py" >&2
  exit 1
}

stub_dir() {
  local dir=$TMP/$1
  mkdir -p "$dir"
  {
    echo 'import os, sys'
    echo 'sys.stdout.write(os.environ.get("PD_STDOUT", ""))'
    echo 'err = os.environ.get("PD_STDERR", "")'
    echo 'if err:'
    echo '    sys.stderr.write(err + "\n")'
    echo 'sys.exit(int(os.environ.get("PD_EXIT", "0")))'
  } > "$dir/plugin-delivery-report.py"
  echo "$dir"
}

run_section() {
  ( SCRIPTS="$1" PD_STDOUT="${PD_STDOUT:-}" PD_STDERR="${PD_STDERR:-}" PD_EXIT="${PD_EXIT:-0}" \
      bash "$TMP/section.sh" 2>&1 )
}

# 1. every card current: the section prints the report and no warning
d=$(stub_dir current)
out=$(PD_STDOUT=$'plugin delivery: 2 cards against origin/main (abc12345)\nplugin delivery: 2 current, 0 ahead of their pin, 0 could not be compared\n' \
      PD_EXIT=0 run_section "$d")
contains "$out" "2 current, 0 ahead" "a current state is reported"
warns_are "$out" 0 "a current state must print no WARN line"

# 2. a card ahead of its pin: its WARN line and file list reach the report
d=$(stub_dir ahead)
out=$(PD_STDOUT=$'WARN plugin delivery: alpha ships files that changed since its pin 3b1ee286 (merged, not released):\n  bin/run.sh\n' \
      PD_EXIT=1 run_section "$d")
contains "$out" "alpha ships files that changed since its pin" "an unreleased fix is surfaced"
contains "$out" "  bin/run.sh" "the shipped file is named"
omits "$out" "did not finish" "exit 1 is the report's own answer, not a crash"
warns_are "$out" 1 "an ahead card is exactly one WARN line"

# 3. a card that cannot be compared stays a WARN, never a clean bill of health
d=$(stub_dir unknown)
out=$(PD_STDOUT=$'WARN plugin delivery: UNKNOWN for alpha: the pin 00000000 is not in this checkout\n' \
      PD_EXIT=2 run_section "$d")
contains "$out" "UNKNOWN for alpha" "an uncomparable card is reported"
omits "$out" "did not finish" "exit 2 is the report's own answer, not a crash"
warns_are "$out" 1 "an uncomparable card is exactly one WARN line"

# 4. a crash's traceback reaches the report under its own WARN label
d=$(stub_dir crash)
out=$(PD_STDERR="Traceback (most recent call last): KeyError: 'plugins'" PD_EXIT=1 run_section "$d")
contains "$out" "WARN plugin delivery diagnostics" "stderr is labelled WARN"
contains "$out" "KeyError: 'plugins'" "the traceback text itself is shown"

# 5. a missing report is a WARN, not silence
mkdir -p "$TMP/empty"
out=$(run_section "$TMP/empty")
contains "$out" "WARN plugin delivery diagnostics" "a missing script is surfaced"
contains "$out" "plugin-delivery-report.py" "the diagnostic names the missing file"

# 6. a killed or timed-out run says it did not finish
d=$(stub_dir killed)
out=$(PD_EXIT=137 run_section "$d")
contains "$out" "WARN plugin delivery report did not finish (exit 137)" "an exit above 2 is named"

# 7. end to end: the real report in a real repository, one card behind its pin
r=$TMP/repo
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main "$r"
git -C "$r" remote add origin https://github.com/acme/stack.git
mkdir -p "$r/plugins/alpha/bin" "$r/plugins/beta" "$r/scripts" "$r/.claude-plugin"
echo 'echo 1' > "$r/plugins/alpha/bin/run.sh"
echo 'x' > "$r/plugins/beta/VERSION"
git -C "$r" add -A
git -C "$r" commit -q -m 'feat: alpha and beta'
pin=$(git -C "$r" rev-parse HEAD)
echo 'echo 2' > "$r/plugins/alpha/bin/run.sh"
git -C "$r" commit -q -am 'fix(alpha): echo 2'
printf '{"plugins":[%s,%s]}\n' \
  "{\"name\":\"alpha\",\"source\":{\"source\":\"git-subdir\",\"url\":\"https://github.com/acme/stack.git\",\"path\":\"plugins/alpha\",\"sha\":\"$pin\"}}" \
  "{\"name\":\"beta\",\"source\":{\"source\":\"git-subdir\",\"url\":\"https://github.com/acme/stack.git\",\"path\":\"plugins/beta\",\"sha\":\"$pin\"}}" \
  > "$r/.claude-plugin/marketplace.json"
cp "$REPO/scripts/plugin-delivery-report.py" "$r/scripts/"
git -C "$r" add -A
git -C "$r" commit -q -m 'chore: cards and report'
out=$(run_section "$r/scripts")
contains "$out" "WARN plugin delivery: alpha ships files that changed since its pin ${pin:0:8}" "the real report names the card"
contains "$out" "1 current, 1 ahead of their pin, 0 could not be compared" "the real report counts both cards"
omits "$out" "diagnostics" "the real report writes nothing to stderr"
warns_are "$out" 1 "the toast gate counts exactly the one ahead card"

echo "harness-weekly plugin delivery section: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
