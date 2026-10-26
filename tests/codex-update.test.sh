#!/usr/bin/env bash
# Tests for scripts/codex-update.sh — verified stable Codex CLI updates through pnpm
# (dotfiles#1377).
#
# Hermetic: a PATH-local fake pnpm reproduces the global layout that matters here
# (.pnpm/@openai+codex@V, its npm:-aliased native package, a bin shim, a store that
# --offline installs can only draw from, and old-version pruning on re-add), the
# registry is a file:// tree, and /proc is a fixture. Nothing touches the network,
# the real pnpm store or ~/.local/bin. Real pnpm is exercised by
# codex-update-live.test.sh (manual-only).
#
# The cases that matter most: the cooldown exception names exact versions of the one
# official package and nothing broader (3); a running Codex session defers promotion
# instead of having its package dir pruned under it (8); a promotion that smoke-fails
# restores the prior exact version from local material alone (10).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/codex-update.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ── fake pnpm ─────────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/stub"
cat >"$TMP/stub/pnpm" <<'FAKE'
#!/usr/bin/env bash
# Fake pnpm: global add/root/bin/ls against --config.global-dir/--config.global-bin-dir.
F=${FAKE_DIR:?}
gdir="" bdir="" offline=0 spec="" mode=none rc=""
for a in "$@"; do
  case "$a" in
    --config.global-dir=*) gdir=${a#*=} ;;
    --config.global-bin-dir=*) bdir=${a#*=} ;;
    --offline) offline=1 ;;
    @openai/codex@*) spec=$a ;;
  esac
done
if [ -n "${npm_config_userconfig:-}" ] && [ -f "$npm_config_userconfig" ]; then
  rc=$(paste -sd'~' "$npm_config_userconfig")
  mode=$(stat -c %a "$npm_config_userconfig")
fi
printf 'ARGS %s\tMODE %s\tRC %s\n' "$*" "$mode" "$rc" >>"$F/log"
root="$gdir/5/node_modules"
# pnpm's metadata cache: --offline cannot resolve a version it does not list, and
# `pnpm store prune` deletes all of it (measured on 10.33.2).
meta="$F/cache/metadata-ff-v1.3/registry.npmjs.org/@openai/codex.json"
case "${1:-}" in
  config) [ "${2:-} ${3:-}" = "get cache-dir" ] && { echo "$F/cache"; exit 0; }; exit 2 ;;
  root) echo "$root"; exit 0 ;;
  bin) echo "$bdir"; exit 0 ;;
  ls) jq -c '[{dependencies: (to_entries | map({key, value: {version: .value}}) | from_entries)}]' "$F/others.json"; exit 0 ;;
  add) ;;
  *) echo "fake pnpm: unsupported ${1:-}" >&2; exit 2 ;;
esac
v=${spec#@openai/codex@}
[ -n "$spec" ] || { echo "fake pnpm: no codex spec" >&2; exit 2; }
if grep -qxF -e "$gdir $v" -e "* $v" "$F/fail_add" 2>/dev/null; then
  # pnpm can echo a registry URL or auth header taken from ~/.npmrc in its errors.
  [ -f "$F/leak" ] && echo " GET https://ci:s3cr3t@registry.example.com/x Authorization: Bearer tok_ABC123 //registry.example.com/:_authToken=npm_XYZ789" >&2
  echo " ERR_PNPM_TARBALL_INTEGRITY  fake integrity failure for $v" >&2; exit 1
fi
if [ "$offline" = 1 ] && ! grep -qxF "$v" "$F/store"; then
  echo " ERR_PNPM_NO_OFFLINE_TARBALL  fake: $v is not in the store" >&2; exit 1
fi
if [ "$offline" = 1 ] && ! grep -qxF "$v" "$meta" 2>/dev/null; then
  echo " ERR_PNPM_NO_OFFLINE_META  fake: no cached metadata lists $v" >&2; exit 1
fi
if grep -qxF "$v" "$F/immature" 2>/dev/null; then
  mature=1
  case "$rc" in *"minimum-release-age-exclude[]=@openai/codex@$v ||"*) ;; *) mature=0 ;; esac
  for s in $(cat "$F/suffixes"); do
    case "$rc" in *"|| $v-$s"*) ;; *) mature=0 ;; esac
  done
  if [ "$mature" = 0 ]; then
    echo " ERR_PNPM_NO_MATURE_MATCHING_VERSION  fake: $v is inside the cooldown" >&2; exit 1
  fi
fi
mkdir -p "$root/@openai" "$bdir"
rm -rf "$root"/.pnpm/@openai+codex@*
pkg="$root/.pnpm/@openai+codex@$v/node_modules/@openai/codex"
mkdir -p "$pkg"
opt=""
for s in $(cat "$F/suffixes"); do opt="$opt\"@openai/codex-$s\":\"npm:@openai/codex@$v-$s\","; done
printf '{"name":"@openai/codex","version":"%s","optionalDependencies":{%s}}\n' "$v" "${opt%,}" >"$pkg/package.json"
if ! grep -qxF "$v" "$F/no_native" 2>/dev/null; then
  nat="$root/.pnpm/@openai+codex@$v-linux-x64/node_modules/@openai/codex"
  mkdir -p "$nat"
  printf '{"name":"@openai/codex","version":"%s-linux-x64"}\n' "$v" >"$nat/package.json"
  ln -sfn "../../../@openai+codex@$v-linux-x64/node_modules/@openai/codex" \
    "$root/.pnpm/@openai+codex@$v/node_modules/@openai/codex-linux-x64"
