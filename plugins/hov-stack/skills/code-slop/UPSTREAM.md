# Upstream provenance

Frozen snapshot of https://github.com/AsyrafHussin/agent-skills — directory
`skills/code-slop/` (SKILL.md, rules/*.md, metadata.json) at commit
1aa0ff717c10309226c9e678f00873976450fd76 (2026-08-27, MIT license, author Asyraf Hussin;
skill metadata dated 2026-05-17, version 1.0.0), vendored 2026-09-02 per the harness-vet
landed as dotfiles PR #893 (issue #892; eval note: memory `anti-slop-skill-list-vet-2026-09`).
Repo LICENSE copied verbatim beside this file.

path: skills/code-slop
sha256 of upstream SKILL.md: d8cb86c721eb474a9eeb650543339e6a6696166ebf9db2c91456837adca7d17a

Local changes (SKILL.md, plus sample data in two rules; the other rules/ files and
metadata.json are byte-identical):
- `rules/test-doesnt-throw.md` and `rules/test-mock-everything.md`: the sample email
  addresses in the code examples are `example.com` addresses here, so this repository's
  public-safety scan passes. A re-pull brings upstream's addresses back.
- `disable-model-invocation: true` added to the frontmatter — invoke-only, like every other
  third-party drop here. Upstream's description asks to trigger on "review for AI slop" and
  similar phrases; that auto-fire is deliberately off.
- A two-line local note after the frontmatter: `style-no-hack-scars` and
  `style-hyper-consistent` are provenance heuristics ("does this repo look human-written"),
  not quality defects; an agent here must never add fake HACK markers or formatting drift
  to satisfy them, and must not report their absence as a finding on a diff.

Why it is here: measured on an 18-defect TypeScript fixture (2026-09-02, Sonnet arms, 2
trials each) the skill scored 15.25/18 with 0 false accusations against
thermo-nuclear-code-quality-review's 13.0 with 0.5 — and the two are complementary, not
nested: code-slop caught type-in-name, mirror-implementation tests, and snapshot-instead-of-
assertion in both trials where thermo-nuclear caught neither; thermo-nuclear caught parallel
if/else-if mode chains in both trials where code-slop caught neither. Run both on a
suspicious diff. Fixture and scoring: `harness/vet-fixtures/anti-slop-list/`.

Deliberately NOT ported: the sibling `technical-debt` skill (quantitative metrics; the
isomorphic-refactor skills already wire radon/lizard/gocyclo), `AGENTS.md` (repo-level
reference duplicate of SKILL.md), and the other 23 skills in the pack (mostly Laravel/PHP).
Not in `codex-skills.txt`; add deliberately if Codex needs it.

Deliberately NOT auto-tracked. Re-pull manually:

    gh api 'repos/AsyrafHussin/agent-skills/contents/skills/code-slop/SKILL.md?ref=HEAD' --jq .content | base64 -d > /tmp/cs-upstream.md
    sha256sum /tmp/cs-upstream.md
    diff /tmp/cs-upstream.md plugins/hov-stack/skills/code-slop/SKILL.md

If the rules changed, re-run the code fixture (bare / thermo-nuclear / code-slop arms, 18
defects, 8 controls) before re-vendoring, and re-check overlap against
`thermo-nuclear-code-quality-review/SKILL.md` and compound-engineering's
`maintainability-reviewer.md`. Remove this drop if either of those gains the three
test-slop and naming classes above with measured recall.
