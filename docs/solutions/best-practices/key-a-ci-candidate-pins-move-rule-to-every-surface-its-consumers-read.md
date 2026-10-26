---
title: "Key a CI candidate pin's move rule to every upstream surface its consumers read"
date: 2026-09-28
category: best-practices
module: harness-tests-pro-gate-candidate
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - "A CI job tests downstream adapters against one pinned upstream commit, and a written rule says when to move the pin"
  - "The move rule is keyed to one upstream artifact's identity (a contract digest, schema hash or version field) while the consumers read other parts of the same upstream tree"
  - "A downstream consumer checks upstream prose or other unversioned text by exact match"
  - "A companion PR has to merge before the upstream release it accompanies, so the pin can name only an earlier release"
symptoms:
  - "The candidate job stayed green through six upstream releases that a downstream consumer's exact-text check rejected until #1432 (shown from source and a tag scan, not a run on a Windows host)"
  - "The break surfaced only when an unrelated contract change forced the pin to move"
root_cause: config_error
related_components:
  - harness-tests
  - codex-desktop-bridge
  - pro-gate-skill
tags:
  - ci-candidate-pin
  - pin-move-rule
  - contract-digest
  - skill-prose-drift
  - exact-substring-check
  - codex-desktop-bridge
  - version-skew
  - pro-gate
---

# Key a CI candidate pin's move rule to every upstream surface its consumers read

## Context

dotfiles `.github/workflows/harness-tests.yml` tests two adapters against a pinned pro-gate candidate. It checks out StartupBros-com/pro-gate at one commit (the ref at `:1785`), builds a runtime from it (`RELEASE_TAG=v0.58.0`, `:1793`), and runs the "Pi pro-gate adapter candidate test" (`:1795-1803`) and the "Codex Desktop pro-gate bridge candidate test" (`:1805-1813`) against that build. The comment above the pin sets the rule for moving it: "Move the pin (and the fixtures) whenever the contract digest changes" (`:1778`). The contract digest is one of two digests in the identity file, pro-gate `skills/pro-gate/review-decision-v1.json`; the other, the corpus digest, the rule does not name.

The rule came from dotfiles #1397, the companion to pro-gate #222 (v0.55.0). #1397's body says "Merge this before that release", so it could pin only the released v0.54.0; its comment noted that v0.54.0's identity is one "v0.55.0 keeps". The identity file then stayed byte-identical: its sha256 is `64af5c4cef6c…` at v0.54.0, v0.55.0, v0.55.3, v0.56.0 and v0.57.0, and it changed only at v0.58.0. By its own rule the pin was right not to move from v0.55.0 through v0.57.0.

pro-gate #222 also changed skill prose. At v0.54.0, pro-gate `skills/pro-gate/SKILL.md:99` ends "…; pro-gate has no merge authority." From v0.55.0 a new sentence precedes it, and line 126 ends "… a cached query is not a GitHub freshness check. Pro-gate has no merge authority." Every tag from v0.55.0 through v0.58.0 carries the capitalized form, and none carries the lowercase one.

The Codex Desktop bridge reads that prose. `windows/sync-claude-skills-to-codex.ps1` `Assert-ProGateSource` reads the skill raw (`:269`), lists required substrings (`:270-281`), and throws "Repository skill is missing required typed-dispatch policy: $text" when one is absent (`:282-284`). .NET `String.Contains(string)` is ordinal, so the match is case-sensitive. Until #1432 the list held the lowercase "pro-gate has no merge authority" (`:273`), and the bridge test asserted the same phrase (`windows/tests/sync-claude-skills-to-codex.test.ps1:201`). Read against each tag's skill, the pre-#1432 source shows the bridge throwing with that lowercase text for any skill from v0.55.0 on, and not mounting it; no Windows host has exercised this. The candidate job kept testing v0.54.0's skill, which still carried the lowercase phrase, so it stayed green.

dotfiles #1432 moved the pin to v0.58.0 because v0.58.0 changed the contract identity, and the moved pin exposed the break. The bridge test under pwsh 7.6.6 failed at the #1432 head before the phrase fix and passed 45/0 after it (session evidence). #1432 changed the bridge and its test to the capitalized phrase. It also states the claim's limit: that the bridge could not mount pro-gate since v0.55.0 "comes from reading the source and the tag scan. It was not exercised on a Windows host."

## Guidance

A pin's move rule covers only the surface it is keyed to. Before trusting a green candidate job across a version range, list what each consumer reads from the pinned tree, and key the rule to all of it.

Here the two consumers read different surfaces:

- **The pi test reads only the identity and the frozen corpus.** It reads `CANONICAL_IDENTITY` (`pi/agent/tests/oracle-pro-gate.test.ts:17`), and it reduces pro-gate `tests/fixtures/review-decision/v1/corpus.json` through the candidate's own library (`:168-170`). It reads no skill prose, but the rule covers it only while a corpus change also moves the contract digest. The identity's `corpus_digest` is a separate field the rule does not name. In the tags sampled from v0.50.0 to v0.58.0 the two changed together, at v0.53.0 and v0.58.0.
- **The bridge and its test read much more.** `Assert-ProGateSource` checks `SKILL.md` prose by exact substring (`windows/sync-claude-skills-to-codex.ps1:269-284`), the skill's Codex metadata, pro-gate `skills/pro-gate/agents/openai.yaml` (`:286-290`), and the identity (`:292-293`). It then reads the plugin manifest's version, pro-gate `.claude-plugin/plugin.json` (`:294`), and checks the identity resolver, pro-gate `skills/pro-gate/scripts/resolve-identity.sh`, by the same kind of exact substring, throwing `PGC004` when one is missing (`:230-246`, called at `:295`). Last it reads the runtime built from the pin: its `VERSION` must equal the manifest version (`PGC005`, `:297-304`), and its `lib.sh` identity must match (`:309`). The digest rule covers only the identity.