fi
rm -f "$root/@openai/codex"
ln -s "../.pnpm/@openai+codex@$v/node_modules/@openai/codex" "$root/@openai/codex"
report="codex-cli $v"
o=$(grep -F "$bdir $v " "$F/report_override" 2>/dev/null | head -1 | cut -d' ' -f3-)
[ -n "$o" ] && report=$o
if grep -qxF "$bdir $v" "$F/broken" 2>/dev/null; then
  printf '#!/usr/bin/env bash\necho "codex: native binary missing" >&2\nexit 1\n' >"$bdir/codex"
else
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "%s" ;; --help) echo "usage: codex" ;; *) exit 64 ;; esac\n' \
    "$report" >"$bdir/codex"
fi
chmod +x "$bdir/codex"
[ "$offline" = 1 ] || grep -qxF "$v" "$F/store" || echo "$v" >>"$F/store"
if [ "$offline" != 1 ]; then
  mkdir -p "${meta%/*}"
  grep -qxF "$v" "$meta" 2>/dev/null || echo "$v" >>"$meta"
fi
if [ -f "$F/mutate_other" ] && [ "$gdir" = "$(cat "$F/live_gdir")" ]; then
  jq '.["left-pad"] = "9.9.9"' "$F/others.json" >"$F/others.tmp" && mv "$F/others.tmp" "$F/others.json"
fi
exit 0
FAKE
chmod +x "$TMP/stub/pnpm"
# Fake notifier: one line per notice, so a test can count them.
cat >"$TMP/stub/notify" <<'FAKE'
#!/usr/bin/env bash
[ -f "${FAKE_DIR:?}/notify_fail" ] && exit 1
printf '%s|%s\n' "$1" "${2:-}" >>"${FAKE_DIR:?}/notify"
FAKE
chmod +x "$TMP/stub/notify"

# ── fixtures ──────────────────────────────────────────────────────────────────────────
SUFFIXES="linux-x64 linux-arm64 darwin-x64 darwin-arm64 win32-x64 win32-arm64"

# new_case <name> [live-version]: fresh dirs plus a live pnpm install of the prior version.
new_case() {
  C="$TMP/case-$1"
  mkdir -p "$C/fake" "$C/proc/1" "$C/state" "$C/lib" "$C/bin"
  # A real process table is never empty; the updater refuses to promote blind when it is.
  printf 'init\0' >"$C/proc/1/cmdline"
  : >"$C/fake/log"; : >"$C/fake/store"
  echo '{"left-pad":"1.3.0","typescript":"5.9.2"}' >"$C/fake/others.json"
  echo "$SUFFIXES" >"$C/fake/suffixes"
  echo "$C/global" >"$C/fake/live_gdir"
  printf 'registry=https://registry.npmjs.org/\n' >"$C/npmrc"
  FAKE_DIR="$C/fake" "$TMP/stub/pnpm" add -g "@openai/codex@${2:-0.156.0}" \
    --config.global-dir="$C/global" --config.global-bin-dir="$C/bin" >/dev/null
  : >"$C/fake/log"
}

# reg_publish <version> [optionalDependencies-json]: candidate + host native manifests.
reg_publish() {
  local v=$1 opt=${2:-} d="$C/reg/@openai/codex"
  mkdir -p "$d"
  if [ -z "$opt" ]; then
    opt=$(jq -cn --arg v "$v" --arg s "$SUFFIXES" \
      '$s | split(" ") | map({key: "@openai/codex-\(.)", value: "npm:@openai/codex@\($v)-\(.)"}) | from_entries')
  fi
  jq -cn --arg v "$v" --argjson opt "$opt" \
    '{name: "@openai/codex", version: $v, optionalDependencies: $opt, dist: {integrity: "sha512-fake"}}' >"$d/$v"
  jq -cn --arg v "$v" \
    '{name: "@openai/codex", version: "\($v)-linux-x64", os: ["linux"], cpu: ["x64"], dist: {integrity: "sha512-fakenative"}}' \
    >"$d/$v-linux-x64"
}
reg_latest() {
  mkdir -p "$C/reg/-/package/@openai/codex"
  jq -cn --arg l "$1" '{latest: $l, alpha: "0.158.0-alpha.2.1"}' >"$C/reg/-/package/@openai/codex/dist-tags"
}

