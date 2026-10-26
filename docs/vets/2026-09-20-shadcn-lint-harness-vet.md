# Harness vet: `shadcn-ui/lint` (`@shadcn/lint`)

**Date:** 2026-09-20
**Candidate:** https://github.com/shadcn-ui/lint @ `44604c49c1d38ef78c0aef5bbfbd9a44bd9ef623`
(tag `@shadcn/lint@0.1.3`), npm `@shadcn/lint@0.1.3`, MIT, author shadcn.
**Self-description:** "A programmable agent-first linter for Tailwind design systems."
**Shape:** pnpm monorepo, 317 files, ~20.8k LOC TS. `packages/lint` (the published
ESLint/Oxlint plugin, six rules) + `packages/evals` (private agent-behaviour eval harness).
**Targets vetted:** (1) global harness scope `~/.claude`; (2) the members app monorepo
(`acme-org/announce-bot`, live checkout `/home/user/SITES/acme-app`).
Three other fleet shadcn repos triaged only, not deep-vetted.
**Landing depth:** report-only. Nothing was installed; no target repo was modified.
**Run choices:** targets inferred from the operator's ask ("does it belong in our shadcn
projects like the members app monorepo"); the members app named explicitly, harness scope implied by
`/harness-vet`. Sweep covered all six rules, the eval harness, docs, supply chain, and both
incumbents.

---

> ## CORRECTION, 2026-09-20 (same day, during implementation)
>
> **The "32 findings" figure below is wrong. The real number is 3,203.**
>
> Every probe in this document was run with the plugin half-blind. `@shadcn/lint`
> discovers the design system from `components.json`, and the members app's lives at
> `packages/ui/components.json` — **not an ancestor of any app file** — so discovery
> from inside `apps/*` found nothing. The rules still fired on wrapper components whose
> `className` forwarding can be traced (`FormLabel` → `Label`), which is why the survey
> returned a plausible-looking 32. A direct `import { Button } from '@kit/ui/button'`
> restyle was **invisible to every measurement in section 2**.
>
> The fix is `settings.shadcn.ui = '@kit/ui'`, the documented substitute for
> `components.json` discovery. With it, measured on the same tree:
>
> | `allow` set | findings | dirty apps |
> | --- | --- | --- |
> | `['layout']` (upstream default, what section 2 used) | **3,203** | 6/9 |
> | `layout + spacing` | 2,259 | 6/9 |
> | `layout + spacing + typography` | 1,297 | 5/9 |
>
> **What this changes:** the ADOPT verdict stands, but "costs almost nothing" does not.
> Adoption is per-app and staged — enabled in three apps
> (clean under `allow: ['layout']`), staged in the other six. Landed in
> a members-app change with its own tracking issue.
>
> **What caught it:** the work spec's *planted negative*, not review and not a green CI run.
> All nine apps passed `--max-warnings 0` while the gate was inert. This is the
> "a gate that stopped gating" failure mode, and the only reason it surfaced is that the
> spec required planting a violation that *must* fail. Section 2's methodology is otherwise
> sound; its blind spot was assuming a green probe meant a working probe.

## 1. Headline

**The members app: ADOPT two rules, SKIP four.** `no-restyle` and `require-static-classes` cover a
capability the members app demonstrably lacks. ~~cost almost nothing to turn on
(**32 findings in 8 files across all 6,662 app-layer files; `require-static-classes` = 0**)~~
— see the correction above: the real volume is **3,203**, so adoption is staged per-app
rather than repo-wide.
The other four rules duplicate a *required, merge-blocking* CI ratchet the members app already runs,
and would add thousands of findings under a `--max-warnings 0` gate.

**Global harness: SKIP the artifact, REJECT the setup path, EXTRACT two ideas.** It is an npm
lint dependency of a project, not a harness artifact. Its `SETUP.md` onboarding tells an agent
to fetch and act on unpinned `main` content — the same shape rejected in today's `react-doctor`
vet.

---

## 2. Measured, not inferred

Runtime: Node v24.12.0, pnpm 10.28.2, ESLint 9.39.5, WSL2. All candidate execution happened in
a scratch sandbox with a fresh `HOME` (`/tmp/vet-shadcn-lint-0920/sandbox-home`). Every members app
measurement was **read-only against the live checkout** — no files copied into it, nothing
written, no `node_modules` touched.

### Build and test, at the released tag

| Step | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | exit 0, 546 packages |
| `pnpm run build` | exit 0, `dist` 229.83 kB (5 files) |
| `pnpm run typecheck` | exit 0 |
| `pnpm --filter @shadcn/lint test` (run 1) | **exit 1** — 739 passed, 1 failed, 1 skipped (60 files) |
| full-suite rerun | exit 0 — 740 passed, 1 skipped |

