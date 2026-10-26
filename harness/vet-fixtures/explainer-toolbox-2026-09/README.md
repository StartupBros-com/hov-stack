# Behavioral fixture: explainer-toolbox vet (2026-09-02)

The planted-fact fixtures behind the `explainer-toolbox-vet-2026-09` memory note
(dotfiles issue #897, PR #898). Two niches, one answer key, Sonnet arms in
`claude -p --bare --tools ""`, judged by a separate Sonnet model that never saw the prompts.

- `fixtureA-source.md` — one bullet from the harness CLAUDE.md (gsc row-limit truncation):
  10 keyed facts, 3 traps (unstated row-limit number, "now fixed" framing, impressions
  relabelled as visits/traffic), register markers (adult-word definitions, toddler
  analogies, preamble, assumption line), form metrics (prose words, panels, HTML).
- `fixtureB-code.ts` — a synthetic 77-line handleUpload module: 12 call edges, 2 quirks
  (preview bypasses dedup; classicRedirect never watches progress), 3 traps (invented retry
  internals, invented validation/scan step, "redirect waits for the scan"). This is the
  second version: the first reused the function names from show-me's own call-tree example
  and its "invalidate cache" diff line, which handed the show-me arms the tree shape for
  free; the PR's code review caught it and every Fixture B number below is from the
  rewritten module, whose identifiers share nothing with the skill text.
- `answer-key.md` — judge-only. Never paste it into an arm prompt.
- `incumbent-eli5-2026-08.md` — the pre-vet `/eli5` text (trq212's three lines), frozen.
- `run-arms.sh` — builds prompts and runs every arm (or `ARMS=...` subset) into a fresh
  `OUT` dir; `unwrap.py` turns the JSON envelopes into `.md` outputs plus one summary line.
- `judge-batch3.md` — the full judge report for the decisive Fixture A batch.
- `judge-fixtureB.md` — the full judge report for Fixture B (one judge, one stated standard).

## Results

Facts are counted out of 10 (A) or 12 edges + 2 quirks = 14 (B). "Traps" is the number of
the three sprung. W is visible prose outside fenced/HTML blocks. V is panels or SVG figures.
Costs are `total_cost_usd` from the envelope.

### Fixture A, batch 1 (no harness note; picture-first skills had no way to write a file)

| Arm | Run 1 | Run 2 | Notes |
|---|---|---|---|
| bare | 10/10, 1 trap, W 374 | 6/10 +1 distorted, 1 trap, W 309 | prose only |
| incumbent /eli5 | 0/10 (dead: tried a Write tool, 20 words) | 7/10 +1 distorted, 1 trap, W 66, V 6 | "magic scoop" analogy x6; claimed "Saved to /tmp/..." with no file |
| candidate (Grace) | 8/10, 1 trap, W 271 | 7/10 +1 distorted, 1 trap, W 305 | assumption line both runs; promised a graphic, produced none |

### Fixture A, batch 3 (uniform inline-HTML harness note, all arms; one judge)

| Arm | Run 1 | Run 2 | R2 toddler | Cost/run |
|---|---|---|---|---|
| bare | 10/10, 1 trap, W 388 | 8/10, 0 traps, W 334 | 0 | $0.01-0.02 |
| incumbent /eli5 | 8/10, 0 traps, V 6 | 7/10 +1 distorted, 1 trap, V 8 | 4 (toy-box theme) | $0.04-0.05 |
| candidate (Grace) | 6/10 +1 distorted, 1 trap, W 311, V 5 | 7/10 +1 distorted, 0 traps, W 300, V 5 | 0 | $0.18-0.33 (18k-32k output tokens) |
| hybrid (final text + assumption line) | 10/10, 0 traps, W 38, V 8 | 10/10, 0 traps, W 57, V 4 | 0 | $0.10-0.14 |

Grace's run 1 invented a ranking mechanism ("ranked by traffic across every page in the
site") the source never states. Both Grace runs and incumbent run 2 softened "read as zero"
to "almost zero". Only the incumbent used toddler analogies. No arm invented a row-limit
number or a "now fixed" framing. Nobody falsely claimed a saved file under the note; hybrid
run 2 said outright that nothing was written to disk.

### Fixture A, batch 4 (the landed `/eli5` text, assumption line removed, n=3, one judge)

| Run | Facts | Distorted | Traps | R2 | W | V | Save claim |
|---|---|---|---|---|---|---|---|
| 1 | 10/10 | 0 | 0 | 0 | 23 | 6 SVGs / 3 panels | no (explicit disclaimer) |
| 2 | 10/10 | 0 | 0 | 0 | 0 | 5 panels | no |
| 3 | 10/10 | 0 | 0 | 0 | 0 | 7 | no |

Mean 10.0/10 versus the incumbent's 7.5 (batch 3) and Grace's 6.5; impressions never
relabelled; every date, flag and number kept in panel captions. The landed text differs from
the measured hybrid by the removed assumption line and one appended tool-use sentence about
`open` (added on code review; not exercisable under `--tools ""`).

### Fixture B (compact code explanation; rewritten module; one judge, one standard)

The judge's standard, stated before scoring: an edge is PRESENT only when the output states
the behavior or annotates it in the diagram; a bare function name in a tree does not
establish what it does, whether it is awaited, or how a branch routes; an annotation on one
line does not transfer to its neighbours.

| Arm | Run 1 | Run 2 | Mean /14 | Forms |
|---|---|---|---|---|
| bare | 10/14, 0 traps, W 289 | 11/14, 0 traps, W 310 | 10.5 | prose / numbered list |
| show-me (upstream) | 7/14, 0 traps, W 102 | 9/14, 0 traps, W 69 | 8.0 | call tree (+ diff in run 2) |
| show-me (adapted) | 9/14, 0 traps, W 134 | 8/14, 0 traps, W 70 | 8.5 | call tree + diff |

show-me is 3-4x terser than the bare model and invented nothing in any run, at a cost of
about 2 of 14 facts. The loss is systematic and the same in upstream and adapted: E1 (what
`normalizeLabel` does — all four show-me runs list the name, none describe the rewrite) and
E9 (which callback handles success versus failure — all four use an unlabelled `X | Y`
pipe). Both bare runs state both. Read that as: ask `/show-me` for the shape, ask prose for
what each function does. The three terminal adaptations leave the form intact (0 Mermaid,
0 `open`, same forms, same score band).

## Key ambiguity worth knowing

F8: the source says "query rows totalling 22". One judge read 22 as impressions and marked
"22 rows" DISTORTED; the answer key now accepts either reading. The sentence in CLAUDE.md is
ambiguous on its own; whoever measured it on 2026-08-05 should make it one thing.

## To rerun

Export Grace's doc (`.../export?format=txt`) to `$GRACE`, shallow-clone humanlayer/skills
@ 3c2629142c5d437428269b1b722b08c0b87f574d to `$HL`, pick a fresh `$OUT`, then
`bash run-arms.sh` (or `ARMS="B-bare B-showme-upstream B-showme-adapted" bash run-arms.sh`).
Judge every `*.md` in `$OUT` against `answer-key.md` with a model that never saw `*.txt`,
one judge per comparison. About $1.50 for the full grid at n=2; Grace's arm is the expensive
one. `run-arms.sh` and `unwrap.py` follow the same pattern as
`../jakubkrehel-skills/run-arms.sh`; a shared runner was not factored out in this PR. The
acceptance check is shared (`../check-arms.py`, dotfiles#1690): the run is accepted only
when every invocation exited 0 with `is_error` false and a non-empty result, else it exits 1
before the results summary.
