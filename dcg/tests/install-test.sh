#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DCG_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
INSTALLER="$DCG_DIR/install.sh"
DOCTOR="$DCG_DIR/doctor.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Derive the pin rather than duplicating it. This suite used to hardcode both
# the version directory and the asset digest, so bumping DCG_VERSION broke it
# with "dry run omitted the pinned checksum" -- a test failure that says nothing
# about the thing under test. A checked-in copy of a pinned constant is drift
# waiting to happen; sourcing it means the suite tracks the pin for free.
# shellcheck source=../common.sh
. "$DCG_DIR/common.sh"

tmp_base=${TMPDIR:-/tmp}
test_root=$(mktemp -d "${tmp_base%/}/dcg-install-test.XXXXXX")
cleanup() {
    local status=$?

    case "$test_root" in
        "${tmp_base%/}"/dcg-install-test.*) rm -rf -- "$test_root" ;;
        *) printf 'warning: refusing unexpected test cleanup path: %s\n' "$test_root" >&2 ;;
    esac
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

test_home="${test_root}/home"
expected_target="${test_home}/.local/lib/dcg/${DCG_TAG}/dcg"
expected_link="${test_home}/.local/bin/dcg"

printf '1/18 syntax checks\n'
bash -n "$DCG_DIR/common.sh" "$INSTALLER" "$DOCTOR" "$0"

printf '2/18 dry run is non-mutating\n'
dry_output=$("$INSTALLER" --home "$test_home" --dry-run)
[[ "$dry_output" == *"$DCG_ASSET_SHA256"* ]] ||
    fail "dry run omitted the pinned checksum"
[[ ! -e "$test_home" ]] || fail "dry run created its requested home"

printf '3/18 verified installation into temporary home\n'
"$INSTALLER" --home "$test_home"
[[ -x "$expected_target" && ! -L "$expected_target" ]] || fail "versioned binary was not installed"
[[ -L "$expected_link" ]] || fail "managed symlink was not installed"
[[ "$(readlink -- "$expected_link")" == "$expected_target" ]] || fail "managed symlink target is wrong"
first_hash=$(sha256sum -- "$expected_target")

printf '4/18 doctor, and a rerun with the pin in place fetches nothing\n'
"$DOCTOR" --home "$test_home"
# A --source-dir that does not exist proves the rerun read no artifact: any fetch or copy
# would stop on it.
rerun_output=$("$INSTALLER" --home "$test_home" --source-dir "${test_root}/no-such-source" 2>&1) ||
    fail "a rerun with the pin in place did not exit 0: $rerun_output"
[[ "$rerun_output" == *"already installed"* ]] || fail "a rerun with the pin in place did not say so: $rerun_output"
second_hash=$(sha256sum -- "$expected_target")
[[ "$first_hash" == "$second_hash" ]] || fail "idempotent reinstall changed the pinned binary"
# Planted negative: a pinned binary whose digest no longer matches is not taken as current.
cp -p -- "$expected_target" "${test_root}/pinned-dcg"
printf 'x' >>"$expected_target"
if "$INSTALLER" --home "$test_home" --source-dir "${test_root}/no-such-source" >"${test_root}/altered.log" 2>&1; then
    fail "a pinned binary with the wrong digest was taken as already installed"
fi
grep -q -F 'source directory not found' "${test_root}/altered.log" ||
    fail "an altered pinned binary did not fall through to a verified install: $(cat "${test_root}/altered.log")"
cp -p -- "${test_root}/pinned-dcg" "$expected_target"
"$DOCTOR" --home "$test_home"

printf '5/18 unrelated command is not overwritten without force\n'
rm -- "$expected_link"
printf '#!/bin/sh\nexit 0\n' >"$expected_link"
chmod 0755 "$expected_link"
if "$INSTALLER" --home "$test_home" >"${test_root}/refusal.log" 2>&1; then
    fail "installer overwrote a non-symlink command without --force"
fi
grep -q 'refusing to replace non-symlink' "${test_root}/refusal.log" ||
    fail "installer refusal was not explicit"

