#!/usr/bin/env bash
# Tests for lib/repo-update.sh (dotfiles#206).
#
# The regression this exists for: dotup's first version skipped its update whenever the tree
# was dirty, and the canonical ~/dotfiles is permanently dirty (backup-harness rsyncs live
# memory into memory/, 167 modified paths when this was found). Case 2 is that exact
# shape — a dirty file NOT in the incoming diff must still fast-forward. Case 3 is its
# planted negative: a dirty file that IS in the incoming diff must refuse and lose nothing.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# shellcheck source=/dev/null
. "$REPO/lib/repo-update.sh"

git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }

# True when <tgz> lists every <path>. Never `tar -t | grep -q` under pipefail:
# grep -q exits on the first hit, GNU tar writes later entries separately, and
# tar then takes SIGPIPE (141), so a listed path reads as missing under load.
tgz_lists() {
  local tgz=$1 listing p
  shift
  listing=$(tar -tzf "$tgz" 2>/dev/null) || return 1
  for p in "$@"; do
    case $'\n'"$listing"$'\n' in
      *$'\n'"$p"$'\n'*) ;;
      *) return 1 ;;
    esac
  done
}

# Build an origin with two commits, and a clone parked one commit behind.
# $1 = fixture name -> echoes the clone path
fixture() {
  local n=$1
  local o=$TMP/$n.git c=$TMP/$n
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c.seed" 2>/dev/null
  printf 'v1\n' >"$c.seed/tracked"
  printf 'other\n' >"$c.seed/untouched"
  git_q "$c.seed" add tracked untouched
  git_q "$c.seed" commit -qm first
  git_q "$c.seed" push -q origin main
  git clone -q "$o" "$c" 2>/dev/null          # the clone under test, at "first"
  printf 'v2\n' >"$c.seed/tracked"            # origin moves ahead, touching ONLY `tracked`
  git_q "$c.seed" commit -qam second
  git_q "$c.seed" push -q origin main
  echo "$c"
}

# ── 1. clean checkout behind origin: fast-forwards ───────────────────────────────────────
C=$(fixture clean)
before=$(git -C "$C" rev-parse HEAD)
if repo_ff_update "$C" >/dev/null; then ok; else bad "clean checkout did not fast-forward"; fi
[ "$(git -C "$C" rev-parse HEAD)" != "$before" ] && ok || bad "clean checkout HEAD did not advance"
grep -q v2 "$C/tracked" && ok || bad "clean checkout did not receive the new content"

# ── 2. REGRESSION: dirty file NOT in the incoming diff still fast-forwards ───────────────
# This is ~/dotfiles with 167 modified memory paths and an incoming change to lib/.
C=$(fixture dirty-unrelated)
printf 'LOCAL-EDIT\n' >>"$C/untouched"
before=$(git -C "$C" rev-parse HEAD)
if repo_ff_update "$C" >/dev/null; then ok; else bad "dirty-but-unrelated checkout refused to fast-forward"; fi
[ "$(git -C "$C" rev-parse HEAD)" != "$before" ] && ok || bad "dirty-but-unrelated HEAD did not advance"
grep -q LOCAL-EDIT "$C/untouched" && ok || bad "local edit was lost during fast-forward"
grep -q v2 "$C/tracked" && ok || bad "dirty-but-unrelated checkout did not receive the new content"

# ── 3. PLANTED NEGATIVE: dirty file that IS in the incoming diff must refuse ─────────────
# If this passes, the update is overwriting uncommitted work and case 2 is dangerous.
C=$(fixture dirty-conflicting)
printf 'PRECIOUS-UNCOMMITTED\n' >>"$C/tracked"
before=$(git -C "$C" rev-parse HEAD)
if repo_ff_update "$C" >/dev/null; then bad "overwrote a locally-modified incoming file"; else ok; fi
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite the refusal"
grep -q PRECIOUS-UNCOMMITTED "$C/tracked" && ok || bad "uncommitted work was DESTROYED"

# ── 4. wrong branch: skipped, does not touch the checkout ────────────────────────────────
C=$(fixture wrong-branch)
git_q "$C" checkout -qb side
before=$(git -C "$C" rev-parse HEAD)
out=$(repo_ff_update "$C" || true)
case "$out" in *"not 'main'"*) ok ;; *) bad "wrong-branch case did not report the branch: $out" ;; esac
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "wrong-branch checkout was modified"

# ── 5. already current: succeeds, says so ────────────────────────────────────────────────
C=$(fixture current)
repo_ff_update "$C" >/dev/null
out=$(repo_ff_update "$C")
case "$out" in *"already current"*) ok ;; *) bad "second update did not report already-current: $out" ;; esac

# ── 6. local commits not on origin: refuses, names divergence ────────────────────────────
C=$(fixture diverged)
printf 'local\n' >"$C/local-only"
git_q "$C" add local-only
git_q "$C" commit -qm "local only"
before=$(git -C "$C" rev-parse HEAD)
out=$(repo_ff_update "$C" || true)
case "$out" in *"not fast-forwardable"*) ok ;; *) bad "diverged case did not report divergence: $out" ;; esac
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "diverged checkout was modified"

# ── untracked-path collisions (dotfiles#484) ─────────────────────────────────────────────
# The canonical checkout sat 25 commits behind for four days because every failed
# fast-forward reported "an incoming change touches a locally-modified file; commit or
# revert it first". The real cause was 27 UNTRACKED files sitting on paths origin/main
# tracks. That advice is wrong twice: there is nothing to revert, and committing them
# converts a lossless delete into real divergence. These cases pin the third diagnosis.
#
# Needs a different fixture shape: a collision requires origin to ADD a path the clone
# does not track, which `fixture` (which only modifies `tracked`) cannot produce.
# $1 = name, $2.. = paths origin's second commit adds -> echoes the clone path
fixture_adds() {
  local n=$1; shift
  local o=$TMP/$n.git c=$TMP/$n f
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c.seed" 2>/dev/null
  printf 'v1\n' >"$c.seed/tracked"
  git_q "$c.seed" add tracked
  git_q "$c.seed" commit -qm first
  git_q "$c.seed" push -q origin main
  git clone -q "$o" "$c" 2>/dev/null          # the clone under test, before the adds
  for f in "$@"; do
    mkdir -p "$(dirname "$c.seed/$f")"
    printf 'INCOMING %s\n' "$f" >"$c.seed/$f"
    git_q "$c.seed" add "$f"
  done
  git_q "$c.seed" commit -qm adds
  git_q "$c.seed" push -q origin main
  echo "$c"
}