The single failure is **a flaky test, not a product defect**. `test/project-cache.test.ts`
→ "an unresolved stylesheet is retried after its alias is configured" failed **5 of 6 isolated
runs** and passed on full-suite rerun. Cause: `src/project/fs.ts:10` sets `TTL = 1000` and the
memo compares against a **mocked** `Date.now()`, while `mtimeOf` reads a **real**
`statSync().mtimeMs`; the test advances the mocked clock by 1500 ms
(`test/project-cache.test.ts:184`). Mocked-clock/real-mtime mismatch.

Why it still matters: `package.json`'s `release` script is
`typecheck && test && corpus:check && changeset publish`, so **the release gate itself is
flaky**. Not disqualifying; a maintenance signal.

### The decisive measurement: the built plugin against real members app source

Built `dist/index.js` was run via ESLint against the live checkout, one rule per pass, with
project discovery left entirely to the plugin (**zero configuration** — it found
`components.json`, tsconfig aliases and the per-app `@theme` CSS on its own).
Counts below exclude probe artifacts (the members app's own `eslint-disable` comments referencing
rules absent from my config).

| Rule | `packages/ui/src/shadcn` (152 files) | `apps/acme-web/app` (1,500) | `packages/ui/src/makerkit` (55) |
| --- | --- | --- | --- |
| `no-restyle` | 115 | 17 | 87 |
| `require-static-classes` | 4 | 0 | 5 |
| `no-unknown-classes` | 87 | 247 | 5 |
| `no-raw-colors` | 329 | 759 | 41 |
| `no-inline-styles` | 445 | 146 | 24 |
| `no-arbitrary-values` | 475 | 258 | 58 |

**Repo-wide, the two uncovered rules:**

| Scope | files linted | `no-restyle` | `require-static-classes` |
| --- | --- | --- | --- |
| `apps/` (all 9 apps) | 6,662 | **32** (8 files) | **0** |
| `packages/` | 1,260 | 202 (25 files) | 9 (7 files) |

Per-app `no-restyle`: app A 17, app B 12, app C 3, and **0 for the three gated apps
and apps D, E and F**.
Top offenders: an app B component preview file (9) and two app A admin dialog files
(8 and 6).

### Autofix safety — the property that matters most under `pnpm lint:fix`

**Zero autofixes across all 3,198 probe findings.** Every remediation is an ESLint
*suggestion* (editor-only), never an auto-applied `fix`. Confirmed independently in source:
no rule declares `meta.fixable`; `no-arbitrary-values.ts:128-129`, `no-raw-colors.ts:159-160`
and `no-unknown-classes.ts:38-39` declare `hasSuggestions: true` only. `eslint --fix` **cannot**
silently rewrite rendered UI. Decisive, because the members app has a `lint:fix` script.

### Opt-in by construction

`plugin.ts:15-18` exports `{ meta, rules }` with **no `configs` key**; `index.ts:1-2` carries the
comment "There is no preset". Installing the plugin changes nothing until a rule is switched on.
That makes a staged rollout genuinely safe.

### Guard-bypass probe (21 attempts)

Against the candidate's own eval fixture, all rules on:

- **13 of 13 same-file evasions caught**, including cases I initially mis-scored as evaded:
  `{...SPREAD}` and `className={INDIRECT}` for module-level constants are reported **at the
  declaration site** with full component attribution. It traces values back to their source.
- Documented limits behave exactly as documented, with a second layer: an **imported** class
  string escapes `no-restyle`, but `require-static-classes` fires — "I can't read this" becomes
  a finding rather than a pass. Parent-selector restyling with a *palette* colour still trips
  `no-raw-colors`.
- **Two confirmed silent bypasses** (zero findings from all five rules), both verified in
  isolation:
  1. `<div className="[&_button]:bg-destructive [&_button]:text-xs">` — parent-selector
     restyling using **valid theme tokens**. Documented at `docs/how-it-works.md:235-240`.
  2. `<Button {...IMPORTED_OBJECT} />` — a props object imported from another module. Slightly
     *worse* than documented: the docs claim `require-static-classes` reports unreadable class
     values it can identify; here nothing fired.

Control check: `<Button className="bg-primary" />` **is** flagged — a valid theme token is still
a restyle on a component that owns its colour.

### Supply chain — clean, and better than expected

- `@shadcn/lint@0.1.3` and its one runtime dep `cn@0.2.6` are **both published via GitHub Actions
  OIDC trusted publishing with SLSA provenance attestations**
  (`dist.attestations.provenance.predicateType = https://slsa.dev/provenance/v1`).
  `release.yml:20` sets `id-token: write`, line 50 sets `NPM_CONFIG_PROVENANCE: "true"`.
- The **published manifest carries no lifecycle scripts** (only `test`/`build`/`typecheck`).
  `prepack`/`postpack` run on the publisher's machine. `npm pack --dry-run`: **8 files, 63.3 kB**
  (LICENSE, README.md, 5 × dist, package.json). **Nothing executes on consumer install.**
- `cn` is **not a typosquat**: `github.com/shadcn-ui/cn`, sole maintainer `shadcn`,
  zero dependencies. The name is a takeover of a package dormant since **2013**
  (`rumpl/cn`, a Chuck Norris jokes CLI); the repository URL changed at 0.2.0. Benign, but worth
  recording since a name-reuse looks identical to a hijack in registry metadata.
