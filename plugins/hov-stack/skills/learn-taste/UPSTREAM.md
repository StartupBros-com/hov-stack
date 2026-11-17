# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit 64eb3deb9a5fbfa041faf783e0bc3fd635872e9c, MIT license),
path: skills/learn-taste
vendored 2026-11-16 per the harness-vet in `docs/vets/2026-11-16-learn-taste-harness-vet.md`
(hov-stack#683). The skill last changed upstream in 0f2e23b32bb1265e84cff8d3e75785fec953fb1b.
Deliberately NOT auto-tracked: re-pull manually and re-run the fixture if wanted.

Local changes: none. `SKILL.md` is byte-identical to the pin (sha256
`d624b8cd475eec24c5dc3f49b0380b56c8dab8399df11b92d7c9685aa8d4d33e`), and upstream
already sets `disable-model-invocation: true`. `LICENSE` is the upstream repo's.
In the pack, members run it as `/hov-stack:learn-taste`.
It is not in `codex-skills.txt`: it reads Claude Code transcripts.

What the vet measured. The fixture is `harness/vet-fixtures/learn-taste-2026-11/`. It uses
synthetic sessions, 3 runs per arm and one model.

- On the ask "turn the design corrections from my last session into rules", learn-taste
  scored a median 7 of 8 correct.
- The ask alone scored 5, and 6 on one judge's lenient reading of a single item. Under
  that reading the rule gives SKIP.
- `craftwork-design/retro` scored 5 and `ce-retro` 3.
- Two external contenders scored 6: `claude-reflect` and nvie's `self-review`. That is
  within the fixture's tie band of 1, so learn-taste is not shown to beat them.
- Every learn-taste run proposed before it wrote, invented no rules and gave no made-up
  reasons.
- Against the ask alone, the lead is mostly one behaviour. When a rule already exists and
  the agent broke it anyway, learn-taste rewrites it stricter or adds a check (3 of 3
  runs, against 0 of 3).
- It found a correction the user made only by editing a file in 2 of 6 runs. No other arm
  found it in 21 runs.
- Asked to read every project, it labels a rule from another project by its source rather
  than applying it here (3 of 3).

Destination. In a repo where design-rails has run, it writes the rules into the wired
`design/DESIGN.md` (6 of 6 runs) and keeps its front matter valid. A later
`design-rails propose --out=design` run overwrites that file and drops them: hov-stack#685.
