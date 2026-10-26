#!/usr/bin/env bash
# Tests for the huggingface lane of scripts/pkg-cache-prune.sh (#380).
#
# The lane exists for one recorded failure mode: hf/xet restarts an interrupted
# download from zero, so a dead download leaves `*.incomplete` partials nothing
# will ever read (32 orphans / 501 GB / disk at 99% in the recorded incident).
# The lane must report ALL partials, delete only ones untouched for >1 day
# (a live download keeps a fresh mtime), and never touch real blobs.
#
# Hermetic, same shape as disk-watermark.test.sh: the script is copied into a
# scratch $TMP/scripts beside a stub notify.sh (say() resolves $HERE/notify.sh
# relative to the SCRIPT's own directory), HOME points at a per-scenario
# fixture home, and pnpm/npm/uv are stubbed first-on-PATH so the three package
# lanes run against no-op stubs instead of this machine's real caches —
# required because the DRY_RUN=0 scenarios here execute for real.
#
# Planted negatives (each verified failing in the inverted state before this
# suite shipped — see the PR for the inversion transcript):
#   - a real blob beside the partial must survive DRY_RUN=0 (invert: widen the
#     delete's -name to '*' and S3/S4 go red);
#   - a fresh partial must survive DRY_RUN=0 and still be REPORTED (invert:
#     drop -mmin +1440 from the delete and S4/S5 go red; make reporting
#     age-gated and S5's "partials: 1" goes red);
#   - the suite must fail wholesale against a script with no hf lane (proves
#     the greps are not vacuous);
#   - the 1-day gate must sit between 12 hours and 2 days (invert: narrow it
#     to -mmin +5 and S4's mid-age partial dies -> red);
#   - a symlinked cache root must be dereferenced (invert: drop find's -H and
#     S7 reports 0 partials while one exists -> red);
#   - the reported byte total must be real (invert: zero the awk sum and S2's
#     "13B total" goes red).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

mkdir -p "$TMP/scripts" "$TMP/bin"
cp "$REPO/scripts/pkg-cache-prune.sh" "$TMP/scripts/pkg-cache-prune.sh"
chmod +x "$TMP/scripts/pkg-cache-prune.sh"

# Stub notify.sh beside the copied script so no scenario can fire the real
# Windows-toast notifier.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/scripts/notify.sh"
chmod +x "$TMP/scripts/notify.sh"

# Stub the three package managers first-on-PATH: their lanes still run (so the
# summary counters behave normally) but against no-ops, never this machine's
# real caches.
for t in pnpm npm uv; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"
  chmod +x "$TMP/bin/$t"
done

OUT=$TMP/out
prune() {  # prune <home> <dry_run>  -> rc; full output in $OUT
  HOME="$1" DRY_RUN="$2" PATH="$TMP/bin:$PATH" \
    bash "$TMP/scripts/pkg-cache-prune.sh" > "$OUT" 2>&1
}

hub() {  # hub <home> -> echoes the blobs dir it created
  local d="$1/.cache/huggingface/hub/models--x--y/blobs"
  mkdir -p "$d"
  echo "$d"
}

# ---- S1: missing ~/.cache/huggingface is skipped, not a failure -------------
H0=$TMP/h0; mkdir -p "$H0"
prune "$H0" 1; rc=$?
[ "$rc" = 0 ] && ok || bad "S1: rc=$rc for a missing HF cache, wanted 0"
grep -q '## huggingface cache' "$OUT" && ok || bad "S1: hf lane never printed its header"
grep -q 'huggingface not present — skipped' "$OUT" && ok || bad "S1: no skip line for missing cache dir"
grep -q 'FAILED' "$OUT" && bad "S1: a lane reported FAILED" || ok

# ---- S2: planted negative, DRY_RUN=1 — reported, nothing deleted ------------
H1=$TMP/h1; B1=$(hub "$H1")
printf 'partial-bytes' > "$B1/abc.incomplete"
touch -d '2 days ago' "$B1/abc.incomplete"
# The blob is aged too, and that is load-bearing: a real hub blob is weeks old,
# and a fresh fixture blob would hide a widened -name filter behind the -mmin
# age gate — inversion B (delete -name widened to '*') passed the suite until
# the blob predated the gate.
printf 'realdata' > "$B1/0123456789abcdef"
touch -d '2 days ago' "$B1/0123456789abcdef"
prune "$H1" 1; rc=$?
[ "$rc" = 0 ] && ok || bad "S2: rc=$rc, wanted 0"
grep -q 'partials: 1 .incomplete' "$OUT" && ok || bad "S2: aged partial not reported"
grep -q '13B total' "$OUT" && ok || bad "S2: byte total not reported (the 13-byte partial must show as 13B)"
sed -n '/## huggingface cache/,/^$/p' "$OUT" | grep -q 'current: [0-9]' && ok || bad "S2: hf section reports no cache size (AC 1)"
grep -q 'eligible (untouched >1d): 1' "$OUT" && ok || bad "S2: aged partial not counted eligible"
grep -q 'would: find' "$OUT" && ok || bad "S2: dry run printed no deletion plan"
[ -f "$B1/abc.incomplete" ] && ok || bad "S2: DRY RUN deleted the partial"
[ -f "$B1/0123456789abcdef" ] && ok || bad "S2: DRY RUN deleted the blob"

