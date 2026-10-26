---
title: "Demote always-loaded agent context without losing operational authority"
date: 2026-08-30
category: best-practices
module: claude-harness-context-management
problem_type: best_practice
component: documentation
severity: medium
applies_when:
  - "An always-loaded agent instruction file mixes durable directives with historical evidence, installation mechanics, or recovery detail"
  - "The same operational detail already has or needs a precise on-read authority"
  - "A context audit produced proposal drafts or receipts that must not become permanent repository noise"
related_components:
  - rent-check
  - claude-global-instructions
  - harness-runbooks
tags:
  - always-loaded-context
  - load-class
  - context-demotion
  - agent-instructions
  - runbook-authority
  - rent-check
---

# Demote always-loaded agent context without losing operational authority

## Context

An always-loaded agent instruction file has two jobs that are easy to conflate:

1. change what the agent does on most relevant turns; and
2. preserve enough detail to install, debug, audit, or explain that behavior later.

Only the first job belongs in the always-loaded layer. Historical probes, credential topology, installation mechanics, and recovery detail are still valuable, but paying their token cost on every turn does not make them more authoritative. It only makes the highest-frequency context harder to scan and easier to contradict.

The dotfiles rent-check workstream exposed both failure modes at once. Model-routing probe history duplicated an existing forensic note, while credential exceptions had accumulated in the global instruction file because they were operationally important. Deleting either block wholesale would have lost evidence or recovery guidance; keeping both in full made rare-use detail permanently loaded. The durable fix shipped across PRs #673, #720, and #727: keep the decision-changing directive and an exact pointer in `CLAUDE.md`, move provenance and mechanics to on-read authorities, and close proposal artifacts separately.

The current tree shows the resulting split:

- `CLAUDE.md:55` retains the model-routing rule and points to `harness/model-routing-forensics.md` for probe history.
- `harness/model-routing-forensics.md:3-5` identifies itself as demoted provenance and says when to read it.
- `CLAUDE.md:124` retains one credential-routing pointer instead of a copied exception catalogue.
- `harness/data-source-clis.md:3-7` says the always-loaded file keeps only routing decisions and measured traps, while install, debug, and re-permission detail lives on read.

## Guidance

### 1. Classify by decision frequency, not importance

Do not ask whether a fact is important. Ask whether it changes an agent's behavior often enough to justify appearing on every turn.

Keep always loaded:

- direct routing decisions (`use gsc, not an MCP`);
- measured traps that change the next command (`filter server-side because row limits truncate`);
- security or authority boundaries (`do not enumerate credential stores`);
- a precise path to the deeper authority.

Demote to on-read:

- probe chronology and historical rationale;
- installation and repair mechanics;
- provider or account inventories;
- exception catalogues consulted only during one operational class;
- evidence receipts that support a directive but are not themselves directives.

This is a load-class decision, not deletion. The on-read document remains versioned and reviewable; the split is intended to stop rare-use detail from taxing unrelated turns.

### 2. Leave an executable pointer, not a vague summary

A demotion is safe only when the residual always-loaded text answers both questions:

1. What should the agent do now?
2. Exactly where should it read before changing, debugging, or re-permissioning that behavior?

The model-routing seam is the compact form to copy:

```markdown
Use the session model for judgment ... When the tier matters, check the
run's reported model; never assume one from config or prose. Probe history:
`harness/model-routing-forensics.md`.
```

The target file then owns the dated probes and their limits. A pointer such as “see the docs” is not enough: it adds retrieval work and makes the deeper authority ambiguous.

### 3. Make the target declare its load class and read trigger

The first paragraph of the on-read document should say why the detail was demoted and when it becomes relevant. Both current authorities do this:

```markdown
Demoted from `~/.claude/CLAUDE.md` ... read it when a pin behaves
unexpectedly or before changing `CLAUDE_CODE_SUBAGENT_MODEL`.
```

```markdown
Detail demoted out of the always-loaded `CLAUDE.md` ... needed only
when you are installing, debugging, or re-permissioning the tools.
```

That declaration prevents two regressions: a future editor copying the detail back “for visibility,” and an agent failing to know when the deeper file is worth loading.

### 4. Verify behavior and references, not just byte reduction

A smaller file is not proof of a safe demotion. The verification set must cover:

- the always-loaded directive still exists;
- the pointer resolves to a current file;
- the target retains the operational detail;
- the real failure or recovery path teaches the permitted command shape;
- stale wording that the demotion replaced is absent.

