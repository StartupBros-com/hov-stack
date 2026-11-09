#!/usr/bin/env bash
set -euo pipefail

# Tests for release/scripts/release-pins.sh.
#
# The script decides what every new machine downloads and runs, so the properties worth
# proving are: verify catches a moved sha256 or a missing archive member; refresh moves a
# pin only forward, only past the cooldown, and only to bytes that match the maker's
# published checksum (and attestation, where the maker has one); any failure leaves
# install-release.sh and the plan untouched; a rewrite changes the TABLE block and nothing
# else; apply writes only rows refresh could have written; and every downloaded program
# runs in a scratch environment no token or config of the caller reaches (jsm's own binary
# also from a read-only copy).
#
# Everything is offline: archives and checksum files are file:// fixtures, `gh` is a stub
# on PATH, and no test touches the real HOME.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${PINS_SCRIPT:-$ROOT/release/scripts/release-pins.sh}"
REAL_IR="$ROOT/plugins/hov-stack/skills/hov-setup/scripts/install-release.sh"
IR_REL='plugins/hov-stack/skills/hov-setup/scripts/install-release.sh'
TMP="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" >&2; exit 1; }
expect_rc() { [ "$RC" -eq "$1" ] || die "$2 (exit $RC, wanted $1)"; }
expect_out() { grep -qF -- "$1" <<<"$OUT" || die "$2 (output lacks: $1)"; }
expect_no_out() { ! grep -qF -- "$1" <<<"$OUT" || die "$2 (output has: $1)"; }
expect_same() { cmp -s "$1" "$2" || die "$3"; }

TAB="$(printf '\t')"
NOW="$(date -u -d 2026-11-03T00:00:00Z +%s)"

# --- stub gh -----------------------------------------------------------------------------
# `gh api repos/<o>/<r>/releases...` serves $FIX/releases/<o>__<r>.json.
# `gh attestation verify <file> --repo <o>/<r>` fails when the repo is listed in $FIX/attest-fail.
# Every call is recorded in $CALLS.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUBGH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  api)
    repo="${2#repos/}"; repo="${repo%%/releases*}"
    f="$FIX/releases/${repo/\//__}.json"
    [ -f "$f" ] || { echo "HTTP 404" >&2; exit 1; }
    cat "$f" ;;
  attestation)
    [ "$2" = verify ] || exit 1
    repo=''
    while [ $# -gt 0 ]; do [ "$1" = --repo ] && repo="$2"; shift; done
    if grep -qxF "$repo" "$FIX/attest-fail" 2>/dev/null; then echo "no attestations found for $repo" >&2; exit 1; fi
    echo "Loaded digest and verified" ;;
  *) echo "unexpected gh: $*" >&2; exit 1 ;;
esac
STUBGH
chmod +x "$TMP/bin/gh"

# Native commands remain untouched; these opt-in stubs exercise Darwin detection offline.
REAL_UNAME=$(command -v uname)
cat > "$TMP/bin/uname" <<'STUBUNAME'
#!/usr/bin/env bash
if [ "${FAKE_DARWIN:-}" = 1 ]; then
  case "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; *) exit 2 ;; esac
else
  exec "$REAL_UNAME" "$@"
fi
STUBUNAME
cat > "$TMP/bin/sysctl" <<'STUBSYSCTL'
#!/usr/bin/env bash
[ "$*" = '-n sysctl.proc_translated' ] || exit 2
printf '%s\n' "${FAKE_TRANSLATED:-0}"
exit "${FAKE_SYSCTL_RC:-0}"
STUBSYSCTL
chmod +x "$TMP/bin/uname" "$TMP/bin/sysctl"

# --- fixtures ------------------------------------------------------------------------------
# Independent of the script under test: the real asset names, written out again here.
spec() { # tool version -> platform|asset|members
  local t=$1 v=$2
  case $t in
    gh)
      echo "linux-x86_64|gh_${v}_linux_amd64.tar.gz|gh_${v}_linux_amd64/bin/gh"
      echo "linux-aarch64|gh_${v}_linux_arm64.tar.gz|gh_${v}_linux_arm64/bin/gh"
      echo "darwin-arm64|gh_${v}_macOS_arm64.zip|gh_${v}_macOS_arm64/bin/gh"
      echo "darwin-x86_64|gh_${v}_macOS_amd64.zip|gh_${v}_macOS_amd64/bin/gh" ;;
    uv)
      for p in linux-x86_64:x86_64-unknown-linux-gnu linux-aarch64:aarch64-unknown-linux-gnu \
               darwin-arm64:aarch64-apple-darwin darwin-x86_64:x86_64-apple-darwin; do
        tr_=${p#*:}
        echo "${p%%:*}|uv-$tr_.tar.gz|uv-$tr_/uv,uv-$tr_/uvx"
      done ;;
    cass)
      echo "linux-x86_64|cass-linux-amd64.tar.gz|cass"
      echo "linux-aarch64|cass-linux-arm64.tar.gz|cass"
      echo "darwin-arm64|cass-darwin-arm64.tar.gz|cass" ;;
    jsm)
      echo "linux-x86_64|jsm-x86_64-unknown-linux-musl.tar.gz|jsm"
      echo "linux-aarch64|jsm-aarch64-unknown-linux-gnu.tar.gz|jsm"
      echo "darwin-arm64|jsm-aarch64-apple-darwin.tar.gz|jsm"
      echo "darwin-x86_64|jsm-x86_64-apple-darwin.tar.gz|jsm" ;;
  esac
}
reldir() { # tool version
  case $1 in
    gh) echo "$FIX/github/cli/cli/releases/download/v$2" ;;
    uv) echo "$FIX/github/astral-sh/uv/releases/download/$2" ;;
    cass) echo "$FIX/github/Dicklesworthstone/coding_agent_session_search/releases/download/v$2" ;;
    jsm) echo "$FIX/jsm/v$2" ;;
  esac
}
sumsname() { case $1 in gh) echo "gh_$2_checksums.txt" ;; uv) echo sha256.sum ;; *) echo SHA256SUMS ;; esac; }
repo_of() { case $1 in gh) echo cli/cli ;; uv) echo astral-sh/uv ;; cass) echo Dicklesworthstone/coding_agent_session_search ;; esac; }
tagof() { case $1 in uv) echo "$2" ;; *) echo "v$2" ;; esac; }

