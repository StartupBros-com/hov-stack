---
title: "ChatGPT stores an inline pro-gate packet as escaped Markdown and wraps bare URLs as links; a 'malformed Markdown link' finding on a plain diff line is a delivery artifact"
date: 2026-10-05
category: integration-issues
module: pro-gate-oracle-inline-delivery
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A Pro P2 says a line in the diff is a malformed Markdown link, quoting `[url](url)` or `[text]\\([url](url))`, but `gh pr diff` shows a plain URL or a well-formed `[text](url)` on that line"
  - "The suggested fix is the text already on the line (dotfiles#1561 round 1)"
  - "The FIX-FIRST costs a Pro round and a fix session that pushes nothing"
root_cause: wrong_api
resolution_type: workaround
severity: medium
related_components:
  - pro-gate
  - oracle
  - cdp-salvage
  - pr-owner
tags: [pro-gate, oracle, chatgpt-composer, markdown-escaping, autolink, false-finding, delivery-receipt, cdp]
---

# ChatGPT stores an inline pro-gate packet as escaped Markdown and wraps bare URLs as links

## Context

dotfiles#1561 round 1 got a FIX-FIRST for `source: [https://github.com/org/rails-ce-pack](https://github.com/org/rails-ce-pack)`. The diff line was a plain URL, and the suggested fix was the line as it already stood. The members app's #4209 got the same kind of P2 two hours earlier: its well-formed `[changelog](https://developers.cloudflare.com/…)` came back as `[changelog]\([https://…](https://…))`. Issue #1580 asked which stage changed the bytes, packet delivery or response extraction.

## What the stored message shows

The answer came from reading the user message ChatGPT stored. The read is one `Runtime.evaluate` in the run's still-open tab: `GET /backend-api/conversation/<id>` with the page's own session, returning only short snippets. It costs no Pro round. Both packets had changed before the model saw them:

- `210 | +#   - source: [https://github.com/org/rails-ce-pack](https://github.com/org/rails-ce-pack)`
- `Cloudflare's [changelog]\([https://developers.cloudflare.com/changelog/post/2026-09-28-cloudflare-cli-beta/](https://…`

The URL wrap is one of four changes ChatGPT makes to every inline packet. The others are an escaped file header and fence (`\### File`, `` \`\`\` ``, so the diff is no longer a code block), backslash escapes on `` ` * _ # - < ~ ``, and `&#x20;` for gutter spaces. Every sampled packet with a file block carries them, back to the oldest checked (2026-09-08). Pro reads past the escapes. It takes the URL wrap as content when the finding is about the line's syntax.

Extraction is ruled out. Both reviews came back through `cdp-salvage.mjs`, whose `readReviewText` reads `innerText`, and an anchor's `innerText` is only its label.

The likely mechanism is that oracle types the packet into ChatGPT's rich-text composer with CDP `Input.insertText`, and ChatGPT keeps user turns as Markdown. That part is inferred. The stored bytes are observed.

## Guidance

When a Pro finding says a URL or link in the diff is malformed:

1. Compare the quoted bytes with `gh pr diff` at the reviewed head. If the diff line is a plain URL or a well-formed link and the quote has `[url](url)` or `\(`, the finding is about the transport, not the code. Do not edit the line to satisfy it.
2. When proof is needed, read the stored packet from the run's tab as above. Do not send Pro a probe. A probe spends a round and still depends on Pro quoting faithfully.
3. Switching delivery to upload is not a workaround. Browser upload delivered nothing at any size in the 2026-09-14 nonce probes.

The repair belongs upstream, in oracle's composer delivery or in a pro-gate delivery receipt that un-escapes and compares the stored message: StartupBros-com/pro-gate#260.