# ── 7. untracked file IDENTICAL to the incoming blob ─────────────────────────────────────
C=$(fixture_adds untracked-same a.txt)
printf 'INCOMING a.txt\n' >"$C/a.txt"
before=$(git -C "$C" rev-parse HEAD)
out=$(repo_ff_update "$C" || true)
case "$out" in *"untracked file(s) occupy paths"*) ok ;; *) bad "untracked collision not named as its own cause: $out" ;; esac
case "$out" in *"identical a.txt"*) ok ;; *) bad "did not list the colliding path: $out" ;; esac
case "$out" in *"1 byte-identical"*) ok ;; *) bad "did not classify the collision as lossless: $out" ;; esac
case "$out" in *"DELETE"*) ok ;; *) bad "did not state the remedy: $out" ;; esac
# The exact sentence that sent four days of debugging the wrong way.
case "$out" in *"commit or revert"*) bad "STILL tells the operator to commit an untracked file: $out" ;; *) ok ;; esac
[ -f "$C/a.txt" ] && ok || bad "the refusal deleted the untracked file itself"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite the refusal"

# ── 8. untracked file that DIFFERS must not be called safe to delete ─────────────────────
C=$(fixture_adds untracked-diff b.txt)
printf 'MY OWN UNSAVED DRAFT\n' >"$C/b.txt"
out=$(repo_ff_update "$C" || true)
case "$out" in *"differs   b.txt"*) ok ;; *) bad "a differing collision was not flagged for inspection: $out" ;; esac
case "$out" in *"1 differ from origin/main"*) ok ;; *) bad "differing count wrong: $out" ;; esac
grep -q 'MY OWN UNSAVED DRAFT' "$C/b.txt" && ok || bad "the untracked draft was DESTROYED"

# ── 9. mixed, and the cap can only ever hide the safe ones ───────────────────────────────
C=$(fixture_adds mixed one two three)
printf 'INCOMING one\n' >"$C/one"
printf 'INCOMING two\n' >"$C/two"
printf 'MINE\n'         >"$C/three"
out=$(repo_ff_update "$C" || true)
case "$out" in *"3 untracked file(s) occupy paths"*) ok ;; *) bad "wrong collision total: $out" ;; esac
case "$out" in *"1 differ from origin/main (check first), 2 byte-identical"*) ok ;; *) bad "wrong split: $out" ;; esac

export REPO_FF_LIST_CAP=1
out=$(repo_ff_update "$C" || true)
unset REPO_FF_LIST_CAP
# Truncation that nobody is told about reads as "that was all of it".
case "$out" in *"2 more not listed"*) ok ;; *) bad "capped list did not state the withheld count: $out" ;; esac
# Ordering is the point of the cap, not decoration: the entry needing a human must survive.
case "$out" in *"differs   three"*) ok ;; *) bad "the cap hid the file that needs inspecting: $out" ;; esac
case "$out" in *"identical one"*|*"identical two"*) bad "a cap of 1 still listed a second entry: $out" ;; *) ok ;; esac

# ── 10. NEGATIVE CONTROL: an untracked file NOT on an incoming path blocks nothing ───────
# Load-bearing. ~/dotfiles carries ~230 untracked files at rest; if the new diagnosis
# widened into a guard, the hourly update would refuse forever and this whole change
# would be a worse outage than the bug it fixes.
C=$(fixture_adds untracked-unrelated a.txt)
printf 'scratch\n' >"$C/NOT-AN-INCOMING-PATH"
if repo_ff_update "$C" >/dev/null; then ok; else bad "an unrelated untracked file blocked the fast-forward"; fi
grep -q scratch "$C/NOT-AN-INCOMING-PATH" && ok || bad "unrelated untracked file was destroyed"

# ── 11. divergence outranks a collision: one cause, the one whose fix is different ───────
C=$(fixture_adds diverged-and-colliding a.txt)
printf 'INCOMING a.txt\n' >"$C/a.txt"
printf 'local\n' >"$C/local-only"
git_q "$C" add local-only
git_q "$C" commit -qm "local only"
out=$(repo_ff_update "$C" || true)
case "$out" in *"not fast-forwardable"*) ok ;; *) bad "divergence not reported when a collision was also present: $out" ;; esac
case "$out" in *"untracked file(s) occupy"*) bad "buried the divergence under a collision list: $out" ;; *) ok ;; esac

# ── 12. an unexplained refusal hands over git's own words instead of inventing a cause ───
C=$(fixture_adds explain-fallback a.txt)
out=$(repo_ff_explain "$C" main "  " "error: something only git knows")
case "$out" in *"no blocking path was identified"*) ok ;; *) bad "fabricated a cause it had not established: $out" ;; esac
case "$out" in *"error: something only git knows"*) ok ;; *) bad "discarded git's own message: $out" ;; esac

# ── memory/ auto-restore (dotfiles#1343) ──────────────────────────────────────────
# A merged memory-mirror PR lands on the exact path backup-harness.sh rsyncs live
# agent memory into, so the canonical checkout collides with itself on every
# such merge. repo_ff_update's 2nd arg is the auto-restore prefix: opt-in
# (only dotup passes it), and only ever attempted when EVERY blocker sits under
# it. Same fixture shape as `fixture`/`fixture_adds` above, just nested under
# memory/ so the "modified" and "untracked" collision shapes both exist
# there.
# $1 = fixture name -> echoes the clone path
fixture_memory() {
  local n=$1
  local o=$TMP/$n.git c=$TMP/$n
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c.seed" 2>/dev/null
  mkdir -p "$c.seed/memory"
  printf 'v1\n' >"$c.seed/memory/note.md"
  printf 'other\n' >"$c.seed/untouched"
  git_q "$c.seed" add memory/note.md untouched
  git_q "$c.seed" commit -qm first
  git_q "$c.seed" push -q origin main
  git clone -q "$o" "$c" 2>/dev/null          # the clone under test, at "first"
  printf 'v2\n' >"$c.seed/memory/note.md"   # origin moves ahead, touching ONLY the mirror note
  git_q "$c.seed" commit -qam second
  git_q "$c.seed" push -q origin main
  echo "$c"
}

