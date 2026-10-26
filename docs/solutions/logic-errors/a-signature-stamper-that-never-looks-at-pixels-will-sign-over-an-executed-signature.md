---
title: "A signature stamper that never looks at pixels will sign over an executed signature; measure ink in the slot and refuse"
date: "2026-09-12"
category: logic-errors
module: sign-it-ink-detection
problem_type: logic_error
component: tooling
symptoms:
  - "sign-it stamped the operator's signature over already-executed e-signed documents because their text layers still show 'By: ______'"
  - "A first threshold missed thin cursive strokes (dark share 0.022 over a 220pt-wide box) and a drawn rule inside the crop read as 7 percent ink on an empty line"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [pdf, signature, ink-detection, pdftoppm, pgm, fail-closed]
---

# A signature stamper that never looks at pixels will sign over an executed signature; measure ink in the slot and refuse

## Problem

The finder worked from the text layer and form fields, both of which still describe a blank line after someone has signed it by hand or through an e-signature service that draws an image. Trial runs on real documents re-stamped three already-executed agreements.

## Symptoms

- Executed lines listed as ordinary candidates and signed without complaint.
- With a first detector: a hairline cursive signature scored under the limit; an underscore rule drawn slightly above the caption scored as ink on a clean line.

## What Didn't Work

- Averaging the dark share over the whole stamp box at 36 dpi with a 128 threshold: antialiased hairlines vanish, a wide box dilutes a signature that covers a third of it, and any rule crossing the box counts.

## Solution

Render each candidate's stamp area small and gray, measure the dark share with three corrections, and refuse above a limit (dotfiles #1131, `inkFraction` in `skills-local/sign-it/scripts/sign-it.mjs`):

```js
// pdftoppm -f P -l P -r 72 -gray -x X -y Y -W W -H H -singlefile in.pdf crop   -> crop.pgm (P5)
const px = buf.subarray(headerLength); const col = new Array(w).fill(0); let rows = 0;
for (let r = 0; r + w <= px.length; r += w) {
  let d = 0; for (let i = r; i < r + w; i++) if (px[i] < 176) d++;
  if (d / w > 0.5) continue;                  // a rule or border spanning the crop is not ink
  for (let i = 0; i < w; i++) if (px[r + i] < 176) col[i]++;
  rows++;
}
const win = Math.max(8, Math.floor(w / 3)); let best = 0;   // a signature rarely spans the slot: judge its densest third
for (let x0 = 0; x0 + win <= w; x0 += Math.max(1, Math.floor(w / 12))) { let d = 0; for (let i = x0; i < x0 + win; i++) d += col[i]; best = Math.max(best, d / (win * rows)); }
return best;                                   // INK_LIMIT 0.025
```

Every `find` candidate carries `ink`; `sign` refuses an inked slot with exit 3 and names `--over-ink` as the override after a render check. The box excludes the bottom strip where the rule and underscores sit and insets the sides so cell borders do not count.

## Why This Works

Signatures are ink where the layout says there is none; the text layer cannot see them but a render can. Seventy-two dpi keeps a one-point stroke at one pixel, the 176 threshold counts antialiased gray, dropping rows that are more than half dark removes rules and borders without removing strokes, and scoring the densest third of the width stops a wide slot from diluting a signature that sits in part of it. On the trial fleet this caught the three executed agreements and the pre-filled lines the same way.

## Prevention

- The suite draws a scrawl of 1.2pt strokes over one blank and 0.5pt strokes over another, leaves a third clean, and asserts the flag on the first two and not the third; a fixture with a drawn rule above its caption asserts the rule alone is not ink.
- Any tool that places content by layout alone should have a pixel check on the target region before it writes.

## Related Issues

- `docs/solutions/best-practices/harden-a-heuristic-tool-on-the-operators-real-files-with-a-trial-fleet.md`: how the three executed agreements were found.
