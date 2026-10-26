# Upstream provenance

Source: https://github.com/cursor/plugins/tree/main/pstack/skills/create-verification-skill
Commit: 1f84288b2c047b6d39952da23f51cf486f3b2f7a (pstack 0.15.2)
Date: 2026-09-19
License: MIT (verbatim upstream `LICENSE` copied beside this file; upstream
copyright holder Lauren Tan)

Vetted per `harness/third-party-skill-vetting.md`: read every file in
both `create-verification-skill/` and `maintain-verification-skill/`, no
network calls or command execution in either SKILL.md, no prompt injection,
no self-updating instruction channel, no name collision with a live skill
(checked `retired-skills.txt`, `codex-skills.txt`, and the
`skill-collision-check.py` roster below), pinned to the commit above rather
than a branch.

## Local changes

- Frontmatter `description`: reworded for our roster. Drops the Cursor
  example phrase `"make a control skill for this repo"` for
  `"build a verify skill for this repo"`, and appends `beyond "it compiles"`
  to name the evidence bar this port adds. No Cursor product name was
  actually present in the original description; this is a roster-fit
  rewrite, not a tool-name swap.
- Frontmatter `argument-hint`: added (upstream had none). Names the
  app-or-surface argument the generator accepts, defaulting to the repo's
  primary user-facing surface.
- Generated-skill frontmatter `disable-model-invocation: true`: required locally.
  The generator itself already has this flag upstream, unchanged at the pin.
  The generated skill starts and kills real processes, so it must run only
  when named, not auto-invoked. Confirmed against the one generated skill
  that has actually run: `harness/vet-fixtures/pstack-2026-09/
  exp20-generated-skill/SKILL.md` (commit `aa6f19c`) carries this flag on
  `verify-better-ccflare`, so the requirement matches the proven fixture
  rather than inventing a new convention.
- Body, line 9 (`.cursor/skills/verify-<app>/`): translated to
  `<repo>/.claude/skills/verify-<app>/` -- Claude Code's project-skill root
  differs from Cursor's. Same translation repeated at the start of section 2
  (`Write .cursor/skills/... -> Write <repo>/.claude/skills/...`) and section
  3 (`Create .cursor/skills/.../features/README.md -> Create
  <repo>/.claude/skills/.../features/README.md`). "You write the
  generator's output" reworded to "Write the generator's output" (voice
  only, imperative throughout).
- Surface bullet: appended "(or the one named by this skill's argument)" to
  point at the new `argument-hint`.
- Section 2, name collision: added a lead sentence -- check the installed
  roster before choosing `verify-<app>`; a project skill that shadows an
  installed one, for example `verify-review`, gets a different app name.
  Upstream had no equivalent check; a Claude Code project roster can already
  hold a same-stem skill upstream's single-vendor Cursor model doesn't
  anticipate.
- Section 1, build prerequisite: added a sentence distinguishing a build
  prerequisite (a missing asset the project's own build step would normally
  generate, such as a gitignored generated file or a compiled worker stub)
  from verification scaffolding: the generator creates the same placeholder
  the build produces and leaves it in place, while only scaffolding invented
  for verification is removed in cleanup. Upstream's scaffolding sentence
  didn't distinguish the two, and the exp20 proof run hit exactly this case
  (a gitignored dashboard bundle needing `bun run build:dashboard`).
- Drive bullet: this is the harness-naming translation the port requires,
  revised twice. The port's initial commit replaced upstream's "browser/CDP
  for web and Electron" with headless Playwright named as the default and
  wsl-cdp as the real-browser fallback. This pass reorders it again, per an
  inward-vet finding: check the installed skill roster first for a skill
  that already covers this repo's stack (for example
  `~/.claude/skills/e2e-testing-for-webapps` for a Next.js,
  Playwright, and Supabase repo) and reuse its infrastructure rather than
  deriving a parallel harness; otherwise an existing harness already in the
  repo wins, then the driver `ce-test-browser` selects for this host, then
  headless Playwright only when neither exists and never installed alongside
  an existing browser stack, then wsl-cdp only for a feature needing the
  operator's already-authenticated browser, and then read-only inspection
  unless the operator confirms a mutating drive in that session.
  Unconditional default-to-Playwright is what the earlier pass got wrong: a
  repo with its own harness or with `ce-test-browser` available shouldn't
  get a second, parallel browser stack.
- Observe bullet: added "DOM/ARIA text" to the evidence-type list, matching
  the evidence-discipline requirement (named artifact types: screenshot,
  DOM text, or exit-code log).
- Doctor bullet: appended "Never drive an instance the verification run did
  not start" plus a sentence requiring the doctor check to prove run-owned
  identity (port owned by us, a build/version stamp, a scratch data or
  config directory named for this run) rather than just liveness. This
  generator rule was implicit in upstream's Isolate bullet and the Doctor
  bullet's own phrasing ("port owned by us"); made explicit here because the
  work-spec requires it to survive the port and the issue's planted
  negatives test for it directly.
