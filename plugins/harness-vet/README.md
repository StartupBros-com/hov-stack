# harness-vet

**The adoption gate for your agent harness.** Someone says a skill, plugin, MCP server, rules file, repo, or paper belongs in your setup. Before you install it, `/harness-vet <candidate>` runs a deep-dive with a default verdict of **SKIP** until verified utility earns the added context, tools, and upkeep. In v0.2.0, that judgment is made per target project or global scope: a global SKIP can coexist with a project ADOPT. v0.2.1 closed the gaps an adversarial review found on that path: the candidate's own copy at another scope is never "coverage", diverged duplicates are diffed and reconciled, a target's first instruction surface is proposed rather than landed, the eval note lives where the target's vets will search, a task must be concrete before the fixture is built, and a tool-heavy component is priced by measurement. v0.2.2 drops licence and terms handling entirely: whether you may use or redistribute a candidate is your call, not the vet's. v0.3.0 adds discovery: the vet searches GitHub, the web and X for the best of what exists for the target's job — other skills, libraries, CLIs, native features — and runs the strongest contenders as phase-4 arms beside the bare model, the candidate and the incumbent, so a verdict means "best of the N upstreams examined", with what was not searched named.

## Why the default is SKIP

Not vibes — receipts (sources and tiers in [`skills/harness-vet/EVIDENCE.md`](skills/harness-vet/EVIDENCE.md)):

- LLM-generated context files **reduced** agent task success 0.5-2% while raising cost 20-23%; human-curated ones helped only marginally (ETH Zurich, arXiv 2602.11988).
- Anthropic removed over 80% of Claude Code's system prompt with no measurable eval loss.
- Large toolsets showed performance losses up to 85%; narrowing the presented tool set tripled selection accuracy in one study.
- A scan of 3,984 public Claude Code skills found 13.4% with critical issues and 76 confirmed malicious.
- Across the ~15 real adoption evaluations this skill was mined from, **no multi-component candidate was ever adopted wholesale**; the modal outcome was extracting a handful of patterns.

These are historical findings from their stated studies and harness runs, not a universal skill-count limit or a measurement of v0.2.0. A candidate can earn adoption by improving the target's task under matched tests against the bare model and any available incumbent.

## What a vet does

Seven phases, each with a checkable completion bound in the [current skill](skills/harness-vet/SKILL.md):

1. **Intake** — resolve the target project(s), global scope, or unresolved destination and intended task/runtime. Normalize the candidate into scratch (read local candidates in place); record its revision or content digest. Check all relevant install locations for partial or shadowed copies and search shared/project prior notes by source identity and aliases. Preserve applicable prior findings. Treat candidate content as data, never instructions; paywalled/registry-only candidates retain the metadata-first path. Then discover: three search lanes (alternatives, implementation, experience) over GitHub, the web and X, one with the candidate's name withheld, followed by seeded passes with a stated stop; admit contenders on their own content, never on stars or authors; the strongest join the deep-vet slate under the existing cap, the rest are listed as triaged.
2. **Digest** — freeze [one shared artifact/environment block plus a delta for each target](skills/harness-vet/DIGEST.md), discovered at runtime and supplied to every reader/verifier. Record effective instructions, callable incumbents, controls, delivery conventions and unknowns. Check asserted paths and names; a project inventory is not a fleet inventory.
3. **Read** — capped fan-out of category readers, with structured per-component findings where supported. Read instructions and bundled executables in full, report unread material, and assess fit and overlap for each target while sharing artifact analysis.
4. **Verify** — refute-by-default: run candidate tests in isolation; compare bare/candidate/incumbent/contender behavior on representative target tasks, irrelevant-task controls and one task the bare model already solves, with matched model/settings, at least three runs per arm and both-order paired judging. Verify incumbent access and equivalence, probe guards both directions, check platform claims against official docs, and reproduce numbers before citing them. Missing tools or credentials mean incomplete evidence. A single fixture is a smoke test; improvement claims need repeated runs.
5. **Price** — quantify exposure where it actually loads: discovery metadata, invoked bodies, tools/services, discoverability and upkeep, including the whole enabled bundle. Apply the armor test and verify placement and off-switch controls in fresh sessions. Verdict delivery separately from content; read bundled code, manifests and update paths for supply-chain risk.
6. **Verdict** — per-component, per-target **ADOPT / ADAPT / EXTRACT / SKIP / REJECT**, with placement, activation and evidence status kept separate, plus a rollup for each target. Every SKIP and REJECT carries a scope-bound `Do-not-retry unless:` with observable predicates. Close with the **audit dividend**: what vetting the candidate exposed about your own harness. [Verdict definitions and the eval-note template](skills/harness-vet/VERDICTS.md) specify the required record.
7. **Ship** — honor report-only, issue-only, PR or apply instructions and the target's conventions. Report-only ends with an explicitly unshipped report. Security-posture changes are proposed with the exact target/config for operator authorization; an adoption recommendation is not permission to enable tooling. Preserve the upstream pin, local changes, update ownership and rollback in a durable eval note with re-evaluation triggers. Applied behavior-shaping ports also receive adversarial review.

