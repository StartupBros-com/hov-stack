# Answer key — fixture v2 (judge only; never shown to arms)

v2 (2026-09-01) rewrote every item the utility lens found textually seeded from the
candidate's own counter-examples (D7, D8, D9, D10, D11, D13, D14, D15, D18, C1, plus the
reused version number 4.1.7 ← 2.3.1 and the README self-narration phrases). Three
inconsistencies that arms found in v1 without being planted are now planted on purpose
(D19-D21). Controls C1, C6, C7 were reworded to remove the ambiguity three v1 arms found.

## Planted defects (21)

| # | Location | Defect | ux-writing rule it maps to | Also in incumbents? |
|---|----------|--------|----------------------------|---------------------|
| D1 | README.md:14 | "The current release is 4.1.7" — version snapshot in a long-lived page | Never snapshot a value that moves faster than the doc | readme-writing: partial ("Outdated badges" row) |
| D2 | README.md:24-32 + docs/config.md:15-23 (+ README:34) | Allowed-keys table duplicated verbatim in two docs, then "The complete reference is docs/config.md" | One canonical home per fact; restating-and-linking is a bug | readme-writing: partial (lean README links to docs) |
| D3 | README.md:5-10 | "What makes it different" positioning section is a feature list | Every README section has one job | readme-writing: partial |
| D4 | README.md:36-39 | "performs noticeably better and is more robust" — no evidence | Adjectives need evidence | readme-writing:55 (full: "Claims get a number or an example, or they get cut"); de-slopify: partial |
| D5 | README.md:45-49 | "Notes on this document" — the README narrates its own structure and maintenance plans | A deliverable does not narrate its own production | de-slopify: partial (meta-commentary) |
| D6 | docs/config.md:6-11 | "Why TOML" design rationale inside the reference page | Rationale is a genre of its own | none |
| D7 | docs/runbook.md:3-12 | "As of this writing ... serve build 4.1.7 ... running container is registry.example.net/lumen:4.1.7-b2291" + hand-maintained fleet table | A doc cannot observe the runtime; never snapshot | none |
| D8 | docs/runbook.md:23-26 | "somewhere under the transport package; grep for it" — pointer to a package, not a symbol | A pointer names a symbol, not a repository | none |
| D9 | cli.py:7-8 (and :11) | status reads file layers only; "Credential: missing" while an env var would be used; per-key value can disagree with its [source] | Report effective values, not stored ones | cli-agent-ergonomics: partial (truthful output) |
| D10 | cli.py:12-14 | `--porcelain` JSON gains a trailing "  # source: files" annotation | Machine-readable output is a contract | cli-agent-ergonomics: YES (parseable deterministic output) |
| D11 | cli.py:19-20 | doctor prints "[origin] key" for every allowed key instead of the deviations | Show deltas, not dumps | cli-doctor-mode: partial |
| D12 | cli.py:21-23 | project path truncated to 40 chars with "..." | Never truncate the payload | cli-agent-ergonomics: partial |
| D13 | cli.py:24 | "Endpoint override: unset (unset)" — value and annotation collide | Re-read neighboring labels after adding metadata | none |
| D14 | cli.py:5 and :50 | docstring + `--help` still say "print the merged settings" after status learned sources (doctor's help at :53 was updated) | Sync sweep: `--help` is the most-missed site | none explicit |
| D15 | cli.py:33-38 | six-line comment recounting discarded memoization attempts and a review decision | A comment carries the non-obvious reason only | none |
| D16 | cli.py:43-45 | `# increment the counter` restates the code | Comment carries non-obvious reason only | generic |
| D17 | messages.py:1-2 | "Unknown key." names nothing (config.md:25 promises file+line); LOAD_FAILED silently degrades to defaults | Error answers what/where/what-now; diagnostics truthful under failure | cli-agent-ergonomics: YES (errors that teach) |
| D18 | PR title | "— leaves out the --explain flag for now" — negative scope from the conversation in the title | State what the code does, not what it nearly did | none |
| D19 | README.md:8 vs docs/config.md:9-10 | README claims JSON support; config.md says JSON was rejected | Facts agree across surfaces / one canonical home | readme-writing: partial (accuracy) |
| D20 | README.md:9 vs cli.py:54 | README claims "exports to .env files"; export writes KEY=VALUE lines to stdout | Sync sweep: README vs help text | none explicit |
| D21 | cli.py:12 | `if args.porcelain` is a sibling of the human-readable prints, so porcelain output still carries lines 8-11 ahead of the JSON | Machine-readable output is a contract | cli-agent-ergonomics: YES |

(21 planted. D2 counts once even if both files cited. D9 counts once for :8 and :11. D10 and D21 are distinct: annotation vs preceding human lines.)

## Honest controls (must NOT be flagged; each flag = false accusation)

| # | Location | Why it is fine |
|---|----------|----------------|
| C1 | cli.py:28-29 | "Hand-rolled KEY=VALUE lines rather than json.dumps: lumen-api ingests this as an env file and its parser accepts nothing else" — a why-not naming a real external constraint. |
| C2 | CHANGELOG.md:5-6 | Version number + date in a changelog — the right home for a dated fact. |
| C3 | README.md:41-43 | "MIT. See LICENSE." — stable fact, single pointer. |
| C4 | cli.py:53-54 | doctor/export help strings accurately describe post-PR behavior. |
| C5 | docs/config.md:25 | Accurate contract statement; messages.py is what fails to honor it (flagging messages.py = D17 hit; flagging config.md:25 as the defect is the wrong location but not a false accusation if the mismatch is the stated problem). |
| C6 | messages.py:3 | ROTATE_HINT names the variable and the condition explicitly. |
| C7 | docs/runbook.md:14-21 | Rotation procedure names the command and the observable (`api_key` line shows `[env]`), not the answer. |
| C8 | PR body | Lists the test command and result; follow-up tracked by issue number. |

## Scoring
- Hit: arm names the location (file + line or clear description) AND the right problem.
- Partial: right location, wrong/vague reason — half credit.
- False accusation: any control flagged as a defect, or an invented defect (something not in the bundle).
- Report per arm: hits / 21, partials, false accusations, and which defects were missed.
