#!/usr/bin/env node
// Hand-started no-Send trial. Only dynamically load the explicitly supplied Oracle package.
import { execFile } from "node:child_process";
import {
  appendFileSync,
  mkdirSync,
  writeFileSync,
  statSync,
  readFileSync,
  readdirSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { createHash, randomUUID } from "node:crypto";

// Functions the trial calls itself. Each must still be exported somewhere under dist/src,
// whatever the acknowledgement; the trial reaches most of them through pageActions'
// re-exports, so the file can move.
const direct = [
  "navigateToChatGPT",
  "ensureNotBlocked",
  "ensureLoggedIn",
  "ensurePromptReady",
  "ensureChatMode",
  "installJavaScriptDialogAutoDismissal",
  "clearPromptComposer",
  "clearComposerAttachments",
  "waitForAttachmentCompletion",
  "isAttachmentVisible",
  "ensureModelSelection",
  "uploadAttachmentViaDataTransfer",
  "captureComposerNavigationUrl",
  "assertComposerPlusStayedInPlace",
  "enableFocusEmulation",
  "activateWithoutFocusEmulation",
  "claimBrowserTarget",
  "connectToRemoteChrome",
  "closeRemoteChromeTarget",
  "listRemoteChromeTargets",
  "withRetries",
  "delay",
  "assembleBrowserPrompt",
  "mapModelToBrowserLabel",
  "readAssistantSnapshot",
];
// Click, key, dispatched-event and submit lines. The CDP and DOM calls a send path needs, plus the
// synthetic-event and indirect forms (dispatchEvent(new MouseEvent('click')), el['click']()) that
// name no CDP method. Over-matching is cheap: only lines new since the live build need a reviewer.
const risky = new RegExp(
  [
    String.raw`dispatchKeyEvent|insertText|dispatchMouseEvent|\.click\s*\(|requestSubmit|form\.submit|\.submit\s*\(`,
    String.raw`keydown|keypress|key:\s*["']Enter|SEND_BUTTON|send-button|composer-submit|\bInput\.|pointerdown|mousedown`,
    String.raw`submitPrompt|runProviderSubmissionFlow|dispatchEvent|\b(Mouse|Pointer|Keyboard|Touch|Input|Submit)Event\b`,
    String.raw`\b(mouseup|pointerup|keyup|touchstart|touchend|beforeinput)\b|\bcode:\s*["']Enter`,
    String.raw`\[\s*["'](click|submit|requestSubmit)["']\s*\]|\bclick\s*\.\s*(call|apply)\b`,
  ].join("|"),
);

// Pre-submit flows click and press keys legitimately (the chat-mode toggle, the model menu,
// removing an attachment), so a risky item alone cannot fail the gate. The audit reads every
// JavaScript file under dist and the manifest, not only the functions the trial calls, so a
// new helper, an arrow function or a moved file cannot hide a click. With a baseline (the live
// build, which reviews already run), only items the candidate adds need a reviewer: they fail
// the audit until PRO_GATE_BUMP_AUDIT_ACK carries the digest of exactly that set for exactly
// this candidate and baseline version. A key is the item's kind and full text, never its file
// or line, so a known line moved to another file stays known.
export function audit(root, { baselineRoot = null, ack = null } = {}) {
  const candidate = inventory(root);
  if (candidate.unreadable)
    return verdictOf([], 0, [{ function: candidate.unreadable }], ack, {});
  if (!baselineRoot)
    return verdictOf(candidate.items, 0, candidate.missing, ack, {
      candidate: candidate.version,
    });
  const baseline = inventory(baselineRoot);
  if (baseline.unreadable)
    return verdictOf([], 0, [{ function: "baseline " + baseline.unreadable }], ack, {
      candidate: candidate.version,
    });
  // A multiset, so a second copy of a known line is still new.
  const known = new Map();
  for (const item of baseline.items)
    known.set(itemKey(item), (known.get(itemKey(item)) ?? 0) + 1);
  const fresh = candidate.items.filter((item) => {
    const n = known.get(itemKey(item)) ?? 0;
    if (n > 0) known.set(itemKey(item), n - 1);
    return n === 0;
  });
  return verdictOf(
    fresh,
    candidate.items.length - fresh.length,
    candidate.missing,
    ack,
    { candidate: candidate.version, baseline: baseline.version },
  );
}
function itemKey(item) {
  return item.kind + "\u0000" + item.text;
}
function verdictOf(hits, known, missing, ack, versions) {
  const candidateVersion = versions.candidate ?? null,
    baselineVersion = versions.baseline ?? null;
  const digest = hits.length
    ? createHash("sha256")
        .update(
          JSON.stringify({
            candidate: candidateVersion,
            baseline: baselineVersion,
            items: hits.map(itemKey).sort(),
          }),
        )
        .digest("hex")
    : null;
  const acknowledged = digest !== null && ack === digest;
  return {
    ok: !missing.length && (!hits.length || acknowledged),
    hits,
    known,
    missing,
    digest,
    acknowledged,
    candidateVersion,
    baselineVersion,
  };
}
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
function inventory(root) {
  const dist = path.join(root, "dist"),
    items = [],
    missing = [],
    exported = new Set();
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
    if (!isObject(manifest)) throw Error("not an object");
  } catch {
    return { unreadable: "package.json unreadable" };
  }
  function walk(dir) {
    for (const ent of readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, ent.name),
        rel = path.relative(dist, file);
      // Never follow a link: report it, since the gate cannot say what it points at.
      if (ent.isSymbolicLink()) items.push({ kind: "symlink", file: rel, text: rel });
      else if (ent.isDirectory()) walk(file);
      else if (ent.isFile() && /\.[cm]?js$/.test(ent.name)) {
        const src = readFileSync(file, "utf8");
        if (rel.split(path.sep)[0] === "src")
          for (const m of src.matchAll(/^export (async )?function\s+([A-Za-z_$][\w$]*)\b/gm))
            exported.add(m[2]);
        src.split("\n").forEach((line, i) => {
          if (risky.test(line))
            items.push({ kind: "line", file: rel, line: i + 1, text: line.trim() });
        });
      }
    }
  }
  try {
    walk(dist);
  } catch {
    return { unreadable: "dist unreadable" };
  }
  // Dependency code is not read; a new dependency, install hook or launcher needs a reviewer.
  for (const field of ["dependencies", "optionalDependencies", "peerDependencies"])
    if (isObject(manifest[field]))
      for (const name of Object.keys(manifest[field]))
        items.push({ kind: "dependency", text: name });
  if (isObject(manifest.scripts))
    for (const key of ["preinstall", "install", "postinstall", "prepare"])
      if (manifest.scripts[key] !== undefined)
        items.push({ kind: "script", text: `${key}: ${manifest.scripts[key]}` });
  const bin =
    typeof manifest.bin === "string"
      ? { [String(manifest.name ?? "")]: manifest.bin }
      : isObject(manifest.bin)
        ? manifest.bin
        : {};
  for (const [name, target] of Object.entries(bin))
    items.push({ kind: "bin", text: `${name}: ${target}` });
  for (const name of direct) if (!exported.has(name)) missing.push({ function: name });
  return {
    unreadable: null,
    items,
    missing,
    version: typeof manifest.version === "string" ? manifest.version : null,
  };
}