- **Execution surface:** exactly one `node:worker_threads` Worker (`tailwind/client.ts:87`).
  No `child_process`, no `eval`, no `new Function`. **No network calls at lint time** — the only
  `https://` strings are rule-doc metadata URLs.
- **One caveat:** `tailwind/oracle.ts:277-286` dynamically `import()`s the project's Tailwind
  `@plugin`/`@config` module to answer class-validity questions. The members app's
  `apps/acme-web/styles/globals.css` has `@plugin '@tailwindcss/typography'`, so this **would**
  execute — code already in the members app's dependency tree, but it is real execution during lint.

### Fragilities worth pinning against

- **No `tailwindcss` dependency or peerDependency at all**, yet the oracle requires Tailwind v4's
  internal `__unstable__loadDesignSystem` (`oracle.ts:104-106`). A Tailwind minor bump can break
  it with no package-manager constraint to catch it.
- **Silent oracle degradation:** `tailwind/client.ts:61-71` — after two transport failures the
  oracle degrades permanently for the rest of the run and reports via `console.warn`, *not* as an
  ESLint violation. Under `--max-warnings 0` a degraded run looks identical to a clean one.
  Relevant to `no-unknown-classes` only; both rules recommended below are AST-only and unaffected.

### Cost

Timed over `apps/` (6,662 files), same machine, two runs each:

| Config | run 1 | run 2 |
| --- | --- | --- |
| parser only, no plugin (baseline) | 28,708 ms | 29,659 ms |
| **proposed two rules** | 31,688 ms | 33,100 ms |
| all six rules | 34,421 ms | — |

**Added cost of the proposed set: ~3.0–3.4 s (~11%) on a full app-layer lint.** On a realistic
`--affected` PR slice (app B): 948 ms → 1,106 ms, **+158 ms**.

### Candidate's own claims, fact-checked

- **Oxlint support is real**, not marketing: `test/oxlint.test.ts` spawns the actual `oxlint`
  binary through a real `.oxlintrc.json` `jsPlugins` entry — run live, **7/7 pass**. Irrelevant to
  The members app, which has no oxlint.
- **No Tailwind v3 claim exists** (README.md:13 scopes to v4). No quotable numeric performance
  claim exists to check.
- **Agent-eval numbers are NOT independently checkable** from the clone: `packages/evals/results/`
  is gitignored, and reproduction needs a signed-in `claude`/`codex` CLI making real paid calls
  ($2–$9 per paired run). Treat the per-model tables as vendor-reported.
- **Corpus numbers ARE reproducible with zero paid calls** and were reproduced exactly:
  `check-corpus.mjs` against the pinned ref `63c1308d` of `shadcn-ui/ui` (485 files) yields
  **602 findings, 534 of them `no-restyle`**. Independent evidence that `no-restyle` is the
  rule carrying the signal — on shadcn's *own* registry.
- **Eval methodology, honestly mixed:** the B-arm is a genuine hidden-lint, equal-round-budget
  placebo (`run.mjs:90-129`, `MAX_ROUNDS = 3`) and honest controls exist (8 `neutral.json` tasks
  with no styling language vs 8 `temptation.json` tasks), with mean/min/max across repeats. But
  the **visual-fidelity judge is unblinded** — `fidelity.mjs` labels the inputs verbatim
  `BEFORE (no lint)` / `AFTER (lint-enforced)`.

### Incomplete / not done

- No live agent A/B was run (would need paid `claude`/`codex` calls). The EXTRACT below is
  therefore marked **unverified-value**, with its deciding measurement named.
- Only `packages/ui` and `apps/**` were probed; three other package groups
  were covered only by the aggregate `packages/` row.
- the members app's checkout was 1 commit behind `origin/main` (`0034f4a2` vs `5bd1404a`) at probe time.
- No lockfile-resolution check of `@typescript-eslint/parser` against the candidate's `>=8.40.0`
  floor.