`tests/test_rent_check_closeout.py:16-37` exercises the real DataForSEO missing-credential path and rejects the worktree-invalid command recipe rather than merely grepping source. `tests/test_rent_check_closeout.py:44-47` checks that the Google IAM authority records the resolved inventory and no longer carries the prior unknown-state claim.

Prefer this behavioral coverage over a snapshot of the entire instruction file. Whole-file snapshots make intentional context edits expensive and encourage blind regeneration; seam assertions name what must survive.

### 5. Separate proposal output from durable receipts

Context audits create drafts, reports, ledgers, and evidence. They should not all live at the same persistence level.

The `.rent-check/` proposal directory is intentionally absent from the tracked tree. `.gitignore:5-6` reserves that ignored location for proposal-only output and points durable receipts to `~/.claude/rent-check/`; `tests/test_rent_check_closeout.py:13-15` pins that `.rent-check/` remains present in `.gitignore`, not the full active-ignore or receipt-location semantics. The final workflow used three dispositions:

- apply verified changes to the canonical files;
- delete stale or superseded local drafts after comparison;
- retain the immutable original report plus a separate closeout receipt outside the repository.

This avoids the worst outcome: a “temporary” audit tree becoming a second documentation system whose stale copies later compete with the canonical instructions.

### 6. Reject support machinery that has no recurring consumer

A one-time audit does not automatically justify a permanent metadata helper, registry, or materializer. Before adding machinery, name the runtime consumer, the decision it gates, the observed recurring defect, and the retirement condition. If the answer is “this would make the audit tidier,” use a one-shot script or direct provider query instead.

The context-demotion work kept existing runbooks and added only narrow seam tests. It did not create a new metadata service or duplicate credential catalogue. That restraint matters: reducing one always-loaded layer while adding a parallel authority elsewhere is not a net simplification.

## Why This Matters

Under this repository's load-cost model, always-loaded text is treated as recurring context rather than a one-time read (`skills-local/rent-check/SKILL.md:55-57`). A paragraph consulted once a month is therefore budgeted repeatedly, while its presence competes with directives that must be noticed immediately. The risk is not only token usage: dense files flatten authority. A dated probe, a current rule, an install recipe, and a security boundary can look equally binding when they share one list.

Demotion restores hierarchy:

- the always-loaded file is an index of decisions and boundaries;
- on-read runbooks hold evidence, mechanics, and recovery detail;
- narrow tests protect selected operational details and proposal-path hygiene;
- receipts prove what the audit changed without becoming another live authority.

The pattern also makes updates safer. Provider inventories and probe results can change without rewriting the global instruction surface, while the stable routing decision remains visible. Under this authority convention, a routing-decision change should be made explicitly in the always-loaded layer rather than introduced through a deep runbook.

## When to Apply

Apply this pattern when:

- a global or root `CLAUDE.md` approaches its byte or line budget or becomes difficult to scan;
- a paragraph is valuable only during installation, debugging, rotation, migration, or incident response;
- the same facts appear in both an instruction file and a harness or runbook document;
- dated evidence is phrased beside current directives and readers can no longer tell which is normative;
- an audit has created drafts or receipts that could be mistaken for canonical project documentation.

Do not demote a rule merely because it is long. Keep it always loaded when omission would change routine behavior, cross a security boundary, or make the pointer impossible to discover at the moment of need. The target state is not the shortest instruction file; it is the smallest always-loaded layer that still routes every consequential decision correctly.

## Examples

### Historical probe detail

**Before:** the global model-routing section contains both the operational rule and dated client or proxy probe history.

**After:** the global section says how to route judgment and verify the served model, then links `harness/model-routing-forensics.md`; the forensic note owns dates, experiments, and caveats.

### Credential exception catalogue

**Before:** the global file named the canonical store and listed runtime exceptions alongside credential-search guidance.

**After:** the global file keeps the anti-enumeration boundary and points to `harness/data-source-clis.md` plus the security runbook for task-specific detail.

### Audit residue

**Before:** proposal drafts sit beside source and can be mistaken for current instructions or accidentally committed.

**After:** `.rent-check/` is ignored, verified edits land in canonical files, stale drafts are deleted after comparison, and durable receipts live under `~/.claude/rent-check/`.

## Related

- `harness/model-routing-forensics.md` — on-read provenance for the concise model-routing directive.
- `harness/data-source-clis.md` — on-read installation, debugging, and credential detail for CLI routing.
- `tests/test_rent_check_closeout.py` — seam tests for proposal artifacts and demoted operational details.
