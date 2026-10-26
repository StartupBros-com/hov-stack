#!/usr/bin/env bash
# Hermetic tests for cass-release-promote.sh.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# Never run beside the real notify.sh, or inherit the operator's archive/unit dirs.
mkdir -p "$TMP/bin" "$TMP/lib" "$TMP/state" "$TMP/release/root" "$TMP/scripts" \
  "$TMP/home" "$TMP/config" "$TMP/units" "$TMP/scratch"
cp "$REPO/scripts/cass-release-promote.sh" "$REPO/scripts/cass-search-health.sh" "$TMP/scripts/"
SCRIPT=$TMP/scripts/cass-release-promote.sh
export HOME=$TMP/home XDG_CONFIG_HOME=$TMP/config XDG_STATE_HOME=$TMP/state TMPDIR=$TMP/scratch
cat >"$TMP/scripts/notify.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/said"
EOF
chmod +x "$TMP/scripts/notify.sh"
# Record timeout argv but keep its real TERM/kill-after behavior. Only the
# no-argument mktemp used by the health helper can be made unevaluable.
cat >"$TMP/bin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/timeouts"
exec /usr/bin/timeout "\$@"
EOF
cat >"$TMP/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [ "${TEST_HEALTH_SETUP_FAIL:-0}" = 1 ] && [ "$#" = 0 ]; then exit 1; fi
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$TMP/bin/timeout" "$TMP/bin/mktemp"
for tool in pgrep systemctl; do
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/$tool"
  chmod +x "$TMP/bin/$tool"
done

make_cass() {
  local version=$1 path=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
# status/search are probed against a scratch --db. A healthy fixture must report
# .data_dir as that scratch parent, because the smoke asserts it to prove the
# isolation held -- without modelling it here the fixture is rejected for
# "scratch --db did not isolate data_dir". \$* is assigned to a scalar first:
# \${*#pat} applies the removal to EACH positional parameter, silently handing
# back the whole arg list.
all="\$*"
db=""
case "\$all" in
  *"--db "*) db=\${all#*--db }; db=\${db%% *} ;;
esac
# Real cass accepts global flags before OR after the subcommand (0.8.0
# auto-corrects to flags-first and says so on stderr), so the verb is not
# reliably \$1. Dispatching on position made this stub answer a
# '--db X status' call with the catch-all branch. Scan for the verb instead.
verb=""
case " \$all " in
  *" --version "*) verb=--version ;;
  *" capabilities "*) verb=capabilities ;;
  *" health "*) verb=health ;;
  *" status "*) verb=status ;;
  *" search "*) verb=search ;;
esac
term='' previous='' maintenance=0 mode=''
for arg in "\$@"; do
  [ "\$previous" = search ] && term=\$arg
  [ "\$previous" = --mode ] && mode=\$arg
  [ "\$arg" = --no-maintenance ] && maintenance=1
  previous=\$arg
 done
printf '%s|%s|%s|%s|%s|%s|%s\n' "\$0" "\$db" "\$verb" "\$term" "\${CASS_AUTO_REFRESH:-unset}" "\$maintenance" "\$mode" >> "$TMP/calls"
case "\$verb" in
  --version) echo "cass $version" ;;
  capabilities)
      [ "\${TEST_CANDIDATE_FAIL:-0}" = 1 ] && { echo 'broken candidate' >&2; exit 4; }
      if [ "\${TEST_POST_FAIL:-0}" = 1 ] && [ "\$0" = "$TMP/bin/cass" ]; then
        echo 'post-promotion capabilities failure' >&2; exit 4
      fi
      echo '{"version":"$version","ok":true}' ;;
  health) echo '{"status":"healthy"}' ;;
  status)
      if [ -n "\$db" ]; then
        printf '{"status":"healthy","index":{"fresh":true},"data_dir":"%s"}\n' "\$(dirname "\$db")"
      else
        echo '{"status":"healthy","index":{"fresh":true}}'
      fi ;;
  search)
      if [ -n "\$db" ]; then
        echo '{"hits":[],"total_matches":0}'
      else
        case "\${TEST_LIVE_MODE:-healthy}" in
          empty) echo '{"hits":[],"total_matches":0}'; exit 0 ;;
          malformed) echo 'not search JSON'; exit 0 ;;
          nonzero) printf 'search failed: %0300d\n' 0 >&2; exit 9 ;;
          custom) [ "\$term" = beta ] && { echo '{"hits":[]}'; exit 0; } ;;
          slow) sleep 2 ;;
        esac
        echo '{"hits":[{}],"total_matches":1}'
      fi ;;
  *) echo 'fixture search' ;;