---

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
| --- | --- | --- | --- | --- | --- | --- |
| `no-restyle` | the members app | **ADOPT** | `apps/*/eslint.config.mjs` (or one shared block scoped to `apps/**`) | `["error", { allow: ["layout"] }]` | probe: 32 findings / 8 files / 6,662 linted | proposed, not installed |
| `require-static-classes` | the members app | **ADOPT** | same | `"error"` | probe: **0** findings in `apps/` | proposed, not installed |
| `no-restyle` + `require-static-classes` | the members app `packages/ui` | **ADAPT** (stage later) | `packages/ui/eslint.config.mjs` | off at first; enable after clearing 202 + 9 | probe, per-scope table | deferred |
| `no-raw-colors` | the members app | **SKIP** — covered | no installation | — | design-drift `palette`/`color` budgets, required check | — |
| `no-arbitrary-values` | the members app | **SKIP** — covered | no installation | — | design-drift `arbitrary` budget 1264 | — |
| `no-inline-styles` | the members app | **SKIP** — cost | no installation | — | 445 findings in `packages/ui/src/shadcn`, mostly legitimate three.js/gsap/motion `transform`/`stroke` | — |
| `no-unknown-classes` | the members app | **SKIP pending config** | no installation | — | 247 findings / 168 distinct `editorial-*` classes outside the theme graph | — |
| Plugin as a whole | global `~/.claude` | **SKIP** | no installation | — | it is a project npm dependency, not a harness artifact | — |
| `SETUP.md` onboarding | global `~/.claude` | **REJECT as packaged** | no installation | — | README.md:29-30, SETUP.md:7-9,20-23 | — |
| `packages/evals` harness | global `~/.claude` | **SKIP** | no installation | — | needs paid CLI calls; copies `~/.codex/auth.json` to a temp dir per call | — |
| Eval *methodology* (hidden-oracle placebo arm) | global `~/.claude` | **EXTRACT** | doctrine note only | — | `run.mjs:90-129` | unverified-value |
| Diagnostic-message doctrine | global `~/.claude` | **EXTRACT** | doctrine note only | — | `no-restyle.ts:31-33,46-62` | unverified-value |

**Rollup — the members app:** 2 ADOPT, 1 ADAPT (deferred), 4 SKIP.
**Rollup — global harness:** 3 SKIP, 1 REJECT, 2 EXTRACT (both unverified-value).

### Why `no-restyle` is not already covered

The members app runs a **required, merge-blocking** `🎨 Design Drift` check — confirmed live via
`gh api repos/acme-org/announce-bot/rulesets/18286188` (ruleset `require-ci`), not just from
`AGENTS.md`. It is a ratchet over four budgets (`palette` 3134, `color` ~1225, `arbitrary` 1264,
`orphan` 25), running the SHA-pinned `design-rails` engine.

It cannot cover this capability, for three independent reasons:

1. **It is a regex line scanner with no AST/JSX awareness** — provably incapable of representing
   "component restyled at its call site" or "dynamically built class string" as categories.
2. **It explicitly excludes `packages/ui/src/shadcn/**`** from enforced totals (`design-drift.yml:8-9`).
3. **It is a ratchet, not a block** — a new violation merges by bumping a budget with a `--reason`.

The workflow's own budget-raise comments say things like *"no existing screen was **restyled**
and no colour literal was added"* — i.e. restyling is reasoned about **in prose by reviewers**
and never mechanically gated. `no-restyle` fills exactly that hole, and the 32/6,662 figure means
it can be switched on at `error` essentially for free.

The in-house ESLint plugin's rules concern `console.*` and Supabase typing — **zero** design rules.

### Why `SETUP.md` is REJECT-as-packaged

`README.md:29-30` tells an agent: *"Read https://github.com/shadcn-ui/lint/blob/main/SETUP.md
and set up @shadcn/lint in this project"*, and `SETUP.md:7-9` chains to
`.../blob/main/README.md#get-started`. Both track `main` — a moving target — and `SETUP.md` and
`docs/` are **not** in the npm tarball, so the fetch is not optional.

This is the same shape rejected hours earlier in
`docs/vets/2026-09-20-react-doctor-harness-vet.md`, and it contradicts the standing rule that
fetched content is data, not instructions. **Correction to an over-strong framing:** the README
*is* shipped in the tarball (a `prepack.mjs` step copies it and rewrites links), so a local
fallback for the config snippets does exist — only `SETUP.md` and `docs/` are absent.

**Use instead:** install the plugin and write the config by hand from the shipped README. The
plugin is fine; its onboarding channel is the defect.

---

## 4. Proposed change (NOT applied — the members app was not modified)

Rationale, exact config, and rollback, for the operator to accept or decline:

```js
// apps/<app>/eslint.config.mjs — appended, preserving existing config
import { plugin as shadcn } from '@shadcn/lint';

export default [
  ...existing,
  {
    files: ['**/*.{ts,tsx}'],
    plugins: { shadcn },
    rules: {
      'shadcn/no-restyle': ['error', { allow: ['layout'] }],
      'shadcn/require-static-classes': 'error',
    },
  },
];
```

- **Dependency:** `@shadcn/lint@0.1.3` as a `devDependency`. **Pin exactly** — no caret. The
  package is six days old (first publish 2026-09-14; 0.1.2 and 0.1.3 both shipped 2026-09-20,
  27 minutes apart).
- **Placement:** per-app configs, or one block scoped to `apps/**`. **Do not** register it in
  `tooling/eslint/base.js` — that applies to every app *and* package and would immediately pull in
  the 202 `packages/` findings under `--max-warnings 0`.
- **Prerequisite:** clear the 32 findings in 8 files in the same PR, or the `--max-warnings 0`
  gate goes red on merge.
