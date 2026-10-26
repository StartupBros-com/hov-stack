# Falsifiers and evidence

The result that would kill each rule in `SKILL.md`, plus the citations behind
the `[research]` tags and the runs behind the `[measured]` ones. Disclosed
rather than inline: a falsifier tells you when to *stop trusting* a rule,
which is a question you ask while auditing the doctrine, not while applying
it. Measured against the doctrine's own progressive-disclosure rule, keeping
this material in the main file cost 22.8% of its length and measurably
reduced how many defects it found
([swapgate4](https://github.com/StartupBros-com/skill-tuner/blob/main/reports/swapgate4-summary.md)).

Tags in `SKILL.md` stay inline. The tag is the confidence signal and costs a
token; the paragraph explaining how to disprove it does not need to be in
the agent's context to shape an edit.

## Context pointers

- **Front-load the leading word** — a pointer whose trigger word is moved to
  the end routes as well as one that front-loads it.
- **One trigger per branch** — a pointer listing synonym triggers routes
  better than one that collapses them, on a blind battery with distractors.
- **Cut identity the body states** — restating the body's identity in the
  pointer measurably improves routing.
- **Never summarize the workflow in the pointer** — a description containing
  a full step-by-step summary routes and executes identically (same
  defect-catch rate) to the same skill with a what/when-only description.
  (Candidate rule, 2026-08-10: sourced from an external authoring guide, no
  paired-compare run behind it yet — first tune/eval pass should test it.)
- **Description pruning lands only at routing parity** — a parity-checked
  prune that measurably undertriggers once it reaches live use.
- **Model-invoked vs user-invoked** — a user-invoked skill an agent reaches
  reliably without being named, or a model-invoked skill nobody types and no
  other skill calls.
- **Router skills** — a router skill that does not reduce "I forgot this
  existed" incidents versus the un-routed set.

## The two loads

- **Context load** — a model whose task performance is flat as always-loaded
  material grows across the tested range.
- **Cognitive load** — moving a document between the two loads produces no
  measurable change in agent token spend or in human recall.

## Structure and disclosure

- **Progressive disclosure** — disclosing reference that every branch needs
  produces no drop in completion quality.
- **Co-location** — scattering a concept's rules across three headings with
  no measurable drop in the agent applying all of them.
- **Sprawl** — doubling a document's length with no drop in attention to any
  single rule, including its mid-document rules.
- **Splitting** — a split that changes neither completion thoroughness nor
  routing reach.

## Steps, completion, and demand

- **Completion criteria** — a sharpened bound that leaves the
  premature-completion rate unchanged; or contradictory bounds that agents
  resolve consistently without a stated precedence.
- **Demand** — a high-demand and a low-demand wording that produce the same
  depth of work.
- **Subagent dispatch has a cost ceiling** — a red-team re-run showing
  uncapped subagent fan-out costs the same as capped fan-out.

## Leading words

- **Leading words** — a leading-word refactor with no measurable change in
  execution behaviour. No direct research support exists for this rule yet;
  the `[craft]` tag stands until an A/B confirms or kills it.
- **Negation** — a negated instruction that suppresses the named behaviour as
  reliably as its positive rephrasing, across repeated trials.

## Pruning and drift

- **Single source of truth** — a duplicated rule that never drifts out of
  sync with its source across repeated edits.
- **Relevance and sediment** — a document left unpruned for a year with no
  accumulation of dead lines.
- **No-op verdicts are time-relative** — a no-op verdict from one model
  version that stays correct, unchecked, across three consecutive upgrades.

## Citations behind the `[research]` tags

Each citation was fetched and adversarially re-verified against its claimed
finding on 2026-08-08 before being recorded here; one quantitative claim
failed that check and was discarded.

- **Negation**: Jang, Ye & Seo, *Can Large Language Models Truly Understand
  Prompts? A Case Study with Negated Prompts* (arXiv:2209.12711). All tested
  LM families perform worse on negated prompts, with an inverse scaling law
  — larger models do worse, not better.
- **Context load**: Chroma, *Context Rot: How Increasing Input Tokens
  Impacts LLM Performance* (trychroma.com/research/context-rot) — all 18
  tested frontier models degrade on simple, difficulty-held-constant tasks
  as input grows. Anthropic, *Effective context engineering for AI agents* —
  context as "a finite resource with diminishing marginal returns" under an
  "attention budget", "a performance gradient rather than a hard cliff".
- **Sprawl**: Liu et al., *Lost in the Middle: How Language Models Use Long
  Contexts* (arXiv:2307.03172, TACL 2024) — mid-document material is
  measurably harder to use than the same material at either end, even for
  explicitly long-context models. Plus Chroma's context-rot result above.

## Where this doctrine's own claims stand

Full evidence ledger, receipts, and the eval runner:
https://github.com/StartupBros-com/skill-tuner. The short version:

- Three gates failed to beat the upstream text (v1 inconclusive with
  regression confirmed, v1-stripped inconclusive, v2 not_worse).
- **v3** (2026-08-08, 15 docs): 42 vs 29 confirmed defects, 95% CI
  [+0.03, +1.70], **better** — bootstrap CI agrees, the sign test alone
  would not resolve; a near-boundary win, quoted at that strength
  ([swapgate6](https://github.com/StartupBros-com/skill-tuner/blob/main/reports/swapgate6-summary.md)).
- The incumbent it beat was frozen from upstream on 2026-08-05 and includes
  upstream's 2026-07-23 rename/restructure and its last content change
  (2026-07-28) — plus one local sentence (the time-relative no-op
  amendment). The comparison is against current upstream content, made
  strictly harder by that amendment.
- The doctrine as a whole measured better once; no individual rule is
  thereby validated.
