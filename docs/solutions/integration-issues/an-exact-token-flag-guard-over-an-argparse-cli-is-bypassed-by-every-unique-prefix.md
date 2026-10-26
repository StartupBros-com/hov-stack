---
title: "An exact-token flag guard over an argparse CLI is bypassed by every unique prefix of the flag"
date: "2026-10-13"
category: integration-issues
module: data-source-cli-wrappers
problem_type: security_issue
component: development_workflow
symptoms:
  - "A wrapper refuses `--curl`, `--explain`, `--url` and `--api-key` by exact string match, yet `vastai --cur show user` prints the account's Bearer API key on stdout, exit 0"
  - "`--expl`, `--ur=https://collector.example.test` and `--api-k=<key>` all pass the guard and reach the vendor parser, which reads each as the full flag"
  - "The wrapper's test suite is green: every fixture spells the refused flags in full"
  - "An adversarial review round reproduces the leak in one command against a fake key, where three topic reviewers had read the same guard and passed it"
root_cause: logic_error
resolution_type: code_fix
severity: high
framework_version: "python argparse (allow_abbrev defaults to True); vastai 1.8.3"
related_components:
  - "bin/vastai_wrap.py"
  - "tests/vastai.test.sh"
  - "docs/vets/2026-10-13-vastai-cli-harness-vet.md"
  - "dotfiles#1769"
tags:
  - argparse
  - allow-abbrev
  - flag-guard
  - credential-leak
  - vendor-cli-wrapper
  - adversarial-review
  - vastai
---

# An exact-token flag guard over an argparse CLI is bypassed by every unique prefix of the flag

## Problem