# The fake programs. Each answers --version, and fails unless it runs in the scratch
# environment: with a canary from the caller's environment (GH_TOKEN, HOV_TEST_CANARY)
# it exits 6, and with the real HOME, unset XDG dirs or the caller's XDG dirs (runenv
# points them at $TMP/canary) it exits 3. The fake jsm also answers
# `update --check --json` with the version in $FIX/jsm-target, and only from a directory
# and file it cannot write. Paths are written in when a fake is built, since env -i keeps
# every variable of the caller from reaching it.
write_member() { # path tool version platform
  local f=$1 t=$2 v=$3 p=$4
  mkdir -p "$(dirname "$f")"
  if [ "${BADBIN:-}" = "$t" ]; then
    printf '#!/bin/sh\nexit 1\n' > "$f"
    chmod +x "$f"
    return
  fi
  cat > "$f" <<EOF
#!/bin/sh
# $t $v $p
[ -z "\${GH_TOKEN:-}\${HOV_TEST_CANARY:-}" ] || { echo "the caller's environment reached $t" >&2; exit 6; }
[ "\$HOME" != "$HOME" ] || { echo "$t runs with the real HOME" >&2; exit 3; }
[ -n "\${XDG_CONFIG_HOME:-}" ] && [ -n "\${XDG_DATA_HOME:-}" ] && [ -n "\${XDG_CACHE_HOME:-}" ] && [ -n "\${XDG_STATE_HOME:-}" ] \\
  || { echo "$t runs without its own XDG dirs" >&2; exit 3; }
case "\$XDG_CONFIG_HOME\$XDG_DATA_HOME\$XDG_CACHE_HOME\$XDG_STATE_HOME" in
  *"$TMP/canary"*) echo "$t runs with the caller's XDG dirs" >&2; exit 3 ;;
esac
if [ "\$1" = --version ]; then echo "$t $v"; echo $t >> "$RANLOG"; echo "$t $p" >> "$RANLOG.platform"; exit 0; fi
EOF
  if [ "$t" = jsm ]; then
    cat >> "$f" <<EOF
[ "\$1 \$2 \$3" = "update --check --json" ] || { echo "bad args: \$*" >&2; exit 5; }
if [ "\$(id -u)" != 0 ]; then
  d=\$(dirname "\$0")
  if [ -w "\$d" ] || [ -w "\$0" ]; then echo "own dir or file is writable" >&2; exit 4; fi
fi
tv=\$(cat "$FIX/jsm-target" 2>/dev/null)
[ -n "\$tv" ] || tv=$v
printf '{"current_version":"v$v","target_version":"v%s","action":"up_to_date"}\n' "\$tv"
EOF
  else
    printf 'echo "%s %s"\n' "$t" "$v" >> "$f"
  fi
  chmod +x "$f"
}

# Build every platform's archive for tool/version plus the maker's checksum file.
# OMIT_PLAT=<platform> builds that archive without its members. PAD_PLAT=<platform> adds
# 3000 files after the members of that (tar) archive, so its listing is far over a pipe
# buffer and the members come first.
mkrelease() { # tool version
  local t=$1 v=$2 dir sums plat asset members stage m sha
  dir=$(reldir "$t" "$v"); mkdir -p "$dir"
  sums="$dir/$(sumsname "$t" "$v")"; : > "$sums"
  while IFS='|' read -r plat asset members; do
    [ -n "$plat" ] || continue
    stage=$(mktemp -d "$TMP/stage.XXXXXX")
    if [ "$plat" = "${OMIT_PLAT:-}" ]; then
      echo decoy > "$stage/decoy"
    else
      while IFS= read -r m; do write_member "$stage/$m" "$t" "$v" "$plat"; done <<EOM
$(printf '%s' "$members" | tr ',' '\n')
EOM
    fi
    if [ "$plat" = "${PAD_PLAT:-}" ]; then
      mkdir "$stage/zzpad"
      (cd "$stage/zzpad" && touch pad-{0001..3000}-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
      tar -czf "$dir/$asset" -C "$stage" "${members%%/*}" zzpad
    else
      case $asset in
        *.zip) (cd "$stage" && zip -qr "$dir/$asset" .) ;;
        *) tar -czf "$dir/$asset" -C "$stage" . ;;
      esac
    fi
    sha=$(sha256sum "$dir/$asset" | awk '{print $1}')
    if [ "$t" = uv ]; then printf '%s *%s\n' "$sha" "$asset" >> "$sums"; else printf '%s  %s\n' "$sha" "$asset" >> "$sums"; fi
  done <<EOF
$(spec "$t" "$v")
EOF
}

addrel() { # tool published [version] [draft] [prerelease]; tag is derived
  local t=$1 pub=$2 v=$3 draft=${4:-false} pre=${5:-false} f
  f="$FIX/releases/$(repo_of "$t" | tr / _ | sed 's/_/__/').json"
  jq --arg t "$(tagof "$t" "$v")" --arg p "$pub" --argjson d "$draft" --argjson pre "$pre" \
    '. + [{tag_name: $t, published_at: $p, draft: $d, prerelease: $pre}]' "$f" > "$f.new"
  mv "$f.new" "$f"
}
newrel() { # tool version published
  mkrelease "$1" "$2"
  if [ "$1" = jsm ]; then
    touch -d "$3" "$(reldir jsm "$2")/SHA256SUMS"   # jsm's release date is this file's Last-Modified
  else
    addrel "$1" "$3" "$2"
  fi
}

