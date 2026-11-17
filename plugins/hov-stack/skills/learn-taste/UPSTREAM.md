# Upstream provenance

Frozen snapshot of https://github.com/emilkowalski/skills (commit 64eb3deb9a5fbfa041faf783e0bc3fd635872e9c, MIT license),
path: skills/learn-taste
vendored 2026-11-16 per the harness-vet in `docs/vets/2026-11-16-learn-taste-harness-vet.md`
(hov-stack#683). The skill last changed upstream in 0f2e23b32bb1265e84cff8d3e75785fec953fb1b.
Deliberately NOT auto-tracked: re-pull manually and re-run the fixture if wanted.

Local changes: none. `SKILL.md` is byte-identical to the pin (sha256
`d624b8cd475eec24c5dc3f49b0380b56c8dab8399df11b92d7c9685aa8d4d33e`), and upstream
already sets `disable-model-invocation: true`. `LICENSE` is the upstream repo's.
It is not in `codex-skills.txt`: it reads Claude Code transcripts.

What the vet measured. The fixture is `harness/vet-fixtures/learn-taste-2026-11/`: synthetic
sessions, 3 runs per arm, one model. On the ask "turn the design corrections from my last
session into rules", it scored a median 7 of 8 correct. The ask alone scored 5 (6 on one
judge's reading of a single item), and the best incumbent, `craftwork-design/retro`, also 5. Every run proposed before it wrote, invented no
rules and gave no made-up reasons. The lead is mostly one behaviour: when a rule already
exists and the agent broke it anyway, learn-taste rewrites it stricter or adds a check,
where the ask alone restates it (6 of 6 runs against 0 of 6). It found a correction the
user made only by editing a file in 2 of 6 runs.

Destination. In a repo where design-rails has run, it writes the rules into the wired
`design/DESIGN.md` (6 of 6 runs) and keeps its front matter valid. A later
`design-rails propose --out=design` run overwrites that file and drops them: hov-stack#685.
