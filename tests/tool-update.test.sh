#!/usr/bin/env bash
# Tests for scripts/tool-update.sh — the verified installer that replaces four upstream
# installers which all fail OPEN.
#
# Case 2 is the reason this file exists. Every vendor installer in this suite treats an
# unverifiable download as "carry on": xf sets CHECKSUM=SKIP and installs, ru and csctf
# log "Proceeding without verification.", tru checks nothing at all. A mismatch here must
# leave the old binary untouched on disk — not warn, not proceed.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/tool-update.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

mkdir -p "$TMP/bin" "$TMP/rel" "$TMP/backups"

# A fake tool: a script that prints "faketool <version>".
make_tool() { printf '#!/usr/bin/env bash\necho "faketool %s"\n' "$1" >"$2"; chmod +x "$2"; }

# Build a release dir the stub gh will "download" from. $1 = version, $2 = checksum to
# publish (empty => publish a checksum file with no matching entry).
make_release() {
  make_tool "$1" "$TMP/rel/faketool"
  if [ -n "${2:-}" ]; then
    echo "$2  faketool" >"$TMP/rel/SHA256SUMS"
  else
    echo "deadbeef  someotherfile" >"$TMP/rel/SHA256SUMS"
  fi
}

# Stub gh: reports the tag in $TMP/tag as latest, and "downloads" by copying $TMP/rel
# into whatever --dir it was handed. The tag goes through a FILE rather than heredoc
# interpolation — the first version substituted a placeholder with sed and silently
# produced the literal tag "2.0.0_TAG_PLACEHOLDER", which read as a real version gap and
# made the already-current case look like a script bug.
stub_gh() {
  printf '%s' "$1" >"$TMP/tag"
  cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  api) echo "v\$(cat "$TMP/tag")"; exit 0 ;;
  release)
    shift
    if [ "\$1" = "download" ]; then
      d=""; p=""
      for a in "\$@"; do [ "\$p" = "--dir" ] && d="\$a"; p="\$a"; done
      [ -n "\$d" ] && cp "$TMP"/rel/* "\$d/" 2>/dev/null
      exit 0
    fi
    exit 1 ;;
esac
exit 1
EOF
  chmod +x "$TMP/bin/gh"
}

TABLE='
faketool|fake/repo|faketool|SHA256SUMS|raw|faketool|faketool
'

run() {
  PATH="$TMP/bin:$PATH" \
  TOOL_UPDATE_TABLE="$TABLE" \
  TOOL_UPDATE_BIN_DIR="$TMP/bin" \
  TOOL_UPDATE_BACKUP_DIR="$TMP/backups" \
  DRY_RUN="${DRY:-0}" bash "$SCRIPT" 2>&1
}

# ── 1. good checksum: installs, and the live binary really changed ──────────────────────
make_tool 1.0.0 "$TMP/bin/faketool"
make_release 2.0.0 "$(sha256sum "$TMP/rel/faketool" 2>/dev/null | awk '{print $1}')"
# regenerate: make_release rewrote the file, so hash it after writing
make_tool 2.0.0 "$TMP/rel/faketool"; echo "$(sha256sum "$TMP/rel/faketool" | awk '{print $1}')  faketool" >"$TMP/rel/SHA256SUMS"
stub_gh 2.0.0
out=$(run)
case "$out" in *"INSTALLED"*) ok ;; *) bad "good checksum did not install: $out" ;; esac
[ "$("$TMP/bin/faketool")" = "faketool 2.0.0" ] && ok || bad "binary not actually replaced: $("$TMP/bin/faketool")"
[ -f "$TMP/backups/faketool-1.0.0" ] && ok || bad "no backup of the outgoing binary was kept"

# ── 2. CHECKSUM MISMATCH: refuses, and the old binary survives untouched ────────────────
make_tool 2.0.0 "$TMP/bin/faketool"
make_tool 3.0.0 "$TMP/rel/faketool"
echo "0000000000000000000000000000000000000000000000000000000000000000  faketool" >"$TMP/rel/SHA256SUMS"
stub_gh 3.0.0
out=$(run)
case "$out" in *"checksum mismatch"*) ok ;; *) bad "mismatch not detected: $out" ;; esac
case "$out" in *INSTALLED*) bad "installed despite a checksum mismatch" ;; *) ok ;; esac
[ "$("$TMP/bin/faketool")" = "faketool 2.0.0" ] && ok || bad "old binary was clobbered on mismatch"

# ── 3. checksum file present but has no entry for our asset: refuses ────────────────────
make_tool 3.0.0 "$TMP/rel/faketool"
echo "deadbeef  a-different-file" >"$TMP/rel/SHA256SUMS"
stub_gh 3.0.0
out=$(run)
case "$out" in *"no checksum for"*) ok ;; *) bad "missing entry not refused: $out" ;; esac
[ "$("$TMP/bin/faketool")" = "faketool 2.0.0" ] && ok || bad "installed with no checksum entry"

# ── 4. smoke check: a verified but non-running binary is rolled back ────────────────────
printf 'this is not executable bash\x00\x01\x02' >"$TMP/rel/faketool"
echo "$(sha256sum "$TMP/rel/faketool" | awk '{print $1}')  faketool" >"$TMP/rel/SHA256SUMS"
stub_gh 4.0.0
out=$(run)
case "$out" in *"rolled back"*|*"SMOKE FAILED"*) ok ;; *) bad "broken binary not rolled back: $out" ;; esac
[ "$("$TMP/bin/faketool" 2>/dev/null)" = "faketool 2.0.0" ] && ok || bad "rollback did not restore a working binary"

# ── 5. already current: no-op ───────────────────────────────────────────────────────────
make_tool 2.0.0 "$TMP/rel/faketool"
echo "$(sha256sum "$TMP/rel/faketool" | awk '{print $1}')  faketool" >"$TMP/rel/SHA256SUMS"
stub_gh 2.0.0
out=$(run)
case "$out" in *"— current"*) ok ;; *) bad "current version not recognised: $out" ;; esac

# ── 6. installed AHEAD of the newest tag: left alone (the cass rule) ────────────────────
make_tool 9.9.9 "$TMP/bin/faketool"
stub_gh 2.0.0
out=$(run)
case "$out" in *"ahead of release"*) ok ;; *) bad "ahead-of-tag not respected: $out" ;; esac
[ "$("$TMP/bin/faketool")" = "faketool 9.9.9" ] && ok || bad "downgraded a binary that was ahead of the newest tag"

# ── 7. DRY_RUN=1 reports but installs nothing ───────────────────────────────────────────
make_tool 1.0.0 "$TMP/bin/faketool"
make_tool 2.0.0 "$TMP/rel/faketool"
echo "$(sha256sum "$TMP/rel/faketool" | awk '{print $1}')  faketool" >"$TMP/rel/SHA256SUMS"
stub_gh 2.0.0
out=$(DRY=1 run)
case "$out" in *"WARN faketool behind"*) ok ;; *) bad "dry run did not report: $out" ;; esac
[ "$("$TMP/bin/faketool")" = "faketool 1.0.0" ] && ok || bad "DRY_RUN=1 modified the binary"

# ── 8. all tools missing (the systemd-PATH fault): must FAIL, not exit 0 ────────────────
# The first live systemd run on 2026-08-07 found none of the five tools — a user unit
# gets PATH=/usr/local/sbin:...:/bin with no ~/.local/bin — printed "not installed —
# skipped" five times, and exited 0. A green service that did nothing, which is the same
# shape as the cosmetic dcg promote this suite already had. An empty tool list is an
# environment fault, not a clean run.
stub_gh 2.0.0
mkdir -p "$TMP/empty"
# The tool must be absent from BOTH BIN_DIR and PATH, or the PATH fallback finds it and
# this stops testing anything. $TMP/bin keeps the gh stub; only faketool goes.
rm -f "$TMP/bin/faketool"
out=$(TOOL_UPDATE_BIN_DIR="$TMP/empty" PATH="$TMP/bin:/usr/bin:/bin" TOOL_UPDATE_TABLE="$TABLE" \
      TOOL_UPDATE_BACKUP_DIR="$TMP/backups" DRY_RUN=0 bash "$SCRIPT" 2>&1); st=$?
[ "$st" -ne 0 ] && ok || bad "all-tools-missing exited 0 — a no-op run would look healthy"
case "$out" in *"environment fault"*) ok ;; *) bad "all-missing did not name the cause: $out" ;; esac

# ── 9. resolution prefers BIN_DIR over PATH ────────────────────────────────────────────
# Guards the fix itself: a tool present in BIN_DIR must be found even when PATH cannot
# see it, which is exactly the systemd case.
mkdir -p "$TMP/only"
make_tool 1.0.0 "$TMP/only/faketool"
make_tool 2.0.0 "$TMP/rel/faketool"
sha256sum "$TMP/rel/faketool" | awk '{print $1"  faketool"}' >"$TMP/rel/SHA256SUMS"
stub_gh 2.0.0
out=$(TOOL_UPDATE_BIN_DIR="$TMP/only" PATH="$TMP/bin:/usr/bin:/bin" TOOL_UPDATE_TABLE="$TABLE" \
      TOOL_UPDATE_BACKUP_DIR="$TMP/backups" DRY_RUN=1 bash "$SCRIPT" 2>&1)
case "$out" in *"WARN faketool behind"*) ok ;; *) bad "BIN_DIR resolution failed when PATH lacks the tool: $out" ;; esac

# ── 10. backup rotation: newest two per tool survive, by mtime ─────────────────────────
# dotfiles#1279: tool-update.sh backs up the outgoing binary on every install (:181-184)
# and nothing ever reaps one. Live host state was 12 files / 184MB, six of them ubs-*.
# The tools do not share a version scheme, so rotation goes by mtime, not by parsing the
# filename's trailing version string. Neither ubs nor xf is actually installed anywhere
# on this PATH/BIN_DIR, so the tools loop reports both "not installed — skipped" without
# ever touching gh — reap_tool_backups() must still run, because the whole point (per
# the issue) is that it fires once after the loop regardless of $rc.
rotdir="$TMP/rotbackups"; mkdir -p "$rotdir" "$TMP/emptybin"
: > "$rotdir/ubs-1.0.0";  touch -d '3 hours ago' "$rotdir/ubs-1.0.0"
: > "$rotdir/ubs-1.1.0";  touch -d '2 hours ago' "$rotdir/ubs-1.1.0"
: > "$rotdir/ubs-1.2.0";  touch -d '1 hour ago'  "$rotdir/ubs-1.2.0"
: > "$rotdir/xf-0.9.0";   touch -d '5 hours ago' "$rotdir/xf-0.9.0"
ROT_TABLE='
ubs|Dicklesworthstone/ultimate_bug_scanner|ubs|SHA256SUMS|raw|ubs|ubs
xf|Dicklesworthstone/xf|xf-x86_64-unknown-linux-gnu.tar.gz|SHA256SUMS|targz|xf|xf
'
out=$(TOOL_UPDATE_BIN_DIR="$TMP/emptybin" PATH="$TMP/bin:/usr/bin:/bin" TOOL_UPDATE_TABLE="$ROT_TABLE" \
      TOOL_UPDATE_BACKUP_DIR="$rotdir" DRY_RUN=0 bash "$SCRIPT" 2>&1)
[ -f "$rotdir/ubs-1.1.0" ] && ok || bad "rotation removed a newest-two ubs backup (ubs-1.1.0): $out"
[ -f "$rotdir/ubs-1.2.0" ] && ok || bad "rotation removed a newest-two ubs backup (ubs-1.2.0): $out"
if [ -f "$rotdir/ubs-1.0.0" ]; then
  bad "rotation kept a THIRD ubs backup (ubs-1.0.0) instead of the newest two: $out"
else
  ok
fi
[ -f "$rotdir/xf-0.9.0" ] && ok || bad "rotation removed the only xf backup — a single backup must never be touched: $out"
case "$out" in *"reaped ubs-1.0.0"*) ok ;; *) bad "rotation did not report what it removed: $out" ;; esac

# ── 11. backup rotation respects DRY_RUN: reports, removes nothing ─────────────────────
: > "$rotdir/ubs-1.0.0"; touch -d '3 hours ago' "$rotdir/ubs-1.0.0"
out=$(TOOL_UPDATE_BIN_DIR="$TMP/emptybin" PATH="$TMP/bin:/usr/bin:/bin" TOOL_UPDATE_TABLE="$ROT_TABLE" \
      TOOL_UPDATE_BACKUP_DIR="$rotdir" DRY_RUN=1 bash "$SCRIPT" 2>&1)
[ -f "$rotdir/ubs-1.0.0" ] && ok || bad "DRY_RUN=1 actually removed a backup: $out"
case "$out" in *"would reap ubs-1.0.0"*) ok ;; *) bad "DRY_RUN=1 did not report what it would reap: $out" ;; esac

if [ "$fail" -eq 0 ]; then
  echo "ok — tool-update: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — tool-update: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
