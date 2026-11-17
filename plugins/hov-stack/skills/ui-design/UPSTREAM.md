# Provenance

House-written for hov-stack (2026-11-17, hov-stack#683), under the root `LICENSE`, except
two sentences under **Building from a design**, which are quoted from
https://github.com/jakubkrehel/skills `skills/build-design/SKILL.md` at commit
6c2120103600407a1a9986afd834e73144ef8998 (MIT, Jakub Krehel; `LICENSE-jakubkrehel` is that
repo's licence):

- "A screenshot or exported image has no values to read. Sizes are ratios to the capture, so
  state the scale you assumed and treat every measurement as an estimate." (upstream line 18,
  verbatim; its third sentence, "Ask for the Figma link when one exists", became "say in the
  reply that the Figma file, if there is one, would replace every estimate", so the build is
  not held up by a question).
- "From an image they are estimates at the scale you stated." (upstream line 22, verbatim).

Those lines are the port that the build-design vet's EXTRACT verdict named
(`docs/vets/2026-11-17-build-design-harness-vet.md`, section 4). They produced its only gain:
replies called image-read values estimates in 8 of 8 runs against the pack's 1 of 8. The
sentence after them ("matches" and "exact" are for values read from a Figma file; say the build
was not compared unless both were rendered) is house-written, against that vet's R5 finding:
model-invoked build-design labelled planted values "Matches" when the build differed.

**Why this skill is model-invoked.** Every design skill in the pack is slash-only, so a plain
"build this design" or "review this page" request loaded none of them (16 of 16 runs in the
build-design vet). The operator approved one model-invoked entry point on 2026-11-17, as an
exception to the pack's invoke-only route for vendored snapshots. This skill holds no
third-party rules beyond the two sentences above: it reads the slash-only skills by path, as
`interface-review` §7 already does, and those skills keep `disable-model-invocation: true`.

The fixture and its result: `harness/vet-fixtures/ui-design-2026-11/` and
`docs/vets/2026-11-17-ui-design-entry.md`.