# Cases 6-8 cover the no-downgrade guard. OBSERVED 2026-08-06: the pin here is v0.6.5 and
# had not moved since #65, while dcg-update.sh had gate-promoted the live guard to v0.9.2.
# Running install.sh walked ~/.local/bin/dcg back to v0.6.5 -- which per dcg-update.sh's
# header is measurably weaker (0.9.2 tightened `git branch -d` from allow to deny).
newer_dir="${test_home}/.local/lib/dcg/v9.9.9"
newer_target="${newer_dir}/dcg"
link_to_newer() {
    mkdir -p "$newer_dir"
    printf '#!/bin/sh\nexit 0\n' >"$newer_target"
    chmod 0755 "$newer_target"
    rm -f -- "$expected_link"
    ln -s -- "$newer_target" "$expected_link"
}

printf '6/18 a newer promoted version is kept, not walked backwards\n'
link_to_newer
"$INSTALLER" --home "$test_home" >"${test_root}/downgrade.log" 2>&1 ||
    fail "installer exited non-zero over a newer promoted version (install.sh runs it under set -e)"
grep -q 'keeping promoted v9.9.9' "${test_root}/downgrade.log" ||
    fail "installer did not say it was keeping the promoted version"
[[ "$(readlink -- "$expected_link")" == "$newer_target" ]] ||
    fail "installer DOWNGRADED the managed symlink away from the promoted version"

printf '7/18 --force still installs the pin over a newer version\n'
link_to_newer
"$INSTALLER" --home "$test_home" --force
[[ "$(readlink -- "$expected_link")" == "$expected_target" ]] ||
    fail "--force did not install the pinned version"

printf '8/18 an OLDER linked version is still upgraded to the pin\n'
older_dir="${test_home}/.local/lib/dcg/v0.0.1"
mkdir -p "$older_dir"
printf '#!/bin/sh\nexit 0\n' >"${older_dir}/dcg"
chmod 0755 "${older_dir}/dcg"
rm -f -- "$expected_link"
ln -s -- "${older_dir}/dcg" "$expected_link"
"$INSTALLER" --home "$test_home" >"${test_root}/upgrade.log" 2>&1 ||
    fail "installer failed when the linked version was older than the pin"
grep -q 'keeping promoted' "${test_root}/upgrade.log" &&
    fail "guard wrongly fired for a version OLDER than the pin"
[[ "$(readlink -- "$expected_link")" == "$expected_target" ]] ||
    fail "installer did not upgrade an older linked version to the pin"

# Cases 9-18 are the platform table and the soft-fail contract (restructure plan U15): a host
# with no build, a missing tool or no network is skipped with exit 3 and the fix printed,
# while a tampered archive or a foreign signature still fails closed with exit 1. Every
# case below asserts that nothing was installed.
expect_status() {
    local want=$1 log=$2 status=0
    shift 2
    "$@" >"$log" 2>&1 || status=$?
    if [[ $status -ne $want ]]; then
        cat -- "$log" >&2
        fail "expected exit $want, got $status: $*"
    fi
}
no_error_line() {
    ! grep -qF 'dcg: error' "$1" || fail "$2 printed a dcg: error line: $(cat -- "$1")"
}
nothing_installed() {
    [[ ! -e "$1/.local/lib/dcg" && ! -e "$1/.local/bin/dcg" && ! -L "$1/.local/bin/dcg" ]] ||
        fail "$2 left an installation under $1"
}

printf '9/18 each platform selects its own archive\n'
# The expected names are written out here, not read from common.sh: this is the mapping
# under test. The digests come from the table, and case 10 checks them against upstream.
while read -r os arch expected_asset; do
    dry_home="${test_root}/dry-${os}-${arch}"
    dry_output=$(DCG_UNAME_S=$os DCG_UNAME_M=$arch "$INSTALLER" --home "$dry_home" --dry-run)
    [[ "$dry_output" == *"/${expected_asset}"$'\n'* ]] ||
        fail "$os/$arch dry run did not select $expected_asset"
    row_sha=$(DCG_UNAME_S=$os DCG_UNAME_M=$arch dcg_select_platform && printf '%s' "$DCG_ASSET_SHA256")
    [[ -n "$row_sha" && "$dry_output" == *"sha256:    ${row_sha}"* ]] ||
        fail "$os/$arch dry run did not print its row's digest"
    [[ ! -e "$dry_home" ]] || fail "$os/$arch dry run created its home"
