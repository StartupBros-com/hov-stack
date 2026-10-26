#!/usr/bin/env bash
# tests/public-safety-scan.test.sh: scripts/public-safety-scan.sh fails on a planted private
# path, address, host, repository or token, in a file or in its name, passes the
# placeholder and reserved forms,
# lists the excluded suites without excusing their sources, honours the allowlist, scans a
# revision, fails closed when git grep fails or the required token list is missing, and
# proves against the real tree that the real allowlist's token rows are load-bearing
# (restructure plan U18, issue #31). Every planted string is assembled from two pieces so
# this suite's own source passes the scan it tests.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCAN=$ROOT/scripts/public-safety-scan.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/public-safety-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok: $*"; }

REPO=$WORK/repo
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main "$REPO"
g() { git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
mkdir -p "$REPO/docs/decisions" "$REPO/tests" "$REPO/src"
printf '%s\n' 'acme/public-thing' > "$REPO/.public-safety-repos"
: > "$REPO/.public-safety-allow"

LINUX='/ho''me/planted'
PROJECT='-ho''me-planted'
MAC='/Us''ers/planted'
WIN='C:\Us''ers\planted'
EMAIL='planted@priv''ate-corp.com'
HOST='box.corp.ts''.net'
MDNS='server.lo''cal'
PRIVREPO='acme/sec''ret-thing'

OUT=""; RC=0
run() { # run [args...]: the scan on $REPO with no token list; sets OUT and RC
  OUT=$(env -u HOV_STACK_PRIVATE_TOKENS HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" "$@" 2>&1); RC=$?
}
has() { grep -qE -- "$1" <<<"$OUT" || fail "$2 (no line matches /$1/)"; }
lacks() { if grep -qE -- "$1" <<<"$OUT"; then fail "$2 (a line matches /$1/)"; fi; }
drop() { rm -f "$@"; g add -A; }

echo "== 1: placeholders, reserved domains, a listed repository, a systemd instance, a variable suffix, a dotted file name and an attribute pass =="
cat > "$REPO/src/ok.txt" <<'EOF'
/home/user/.claude and /home/runner/work and /home/NAME and /Users/Shared and /Users/someone-else
C:\Users\<name>\AppData and /mnt/c/Users/user/x and %USERPROFILE%\.claude
author@example.com, ci@fixture.test, git@github.com, unit@1000.service, cron@backup.timer
acme/public-thing and acme/public-thing.git and https://github.com/acme/public-thing/pull/1 and other-org/anything
"$edges.internal" and config.local.json and self.local_remaining
~/SITES/demo and $HOME/.claude/settings.json and projects/-home-user/memory
EOF
g add -A; run
[ "$RC" -eq 0 ] || fail "a clean tree exits $RC: $OUT"
has '^result: PASS \(0 hits outside the allowlist\)' "the pass line"
has '^private-token list: not configured' "the token layer reports itself absent"
ok "a clean tree passes and says the token list is not configured"

echo "== 2: each planted home-path form fails naming path:line and shape, redacted; the ~-relative line passes =="
printf '%s\n' "$LINUX/.claude" > "$REPO/src/linux.txt"
printf '%s\n' "projects/$PROJECT/memory" > "$REPO/src/project.txt"
printf '%s\n' "$MAC/Library" > "$REPO/src/mac.txt"
printf '%s\n' "$WIN\\AppData" > "$REPO/src/win.txt"
cat > "$REPO/src/tilde.txt" <<'EOF'
~/.claude/settings.json and $HOME/.claude
EOF
g add -A; run
[ "$RC" -eq 1 ] || fail "planted paths exit $RC, want 1"
has '^  src/linux\.txt:1  linux-home  \[redacted, 13 chars\]$' "the Linux hit, redacted"
has '^  src/project\.txt:1  linux-home  \[redacted' "the project-directory hit"
has '^  src/mac\.txt:1  macos-home  \[redacted' "the macOS hit"
has '^  src/win\.txt:1  windows-home  \[redacted' "the Windows hit"
lacks 'src/tilde\.txt' "the ~-relative line"
lacks 'planted' "the matched text without --show"
has '^result: FAIL \(4 hits in 4 files\)$' "the fail line"
run --show
has "^  src/linux\\.txt:1  linux-home  $LINUX\$" "--show prints the matched text"
ok "four planted home paths fail with path:line and shape; the ~-relative line passes"

echo "== 3: a regex-escaped path and more than ten hits in one shape =="
# The file holds the single-escaped form a JS or Python regex literal carries (each slash preceded by a backslash).
printf 're = /\\/ho%sme\\/planted\\//\n' '' > "$REPO/src/escaped.js"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "$LINUX/n$i"; done > "$REPO/src/many.txt"
g add -A; run
has '^  src/escaped\.js:1  linux-home' "the escaped path"
has '^  \.\.\. and [0-9]+ more linux-home hits \(--all lists them\)$' "the per-shape cap"
lacks '^  src/many\.txt:12 ' "the twelfth hit under the cap"
run --all
has '^  src/many\.txt:12  linux-home' "--all lists past the cap"
lacks 'more linux-home hits' "the cap line under --all"
drop "$REPO"/src/linux.txt "$REPO"/src/project.txt "$REPO"/src/mac.txt "$REPO"/src/win.txt "$REPO"/src/tilde.txt "$REPO"/src/escaped.js "$REPO"/src/many.txt
ok "an escaped path is a hit; --all lists past the ten-per-shape cap"

echo "== 4: an address, a tailnet host, an mDNS host and an unlisted repository under a watched owner fail =="
printf '%s\n' "mail $EMAIL" > "$REPO/src/email.txt"
printf '%s\n' "ssh $HOST" > "$REPO/src/host.txt"
printf '%s\n' "ping $MDNS" > "$REPO/src/mdns.txt"
printf '%s\n' "see $PRIVREPO and git@github.com:$PRIVREPO.git" > "$REPO/src/repo.txt"
printf '%s\n' "ORIGIN=\"\${ORIGIN:-$PRIVREPO}\"" > "$REPO/src/default.sh"
printf '%s\n' "see word-$PRIVREPO" > "$REPO/src/hyphen.txt"
g add -A; run
[ "$RC" -eq 1 ] || fail "planted address, host and repository exit $RC, want 1"
has '^  src/email\.txt:1  email' "the address"
has '^  src/host\.txt:1  private-host' "the host"
has '^  src/mdns\.txt:1  private-host' "the mDNS host (issue #31 names .local; config.local.json in section 1 is a file name)"
has '^  src/repo\.txt:1  private-repo' "the repository"
has '^  src/default\.sh:1  private-repo' "a shell parameter default: the hyphen of :- is an operator, not a word"
has '^result: FAIL \(6 hits in 5 files\)$' "two repository matches on one line count twice; the hyphenated word adds none"
if grep -qE 'src/hyphen\.txt' <<<"$OUT"; then fail "a hyphenated word ending in a watched owner is not a repository mention"; fi
drop "$REPO"/src/email.txt "$REPO"/src/host.txt "$REPO"/src/mdns.txt "$REPO"/src/repo.txt "$REPO"/src/default.sh "$REPO"/src/hyphen.txt
ok "an address, two hosts, an unlisted repository and a shell default naming one fail; a hyphenated word passes"

echo "== 5: the token list fails a planted token from the environment or the overlay; --require-tokens fails closed without one =="
printf '%s\n' 'the planted-town box' > "$REPO/src/token.txt"
g add -A; run
[ "$RC" -eq 0 ] || fail "without a token list the token is not a hit (exit $RC)"
OUT=$(HOV_STACK_PRIVATE_TOKENS=$'# comment\n\nPLANTED-TOWN\n' HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" 2>&1); RC=$?
[ "$RC" -eq 1 ] || fail "a token from the environment exits $RC, want 1"
has '^private-token list: active \(1 entries from HOV_STACK_PRIVATE_TOKENS\)$' "the environment list is counted without its comment and blank line"
has '^  src/token\.txt:1  private-token  \[redacted, 12 chars\]$' "the token hit, case-insensitive"
mkdir -p "$WORK/overlay"; printf 'planted-town\n' > "$WORK/overlay/private-tokens"
OUT=$(env -u HOV_STACK_PRIVATE_TOKENS HOV_STACK_OVERLAY="$WORK/overlay" bash "$SCAN" --root "$REPO" 2>&1); RC=$?
[ "$RC" -eq 1 ] || fail "a token from the overlay exits $RC, want 1"
has '^private-token list: active \(1 entries from <overlay>/private-tokens\)$' "the overlay list is named by its role, never by its path (the report is pasted into PRs)"
run --require-tokens
[ "$RC" -eq 2 ] || fail "--require-tokens without a list exits $RC, want 2"
has '^private-token list missing: set HOV_STACK_PRIVATE_TOKENS or write <overlay>/private-tokens' "the missing list is named"
lacks '^result: ' "no result line when the required list is missing"
drop "$REPO"/src/token.txt
ok "the token layer fails a planted token from either source and fails closed when required"

echo "== 6: an allowlist row passes a documented mention; removing it fails; a stale row is reported; a shape column confines a row =="
printf '%s\n' "History: the setup was published from $PRIVREPO before the flip." > "$REPO/docs/decisions/2026-01-01-history.md"
printf '%s\t%s\t%s\n' '^docs/decisions/' 'acme/[s]ecret-thing' 'the decision record names the repository the tree came from' \
  '^nowhere/' 'nothing' 'a row that matches nothing' > "$REPO/.public-safety-allow"
g add -A; run
[ "$RC" -eq 0 ] || fail "an allowlisted mention exits $RC, want 0"
has '^  private-repo +0 +0 +1$' "the summary counts the allowlisted match"
has '^allowlist entries that matched nothing \(stale\?\):$' "the stale row is reported"
has 'a row that matches nothing' "the stale row's reason"
: > "$REPO/.public-safety-allow"; g add -A; run
[ "$RC" -eq 1 ] || fail "with the row removed the mention exits $RC, want 1"
has '^  docs/decisions/2026-01-01-history\.md:1  private-repo' "the mention fails without its row"
# A fourth column confines the row to one shape: the same row passes under private-repo and
# is a non-match under email, so a row cannot quietly cover more than it names.
printf '%s\t%s\t%s\t%s\n' '^docs/decisions/' 'acme/[s]ecret-thing' 'confined to its shape' 'private-repo' > "$REPO/.public-safety-allow"
g add -A; run
[ "$RC" -eq 0 ] || fail "a row confined to private-repo exits $RC, want 0"
printf '%s\t%s\t%s\t%s\n' '^docs/decisions/' 'acme/[s]ecret-thing' 'confined to the wrong shape' 'email' > "$REPO/.public-safety-allow"
g add -A; run
[ "$RC" -eq 1 ] || fail "a row confined to email does not cover a private-repo hit (exit $RC, want 1)"
has '^allowlist entries that matched nothing \(stale\?\):$' "the wrongly confined row is reported stale"
printf '%s\t%s\t%s\t%s\n' '^docs/decisions/' 'acme/[s]ecret-thing' 'a shape the scan does not have' 'bare-word' > "$REPO/.public-safety-allow"
g add -A; run
[ "$RC" -eq 2 ] || fail "an unknown shape name exits $RC, want 2"
has 'names a shape the scan does not have' "the unknown shape is named"
lacks '^result: ' "no result line on a bad allowlist"
# A private-token row cannot match while no list is configured: it is reported as not
# exercised, apart from the stale rows, and it matches once the list is present.
printf '%s\n' "History: the box was called planted-town." > "$REPO/docs/decisions/2026-01-02-box.md"
printf '%s\t%s\t%s\t%s\n' '^docs/decisions/' 'acme/[s]ecret-thing' 'the repository mention' 'private-repo' \
  '^docs/decisions/2026-01-02-box\.md$' 'planted-[t]own' 'the decision record names the old box' 'private-token' > "$REPO/.public-safety-allow"
g add -A; run
[ "$RC" -eq 0 ] || fail "with no token list the token row is unexercised and the tree passes (exit $RC)"
has '^allowlist entries for the private-token shape, not exercised because the list is not configured:$' "the unexercised token row is reported apart"
has 'the decision record names the old box' "the unexercised row's reason"
lacks '^allowlist entries that matched nothing \(stale\?\):$' "an unexercised token row is not called stale"
OUT=$(HOV_STACK_PRIVATE_TOKENS=$'planted-town\n' HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "with the list configured the token row covers its mention (exit $RC, want 0)"
has '^  private-token +0 +0 +1$' "the summary counts the allowlisted token match"
lacks 'not exercised because the list is not configured' "an exercised token row is not reported as unexercised"
drop "$REPO"/docs/decisions/2026-01-01-history.md "$REPO"/docs/decisions/2026-01-02-box.md
: > "$REPO/.public-safety-allow"; g add -A
ok "the allowlist passes a named exception and nothing else, and a shape column confines a row"

echo "== 7: the skip list's suites are listed as excluded from the run and their sources are still scanned =="
printf 'xfail\t%s\t%s\t%s\n' tests/private-only.test.sh 'needs the private host table' 'host table' > "$REPO/tests/claude-tests.skips"
printf '%s\n' '#!/usr/bin/env bash' "cat $LINUX/hosts.tsv" > "$REPO/tests/private-only.test.sh"
g add -A; run
[ "$RC" -eq 1 ] || fail "a hit inside an excluded suite exits $RC, want 1"
has '^excluded from the test run by tests/claude-tests.skips, sources scanned like any other tracked file:$' "the excluded heading"
has '^  xfail tests/private-only\.test\.sh$' "the excluded suite is listed"
has '^  tests/private-only\.test\.sh:2  linux-home' "its source is still scanned"
ok "an excluded suite is listed and its planted hit still fails"

echo "== 8: --rev scans a commit; the working tree scan no longer sees a removed file; a bad revision is exit 2 =="
g commit -q -m planted
drop "$REPO"/tests/private-only.test.sh
run
[ "$RC" -eq 0 ] || fail "after the removal the working tree exits $RC, want 0"
run --rev HEAD
[ "$RC" -eq 1 ] || fail "--rev HEAD exits $RC, want 1"
has '^public-safety scan: .* \(revision [0-9a-f]{40}\)$' "the revision is named"
lacks '^public-safety scan: /' "the header names the tree by its basename, never by an absolute path"
lacks '^public-safety scan: /' "the header names the tree by its basename, never by an absolute path"
has '^  xfail tests/private-only\.test\.sh$' "the committed skip list is read"
has '^  tests/private-only\.test\.sh:2  linux-home' "the committed hit"
run --rev no-such-rev
[ "$RC" -eq 2 ] || fail "a bad revision exits $RC, want 2"
has 'no such revision' "the bad revision is named"
ok "--rev scans the commit, not the working tree"

echo "== 9: a git grep failure is exit 2, never a pass; a missing input or unknown argument is exit 2 =="
mkdir -p "$WORK/stub"
cat > "$WORK/stub/git" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = grep ] && { echo "stub: grep refused" >&2; exit 2; }; done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$WORK/stub/git"
OUT=$(REAL_GIT=$(command -v git) PATH="$WORK/stub:$PATH" env -u HOV_STACK_PRIVATE_TOKENS HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" 2>&1); RC=$?
[ "$RC" -eq 2 ] || fail "a failing git grep exits $RC, want 2"
has '^git grep failed for shape linux-home \(exit 2\): stub: grep refused' "the failure is named"
lacks '^result: ' "no result line after a grep failure"
run --allow "$WORK/none"
[ "$RC" -eq 2 ] || fail "a missing allowlist exits $RC, want 2"
has '^allowlist missing: ' "the missing allowlist is named"
run --bogus
[ "$RC" -eq 2 ] || fail "an unknown argument exits $RC, want 2"
has '^unknown argument: --bogus' "the unknown argument is named"
ok "the scan fails closed on a grep failure and on a missing input"

echo "== 10: the real allowlist's token rows are load-bearing: without them the real tree fails on the files they name =="
# The rows that keep the old staging name in the decision record and the restructure plan.
# A scratch fixture cannot show those rows do anything, so this section scans the real tree
# with the old name as the only token; the name and the row needle are assembled from pieces
# because this file is part of that tree. The tree may be dirty under a developer, so the
# assertions are about the two files the rows name, never about the whole result.
STAGING='w''stack'
ROW_NEEDLE='^[w]st''ack$'
REAL_ALLOW=$ROOT/.public-safety-allow
real_scan() { # real_scan <allowlist>: the real tree, the staging name as the only token
  OUT=$(HOV_STACK_PRIVATE_TOKENS="$STAGING" HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$ROOT" --allow "$1" --require-tokens 2>&1); RC=$?
}
if grep -q -F -- "$ROW_NEEDLE" "$REAL_ALLOW"; then
  grep -v -F -- "$ROW_NEEDLE" "$REAL_ALLOW" > "$WORK/allow-minus"
  real_scan "$WORK/allow-minus"
  [ "$RC" -eq 1 ] || fail "the real tree without its token rows exits $RC, want 1"
  has '^  docs/decisions/2026-10-20-hovstack-architecture\.md:[0-9]+  private-token' "the decision record fails without its row"
  has '^  docs/plans/2026-10-20-feat-hovstack-restructure-plan\.md:[0-9]+  private-token' "the restructure plan fails without its row"
  real_scan "$REAL_ALLOW"
  lacks '^  docs/(decisions|plans)/2026-10-20-[a-z-]+\.md:[0-9]+  private-token' "with the real rows neither file is reported"
  has '^  private-token +[0-9]+ +[0-9]+ +([2-9]|[1-9][0-9]+)$' "the summary counts at least two allowlisted token matches"
  ok "the real token rows cover the two files they name and nothing stands in for them"
else
  real_scan "$REAL_ALLOW"
  lacks '^  docs/(decisions|plans)/2026-10-20-[a-z-]+\.md:[0-9]+  private-token' "with no token rows left, the old name is gone from the files that carried it"
  ok "the real allowlist has no token rows and the files they named no longer carry the old name"
fi

echo "== 11: a file's name is scanned like its content: a home form or token in a path fails as path:path, --rev sees it, a row covers it =="
TOKDIR='planted''-town'
mkdir -p "$REPO/src/$TOKDIR" "$REPO/src/$PROJECT"
printf '%s\n' 'clean content' > "$REPO/src/$TOKDIR/checks.json"
printf '%s\n' 'clean content' > "$REPO/src/$PROJECT/session.jsonl"
g add -A; run
[ "$RC" -eq 1 ] || fail "a home form in a path exits $RC, want 1"
has "^  src/$PROJECT/session\.jsonl:path  linux-home" "the home form in the file's path"
lacks "^  src/$TOKDIR/" "without a token list a token in a path is not a hit"
has '^result: FAIL \(1 hits in 1 files\)$' "the path is the only hit; the clean contents add none"
OUT=$(HOV_STACK_PRIVATE_TOKENS=$'planted-town\n' HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" 2>&1); RC=$?
[ "$RC" -eq 1 ] || fail "a token in a path exits $RC, want 1"
has "^  src/$TOKDIR/checks\.json:path  private-token  \[redacted, 12 chars\]$" "the token in the path, redacted"
g commit -q -m paths
drop "$REPO/src/$PROJECT/session.jsonl"
run
lacks "^  src/$PROJECT/" "the working tree no longer has the path"
run --rev HEAD
[ "$RC" -eq 1 ] || fail "--rev HEAD with the path committed exits $RC, want 1"
has "^  src/$PROJECT/session\.jsonl:path  linux-home" "the committed path"
printf '%s\t%s\t%s\t%s\n' '^src/planted-[t]own/' 'planted-[t]own' 'a fixture directory named after the box' 'private-token' > "$REPO/.public-safety-allow"
g add -A
OUT=$(HOV_STACK_PRIVATE_TOKENS=$'planted-town\n' HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "a row covering the path exits $RC, want 0"
has '^  private-token +0 +0 +1$' "the summary counts the allowlisted path match"
drop "$REPO/src/$TOKDIR/checks.json"
: > "$REPO/.public-safety-allow"; g add -A
ok "a home form or token in a file's name fails like one in its content, and a row covers it"

echo "== 12: a path whose bytes are not valid UTF-8 is still scanned by name, in the tree and at --rev =="
BADDIR=$(printf 'caf\351')
mkdir -p "$REPO/src/$BADDIR/$TOKDIR"
printf '%s\n' 'clean content' > "$REPO/src/$BADDIR/$TOKDIR/x.json"
g add -A; g commit -q -m bad-bytes
for rev in "" HEAD; do
  OUT=$(HOV_STACK_PRIVATE_TOKENS=$'planted-town\n' HOV_STACK_OVERLAY="$WORK/no-overlay" bash "$SCAN" --root "$REPO" ${rev:+--rev "$rev"} 2>&1); RC=$?
  [ "$RC" -eq 1 ] || fail "a token under a non-UTF-8 directory exits $RC, want 1 (rev '${rev}')"
  has "/$TOKDIR/x\.json:path  private-token  \[redacted, 12 chars\]$" "the token in a path that is not valid UTF-8 (rev '${rev}')"
done
drop "$REPO/src/$BADDIR/$TOKDIR/x.json"
ok "a token in a path that is not valid UTF-8 is a hit, in the tree and at a revision"

if [ "$fails" -eq 0 ]; then echo "public-safety-scan: all sections passed"; else echo "public-safety-scan: $fails failure(s)"; exit 1; fi
