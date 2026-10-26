# Upstream provenance

Frozen snapshot of https://github.com/cursor/plugins — file
`thermos/skills/thermo-nuclear-code-quality-review/SKILL.md` at commit
5102244dabd626b101cff40accbe7f7d1eeefa15 (2026-05-27, MIT license, author Cursor /
Eric Zakariasson; skill first published 2026-05-21 in commit 909bc5d), vendored
2026-09-01 per the harness-vet landed as dotfiles PR #825 (eval note: memory
`thermo-nuclear-code-quality-review-vet-2026-09`).

sha256 of SKILL.md: 7faca08b51b643b2ddd0836f92af15574444024685dcc1e677dbbb39ae8c9e8f

Local changes: none. Upstream already sets `disable-model-invocation: true`, so the
file is byte-identical and invoke-only. An identical copy also lives upstream at
`cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md`.

Deliberately NOT ported: the sibling `thermo-nuclear-review` skill (covered by
ce-code-review's correctness + previous-comments personas), the `thermos` orchestrator
and both `agents/*.md` files (Cursor `Task`/`shell`/`explore` vocabulary; not valid
here), and the plugin manifest (`.cursor-plugin/` is not a Claude Code marketplace).
Not in `codex-skills.txt`; add deliberately if Codex needs it.

Deliberately NOT auto-tracked. Re-pull manually:

    gh api 'repos/cursor/plugins/contents/thermos/skills/thermo-nuclear-code-quality-review/SKILL.md?ref=HEAD' --jq .content | base64 -d > /tmp/tn-upstream.md
    sha256sum /tmp/tn-upstream.md plugins/hov-stack/skills/thermo-nuclear-code-quality-review/SKILL.md
    diff /tmp/tn-upstream.md plugins/hov-stack/skills/thermo-nuclear-code-quality-review/SKILL.md

If the rules changed, re-run the vet's planted-defect fixture (8 arms, 6 defects,
4 honest controls) before re-vendoring, and re-check overlap against
compound-engineering's `maintainability-reviewer.md`, which was derived from this
skill (CE PR #854). Remove this drop if ce-code-review ever gains a single-lens or
persona-select argument — then the persona is the canonical home and this copy is
the duplicate.
