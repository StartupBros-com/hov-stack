#!/usr/bin/env bash
# install.sh URL construction, offline: curl is stubbed on PATH and logs every URL it is
# asked for. The installer is copied alone into a scratch dir so it takes the download
# path, not local mode. No network calls.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "install.sh URLs"
t="$(mktemp -d "${TMPDIR:-/tmp}/wslcdp-inst.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/src" "$t/home"
cp "$HERE/install.sh" "$t/src/install.sh"
echo microsoft >"$t/proc-version"
cat >"$t/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; --connect-timeout|--proxy) shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
printf '%s\n' "$url" >>"$CURL_LOG"
case "$url" in
  https://api.github.com/*) printf '{"sha":"abc123abc123abc123abc123"}' ;;
  *) [ -n "$out" ] && echo "stub" >"$out" ;;
esac
exit 0
STUB
chmod +x "$t/bin/curl"

run_install(){ # extra env assignments are passed as args
  : >"$t/curl.log"
  env CURL_LOG="$t/curl.log" HOME="$t/home" PATH="$t/bin:$PATH" \
    WSL_CDP_PROC_VERSION="$t/proc-version" "$@" bash "$t/src/install.sh" --quiet >/dev/null 2>&1
}

run_install
log="$(cat "$t/curl.log")"
assert_contains "resolves the ref via hov-stack" "$log" "https://api.github.com/repos/StartupBros-com/hov-stack/commits/main"
for f in wsl-cdp wsl-cdp-forward.py wsl-cdp-drive.mjs wsl-cdp-setup.ps1; do
  assert_contains "fetches $f from the plugin subtree" "$log" "https://raw.githubusercontent.com/StartupBros-com/hov-stack/abc123abc123abc123abc123/plugins/wsl-cdp/$f"
done
case "$log" in *StartupBros-com/wsl-cdp*) _no "no URL points at the old repo" ;; *) _ok "no URL points at the old repo" ;; esac

run_install WSL_CDP_REF=wsl-cdp--v0.3.6
assert_contains "WSL_CDP_REF accepts a release tag" "$(cat "$t/curl.log")" "/repos/StartupBros-com/hov-stack/commits/wsl-cdp--v0.3.6"

t_summary