- Section 3, unverified marking: added a sentence -- mark every state
  assumption in a feature file the proof run did not drive with an inline
  `unverified:` prefix, so a later run confirms it before trusting it.
  Upstream had no such marker; without it a one-feature proof run (see the
  Prove-step entry below) reads as if it covered the whole map.
- Evidence bullet, revised twice. The port's initial commit prepended the
  artifact-naming rule -- every pass claim saves a screenshot, a DOM/ARIA
  text dump, or an exit-code log under this repo's
  `.claude/deliverables/verify-<app>/<run-id>/`, one file per claim -- and
  appended the `environment blocked: <what>` outcome plus "never guess at a
  secret value to get past a blocked environment" (neither concept existed
  upstream). An inward vet caught that the per-run path was wrong against
  `harness/deliverable-locations.md`: `.claude/deliverables/` is the
  Reviewable tier, for operator-read files opened via `open-deliverable`,
  not a dumping ground for every run's raw proof. This pass replaces it with
  a two-tier rule: per-run proof goes to a fresh
  `/tmp/verify-<app>-<run-id>/` directory, one file per pass claim,
  surviving cleanup there; when a run's proof is meant for the operator, a
  short summary plus key artifacts also go to
  `<repo>/.claude/deliverables/verify-<app>/<YYYY-MM-DD-HHMM>-<slug>/`, with
  `open-deliverable <path>` run and the path reported. Also added, at the
  `environment blocked` outcome: in the harness outcome taxonomy this is
  `NO_EVIDENCE`, the gate could not be evaluated
  (`harness/evidence-regime.md` section 5) -- upstream drew no such
  taxonomy distinction and this port hadn't named one either until now.
- Cleanup bullet: revised to match the Evidence-bullet fix above -- proof
  artifacts under `/tmp/verify-<app>-<run-id>/`, and anything already copied
  to `<repo>/.claude/deliverables/verify-<app>/` for the operator, survive
  the teardown (previously pointed only at the deliverables path). "A
  cleanup that eats the proof fails this step" is unchanged from the port's
  initial commit, which split it into its own sentence here (upstream only
  stated it once, in the Prove section).
- Feature-map H2 names (section 3): normalized `How to get to it (user
  POV)` -> `How to get to it from the user's point of view` and `Driving it
  with <harness>` -> `Driving it with the harness`. This pass deliberately
  left the headings unchanged even though the browser-driver order above
  changed: the one generated skill that has actually run (the exp20
  fixture, `harness/vet-fixtures/pstack-2026-09/
  exp20-generated-skill/`, not present in this worktree's checkout but
  confirmed in repo history at commits `aa6f19c`/`a2730a1`) used these exact
  heading strings, and a fixed heading stays greppable across repos
  regardless of which harness a given repo's Drive section names.
- Prove step (section 4), revised twice. The port's initial commit appended
  "capture evidence under `.claude/deliverables/verify-<app>/`" and restated
  the `environment blocked: <what>` outcome. This pass updates the evidence
  path to match the Evidence-bullet fix (`/tmp/verify-<app>-<run-id>/`, with
  an operator copy under `.claude/deliverables/...` when warranted), adds
  the same `NO_EVIDENCE` taxonomy note, and adds a new sentence: the agent
  that wrote the skill also proved it, so this one proof run is
  self-certification -- record which feature was proven, and leave every
  other feature file marked `unverified:` until a fresh session drives it.
  Upstream had no self-certification caveat; the port's own generation
  model (one agent writes and proves the skill in the same session) makes
  it load-bearing here.
- Section 5 (maintenance pointer): unchanged in meaning. The referenced
  skill name (`/maintain-verification-skill`) is unchanged because it does
  not collide with any live skill in this roster.
- No Cursor-only tool tokens (`subagent_type`, `AskQuestion`, `control-ui`,
  `control-cli`, `cursor-team-kit`) were present anywhere in this file
  upstream; none needed replacement here.

### references/feature-map-example/ (ported)

The three example files (`README.md`, `create-note.md`, `search.md`) port a
fictional Notes app that upstream drives entirely through a single wrapper
binary, `control-notes browser ...` / `control-notes cli -- ...` (Cursor's
`control-ui`/`control-cli` family under a per-app name). There is no Claude
Code equivalent unified control binary, so every occurrence was replaced
with a direct call in the tool that actually does the work:

- Browser actions: `control-notes browser <verb> --role ... --name ...`
  replaced with the equivalent Playwright locator call inline in the step
  prose (e.g. `page.getByRole('button', { name: 'New note' }).click()`),
  driven per the Drive-bullet translation above.