- **Parser:** the members app already configures `@typescript-eslint/parser`; no new parser setup needed.
- **Update owner / review trigger:** re-review on any `@shadcn/lint` minor bump, on a Tailwind v4
  minor bump (the `__unstable__loadDesignSystem` dependency), or if `packages/ui` ownership of
  `src/shadcn` changes.
- **Rollback:** delete the rules block and the devDependency. No codemod, no migration, no
  generated artefacts — and since nothing is `fixable`, no source was ever auto-rewritten.

### Triage rows (not deep-vetted)

Probed with the same built plugin; all three confirmed Tailwind v4 with real `@theme`.

| Repo | Tailwind | `no-restyle` | `no-raw-colors` | files linted |
| --- | --- | --- | --- | --- |
| `better-ccflare/packages/dashboard-web` | 4.2.2 | **440** (65 files) | 297 | 237 |
| `acme-evals/apps/cockpit` | 4.3.2 | 250 (16 files) | 174 | 847 |
| `acme-health/packages/ui` | catalog → v4 | 141 (21 files) | 26 | 99 |

Note the contrast: **the members app's app layer is 32 findings across 6,662 files; ccflare's dashboard is
440 across 237.** the members app is by far the most disciplined repo in the fleet on this axis — which is
*why* adoption there is cheap, and why the others would need real cleanup first.
`acme-health` has 0 CSS files with `@theme`, so its numbers are lower-confidence.

---

## 5. Audit dividend

1. **My own digest was wrong and the readers caught it.** I recorded "no DESIGN.md in the members app"
   from a `find -maxdepth 3`. The members app actually has **11 `DESIGN.md` files** plus a `design/README.md`
   router. Depth-limited `find` is not an inventory.
2. **`packages/ui/src/shadcn` is the least-checked code in the repo.** The 152-file library
   that all 10 apps import is (a) excluded from design-drift's enforced totals and (b) has
   9 ESLint rules switched off wholesale in `packages/ui/eslint.config.mjs:5-18`, a block
   scoped precisely to `files: ['src/shadcn/**/*.{ts,tsx}']`. **Today's independent
   `react-doctor` vet reached the same gap from a different direction** (on a 16-planted-defect
   fixture: stock Next config caught 5, that config caught 2). Two vets converging on one blind
   spot is the strongest signal in this document, and it is about the members app, not about either
   candidate.

   *Corrected 2026-09-20, from the react.doctor session:* this originally said "triply exempt"
   and cited `tooling/eslint/base.js:473-474` as a third correctness exemption. That carve-out
   list governs **`max-file-lines`** — the god-file cleanup ratchet — not any lint rule. The
   accurate count is **two correctness-relevant exemptions plus one file-size one**. Also worth
   keeping straight: `packages/ui/eslint.config.mjs` is two blocks with different scopes — lines
   5-18 disable 9 rules for `src/shadcn/**` specifically, lines 19-32 disable 3 more package-wide.
   The concentration is in `src/shadcn`, which is 152 of the package's 217 files.
3. **`design-rails` pin drift.** The global harness skill vendors `design-rails @ 46a8a1e`
   (v0.12.1); the members app CI pins `7bca61c3` (v0.12.0). Different commits of the same engine, not shown
   to be synchronised — a fix in one does not reach the other.
4. **168 distinct `editorial-*` classes sit outside the discovered theme graph.** Not a bug:
   `app/(editorial)/editorial.css` is imported *from TSX* (`editorial-shell.tsx:6`), not from the
   CSS `@import` chain, so no Tailwind-aware tool can see it. Any future CSS tooling in that
   subtree will mis-read it the same way, and a small `@import` into the theme graph would fix it
   once for all of them.
5. **A vet that only measures findings cannot tell a clean codebase from a blind tool.** This is
   the biggest lesson here and it is about the *protocol*, not the members app. Every measurement in
   section 2 was internally consistent, reproducible, cross-checked against a second reader's
   file counts, and wrong — because a tool reporting 32 findings and a tool that cannot see
   two-thirds of the component surface produce the same kind of output: a number. Nothing in
   the phase-4 repertoire as written would have caught it. The planted negative did, because it
   is the only check that asserts a *positive* — "this must be reported" — rather than counting
   what happens to come back.

   Worth adding to the vet protocol: when a candidate's value depends on it *recognising*
   something (components, symbols, routes, call sites), plant a known-positive and confirm it is
   reported, before trusting any count. A low finding count is exactly what both "clean" and
   "broken" look like. The existing "no silent caps" instinct covers truncation; this covers
   silent under-recognition, which reads as good news instead of a gap.

---

## 5b-updated. Where the backlog stands now (2026-09-21)

