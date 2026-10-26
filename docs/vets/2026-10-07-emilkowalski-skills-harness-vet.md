# Harness vet: emilkowalski/skills round 3 (`break-ui`, `mobile-native`, `ask-sonner`, `write-swift`, the X post)

- Date: 2026-10-07. Skill: harness-vet. Landing: PR for review (dotfiles #1678). Nothing vendored. Four installed snapshots receive EXTRACT lines, one installed snapshot loses a branded block, the fixture and this note land beside them. No setting, hook or permission changed. Deploy stays the usual `skills-localize.sh apply` after merge.
- Operator ask: "let's /harness-vet https://x.com/emilkowalski/status/2106752670405099523 https://github.com/emilkowalski/skills/tree/main/skills (we already use some of their skills) https://github.com/emilkowalski/skills/tree/main/skills/break-ui".
- Prior rounds: round 1 (PR #125, 2026-07-22, pin `f6f79ca1`) vendored eight skills; round 2 (PR #162, 2026-08-05, pin `de33dbed`) SKIPPED `animation-vocabulary`. Neither has a note in `docs/vets/` (the directory starts 2026-09-11); their verdicts live in the PR bodies and were reused as leads, not as fit verdicts.

## Verdict in one screen

**No new skill is vendored. `break-ui` and `mobile-native` land as EXTRACT lines inside skills already installed; `ask-sonner` and `write-swift` are SKIP; the eight installed copies stay frozen, with `emil-design-eng`'s "Initial Response" block stripped; the `npx skills` install route is REJECT; the X post is evidence, not a component.**

1. **`break-ui` vs the installed `/break` (global): EXTRACT.** The planted-defect fixture (§2) tied three ways at n=2: bare, `break-ui` and `/break` each found 10.5 of 11 latent defects on average, with the same single accusation (a control that turned out to be a real defect) and comparable valid extras. The candidate did not beat the bare model or what is installed, so there is no detection evidence for vendoring a second break skill. Its two scenario axes that `/break` lacks, Time and Images and media, are ported into `skills-local/break/scenarios.md` with an unverified-value marker: on this fixture the bare arm found the time and media defects without them.
2. **`mobile-native` (global, the members app): EXTRACT.** Half of its topics are already in installed invoke-only skills (sticky hover, `touch-action: manipulation`, 16px inputs, safe-area padding, scroll-snap, press feedback, dialog overscroll, never-disable-zoom: K1-K9). Of the 14 platform claims checked, 3 are confirmed, 10 partial and 1 refuted (`interactive-widget=resizes-content` makes Chrome for Android differ from iOS, not match it), and one rule conflicts with installed doctrine (blanket `user-select: none` on buttons, tabs and chips against `better-typography` L131). The verified gaps go into the skills that own them: `viewport-fit=cover` and `100dvh`/`100svh` into `better-layout`; `touch-action: pan-x`/`pan-y`, the `transparent` tap highlight with its `:active` pairing, and root `overscroll-behavior: none` into `better-accessibility`. No behavioral test ran for this skill, so the ported lines carry unverified-value markers in each UPSTREAM.md.
3. **`ask-sonner` (global, the members app): SKIP.** Six of its API facts are wrong against both sonner 2.0.7 (installed in the members app) and 2.0.8 (npm latest): the offset default is 24px not 32px, `toast.getActiveToasts()` is not exported (the public names are `getToasts` and `getHistory`), `hotkey` is a string array, `toastOptions` is an 11-key subset, `containerAriaLabel` is a Toaster prop, and ids are string or number. Nothing becomes true in a newer release. Reference is covered by context7 and the bundled `index.d.ts`; `/pick-ui-library` already routes toasts to Sonner. Its three troubleshooting rows that are right (two Toasters duplicate, `sonner/dist/styles.css`, theme default `light`) are recorded in §6 rather than vendored. One real members app defect fell out of checking them (§6, dividend 6).
4. **`write-swift` (omlx): SKIP.** Its central premise is stale: Swift 6.4 shipped on 2026-09-15 and the skill says it has not. It also presents macOS-26-only APIs (`InlineArray`, `.span` producers, `OutputSpan`, `MainActorMessage`) as plain Swift 6.2 features, mislabels two versions, and tells every project to enable Approachable Concurrency. omlx is a Swift 6.0 language-mode project targeting macOS 15 with 29 XCTest files, 0 Swift Testing files and no concurrency flags, so the skill describes a migration, not the project. No Swift toolchain exists on this host; nothing compiled.
5. **The eight installed copies: no re-pull.** They are frozen by design. The one reconciliation is `emil-design-eng`, which round 1 vendored with the upstream "Initial Response" block and the animations.dev course link intact. A live probe on `break-ui`'s copy of the same block shape returned only the branded line and nothing else, so the block is stripped (UPSTREAM.md logs it).
6. **Triaged only, not deep-vetted: `animate-expo`, `animation-vocabulary`, `performance-cheatsheet`: SKIP.** No Expo or React Native project exists under `~/SITES`; `animation-vocabulary`'s round-2 trigger is still unmet; the cheatsheet's three net-new rows (virtualize, `ref.current.style`, `will-change`) are recorded in the triggers.
7. **Delivery: `npx skills add emilkowalski/skills`: REJECT. `git clone` plus cherry-pick into `skills-local/` (the existing route): keep.** The npx route installs an unpinned HEAD of a repo where 11 of 14 skills are model-invocable and every SKILL.md carries the "respond only with" block.
8. **The X post: evidence only.** It announces `/mobile-native` and `/break-ui` and, in the thread, the author tells a customer the course skills "are more specific to a given task and have more nuances"; the public repo is the author-acknowledged lighter tier. No component to verdict.

## 1. Source identity, targets, run choices

| Item | Identity |
|---|---|
| X post | https://x.com/emilkowalski/status/2106752670405099523 (2026-10-04, 157k impressions at intake). Thread fetched in full; the author's "use the course skills if you have them" reply is the one verdict-shaping line. |
| Repo | https://github.com/emilkowalski/skills at `e8a175de22ae1e49370fc144c1f3bb9aeedf988d` (2026-10-02), MIT, 44,079 stars, 55 commits since 2026-03-16, single author plus two external PRs merged of 14; 11 of 12 issues closed, median 2.3 days. Full clone in scratch at `/tmp/hv-emil-2026-10-07/repo`. 14 skills; a stray empty `.pl` file. |
| npm `skills` 1.7.1 (the `npx skills` installer) | No install scripts; dependencies `tar` and `yaml`; maintainers rauchg and quuu. Delivery verdict in §3. |
| Install state | Eight frozen snapshots in `skills-local/` (animate, apple-design, emil-design-eng, find-animation-opportunities, improve-animations, pick-ui-library, prototype, review-animations), each with UPSTREAM.md pinned to `f6f79ca1` or `de33dbed`, `disable-model-invocation: true` and `agents/openai.yaml`. Deployed copies under `~/.claude/skills/` are byte-identical to skills-local (skills-localize). Only `emil-design-eng` carried the "Initial Response" block (`grep -l 'respond only with'` across both trees matched one file). |
| Prior verdict search | `docs/vets/` (13 notes, none for this source), live memory index and archive tier, `harness/`, PR #125 and #162 bodies, dotfiles issues. Round-1 and round-2 verdicts reused as leads. |

**Targets.**
- **T1:** the global harness (`~/.claude/skills` via `skills-local/`, Codex through `agents/openai.yaml`). Task: a UI-polish or break-testing pass on a React component, invoked by name.
- **T2:** the members app (`acme-org/announce-bot`; sonner 2.0.7 at 68 import sites across 7 packages; a web app with mobile surfaces). Task: a toast integration or a mobile layout fix.
- **T3:** omlx (Swift macOS app, 125 Swift files, last commit 2026-09-03). Task: a Swift change that respects the project's language mode and deployment target.
- No Expo or React Native project exists under `~/SITES`, so `animate-expo` has no target.

**Run choices.**
- This is one repo bundling 14 components, a multi-component candidate, not a list. The operator-named `break-ui` was read in full and behaviorally tested. `mobile-native`, `ask-sonner` and `write-swift` were read in full and fact-checked but got no fixture; `animate-expo`, `animation-vocabulary` and `performance-cheatsheet` were triaged only. The eight installed copies were diffed against their pins by the repo-level reader.
- Six readers (triage, repo-level, ask-sonner, break-ui, write-swift, mobile-native) carried the frozen digest; all six returned, none a stub. Five verifiers batched by subsystem (mobile-native platform claims M1-M14, ask-sonner API S1-S12, write-swift versions W1-W12, break-ui platform facts B1-B12, installed-coverage control surfaces K1-K20), each with REFUTED as the default. Two judges scored the fixture.
- Landing depth: PR for review, in `docs/vets/` as established. Scope inferred from the ask and the install state; the operator was not live.

## 2. Measured, not inferred

**Isolation and the skill-loading fact.**
- Smoke: `claude -p --bare --settings <env-only file> --model sonnet --tools "" --output-format json` in an empty `CLAUDE_CONFIG_DIR` answered `pong` in one turn on `claude-sonnet-5-5`.
- `claude -p --bare "/break-ui"` with the candidate under `<CLAUDE_CONFIG_DIR>/skills/` loaded nothing: 73 input tokens and "doesn't match any command". The same prompt without `--bare`, with `settings.json` copied into the scratch config dir and `--setting-sources user`, loaded it (7,135 cache-write tokens) and the reply was exactly the branded line, nothing else, one turn. That is the live confirmation of the "Initial Response" block's effect, and the reason the fixture inlines skill text instead of invoking it.

**Fixture** (`harness/vet-fixtures/emilkowalski-break-ui/`, README has the per-run table).
- Component: a React members list with 11 planted latent defects (single-word-name crash in `initials()`, flex text column with no `min-width: 0`, "1 open tasks", avatar with no fallback, `word-break: break-all` on URLs, a 96px invite button, a 20px count pill, "0 days ago", no empty state, an unguarded "+N" team chip, a bio cut mid-glyph) and 11 honest controls. Judge-only answer key with a 10-point dataset rubric and a plausibility flag.
- Arms: bare; `break-ui` (SKILL.md plus CATALOG.md inlined); `/break` (SKILL.md, scenarios.md, plus `better-typography` and `better-layout`, the two skills it hands breaks to). Prompts 9,814, 32,621 and 37,776 bytes. `grep -c 'answer-key'` printed 0 for all three. Two runs per arm, sonnet, `--bare`, `--tools ""`, own `CLAUDE_CONFIG_DIR` per run; six runs, all exit 0, empty stderr, `num_turns` 1 each; cost $0.14 to $0.22 per run.
- Judges: two `lean-reader` sonnet agents, prompts never shown. Full agreement on every detection and accusation count; one dataset disagreement settled by eye (break-1 does contain an emoji-first name, so 10 not 9).

| Arm | Detection, mean of two runs (of 11) | False accusations as keyed | After C2 reclassified | Dataset (of 10) | Plausibility | Valid unkeyed extras per run |
|---|---|---|---|---|---|---|
| bare | 10.5 | 1 | 0 | 10 | 1 FAIL, 1 PASS | 6 to 7 |
| `break-ui` | 10.5 | 1 | 0 | 9 | 2 PASS | 7 to 8 |
| `/break` | 10.5 | 1 | 0 | 10 | 2 PASS | 8 to 9 |

- All six runs accused the same "control": the header picks the English nouns "member"/"members" by the viewer's locale plural category, so fr-FR shows "0 member" and ru-RU "21 member". That is a real defect the key had mis-filed as a control; the key carries a dated correction (C2 reclassified as D12) and the component is unchanged so the runs stay reproducible. The one-team and two-team demo rows also render the "+-N" chip as shipped, so that defect was visible to every arm.
- Neither skill arm declined; every run labelled its findings inferred. The expected "`/break` refuses predicted failures headless" confound did not occur.
- Reading: headless, no-tools sonnet saturates this key regardless of skill. The fixture measured no detection gain for `break-ui` over bare or `/break`; it does not show that either skill adds nothing, only that this key cannot separate them. Both skill arms produced plausible long values where bare once used repeated characters, the one measured difference in the skills' favour.

**Verifier tallies** (REFUTED by default; CONFIRMED needs file:line or command output).

| Batch | Confirmed | Partial | Refuted | Verdict-shaping items |
|---|---|---|---|---|
| `break-ui` B1-B12 | 5 | 6 | 1 | B8 "~30% longer" French translation is 144% longer by the file's own string; B5 recommends unprefixed `line-clamp` with no fallback; B9 offers `title` for truncated text against MDN; B4 `overflow-wrap: anywhere` counts toward min-content (MDN), `break-word` does not |
| `ask-sonner` S1-S12 | 7 | 3 | 6 | S1-S5 and S7 wrong against 2.0.7 `dist/index.mjs` and `index.d.ts` and against 2.0.8 (npm latest, fetched and diffed: only `customAriaLabel` added) |
| `write-swift` W1-W12 | 2 | 8 | 2 | W1 and W9: Swift 6.4 released 2026-09-15 per swift.org; W5 and W8: macOS 26 availability hidden; W7: raw identifiers are 6.2 not 6.0; W12: omlx `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, 29 XCTest files, 0 Swift Testing |
| `mobile-native` M1-M14 | 3 | 10 | 1 | M7 refuted (Chrome docs: `resizes-content` resizes the layout viewport; Safari resizes only the visual viewport and ignores the key); M5 iOS root-bounce half unverified; M8 Safari 26 ignores `theme-color` for tinting (secondary sources); M14 stylus rationale wrong per Media Queries 4 |
| installed coverage K1-K20 | 14 | 4 | 2 | K10 `user-select: none` conflict; K11 `overflow-wrap` divergence; K16 the cited typography lines say nothing about diacritic clipping; K17 `scenarios.md` has no Time or Images axis |

**Limits of the evidence.** n=2 per arm, one model, no browser, no tools. No Swift toolchain, no Xcode and no iOS device on this host: W3's "Xcode 26 builds macOS 15" and the M3, M5, M6, M8 device behaviours rest on secondary sources. MDN's compat tables render client-side, so B3's Firefox version and B5's unprefixed `line-clamp` rows were not read from the primary source. The coverage verifier had no shell; its counts are Grep-tool counts with a positive control. The sonner facts were read from dist source and types, not run.

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| `break-ui` (SKILL.md, CATALOG.md) | T1 global | EXTRACT | Time and Images and media axes in `skills-local/break/scenarios.md` | invoke-only via `/break`, unchanged | fixture tie (§2); K17 confirmed the axes absent; B1-B12 | landed in this PR; value unverified, marker in `break/UPSTREAM.md` |
| `break-ui` | T2 members app | same as T1 (global skill) | as above | as above | as above | as above |
| `mobile-native` | T1 global, T2 members app | EXTRACT | one paragraph in `better-layout/spacing-and-adaptivity.md`; three bullets in `better-accessibility/hit-areas.md` | invoke-only via those skills, unchanged | M1-M14; K1-K10; no fixture | landed; value unverified, markers in both UPSTREAM.md files |
| `ask-sonner` (SKILL.md, API.md) | T1 global | SKIP | none | none | S1-S5, S7 refuted; K19 `/pick-ui-library` already names Sonner | no install |
| `ask-sonner` | T2 members app | SKIP | none | none | same; S12a one real defect (§6) | no install; the members app issue filed (§6) |
| `write-swift` | T3 omlx | SKIP | none | none | W1, W9 refuted; W5, W8 availability; W12 project settings | no install |
| `write-swift` | T1 global | SKIP | none | none | no Swift task recorded for any other target; no toolchain to test | no install |
| `animate-expo` | all | SKIP (triaged, not deep-vetted) | none | none | no Expo or React Native project under `~/SITES` | no install |
| `animation-vocabulary` | T1 | SKIP (triaged; round-2 trigger unmet) | none | none | round 2 PR #162 | no install |
| `performance-cheatsheet` | T1 | SKIP (triaged, not deep-vetted) | none | none | K18: 4 of 7 rows already in `animate`/`emil-design-eng`; virtualize, `ref.current.style`, `will-change` absent | no install |
| eight installed copies, upstream deltas since `f6f79ca1`/`de33dbed` | T1 | SKIP re-pull; reconcile `emil-design-eng` | strip SKILL.md L9-L15 | invoke-only, unchanged | B12 and the live probe | landed |
| delivery: `npx skills add` / skills.sh | all | REJECT | none | none | unpinned HEAD; 11 of 14 model-invocable; "respond only with" block in all 14 | no install |
| delivery: clone and cherry-pick into `skills-local/` | T1 | keep (existing route) | `skills-local/<name>/` with LICENSE, UPSTREAM.md, `disable-model-invocation: true`, `agents/openai.yaml` | invoke-only | rounds 1 to 3 | in use |
| X post | none | evidence only | none | none | thread fetched | none |

**Rollups.** T1 global: 0 ADOPT, 0 ADAPT, 2 EXTRACT, 8 SKIP, 1 REJECT (delivery), 1 reconciliation. T2 members app: 2 EXTRACT (via the global skills), 1 SKIP, 1 dividend issue. T3 omlx: 1 SKIP.

**Price (phase 5), one line.** Nothing vendored and no tool added, so no tool-count measurement. The EXTRACT lines live inside invoke-only skills and cost nothing per prompt; the whole emilkowalski bundle stays off the model-invocable surface; supply chain is markdown only; delivery route unchanged.

## 4. Changes in this PR

| File | Change | Provenance and pin | Rollback |
|---|---|---|---|
| `skills-local/break/scenarios.md` L60-L87 | Time axis and Images and media axis, paraphrased in the file's cue/table/lands-in idiom | emilkowalski/skills `skills/break-ui/CATALOG.md` L88-L111 at `e8a175de…`; logged in `break/UPSTREAM.md` with the unverified-value marker | revert the hunk; the UPSTREAM.md line names it |
| `skills-local/better-typography/SKILL.md` L69, `wrapping-and-punctuation.md` L22, `css-cheat-sheet.md` L45 | `overflow-wrap: anywhere` added beside `break-word` for shrinking flex and grid children; `break-word` stays the default | B4 (MDN overflow-wrap) and K11; Tailwind `wrap-anywhere` per tailwindcss.com; logged in `better-typography/UPSTREAM.md` | revert the three hunks |
| `skills-local/better-layout/spacing-and-adaptivity.md` L117 | `viewport-fit=cover` prerequisite for `env()` insets; `100dvh`/`100svh` over `100vh` | `mobile-native/SKILL.md` L88-L98, L169-L187; M2, M3 (WebKit, web.dev); logged in `better-layout/UPSTREAM.md` | revert the hunk |
| `skills-local/better-accessibility/hit-areas.md` L91-L93 | `pan-x`/`pan-y` semantics; `transparent` tap highlight with `:active`; root `overscroll-behavior: none` for Android pull-to-refresh, iOS half marked unverified | `mobile-native/SKILL.md` L78-L84, L146-L165, L205-L221; M4, M5, M10 (MDN); K3, K6, K8; logged in `better-accessibility/UPSTREAM.md` | revert the hunk |
| `skills-local/emil-design-eng/SKILL.md` L9-L15 | "Initial Response" block and course link removed | B12 and the live probe; logged in `emil-design-eng/UPSTREAM.md` | restore from `f6f79ca1` |
| `harness/vet-fixtures/emilkowalski-break-ui/` | component, stylesheet, judge-only key with dated corrections, runner, parser, README with results | this vet | delete the directory |
| this note; live memory notes | pointer and the `--bare` skill-loading fact | this vet | delete |

Update owner: whoever next re-pulls a jakubkrehel or emilkowalski snapshot re-diffs these hunks; the UPSTREAM.md lines are the diff guide. Deploy: `skills-localize.sh apply` from the canonical checkout after merge, as for every skills-local change. `codex-skills.txt` untouched.

**Deviations from the issue's acceptance criteria, on evidence.**
- The memory pointer goes into live memory (`~/.claude/projects/-home-user-hov-stack/memory/`), not `memory/-home-user-hov-stack/MEMORY.md`: a PR that touches `memory/**` collides with the canonical checkout's uncommitted mirror copies and blocks dotup activation for every later merge (memory note `memory-mirror-pr-merge-blocks-dotup-activation`, 2026-09-23; durable fix tracked in #1343). The memory-push flow mirrors live memory on its own schedule.
- The planted negative "`test_skill_frontmatter.py` must fail on a vendored skill missing `disable-model-invocation: true`" cannot pass as written: the test checks YAML parse, name, description, directory match and provenance, not that key, and two of the 28 LICENSE-bearing snapshots (`firecrawl-research-index`, `google-safe-browsing`) lack it today. Adding the assertion would turn the suite red on files this PR does not own. Recorded as dividend 8 for a separate decision. The scratch-tree run that demonstrates the gap is in §6.

## 5. Shared artifact findings vs target-specific fit

Shared (true at `e8a175de` whatever the target): the "Initial Response" block in all 14 SKILL.md files and its live effect; the six `ask-sonner` API errors; the stale Swift 6.4 premise and the macOS-26 availability gaps; the `mobile-native` refuted and partial claims; the `break-ui` numeric error (B8) and the three patch-worthy rows (B5, B9, B12); the npx route's unpinned HEAD.

Target-specific: `break-ui`'s fixture tie is a T1 finding about detection on a React component; `ask-sonner`'s members app facts (S12a-c); `write-swift`'s omlx settings (W12); `mobile-native`'s overlap map against the installed invoke-only skills (K1-K10), which is a T1 fact that also serves T2 because the skills are global.

Prior notes reused: round 1 and round 2 PR bodies for the install state and the `animation-vocabulary` trigger; the jakubkrehel vet (2026-09-01, #816/#817) for the `/break` incumbent's posture and the skills-local conventions. Applicability change: `/break` was adopted as "no incumbent"; it now has a competitor, and the fixture here is the first paired measurement either has had. Searched and empty: `docs/vets/` for this source. Unavailable: none.

## 6. Audit dividend and triggers

**Dividend.**

1. **`claude -p --bare` loads no skills.** Even with `CLAUDE_CONFIG_DIR` pointing at a dir holding `skills/<name>/SKILL.md`, a `/name` prompt under `--bare` reaches the model as plain text (73 input tokens). A skill probe needs the non-bare form with a scratch `CLAUDE_CONFIG_DIR`, a `settings.json` inside it and `--setting-sources user`. Memory note written. Fixture arms that inline skill text are unaffected.
2. **Round 1 shipped `emil-design-eng` with the "respond only with" gag and a course link, and it was live for 77 days.** Anyone who typed `/emil-design-eng` with no question got one branded sentence. Fixed here. The check is `grep -l 'respond only with' skills-local/*/SKILL.md` (empty after this PR; the phrase survives only in `emil-design-eng/UPSTREAM.md`'s changelog line); it belongs in the vendoring pass for every future snapshot from this author.
3. **The fixture's "control" C2 was a real defect, and every arm caught it.** Selecting English nouns by a foreign locale's plural category is a bug; the key author (this session) mis-filed it. Corrected with a dated note. Lesson for the next key: a control must be verified against at least one non-English locale before it is called honest.
4. **The fixture saturates under headless sonnet.** 10 to 11 of 11 for every arm at n=2. The next planted-defect key for a UI skill needs defects that only a rendered layout shows, or rule interactions, before it can rank skills. A rendering arm (the `/break` posture) is the obvious next instrument.
5. **`better-typography` and `break-ui` disagreed on `overflow-wrap`, and MDN sides with the candidate for flex and grid children.** Reconciled additively (§4). `better-typography` also has no line on diacritic clipping although `/break` tests for it (K16); not patched, recorded.
6. **A members-app story page mounts two Toasters.** The root provider and the story each render one, so every toast on that page renders twice. A members-app issue records the static finding and the browser check still needed. A separate app uses a light Toaster without a theme prop; it has dark tokens but no theme toggle, so light is currently correct. The story says the default is `system`; the runtime default is `light`.
7. **No installed mobile-web doctrine auto-fires.** Every covering rule (K1-K10) lives in an invoke-only skill, and the cross-references between them only help once one is invoked. A mobile layout task on the members app gets none of it unless someone types a skill name. Not changed here; it is the always-on budget decision the skill audit made, recorded so the next mobile incident can point at it.
8. **The frontmatter test does not enforce the invoke-only posture, and two licensed snapshots lack it.** `firecrawl-research-index` and `google-safe-browsing` carry a LICENSE but no `disable-model-invocation: true`; 27 house-authored skills-local skills lack it too, by design or by omission. A scoped assertion (LICENSE present implies the key) is one line in `test_third_party_snapshots_record_provenance`, but it needs a decision on those two first. Scratch-tree demonstration: copying the test and one snapshot to a scratch tree, deleting the key and running the test passes today (§4 deviation).
9. **Verified facts worth keeping even though their skills are SKIP.** Swift 6.4 shipped 2026-09-15 (Xcode 27); `InlineArray`, `OutputSpan`, `.span` producers and `MainActorMessage` need macOS 26; `anyAppleOS` minimum is 26.0 and `withTaskCancellationShield` is 27.0. Sonner's offset default is 24px, `theme` default `light`, `getToasts`/`getHistory` are the public read calls, `onDismiss` also fires on `toast.dismiss()`.

**Do-not-retry unless (scope-bound).**

- `break-ui` → ADOPT/ADAPT at T1: a fixture with a rendering arm, or a key with defects a headless arm misses, shows `break-ui` finding defects `/break` plus the bare model do not at n≥3; or `/break` is removed from skills-local.
- `mobile-native` → ADAPT at T1 or T2: a members app repository mobile task is recorded as failing with the four extracted lines in place and succeeding with the skill, and upstream (or a local patch) resolves the `user-select: none` conflict (L31, L189-L201), M7 (L278), M14 (L70), M8 (L223-L233) and M5 (L148).
- `ask-sonner` → ADAPT at T2: upstream corrects S1 (24px), S2 (`getToasts`/`getHistory`), S3 (`string[]`), S4 (the 11-key `ToastOptions`), S5 (Toaster prop) and S7 (`string | number`), and a members app repository sonner task is recorded as failing with context7 plus `index.d.ts` available.
- `write-swift` → ADAPT at T3: omlx moves to the Swift 6.4 toolchain (Xcode 27) and a macOS 26 deployment target, and upstream fixes W1, W5, W7, W8 and W9 with availability annotations.
- `performance-cheatsheet` → EXTRACT: a measured jank task where virtualization, `ref.current.style` or `will-change` is the fix and `animate` does not name it.
- `animate-expo` → re-vet: an Expo or React Native project appears under `~/SITES`.
- `animation-vocabulary` → re-vet: the round-2 trigger (a recorded need for shared motion vocabulary across contributors) is met.
- npx route → re-vet: the installer pins a commit and the repo ships its skills invoke-only by default.

Re-audit triggers for the landed extracts: a jakubkrehel re-pull of `break`, `better-typography`, `better-layout` or `better-accessibility` (re-diff the hunks named in each UPSTREAM.md); MDN changes the `overflow-wrap` min-content wording; WebKit documents root `overscroll-behavior: none` behaviour (update the iOS caveat).