rows_for() { # tool version [omit platform]
  local t=$1 v=$2 plat asset members
  while IFS='|' read -r plat asset members; do
    [ -n "$plat" ] || continue
    [ "$plat" != "${3:-}" ] || continue
    printf '%s|%s|%s|file://%s/%s|%s|%s\n' "$t" "$v" "$plat" "$(reldir "$t" "$v")" "$asset" \
      "$(sha256sum "$(reldir "$t" "$v")/$asset" | awk '{print $1}')" "$members"
  done <<EOF
$(spec "$t" "$v")
EOF
}

# A copy of the real install-release.sh whose TABLE block holds $2.
mkir() { # out rows-file
  local s e
  s=$(grep -nF "TABLE=\${HOV_SETUP_RELEASE_TABLE:-'" "$REAL_IR" | head -n1 | cut -d: -f1)
  e=$(awk -v s="$s" -v c="'}" 'NR > s && $0 == c { print NR; exit }' "$REAL_IR")
  { head -n "$s" "$REAL_IR"; cat "$2"; tail -n +"$e" "$REAL_IR"; } > "$1"
}
rows_of() { # file -> the lines between the TABLE markers
  local s e
  s=$(grep -nF "TABLE=\${HOV_SETUP_RELEASE_TABLE:-'" "$1" | head -n1 | cut -d: -f1)
  e=$(awk -v s="$s" -v c="'}" 'NR > s && $0 == c { print NR; exit }' "$1")
  sed -n "$((s + 1)),$((e - 1))p" "$1"
}
outside_of() { # file -> everything except the rows between the TABLE markers
  local s e
  s=$(grep -nF "TABLE=\${HOV_SETUP_RELEASE_TABLE:-'" "$1" | head -n1 | cut -d: -f1)
  e=$(awk -v s="$s" -v c="'}" 'NR > s && $0 == c { print NR; exit }' "$1")
  head -n "$s" "$1"; tail -n +"$e" "$1"
}
edit_row() { # file tool platform field-number new-value
  awk -F'|' -v OFS='|' -v t="$2" -v p="$3" -v i="$4" -v n="$5" '$1 == t && $3 == p { $i = n } { print }' "$1" > "$1.new"
  mv "$1.new" "$1"
}