> The decomposition below is preserved as written, but **its headline numbers are
> superseded**. Three changes landed after it: `Badge` gained a `size` variant and shed
> 92 redundant overrides (a members-app change), and a `contracts` entry scoped `no-restyle` away
> from spacing on container slots (a members-app change, −566).
>
> **Current: 2,382 no-restyle findings** (was 3,173). Superseded again by 5c below:
> as of 2026-09-21 the gate is on in all 9 apps and this backlog is frozen, not blocking.
>
> | family | count | | top component | count |
> | --- | --- | --- | --- | --- |
> | colour | 926 | | `Button` | 395 |
> | typography | 840 | | `TableCell` | 259 |
> | spacing | 374 | | `Badge` | 224 |
> | shape | 200 | | `CardTitle` | 209 |
> | other | 175 | | `GlowText` | 158 |
>
> Two findings from doing the work that the original section did not anticipate:
>
> 1. **The "restating a base class" win does not generalise.** `Badge` was 96/320 that
>    way, which looked like a pattern; measured across every component it is only ~100 of
>    3,081. Do not plan a campaign around it. (The first measurement said 22 because the
>    extractor only read `cva('base')` and was blind to every component using a plain
>    `cn('…', className)` — which is most of the big ones. A number produced by a filter
>    that silently matches nothing looks exactly like a real result.)
> 2. **The largest category was never drift.** 679 findings were spacing/layout on
>    container slots — `space-y-4` on `<CardContent>` alone was 149. `CardContent`'s base
>    is `p-6 pt-0`, padding *around* children; `space-y-4` spaces the children, which is
>    the consumer's composition. The `contracts` fix removed 566 of those while leaving
>    colour findings **unchanged at 831** — that zero delta is the evidence it sharpened
>    the gate rather than weakening it.
>
> **Next, and both are design decisions rather than mechanics:** give `Badge` a `gap-1`
> base (upstream shadcn does; ~28 findings, but icon+text badges gain spacing), and give
> `CardTitle` size/weight variants (209 findings, nearly all typography). Doing both puts
> app F — now at 7 — within reach of being the 4th gated app.

## 5b. Backlog decomposition (added 2026-09-20, after adoption)

The corrected 3,203 figure is a scary number that hides a tractable one. Measured across all
9 apps with the shipped `allow: ['layout']` config, `no-restyle` findings split three ways —
the discriminator is the rule's own message text, which either lists real variants
("Use a variant: default, destructive, …") or says the component has none to offer
("Add a variant in <file> only if …"):

| | findings | share |
| --- | --- | --- |
| component **has** variants to use | 658 | 20.7% |
| component has **no** variants (styling primitive) | 1,563 | 49.3% |
| spacing/ownership advice | 952 | 30.0% |
| **total** | **3,173** | |

**549 of the 658 genuine-drift findings are two components: `Button` (285) and `Badge` (264).**
That is the actual design-system drift in this repo. It is a campaign with a shape, not a wall.

The 1,563 are the rule flagging `TableCell` (232), `CardTitle` (183), `GlowText` (158),
`Label` (132), `Card` (122), `Input` (71), `Textarea` (71) — components with no variant to
offer, where call-site styling is ordinary composition. A significant slice of those are
vendored magicui/aceternity primitives (`GlowText`, `MagicCard`, `TypingAnimation`,
`AnimatedSpan`) that live under `packages/ui/src/shadcn/**` and are *meant* to be styled
per-use. A `contracts` entry could reclassify them and roughly halve the reported backlog,
but that is a policy call about what each component owns and should be made deliberately.

Per-app: app C 1,465 · app A 1,006 · app B 623 · app D 40 ·
app E 28 · app F 11 · three other apps 0 (gated).

**Why the three smallest apps were not gated** (investigated and declined, a members-app change
closed unmerged): none is a cleanup. App F's 11 are mostly `Badge` internal
padding (`px-1.5`, `py-0`) — removing them changes rendered size, so the honest fix is a
`Badge` size variant, which would also serve a large share of the 264 Badge findings and
therefore deserves to be designed rather than improvised. Apps D and E
restyle `Accordion`, `Terminal` and `MagicCard` for the funnels dark
theme on revenue pages, with no visual verification available to prove appearance is
preserved.

*Consumer and deletion condition for this section:* it exists to be read by whoever onboards
the next app to the gate, so that they start from "549 findings on two components" rather
than re-deriving 3,203. Delete it once all 9 apps are gated, or once a `contracts` policy
supersedes the classification.

## 5c. The backlog is measuring a missing API, not debt (2026-09-21)

Section 5b classified findings by the rule's own **message text** — whether it offered
real variants or said there were none. Measuring the same question from the opposite
direction, against the **component sources**, corroborates it and produces the number
that actually decides strategy:

> **10 of 472 components in `packages/ui` expose a variant API.**
> `Alert`, `Badge`, `Button`, `CardTitle`, `CopyButton`, `Label`, `MultiSelect`,
> `RainbowButton`, `SheetContent`, `SidebarMenuButton`. That is the whole list.

Method: for each `.tsx` under `packages/ui/src`, find `const <name> = cva(…)` declarations
carrying a `variants:` block, then check whether each component's own body composes one.
Two traps, both of which silently deflate the count:

1. Splitting a file into component spans on any `const X =` truncates a component at its
   first inner declaration. `const Comp = asChild ? Slot.Root : 'button'` inside `Button`
   moved `buttonVariants(` out of `Button`'s span and into `Comp`'s, so the scan reported
   `Comp` as the component with variants and **missed `Button` entirely**. Anchor
   declarations at column 0.
2. `const Button: React.FC<ButtonProps> = ({` does not match `const (\w+) =`. The type
   annotation sits between the name and the `=`.

Against the 2,382 `no-restyle` findings in the six then-ungated apps:

| what the fix actually is | count | share |
| --- | --- | --- |
| component **has** a variant API | 769 | 32.3% |
| spacing → move to parent (no variant involved) | 239 | 10.0% |
| component has **no variant API at all** | 1,374 | **57.7%** |

**The conclusion that matters:** for 57.7% of findings the rule's advice ("use one of its
variants") cannot be followed, because there is nothing to use. Those findings are not
debt. They are the rule reporting, once per className, that this repo has no variant
layer. Clearing them means inventing variant APIs on `TableCell` (241), `FormItem` (38),
`ScrollArea` (22), `Skeleton` (16) — structural elements that own no visual identity.

So a plan of "clear an app's findings, then gate it" never terminates, and it is exactly
the plan the vet had been executing app by app.

### What replaced it: freeze, then gate

ESLint 9.39.1 — already the version in the repo — has bulk suppressions built in.
Snapshot the findings into a per-app `eslint-suppressions.json`, turn the rules on
everywhere, and let the backlog shrink independently. Shipped as a members-app change: 3 gated
apps → **9**, 2,387 findings frozen, no new dependency and no new CI script.

The counts ratchet monotonically downward in **both** directions, which is the property
that makes this a gate rather than a budget:

- add a violation → the file's count is exceeded → **exit 1**
- remove one → an unused suppression is left behind → **exit 2**

That second exit looks like a footgun and is the load-bearing part: it is why CI must
**not** pass `--pass-on-unpruned-suppressions`. Without it, fixing a violation leaves
slack inside the file that a future violation can occupy silently. `pnpm lint:prune` is
the remedy, and ESLint's own error message names it.

Verified before adopting, not assumed: generate → exit 0; add one class → exit 1 naming
it; revert → exit 0; delete the suppressions file → exit 2 (fails closed); edit a count
down with a **warm `--cache`** and untouched source → exit 1, so the ESLint cache does not
hide suppressions changes.

**Known limit, recorded rather than papered over:** suppression is counted per file per
rule, so fixing one violation and adding another in the same file, same rule, same commit
nets zero and passes.

### Contracts vs suppressions

The two must not blur or the suppressions file becomes design-drift's budget-bump ratchet
in a new costume. One question decides it — **is this fine forever?** Yes → a `contracts`
entry (reviewed once, applies everywhere). No, we just have not got to it → a suppression
(per file, prunable, expected only to shrink).

`require-static-classes` is the worked example: 28 of its 33 findings were in app B's
component preview gallery, which already carried a nine-rule carve-out and a
`max-file-lines` exemption on the stated grounds that it is not production code. Computed
class strings are what a gallery *does*, so the rule joined that existing block — a
contract. The other 5 are real app code and were frozen — debt.

### The one the rule gets wrong

`acme-web-funnels`' 38 findings looked like House of Vibe **brand application**, not drift.
`--color-hov: #39ff14` is a declared token (`src/styles/globals.css:151`) and
`design/brands.json` maps `primary → --color-hov`. `no-restyle` encodes "one design system
owns this component"; this repo deliberately runs N brands over shared primitives. A variant
on shared `Accordion` is certainly wrong — that would push one brand's identity into a
package all 10 apps import.

> **Corrected by 5d.** This section originally concluded "the fix is an app-local brand
> wrapper applying the classes once". Measurement did not support it: **16 of the 38 were
> in files nothing renders**, and for the 22 that remain a wrapper relocates the restyle
> rather than removing it. See 5d.

*Consumer and deletion condition:* read by whoever next plans work against this backlog,
so they do not restart the burn-down-then-gate plan that 5c exists to close. Delete once
a variant layer exists for the components that warrant one, or once the suppressions files
are empty.

## 5d. What the follow-up work measured (2026-09-21)

5c proposed freeze-then-gate and it shipped (a members-app change). Working the frozen backlog down
produced three corrections to how the mechanism was described, and one live bug.

### The funnels 38 were not what 5c said

| file | findings | referenced by |
|---|---:|---|
| `FaqSection.tsx` | 22 | `src/pages/index.astro:1336` |
| `TerminalCta.tsx` | 11 | **nothing** |
| `TerminalShowcase.tsx` | 5 | **nothing** |

The two dead files had no import, no `import.meta.glob`, no `.astro` reference, no barrel;
the only file in the monorepo naming them was the suppressions file generated by a members-app change.
Deleted in a members-app change (`astro check`: 118 files, 0 errors), taking the repo to 2,371.

