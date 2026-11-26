#!/usr/bin/env node
// deliverable-render — turn one Markdown file into one self-contained HTML page.
//
// Usage: node deliverable-render.js <source.md> <out.html> [--url-prefix <prefix>]
//   --url-prefix   what a local absolute path is appended to in a link or image URL.
//                  Default "file://"; the opener passes "file://wsl.localhost/<distro>" on WSL.
//
// Called by bin/open-deliverable so a Markdown report never reaches the browser as raw text.
// The page carries no script and a Content-Security-Policy that allows none: a report can
// quote web content, and a quoted <script> or remote image must not act when the file opens.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const markdownit = require("./vendor/markdown-it/markdown-it.umd.min.js");

const CALLOUTS = { NOTE: "Note", TIP: "Tip", IMPORTANT: "Important", WARNING: "Warning", CAUTION: "Caution" };
const WORDS_PER_MINUTE = 230;

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function encodePath(p) {
  return p.split("/").map((seg) => encodeURIComponent(seg)).join("/");
}

function splitFrontMatter(text) {
  if (!/^---\r?\n/.test(text)) return { front: "", body: text };
  const m = /\r?\n(---|\.\.\.)[ \t]*(\r?\n|$)/.exec(text.slice(3));
  if (!m) return { front: "", body: text };
  const end = 3 + m.index;
  return { front: text.slice(text.indexOf("\n") + 1, end), body: text.slice(end + m[0].length) };
}

function inlineText(token) {
  return (token.children || [])
    .map((c) => (c.type === "text" || c.type === "code_inline" ? c.content : c.type === "softbreak" ? " " : ""))
    .join("");
}

function slugger() {
  const seen = new Map();
  return (text) => {
    const base = text.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s+/g, "-") || "section";
    const n = seen.get(base) || 0;
    seen.set(base, n + 1);
    return n ? `${base}-${n}` : base;
  };
}

