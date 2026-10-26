#!/usr/bin/env bash
# Role-aware proxy env in sync.sh (acme-infra plan
# 2026-08-30-0030-feat-ccflare-tailnet-sharing-plan.md, U2/U3; R7, R12).
#
# What this pins:
#   1. reconcile_runtime_env resolves ANTHROPIC_BASE_URL by profile_role —
#      workstation -> loopback guard, satellite -> the proxy host's serve URL,
#      read from CCFLARE_URL_SATELLITE in the environment (the public tree
#      ships no proxy host) — on both the fresh-seed and merge branches, so a
#      fresh satellite bootstrap can never inherit the workstation's loopback
#      URL (AE5), and a satellite with the variable unset fails closed.
#   2. An undeclared host fails closed: reconcile errors and writes nothing
#      instead of guessing either role's URL; check() falls back to a raw
#      comparison there, so a stale role URL on an undeclared host DRIFTs.
#   3. The host-local ccflare secret — env.ANTHROPIC_CUSTOM_HEADERS
#      ("x-api-key: …"), the channel that keeps Claude Code in claude.ai-login
#      mode — survives reconcile untouched (R12), and the canonical-secret
#      tripwire: EITHER that key or the legacy env.ANTHROPIC_AUTH_TOKEN
#      reaching the TRACKED canonical settings.json makes check() report
#      DRIFT loudly (push once copied live settings verbatim, and the
#      comparison excludes both vars from both sides, so a leaked secret was
#      otherwise invisible).
#   4. check()'s settings comparison accepts the legitimate per-role URL and
#      the live-only secret without DRIFT, and still reports DRIFT for a
#      genuinely wrong URL.
#
# Hermetic per the sync-install-smoke.test.sh pattern: scratch $HOME and
# $CLAUDE_HOME, a copied source tree outside the git worktree, a one-row
# hosts.tsv per fixture, the CLAUDE_SYNC_* overrides, and a PATH-local
# systemctl stub so check() can never reach the invoking user's live systemd
# manager. Drives the narrow `reconcile-runtime-env` and `check` dispatch
# modes directly — the full-install path is sync-install-smoke's job.
set -uo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/manifest.sh
. "$SRC/lib/manifest.sh"   # DOTFILES_HARNESS: the tree sync.sh installs
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

LOOPBACK_URL="http://127.0.0.1:8788"
# A documentation address stands in for the proxy host: the tree ships none.
SATELLITE_URL="https://proxy-host.example.net"
unset CCFLARE_URL_SATELLITE
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)

# No live user manager exists inside this scratch fixture (mirrors
# sync-install-smoke's hermetic setup).
STUB_BIN=$TMP/test-bin
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
exit 3
SH
chmod +x "$STUB_BIN/systemctl"

FIX_REPO="" FIX_HOME="" FIX_CLAUDE_HOME="" OUT="" RC=0

build_fixture() { # <name> <role|none>
  local name=$1 role=$2 root e
  root=$TMP/$name
  mkdir -p "$root/dotfiles"
  for e in "${DOTFILES_HARNESS[@]}"; do cp -a "$SRC/$e" "$root/dotfiles/$e"; done
  cp -a "$SRC/config" "$root/dotfiles/config"
  cp -a "$SRC/lib" "$root/dotfiles/lib"
  if [ "$role" = none ]; then
    printf '# hermetic fixture table — deliberately empty\n' > "$root/dotfiles/hosts.tsv"
  else
    printf '# hermetic fixture table — one row, this host only\n%s\t%s\n' \
      "$HOSTNAME_SHORT" "$role" > "$root/dotfiles/hosts.tsv"
  fi
  FIX_REPO=$root/dotfiles
  FIX_HOME=$root/home
  FIX_CLAUDE_HOME=$root/claude-home
  mkdir -p "$FIX_HOME" "$FIX_CLAUDE_HOME"
  # reconcile_runtime_env requires the mapped CLAUDE_ENV_FILE target to exist,
  # and a plugin manifest under each mapped CLAUDE_CODE_PLUGIN_DIRS entry;
  # install links ~/.claude/mods into the checkout, so the fixture does too.
  touch "$FIX_CLAUDE_HOME/claude-env.sh"
  ln -s "$FIX_REPO/mods" "$FIX_CLAUDE_HOME/mods"
}

