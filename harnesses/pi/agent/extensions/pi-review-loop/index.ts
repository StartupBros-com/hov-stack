import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { promises as fs } from "node:fs";
import path from "node:path";
import { Type } from "@sinclair/typebox";
import { loadSettings, getReviewPrompt, type ReviewerLoopSettings, type ReviewPromptConfig } from "./settings.js";

export default function (pi: ExtensionAPI) {
  const isHeadlessJson = process.argv.includes("--mode") && process.argv.includes("json") || process.argv.some((arg) => arg === "--mode=json");
  if (isHeadlessJson) return;

  const TEMPLATE_MAX_ITERATIONS: Record<string, number> = {
    "skeptical-review": 1,
    "double-check-plan": 2,
  };
  const MAX_SKEPTICAL_TODOS = 12;

  let settings: ReviewerLoopSettings = loadSettings();
  let reviewModeActive = false;
  let currentIteration = 0;
  let customPromptSuffix = "";
  let freshContext = settings.freshContext;
  let activeFreshContextOverride: boolean | null = null;
  let reviewBoundaryCount = -1;
  let boundaryNeedsCapture = false;
  let activePromptConfig: ReviewPromptConfig = settings.reviewPromptConfig;
  let activePromptContextNote = "";

  function getEffectiveMaxIterations(promptConfig: ReviewPromptConfig = activePromptConfig): number {
    if (promptConfig.type === "template") {
      const cap = TEMPLATE_MAX_ITERATIONS[promptConfig.value];
      if (typeof cap === "number") return Math.min(settings.maxIterations, cap);
    }
    return settings.maxIterations;
  }

  function isSkepticalReviewPrompt(promptConfig: ReviewPromptConfig = activePromptConfig): boolean {
    return promptConfig.type === "template" && promptConfig.value === "skeptical-review";
  }

  function isFreshContextEnabled(): boolean {
    return activeFreshContextOverride ?? freshContext;
  }

  type SkepticalSourceContext = {
    source: "todo-frontmatter" | "context-manifest" | "heuristic" | "none";
    featureId?: string;
    topic?: string;
    planPath?: string;
    brainstormPath?: string;
    planKind?: string;
    phaseId?: string;
    parentPlanPath?: string;
  };

  function normalizeProjectPath(cwd: string, value: string | undefined): string | undefined {
    if (!value) return undefined;
    const trimmed = value.trim();
    if (!trimmed) return undefined;
    const absolute = path.isAbsolute(trimmed) ? trimmed : path.resolve(cwd, trimmed);
    return path.relative(cwd, absolute).replace(/\\/g, "/");
  }

  function parseFrontmatter(markdown: string): Record<string, string> {
    const normalized = markdown.replace(/\r\n/g, "\n");
    if (!normalized.startsWith("---\n")) return {};
    const end = normalized.indexOf("\n---\n", 4);
    if (end === -1) return {};

    const block = normalized.slice(4, end);
    const result: Record<string, string> = {};
    for (const rawLine of block.split("\n")) {
      const line = rawLine.trim();
      if (!line) continue;
      const match = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
      if (!match) continue;
      result[match[1]] = match[2].trim().replace(/^['"]|['"]$/g, "");
    }
    return result;
  }

  type PendingTodoMeta = {
    filePath: string;
    frontmatter: Record<string, string>;
    mtimeMs: number;
  };

  async function loadPendingTodos(cwd: string): Promise<PendingTodoMeta[]> {
    const todosDir = path.join(cwd, "todos");
    const todoEntries = await fs.readdir(todosDir, { withFileTypes: true }).catch(() => []);
    const pendingTodos = await Promise.all(
      todoEntries
        .filter((entry) => entry.isFile() && /-pending-.*\.md$/i.test(entry.name))
        .map(async (entry) => {
          const filePath = path.join(todosDir, entry.name);
          const markdown = await fs.readFile(filePath, "utf8").catch(() => "");
          if (!markdown.trim()) return null;
          const stat = await fs.stat(filePath).catch(() => null);
          return {
            filePath,
            frontmatter: parseFrontmatter(markdown),
            mtimeMs: stat?.mtimeMs ?? 0,
          } satisfies PendingTodoMeta;
        })
    );

    return pendingTodos
      .filter((todo): todo is PendingTodoMeta => Boolean(todo))
      .sort((a, b) => a.filePath.localeCompare(b.filePath));
  }

  async function resolveSkepticalSourceContext(
    cwd: string,
    pendingTodoPaths: string[],
    pendingTodoFrontmatters?: Record<string, string>[],
  ): Promise<SkepticalSourceContext> {
    const todoFrontmatters = pendingTodoFrontmatters ?? await Promise.all(
      pendingTodoPaths.map(async (filePath) => {
        const markdown = await fs.readFile(filePath, "utf8").catch(() => "");
        return parseFrontmatter(markdown);
      })
    );

    const singleValue = (values: Array<string | undefined>) => {
      const unique = [...new Set(values.filter((value): value is string => Boolean(value && value.trim())))];
      return unique.length === 1 ? unique[0] : undefined;
    };

    const todoContext: SkepticalSourceContext = {
      source: "todo-frontmatter",
      featureId: singleValue(todoFrontmatters.map((fm) => fm.source_feature_id)),
      topic: singleValue(todoFrontmatters.map((fm) => fm.source_topic)),
      planPath: singleValue(todoFrontmatters.map((fm) => normalizeProjectPath(cwd, fm.source_plan))),
      brainstormPath: singleValue(todoFrontmatters.map((fm) => normalizeProjectPath(cwd, fm.source_brainstorm))),
      planKind: singleValue(todoFrontmatters.map((fm) => fm.source_plan_kind)),
      phaseId: singleValue(todoFrontmatters.map((fm) => fm.source_phase_id)),
      parentPlanPath: singleValue(todoFrontmatters.map((fm) => normalizeProjectPath(cwd, fm.source_parent_plan))),
    };

    if (todoContext.featureId || todoContext.planPath || todoContext.brainstormPath) {
      return todoContext;
    }

    return { source: "none" };
  }

  async function buildSkepticalReviewContextNote(cwd: string): Promise<string> {
    const lines: string[] = [];
    const pendingTodos = await loadPendingTodos(cwd);
    const pendingTodoPaths = pendingTodos.map((todo) => todo.filePath).sort();
    const sourceContext = await resolveSkepticalSourceContext(
      cwd,
      pendingTodoPaths,
      pendingTodos.map((todo) => todo.frontmatter),
    );

    lines.push("## Skeptical review context");
    lines.push("");
    lines.push("This pass is for adjudicating Compound Engineering review findings, not for running a new broad code review.");
    lines.push("");

    if (pendingTodoPaths.length > 0) {
      lines.push("### Pending review todo files");
      lines.push("Read all pending review todo files first and update them via the `ce_todo` tool:");
      for (const filePath of pendingTodoPaths.slice(0, MAX_SKEPTICAL_TODOS)) {
        lines.push(`- ${path.relative(cwd, filePath)}`);
      }
      if (pendingTodoPaths.length > MAX_SKEPTICAL_TODOS) {
        lines.push(`- ... plus ${pendingTodoPaths.length - MAX_SKEPTICAL_TODOS} more pending todo(s)`);
      }
      lines.push("");
    } else {
      lines.push("### Pending review todo files");
      lines.push("No `*-pending-*.md` files were found under `todos/`.");
      lines.push("");
    }

    const distinctPlans = [...new Set(pendingTodos.map((todo) => normalizeProjectPath(cwd, todo.frontmatter.source_plan)).filter(Boolean))];
    const distinctPrs = [...new Set(pendingTodos.map((todo) => todo.frontmatter.source_pr).filter(Boolean))];
    const distinctFeatures = [...new Set(pendingTodos.map((todo) => todo.frontmatter.source_feature_id).filter(Boolean))];

    if (distinctPlans.length <= 1 && distinctPrs.length <= 1 && distinctFeatures.length <= 1) {
      lines.push("### Resolved feature intent context");
      lines.push(`Recovered from: ${sourceContext.source}`);
      if (sourceContext.featureId) lines.push(`- Feature ID: ${sourceContext.featureId}`);
      if (sourceContext.topic) lines.push(`- Topic: ${sourceContext.topic}`);
      if (sourceContext.planPath) lines.push(`- Plan: ${sourceContext.planPath}`);
      if (sourceContext.planKind) lines.push(`- Plan Kind: ${sourceContext.planKind}`);
      if (sourceContext.phaseId) lines.push(`- Phase: ${sourceContext.phaseId}`);
      if (sourceContext.parentPlanPath) lines.push(`- Parent Plan: ${sourceContext.parentPlanPath}`);
      if (sourceContext.brainstormPath) lines.push(`- Brainstorm: ${sourceContext.brainstormPath}`);
      lines.push("");
      lines.push("Use the resolved plan as the primary intent source. Only read the brainstorm when the plan is missing critical product intent, rejected alternatives, or explicit non-goals.");
    } else {
      lines.push("### Pending todo provenance");
      lines.push("These pending todos span multiple features / plans / PRs. Do not collapse them into one context. Use each todo's stamped provenance when adjudicating it.");
      lines.push("");
      for (const todo of pendingTodos.slice(0, MAX_SKEPTICAL_TODOS)) {
        const rel = path.relative(cwd, todo.filePath);
        lines.push(`- ${rel}`);
        if (todo.frontmatter.source_feature_id) lines.push(`  - Feature ID: ${todo.frontmatter.source_feature_id}`);
        if (todo.frontmatter.source_pr) lines.push(`  - PR: #${todo.frontmatter.source_pr}`);
        if (todo.frontmatter.source_branch) lines.push(`  - Branch: ${todo.frontmatter.source_branch}`);
        if (todo.frontmatter.source_plan) lines.push(`  - Plan: ${normalizeProjectPath(cwd, todo.frontmatter.source_plan)}`);
        if (todo.frontmatter.source_phase_id) lines.push(`  - Phase: ${todo.frontmatter.source_phase_id}`);
      }
      lines.push("");
      lines.push("When multiple pending todos belong to different features, adjudicate each one against its own plan / PR context instead of applying one shared intent model.");
    }
    lines.push("Do not invent a fresh broad review. Adjudicate the pending review findings against the actual intended feature scope.");
    lines.push("");

    lines.push("### Required outcome");
    lines.push("For each pending todo, decide whether it should become `ready`, remain `pending` with tighter scope, or become `wont_fix`. Update the markdown files and return a concise adjudication summary.");

    return lines.join("\n").trim();
  }

  function updateStatus(ctx: ExtensionContext) {
    try {
      if (!ctx.hasUI) return;
      if (reviewModeActive) {
        const parts = [`Review mode (${currentIteration + 1}/${getEffectiveMaxIterations()})`, getPromptModeLabel()];
        if (isFreshContextEnabled()) parts.push("fresh");
        ctx.ui.setStatus("review-loop", parts.join(" | "));
      } else {
        ctx.ui.setStatus("review-loop", undefined);
      }
    } catch {
      // Ignore stale/headless UI contexts after session replacement.
    }
  }

  function buildReviewPrompt(promptConfig: ReviewPromptConfig): string {
    let prompt = getReviewPrompt(promptConfig);
    if (activePromptContextNote) {
      prompt = `${prompt}\n\n${activePromptContextNote}`;
    }
    if (customPromptSuffix) {
      prompt = `${prompt}\n\n**Additional focus:** ${customPromptSuffix}`;
    }
    return prompt;
  }

  function parseCustomText(args: string): string {
    const trimmed = args.trim();
    if (!trimmed) return "";

    const match = trimmed.match(/^"(.+)"$/s) || trimmed.match(/^'(.+)'$/s);
    return match ? match[1].trim() : trimmed;
  }

  function getPromptModeLabel(): string {
    if (activePromptConfig.type === "template") {
      return `template:${activePromptConfig.value}`;
    }
    if (activePromptConfig.type === "file") {
      return `file:${activePromptConfig.value}`;
    }
    return "inline";
  }

  async function startReviewMode(
    ctx: ExtensionContext,
    promptConfig: ReviewPromptConfig,
    args: string,
    startedMessage: string
  ) {
    if (reviewModeActive) {
      ctx.ui.notify("Review mode is already active", "info");
      return false;
    }

    customPromptSuffix = parseCustomText(args);
    activePromptConfig = promptConfig;
    activeFreshContextOverride = isSkepticalReviewPrompt(promptConfig) ? false : null;
    activePromptContextNote = isSkepticalReviewPrompt(promptConfig)
      ? await buildSkepticalReviewContextNote(ctx.cwd)
      : "";

    enterReviewMode(ctx);
    if (isFreshContextEnabled() && reviewBoundaryCount < 0) boundaryNeedsCapture = true;
    pi.sendUserMessage(buildReviewPrompt(activePromptConfig));

    const effectiveMaxIterations = getEffectiveMaxIterations(promptConfig);
    const suffix = effectiveMaxIterations < settings.maxIterations
      ? ` Safety cap: ${effectiveMaxIterations} iteration${effectiveMaxIterations === 1 ? "" : "s"}.`
      : "";

    const modeNote = isSkepticalReviewPrompt(promptConfig)
      ? " Context-aware todo adjudication mode enabled."
      : "";

    ctx.ui.notify(`${startedMessage}${suffix}${modeNote}`, "info");
    return true;
  }

  function exitReviewMode(ctx: ExtensionContext, reason: string) {
    reviewModeActive = false;
    currentIteration = 0;
    customPromptSuffix = "";
    activePromptContextNote = "";
    activeFreshContextOverride = null;
    reviewBoundaryCount = -1;
    boundaryNeedsCapture = false;
    activePromptConfig = settings.reviewPromptConfig;
    updateStatus(ctx);
    ctx.ui.notify(`Review mode ended: ${reason}`, "info");
  }

  function enterReviewMode(ctx: ExtensionContext) {
    reviewModeActive = true;
    currentIteration = 0;
    reviewBoundaryCount = -1;
    boundaryNeedsCapture = false;
    updateStatus(ctx);
    try {
      if (ctx.hasUI) ctx.ui.notify("Review mode activated", "info");
    } catch {}
  }

  pi.on("session_start", async () => {
    settings = loadSettings();
    freshContext = settings.freshContext;
    activeFreshContextOverride = null;
    activePromptConfig = settings.reviewPromptConfig;
    activePromptContextNote = "";
    reviewModeActive = false;
    currentIteration = 0;
    customPromptSuffix = "";
    reviewBoundaryCount = -1;
    boundaryNeedsCapture = false;
  });

  pi.on("input", async (event, ctx) => {
    if (!ctx.hasUI) return { action: "continue" as const };

    const isTrigger = settings.autoTrigger && settings.triggerPatterns.some((p) => p.test(event.text));

    if (reviewModeActive && event.source === "interactive" && !isTrigger) {
      exitReviewMode(ctx, "user interrupted");
      return { action: "continue" as const };
    }

    if (isTrigger && !reviewModeActive) {
      enterReviewMode(ctx);
    }

    return { action: "continue" as const };
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!ctx.hasUI) return;
    if (reviewModeActive) return;
    if (!settings.autoTrigger) return;

    const isTrigger = settings.triggerPatterns.some((p) => p.test(event.prompt));
    if (isTrigger) {
      enterReviewMode(ctx);
    }
  });

  pi.on("context", async (event) => {
    if (!reviewModeActive || !isFreshContextEnabled()) return;

    const messages = event.messages;
    if (messages.length === 0) return;

    if (boundaryNeedsCapture) {
      for (let i = messages.length - 1; i >= 0; i--) {
        if (messages[i].role === "user") {
          reviewBoundaryCount = i;
          break;
        }
      }
      boundaryNeedsCapture = false;
    }

    if (currentIteration === 0) return;
    if (reviewBoundaryCount < 0) return;

    let lastUserIdx = -1;
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === "user") {
        lastUserIdx = i;
        break;
      }
    }
    if (lastUserIdx < 0) return;
    if (reviewBoundaryCount >= lastUserIdx) return;

    const preReview = messages.slice(0, reviewBoundaryCount);
    const currentIterationMsgs = messages.slice(lastUserIdx);

    const assembled: typeof messages = [...preReview];

    assembled.push({
      role: "user",
      content: [{
        type: "text",
        text: `[Review pass ${currentIteration + 1}. ${currentIteration} prior pass(es) completed, fixes applied to code. Re-read any relevant plan, spec, PRD, or progress documents before reviewing. Review with fresh eyes.]`,
      }],
      timestamp: Date.now(),
    } as any);

    assembled.push(...currentIterationMsgs);

    return { messages: assembled };
  });

  pi.on("agent_end", async (event, ctx) => {
    if (!ctx.hasUI) return;
    if (!reviewModeActive) return;

    const assistantMessages = event.messages.filter((m) => m.role === "assistant");
    const lastAssistantMessage = assistantMessages[assistantMessages.length - 1];

    if (!lastAssistantMessage) {
      exitReviewMode(ctx, "aborted");
      return;
    }

    const textContent = lastAssistantMessage.content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map((c) => c.text)
      .join("\n");

    if (!textContent.trim()) {
      exitReviewMode(ctx, "aborted");
      return;
    }

    const hasExitPhrase = settings.exitPatterns.some((p) => p.test(textContent));
    const hasIssuesFixed = settings.issuesFixedPatterns.some((p) =>
      p.test(textContent)
    );

    if (hasExitPhrase && !hasIssuesFixed) {
      exitReviewMode(ctx, "no issues found");
      return;
    }

    currentIteration++;
    const effectiveMaxIterations = getEffectiveMaxIterations();
    if (currentIteration >= effectiveMaxIterations) {
      exitReviewMode(ctx, `max iterations (${effectiveMaxIterations}) reached`);
      return;
    }

    if (isFreshContextEnabled() && reviewBoundaryCount < 0) boundaryNeedsCapture = true;
    updateStatus(ctx);
    pi.sendUserMessage(buildReviewPrompt(activePromptConfig), {
      deliverAs: "followUp",
    });
  });

  pi.registerCommand("review-start", {
    description: "Activate review loop with optional custom focus text.",
    handler: async (args, ctx) => {
      await startReviewMode(ctx, settings.reviewPromptConfig, args, "Review mode started. Review prompt sent.");
    },
  });

  pi.registerCommand("review-plan", {
    description: "Activate review loop for plans/specs/PRDs with optional custom focus text.",
    handler: async (args, ctx) => {
      await startReviewMode(
        ctx,
        { type: "template", value: "double-check-plan" },
        args,
        "Plan review mode started. Review prompt sent."
      );
    },
  });

  pi.registerCommand("review-skeptical", {
    description: "Adjudicate Compound Engineering review todos using implementation context from this session.",
    handler: async (args, ctx) => {
      await startReviewMode(
        ctx,
        { type: "template", value: "skeptical-review" },
        args,
        "Skeptical review mode started. Review prompt sent."
      );
    },
  });

  pi.registerCommand("review-max", {
    description: "Set max review iterations (some templates enforce lower safety caps)",
    handler: async (args, ctx) => {
      const num = parseInt(args, 10);
      if (isNaN(num) || num < 1) {
        ctx.ui.notify("Usage: /review-max <number>", "error");
        return;
      }
      settings.maxIterations = num;
      ctx.ui.notify(`Max review iterations set to ${settings.maxIterations}`, "info");
    },
  });

  pi.registerCommand("review-exit", {
    description: "Exit review mode manually",
    handler: async (_args, ctx) => {
      if (reviewModeActive) {
        exitReviewMode(ctx, "manual exit");
      } else {
        ctx.ui.notify("Review mode is not active", "info");
      }
    },
  });

  pi.registerCommand("review-status", {
    description: "Show review mode status",
    handler: async (_args, ctx) => {
      const effectiveMaxIterations = getEffectiveMaxIterations();
      if (reviewModeActive) {
        const parts = [`iteration ${currentIteration + 1}/${effectiveMaxIterations}`, getPromptModeLabel()];
        if (isFreshContextEnabled()) parts.push("fresh context");
        if (effectiveMaxIterations < settings.maxIterations) parts.push(`safety cap ${effectiveMaxIterations}`);
        ctx.ui.notify(`Review mode active: ${parts.join(", ")}`, "info");
      } else {
        const capNote = effectiveMaxIterations < settings.maxIterations ? `, effective max: ${effectiveMaxIterations}` : "";
        ctx.ui.notify(
          `Review mode inactive (max: ${settings.maxIterations}${capNote}, auto-trigger: ${settings.autoTrigger ? "on" : "off"}, fresh: ${freshContext ? "on" : "off"})`,
          "info"
        );
      }
    },
  });

  pi.registerCommand("review-auto", {
    description: "Toggle auto-trigger, or start review with custom focus: /review-auto focus on X",
    handler: async (args, ctx) => {
      const arg = args.trim();
      const argLower = arg.toLowerCase();

      if (argLower === "on" || argLower === "true" || argLower === "1") {
        settings.autoTrigger = true;
        ctx.ui.notify(`Auto-trigger enabled`, "info");
        return;
      }
      if (argLower === "off" || argLower === "false" || argLower === "0") {
        settings.autoTrigger = false;
        ctx.ui.notify(`Auto-trigger disabled`, "info");
        return;
      }
      if (arg === "") {
        settings.autoTrigger = !settings.autoTrigger;
        ctx.ui.notify(
          `Auto-trigger ${settings.autoTrigger ? "enabled" : "disabled"}`,
          "info"
        );
        return;
      }

      settings.autoTrigger = true;
      customPromptSuffix = parseCustomText(arg);
      if (reviewModeActive) {
        ctx.ui.notify(`Auto-trigger enabled, focus updated for next iteration`, "info");
      } else {
        activePromptConfig = settings.reviewPromptConfig;
        activePromptContextNote = "";
        activeFreshContextOverride = null;
        enterReviewMode(ctx);
        if (isFreshContextEnabled() && reviewBoundaryCount < 0) boundaryNeedsCapture = true;
        pi.sendUserMessage(buildReviewPrompt(activePromptConfig));
        ctx.ui.notify(`Auto-trigger enabled, review started with custom focus`, "info");
      }
    },
  });

  pi.registerCommand("review-fresh", {
    description: "Toggle fresh context mode for review iterations",
    handler: async (args, ctx) => {
      const arg = args.trim().toLowerCase();

      if (arg === "on" || arg === "true" || arg === "1") {
        freshContext = true;
      } else if (arg === "off" || arg === "false" || arg === "0") {
        freshContext = false;
      } else {
        freshContext = !freshContext;
      }
      ctx.ui.notify(`Fresh context ${freshContext ? "enabled" : "disabled"}`, "info");
    },
  });

  pi.registerTool({
    name: "review_loop",
    description:
      "Control the automated code review loop. Start/stop review mode, toggle auto-trigger, choose a review prompt template, or check status. When started, the loop repeatedly prompts for code review until 'No issues found' or max iterations reached.",
    parameters: Type.Object({
      start: Type.Optional(
        Type.Boolean({
          description: "Start review mode and send the review prompt",
        })
      ),
      stop: Type.Optional(
        Type.Boolean({
          description: "Stop review mode",
        })
      ),
      autoTrigger: Type.Optional(
        Type.Boolean({
          description: "Enable/disable auto-trigger from keywords (disabled by default)",
        })
      ),
      maxIterations: Type.Optional(
        Type.Number({
          description: "Set max iterations (can be combined with start)",
          minimum: 1,
        })
      ),
      focus: Type.Optional(
        Type.String({
          description: "Custom focus/instructions to append to the review prompt (e.g., \"focus on error handling\")",
        })
      ),
      promptTemplate: Type.Optional(
        Type.String({
          description: "Prompt template name from ~/.pi/agent/prompts (for example: skeptical-review or double-check-plan)",
        })
      ),
      freshContext: Type.Optional(
        Type.Boolean({
          description: "Enable/disable fresh context mode (strips prior review iterations from context)",
        })
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (typeof params.maxIterations === "number" && params.maxIterations >= 1) {
        settings.maxIterations = params.maxIterations;
      }

      if (typeof params.autoTrigger === "boolean") {
        settings.autoTrigger = params.autoTrigger;
        ctx.ui.notify(
          `Auto-trigger ${settings.autoTrigger ? "enabled" : "disabled"}`,
          "info"
        );
      }

      if (typeof params.focus === "string") {
        customPromptSuffix = params.focus.trim();
      }

      if (typeof params.promptTemplate === "string" && params.promptTemplate.trim()) {
        activePromptConfig = {
          type: "template",
          value: params.promptTemplate.trim(),
        };
      }

      if (typeof params.freshContext === "boolean") {
        freshContext = params.freshContext;
        ctx.ui.notify(
          `Fresh context ${freshContext ? "enabled" : "disabled"}`,
          "info"
        );
      }

      const effectiveMaxIterations = getEffectiveMaxIterations();

      if (params.start) {
        if (reviewModeActive) {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  active: true,
                  currentIteration,
                  maxIterations: effectiveMaxIterations,
                  configuredMaxIterations: settings.maxIterations,
                  autoTrigger: settings.autoTrigger,
                  freshContext: isFreshContextEnabled(),
                  promptTemplate: getPromptModeLabel(),
                  focus: customPromptSuffix || undefined,
                  message: "Review mode is already active",
                }),
              },
            ],
          };
        }

        if (!(typeof params.promptTemplate === "string" && params.promptTemplate.trim())) {
          activePromptConfig = settings.reviewPromptConfig;
        }
        activeFreshContextOverride = isSkepticalReviewPrompt(activePromptConfig) ? false : null;
        activePromptContextNote = isSkepticalReviewPrompt(activePromptConfig)
          ? await buildSkepticalReviewContextNote(ctx.cwd)
          : "";
        enterReviewMode(ctx);
        if (isFreshContextEnabled() && reviewBoundaryCount < 0) boundaryNeedsCapture = true;
        pi.sendUserMessage(buildReviewPrompt(activePromptConfig));

        const startedEffectiveMaxIterations = getEffectiveMaxIterations();
        const safetyCapNote = startedEffectiveMaxIterations < settings.maxIterations
          ? ` Safety cap: ${startedEffectiveMaxIterations} iteration${startedEffectiveMaxIterations === 1 ? "" : "s"}.`
          : "";

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                active: true,
                currentIteration,
                maxIterations: startedEffectiveMaxIterations,
                configuredMaxIterations: settings.maxIterations,
                autoTrigger: settings.autoTrigger,
                freshContext: isFreshContextEnabled(),
                promptTemplate: getPromptModeLabel(),
                focus: customPromptSuffix || undefined,
                message: customPromptSuffix
                  ? `Review mode started with custom focus. Review prompt sent.${safetyCapNote}`
                  : `Review mode started. Review prompt sent.${safetyCapNote}`,
              }),
            },
          ],
        };
      }

      if (params.stop) {
        if (!reviewModeActive) {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  active: false,
                  currentIteration: 0,
                  maxIterations: effectiveMaxIterations,
                  configuredMaxIterations: settings.maxIterations,
                  autoTrigger: settings.autoTrigger,
                  freshContext: isFreshContextEnabled(),
                  promptTemplate: getPromptModeLabel(),
                  message: "Review mode is not active",
                }),
              },
            ],
          };
        }

        exitReviewMode(ctx, "stopped by agent");

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                active: false,
                currentIteration: 0,
                maxIterations: getEffectiveMaxIterations(),
                configuredMaxIterations: settings.maxIterations,
                autoTrigger: settings.autoTrigger,
                freshContext: isFreshContextEnabled(),
                promptTemplate: getPromptModeLabel(),
                message: "Review mode stopped",
              }),
            },
          ],
        };
      }

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              active: reviewModeActive,
              currentIteration,
              maxIterations: effectiveMaxIterations,
              configuredMaxIterations: settings.maxIterations,
              autoTrigger: settings.autoTrigger,
              freshContext: isFreshContextEnabled(),
              promptTemplate: getPromptModeLabel(),
              focus: customPromptSuffix || undefined,
              message: reviewModeActive
                ? `Review mode active: iteration ${currentIteration + 1}/${effectiveMaxIterations}`
                : "Review mode inactive",
            }),
          },
        ],
      };
    },
  });
}
