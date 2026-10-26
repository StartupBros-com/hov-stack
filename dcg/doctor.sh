#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<'EOF'
Validate the pinned DCG installation without changing it. Exits 3, naming the
release page, on a platform this installer has no build for.

Usage: ./dcg/doctor.sh [--home DIR]
EOF
}

install_home=${HOME:-}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --home)
            [[ $# -ge 2 ]] || dcg_die "--home requires a directory"
            install_home=$2
            shift 2
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

target="${install_home%/}/.local/lib/dcg/${DCG_TAG}/dcg"
link="${install_home%/}/.local/bin/dcg"

dcg_require_installable_platform
dcg_require_command file
dcg_require_command env
dcg_require_command readlink
dcg_have_sha256 || dcg_die "required command not found: sha256sum (or shasum)"

[[ -f "$target" && ! -L "$target" ]] || dcg_die "versioned binary is missing: $target"
[[ -L "$link" ]] || dcg_die "managed symlink is missing: $link"
[[ "$(readlink -- "$link")" == "$target" ]] ||
    dcg_die "managed symlink does not target $target"

dcg_validate_binary "$target"
[[ "$link" -ef "$target" ]] || dcg_die "managed symlink does not resolve to the versioned binary"

dcg_log "healthy: ${DCG_TAG} at $target"
dcg_log "robot allow and deny checks passed"