run_sync() { # <mode>
  local mode=$1
  OUT=$(HOME=$FIX_HOME CLAUDE_HOME=$FIX_CLAUDE_HOME \
    PATH="$STUB_BIN:$PATH" \
    CLAUDE_SYNC_SKIP_HOOK_RECONCILE=1 \
    CLAUDE_MEMORY_MIRROR_ROOT=$TMP/empty-mirror \
    CLAUDE_SYNC_SYSTEM_SYS_DIR=$TMP/etc-systemd-system \
    CLAUDE_SYNC_MANAGED_LOCK=$TMP/etc-claude-code/managed-settings.json \
    CLAUDE_WINDOWS_HOME=$TMP/windows-home \
    bash "$FIX_REPO/sync.sh" "$mode" 2>&1)
  RC=$?
}
mkdir -p "$TMP/empty-mirror" "$TMP/windows-home"

live_env() { # <key>
  jq -r ".env.${1} // empty" "$FIX_CLAUDE_HOME/settings.json" 2>/dev/null
}

# ---- 1. workstation fixture ------------------------------------------------
build_fixture ws workstation
run_sync reconcile-runtime-env
[ "$RC" -eq 0 ] && ok || bad "workstation reconcile exited $RC: $(printf '%s' "$OUT" | tail -3)"
[ "$(live_env ANTHROPIC_BASE_URL)" = "$LOOPBACK_URL" ] && ok \
  || bad "workstation seeded ANTHROPIC_BASE_URL='$(live_env ANTHROPIC_BASE_URL)', want $LOOPBACK_URL"

# live-only ccflare secret survives the merge branch
WS_SETTINGS=$FIX_CLAUDE_HOME/settings.json
jq '.env.ANTHROPIC_CUSTOM_HEADERS = "x-api-key: btr-test-live-only"' "$WS_SETTINGS" > "$WS_SETTINGS.tmp" \
  && mv "$WS_SETTINGS.tmp" "$WS_SETTINGS"
run_sync reconcile-runtime-env
[ "$RC" -eq 0 ] && ok || bad "workstation merge reconcile exited $RC: $(printf '%s' "$OUT" | tail -3)"
[ "$(live_env ANTHROPIC_CUSTOM_HEADERS)" = "x-api-key: btr-test-live-only" ] && ok \
  || bad "live-only ANTHROPIC_CUSTOM_HEADERS did not survive reconcile (got '$(live_env ANTHROPIC_CUSTOM_HEADERS)')"
[ "$(live_env ANTHROPIC_BASE_URL)" = "$LOOPBACK_URL" ] && ok \
  || bad "workstation merge rewrote URL to '$(live_env ANTHROPIC_BASE_URL)'"

# check(): custom-headers secret + role-correct URL must not DRIFT
run_sync check
grep -q "DRIFT: settings.json differs" <<<"$OUT" \
  && bad "workstation check flags settings DRIFT with role-correct URL + live secret" \
  || ok

# check(): a genuinely wrong URL still DRIFTs (carve-out must not over-reach)
jq '.env.ANTHROPIC_BASE_URL = "http://evil.example:9999"' "$WS_SETTINGS" > "$WS_SETTINGS.tmp" \
  && mv "$WS_SETTINGS.tmp" "$WS_SETTINGS"
run_sync check
grep -q "DRIFT: settings.json differs" <<<"$OUT" && ok \
  || bad "workstation check missed a genuinely wrong ANTHROPIC_BASE_URL"

# canonical-secret tripwire: EITHER ccflare var in the TRACKED copy is loud
jq '.env.ANTHROPIC_CUSTOM_HEADERS = "x-api-key: btr-leaked-into-repo"' "$FIX_REPO/settings.json" \
  > "$FIX_REPO/settings.json.tmp" \
  && mv "$FIX_REPO/settings.json.tmp" "$FIX_REPO/settings.json"
