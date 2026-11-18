# Harness vet: `build-design` from jakubkrehel/skills

**Date:** 2026-11-17
**Ask (operator):** "if there are new skills we should likely vet them one-by-one with
/harness-vet … I bet many of those will be adopted or cherry-picked."
**Tracking:** issue #683 (the second of nine vets there), branch `vet-build-design`.
**Fixture:** `harness/vet-fixtures/build-design-2026-11/`. Its README is the pre-registration,
committed and pushed before any scored run (`7c8c618`, amended in `f8c8d07`, both before the
launch). Synthetic project and designs only.

## Headline

> **Update, later on 2026-11-17: the port landed under option 2.** The operator allowed one
> model-invoked design skill (section 4). The two lines went into a new pack-written entry skill,
> `ui-design`, which shipped in hov-stack 0.3.6 (#730) after its own pre-registered live run in
> `harness/vet-fixtures/ui-design-2026-11/`. In that run's round 1, the first wording around the
> two lines put the billing-page toggle off the theme in 3 of 4 runs. One disclosed revision fixed
> it.
> Results and verdict: `docs/vets/2026-11-17-ui-design-entry.md`. The sections below record this
> vet as measured; dated notes mark where the outcome changed.

- **Verdict: EXTRACT by the pre-registered rule; the port is not landed.** build-design is not
  adopted, and nothing in the pack changes.
  - No pack skill a member would invoke when handing over a design could carry the port, under
    the pack's invoke-only posture.
  - Whether to make an exception is a decision for the operator (section 4).
- **The whole gain is one report item, on builds that bare already gets right.**
  - With build-design, the reply calls the values it read off the image estimates, or states
    the scale it assumed (R2), in 8 of 8 runs.
  - The pack does this in 1 of 8 runs, and bare in 0 of 8.
  - Net of losses, that is +7 report passes against a margin of 3.
  - Every other report cell, and every outcome cell but one, sat at ceiling in every arm. The
    drop rule removed them.
- **Harm test: passed.**
  - No outcome regression, and every countermetric held.
  - The one outcome cell left, D1 on the billing page (t4), went 3 of 4 for build-design
    against 4 of 4 for the pack and bare. One run positioned the toggle knob with a spacing step
    the theme lacks.
  - Median cost was $0.072 a run against the pack's $0.051, and the median billing-page diff
    was smaller (116.5 lines against 136).
- **The contender regressed.** `design-to-code-fidelity` went off-scale on the billing-page
  toggle in 4 of 4 runs, and asked before building in 7 of 12 build runs. So it is not an
  EXTRACT source, and it is skipped for this job.
- **Routing.**
  - The pack's design skills are all slash-only. On a plain "build this design" ask, the pack
    arm loaded no skill in 16 of 16 runs.
  - Upstream build-design is model-invocable. Asked in plain words, it loaded on the
    billing-page task in 4 of 4 runs and on an unrelated typo fix in 0 of 4.
  - Its estimate wording survived in all four of those runs, but one of them labelled the
    planted gap and seat bar "Matches", and a second is arguable (exploratory, read by hand).
- **What this rests on.** Synthetic designs, one model (`claude-sonnet-5-5`), four runs per
  cell, and no arm able to render its build.

## 1. Source, target and run choices

- **Source.** [`jakubkrehel/skills`](https://github.com/jakubkrehel/skills) at
  `6c2120103600407a1a9986afd834e73144ef8998`, path `skills/build-design`, MIT. The path last
  changed in `1eb03d2` (2026-10-24). Files and sha256:
  - `SKILL.md` `d51cb44f…3a68`
  - `figma.md` `998359b0…8942` (the Figma path)
  - `agents/openai.yaml` `858842fc…f518`

  Upstream leaves it model-invocable (no `disable-model-invocation`).
- **Target.** The hov-stack plugin's skill pack, the default install for HOV members. The pack
  already carries nine of the candidate's siblings from the same upstream (better-accessibility,
  better-colors, better-layout, better-typography, better-ui, better-writing, break,
  explain-interface, interface-review), and build-design defers its domain rules to them. So
  the question is the pack against the pack plus build-design, with bare as the floor.
- **Use case.** A member hands an agent a design (a screenshot, or a Figma link) and wants it
  built inside their existing project with the tokens and components it already has, and told
  plainly where the build could not match.
- **Fixture.** `acme-console`, a synthetic Vite + React + Tailwind v4 repo with a reset token
  scale, so an off-scale class emits no CSS. Four tasks, with planted values the scale cannot
  express (`answer-key.md`):
  - t1, a Team members card into the settings page;
  - t2, a Figma link with no Figma tool;
  - t3, a Delete workspace card where every value maps (the clean control);
  - t4, a whole billing page with missing components and off-scale, off-palette values.
- **Arms.** bare; the pack (`--plugin-dir`); the pack plus build-design, invoked as
  `/hov-stack:build-design <task>`; the pack plus the contender `design-to-code-fidelity`
  (`guillem-cotcha/design-to-code-skills` @ `5548960f32791982a0d353903dc050c4a9368c30`, MIT,
  `SKILL.md` sha256 `864564fd…9f6d`), invoked the same way.
- **Runs.** `claude -p` 2.1.326, model `claude-sonnet-5-5`, `--max-turns 60
  --max-budget-usd 4`. Each run is isolated: an emptied environment; HOME, TMPDIR, the XDG pair
  and `CLAUDE_CONFIG_DIR` inside the run dir; tools `Read,Glob,Grep,Write,Edit,Skill,TodoWrite`
  (no shell, so no arm can render its build). One identical second turn goes to any arm whose
  first turn left the working copy unchanged on a build task.
- **Landing depth.** PR to hov-stack carrying this note and the fixture. A port into the pack
  lands only after its own live run (pre-registered).

**Discovery record** (one discovery agent, three lanes × three sources, then four passes):

| lane | source | outcome |
|---|---|---|
| alternatives | GitHub | lead found: guillem-cotcha/design-to-code-skills, hxx2001/screenshot_to_code_agent-skill, warpdotdev/figma-skills, tomc98/figma-skill and others. `gh search repos` returned nothing for queries of four or more words, so those were re-run with two or three words. |
| alternatives | Web | lead found: Figma's `mcp-server-guide` skills, robukh/figma-suite |
| alternatives | X | an unnamed "design-to-code" skill in a video post, no repo link; not resolved |
| implementation | GitHub | lead found: Figma MCP servers (official, GLips, southleft), tablesleveldesign/design-tokens-mcp |
| implementation | Web | lead found: Figma's MCP tools page |
| implementation | X | posts naming a Figma-aware skill plus Code Connect as the lever; no new repo |
| experience | GitHub | lead found: 731-cyber/claude-figma-pixel-parity; "design to code benchmark" returned nothing |
| experience | Web | write-ups on Figma MCP limits (responsive layouts, unbound tokens, large frames) |
| experience | X | posts that Figma MCP plus Claude still misuses the design system's text styles and tokens |

- **Pass 1** was seeded by "pixel-perfect / fidelity". It admitted skobak/pix and led to full
  reads of 731-cyber and guillem-cotcha.
- **Pass 2** was seeded by Figma's `figma-design-to-code` skill and `create_design_system_rules`
  prompt. It admitted the official skill.
- **Pass 3** was seeded by "DESIGN.md" from the X hits. It admitted google-labs-code/design.md as
  a complement.
- **Pass 4** chased the X-promoted "design-to-code" skill. It admitted nothing.
- **The stop that fired:** the four-pass ceiling. Pass 3 admitted something, so the two-empty-
  passes stop never fired. This is an incomplete search, and it claims no exhaustive coverage.
  Surfaced but not opened: GLips/Figma-Context-MCP, southleft/figma-console-mcp,
  grab/cursor-talk-to-figma-mcp, warpdotdev/figma-skills, tomc98/figma-skill,
  albertogloder/figma-agent-skills.

## 2. Measured, not inferred

**Runs.** 64 scored runs (4 arms × 4 tasks × 4) plus the 8-run invocation probe, launched at
`f8c8d07` on 2026-11-17 from 09:18 to 09:25 UTC.
- 72 of 72 runs finished with status `ok`. None was void, and none stopped at its own turn or
  budget cap.
- The skill-load log (`results/skill-loads.txt`) shows no unresolved slash command, no
  permission refusal and no path outside a run dir in any run.
- All 72 ran on `claude-sonnet-5-5`, and together they cost $4.96. The judges were 12 Sonnet
  subagents at about 80k tokens each.

**Scored cells that were not dropped** (`results/tally.md` has every cell):

| item (task) | bare | pack | pack+build-design | pack+design-to-code-fidelity |
|---|---|---|---|---|
| D1 on-system values (t4) | 4/4 | 4/4 | 3/4 | **0/4** |
| R2 values called estimates (t1) | 0/4 | 0/4 | **4/4** | 3/4 |
| R2 values called estimates (t4) | 0/4 | 1/4 | **4/4** | 3/4 |
| R4 asks for the Figma frame or an export (t2) | 4/4 | 4/4 | 4/4 | 3/4 |

All 23 dropped cells had every arm passing every run:
- G_built, D1 (t1, t3), D2, D3 and D4 on every build task;
- D5, the t1 email colour, with the naming half graded through J5;
- O2, building nothing from a Figma link;
- R1, the badge gap reported;
- R3, no unverified whole-build match claim;
- R5, no false match on a planted value.

| arm | outcome passes (retained) | report passes (retained) | t3 asked and stopped | second turn needed (16 runs) | median added lines t1 / t3 / t4 | median cost |
|---|---|---|---|---|---|---|
| bare | 4/4 | 4/12 | 0/4 | 0 | 37.5 / 8 / 125 | $0.045 |
| pack | 4/4 | 5/12 | 0/4 | 0 | 36 / 8 / 136 | $0.051 |
| pack+build-design | 3/4 | 12/12 | 0/4 | 1 | 35.5 / 8 / 116.5 | $0.072 |
| pack+design-to-code-fidelity | 0/4 | 9/12 | 1/4 | 7 | 39.5 / 9 / 126 | $0.097 |

- **Rules, as pre-registered** (README, "Pre-registered").
  - ADOPT is not met. The outcome margin over the pack is -1 against a required +3, so
    conditions 1 and 2 fail. Conditions 3 to 5 hold.
  - EXTRACT is met: +7 report passes net against a margin of 3, and no outcome regression.
  - The contender is -4 on outcome against the pack, with a D1 (t4) regression (4 fails against
    0). It is +4 on report. The outcome regression rules it out as an EXTRACT source.
- **Judges.** Two Sonnet judges graded blinded packets in batches of about 11, one reading
  forward and one reading backward. They agreed on all 170 graded items, so there was nothing
  to adjudicate.
  - Judge B left r34, the last packet in its order, out of its batch-4 file. The tally refused
    to run, as designed. The same judge, asked again, graded r34 into `judge-b-4b.json`. That
    cell (R3 on t3) is dropped, so it does not touch the verdict.
  - Two Sonnet judges agreeing is not independent evidence, so I re-read the deciding cells
    from the replies themselves:
    - **R2, pack and build-design on t1 and t4.** Every build-design reply states a 2× scale or
      calls its values estimates. The one pack pass is r06 ("the design's toggle is about
      36×20px"). The other seven pack replies name gaps but call no value an estimate.
    - **R5, build-design on t1 and t4.** Every planted value is either named as rounded,
      deviating or a question, or not mentioned. Two runs needed a closer look:
      - r02's "Header to first divider | 24px | `mt-3 pt-3` | Matches, made from two tokens"
        is true. The divider is the list's top border, below 12px of margin and 12px of
        padding, so the build renders 24px from two existing steps.
      - r45 never mentions the header gap, and built it at 16px (`mt-4`). Under the brief,
        saying nothing passes R5.
  - The calibration run's false "Matches" on the billing gap did not recur in any of the 8
    scored runs.
- **The outcome cell.** Both of build-design's off-scale classes on t4 are the 36×20 toggle:
  - scored r01's knob uses `left-6`;
  - probe r71's track uses `h-6`.

  The reset theme defines neither step. Counting both forms, build-design went off-scale on t4
  in 2 of 8 runs, against 0 of 8 for bare and the pack. That is under the regression rule's
  threshold, and the probe is outside the rule, so it is reported, not counted. The
  contender's four fails are the same toggle: `h-5` in three runs, and arbitrary pixel values
  in r15.
- **Invocation probe** (exploratory, outside both rules). pack+build-design with plain prompts.
  - On the billing page, the Skill tool loaded build-design in 4 of 4 runs.
  - On "Fix the typo in the Notifications card title", it loaded in 0 of 4.
  - All four billing replies state the 2× scale or call the values estimates (read by hand; no
    judge graded the probe).
  - R5, read by hand against the brief:
    - r66 and r72 pass.
    - r71 fails twice. "Page padding and gaps | 32px | `p-8`, `gap-8` | Matches" is the
      brief's own fail example, since the design's gap is 24px. "Seats bar | 4px track … |
      `h-1` | Matches" is also false, since the planted height is 6px.
    - r70 is arguable: "Page layout, card padding, gaps | 32px / 16px | … `gap-8` | Matches the
      Settings layout".
  - With calibration's r15, build-design made a false match on a planted value in 2 or 3 of 9
    billing-page builds, and in none of the 4 scored ones.
  - The scored pack arm loaded no skill in any of its 16 runs.
- **Routing, as found in calibration.** The pack arm's skill listing names 28 skills: 15 from
  the pack and none a design skill. 33 of the pack's 47 skills carry
  `disable-model-invocation: true`, and every design sibling of the candidate is among them.
  That is the pack's existing route for vendored third-party snapshots, which the 2026-10-07 vet
  kept, so it is not an accident. Its finding 8 names two licensed snapshots that lack the flag,
  `firecrawl-research-index` and `google-safe-browsing`. Both appear in this listing.
- **Not measured.**
  - The Figma path: no Figma MCP was connected.
  - The candidate's compare step: no arm could render its build. Every build-design reply said
    the comparison was unverified, as its step 4 asks.
  - The payoff of asking first: the second turn supplies nothing new.
  - Other models.
  - Real member designs.
  - Interactive sessions.

## 3. Verdicts

| component | target | verdict | placement | activation | evidence | state |
|---|---|---|---|---|---|---|
| build-design @ `6c21201` | hov-stack skill pack | **EXTRACT** by the rule; not landed | no installation | none | section 2: R2 8/8 against the pack's 1/8; no outcome regression | at vet time, port not landed: no pack skill a member invokes when building from a design under the invoke-only posture; the posture question is the operator's (section 4). **2026-11-17: landed in `ui-design` (#730, 0.3.6) under option 2** |
| design-to-code-fidelity @ `5548960` | none | SKIP for this job | no installation | none | D1 (t4) 0/4, a regression against the pack; asked before building in 7 of 12 build runs; median $0.097 | alternatives/GitHub, deep-vetted |
| hov-stack skill pack 0.3.5 | already installed | no change | no change | as installed | outcome at ceiling; R2 1/8 | incumbent |
| Figma `figma-design-to-code` (figma/mcp-server-guide @ `490a73c`) | none | not evaluated under this fixture | no installation | none | needs the Figma MCP server; connecting one is the operator's security-posture call | alternatives/Web, pass 2, triaged |
| skobak/pix @ `4a5d900` | none | not evaluated under this fixture | no installation | none | needs the Figma MCP server and Chrome; its reuse of project components was only partly read | pass 1, triaged |
| hxx2001/screenshot_to_code_agent-skill @ `f071261` | none | not evaluated under this fixture | no installation | none | runs Python scripts, a preview server and a browser capture, which no arm had, and targets a new standalone page rather than an existing tokened project | alternatives/GitHub, triaged |
| Figma `figma-code-connect` (same pin as `figma-design-to-code`) | none | complement, not a contender | no installation | none | maps Figma components to code components; builds nothing itself | pass 2, triaged |
| 731-cyber/claude-figma-pixel-parity @ `2ee5933` | none | complement, not a contender | no installation | none | compares and fixes an existing build against Figma values; Figma MCP | experience/GitHub, triaged |
| robukh/figma-suite @ `bd79635` | none | complement, not a contender | no installation | none | token and component sync between code and Figma; its own description leaves code generation to the official skills | alternatives/Web, triaged |
| tablesleveldesign/design-tokens-mcp @ `d280366` | none | complement, not a contender | no installation | none | token lookup and contrast only; its README says nearest-token lookup is not built | implementation/GitHub, triaged |
| google-labs-code/design.md @ `1ed38aa` | none | complement, not a contender | no installation | none | a token and rationale file format, no design-to-code workflow | pass 3, triaged |
| Figma MCP server (remote) | none | complement, not a contender | no installation | none | the data layer under every Figma contender; connecting it is a security-posture change | implementation/Web, triaged |

## 4. The change

**No pack change** at vet time. *2026-11-17: the operator took option 2; see the note under the
headline.*

- **The port the rule names.** These are the candidate's lines behind the R2 gain, `SKILL.md`
  lines 18 and 22 at the pin:
  - "A screenshot or exported image has no values to read. Sizes are ratios to the capture, so
    state the scale you assumed and treat every measurement as an estimate. Ask for the Figma
    link when one exists, since it replaces the whole estimate."
  - "From an image they are estimates at the scale you stated."
- **Why it is not landed.** The rule writes the port "into an existing pack skill" and lands it
  only after its own live run. No host passes the reachability test, meaning a skill a member
  would invoke when handing over a design:
  - The nine siblings polish (better-ui, better-layout, better-colors, better-typography,
    better-accessibility, better-writing), review (interface-review), explain
    (explain-interface) or stress-test (break). None is the command for "build this".
  - With a plain prompt, a port inside a slash-only skill never loads. The pack loaded no skill
    in 16 of 16 plain runs, so the live run would fail by construction.
  - With that host's slash command, the run measures a command no member types for this job.
  - The remaining routes each change something this vet may not change on its own:
    - design-rails is a separate plugin, not the pack;
    - a new pack skill carrying the lines is vendoring by another name, which the rule did not
      reach;
    - removing `disable-model-invocation` from a design skill departs from the invoke-only
      route that the 2026-10-07 vet kept for vendored snapshots. It would not be the first
      exception: two licensed snapshots already lack the flag (section 2).
- **The operator's decision: an exception to the invoke-only posture for one design-build
  skill.** Options, best first:
  1. **Keep the posture; land nothing (recommended).** On this fixture the pack already builds
     on-system with full component reuse. What members miss is one reporting habit, at no
     measured cost to the build.
  2. **Allow one model-invocable design-build skill.** That is build-design without the
     slash-only flag, or a pack-written skill carrying the two lines.
     - The probe says it would load when wanted (4 of 4) and stay out of an unrelated task
       (0 of 4), and that the estimate wording survives.
     - It also went off-scale on the toggle in 1 of 4 plain runs. In 1 of 4 (perhaps 2), it
       labelled a planted value "Matches" when the build differs.
     - It would need its own plain-prompt live run (four runs each of t1 and t4) before it
       lands.
     - *Taken 2026-11-17* as a pack-written skill, `ui-design` (#730), after that run:
       `harness/vet-fixtures/ui-design-2026-11/`.
  3. **Vendor build-design slash-only as `/hov-stack:build-design`.** This is exactly the
     measured candidate arm. But the rule gave EXTRACT, not ADOPT, so this overrides the
     pre-registration, and it reaches only members who know to type it.
- **Provenance for any later landing.** Pin `6c21201`, `SKILL.md` sha256 `d51cb44f…3a68`, MIT.
  The candidate names a `variant` skill for exploring alternatives, which the pack does not
  carry (the pack's nearest is `prototype`). A vendored copy would need that line adapted.

## 5. Findings

- **Shared, about the artifact.**
  - It builds on-system and reuses the project's components as well as the pack does. Every
    such cell was at ceiling, except the toggle.
  - It never claimed the build as a whole matched. All 12 scored build replies say they did not
    render or compare, as its step 4 asks when no browser is at hand (read by hand). r39 closes
    with "I didn't compare any other widths", which sits badly with its opening "the comparison
    against the design is unverified".
  - Its report table marks many rows "Matches". Those are values read off the image at an
    assumed 2× scale and never rendered.
    - On unplanted rows they were right.
    - On planted values, the scored runs made no false match (0 of 8 on t1 and t4).
    - It did make them in calibration (r15) and in the plain-prompt probe (r71, arguably r70).
    - A port of the estimate lines would carry that table habit with it unless the port's live
      run checks R5. *2026-11-17: the ui-design run scored R5, with 1 fail in round 1 and 0 in
      round 2.*
  - The 36×20 toggle is where it slips: off-scale in 2 of 8 billing-page builds across both
    forms.
- **Target fit.**
  - The invoke-only posture is what blocks the port (section 4). It is also why the pack arm
    loaded no skill: the siblings build-design defers to are invisible to the model unless a
    member types their slash command.
  - Nothing in the outcome items suggests members lose build quality by not having
    build-design.
- **Fixture findings.**
  - The answer key says the t1 header gap (24px) has no on-scale value. r02 composed it from
    two existing steps (`mt-3 pt-3`), which D1 correctly passes.
  - No item scores whether the t1 gap's rounding was reported. r45 built it at 16px without a
    word and passed every item. A re-vet should add that item before calibration, not after.
  - Judge batches can drop a packet silently. The tally's refusal on a missing grade caught r34.

- **Figma path, fact-checked but not run.** The candidate's `figma.md` names Figma MCP tools
  and behaviours. Against Figma's tools page and help articles: `get_screenshot`,
  `get_metadata`, `get_variable_defs`, Code Connect naming the exact component, and React +
  Tailwind as the default output are confirmed. Temporary asset URLs are confirmed; the word
  "expire" and a lifetime are not in the docs. The sparse-response handling, the `1-2` to `1:2`
  node-id conversion and the branch-key rule are absent from the docs and confirmed only by
  Figma's own skills repo, which itself calls `get_design_context` with the hyphen form in one
  place.
- **Prior notes.** I searched `docs/vets/` for build-design and for every contender here. None is
  in an earlier note. The nearest are the 2026-09-01 jakubkrehel vet that brought in the nine
  siblings (#816/#817 as the emilkowalski note cites them). Its note is a memory note, not in
  `docs/vets/`; its review-only fixture is `harness/vet-fixtures/jakubkrehel-skills/`, which
  predates build-design and does not exercise it; and each
  sibling's `UPSTREAM.md` cites it), and `2026-10-07-emilkowalski-skills-harness-vet.md`, whose
  delivery row keeps the existing invoke-only route for vendored snapshots
  (`disable-model-invocation: true`). That route changes applicability here: section 4 follows
  it.
- **Discovery hits dropped at triage.**
  - abi/screenshot-to-code, emilwallner/Screenshot-to-code, NoviScl/Design2Code,
    HySonLab/Design2Code, SALT-NLP/Sketch2Code: standalone apps or research code, not an agent
    skill working inside an existing repo.
  - bitovi/ai-enablement-prompts `figma-design-react`: says it does not build components and
    tells the agent not to use other component libraries as reference.
  - stellar/laboratory, vultisig/vultisig-ios, Synerise/synerise-design, moderntribe/tribe-libs
    figma skills: tied to one codebase.
  - IgniteUI `igniteui-wc-figma-to-app`: tied to one component library.
  - alima-max/prototype-to-figma-skill, senlindesign/claude2figma,
    Shanmus4/figma-variables-tokens-generator: write into Figma, the opposite direction.
  - Framer MCP, DS Manager MCP and taste-skill posts on X: other tools, not design-to-code.
  - wilwaldon/Claude-Code-Frontend-Design-Toolkit and the skill-directory mirrors: listing
    sites.
  - The unnamed X "design-to-code" skill: no retrievable repo.

## 6. Audit dividend and re-audit triggers

**Audit dividend:**

1. **Routing.** On a plain "build this design" ask, the pack's design skills are invisible to
   the model: no skill loaded in 16 of 16 pack runs. That is the invoke-only posture working as
   set, but it means a member gets better-ui and its siblings only by typing their slash
   commands. The posture question in section 4 is the operator's.
2. **The fixture's two item gaps** (section 5): the composed-gap route, and the unscored t1 gap
   report.
3. **Two papercuts, logged.**
   - The worktree guard refused a git-free inline Python check as "too complex to verify"
     (git operations). A script file ran the same code.
   - A judge subagent can omit its last packet from a batch file without saying so.

**Do-not-retry unless:**

- upstream `build-design/SKILL.md` changes from sha256 `d51cb44f…3a68`;
- a Figma MCP is connected, which opens the Figma path (also re-check `figma.md` against
  Figma's docs then);
- the fixture gains a render step (a shell and a browser), which exercises the candidate's
  compare step;
- a second turn supplies real values, which measures the payoff of asking first;
- the operator changes the invoke-only posture for a design-build skill (then run the port, or
  build-design itself, with plain prompts on t1 and t4 before it lands). *Fired 2026-11-17: the
  port ran in `harness/vet-fixtures/ui-design-2026-11/` before it landed in #730;*
- the fixture gains a second model;
- for the contender: `design-to-code-fidelity/SKILL.md` changes from sha256 `864564fd…9f6d`.

**Evidence on disk:** `harness/vet-fixtures/build-design-2026-11/results/`. It holds:
- the run key and the scores;
- both judges' grades, with their batch files;
- the tally and the skill-load log;
- `replies.jsonl`, every run's prompt and replies, which the hand-read claims above can be
  checked against.

The run dirs, their diffs and the packets were under `/tmp` and are not kept.