# run [args...]: DRY=default leaves DRY_RUN unset so the script's own default applies.
run() {
  local -a dr=(DRY_RUN="${DRY:-0}")
  [ "${DRY:-}" = default ] && dr=()
  env -u DRY_RUN "${dr[@]}" \
    PATH="${PRE_PATH:+$PRE_PATH:}$C/bin:$TMP/stub:$PATH" FAKE_DIR="$C/fake" \
    CODEX_UPDATE_PNPM="$TMP/stub/pnpm" \
    CODEX_UPDATE_REGISTRY="file://$C/reg" \
    CODEX_UPDATE_STATE_DIR="$C/state" CODEX_UPDATE_LIB_DIR="$C/lib" \
    CODEX_UPDATE_GLOBAL_DIR="$C/global" CODEX_UPDATE_BIN_DIR="$C/bin" \
    CODEX_UPDATE_NPMRC="$C/npmrc" CODEX_UPDATE_PROC_ROOT="$C/proc" \
    CODEX_UPDATE_PLATFORM="${PLAT-linux-x64}" CODEX_UPDATE_NOTIFY="$TMP/stub/notify" \
    bash "$SCRIPT" "$@" 2>&1
}
notes() { if [ -f "$C/fake/notify" ]; then wc -l <"$C/fake/notify" | tr -d ' '; else echo 0; fi; }
held() { cat "$C/state/hold" 2>/dev/null; }
live_ver() { "$C/bin/codex" --version 2>/dev/null; }
rec_ver() { jq -r .version "$C/state/verified-version.json" 2>/dev/null; }
outcome() { jq -r .outcome "$C/state/status.json" 2>/dev/null; }
adds() { grep -c '^ARGS add' "$C/fake/log"; }
live_adds() { grep '^ARGS add' "$C/fake/log" | grep -F -- "--config.global-dir=$C/global" | grep -c .; }

# ── 1. already current: no install, and a record for the verified live version ────────
new_case 1; reg_latest 0.156.0; reg_publish 0.156.0
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok || bad "1: current run exited $rc: $out"
has "$out" "codex current: 0.156.0" && ok || bad "1: no current line: $out"
[ "$(adds)" = 0 ] && ok || bad "1: pnpm add ran for an already-current install"
[ "$(rec_ver)" = 0.156.0 ] && ok || bad "1: no record for the verified current version"
jq -e 'keys == ["packageName","schemaVersion","verifiedAt","version"] and .schemaVersion == 1
  and .packageName == "@openai/codex"
  and (.verifiedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"))' \
  "$C/state/verified-version.json" >/dev/null 2>&1 && ok || bad "1: record shape is not what better-ccflare reads"
[ "$(outcome)" = current ] && ok || bad "1: status outcome is '$(outcome)', not current"

# ── 2. the default is report-only ─────────────────────────────────────────────────────
new_case 2; reg_latest 0.157.1; reg_publish 0.157.1
out=$(DRY=default run); rc=$?
[ "$rc" -eq 0 ] && ok || bad "2: dry run exited $rc: $out"
has "$out" "would update codex 0.156.0 -> 0.157.1" && ok || bad "2: no would-update line: $out"
[ "$(adds)" = 0 ] && ok || bad "2: the default run installed something"
[ "$(live_ver)" = "codex-cli 0.156.0" ] && ok || bad "2: live install changed on a dry run"
[ ! -e "$C/state/verified-version.json" ] && [ ! -e "$C/state/status.json" ] && ok \
  || bad "2: a dry run wrote state"

# ── 3. promotion inside the cooldown: exact exclude for every declared alias, no more ──
new_case 3; reg_latest 0.157.1; reg_publish 0.157.1; echo 0.157.1 >"$C/fake/immature"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok || bad "3: promotion exited $rc: $out"
has "$out" "codex promoted: 0.156.0 -> 0.157.1" && ok || bad "3: no promoted line: $out"
[ "$(live_ver)" = "codex-cli 0.157.1" ] && ok || bad "3: live reports '$(live_ver)'"
[ "$(rec_ver)" = 0.157.1 ] && ok || bad "3: record is '$(rec_ver)', not 0.157.1"
[ "$(outcome)" = promoted ] && ok || bad "3: status outcome is '$(outcome)'"
# Only two exceptions ever appear: the candidate (staging, promotion) and the version
# being retained (it may itself be under a day old), each naming exact versions of the
# official package and every alias its own manifest declares.
want_c='minimum-release-age-exclude[]=@openai/codex@0.157.1 || 0.157.1-darwin-arm64 || 0.157.1-darwin-x64 || 0.157.1-linux-arm64 || 0.157.1-linux-x64 || 0.157.1-win32-arm64 || 0.157.1-win32-x64'
want_p='minimum-release-age-exclude[]=@openai/codex@0.156.0 || 0.156.0-darwin-arm64 || 0.156.0-darwin-x64 || 0.156.0-linux-arm64 || 0.156.0-linux-x64 || 0.156.0-win32-arm64 || 0.156.0-win32-x64'
excl=$(grep -o 'minimum-release-age-exclude[^~]*' "$C/fake/log" | sort -u)
[ "$excl" = "$(printf '%s\n%s\n' "$want_c" "$want_p" | sort -u)" ] && ok \
  || bad "3: exclude lines were not exactly the declared exact versions: $excl"
grep '^ARGS add' "$C/fake/log" | grep -F -- '@openai/codex@0.157.1 ' | grep -vqF "$want_c" \
  && bad "3: a candidate install ran without its exact exception" || ok
grep -q -e 'minimum-release-age=' -e 'minimum-release-age-exclude=' "$C/fake/log" \
  && bad "3: the cooldown itself was overridden or a string-form exclude was used" || ok
[ "$(grep '^ARGS add' "$C/fake/log" | grep -vc 'MODE 600')" = 0 ] && ok || bad "3: an add ran with a non-private rc"
[ "$(grep '^ARGS add' "$C/fake/log" | grep -vc 'RC registry=https://registry.npmjs.org/')" = 0 ] && ok \
  || bad "3: the operator's npmrc was not carried into the per-run rc"
[ -z "$(find "$C/state" "$C/lib" -name 'npmrc*' -print -quit)" ] && ok || bad "3: the per-run rc outlived the run"
grep '^ARGS add' "$C/fake/log" | grep -F -- "--config.global-dir=$C/global" | grep -F '@openai/codex@0.157.1' \
  | grep -q -- '--offline' && ok || bad "3: the live promotion was not drawn from the staged store (--offline)"
[ "$("$C/lib/retained/0.156.0/bin/codex" --version 2>/dev/null)" = "codex-cli 0.156.0" ] && ok \
  || bad "3: the previous version was not retained as a runnable copy"
[ ! -e "$C/lib/staging/0.157.1" ] && ok || bad "3: staging dir left behind"

# ── 4. a prerelease on `latest` is rejected, never installed ──────────────────────────
# A rejected candidate is the gate working (dotfiles#518: cass-release-promote's
# reject/fail split): exit 0 so OnFailure does not page, one notice, no repeat notices.
new_case 4; reg_latest 0.158.0-alpha.2.1; reg_publish 0.158.0-alpha.2.1
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "REJECTED" && ok || bad "4: prerelease latest was not a clean rejection ($rc): $out"
has "$out" "not a stable release" && ok || bad "4: no stable-release refusal: $out"
[ "$(adds)" = 0 ] && ok || bad "4: a prerelease was installed"
[ "$(outcome)" = rejected ] && [ "$(notes)" = 1 ] && ok || bad "4: outcome '$(outcome)' with $(notes) notices"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ "$(notes)" = 1 ] && ok || bad "4: the next tick re-notified or failed ($rc, $(notes) notices): $out"