esac
EOF
  chmod +x "$path"
}

make_release() {
  local version=$1
  rm -rf "$TMP/release/root/cass" "$TMP/release/cass-linux-amd64.tar.gz" "$TMP/release/cass-linux-amd64.tar.gz.sha256"
  make_cass "$version" "$TMP/release/root/cass"
  tar -czf "$TMP/release/cass-linux-amd64.tar.gz" -C "$TMP/release/root" cass
  sha256sum "$TMP/release/cass-linux-amd64.tar.gz" | awk '{print $1"  cass-linux-amd64.tar.gz"}' >"$TMP/release/cass-linux-amd64.tar.gz.sha256"
}

stub_gh() {
  local tag=$1 published=${2:-2026-08-11T19:27:28Z}
  cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gh-calls"
[ "\${TEST_OFFLINE:-0}" = 1 ] && exit 1
case "\$1 \$2" in
  "api repos/Dicklesworthstone/coding_agent_session_search/releases/latest")
    printf '%s\n' '{"tag_name":"$tag","published_at":"$published"}' ;;
  "api repos/Dicklesworthstone/coding_agent_session_search/git/ref/tags/$tag")
    printf '%s\n' '{"object":{"sha":"commit-$tag","type":"commit"}}' ;;
  "release download")
    d=''
    previous=''
    for arg in "\$@"; do
      [ "\$previous" = --dir ] && d="\$arg"
      previous="\$arg"
    done
    cp "$TMP/release/cass-linux-amd64.tar.gz" "$TMP/release/cass-linux-amd64.tar.gz.sha256" "\$d/" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
}

run() {
  : > "$TMP/calls"; : > "$TMP/timeouts"; : > "$TMP/said"; : > "$TMP/gh-calls"
  PATH="$TMP/bin:/usr/bin:/bin" \
  CASS_BIN_DIR="$TMP/bin" CASS_RELEASE_LIB="$TMP/lib" CASS_RELEASE_STATE="$TMP/state" \
  CASS_RELEASE_UNIT_DIR="$TMP/units" CASS_PIN_FILE="$TMP/pin.sh" DRY_RUN="${DRY:-0}" "$SCRIPT" 2>&1
}

cat >"$TMP/pin.sh" <<EOF
CASS_PIN_SHA=PLACEHOLDER
CASS_PIN_COMMIT=f6c3146b
CASS_PIN_DATE=2026-08-04
EOF

# gh is stubbed, but the script needs the real jq/sha256sum/tar/timeout.
make_cass 0.6.23 "$TMP/bin/cass"
old_hash=$(sha256sum "$TMP/bin/cass" | awk '{print $1}')
sed -i "s/PLACEHOLDER/$old_hash/" "$TMP/pin.sh"
make_release 0.6.24
stub_gh v0.6.24

# 1. Dry-run resolves candidate but does not install or create provenance.
out=$(DRY=1 run)
case "$out" in *'candidate v0.6.24@commit-v0.6.24'*) ok ;; *) bad "dry-run did not resolve exact candidate: $out" ;; esac
[ ! -e "$TMP/state/provenance.json" ] && ok || bad "dry-run mutated provenance"
[ ! -e "$TMP/state/last-check.json" ] && ok || bad "dry-run mutated check receipt"
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.23' ] && ok || bad "dry-run changed live binary"

# 2. Valid candidate promotes and records provenance.
out=$(DRY=0 run)
case "$out" in *'PROMOTED cass main@f6c3146b -> v0.6.24@commit-v0.6.24'*) ok ;; *) bad "valid candidate did not promote: $out" ;; esac
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.24' ] && ok || bad "candidate not live after promotion"
jq -e '.source_kind == "tag" and .source_ref == "v0.6.24" and .commit == "commit-v0.6.24"' "$TMP/state/provenance.json" >/dev/null 2>&1 && ok || bad "provenance missing release tuple"
jq -e '.outcome == "promoted" and .tag == "v0.6.24" and .commit == "commit-v0.6.24"' "$TMP/state/last-check.json" >/dev/null 2>&1 && ok || bad "promotion receipt missing release tuple"

