# design-rails: extract the design-loop engine into an OSS plugin

Supersedes the 2026-08-07 draft of this plan (then named "design-ratchet" — G1 has
since been DECIDED by the owner: **design-rails**, npm-verified available, chosen as
"guardrails that keep AI agents on YOUR design"). The product also grew between
drafts; this revision reflects what actually exists.

## What ships (all built, deployed, and dogfooded as of 2026-08-08)

One engine, five verbs, already live in the private harness:

- `posture` — five pass/fail checks per app (exists-at-scope / valid / wired /
  followed / enforced), workspace-aware, root-blend = failure.
- `scan` — drift measurement (six detectors, per-detector CI budgets) plus the
  declared-token reader (theme files by content, oklch, dark-mode systems, one-hop
  alias/reference resolution).
- `propose` — authors a Google-spec DESIGN.md + DTCG tokens from the app's own
  declarations and shipped literals; refuses monorepo blends.
- `decide` — renders open taste decisions as visual HTML pages; records the human's
  choice back into the review record.
- `--tighten` — the one-way ratchet as a command; refuses to absorb increases.

## Evidence base (goes in the README, verbatim claims only)

- 4/4 public-repo validation: derived systems agree with each repo's own declared
  tokens (taxonomy, cal.com, excalidraw, outline — each verified per-role).
- Controlled 3v3 adherence experiment: wired DESIGN.md prevented 100% of the
  violation-copying that occurred in 2 of 3 control runs, with generators citing
  the file's ban verbatim as their reason.
- Full production loop on the flagship monorepo: per-app systems derived and
  committed, three owner decisions rendered → decided → recorded, first migration
  (29 chart call sites), CI budgets tightened four times, one theme flip shipped to
  production behind the wiring.
- Measured against the field: Buoy 26% coverage on the same repo; the one
  codebase-first "competitor" listing was a prompt with no executable code.

## Will-owned gates

- **G1 — DONE: design-rails** (2026-08-08).
- **G2 — public flip + v0.1.0 tag** at the pinned SHA (runbook freshly exercised by
  skill-tuner's promotion).

## Decisions (carried from the first draft, still holding)

- D1 canonical home = the new repo; D2 dotfiles consumes via frozen-snapshot +
  overlay; D3 prbot switches vendored file → pinned npx after G2; D4 fresh curated
  history; D6 issue #261's remainder (region budgets) migrates upstream as v0.2.
- D5 revised: **posture is the front door** (`npx design-rails posture .`), not the
  scanner — the five-check table is the product's face; scan/propose/decide/tighten
  are what its failing rows prescribe.

## Repo layout (v0.1.0)

```
design-rails/
  bin/design-rails            # dispatcher: posture | scan | propose | decide | tighten
  src/{scan,propose,decide,posture}.mjs   # engine, dependency-free
  test/                       # 79 tests, mutation-check notes preserved
  skills/design-rails/SKILL.md            # generic Claude Code skill
  .claude-plugin/plugin.json
  docs/validation.md          # the evidence base above, with method
  docs/upstream-limits.md     # @google/design.md v0.4.0 traps, dated
  PROVENANCE.md · LICENSE (MIT) · NOTICE (plugin87 MIT ideas, impeccable
  Apache-2.0 method, design-system-ops MIT method)
  .github/workflows/ci.yml    # hosted runners
```

## Phases

- **P1 — scaffold (repo created PRIVATE, in progress).** Curated import from
  dotfiles @ current main; private-identifier sweep (the engine comments accreted
  fresh app/brand specifics during the dogfood sprints — sweep list: the
  private app, brand and repository names); README leads
  with posture and the evidence; CI green; designmd-lint smoke pinned @0.4.0.
- **P2 — consumption switch (dotfiles).** Vendor-drop + overlay split; live
  behaviour byte-identical.
- **P3 — G2 flip + v0.1.0** (Will), flip evidence recorded per house precedent.
- **P4 — marketplace + prbot.** `chore: promote design-rails v0.1.0`; prbot CI to
  pinned npx; #261 remainder migrates upstream.
- **Release gate (new since draft 1): the house's own QA.** Before promotion,
  design-rails' SKILL.md passes a skill-tuner eval run — the marketplace's
  authoring-quality bar applied to its own next listing.

## Planted negatives (unchanged in force)

- P1 importing git history instead of a curated snapshot leaks private context.
- P2 changing engine bytes during the split — the switch is provenance-only.
- A marketplace entry before G2 cannot go green; don't burn the promotion commit.

## No-Claim Boundary

- Availability ≠ adoption; the validation evidence is dated and decays with the
  alpha spec; greenfield authoring is explicitly out of scope (registries and
  Stitch own that lane).
