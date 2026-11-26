# Vendor vet: markdown-it 15.0.3 for `open-deliverable`

- Date: 2026-11-25. Scope: one file, `lib/vendor/markdown-it/markdown-it.umd.min.js`, used only by `lib/deliverable-render.js`.
- Verdict: **ADOPT, vendored and pinned.** Provenance and hashes: `lib/vendor/markdown-it/UPSTREAM.md`.

## Why a vendored parser

`open-deliverable` renders a Markdown report to a page before the browser opens it. The renderer has to be the same on every host and testable in CI. `./setup` requires node and installs no packages; CI has node 22 and no pandoc and no Python Markdown library. Checked alternatives:

| Option | Why not |
|---|---|
| pandoc | Not on CI, not on a stock macOS; output differs by version |
| Python `markdown` / `markdown-it-py` | Present on the workstation only; not installed by `./setup` or CI |
| A browser-side renderer (script in the page) | The page would need script execution; reports quote web content, so the page allows none |
| `franken_markdown` | Its licence carries a rider that grants no rights to Anthropic or anyone acting for its benefit, and counts an "evaluation harness, or pipeline for … automated systems" as use; not usable in a public Claude Code harness (legal reach not tested, treated as a stop) |
| A hand-written parser | Tables, nested lists, link reference definitions and autolinks are where hand-written Markdown parsers go wrong |

## What was checked

1. **Identity.** The npm tarball was downloaded once and its sha512 matched the registry's `dist.integrity` before anything was unpacked. The vendored file is `dist/browser/markdown-it.umd.min.js`, byte-verbatim (100,786 bytes).
2. **What the bundle can reach.** A literal search of the bundle found 0 occurrences each of `require(`, `import(`, `fetch(`, `XMLHttpRequest`, `WebSocket`, `process.`, `child_process`, `eval(`, `new Function`, `document.` and `localStorage`. It is a pure text-to-text library; file and network access live only in `lib/deliverable-render.js`, which reads the source and the stylesheet and writes one output file.
3. **Licences.** markdown-it is MIT. The bundle inlines entities (BSD-2-Clause), linkify-it, mdurl, punycode.js and uc.micro (MIT); their licence texts are in `lib/vendor/markdown-it/licenses/`.
4. **Untrusted input.** The renderer sets `html: false`. A report containing `<script>document.title="pwned"</script>` and a remote image was opened in Chrome 158 from a `file://wsl.localhost/` URL: the title was unchanged, `document.scripts.length` was 0, the remote image did not load (`naturalWidth` 0) and a local image beside the source did (`naturalWidth` 10). markdown-it's own link validator refuses `javascript:`, `vbscript:` and non-image `data:` links.
5. **Drift.** `tests/open-deliverable.test.sh` compares the file's sha256 with the one recorded in `UPSTREAM.md`, so a replaced bundle fails until the record is edited in the same change.

## Not checked

- macOS and a Linux desktop: the rendered page was opened on WSL only.
- Firefox and Safari handling of the page's `img-src file:` policy.
- The parser's behaviour on adversarially large or deeply nested input (markdown-it caps nesting at 100 by default; not measured here).

## Re-vet when

A new markdown-it major is adopted, the renderer starts passing `html: true`, or the page gains a script.