done <<'ROWS'
Linux x86_64 dcg-x86_64-unknown-linux-musl.tar.xz
Linux amd64 dcg-x86_64-unknown-linux-musl.tar.xz
Linux aarch64 dcg-aarch64-unknown-linux-gnu.tar.xz
Linux arm64 dcg-aarch64-unknown-linux-gnu.tar.xz
Darwin x86_64 dcg-x86_64-apple-darwin.tar.xz
Darwin arm64 dcg-aarch64-apple-darwin.tar.xz
ROWS

printf '10/18 every row names the real, signed upstream archive\n'
# Only the host's row is ever installed in CI, so a mistyped digest in any other row would
# reach a stranger as a hard checksum failure. Fetch each archive and check it the way the
# installer would, short of running a binary built for another platform.
rows_dir="${test_root}/rows"
while read -r os arch; do
    (
        export DCG_UNAME_S=$os DCG_UNAME_M=$arch
        row_status=0
        dcg_select_platform || row_status=$?
        [[ $row_status -ne 1 ]] || fail "$os/$arch has no row"
        row_dir="${rows_dir}/${DCG_ASSET}"
        mkdir -p -- "$row_dir"
        for name in "$DCG_ASSET" "$DCG_CHECKSUM" "$DCG_MINISIG"; do
            curl --fail --silent --show-error --location --proto '=https' --retry 3 \
                --output "${row_dir}/${name}" "${DCG_RELEASE_BASE}/${name}"
        done
        read -r row_sha _ < <(dcg_sha256 "${row_dir}/${DCG_ASSET}")
        [[ "$row_sha" == "$DCG_ASSET_SHA256" ]] ||
            fail "$DCG_ASSET: table digest $DCG_ASSET_SHA256, upstream archive $row_sha"
        [[ "$(<"${row_dir}/${DCG_CHECKSUM}")" == "${DCG_ASSET_SHA256}  ${DCG_ASSET}" ]] ||
            fail "$DCG_ASSET: published .sha256 does not match the table"
        dcg_verify_minisign "${row_dir}/${DCG_ASSET}" "${row_dir}/${DCG_MINISIG}" >/dev/null
        if [[ $row_status -eq 0 ]]; then
            [[ "$(tar -tJf "${row_dir}/${DCG_ASSET}")" == "dcg" ]] ||
                fail "$DCG_ASSET does not hold exactly one file named dcg"
            tar -xJf "${row_dir}/${DCG_ASSET}" --directory "$row_dir" -- dcg
            read -r row_sha _ < <(dcg_sha256 "${row_dir}/dcg")
            [[ "$row_sha" == "$DCG_BINARY_SHA256" ]] ||
                fail "$DCG_ASSET: table binary digest $DCG_BINARY_SHA256, extracted $row_sha"
            description=$(LC_ALL=C file -b -- "${row_dir}/dcg")
            [[ "$description" == *"$DCG_FILE_FORMAT"* && "$description" == *"$DCG_FILE_ARCH"* ]] ||
                fail "$DCG_ASSET: file says '$description'"
        fi
    )
done <<'ROWS'
Linux x86_64
Linux aarch64
Darwin x86_64
Darwin arm64
MINGW64_NT-10.0 x86_64
MINGW64_NT-10.0 arm64
ROWS

printf '11/18 a platform with no build is skipped with the release link\n'
expect_status 3 "${test_root}/unsupported.log" \
    env DCG_UNAME_S=FreeBSD DCG_UNAME_M=amd64 "$INSTALLER" --home "${test_root}/h11"
grep -qF "ships no build for FreeBSD/amd64" "${test_root}/unsupported.log" ||
    fail "unsupported-platform skip did not name the host"
grep -qF "$DCG_RELEASE_PAGE" "${test_root}/unsupported.log" ||
    fail "unsupported-platform skip did not link the release"
[[ ! -e "${test_root}/h11" ]] || fail "unsupported-platform skip created its home"
no_error_line "${test_root}/unsupported.log" "an unsupported-platform skip"

printf '12/18 Windows is skipped with the zip, its digest and the key\n'
expect_status 3 "${test_root}/windows.log" \
    env DCG_UNAME_S=MINGW64_NT-10.0-19045 DCG_UNAME_M=x86_64 "$INSTALLER" --home "${test_root}/h12"
