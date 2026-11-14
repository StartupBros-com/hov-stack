#!/usr/bin/env bash
# tests/pre-push-hook.test.sh: scripts/git-hooks/pre-push, driven by real pushes to a local
# bare remote, blocks a push that would publish a planted private token in any new commit
# (the tip, an earlier commit, a second pushed ref, a tag), passes a clean push, a delete
# and a hit that the pushed tip's committed allowlist covers, ignores an uncommitted
# allowlist edit, fails closed without the token list or a named remote, and is tracked
# executable. The planted token is assembled from two pieces so this suite's own source
# passes the scan it drives.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOKS=$ROOT/scripts/git-hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pre-push-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok: $*"; }

echo "== 0: the hook is tracked executable =="
mode=$(git -C "$ROOT" ls-files -s scripts/git-hooks/pre-push | cut -d' ' -f1)
[ "$mode" = 100755 ] || fail "the hook is tracked with mode '$mode', want 100755: git skips a hook that is not executable"
ok "the hook is tracked as 100755"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REMOTE=$WORK/remote.git
REPO=$WORK/repo
git init -q --bare "$REMOTE"
git init -q -b main "$REPO"
g() { git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
g remote add origin "$REMOTE"
g config core.hooksPath "$HOOKS"
TOKEN='plantedtoken''word'

OUT=""; RC=0
push() { # push [args...]: git push from $REPO with the planted token list; sets OUT and RC
  OUT=$(HOV_STACK_PRIVATE_TOKENS="$TOKEN" HOV_STACK_OVERLAY="$WORK/no-overlay" git -C "$REPO" push "$@" 2>&1); RC=$?
}
push_without_list() { # the same with no token list anywhere
  OUT=$(env -u HOV_STACK_PRIVATE_TOKENS HOV_STACK_OVERLAY="$WORK/no-overlay" git -C "$REPO" push "$@" 2>&1); RC=$?
}
has() { grep -qE -- "$1" <<<"$OUT" || fail "$2 (no line matches /$1/): $OUT"; }
lacks() { if grep -qiE -- "$1" <<<"$OUT"; then fail "$2 (a line matches /$1/): $OUT"; fi; }
on_remote() { git -C "$REMOTE" rev-parse --verify --quiet "$1" >/dev/null; }
commit_file() { # commit_file <path> <text> <message>
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  g add -A && g commit -qm "$3"
}
branch() { g checkout -q -b "$1" main; }
tip_sha() { g rev-parse HEAD; }

echo "== 1: the first push of main scans its commit and passes =="
printf '%s\n' 'acme/public-thing' > "$REPO/.public-safety-repos"
: > "$REPO/.public-safety-allow"
commit_file README.md 'fixture' 'first'
push origin main
[ "$RC" -eq 0 ] || fail "a clean first push exits $RC: $OUT"
has 'scanning 1 commit\(s\) not yet on origin' "the scan count"
has '1 commit\(s\) clean' "the pass line"
on_remote refs/heads/main || fail "main did not reach the remote"
ok "a clean push passes"

echo "== 2: a new branch scans only the commit the remote lacks =="
branch feature
commit_file src/a.txt 'clean text' 'a'
push origin feature
[ "$RC" -eq 0 ] || fail "a clean branch push exits $RC: $OUT"
has 'scanning 1 commit\(s\) not yet on origin' "main's commit is not rescanned"
on_remote refs/heads/feature || fail "feature did not reach the remote"
ok "commits already on the remote's tracking refs are skipped"

echo "== 3: a token in the tip blocks the push, redacted =="
branch leak
commit_file src/leak.txt "a $TOKEN here" 'leak'
leak=$(tip_sha)
push origin leak
[ "$RC" -ne 0 ] || fail "a push carrying the token passed: $OUT"
has "commit $leak fails the scan" "the failing commit is named"
has '^  src/leak\.txt:1  private-token  \[redacted, 16 chars\]$' "the scan's report, redacted"
has 'push blocked: 1 of 1 commit' "the block line"
lacks "$TOKEN" "the token text"
on_remote refs/heads/leak && fail "the leaking branch reached the remote"
ok "a token in the pushed tip blocks the push"

echo "== 4: a token added and removed within one push still blocks it =="
branch scrub
commit_file src/scrub.txt "a $TOKEN here" 'add'
added=$(tip_sha)
commit_file src/scrub.txt 'scrubbed' 'remove'
push origin scrub
[ "$RC" -ne 0 ] || fail "a push whose history carries the token passed: $OUT"
has "commit $added fails the scan" "the earlier commit is named"
has 'push blocked: 1 of 2 commit' "only the earlier commit fails"
on_remote refs/heads/scrub && fail "the scrubbed branch reached the remote"
ok "every new commit is scanned, not only the tip"

echo "== 5: the pushed tip's committed allowlist covers an earlier commit's hit =="
branch allowed
commit_file docs/x.txt "the $TOKEN name" 'mention'
printf '%s\t%s\t%s\t%s\n' '^docs/x\.txt$' '^[p]lantedtokenword$' 'fixture: meant to be public' 'private-token' > "$REPO/.public-safety-allow"
g add -A && g commit -qm 'allow the mention'
push origin allowed
[ "$RC" -eq 0 ] || fail "a hit the tip's allowlist covers was blocked: $OUT"
has 'scanning 2 commit\(s\)' "both commits are scanned"
on_remote refs/heads/allowed || fail "the allowed branch did not reach the remote"
ok "a later commit's allowlist row covers the earlier commit"

echo "== 6: an uncommitted allowlist edit changes nothing =="
branch dirty-allow
commit_file docs/y.txt "the $TOKEN name" 'mention'
printf '%s\t%s\t%s\t%s\n' '^docs/y\.txt$' '^[p]lantedtokenword$' 'not committed' 'private-token' > "$REPO/.public-safety-allow"
push origin dirty-allow
[ "$RC" -ne 0 ] || fail "an uncommitted allowlist row let the token through: $OUT"
on_remote refs/heads/dirty-allow && fail "the branch reached the remote"
g checkout -q -- .public-safety-allow
ok "only the committed allowlist counts"

echo "== 7: two refs in one push are both scanned =="
branch two-a
commit_file src/two-a.txt 'clean' 'clean'
branch two-b
commit_file src/two-b.txt "a $TOKEN" 'leak'
two_b=$(tip_sha)
push origin two-a two-b
[ "$RC" -ne 0 ] || fail "a two-ref push with a token in one ref passed: $OUT"
has 'scanning 2 commit\(s\)' "both refs' commits are planned"
has "commit $two_b fails the scan" "the leaking ref's commit is named"
on_remote refs/heads/two-a && fail "the clean ref was pushed although the push was blocked"
on_remote refs/heads/two-b && fail "the leaking ref reached the remote"
ok "every pushed ref is read before any scan runs"

echo "== 8: a tag is scanned through to its commit =="
g tag -a v-clean -m 'clean tag' main
push origin v-clean
[ "$RC" -eq 0 ] || fail "a tag on a pushed commit was blocked: $OUT"
lacks 'scanning' "a tag on a commit the remote has scans nothing"
on_remote refs/tags/v-clean || fail "the clean tag did not reach the remote"
g tag -a v-leak -m 'leak tag' leak
push origin v-leak
[ "$RC" -ne 0 ] || fail "a tag on the leaking commit passed: $OUT"
has "commit $leak fails the scan" "the tagged commit is scanned"
on_remote refs/tags/v-leak && fail "the leaking tag reached the remote"
ok "tags are peeled and scanned"

echo "== 9: without the token list the push is blocked =="
branch nolist
commit_file src/n.txt 'clean' 'n'
push_without_list origin nolist
[ "$RC" -ne 0 ] || fail "a push without the token list passed: $OUT"
has 'private-token list missing' "the scan says why"
has 'the scan could not run on' "the hook says it could not scan"
on_remote refs/heads/nolist && fail "the branch reached the remote"
ok "a missing token list fails closed"

echo "== 10: a delete publishes nothing and needs no token list =="
push_without_list origin --delete feature
[ "$RC" -eq 0 ] || fail "a delete exits $RC: $OUT"
lacks 'scanning' "a delete scans nothing"
on_remote refs/heads/feature && fail "feature is still on the remote"
ok "a delete passes"

echo "== 11: a push to a bare URL is refused =="
push "$REMOTE" nolist
[ "$RC" -ne 0 ] || fail "a push to a URL passed: $OUT"
has 'push through a named remote' "the hook says why"
on_remote refs/heads/nolist && fail "the branch reached the remote"
ok "a URL push fails closed"

if [ "$fails" -eq 0 ]; then echo "pre-push-hook: all sections passed"; else echo "pre-push-hook: $fails failure(s)"; exit 1; fi
