#!/usr/bin/env bash
# Real-pnpm, real-registry check of scripts/codex-update.sh (dotfiles#1377). MANUAL-ONLY:
# it downloads two real @openai/codex releases (native packages included) from npm.
#
# Everything lands in one isolated prefix below mktemp: global dir, bin dir, pnpm store,
# pnpm metadata cache, updater state and retained copies. The live ~/.local/bin/codex,
# the real pnpm store and ~/.config/pnpm are never written.
#
# What the hermetic suite cannot prove and this does, against pnpm 11's real behavior:
#   1. the per-run exact exclude really admits a candidate pnpm would otherwise refuse
#      (the environment sets a 10-year minimum age, and a negative control proves it
#      bites);
#   2. an unrelated global in the same prefix is untouched by promotion;
#   3. after `pnpm store prune` empties the metadata cache, --rollback reinstalls the
#      prior exact version with the network dead (a proxy on a closed port), from the
#      retained prefix's references and its metadata snapshot.
#
# Run:   CODEX_UPDATE_LIVE_TEST=1 bash tests/codex-update-live.test.sh
# Knobs: CODEX_UPDATE_LIVE_PREV (default 0.156.0) must be older than npm's `latest`.
set -uo pipefail

if [ "${CODEX_UPDATE_LIVE_TEST:-}" != 1 ]; then
  echo "skipped: set CODEX_UPDATE_LIVE_TEST=1 (downloads real Codex releases)"
  exit 0
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/codex-update.sh
PREV=${CODEX_UPDATE_LIVE_PREV:-0.156.0}
BASE=$(mktemp -d "${TMPDIR:-/tmp}/codex-update-live.XXXXXX") || exit 1
trap 'rm -rf "$BASE"' EXIT
G=$BASE/global B=$BASE/bin STORE=$BASE/store CACHE=$BASE/cache
mkdir -p "$G" "$B" "$BASE/state" "$BASE/lib" "$BASE/cwd"
cd "$BASE/cwd" || exit 1

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

PV=$(pnpm --version 2>/dev/null | tail -n 1)
case "$PV" in
  11.*) echo "pnpm $PV" ;;
  *) echo "needs pnpm 11 first on PATH; pnpm reports '${PV:-nothing}'"; exit 1 ;;
esac

# Every pnpm call here, the updater's included, sees this: nothing is mature for ten years.
export pnpm_config_minimum_release_age=5256000
unset pnpm_config_minimum_release_age_exclude
ISO=(--config.global-dir="$G" --config.global-bin-dir="$B" --config.store-dir="$STORE"
  --config.cache-dir="$CACHE" --config.enable-global-virtual-store=false)
p() { PATH="$B:$PATH" pnpm "$@" "${ISO[@]}"; }
ver_in() { p ls -g --depth=0 --json 2>/dev/null | jq -r --arg n "$1" '.[0].dependencies[$n].version // empty'; }
path_in() { p ls -g --depth=0 --json 2>/dev/null | jq -r --arg n "$1" '.[0].dependencies[$n].path // empty'; }

