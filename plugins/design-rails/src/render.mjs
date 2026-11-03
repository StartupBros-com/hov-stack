#!/usr/bin/env node
/*
  design-rails render — rendered-page checks, dependency-free.

  scan reads source: colour literals, utility classes, declared heights. It
  cannot see what the browser paints once alpha, opacity, inheritance and
  layout have had their say. render loads a page in headless Chrome at one or
  more viewports, measures the laid-out result, and reports four rules (see
  render-rules.mjs for each rule's threshold and its source):

    text-contrast    final text colour vs final background, WCAG 1.4.3
    target-size      interactive targets under 24 by 24 CSS pixels, WCAG 2.5.8
    text-clipped     text cut off by an overflow: hidden or clip box
    page-overflow-x  the page scrolls sideways, WCAG 1.4.10

  Usage:
    node render.mjs <url | page.html> [--viewport=1440x900,390x844] [--json]
                    [--fail-on=<n>] [--chrome=<path>] [--timeout=<ms>]
                    [--settle=<ms>] [--no-sandbox] [--no-color]

  Exit 0 ok (or no --fail-on), 1 when findings exceed --fail-on, 2 on error.

  How it stays safe on a page it does not trust:
    - Chrome talks over --remote-debugging-pipe (fd 3 and 4): no port, no
      WebSocket, nothing another local process can attach to.
    - Every run gets a fresh --user-data-dir plus XDG_CONFIG_HOME,
      XDG_CACHE_HOME and TMPDIR under one temp root, removed on every exit
      path. A profile flag alone still lets Chrome write the user's
      default config.
    - The collector runs in an isolated world: it shares the DOM but not the
      page's JavaScript globals, so a page that patches Array, JSON or
      getComputedStyle cannot steer it.
    - Results come back by value through the protocol and are JSON-parsed.
      Nothing the page supplies is ever evaluated here, and page strings are
      stripped of control and bidi characters before they are printed.
    - Dialogs are dismissed, and launch, load and collection each time out.

  Chrome: --chrome=<path>, else CHROME_PATH, else google-chrome-stable,
  google-chrome, chromium, chromium-browser or chrome on PATH (snap builds
  are skipped: their private /tmp breaks the isolation above), else the
  macOS app bundles. --no-sandbox is opt-in, for containers that need it.
*/
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { analyze, RULES } from "./render-rules.mjs";

const DEFAULT_VIEWPORTS = "1440x900,390x844";
const LIMITS = { elements: 20000, texts: 4000, targets: 2000, clipTexts: 6000 };

// ---------------------------------------------------------------- Chrome

const CHROME_NAMES = ["google-chrome-stable", "google-chrome", "chromium", "chromium-browser", "chrome"];
const CHROME_BUNDLES = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
];

