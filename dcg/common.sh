#!/usr/bin/env bash

# Shared, pinned DCG release metadata and validation helpers.
#
# WHY THIS VERSION, AND WHAT VERIFIES IT.
#
# The pin is not "latest" -- it is the newest release this installer can prove
# came from upstream. That used to cap us at 0.6.5, because Sigstore was the only
# signature we checked and upstream's Sigstore signing has been broken since
# ~v0.8.0 (measured 2026-08-27, cosign 3.0.6 and 3.1.3 identical: v0.8.0 through
# v0.12.5 all fail transparency-log verification, and v0.12.5 fails even under
# --insecure-ignore-tlog with "signature time outside of public key validity
# window"). v0.13.0 published no signature asset at all; v0.13.1+ dropped the
# Sigstore bundle and ship minisign.
#
# We now verify minisign, the chain upstream actually maintains, so the pin can
# track current releases again.
#
# Signature policy, in order:
#   1. sha256 against BOTH the pinned digest and the published .sha256  (mandatory)
#   2. minisign against the pinned public key below                     (mandatory)
#   3. Sigstore, only when DCG_SIGSTORE_BUNDLE=1                        (mandatory when on)
#
# The key is PINNED, never fetched. Upstream publishes it in their install.sh; it
# was read once, out of band, and copied here. Fetching a key from the same host
# that serves the artifact it authenticates proves nothing.
#
# ONE KEY ONLY, deliberately. Upstream carries a legacy key and applies it to
# exactly one version (v0.6.7). v0.13.1 was ALSO signed with that legacy key --
# which is what upstream's "v0.13.2 signing correction", cut 28 minutes later,
# fixed. Pinning only the primary key rejects a release signed with the wrong
# key, and v0.13.1 is live proof this matters: it was `latest` for 28 minutes,
# and a sha256-only promote would have accepted it.
#
# NO-CLAIM BOUNDARY: minisign gives authenticity against a pinned key. It does
# NOT provide the transparency-log or OIDC-identity properties the Sigstore path
# claimed, and it does not protect against a compromised upstream signing key.
#
# When bumping, for EVERY row of the platform table below: the asset digest from
# its .sha256, the binary digest from sha256 of the EXTRACTED binary, and a
# minisign check of the archive against the pinned key. Then confirm upstream's
# install.sh for the new tag still pins the same key, and decide
# DCG_SIGSTORE_BUNDLE from whether that release's bundle actually verifies.
readonly DCG_VERSION="0.15.3"
readonly DCG_TAG="v${DCG_VERSION}"
# 0: v0.15.3 publishes a .sigstore.json again, but it does not verify. Checked
# 2026-10-23 with cosign 3.0.6 against the linux x86_64 archive and the release
# workflow identity: "failed to verify log inclusion: transparency log
# certificate does not match". minisign above is the trust root either way, and
# cosign is not a tool a fresh machine should need. Explicit rather than probed,
# so a pin bump forces a conscious decision about what verifies the artifact.
readonly DCG_SIGSTORE_BUNDLE=0
# Upstream primary signing key, key ID 69B3955C8D2E62A8.
#
# PROVENANCE, because a pinned trust anchor with no recorded origin is just a
# string someone typed. Confirmed on TWO channels that are not the release
# assets it authenticates -- fetching a key from the same place as the artifact
# proves nothing:
#
#   1. upstream install.sh (MINISIGN_PUBLIC_KEY), read out of band; re-read from
#      the v0.15.3 release on 2026-10-23 and unchanged
#   2. upstream README.md at commit d1ada2d0136c64146726bdc13b7147b6023c3bad,
#      lines 1120-1129, independently fetched and matched 2026-08-28. Line 1008
#      of the same file corroborates the retired-key story below.
#
# CUSTODY, stated as upstream states it: "DSR-managed". Upstream publishes NO
# rotation or revocation policy that we could find. That is a real gap and it is
# recorded rather than smoothed over -- if this key is ever rotated we will learn
# about it from a verification failure, not from an announcement, and the
# response is to re-verify against both channels above before changing this line.
#
# The legacy key (36B847D11BA5A0D0) is deliberately absent: upstream applies it
# to exactly one version (v0.6.7), and v0.13.1 used it by mistake -- the error
# their "v0.13.2 signing correction" fixed 28 minutes later.
readonly DCG_MINISIGN_PUBKEY="RWSoYi6NXJWzaRs1mJmOwwXrZfPWcq6MXnQlNMLBYKzlIQTLwuVQG6uO"
readonly DCG_MINISIGN_KEY_ID="69B3955C8D2E62A8"
readonly DCG_RELEASE_BASE="https://github.com/Dicklesworthstone/destructive_command_guard/releases/download/${DCG_TAG}"
readonly DCG_RELEASE_PAGE="https://github.com/Dicklesworthstone/destructive_command_guard/releases/tag/${DCG_TAG}"
readonly DCG_COSIGN_IDENTITY="https://github.com/Dicklesworthstone/destructive_command_guard/.github/workflows/dist.yml@refs/tags/${DCG_TAG}"
readonly DCG_COSIGN_ISSUER="https://token.actions.githubusercontent.com"

