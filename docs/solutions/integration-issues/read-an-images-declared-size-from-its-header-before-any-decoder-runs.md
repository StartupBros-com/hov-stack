---
title: "Read an image's declared size from its header before any decoder runs; pngjs and jpeg-js allocate whatever the file claims"
date: "2026-09-13"
category: integration-issues
module: sign-it-image-intake
problem_type: security_issue
component: tooling
symptoms:
  - "A 200-byte file that declares a 100,000 by 100,000 pixel canvas makes PNG.sync.read or jpeg.decode allocate tens of gigabytes and the process dies"
  - "The input arrives from a network listener (the phone drawing page) or from a user's photo, so the size is attacker-controlled"
  - "A first fix that only checked the size broke the existing corrupt-file test: garbage after a PNG signature read as an enormous canvas and was reported as too large instead of unreadable"
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags: [images, png, jpeg, pngjs, jpeg-js, decompression-bomb, input-validation, security, sign-it]
---

# Read an image's declared size from its header before any decoder runs; pngjs and jpeg-js allocate whatever the file claims

## Problem

sign-it's onboarding accepts a signature image two ways: a PNG posted by the drawing page over a local or LAN listener, and a photo the user names. Both paths decoded with pngjs or jpeg-js straight from the bytes. Neither library caps width, height, or memory: the decoder allocates width times height times four bytes on the file's word alone. The security reviewer of dotfiles #1140 flagged it; a small crafted file would take the process down, and on the phone path the file comes from whoever holds the link.

## Symptoms

- Process exhaustion on a tiny file with a huge declared canvas.
- No error before allocation; the failure is an out-of-memory kill, not an exception the caller can map to a sentence.
- After adding a bare size check, the suite's planted negative ("PNG signature followed by garbage") flipped from "unreadable" to "too large", because the garbage bytes at the dimension offsets read as large numbers.

## What Didn't Work

- Checking size after decode: the allocation is the harm, so the check must precede it.
- Checking dimensions without checking the chunk marker: a corrupt file has bytes at the dimension offsets too, and the wrong refusal misleads the user ("use a smaller copy" for a file that is simply broken).

## Solution

Read the declared pixel count from the header alone, refuse above a budget, and require the header marker before trusting the numbers (`skills-local/sign-it/scripts/image-clean.mjs`, dotfiles #1140):

```js
const MAX_PIXELS = 40e6;
function declaredPixels(buffer, kind) {
  if (kind === 'png') {
    // IHDR is always the first chunk: type at bytes 12..15, width at 16, height at 20
    if (buffer.length < 24 || buffer.toString('latin1', 12, 16) !== 'IHDR') throw { code: 'unreadable' };
    return buffer.readUInt32BE(16) * buffer.readUInt32BE(20);
  }
  // JPEG: walk markers to the first SOF (C0..CF except C4, C8, CC); height at +5, width at +7
  let i = 2;
  while (i + 9 < buffer.length) {
    if (buffer[i] !== 0xFF) { i++; continue; }
    const m = buffer[i + 1];
    if (m === 0xFF) { i++; continue; }
    if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) return buffer.readUInt16BE(i + 5) * buffer.readUInt16BE(i + 7);
    const len = buffer.readUInt16BE(i + 2); if (len < 2) break; i += 2 + len;
  }
  return 0;
}
function decode(buffer, kind) {
  if (declaredPixels(buffer, kind) > MAX_PIXELS) throw { code: 'too-large' };
  // only now: PNG.sync.read(buffer) or jpeg.decode(buffer, { useTArray: true })
}
```

The listener's POST handler applies the same IHDR-plus-size check before its own decode, and the CLI maps the codes to plain sentences (`too-large`: "that picture is too big to process safely; use a smaller copy, or draw it instead"; `unreadable`: "that picture won't open for me").

## Why This Works

The dimensions a decoder will allocate for are written in a fixed place before any compressed data: PNG's IHDR chunk and JPEG's start-of-frame marker. Reading them costs nothing and needs no library. Requiring the chunk marker first keeps the two failure classes apart: a corrupt file has no IHDR at offset 12 and is refused as unreadable; a well-formed bomb has a real IHDR and is refused as too large. Forty megapixels is far above any signature and far below what exhausts a laptop.

## Prevention

- Any intake of images from users or the network gets a header size check before decode, in the suite as a stub file: a PNG signature plus IHDR declaring a huge canvas must be refused with `too-large`, and a PNG signature followed by garbage must still be refused as `unreadable`.
- Put the check in the one function every decode path calls, so a new intake path cannot skip it.

## Related Issues

- `docs/solutions/best-practices/split-a-build-across-implementers-under-a-written-contract-and-let-reviewers-not-the-suite-find-the-blockers.md`: how this was found by a reviewer, not the suite.