# ── 5. a registry that moved backwards is not a downgrade order ───────────────────────
new_case 5 0.157.1; reg_latest 0.156.0; reg_publish 0.156.0
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok || bad "5: downgrade case exited $rc: $out"
has "$out" "refusing downgrade" && ok || bad "5: no downgrade refusal: $out"
[ "$(adds)" = 0 ] && [ "$(live_ver)" = "codex-cli 0.157.1" ] && ok || bad "5: live install was downgraded"

# ── 6. manifest checks: foreign alias target, missing host alias, missing host artifact ─
new_case 6a; reg_latest 0.157.1
reg_publish 0.157.1 '{"@openai/codex-linux-x64":"npm:evil-codex@0.157.1-linux-x64"}'
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "manifest check failed" && has "$out" "REJECTED" && [ "$(adds)" = 0 ] && ok \
  || bad "6a: a foreign alias target was accepted ($rc): $out"
[ "$(held)" = 0.157.1 ] && [ "$(outcome)" = rejected ] && [ "$(notes)" = 1 ] && ok \
  || bad "6a: rejection not held/recorded/notified once (hold '$(held)', outcome '$(outcome)', $(notes) notices)"
new_case 6b; reg_latest 0.157.1
reg_publish 0.157.1 '{"@openai/codex-darwin-arm64":"npm:@openai/codex@0.157.1-darwin-arm64"}'
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "manifest check failed" && [ "$(adds)" = 0 ] && [ "$(held)" = 0.157.1 ] && ok \
  || bad "6b: a candidate without the host alias was accepted ($rc): $out"
# A manifest that cannot be fetched is not evidence against the release (registry
# propagation, a network blip): defer, never hold, and promote once it appears.
new_case 6c; reg_latest 0.157.1; reg_publish 0.157.1; rm "$C/reg/@openai/codex/0.157.1-linux-x64"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "deferred" && [ "$(adds)" = 0 ] && [ -z "$(held)" ] && ok \
  || bad "6c: an unfetchable host artifact manifest was not a plain deferral ($rc, hold '$(held)'): $out"
reg_publish 0.157.1
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "codex promoted: 0.156.0 -> 0.157.1" && ok \
  || bad "6c: the release did not promote once its manifest appeared ($rc): $out"
new_case 6d; reg_latest 0.157.1; reg_publish 0.157.1
jq '.cpu = ["arm64"]' "$C/reg/@openai/codex/0.157.1-linux-x64" >"$C/native.tmp" \
  && mv "$C/native.tmp" "$C/reg/@openai/codex/0.157.1-linux-x64"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "REJECTED" && [ "$(adds)" = 0 ] && [ "$(held)" = 0.157.1 ] && ok \
  || bad "6d: a host artifact for the wrong cpu was accepted ($rc): $out"