# Both a memory path AND a non-memory path collide, so the non-memory blocker
# must veto recovery entirely — this is the issue's own planted negative.
# $1 = fixture name -> echoes the clone path
fixture_memory_and_other() {
  local n=$1
  local o=$TMP/$n.git c=$TMP/$n
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c.seed" 2>/dev/null
  mkdir -p "$c.seed/memory"
  printf 'v1\n' >"$c.seed/memory/note.md"
  printf 'v1\n' >"$c.seed/settings.json"
  git_q "$c.seed" add memory/note.md settings.json
  git_q "$c.seed" commit -qm first
  git_q "$c.seed" push -q origin main
  git clone -q "$o" "$c" 2>/dev/null
  printf 'v2\n' >"$c.seed/memory/note.md"
  printf 'v2\n' >"$c.seed/settings.json"
  git_q "$c.seed" commit -qam second
  git_q "$c.seed" push -q origin main
  echo "$c"
}

# ── 13. memory-only MODIFIED collision recovers, and ends at incoming content ────────────
C=$(fixture_memory memory-modified)
printf 'LIVE-MEMORY-DIRT\n' >>"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)
# NOT `out=$(repo_ff_update ...)`: command substitution runs the function in a
# subshell, so its REPO_FF_RECOVERY_ATTEMPTED assignment would never reach this
# script. Redirect to a file instead so the call runs in-process.
# REPO_FF_SNAPSHOT_DIR is test-owned in every recovery case from here down —
# the default location is a REAL path under the operator's $HOME, and this
# suite must never write there.
outfile=$TMP/out.13
snap13=$TMP/snap.13
rc=0
REPO_FF_SNAPSHOT_DIR=$snap13 repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
out=$(cat "$outfile")
[ "$rc" -eq 0 ] && ok || bad "memory-only modified collision did not auto-recover: $out"
[ "$(git -C "$C" rev-parse HEAD)" != "$before" ] && ok || bad "memory-only modified collision HEAD did not advance"
[ "$(cat "$C/memory/note.md")" = v2 ] \
  && ok || bad "memory-only modified collision did not end at incoming content: $(cat "$C/memory/note.md")"
[ -n "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was not set despite a successful recovery"
case "$out" in *"recovered from a memory/ collision"*) ok ;; *) bad "recovery was not announced: $out" ;; esac
snap13_file=$(find "$snap13" -maxdepth 1 -name 'mirror-droppings-*.tgz' 2>/dev/null | head -1)
[ -n "$snap13_file" ] && [ -f "$snap13_file" ] \
  && ok || bad "no recovery snapshot tarball was written to $snap13"
tgz_lists "$snap13_file" 'memory/note.md' \
  && ok || bad "the snapshot tarball did not list the recovered blocker path"

# ── 14. memory-only UNTRACKED collision recovers (PR #1224 shape: new mirror files) ──────
# #1224 added 2,053 NEW files under memory/**, which a checkout already
# carrying an uncommitted live copy hits as untracked-diff/untracked-same, not
# modified. Those must recover too, by deleting the untracked copy (never a
# `git checkout --`, which has nothing at HEAD to restore an untracked path to).
C=$(fixture_adds memory-untracked memory/note.md)
mkdir -p "$C/memory"
printf 'LIVE-MEMORY-DIRT\n' >"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)
outfile=$TMP/out.14
snap14=$TMP/snap.14
rc=0
REPO_FF_SNAPSHOT_DIR=$snap14 repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
out=$(cat "$outfile")
[ "$rc" -eq 0 ] && ok || bad "memory-only untracked collision did not auto-recover: $out"
[ "$(git -C "$C" rev-parse HEAD)" != "$before" ] && ok || bad "memory-only untracked collision HEAD did not advance"
grep -q 'INCOMING memory/note.md' "$C/memory/note.md" \
  && ok || bad "memory-only untracked collision did not receive incoming content"
[ -n "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was not set despite a successful recovery"
case "$out" in *"recovered from a memory/ collision"*) ok ;; *) bad "recovery was not announced: $out" ;; esac