windows_sha=$(DCG_UNAME_S=MINGW64_NT-10.0 DCG_UNAME_M=x86_64 dcg_select_platform || true
    printf '%s' "$DCG_ASSET_SHA256")
for expected in dcg-x86_64-pc-windows-msvc.zip "$windows_sha" "$DCG_MINISIGN_PUBKEY" "$DCG_RELEASE_PAGE"; do
    grep -qF -- "$expected" "${test_root}/windows.log" || fail "Windows skip omitted $expected"
done
[[ ! -e "${test_root}/h12" ]] || fail "Windows skip created its home"
no_error_line "${test_root}/windows.log" "the Windows skip"

# The host row's real assets, fetched by case 10, seed the --source-dir cases.
host_assets="${rows_dir}/${DCG_ASSET}"
seed_source() {
    mkdir -p -- "$1"
    cp -- "${host_assets}/${DCG_ASSET}" "${host_assets}/${DCG_CHECKSUM}" "${host_assets}/${DCG_MINISIG}" "$1/"
}

printf '13/18 a tampered archive fails closed and installs nothing\n'
seed_source "${test_root}/tampered"
printf 'x' >>"${test_root}/tampered/${DCG_ASSET}"
expect_status 1 "${test_root}/tampered.log" \
    "$INSTALLER" --home "${test_root}/h13" --source-dir "${test_root}/tampered"
grep -qF "checksum mismatch for ${DCG_ASSET}" "${test_root}/tampered.log" ||
    fail "tampered archive was not refused on its checksum"
nothing_installed "${test_root}/h13" "a tampered archive"

printf '14/18 a signature from another key fails closed and installs nothing\n'
seed_source "${test_root}/wrongkey"
minisign -G -p "${test_root}/other.pub" -s "${test_root}/other.sec" -W >/dev/null
rm -f -- "${test_root}/wrongkey/${DCG_MINISIG}"
minisign -S -s "${test_root}/other.sec" -m "${test_root}/wrongkey/${DCG_ASSET}" \
    -x "${test_root}/wrongkey/${DCG_MINISIG}" >/dev/null
expect_status 1 "${test_root}/wrongkey.log" \
    "$INSTALLER" --home "${test_root}/h14" --source-dir "${test_root}/wrongkey"
grep -qF "minisign verification FAILED" "${test_root}/wrongkey.log" ||
    fail "foreign signature was not refused by minisign"
nothing_installed "${test_root}/h14" "a foreign signature"

# A PATH holding only the tools the installer uses, minus the ones a case removes, and a
# curl that records being called and fails the way an offline machine's curl does.
make_path() {
    local dir=$1 tool tool_path
    shift
    mkdir -p -- "$dir"
    for tool in bash dirname uname tar xz file install ln mv mktemp cp env sha256sum shasum \
        readlink rm mkdir chmod cat minisign; do
        case " $* " in *" $tool "*) continue ;; esac
        tool_path=$(type -P "$tool" 2>/dev/null) || continue
        ln -s -- "$tool_path" "$dir/$tool"
    done
    printf '#!/bin/sh\n: >"%s"\necho "curl: (6) Could not resolve host: github.com" >&2\nexit 6\n' \
        "$dir/curl-was-called" >"$dir/curl"
    chmod -- 0755 "$dir/curl"
}

printf '15/18 a missing minisign is skipped with its install command, before any download\n'
make_path "${test_root}/path-no-minisign" minisign
expect_status 3 "${test_root}/no-minisign.log" \
    env PATH="${test_root}/path-no-minisign" "$BASH" "$INSTALLER" --home "${test_root}/h15"
grep -qF "missing required commands: minisign" "${test_root}/no-minisign.log" ||
    fail "missing-minisign skip did not name minisign"
grep -qF "mise use -g minisign" "${test_root}/no-minisign.log" ||
    fail "missing-minisign skip did not give an install command"
[[ ! -e "${test_root}/path-no-minisign/curl-was-called" ]] ||
    fail "installer downloaded before checking for minisign"
nothing_installed "${test_root}/h15" "a missing minisign"
no_error_line "${test_root}/no-minisign.log" "a missing-minisign skip"

