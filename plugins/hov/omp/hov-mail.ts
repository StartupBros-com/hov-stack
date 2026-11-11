// hov-mail: count-only mail delivery for oh-my-pi (OMP), from the hov plugin (hov-stack#529, PR 5).
//
// Before each turn this runs `hov notify`, which prints a <hov-mail> block naming how many unread messages
// this agent has and who sent them, when any arrived that this session was not told about yet, and puts
// that block into the run as a custom message. It never injects a body: the model reads mail with the hov
// MCP `inbox` tool (or `hov inbox`). It never changes what the session may do, and nothing here runs
// anything a message says. If hov is missing or fails, the turn proceeds without mail.
//
// Install: copy this file into ~/.omp/agent/extensions/. OMP loads extensions when it starts, so a running
// session is not affected until it is restarted. Plain JavaScript in a .ts file, so node loads it in tests.
//
// Environment: HOV_AS names this agent in the mailbox (default "omp"); HOV_BIN names the hov executable
// (default: ~/.local/bin/hov when it exists, else `hov` on PATH).

import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const NAME = process.env.HOV_AS || "omp";
const LOCAL_HOV = join(homedir(), ".local", "bin", "hov");
const HOV = process.env.HOV_BIN || (existsSync(LOCAL_HOV) ? LOCAL_HOV : "hov");
// When the host gives no session id, every turn of this process still counts as one session.
const FALLBACK_SESSION = `omp-${randomUUID()}`;

export default function (pi) {
  pi.on("before_agent_start", async (_event, ctx) => {
    try {
      let sid = "";
      try {
        sid = String(ctx?.sessionManager?.getSessionId?.() || "");
      } catch {
        sid = "";
      }
      if (!sid) sid = FALLBACK_SESSION;
      const out = await pi.exec(
        HOV,
        ["notify", "--as", NAME, "--session", sid, "--event", "before_agent_start", "--json"],
        { timeout: 5000 },
      );
      if (!out || out.code !== 0 || !out.stdout) return;
      const r = JSON.parse(out.stdout);
      if (!r || typeof r.text !== "string" || !r.text) return;
      return { message: { customType: "hov-mail", content: r.text, display: true } };
    } catch {
      return; // mail is never worth failing a turn over
    }
  });
}