# ── 15. PLANTED NEGATIVE: a modified file OUTSIDE the prefix still refuses, prefix or not ─
# Passing an auto-restore prefix must never widen what gets rescued: a collision
# that has nothing to do with memory/ is refused exactly as it was before
# this feature existed.
C=$(fixture dirty-conflicting-with-prefix)
printf 'PRECIOUS-UNCOMMITTED\n' >>"$C/tracked"
before=$(git -C "$C" rev-parse HEAD)
if repo_ff_update "$C" "memory/" >/dev/null
then bad "a memory/ prefix let a non-memory collision through"
else ok
fi
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite the refusal"
grep -q PRECIOUS-UNCOMMITTED "$C/tracked" && ok || bad "uncommitted work was DESTROYED"
[ -z "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was set despite a non-memory blocker vetoing recovery"

# ── 16. no prefix argument at all => no auto-restore (regression guard) ──────────────────
# The default path — used by launchpad-freshen.sh and every case above this
# section — must be byte-for-byte unchanged: strictly opt-in.
C=$(fixture_memory memory-no-prefix)
printf 'LIVE-MEMORY-DIRT\n' >>"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)
if repo_ff_update "$C" >/dev/null
then bad "no-prefix call unexpectedly recovered a memory collision"
else ok
fi
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite no prefix arg"
grep -q LIVE-MEMORY-DIRT "$C/memory/note.md" && ok || bad "local memory dirt was destroyed without a prefix arg"
[ -z "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was set without a prefix arg"

# ── 17. PLANTED NEGATIVE: a memory blocker PLUS a non-memory blocker is refused ──────────
# One non-memory blocker must veto recovery entirely, not just get filtered out
# of the restore list — both edits must survive untouched.
C=$(fixture_memory_and_other memory-and-other)
printf 'LIVE-MEMORY-DIRT\n' >>"$C/memory/note.md"
printf 'LOCAL-SETTINGS-EDIT\n' >>"$C/settings.json"
before=$(git -C "$C" rev-parse HEAD)
if repo_ff_update "$C" "memory/" >/dev/null
then bad "memory + non-memory collision was NOT refused"
else ok
fi
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite a non-memory blocker"
grep -q LIVE-MEMORY-DIRT "$C/memory/note.md" && ok || bad "memory edit was destroyed despite the veto"
grep -q LOCAL-SETTINGS-EDIT "$C/settings.json" && ok || bad "non-memory edit was destroyed"
[ -z "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was set despite a non-memory blocker vetoing recovery"

# ── all-or-nothing recovery rollback (dotfiles#1343 follow-up) ──────────────────────────
# The recovery block backs up every blocker before touching it precisely so a failure
# partway through — a restore step, or the retried merge — can put the tree back
# byte-identical instead of leaving an already-`rm -f`'d file gone with no way back.
# These fixtures carry TWO blockers in different subdirectories, one of each kind, so
# a rollback that only knows how to undo one shape is caught.
#
# $1 = fixture name -> echoes the clone path. The clone (before any local edits) has:
#   memory/sub-a/note.md  (tracked, origin moves it to v2)
#   memory/sub-b/new.md   (does NOT exist yet; origin's 2nd commit adds it)
fixture_memory_partial() {
  local n=$1
  local o=$TMP/$n.git c=$TMP/$n
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c.seed" 2>/dev/null
  mkdir -p "$c.seed/memory/sub-a"
  printf 'v1\n' >"$c.seed/memory/sub-a/note.md"
  git_q "$c.seed" add memory/sub-a/note.md
  git_q "$c.seed" commit -qm first
  git_q "$c.seed" push -q origin main
  git clone -q "$o" "$c" 2>/dev/null          # the clone under test, before the 2nd commit
  printf 'v2\n' >"$c.seed/memory/sub-a/note.md"
  mkdir -p "$c.seed/memory/sub-b"
  printf 'INCOMING sub-b/new.md\n' >"$c.seed/memory/sub-b/new.md"
  git_q "$c.seed" add memory/sub-a/note.md memory/sub-b/new.md
  git_q "$c.seed" commit -qm second
  git_q "$c.seed" push -q origin main
  echo "$c"
}

# Writes a `git` shim to <dir>/git that fails (exit 1) any invocation whose argv
# contains $2 as an EXACT arg (i.e. the subcommand itself — "checkout" or "merge"),
# and execs the real git otherwise. Exact match, not substring: a fixture's own
# tmpdir is passed to every call as the `-C <repo>` argument, and a substring match
# would misfire on any repo path that happens to contain the keyword. The real
# git's path is resolved BEFORE the caller prepends <dir> to PATH — once it's
# prepended, `command -v git` would just find the shim.
write_git_shim() {
  local dir=$1 keyword=$2 real
  real=$(command -v git)
  mkdir -p "$dir"
  cat >"$dir/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "$keyword" ]; then
    exit 1
  fi
done
exec "$real" "\$@"
SHIM
  chmod +x "$dir/git"
}

# Writes a `cp` shim to <dir>/cp that fails (exit 1) ONLY when its SOURCE
# argument — the first operand after a `--`, which is how every `cp` call in
# the recovery block is invoked — sits under a `repo-ff-recover.*` backup dir.
# The forward pass's backup copy (`cp -p -- "$repo/$path" "$dest"`) has its
# SOURCE under the repo, not the backup dir, so it is untouched; only the
# rollback's restore copy (`cp -p -- "$backup/$path" "$repo/$path"`) has its
# source there. This is the reviewer's own repro shape: the forward copy must
# keep working while only the backup-to-repo direction fails.
write_recover_cp_shim() {
  local dir=$1 real
  real=$(command -v cp)
  mkdir -p "$dir"
  cat >"$dir/cp" <<SHIM
#!/usr/bin/env bash
seen_dashdash=0
src=""
for a in "\$@"; do
  if [ "\$seen_dashdash" -eq 1 ] && [ -z "\$src" ]; then
    src=\$a
    continue
  fi
  [ "\$a" = "--" ] && seen_dashdash=1
done
case "\$src" in
  */repo-ff-recover.*) exit 1 ;;
esac
exec "$real" "\$@"
SHIM
  chmod +x "$dir/cp"
}

# Writes a `cp` shim to <dir>/cp that LOGS every invocation's SOURCE operand to
# <logfile> (one per line, appended, regardless of whether it goes on to
# succeed or fail) and fails (exit 1) ONLY when that source contains
# <fail_substring>. Unlike write_recover_cp_shim, this is a "spy": the
# forward-pass backup loop's final on-disk bytes are IDENTICAL whether a
# guard correctly stopped it after a failure or a broken guard let it keep
# going and a clean rollback later undid the extra work — a rollback always
# ends in `rm -rf -- "$backup"`, erasing that evidence, and correctly
# restores whatever it does process either way. The only way to prove a
# later blocker was never even ATTEMPTED is a log that survives independently
# of the backup dir's fate: a path that never appears in it was never passed
# to `cp` at all.
write_spy_cp_shim() {
  local dir=$1 fail_substring=$2 logfile=$3 real
  real=$(command -v cp)
  mkdir -p "$dir"
  cat >"$dir/cp" <<SHIM
#!/usr/bin/env bash
seen_dashdash=0
src=""
for a in "\$@"; do
  if [ "\$seen_dashdash" -eq 1 ] && [ -z "\$src" ]; then
    src=\$a
    continue
  fi
  [ "\$a" = "--" ] && seen_dashdash=1
done
printf '%s\n' "\$src" >>"$logfile"
case "\$src" in
  *"$fail_substring"*) exit 1 ;;
esac
exec "$real" "\$@"
SHIM
  chmod +x "$dir/cp"
}

# Three memory blockers in three different subdirectories, all MODIFIED, so
# the forward backup loop has a real THIRD item that a guard failing to stop
# after the SECOND item's failure would go on to touch.
# $1 = fixture name -> echoes the clone path
fixture_memory_triple() {
  local n=$1
  local o=$TMP/$n.git c=$TMP/$n
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c.seed" 2>/dev/null
  mkdir -p "$c.seed/memory/sub-a" "$c.seed/memory/sub-b" "$c.seed/memory/sub-c"
  printf 'v1\n' >"$c.seed/memory/sub-a/note.md"
  printf 'v1\n' >"$c.seed/memory/sub-b/note.md"
  printf 'v1\n' >"$c.seed/memory/sub-c/note.md"
  git_q "$c.seed" add memory/sub-a/note.md memory/sub-b/note.md memory/sub-c/note.md
  git_q "$c.seed" commit -qm first
  git_q "$c.seed" push -q origin main
  git clone -q "$o" "$c" 2>/dev/null          # the clone under test, before the 2nd commit
  printf 'v2\n' >"$c.seed/memory/sub-a/note.md"
  printf 'v2\n' >"$c.seed/memory/sub-b/note.md"
  printf 'v2\n' >"$c.seed/memory/sub-c/note.md"
  git_q "$c.seed" commit -qam second
  git_q "$c.seed" push -q origin main
  echo "$c"
}

# Writes a `tar` shim to <dir>/tar that always exits <rc> after printing <msg>
# to stderr, regardless of its arguments. GNU tar can exit 0 while still
# warning on stderr about a file it silently skipped or truncated ("file
# changed as we read it", "Cannot stat"), so this fakes both shapes: a hard
# failure (nonzero rc) and the one the fix actually exists for (rc=0, stderr
# non-empty).
write_tar_shim() {
  local dir=$1 rc=$2 msg=$3
  mkdir -p "$dir"
  cat >"$dir/tar" <<SHIM
#!/usr/bin/env bash
echo "$msg" >&2
exit $rc
SHIM
  chmod +x "$dir/tar"
}

# Writes a `tar` shim to <dir>/tar that, for a listing (`-t...`), prints the
# real tar's listing one entry at a time with a pause before each later entry,
# so a reader that stops at the first entry has closed the pipe by the next
# write. Any other call execs the real tar.
write_slow_list_tar_shim() {
  local dir=$1 real
  real=$(command -v tar)
  mkdir -p "$dir"
  cat >"$dir/tar" <<SHIM
#!/usr/bin/env bash
set -e
case "\${1:-}" in
  -t*) ;;
  *) exec "$real" "\$@" ;;