# 3. Accepted tag is a no-op and keeps the binary untouched.
out=$(DRY=0 run)
case "$out" in *'v0.6.24 (commit-v0.6.24) — current'*) ok ;; *) bad "accepted tag was not current: $out" ;; esac
jq -e '.outcome == "current" and .tag == "v0.6.24"' "$TMP/state/last-check.json" >/dev/null 2>&1 && ok || bad "current receipt was not refreshed"

# 4. Checksum mismatch refuses and preserves the live binary.
make_cass 0.6.25 "$TMP/release/root/cass"
tar -czf "$TMP/release/cass-linux-amd64.tar.gz" -C "$TMP/release/root" cass
printf '%064d  cass-linux-amd64.tar.gz\n' 0 >"$TMP/release/cass-linux-amd64.tar.gz.sha256"
# Genuinely newer publication date: this case tests the CHECKSUM gate, so it has
# to get past the backwards-move guard that case 8 exercises.
stub_gh v0.6.25 2026-09-01T00:00:00Z
out=$(DRY=0 run)
case "$out" in *'checksum mismatch'*) ok ;; *) bad "checksum mismatch not rejected: $out" ;; esac
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.24' ] && ok || bad "checksum failure changed live binary"

# 5. Pin drift refuses before release download.
make_cass 0.6.23 "$TMP/bin/cass"
# Restore the old hash mismatch deliberately.
printf 'CASS_PIN_SHA=not-the-live-hash\nCASS_PIN_COMMIT=f6c3146b\nCASS_PIN_DATE=2026-08-04\n' >"$TMP/pin.sh"
stub_gh v0.6.24
out=$(DRY=0 run)
case "$out" in *'does not match recorded/bootstrap provenance'*) ok ;; *) bad "pin drift was not rejected: $out" ;; esac

# 6. Unsafe archive member is rejected before extraction.
rm -f "$TMP/state/provenance.json"
make_cass 0.6.23 "$TMP/bin/cass"
old_hash=$(sha256sum "$TMP/bin/cass" | awk '{print $1}')
printf 'CASS_PIN_SHA=%s\nCASS_PIN_COMMIT=f6c3146b\nCASS_PIN_DATE=2026-08-04\n' "$old_hash" >"$TMP/pin.sh"
mkdir -p "$TMP/unsafe/root"
make_cass 0.6.24 "$TMP/unsafe/root/cass"
# GNU tar strips `../` on creation, so build a traversal header explicitly.
python3 - "$TMP/release/cass-linux-amd64.tar.gz" <<'PY'
import io, tarfile, sys
out = sys.argv[1]
with tarfile.open(out, 'w:gz') as tf:
    data = b'#!/bin/sh\necho cass 0.6.26\n'
    safe = tarfile.TarInfo('cass')
    safe.mode = 0o755
    safe.size = len(data)
    tf.addfile(safe, io.BytesIO(data))
    bad = tarfile.TarInfo('../escape')
    bad.size = 0
    tf.addfile(bad)
PY
sha256sum "$TMP/release/cass-linux-amd64.tar.gz" | awk '{print $1"  cass-linux-amd64.tar.gz"}' >"$TMP/release/cass-linux-amd64.tar.gz.sha256"
stub_gh v0.6.26
out=$(DRY=0 run)
case "$out" in *'archive contains unsafe members'*|*'expected one executable'*) ok ;; *) bad "unsafe/malformed archive was not rejected: $out" ;; esac

# 7. Existing active index defers without download/install.
rm -f "$TMP/state/provenance.json"
make_release 0.6.24
stub_gh v0.6.24
make_cass 0.6.23 "$TMP/bin/cass"
old_hash=$(sha256sum "$TMP/bin/cass" | awk '{print $1}')
printf 'CASS_PIN_SHA=%s\nCASS_PIN_COMMIT=f6c3146b\nCASS_PIN_DATE=2026-08-04\n' "$old_hash" >"$TMP/pin.sh"
mkdir -p "$TMP/home/.local/share/coding-agent-search"
printf 'pid=%s\n' "$$" >"$TMP/home/.local/share/coding-agent-search/index-run.lock"
out=$(HOME="$TMP/home" DRY=0 run)
case "$out" in *'promotion deferred'*) ok ;; *) bad "active index was not deferred: $out" ;; esac
rm -f "$TMP/home/.local/share/coding-agent-search/index-run.lock"

