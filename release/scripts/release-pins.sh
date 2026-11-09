#!/usr/bin/env bash
set -euo pipefail

# Verify and refresh the pinned program releases in install-release.sh.
#
# install-release.sh pins one archive per tool and platform (gh, uv, cass, jsm) by
# url and sha256. Left alone those pins go stale, and a pin nobody re-checks can
# rot unnoticed (a maker re-uploads an asset, a URL moves). This script does two jobs:
#
#   verify   re-downloads every pinned archive and proves the pin still holds
#   refresh  finds newer releases, proves them against what the maker published,
#            and plans (or, with --write, performs) the pin move
#
# It reads the TABLE out of install-release.sh by text and never sources it, and it
# never edits any other part of that file.
#
# Usage:
#   release-pins.sh verify [--table-from <install-release.sh>] [--if-changed-since <ref>]
#   release-pins.sh refresh [--write]
#   release-pins.sh apply <rows-file>
#
# verify: for every row, downloads the url, requires the archive's sha256 to equal the
#   pin and the archive to list every member. For the rows of this machine's platform it
#   also runs install-release.sh for the tool into a temp dir (which runs --version), in
#   the scratch environment below.
#   One line per row. --if-changed-since <ref> skips everything, with a one-line
#   notice, when <ref> is a commit and neither install-release.sh nor this script changed
#   between it and HEAD; an empty ref, an all-zero sha or a non-commit verifies everything.
#
# refresh: per tool, the candidate is the highest release that is past its cooldown
#   (not a draft or prerelease, published at least HOV_PIN_MIN_AGE_DAYS ago). A pin never
#   moves backwards or to an equal version. At the chosen version every platform row the
#   tool should have is rebuilt (on a move) or added (when missing): the asset and the
#   publisher's checksum file are downloaded, our sha256 must equal the publisher's
#   listed value, the archive must list the expected members, and for attested tools
#   `gh attestation verify` must pass. All or nothing: if anything fails, no plan line is
#   written and install-release.sh is not touched. PLAN_FILE gets one TSV line per
#   changed tool: tool, old version, new version, comma-joined platforms added or changed.
#   An empty PLAN_FILE means no drift. With ROWS_FILE set, a successful run also writes
#   there every row of the new TABLE, in table order: the input `apply` takes. jsm is not
#   on GitHub and has no public latest-version endpoint, so its pinned binary is run as
#   `update --check --json` from a read-only copy (it updates itself otherwise), in the
#   scratch environment.
#
# apply: writes the rows in <rows-file> into the TABLE of INSTALL_RELEASE once they are
#   proven to be rows refresh could have written: one per tool and platform the metadata
#   names, in its order; one x.y.z version per tool, no lower than the table's; the url
#   and members that tool, version and platform fix; a 64-hex sha256; and a tool that
#   keeps its version keeps its rows byte for byte. It downloads and runs nothing, so the
#   refresh workflow's job that holds the bot's key can run it on rows produced by the
#   other job, the one that ran the downloaded programs. PLAN_FILE gets the plan, as for
#   refresh. Any problem refuses every row and changes nothing.
#
# The scratch environment: a program this script downloaded runs under `env -i` with
# PATH, the proxy settings and a fresh HOME, XDG dirs and TMPDIR, so neither a token in
# the caller's environment (GH_TOKEN in CI) nor the caller's own config reaches it.
#
# Env:
#   INSTALL_RELEASE                  refresh, apply: path to install-release.sh (default below)
#   PLAN_FILE                        refresh, apply: required; truncated first
#   ROWS_FILE                        refresh: optional; gets the new TABLE rows on success
#   HOV_PIN_MIN_AGE_DAYS             cooldown in days (default 3)
#   GH_TOKEN                         for gh api and gh attestation verify
#   HOV_PINS_PLATFORM                test-only: this machine's platform (default: uname)
#   HOV_PINS_NOW                     test-only: epoch seconds standing in for now
#   HOV_PINS_GITHUB_DOWNLOAD_BASE    test-only: default https://github.com
#   HOV_PINS_JSM_BASE                test-only: default the jsm download base
#   HOV_PINS_TEST_ALLOW_FILE         test-only: 1 lets downloads read file:// urls
#                                    (otherwise https only, redirects included)
#
# Exit codes:
#   0  everything passed (verify) / the plan is computed and, with --write, applied
#   1  a pin failed verification, a refresh step failed, or apply refused the rows
#      (nothing was changed)
#   2  usage error

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'usage: release-pins.sh verify [--table-from <file>] [--if-changed-since <ref>]\n' >&2
  printf '       release-pins.sh refresh [--write]   (env: PLAN_FILE required)\n' >&2
  printf '       release-pins.sh apply <rows-file>   (env: PLAN_FILE required)\n' >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF_REL='release/scripts/release-pins.sh'