esac
listing=\$("$real" "\$@")
first=1
while IFS= read -r line; do
  [ "\$first" -eq 1 ] || sleep 1
  first=0
  printf '%s\n' "\$line"
done <<<"\$listing"
SHIM
  chmod +x "$dir/tar"
}

# ── 18. PLANTED NEGATIVE: a restore step failing rolls everything back ──────────────────
# Forces `git checkout --` (the modified-blocker restore) to fail. By the time it runs,
# the untracked-diff blocker in the OTHER subdirectory has already been moved into the
# backup — this is exactly the shape #1343's own comment forbade: an earlier step must
# not have destroyed something the later failure can no longer undo.
C=$(fixture_memory_partial recover-restore-fail)
printf 'v1\nLOCAL-MODIFIED-UNIQUE\n' >"$C/memory/sub-a/note.md"
mkdir -p "$C/memory/sub-b"
printf 'LOCAL-UNTRACKED-UNIQUE\n' >"$C/memory/sub-b/new.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.18
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.18
write_git_shim "$shim_dir" checkout
snap18=$TMP/snap.18
outfile=$TMP/out.18
# Run in-process (not `( ... )`, not command substitution) for the same reason
# tests 13/14 do: REPO_FF_RECOVERY_ATTEMPTED must reach THIS shell to be checkable.
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap18"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a failed restore step did not degrade to refusal (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved during a rolled-back recovery"
[ -z "${REPO_FF_ROLLBACK_FAILED:-}" ] \
  && ok || bad "REPO_FF_ROLLBACK_FAILED was set despite a clean rollback (restore-step failure case)"
[ -n "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was not set despite an attempted (and rolled-back) recovery"
[ -f "$C/memory/sub-b/new.md" ] \
  && grep -q LOCAL-UNTRACKED-UNIQUE "$C/memory/sub-b/new.md" \
  && ok || bad "the untracked blocker was not restored to its original path/content"
grep -q LOCAL-MODIFIED-UNIQUE "$C/memory/sub-a/note.md" \
  && ok || bad "the modified blocker lost its local content"
case "$out" in *"rolled back"*) ok ;; *) bad "no rollback WARN was printed: $out" ;; esac
[ -z "$(find "$recovery_tmp" -maxdepth 1 -name 'repo-ff-recover.*' 2>/dev/null)" ] \
  && ok || bad "a repo-ff-recover.* backup dir survived the rollback"

# ── 19. PLANTED NEGATIVE: the retried merge failing rolls everything back too ────────────
# Every restore succeeds this time; only the ff-only retry is forced to fail (which
# also forces the FIRST merge attempt to fail, which is what triggers recovery at all).
C=$(fixture_memory_partial recover-retry-fail)
printf 'v1\nLOCAL-MODIFIED-UNIQUE\n' >"$C/memory/sub-a/note.md"
mkdir -p "$C/memory/sub-b"
printf 'LOCAL-UNTRACKED-UNIQUE\n' >"$C/memory/sub-b/new.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.19
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.19
write_git_shim "$shim_dir" merge
snap19=$TMP/snap.19
outfile=$TMP/out.19
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap19"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a failed merge retry did not degrade to refusal (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved during a rolled-back recovery"
[ -z "${REPO_FF_ROLLBACK_FAILED:-}" ] \
  && ok || bad "REPO_FF_ROLLBACK_FAILED was set despite a clean rollback (merge-retry failure case)"
[ -n "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was not set despite an attempted (and rolled-back) recovery"
[ -f "$C/memory/sub-b/new.md" ] \
  && grep -q LOCAL-UNTRACKED-UNIQUE "$C/memory/sub-b/new.md" \
  && ok || bad "the untracked blocker was not restored to its original path/content"
grep -q LOCAL-MODIFIED-UNIQUE "$C/memory/sub-a/note.md" \
  && ok || bad "the modified blocker lost its local content"
case "$out" in *"rolled back"*) ok ;; *) bad "no rollback WARN was printed: $out" ;; esac
[ -z "$(find "$recovery_tmp" -maxdepth 1 -name 'repo-ff-recover.*' 2>/dev/null)" ] \
  && ok || bad "a repo-ff-recover.* backup dir survived the rollback"

