#!/usr/bin/env bash
set -euo pipefail

# Offline boundary fixtures: require the real release URLs and checksum pins,
# then verify fixture bytes with real sha256sum. This is not an upstream
# authenticity test; real pinned downloads are validated separately.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${PROVISION_SCRIPT:-$ROOT/release/scripts/provision-ci-tools.sh}"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/assets/shellcheck-v0.11.0" "$TMP/ambient"
REAL_SHA="$(command -v sha256sum)"
export REAL_SHA
for tool in bash mkdir chmod cp mv tar gzip cat; do
  ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
for tool in jq yq shellcheck actionlint; do
  printf '#!/bin/bash\nprintf "ambient-%s-wrong-version\\n"\n' "$tool" >"$TMP/ambient/$tool"
  chmod +x "$TMP/ambient/$tool"
done
printf '#!/bin/bash\nprintf "jq-1.8.1\\n"\n' >"$TMP/assets/jq"
printf '#!/bin/bash\nprintf "yq-4.50.1\\n"\n' >"$TMP/assets/yq"
printf '#!/bin/bash\nprintf "shellcheck-0.11.0\\n"\n' >"$TMP/assets/shellcheck-v0.11.0/shellcheck"
printf '#!/bin/bash\nprintf "actionlint-1.7.12\\n"\n' >"$TMP/assets/actionlint"
chmod +x "$TMP/assets/actionlint"
chmod +x "$TMP/assets/"{jq,yq,shellcheck-v0.11.0/shellcheck}
tar -czf "$TMP/assets/shellcheck.tar.gz" -C "$TMP/assets" shellcheck-v0.11.0
tar -czf "$TMP/assets/actionlint.tar.gz" -C "$TMP/assets" actionlint

cat >"$TMP/bin/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
url= target=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) target="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) exit 90 ;;
  esac
done
case "$url" in
  https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-amd64) asset=jq ;;
  https://github.com/mikefarah/yq/releases/download/v4.50.1/yq_linux_amd64) asset=yq ;;
  https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.gz) asset=shellcheck.tar.gz ;;
  https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz) asset=actionlint.tar.gz ;;
  *) exit 91 ;;
esac
[ "$asset" != "${FAIL_DOWNLOAD:-}" ] || exit 22
cp "$ASSETS/$asset" "$target"
if [ "$asset" = "${FAIL_CHECKSUM:-}" ]; then
  printf 'corrupted download\n' >>"$target"
fi
STUB

cat >"$TMP/bin/sha256sum" <<'STUB'
#!/bin/bash
set -euo pipefail
[ "$*" = '--check --status' ] || exit 92
read -r pin target
case "$pin" in
  020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d) asset=jq ;;
  c7a1278e6bbc4924f41b56db838086c39d13ee25dcb22089e7fbf16ac901f0d4) asset=yq ;;
  b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6) asset=shellcheck.tar.gz ;;
  8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8) asset=actionlint.tar.gz ;;
  *) exit 93 ;;
esac
digest="$("$REAL_SHA" "$ASSETS/$asset")"
printf '%s  %s\n' "${digest%% *}" "$target" | "$REAL_SHA" --check --status
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/sha256sum"
export ASSETS="$TMP/assets"

count=0
setup_case() {
  count=$((count + 1))
  CASE="$TMP/case-$count"
  mkdir -p "$CASE/runner temp"
  export RUNNER_TEMP="$CASE/runner temp" GITHUB_PATH="$CASE/github-path"
  : >"$GITHUB_PATH"
  unset FAIL_DOWNLOAD FAIL_CHECKSUM
}
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
provision() { PATH="$TEST_PATH" bash "$SCRIPT" >"$CASE/output" 2>&1; }
check_selection() {
  local selected next_path tool expected actual
  selected="$(cat "$GITHUB_PATH")"
  [ "$selected" = "$RUNNER_TEMP/hov-ci-bin" ] || fail 'GITHUB_PATH must select the private bin directory'
  [ "$(wc -l <"$GITHUB_PATH")" -eq 1 ] || fail 'one PATH entry per successful provisioning'
  next_path="$selected:$TEST_PATH"
  for tool in jq yq shellcheck actionlint; do
    [ -x "$selected/$tool" ] || fail "$tool must be provisioned even when ambient tools exist"
    actual="$(PATH="$next_path" bash -c 'command -v "$1"' bash "$tool")"
    [ "$actual" = "$selected/$tool" ] || fail "$tool must resolve to the provisioned executable"
    case "$tool" in jq) expected=jq-1.8.1 ;; yq) expected=yq-4.50.1 ;; shellcheck) expected=shellcheck-0.11.0 ;; actionlint) expected=actionlint-1.7.12 ;; esac
    actual="$(PATH="$next_path" bash -c '"$1" --version' bash "$tool")"
    [ "$actual" = "$expected" ] || fail "$tool must execute the pinned fixture"
  done
}

setup_case
TEST_PATH="$TMP/ambient:$TMP/bin"
provision || { cat "$CASE/output"; fail 'provisioning with ambient tools'; }
check_selection
printf 'ok - wrong-version ambient tools are replaced and next-step PATH selects pinned executables\n'

setup_case
TEST_PATH="$TMP/bin"
provision || { cat "$CASE/output"; fail 'provisioning with tools missing'; }
check_selection
printf 'ok - missing tools are provisioned and selected\n'

for failure in download checksum; do
  for asset in jq yq shellcheck.tar.gz actionlint.tar.gz; do
    setup_case
    TEST_PATH="$TMP/ambient:$TMP/bin"
    if [ "$failure" = download ]; then export FAIL_DOWNLOAD="$asset"; else export FAIL_CHECKSUM="$asset"; fi
    if provision; then fail "$asset $failure failure must stop provisioning"; fi
    [ ! -s "$GITHUB_PATH" ] || fail "$asset $failure failure must not publish a PATH entry"
    case "$asset" in shellcheck.tar.gz) target=shellcheck ;; actionlint.tar.gz) target=actionlint ;; *) target="$asset" ;; esac
    [ ! -x "$RUNNER_TEMP/hov-ci-bin/$target" ] || fail "$asset $failure failure must not install an executable"
    printf 'ok - %s %s failure stops before PATH publication\n' "$asset" "$failure"
  done
done
printf 'Passed %s offline subprocess cases\n' "$count"