# Exit status for "skipped: nothing was installed or changed, and the message
# names the fix" -- an unsupported platform, a missing tool, no network. Distinct
# from 1, which means verification refused an artifact or the host is in a state
# this installer will not touch. ./setup reports a skip and carries on (restructure
# plan KTD13); a verification failure is never downgraded to a skip.
readonly DCG_EXIT_SKIPPED=3

dcg_log() {
    printf 'dcg: %s\n' "$*"
}

dcg_die() {
    printf 'dcg: error: %s\n' "$*" >&2
    exit 1
}

# dcg_skip <reason> [fix line...]
dcg_skip() {
    local line
    printf 'dcg: skipped: %s\n' "$1" >&2
    shift
    for line in "$@"; do
        printf '  %s\n' "$line" >&2
    done
    exit "$DCG_EXIT_SKIPPED"
}

dcg_require_command() {
    command -v "$1" >/dev/null 2>&1 || dcg_die "required command not found: $1"
}

# sha256sum on Linux; macOS ships shasum instead. Both print "<digest>  <path>".
dcg_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1"
    else
        shasum -a 256 -- "$1"
    fi
}

dcg_have_sha256() {
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1
}

# THE PLATFORM TABLE: one row per archive the pinned release ships (six for
# v0.15.3). dcg_select_platform sets, for the host:
#
#   DCG_HOST           uname -s/uname -m as seen
#   DCG_ASSET          archive name; DCG_CHECKSUM, DCG_MINISIG, DCG_BUNDLE beside it
#   DCG_ASSET_SHA256   digest of the archive (its published .sha256)
#   DCG_BINARY_SHA256  digest of the extracted binary
#   DCG_FILE_FORMAT,   two substrings `file -b` must print for that binary. Two,
#   DCG_FILE_ARCH      not one phrase: macOS's file prints "Mach-O 64-bit
#                      executable arm64" where Linux's prints "Mach-O 64-bit arm64
#                      executable"
#
# and returns 0 for a row this installer installs, 2 for a row it only describes
# (the Windows zips: download and verify by hand), and 1 for a host with no row.
#
# DCG_UNAME_S and DCG_UNAME_M stand in for uname so the suite and a dry run can
# select any row. Selecting the wrong row on a real host cannot install anything:
# the binary must still pass its digest, `file`, --version and robot checks here.
#
# Not readonly, and selected at source time, so a caller that only reads
# DCG_ASSET or DCG_ASSET_SHA256 gets the host's row, as when there was one row.
dcg_select_platform() {
    local kernel machine os arch

    kernel=${DCG_UNAME_S:-$(uname -s)}
    machine=${DCG_UNAME_M:-$(uname -m)}
    DCG_HOST="$kernel/$machine"
    DCG_ASSET= DCG_ASSET_SHA256= DCG_BINARY_SHA256= DCG_FILE_FORMAT= DCG_FILE_ARCH=
    DCG_CHECKSUM= DCG_MINISIG= DCG_BUNDLE=

    case "$kernel" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT) os=windows ;;
        *) return 1 ;;
    esac
    # Linux reports aarch64 and macOS arm64 for the same architecture.
    case "$machine" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) return 1 ;;
    esac

    case "$os-$arch" in
        linux-x86_64)
            # x86_64 is the only Linux build upstream links statically (musl).
            DCG_ASSET=dcg-x86_64-unknown-linux-musl.tar.xz
            DCG_ASSET_SHA256=dc7dcec9679f74ac3e6990959771ca0c84168eba658eff64fe9e63f917a84cc4
            DCG_BINARY_SHA256=0012c40d26a6820657dcb650a0be7b9e174e603e9ae543cc7202bf7113206bf4
            DCG_FILE_FORMAT="ELF 64-bit LSB" DCG_FILE_ARCH="x86-64"
            ;;
        linux-aarch64)
            # A glibc build: it will not run on a musl-only distribution.
            DCG_ASSET=dcg-aarch64-unknown-linux-gnu.tar.xz
            DCG_ASSET_SHA256=361765877ef5fc2aa89e3d07b189a4abba4368441125fb5f67b5728d26e5b271
            DCG_BINARY_SHA256=7076062cdf084a5f8c309c168b3b77b8d6700fa9fa14e9fd724f8ef034f485b3
            DCG_FILE_FORMAT="ELF 64-bit LSB" DCG_FILE_ARCH="aarch64"
            ;;
        darwin-x86_64)
            DCG_ASSET=dcg-x86_64-apple-darwin.tar.xz
            DCG_ASSET_SHA256=ec548b61a14c29dd2fc9ae54b1512d99cd3a370911e82639ed1fac71eec91585
            DCG_BINARY_SHA256=4f02a0d673eb1d7c3ed54fed823998ac6b8bf5380169b3ff3de10138aed87fd6
            DCG_FILE_FORMAT="Mach-O 64-bit" DCG_FILE_ARCH="x86_64"
            ;;
        darwin-aarch64)
            DCG_ASSET=dcg-aarch64-apple-darwin.tar.xz
            DCG_ASSET_SHA256=50a1a50762299c7e4b5ebaf3f932f45066c8e7c86a1d5d419b01babd1e2698d7
            DCG_BINARY_SHA256=deaffef19ab002d7c499479f3b83c5b6cf9d297d2c2c1096b835349c2e31aff8
            DCG_FILE_FORMAT="Mach-O 64-bit" DCG_FILE_ARCH="arm64"
            ;;
        windows-x86_64)
            DCG_ASSET=dcg-x86_64-pc-windows-msvc.zip
            DCG_ASSET_SHA256=2e399907f6854e189abe6cb08c693751211527594e92b202f4d9452e758da109
            ;;
        windows-aarch64)
            DCG_ASSET=dcg-aarch64-pc-windows-msvc.zip
            DCG_ASSET_SHA256=5901460b3dc36744ef42617047ad45aa468fac75de2b5ededf7eac5f95487b67
            ;;
    esac
    DCG_CHECKSUM="${DCG_ASSET}.sha256"
    DCG_MINISIG="${DCG_ASSET}.minisig"
    DCG_BUNDLE="${DCG_ASSET}.sigstore.json"
    [[ "$os" != windows ]] || return 2
}

