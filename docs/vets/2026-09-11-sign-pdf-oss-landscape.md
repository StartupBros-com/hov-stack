# OSS landscape check before publishing sign-pdf

- Date: 2026-09-11. Question from the operator: is `sign-pdf` (dotfiles `skills-local/sign-pdf`, PR #1120) useful and unique enough to open-source and list on the HoV marketplace?
- Method: five parallel search angles (GitHub repos and code search, agent registries including smithery.ai and skills.sh, npm/PyPI/crates.io/pkg.go.dev, open-source e-sign platforms and GUI signers, prior art for signature-line detection), about 100 queries, deduplicated, then eight deep reads that cloned and ran the closest matches against our own fixture (`test-agreement.pdf`, two pages, "Party A: ____ Date: ____" and "Party B: ____ Date: ____" on page 2). Coverage gap: `exa-cli` and Firecrawl search were out of credits for the whole run, so general web coverage came from GitHub, registry APIs and README fetches only.

## Answer

**Useful: yes. Unique as an idea: no. Unique as a property set: yes, narrowly.** The job "agent stamps my signature on the right line" has been built at least four times in the agent ecosystem and the underscore-run-after-a-label heuristic has been reinvented in six or more repos. What no installable tool in the set does is all of the following at once, each verified by running the competitor: refuse rather than guess when the slot is missing or ambiguous, detect at word level so a label and its blank in one text run still resolve, store the operator's signature with restrictive file modes, stamp the date automatically, render a preview for the agent to check, and seal, with an MIT-only dependency tree.

## Closest competitors (executed, not just read)

| Tool | What it is | On our fixture | Fail-closed | Seal | Scanned PDFs | Deps and license | Signal |
|---|---|---|---|---|---|---|---|
| [Open-Document-Alliance/PDF-Tools](https://github.com/Open-Document-Alliance/PDF-Tools) @ 91b969d | 57-tool MCP server for Claude Desktop and Cursor; 12 signing tools; saved signatures as plaintext JSON under `~/.pdf-toolkit-files` | Driven headlessly over stdio JSON-RPC: `detect_signature_zones` returned one zone mis-anchored to the "Signatures" heading on a page with three signable lines and `apply_signature` stamped it there without warning; date only if the caller passes the text | No: zero zones is `isError:false` with a hint | No | No (README: OCR planned) | pdf-lib, pdfjs-dist, native canvas; MIT | 153 stars, active (pushed 2026-09-07), 138 test files |
| [DrBaher/sign-cli](https://github.com/DrBaher/sign-cli) @ df6fe27 (npm 0.9.0) | Agent-first contract-ops CLI plus 19-tool MCP and 20-route HTTP API; AcroForm and anchor-text detection; from-scratch offline PAdES; hash-chained audit | `detect-signature-field`: 0 candidates, exit 2, because the anchor regex needs the label to be its own text item; worked once label and blank were split into separate draws, then stamped and sealed correctly | Yes, documented exit codes | Yes | No | 27k LOC, MIT | 0 stars, last push 2026-07-13, 801 tests pass |
| [dwmkerr/claude-toolkit pdf-sign](https://github.com/dwmkerr/claude-toolkit) @ 4316684 | A 104-line SKILL.md recipe: agent creates a venv, installs pymupdf, writes ad hoc code with `page.search_for(label)`; asks for the signature path every time | Recipe works when the agent writes it well; `find()` returns the first match on duplicates (our three "Date:" hits needed a manual y-filter) and raises on no match | No scripts, no exit codes | No | Yes: tesseract OCR fallback verified on a rasterized copy | pymupdf (AGPL-3.0, unflagged) | 23 stars (whole toolkit); zero tests for this skill; excluded from its own CI |
| [huyang218/dsh-plugins seal](https://github.com/huyang218/dsh-plugins/tree/main/packages/seal) @ 57df058 | Same three-stage pipeline (locate via `pdftotext -bbox`, stamp, PAdES via a self-issued PKCS#12) for Chinese company seals, bound to the dsh agent runtime | Locates by a weighted marker table; zero candidates falls back to the bottom-right corner with a note; no date | No | Yes | No | MIT | 1 star, one five-day burst in 2026-08; 82 tests pass |

Partial and adjacent, read but not run: svenssonaxel/pdf-sign (162 stars, click-to-place GUI), open-pdf-sign (949 stars, crypto plus image at given coordinates), JSignPdf (471 stars), Stirling-PDF (91k stars, web "Sign" tool), pdfile and PyPI `signpdf` (image at manual coordinates), `@signpdf/signpdf` and digitorus/pdfsign (crypto only), e-sign SaaS MCPs (eSignatures.com, PandaDoc, Formify, zsign, signsimple, staffSign), Anthropic's `signature-request` skill (routes to an integration), documenso-pack skills, Documenso/DocuSeal/OpenSign/LibreSign (platforms). Line-detection prior art with the same underscore-run idea: intelogroup/clixen, vinaypat27/Legalyze, adlerazevedo/pdf-laboratory, Ravonus/proofmark, Thoxie/Small-Claims-Genie, elyxlz/vesta, antoine-levitt/perso.

Ethics flag: daymade/claude-code-skills (1,388 stars) ships a pipeline that synthesizes a handwriting-style signature and scan artifacts to make an unsigned document look hand-signed. sign-pdf's never-fabricate rule is a deliberate opposite and should stay visible in its README.

## What to borrow before publishing

1. AcroForm `/Sig` widget detection as a confidence-1.0 source ahead of the text heuristic (sign-cli `signature-field-detection.ts:143-186`; PDF-Tools `helpers.js:1471`). pdf-lib can read form fields, so this is small.
2. An OCR fallback for scanned PDFs, implemented with tesseract mapped back into pdf-lib coordinates, never pymupdf (verified working in dwmkerr's recipe; the one capability we lack that a real inbound contract may need).
3. A legal-claims lint in CI that fails the build on unqualified phrases like "legally binding" (sign-cli `scripts/lint-legal-claims.mjs`).
4. Machine-readable geometry warnings beside the preview: stamp outsized versus median text height, overlaps text, crosses page edge (sign-cli `stamp-quality.ts`; dsh `geometry.js:106-113`).
5. Below-label placement for the European convention where the label sits alone on its line and the signature goes under it (sign-cli's below-anchor probe).
6. A regression test asserting two same-label slots on one page both surface (clixen collapsed them).

## Naming

"sign-pdf" is crowded: GitHub name search returns eight cryptographic signers, and the npm name was published and fully unpublished in 2021, which npm treats as permanently retired. `sign-that` is free on npm and has no GitHub collision, and it is the trigger phrase. `sign-line`, `sign-here`, `autosign-pdf` are free on npm but noisier on GitHub.

## Recommendation (ranked)

1. **Publish under `sign-that`, positioned narrowly** as the fail-closed Claude Code skill for signing your own PDFs, with the comparison table above in the README crediting PDF-Tools, sign-cli and dwmkerr's recipe, after items 1 and 2 above are closed and one real inbound contract has been signed with it.
2. Contribute fail-closed ambiguity handling and the word-level detector upstream to Open-Document-Alliance/PDF-Tools (active, MIT) and keep ours private. Good citizenship, no catalog cost, but their MCP shape is not what a Claude Code user installing from the HoV marketplace wants.
3. Keep it private in dotfiles. Zero cost, forgoes the customer value the marketplace exists for.

Catalog cost reminder from hov-marketplace's release recipe: every added skill description eats Codex's skills context budget; keep the roster description lean.

---

Outcome: the skill shipped as sign-it (renamed from sign-pdf) and is published to the HoV marketplace; see the Outcome section of `2026-09-11-documenso-harness-vet.md`.