N=0
new_world() {
  N=$((N + 1))
  FIX="$TMP/w$N"; CALLS="$FIX/calls"; RANLOG="$FIX/ran"
  mkdir -p "$FIX/github" "$FIX/jsm" "$FIX/releases"
  : > "$CALLS"; : > "$RANLOG"
  local tv t v
  : > "$FIX/rows"
  # shellcheck disable=SC2086  # WORLD is a space-separated list of tool:version
  for tv in ${WORLD:-gh:2.0.0 uv:1.0.0 cass:3.0.0 jsm:4.0.0}; do
    t=${tv%%:*}; v=${tv##*:}
    mkrelease "$t" "$v"
    if [ "$t" != jsm ]; then printf '[]' > "$FIX/releases/$(repo_of "$t" | tr / _ | sed 's/_/__/').json"; addrel "$t" 2026-09-01T00:00:00Z "$v"; fi
    rows_for "$t" "$v" >> "$FIX/rows"
  done
  IR="$FIX/ir.sh"
  mkir "$IR" "$FIX/rows"
  cp "$IR" "$FIX/ir.orig"
}

K=0
# GH_TOKEN, HOV_TEST_CANARY and the XDG dirs stand for a caller's environment: a fake
# program that sees any of them fails (see write_member). ALLOWFILE=0 drops the test-only
# switch that lets downloads read file:// urls.
runenv() {
  env PATH="$TMP/bin:$PATH" FIX="$FIX" CALLS="$CALLS" REAL_UNAME="$REAL_UNAME" \
    FAKE_DARWIN="${FAKE_DARWIN:-}" FAKE_TRANSLATED="${FAKE_TRANSLATED:-0}" FAKE_SYSCTL_RC="${FAKE_SYSCTL_RC:-0}" \
    GH_TOKEN=canary-token HOV_TEST_CANARY=1 XDG_CONFIG_HOME="$TMP/canary/config" \
    XDG_DATA_HOME="$TMP/canary/data" XDG_CACHE_HOME="$TMP/canary/cache" XDG_STATE_HOME="$TMP/canary/state" \
    HOV_PINS_PLATFORM="${TEST_PLATFORM-linux-x86_64}" HOV_PINS_NOW="$NOW" HOV_PINS_TEST_ALLOW_FILE="${ALLOWFILE:-1}" \
    HOV_PINS_GITHUB_DOWNLOAD_BASE="file://$FIX/github" HOV_PINS_JSM_BASE="file://$FIX/jsm" \
    "$@"
}
run_verify() {
  RC=0; OUT=$(runenv bash "$SCRIPT" verify "$@" 2>&1) || RC=$?
}
run_refresh() { # args for refresh; AGE= cooldown days, JT= the version the fake jsm reports
  K=$((K + 1)); PLAN="$FIX/plan.$K"; ROWSOUT="$FIX/rows.out.$K"
  printf '%s' "${JT:-}" > "$FIX/jsm-target"
  RC=0; OUT=$(runenv INSTALL_RELEASE="$IR" PLAN_FILE="$PLAN" ROWS_FILE="$ROWSOUT" HOV_PIN_MIN_AGE_DAYS="${AGE:-3}" \
    bash "$SCRIPT" refresh "$@" 2>&1) || RC=$?
}
run_apply() { # rows-file
  K=$((K + 1)); PLAN="$FIX/plan.$K"
  RC=0; OUT=$(runenv INSTALL_RELEASE="$IR" PLAN_FILE="$PLAN" bash "$SCRIPT" apply "$1" 2>&1) || RC=$?
}

# --- verify ---------------------------------------------------------------------------------
new_world
run_verify --table-from "$IR"
expect_rc 0 'verify passes on a good table'
[ "$(printf '%s\n' "$OUT" | grep -c '^ok ')" -eq 15 ] || die 'verify prints one ok line per row (15)'
expect_out 'ok cass linux-x86_64 3.0.0' 'verify names the row'
expect_out 'ok jsm darwin-arm64 4.0.0' 'verify covers rows of other platforms'
[ "$(sort "$RANLOG" | tr '\n' ' ')" = 'cass gh jsm uv ' ] \
  || die "verify installs each tool for this machine's platform and only that (ran: $(tr '\n' ' ' < "$RANLOG"))"
pass 'verify passes on a good file:// table, installs only this platform, and runs each program in the scratch environment'

# Verify actually executes the selected fixture, not merely a platform label.
check_darwin_execution() { # sysctl output status expected-platform [override]
  new_world
  FAKE_DARWIN=1 FAKE_TRANSLATED="$1" FAKE_SYSCTL_RC="$2" TEST_PLATFORM="${4-}" run_verify --table-from "$IR"
  expect_rc 0 'Darwin detection verifies the offline table'
  case "$3" in
    darwin-arm64) printf 'cass darwin-arm64\ngh darwin-arm64\njsm darwin-arm64\nuv darwin-arm64\n' > "$FIX/ran.want" ;;
    darwin-x86_64) printf 'gh darwin-x86_64\njsm darwin-x86_64\nuv darwin-x86_64\n' > "$FIX/ran.want" ;;
    *) die 'unsupported expected Darwin fixture platform' ;;
  esac
  sort "$RANLOG.platform" > "$FIX/ran.got"
  expect_same "$FIX/ran.got" "$FIX/ran.want" 'verify executes exactly the detected platform fixtures (cass absent on Intel)'
}
check_darwin_execution 0 0 darwin-x86_64
pass 'native Intel Darwin executes only Intel fixtures'
check_darwin_execution $' \n\t1 \n' 0 darwin-arm64
pass 'Rosetta Darwin executes ARM fixtures when successful sysctl output trims to exactly 1'
check_darwin_execution 1 1 darwin-x86_64
pass 'failed sysctl cannot select Rosetta even when its output is 1'
check_darwin_execution 11 0 darwin-x86_64
check_darwin_execution '1 extra' 0 darwin-x86_64
pass 'unexpected successful sysctl output remains Intel'
check_darwin_execution 1 0 darwin-x86_64 darwin-x86_64
pass 'the explicit platform override wins over Rosetta detection'

new_world
ALLOWFILE=0 run_verify --table-from "$IR"
expect_rc 1 'without the test switch a file:// url is refused'
expect_out 'FAIL gh linux-x86_64: download failed: file://' 'the refusal is a failed download'
pass 'downloads are https only outside the tests'

new_world
real=$(sha256sum "$(reldir cass 3.0.0)/cass-darwin-arm64.tar.gz" | awk '{print $1}')
bad=$(printf 'a%.0s' $(seq 64))
edit_row "$IR" cass darwin-arm64 5 "$bad"
run_verify --table-from "$IR"
expect_rc 1 'verify fails on a sha mismatch'
expect_out "FAIL cass darwin-arm64: sha256 is $real, pin is $bad" 'verify names tool, platform and both shas'
expect_out 'ok gh linux-x86_64 2.0.0' 'verify keeps checking the other rows'
pass 'verify fails on a sha mismatch'

new_world
edit_row "$IR" gh darwin-arm64 6 'nope/bin/gh'
run_verify --table-from "$IR"
expect_rc 1 'verify fails on a missing member'
expect_out 'FAIL gh darwin-arm64: archive lacks member nope/bin/gh' 'verify names the missing member'
pass 'verify fails on a missing archive member'

new_world
BADBIN=cass mkrelease cass 3.0.0   # same names, binaries that fail --version
{ rows_for gh 2.0.0; rows_for uv 1.0.0; rows_for cass 3.0.0; rows_for jsm 4.0.0; } > "$FIX/rows"
mkir "$IR" "$FIX/rows"
run_verify --table-from "$IR"
expect_rc 1 'verify fails when the installed program fails --version'
expect_out 'FAIL cass linux-x86_64: install-release.sh cass exited 1' 'verify reports the installer failure'
expect_out 'ok cass linux-aarch64 3.0.0' 'a platform that is not this machine is not installed'
pass 'verify runs install-release.sh for this platform and reports its failure'

