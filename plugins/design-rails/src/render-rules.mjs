/*
  design-rails render: the rules half.

  Pure functions over the facts the in-page collector (render.mjs) returns,
  so every threshold here is testable without a browser. Colours arrive as
  [r, g, b, a] with channels 0-255 and alpha 0-1, already resolved by the
  browser; rectangles arrive as [left, top, right, bottom] in CSS pixels.

  text-contrast    WCAG 2.2 SC 1.4.3. 4.5:1, or 3:1 for large text (24 CSS
                   pixels, or 18.66 at weight 700 and up). Both colours are
                   the FINAL ones: the text's own alpha, every background
                   layer's alpha and every ancestor's opacity are composited
                   over the page ground, so a 45%-alpha black that a source
                   check reads as "black" is measured as the grey it paints.
                   Text over a background image or gradient, and clipped
                   gradient text, are counted as not measured, never guessed.
                   Disabled controls are exempt, as 1.4.3 exempts them.
  target-size      WCAG 2.2 SC 2.5.8, 24 by 24 CSS pixels. Evaluated
                   exceptions: spacing (a 24-pixel circle on each undersized
                   target meets no other target and no other circle), inline
                   (a target inside running text) and user-agent control (a
                   checkbox or radio the author left at its native
                   appearance). The equivalent and essential exceptions need
                   intent and are not evaluated. Targets under 44 are counted
                   as an advisory, the recommendation scan's touch check uses.
  text-clipped     text whose laid-out line boxes straddle the edge of an
                   overflow: hidden or clip ancestor: partly visible, partly
                   cut. Text wholly outside its box (a collapsed panel, an
                   off-screen slide) is hidden on purpose and not reported.
                   Ellipsis (horizontal) and line-clamp (vertical) are
                   deliberate truncation and are listed apart, not counted.
  page-overflow-x  WCAG 2.2 SC 1.4.10: the document is wider than the
                   viewport, so the page scrolls sideways.
*/

export const RULES = ["text-contrast", "target-size", "text-clipped", "page-overflow-x"];

const WHITE = [255, 255, 255];
const SLOP = 1; // sub-pixel layout noise, in CSS pixels

const linear = (v) => {
  const c = v / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
};

