// hov-mail: count-only mail delivery for oh-my-pi (OMP), from the hov plugin (hov-stack#529, PR 5).
//
// Before each turn, after each tool result, and on a three-second timer this asks `hov notify` for a <hov-mail>
// count block, which it prints only for mail this session was not told about yet. Timer notices use OMP's
// non-interrupting aside queue: a busy agent sees one at its next step boundary, and an idle agent wakes unless
// OMP's plan mode or the user's Esc pause holds it. It never injects a body: the model reads mail with the hov
// MCP `inbox` tool (or the `hov inbox --as <name>` command the block prints). It never changes what the session
// may do, and nothing here runs anything a message says. If hov is missing or fails, the turn proceeds without mail.
//
// A check costs a stat, not a process. `hov notify` (about 40 ms of Python) runs only when the mailbox file or its
// WAL changed since this session's last clean poll, or on every 20th check (a minute of timer ticks), which bounds
// any change the file metadata missed. An empty poll writes nothing, so it never triggers the next one. The path
// comes from the poll's own JSON; an older hov that omits it is polled on every check.
//
// Install: copy this file into ~/.omp/agent/extensions/. OMP loads extensions when it starts, so a running
// session is not affected until it is restarted. Plain JavaScript in a .ts file, so node loads it in tests.
//
// A subagent turn (ctx.agent.kind === "sub") asks for nothing: a subagent shares the main session's mailbox
// name, so only the main session is told. The block goes in with attribution "agent", the value OMP gives its
// own injected messages, so it is never billed or shown as something the user typed.
//
// Environment: HOV_AS names this agent in the mailbox (default "omp"); HOV_BIN names the hov executable
// (default: ~/.local/bin/hov when it exists, else `hov` on PATH).

import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const NAME = process.env.HOV_AS || "omp";
const LOCAL_HOV = join(homedir(), ".local", "bin", "hov");
const HOV = process.env.HOV_BIN || (existsSync(LOCAL_HOV) ? LOCAL_HOV : "hov");
// When the host gives no session id, every turn of this process still counts as one session.
const FALLBACK_SESSION = `omp-${randomUUID()}`;
const POLL_MS = 3000;
const BACKSTOP = 20;

// Inode, size and mtime of the mailbox and its WAL. The -shm file is left out: readers touch it.
function signature(db) {
  return [db, `${db}-wal`]
    .map(p => {
      try {
        const s = statSync(p);
        return `${s.ino}:${s.size}:${s.mtimeMs}`;
      } catch {
        return "-";
      }
    })
    .join(" ");
}

export default function (pi) {
  let inFlight = false;
  let generation = 0;
  let stopped = false;
  let cancelTimer;
  let dbPath; // the mailbox file, as the last clean poll named it
  let seen; // { sid, sig }: the mailbox as it stood just before this session's last clean poll
  let skipped = 0;

  function sessionId(ctx) {
    try {
      return String(ctx?.sessionManager?.getSessionId?.() || FALLBACK_SESSION);
    } catch {
      return FALLBACK_SESSION;
    }
  }

  const message = text => ({ customType: "hov-mail", content: text, display: true, attribution: "agent" });

  async function notify(ctx, event) {
    if (stopped || inFlight || ctx?.agent?.kind === "sub") return;
    const sid = sessionId(ctx);
    const sig = dbPath && signature(dbPath);
    if (sig && seen?.sid === sid && seen.sig === sig && ++skipped < BACKSTOP) return;
    skipped = 0;
    inFlight = true;
    const started = generation;
    try {
      const out = await pi.exec(
        HOV,
        ["notify", "--as", NAME, "--session", sid, "--event", event, "--json"],
        { timeout: 5000 },
      );
      // A timer's pending exec can outlive a switch or shutdown. Never hand its result to a different run.
      if (stopped || started !== generation || sid !== sessionId(ctx)) return;
      if (!out || out.code !== 0 || out.killed || !out.stdout) return;
      const r = JSON.parse(out.stdout);
      // A clean poll handed this session everything written before `sig` was taken. A path that is new, moved
      // or missing (an older hov) gates nothing until the next clean poll records it.
      const db = typeof r?.db === "string" && r.db ? r.db : undefined;
      if (db !== dbPath) [dbPath, seen] = [db, undefined];
      else if (sig) seen = { sid, sig };
      if (r && typeof r.text === "string" && r.text) return r.text;
    } catch {
      return; // mail is never worth failing a turn over
    } finally {
      inFlight = false;
    }
  }

  function stop() {
    stopped = true;
    generation++;
    seen = undefined; // a new run starts with a real poll
    skipped = 0;
    cancelTimer?.();
    cancelTimer = undefined;
  }

  function start(_event, ctx) {
    stop();
    if (ctx?.agent?.kind === "sub") return;
    stopped = false;
    // Older OMP hosts can keep using the turn/tool handlers without managed timers.
    if (typeof ctx.setInterval !== "function") return;
    const started = generation;
    const timer = ctx.setInterval(async () => {
      const text = await notify(ctx, "poll");
      if (!text || stopped || started !== generation) return;
      try {
        // Aside reaches a busy agent at a step boundary and wakes an idle one. OMP itself preserves
        // plan mode and the user's Esc pause; do not use sendUserMessage, steer, or abort here.
        pi.sendMessage(message(text), { deliverAs: "aside" });
      } catch {
        // A host shutting down must not fail because a notification could not be queued.
      }
    }, POLL_MS);
    cancelTimer = () => ctx.clearTimer(timer);
  }

  pi.on("session_start", start);
  pi.on("session_switch", start);
  pi.on("session_shutdown", stop);
  pi.on("before_agent_start", async (_event, ctx) => {
    const text = await notify(ctx, "before_agent_start");
    if (text) return { message: message(text) };
  });
  pi.on("tool_result", async (_event, ctx) => {
    const text = await notify(ctx, "tool_result");
    if (text) return { additionalContext: text };
  });
}
