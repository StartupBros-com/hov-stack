import assert from "node:assert/strict";
import test from "node:test";

import { analyze, contrast, finalColours, isLargeText, spacingConflict } from "../src/render-rules.mjs";
import { parseViewports, sanitize, toUrl } from "../src/render.mjs";

const WHITE = [255, 255, 255, 1];
const page = (over) => ({ viewport: { width: 1000, height: 800 }, docWidth: 1000, texts: [], targets: [], clips: [], ...over });
const text = (over) => ({ sel: "p", text: "copy", color: [0, 0, 0, 1], fontSize: 16, fontWeight: 400, disabled: false, layers: [{ bg: WHITE, opacity: 1, image: false }], ...over });
const target = (sel, rect, over) => ({ sel, text: "", rect, inline: false, uaControl: false, disabled: false, ...over });
const rules = (result) => result.findings.map((f) => f.rule);

test("contrast matches the WCAG reference points", () => {
  assert.equal(Math.round(contrast([0, 0, 0], [255, 255, 255]) * 100) / 100, 21);
  assert.equal(contrast([255, 255, 255], [255, 255, 255]), 1);
  // #777 on white is the textbook just-under-4.5 grey.
  const grey = contrast([0x77, 0x77, 0x77], [255, 255, 255]);
  assert.ok(grey > 4.4 && grey < 4.5, `#777 on white = ${grey}`);
});

test("half-alpha black text over white paints mid grey", () => {
  const c = finalColours(text({ color: [0, 0, 0, 0.5] }));
  assert.deepEqual(c, { fg: [127.5, 127.5, 127.5], bg: [255, 255, 255] });
  const tinted = finalColours(text({ color: [10, 20, 30, 1], layers: [{ bg: [200, 200, 200, 1], opacity: 1, image: false }] }));
  assert.deepEqual(tinted, { fg: [10, 20, 30], bg: [200, 200, 200] });
});

test("isLargeText uses 24px, or 18.66px at weight 700", () => {
  assert.equal(isLargeText(24, 400), true);
  assert.equal(isLargeText(23.9, 400), false);
  assert.equal(isLargeText(18.66, 700), true);
  assert.equal(isLargeText(18.66, 600), false);
  assert.equal(isLargeText(18, 700), false);
});

test("text alpha is composited: 45% black on white fails though solid black passes", () => {
  const solid = analyze(page({ texts: [text({ color: [0, 0, 0, 1] })] }));
  assert.deepEqual(rules(solid), []);
  const faint = analyze(page({ texts: [text({ color: [0, 0, 0, 0.45] })] }));
  assert.deepEqual(rules(faint), ["text-contrast"]);
  const f = faint.findings[0];
  assert.ok(f.ratio > 3 && f.ratio < 4.5, `ratio ${f.ratio}`);
  assert.equal(f.needed, 4.5);
  assert.equal(f.bg, "#ffffff");
});

test("ancestor opacity fades both the text and every background below it", () => {
  const faded = text({ layers: [{ bg: WHITE, opacity: 1, image: false }, { bg: [0, 0, 0, 0], opacity: 0.4, image: false }] });
  const colours = finalColours(faded);
  assert.ok(colours.fg[0] > 150 && colours.fg[0] < 155, `fg ${colours.fg}`);
  assert.deepEqual(rules(analyze(page({ texts: [faded] }))), ["text-contrast"]);

  // A dark card at half opacity over white is a mid grey, and so is its white text's ground.
  const card = text({ color: [255, 255, 255, 1], layers: [{ bg: WHITE, opacity: 1, image: false }, { bg: [0, 0, 0, 1], opacity: 0.5, image: false }] });
  const c = finalColours(card);
  assert.deepEqual(c.bg, [127.5, 127.5, 127.5]);
  assert.deepEqual(c.fg, [255, 255, 255]);
});

test("translucent backgrounds stack in order", () => {
  const stacked = text({
    color: [255, 255, 255, 1],
    layers: [
      { bg: WHITE, opacity: 1, image: false },
      { bg: [0, 0, 0, 0.5], opacity: 1, image: false },
      { bg: [0, 0, 0, 0.5], opacity: 1, image: false },
    ],
  });
  assert.deepEqual(finalColours(stacked).bg, [63.75, 63.75, 63.75]);
});

