// @ts-nocheck
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const ESC = "\x1b";
const ST = `${ESC}\\`;

type ProgressMode = "none" | "indeterminate" | "error" | "percent";

function isWezTermSession() {
  return process.stdout.isTTY && (
    process.env.TERM_PROGRAM === "WezTerm" ||
    !!process.env.WEZTERM_EXECUTABLE ||
    !!process.env.WEZTERM_PANE
  );
}

function wrapForTmux(sequence: string) {
  return `${ESC}Ptmux;${sequence.replace(/\x1b/g, `${ESC}${ESC}`)}${ST}`;
}

function writeTerminalSequence(sequence: string) {
  if (!isWezTermSession()) return;
  process.stdout.write(process.env.TMUX ? wrapForTmux(sequence) : sequence);
}

function emitProgress(mode: ProgressMode, percent = 0) {
  const value = Math.max(0, Math.min(100, Math.floor(percent)));

  if (mode === "none") {
    writeTerminalSequence(`${ESC}]9;4;0;0${ST}`);
    return;
  }

  if (mode === "indeterminate") {
    writeTerminalSequence(`${ESC}]9;4;3;0${ST}`);
    return;
  }

  if (mode === "error") {
    writeTerminalSequence(`${ESC}]9;4;2;${value}${ST}`);
    return;
  }

  writeTerminalSequence(`${ESC}]9;4;1;${value}${ST}`);
}

export default function (_pi: ExtensionAPI) {
  let active = false;

  function clear(ctx?: ExtensionContext) {
    active = false;
    emitProgress("none");
    if (isWezTermSession()) ctx?.ui.setStatus("wezterm-progress", undefined);
  }

  function start(ctx?: ExtensionContext) {
    active = true;
    emitProgress("indeterminate");
    if (isWezTermSession()) ctx?.ui.setStatus("wezterm-progress", "wezterm-progress:on");
  }

  _pi.on("session_start", async (_event, ctx) => {
    clear(ctx);
  });

  _pi.on("session_switch", async (_event, ctx) => {
    clear(ctx);
  });

  _pi.on("session_fork", async (_event, ctx) => {
    clear(ctx);
  });

  _pi.on("agent_start", async (_event, ctx) => {
    start(ctx);
  });

  _pi.on("tool_execution_start", async (_event, ctx) => {
    if (!active) start(ctx);
    else emitProgress("indeterminate");
  });

  _pi.on("tool_execution_end", async (_event, ctx) => {
    if (active) emitProgress("indeterminate");
    else clear(ctx);
  });

  _pi.on("tool_result", async (event, _ctx) => {
    if (!active) return;

    const text = JSON.stringify(event.result ?? "").toLowerCase();
    if (text.includes("yes, allow once") || text.includes("allow always") || text.includes("(y/n)") || text.includes("do you trust")) {
      emitProgress("error", 100);
    }
  });

  _pi.on("agent_end", async (_event, ctx) => {
    clear(ctx);
  });

  _pi.on("session_shutdown", async (_event, ctx) => {
    clear(ctx);
  });
}