- CLI actions: `control-notes cli -- notes <command>` replaced with the
  bare `notes <command>` invocation as a direct shell command, capturing
  stdout/stderr/exit code directly (no wrapper).
- `control-notes doctor` (README baseline preconditions) replaced with "the
  doctor check named in the skill's Doctor section (for example `curl -s
  http://127.0.0.1:4173/api/health`)" -- the example no longer assumes a
  named binary the generated skill may not have. The same substitution was
  also made, but left undocumented until this pass, inside the per-feature
  precondition lines: `create-note.md` line 24 (`` `control-notes doctor`
  reports the expected URL and disposable data directory.`` became
  `` The doctor check reports the expected URL and disposable data
  directory.``) and `search.md` line 26 (same pattern, "and data directory"
  wording).
- `control-notes` / `notes` CLI on `PATH` (README) trimmed to just the
  `notes` CLI, since `control-notes` no longer exists in the port.
- README "Driving conventions" bullets name headless Playwright (Chromium)
  as the default and wsl-cdp as the real-browser fallback, with the generated
  skill's Drive section deciding the harness; terminal actions use direct
  shell invocation or a PTY driver for interactive prompts. These replace
  the `control-notes browser` and `control-notes cli -- <command>` wrappers.
- README "Feature entry contract" H2 names normalized to the same canonical
  wording as the generator body (`How to get to it from the user's point of
  view`, `Driving it with the harness`).
- README, UI proof line: restored to upstream's original wording -- "UI
  proof includes an ARIA snapshot and a screenshot with the app identity
  visible" -- reversing an earlier local change that had it read "a DOM
  text dump (or ARIA snapshot)". See the proof-artifact fix below.
- `create-note.md` and `search.md`: every `control-notes browser ...` /
  `control-notes cli -- ...` command line replaced 1:1 with its Playwright
  or direct-shell equivalent as above; all user-facing content (feature
  IDs, entry points, preconditions, gotchas) preserved except two further
  fixes this pass:
  - Proof-artifact rigor: an earlier local change had swapped upstream's
    ARIA snapshot proof for a DOM-text (`innerText()`) dump, to match what
    the exp20 fixture happened to capture. An inward vet flagged this as a
    real rigor loss (an ARIA snapshot is closer to what an accessibility-
    tree assertion actually sees than a raw text dump), so this pass
    restores `page.locator('body').ariaSnapshot()` in both files, alongside
    the screenshot, and renames the artifacts `*.aria.txt`. Both files'
    proof paths also move off `evidence/<feature>/...` onto the per-run
    `/tmp/verify-notes-$RUN_ID/<feature>/...` path from the Evidence-bullet
    fix above.
  - Verb harmonization: the "How to get to it" entry-point bullet and the
    matching driving step must use the same verb for the same action. Two
    entry-point bullets still read "Choose" while their driving steps
    already read "Click" (an undocumented gap from the port's initial
    commit, corrected here); this pass changes both to "Click":
    `create-note.md` line 14 (`New note`) and `search.md` line 16
    (`Search`). Combined with the port's initial-commit rewrites -- also
    undocumented until now -- of `create-note.md`'s "Open editor" and "Save
    note" steps, and `search.md`'s "Toolbar entry", "Open result", and
    "Clear query" steps, every `Choose` in both files is now `Click`: seven
    rewrites total, five from the initial port and two from this pass.
    `create-note.md`'s "Cancel draft" step keeps upstream's lowercase
    "choose `Cancel`" verbatim; it was never part of this rewrite.
  - `create-note.md` line 3: upstream reads "cancel an unfinished draft";
    this port reads "cancel an unfinished browser draft". Undocumented in
    every prior revision of this file; recorded now. The word "browser"
    disambiguates from the CLI creation path added two sentences later in
    the same file, which has no draft-cancel step of its own.

Every em dash in the upstream text was replaced with `--` throughout both
SKILL.md files and the three reference files, per this harness's writing
rules (no em-dashes).

## Unverified local changes

- The `.claude/deliverables/verify-<app>/<YYYY-MM-DD-HHMM>-<slug>/`
  operator-facing path and the `open-deliverable <path>` step have not been
  exercised by any run. The one proof run this port has (experiment 20,
  driving a scratch clone of better-ccflare) wrote its evidence to `/tmp`
  after a write-isolation guard refused a write to
  `<repo>/.claude/deliverables/...` from outside the run's own worktree; it
  never reached the deliverables path or `open-deliverable` at all. The
  two-tier rule above is written to match the doctrine in
  `harness/deliverable-locations.md`, not to match an observed run.
- The reordered Drive bullet (existing-repo-harness, then `ce-test-browser`,
  then headless Playwright, then wsl-cdp) and the roster-reuse instruction
  pointing at `e2e-testing-for-webapps` have not been exercised by any
  generator run either. Experiment 20 predates this ordering and used
  headless Playwright directly.