# ── 20. PLANTED NEGATIVE: a rollback step that itself fails must not delete evidence ─────
# The reviewer's own repro (dotfiles#1343 3rd follow-up, P1): the retried merge is
# shimmed to fail (exactly like #19, so a rollback is forced), AND `cp` is shimmed
# to fail ONLY on the backup->repo direction — the forward copy still works, so the
# backup dir DOES get populated before the rollback runs into it. Before this fix,
# the rollback's `cp`/`mv` calls ended in `2>/dev/null` with no status check and
# `rm -rf -- "$backup"` ran unconditionally afterward: the modified file's local
# content was lost, the backup was deleted anyway, and the WARN still said "rolled
# back". Now: the backup dir AND the snapshot tarball must both survive, and
# "rolled back" must never be said when a rollback step actually failed.
C=$(fixture_memory_partial recover-rollback-fail)
printf 'v1\nLOCAL-MODIFIED-UNIQUE\n' >"$C/memory/sub-a/note.md"
mkdir -p "$C/memory/sub-b"
printf 'LOCAL-UNTRACKED-UNIQUE\n' >"$C/memory/sub-b/new.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.20
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.20
write_git_shim "$shim_dir" merge
write_recover_cp_shim "$shim_dir"
snap20=$TMP/snap.20
outfile=$TMP/out.20
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap20"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a failed rollback step did not return 1 (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved during a failed rollback"
[ -n "${REPO_FF_ROLLBACK_FAILED:-}" ] \
  && ok || bad "REPO_FF_ROLLBACK_FAILED was not set despite a rollback step that itself failed"
[ -n "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was not set despite an attempted (and failed) rollback"
backup_dir=$(find "$recovery_tmp" -maxdepth 1 -name 'repo-ff-recover.*' 2>/dev/null | head -1)
[ -n "$backup_dir" ] && [ -d "$backup_dir" ] \
  && ok || bad "the backup dir did not survive a failed rollback step"
[ -n "$backup_dir" ] && grep -q LOCAL-MODIFIED-UNIQUE "$backup_dir/memory/sub-a/note.md" 2>/dev/null \
  && ok || bad "the backup dir lost the modified blocker's local content"
snap20_file=$(find "$snap20" -maxdepth 1 -name 'mirror-droppings-*.tgz' 2>/dev/null | head -1)
[ -n "$snap20_file" ] && [ -f "$snap20_file" ] \
  && ok || bad "the snapshot tarball did not survive a failed rollback"
[ -n "$snap20_file" ] \
  && tgz_lists "$snap20_file" 'memory/sub-a/note.md' 'memory/sub-b/new.md' \
  && ok || bad "the snapshot tarball did not list both blocker paths"
[ -n "$backup_dir" ] && case "$out" in *"$backup_dir"*) ok ;; *) bad "the WARN did not name the backup dir: $out" ;; esac
case "$out" in *"rolled back"*) bad "a FAILED rollback still claimed 'rolled back' as a success: $out" ;; *) ok ;; esac

# ── 21. PLANTED NEGATIVE: a snapshot that cannot be written refuses without mutating ─────
# REPO_FF_SNAPSHOT_DIR points under a regular file, so `mkdir -p` on it fails for
# ANY user, root included — the fixture the task calls for a "path that cannot be
# created ... which fails for root too". Both blockers must survive untouched and
# no backup dir may be created at all: the snapshot write is strictly the FIRST
# thing the recovery block does.
C=$(fixture_memory_partial snapshot-write-fails)
printf 'v1\nLOCAL-MODIFIED-UNIQUE\n' >"$C/memory/sub-a/note.md"
mkdir -p "$C/memory/sub-b"
printf 'LOCAL-UNTRACKED-UNIQUE\n' >"$C/memory/sub-b/new.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.21
mkdir -p "$recovery_tmp"
blocker_file=$TMP/snapshot-blocker-file.21
: >"$blocker_file"
outfile=$TMP/out.21
old_tmpdir=${TMPDIR:-}
TMPDIR="$recovery_tmp"
rc=0
REPO_FF_SNAPSHOT_DIR="$blocker_file/cannot-create-under-a-file" repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a snapshot-write failure did not degrade to refusal (rc=$rc): $out"
grep -q LOCAL-MODIFIED-UNIQUE "$C/memory/sub-a/note.md" \
  && ok || bad "the modified blocker was touched despite a snapshot failure"
[ -f "$C/memory/sub-b/new.md" ] && grep -q LOCAL-UNTRACKED-UNIQUE "$C/memory/sub-b/new.md" \
  && ok || bad "the untracked blocker was touched despite a snapshot failure"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite a snapshot failure"
[ -z "$(find "$recovery_tmp" -maxdepth 1 -name 'repo-ff-recover.*' 2>/dev/null)" ] \
  && ok || bad "a backup dir was created despite a snapshot failure"
[ -z "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was set despite a snapshot failure"
case "$out" in *"could not write recovery snapshot"*) ok ;; *) bad "the snapshot failure was not announced: $out" ;; esac

# ── 22. a staged mirror file is restored from HEAD, not the index ────────────────────────
# A stray `git add` on a mirror file must not survive the auto-restore: `git
# checkout -- $path` restores from the INDEX, which would leave the staged
# (locally-modified) content in place after "recovery". `checkout HEAD --` is
# what actually reverts a staged file to the pre-collision committed content.
C=$(fixture_memory memory-staged)
printf 'LIVE-MEMORY-DIRT\n' >>"$C/memory/note.md"
git_q "$C" add memory/note.md
before=$(git -C "$C" rev-parse HEAD)
snap22=$TMP/snap.22
outfile=$TMP/out.22
rc=0
REPO_FF_SNAPSHOT_DIR="$snap22" repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
out=$(cat "$outfile")
[ "$rc" -eq 0 ] && ok || bad "a staged mirror collision did not auto-recover: $out"
[ "$(git -C "$C" rev-parse HEAD)" != "$before" ] && ok || bad "staged mirror collision HEAD did not advance"
[ "$(cat "$C/memory/note.md")" = v2 ] \
  && ok || bad "staged mirror collision did not end at incoming content: $(cat "$C/memory/note.md")"
[ -z "$(git -C "$C" diff --cached --name-only)" ] \
  && ok || bad "a stale staged entry survived the recovery: $(git -C "$C" diff --cached --name-only)"