# ── 7. a bad candidate never reaches the live install ─────────────────────────────────
new_case 7a; reg_latest 0.157.1; reg_publish 0.157.1
echo "$C/lib/staging/0.157.1/bin 0.157.1 codex-cli 0.157.0" >"$C/fake/report_override"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "REJECTED" && has "$out" "expected 'codex-cli 0.157.1'" && ok \
  || bad "7a: wrong staged version not rejected ($rc): $out"
[ "$(live_adds)" = 0 ] && [ "$(live_ver)" = "codex-cli 0.156.0" ] && ok || bad "7a: live install touched"
[ "$(rec_ver)" != 0.157.1 ] && ok || bad "7a: record advertised an unverified version"
[ "$(held)" = 0.157.1 ] && [ "$(notes)" = 1 ] && [ ! -e "$C/lib/staging" ] && ok \
  || bad "7a: rejected candidate not held/notified once, or staging left (hold '$(held)', $(notes) notices)"
# pnpm itself failing is the promoter's problem, not the candidate's: exit 1 (pages), no hold.
new_case 7b; reg_latest 0.157.1; reg_publish 0.157.1; echo "* 0.157.1" >"$C/fake/fail_add"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "staging failed" && [ "$(live_ver)" = "codex-cli 0.156.0" ] && [ -z "$(held)" ] && ok \
  || bad "7b: a failed staging install was not contained, or was held ($rc, hold '$(held)'): $out"
new_case 7c; reg_latest 0.157.1; reg_publish 0.157.1; echo 0.157.1 >"$C/fake/no_native"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "native" && has "$out" "REJECTED" && [ "$(live_adds)" = 0 ] && ok \
  || bad "7c: a candidate without its native artifact was promoted ($rc): $out"

# ── 8. a running Codex session defers promotion ───────────────────────────────────────
new_case 8a; reg_latest 0.157.1; reg_publish 0.157.1
mkdir -p "$C/proc/4242"
ln -s "$C/global/5/node_modules/.pnpm/@openai+codex@0.156.0-linux-x64/node_modules/@openai/codex/vendor/x86_64-unknown-linux-musl/bin/codex" \
  "$C/proc/4242/exe"
printf 'codex\0exec\0' >"$C/proc/4242/cmdline"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "deferred" && ok || bad "8a: native codex process did not defer ($rc): $out"
[ "$(live_adds)" = 0 ] && [ "$(live_ver)" = "codex-cli 0.156.0" ] && ok || bad "8a: live install changed under a running session"
[ "$(outcome)" = deferred ] && ok || bad "8a: status outcome is '$(outcome)'"
new_case 8b; reg_latest 0.157.1; reg_publish 0.157.1
mkdir -p "$C/proc/77"; ln -s /usr/bin/node "$C/proc/77/exe"
printf 'node\0%s\0' "$C/global/5/node_modules/.pnpm/@openai+codex@0.156.0/node_modules/@openai/codex/bin/codex.js" \
  >"$C/proc/77/cmdline"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "deferred" && [ "$(live_adds)" = 0 ] && ok \
  || bad "8b: node-launched codex did not defer ($rc): $out"

# ── 9. concurrent pnpm global/store work defers; project-local pnpm does not ──────────
new_case 9a; reg_latest 0.157.1; reg_publish 0.157.1
mkdir -p "$C/proc/99"; ln -s /usr/bin/node "$C/proc/99/exe"
printf 'node\0/opt/pnpm/bin/pnpm.cjs\0add\0-g\0typescript\0' >"$C/proc/99/cmdline"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "deferred" && [ "$(live_adds)" = 0 ] && ok \
  || bad "9a: a concurrent pnpm -g did not defer ($rc): $out"
new_case 9b; reg_latest 0.157.1; reg_publish 0.157.1
mkdir -p "$C/proc/98"; ln -s /home/u/.local/share/pnpm/pnpm "$C/proc/98/exe"
printf 'pnpm\0store\0prune\0' >"$C/proc/98/cmdline"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "deferred" && ok || bad "9b: a concurrent store prune did not defer ($rc): $out"
new_case 9c; reg_latest 0.157.1; reg_publish 0.157.1
mkdir -p "$C/proc/97"; ln -s /usr/bin/node "$C/proc/97/exe"
printf 'node\0/opt/pnpm/bin/pnpm.cjs\0dev\0' >"$C/proc/97/cmdline"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "codex promoted" && ok || bad "9c: a project-local pnpm dev blocked promotion ($rc): $out"

# ── 10. post-promotion smoke failure restores the exact prior version, offline ────────
new_case 10; reg_latest 0.157.1; reg_publish 0.157.1; echo "$C/bin 0.157.1" >"$C/fake/broken"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "ROLLED BACK to 0.156.0" && ok || bad "10: no rollback ($rc): $out"
[ "$(live_ver)" = "codex-cli 0.156.0" ] && ok || bad "10: live reports '$(live_ver)' after rollback"
[ "$(rec_ver)" = 0.156.0 ] && ok || bad "10: record not restored with the installation ($(rec_ver))"
[ "$(outcome)" = rolled-back ] && ok || bad "10: status outcome is '$(outcome)'"
grep '^ARGS add' "$C/fake/log" | grep -F -- "--config.global-dir=$C/global" | grep -F '@openai/codex@0.156.0' \
  | grep -q -- '--offline' && ok || bad "10: the rollback install was not offline"
