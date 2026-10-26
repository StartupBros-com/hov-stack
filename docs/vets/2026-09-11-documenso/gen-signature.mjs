// One-off asset generator: renders signature.html in headless Chromium and
// screenshots the signature <div> with a transparent background PNG.
// Not part of the sign.mjs runtime dependency footprint (measured separately).
import { chromium } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const htmlPath = path.join(__dirname, "signature.html");
const outPath = path.join(__dirname, "..", "signature.png");

const browser = await chromium.launch({
  executablePath:
    "/home/user/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome",
});
const page = await browser.newPage({
  viewport: { width: 900, height: 260 },
  // transparent page background requires omitBackground on screenshot, not here
});
await page.goto("file://" + htmlPath);
const el = await page.$(".sig");
await el.screenshot({ path: outPath, omitBackground: true });
await browser.close();
console.log("wrote", outPath);
