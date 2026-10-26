#!/usr/bin/env node
// sign.mjs — stamp a signature PNG (+ optional typed name / date text) onto a PDF page.
//
// Usage:
//   node sign.mjs --input in.pdf --page 2 --sig signature.png \
//     --x 121 --y 658 --width 125 \
//     [--height 36] [--name "Alex J. Carter"] [--date "Sep 11, 2026"] \
//     --out out.pdf
//
// x/y/width/height accept either raw PDF points, or a percentage of the page
// (e.g. --x 20% --y 80%). x/y are the BOTTOM-LEFT corner of the signature
// image, in PDF coordinate space (origin bottom-left of the page).

import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import fs from "node:fs";

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

// Resolve a value that may be "NN" (points) or "NN%" (percent of `base`).
function resolveDim(value, base) {
  if (typeof value === "string" && value.trim().endsWith("%")) {
    const pct = parseFloat(value.trim().slice(0, -1));
    return (pct / 100) * base;
  }
  return parseFloat(value);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const required = ["input", "page", "sig", "x", "y", "width", "out"];
  const missing = required.filter((k) => args[k] === undefined);
  if (missing.length) {
    console.error("Missing required args: " + missing.join(", "));
    console.error(
      "Usage: node sign.mjs --input in.pdf --page N --sig sig.png --x X --y Y --width W [--height H] [--name NAME] [--date DATE] --out out.pdf"
    );
    process.exit(1);
  }

  const inputBytes = fs.readFileSync(args.input);
  const pdfDoc = await PDFDocument.load(inputBytes);

  const pageIndex = parseInt(args.page, 10) - 1; // CLI is 1-indexed
  const pages = pdfDoc.getPages();
  if (pageIndex < 0 || pageIndex >= pages.length) {
    console.error(`Page ${args.page} out of range (document has ${pages.length} pages)`);
    process.exit(1);
  }
  const page = pages[pageIndex];
  const { width: pageWidth, height: pageHeight } = page.getSize();

  const sigBytes = fs.readFileSync(args.sig);
  const sigImage = await pdfDoc.embedPng(sigBytes);
  const sigAspect = sigImage.height / sigImage.width;

  const drawWidth = resolveDim(args.width, pageWidth);
  const drawHeight = args.height
    ? resolveDim(args.height, pageHeight)
    : drawWidth * sigAspect;
  const drawX = resolveDim(args.x, pageWidth);
  const drawY = resolveDim(args.y, pageHeight);

  page.drawImage(sigImage, {
    x: drawX,
    y: drawY,
    width: drawWidth,
    height: drawHeight,
  });

  const font = await pdfDoc.embedFont(StandardFonts.Helvetica);

  // Optional small typed name printed just below the signature graphic —
  // mimics the "typed + drawn" confirmation pattern e-sign tools show.
  if (args.name && typeof args.name === "string") {
    const nameSize = 7;
    page.drawText(args.name, {
      x: drawX,
      y: drawY - nameSize - 2,
      size: nameSize,
      font,
      color: rgb(0.35, 0.35, 0.35),
    });
  }

  // Optional date text, placed independently via --dateX/--dateY (falls back
  // to just right of the signature if not given).
  if (args.date && typeof args.date === "string") {
    const dateSize = 10;
    const dateX = args.dateX ? resolveDim(args.dateX, pageWidth) : drawX + drawWidth + 20;
    const dateY = args.dateY ? resolveDim(args.dateY, pageHeight) : drawY + 4;
    page.drawText(args.date, {
      x: dateX,
      y: dateY,
      size: dateSize,
      font,
      color: rgb(0, 0, 0),
    });
  }

  const outBytes = await pdfDoc.save();
  fs.writeFileSync(args.out, outBytes);
  console.log(`Wrote ${args.out} (page ${args.page}, ${outBytes.length} bytes)`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