IR_REL='plugins/hov-stack/skills/hov-setup/scripts/install-release.sh'
DEFAULT_IR="$ROOT/$IR_REL"

GITHUB_BASE="${HOV_PINS_GITHUB_DOWNLOAD_BASE:-https://github.com}"
JSM_BASE="${HOV_PINS_JSM_BASE:-https://jeffreys-skills.md/api/v1/downloads/jsm}"

# ---------------------------------------------------------------------------
# Per-tool metadata: the single source of truth. {V} is the version.
#
# META    tool|source|repo|tag prefix|checksum file|attested
#   source github: assets are <GITHUB_BASE>/<repo>/releases/download/<prefix><V>/<asset>
#   source jsm:    assets are <JSM_BASE>/v<V>/<asset>; repo is unused
# ASSETS  tool|platform|asset|members (comma-separated paths inside the archive)
#   Row order in the table follows this order: tools as listed, platforms as listed.
#   Only supported release platforms are listed. Refresh adds a missing platform row
#   at the current version. cass has no darwin-x86_64 build.
# ---------------------------------------------------------------------------
META='
gh|github|cli/cli|v|gh_{V}_checksums.txt|yes
uv|github|astral-sh/uv||sha256.sum|yes
cass|github|Dicklesworthstone/coding_agent_session_search|v|SHA256SUMS|no
jsm|jsm||v|SHA256SUMS|no
'
ASSETS='
gh|linux-x86_64|gh_{V}_linux_amd64.tar.gz|gh_{V}_linux_amd64/bin/gh
gh|linux-aarch64|gh_{V}_linux_arm64.tar.gz|gh_{V}_linux_arm64/bin/gh
gh|darwin-arm64|gh_{V}_macOS_arm64.zip|gh_{V}_macOS_arm64/bin/gh
gh|darwin-x86_64|gh_{V}_macOS_amd64.zip|gh_{V}_macOS_amd64/bin/gh
uv|linux-x86_64|uv-x86_64-unknown-linux-gnu.tar.gz|uv-x86_64-unknown-linux-gnu/uv,uv-x86_64-unknown-linux-gnu/uvx
uv|linux-aarch64|uv-aarch64-unknown-linux-gnu.tar.gz|uv-aarch64-unknown-linux-gnu/uv,uv-aarch64-unknown-linux-gnu/uvx
uv|darwin-arm64|uv-aarch64-apple-darwin.tar.gz|uv-aarch64-apple-darwin/uv,uv-aarch64-apple-darwin/uvx
uv|darwin-x86_64|uv-x86_64-apple-darwin.tar.gz|uv-x86_64-apple-darwin/uv,uv-x86_64-apple-darwin/uvx
cass|linux-x86_64|cass-linux-amd64.tar.gz|cass
cass|linux-aarch64|cass-linux-arm64.tar.gz|cass
cass|darwin-arm64|cass-darwin-arm64.tar.gz|cass
jsm|linux-x86_64|jsm-x86_64-unknown-linux-musl.tar.gz|jsm
jsm|linux-aarch64|jsm-aarch64-unknown-linux-gnu.tar.gz|jsm
jsm|darwin-arm64|jsm-aarch64-apple-darwin.tar.gz|jsm
jsm|darwin-x86_64|jsm-x86_64-apple-darwin.tar.gz|jsm
'

TABLE_OPEN="TABLE=\${HOV_SETUP_RELEASE_TABLE:-'"
TABLE_CLOSE="'}"

WORK="$(mktemp -d)"
IR_TMP=''   # the rewrite's temp file beside install-release.sh, while one exists
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
  [ -z "$IR_TMP" ] || rm -f "$IR_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  sha_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  fail 'neither sha256sum nor shasum is available'
fi

# https only, redirects included. The asset and the publisher's checksum file come over
# the same channel, so a redirect to http or to another scheme would let anyone on the
# path forge both. The tests serve file:// fixtures and set HOV_PINS_TEST_ALLOW_FILE=1.
PROTO='=https'
[ "${HOV_PINS_TEST_ALLOW_FILE:-}" != 1 ] || PROTO='=https,file'
download() { curl -fsSL --proto "$PROTO" --proto-redir '=https' --retry 2 --connect-timeout 15 -o "$2" "$1"; }