/** WCAG relative luminance of an opaque [r, g, b]. */
export function luminance([r, g, b]) {
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

/** WCAG contrast ratio of two opaque colours, 1 to 21. */
export function contrast(a, b) {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

export function hex(rgb) {
  return "#" + rgb.map((v) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("");
}

/** Large-scale text in WCAG terms: 18pt, or 14pt bold, in CSS pixels. */
export function isLargeText(fontSize, fontWeight) {
  return fontSize >= 24 || (fontSize >= 18.66 && fontWeight >= 700);
}

const premultiply = ([r, g, b, a]) => [r * a, g * a, b * a, a];
const over = (top, under) => top.map((v, i) => v + under[i] * (1 - top[3]));

/**
 * One pixel's final colour: `top` (or nothing) painted inside the innermost
 * layer, then each layer's group, inside out. A layer's opacity scales its
 * whole group (its own background and everything painted inside it) as one
 * image, which is what CSS opacity does. Returns [r, g, b, alpha-before-canvas].
 */
function flatten(layers, top) {
  let pixel = top ? premultiply(top) : [0, 0, 0, 0];
  for (let i = layers.length - 1; i >= 0; i--) {
    pixel = over(pixel, premultiply(layers[i].bg)).map((v) => v * layers[i].opacity);
  }
  const alpha = pixel[3];
  return [...over(pixel, [...WHITE, 1]).slice(0, 3), alpha];
}

/**
 * Final text and ground colours for one text record, or null when they
 * cannot be known (an image or gradient in the stack, transparent text,
 * or a dark-only root with no opaque layer to stand on).
 *
 * `layers` runs from the root element down to the text's own element. The
 * ground is the pixel beside a glyph, the text colour the pixel under one.
 */
export function finalColours(record, rootDarkOnly = false) {
  if (record.layers.some((layer) => layer.image)) return null;
  if (record.color[3] <= 0) return null;
  const ground = flatten(record.layers);
  if (rootDarkOnly && ground[3] < 0.999) return null;
  const fg = flatten(record.layers, record.color);
  return { fg: fg.slice(0, 3), bg: ground.slice(0, 3) };
}

const intersects = (a, b) =>
  a[0] < b[2] - SLOP && a[2] > b[0] + SLOP && a[1] < b[3] - SLOP && a[3] > b[1] + SLOP;

const beyond = (text, box, axis) =>
  axis === "x" ? text[0] < box[0] - SLOP || text[2] > box[2] + SLOP : text[1] < box[1] - SLOP || text[3] > box[3] + SLOP;

const centre = (r) => [(r[0] + r[2]) / 2, (r[1] + r[3]) / 2];
const undersized = (r) => r[2] - r[0] < 24 || r[3] - r[1] < 24;

function distanceToRect([x, y], r) {
  const dx = Math.max(r[0] - x, 0, x - r[2]);
  const dy = Math.max(r[1] - y, 0, y - r[3]);
  return Math.hypot(dx, dy);
}

/**
 * The WCAG 2.5.8 spacing test for one undersized target: the first other
 * target its 24-pixel circle meets, or null when the spacing exception holds.
 */
export function spacingConflict(target, targets) {
  const c = centre(target.rect);
  for (const other of targets) {
    if (other === target) continue;
    if (undersized(other.rect)) {
      if (Math.hypot(c[0] - centre(other.rect)[0], c[1] - centre(other.rect)[1]) < 24) return other;
    } else if (distanceToRect(c, other.rect) < 12) return other;
  }
  return null;
}

const round2 = (n) => Math.round(n * 100) / 100;
const size = (r) => `${Math.round(r[2] - r[0])}x${Math.round(r[3] - r[1])}`;

/** Findings and advisories for one rendered viewport. */
export function analyze(page) {
  const findings = [];
  const advisories = { targetsUnder44: 0, targetsSpacedUnder24: 0, truncated: [], contrastUnmeasured: 0 };

  for (const t of page.texts || []) {
    if (t.disabled) continue;
    const colours = finalColours(t, page.rootDarkOnly);
    if (!colours) {
      advisories.contrastUnmeasured++;
      continue;
    }
    const ratio = contrast(colours.fg, colours.bg);
    const needed = isLargeText(t.fontSize, t.fontWeight) ? 3 : 4.5;
    if (ratio < needed) {
      findings.push({
        rule: "text-contrast",
        selector: t.sel,
        text: t.text,
        ratio: round2(ratio),
        needed,
        fg: hex(colours.fg),
        bg: hex(colours.bg),
        message: `${hex(colours.fg)} on ${hex(colours.bg)} = ${round2(ratio)}:1, needs ${needed}:1`,
      });
    }
  }

  const targets = (page.targets || []).filter((t) => !t.disabled);
  for (const t of targets) {
    const w = t.rect[2] - t.rect[0];
    const h = t.rect[3] - t.rect[1];
    if (w < 44 || h < 44) advisories.targetsUnder44++;
    if (w >= 24 && h >= 24) continue;
    if (t.inline || t.uaControl) continue;
    const near = spacingConflict(t, targets);
    if (!near) {
      advisories.targetsSpacedUnder24++;
      continue;
    }
    findings.push({
      rule: "target-size",
      selector: t.sel,
      text: t.text,
      size: size(t.rect),
      near: near.sel,
      message: `${size(t.rect)} target, under 24x24 and too close to ${near.sel}`,
    });
  }

  const clipped = new Map();
  for (const c of page.clips || []) {
    if (!intersects(c.textBox, c.box)) continue; // wholly hidden: on purpose
    if (!beyond(c.textBox, c.box, c.axis)) continue;
    if ((c.axis === "x" && c.ellipsis) || (c.axis === "y" && c.clamp)) {
      advisories.truncated.push({ selector: c.sel, axis: c.axis, by: c.axis === "x" ? "ellipsis" : "line-clamp" });
      continue;
    }
    const key = `${c.sel}\u0000${c.axis}`;
    const seen = clipped.get(key);
    if (seen) seen.texts++;
    else clipped.set(key, { rule: "text-clipped", selector: c.sel, text: c.text, axis: c.axis, texts: 1 });
  }
  for (const f of clipped.values()) {
    f.message = `text cut off ${f.axis === "x" ? "at the left or right edge" : "at the top or bottom edge"} of an overflow-hidden box`;
    findings.push(f);
  }
  advisories.truncated = dedupeBy(advisories.truncated, (t) => `${t.selector}\u0000${t.axis}`);

  if (page.docWidth > page.viewport.width + SLOP) {
    const by = Math.round(page.docWidth - page.viewport.width);
    findings.push({
      rule: "page-overflow-x",
      selector: "html",
      by,
      offenders: (page.overflowers || []).slice(0, 5),
      message: `page is ${by}px wider than the viewport and scrolls sideways`,
    });
  }

  return { findings, advisories };
}

function dedupeBy(items, key) {
  const seen = new Set();
  return items.filter((item) => {
    const k = key(item);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}
