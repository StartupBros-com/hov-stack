# learn-taste-2026-11

This fixture is the harness-vet run for
[`emilkowalski/skills` `learn-taste`](https://github.com/emilkowalski/skills/tree/64eb3deb9a5fbfa041faf783e0bc3fd635872e9c/skills/learn-taste)
(pinned at `64eb3de`; `SKILL.md` sha256 `d624b8cd…d33e`, unchanged since
`0f2e23b`). Work item: hov-stack#683. The verdict lives in
`docs/vets/2026-11-16-learn-taste-harness-vet.md`.

## The job

The arm reads the user's **previous** Claude Code session in a repo. It turns
the design corrections the user made there into rules, each with its why, and
proposes them before writing. Then, told `write all`, it writes them where the
next agent will read them.

The repo is `acme-notes`, a synthetic Vite/React/Tailwind app. It already
follows the design-rails convention: a token-fronted `design/DESIGN.md` that
`CLAUDE.md` names as the styling source of truth. A HOV member's repo looks
like this once `/design-rails` has run.

## Arms (matched: same ask, same model, same tools, same isolation)

| Arm | Turn 1 prompt | Skill under `~/.claude/skills` |
|---|---|---|
| bare | the ask | none |
| learn-taste | `/learn-taste ` + the ask | learn-taste @ `64eb3de` |
| ce-retro | `/ce-retro ` + the ask | compound-engineering 3.38.1 `ce-retro`, the installed incumbent that mines sessions for fixes to a repo's instructions |
| retro | `/retro ` + the ask | `craftwork-design/retro` @ `d39280b`, the strongest headless third-party contender from discovery |

The ask: "Go through my previous session in this repo and turn the design
corrections I made into rules future sessions will follow. Show me what you'd
add before writing anything." Turn 2 for every arm is `write all`.

Two arms were not run.

- `BayramAnnakov/claude-reflect` @ `b6c4232`. Its `/reflect` is an interactive
  flow with about 10 `AskUserQuestion` stops, and it spawns a nested
  `claude -p` for each message. It has no headless form.
- `davidparys/claude-mods` rule-keeper @ `7aa4eb9`. It is a UI band on typed
  prompts in a live session, and cannot read a past transcript.

Both are recorded as typed mismatches in the eval note.

## Adoption rule (declared before any scored run)

The primary metric is K-correct: the count of K1–K8 with the correct
disposition (see `answer-key.md`), as a median over 3 runs per arm. A
difference of 1 or less is a tie. With n=3, no significance is claimed.

Notation: LT is learn-taste, B is bare, and I is the better of ce-retro and
retro by median K-correct.

1. **ADOPT or ADAPT** for the hov-stack skill pack (slash-only) needs all
   three of these:
   - (a) median K-correct(LT) ≥ median(B) + 2, and ≥ median(I) + 1.
   - (b) Zero premature writes in every LT run.
   - (c) Median invented rules(LT) ≤ max(1, median(B)), and no LT run follows
     X2.
2. **ADAPT**, not ADOPT, if in any LT run turn 2 creates a root `DESIGN.md`
   beside the wired `design/DESIGN.md`, or breaks its front matter. The
   adaptation is then a destination note.
3. If (a) fails only because B is within 1 of LT, the verdict is **EXTRACT**
   when LT beats B on a countermetric:
   - median fabricated whys lower by ≥1, or
   - median invented rules lower by ≥1, or
   - B wrote prematurely in any run while LT did not.

   Otherwise the verdict is **SKIP**. The ask alone gets the model there.
4. If I beats LT by 2 or more, the verdict is **SKIP**, and the incumbent is
   named.

**Countermetric tolerance for LT:** median invented rules ≤ 1, median
fabricated whys ≤ 1, and premature writes 0.

Cost (`total_cost_usd`) is recorded for each turn and gates nothing.

## Exploratory: the all-history ask (outside the adoption rule)

Declared after the scored matrix and before any of these runs. No verdict
rides on them; they inform what an all-history mode would need.

Arms `bare-wide` and `learn-taste-wide`, 3 runs each, ask `ASK_WIDE` in
`make_runs.py` ("Go through all my past sessions, in every project, not just
this one, …"). Same fixture, so the billing-portal session is now in scope by
the ask. Recorded from turn 1:

- K-correct, graded as above, so a drop shows what the wider scope cost.
- X3 disposition, one of four:
  - **leak**: a slate-900 or no-pure-black rule proposed for acme-notes with
    no mention that it came from billing-portal;
  - **labeled**: proposed or offered with billing-portal named as its source,
    as a cross-project or user-level candidate, or as a question;
  - **excluded**: named and left out;
  - **missed**: not mentioned.
- Reach: whether `tools.txt` shows the billing-portal session.
- Invented rules and fabricated whys, as above.

Turn 2 is recorded as for the scored arms, plus where any X3 content landed.

## Added arm: claude-reflect (declared after the scored matrix, before its runs)

claude-reflect was slated in discovery and left out as having no headless form, a call
made from reading alone. Two probes then showed otherwise. Under `claude -p`,
AskUserQuestion is not offered even when allowed, and the model asks in plain text
instead. Its history scan needs no hook-captured queue. So the two-turn form fits it.

- **Invocation.** Turn 1 is `/reflect --scan-history ` + the ask, with the plugin at
  `b6c4232` copied into the run dir and loaded with `--plugin-dir`. `--scan-history` is its
  documented cold-start form. With an empty queue, plain `/reflect` only asks whether to
  scan. Its four hooks load too. They are local Python that writes only under HOME.
- **Scope.** Its scan reads this project's sessions only (`project_paths.py`). X3, from
  billing-portal, is outside that scope by default. It is graded as for the scored arms.
- **Measurement.** It classifies messages with nested `claude -p` calls. `run_arm.sh`
  routes them through a logging shim, and `check_runs.py` adds their cost to the arm's.
  Nested transcripts are counted (`nested_sessions`) and left out of the arm's tool log.
  They land in the same folder its scan reads. That is reported, not corrected.
- **Rule.** I is now the best of ce-retro, retro and claude-reflect by median K-correct.
  Rule 1(a) needs median(LT) ≥ median(I) + 1. With LT at 7, it holds only if claude-reflect's
  median is 6 or less. The declared rule left one case open, claude-reflect at 7 or 8: (a)
  fails, and rule 4 cannot fire. Declared now: in that case learn-taste is **SKIP** (not
  better than the best contender), claude-reflect's row gets its own phase-5 pricing as a
  proposal for the operator (it ships hooks, and enabling a plugin is the operator's call),
  and nothing lands for either.
- **Smoke first.** One run comes before the others. It passes if both turns exit 0 with a
  non-error result and the turn-1 reply proposes rules drawn from the planted session. If it
  passes and nothing in the setup changes after it, it counts as rep 1, and reps 2 and 3
  follow. If it fails, the arm is PARTIAL. The deciding run is then an interactive session
  with scripted answers on this fixture, and learn-taste is SKIP pending that run.
- **Grading.** The same brief, two judges in opposite orders, plus the K7-only judge. The
  batch also carries the first scored run of learn-taste (r07), bare (r03) and retro (r01),
  rebuilt with the current `packets.py` under new numbers. That keeps a one-arm batch blind
  and shows drift against the first grades. Those three re-grades are reported as drift
  only, and the scored matrix keeps its recorded grades.

## Running it

```bash
# third-party skills at their pins, in a scratch dir (never vendored here)
git clone --filter=blob:none https://github.com/emilkowalski/skills /tmp/<dir>/emil && git -C /tmp/<dir>/emil checkout 64eb3de
git clone --filter=blob:none https://github.com/craftwork-design/retro /tmp/<dir>/retro && git -C /tmp/<dir>/retro checkout d39280b
python3 -I make_runs.py --out /tmp/<runs> --key /tmp/<key>/map.json --reps 3 \
  --src learn-taste=/tmp/<dir>/emil/skills/learn-taste \
  --src ce-retro=<compound-engineering 3.38.1>/skills/ce-retro \
  --src retro=/tmp/<dir>/retro/skill
bash run_arm.sh /tmp/<runs>/r01   # one per run dir; independent, so run them in parallel
```

`run_arm.sh` explains the isolation. HOME, TMPDIR, the XDG dirs and
`CLAUDE_CONFIG_DIR` (= `HOME/.claude`) all point inside the run dir. The
environment is emptied except PATH and the model-route variables, which pass
by name. `sessions.py` builds the repo by replaying the planted session onto
`seed/`, and it fails if any edit's old text is not found exactly once.
Everything in `seed/` and `sessions.py` is synthetic.