No brand-wrapper layer was built for the remaining 22, and the reason generalises. The
plugin *does* resolve local wrappers — `resolveDeclared` marks one **transparent** if it
destructures `className`/`...props` and forwards it, **opaque** otherwise — so an opaque
`HovAccordionItem` would take the call site to zero. But **there is no exemption for a file
that is itself a design system**: `settings.shadcn.ui` is only an import-prefix list, which
is exactly why `packages/ui` needs its own `files:` carve-out. The restyle therefore moves
into the wrapper file, which needs either a carve-out (an exact-count ratchet traded for an
unbounded exemption) or the same suppressions. With one consumer that is indirection, not
enforcement. Build it when a second House of Vibe accordion appears.

### Two holes in the ratchet, not one

5c recorded that fixing one violation and adding another in the same file/rule/commit nets
zero. A second hole is larger and was found by tripping over it:

- **Deleting a file leaves its suppression entry behind and nothing fails.**
  Unused-suppression detection only evaluates files ESLint actually lints, so a deleted
  file's entry is never checked. Expected exit 2, **observed exit 0**. The ratchet covers
  in-file fixes, not whole-file deletion — prune explicitly after any deletion.

And a usability fact worth knowing before reading a red CI log:

- **One new violation un-suppresses the whole file/rule.** Planting a single `bg-pink-500`
  in a file holding 22 suppressed findings reported **23** errors, not 1. The new one is
  there and correctly named, but the failure is as loud as the file's entire backlog. An
  argument for keeping suppressed files small.

### The variant-API triage, and its honest yield

Of 2,382 `no-restyle` findings, **911 are on the 10 components that expose a cva variant
API**. Classified against each component's real base + `defaultVariants`:

| bucket | n |
|---|---:|
| class already applied by the component's defaults | 122 |
| class matches a non-default variant value | 144 |
| no variant value produces it | 645 |

The middle bucket is mostly **not** a mechanical edit, because adopting a variant value
applies its *whole* class set: `Button text-xs → size="sm"` (42 sites) also swaps
`h-9 px-4 py-2` for `h-8 rounded-md px-3`. Only 19 of the 144 are side-effect-free.

Only the `Label` slice converted cleanly — **89 findings across 75 sites**, shipped as
a members-app change, taking the repo to 2,282. That is the realistic yield of the whole
variant-API story: about 4% of the backlog, not a third.

### "It is in the base, so deleting it is a no-op" is unsound

The conversion was accepted per site only when

```
twMerge(variants(propsBefore), classNameBefore) === twMerge(variants(propsAfter), classNameAfter)
```

as a class set. That check rejected one site, and the reason is a live defect rather than
an edge case: `labelVariants` declares `leading-none` in its **base** and appends the size
variant's `text-sm` **after** it, and tailwind-merge treats a text-size class as also
setting line-height —

```
twMerge("leading-none text-sm")  ===  "text-sm"
```

so `Label`'s base `leading-none` is stripped on every render and has been since the size
variant was added. The only Labels getting it are the call sites that respell it. Deleting
those as "redundant" is a silent visual regression. Filed as a members-app change; not fixed,
because either repair changes line-height on every `Label` in the monorepo.

The general lesson: whenever an earlier class in a `cva` base is in a tailwind-merge
conflict group with a later variant class, the base class is dead and the class-membership
heuristic is wrong. Only a per-site merge comparison catches it — **and the comparison
must be paired with an inverted-proof suite**, since a check that cannot fail is not
evidence. Here it rejected all 5 deliberately wrong edits and accepted all 4 correct ones.

*Consumer and deletion condition:* read by whoever next works the frozen backlog down, so
they do not re-derive the ratchet's holes by tripping over them or ship the unsound
"redundant class" heuristic. Delete once the suppressions files are empty, or once
`@shadcn/lint` gains a first-class notion of an app-local brand layer.

## 6. Re-audit triggers

**`Do-not-retry unless:`** (the four SKIPped rules, the members app)
- design-drift's ratchet is retired, or its `packages/ui/src/shadcn` exclusion is removed; or
- `packages/ui`'s 202 `no-restyle` / 9 `require-static-classes` findings are cleared, making the
  `packages/ui` ADAPT row actionable; or
- the `editorial.css` import is added to the theme graph (reopens `no-unknown-classes` at a much
  lower finding count); or
- the members app gains a `warn` tier distinct from `error` (today `--max-warnings 0` makes them identical).

**`Do-not-retry unless:`** (`SETUP.md`, global)
- upstream version-pins the setup instructions or ships them inside the npm package.
  The REJECT is of the **onboarding channel**, not the plugin, and does not block the members app ADOPT.

**ADOPT review trigger:** any `@shadcn/lint` minor bump, any Tailwind v4 minor bump, or a change in
`packages/ui`'s ownership of `src/shadcn`.

**Artefact findings that travel to any future target:** OIDC + SLSA provenance on both packages;
no consumer install-time scripts; no `fixable` rules; no lint-time network; worker-thread
`import()` of project Tailwind plugins; no `tailwindcss` peer constraint; silent oracle
degradation after two transport failures.