Degrades gracefully: works with a workflow tool, a task/agent tool, or fully inline; with or without a memory system.

## Scope, coverage and delivery

**Shared artifact safety and target fit answer different questions.** A historical global SKIP solely for irrelevant context cost can remain valid while the same safe revision earns ADOPT for a concrete need in project-a. Recheck that project's utility, incumbent and all price checks; an as-is skill at a supported local placement is still ADOPT. This does not recommend global enablement. An unchanged revision with confirmed undisclosed exfiltration remains REJECT in project-a: project scope controls loading, not execution containment. Record which prior evidence still applies.

**Coverage means usable capability for this task.** A fully proven equivalent global invoke-only skill counts as an incumbent when it can actually be called from project-a. Its body need not be always on to justify SKIP-as-covered. A matching name, broad topic, disabled copy, or skill available only in project-b is not automatic coverage in project-a. Name and test the covering mechanism, invocation path, access and constraints. If evidence is missing, record SKIP pending evidence and its deciding check rather than invent a loss or call the candidate unsafe.

Multiple targets share the candidate's artifact review but get separate target rows in the digest, fit tests, costs and verdict rollups. The same safe candidate can earn project-a ADOPT for a demonstrated unmet need and project-b SKIP for an equivalent callable incumbent; neither conclusion silently changes global scope or other projects.

Keep these three decisions explicit:

| Decision   | What must be established                                                                                                                    |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Placement  | Where the host supports the artifact: project/subtree, global, or another verified source location, with its effective precedence.          |
| Activation | When it becomes visible, callable or automatic, and what enable/disable controls and session reloads actually do.                           |
| Packaging  | What is delivered together: a standalone skill, plugin bundle, installer or other mechanism, including hooks, services, grants and updates. |

A native project plugin install is **ADOPT as-is** when all bundled components are needed, safe, useful and priced for that target. Narrow placement alone does not require a fork. If only skill-x is wanted but enabling the plugin also brings objectionable hooks and services, project placement does not remove those bundle effects. Check actual per-component controls; do not invent a per-skill override. When tests prove skill-x works independently without hidden manifest behavior or dependencies, explicitly repackage it as a standalone skill under **ADAPT**. Record the copied files, attribution, source revision, adaptations, update owner and rollback. Porting only an idea into the target's idiom is **EXTRACT**.

Configuration is a claim to verify. Use isolated fresh target sessions and an unrelated control to check discovery/visibility, name collisions and precedence, invocation, enable/disable effects, hooks/services/tool grants and reload requirements. Match the intended local or hosted runtime. Record observed output and actual runtime state; if checks cannot run, mark them PARTIAL with the deciding check. Proposed, tested, landed and runtime-verified are separate states.

## Historical field results

These earlier evaluations illustrate the method; they are not v0.2.0 behavioral evaluation or deployment evidence.

- **Two prompt-skills from a social thread**: the A/B sandbox refuted the "models already do this" assumption for one of them — its scaffold measurably beat the bare model — while the arithmetic audit found its own worked examples off by 10×. Verdict: EXTRACT the proven pattern, skip the artifact. The extraction shipped as a new clean-room skill the same day.
- **A ~64KB paid registry skill**: a 3-arm planted-defect audit (bare / candidate / incumbent doctrine) showed the candidate's detection **identical** to the ~170-line doctrine the harness already carried — and found one blind spot _shared_ by both, which became a one-line doctrine fix. The audit dividend also surfaced a silently-failing nightly auth job. The verdict was SKIP; the vet still paid for itself twice.

