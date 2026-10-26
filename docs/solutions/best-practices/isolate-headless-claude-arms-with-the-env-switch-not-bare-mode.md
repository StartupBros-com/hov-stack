---
title: "Isolate headless claude arms with CLAUDE_CODE_DISABLE_CLAUDE_MDS=1, not --bare"
date: "2026-09-20"
category: best-practices
module: headless-claude-arm-isolation
problem_type: best_practice
component: testing_framework
severity: high
resolution_type: code_fix
applies_when:
  - "A harness shells out to `claude -p` to run measurement, review, probe, routing or judge arms and the result is compared across runs or across machines"
  - "Per-call cost or the arm's answers change with the directory the harness is launched from, or an arm mentions the operator's own rules, memory or project instructions"
  - "Someone proposes `--bare` to strip the caller's instruction files from a headless call"
symptoms:
  - "An arm launched from a directory with a CLAUDE.md and an auto-memory index reports the host's memory index loaded on every call, at roughly ten times the per-call cost of the same call without it"
  - "`--setting-sources \"\"` is already set and makes no difference, because it governs settings files, not instruction files or memory"
  - "Banked baselines from before the switch pair silently with new runs unless the adapter shape is recorded and the comparison refuses the mismatch"
tags: [headless, claude-p, adapter-isolation, bare-mode, oauth, eval-arms, provenance]
related_components:
  - skill-tuner-adapter
  - memory-dream-eval
---

# Isolate headless claude arms with CLAUDE_CODE_DISABLE_CLAUDE_MDS=1, not --bare

## Context

skill-tuner's adapter had run every probe, routing and endtask arm with `--setting-sources ""` and assumed that isolated the arm. Measured on 2026-09-20 (Claude Code 2.1.278, Sonnet, three calls per condition, launched from a directory with a CLAUDE.md and an auto-memory index): the agent under test reported the host's memory index loaded every time and the calls cost $0.0593, $0.0598 and $0.0283. The same calls with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` in the environment reported nothing loaded and cost $0.0045, $0.0041 and $0.0062; `--bare` gave $0.0005. So every arm the tool had ever run judged its target with the caller's doctrine in context, which is a confound (the host's rules are not the document under test) and about an order of magnitude of per-call cost. The vet's first proposal was `--bare`, and the headless documentation refused it: in bare mode Claude Code never reads OAuth credentials or the system keychain, so a tool distributed to subscription-auth users would stop working for all of them.

## Guidance

For any harness that runs `claude -p` as an arm:

- Put `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` in the subprocess environment of every arm. It strips the user CLAUDE.md, the project CLAUDE.md and auto memory and leaves authentication alone. Do it in the one adapter chokepoint (skill-tuner's `adapter_env()` merges it over the caller's environment so `ANTHROPIC_API_KEY` and `PATH` survive), and add a test that the subprocess call receives it and that the command never contains `--bare`.
- Do not reach for `--bare` unless the harness authenticates with an API key only. Bare mode is the cheaper envelope, but it is an auth-mode decision, not an isolation knob.
- Treat the change as an envelope change: record a new adapter shape in every manifest the arms write (skill-tuner uses `claude-p-user-message-isolated` and `claude-p-doctrine-system-prompt-isolated`) and make the comparison refuse to pair runs of different shapes. Figures measured under the old envelope are stale as per-call costs and say so in the cost doc; the direction of earlier findings does not depend on them.
- `--setting-sources ""` stays for what it does govern, settings files; it is not a substitute.

## Why This Matters

An arm is a unit of exposure: it treats whatever its launcher hands it as instruction. A harness that lets the operator's own rules into the arm measures those rules as much as the document under test, and it pays for them on every call. The failure is silent, because the arm still answers and the cost is only visible in aggregate. The wrong fix is silent in a different way: `--bare` works on the developer's machine with an API key in the environment and breaks on every subscription-auth install.

## When to Apply

- Any new headless adapter, and any existing one whose manifests do not record an envelope shape.
- Before trusting a per-call cost figure or a cross-run comparison from a harness launched inside a repository with instruction files.
- Not for interactive sessions, where the instruction files are the point.

## Examples

Verified by launching the arm from a directory with instruction files and asking it what it loaded: before, `CLAUDE_MD: yes` on three of three calls; after, `CLAUDE_MD: no` on three of three, with the operator's login untouched. skill-tuner v0.8.2 (PR #53) shipped the switch and the `-isolated` shapes; its unit suite asserts the environment reaches the subprocess and that the default and doctrine-in-system paths both record the isolated shape.

## Related

- `docs/vets/2026-09-20-claude-plugin-eval-harness-vet.md` (the measurement and the rejected `--bare` proposal)
- skill-tuner's cost document (its docs folder), section "Arms no longer carry the caller's CLAUDE.md and memory" (the re-baseline boundary)
- The headless documentation's bare-mode section (bare mode reads no OAuth credentials)
- CONCEPTS.md: Arm