test("large text needs 3:1, normal text 4.5:1", () => {
  const grey = [0x88, 0x88, 0x88, 1]; // 3.54:1 on white
  assert.deepEqual(rules(analyze(page({ texts: [text({ color: grey, fontSize: 28 })] }))), []);
  assert.deepEqual(rules(analyze(page({ texts: [text({ color: grey, fontSize: 16 })] }))), ["text-contrast"]);
  assert.deepEqual(rules(analyze(page({ texts: [text({ color: grey, fontSize: 19, fontWeight: 700 })] }))), []);
});

test("unknowable contrast is counted as unmeasured, never guessed", () => {
  const overImage = text({ color: [0xaa, 0xaa, 0xaa, 1], layers: [{ bg: WHITE, opacity: 1, image: false }, { bg: [0, 0, 0, 0], opacity: 1, image: true }] });
  const transparent = text({ color: [0, 0, 0, 0] });
  const darkRoot = text({ color: [0x33, 0x33, 0x33, 1], layers: [] });
  const r = analyze(page({ texts: [overImage, transparent], rootDarkOnly: false }));
  assert.deepEqual(rules(r), []);
  assert.equal(r.advisories.contrastUnmeasured, 2);
  // With no opaque layer, a dark-only root's canvas colour is unknown.
  assert.equal(analyze(page({ texts: [darkRoot], rootDarkOnly: true })).advisories.contrastUnmeasured, 1);
  // With a light root, the canvas is white and #333 passes.
  assert.deepEqual(rules(analyze(page({ texts: [darkRoot], rootDarkOnly: false }))), []);
});

test("disabled text is exempt from contrast", () => {
  const r = analyze(page({ texts: [text({ color: [0xcc, 0xcc, 0xcc, 1], disabled: true })] }));
  assert.deepEqual(rules(r), []);
});

test("target-size: an undersized target too close to another is reported", () => {
  const a = target("#a", [0, 0, 18, 18]);
  const b = target("#b", [20, 0, 38, 18]);
  const r = analyze(page({ targets: [a, b] }));
  assert.deepEqual(rules(r), ["target-size", "target-size"]);
  assert.equal(r.findings[0].near, "#b");
  assert.equal(r.findings[0].size, "18x18");
  assert.equal(r.advisories.targetsUnder44, 2);
});

test("target-size: WCAG 2.5.8 spacing, inline and user-agent exceptions hold", () => {
  const lone = target("#lone", [0, 0, 20, 20]);
  const far = target("#far", [200, 0, 244, 44]);
  const spaced = analyze(page({ targets: [lone, far] }));
  assert.deepEqual(rules(spaced), []);
  assert.equal(spaced.advisories.targetsSpacedUnder24, 1);

  const near = target("#near", [24, 0, 68, 44]); // centre (10, 10) is 14 from its edge
  assert.equal(spacingConflict(lone, [lone, near]), null);
  const touching = target("#touching", [21, 0, 65, 44]); // 11 from the edge
  assert.equal(spacingConflict(lone, [lone, touching]), touching);

  const inline = target("#inline", [0, 0, 30, 18], { inline: true });
  const checkbox = target("#check", [32, 0, 45, 13], { uaControl: true });
  assert.deepEqual(rules(analyze(page({ targets: [inline, checkbox] }))), []);
});

test("target-size: two undersized targets conflict only when their circles overlap", () => {
  const a = target("#a", [0, 0, 20, 20]); // centre 10
  const b = target("#b", [24, 0, 44, 20]); // centre 34: 24 apart, circles just touch
  assert.equal(spacingConflict(a, [a, b]), null);
  const c = target("#c", [23, 0, 43, 20]); // centre 33: 23 apart
  assert.equal(spacingConflict(a, [a, c]), c);
});

test("target-size: disabled targets are neither checked nor counted as neighbours", () => {
  const a = target("#a", [0, 0, 18, 18]);
  const off = target("#off", [20, 0, 38, 18], { disabled: true });
  assert.deepEqual(rules(analyze(page({ targets: [a, off] }))), []);
});