# --if-changed-since, in a scratch git repo that holds a copy of the script.
new_world
R="$TMP/repo"
mkdir -p "$R/release/scripts" "$R/$(dirname "$IR_REL")"
cp "$SCRIPT" "$R/release/scripts/release-pins.sh"
echo 'gh|2.0.0|linux-x86_64|file:///nonexistent/gh.tar.gz|aaaa|gh' > "$FIX/unreachable"
mkir "$R/$IR_REL" "$FIX/unreachable"
rgit() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
rgit init -q
rgit add -A; rgit commit -qm one
echo unrelated > "$R/other.txt"; rgit add -A; rgit commit -qm two
RS="$R/release/scripts/release-pins.sh"
rv() { RC=0; OUT=$(runenv bash "$RS" verify "$@" 2>&1) || RC=$?; }
rv --if-changed-since HEAD~1
expect_rc 0 'unchanged inputs skip'
expect_out 'pins not re-verified' 'the skip says so'
expect_no_out 'FAIL' 'the skip does not download'
rv --if-changed-since ''
expect_rc 1 'an empty ref verifies everything'
rv --if-changed-since 0000000000000000000000000000000000000000
expect_rc 1 'an all-zero sha verifies everything'
rv --if-changed-since not-a-commit
expect_rc 1 'a ref that is not a commit verifies everything'
echo '# touched' >> "$R/$IR_REL"; rgit add -A; rgit commit -qm three
rv --if-changed-since HEAD~1
expect_rc 1 'a changed install-release.sh verifies'
rv --if-changed-since HEAD
expect_rc 0 'a ref equal to HEAD skips'
echo '# touched' >> "$RS"; rgit add -A; rgit commit -qm four
rv --if-changed-since HEAD~1
expect_rc 1 'a changed release-pins.sh verifies'
pass '--if-changed-since skips when unchanged and verifies on a change, an empty or zero ref, or a non-commit'

# --- refresh ----------------------------------------------------------------------------------
new_world
run_refresh --write
expect_rc 0 'refresh on an up-to-date, complete table'
[ ! -s "$PLAN" ] || die 'an up-to-date table has an empty plan'
expect_same "$IR" "$FIX/ir.orig" 'an up-to-date table is byte-identical after --write'
pass 'refresh on an up-to-date table: empty plan, same bytes'

new_world
grep -q ' \*uv-' "$(reldir uv 1.0.0)/sha256.sum" || die 'fixture: uv checksum lines use the " *name" form'
newrel gh 2.1.0 2026-10-30T00:00:00Z
newrel uv 1.1.0 2026-10-30T00:00:00Z
run_refresh
expect_rc 0 'refresh moves pins past the cooldown'
printf 'gh\t2.0.0\t2.1.0\tlinux-x86_64,linux-aarch64,darwin-arm64,darwin-x86_64\nuv\t1.0.0\t1.1.0\tlinux-x86_64,linux-aarch64,darwin-arm64,darwin-x86_64\n' > "$FIX/plan.want"
expect_same "$PLAN" "$FIX/plan.want" 'the plan has one TSV line per moved tool, with " *name" checksum lines parsed for uv'
expect_same "$IR" "$FIX/ir.orig" 'without --write the table is untouched'
grep -q 'attestation verify .*--repo cli/cli' "$CALLS" || die 'gh is attestation-verified'
grep -q 'attestation verify .*--repo astral-sh/uv' "$CALLS" || die 'uv is attestation-verified'
! grep -q 'attestation verify .*--repo Dicklesworthstone' "$CALLS" || die 'cass has no attestations and is not asked for one'
run_refresh --write
expect_rc 0 'refresh --write'
{ rows_for gh 2.1.0; rows_for uv 1.1.0; rows_for cass 3.0.0; rows_for jsm 4.0.0; } > "$FIX/rows.want"
rows_of "$IR" > "$FIX/rows.got"
expect_same "$FIX/rows.got" "$FIX/rows.want" '--write replaces exactly the moved rows, in table order'
outside_of "$IR" > "$FIX/out.got"; outside_of "$FIX/ir.orig" > "$FIX/out.want"
expect_same "$FIX/out.got" "$FIX/out.want" '--write leaves every byte outside the TABLE block alone'
[ -z "$(find "$FIX" -maxdepth 1 -name '.install-release.*')" ] || die '--write leaves no temp file beside install-release.sh'
cp "$IR" "$FIX/ir.moved"
run_refresh --write
[ ! -s "$PLAN" ] || die 'a second refresh finds no drift'
expect_same "$IR" "$FIX/ir.moved" 'a second --write writes the same bytes'
pass 'refresh moves pins forward; --write changes only the TABLE block; idempotent'

new_world
newrel gh 2.1.0 2026-11-02T00:00:00Z
run_refresh --write
expect_rc 0 'a newer release inside the cooldown is not an error'
[ ! -s "$PLAN" ] || die 'a release inside the cooldown is not planned'
expect_same "$IR" "$FIX/ir.orig" 'the table keeps its pin inside the cooldown'
expect_out 'gh: 2.1.0 is inside the 3-day cooldown; eligible 2026-11-05T00:00Z' 'the run says when it becomes eligible'
AGE=1 run_refresh
grep -q "^gh${TAB}2.0.0${TAB}2.1.0" "$PLAN" || die 'HOV_PIN_MIN_AGE_DAYS=1 makes a day-old release eligible'
newrel gh 2.2.0 2026-11-02T12:00:00Z
run_refresh
[ ! -s "$PLAN" ] || die '2.1.0 and 2.2.0 are both inside the cooldown'
newrel gh 2.0.5 2026-10-20T00:00:00Z
run_refresh
grep -q "^gh${TAB}2.0.0${TAB}2.0.5${TAB}" "$PLAN" || die 'the newest eligible release wins when newer ones are held'
expect_out 'gh: 2.2.0 is inside the 3-day cooldown' 'the newest held release is the one reported'
pass 'refresh keeps a pin while a newer release is inside the cooldown'