run_sync check
grep -q "canonical copy carries a ccflare secret" <<<"$OUT" && ok \
  || bad "tripwire did not fire on ANTHROPIC_CUSTOM_HEADERS in the tracked settings.json"
jq 'del(.env.ANTHROPIC_CUSTOM_HEADERS) | .env.ANTHROPIC_AUTH_TOKEN = "btr-legacy-leak"' "$FIX_REPO/settings.json" \
  > "$FIX_REPO/settings.json.tmp" \
  && mv "$FIX_REPO/settings.json.tmp" "$FIX_REPO/settings.json"
run_sync check
grep -q "canonical copy carries a ccflare secret" <<<"$OUT" && ok \
  || bad "tripwire did not fire on legacy ANTHROPIC_AUTH_TOKEN in the tracked settings.json"
jq 'del(.env.ANTHROPIC_AUTH_TOKEN)' "$FIX_REPO/settings.json" \
  > "$FIX_REPO/settings.json.tmp" \
  && mv "$FIX_REPO/settings.json.tmp" "$FIX_REPO/settings.json"

# ---- 2. satellite fixture --------------------------------------------------
build_fixture sat satellite
# PLANTED NEGATIVE: with no proxy URL in the environment the satellite fails
# closed, names the variable, and writes nothing.
unset CCFLARE_URL_SATELLITE
run_sync reconcile-runtime-env
[ "$RC" -ne 0 ] && ok || bad "satellite reconcile with CCFLARE_URL_SATELLITE unset succeeded; must fail closed"
grep -q "CCFLARE_URL_SATELLITE is unset" <<<"$OUT" && ok \
  || bad "satellite failure does not name CCFLARE_URL_SATELLITE: $(printf '%s' "$OUT" | tail -3)"
[ ! -e "$FIX_CLAUDE_HOME/settings.json" ] && ok \
  || bad "satellite reconcile with CCFLARE_URL_SATELLITE unset wrote settings.json; fail-closed must write nothing"
export CCFLARE_URL_SATELLITE=$SATELLITE_URL
run_sync reconcile-runtime-env
[ "$RC" -eq 0 ] && ok || bad "satellite reconcile exited $RC: $(printf '%s' "$OUT" | tail -3)"
[ "$(live_env ANTHROPIC_BASE_URL)" = "$SATELLITE_URL" ] && ok \
  || bad "satellite seeded ANTHROPIC_BASE_URL='$(live_env ANTHROPIC_BASE_URL)', want $SATELLITE_URL (AE5)"

run_sync reconcile-runtime-env
[ "$(live_env ANTHROPIC_BASE_URL)" = "$SATELLITE_URL" ] && ok \
  || bad "satellite merge rewrote URL to '$(live_env ANTHROPIC_BASE_URL)', want $SATELLITE_URL"

run_sync check
grep -q "DRIFT: settings.json differs" <<<"$OUT" \
  && bad "satellite check flags settings DRIFT for the role-correct tailnet URL" \
  || ok

# ---- 3. unclassified fixture: fail closed ----------------------------------
unset CCFLARE_URL_SATELLITE
build_fixture unk none
run_sync reconcile-runtime-env
[ "$RC" -ne 0 ] && ok || bad "unclassified-host reconcile succeeded; must fail closed"
grep -qi "role" <<<"$OUT" && ok \
  || bad "unclassified-host failure does not name the role problem: $(printf '%s' "$OUT" | tail -3)"
[ ! -e "$FIX_CLAUDE_HOME/settings.json" ] && ok \
  || bad "unclassified-host reconcile wrote settings.json; fail-closed must write nothing"

# check() on an undeclared host has no role projection: a stale role URL in
# live settings raw-compares against canonical and must DRIFT.
printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}\n' "$SATELLITE_URL" > "$FIX_CLAUDE_HOME/settings.json"
run_sync check
grep -q "DRIFT: settings.json differs" <<<"$OUT" && ok \
  || bad "unclassified check missed a stale role URL (raw comparison must catch divergence)"

echo "sync-proxy-env-roles: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