function executable(path) {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

/** The Chrome binary to drive, or null. An explicit choice is never second-guessed. */
export function findChrome(explicit, env = process.env) {
  if (explicit) return executable(explicit) ? explicit : null;
  if (env.CHROME_PATH) return executable(env.CHROME_PATH) ? env.CHROME_PATH : null;
  const dirs = (env.PATH || "").split(delimiter).filter((d) => d && !d.startsWith("/snap/"));
  for (const name of CHROME_NAMES) {
    for (const dir of dirs) {
      const candidate = join(dir, name);
      if (executable(candidate)) return candidate;
    }
  }
  return CHROME_BUNDLES.find(executable) || null;
}

/** One protocol connection over Chrome's debugging pipe: NUL-terminated JSON frames. */
class Connection {
  constructor(proc, timeoutMs) {
    this.proc = proc;
    this.timeoutMs = timeoutMs;
    this.nextId = 0;
    this.pending = new Map();
    this.listeners = new Set();
    this.failure = null;
    let partial = [];
    proc.stdio[4].on("data", (chunk) => {
      let start = 0;
      let end;
      while ((end = chunk.indexOf(0, start)) !== -1) {
        partial.push(chunk.subarray(start, end));
        this.dispatch(Buffer.concat(partial).toString("utf8"));
        partial = [];
        start = end + 1;
      }
      if (start < chunk.length) partial.push(chunk.subarray(start));
    });
    proc.stdio[3].on("error", () => {}); // EPIPE after Chrome dies; fail() reports the cause
  }

  dispatch(raw) {
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (typeof message.id === "number") {
      const waiting = this.pending.get(message.id);
      if (!waiting) return;
      this.pending.delete(message.id);
      clearTimeout(waiting.timer);
      if (message.error) waiting.reject(new Error(`${waiting.method}: ${message.error.message}`));
      else waiting.resolve(message.result || {});
      return;
    }
    for (const listener of [...this.listeners]) listener(message);
  }

  send(method, params = {}, sessionId) {
    if (this.failure) return Promise.reject(this.failure);
    const id = ++this.nextId;
    const frame = { id, method, params };
    if (sessionId) frame.sessionId = sessionId;
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} got no answer within ${this.timeoutMs} ms`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve: resolvePromise, reject, method, timer });
      this.proc.stdio[3].write(JSON.stringify(frame) + "\0");
    });
  }

  /** Resolve on the next `method` event for `sessionId`; reject on timeout or a dead browser. */
  waitFor(method, sessionId) {
    return new Promise((resolvePromise, reject) => {
      if (this.failure) return reject(this.failure);
      const listener = (message) => {
        if (message.method === "design-rails:closed") {
          stop();
          reject(message.error);
        } else if (message.method === method && message.sessionId === sessionId) {
          stop();
          resolvePromise(message.params);
        }
      };
      const timer = setTimeout(() => {
        stop();
        reject(new Error(`${method} did not arrive within ${this.timeoutMs} ms`));
      }, this.timeoutMs);
      const stop = () => {
        clearTimeout(timer);
        this.listeners.delete(listener);
      };
      this.listeners.add(listener);
    });
  }

  on(method, sessionId, handler) {
    const listener = (message) => {
      if (message.method === method && message.sessionId === sessionId) handler(message.params);
    };
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  fail(error) {
    if (this.failure) return;
    this.failure = error;
    for (const waiting of this.pending.values()) {
      clearTimeout(waiting.timer);
      waiting.reject(error);
    }
    this.pending.clear();
    for (const listener of [...this.listeners]) listener({ method: "design-rails:closed", error });
  }
}

/** Start Chrome in a throwaway profile and prove the pipe answers. */
export async function launch(chrome, { noSandbox = false, timeoutMs = 30000 } = {}) {
  const root = mkdtempSync(join(tmpdir(), "design-rails-render-"));
  const dirs = { profile: join(root, "profile"), config: join(root, "xdg-config"), cache: join(root, "xdg-cache"), tmp: join(root, "tmp") };
  for (const dir of Object.values(dirs)) mkdirSync(dir, { recursive: true });
  const args = [
    "--headless=new",
    "--remote-debugging-pipe",
    `--user-data-dir=${dirs.profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-sync",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-default-apps",
    "--mute-audio",
    "--hide-scrollbars",
    "--force-color-profile=srgb",
    "about:blank",
  ];
  if (noSandbox) args.unshift("--no-sandbox");
  const proc = spawn(chrome, args, {
    stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"],
    env: { ...process.env, XDG_CONFIG_HOME: dirs.config, XDG_CACHE_HOME: dirs.cache, TMPDIR: dirs.tmp },
  });
  let stderr = "";
  proc.stderr.on("data", (data) => {
    stderr = (stderr + data).slice(-4000);
  });
  const conn = new Connection(proc, timeoutMs);
  const gone = new Promise((done) => {
    proc.once("exit", done);
    proc.once("error", done);
  });
  proc.once("error", (error) => conn.fail(new Error(`could not start ${chrome}: ${error.message}`)));
  proc.once("exit", (code, signal) => {
    const tail = stderr.trim().split("\n").slice(-6).join("\n");
    conn.fail(new Error(`Chrome exited (${signal || code})${tail ? `:\n${tail}` : ""}`));
  });

  let closed = false;
  const browser = {
    conn,
    root,
    stderr: () => stderr,
    kill() {
      if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGKILL");
      rmSync(root, { recursive: true, force: true, maxRetries: 3 });
    },
    async close() {
      if (closed) return;
      closed = true;
      if (proc.exitCode === null && proc.signalCode === null) {
        conn.send("Browser.close").catch(() => {});
        const force = setTimeout(() => proc.kill("SIGKILL"), 5000);
        await gone;
        clearTimeout(force);
      }
      rmSync(root, { recursive: true, force: true, maxRetries: 3 });
    },
  };
  try {
    await conn.send("Browser.getVersion");
  } catch (error) {
    await browser.close();
    throw error;
  }
  return browser;
}

// ---------------------------------------------------------------- collector

/*
  Runs inside the page, in an isolated world: same DOM, its own JavaScript
  globals. It reads computed style and layout and returns plain data; every
  judgement happens in render-rules.mjs. Serialized with toString(), so it
  must not close over anything in this module.
*/
async function collect(limits) {
  await document.fonts.ready;
  const root = document.documentElement;
  const body = document.body || root;
  const view = { width: root.clientWidth, height: window.innerHeight };
  const SKIP = new Set(["script", "style", "noscript", "template", "head", "title", "meta", "link", "iframe", "object"]);

  const styles = new Map();
  const css = (el) => {
    let s = styles.get(el);
    if (!s) {
      s = getComputedStyle(el);
      styles.set(el, s);
    }
    return s;
  };

  // Every computed colour to [r, g, b, a]. Legacy rgb()/rgba() is parsed
  // exactly; any other syntax (oklch, lab, color()) is painted into a 1x1
  // canvas and read back, so the browser does the colour-space maths.
  const canvas = document.createElement("canvas");
  canvas.width = 1;
  canvas.height = 1;
  const paint = canvas.getContext("2d", { willReadFrequently: true });
  const colours = new Map();
  const colour = (value) => {
    if (colours.has(value)) return colours.get(value);
    let out = [0, 0, 0, 0];
    const legacy = /^rgba?\(([^)]*)\)$/.exec(value || "");
    if (legacy) {
      const n = legacy[1].split(/[\s,/]+/).filter(Boolean).map(Number);
      out = [n[0], n[1], n[2], n.length > 3 ? n[3] : 1];
    } else if (value && value !== "transparent") {
      paint.clearRect(0, 0, 1, 1);
      paint.fillStyle = value;
      paint.fillRect(0, 0, 1, 1);
      const d = paint.getImageData(0, 0, 1, 1).data;
      out = [d[0], d[1], d[2], d[3] / 255];
    }
    colours.set(value, out);
    return out;
  };

  const snippet = (s) => String(s || "").replace(/\s+/g, " ").trim().slice(0, 60);
  const sel = (el) => {
    const parts = [];
    for (let e = el, depth = 0; e && e.nodeType === 1 && depth < 3; e = e.parentElement, depth++) {
      if (e.id) {
        parts.unshift(`${e.localName}#${e.id}`);
        break;
      }
      const classes = Array.from(e.classList).slice(0, 2);
      parts.unshift(classes.length ? `${e.localName}.${classes.join(".")}` : e.localName);
    }
    return parts.join(" > ").slice(0, 160);
  };
  const box = (r) => [r.left, r.top, r.right, r.bottom];

  // The visually-hidden pattern (a 1-pixel box that clips its content): text
  // meant for assistive technology only, never a visual defect.
  const hiddenSelf = new Map();
  const visuallyHidden = (el) => {
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      let hidden = hiddenSelf.get(e);
      if (hidden === undefined) {
        const r = e.getBoundingClientRect();
        const s = css(e);
        hidden =
          (r.width <= 1 || r.height <= 1) &&
          (s.overflowX !== "visible" || s.overflowY !== "visible" || s.clip !== "auto" || s.clipPath !== "none");
        hiddenSelf.set(e, hidden);
      }
      if (hidden) return true;
    }
    return false;
  };

  // Background layers from the root down, keeping only the ones that paint
  // or change opacity: [{ bg, opacity, image }].
  const stacks = new Map();
  const layers = (el) => {
    if (stacks.has(el)) return stacks.get(el);
    const above = el.parentElement ? layers(el.parentElement) : [];
    const s = css(el);
    const layer = { bg: colour(s.backgroundColor), opacity: Number(s.opacity), image: s.backgroundImage !== "none" };
    const out = layer.bg[3] > 0 || layer.opacity < 1 || layer.image ? above.concat([layer]) : above;
    stacks.set(el, out);
    return out;
  };

  const all = Array.from(root.getElementsByTagName("*"));
  let capped = all.length > limits.elements;
  const elements = all.slice(0, limits.elements);

  // text-contrast: elements with their own visible text.
  const texts = [];
  for (const el of elements) {
    if (texts.length >= limits.texts) {
      capped = true;
      break;
    }
    if (SKIP.has(el.localName) || el.closest("svg")) continue;
    let own = "";
    let shown = false;
    for (const node of el.childNodes) {
      if (node.nodeType !== 3 || !/\S/.test(node.data)) continue;
      own += node.data;
      if (!shown) {
        const range = document.createRange();
        range.selectNodeContents(node);
        shown = range.getClientRects().length > 0;
      }
    }
    if (!shown) continue;
    const s = css(el);
    if (s.visibility !== "visible" || visuallyHidden(el)) continue;
    const fill = s.webkitTextFillColor || s.color;
    texts.push({
      sel: sel(el),
      text: snippet(own),
      color: colour(fill),
      fontSize: parseFloat(s.fontSize),
      fontWeight: Number(s.fontWeight) || 400,
      disabled: Boolean(el.closest(":disabled, [aria-disabled='true']")),
      layers: layers(el),
    });
  }

  // target-size: what a pointer can hit.
  const TARGETS =
    "a[href], button, input:not([type='hidden']), select, textarea, summary, [role='button'], [role='link'], " +
    "[role='checkbox'], [role='radio'], [role='switch'], [role='tab'], [role='menuitem'], [tabindex]:not([tabindex='-1'])";
  const alnum = (s) => (String(s || "").match(/[\p{L}\p{N}]/gu) || []).length;
  const inRunningText = (el) => {
    let block = el.parentElement;
    while (block && css(block).display.startsWith("inline")) block = block.parentElement;
    return Boolean(block) && alnum(block.textContent) > alnum(el.textContent) + 1;
  };
  const targets = [];
  for (const el of Array.from(document.querySelectorAll(TARGETS))) {
    if (targets.length >= limits.targets) {
      capped = true;
      break;
    }
    const s = css(el);
    if (s.visibility !== "visible" || s.pointerEvents === "none") continue;
    const r = el.getBoundingClientRect();
    if (r.width <= 1 || r.height <= 1 || r.right <= 0 || r.bottom <= 0) continue; // hidden or parked off-screen
    if (visuallyHidden(el)) continue;
    let rect = box(r);
    const type = String(el.getAttribute("type") || "").toLowerCase();
    const choice = el.localName === "input" && (type === "checkbox" || type === "radio");
    if (choice && el.labels) {
      // A label is part of its control's hit area.
      for (const label of Array.from(el.labels)) {
        const lr = label.getBoundingClientRect();
        if (lr.width > 1 && lr.height > 1) {
          rect = [Math.min(rect[0], lr.left), Math.min(rect[1], lr.top), Math.max(rect[2], lr.right), Math.max(rect[3], lr.bottom)];
        }
      }
    }
    targets.push({
      sel: sel(el),
      text: snippet(el.textContent || el.getAttribute("aria-label")),
      rect,
      inline: s.display === "inline" && inRunningText(el),
      uaControl: choice && s.appearance !== "none",
      disabled: el.matches(":disabled") || el.getAttribute("aria-disabled") === "true",
    });
  }

  // text-clipped: each text node against its clipping ancestors, nearest
  // first, up to the first scroll container on that axis.
  const clips = [];
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  let seen = 0;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!/\S/.test(node.data)) continue;
    if (++seen > limits.clipTexts) {
      capped = true;
      break;
    }
    const parent = node.parentElement;
    if (!parent || SKIP.has(parent.localName) || parent.closest("svg")) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = Array.from(range.getClientRects()).filter((r) => r.width > 0 && r.height > 0);
    if (!rects.length) continue;
    if (visuallyHidden(parent) || parent.closest("[aria-hidden='true'], [inert]")) continue;
    const textBox = [
      Math.min(...rects.map((r) => r.left)),
      Math.min(...rects.map((r) => r.top)),
      Math.max(...rects.map((r) => r.right)),
      Math.max(...rects.map((r) => r.bottom)),
    ];
    const done = { x: false, y: false };
    for (let a = parent; a && a !== body && a !== root && !(done.x && done.y); a = a.parentElement) {
      const s = css(a);
      for (const axis of ["x", "y"]) {
        if (done[axis]) continue;
        const overflow = axis === "x" ? s.overflowX : s.overflowY;
        if (overflow === "visible") continue;
        if (overflow !== "hidden" && overflow !== "clip") {
          done[axis] = true; // a scroll container: the text is reachable
          continue;
        }
        const r = a.getBoundingClientRect();
        const pad = [
          r.left + parseFloat(s.borderLeftWidth),
          r.top + parseFloat(s.borderTopWidth),
          r.right - parseFloat(s.borderRightWidth),
          r.bottom - parseFloat(s.borderBottomWidth),
        ];
        const out =
          axis === "x"
            ? textBox[0] < pad[0] - 1 || textBox[2] > pad[2] + 1
            : textBox[1] < pad[1] - 1 || textBox[3] > pad[3] + 1;
        if (!out) continue;
        done[axis] = true;
        const ps = css(parent);
        clips.push({
          sel: sel(a),
          text: snippet(node.data),
          axis,
          box: pad,
          textBox,
          ellipsis: s.textOverflow === "ellipsis" || ps.textOverflow === "ellipsis",
          clamp: (s.webkitLineClamp || "none") !== "none" || (ps.webkitLineClamp || "none") !== "none",
        });
      }
    }
  }

  // page-overflow-x: the outermost elements that run past the right edge.
  const viewportClips = [css(root).overflowX, css(body).overflowX].some((o) => o === "hidden" || o === "clip");
  const docWidth = viewportClips ? view.width : root.scrollWidth;
  const overflowers = [];
  if (docWidth > view.width + 1) {
    for (const el of elements) {
      if (overflowers.length >= 10) break;
      if (el === root || el === body || SKIP.has(el.localName)) continue;
      const r = el.getBoundingClientRect();
      if (r.right <= view.width + 1 || css(el).position === "fixed") continue;
      const p = el.parentElement;
      if (p && p !== body && p !== root && p.getBoundingClientRect().right > view.width + 1) continue;
      let contained = false;
      for (let a = p; a && a !== body && a !== root; a = a.parentElement) {
        if (css(a).overflowX !== "visible") {
          contained = true;
          break;
        }
      }
      if (!contained) overflowers.push({ selector: sel(el), right: Math.round(r.right) });
    }
  }

  return {
    viewport: view,
    docWidth,
    rootDarkOnly: css(root).colorScheme.trim() === "dark",
    elements: all.length,
    capped,
    texts,
    targets,
    clips,
    overflowers,
  };
}