new_world
newrel gh 2.9.9 2026-10-20T00:00:00Z
newrel gh 2.10.0 2026-10-20T00:00:00Z
run_refresh
expect_rc 0 'refresh with 2.9.9 and 2.10.0 eligible'
grep -q "^gh${TAB}2.0.0${TAB}2.10.0${TAB}" "$PLAN" || die '2.10.0 is above 2.9.9: versions compare as numbers, field by field'
WORLD='gh:2.10.0 uv:1.0.0 cass:3.0.0 jsm:4.10.0' new_world
newrel gh 2.9.9 2026-10-20T00:00:00Z
JT=4.9.9 run_refresh --write
expect_rc 0 'a pin at x.10.0 with x.9.9 on offer'
[ ! -s "$PLAN" ] || die 'a pin at 2.10.0 (gh) or 4.10.0 (jsm) does not move to 2.9.9 or 4.9.9'
expect_same "$IR" "$FIX/ir.orig" 'the table is untouched'
pass 'versions compare as numbers field by field: x.10.0 is above x.9.9, for gh and for jsm'

new_world
addrel gh 2026-10-01T00:00:00Z 2.0.99999999999999999999
addrel gh 2026-10-01T00:00:00Z 2.1234567.0
run_refresh --write
expect_rc 0 'a tag with an oversized field does not break the run'
[ ! -s "$PLAN" ] || die 'a tag with a field over six digits is not a release'
expect_same "$IR" "$FIX/ir.orig" 'the table is untouched'
pass 'a tag with a field over six digits is ignored, not chosen'

new_world
newrel gh 1.9.0 2026-10-01T00:00:00Z
addrel gh 2026-10-01T00:00:00Z 9.0.0 true false
addrel gh 2026-10-01T00:00:00Z 9.1.0 false true
jq '. + [{tag_name: "nightly", published_at: "2026-10-01T00:00:00Z", draft: false, prerelease: false}]' \
  "$FIX/releases/cli__cli.json" > "$FIX/x.json" && mv "$FIX/x.json" "$FIX/releases/cli__cli.json"
# the pinned 2.0.0 is no longer listed (withdrawn), so 1.9.0 is the newest eligible release
jq 'map(select(.tag_name != "v2.0.0"))' "$FIX/releases/cli__cli.json" > "$FIX/x.json"
cp "$FIX/x.json" "$FIX/releases/cli__cli.json"
JT=3.0.0 run_refresh --write
expect_rc 0 'older releases, drafts, prereleases and non-version tags are ignored'
[ ! -s "$PLAN" ] || die 'a pin never moves backwards, to an equal version, or to a draft or prerelease'
expect_same "$IR" "$FIX/ir.orig" 'the table is untouched'
pass 'refresh never moves backwards (gh and jsm) and ignores drafts and prereleases'

new_world
grep -v '^gh|2.0.0|darwin-arm64|' "$IR" | grep -v '^jsm|4.0.0|darwin-arm64|' > "$IR.new"; mv "$IR.new" "$IR"
[ "$(rows_of "$IR" | wc -l)" -eq 13 ] || die 'fixture: two rows removed'
run_refresh --write
expect_rc 0 'refresh adds missing platform rows'
printf 'gh\t2.0.0\t2.0.0\tdarwin-arm64\njsm\t4.0.0\t4.0.0\tdarwin-arm64\n' > "$FIX/plan.want"
expect_same "$PLAN" "$FIX/plan.want" 'the plan names the added platform at the same version'
expect_same "$IR" "$FIX/ir.orig" 'the added rows land in their ordered places'
pass 'refresh adds a missing platform row at the current version'

# The table used before Intel support must gain only the three supported rows.
new_world
awk -F'|' '$3 != "darwin-x86_64"' "$FIX/rows" > "$FIX/legacy.rows"
[ "$(wc -l < "$FIX/legacy.rows")" -eq 12 ] || die 'fixture: legacy table has exactly 12 rows'
mkir "$IR" "$FIX/legacy.rows"
run_refresh --write
expect_rc 0 'refresh upgrades the legacy table without a version move'
printf 'gh\t2.0.0\t2.0.0\tdarwin-x86_64\nuv\t1.0.0\t1.0.0\tdarwin-x86_64\njsm\t4.0.0\t4.0.0\tdarwin-x86_64\n' > "$FIX/plan.want"
expect_same "$PLAN" "$FIX/plan.want" 'exactly three Intel additions are planned at the current versions'
expect_same "$IR" "$FIX/ir.orig" 'only the three Intel rows are inserted in metadata order'
[ "$(rows_of "$IR" | wc -l)" -eq 15 ] || die 'upgraded table has exactly 15 rows'
! grep -q '^cass|[^|]*|darwin-x86_64|' "$IR" || die 'cass must not gain an unsupported Intel row'
pass 'refresh upgrades a legacy 12-row table with exactly three Intel rows at current versions'

# fail closed
for intel_failure in missing checksum member; do
  new_world
  awk -F'|' '$3 != "darwin-x86_64"' "$FIX/rows" > "$FIX/legacy.rows"
  mkir "$IR" "$FIX/legacy.rows"
  cp "$IR" "$FIX/legacy.ir"
  case "$intel_failure" in
    missing) rm "$(reldir uv 1.0.0)/uv-x86_64-apple-darwin.tar.gz"; reason='download failed:' ;;
    checksum) printf corrupt >> "$(reldir uv 1.0.0)/uv-x86_64-apple-darwin.tar.gz"; reason='sha256 is ' ;;
    member) OMIT_PLAT=darwin-x86_64 mkrelease uv 1.0.0; reason='archive lacks member uv-x86_64-apple-darwin/uv' ;;
  esac
  run_refresh --write
  expect_rc 1 "Intel $intel_failure fails the whole refresh"
  expect_out "FAIL uv darwin-x86_64: $reason" 'failure names the Intel asset and exact verification stage'
  [ ! -s "$PLAN" ] || die 'no partial plan after an Intel asset failure'
  [ ! -s "$ROWSOUT" ] || die 'no partial rows output after an Intel asset failure'
  expect_same "$IR" "$FIX/legacy.ir" 'Intel failure leaves the original legacy table unchanged'
  pass "refresh fails closed on an Intel asset $intel_failure"
