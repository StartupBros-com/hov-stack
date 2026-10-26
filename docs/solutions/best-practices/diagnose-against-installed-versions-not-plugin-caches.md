---
title: "Diagnose plugin behavior against the installed version and live record provenance, not caches"
date: 2026-08-31
category: best-practices
module: papercut-family-destination-routing
problem_type: best_practice
component: development_workflow
severity: medium
applies_when:
  - "Naming the owner or destination repo for a defect whose evidence involves a plugin, vendored copy, or any versioned tool cache"
  - "A grep over an installation/cache tree found the incriminating instruction or code"
  - "Telemetry keeps producing fresh records and the diagnosis must explain who is producing them NOW"
tags:
  - plugin-cache
  - version-skew
  - provenance
  - misfiled-issue
  - papercut
---

# Diagnose plugin behavior against the installed version and live record provenance, not caches

## Context

While routing a papercut family (optional-config probe noise, 2026-08-31), a
grep over the plugin cache found pro-gate's SKILL.md instructing an
unconditional read of `.compound-engineering/config.local.yaml` — an
optional per-repo file, absent by design almost everywhere, which is why
probing it fails. A dossier was
authored naming pro-gate as the offender and an issue filed
(StartupBros-com/pro-gate#104). Eighteen minutes later the fix branch died on
its anchor: the instruction did not exist at the repo's main — nor in the
*installed* plugin version. The grep had matched a stale cached version
(0.34.0) that no session runs; the live records actually came from a different
plugin entirely (the compound-engineering plugin's skills — re-routed upstream
as EveryInc/compound-engineering-plugin#1593).

Plugin caches retain every version ever installed. A cache-wide grep is a
search over history presented as the present.

## Guidance

Before naming a destination for a defect grounded in plugin/vendored text,
require two proofs, in order:

1. **The installed version carries the text.** Resolve which version is live
   (for Claude Code plugins, the highest version the marketplace pin selects —
   confirm with the pinned entry, not `ls` order) and grep only that tree.
   A cached sibling version proving the point is not evidence; it is a museum
   exhibit.

2. **A fresh record traces to it.** Take the newest 2-3 telemetry records for
   the signature and read their provenance fields (session, cwd, target, tool)
   — do they identify the suspected producer, or merely a directory it also
   touches? In the misfile, fresh records sat in pro-gate *worktrees* because
   CE skills ran there — the cwd implicated the bystander.

Only when both point at the same producer does the dossier get a destination.
The eighteen-minute correction was cheap precisely because the anchor check
failed before wrong code shipped — an exact-anchor patch (`s.count(old) == 1`)
against the live tree is itself a cheap third proof, worth keeping even when
the first two feel conclusive.

## Applicability

This is for routing and blame decisions, not for reading old code on purpose —
archaeology in caches is fine when versioned history is the question. The rule
triggers the moment a conclusion says "X currently does Y" with a cache path in
the evidence chain.