# ── 23. PLANTED NEGATIVE: a rollback restores bytes AND the git index (dotfiles#1343 4th) ─
# The forward pass's `checkout HEAD --` un-stages a modified blocker as a side effect
# (index and worktree both reset to HEAD). A rollback that only `cp`s the bytes back
# without re-staging leaves a blocker that was staged before the attempt ("M " in
# `git status --short`) unstaged ("M ") afterward, while the WARN still claims the
# tree is byte-identical. Force the retried merge to fail (same technique as #19) so
# the restore succeeds and the rollback runs, then check the INDEX, not just the bytes.
C=$(fixture_memory memory-staged-rollback)
printf 'v1\nLOCAL-MODIFIED-UNIQUE\n' >"$C/memory/note.md"
git_q "$C" add memory/note.md
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.23
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.23
write_git_shim "$shim_dir" merge
snap23=$TMP/snap.23
outfile=$TMP/out.23
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap23"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a rolled-back staged blocker did not degrade to refusal (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved during a rolled-back recovery"
grep -q LOCAL-MODIFIED-UNIQUE "$C/memory/note.md" \
  && ok || bad "the staged blocker's local content was not restored"
case "$(git -C "$C" status --short -- memory/note.md)" in
  'M '*) ok ;;
  *) bad "a blocker staged before the attempt was not re-staged after rollback: '$(git -C "$C" status --short -- memory/note.md)'" ;;
esac
case "$out" in *"rolled back"*) ok ;; *) bad "no rollback WARN was printed: $out" ;; esac

# ── 24. NEGATIVE CONTROL: the unstaged variant of #23 stays unstaged after rollback ──────
# Proves #23 is a real assertion and not a tautology of `git status` always reporting
# "M " regardless of the index: an otherwise-identical blocker that was NEVER staged
# must come back as " M", not "M ".
C=$(fixture_memory memory-unstaged-rollback)
printf 'v1\nLOCAL-MODIFIED-UNIQUE\n' >"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.24
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.24
write_git_shim "$shim_dir" merge
snap24=$TMP/snap.24
outfile=$TMP/out.24
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap24"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a rolled-back unstaged blocker did not degrade to refusal (rc=$rc): $out"
grep -q LOCAL-MODIFIED-UNIQUE "$C/memory/note.md" \
  && ok || bad "the unstaged blocker's local content was not restored"
case "$(git -C "$C" status --short -- memory/note.md)" in
  ' M'*) ok ;;
  *) bad "a blocker that was never staged came back staged after rollback: '$(git -C "$C" status --short -- memory/note.md)'" ;;
esac

# ── 25. PLANTED NEGATIVE: rollback restores the ORIGINAL staged blob, not the ─────────────
#         worktree bytes at rollback time (dotfiles#1343 5th follow-up, P1)
# memory/ is continuously rsynced on top of anything staged, so a blocker can be
# "MM" going in: staged content A, then further overwritten in the worktree to content B
# BEFORE the recovery attempt even starts. `git add -- "$path"` at rollback time stages
# whatever bytes are CURRENTLY in the worktree — which is the just-restored backup copy of
# B, not the original staged A — silently discarding the real staged content. Force the
# retried merge to fail (same technique as #19/#23) so the restore succeeds and rollback
# runs, then check the INDEX BLOB, not just the worktree bytes.
C=$(fixture_memory memory-mm-rollback)
printf 'v1\nSTAGED-A\n' >"$C/memory/note.md"
git_q "$C" add memory/note.md
printf 'v1\nSTAGED-A\nWORKTREE-B\n' >"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.25
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.25
write_git_shim "$shim_dir" merge
snap25=$TMP/snap.25
outfile=$TMP/out.25
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap25"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "an MM-blocker rollback did not degrade to refusal (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved during an MM-blocker rollback"
[ "$(cat "$C/memory/note.md")" = "$(printf 'v1\nSTAGED-A\nWORKTREE-B')" ] \
  && ok || bad "the worktree bytes after rollback are '$(cat "$C/memory/note.md")', want the pre-attempt WORKTREE-B content"
[ "$(git -C "$C" show :memory/note.md)" = "$(printf 'v1\nSTAGED-A')" ] \
  && ok || bad "rollback re-staged the worktree bytes instead of the original staged blob: index has '$(git -C "$C" show :memory/note.md)', want STAGED-A"
case "$(git -C "$C" status --short -- memory/note.md)" in
  'MM'*) ok ;;
  *) bad "post-rollback status was '$(git -C "$C" status --short -- memory/note.md)', want MM (staged A, worktree B, exactly as before the attempt)" ;;
esac
case "$out" in *"rolled back"*) ok ;; *) bad "no rollback WARN was printed: $out" ;; esac

# ── 26. PLANTED NEGATIVE: a failed item must stop the loop, not just fail it ──────────────
# `[ "$ok" -eq 1 ] || break` is the guard that a failure partway through the forward
# backup loop stops FURTHER processing rather than just recording the failure and
# ploughing on. Three blockers, sub-a/sub-b/sub-c, in path order; sub-b's `cp` backup
# is forced to fail. A correct guard means sub-c's `cp` is NEVER INVOKED AT ALL — the
# spy log is the only evidence that survives independently of the backup dir (which a
# clean rollback deletes either way, and which restores whatever it DOES process
# identically regardless of how much extra work a broken guard let happen).
C=$(fixture_memory_triple memory-triple-guard)
printf 'LOCAL-A\n' >>"$C/memory/sub-a/note.md"
printf 'LOCAL-B\n' >>"$C/memory/sub-b/note.md"
printf 'LOCAL-C\n' >>"$C/memory/sub-c/note.md"
before=$(git -C "$C" rev-parse HEAD)