# 21. the failed candidate is held, not retried (and re-alerted) every 15 minutes
: >"$C/fake/log"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "holding 0.157.1" && [ "$(adds)" = 0 ] && ok \
  || bad "21: a rolled-back candidate was retried ($rc): $out"
[ "$(outcome)" = held ] && ok || bad "21: status outcome is '$(outcome)', not held"
reg_latest 0.157.2; reg_publish 0.157.2; rm -f "$C/fake/broken"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "codex promoted: 0.156.0 -> 0.157.2" && ok \
  || bad "21: a newer release did not clear the hold ($rc): $out"

# ── 11. a rollback that cannot complete fails loudly and names the retained copy ──────
new_case 11; reg_latest 0.157.1; reg_publish 0.157.1
echo "$C/bin 0.157.1" >"$C/fake/broken"; echo "$C/global 0.156.0" >"$C/fake/fail_add"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "ROLLBACK FAILED" && ok || bad "11: failed rollback not reported ($rc): $out"
has "$out" "$C/lib/retained/0.156.0/bin/codex" && ok || bad "11: the retained emergency copy was not named: $out"
[ "$(outcome)" = rollback-failed ] && ok || bad "11: status outcome is '$(outcome)'"

# ── 12. unrelated pnpm globals must not move ──────────────────────────────────────────
new_case 12; reg_latest 0.157.1; reg_publish 0.157.1; touch "$C/fake/mutate_other"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "unrelated pnpm globals changed" && ok || bad "12: global drift not reported ($rc): $out"
has "$out" "left-pad" && ok || bad "12: the drifted package was not named: $out"

# ── 13. one run at a time ─────────────────────────────────────────────────────────────
new_case 13; reg_latest 0.157.1; reg_publish 0.157.1
( flock -x 9; sleep 3 ) 9>"$C/state/lock" &
holder=$!
sleep 0.5
out=$(run); rc=$?
wait "$holder"
[ "$rc" -eq 0 ] && has "$out" "another codex-update run holds the lock" && [ "$(adds)" = 0 ] && ok \
  || bad "13: a concurrent run was not excluded ($rc): $out"

# ── 14. the record is replaced atomically, never written through a planted symlink ────
new_case 14; reg_latest 0.156.0; reg_publish 0.156.0
echo sentinel >"$C/elsewhere"; ln -s "$C/elsewhere" "$C/state/verified-version.json"
run >/dev/null
[ "$(cat "$C/elsewhere")" = sentinel ] && ok || bad "14: the record was written through a symlink"
[ -f "$C/state/verified-version.json" ] && [ ! -L "$C/state/verified-version.json" ] && ok \
  || bad "14: the record is not a regular file"
[ -z "$(find "$C/state" -mindepth 1 -maxdepth 1 ! -name verified-version.json ! -name status.json \
  ! -name lock -print -quit)" ] && ok || bad "14: temp files left in the state dir: $(ls -A "$C/state")"

# ── 15. a current install re-stamps an aging record and leaves a fresh one alone ──────
new_case 15; reg_latest 0.156.0; reg_publish 0.156.0
printf '{"schemaVersion":1,"packageName":"@openai/codex","version":"0.156.0","verifiedAt":"2026-01-01T00:00:00.000Z"}\n' \
  >"$C/state/verified-version.json"
run >/dev/null
[ "$(jq -r .verifiedAt "$C/state/verified-version.json")" != 2026-01-01T00:00:00.000Z ] && ok \
  || bad "15: an aging record was not re-stamped"
fresh=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"schemaVersion":1,"packageName":"@openai/codex","version":"0.156.0","verifiedAt":"%s"}\n' "$fresh" \
  >"$C/state/verified-version.json"
run >/dev/null
[ "$(jq -r .verifiedAt "$C/state/verified-version.json")" = "$fresh" ] && ok || bad "15: a fresh record was rewritten"

# ── 16. retention keeps the two newest previous versions ──────────────────────────────
new_case 16 0.157.1; reg_latest 0.157.2; reg_publish 0.157.2
for v in 0.150.0 0.154.0 0.156.0; do
  mkdir -p "$C/lib/retained/$v/bin"
  printf '#!/usr/bin/env bash\necho "codex-cli %s"\n' "$v" >"$C/lib/retained/$v/bin/codex"
  chmod +x "$C/lib/retained/$v/bin/codex"
done
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok || bad "16: promotion exited $rc: $out"
[ "$(ls "$C/lib/retained" | sort -V | tr '\n' ' ')" = "0.156.0 0.157.1 " ] && ok \
  || bad "16: retained set is '$(ls "$C/lib/retained" | tr '\n' ' ')'"

