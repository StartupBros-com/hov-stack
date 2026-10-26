# Upstream provenance

Source: https://github.com/anthropics/claude-plugins-community
path: eli5/skills/eli5/SKILL.md
Pinned at commit f4c9452f5ca091f1be7064d9faab1b001ea21645 (2026-08-21).

Base text: the three-line `/eli5` skill by Thariq Shihipar (trq212, Anthropic), announced
2026-08-21 (x.com/trq212/status/2090884854590382515) and shipped in
anthropics/claude-plugins-community `eli5/skills/eli5/SKILL.md` at that commit. Vendored byte-verbatim with one added demotion line on 2026-08-21 (dotfiles
PR #440, memory note eli5-skill-vet-2026-08); the demotion line moved to a `name-only`
skillOverrides entry on 2026-08-29 (PR #633). Upstream's sentence "Explain like I'm someone
who knows nothing about this topic, using a HTML artifact with big pictures and few words."
and the `Topic: $ARGUMENTS` line are unchanged.

## 2026-09-02 changes (dotfiles PR #898, issue #897, memory note explainer-toolbox-vet-2026-09)

Sources: Grace Clarke's "eli5-for-grownups" SKILL.md (x.com/graceclarke/status/2091999661565325497,
Google Doc `SKILL-eli5-for-grownups-2026-08-23`, published 2026-08-24 with "Should you like, here
it is"; no license declared, so her text is paraphrased), the `/bro` skill
(https://github.com/luchasarie/bro-skill `SKILL.md` at 01e51f8092973be58eff3b7271282bd8488a02ae,
MIT, "Copyright (c) 2026 Hermes Agent + Luka"), and harness-authored lines.

- Description line: rewritten locally. Upstream's "Explain a topic like I'm a 5 year old" promised
  the framing the new body forbids (inward conflict review, 2026-09-02). The `/eli5 <topic>` trigger
  clause is kept.
- Paragraph "Knows nothing covers this one topic only ...": paraphrase of her "Who '5' is" section
  and her "Banned, every time" list. Her three example analogies and two banned phrases were
  quoted here until 2026-10-22, when they were dropped because her text carries no licence; the
  rule stays in harness words.
- Paragraph "Facts survive verbatim ...": the rule and its category list (path, command, filename,
  number, URL, name, decision) are `/bro` rule 3. Harness-authored additions: "even when that costs
  the few-words goal: trim prose, never facts" (precedence, from the conflict review), "date, flag
  and rule", "inside panel titles and captions too", and "nothing is invented to fill a gap: no
  unstated limits, no 'now fixed'" (the traps the 2026-08 and 2026-09 fixtures sprang).
- Paragraph "This is a terminal, not a chat panel ...": harness-authored. Upstream assumes a
  claude.ai artifact panel; on this host previous `/eli5` runs left files in `~`,
  `~/discord-exports/` and `~/reports/`, so a landing path is named. PR #898 first pointed it
  at `~/reports/` with `wsl-cdp open` as the viewer; PR #928 (dotfiles #908, 2026-09-03)
  replaced that with the harness-wide rule: `.claude/deliverables/eli5/` in the repo being
  worked in, shown by `open-deliverable` (`harness/deliverable-locations.md`). These
  are tool-use instructions the no-tools fixture cannot exercise; the measured content rules
  are unchanged.

Tested and dropped: her "state your assumption" opening line ("Assuming you know X but not Y —
tell me if I'm off"). It was in the measured hybrid text (fixture in
`harness/vet-fixtures/explainer-toolbox-2026-09/`), then cut on the inward review: it is
preamble under the harness's response-shape rule and the lowest behavior change per token of the
four additions. Also tested and dropped: her "keep the real jargon and define it in a few words at
the moment it appears" clause (invites caption bloat against the few-words form).

Not ported: her Move 1 chat-first walkthrough (orient / core line / numbered steps / closing
truth), the comic-strip panel rules, the aesthetic block, the follow-up mode, and the "when to
skip the graphic" caveats. The vet measured her full skill at ~1,900 words producing ~300-word
prose answers plus a six-panel strip at up to 32k output tokens a run; the picture-first form is
what `/eli5` is for, and `/bro` already covers fact-preserving prose.

## Licences

- `LICENSE` is the Apache License 2.0 from the root of anthropics/claude-plugins-community at
  the pinned commit, byte-for-byte; that repository has no `NOTICE` file at the pin. The upstream
  plugin's own `plugin.json` declares MIT; this copy follows the repository licence, the stricter
  of the two.
- Modification notice (Apache-2.0 section 4(b)): this `SKILL.md` is a modified version of the
  upstream file. The description line is rewritten, and the three paragraphs that follow the
  upstream sentence ("Knows nothing ...", "Facts survive verbatim ...", "This is a terminal ...")
  are added, as recorded above. Its first frontmatter line is a comment that names the
  upstream file and points here.
- `LICENSE-bro-skill` is the MIT licence of luchasarie/bro-skill at the pin above, byte-for-byte,
  for the rule that "Facts survive verbatim ..." rewords from `/bro`.