// Block-2 instrument: a later cancellation must not overwrite a successful response.
export function scoreUpload(requests, cleanupStart) {
  const ok = (s) => typeof s === "number" && s >= 200 && s < 300;
  const cut = typeof cleanupStart === "number" ? cleanupStart : Infinity;
  const up = requests.filter((q) => q.phase === "upload");
  const creates = up.filter(
    (q) =>
      q.method === "POST" &&
      q.host === "chatgpt.com" &&
      q.path === "/backend-api/files",
  );
  const puts = up.filter(
    (q) =>
      q.method === "PUT" &&
      /\.oaiusercontent\.com$/.test(q.host) &&
      /^\/files\/[^/]+\/raw$/.test(q.path),
  );
  const finals = up.filter(
    (q) =>
      q.method === "POST" &&
      q.host === "chatgpt.com" &&
      /^\/backend-api\/files\/[^/]+$/.test(q.path),
  );
  const classify = (q) => {
    if (ok(q.status) && q.statusMs < cut)
      return q.failed
        ? "2xx-then-cancel"
        : q.finished
          ? "2xx-finished"
          : "2xx-open";
    if (q.status != null && q.statusMs < cut) return `non-2xx:${q.status}`;
    if (q.failed && q.failedMs >= cut) return "cancel-after-cleanup";
    if (q.failed) return "cancel-no-response";
    return "pending-at-cleanup";
  };
  const finalClasses = finals.map(classify);
  const finalHeld = finalClasses.some(
    (c) => c.startsWith("2xx") || c === "cancel-after-cleanup",
  );
  const beforeCleanup = (q) => ok(q.status) && q.statusMs < cut;
  return {
    creates: creates.length,
    createsOk: creates.filter((q) => ok(q.status)).length,
    puts: puts.length,
    putsOk: puts.filter((q) => ok(q.status)).length,
    finals: finals.length,
    finalClasses,
    finalPaths: [...new Set(finals.map((q) => q.path))],
    signal:
      creates.length === 1 &&
      beforeCleanup(creates[0]) &&
      puts.some(beforeCleanup) &&
      finals.some(beforeCleanup),
    realFinding: finalClasses.includes("cancel-no-response") && !finalHeld,
    doubleUpload: creates.length > 1,
  };
}