# ── 17. manual --rollback restores the newest retained version, offline ───────────────
new_case 17; reg_latest 0.157.1; reg_publish 0.157.1
run >/dev/null
: >"$C/fake/log"
out=$(run --rollback); rc=$?
[ "$rc" -eq 0 ] && has "$out" "rolled back to 0.156.0" && ok || bad "17: --rollback failed ($rc): $out"
[ "$(live_ver)" = "codex-cli 0.156.0" ] && [ "$(rec_ver)" = 0.156.0 ] && ok || bad "17: live/record not restored"
grep '^ARGS add' "$C/fake/log" | grep -F '@openai/codex@0.156.0' | grep -q -- '--offline' && ok \
  || bad "17: --rollback did not install offline"
# The version a manual rollback replaces is retained too, so the rollback can be undone offline.
[ "$("$C/lib/retained/0.157.1/bin/codex" --version 2>/dev/null)" = "codex-cli 0.157.1" ] && ok \
  || bad "17: the replaced version was not retained"
: >"$C/fake/log"
out=$(run --rollback 0.157.1); rc=$?
[ "$rc" -eq 0 ] && has "$out" "rolled back to 0.157.1" && [ "$(live_ver)" = "codex-cli 0.157.1" ] && ok \
  || bad "17: undoing the rollback failed ($rc): $out"
[ "$(grep -c -- '--prefer-offline' "$C/fake/log")" = 0 ] && ok || bad "17: undoing the rollback needed the network"
# A replaced version that cannot be retained (it may be the broken one) never blocks the rollback.
new_case 17b; reg_latest 0.157.1; reg_publish 0.157.1
run >/dev/null
echo "$C/lib/retained/0.157.1/global 0.157.1" >"$C/fake/fail_add"
out=$(run --rollback); rc=$?
[ "$rc" -eq 0 ] && has "$out" "rolled back to 0.156.0" && has "$out" "WARN could not retain 0.157.1" && ok \
  || bad "17b: a failed retention blocked or hid the rollback ($rc): $out"

# ── 22. rollback stays offline after `pnpm store prune` wiped pnpm's metadata cache ───
# Measured on pnpm 10.33.2: prune reports "Removed all cached metadata files" and keeps
# the retained prefix's packages, and --offline then fails ERR_PNPM_NO_OFFLINE_META even
# for an exact version. The retained copy carries its own metadata snapshot.
new_case 22; reg_latest 0.157.1; reg_publish 0.157.1
run >/dev/null
rm -rf "$C/fake/cache"
: >"$C/fake/log"
out=$(run --rollback); rc=$?
[ "$rc" -eq 0 ] && has "$out" "rolled back to 0.156.0" && ok || bad "22: rollback after a metadata wipe failed ($rc): $out"
! has "$out" "prefer-offline" && [ "$(grep -c -- '--prefer-offline' "$C/fake/log")" = 0 ] && ok \
  || bad "22: rollback after a metadata wipe needed the network: $out"
[ "$(live_ver)" = "codex-cli 0.156.0" ] && ok || bad "22: live reports '$(live_ver)'"

# ── 18. --report: current, pending, stalled, never-run, aging record; changes nothing ─
new_case 18; reg_latest 0.156.0; reg_publish 0.156.0
out=$(run --report); rc=$?
[ "$rc" -eq 0 ] && has "$out" "codex current: 0.156.0" && ok || bad "18: current report ($rc): $out"
reg_latest 0.157.1; reg_publish 0.157.1
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
jq -cn --arg now "$now" --arg since "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000Z)" \
  '{checkedAt: $now, installed: "0.156.0", candidate: "0.157.1", outcome: "deferred", gapSince: $since}' \
  >"$C/state/status.json"
out=$(run --report)
has "$out" "codex behind: 0.156.0 -> 0.157.1" && ! has "$out" "WARN" && ok || bad "18: a fresh gap warned: $out"
jq -cn --arg now "$now" --arg since "$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%S.000Z)" \
  '{checkedAt: $now, installed: "0.156.0", candidate: "0.157.1", outcome: "deferred", gapSince: $since}' \
  >"$C/state/status.json"
out=$(run --report)
has "$out" "WARN codex behind: 0.156.0 -> 0.157.1" && has "$out" "deferred" && ok || bad "18: a stalled gap did not warn: $out"
jq -cn --arg now "$now" --arg since "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000Z)" \
  '{checkedAt: $now, installed: "0.156.0", candidate: "0.157.1", outcome: "rejected",
    detail: "manifest check failed", gapSince: $since}' >"$C/state/status.json"
out=$(run --report)
has "$out" "WARN codex behind: 0.156.0 -> 0.157.1" && has "$out" "rejected" && ok \
  || bad "18: a rejected candidate did not warn at once: $out"
rm -f "$C/state/status.json"
out=$(run --report)
has "$out" "WARN codex behind" && has "$out" "has not run" && ok || bad "18: an inactive updater did not warn: $out"
printf '{"schemaVersion":1,"packageName":"@openai/codex","version":"0.156.0","verifiedAt":"%s"}\n' \
  "$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%S.000Z)" >"$C/state/verified-version.json"