// A relative link in the source is relative to the source's folder; the page is served from a
// cache folder, so every local reference is rewritten to an absolute file URL here.
function localUrl(raw, sourceDir, prefix) {
  if (!raw || raw.startsWith("#") || raw.startsWith("//") || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) return raw;
  const cut = raw.search(/[?#]/);
  const tail = cut === -1 ? "" : raw.slice(cut);
  let p = cut === -1 ? raw : raw.slice(0, cut);
  try {
    p = decodeURI(p);
  } catch {
    return raw;
  }
  return prefix + encodePath(path.resolve(sourceDir, p)) + tail;
}

function build(sourcePath, prefix) {
  const sourceDir = path.dirname(sourcePath);
  const md = markdownit({ html: false, linkify: true });
  const outline = [];

  md.core.ruler.push("deliverable_page", (state) => {
    const slug = slugger();
    const t = state.tokens;
    for (let i = 0; i < t.length; i++) {
      const tok = t[i];
      if (tok.type === "heading_open" && t[i + 1] && t[i + 1].type === "inline") {
        const text = inlineText(t[i + 1]);
        const id = slug(text);
        tok.attrSet("id", id);
        outline.push({ level: Number(tok.tag.slice(1)), text, id });
      }
      if (tok.type === "blockquote_open" && t[i + 2] && t[i + 2].type === "inline") {
        const kids = t[i + 2].children || [];
        const m = kids[0] && kids[0].type === "text" && /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/.exec(kids[0].content);
        if (m) {
          tok.attrJoin("class", `callout callout-${m[1].toLowerCase()}`);
          kids.shift();
          if (kids[0] && kids[0].type === "softbreak") kids.shift();
          const label = new state.Token("html_inline", "", 0);
          label.content = `<strong class="callout-title">${CALLOUTS[m[1]]}</strong> `;
          kids.unshift(label);
        }
      }
      if (tok.type === "list_item_open" && t[i + 2] && t[i + 2].type === "inline") {
        const kids = t[i + 2].children || [];
        const m = kids[0] && kids[0].type === "text" && /^\[([ xX])\]\s+/.exec(kids[0].content);
        if (m) {
          const done = m[1] !== " ";
          kids[0].content = kids[0].content.slice(m[0].length);
          tok.attrJoin("class", done ? "task task-done" : "task");
          const box = new state.Token("html_inline", "", 0);
          box.content = `<span class="box" role="img" aria-label="${done ? "done" : "not done"}">${done ? "✓" : ""}</span>`;
          kids.unshift(box);
        }
      }
      if (tok.type !== "inline") continue;
      for (const c of tok.children || []) {
        if (c.type === "link_open") {
          const href = c.attrGet("href");
          const next = localUrl(href, sourceDir, prefix);
          c.attrSet("href", next);
          if (/^https?:/i.test(next)) c.attrSet("rel", "noopener noreferrer");
        } else if (c.type === "image") {
          c.attrSet("src", localUrl(c.attrGet("src"), sourceDir, prefix));
          c.attrSet("loading", "lazy");
        }
      }
    }
  });

  md.renderer.rules.table_open = () => '<div class="table-wrap"><table>\n';
  md.renderer.rules.table_close = () => "</table></div>\n";
  md.renderer.rules.fence = (tokens, idx) => {
    const tok = tokens[idx];
    const lang = (tok.info || "").trim().split(/\s+/)[0];
    const pre = `<pre${lang ? ` data-lang="${esc(lang)}"` : ""}><code>${esc(tok.content)}</code></pre>\n`;
    if (lang !== "mermaid") return pre;
    return `<figure class="diagram-source"><figcaption>Diagram source (Mermaid), shown as text</figcaption>${pre}</figure>\n`;
  };
  return { md, outline };
}

// The list is emitted twice because the page has no script: a side column on a wide screen and
// a closed <details> on a narrow one, switched by a media query.
function outlineHtml(outline) {
  const items = outline.filter((h) => h.level === 2 || h.level === 3);
  if (items.length < 3) return { side: "", top: "" };
  const lis = items.map((h) => `<li class="l${h.level}"><a href="#${esc(h.id)}">${esc(h.text)}</a></li>`).join("\n");
  return {
    side: `<nav class="outline outline-side" aria-label="Contents"><p>Contents</p><ol>\n${lis}\n</ol></nav>`,
    top: `<details class="outline outline-top"><summary>Contents</summary><ol>\n${lis}\n</ol></details>\n`,
  };
}

function formatBytes(n) {
  return n < 1024 ? `${n} B` : n < 1048576 ? `${Math.round(n / 1024)} KB` : `${(n / 1048576).toFixed(1)} MB`;
}

function stamp(d) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

const CSS = fs.readFileSync(path.join(__dirname, "deliverable-page.css"), "utf8");

function render(sourcePath, prefix) {
  const raw = fs.readFileSync(sourcePath, "utf8");
  const stat = fs.statSync(sourcePath);
  const { front, body } = splitFrontMatter(raw);
  const { md, outline } = build(sourcePath, prefix);
  const html = md.render(body);
  const h1 = outline.find((h) => h.level === 1);
  const title = h1 ? h1.text : path.basename(sourcePath);
  const words = (body.match(/\S+/g) || []).length;
  const minutes = Math.max(1, Math.round(words / WORDS_PER_MINUTE));
  const nav = outlineHtml(outline);
  const frontBlock = front.trim()
    ? `<details class="front-matter"><summary>Front matter</summary><pre><code>${esc(front.trim())}</code></pre></details>\n`
    : "";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file:; style-src 'unsafe-inline'">
<meta name="generator" content="open-deliverable (markdown)">
<title>${esc(title)}</title>
<style>
${CSS}</style>
</head>
<body>
<header class="source-bar">
<span class="source-path" title="Click to select the path of the Markdown source">${esc(sourcePath)}</span>
<span class="source-facts">${formatBytes(stat.size)} · about ${minutes} min · saved ${stamp(stat.mtime)}</span>
</header>
<div class="layout${nav.side ? " has-outline" : ""}">
${nav.side}
<main>
${nav.top}${frontBlock}${html}</main>
</div>
</body>
</html>
`;
}

function main(argv) {
  const args = [];
  let prefix = "file://";
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--url-prefix") prefix = argv[++i] || "";
    else args.push(argv[i]);
  }
  if (args.length !== 2) {
    process.stderr.write("usage: deliverable-render.js <source.md> <out.html> [--url-prefix <prefix>]\n");
    return 2;
  }
  const source = path.resolve(args[0]);
  const out = path.resolve(args[1]);
  const page = render(source, prefix);
  const tmp = `${out}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, page);
  fs.renameSync(tmp, out);
  return 0;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`deliverable-render: ${err.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = { render, splitFrontMatter, localUrl };
