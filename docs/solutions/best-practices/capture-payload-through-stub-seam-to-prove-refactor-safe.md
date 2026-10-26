---
title: "Capture the payload through a test's stub seam to prove a refactor is safe, not by sampling"
date: "2026-09-04"
category: best-practices
module: pro-gate-oracle-prompt-capture
problem_type: best_practice
component: development_workflow
severity: medium
applies_when:
  - "A refactor changes how a payload sent to an external binary or API is assembled, and the default/most-common invocation must not silently change"
  - "The engine already resolves that binary through an overridable env var and passes the full payload as a single CLI argument"
  - "The test suite already stubs the binary and records its argv for assertions"
  - "The payload embeds volatile per-run identity (timestamps, pids, run ids, checksums) that would otherwise defeat a byte-exact diff"
tags:
  - pro-gate
  - verification
  - regression-detection
  - test-double
  - capture-and-diff
  - prompt-assembly
  - golden-master
---

# Capture the payload through a test's stub seam to prove a refactor is safe, not by sampling

## Context

pro-gate's `oracle-review.sh` resolves its external "oracle" binary through an overridable env var
— `ORACLE_BIN="${PRO_GATE_ORACLE_BIN:-oracle}"` (bin/oracle-review.sh:2900) — and passes the fully
assembled review prompt as that binary's single `-p` argument (`-p "$(cat "$PROMPT_FILE")"`,
bin/oracle-review.sh:3425). The test suite already exploits this seam: a fake oracle records its
full argv to a file named by `PG_TEST_ARGV_FILE` before writing a canned review (e.g.
tests/engine.test.sh:730), and dozens of checks grep that captured argv for expected flags and text
(tests/engine.test.sh:2044, tests/engine.test.sh:2075).

PR #137 added `--brief`, a flag that lets a caller substitute the engine's built-in reviewer
persona with a custom task body inside the prompt-assembly block
(bin/oracle-review.sh:2916-3042). The risk: touching that block could silently change the DEFAULT
review prompt — the one every prior run without `--brief` depended on, out of a ledger that
already held 723 logged runs by July 2026 alone per README.md:97. Sampling a handful of runs after
the change and eyeballing them would only show the sampled runs still *look* like reviews; it
would not show the bytes were unchanged.

Instead, PR #137's own verification section describes a direct capture-and-diff: run the engine
against a fixed diff input with `PRO_GATE_ORACLE_BIN` pointed at a stub that dumps its `-p`
argument, normalize the two pieces of volatile per-run identity the prompt embeds — the run marker
(`RUN_MARKER="pg-run-${ROUND_KEY:-diff}-$(date +%s)-$$"`, bin/oracle-review.sh:2927, which bakes in
an epoch and a pid) and what the PR body itself calls the "repo-identity hash": a `cksum`-based
checksum of the repo remote URL and branch (`ROUND_SUM`, bin/oracle-review.sh:2794) threaded
through `ROUND_KEY` into the prompt's title line (bin/oracle-review.sh:3307) — then sha256 the
normalized captures from before and after the change. PR #137's body reports the two digests
matching exactly and states the cost in its own words: "This cost zero Pro slots and touched no
network." PR #139, a follow-on hardening pass that edited the same prompt-assembly block again,
re-ran the identical capture and reports the digest unchanged again, confirming the default prompt
stayed byte-for-byte stable across two separate rounds of edits to code sitting right next to it.

## Guidance

### Two preconditions make this work

1. **The seam already exists for tests.** pro-gate didn't build an oracle stub to run this proof —
   it reused the `PRO_GATE_ORACLE_BIN` / `PG_TEST_ARGV_FILE` machinery the test suite already
   depended on. Standing up a capture seam JUST for a one-off verification is a much bigger lift
   than reusing one that is already load-bearing for other tests.
2. **Volatile identity gets normalized before comparison.** Without stripping the run marker's
   embedded epoch+pid and the round checksum, every capture would differ from every other capture
   by construction, and a diff would show noise on every run, never a real signal. Enumerate every
   value in the payload that changes per-invocation rather than per-content before trusting a byte
   comparison of it.

### State plainly what the proof does and does not cover

A byte-exact match on the captured payload proves the code that ASSEMBLES the payload produced
the same bytes for the same input before and after the change. It says nothing about how the
external party (the oracle binary, the model behind it) responds to that payload — that is a
live-behavior risk, not a payload-drift risk, and pro-gate's own history treats them as separate:
PR #139 exists specifically because a live run against a real model (not a stub) surfaced three
design defects that the byte-identical prompt capture could never have caught, since none of them
were about what the prompt said — they were about the model's freedom to disregard the appended
contract once given the floor.

### When to reach for it over sampling

Prefer capture-and-diff whenever the question under test is "did the payload change," not "does
the recipient still behave correctly given the payload." The former is a pure function of the code
between the input and the seam, so one execution per side is exhaustive — there is no larger N
that makes the proof stronger. Sampling only earns its cost when the recipient's behavior is
itself the unknown, and even then it answers a different question than payload drift.

## Applicability

This generalizes past prompt strings: any harness that resolves an external dependency through an
overridable-binary env var and hands it one fully-assembled payload has the same seam available,
whether the payload is a prompt, a request body, or a generated config file. The sibling learning
[verify-parity-claims-by-exercising-both-sides](verify-parity-claims-by-exercising-both-sides.md)
covers the related trap of trusting a design document instead of executing the code it describes
to check that two components agree; this one is narrower and cheaper — it proves ONE component's
output is unchanged across a refactor, using a seam the tests already paid for, and it only ever
proves input fidelity, never recipient correctness.