LATEST=$(curl -fsS --max-time 30 https://registry.npmjs.org/-/package/@openai/codex/dist-tags | jq -r .latest)
echo "prev=$PREV latest=$LATEST base=$BASE"

# Setup: PREV with its own exact exception, then an unrelated global in its own add.
aliases=$(curl -fsS --max-time 30 "https://registry.npmjs.org/@openai/codex/$PREV" |
  jq -r '.optionalDependencies | keys[] | ltrimstr("@openai/codex-")' | sort | tr '\n' ' ')
pat="@openai/codex@$PREV"
for s in $aliases; do pat="$pat || $PREV-$s"; done
pnpm_config_minimum_release_age_exclude=$(jq -cn --arg e "$pat" '[$e]') \
  p add -g "@openai/codex@$PREV" >"$BASE/setup.log" 2>&1 || { tail -5 "$BASE/setup.log"; exit 1; }
pnpm_config_minimum_release_age_exclude='["is-number@7.0.0"]' \
  p add -g is-number@7.0.0 >>"$BASE/setup.log" 2>&1 || { tail -5 "$BASE/setup.log"; exit 1; }
[ "$("$B/codex" --version)" = "codex-cli $PREV" ] && ok "setup installed $PREV" || { bad "setup"; exit 1; }
[ "$(ver_in is-number)" = 7.0.0 ] && ok "setup installed is-number 7.0.0" || { bad "setup is-number"; exit 1; }
isnum_path=$(path_in is-number)

# 1a. negative control: without an exception the 10-year age refuses the candidate.
mkdir -p "$BASE/neg/g" "$BASE/neg/b"
if PATH="$BASE/neg/b:$PATH" pnpm add -g "@openai/codex@$LATEST" \
  --config.global-dir="$BASE/neg/g" --config.global-bin-dir="$BASE/neg/b" \
  --config.store-dir="$STORE" --config.cache-dir="$CACHE" >"$BASE/neg.log" 2>&1; then
  bad "1a: $LATEST resolved with no exception; the control does not bite"
else
  grep -q ERR_PNPM_NO_MATURE_MATCHING_VERSION "$BASE/neg.log" && ok "1a: cooldown refuses $LATEST without an exception" \
    || bad "1a: unexpected refusal: $(tail -2 "$BASE/neg.log")"
fi

run() {
  env PATH="$B:$PATH" DRY_RUN=0 \
    CODEX_UPDATE_STATE_DIR="$BASE/state" CODEX_UPDATE_LIB_DIR="$BASE/lib" \
    CODEX_UPDATE_GLOBAL_DIR="$G" CODEX_UPDATE_BIN_DIR="$B" \
    CODEX_UPDATE_STORE_DIR="$STORE" CODEX_UPDATE_CACHE_DIR="$CACHE" \
    CODEX_UPDATE_NOTIFY=true \
    "$@"
}

# 1b + 2. promotion through the updater's own exact exception; is-number stays put.
out=$(run bash "$SCRIPT" 2>&1); rc=$?
echo "$out" | sed 's/^/  | /'
[ "$rc" -eq 0 ] && [ "$("$B/codex" --version)" = "codex-cli $LATEST" ] && ok "1b: promoted to $LATEST" \
  || bad "1b: promotion ($rc)"
[ "$(ver_in @openai/codex)" = "$LATEST" ] && ok "1b: pnpm lists $LATEST" || bad "1b: pnpm lists '$(ver_in @openai/codex)'"
[ "$(jq -r .version "$BASE/state/verified-version.json")" = "$LATEST" ] && ok "1b: record names $LATEST" || bad "1b: record"
[ "$(ver_in is-number)" = 7.0.0 ] && [ "$(path_in is-number)" = "$isnum_path" ] && ok "2: is-number untouched" \
  || bad "2: unrelated global moved ($(ver_in is-number) at $(path_in is-number))"
[ "$("$BASE/lib/retained/$PREV/bin/codex" --version)" = "codex-cli $PREV" ] && ok "retained copy of $PREV runs" \
  || bad "retained copy"
[ -n "$(find "$BASE/lib/retained/$PREV/metadata" -name codex.jsonl -type f 2>/dev/null)" ] \
  && ok "retained copy carries a metadata snapshot" || bad "no metadata snapshot in the retained copy"

# 3. prune the isolated store, then roll back with the network dead.
p store prune >"$BASE/prune.log" 2>&1 || bad "3: store prune failed: $(tail -2 "$BASE/prune.log")"
[ -z "$(find "$CACHE" -name codex.jsonl -type f 2>/dev/null)" ] && ok "3: store prune emptied the codex metadata cache" \
  || bad "3: codex metadata survived the prune; the offline rollback below proves less"
[ "$("$BASE/lib/retained/$PREV/bin/codex" --version)" = "codex-cli $PREV" ] && ok "3: retained copy survives store prune" \
  || bad "3: retained copy broke after prune"
dead=http://127.0.0.1:9
out=$(run env HTTPS_PROXY=$dead HTTP_PROXY=$dead https_proxy=$dead http_proxy=$dead \
  pnpm_config_https_proxy=$dead pnpm_config_proxy=$dead \
  npm_config_https_proxy=$dead npm_config_proxy=$dead bash "$SCRIPT" --rollback 2>&1); rc=$?
echo "$out" | sed 's/^/  | /'
[ "$rc" -eq 0 ] && [ "$("$B/codex" --version)" = "codex-cli $PREV" ] && ok "3: offline rollback to $PREV after prune" \
  || bad "3: offline rollback ($rc)"
grep -q 'prefer-offline' <<<"$out" && bad "3: rollback needed the network fallback" || ok "3: rollback stayed offline"
[ "$(jq -r .version "$BASE/state/verified-version.json")" = "$PREV" ] && ok "3: record restored to $PREV" || bad "3: record"

# The rolled-back release is held rather than re-promoted on the next tick.
out=$(run bash "$SCRIPT" 2>&1)
case "$out" in *"holding $LATEST"*) ok "held $LATEST after manual rollback" ;; *) bad "not held: $out" ;; esac

if [ "$fail" -eq 0 ]; then
  echo "ok — codex-update live: $pass/$((pass + fail)) checks passed"
else
  echo "FAIL — codex-update live: $fail of $((pass + fail)) checks failed"
  exit 1
fi