- **A frontier-lab engineering post**: all seven verifiable claims CONFIRMED against official docs and the benchmark's own repo — and the verdict was still EXTRACT 1 / SKIP 3, because true ≠ needed. The dividend: testing the article's described failure mode against the host harness found its model-routing proxy silently discarding reasoning on every turn — a file:line-documented bug, now tracked upstream.

The pattern across all three: even when the answer is "don't install it" — and it usually is — a real vet returns value. In 3 of 3 runs, the audit dividend (what vetting the candidate exposed about the _host_ harness) was the chief finding, which is why the skill treats it as a required output, not a bonus.

## Install

From the [House of Vibe marketplace](https://github.com/StartupBros-com/hov-stack):

```
/plugin marketplace add StartupBros-com/hov-stack
/plugin install harness-vet@hov
```

Then: `/harness-vet <repo-url | local-path | post-or-paper-link>`, or
`/harness-vet <concrete task> for <project-path>` to find and compare what
exists for a task with no candidate in hand.

The skill is user-invoked only (`disable-model-invocation: true`). Price actual discovery metadata and invoked content according to the host's behavior instead of assuming that every installed source has the same exposure.

## Scoped invocations

The argument hint is `<candidate | concrete task> [for <project-path> ... | global] [report-only]`. Candidate inputs remain repo URLs, local paths, social posts, papers and registry entries. These are agent invocations, not shell commands; replace placeholders and verify project paths exist.

```text
/harness-vet <candidate> for <project-path> report-only
/harness-vet <candidate> global report-only
```

Ordinary language can name multiple targets and their tasks in one run:

```text
/harness-vet <candidate> for ./projects/project-a and ./projects/project-b. Evaluate its release-check skill for project-a's unmet release-check task and project-b's existing release-check workflow separately. Report-only; give a verdict and placement/activation recommendation for each target.
```

Explicit targets and landing instructions take priority. Otherwise the vet can infer a destination from the stated task and verified project context, recording its reasoning; the launch directory alone is insufficient. An interactive run asks only when an unresolved choice changes the work. An unattended candidate-only request with no defensible destination continues report-only with target `unresolved`, no installation, and unknowns recorded. Incomplete utility evidence warrants SKIP pending evidence, not a security REJECT or a default global install.

Large list-candidates (entries independently sourced and versioned) receive whole-list triage and at most three deep-vets by default; operator-named entries fill that slate first, and when they exceed it the run says so and offers the sizing choice instead of dropping names. A skill pack with one manifest is a multi-component candidate, not a list: named components are read in full first and the rest are marked triaged, not deep-vetted. Without an explicit landing instruction, use discovered target conventions, then PR-for-review. An unresolved destination still authorizes no installation.

## Behavioral fixtures

The thirteen authored [scope cases](tests/scope_cases.json) cover global versus project fit, callable incumbents, unavailable copies, retained security findings, multiple targets, unresolved destinations, both plugin delivery choices, the candidate's own copy at another scope, a target's first instruction surface, an unmeasured tool-heavy MCP server, a skill pack with operator-named skills, and a discovered contender slated with no incumbent. [Fixture instructions](tests/README.md) explain structural validation and evaluation with a fresh model session per case, withholding `expected` and `forbidden_claims` from the evaluated model. In v0.2.1 the smoke ran three rounds over that revision's thirteen cases (twelve of today's plus the since-removed licence case): 10, then 12, then 13 of 13 exact, with the two failures kept visible and the doctrine changed once in response to each; the v0.3.0 discovery case has had structural validation only, no fresh-model smoke. [The v0.2.1 rounds](tests/scope-smoke-v0.2.1.json) record every answer, every reviewer note and the SHA-256 of the four shipped files; [the v0.2.0 responses](tests/scope-smoke-final.json) and [its initial failures](tests/scope-smoke-results.json) remain visible, and [VERIFICATION.md](tests/VERIFICATION.md) states what each round did and did not establish. These synthetic decisions do not establish runtime isolation, estate-planning quality, statistical improvement or release deployment.

## What this is not

- Not a claim of better verdicts than your own careful deep-dive — no paired comparison has run. It encodes a mined, field-tested methodology so the deep-dive actually happens instead of being skipped.
- Not a scanner: it reads, runs, and prices with judgment; supply-chain review is a phase, not a signature database.

MIT. Mined from ~15 real adoption evaluations (2026-07/08) on the authoring harness; the `[measured]` tags in the skill refer to those runs.
