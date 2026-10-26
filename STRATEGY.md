---
name: hov-stack
last_updated: 2026-10-20
---

# hov-stack Strategy

## Purpose

Builders want their Claude Code setup to work like a perfected, opinionated system the moment they drop it in. A setup only gets there through thousands of hard-earned decisions, optimizations and tweaks made day in and day out over years, and nobody gets to skip that work today.

## Positioning

hov-stack ships only what its author runs every day across several businesses, proven by the work that came out of it, so a fresh install carries those decisions already made. The selectivity (fewer skills, loaded on explicit invoke) and the guard layer that lets agents run unattended are what survived that use, not features picked for a list.

## Users

**Primary:** The Claude Code power user - already running Claude Code daily on their own projects. They're hiring hov-stack to replace a home-grown setup with one that has the thousands of decisions already made, so their agents run unattended.

**Secondary:** The House of Vibe builder - not an engineer, reached through HoV workshops and the guided setup. They're hiring hov-stack to ship their business without learning the harness.

## Boundaries

- A contributed skill the author does not run is considered and heavily processed, and merged only once he runs it himself.
- No softer edition or builder mode. One stack; a builder who wants pushes to main edits their own settings.

_Resist a change when:_ it puts something in the stack its author does not run, or loosens the stack for one audience.

## Key metrics

- **Stars and forks** - on the public repo; the viral signal. GitHub.
- **Cloners versus viewers** - unique cloners per week against unique viewers; whether readers become installers. GitHub traffic insights.
- **Outside issues and PRs** - opened by people who are not the author; strangers are running the stack. The repo.
- **Plugin installs** - members' machines pulling plugin updates through the hov marketplace. Not counted today: the release train announces releases and counts nothing. Needs a counter.
- **Author PRs merged per 60 days** - across the author's repos; the receipt the README leads with, and the one that regresses if the stack gets worse for him. GitHub search.

## Tracks

### The stack

The rules, guards, permission lists and selective skills the author runs daily, curated one by one.

_Why it serves the approach:_ it is the thing whose decisions are being handed over; every line in it is one he runs.

### Drop-in

The public repo shape, the deterministic `./setup` with dcg by default, the guided in-session setup, and the flip to `StartupBros-com/hov-stack` (decisions in `docs/decisions/2026-10-20-hovstack-architecture.md`).

_Why it serves the approach:_ decisions nobody can install are not handed over; this track is the minute between clone and a working setup.

### The plugin train

The twelve tools folded in as `plugins/<name>/`, the announce chain rewritten first behind its gates, the `hov` marketplace, and the skills as one plugin for people who will not clone.

_Why it serves the approach:_ the tools are part of what he runs, and the train is how a member's machine gets each update the day it ships.

### Receipts

The data that proves the stack is better, the README in the author's voice, and the origin story that links House of Vibe.

_Why it serves the approach:_ the positioning is a proof claim; without the receipts it is an adjective.