done
new_world
newrel gh 2.1.0 2026-10-30T00:00:00Z
newrel uv 1.1.0 2026-10-30T00:00:00Z
sed -i "s/^[0-9a-f]\\{8\\}\\(.*arm64\\.tar\\.gz\\)\$/deadbeef\\1/" "$(reldir gh 2.1.0)/gh_2.1.0_checksums.txt"
run_refresh --write
expect_rc 1 'a publisher checksum mismatch fails the run'
expect_out 'FAIL gh linux-aarch64: sha256 is ' 'the failure names tool and platform'
expect_out 'publisher lists deadbeef' 'the failure names the publisher value'
[ ! -s "$PLAN" ] || die 'no plan line is written when any tool fails (uv moved fine)'
expect_same "$IR" "$FIX/ir.orig" 'install-release.sh is untouched when any tool fails'
pass 'refresh fails closed on a publisher checksum mismatch'

new_world
newrel gh 2.1.0 2026-10-30T00:00:00Z
newrel uv 1.1.0 2026-10-30T00:00:00Z
echo astral-sh/uv > "$FIX/attest-fail"
run_refresh --write
expect_rc 1 'a failed attestation fails the run'
expect_out 'FAIL uv linux-x86_64: attestation verification failed' 'the failure names the attested tool'
[ ! -s "$PLAN" ] || die 'no plan line after an attestation failure'
expect_same "$IR" "$FIX/ir.orig" 'install-release.sh is untouched after an attestation failure'
pass 'refresh fails closed on a failed attestation of an attested tool'

new_world
newrel gh 2.1.0 2026-10-30T00:00:00Z
newrel uv 1.1.0 2026-10-30T00:00:00Z
newrel cass 3.1.0 2026-10-30T00:00:00Z
printf 'Dicklesworthstone/coding_agent_session_search\njsm\n' > "$FIX/attest-fail"
run_refresh --write
expect_rc 0 'attestation is not asked of tools without any'
grep -q "^cass${TAB}3.0.0${TAB}3.1.0" "$PLAN" || die 'cass moves without an attestation'
pass 'refresh does not require attestations for cass'

new_world
newrel gh 2.1.0 2026-10-30T00:00:00Z
newrel uv 1.1.0 2026-10-30T00:00:00Z
newrel cass 3.1.0 2026-10-30T00:00:00Z
sed -i "s/^[0-9a-f]\\{8\\}/deadbeef/" "$(reldir cass 3.1.0)/SHA256SUMS"
run_refresh --write
expect_rc 1 'one of four tools failing fails the run'
expect_out 'FAIL cass ' 'the failing tool is named'
[ ! -s "$PLAN" ] || die 'the three good tools are not planned either'
expect_same "$IR" "$FIX/ir.orig" 'the three good tools are not written either'
pass 'refresh is all-or-nothing when one tool fails'

new_world
OMIT_PLAT=darwin-arm64 newrel gh 2.1.0 2026-10-30T00:00:00Z
run_refresh --write
expect_rc 1 'an archive lacking a templated member fails the run'
expect_out 'FAIL gh darwin-arm64: archive lacks member gh_2.1.0_macOS_arm64/bin/gh' 'the missing member is named'
expect_same "$IR" "$FIX/ir.orig" 'install-release.sh is untouched'
pass 'refresh fails closed on a missing archive member'

new_world
PAD_PLAT=linux-x86_64 newrel gh 2.1.0 2026-10-30T00:00:00Z
run_refresh
expect_rc 0 'an archive whose listing is far over a pipe buffer'
grep -q "^gh${TAB}2.0.0${TAB}2.1.0${TAB}" "$PLAN" || die 'the large archive passes its member check'
# The same defect class anywhere else: a pipe into a reader that stops early.
! grep -nE '\| *(grep -[a-zA-Z]*q|head|awk .*exit *\})' "$SCRIPT" || die 'release-pins.sh pipes into a reader that stops early (SIGPIPE under pipefail)'
pass 'a member check reads a listing of any size: a large archive is not a broken pipe'

new_world
edit_row "$IR" jsm linux-x86_64 5 "$(printf 'b%.0s' $(seq 64))"
run_refresh --write
expect_rc 1 'a pinned jsm binary that does not match its pin is not run'
expect_out 'FAIL jsm linux-x86_64: pinned binary sha256 is' 'the failure names the check'
pass 'refresh will not run a jsm binary that fails its pinned sha256'

# jsm
new_world
newrel jsm 5.0.0 2026-10-30T00:00:00Z
JT=5.0.0 run_refresh
expect_rc 0 'jsm check runs from a read-only copy in the scratch environment, with no GH_TOKEN (the fake exits non-zero otherwise)'
grep -q "^jsm${TAB}4.0.0${TAB}5.0.0${TAB}linux-x86_64,linux-aarch64,darwin-arm64,darwin-x86_64\$" "$PLAN" \
  || die 'jsm moves to the version update --check reports'
newrel jsm 5.1.0 2026-11-02T12:00:00Z
JT=5.1.0 run_refresh
expect_rc 0 'jsm inside the cooldown is not an error'
[ ! -s "$PLAN" ] || die "jsm's release date is the Last-Modified of its SHA256SUMS; 5.1.0 is too new"
expect_out 'jsm: 5.1.0 is inside the 3-day cooldown; eligible 2026-11-05T12:00Z' 'jsm cooldown is reported'
pass 'jsm: version comes from the read-only pinned binary, date from Last-Modified, cooldown applies'