export function summarize(
  records,
  { stopped = "count", broken = null, wallMs = 0 } = {},
) {
  let counted = 0,
    failures = 0,
    inconclusive = 0;
  const outcomes = {};
  for (const r of records) {
    outcomes[r.outcome] = (outcomes[r.outcome] ?? 0) + 1;
    broken ??=
      r.broken ??
      r.tripwire ??
      (r.sendBlockFired ? "send block fired" : null) ??
      (r.targetCreated && r.targetClose?.gone !== true
        ? `own tab ${r.targetClose?.id ?? "?"} not closed`
        : null);
    if (
      r.phases?.uploadStart == null ||
      r.reviewOverlap ||
      r.outcome === "harness-error"
    ) {
      inconclusive++;
      continue;
    }
    counted++;
    const upload = scoreUpload(r.requests ?? [], r.phases?.cleanupStart);
    if (r.outcome !== "chip" || !upload.signal || upload.doubleUpload)
      failures++;
  }
  return {
    counted,
    failures,
    inconclusive,
    broken,
    stopped: broken ? "broken" : stopped,
    outcomes,
    wallMs,
  };
}
function classification(s) {
  if (!s || typeof s !== "object") return "broken";
  if (s.broken) return "broken";
  if (
    !Number.isInteger(s.counted) ||
    !Number.isInteger(s.failures) ||
    s.failures < 0 ||
    s.failures > s.counted ||
    !Number.isInteger(s.inconclusive) ||
    s.inconclusive < 0
  )
    return "broken";
  if (
    s.inconclusive > 3 ||
    s.stopped === "deadline" ||
    s.stopped === "inconclusive"
  )
    return "inconclusive";
  if (s.failures >= 3) return "fail";
  return s.counted >= 20 ? "pass" : "inconclusive";
}
export function decide(candidate, control = null) {
  const c = classification(candidate),
    k = control === null ? null : classification(control);
  let verdict, reason;
  if (c === "broken") {
    verdict = "broken";
    reason = candidate?.broken || "invalid candidate summary";
  } else if (c === "inconclusive") {
    verdict = "defer";
    reason = "candidate inconclusive";
  } else if (c === "pass") {
    verdict = "pass";
    reason = "candidate has at most 2 failures in 20 counted trials";
  } else if (k === null) {
    verdict = "needs-control";
    reason = "candidate reached 3 failures";
  } else if (k === "broken") {
    verdict = "broken";
    reason = control?.broken || "invalid control summary";
  } else if (k === "pass") {
    verdict = "reject";
    reason = "candidate failed and control passed";
  } else {
    verdict = "defer";
    reason =
      k === "fail" ? "candidate and control failed" : "control inconclusive";
  }
  return { verdict, reason, candidate, control };
}

function redactUrl(raw) {
  try {
    const u = new URL(raw);
    return {
      host: u.host,
      path: u.pathname
        .split("/")
        .map((s) =>
          /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(s) ||
          /^(file|conv|g|c|user|org)-[A-Za-z0-9_-]{6,}$/.test(s) ||
          (s.length >= 8 && /\d/.test(s))
            ? "*"
            : s,
        )
        .join("/"),
    };
  } catch {
    return { host: "?", path: "?" };
  }
}
function pcount(pattern) {
  return new Promise((resolve) =>
    execFile("pgrep", ["-fc", pattern], (err, stdout) =>
      resolve(
        err?.code === 1 ? 0 : err ? -1 : Number(String(stdout).trim()) || 0,
      ),
    ),
  );
}
// The processes that drive the review browser: Oracle itself, and the salvage helper that
// harvest, recovery, reservation probes, tab sweeps and the conversation organizer run,
// several of them without a review slot. A review wrapper waiting for a slot the bump
// holds runs neither until it is admitted, so it does not count as overlap.
async function reviewInFlight() {
  const counts = await Promise.all(
    ["oracle-cli\\.js", "cdp-salvage\\.mjs"].map(pcount),
  );
  return { active: counts.some((n) => n !== 0), counts };
}