# 8. PLANTED NEGATIVE: an OLDER "latest" release must never be promoted.
# If upstream yanks a release or re-points "latest" at an earlier tag, the
# accepted-tag equality check does not match. An earlier draft applied the
# backwards-move guard only to `main` provenance, so this case sailed through
# every checksum and smoke gate and promoted a DOWNGRADE. Fails closed now, and
# must not even reach the network.
rm -f "$TMP/state/provenance.json" "$TMP/state/last-check.json"
make_cass 0.6.24 "$TMP/bin/cass"
live_hash=$(sha256sum "$TMP/bin/cass" | awk '{print $1}')
jq -n --arg sha "$live_hash" \
  '{schema_version:1,source_kind:"tag",source_ref:"v0.6.24",commit:"commit-v0.6.24",release_date:"2026-08-11T19:27:28Z",binary_sha256:$sha}' \
  >"$TMP/state/provenance.json"
# Newer-sounding tag, OLDER publication date — the yank/re-point shape.
stub_gh v0.6.25 2026-08-01T00:00:00Z
# Any download attempt is itself the failure, so make the release unfetchable.
rm -f "$TMP/release/cass-linux-amd64.tar.gz" "$TMP/release/cass-linux-amd64.tar.gz.sha256"
out=$(DRY=0 run)
case "$out" in *'is newer than or equal to v0.6.25'*) ok ;; *) bad "older 'latest' release was not refused: $out" ;; esac
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.24' ] && ok || bad "older release changed the live binary"
jq -e '.source_ref == "v0.6.24"' "$TMP/state/provenance.json" >/dev/null 2>&1 && ok || bad "older release overwrote provenance"
jq -e '.outcome == "ahead" and .tag == "v0.6.25"' "$TMP/state/last-check.json" >/dev/null 2>&1 && ok || bad "refusal did not record an 'ahead' receipt"

# 8b. EQUAL publication dates are ambiguous, and ambiguity fails closed.
# Two different tags sharing a published_at give no ordering evidence, so the
# guard refuses rather than guessing. Cost of a false refusal is one day plus a
# visible 'ahead' line in the weekly report; cost of a wrong guess is a silent
# downgrade. This assertion exists so the strictness stays deliberate.
stub_gh v0.6.25 2026-08-11T19:27:28Z
out=$(DRY=0 run)
case "$out" in *'is newer than or equal to v0.6.25'*) ok ;; *) bad "equal-date release was not refused: $out" ;; esac
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.24' ] && ok || bad "equal-date release changed the live binary"

# 9. A live binary that fails its read-only smoke must NOT get a success receipt.
rm -f "$TMP/state/last-check.json"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "cass 0.6.24" ;; *) exit 3 ;; esac\n' >"$TMP/bin/cass"
chmod +x "$TMP/bin/cass"
broken_hash=$(sha256sum "$TMP/bin/cass" | awk '{print $1}')
jq -n --arg sha "$broken_hash" \
  '{schema_version:1,source_kind:"tag",source_ref:"v0.6.24",commit:"commit-v0.6.24",release_date:"2026-08-11T19:27:28Z",binary_sha256:$sha}' \
  >"$TMP/state/provenance.json"
stub_gh v0.6.24
out=$(DRY=0 run)
case "$out" in *'failed its read-only smoke'*) ok ;; *) bad "broken live binary was not caught: $out" ;; esac
[ ! -e "$TMP/state/last-check.json" ] && ok || bad "a failing live smoke still wrote a success receipt"

# Reuse the same fixture setup for promotion and advisory outcomes; the source
# helper remains real. Each case owns its binaries, receipts and notification log.
seed_live() {
  rm -f "$TMP/bin/cass" "$TMP/state/provenance.json" "$TMP/state/last-check.json"
  make_cass 0.6.23 "$TMP/bin/cass"
  old_hash=$(sha256sum "$TMP/bin/cass" | awk '{print $1}')
  printf 'CASS_PIN_SHA=%s\nCASS_PIN_COMMIT=f6c3146b\nCASS_PIN_DATE=2026-08-04\n' "$old_hash" >"$TMP/pin.sh"
  make_release 0.6.24
  stub_gh v0.6.24
}