test("text-clipped: text straddling a hidden edge is reported per box and axis", () => {
  const box = [0, 0, 200, 48];
  const r = analyze(
    page({
      clips: [
        { sel: "div#c", text: "first", axis: "y", box, textBox: [0, 0, 190, 96], ellipsis: false, clamp: false },
        { sel: "div#c", text: "second", axis: "y", box, textBox: [0, 30, 190, 70], ellipsis: false, clamp: false },
      ],
    }),
  );
  assert.deepEqual(rules(r), ["text-clipped"]);
  assert.equal(r.findings[0].axis, "y");
  assert.equal(r.findings[0].texts, 2);
});

test("text-clipped: wholly hidden text and deliberate truncation are not findings", () => {
  const box = [0, 0, 120, 24];
  const r = analyze(
    page({
      clips: [
        { sel: "div#collapsed", text: "x", axis: "y", box: [0, 0, 200, 0], textBox: [0, 16, 190, 40], ellipsis: false, clamp: false },
        { sel: "div#ellipsis", text: "x", axis: "x", box, textBox: [0, 0, 400, 24], ellipsis: true, clamp: false },
        { sel: "div#ellipsis", text: "y", axis: "x", box, textBox: [0, 0, 300, 24], ellipsis: true, clamp: false },
        { sel: "p.clamp", text: "x", axis: "y", box: [0, 0, 200, 48], textBox: [0, 0, 200, 120], ellipsis: false, clamp: true },
        { sel: "div#fits", text: "x", axis: "x", box, textBox: [0.5, 0, 120.5, 24], ellipsis: false, clamp: false },
      ],
    }),
  );
  assert.deepEqual(rules(r), []);
  assert.deepEqual(
    r.advisories.truncated.map((t) => [t.selector, t.by]),
    [
      ["div#ellipsis", "ellipsis"],
      ["p.clamp", "line-clamp"],
    ],
  );
});

test("text-clipped: ellipsis does not excuse a vertical cut", () => {
  const r = analyze(page({ clips: [{ sel: "div#e", text: "x", axis: "y", box: [0, 0, 120, 24], textBox: [0, 0, 120, 48], ellipsis: true, clamp: false }] }));
  assert.deepEqual(rules(r), ["text-clipped"]);
});

test("page-overflow-x: a document wider than the viewport is reported once", () => {
  const r = analyze(page({ docWidth: 1600, overflowers: [{ selector: "div#wide", right: 1616 }] }));
  assert.deepEqual(rules(r), ["page-overflow-x"]);
  assert.equal(r.findings[0].by, 600);
  assert.equal(r.findings[0].offenders[0].selector, "div#wide");
  assert.deepEqual(rules(analyze(page({ docWidth: 1000.6 }))), []);
});

test("toUrl accepts http, https, file and local paths, and refuses other schemes", () => {
  assert.equal(toUrl("https://example.com/a"), "https://example.com/a");
  assert.equal(toUrl("file:///tmp/x.html"), "file:///tmp/x.html");
  assert.match(toUrl(new URL(import.meta.url).pathname), /^file:\/\//);
  assert.throws(() => toUrl("javascript:alert(1)"), /refusing 'javascript:'/);
  assert.throws(() => toUrl("data:text/html,<p>x"), /refusing 'data:'/);
  assert.throws(() => toUrl("./no-such-page.html"), /no such page/);
});

test("parseViewports reads WxH lists and rejects nonsense", () => {
  assert.deepEqual(parseViewports("1440x900,390x844"), [
    { width: 1440, height: 900 },
    { width: 390, height: 844 },
  ]);
  assert.throws(() => parseViewports("wide"), /bad --viewport/);
  assert.throws(() => parseViewports("10x10"), /200 to 8000/);
});

test("sanitize strips control and bidi-override characters at any depth", () => {
  const dirty = { sel: "p#a\u202eb", list: [{ text: "x\u0007y\u2066z" }], n: 3 };
  assert.deepEqual(sanitize(dirty), { sel: "p#ab", list: [{ text: "xyz" }], n: 3 });
});
