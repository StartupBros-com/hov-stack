#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Install the verified Destructive Command Guard binary (bootstrap only: the
nightly dcg-auto-update timer, where it is enabled, owns the version afterwards).

Usage: ./dcg/install.sh [options]

Options:
  --home DIR        Install beneath DIR instead of \$HOME (safe for tests).
  --source-dir DIR  Read the archive, .sha256 and .minisig from DIR; every check still runs.
  --dry-run         Print the artifact and destination that would be installed; change nothing.
  --force           Replace an existing non-symlink ~/.local/bin/dcg.
  -h, --help        Show this help.

Installs ${DCG_TAG} for Linux (x86_64, aarch64) and macOS (x86_64, arm64) at
  ~/.local/lib/dcg/${DCG_TAG}/dcg
with an atomic symlink at
  ~/.local/bin/dcg

Exit status:
  0  installed, already current, or a newer promoted version was kept
  1  verification refused an artifact, or the destination is in a state this
     installer will not touch; nothing was installed
  ${DCG_EXIT_SKIPPED}  skipped, with the fix printed: a platform with no build here, a
     missing tool, or no network; nothing was downloaded or installed
EOF
}

install_home=${HOME:-}
source_dir=
dry_run=0
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --home)
            [[ $# -ge 2 ]] || dcg_die "--home requires a directory"
            install_home=$2
            shift 2
            ;;
        --source-dir)
            [[ $# -ge 2 ]] || dcg_die "--source-dir requires a directory"
            source_dir=$2
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            dcg_die "unknown option: $1"
            ;;
    esac
done

[[ -n "$install_home" ]] || dcg_die "HOME is empty; pass --home DIR"
[[ "$install_home" == /* ]] || dcg_die "installation home must be an absolute path: $install_home"
[[ "$install_home" != "/" ]] || dcg_die "refusing to use / as the installation home"

target_dir="${install_home%/}/.local/lib/dcg/${DCG_TAG}"
target="${target_dir}/dcg"
bin_dir="${install_home%/}/.local/bin"
link="${bin_dir}/dcg"

# A host with no installable row stops here, before any download, with the fix.
dcg_require_installable_platform

if [[ $dry_run -eq 1 ]]; then
    cat <<EOF
DCG dry run (no files or network accessed)
  version:   ${DCG_TAG}
  platform:  ${DCG_HOST}
  asset:     ${DCG_RELEASE_BASE}/${DCG_ASSET}
  sha256:    ${DCG_ASSET_SHA256}
  minisig:   ${DCG_RELEASE_BASE}/${DCG_MINISIG}
  key:       ${DCG_MINISIGN_KEY_ID}
  sigstore:  $([[ "$DCG_SIGSTORE_BUNDLE" -eq 1 ]] && printf '%s (%s)' "$DCG_COSIGN_IDENTITY" "$DCG_COSIGN_ISSUER" || printf 'not verified for this release')
  binary:    ${target}
  symlink:   ${link} -> ${target}
EOF
    exit 0
fi

# Never walk a promoted version backwards.
#
# OBSERVED 2026-08-06: this script's pin was v0.6.5 and had not moved since #65, but the live
# guard had been promoted to v0.9.2 by scripts/dcg-update.sh -- the verify-then-promote
# updater that only moves the symlink AFTER the dcg-contract/ gate passes. Running
# ./install.sh therefore silently reverted a gated promotion: ~/.local/bin/dcg went back to
# v0.6.5, and per dcg-update.sh's own header v0.9.2 had TIGHTENED `git branch -d` from allow
# to deny. So the downgrade measurably weakened enforcement.
#
# It was also latently worse than it looked. dcg's self_heal_hook rewrites the settings.json
# hook entry to the RESOLVED versioned path on its next invocation, so the agent-facing hook
# would eventually have followed the symlink down to v0.6.5 on its own. What made it visible
# at all was an unrelated failure: sync.sh's reconcile matches the canonical hook by
# resolved path, found v0.6.5 where settings.json said v0.9.2, and aborted install.sh.
#
# Exit 0, not dcg_die: install.sh runs this unconditionally under `set -e`, and a hard failure
# here would abort the whole installer over a machine that is already ahead of the pin.
# readlink -f is missing before macOS 12.3; the link names an absolute versioned path, so
# the plain readlink fallback yields the same version directory.
if [[ $force -ne 1 && -L "$link" ]]; then
    current_target=$(readlink -f -- "$link" 2>/dev/null || readlink -- "$link" 2>/dev/null || true)
    current_version=${current_target%/dcg}
    current_version=${current_version##*/}
    if [[ "$current_version" == v* ]] && dcg_version_newer "$current_version" "$DCG_TAG"; then
        dcg_log "keeping promoted ${current_version}; pin is ${DCG_TAG} (older). Nothing to do."
        dcg_log "  the pin is a floor, not a ceiling -- promote with scripts/dcg-update.sh,"
        dcg_log "  which gates on dcg-contract/. Pass --force to install the pin anyway."
        exit 0
    fi
fi

# The pin already in place: nothing to fetch, so a ./setup rerun touches no network. The
# link must resolve to this pin's target (-ef follows the link without readlink -f) and the
# binary must still carry the pinned digest; anything else falls through to a verified
# install, and --force reinstalls regardless.
if [[ $force -ne 1 && -L "$link" && -f "$target" && ! -L "$target" && "$link" -ef "$target" ]] &&
    dcg_have_sha256; then
    read -r current_sha _ < <(dcg_sha256 "$target") || current_sha=
    if [[ "$current_sha" == "$DCG_BINARY_SHA256" ]]; then
        dcg_log "${DCG_TAG} is already installed at $target. Nothing to do."
        exit 0
    fi
fi

# Every tool the install needs, checked in ONE pass before anything is fetched, so a fresh
# machine learns the whole list at once. A missing tool is a skip that names the install
# command, not a failure: nothing has been downloaded or changed yet (restructure plan U15).
missing=
for command_name in tar file install ln mv mktemp cp env; do
    command -v "$command_name" >/dev/null 2>&1 || missing="$missing $command_name"
done
dcg_have_sha256 || missing="$missing sha256sum"
# type -P, as in dcg_verify_minisign: a shell function named minisign is not minisign.
[[ -n "$(type -P minisign 2>/dev/null || true)" ]] || missing="$missing minisign"
# GNU tar hands .xz to the xz program; bsdtar (macOS) decompresses it itself.
tar_version=$(tar --version 2>/dev/null || true)
if [[ "$tar_version" == *"GNU tar"* ]]; then
    command -v xz >/dev/null 2>&1 || missing="$missing xz"
fi
# cosign is required ONLY when the pin turns Sigstore verification on. Demanding it
# unconditionally would make cosign a hard dependency for a step that does not run.
if [[ "$DCG_SIGSTORE_BUNDLE" -eq 1 ]]; then
    command -v cosign >/dev/null 2>&1 || missing="$missing cosign"
fi
if [[ -z "$source_dir" ]]; then
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
fi
missing=${missing# }
if [[ -n "$missing" ]]; then
    hints=()
    if [[ "${DCG_HOST%%/*}" == Darwin ]]; then
        hints+=("macOS: brew install $missing")
    else
        hints+=("Debian/Ubuntu: sudo apt-get install ${missing/xz/xz-utils}")
        hints+=("Fedora: sudo dnf install $missing")
    fi
    [[ " $missing " != *" minisign "* ]] || hints+=("minisign also installs with: mise use -g minisign")
    hints+=("then re-run ./dcg/install.sh")
    dcg_skip "missing required commands: $missing (nothing was downloaded)" "${hints[@]}"
fi
if [[ -n "$source_dir" ]]; then
    [[ -d "$source_dir" ]] || dcg_die "source directory not found: $source_dir"
fi

if [[ -e "$link" && ! -L "$link" && $force -ne 1 ]]; then
    dcg_die "refusing to replace non-symlink $link (pass --force to replace it)"
fi
if [[ -L "$target" || (-e "$target" && ! -f "$target") ]]; then
    dcg_die "refusing to replace unexpected versioned target: $target"
fi

tmp_base=${TMPDIR:-/tmp}
[[ "$tmp_base" == /* && -d "$tmp_base" ]] || dcg_die "TMPDIR must name an existing absolute directory"
work_dir=$(mktemp -d "${tmp_base%/}/dcg-install.XXXXXX")
target_tmp=
link_tmp=

cleanup() {
    local status=$?

    [[ -z "$target_tmp" ]] || rm -f -- "$target_tmp"
    [[ -z "$link_tmp" ]] || rm -f -- "$link_tmp"
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        case "$work_dir" in
            "${tmp_base%/}"/dcg-install.*) rm -rf -- "$work_dir" ;;
            *) printf 'dcg: warning: refusing unexpected cleanup path: %s\n' "$work_dir" >&2 ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

archive="${work_dir}/${DCG_ASSET}"
checksum="${work_dir}/${DCG_CHECKSUM}"
bundle="${work_dir}/${DCG_BUNDLE}"
minisig="${work_dir}/${DCG_MINISIG}"

# A failed download is a skip: the work directory is removed on exit and nothing was
# installed. curl's own error line stays on stderr.
fetch() {
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --output "$1" "${DCG_RELEASE_BASE}/$2" ||
        dcg_skip "could not download $2 for ${DCG_TAG} (offline?); nothing was installed" \
            "Re-run ./dcg/install.sh once GitHub is reachable."
}

if [[ -n "$source_dir" ]]; then
    dcg_log "copying pinned release assets from $source_dir"
    cp -- "${source_dir%/}/${DCG_ASSET}" "$archive" ||
        dcg_die "missing source archive: ${source_dir%/}/${DCG_ASSET}"
    cp -- "${source_dir%/}/${DCG_CHECKSUM}" "$checksum" ||
        dcg_die "missing published checksum: ${source_dir%/}/${DCG_CHECKSUM}"
    cp -- "${source_dir%/}/${DCG_MINISIG}" "$minisig" ||
        dcg_die "missing minisign signature: ${source_dir%/}/${DCG_MINISIG}"
    if [[ "$DCG_SIGSTORE_BUNDLE" -eq 1 ]]; then
        cp -- "${source_dir%/}/${DCG_BUNDLE}" "$bundle" ||
            dcg_die "missing Sigstore bundle: ${source_dir%/}/${DCG_BUNDLE}"
    fi
else
    dcg_log "downloading ${DCG_ASSET} from ${DCG_TAG}"
    fetch "$archive" "$DCG_ASSET"
    fetch "$checksum" "$DCG_CHECKSUM"
    fetch "$minisig" "$DCG_MINISIG"
    if [[ "$DCG_SIGSTORE_BUNDLE" -eq 1 ]]; then
        fetch "$bundle" "$DCG_BUNDLE"
    fi
fi

read -r actual_sha _ < <(dcg_sha256 "$archive")
[[ "$actual_sha" == "$DCG_ASSET_SHA256" ]] ||
    dcg_die "checksum mismatch for ${DCG_ASSET}: expected ${DCG_ASSET_SHA256}, got ${actual_sha}"
published_checksum=$(<"$checksum")
[[ "$published_checksum" == "${DCG_ASSET_SHA256}  ${DCG_ASSET}" ]] ||
    dcg_die "published checksum file does not exactly match the pinned asset and digest"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$work_dir" && sha256sum -c -- "$DCG_CHECKSUM" >/dev/null) ||
        dcg_die "published checksum file does not verify the archive"
else
    (cd "$work_dir" && shasum -a 256 -c -- "$DCG_CHECKSUM" >/dev/null) ||
        dcg_die "published checksum file does not verify the archive"
fi
dcg_log "pinned and published SHA-256 verified"

dcg_verify_minisign "$archive" "$minisig"

if [[ "$DCG_SIGSTORE_BUNDLE" -eq 1 ]]; then
    cosign verify-blob \
        --bundle "$bundle" \
        --certificate-identity "$DCG_COSIGN_IDENTITY" \
        --certificate-oidc-issuer "$DCG_COSIGN_ISSUER" \
        "$archive" >/dev/null
    dcg_log "Sigstore identity and signature verified"
fi

if ! archive_listing=$(tar -tJf "$archive"); then
    dcg_die "could not read xz archive"
fi
# Command substitution drops the trailing newline, so one entry named dcg reads as
# exactly "dcg" and any second entry leaves a newline in the string.
[[ "$archive_listing" == "dcg" ]] ||
    dcg_die "archive must contain exactly one top-level file named dcg"
if ! verbose_listing=$(tar -tvJf "$archive"); then
    dcg_die "could not inspect xz archive"
fi
[[ "${verbose_listing:0:1}" == "-" ]] || dcg_die "archive entry dcg is not a regular file"

extract_dir="${work_dir}/extract"
mkdir -p -- "$extract_dir"
tar -xJf "$archive" --directory "$extract_dir" --no-same-owner --no-same-permissions -- dcg
extracted="${extract_dir}/dcg"
chmod 0755 -- "$extracted"
dcg_validate_binary "$extracted"
dcg_log "architecture, version, and robot allow/deny checks passed"

mkdir -p -- "$target_dir" "$bin_dir"
target_tmp="${target_dir}/.dcg.tmp.$$"
install -m 0755 -- "$extracted" "$target_tmp"
dcg_validate_binary "$target_tmp"
dcg_mv_over "$target_tmp" "$target"
target_tmp=

link_tmp="${bin_dir}/.dcg.link.$$"
ln -s -- "$target" "$link_tmp"
dcg_mv_over "$link_tmp" "$link"
link_tmp=

dcg_log "installed ${DCG_TAG} at $target"
dcg_log "linked $link -> $target"
