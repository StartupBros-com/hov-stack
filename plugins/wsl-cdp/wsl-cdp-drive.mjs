#!/usr/bin/env node
// wsl-cdp-drive: WebSocket-layer CDP verbs for the wsl-cdp bridge.
// Needs node >= 22 (global WebSocket + fetch). No npm dependencies.
//
//   eval <js> [tabId]         Runtime.evaluate, returnByValue, prints the value as JSON
//   text [tabId]              document.body.innerText of the tab
//   screenshot <file> [tabId] Page.captureScreenshot (png) written to <file>
//   upload <winPath> <selector> [tabId]
//                             DOM.setFileInputFiles on the matched file input,
//                             then dispatches input+change so page JS reacts.
//                             winPath must be a WINDOWS path the browser can
//                             read (the CLI wrapper handles staging/translation).
//
// Tab selection: explicit tabId, else the first "page" target.
const PORT = process.env.WSL_CDP_PORT || "9223";
const BASE = `http://127.0.0.1:${PORT}`;
const TIMEOUT_MS = 20000;

async function target(tabId) {
  let list;
  try {
    list = await (await fetch(`${BASE}/json/list`)).json();
  } catch (e) {
    throw new Error(`cannot reach the bridge at ${BASE}/json/list (${e.message}) — run: wsl-cdp doctor`);
  }
  const t = tabId
    ? list.find((x) => x.id === tabId)
    : list.find((x) => x.type === "page");
  if (!t) throw new Error(tabId ? `no tab ${tabId}` : "no page targets (wsl-cdp open URL first)");
  return t;
}

function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const pending = new Map();
    let nextId = 1;
    let opened = false;
    ws.onopen = () => {
      opened = true;
      resolve({
        send(method, params = {}) {
          const id = nextId++;
          return new Promise((res, rej) => {
            pending.set(id, { res, rej });
            ws.send(JSON.stringify({ id, method, params }));
            setTimeout(() => {
              if (pending.delete(id)) rej(new Error(`${method} timed out after ${TIMEOUT_MS}ms`));
            }, TIMEOUT_MS);
          });
        },
        close: () => ws.close(),
      });
    };
    ws.onerror = () => { if (!opened) reject(new Error(`websocket connect failed: ${wsUrl}`)); };
    ws.onclose = () => {
      // The tab was closed or the browser exited mid-request. Fail every
      // in-flight call now instead of hanging until each per-call timer fires
      // (or forever, for a call whose timer already fired but left the socket
      // open). Pre-open closes are already surfaced by onerror.
      const err = new Error("CDP websocket closed before response (tab closed or browser exited?)");
      for (const { rej } of pending.values()) rej(err);
      pending.clear();
    };
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && pending.has(msg.id)) {
        const { res, rej } = pending.get(msg.id);
        pending.delete(msg.id);
        msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
      }
    };
  });
}

async function evaluate(cdp, expression) {
  const r = await cdp.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || "evaluation threw");
  return r.result.value;
}

async function withCdp(tabId, action) {
  const t = await target(tabId);
  const cdp = await connect(t.webSocketDebuggerUrl);
  const result = await action(cdp, t);
  cdp.close();
  return result;
}

const [cmd, a1, a2, a3] = process.argv.slice(2);
try {
  if (cmd === "eval") {
    if (!a1) throw new Error("usage: wsl-cdp eval JS [TAB_ID]");
    await withCdp(a2 || undefined, async (cdp) => {
      console.log(JSON.stringify(await evaluate(cdp, a1)));
    });
  } else if (cmd === "text") {
    await withCdp(a1 || undefined, async (cdp) => {
      const raw = await evaluate(cdp, "document.body.innerText");
      // innerText comes from an uncontrolled page: strip C0 control chars and DEL
      // (but keep \t \n \r) so a hostile page can't inject terminal escapes or
      // NULs into an agent's stdout / a downstream parser.
      console.log(String(raw ?? "").replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, ""));
    });
  } else if (cmd === "screenshot") {
    if (!a1) throw new Error("usage: wsl-cdp screenshot FILE [TAB_ID]");
    await withCdp(a2 || undefined, async (cdp, t) => {
      const { data } = await cdp.send("Page.captureScreenshot", { format: "png" });
      const { writeFileSync } = await import("node:fs");
      const buf = Buffer.from(data, "base64");
      writeFileSync(a1, buf);
      console.log(`${a1} (${buf.length} bytes, tab ${t.id})`);
    });
  } else if (cmd === "upload") {
    if (!a1 || !a2) throw new Error("usage: wsl-cdp upload FILE SELECTOR [TAB_ID]");
    await withCdp(a3 || undefined, async (cdp, t) => {
      await cdp.send("DOM.enable");
      const { root } = await cdp.send("DOM.getDocument", { depth: 1 });
      const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector: a2 });
      if (!nodeId) throw new Error(`no element matches selector: ${a2}`);
      await cdp.send("DOM.setFileInputFiles", { files: [a1], nodeId });
      // setFileInputFiles alone does not reliably fire the page's own handlers
      // (measured against GitHub's social-preview uploader): dispatch input +
      // change on the same selector so uploader JS reacts.
      await evaluate(cdp, `(() => {
        const el = document.querySelector(${JSON.stringify(a2)});
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return true; })()`);
      console.log(`upload set: ${a1} -> ${a2} (tab ${t.id}); the page's own uploader takes it from here`);
    });
  } else {
    console.error("usage: wsl-cdp <eval|text|screenshot|upload> ...");
    process.exit(2);
  }
  process.exit(0);
} catch (e) {
  console.error(`wsl-cdp: ${e.message}`);
  process.exit(1);
}
