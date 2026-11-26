#!/usr/bin/env bash
# merge-freeze.sh on its own: hold, show, release and check, each under a scratch freeze folder.
# pr-land.test.sh covers how pr-land.sh acts on what `check` says. No network, no gh.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MF="$ROOT/scripts/merge-freeze.sh"
TMP=$(mktemp -d /tmp/merge-freeze-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
check() { local name=$1; shift; if "$@"; then ok; else bad "$name"; fi; }
has() { [[ "$1" == *"$2"* ]]; }
[ -f "$MF" ] || { echo "missing $MF" >&2; exit 1; }

export MERGE_FREEZE_DIR="$TMP/freeze"
R=Acme-Org/Widgets
F="$MERGE_FREEZE_DIR/acme-org_widgets.json"
as() { local who=$1; shift; OUT=$(cd "$TMP" && CLAUDE_CODE_SESSION_ID=$who bash "$MF" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
reset() { rm -rf "$MERGE_FREEZE_DIR"; }

# --- hold
reset; as sess-a hold --repo "$R" --minutes 30 --reason 'deploying the router' --allow-pr 12 --allow-pr 9
check "hold: exit 0 (got $RC; $ERR)" test "$RC" -eq 0
check 'hold: one file per repository, name lower-cased' test -f "$F"
check 'hold: records the holder' test "$(jq -r .holder "$F")" = sess-a
check 'hold: records the session' test "$(jq -r .session "$F")" = sess-a
check 'hold: records the reason' test "$(jq -r .reason "$F")" = 'deploying the router'
check 'hold: allowed PRs sorted, numbers' test "$(jq -c .allow_prs "$F")" = '[9,12]'
check 'hold: ends 30 minutes after it starts' test "$(jq '.until - .since' "$F")" = 1800
check 'hold: prints the freeze' has "$OUT" 'acme-org/widgets frozen until'
check 'hold: names the PRs that may merge' has "$OUT" '#9, #12'
reset; git init -q -b release-cut "$TMP/repo" && git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
OUT=$(cd "$TMP/repo" && CLAUDE_CODE_SESSION_ID=sess-a bash "$MF" hold --repo "$R" --minutes 5 --reason r 2>&1)
check 'hold in a checkout: records its branch' test "$(jq -r .branch "$F")" = release-cut
check 'hold in a checkout: prints the branch' has "$OUT" 'by sess-a (branch release-cut): r'
reset; as sess-a hold --repo "$R" --minutes 5 --reason $'two\nlines'
check 'hold: a reason stays one line' test "$(jq -r .reason "$F")" = 'two lines'
reset; (cd "$TMP" && env -u CLAUDE_CODE_SESSION_ID USER=ops bash "$MF" hold --repo "$R" --minutes 5 --reason r >/dev/null 2>&1)
check 'hold: outside Claude Code the holder is shell:$USER' test "$(jq -r .holder "$F")" = shell:ops
check 'hold: outside Claude Code no session is recorded' test "$(jq -r .session "$F")" = null

# Another holder's active freeze is refused; the holder may extend its own; an ended one is replaced.
reset; as sess-a hold --repo "$R" --minutes 30 --reason first
as sess-b hold --repo "$R" --minutes 30 --reason second
check 'hold over another active freeze: exit 1' test "$RC" -eq 1
check 'hold over another active freeze: names the holder' has "$ERR" 'by sess-a'
check 'hold over another active freeze: file unchanged' test "$(jq -r .reason "$F")" = first
as sess-a hold --repo "$R" --minutes 60 --reason extended
check 'the holder extends its own freeze' test "$RC" -eq 0
check 'extended: new end and reason' test "$(jq -r '"\(.reason) \(.until - .since)"' "$F")" = 'extended 3600'
jq '.until = (now | floor) - 1' "$F" >"$TMP/f.json" && mv "$TMP/f.json" "$F"
as sess-b hold --repo "$R" --minutes 10 --reason after
check 'hold over an ended freeze: exit 0' test "$RC" -eq 0
check 'hold over an ended freeze: the new holder has it' test "$(jq -r .holder "$F")" = sess-b

# --- check
reset
as sess-b check --repo "$R"
check 'check, no freeze: exit 0' test "$RC" -eq 0
as sess-a hold --repo "$R" --minutes 30 --reason 'deploying the router' --allow-pr 5
as sess-b check --repo ACME-ORG/WIDGETS --pr 6
check 'check, frozen: exit 1 (any case of the repo name)' test "$RC" -eq 1
check 'check, frozen: names the holder' has "$OUT" 'by sess-a'
check 'check, frozen: names the reason' has "$OUT" 'deploying the router'
as sess-b check --repo "$R" --pr 5
check 'check, an allowed PR: exit 0' test "$RC" -eq 0
as sess-b check --repo "$R"
check 'check, no PR given: held' test "$RC" -eq 1
as sess-a check --repo "$R"
check "check, the holder's own run: exit 0" test "$RC" -eq 0
as sess-b check --repo acme-org/widgets-extra
check 'check, another repository: exit 0' test "$RC" -eq 0
jq '.until = (now | floor) - 1' "$F" >"$TMP/f.json" && mv "$TMP/f.json" "$F"
as sess-b check --repo "$R"
check 'check, an ended freeze: exit 0' test "$RC" -eq 0
check 'check, an ended freeze: says it ignored it' has "$ERR" 'ignoring the freeze'
echo '{"repo": "acme-org/widgets"}' >"$F"
as sess-b check --repo "$R"
check 'check, a file missing fields: exit 2' test "$RC" -eq 2
check 'check, a bad file: names it' has "$OUT" "$F"
echo 'not json' >"$F"
as sess-b check --repo "$R"
check 'check, a file that is not JSON: exit 2' test "$RC" -eq 2

# --- release
reset; as sess-a hold --repo "$R" --minutes 30 --reason r
as sess-b release --repo "$R"
check "release of another's active freeze: exit 1" test "$RC" -eq 1
check "release of another's active freeze: kept" test -f "$F"
as sess-b release --repo "$R" --force
check 'release --force: exit 0' test "$RC" -eq 0
check 'release --force: removed' test ! -e "$F"
as sess-a hold --repo "$R" --minutes 30 --reason r
as sess-a release --repo "$R"
check 'the holder releases its own: removed' test ! -e "$F"
as sess-a release --repo "$R"
check 'release with nothing held: exit 0' test "$RC" -eq 0
mkdir -p "$MERGE_FREEZE_DIR"; echo 'not json' >"$F"
as sess-a release --repo "$R"
check 'release of a bad file without --force: exit 1' test "$RC" -eq 1
as sess-a hold --repo "$R" --minutes 5 --reason r
check 'hold over a bad file without --force: exit 1' test "$RC" -eq 1
as sess-a release --repo "$R" --force
check 'release --force clears a bad file' test ! -e "$F"

# --- show
reset; as sess-a show
check 'show, nothing held' has "$OUT" 'no merge freezes'
as sess-a hold --repo "$R" --minutes 30 --reason r
as sess-a hold --repo other-org/gadgets --minutes 30 --reason s
jq '.until = (now | floor) - 1' "$MERGE_FREEZE_DIR/other-org_gadgets.json" >"$TMP/f.json" \
  && mv "$TMP/f.json" "$MERGE_FREEZE_DIR/other-org_gadgets.json"
as sess-a show
check 'show: lists the active freeze' has "$OUT" 'acme-org/widgets frozen until'
check 'show: marks the ended one' has "$OUT" '(ended) other-org/gadgets'
as sess-a show --json
check 'show --json: one object per freeze, active flagged' \
  test "$(jq -c 'map({repo, active}) | sort_by(.repo)' <<<"$OUT")" = '[{"repo":"acme-org/widgets","active":true},{"repo":"other-org/gadgets","active":false}]'
as sess-a show --repo "$R" --json
check 'show --repo: only that repository' test "$(jq length <<<"$OUT")" = 1
SHOWN=$OUT
as sess-a status --repo "$R" --json
check 'status is show: exit 0 and the same listing' test "$RC" -eq 0 -a "$OUT" = "$SHOWN"
as sess-a status
check 'status with no options: lists the active freeze' has "$OUT" 'acme-org/widgets frozen until'

# --- usage
for args in 'hold --repo a/b --reason r' 'hold --repo a/b --minutes 0 --reason r' \
            'hold --repo a/b --minutes 1441 --reason r' 'hold --repo a/b --minutes 5' \
            'check' 'check --repo nope' 'check --repo a/b --pr x' 'freeze --repo a/b' ''; do
  read -r -a argv <<<"$args"
  as sess-a "${argv[@]}"
  check "usage error: '$args' exits 64 (got $RC)" test "$RC" -eq 64
done

printf 'merge-freeze: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