recovery_tmp=$TMP/recovery-tmpdir.26
mkdir -p "$recovery_tmp"
shim_dir=$TMP/shim.26
spy_log=$TMP/spy.26.log
: >"$spy_log"
write_spy_cp_shim "$shim_dir" "memory/sub-b/note.md" "$spy_log"
snap26=$TMP/snap.26
outfile=$TMP/out.26
old_path=$PATH old_tmpdir=${TMPDIR:-}
PATH="$shim_dir:$PATH" TMPDIR="$recovery_tmp" REPO_FF_SNAPSHOT_DIR="$snap26"
rc=0
repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
if [ -n "$old_tmpdir" ]; then TMPDIR=$old_tmpdir; else unset TMPDIR; fi
unset REPO_FF_SNAPSHOT_DIR
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a mid-loop cp failure did not degrade to refusal (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved during a triple-blocker rollback"
[ -n "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was not set despite an attempted (and rolled-back) recovery"
grep -q 'sub-a/note.md' "$spy_log" && ok || bad "the spy log never saw sub-a, the shim itself is broken: $(cat "$spy_log")"
grep -q 'sub-b/note.md' "$spy_log" && ok || bad "the spy log never saw sub-b's forced failure, the shim itself is broken: $(cat "$spy_log")"
grep -q 'sub-c/note.md' "$spy_log" \
  && bad "the guard did NOT stop the loop: sub-c's cp was invoked after sub-b's failure: $(cat "$spy_log")" \
  || ok
grep -q LOCAL-A "$C/memory/sub-a/note.md" && ok || bad "sub-a's local content was lost"
grep -q LOCAL-B "$C/memory/sub-b/note.md" && ok || bad "sub-b's local content was lost"
grep -q LOCAL-C "$C/memory/sub-c/note.md" && ok || bad "sub-c's local content was lost"
case "$out" in *"rolled back"*) ok ;; *) bad "no rollback WARN was printed: $out" ;; esac
[ -z "$(find "$recovery_tmp" -maxdepth 1 -name 'repo-ff-recover.*' 2>/dev/null)" ] \
  && ok || bad "a repo-ff-recover.* backup dir survived the rollback"

# ── 27. PLANTED NEGATIVE: a hard tar failure degrades to refusal and surfaces tar's words ─
C=$(fixture_memory tar-hard-failure)
printf 'LIVE-MEMORY-DIRT\n' >>"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)

shim_dir=$TMP/shim.27
write_tar_shim "$shim_dir" 2 "tar: fatal: disk quota exceeded"
snap27=$TMP/snap.27
outfile=$TMP/out.27
old_path=$PATH
PATH="$shim_dir:$PATH"
rc=0
REPO_FF_SNAPSHOT_DIR="$snap27" repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "a hard tar failure did not degrade to refusal (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite a hard tar failure"
grep -q LIVE-MEMORY-DIRT "$C/memory/note.md" \
  && ok || bad "the blocker was touched despite a hard tar failure"
[ -z "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was set despite a hard tar failure"
case "$out" in *"could not write recovery snapshot"*) ok ;; *) bad "the tar failure was not announced: $out" ;; esac
case "$out" in *"disk quota exceeded"*) ok ;; *) bad "tar's own stderr was not surfaced in the WARN: $out" ;; esac

# ── 28. PLANTED NEGATIVE: tar exiting 0 while warning on stderr is still a failure ────────
# The fix this test exists for: GNU tar can exit 0 and still warn about a file it
# silently skipped or truncated. `2>/dev/null` threw that warning away and treated
# exit 0 as success outright — a "successful" snapshot that would turn out useless
# on the one day it is needed. This must refuse exactly like a hard failure.
C=$(fixture_memory tar-warns-but-exits-zero)
printf 'LIVE-MEMORY-DIRT\n' >>"$C/memory/note.md"
before=$(git -C "$C" rev-parse HEAD)

shim_dir=$TMP/shim.28
write_tar_shim "$shim_dir" 0 "tar: memory/note.md: file changed as we read it"
snap28=$TMP/snap.28
outfile=$TMP/out.28
old_path=$PATH
PATH="$shim_dir:$PATH"
rc=0
REPO_FF_SNAPSHOT_DIR="$snap28" repo_ff_update "$C" "memory/" >"$outfile" 2>&1 || rc=$?
PATH=$old_path
out=$(cat "$outfile")

[ "$rc" -eq 1 ] && ok || bad "tar exiting 0 with a stderr warning was treated as a successful snapshot (rc=$rc): $out"
[ "$(git -C "$C" rev-parse HEAD)" = "$before" ] && ok || bad "HEAD moved despite tar's exit-0 warning"
grep -q LIVE-MEMORY-DIRT "$C/memory/note.md" \
  && ok || bad "the blocker was touched despite tar's exit-0 warning"
[ -z "${REPO_FF_RECOVERY_ATTEMPTED:-}" ] \
  && ok || bad "REPO_FF_RECOVERY_ATTEMPTED was set despite tar's exit-0 warning"
case "$out" in *"could not write recovery snapshot"*) ok ;; *) bad "an exit-0-with-stderr tar was not treated as a snapshot failure: $out" ;; esac
case "$out" in *"file changed as we read it"*) ok ;; *) bad "tar's exit-0 stderr warning was not surfaced in the WARN: $out" ;; esac

# ── 29. a snapshot listing whose first entry matches early still reads as listed ─────────
# pro-gate round 3 on PR #1653: case 20 failed once in a parallel local run with
# "the snapshot tarball did not list both blocker paths". `tar -tzf | grep -qx
# <first entry>` under pipefail: grep -q exited on the first entry, tar's later
# write took SIGPIPE, and the pipeline read false (28 of 3000 under CPU load).
# The shim widens that window to every run.
lst=$TMP/listing.29
mkdir -p "$lst/memory/sub-a" "$lst/memory/sub-b"
printf 'a\n' >"$lst/memory/sub-a/note.md"
printf 'b\n' >"$lst/memory/sub-b/new.md"
tgz29=$TMP/listing.29.tgz
tar -C "$lst" -czf "$tgz29" -- memory/sub-a/note.md memory/sub-b/new.md
shim_dir=$TMP/shim.29
write_slow_list_tar_shim "$shim_dir"
old_path=$PATH
PATH="$shim_dir:$PATH"
[ "$(tar -tzf "$tgz29")" = $'memory/sub-a/note.md\nmemory/sub-b/new.md' ] \
  && ok || bad "the slow-listing tar shim did not reproduce the real listing"
if tar -tzf "$tgz29" 2>/dev/null | grep -qx 'memory/sub-a/note.md'; then
  bad "the slow-listing tar shim did not break an early-exit grep under pipefail"
else
  ok
fi
tgz_lists "$tgz29" 'memory/sub-a/note.md' 'memory/sub-b/new.md' \
  && ok || bad "tgz_lists missed a listed first entry when grep exits before tar's last write"
PATH=$old_path
if tgz_lists "$tgz29" 'memory/sub-a/note.md' 'memory/sub-c/absent.md'; then
  bad "tgz_lists reported a path the tarball does not list"
else
  ok
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — repo_ff_update: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — repo_ff_update: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
