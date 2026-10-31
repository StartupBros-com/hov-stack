# Sources and licenses

rent-check is original text synthesizing concepts from the artifacts below,
identified in a 2026-08-10 ecosystem recon (7-arm search sweep + 8-cluster
deep read; every artifact verified by reading its actual files). No text is
reproduced verbatim from any source. Concepts from unlicensed repos are
reimplemented from their ideas only.

## Papers

| Source | License | Taken |
|---|---|---|
| arXiv 2604.11088 "Guardrails Beat Guidance" | CC BY-NC-SA (findings cited, prose not reproduced) | Polarity (Q3), priming (Q4), distortion averaging |
| arXiv 2605.10039 instruction-adherence RCT | CC BY 4.0 | Size/position/conflict nulls, session decay (E3) |
| arXiv 2602.11988 "Evaluating AGENTS.md" (ETH Zurich) | arXiv license | Derivable-content evidence (L2), LLM-generated-file caveat (R5) |
| arXiv 2606.15828 configuration smells (SCAM 2026) | arXiv license | Smell taxonomy + prevalence (R1, R5), folklore caveat |
| arXiv 2603.00822 ContextCov | CC BY 4.0 (code link 404s — flagged) | Enforcement-ladder direction (E2) |
| arXiv 2607.25398 HANDBOOK.md (Surge AI) | CC BY 4.0 | Two-sided grading, self-report distrust (MEASURE.md) |

## First-party

Anthropic: `/doctor` (binary + docs), "New rules of context engineering"
(2026-07-24), "Steering Claude Code" (2026-06-18), memory/rules docs,
claude-md-management plugin (Apache-2.0). Taken: load-class matrix (L1),
derivable-content cut (L2), anti-pattern→mechanism mapping (E1/E2),
deferred-MCP costing (L1).

## Vendor evals

Vercel "AGENTS.md outperforms skills" (docs-index pattern, uninvoked-skill
finding → L6); Augment Code "How to write good AGENTS.md" (size band,
don't-walls → Q5, decision tables → Q7, discovery hierarchy → L4);
philschmid.de (tool-naming effect → Q6).

## Tools and skills (concepts)

| Source | License | Taken |
|---|---|---|
| 0xmariowu/AgentLint | MIT | Evidence-citation-per-check discipline; emphasis-density references (R6) |
| fedius01/ccinspect | MIT | Write-blindness detection (R3), cross-layer precedence framing |
| lumatic2/claude-md-doctor | MIT (archived) | Removal test framing (Q2), 3-way enforcement classification (E1), @import-eager finding |
| kosk-t/harness-audit | MIT | Paper-tiger gates (E4), cost-benefit gate, "considered but rejected" section |
| meetdave3/refine-skill | MIT | Phase gating, before/after re-score idea |
| ralfyishere/rulebench | MIT | Honesty section, NOT-RUN handling, baseline hardness (MEASURE.md) |
| BaconMan1168/optirule | MIT | Git-history task mining, pre-spend gate (MEASURE.md) |
| BenMalaga/claudemd-check | MIT | Transcript-construction rule (MEASURE.md) |
| JeronimoColon/constitution-ablation-harness | MIT | Fisher/Holm/kappa stats, dev/holdout split (MEASURE.md) |
| fernforge/ruleprof | MIT (agent-authored, flagged) | Pre-spend trial floor (MEASURE.md) |
| laurigates/claude-plugins evaluate-context-engineering | MIT | Two-channel separation, quote-or-default judging, counter-finding rule, load-class cost model |
| agent-sh/agnix | MIT/Apache-2.0 | Weak-language/negative-only detector idea (Q1/Q3); eval-against-fixtures pattern |
| ncoevoet/claude-markdown-health-check | MIT | Threshold-drift transparency, paired-guard eval idea |
| 7y-9/agentsmd-check | Apache-2.0 | Lockfile/script cross-checks (R2) |
| Anbeeld/AGENTS.md | MIT | Invariant-floor framing, untrusted-content boundary phrasing direction |
| wan-huiyan/claude-ecosystem-hygiene | MIT | Shadow-config ablation (MEASURE.md), retrieval-gate negative result + layered-ablation trade (EVIDENCE.md) |
| karanb192/claude-code-hooks dead-rules-audit | MIT | Obedience telemetry + promote threshold (E5) |
| crouton-labs/crouton-kit | none — concepts only | Line-admission bar, stale-worse-than-missing, ceiling-not-quota (Q2) |
| Vesely/skills context-audit | none — concepts only | Five-filter screen idea (Q1), /context-grounded budgeting |
| drpalaric/claudit | none — concepts only | Reconciliation discipline (R1/R4), draft-file output discipline, injection-surface check |
| kylesnowschwartz/SimpleClaude sc-claude-md-improver | none — concepts only | Displacement framing (Q2), folklore disclaimer norm |
| trailofbits/claude-code-config | none — concepts only | Weekly rule/hook/command improvement taxonomy |

Also consulted: Chroma "Context Rot" (length-degradation grounding),
writing-for-agents / skill-tuner doctrine (pointer quality L5, no-op
time-relativity Q1) — the local doctrine this skill composes with.