# Fill SCRATCH_ENV for `env -i "${SCRATCH_ENV[@]}" <program>`: PATH, the proxy settings,
# LC_ALL=C and a fresh HOME, XDG dirs and TMPDIR under $1. A program this script
# downloaded gets that and nothing else, so no token or config of the caller reaches it.
SCRATCH_ENV=()
scratch_env() { # dir
  local d=$1 v
  mkdir -p "$d/home" "$d/config" "$d/data" "$d/cache" "$d/state" "$d/tmp"
  SCRATCH_ENV=("PATH=$PATH" "HOME=$d/home" "XDG_CONFIG_HOME=$d/config" "XDG_DATA_HOME=$d/data"
    "XDG_CACHE_HOME=$d/cache" "XDG_STATE_HOME=$d/state" "TMPDIR=$d/tmp" "LC_ALL=C")
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy; do
    [ -z "${!v:-}" ] || SCRATCH_ENV+=("$v=${!v}")
  done
}

detect_platform() {
  if [ -n "${HOV_PINS_PLATFORM:-}" ]; then printf '%s' "$HOV_PINS_PLATFORM"; return; fi
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) printf 'darwin-arm64' ;;
    Darwin/x86_64)
      local translated
      if translated=$(sysctl -n sysctl.proc_translated 2>/dev/null) &&
        [[ "$translated" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
        printf 'darwin-arm64'
      else
        printf 'darwin-x86_64'
      fi ;;
    Linux/x86_64) printf 'linux-x86_64' ;;
    Linux/aarch64 | Linux/arm64) printf 'linux-aarch64' ;;
    *) printf '%s-%s' "$(uname -s)" "$(uname -m)" ;;
  esac
}

# Replace {V} in $1 with $2.
tmpl() { printf '%s' "${1//\{V\}/$2}"; }

# x.y.z with at most six digits a field. A stray tag such as 0.0.99999999999999999999
# is not a release and is ignored, and every field fits shell arithmetic.
is_version() { [[ "$1" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; }
# vgt A B: version A is higher than B, field by field as numbers (0.10.0 is above
# 0.9.9). Both must pass is_version.
vgt() {
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
    if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
  done
  return 1
}

fmt_epoch() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ; }

meta_tools() { printf '%s\n' "$META" | awk -F'|' 'NF { print $1 }'; }
meta_field() { printf '%s\n' "$META" | awk -F'|' -v t="$1" -v i="$2" '$1 == t { print $i }'; }
asset_platforms() { printf '%s\n' "$ASSETS" | awk -F'|' -v t="$1" '$1 == t { print $2 }'; }
asset_field() { printf '%s\n' "$ASSETS" | awk -F'|' -v t="$1" -v p="$2" -v i="$3" '$1 == t && $2 == p { print $i }'; }

# Line numbers of the TABLE block in a file: TBL_START (the opening line) and TBL_END
# (the closing line). The rows are the lines between.
locate_table() {
  TBL_START=$(TABLE_OPEN="$TABLE_OPEN" awk '$0 == ENVIRON["TABLE_OPEN"] { print NR; exit }' "$1")
  [ -n "$TBL_START" ] || fail "no TABLE block opening in $1"
  TBL_END=$(TABLE_CLOSE="$TABLE_CLOSE" awk -v s="$TBL_START" 'NR > s && $0 == ENVIRON["TABLE_CLOSE"] { print NR; exit }' "$1")
  [ -n "$TBL_END" ] || fail "no TABLE block close in $1"
}
table_rows() {
  sed -n "$((TBL_START + 1)),$((TBL_END - 1))p" "$1" | grep -v '^[[:space:]]*$' || true
}

# Publisher checksum lookup: "<sha>  <name>" or the binary-mode "<sha> *<name>".
sum_lookup() { # file name
  awk -v name="$2" '{ gsub(/\r/, ""); n = $2; sub(/^\*/, "", n); sub(/^\.\//, "", n)
    if (n == name) { print tolower($1); exit } }' "$1"
}

# Member paths of an archive, one per line, without a leading ./
archive_members() {
  case $1 in
    *.tar.gz | *.tgz) tar -tzf "$1" ;;
    *.zip) unzip -Z1 "$1" ;;
    *) return 1 ;;
  esac | sed 's|^\./||'
}