printf '16/18 no network is skipped, not failed\n'
make_path "${test_root}/path-offline"
expect_status 3 "${test_root}/offline.log" \
    env PATH="${test_root}/path-offline" "$BASH" "$INSTALLER" --home "${test_root}/h16"
grep -qF "(offline?)" "${test_root}/offline.log" || fail "offline skip did not say so"
grep -qF "Could not resolve host" "${test_root}/offline.log" || fail "offline skip hid curl's error"
[[ -e "${test_root}/path-offline/curl-was-called" ]] || fail "offline case never reached the download"
nothing_installed "${test_root}/h16" "an offline run"
no_error_line "${test_root}/offline.log" "an offline skip"

# A chmod shaped like macOS's: BSD chmod reads every argument after the mode as a file, so
# `chmod 0755 -- f` fails with "chmod: --: No such file or directory". OBSERVED 2026-11-03
# (#371): that one spelling made every Mac install fail after both verifications passed.
printf '17/18 a BSD-shaped chmod installs: no option marker after the mode\n'
real_chmod=$(type -P chmod)
make_path "${test_root}/path-bsd-chmod" chmod
cat >"${test_root}/path-bsd-chmod/chmod" <<EOF
#!/bin/sh
[ "\$1" = -- ] && shift
case "\$1" in -*) echo "chmod: unexpected option \$1" >&2; exit 1 ;; esac
mode=\$1
shift
for f in "\$@"; do
    if [ "\$f" = -- ] || [ ! -e "\$f" ]; then echo "chmod: \$f: No such file or directory" >&2; exit 1; fi
done
exec "$real_chmod" "\$mode" "\$@"
EOF
"$real_chmod" 0755 "${test_root}/path-bsd-chmod/chmod"
# Planted negative: the stub refuses the GNU-only spelling, so it is a real stand-in.
touch "${test_root}/chmod-probe"
if "${test_root}/path-bsd-chmod/chmod" 0755 -- "${test_root}/chmod-probe" 2>/dev/null; then
    fail "the BSD-shaped chmod stub accepted an option marker after the mode"
fi
seed_source "${test_root}/bsd-source"
expect_status 0 "${test_root}/bsd-chmod.log" \
    env PATH="${test_root}/path-bsd-chmod" "$BASH" "$INSTALLER" --home "${test_root}/h17" \
    --source-dir "${test_root}/bsd-source"
[[ -x "${test_root}/h17/.local/lib/dcg/${DCG_TAG}/dcg" && -L "${test_root}/h17/.local/bin/dcg" ]] ||
    fail "a BSD-shaped chmod did not end in an installed, linked binary"

# set -e ends the installer at any unchecked failure; the ERR trap is what makes that end
# name the command, instead of leaving ./setup pointing at a dcg: error line never printed.
printf '18/18 an unexpected failure prints one dcg: error line naming the command\n'
make_path "${test_root}/path-failing-chmod" chmod
printf '#!/bin/sh\nexit 1\n' >"${test_root}/path-failing-chmod/chmod"
"$real_chmod" 0755 "${test_root}/path-failing-chmod/chmod"
expect_status 1 "${test_root}/failing-chmod.log" \
    env PATH="${test_root}/path-failing-chmod" "$BASH" "$INSTALLER" --home "${test_root}/h18" \
    --source-dir "${test_root}/bsd-source"
# shellcheck disable=SC2016  # the backticks are literal, as install.sh prints them
grep -qE '^dcg: error: `chmod .*` failed \(exit 1\) at line [0-9]+ of install\.sh$' \
    "${test_root}/failing-chmod.log" ||
    fail "a failing chmod ended the installer without a dcg: error line: $(cat -- "${test_root}/failing-chmod.log")"
[[ $(grep -cF 'dcg: error' "${test_root}/failing-chmod.log") -eq 1 ]] ||
    fail "a failing chmod printed more than one dcg: error line: $(cat -- "${test_root}/failing-chmod.log")"
[[ ! -e "${test_root}/h18/.local/bin/dcg" && ! -L "${test_root}/h18/.local/bin/dcg" ]] ||
    fail "a failing chmod still linked dcg"

printf 'PASS: DCG installer tests used only %s\n' "$test_root"