Ways to close the gap. These are recommendations; none is in place:

1. **Key the rule to every file the consumers read.** Here that is pro-gate `skills/pro-gate/SKILL.md`, `skills/pro-gate/agents/openai.yaml`, `skills/pro-gate/scripts/resolve-identity.sh`, `.claude-plugin/plugin.json` and `tests/fixtures/review-decision/v1/corpus.json`, beside `review-decision-v1.json`, plus the runtime built from them. Move the pin when any of them changes. A list this long is itself the case for recommendation 2.
2. **Move the pin on every upstream release.** This costs a candidate run per release even when nothing a consumer reads changed, but it leaves no blind spot. It also covers the companion case: a companion that merges before its release can pin only the previous one, so move the pin once the release is tagged.
3. **Assert a structured field instead of prose** wherever the upstream offers one. The bridge already checks the identity structurally. Its prose checks carry no version contract of their own, so any upstream edit can break them.

The residual is live: `harness-tests.yml:1778` still keys the pin to the contract digest alone. A prose edit inside an unchanged digest, the shape of #222, would again go untested until a digest change happens to move the pin.

## Why This Matters

The green candidate job proved one thing: contract compatibility with v0.54.0. It did not prove that the bridge could mount v0.55.0 through v0.57.0. That was easy to read as the stronger claim, because the job's name says "candidate" and the job stayed green while six releases shipped (v0.55.0 on 2026-09-25 through v0.57.0 on 2026-09-27). The exposure rests on source and a tag scan, not a Windows repro; carry that qualifier whenever the claim is repeated.

The companion ordering makes the lag structural rather than accidental. When a caller update must merge before the upstream release, the pin cannot name that release at merge time. Under a digest-only rule, the pin does not move to it afterwards either unless the next release happens to change the digest.

## When to Apply

- Writing or reviewing a "move the pin when X changes" rule for an upstream commit that CI tests against.
- Adding a consumer that string-matches upstream prose, or that reads any upstream file the move rule does not key on.
- Merging a companion PR before the upstream release it accompanies.
- Not needed when the pin already moves on every upstream release, or when every consumer reads only the artifact the rule is keyed to.

## Examples

The breaking change was one inserted sentence. Before it, pro-gate `skills/pro-gate/SKILL.md` at v0.54.0 (line 99) read:

```text
Re-query immediately before handing off to the existing merge workflow; pro-gate has no merge authority.
```

After it, v0.55.0 (line 126) read:

```text
Prepare current PR evidence in a new directory and re-query with it immediately before handoff; a cached query is not a GitHub freshness check. Pro-gate has no merge authority.
```

The edit left `review-decision-v1.json` byte-identical, so the pin rule saw nothing to move for. Yet it changed the one substring that `windows/sync-claude-skills-to-codex.ps1:273` and `windows/tests/sync-claude-skills-to-codex.test.ps1:201` required verbatim. That is the shape to watch for: a no-op for the identity the pin is keyed to, and a breaking change for a consumer the pin does not watch.

The pin's own history shows how it moves:

| PR | Pin | Why it moved |
|---|---|---|
| dotfiles #548 | an unpublished pro-gate commit, runtime 0.36.0 | Introduced for the Pi/Codex adapter parity job (dotfiles #547), pinned to "the exact unpublished pro-gate commit they were authored against" |
| dotfiles #1110 | unchanged | Moved the block while splitting the harness suite |
| dotfiles #1397 | v0.54.0 | Wrote the digest rule |
| dotfiles #1432 | v0.58.0 | The digest changed |

Nothing in that history moves the pin on a release that keeps the digest.

## Related

- [A grepped implementation string in a test is a caller a rename sweep never sees](a-grepped-implementation-string-in-a-test-is-an-invisible-caller.md) is the same failure one level down. A consumer depends on an exact string, and the mechanism meant to catch a breaking change watches a narrower signal: an identifier sweep there, a digest-keyed pin here. CONCEPTS.md's *Pinned anchor* names that doc's case; the bridge's required phrase shares the invisible-caller trait but feeds no positional assertion.
- [Routing metadata that says the alternative is broken outlives the outage](routing-metadata-that-says-the-alternative-is-broken-outlives-the-outage.md) is another case of a narrow proxy standing in for the thing it should track, with nothing to force a recheck.
- [Run the release-notes checker locally and read tagged blobs through git show](run-the-release-notes-checker-locally-and-verify-tagged-blobs-with-git-show.md) describes the method that established the tag facts above: reading each tag's blobs with `git show <tag>:<path>`. When counting a lowercase literal, use a case-sensitive search. This host's `~/.ripgreprc` sets `--smart-case`, so `rg -F` with an all-lowercase pattern also matches the capitalized form.
- [Verify a parity claim by exercising both sides, never by reading a design table](verify-parity-claims-by-exercising-both-sides.md): the candidate job exists to prove Pi/Codex adapter parity, and a pin that stops moving proves parity only against the release it names.
- dotfiles #1397 wrote the rule; dotfiles #1432 moved the pin and fixed the phrase.