DCG_PLATFORM_STATUS=0
dcg_select_platform || DCG_PLATFORM_STATUS=$?

# Exits with DCG_EXIT_SKIPPED, naming the fix, unless the host has an installable row.
dcg_require_installable_platform() {
    case "$DCG_PLATFORM_STATUS" in
        0) ;;
        2)
            dcg_skip "this installer does not install on Windows ($DCG_HOST)" \
                "Download and verify the release by hand, then put dcg.exe on PATH:" \
                "  ${DCG_RELEASE_BASE}/${DCG_ASSET} and ${DCG_MINISIG}" \
                "  sha256 ${DCG_ASSET_SHA256}" \
                "  minisign -Vm ${DCG_ASSET} -P ${DCG_MINISIGN_PUBKEY}" \
                "Release: ${DCG_RELEASE_PAGE}"
            ;;
        *)
            dcg_skip "${DCG_TAG} ships no build for $DCG_HOST" \
                "The release lists every platform it ships: ${DCG_RELEASE_PAGE}"
            ;;
    esac
}

dcg_validate_binary() {
    local binary=$1
    local binary_sha description version_output version_pattern allow_status deny_status

    [[ -f "$binary" && ! -L "$binary" ]] || dcg_die "expected a regular binary: $binary"

    read -r binary_sha _ < <(dcg_sha256 "$binary")
    [[ "$binary_sha" == "$DCG_BINARY_SHA256" ]] ||
        dcg_die "binary checksum mismatch: expected ${DCG_BINARY_SHA256}, got ${binary_sha}"

    description=$(LC_ALL=C file -b -- "$binary")
    [[ "$description" == *"$DCG_FILE_FORMAT"* && "$description" == *"$DCG_FILE_ARCH"* ]] ||
        dcg_die "unexpected binary architecture: $description"

    if ! version_output=$("$binary" --version 2>&1); then
        dcg_die "binary failed its version check: $binary"
    fi
    version_pattern="(^|[[:space:]])v?${DCG_VERSION//./\\.}([[:space:]]|$)"
    [[ "$version_output" =~ $version_pattern ]] ||
        dcg_die "expected DCG ${DCG_VERSION}, got: $version_output"

    # Explicit empty config + empty environment + neutral cwd makes these probes
    # independent of any future ~/.config/dcg, project .dcg.toml, or bypass flag.
    if (cd / && env -i HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent PATH=/usr/bin:/bin \
        "$binary" --robot test --config /dev/null 'git status' >/dev/null 2>&1); then
        allow_status=0
    else
        allow_status=$?
    fi
    [[ $allow_status -eq 0 ]] ||
        dcg_die "robot allow check failed with exit $allow_status"

    if (cd / && env -i HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent PATH=/usr/bin:/bin \
        "$binary" --robot test --config /dev/null 'git reset --hard HEAD~1' >/dev/null 2>&1); then
        deny_status=0
    else
        deny_status=$?
    fi
    [[ $deny_status -eq 1 ]] ||
        dcg_die "robot deny check returned $deny_status instead of 1"
}

