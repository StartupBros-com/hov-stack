# Destructive Command Guard

This directory owns the first-install path for the DCG binary. Agent hook wiring
lives with each agent's canonical configuration; the installer deliberately does
not rewrite Claude, Pi, Codex, or shell configuration.

There are two install paths. `install.sh` here bootstraps a machine with no dcg
from one pinned release. After that, the nightly updater owns the version.

## Bootstrap: one pinned release, verified before anything lands

`install.sh` installs the release that `common.sh` pins (`DCG_VERSION`, now
v0.15.3). It picks the archive for the host from the platform table in
`common.sh`:

| Host | Archive |
| --- | --- |
| Linux x86_64 | `dcg-x86_64-unknown-linux-musl.tar.xz` |
| Linux aarch64 | `dcg-aarch64-unknown-linux-gnu.tar.xz` |
| macOS x86_64 | `dcg-x86_64-apple-darwin.tar.xz` |
| macOS arm64 | `dcg-aarch64-apple-darwin.tar.xz` |
| Windows x86_64, aarch64 | not installed: the installer names the `.zip`, its SHA-256 and the minisign command to check it by hand, then skips |

Every row pins its archive's SHA-256. Each `.tar.xz` row also pins the extracted
binary's SHA-256 and its `file` signature. The install fails if any of these
fails: the published `.sha256` against the pin, the downloaded archive against
the pin, the minisign signature against the pinned signing key
(`69B3955C8D2E62A8`), an archive holding anything but `dcg`, the extracted
binary's checksum, architecture or version, or either robot-mode smoke check.
There are no verification-skip flags.

minisign is the trust root. The release also publishes a Sigstore bundle, but
cosign rejects v0.15.3's ("transparency log certificate does not match"), so the
pin sets `DCG_SIGSTORE_BUNDLE=0`. A pin that sets it to 1 makes cosign mandatory.

Robot probes run from `/` with an empty environment and `--config /dev/null`, so
user or project configuration cannot change the installer/doctor result.

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | Installed, already current, or a newer version the nightly updater promoted is kept (it never downgrades) |
| 1 | Verification failed, or the destination is in a state it will not touch; nothing is installed |
| 3 | Skipped: no build for this platform, a required tool is missing, or GitHub is unreachable; nothing is installed |

A skip prints its reason and the fix: the release page for an unsupported
platform, every missing command at once with the platform's install command
(minisign also installs with `mise use -g minisign`), or a re-run once GitHub is
reachable. The repository's root `install.sh` runs this script under `set -e`,
so a skip stops it just as a failure does. `./setup` instead reports a skip or a
failure in its closing status block and carries on with the other steps; only a
failure makes it exit 1.

A rerun with the pin already in place (the link resolves to the pinned binary and
its digest still matches) downloads nothing and exits 0; `--force` reinstalls.

`allowlist.toml` contains only exact-command exceptions for reproducible cache
directories that the default filesystem pack otherwise blocks. It deliberately
does not allow the general `rm-rf` rule.

## Nightly: latest, contract-gated, never pinned by version

`systemd/dcg-auto-update.timer` runs `scripts/dcg-update.sh` nightly; it fetches
the newest GitHub release, verifies the published checksum and the minisign
signature against the same pinned signing key, installs the candidate to its own
`~/.local/lib/dcg/vX.Y.Z/` directory, runs the behavioural contract in
`scripts/dcg-contract/` from that directory, and only then moves the
`~/.local/bin/dcg` symlink and re-points the live hook. A candidate that fails
the contract is refused and the box stays on the previous version; the previous
version directory is kept as the rollback affordance and reaped after the next
promote. What the updater pins is the signing key and the contract, not a
version (dotfiles#517, #1201).

Hook path policy (dotfiles#1201): the tracked `settings.json` names the
stable symlink `/home/user/.local/bin/dcg` and never a version. The live
`~/.claude/settings.json` names the resolved versioned binary, which is
upstream's fail-closed absolute hook path and the form dcg's own self-heal
writes. `sync.sh reconcile-dcg` bridges the two, and `harness-doctor.sh`
section 11b warns when the live hook and the installed binary disagree.

## Usage

Review the archive, checksum and paths the host would get, without network or
writes:

```bash
./dcg/install.sh --dry-run
```

Install the verified binary and its atomic symlink:

```bash
./dcg/install.sh
./dcg/doctor.sh
./dcg/sync.sh install
```

The resulting paths are (the version is the pin on first install, then whatever
the nightly updater last promoted):

```text
~/.local/lib/dcg/vX.Y.Z/dcg
~/.local/bin/dcg -> ~/.local/lib/dcg/vX.Y.Z/dcg
```

`--home DIR` redirects both paths for isolated testing. `--source-dir DIR`
accepts an already-downloaded archive, its `.sha256` file and its `.minisig`
signature, but still performs all verification.

## Tests

```bash
bash tests/dcg.test.sh
```

That is the suite CI runs. It runs `dcg/tests/install-test.sh`, installs the
pinned release into a temporary home, and runs the minisign, policy, protocol
and allowlist-sync tests in `dcg/tests/` against that binary through `DCG_BIN`,
so this machine's own dcg is neither touched nor trusted. It needs the network
and minisign.

`install-test.sh` downloads and verifies the real pinned release and every
platform's published archive against its pin, and covers a tampered archive, a
signature from another key, a missing minisign, no network, an unsupported
platform and Windows. It installs only inside a disposable directory under
`${TMPDIR:-/tmp}`. The protocol test feeds command strings to DCG without
executing them and verifies Claude/Codex denial contracts plus an unchanged
disposable-repository sentinel.