// One trial's own budget, and the time its cleanup may take after that: clearing the
// composer, settling intercepted requests and seeing its own tab gone. A trial starts only
// when both fit before the deadline.
const TRIAL_MS = 240000,
  CLOSE_MS = 30000;
// Waits for at most ms, then clears its timer so it never holds the process open.
async function within(promise, ms) {
  const ac = new AbortController();
  try {
    return await Promise.race([
      promise,
      sleep(ms, undefined, { signal: ac.signal }).catch(() => {}),
    ]);
  } finally {
    ac.abort();
  }
}
async function run(options) {
  const out = path.resolve(options.out);
  mkdirSync(out, { recursive: true });
  const started = Date.now(),
    records = [];
  const count = integer(options.count, "count", 1),
    stop = integer(
      options["stop-at-failures"] ?? Number.MAX_SAFE_INTEGER,
      "stop-at-failures",
      1,
    );
  const deadline = integer(
    options["deadline-epoch"] ?? Number.MAX_SAFE_INTEGER,
    "deadline-epoch",
    1,
  );
  const host = options.host ?? "127.0.0.1",
    port = integer(options.port ?? 9222, "port", 1),
    model = options.model ?? "gpt-5.6",
    gap = integer(options["gap-ms"] ?? 5000, "gap-ms", 0);
  const log = (line) =>
    appendFileSync(
      path.join(out, "oracle.log"),
      `${new Date().toISOString()} ${line}\n`,
    );
  let modules = null,
    current = null,
    interruptTrial,
    interrupted = null,
    stopped = "count",
    broken = null;
  // Tabs this run created and has not yet seen gone. The record names them for a person
  // to close if this process dies; a tab leaves it only once Chrome no longer lists it.
  const open = new Set();
  const record = () =>
    writeFileSync(
      path.join(out, "open-target.txt"),
      [...open].map((slot) => slot.target + "\n").join(""),
    );
  const load = (rel) =>
    import(
      pathToFileURL(
        path.join(path.resolve(options["oracle-root"]), "dist/src", rel),
      ).href
    );
  async function pages() {
    try {
      const targets = await modules.chrome.listRemoteChromeTargets({
        host,
        port,
      });
      const kinds = { blank: 0, chatgptRoot: 0, conversation: 0, other: 0 };
      for (const t of targets)
        if (t.type === "page")
          kinds[
            t.url === "about:blank"
              ? "blank"
              : /^https:\/\/chatgpt\.com\/?(\?.*)?$/.test(t.url ?? "")
                ? "chatgptRoot"
                : /^https:\/\/chatgpt\.com\/c\//.test(t.url ?? "")
                  ? "conversation"
                  : "other"
          ]++;
      return { kinds, ids: targets.map((t) => t.targetId ?? t.id) };
    } catch {
      return { kinds: null, ids: [] };
    }
  }
  async function gone(id, windowMs) {
    const start = Date.now();
    let last;
    do {
      last = await pages();
      if (last.kinds && !last.ids.includes(id))
        return { gone: true, afterMs: Date.now() - start, kinds: last.kinds };
      await sleep(500);
    } while (Date.now() - start < windowMs);
    return { gone: false, afterMs: Date.now() - start, kinds: last?.kinds ?? null };
  }
  // Each trial owns one slot, so a connection that resolves after its trial timed out can
  // never stand in for, or close, a later trial's tab. Closing the CDP connection closes
  // the tab it created; Chrome's target endpoint is the fallback, tried twice.
  function closeSlot(slot) {
    if (!slot.connection && !slot.target)
      return Promise.resolve({ gone: true, id: null, afterMs: 0, kinds: null });
    return (slot.closing ??= (async () => {
      const id = slot.target,
        own = slot.connection;
      slot.connection = null;
      try {
        await own?.close();
      } catch {}
      if (!id) return { gone: false, id: null, afterMs: 0, kinds: null };
      let seen = await gone(id, 5000),
        tries = 0;
      while (!seen.gone && tries < 2) {
        tries++;
        await modules.chrome
          .closeRemoteChromeTarget(host, port, id, log)
          .catch(() => {});
        seen = await gone(id, 5000);
      }
      if (seen.gone) {
        open.delete(slot);
        record();
      }
      return { ...seen, id, fallbackTries: tries };
    })());
  }
  const onSignal = (sig) => {
    interrupted ??= sig;
    interruptTrial?.(Error(sig));
    if (current) void closeSlot(current);
  };
  const onInt = () => onSignal("SIGINT"),
    onTerm = () => onSignal("SIGTERM"),
    onHup = () => onSignal("SIGHUP");
  process.on("SIGINT", onInt);
  process.on("SIGTERM", onTerm);
  process.on("SIGHUP", onHup);
  try {
    const [
      pa,
      transfer,
      attachments,
      chrome,
      focus,
      claim,
      utils,
      prompt,
      config,
    ] = await Promise.all([
      load("browser/pageActions.js"),
      load("browser/actions/remoteFileTransfer.js"),
      load("browser/actions/attachments.js"),
      load("browser/chromeLifecycle.js"),
      load("browser/focusEmulation.js"),
      load("browser/targetClaim.js"),
      load("browser/utils.js"),
      load("browser/prompt.js"),
      load("cli/browserConfig.js"),
    ]);
    modules = { chrome };
    const { delay } = utils;
    const dir = path.join(out, "pro-review.synthetic");
    mkdirSync(dir, { recursive: true });
    const diff = path.join(dir, "pr.filtered.diff");
    writeFileSync(
      diff,
      [
        "diff --git a/synthetic/upload-trial.ts b/synthetic/upload-trial.ts",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/synthetic/upload-trial.ts",
        "@@ -0,0 +1,2600 @@",
        ...Array.from(
          { length: 2600 },
          (_, i) =>
            `+export const syntheticUploadTrialValue${i + 1} = ${i + 1}; // filler line for a no-send upload trial`,
        ),
        "",
      ].join("\n"),
    );
    const promptText =
      "Synthetic upload trial. This prompt is never typed or sent; it only sizes Oracle's attachment plan.\n" +
      "Review the attached diff for correctness.\n".repeat(20);
    while (true) {
      const s = summarize(records);
      if (s.broken || interrupted) {
        broken = s.broken ?? interrupted;
        stopped = "broken";
        break;
      }
      if (s.counted >= count) {
        stopped = "count";
        break;
      }
      if (s.failures >= stop) {
        stopped = "failures";
        break;
      }
      if (s.inconclusive > 3) {
        stopped = "inconclusive";
        break;
      }
      if (deadline * 1000 - Date.now() < TRIAL_MS + CLOSE_MS) {
        stopped = "deadline";
        break;
      }
      if (records.length) {
        await delay(gap);
        if (deadline * 1000 - Date.now() < TRIAL_MS + CLOSE_MS) {
          stopped = "deadline";
          break;
        }
      }
      const n = records.length + 1,
        t0 = Date.now();
      const r = {
        trial: n,
        startedAt: new Date().toISOString(),
        model,
        strategy: "current",
        phases: {},
        requests: [],
        tripwire: null,
      };
      const mark = (k) => {
        r.phases[k] = Date.now() - t0;
      };
      const logger = Object.assign(
        (msg) => log(`[t${n} +${Date.now() - t0}ms] ${msg}`),
        { verbose: false },
      );
      let phase = "connect",
        uploadStarted = false,
        aborted = false,
        timer,
        removeDialog;
      const check = () => {
        if (aborted || interrupted || r.broken || r.tripwire)
          throw Error(
            r.broken ?? r.tripwire ?? interrupted ?? "trial deadline",
          );
      };
      // Every awaited step is a cancellation boundary: a timed-out continuation cannot
      // navigate or start another upload after its own tab has been closed.
      const step = async (fn) => {
        check();
        const v = await fn();
        check();
        return v;
      };
      const pending = new Map(),
        interceptions = new Set(),
        slot = { connection: null, target: null, connecting: null, closing: null };
      current = slot;
      try {
        const before = await reviewInFlight();
        if (before.active) {
          r.outcome = "skipped-review-in-flight";
          r.counts = before.counts;
        } else {
          r.kindsBefore = (await pages()).kinds;
          const artifacts = await prompt.assembleBrowserPrompt(
            {
              prompt: promptText,
              file: [diff],
              model,
              browserAttachments: "auto",
            },
            { cwd: dir },
          );
          r.attachmentMode = artifacts.attachmentMode;
          r.composerChars = artifacts.composerText.length;
          r.attachments = artifacts.attachments.map((a) => ({
            name: path.basename(a.path),
            sizeBytes: a.sizeBytes ?? statSync(a.path).size,
            generatedBundle: a.generatedBundle === true,
          }));
          if (artifacts.attachments.length !== 1) {
            r.outcome = "harness-error";
            r.error = `expected 1 attachment, got ${artifacts.attachments.length}`;
          } else {
            // A signal that landed before the race exists has no rejection to call.
            check();
            await Promise.race([
              new Promise((_, reject) => {
                interruptTrial = reject;
              }),
              new Promise((_, reject) => {
                timer = setTimeout(() => {
                  aborted = true;
                  reject(Error("trial deadline 240000ms"));
                }, TRIAL_MS);
              }),
              (async () => {
                slot.connecting = chrome.connectToRemoteChrome(
                  host,
                  port,
                  logger,
                  "about:blank",
                  undefined,
                  { fallbackToDefault: false, background: false },
                );
                const own = await slot.connecting;
                slot.connection = own;
                slot.target = own.targetId ?? null;
                if (slot.target) {
                  r.targetCreated = true;
                  open.add(slot);
                  record();
                }
                if (aborted || interrupted) {
                  await closeSlot(slot);
                  check();
                }
                if (!slot.target) {
                  r.broken = "no dedicated target id";
                  throw Error(r.broken);
                }
                mark("connected");
                const client = own.client,
                  { Network, Page, Runtime, Input, DOM, Fetch } = client;
                client.on("disconnect", () => {
                  r.disconnected = true;
                });
                client.on("Fetch.requestPaused", (p) => {
                  const task = (async () => {
                    const method = p?.request?.method,
                      pathname = new URL(p.request.url).pathname;
                    if (
                      !["GET", "HEAD", "OPTIONS"].includes(method) &&
                      /^\/backend-api\/(f\/)?conversation\/?$/.test(pathname)
                    ) {
                      r.sendBlockFired = true;
                      r.broken = "send block fired";
                      await Fetch.failRequest({
                        requestId: p.requestId,
                        errorReason: "BlockedByClient",
                      });
                    } else
                      await Fetch.continueRequest({ requestId: p.requestId });
                  })().catch(() => {
                    r.broken = "send interception failed";
                  });
                  interceptions.add(task);
                  void task.finally(() => interceptions.delete(task));
                });
                // Arm before any navigation or page helper. Failure is broken, never an upload result.
                try {
                  await Fetch.enable({
                    patterns: [
                      {
                        urlPattern: "*backend-api/*conversation*",
                        requestStage: "Request",
                      },
                    ],
                  });
                } catch {
                  r.broken = "send block could not be armed";
                  throw Error(r.broken);
                }
                check();
                client.on("Network.requestWillBeSent", (p) => {
                  const method = p?.request?.method;
                  if (!method || ["GET", "HEAD", "OPTIONS"].includes(method))
                    return;
                  const u = redactUrl(p.request.url),
                    row = {
                      phase,
                      method,
                      ...u,
                      status: null,
                      ms: Date.now() - t0,
                    };
                  r.requests.push(row);
                  pending.set(p.requestId, row);
                  if (
                    method === "POST" &&
                    /^\/backend-api\/(f\/)?conversation\/?$/.test(u.path)
                  )
                    r.tripwire ??= `conversation POST ${u.path}`;
                });
                client.on("Network.responseReceived", (p) => {
                  const q = pending.get(p.requestId);
                  if (q) {
                    q.status = p?.response?.status ?? null;
                    q.statusMs = Date.now() - t0;
                  }
                });
                client.on("Network.loadingFinished", (p) => {
                  const q = pending.get(p.requestId);
                  if (q) {
                    q.finished = true;
                    q.finishedMs = Date.now() - t0;
                  }
                });
                client.on("Network.loadingFailed", (p) => {
                  const q = pending.get(p.requestId);
                  if (q) {
                    q.failed = p?.errorText ?? "?";
                    q.canceled = p?.canceled === true;
                    q.failedMs = Date.now() - t0;
                  }
                });
                const onNav = (url) => {
                  const u = redactUrl(url ?? "");
                  if (/\/c\//.test(u.path))
                    r.tripwire ??= `conversation URL ${u.path}`;
                };
                client.on("Page.frameNavigated", (p) => {
                  if (!p?.frame?.parentId) onNav(p?.frame?.url);
                });
                client.on("Page.navigatedWithinDocument", (p) => onNav(p?.url));
                await step(() =>
                  Promise.all([
                    Network.enable({}),
                    Page.enable(),
                    Runtime.enable(),
                    DOM.enable(),
                  ]),
                );
                removeDialog = pa.installJavaScriptDialogAutoDismissal(
                  Page,
                  logger,
                );
                const focused = await step(() =>
                  focus.enableFocusEmulation(client, logger, "remote target"),
                );
                await step(() =>
                  focus.activateWithoutFocusEmulation(
                    Page,
                    false,
                    focused,
                    logger,
                  ),
                );
                phase = "navigate";
                await step(() =>
                  pa.navigateToChatGPT(
                    Page,
                    Runtime,
                    "https://chatgpt.com/",
                    logger,
                  ),
                );
                mark("navigated");
                for (const [name, args] of [
                  ["ensureNotBlocked", [Runtime, false, logger]],
                  [
                    "ensureLoggedIn",
                    [Runtime, logger, { remoteSession: true }],
                  ],
                ]) {
                  try {
                    await step(() => pa[name](...args));
                  } catch (e) {
                    r.broken ??= `${name}: ${e.message}`;
                    throw e;
                  }
                }
                mark("loggedIn");
                await step(() => pa.ensurePromptReady(Runtime, 60000, logger));
                mark("promptReady");
                r.chatMode = await step(() =>
                  pa.ensureChatMode(Runtime, Input, 60000, logger, {}),
                );
                if (r.chatMode === "switched")
                  await step(() =>
                    pa.ensurePromptReady(Runtime, 60000, logger),
                  );
                await step(() =>
                  Runtime.evaluate({
                    expression: "location.href",
                    returnByValue: true,
                  }),
                );
                const desired = config.mapModelToBrowserLabel(model);
                const evidence = await step(() =>
                  utils.withRetries(
                    () =>
                      pa.ensureModelSelection(
                        Runtime,
                        desired,
                        logger,
                        "current",
                        { implicitDefault: false },
                      ),
                    { retries: 2, delayMs: 300 },
                  ),
                );
                r.modelEvidence =
                  typeof evidence === "object"
                    ? JSON.stringify(evidence).slice(0, 300)
                    : String(evidence);
                await step(() => pa.ensurePromptReady(Runtime, 60000, logger));
                mark("modelReady");
                phase = "prep";
                await step(() =>
                  claim.claimBrowserTarget(Runtime, randomUUID()),
                );
                await step(() =>
                  pa.readAssistantSnapshot(Runtime).catch(() => null),
                );
                await step(() => pa.clearPromptComposer(Runtime, logger));
                await step(() => pa.ensurePromptReady(Runtime, 60000, logger));
                const navUrl = await step(() =>
                  pa.captureComposerNavigationUrl(Runtime),
                );
                await step(() =>
                  pa.clearComposerAttachments(Runtime, 5000, logger),
                );
                const attachment = artifacts.attachments[0];
                await step(() =>
                  pa.assertComposerPlusStayedInPlace(Runtime, navUrl),
                );
                phase = "upload";
                uploadStarted = true;
                mark("uploadStart");
                await step(() =>
                  transfer.uploadAttachmentViaDataTransfer(
                    { runtime: Runtime, dom: DOM, navigationUrl: navUrl },
                    attachment,
                    logger,
                  ),
                );
                mark("queued");
                await step(() => delay(500));
                await step(() =>
                  pa.waitForAttachmentCompletion(
                    Runtime,
                    60000,
                    [path.basename(attachment.path)],
                    logger,
                  ),
                );
                mark("allUploaded");
                r.outcome = "chip";
                const hold = Date.now();
                while (Date.now() - hold < 15000) {
                  const finals = r.requests.filter(
                    (q) =>
                      q.method === "POST" &&
                      q.host === "chatgpt.com" &&
                      /^\/backend-api\/files\/[^/]+$/.test(q.path),
                  );
                  if (
                    finals.length &&
                    finals.every((q) => q.finished || q.failed)
                  )
                    break;
                  await step(() => delay(200));
                }
                r.holdMs = Date.now() - hold;
                mark("cleanupStart");
                phase = "cleanup";
                await step(() => delay(1500));
                const href = await step(() =>
                  Runtime.evaluate({
                    expression: "location.href",
                    returnByValue: true,
                  }),
                );
                onNav(href?.result?.value);
                r.visibleBeforeClear = await step(() =>
                  attachments
                    .isAttachmentVisible(
                      Runtime,
                      path.basename(attachment.path),
                      undefined,
                      { countFileInput: false },
                    )
                    .catch(() => null),
                );
                // The completion helper can return after the chip is gone. Only a chip
                // still in the composer at cleanup passes; a probe that cannot tell fails,
                // like any other error after upload start.
                if (r.visibleBeforeClear !== true)
                  r.outcome =
                    r.visibleBeforeClear === false
                      ? "chip-gone"
                      : "chip-unverified";
                await step(() =>
                  pa.clearComposerAttachments(Runtime, 5000, logger),
                );
                r.clearedAfter = true;
              })(),
            ]);
          }
        }
      } catch (e) {
        r.error = e?.message ?? String(e);
        r.outcome = /Attachment did not appear/.test(r.error)
          ? "drop"
          : uploadStarted
            ? "upload-error"
            : "pre-upload-error";
        if (slot.connection) {
          try {
            mark("cleanupStart");
            phase = "cleanup";
            await pa.clearComposerAttachments(
              slot.connection.client.Runtime,
              5000,
              logger,
            );
            r.clearedAfter = true;
          } catch {
            r.clearedAfter = false;
          }
        }
      } finally {
        aborted = true;
        interruptTrial = undefined;
        clearTimeout(timer);
        removeDialog?.();
        await within(Promise.all([...interceptions]), 5000);
        // A connection still opening after its trial ended gets a moment to land, so the
        // tab it makes is closed and checked here rather than left behind.
        if (slot.connecting)
          await within(
            slot.connecting.then(
              () => {},
              () => {},
            ),
            10000,
          );
        r.targetClose = await closeSlot(slot);
        current = null;
        r.upload = scoreUpload(r.requests, r.phases.cleanupStart);
        r.pass =
          r.outcome === "chip" && r.upload.signal && !r.upload.doubleUpload;
        r.totalMs = Date.now() - t0;
        const after = await reviewInFlight();
        if (after.active) {
          r.reviewOverlap = true;
          r.countsAfter = after.counts;
        }
        records.push(r);
        appendFileSync(
          path.join(out, "results.jsonl"),
          JSON.stringify(r) + "\n",
        );
      }
    }
  } catch (e) {
    broken = e?.message ?? String(e);
    stopped = "broken";
  } finally {
    for (const slot of [...open]) await (slot.closing ?? closeSlot(slot));
    if (open.size) {
      broken ??= `own tab ${[...open].map((slot) => slot.target).join(", ")} not closed`;
      stopped = "broken";
    }
    process.off("SIGINT", onInt);
    process.off("SIGTERM", onTerm);
    process.off("SIGHUP", onHup);
  }
  const result = summarize(records, {
    stopped,
    broken,
    wallMs: Date.now() - started,
  });
  writeFileSync(path.join(out, "summary.json"), JSON.stringify(result) + "\n");
  return result;
}

function integer(value, name, min) {
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < min) throw Error(`invalid ${name}`);
  return n;
}
async function main(args) {
  const command = args.shift(),
    options = {};
  const allowed = {
    audit: ["oracle-root", "baseline-root", "ack"],
    run: [
      "oracle-root",
      "out",
      "count",
      "stop-at-failures",
      "deadline-epoch",
      "host",
      "port",
      "model",
      "gap-ms",
    ],
    decide: ["candidate", "control"],
  };
  if (!allowed[command])
    throw Error("usage: oracle-upload-trial.mjs audit|run|decide [options]");
  while (args.length) {
    const key = args.shift()?.replace(/^--/, "");
    if (
      !allowed[command].includes(key) ||
      !args.length ||
      options[key] !== undefined
    )
      throw Error("invalid option");
    options[key] = args.shift();
  }
  for (const key of command === "decide"
    ? ["candidate"]
    : command === "run"
      ? ["oracle-root", "out", "count"]
      : ["oracle-root"])
    if (!options[key]) throw Error(`missing --${key}`);
  if (command === "audit") {
    const result = audit(options["oracle-root"], {
      baselineRoot: options["baseline-root"] || null,
      ack: options.ack || null,
    });
    console.log(JSON.stringify(result));
    return result.ok ? 0 : 1;
  }
  if (command === "decide") {
    console.log(
      JSON.stringify(
        decide(
          JSON.parse(readFileSync(options.candidate)),
          options.control ? JSON.parse(readFileSync(options.control)) : null,
        ),
      ),
    );
    return 0;
  }
  const result = await run(options);
  console.log(JSON.stringify(result));
  return result.broken ? 1 : 0;
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    process.exitCode = 1;
  }
}