# Wrong inherited override must never substitute a different binary's health.
cat >"$TMP/wrong-health-bin" <<EOF
#!/usr/bin/env bash
printf 'wrong binary queried\n' >> "$TMP/wrong-health-used"
exit 9
EOF
chmod +x "$TMP/wrong-health-bin"
export CASS_HEALTH_BIN=$TMP/wrong-health-bin CASS_AUTO_REFRESH=1

# Healthy archive: all five ACTUAL terms, once for the downloaded candidate and
# again for the promoted live path; scratch searches deliberately stay empty.
seed_live
out=$(run); rc=$?
[ "$rc" = 0 ] && ok || bad "healthy promotion failed: $out"
case "$out" in *'PROMOTED cass '*) ok ;; *) bad "healthy candidate not promoted: $out" ;; esac
if grep -qF 'live archive degraded' "$TMP/said"; then bad "healthy archive notified degradation"; else ok; fi
expected=$(printf '%s\n' error test file commit function error test file commit function)
actual=$(awk -F'|' '$2 == "" && $3 == "search" {print $4}' "$TMP/calls")
[ "$actual" = "$expected" ] && ok || bad "not all five real terms ran in both advisories: $actual"
awk -F'|' -v scratch="$TMP/scratch/" -v live="$TMP/bin/cass" '
  $2 == "" && $3 == "search" {
    n++; if (n <= 5 ? index($1,scratch) != 1 : $1 != live) wrong=1
    if ($5 != "0" || $6 != "1" || $7 != "lexical") wrong=1
  }
  END {exit !(n == 10 && !wrong)}' "$TMP/calls" && ok || bad "wrong binary or unsafe live search argv/env"
awk -F'|' '$2 == "" && $3 == "status" {n++; if ($5 != "0") wrong=1} END {exit !(n == 2 && !wrong)}' \
  "$TMP/calls" && ok || bad "live status did not suppress auto-refresh locally"
[ ! -e "$TMP/wrong-health-used" ] && ok || bad "inherited CASS_HEALTH_BIN overrode candidate"
[ "$(grep -cF -- '-k 5 30 ' "$TMP/timeouts")" = 10 ] && ok || bad "advisory default query timeout is not 30s"

# Receipt semantics on a current binary: binary smoke ran, not a new install.
out=$(run); rc=$?
[ "$rc" = 0 ] && ok || bad "current live check failed: $out"
case "$out" in *'— current'*) ok ;; *) bad "current anchor disappeared: $out" ;; esac
[ "$(awk -F'|' '$2 == "" && $3 == "search" {n++} END {print n+0}' "$TMP/calls")" = 5 ] && ok || bad "current path did not query archive"
if grep -qF 'live archive degraded' "$TMP/said"; then bad "healthy current archive notified degradation"; else ok; fi
jq -e '.outcome == "current" and .schema_version == 1 and (keys | length) == 6' "$TMP/state/last-check.json" >/dev/null \
  && ok || bad "current binary receipt changed meaning/schema"

# Current/ahead active-index skips preserve a prior receipt byte-for-byte, and
# do not run status/search, download anything, or claim archive health.
cp "$TMP/state/last-check.json" "$TMP/before-check.json"
printf 'pid=%s\n' "$$" >"$TMP/home/.local/share/coding-agent-search/index-run.lock"
for outcome in current ahead; do
  [ "$outcome" = ahead ] && stub_gh v0.6.25 2026-08-01T00:00:00Z
  out=$(run); rc=$?
  [ "$rc" = 0 ] && ok || bad "active $outcome returned $rc: $out"
  case "$out" in *'live check skipped: an index run is active; no receipt written;'*'archive health not evaluated'*) ok ;; *) bad "active $outcome skip not explicit: $out" ;; esac
  cmp -s "$TMP/before-check.json" "$TMP/state/last-check.json" && ok || bad "active $outcome altered receipt"
  if grep -E '\|(status|search)\|' "$TMP/calls"; then bad "active $outcome probed archive"; else ok; fi
  if grep -qF 'release download' "$TMP/gh-calls"; then bad "active $outcome downloaded"; else ok; fi
done
rm -f "$TMP/home/.local/share/coding-agent-search/index-run.lock"