# ---- S3: planted negative, DRY_RUN=0 — partial removed, blob untouched ------
prune "$H1" 0; rc=$?
[ "$rc" = 0 ] && ok || bad "S3: rc=$rc, wanted 0"
[ ! -f "$B1/abc.incomplete" ] && ok || bad "S3: aged .incomplete partial survived DRY_RUN=0"
[ -f "$B1/0123456789abcdef" ] && ok || bad "S3: the real blob was DELETED"
[ "$(cat "$B1/0123456789abcdef" 2>/dev/null)" = 'realdata' ] && ok || bad "S3: blob content changed"
grep -q 'ok: find' "$OUT" && ok || bad "S3: delete pass did not report ok"

# ---- S4: age guard — fresh partial survives, is still reported --------------
H2=$TMP/h2; B2=$(hub "$H2")
printf 'p' > "$B2/old.incomplete";   touch -d '2 days ago' "$B2/old.incomplete"
printf 'p' > "$B2/fresh.incomplete"  # mtime now = a download in flight
# mid pins the gate's VALUE, not just its existence: 12h old is inside the
# 1-day window, so it must survive — a gate silently narrowed to minutes
# (-mmin +5 still passes an age-0-vs-2-days-only suite) deletes it and goes
# red here. Together with old (2 days, must die) this pins 12h < gate <= 2d.
printf 'p' > "$B2/mid.incomplete";   touch -d '12 hours ago' "$B2/mid.incomplete"
printf 'realdata' > "$B2/blob";      touch -d '2 days ago' "$B2/blob"  # aged: see S2
prune "$H2" 0; rc=$?
[ "$rc" = 0 ] && ok || bad "S4: rc=$rc, wanted 0"
grep -q 'partials: 3 .incomplete' "$OUT" && ok || bad "S4: reporting missed a partial (must count all, age-gated or not)"
grep -q 'eligible (untouched >1d): 1' "$OUT" && ok || bad "S4: eligibility count wrong (only the 2-day partial is past the gate)"
[ ! -f "$B2/old.incomplete" ] && ok || bad "S4: aged partial survived"
[ -f "$B2/fresh.incomplete" ] && ok || bad "S4: fresh partial (simulated live download) was DELETED"
[ -f "$B2/mid.incomplete" ] && ok || bad "S4: 12h-old partial was DELETED (gate narrower than designed)"
[ -f "$B2/blob" ] && ok || bad "S4: blob was deleted"

# ---- S5: fresh-only — reported nonzero, nothing deleted, exit 0 -------------
H3=$TMP/h3; B3=$(hub "$H3")
printf 'p' > "$B3/fresh.incomplete"
prune "$H3" 1; rc=$?
[ "$rc" = 0 ] && ok || bad "S5: rc=$rc, wanted 0"
grep -q 'partials: 1 .incomplete' "$OUT" && ok || bad "S5: reported 0 while a partial exists (the issue's explicit failure mode)"
grep -q 'eligible (untouched >1d): 0' "$OUT" && ok || bad "S5: fresh partial counted eligible"
grep -q 'nothing eligible' "$OUT" && ok || bad "S5: no held-back note"
prune "$H3" 0; rc=$?
[ "$rc" = 0 ] && ok || bad "S5: rc=$rc on apply, wanted 0"
[ -f "$B3/fresh.incomplete" ] && ok || bad "S5: fresh partial deleted under DRY_RUN=0"

# ---- S6: zero partials reads as none ----------------------------------------
H4=$TMP/h4; B4=$(hub "$H4")
printf 'realdata' > "$B4/blob"
prune "$H4" 1; rc=$?
[ "$rc" = 0 ] && ok || bad "S6: rc=$rc, wanted 0"
grep -q 'partials: none' "$OUT" && ok || bad "S6: empty cache did not report 'partials: none'"

# ---- S7: symlinked cache root — dereferenced, reported, reclaimed -----------
# ~/.cache/huggingface relocated to another disk and symlinked back is the
# usual post-disk-full layout. test -d dereferences the link, but default -P
# find/du given the symlink as their path argument do NOT descend — without
# -H the lane reports 'partials: none' forever while orphans sit untouched
# (the issue's explicit "reports 0 when a partial exists" failure mode).
H5=$TMP/h5; mkdir -p "$H5/.cache"
REAL=$TMP/real-hf-store
mkdir -p "$REAL/hub/models--x--y/blobs"
B5=$REAL/hub/models--x--y/blobs
printf 'partial-bytes' > "$B5/abc.incomplete"; touch -d '2 days ago' "$B5/abc.incomplete"
printf 'realdata' > "$B5/blob";                touch -d '2 days ago' "$B5/blob"
ln -s "$REAL" "$H5/.cache/huggingface"
prune "$H5" 1; rc=$?
[ "$rc" = 0 ] && ok || bad "S7: rc=$rc, wanted 0"
grep -q 'partials: 1 .incomplete' "$OUT" && ok || bad "S7: symlinked cache root reported 0 partials while one exists"
prune "$H5" 0; rc=$?
[ "$rc" = 0 ] && ok || bad "S7: rc=$rc on apply, wanted 0"
[ ! -f "$B5/abc.incomplete" ] && ok || bad "S7: partial behind the symlink survived DRY_RUN=0"
[ -f "$B5/blob" ] && ok || bad "S7: blob behind the symlink was DELETED"

if [ "$fail" -eq 0 ]; then
  echo "ok — pkg-cache-prune huggingface lane: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — pkg-cache-prune huggingface lane: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
