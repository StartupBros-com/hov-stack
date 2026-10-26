---
title: "mise exports RUSTUP_TOOLCHAIN, which outranks every repo's rust-toolchain.toml"
date: "2026-09-08"
category: integration-issues
module: mise
problem_type: integration_issue
component: build_system
severity: high
applies_when:
  - "Building any Rust repo on a machine where mise manages the rust tool"
  - "A build fails on unstable features, edition, or lint flags in a repo that pins a nightly or exact channel"
  - "A version manager and a repo-local pin file both claim authority over the same toolchain"
  - "Reproducing a build that works in CI but fails locally, or vice versa"
symptoms:
  - "rust-toolchain.toml pins nightly but rustc --version reports a stable release"
  - "Build errors name an unstable feature or a nightly-only flag, never the toolchain or the override"
  - "cargo respects the pin on CI and ignores it locally with identical source"
  - "RUSTUP_TOOLCHAIN is set in the environment but appears in no shell profile"
root_cause: configuration
resolution_type: configuration_change
related_components:
  - "mise"
  - "rustup"
  - "cass"
  - "coding_agent_session_search"
tags:
  - mise
  - rustup
  - toolchain-pin
  - env-precedence
  - silent-override
  - build-failure
---

# mise exports RUSTUP_TOOLCHAIN, which outranks every repo's rust-toolchain.toml

## Problem

Two cass builds failed on unstable-feature errors in a tree whose `rust-toolchain.toml` reads `channel = "nightly"`. The errors named the features. They never named the toolchain, and nothing in the output suggested the pin was not in effect.

`rust = "latest"` in `~/.config/mise/config.toml` makes mise's rust plugin export `RUSTUP_TOOLCHAIN` into every shell:

```
$ mise env | grep -i rustup
export RUSTUP_HOME=/home/user/.rustup
export RUSTUP_TOOLCHAIN=1.95.0
```

`RUSTUP_TOOLCHAIN` is rustup's highest-precedence toolchain selector — above a directory override, above `rust-toolchain.toml`. So the pin loses, silently, in every Rust repo on the machine.

## Symptoms

- `rust-toolchain.toml` pins nightly; `rustc --version` reports a stable release
- Errors cite unstable features or nightly-only flags, never the toolchain or the override
- The same source builds on CI (no mise, no exported var) and fails locally
- `RUSTUP_TOOLCHAIN` is set in the environment but grep finds it in no shell profile — mise injects it at shell-hook time, so it exists nowhere on disk to grep for

## Diagnosis

One probe, run from inside the repo, settles it — same directory, same source, only the variable differs:

```
=== rust-toolchain.toml ===
[toolchain]
channel = "nightly"
components = ["rustfmt", "clippy"]
profile = "default"

=== inherited env (RUSTUP_TOOLCHAIN=1.95.0) ===
rustc 1.95.0 (59807616e 2026-04-14)

=== RUSTUP_TOOLCHAIN unset ===
rustc 1.99.0-nightly (af3d95584 2026-07-09)
```

The repo asks for nightly and gets stable 1.95.0. Unset the variable and the identical tree resolves `1.99.0-nightly`. Nothing else changed.

## Solution

For a one-off build, unset it for that command only, from a script file rather than inline:

```bash
cd "$SRC" || exit 1
unset RUSTUP_TOOLCHAIN
cargo build --release
```

Or select the pinned toolchain explicitly, which also works and is self-documenting in logs — `export RUSTUP_TOOLCHAIN=nightly-2026-08-31` names exactly what is being built with, rather than relying on absence.

For the machine, the durable fix is to stop mise from claiming rust at all: drop `rust = "latest"` from `~/.config/mise/config.toml` and let rustup do what it already does well — resolve per-repo pins with no ambient variable involved. This is a global toolchain decision with reach beyond any one repo, so it belongs to the operator, not to a build script working around it.

## Why This Happens

Both tools are behaving correctly and to spec in isolation. mise's job is to pin tool versions per project, and exporting the tool's own selector variable is how it does that. rustup's job is to honour `RUSTUP_TOOLCHAIN` above all other sources, since an explicit environment variable is conventionally the strongest signal available.

The collision is that mise's export is not explicit *to the user* — it comes from a global config listing `rust = "latest"`, which reads as "keep rust current", not as "override every repo's pin". Neither tool can see the conflict: mise does not read `rust-toolchain.toml`, and rustup cannot distinguish a variable a person set deliberately from one a shell hook injected. The resulting failure surfaces two layers downstream, as a compile error about a feature, with no component in a position to report the real cause.

`rust = "latest"` compounds it: the effective toolchain drifts on every mise upgrade, so a build that worked last month can break with no change to the repo.

## Prevention

1. **When a build fails on unstable features or edition flags, check the resolved toolchain before reading the errors.** `rustc --version` inside the repo, compared against the pin, is one command and rules this out immediately.
2. **Treat "set in the environment but in no profile" as a version-manager signature, not a mystery.** Ask the manager what it exports — `mise env` — rather than grepping dotfiles for a variable that is injected, not stored.
3. **Don't let two systems own one toolchain.** Either the version manager pins it or the repo pin file does. Both is not redundancy; it is a silent precedence contest the repo always loses.
4. **Generalise the shape beyond Rust.** Any ambient variable that outranks a repo-local pin fails this way — the pin file is visible in the diff and reviewable, the variable is invisible and wins. When a tool offers both, know which one the tool consults first.
5. **Suspect this whenever local and CI disagree with identical source.** CI usually has no version manager and no exported selector, so it honours the pin the developer's shell is quietly overriding.

## Related Issues

- `routing-metadata-that-says-the-alternative-is-broken-outlives-the-outage.md` (best-practices) — from the same workstream; the shared thread is a signal that is confidently wrong rather than absent, so nothing prompts a re-check.
- `verify-a-pagination-sentinel-is-not-a-corpus-count-before-diagnosing.md` (best-practices) — same discipline, applied earlier: confirm what a value actually means before building a diagnosis on it. Here, confirm which toolchain is actually resolved before reading the compiler's complaints.