# Ahead can attest binary smoke while reporting a degraded live archive.
out=$(TEST_LIVE_MODE=empty run); rc=$?
[ "$rc" = 0 ] && ok || bad "degraded ahead archive failed lane: $out"
grep -qF 'live archive degraded' "$TMP/said" && ok || bad "ahead degraded archive was silent"
jq -e '.outcome == "ahead"' "$TMP/state/last-check.json" >/dev/null && ok || bad "ahead binary receipt missing"
[ "$(awk -F'|' '$2 == "" && $3 == "search" {n++} END {print n+0}' "$TMP/calls")" = 5 ] && ok || bad "ahead archive not queried"

# Each unhealthy/unevaluable condition is visible but cannot reject or roll back
# a candidate that passed hermetic gates, before OR after the live-link swap.
for mode in empty malformed nonzero unevaluable unavailable; do
  seed_live
  setup_fail=0
  [ "$mode" = unevaluable ] && setup_fail=1
  [ "$mode" = unavailable ] && mv "$TMP/scripts/cass-search-health.sh" "$TMP/helper-saved"
  out=$(TEST_LIVE_MODE="$mode" TEST_HEALTH_SETUP_FAIL="$setup_fail" run); rc=$?
  [ "$mode" = unavailable ] && mv "$TMP/helper-saved" "$TMP/scripts/cass-search-health.sh"
  [ "$rc" = 0 ] && ok || bad "$mode advisory rejected candidate: $out"
  case "$out" in *'PROMOTED cass '*) ok ;; *) bad "$mode archive blocked promotion: $out" ;; esac
  [ "$(readlink -f "$TMP/bin/cass")" = "$TMP/lib/v0.6.24/cass" ] && ok || bad "$mode archive rolled back binary"
  [ "$(grep -cF 'live archive degraded' "$TMP/said")" = 2 ] && ok || bad "$mode did not notify both advisories"
  awk '/live archive degraded/ && length($0) > 280 {bad=1} END {exit bad}' "$TMP/said" && ok || bad "$mode notification detail unbounded"
  jq -e '.outcome == "promoted" and .schema_version == 1 and (keys | length) == 6' "$TMP/state/last-check.json" >/dev/null \
    && ok || bad "$mode lost binary smoke receipt or changed schema"
  jq -e '.source_ref == "v0.6.24"' "$TMP/state/provenance.json" >/dev/null && ok || bad "$mode lost candidate provenance"
  case "$mode" in
    empty) detail='ZERO results' ;;
    malformed) detail='not cass search JSON' ;;
    nonzero) detail='exit=9' ;;
    unevaluable) detail='cannot evaluate — mktemp failed' ;;
    unavailable) detail='cannot evaluate — helper unavailable' ;;
  esac
  case "$out" in *"$detail"*) ok ;; *) bad "$mode did not surface query evidence: $out" ;; esac
  if [ "$mode" = unevaluable ] || [ "$mode" = unavailable ]; then
    case "$out" in *'live search probe degraded (exit 2)'*) ok ;; *) bad "$mode evaluation was not exit 2: $out" ;; esac
  fi
done

# Existing controls remain controls: two of three custom terms may pass, and
# raising MIN_OK to three degrades only the advisory on the current binary.
seed_live
out=$(TEST_LIVE_MODE=custom CASS_HEALTH_TERMS='alpha beta gamma' CASS_HEALTH_MIN_OK=2 CASS_HEALTH_QUERY_TIMEOUT=7 run); rc=$?
[ "$rc" = 0 ] && ok || bad "custom control promotion failed: $out"
if grep -qF 'live archive degraded' "$TMP/said"; then bad "custom 2/3 threshold was ignored"; else ok; fi
expected=$(printf '%s\n' alpha beta gamma alpha beta gamma)
actual=$(awk -F'|' '$2 == "" && $3 == "search" {print $4}' "$TMP/calls")
[ "$actual" = "$expected" ] && ok || bad "custom terms ignored: $actual"
[ "$(grep -cF -- '-k 5 7 ' "$TMP/timeouts")" = 6 ] && ok || bad "custom query timeout ignored"
out=$(TEST_LIVE_MODE=custom CASS_HEALTH_TERMS='alpha beta gamma' CASS_HEALTH_MIN_OK=3 run); rc=$?
[ "$rc" = 0 ] && ok || bad "custom threshold gated current receipt: $out"
grep -qF 'live archive degraded' "$TMP/said" && ok || bad "custom 3/3 threshold ignored"
jq -e '.outcome == "current"' "$TMP/state/last-check.json" >/dev/null && ok || bad "degraded current binary receipt missing"
# Exercise the real timeout, not just its recorded argument spelling.
out=$(TEST_LIVE_MODE=slow CASS_HEALTH_TERMS=alpha CASS_HEALTH_MIN_OK=1 CASS_HEALTH_QUERY_TIMEOUT=0.1 run); rc=$?
[ "$rc" = 0 ] && ok || bad "query timeout gated current check: $out"
case "$out" in *'exit=124'*) ok ;; *) bad "custom query timeout did not fire: $out" ;; esac
grep -qF 'live archive degraded' "$TMP/said" && ok || bad "timed-out query did not notify"
[ ! -e "$TMP/wrong-health-used" ] && ok || bad "advisory used inherited wrong binary"