out=$(run --report)
has "$out" "WARN codex verified-version record" && ok || bad "18: an aging record did not warn: $out"
[ "$(adds)" = 0 ] && ok || bad "18: --report installed something"

# ── 19. no pnpm-owned install: refuse rather than install from scratch ────────────────
new_case 19; rm -rf "$C/global"; reg_latest 0.157.1; reg_publish 0.157.1
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "no pnpm-owned @openai/codex install" && [ "$(adds)" = 0 ] && ok \
  || bad "19: missing install not refused ($rc): $out"

# ── 20. a different codex ahead on PATH is reported, not touched ──────────────────────
new_case 20; reg_latest 0.156.0; reg_publish 0.156.0
mkdir -p "$C/other"; printf '#!/usr/bin/env bash\necho "codex-cli 0.1.0"\n' >"$C/other/codex"; chmod +x "$C/other/codex"
out=$(PRE_PATH="$C/other" run); rc=$?
has "$out" "WARN active codex launcher" && ok || bad "20: foreign launcher not reported: $out"
[ "$(jq -r .launcherOwned "$C/state/status.json")" = false ] && ok || bad "20: status did not record launcher ownership"
[ "$("$C/other/codex" --version)" = "codex-cli 0.1.0" ] && ok || bad "20: the foreign launcher was modified"

# ── 23. a process table it cannot read defers promotion instead of promoting blind ────
new_case 23; reg_latest 0.157.1; reg_publish 0.157.1; rm -rf "$C/proc/1"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "deferred" && has "$out" "cannot inspect running processes" && ok \
  || bad "23: an empty process table did not defer ($rc): $out"
[ "$(live_adds)" = 0 ] && [ "$(live_ver)" = "codex-cli 0.156.0" ] && ok || bad "23: live install changed blind"

# ── 24. macOS is refused: no /proc for the session check, no GNU date/mv/flock/timeout ─
new_case 24; reg_latest 0.157.1; reg_publish 0.157.1
mkdir -p "$C/uname"
printf '#!/usr/bin/env bash\ncase "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin arm64 ;; esac\n' \
  >"$C/uname/uname"
chmod +x "$C/uname/uname"
out=$(PLAT='' PRE_PATH="$C/uname" run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "unsupported platform" && [ "$(adds)" = 0 ] && ok \
  || bad "24: Darwin was not refused ($rc): $out"

# ── 25. an unreachable registry is a promoter failure (exit 1 pages); --report names it ─
new_case 25
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "could not read the @openai/codex dist-tags" && [ "$(outcome)" = failed ] && ok \
  || bad "25: an unreachable registry was not a failure ($rc, outcome '$(outcome)'): $out"
out=$(run --report); rc=$?
[ "$rc" -eq 0 ] && has "$out" "registry unreachable" && ok || bad "25: --report did not name the unreachable registry ($rc): $out"

# ── 26. a prerelease live install is left alone ──────────────────────────────────────
new_case 26 0.158.0-alpha.1; reg_latest 0.157.1; reg_publish 0.157.1
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "not a stable release; not managing it" && [ "$(adds)" = 0 ] && ok \
  || bad "26: a prerelease live install was managed ($rc): $out"

# ── 27. report-only mode writes nothing, even for a rejection, and tells the truth about a hold ─
new_case 27; reg_latest 0.158.0-alpha.2.1; reg_publish 0.158.0-alpha.2.1
out=$(DRY=default run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "REJECTED" && [ -z "$(held)" ] && [ "$(notes)" = 0 ] && [ ! -e "$C/state/status.json" ] && ok \
  || bad "27: a dry-run rejection wrote state or notified ($rc, hold '$(held)', $(notes) notices): $out"
reg_latest 0.157.1; reg_publish 0.157.1; echo 0.157.1 >"$C/state/hold"
out=$(DRY=default run); rc=$?
[ "$rc" -eq 0 ] && has "$out" "holding 0.157.1" && ! has "$out" "would update" && [ ! -e "$C/state/status.json" ] && ok \
  || bad "27: a dry run reported a held candidate as an update ($rc): $out"

# ── 28. pnpm output reaches the journal (and OnFailure's Discord page) with credentials masked ─
new_case 28; reg_latest 0.157.1; reg_publish 0.157.1
echo "* 0.157.1" >"$C/fake/fail_add"; touch "$C/fake/leak" "$C/fake/notify_fail"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && has "$out" "staging failed" && has "$out" "[redacted]" && ok || bad "28: no redacted staging failure ($rc): $out"
! has "$out" "s3cr3t" && ! has "$out" "tok_ABC123" && ! has "$out" "npm_XYZ789" && ok \
  || bad "28: pnpm output leaked a credential: $out"
has "$out" "WARN notify failed" && ok || bad "28: a failed notifier left no trace: $out"

if [ "$fail" -eq 0 ]; then
  echo "ok — codex-update: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — codex-update: $fail of $((pass + fail)) assertions failed"
  exit 1
fi
