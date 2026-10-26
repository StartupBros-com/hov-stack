// @ts-nocheck
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const IDLE_ICON = "󰚩";

const LANE_ALIASES: Record<string, string> = {
  "review-skeptical": "review",
  "skeptical-review": "review",
  "double-check": "verify",
  "double-check-plan": "verify",
  "workflows-plan": "plan",
  "workflows-work": "work",
  "workflows-brainstorm": "brainstorm",
  "workflows-compound": "compound",
  "workflows-review": "review",
  "resolve-todo-parallel": "todo",
  "resolve-pr-parallel": "pr",
  "resolve-parallel": "resolve",
  "test-browser": "browser",
  "feature-video": "video",
  "report-bug": "bug",
  "reproduce-bug": "debug",
  "changelog": "changelog",
  "commit": "commit",
  "lfg": "lfg",
  "slfg": "swarm",
};

const TOOL_ALIASES: Record<string, string> = {
  bash: "bash",
  read: "read",
  edit: "edit",
  write: "write",
  lsp: "lsp",
  WebSearch: "search",
  web_search_exa: "search",
  firecrawl_search: "search",
  WebFetch: "fetch",
  firecrawl_scrape: "fetch",
  firecrawl_map: "map",
  review_loop: "review",
  subagent: "agents",
  todo: "todo",
  ask_user_question: "ask",
};

type TitleState = {
  repo: string;
  lane: string;
  session: string;
  model: string;
  active: boolean;
  tool: string;
};

function compactWords(value: string, max = 14) {
  const cleaned = value
    .trim()
    .toLowerCase()
    .replace(/^skill:/, "")
    .replace(/^\/+/, "")
    .replace(/[._:]+/g, "-")
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  if (!cleaned) return "";
  if (LANE_ALIASES[cleaned]) return LANE_ALIASES[cleaned];
  if (cleaned.length <= max) return cleaned;

  const pieces = cleaned.split("-").filter(Boolean);
  const compact = pieces
    .map((piece, index) => (index === 0 ? piece : piece.slice(0, 4)))
    .join("-");

  return compact.slice(0, max);
}

function shortModel(provider?: string, modelId?: string) {
  if (!provider || !modelId) return "";

  if (provider === "openai-codex") {
    const gpt5 = modelId.match(/^gpt-5(?:\.(\d+))?$/);
    if (gpt5) return gpt5[1] ? `g5.${gpt5[1]}` : "g5";
    return compactWords(modelId, 10);
  }

  if (provider === "anthropic") {
    const family = modelId.match(/^claude-(opus|sonnet|haiku)-(.+)$/);
    if (family) return family[1];
    return compactWords(modelId.replace(/^claude-/, ""), 10);
  }

  if (provider === "google") {
    return modelId.startsWith("gemini") ? compactWords(modelId.replace(/^gemini-?/, "gm-"), 10) : compactWords(modelId, 10);
  }

  return compactWords(modelId, 10);
}

function detectLane(prompt: string) {
  const trimmed = prompt.trim();
  if (!trimmed) return "";

  const slash = trimmed.match(/^\/([^\s]+)/);
  if (slash) return compactWords(slash[1]);

  if (/\breview\b/i.test(trimmed)) return "review";
  if (/\bplan\b/i.test(trimmed)) return "plan";
  if (/\bdebug\b|\bbug\b/i.test(trimmed)) return "debug";
  if (/\brefactor\b|\bimplement\b|\bbuild\b/i.test(trimmed)) return "build";
  return "";
}

function shortTool(toolName: string) {
  return TOOL_ALIASES[toolName] || compactWords(toolName, 12);
}

function buildTitle(state: TitleState, frame?: string) {
  const parts = [state.repo];

  const lane = state.lane || state.session;
  if (lane) parts.push(lane);
  if (state.model) parts.push(state.model);
  if (state.tool) parts.push(state.tool);
  else if (state.active) parts.push("think");

  return `${frame || IDLE_ICON} π ${parts.join(" · ")}`;
}

function buildStatus(state: TitleState) {
  const parts = [] as string[];
  const lane = state.lane || state.session;
  if (lane) parts.push(lane);
  if (state.model) parts.push(state.model);
  if (state.tool) parts.push(state.tool);
  else parts.push(state.active ? "thinking" : "ready");
  return `󰚩 ${parts.join(" · ")}`;
}

export default function (pi: ExtensionAPI) {
  const isHeadlessJson = process.argv.includes("--mode") && process.argv.includes("json") || process.argv.some((arg) => arg === "--mode=json");
  if (isHeadlessJson) return;

  const state: TitleState = {
    repo: path.basename(process.cwd()),
    lane: "",
    session: "",
    model: "",
    active: false,
    tool: "",
  };

  let timer: ReturnType<typeof setInterval> | undefined;
  let frameIndex = 0;

  function refreshSessionState() {
    state.repo = path.basename(process.cwd());
    state.session = compactWords(pi.getSessionName() || "", 14);

    const model = pi.getModel?.();
    state.model = shortModel(model?.provider, model?.id);
  }

  function applyUi(ctx: ExtensionContext): boolean {
    try {
      if (!ctx.hasUI) return false;
      ctx.ui.setTitle(buildTitle(state));
      ctx.ui.setStatus("pi-ai-title", buildStatus(state));
      return true;
    } catch {
      if (timer) {
        clearInterval(timer);
        timer = undefined;
      }
      return false;
    }
  }

  function stopSpinner(ctx: ExtensionContext) {
    if (timer) {
      clearInterval(timer);
      timer = undefined;
    }
    frameIndex = 0;
    applyUi(ctx);
  }

  function startSpinner(ctx: ExtensionContext) {
    stopSpinner(ctx);
    try {
      if (!ctx.hasUI) return;
    } catch {
      return;
    }
    timer = setInterval(() => {
      const frame = SPINNER_FRAMES[frameIndex % SPINNER_FRAMES.length];
      try {
        ctx.ui.setTitle(buildTitle(state, frame));
      } catch {
        if (timer) {
          clearInterval(timer);
          timer = undefined;
        }
      }
      frameIndex++;
    }, 90);
  }

  pi.on("session_start", async (_event, ctx) => {
    refreshSessionState();
    state.active = false;
    state.tool = "";
    applyUi(ctx);
  });

  pi.on("session_switch", async (_event, ctx) => {
    refreshSessionState();
    state.active = false;
    state.tool = "";
    applyUi(ctx);
  });

  pi.on("session_fork", async (_event, ctx) => {
    refreshSessionState();
    applyUi(ctx);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    refreshSessionState();
    const lane = detectLane(event.prompt);
    if (lane) state.lane = lane;
    applyUi(ctx);
  });

  pi.on("model_select", async (event, ctx) => {
    state.model = shortModel(event.model.provider, event.model.id);
    applyUi(ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    refreshSessionState();
    state.active = true;
    state.tool = "";
    startSpinner(ctx);
  });

  pi.on("tool_execution_start", async (event, ctx) => {
    state.tool = shortTool(event.toolName);
    if (state.active && !timer) startSpinner(ctx);
    else applyUi(ctx);
  });

  pi.on("tool_execution_end", async (_event, ctx) => {
    state.tool = "";
    if (state.active && !timer) startSpinner(ctx);
    else applyUi(ctx);
  });

  pi.on("agent_end", async (_event, ctx) => {
    state.active = false;
    state.tool = "";
    stopSpinner(ctx);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    stopSpinner(ctx);
    try {
      if (!ctx.hasUI) return;
      ctx.ui.setStatus("pi-ai-title", undefined);
    } catch {}
  });
}
