---
name: cass-rerank-local
description: >-
  Lexical session search with optional semantic reranking. Use INSTEAD of bare `cass search` for top-1/top-few relevant-session results
  (past fixes, decisions, "how did I do X"); for broad scans, plain cass.
---

<!--
  LOCAL skill, pairs with the `cass-rerank` wrapper (source: scripts/cass-rerank
  in the hov-stack repo; put it on PATH to call it by name). Routes through the
  gateway host's `local-rerank`
  LiteLLM lane over the tailnet with a scoped virtual key, per the lab's target
  architecture (one gateway, one pane; no ad-hoc SSH tunnels). The old
  SSH tunnel chain is retired.

  Model-choice history: the original "granite-r2 is best" result came from an
  eval with leaked synthetic queries and single-positive labels. The 2026-07
  rebuild reversed it — granite-r2 came LAST and was the only
  reranker that hurt vs baseline. The gateway lane exposes `local-rerank` only,
  which sidesteps that choice entirely.
-->

# cass-rerank — reranked session search

> ⚠️ **NEVER run bare `cass`** — it launches a blocking TUI. Use `cass-rerank` or `cass ... --robot`.

> **Historical incidents:** lexical retrieval failed in September 2026 (upstream
> cass #494), and this wrapper previously mislabeled retrieval
> errors as "no results". Lexical recovery was observed on September 29; synthetic
> scoring was observed on October 1. Those dated observations are not current-health
> guarantees or post-fix end-to-end evidence. The wrapper now reports retrieval
> failures separately from a valid search with no candidates.

## Use it

```bash
cass-rerank "how did I fix supabase RLS policy errors" --require-rerank
cass-rerank "stripe webhook signature verification" --limit 3 --require-rerank
cass-rerank "oauth token refresh" --json --require-rerank
cass-rerank "oauth token refresh" --json  # permits labeled lexical fallback
```

Use `--require-rerank` when genuine scoring is required. With candidates present,
scoring failure exits nonzero instead of returning fallback results. A legitimate
no-candidate response does not contact the scoring service and proves nothing
about its health, including in strict mode.

`--limit` is an upper bound, not an exact-count promise. A shorter nonempty
scoring response is accepted if its count, indices and scores are valid;
`--require-rerank` requires valid scoring without fallback, not exactly K results
or backend-completeness attestation.

Each result prints the ranked snippet + `source_path:line` you can open.

## When to use which

| Situation | Tool |
|-----------|------|
| "Find the ONE session where I solved X" (top-1 matters) | `cass-rerank` |
| Broad keyword scan, many hits | `CASS_AUTO_REFRESH=0 cass search "query" --robot --no-maintenance --mode lexical --limit 3` |
| Deep dive / cited evidence pack | `cass pack "..." --robot` (jsm cass skill) |

## Diagnose retrieval without maintenance

Native retrieval failures exit nonzero; they are not empty matches. This includes
native exit-zero responses with `budget.timed_out=true`, whether they contain no
hits or partial hits. Preserve the diagnostic and inspect `CASS_SEARCH_TIMEOUT_MS`,
`CASS_SEARCH_BUDGET_MS`, or `cass.toml` deadlines; an incomplete search is not a
completed empty search. To diagnose retrieval without maintenance:

```bash
CASS_AUTO_REFRESH=0 cass search "query" --robot --no-maintenance --mode lexical --limit 3
CASS_AUTO_REFRESH=0 cass status --json
```

On `maintenance-required`, `checkpoint_incomplete`, or an incomplete checkpoint,
hand recovery to the operator. Agents must not initiate rebuilds or try a non-robot
search to trigger inline repair. The wrapper itself forces operation-local
`CASS_AUTO_REFRESH=0`, `--no-maintenance`, and `--mode lexical` for retrieval;
it does not depend on the calling shell's environment to disable maintenance.

## Notes

- **Observable outcome:** by default, endpoint/protocol failures return useful
  lexical-order results with null rerank scores and a stderr warning. JSON
  `rerank_status` is `reranked` for validated scoring, `lexical_fallback` for that
  fallback, `no_candidates` for a genuine empty search, or `failed` for retrieval
  failure or strict-mode scoring failure. Failures exit nonzero; JSON mode emits
  one failure document with an error and no results. `reranked` validates response
  mapping, not backend identity or scoring quality; valid score ties are preserved.
- HTTP 200 from model listing is not proof that scoring works.
- Routing stays through the gateway's scoped-key lane, not a raw backend or SSH
  tunnel. `CASS_RERANK_ENDPOINT` is required (no default; the wrapper names the variable when it is unset); `CASS_RERANK_MODEL` sets
  the default requested model and `--model` overrides it. The output `model` is
  that requested label, not backend attestation. `CASS_BIN` overrides the native
  executable. Existing candidate/overfetch and `--no-dedupe` controls remain available.
- Auth: scoped virtual key at `~/.config/cass-rerank/key` (600), limited to `local-rerank` + `local-embed`. Never the master key. Override with `CASS_RERANK_API_KEY`.
- Reranking only reorders what lexical retrieved — it can't surface a session lexical never found (recall is the separate embedding-index question).
- **Reranking's real-world value is modest.** On the corrected eval, no reranker beat the embedding baseline by much once labels credited all genuinely-relevant sessions; the big lifts in the original eval were an artifact of leaked queries and single-positive labels.
