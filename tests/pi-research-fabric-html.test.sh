#!/usr/bin/env bash
# Tests htmlToText in pi's research-fabric extension, the text a direct WebFetch
# hands the model. The extension imports pi packages this repo does not install, so
# the test cuts the helper out of the real source, strips its types with Node's own
# stripper, and imports that.
#
# The bug: script and style bodies survived when the end tag carried a space
# (`</script >`) or when nested tags rebuilt an opener (`<scr<script></script>ipt>`),
# so page script text reached the model. CodeQL alerts 16, 18 and 19.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$ROOT/harnesses/pi/agent/optional-extensions/research-fabric.ts
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

node --no-warnings --input-type=module - "$SRC" "$TMP" <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [src, tmp] = process.argv.slice(2);
const text = readFileSync(src, "utf8");
const start = text.indexOf("const HIDDEN_BLOCKS");
const fn = text.indexOf("export function htmlToText", start);
const end = text.indexOf("\n}\n", fn);
if (start < 0 || fn < 0 || end < 0) {
  console.error(`FAIL: htmlToText or HIDDEN_BLOCKS not found in ${src}`);
  process.exit(1);
}
const out = join(tmp, "html-to-text.mjs");
writeFileSync(out, stripTypeScriptTypes(text.slice(start, end + 3)));
const { htmlToText } = await import(pathToFileURL(out).href);

let pass = 0, fail = 0;
const eq = (name, input, want) => {
  const got = htmlToText(input);
  if (got === want) pass++;
  else { fail++; console.error(`FAIL: ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }
};

eq("plain end tag", "a<script>evil()</script>b", "ab");
eq("end tag with a space", "a<script>evil()</script >b", "ab");
eq("end tag with a newline", "a<script>evil()</script\n>b", "ab");
eq("end tag with an attribute", "a<script>evil()</script foo=1>b", "ab");
eq("uppercase", "a<SCRIPT>evil()</SCRIPT>b", "ab");
eq("nested script opener", "a<scr<script></script>ipt>evil()</script>b", "ab");
eq("nested style opener", "a<sty<style></style>le>x{}</style>b", "ab");
eq("style end tag with a space", "a<style>x{}</style >b", "ab");
eq("noscript", "a<noscript>enable js</noscript >b", "ab");
eq("unclosed script drops the rest", "a<script>evil()", "a");
eq("a tag inside a script string", "<p>Hello</p><script>var a = '</p>';</script><p>World</p>", "Hello World");
eq("ordinary page text survives", "<h1>Title</h1>\n<p>One <b>two</b>   three</p>", "Title One two three");
eq("<scripts> is not a script tag", "a<scripts>kept</scripts>b", "a kept b");

// Each removal rebuilds the next opener, so without the pass cap this takes one
// pass per level; with it the text is cut at the first block left standing.
let deep = "<script></script>";
for (let i = 0; i < 2000; i++) deep = `<scr${deep}ipt>evil()</script>`;
const t0 = process.hrtime.bigint();
const deepOut = htmlToText(`keep ${deep} tail`);
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
if (deepOut.includes("evil") || ms > 2000) { fail++; console.error(`FAIL: deep nesting: ${ms.toFixed(0)}ms, leaked=${deepOut.includes("evil")}`); }
else pass++;

console.log(`pi-research-fabric-html: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
EOF