// ---------------------------------------------------------------- render

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

/** Strip control and bidi-override characters from every string a page supplied. */
export function sanitize(value) {
  if (typeof value === "string") return value.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "");
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = sanitize(v);
    return out;
  }
  return value;
}

/** Load `url` at one viewport in a fresh tab and return the collector's facts. */
export async function measure(browser, url, viewport, { settleMs = 250 } = {}) {
  const { conn } = browser;
  const { targetId } = await conn.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await conn.send("Target.attachToTarget", { targetId, flatten: true });
  const send = (method, params) => conn.send(method, params, sessionId);
  const dismiss = conn.on("Page.javascriptDialogOpening", sessionId, () => {
    send("Page.handleJavaScriptDialog", { accept: false }).catch(() => {});
  });
  try {
    await send("Page.enable");
    await send("Emulation.setDeviceMetricsOverride", {
      width: viewport.width,
      height: viewport.height,
      deviceScaleFactor: 1,
      mobile: viewport.width < 600,
    });
    const loaded = conn.waitFor("Page.loadEventFired", sessionId);
    const nav = await send("Page.navigate", { url });
    if (nav.errorText) {
      loaded.catch(() => {});
      throw new Error(`could not load ${url}: ${nav.errorText}`);
    }
    await loaded;
    if (settleMs > 0) await sleep(settleMs);
    const { frameTree } = await send("Page.getFrameTree");
    const world = await send("Page.createIsolatedWorld", { frameId: frameTree.frame.id, worldName: "design-rails-render" });
    const result = await send("Runtime.evaluate", {
      expression: `(${collect.toString()})(${JSON.stringify(LIMITS)})`,
      contextId: world.executionContextId,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      const detail = result.exceptionDetails.exception?.description || result.exceptionDetails.text;
      throw new Error(`collector failed: ${detail}`);
    }
    return sanitize(result.result.value);
  } finally {
    dismiss();
    await conn.send("Target.closeTarget", { targetId }).catch(() => {});
  }
}

// ---------------------------------------------------------------- CLI

export function toUrl(target) {
  if (/^(https?|file):\/\//i.test(target)) return new URL(target).href;
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(target);
  if (scheme && !/^[a-z]:[\\/]/i.test(target)) {
    throw new Error(`refusing '${scheme[1]}:': render loads http, https and file pages only`);
  }
  const abs = resolve(target);
  if (!existsSync(abs) || !statSync(abs).isFile()) throw new Error(`no such page: ${target}`);
  return pathToFileURL(abs).href;
}

export function parseViewports(spec) {
  return spec.split(",").map((part) => {
    const m = /^(\d+)x(\d+)$/.exec(part.trim());
    if (!m) throw new Error(`bad --viewport '${part}': use WIDTHxHEIGHT, for example 390x844`);
    const [width, height] = [Number(m[1]), Number(m[2])];
    if (width < 200 || height < 200 || width > 8000 || height > 8000) {
      throw new Error(`bad --viewport '${part}': each side must be 200 to 8000`);
    }
    return { width, height };
  });
}

function flag(args, name) {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? undefined : hit.slice(name.length + 3);
}

function count(value, name) {
  if (!/^\d+$/.test(value)) throw new Error(`bad --${name} '${value}': a whole number`);
  return Number(value);
}

function print(url, pages, total, color) {
  const paint = (code, s) => (color ? `\u001b[${code}m${s}\u001b[0m` : s);
  const out = [paint("1", `design-rails render: ${url}`)];
  for (const page of pages) {
    const tally = RULES.map((rule) => [rule, page.findings.filter((f) => f.rule === rule).length]).filter(([, n]) => n);
    const head = `${page.width}x${page.height}: ${page.findings.length} finding${page.findings.length === 1 ? "" : "s"}`;
    out.push("", paint(page.findings.length ? "31" : "32", head) + (tally.length ? ` (${tally.map(([r, n]) => `${r} ${n}`).join(", ")})` : ""));
    for (const f of page.findings) {
      const quote = f.text ? ` "${f.text}"` : "";
      const offenders = f.offenders?.length ? ` (past the edge: ${f.offenders.map((o) => o.selector).join(", ")})` : "";
      out.push(`  ${f.rule.padEnd(16)}${f.selector}${quote}: ${f.message}${offenders}`);
    }
    const a = page.advisories;
    const notes = [];
    if (a.targetsUnder44) notes.push(`${a.targetsUnder44} target${a.targetsUnder44 === 1 ? "" : "s"} under 44 by 44`);
    if (a.targetsSpacedUnder24) notes.push(`${a.targetsSpacedUnder24} under 24 but spaced clear (WCAG 2.5.8's spacing exception)`);
    if (a.truncated.length) notes.push(`${a.truncated.length} truncated on purpose (ellipsis or line-clamp)`);
    if (a.contrastUnmeasured) notes.push(`${a.contrastUnmeasured} text${a.contrastUnmeasured === 1 ? "" : "s"} over an image or gradient, contrast not measured`);
    if (page.capped) notes.push(`element caps reached, so the page was only partly measured`);
    if (notes.length) out.push(paint("2", `  advisory: ${notes.join("; ")}`));
  }
  out.push("", `total: ${total} finding${total === 1 ? "" : "s"}`);
  console.log(out.join("\n"));
}

async function main() {
  const args = process.argv.slice(2);
  const positional = args.filter((a) => !a.startsWith("--"));
  if (args.includes("--help") || positional.length !== 1) {
    console.error(
      "usage: design-rails render <url | page.html> [--viewport=WxH[,WxH]] [--json] [--fail-on=<n>]\n" +
        "                          [--chrome=<path>] [--timeout=<ms>] [--settle=<ms>] [--no-sandbox] [--no-color]",
    );
    process.exit(args.includes("--help") ? 0 : 2);
  }
  const asJson = args.includes("--json");
  const color = !asJson && !args.includes("--no-color") && process.stdout.isTTY;
  let url, viewports, failOn, timeoutMs, settleMs;
  try {
    url = toUrl(positional[0]);
    viewports = parseViewports(flag(args, "viewport") ?? DEFAULT_VIEWPORTS);
    failOn = flag(args, "fail-on") === undefined ? null : count(flag(args, "fail-on"), "fail-on");
    timeoutMs = count(flag(args, "timeout") ?? "30000", "timeout");
    settleMs = count(flag(args, "settle") ?? "250", "settle");
  } catch (error) {
    console.error(`design-rails render: ${error.message}`);
    process.exit(2);
  }
  const chrome = findChrome(flag(args, "chrome"));
  if (!chrome) {
    console.error("design-rails render: no Chrome found. Pass --chrome=<path> or set CHROME_PATH.");
    process.exit(2);
  }

  let browser = null;
  const abort = (code) => () => {
    if (browser) browser.kill();
    process.exit(code);
  };
  process.once("SIGINT", abort(130));
  process.once("SIGTERM", abort(143));

  const pages = [];
  try {
    browser = await launch(chrome, { noSandbox: args.includes("--no-sandbox"), timeoutMs });
    for (const viewport of viewports) {
      const facts = await measure(browser, url, viewport, { settleMs });
      const { findings, advisories } = analyze(facts);
      pages.push({ ...viewport, elements: facts.elements, capped: facts.capped, findings, advisories });
    }
  } catch (error) {
    console.error(`design-rails render: ${error.message}`);
    if (browser) await browser.close();
    process.exit(2);
  }
  await browser.close();

  const total = pages.reduce((n, p) => n + p.findings.length, 0);
  if (asJson) console.log(JSON.stringify({ url, chrome, viewports: pages, total }, null, 2));
  else print(url, pages, total, color);
  if (failOn !== null && total > failOn) {
    console.error(`design-rails render: ${total} findings, over the --fail-on budget of ${failOn}`);
    process.exit(1);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