# Offline and active promotion cannot issue a new receipt or probe an archive.
seed_live
out=$(TEST_OFFLINE=1 run); rc=$?
[ "$rc" = 0 ] && ok || bad "offline discovery failed: $out"
case "$out" in *'latest release unknown (offline); leaving current binary in place;'*'archive health not evaluated'*) ok ;; *) bad "offline skip not explicit: $out" ;; esac
[ ! -e "$TMP/state/last-check.json" ] && [ ! -s "$TMP/calls" ] && ok || bad "offline path wrote a receipt/probed binary"
printf 'pid=%s\n' "$$" >"$TMP/home/.local/share/coding-agent-search/index-run.lock"
out=$(run); rc=$?
[ "$rc" = 0 ] && ok || bad "active promotion failed: $out"
case "$out" in *'promotion deferred — an index run is active; no files changed;'*'archive health not evaluated'*) ok ;; *) bad "active promotion skip not explicit: $out" ;; esac
[ ! -e "$TMP/state/last-check.json" ] && ok || bad "active promotion wrote receipt"
if grep -E '\|(status|search)\|' "$TMP/calls"; then bad "active promotion probed archive"; else ok; fi
if grep -qF 'release download' "$TMP/gh-calls"; then bad "active promotion downloaded"; else ok; fi
rm -f "$TMP/home/.local/share/coding-agent-search/index-run.lock"

# Candidate faults still reject, while a post-promotion binary failure still
# rolls back: only live archive health was removed from the verdict.
out=$(TEST_CANDIDATE_FAIL=1 run); rc=$?
[ "$rc" = 0 ] && ok || bad "candidate refusal should exit 0: $out"
case "$out" in *'REJECTED cass-release-promote:'*'capabilities'*) ok ;; *) bad "candidate fault not refused: $out" ;; esac
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.23' ] && [ ! -e "$TMP/state/last-check.json" ] && ok || bad "refused candidate changed live binary/receipt"
out=$(TEST_POST_FAIL=1 run); rc=$?
[ "$rc" = 1 ] && ok || bad "post-promotion binary fault should exit 1: $out"
case "$out" in *'post-promotion smoke failed'*'rolled back'*) ok ;; *) bad "binary failure not rolled back: $out" ;; esac
[ "$("$TMP/bin/cass" --version)" = 'cass 0.6.23' ] && ok || bad "rollback did not restore old binary"
[ ! -e "$TMP/state/provenance.json" ] && [ ! -e "$TMP/state/last-check.json" ] && ok || bad "rollback left candidate provenance/receipt"

# 10. The unit keeps the live-archive advisory search from starting a rebuild.
# On cass 0.9.0 a search against an unusable, over-budget lexical index spawns a
# detached `cass index --full --background` unless CASS_AUTO_REFRESH is off, and
# the knob only reaches the script if it sits in [Service].
awk '/^\[/ {section=$0} section == "[Service]" && $0 == "Environment=CASS_AUTO_REFRESH=0" {found=1} END {exit !found}' \
  "$REPO/systemd/cass-release-promote.service" && ok || bad "promote unit does not set CASS_AUTO_REFRESH=0 in [Service]"

if [ "$fail" -eq 0 ]; then
  printf 'ok — cass-release-promote: %d/%d assertions passed\n' "$pass" "$((pass + fail))"
else
  printf 'FAIL — cass-release-promote: %d of %d assertions failed\n' "$fail" "$((pass + fail))" >&2
  exit 1
fi