The `vastai` wrapper (dotfiles #1769) stands in front of the vendor's `vastai` CLI so agents can rent GPUs without ever seeing the account's API key. The vendor source prints the full key for `--explain` and `--curl`, sends it to any host named by `--url`, and takes it in argv through `--api-key`, so the wrapper refused those four flags before any exec. The refusal compared each argv token to the four spellings. Python's `argparse` resolves any unambiguous prefix of a long option to that option unless the parser was built with `allow_abbrev=False`, and the vendor parser was not, so `--cur`, `--expl`, `--ur` and `--api` were the same flags to the vendor and invisible to the guard. The first adversarial review round ran `vastai --cur show user --raw` with a fake key and got the Bearer key on stdout.

## Symptoms

- `vastai --cur show user` printed the key and exited 0 while `vastai --curl show user` was refused with exit 2.
- `--ur=https://…` reached the vendor and would have sent the key to that host; `--api-k=<value>` put a key in argv past the guard.
- All 153 wrapper tests passed at the time, because every fixture spelled the flags in full.

## What Didn't Work

- **Exact-token comparison** (`token in ("--explain", "--curl")`, `token == "--api-key"`, `token.startswith("--url")`): correct for the spellings it names, blind to every prefix argparse accepts.
- **Relying on the review ladder's topic reviewers**: three general lenses read the guard and did not try an abbreviation. The adversarial lens, prompted to refute the guard, found it in one command. The vet note (`docs/vets/2026-10-13-vastai-cli-harness-vet.md`) now records this under the `--explain`/`--curl` finding.

## Solution

Resolve every long-option token to the flag argparse would read **before** any guard looks at it, using argparse's own rule: an exact match wins; otherwise a token is the single flag it is a unique prefix of; an ambiguous prefix (argparse would error) and a short option resolve to nothing. The guards then compare canonical flags, never raw tokens, and the refusal names both spellings so the caller learns why `--cur` was refused (`bin/vastai_wrap.py`, `canonical_flag`, the loop at the top of `main`):

```python
GLOBAL_FLAGS = ("--api-key", "--curl", "--explain", "--full", "--help", "--no-color",
                "--raw", "--retry", "--url", "--version")

def canonical_flag(token):
    """The vendor global flag that `token` spells or unambiguously abbreviates,
    with any `=value` removed: `--cur` and `--curl=x` are both `--curl`. None for
    a positional, a short option, a bare `--`, or a prefix argparse would reject
    as ambiguous (`--r` could be `--raw` or `--retry`)."""
    if not token.startswith("--") or len(token) == 2:
        return None
    name = token.partition("=")[0]
    if name in GLOBAL_FLAGS:
        return name
    matches = [flag for flag in GLOBAL_FLAGS if flag.startswith(name)]
    return matches[0] if len(matches) == 1 else None

for token in args:
    flag = canonical_flag(token)
    spelled = flag if token.partition("=")[0] == flag else f"{token} (argparse reads it as {flag})"
    if flag == "--api-key":
        refuse(f"{spelled} puts the key in argv. ...")
    if flag in ("--explain", "--curl"):
        refuse(f"{spelled} prints the full API key to stdout ...")
```

Every other place the wrapper reasons about flags went through the same function: the `--url` value collector (`--ur X`, `--ur=X`), the positional-word extractor that skips a value-taking flag, the `--raw`/`--full`/`--no-color` pager logic, and the credential-free detection for `--help`/`--version` (so `--vers` still runs without resolving a key).

Tests pin the behaviour with the abbreviations themselves (`tests/vastai.test.sh`, the block commented "adversarial round 1, P1"): `--cur --c --expl --e` are refused and never reach the recorded vendor binary, `--api` and `--api-k=` are refused as `--api-key`, `--ur` and `--ur=` to a non-loopback host are refused, the ambiguous `--r` passes through untouched, `--ra` is read as `--raw`, and `--vers` resolves no credential.

## Why This Works

The guard now models the parser it is guarding. argparse's `allow_abbrev` (default `True`) matches a long-option token against every registered option by prefix and accepts a unique match, so the set of tokens that *mean* `--curl` is every prefix of `--curl` down to the shortest that no other option shares (`--cur`, since `--c` would collide with nothing else here but is still unique in this flag set). Comparing canonical flags collapses that whole set onto the one spelling the guard names. Ambiguous prefixes are left alone because argparse rejects them itself, and short options are out of scope because the vendor's dangerous flags have no short form.

The harness already knew this lesson for parsers it **owns**: `stripe-api`, `supabase-api` and `firecrawl-cli` build their parsers with `allow_abbrev=False` so a prefix like `--confirm-mo` cannot stand in for a money-moving confirmation (`bin/stripe_api.py`, `bin/supabase_api.py`, `bin/firecrawl_cli.py`). A wrapper over a **vendor's** parser cannot set that; the only options are to resolve prefixes the way the parser does, or to refuse every `--` token that is not an exact known flag (which breaks legitimate abbreviations users type).

## Prevention

- Any text-level rule keyed to a long option of an argparse program you do not control, whether a wrapper guard, a PreToolUse hook matcher or a settings permission pattern, must either resolve unique prefixes to the canonical flag first or treat every unknown `--token` as the most dangerous flag it could abbreviate. A guard that compares spellings is a guard on the spellings only.
- Where you own the parser, pass `allow_abbrev=False` to `ArgumentParser` **and every subparser** (each `add_parser` call has its own setting), as `supabase_api.py` does.
- When writing tests for a flag guard, add the shortest unique prefix of each refused flag as its own fixture, plus one `=value` form. A suite that only spells the flags in full certifies nothing about abbreviations.
- Put a refute-by-default adversarial lens on any guard that protects a credential before merging. In this case it found the bypass that three topic lenses missed, consistent with the measured yield in `docs/solutions/best-practices/measure-per-tier-review-yield-before-cutting-a-ladder.md`.

## Related Issues

- dotfiles #1769 (the wrapper, the fix and the tests) and #1767 (the work spec).
- `docs/vets/2026-10-13-vastai-cli-harness-vet.md`: the vendor-source line numbers for each key-leaking path.
- `harness/data-source-clis.md`, vast.ai section: the agent-facing rules the wrapper enforces.
