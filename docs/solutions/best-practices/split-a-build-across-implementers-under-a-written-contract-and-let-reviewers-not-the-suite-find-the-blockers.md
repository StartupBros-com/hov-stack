---
title: "Split a build across implementers under a written contract, and expect the reviewers, not the green suite, to find the blockers"
date: "2026-09-13"
category: best-practices
module: sign-it-onboarding-build-orchestration
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A feature touches one large script plus several new files and would take a single agent most of a day"
  - "Running a workflow of parallel implementers in one worktree, where two agents editing the same file would collide"
  - "Deciding whether a green suite is enough evidence to ship a change that adds a network listener, a decoder, or any surface that takes untrusted input"
related_components:
  - "skills-local/sign-it/docs/onboarding-flow.md"
  - "skills-local/sign-it/scripts/image-clean.mjs"
  - "skills-local/sign-it/tests/run.sh"
tags: [workflow, contract-first, parallel-implementation, adversarial-review, integrator, sign-it, onboarding]
---

# Split a build across implementers under a written contract, and expect the reviewers, not the green suite, to find the blockers

## Context

sign-it's first-run onboarding (dotfiles #1140) needed a detached drawing listener with a phone link, an image-cleanup module, four new config fields, preview and undo, doctor fields, a rewritten skill script and a page of tests: a day of work through one context. It was built in about thirty minutes of wall-clock by a workflow of three implementers writing in the same worktree, followed by one integrator and two reviewers. The suite came back 215 of 215. The reviewers then found two blockers the suite could not have: a live listener was reused for a phone request even when it was bound to localhost, and both image decoders ran on whatever size the file declared, so a small file claiming a huge canvas would exhaust memory. Neither was a test the implementers would have written, because both are about inputs the contract never mentioned.

## Guidance

1. **Write the contract before the fan-out, and make it the only shared state.** One document names every file and its single owner, every command flag with its exact JSON shape, every config key and file name, every error code and the sentence it maps to, and the test each acceptance item needs. Agents do not negotiate seams in chat; they read the contract. Here that was `/tmp/.../onboarding-contract.md`, about 120 lines, referenced by every prompt.

2. **Partition by file, never by feature.** Implementer A owned the CLI script and the drawing page, B owned the new image module and its fixture generators, C owned SKILL.md, README and the test script. A new module's export signature and thrown error shape were fixed in the contract so A could import B's file before it existed. No worktree isolation was needed because no two agents touched one file.

3. **One integrator, alone, to green.** After the fan-out, a single agent runs the whole suite and fixes seams in any file, with the rule that it may not weaken or delete a check to pass; a wrong check is fixed to the contract and reported. It found one seam (an old planted-negative test now met a different, correct exit code from the new error taxonomy).

4. **Then two reviewers with different seats, refute-by-default, before the orchestrator reads the diff.** A spec-conformance reviewer reads the built flow against the spec's wording; a security reviewer attacks the new surfaces with a written list (token entropy and single use, bind address, expiry and teardown, size limits, path handling, what a second client on the LAN can do, permissions, argument quoting, decoder bombs, what state files leak). The second seat is where the blockers came from.

5. **Fix the blockers at the source, then re-verify with the same suite plus one test per finding.** The size check reads the declared dimensions from the PNG IHDR or the JPEG SOF marker before any decoder allocates, and requires the IHDR marker first so a corrupt file still reads as unreadable rather than too-large. The listener compares the requested mode with the live one and replaces a mismatch. `doctor` prints a listener summary without the token or the URL. Each got a check in the suite (219 after).

## Why This Matters

A green suite proves the code does what its authors imagined; the reviewers proved it also survives what they did not. The security reviewer's finding was a memory-exhaustion bug on the one input path that accepts files from a network listener, in a feature whose whole point is to be safe for non-technical users. The cost of the reviewers was two agents and a few minutes; the cost of shipping without them would have been discovered by the first hostile image.

## When to Apply

- Any change that adds a listener, an upload, a decoder, or a parser of files the user did not author: add the security seat with a written attack list, whatever the suite says.
- Any build too large for one context: write the contract first, partition by file, one integrator, then review. Do not let implementers "coordinate" in prose.
- When an integrator wants to change a test to pass: it must cite the contract clause the test contradicts, or the test stands.

## Examples

- **Contract line that prevented a seam:** "`cleanSignatureImage(buffer) → { png, width, height, cleaned }`; errors are thrown as `{ code: 'heic' | 'too-small' | 'unreadable' }`." A wired its `--from` handler to `.code` before B's file existed; B's report reminded the integrator that the throws are plain objects, not `Error` instances.
- **Blocker the suite could not see:** `setup --draw --phone` returned the running localhost listener's URL. The suite had a phone test and a local test, never one after the other. The reviewer ran them in sequence.
- **Blocker the suite could not see:** `PNG.sync.read` on a 200-byte file declaring 100,000 by 100,000 pixels. The fix is eight lines and a header read; the test is a stub file.

## Related

- `docs/solutions/best-practices/harden-a-heuristic-tool-on-the-operators-real-files-with-a-trial-fleet.md`: the same skepticism applied to inputs instead of code.
- `docs/solutions/logic-errors/a-signature-stamper-that-never-looks-at-pixels-will-sign-over-an-executed-signature.md`: an earlier sign-it blocker found by trial rather than review.