# Sets REASON and returns 1 when a listed member (comma-separated) is absent.
check_members() { # archive members
  local listing m
  listing=$(archive_members "$1") || { REASON="cannot list $(basename "$1")"; return 1; }
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    # A here-string, not a pipe: grep -q stops at the first match, and under pipefail the
    # writer's SIGPIPE on a listing over one buffer would read as a missing member.
    if ! grep -qxF -- "$m" <<<"$listing"; then
      REASON="archive lacks member $m"
      return 1
    fi
  done <<EOF
$(printf '%s' "$2" | tr ',' '\n')
EOF
  return 0
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
REASON=''

verify_row() { # tool version platform url sha members; sets REASON
  local t=$1 p=$3 u=$4 s=$5 m=$6 d a got inst out rc=0
  d=$(mktemp -d "$WORK/row.XXXXXX")
  a=${u##*/}
  download "$u" "$d/$a" || { REASON="download failed: $u"; return 1; }
  got=$(sha_of "$d/$a")
  [ "$got" = "$s" ] || { REASON="sha256 is $got, pin is $s"; return 1; }
  check_members "$d/$a" "$m" || return 1
  if [ "$p" = "$PLATFORM" ]; then
    inst=$(mktemp -d "$WORK/inst.XXXXXX")
    mkdir "$inst/bin"
    scratch_env "$inst"
    out=$(env -i "${SCRATCH_ENV[@]}" HOV_SETUP_PLATFORM="$p" HOV_SETUP_BIN_DIR="$inst/bin" \
      bash "$TABLE_FROM" "$t" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      REASON="install-release.sh $t exited $rc: $(printf '%s' "$out" | tail -n 1)"
      return 1
    fi
  fi
  return 0
}

skip_unchanged() { # ref -> 0 when verify can be skipped
  local ref=$1 rel
  case $ref in '' | 0000000000000000000000000000000000000000) return 1 ;; esac
  git -C "$ROOT" cat-file -e "$ref^{commit}" 2>/dev/null || return 1
  rel=${TABLE_FROM#"$ROOT"/}
  git -C "$ROOT" diff --quiet "$ref" HEAD -- "$rel" "$SELF_REL" 2>/dev/null
}

cmd_verify() {
  TABLE_FROM=$DEFAULT_IR
  local since=''
  while [ $# -gt 0 ]; do
    case $1 in
      --table-from) [ $# -ge 2 ] || usage; TABLE_FROM=$2; shift 2 ;;
      --if-changed-since) [ $# -ge 2 ] || usage; since=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -f "$TABLE_FROM" ] || fail "no such file: $TABLE_FROM"

  if [ -n "${since:-}" ] && skip_unchanged "$since"; then
    printf 'pins not re-verified: neither %s nor %s changed since %s\n' \
      "$(basename "$TABLE_FROM")" "$(basename "$SELF_REL")" "$since"
    return 0
  fi

  PLATFORM=$(detect_platform)
  locate_table "$TABLE_FROM"
  local rows bad=0 n=0 t v p u s m
  rows=$(table_rows "$TABLE_FROM")
  [ -n "$rows" ] || fail "the TABLE in $TABLE_FROM has no rows"
  while IFS='|' read -r t v p u s m; do
    [ -n "$t" ] || continue
    n=$((n + 1))
    if verify_row "$t" "$v" "$p" "$u" "$s" "$m"; then
      printf 'ok %s %s %s\n' "$t" "$p" "$v"
    else
      printf 'FAIL %s %s: %s\n' "$t" "$p" "$REASON"
      bad=$((bad + 1))
    fi
  done <<EOF
$rows
EOF
  if [ "$bad" -gt 0 ]; then
    printf '%s of %s pinned rows failed\n' "$bad" "$n" >&2
    return 1
  fi
  printf 'all %s pinned rows verified\n' "$n"
}

# ---------------------------------------------------------------------------
# refresh
# ---------------------------------------------------------------------------
FAILS=0
note_fail() { printf 'FAIL %s %s: %s\n' "$1" "$2" "$3" >&2; FAILS=$((FAILS + 1)); }

# Where a tool's assets live at version $2.
release_dir_url() { # tool version
  if [ "$(meta_field "$1" 2)" = jsm ]; then
    printf '%s/v%s' "$JSM_BASE" "$2"
  else
    printf '%s/%s/releases/download/%s%s' "$GITHUB_BASE" "$(meta_field "$1" 3)" "$(meta_field "$1" 4)" "$2"
  fi
}

# Sets CAND (highest eligible version, or empty) and HELD_V/HELD_E (a newer release still
# in its cooldown, and the epoch it was published). $1 tool, $2 current version.
candidate_github() {
  local tool=$1 cur=$2 repo prefix json list v e best_all='' best_all_e=0 best_el=''
  repo=$(meta_field "$tool" 3)
  prefix=$(meta_field "$tool" 4)
  json=$(gh api "repos/$repo/releases?per_page=100") || { note_fail "$tool" all "gh api releases of $repo failed"; return 1; }
  list=$(printf '%s' "$json" | jq -r --arg prefix "$prefix" '
      .[] | select(.draft == false and .prerelease == false and .published_at != null)
      | select(.tag_name | startswith($prefix))
      | (.tag_name | ltrimstr($prefix)) as $v
      | select($v | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | "\($v) \(.published_at | fromdateiso8601)"') \
    || { note_fail "$tool" all "cannot parse the releases of $repo"; return 1; }
  while read -r v e; do
    is_version "$v" || continue
    if [ -z "$best_all" ] || vgt "$v" "$best_all"; then best_all=$v; best_all_e=$e; fi
    if [ "$e" -le "$CUTOFF" ] && { [ -z "$best_el" ] || vgt "$v" "$best_el"; }; then best_el=$v; fi
  done <<EOF
$list
EOF
  CAND=$best_el
  HELD_V=''; HELD_E=0
  local base=$cur
  [ -z "$CAND" ] || ! vgt "$CAND" "$cur" || base=$CAND
  if [ -n "$best_all" ] && vgt "$best_all" "$base"; then HELD_V=$best_all; HELD_E=$best_all_e; fi
  return 0
}

# jsm: run the pinned binary (sha checked) for its own idea of the latest version.
candidate_jsm() {
  local tool=$1 cur=$2 row u s m d a bin out target lm e
  row=$(awk -F'|' -v p="$PLATFORM" '$3 == p { print; exit }' <<<"$TOOL_ROWS")
  if [ -z "$row" ]; then
    note_fail "$tool" all "no pinned $tool row for $PLATFORM, so its binary cannot be run for update --check"
    return 1
  fi
  IFS='|' read -r _ _ _ u s m <<<"$row"
  d="$WORK/jsm-bin"
  rm -rf "$d"; mkdir -p "$d/dl" "$d/x"
  a=${u##*/}
  download "$u" "$d/dl/$a" || { note_fail "$tool" all "download of the pinned binary failed: $u"; return 1; }
  [ "$(sha_of "$d/dl/$a")" = "$s" ] || { note_fail "$tool" "$PLATFORM" "pinned binary sha256 is $(sha_of "$d/dl/$a"), pin is $s; not running it"; return 1; }
  tar -xzf "$d/dl/$a" -C "$d/x" || { note_fail "$tool" all "cannot extract the pinned binary"; return 1; }
  bin="$d/x/${m%%,*}"
  [ -f "$bin" ] || { note_fail "$tool" all "pinned binary ${m%%,*} is not in the archive"; return 1; }
  # It replaces itself on update: make the copy it runs from read-only.
  chmod -R a-w "$d/x"
  scratch_env "$d/env"
  out=$(cd "$d/env/home" && env -i "${SCRATCH_ENV[@]}" "$bin" update --check --json 2>"$d/err") \
    || { note_fail "$tool" all "update --check --json failed: $(tail -n 1 "$d/err")"; return 1; }
  target=$(printf '%s' "$out" | jq -r '.target_version // empty') \
    || { note_fail "$tool" all "update --check output is not JSON"; return 1; }
  target=${target#v}
  is_version "$target" || { note_fail "$tool" all "update --check gave no usable target_version"; return 1; }
  CAND=''; HELD_V=''; HELD_E=0
  vgt "$target" "$cur" || return 0
  lm=$(curl -fsSIL --proto "$PROTO" --proto-redir '=https' --connect-timeout 15 "$(release_dir_url "$tool" "$target")/$(meta_field "$tool" 5)" 2>/dev/null \
    | awk 'tolower($1) == "last-modified:" { sub(/^[^:]*: */, ""); gsub(/\r/, ""); v = $0 } END { print v }') || lm=''
  [ -n "$lm" ] || { note_fail "$tool" all "no Last-Modified for v$target, so its release date is unknown"; return 1; }
  e=$(date -u -d "$lm" +%s 2>/dev/null || date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "$lm" +%s 2>/dev/null) \
    || { note_fail "$tool" all "cannot read the date '$lm'"; return 1; }
  if [ "$e" -le "$CUTOFF" ]; then CAND=$target; else HELD_V=$target; HELD_E=$e; fi
  return 0
}

# Build the row for tool/version/platform into ROW, or note a failure and return 1.
gen_row() {
  local tool=$1 v=$2 plat=$3 asset members dir csname csurl url d pub ours att repo
  asset=$(tmpl "$(asset_field "$tool" "$plat" 3)" "$v")
  members=$(tmpl "$(asset_field "$tool" "$plat" 4)" "$v")
  dir=$(release_dir_url "$tool" "$v")
  csname=$(tmpl "$(meta_field "$tool" 5)" "$v")
  csurl="$dir/$csname"
  url="$dir/$asset"
  d="$WORK/dl/$tool/$v"
  mkdir -p "$d"
  if [ ! -f "$d/$csname" ]; then
    download "$csurl" "$d/$csname" || { note_fail "$tool" "$plat" "download of the checksum file failed: $csurl"; return 1; }
  fi
  download "$url" "$d/$asset" || { note_fail "$tool" "$plat" "download failed: $url"; return 1; }
  ours=$(sha_of "$d/$asset")
  pub=$(sum_lookup "$d/$csname" "$asset")
  [ -n "$pub" ] || { note_fail "$tool" "$plat" "the publisher's $csname does not list $asset"; return 1; }
  [[ "$pub" =~ ^[0-9a-f]{64}$ ]] || { note_fail "$tool" "$plat" "the publisher's checksum for $asset is not a sha256"; return 1; }
  [ "$ours" = "$pub" ] || { note_fail "$tool" "$plat" "sha256 is $ours, publisher lists $pub"; return 1; }
  check_members "$d/$asset" "$members" || { note_fail "$tool" "$plat" "$REASON"; return 1; }
  if [ "$(meta_field "$tool" 6)" = yes ]; then
    repo=$(meta_field "$tool" 3)
    att=$(gh attestation verify "$d/$asset" --repo "$repo" 2>&1) \
      || { note_fail "$tool" "$plat" "attestation verification failed for $asset: $(printf '%s' "$att" | tail -n 1)"; return 1; }
  fi
  ROW="$tool|$v|$plat|$url|$ours|$members"
  return 0
}

refresh_tool() {
  local tool=$1 vers cur chosen plat existing
  TOOL_ROWS=$(printf '%s\n' "$ROWS" | awk -F'|' -v t="$tool" '$1 == t')
  if [ -z "$TOOL_ROWS" ]; then note_fail "$tool" all 'no rows in the table'; return 0; fi
  vers=$(printf '%s\n' "$TOOL_ROWS" | cut -d'|' -f2 | sort -u)
  if [ "$(printf '%s\n' "$vers" | wc -l | tr -d ' ')" -ne 1 ]; then
    note_fail "$tool" all "rows pin different versions ($(printf '%s' "$vers" | tr '\n' ' '))"
    return 0
  fi
  cur=$vers
  is_version "$cur" || { note_fail "$tool" all "pinned version '$cur' is not x.y.z"; return 0; }

  CAND=''; HELD_V=''; HELD_E=0
  if [ "$(meta_field "$tool" 2)" = jsm ]; then
    candidate_jsm "$tool" "$cur" || return 0
  else
    candidate_github "$tool" "$cur" || return 0
  fi
  chosen=$cur
  if [ -n "$CAND" ] && vgt "$CAND" "$cur"; then chosen=$CAND; fi
  if [ -n "$HELD_V" ]; then
    printf '%s: %s is inside the %s-day cooldown; eligible %s\n' "$tool" "$HELD_V" "$DAYS" "$(fmt_epoch $((HELD_E + DAYS * 86400)))"
  fi
  if [ "$chosen" != "$cur" ]; then
    printf '%s: moving %s -> %s\n' "$tool" "$cur" "$chosen"
  else
    printf '%s: keeping %s\n' "$tool" "$cur"
  fi

  : > "$WORK/rows.$tool"
  for plat in $(asset_platforms "$tool"); do
    existing=$(awk -F'|' -v p="$plat" '$3 == p { print; exit }' <<<"$TOOL_ROWS")
    if [ "$chosen" = "$cur" ] && [ -n "$existing" ]; then
      printf '%s\n' "$existing" >> "$WORK/rows.$tool"
      continue
    fi
    if gen_row "$tool" "$chosen" "$plat"; then
      printf '%s\n' "$ROW" >> "$WORK/rows.$tool"
    fi
  done
}

cmd_refresh() {
  local write=0 arg
  for arg in "$@"; do
    case $arg in
      --write) write=1 ;;
      *) usage ;;
    esac
  done
  [ -n "${PLAN_FILE:-}" ] || { printf 'error: PLAN_FILE is not set\n' >&2; exit 2; }
  : > "$PLAN_FILE"
  INSTALL_RELEASE="${INSTALL_RELEASE:-$DEFAULT_IR}"
  [ -f "$INSTALL_RELEASE" ] || fail "no such file: $INSTALL_RELEASE"
  DAYS="${HOV_PIN_MIN_AGE_DAYS:-3}"
  [[ "$DAYS" =~ ^[0-9]+$ ]] || fail "HOV_PIN_MIN_AGE_DAYS must be a whole number, got '$DAYS'"
  NOW="${HOV_PINS_NOW:-$(date +%s)}"
  [[ "$NOW" =~ ^[0-9]+$ ]] || fail "HOV_PINS_NOW must be epoch seconds, got '$NOW'"
  CUTOFF=$((NOW - DAYS * 86400))
  PLATFORM=$(detect_platform)

  locate_table "$INSTALL_RELEASE"
  ROWS=$(table_rows "$INSTALL_RELEASE")
  : > "$WORK/plan"
  check_table_known

  local t
  if [ "$FAILS" -eq 0 ]; then
    for t in $(meta_tools); do refresh_tool "$t"; done
  fi
  : > "$WORK/newrows.all"
  if [ "$FAILS" -eq 0 ]; then
    for t in $(meta_tools); do cat "$WORK/rows.$t" >> "$WORK/newrows.all"; done
    # The plan comes from the same proof apply runs, so the two cannot disagree.
    check_rows "$WORK/newrows.all" || true
  fi
  if [ "$FAILS" -gt 0 ]; then
    printf 'refresh failed (%s problem(s)); nothing was changed\n' "$FAILS" >&2
    return 1
  fi

  if [ -s "$WORK/plan" ] && [ "$write" -eq 1 ]; then
    write_table "$INSTALL_RELEASE" "$WORK/newrows.all"
  fi
  [ -z "${ROWS_FILE:-}" ] || cp "$WORK/newrows.all" "$ROWS_FILE"
  cp "$WORK/plan" "$PLAN_FILE"
  report_plan "$write"
}

cmd_apply() {
  [ $# -eq 1 ] || usage
  local rows=$1
  [ -n "${PLAN_FILE:-}" ] || { printf 'error: PLAN_FILE is not set\n' >&2; exit 2; }
  : > "$PLAN_FILE"
  INSTALL_RELEASE="${INSTALL_RELEASE:-$DEFAULT_IR}"
  [ -f "$INSTALL_RELEASE" ] || fail "no such file: $INSTALL_RELEASE"
  [ -f "$rows" ] || fail "no such file: $rows"
  locate_table "$INSTALL_RELEASE"
  ROWS=$(table_rows "$INSTALL_RELEASE")
  : > "$WORK/plan"
  check_table_known
  if [ "$FAILS" -eq 0 ]; then check_rows "$rows" || true; fi
  if [ "$FAILS" -gt 0 ]; then
    printf 'apply refused the rows (%s problem(s)); nothing was changed\n' "$FAILS" >&2
    return 1
  fi
  [ ! -s "$WORK/plan" ] || write_table "$INSTALL_RELEASE" "$rows"
  cp "$WORK/plan" "$PLAN_FILE"
  report_plan 1
}

# A row the metadata does not know would be dropped by a rewrite: refuse instead.
check_table_known() {
  local t p
  while IFS='|' read -r t _ p _; do
    [ -n "$t" ] || continue
    [ -n "$(asset_field "$t" "$p" 3)" ] \
      || note_fail "$t" "$p" 'the table has a row the release-pins metadata does not describe'
  done <<EOF
$ROWS
EOF
}

# Prove that the rows in $1 are rows refresh could have written over the table's ROWS
# (see apply in the header), and append the plan to $WORK/plan. Notes every problem;
# returns 1 if there was any.
check_rows() { # rows-file
  local f=$1 before=$FAILS want got t v p u s m extra tool vers oldv old line changed
  want=$(printf '%s\n' "$ASSETS" | awk -F'|' 'NF { print $1 "|" $2 }')
  got=$(awk -F'|' '{ print $1 "|" $3 }' "$f")
  if [ "$got" != "$want" ]; then
    note_fail rows all 'not exactly one row per tool and platform of the metadata, in its order'
    return 1
  fi
  # `|| [ -n "$t" ]` reads a last line that has no newline.
  while IFS='|' read -r t v p u s m extra || [ -n "$t" ]; do
    [ -z "$extra" ] || { note_fail "$t" "$p" 'the row has more than six fields'; continue; }
    is_version "$v" || { note_fail "$t" "$p" "version '$v' is not x.y.z"; continue; }
    [ "$u" = "$(release_dir_url "$t" "$v")/$(tmpl "$(asset_field "$t" "$p" 3)" "$v")" ] \
      || note_fail "$t" "$p" "the url is not the $t $v release asset for $p: $u"
    [[ "$s" =~ ^[0-9a-f]{64}$ ]] || note_fail "$t" "$p" 'the sha256 is not 64 lowercase hex digits'
    [ "$m" = "$(tmpl "$(asset_field "$t" "$p" 4)" "$v")" ] \
      || note_fail "$t" "$p" "the members are not the $t $v members for $p"
  done < "$f"
  [ "$FAILS" -eq "$before" ] || return 1

  for tool in $(meta_tools); do
    vers=$(awk -F'|' -v t="$tool" '$1 == t { print $2 }' "$f" | sort -u)
    oldv=$(printf '%s\n' "$ROWS" | awk -F'|' -v t="$tool" '$1 == t { print $2 }' | sort -u)
    if [ "$(printf '%s\n' "$vers" | wc -l | tr -d ' ')" -ne 1 ]; then
      note_fail "$tool" all "the rows pin different versions ($(printf '%s' "$vers" | tr '\n' ' '))"
      continue
    fi
    if [ -z "$oldv" ] || [ "$(printf '%s\n' "$oldv" | wc -l | tr -d ' ')" -ne 1 ] || ! is_version "$oldv"; then
      note_fail "$tool" all 'the table does not pin one x.y.z version'
      continue
    fi
    if vgt "$oldv" "$vers"; then
      note_fail "$tool" all "the rows move it backwards, $oldv -> $vers"
      continue
    fi
    changed=''
    while IFS= read -r line; do
      p=$(printf '%s' "$line" | cut -d'|' -f3)
      old=$(awk -F'|' -v t="$tool" -v p="$p" '$1 == t && $3 == p { print; exit }' <<<"$ROWS")
      [ "$line" != "$old" ] || continue
      if [ "$vers" = "$oldv" ] && [ -n "$old" ]; then
        note_fail "$tool" "$p" "the row changes while $tool stays at $vers"
        continue
      fi
      changed="${changed:+$changed,}$p"
    done <<EOF
$(awk -F'|' -v t="$tool" '$1 == t' "$f")
EOF
    [ -z "$changed" ] || printf '%s\t%s\t%s\t%s\n' "$tool" "$oldv" "$vers" "$changed" >> "$WORK/plan"
  done
  [ "$FAILS" -eq "$before" ]
}

# Replace the TABLE rows of $1 (located by locate_table) with the lines of $2. The new
# file is built beside the old one and renamed over it, so a reader sees the old file or
# the new one, never half of one, and the EXIT trap removes a temp file a failure leaves.
# awk ends every row with a newline, even a last one that had none.
write_table() { # file rows-file
  IR_TMP=$(mktemp "$(dirname "$1")/.install-release.XXXXXX")
  cp -p "$1" "$IR_TMP"
  { head -n "$TBL_START" "$1"; awk '{ print }' "$2"; tail -n +"$TBL_END" "$1"; } > "$IR_TMP" \
    || fail "could not build the new $1"
  mv "$IR_TMP" "$1"
  IR_TMP=''
}

report_plan() { # written: 0 or 1
  if [ -s "$PLAN_FILE" ]; then
    printf 'plan: %s tool(s) to change%s\n' "$(wc -l < "$PLAN_FILE" | tr -d ' ')" "$([ "$1" -eq 1 ] && printf ' (written)')"
  else
    printf 'plan: no drift\n'
  fi
}

# ---------------------------------------------------------------------------
[ $# -ge 1 ] || usage
cmd=$1; shift
case $cmd in
  verify) cmd_verify "$@" ;;
  refresh) cmd_refresh "$@" ;;
  apply) cmd_apply "$@" ;;
  *) usage ;;
esac

