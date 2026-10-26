---
title: "A PDF library that refuses encrypted files is refusing owner-password forms any viewer opens; decrypt through qpdf with the empty user password"
date: "2026-09-12"
category: integration-issues
module: sign-it-pdf-open
problem_type: integration_issue
component: tooling
symptoms:
  - "pdf-lib throws 'Input document to PDFDocument.load is encrypted' on government and bank forms that open in every viewer without a password"
  - "A sweep of 1,676 PDFs in one Downloads folder returned 112 errors, 86 of them this message"
  - "The same files report 'User password = ' (empty) and a restrictive P value under qpdf --show-encryption"
root_cause: missing_tooling
resolution_type: code_fix
severity: high
tags: [pdf, encryption, owner-password, qpdf, pdf-lib, forms]
---

# A PDF library that refuses encrypted files is refusing owner-password forms any viewer opens; decrypt through qpdf with the empty user password

## Problem

sign-it could not open owner-locked government and bank form PDFs: pdf-lib refuses any file with an `/Encrypt` dictionary, and these files are encrypted only to restrict editing (an owner password) while their user password is empty, which is why every viewer opens them silently.

## Symptoms

- `cannot open PDF: Input document to PDFDocument.load is encrypted` on files the operator opens daily.
- 86 of 112 errors in a 1,676-file sweep were this one message.
- `qpdf --show-encryption` on such a file prints `User password =` with nothing after it.

## What Didn't Work

- pdf-lib's `ignoreEncryption: true` parses the object tree but leaves streams encrypted, so stamping onto the page produces a file whose original content is unreadable. Not tried in the shipped code because the failure mode is documented by pdf-lib's own issue tracker; the qpdf route was taken directly.

## Solution

Open through the library first; on an encryption error, decrypt with qpdf into a scratch copy that every later step reads (text extraction, rendering, stamping), and remove the copy at exit. In `skills-local/sign-it/scripts/sign-it.mjs` (dotfiles #1131):

```js
async function openPdf(pdfLib, pdf) {
  try { return { doc: await pdfLib.PDFDocument.load(fs.readFileSync(pdf)), src: pdf, repaired: null }; }
  catch (e) {
    const encrypted = /encrypted/i.test(e.message);
    const qpdf = have('qpdf');
    if (!qpdf) die(encrypted ? 4 : 5, encrypted ? 'the PDF is encrypted; install qpdf ...' : `cannot open PDF: ${e.message}`);
    const copy = path.join(scratchDir(), path.basename(pdf));
    const r = run(qpdf, encrypted ? ['--decrypt', pdf, copy] : [pdf, copy]);   // exit 3 = warnings, still usable
    if (r.status !== 0 && r.status !== 3) {
      if (/password/i.test(r.stderr)) die(5, 'the PDF needs a password to open; sign-it does not take passwords');
      die(5, `cannot open PDF: ${e.message} (qpdf: ${r.stderr.trim().slice(-200)})`);
    }
    return { doc: await pdfLib.PDFDocument.load(fs.readFileSync(copy)), src: copy, repaired: encrypted ? 'decrypted' : 'rewritten' };
  }
}
```

The result carries `repaired: "decrypted"` so the JSON says what happened, and the signed output carries no encryption, which is stated in the docs rather than hidden. A file with a real user password stays a refusal: qpdf reports an invalid password and the tool never prompts for one.

## Why This Works

PDF encryption has two passwords. The owner password gates permissions; the user password gates opening. Forms are commonly shipped with an owner password and an empty user password so that viewers open them but discourage edits. pdf-lib implements no decryption at all, so it cannot tell the two cases apart and refuses both. qpdf implements the standard security handler, tries the empty user password, and writes an unencrypted equivalent; every downstream tool (poppler, pdf-lib) then works on that copy.

## Prevention

- Test fixtures for any PDF tool should include an owner-locked file built in the suite itself: `qpdf --encrypt --user-password= --owner-password=x --bits=256 -- in.pdf locked.pdf`, plus a user-locked one that must stay a refusal.

## Related Issues

- `docs/solutions/best-practices/harden-a-heuristic-tool-on-the-operators-real-files-with-a-trial-fleet.md`: the sweep that surfaced this family.