# --- apply --------------------------------------------------------------------------------------
new_world
newrel gh 2.1.0 2026-10-30T00:00:00Z
newrel uv 1.1.0 2026-10-30T00:00:00Z
run_refresh
expect_rc 0 'refresh writes ROWS_FILE'
cp "$PLAN" "$FIX/plan.refresh"
cp "$ROWSOUT" "$FIX/rows.good"
{ rows_for gh 2.1.0; rows_for uv 1.1.0; rows_for cass 3.0.0; rows_for jsm 4.0.0; } > "$FIX/rows.want"
expect_same "$FIX/rows.good" "$FIX/rows.want" 'ROWS_FILE holds every new row, in table order'
expect_same "$IR" "$FIX/ir.orig" 'refresh without --write leaves the table alone'

refuse() { # rows-file reason what
  run_apply "$1"
  expect_rc 1 "$3"
  expect_out "$2" "$3: the reason is named"
  expect_out 'apply refused the rows' "$3: the run says nothing was changed"
  [ ! -s "$PLAN" ] || die "$3: no plan is written"
  expect_same "$IR" "$FIX/ir.orig" "$3: the table is untouched"
}
cp "$FIX/rows.good" "$FIX/r1"; edit_row "$FIX/r1" gh linux-x86_64 4 'https://evil.example/gh_2.1.0_linux_amd64.tar.gz'
refuse "$FIX/r1" 'FAIL gh linux-x86_64: the url is not the gh 2.1.0 release asset for linux-x86_64' 'a url off the release template'
cp "$FIX/rows.good" "$FIX/r2"; edit_row "$FIX/r2" uv darwin-arm64 6 'uv-aarch64-apple-darwin/uv'
refuse "$FIX/r2" 'FAIL uv darwin-arm64: the members are not the uv 1.1.0 members' 'members off the template'
cp "$FIX/rows.good" "$FIX/r3"; edit_row "$FIX/r3" cass linux-x86_64 5 "$(printf 'c%.0s' $(seq 64))"
refuse "$FIX/r3" 'FAIL cass linux-x86_64: the row changes while cass stays at 3.0.0' 'a sha256 change without a version move'
mkrelease gh 1.9.0
{ rows_for gh 1.9.0; rows_for uv 1.1.0; rows_for cass 3.0.0; rows_for jsm 4.0.0; } > "$FIX/r4"
refuse "$FIX/r4" 'FAIL gh all: the rows move it backwards, 2.0.0 -> 1.9.0' 'a backwards move'
sed '2d' "$FIX/rows.good" > "$FIX/r5"
refuse "$FIX/r5" 'FAIL rows all: not exactly one row per tool and platform' 'a missing row'
{ sed -n 2p "$FIX/rows.good"; sed -n 1p "$FIX/rows.good"; sed -n '3,$p' "$FIX/rows.good"; } > "$FIX/r6"
refuse "$FIX/r6" 'FAIL rows all: not exactly one row per tool and platform' 'rows out of order'
sed '1s/$/|extra/' "$FIX/rows.good" > "$FIX/r7"
refuse "$FIX/r7" 'FAIL gh linux-x86_64: the row has more than six fields' 'a seventh field'
old_gh=$(grep '^gh|2.0.0|darwin-arm64|' "$FIX/rows")
awk -F'|' -v r="$old_gh" '$1 == "gh" && $3 == "darwin-arm64" { print r; next } { print }' "$FIX/rows.good" > "$FIX/r8"
refuse "$FIX/r8" 'FAIL gh all: the rows pin different versions' 'two versions for one tool'
cp "$FIX/rows.good" "$FIX/r9"; edit_row "$FIX/r9" jsm darwin-arm64 5 'XYZ'
printf '%s' "$(cat "$FIX/r9")" > "$FIX/r9.nonl"
refuse "$FIX/r9.nonl" 'FAIL jsm darwin-arm64: the sha256 is not 64 lowercase hex digits' 'a bad last row with no newline'
pass 'apply refuses an off-template url or members, a sha change in place, a backwards move, a missing, reordered or overlong row, mixed versions, and a bad last row'

run_apply "$FIX/rows.good"
expect_rc 0 'apply writes good rows'
expect_same "$PLAN" "$FIX/plan.refresh" "apply's plan is refresh's plan"
rows_of "$IR" > "$FIX/rows.got"
expect_same "$FIX/rows.got" "$FIX/rows.want" 'apply writes exactly the rows'
outside_of "$IR" > "$FIX/out.got"; outside_of "$FIX/ir.orig" > "$FIX/out.want"
expect_same "$FIX/out.got" "$FIX/out.want" 'apply leaves every byte outside the TABLE block alone'
cp "$IR" "$FIX/ir.applied"
run_apply "$FIX/rows.good"
expect_rc 0 'apply again'
[ ! -s "$PLAN" ] || die 'the same rows applied twice find no drift'
expect_same "$IR" "$FIX/ir.applied" 'a second apply writes nothing'
pass 'apply writes the rows refresh produced, with the same plan and nothing else; a second apply is a no-op'

new_world
newrel gh 2.1.0 2026-10-30T00:00:00Z
{ rows_for gh 2.1.0; rows_for uv 1.0.0; rows_for cass 3.0.0; rows_for jsm 4.0.0; } > "$FIX/rows.want"
printf '%s' "$(cat "$FIX/rows.want")" > "$FIX/rows.nonl"
run_apply "$FIX/rows.nonl"
expect_rc 0 'apply takes rows whose last line has no newline'
rows_of "$IR" > "$FIX/rows.got"
expect_same "$FIX/rows.got" "$FIX/rows.want" 'the last row still ends its own line in the table'
pass 'apply ends the last row with a newline'

printf '%s tests passed\n' "$PASS"

