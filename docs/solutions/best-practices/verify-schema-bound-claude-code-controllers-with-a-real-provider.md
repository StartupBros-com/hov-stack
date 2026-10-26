---
title: "Verify schema-bound Claude Code controllers with a real provider"
date: 2026-09-01
category: best-practices
module: claude-code-controller
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A controller invokes Claude Code with --agent, --output-format, or --json-schema"
  - "Structured model output authorizes a state transition or another automated action"
  - "A local JSON Schema validator accepts a schema that the provider must also accept"
tags:
  - claude-code
  - structured-output
  - json-schema
  - controller
  - provider-boundary
  - verification
---

# Verify schema-bound Claude Code controllers with a real provider

## Context

A controller can look schema-bound while silently running through a route that does
not deliver schema-validated output. During the memory-miner rollout, the same
minimal schema behaved differently across Claude Code invocation routes: plain print
mode returned `structured_output`, while the custom-main-agent `--agent` route
returned a successful prose-only envelope. Treating `result` as a fallback would
have converted unverified prose into control data.

Fixing that route exposed a second boundary mismatch. The local CLI accepted a
Draft 7 tuple-array schema, but the provider rejected the generated tool schema as
invalid Draft 2020-12 before inference. A third mismatch appeared after inference:
Claude Code 2.1.252 reported one terminal result turn beyond the configured agentic
turn ceiling.

These were separate failures at route construction, provider schema validation, and
metric interpretation. Mocked command tests could not prove any of those boundaries.

## Guidance

1. **Use one provider route and append tracked instructions.** Prefer the ordinary
   print-mode path that has been provider-proven. When a tracked agent artifact owns
   the behavior contract, validate and append its body through
   `--append-system-prompt` rather than switching to an unverified `--agent` route.
   The memory controller implements that split in
   `scripts/memory-mine-controller.py` (shipped in PR #775).

2. **Require `structured_output` when it authorizes control flow.** Missing or
   malformed structured output is a terminal contract failure. Never parse
   human-readable `result` prose as a schema fallback. The memory and loop-quality
   controllers enforce this boundary in PR #772; the memory controller records the
   `structured_output_missing` detail near `scripts/memory-mine-controller.py:91`
   and raises `candidate_invalid` with that detail near lines 1787–1790.

3. **Design provider schemas for every validator they cross.** Prefer homogeneous
   arrays, required object properties, enums, and cross-draft conditionals. Avoid
   Draft 7 tuple `items` when the provider expects Draft 2020-12. Keep stricter local
   invariants at one runtime-normalization boundary—for example, canonicalizing an
   exact session set into manifest order before persistence
   (`scripts/memory-mine-controller.py:1685-1687`, PR #783).

4. **Run a harmless synthetic probe through the exact real route.** Use the same
   prompt route, tool allow/deny lists, schema, working-directory shape, and provider
   endpoint as production, but harmless synthetic inputs and isolated state. Assert
   that the request reaches inference, returns `structured_output`, and survives
   runtime normalization. A mocked subprocess test still belongs in CI, but it proves
   assembly—not provider compatibility.

5. **Separate execution limits from reported metrics.** Keep controller-owned hard
   limits in the actual invocation (`--max-turns 12`, timeout, cost, process group).
   Validate provider-reported completion metrics according to their observed
   accounting rather than assuming they are the same counter. The memory controller
   derives `MAX_REPORTED_TURNS` separately and accepts the terminal reporting turn
   only on completed envelopes (PR #792; definitions and checks at
   `scripts/memory-mine-controller.py:42`, `:784`, `:867`, and `:1817`).

## Why This Matters

A schema is a safety boundary only when the provider accepted it and the controller
received the validated field. Otherwise a controller may spend money, mutate state,
or certify work using data that never passed the claimed contract. Route parity,
provider compatibility, runtime normalization, and metric interpretation each need
their own proof.

## When to Apply

- Headless Claude Code controllers whose output selects work, approves transitions,
  records machine-readable findings, or triggers writes.
- Any invocation using custom agents, custom tool restrictions, or structured-output
  schemas.
- Any controller whose local and provider schema validators may use different JSON
  Schema drafts.
- Any budget check that compares provider telemetry with a controller-owned limit.

## Examples

**Unsafe fallback:**

```python
candidate = envelope.get("structured_output")
if candidate is None:
    candidate = json.loads(envelope["result"])
```

**Fail closed:**

```python
if "structured_output" not in envelope:
    raise OutputContractError("structured_output_missing")
candidate = validate_and_normalize(envelope["structured_output"])
```

**Cross-draft array:**

```json
{
  "type": "array",
  "items": {"type": "object"},
  "minItems": 2,
  "maxItems": 2
}
```

Enforce exact membership with compatible constraints, then normalize order in the
controller instead of relying on draft-specific tuple syntax.

## Related

- [Verify a parity claim by exercising both sides](verify-parity-claims-by-exercising-both-sides.md)
- [Diagnose plugin behavior against the installed version](diagnose-against-installed-versions-not-plugin-caches.md)