# dcg_version_newer A B: succeeds when dotted version A is newer than B (a
# leading v is ignored). Anything that is not all-numeric dotted is never newer.
# Plain bash rather than `sort -V`, which older macOS sort lacks.
dcg_version_newer() {
    local a=${1#v} b=${2#v} x y
    [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ && "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    while [[ -n "$a" || -n "$b" ]]; do
        x=${a%%.*} y=${b%%.*}
        if [[ "$a" == *.* ]]; then a=${a#*.}; else a=; fi
        if [[ "$b" == *.* ]]; then b=${b#*.}; else b=; fi
        x=${x:-0} y=${y:-0}
        ((10#$x > 10#$y)) && return 0
        ((10#$x < 10#$y)) && return 1
    done
    return 1
}

# dcg_mv_over <source> <dest>: rename over dest without following it when dest
# is a link to a directory. GNU mv spells that -T; BSD and macOS mv spell it -h.
dcg_mv_over() {
    if mv --version >/dev/null 2>&1; then
        mv -Tf -- "$1" "$2"
    else
        mv -hf -- "$1" "$2"
    fi
}

# dcg_verify_minisign <artifact> <signature> [pubkey]
#
# Fail-closed. Aborts on a missing verifier, a missing signature, or a signature
# that does not check out against the pinned key. There is deliberately no
# best-effort path: every caller here can safely do nothing instead (the
# bootstrap has installed nothing yet; the updater keeps the version already
# running), so accepting weaker evidence buys exactly nothing. install.sh checks
# for minisign before it downloads anything and reports its absence as a skip;
# reaching this function without it is still a hard failure.
#
# `type -P` resolves a real executable on PATH and will not match a shell
# function or alias -- borrowed from upstream's own strict mode, because a
# stubbed `minisign` exiting 0 would otherwise satisfy the only cryptographic
# check standing between an unattended timer and a new guard binary.
#
# pubkey defaults to the pin and is injectable so the suite can exercise this
# against a keypair it generates, instead of being limited to whatever upstream
# published today. Production callers pass two arguments and get the pin.
dcg_verify_minisign() {
    local artifact=$1 signature=$2 pubkey=${3:-$DCG_MINISIGN_PUBKEY} bin
    bin=$(type -P minisign 2>/dev/null || true)
    [ -n "$bin" ] && [ -x "$bin" ] ||
        dcg_die "minisign not found on PATH; required to verify ${DCG_ASSET} (mise install minisign)"
    [ -s "$signature" ] ||
        dcg_die "minisign signature missing or empty: ${signature}"
    "$bin" -Vm "$artifact" -x "$signature" -P "$pubkey" >/dev/null 2>&1 ||
        dcg_die "minisign verification FAILED for ${DCG_ASSET} (expected key ${DCG_MINISIGN_KEY_ID}); refusing"
    dcg_log "minisign signature verified (key ${DCG_MINISIGN_KEY_ID})"
}
