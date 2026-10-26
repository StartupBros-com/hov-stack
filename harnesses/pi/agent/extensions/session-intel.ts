// @ts-nocheck
/**
 * Session Intelligence Extension
 *
 * A quiet, power-user session lifecycle layer for pi:
 * - stable AI session names for /resume
 * - durable per-session handoff files outside the conversation
 * - high-fidelity custom compaction summaries via session_before_compact
 * - tiny widget showing durable next step / handoff staleness
 *
 * This intentionally avoids recap-after-every-turn noise. It syncs at natural
 * breakpoints, on demand, and before compaction.
 */

import { existsSync } from "node:fs";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

import { completeSimple } from "@mariozechner/pi-ai";
import {
	convertToLlm,
	getAgentDir,
	serializeConversation,
	type ExtensionAPI,
	type ExtensionContext,
} from "@mariozechner/pi-coding-agent";

const WIDGET_KEY = "session-intel";
const CUSTOM_TYPE = "session-intel";
const CONFIG_NAME = "session-intel.json";

interface SessionIntelConfig {
	enabled: boolean;
	provider?: string;
	model?: string;
	autoName: boolean;
	injectHandoff: boolean;
	showWidget: boolean;
	customCompaction: boolean;
	autoHandoff: boolean;
	contextSyncThreshold: number;
	minTurnsBetweenHandoffs: number;
	minSecondsBetweenHandoffs: number;
	maxPromptChars: number;
	maxInjectChars: number;
	maxSummaryTokens: number;
	verbose: boolean;
}

const DEFAULT_CONFIG: SessionIntelConfig = {
	enabled: true,
	autoName: true,
	injectHandoff: true,
	showWidget: true,
	customCompaction: true,
	autoHandoff: true,
	contextSyncThreshold: 0.62,
	minTurnsBetweenHandoffs: 6,
	minSecondsBetweenHandoffs: 300,
	maxPromptChars: 36_000,
	maxInjectChars: 3_500,
	maxSummaryTokens: 2_500,
	verbose: false,
};

const PREFERRED_SUMMARY_MODELS = [
	{ provider: "openai-codex", id: "gpt-5.4-nano" },
	{ provider: "openai-codex", id: "gpt-5.4-mini" },
	{ provider: "anthropic", id: "claude-haiku-4-5" },
	{ provider: "google", id: "gemini-3-flash" },
];

const NAME_SYSTEM_PROMPT = `You name coding-agent sessions for a power user.
Return exactly one concise session title, 4-9 words, no punctuation at the end.
Prefer concrete nouns, repo concepts, and the user's actual objective.
Do not mention "session", "conversation", "user", or "assistant".`;

const HANDOFF_SYSTEM_PROMPT = `You write durable handoff notes for a coding-agent session.
The note will be stored outside the conversation and may be injected into future sessions or compaction summaries.
Be concise, factual, and operational. Preserve exact file paths, commands, errors, decisions, and next actions.
Do not describe generic activity; capture resumable state.

Use exactly this markdown structure:
# Session Handoff

## Goal
- ...

## Current State
- ...

## Decisions
- **Decision:** rationale

## Changed / Important Files
- path — why it matters

## Validation
- Commands run and results, or "None recorded"

## Risks / Blockers
- ...

## Next Steps
1. ...

## Last Updated
- ISO timestamp — one-line note`;

const COMPACTION_SYSTEM_PROMPT = `You create structured context checkpoints for pi coding-agent compaction.
This replaces the default compact summary. Optimize for a future model continuing the exact work with minimal recovery turns.
Preserve the user's goal, current implementation state, decisions and rationale, modified files, read files, validation, blockers, and exact next steps.
Drop noisy tool output and failed dead-end details unless they prevent repeated mistakes.

Use exactly this markdown structure:
## Goal
[Current user objective]

## Durable State / Handoff
[Relevant saved handoff or autonomy status]

## Constraints & Preferences
- ...

## Progress
### Done
- [x] ...

### In Progress
- [ ] ...

### Blocked
- ...

## Key Decisions
- **Decision:** rationale

## Important Files
- path — read/modified/reason

## Validation
- command — result

## Next Steps
1. ...

## Critical Context
- ...`;

function nowIso(): string {
	return new Date().toISOString();
}

function trimForPrompt(text: string, maxChars: number): string {
	if (text.length <= maxChars) return text;
	return `${text.slice(0, maxChars)}\n\n[... truncated ${text.length - maxChars} chars ...]`;
}

function stripCodeFences(text: string): string {
	let out = text.trim();
	out = out.replace(/^```(?:markdown|md|text)?\s*/i, "");
	out = out.replace(/\s*```$/i, "");
	return out.trim();
}

function extractText(response: any): string {
	return (response?.content ?? [])
		.filter((c: any) => c?.type === "text" && typeof c.text === "string")
		.map((c: any) => c.text)
		.join("\n")
		.trim();
}

function shortHash(value: string): string {
	return crypto.createHash("sha1").update(value).digest("hex").slice(0, 12);
}

function slug(value: string): string {
	return value
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-|-$/g, "")
		.slice(0, 48) || "project";
}

function sessionId(ctx: ExtensionContext): string {
	return ctx.sessionManager.getSessionId?.() || shortHash(ctx.sessionManager.getSessionFile?.() || `${ctx.cwd}:${Date.now()}`);
}

function repoName(cwd: string): string {
	let current = path.resolve(cwd);
	while (true) {
		if (existsSync(path.join(current, ".git"))) return path.basename(current);
		const parent = path.dirname(current);
		if (parent === current) return path.basename(cwd) || "cwd";
		current = parent;
	}
}

function intelRootForCwd(cwd: string): string {
	return path.join(getAgentDir(), "session-intel", `${slug(repoName(cwd))}-${shortHash(path.resolve(cwd))}`);
}

function handoffPath(ctx: ExtensionContext): string {
	return path.join(intelRootForCwd(ctx.cwd), `${sessionId(ctx)}.md`);
}

function configPaths(cwd: string): string[] {
	return [path.join(getAgentDir(), CONFIG_NAME), path.join(cwd, ".pi", CONFIG_NAME)];
}

async function readIfExists(filePath: string): Promise<string | null> {
	try {
		return await fs.readFile(filePath, "utf8");
	} catch {
		return null;
	}
}

async function loadConfig(cwd: string): Promise<SessionIntelConfig> {
	let config = { ...DEFAULT_CONFIG };
	for (const filePath of configPaths(cwd)) {
		const text = await readIfExists(filePath);
		if (!text) continue;
		try {
			config = { ...config, ...JSON.parse(text) };
		} catch (error) {
			console.error(`[session-intel] Failed to parse ${filePath}:`, error);
		}
	}
	return config;
}

async function writeDefaultConfig(ctx: ExtensionContext): Promise<string> {
	const filePath = path.join(getAgentDir(), CONFIG_NAME);
	await fs.mkdir(path.dirname(filePath), { recursive: true });
	if (!existsSync(filePath)) {
		await fs.writeFile(filePath, JSON.stringify(DEFAULT_CONFIG, null, 2) + "\n", "utf8");
	}
	return filePath;
}

function getBranchMessages(ctx: ExtensionContext): any[] {
	return ctx.sessionManager
		.getBranch()
		.filter((entry: any) => entry.type === "message")
		.map((entry: any) => entry.message);
}

function serializeMessages(messages: any[], maxChars: number): string {
	try {
		return trimForPrompt(serializeConversation(convertToLlm(messages)), maxChars);
	} catch {
		return trimForPrompt(messages.map((m) => JSON.stringify(m)).join("\n"), maxChars);
	}
}

function usagePercent(ctx: ExtensionContext): number | null {
	const usage = ctx.getContextUsage?.();
	if (!usage) return null;
	const used = Number(usage.tokens ?? usage.messageTokens ?? usage.effectiveTokens ?? 0);
	const total = Number(usage.contextWindow ?? usage.maxTokens ?? 0);
	if (!Number.isFinite(used) || !Number.isFinite(total) || total <= 0) return null;
	return used / total;
}

function normalizeTitle(text: string): string {
	return stripCodeFences(text)
		.split(/\r?\n/)[0]
		.replace(/^[-*#\s"']+/, "")
		.replace(/["'.\s]+$/, "")
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, 90);
}

function getFileOps(preparation: any): { readFiles: string[]; modifiedFiles: string[] } {
	const fileOps = preparation?.fileOps ?? {};
	const readFiles = Array.from(fileOps.read ?? fileOps.readFiles ?? []).map(String).sort();
	const edited = fileOps.edited ?? fileOps.modified ?? fileOps.modifiedFiles ?? [];
	const modifiedFiles = Array.from(edited).map(String).sort();
	return { readFiles, modifiedFiles };
}

function firstNextStep(markdown: string): string | null {
	const lines = markdown.split(/\r?\n/);
	let inNext = false;
	for (const line of lines) {
		if (/^##\s+Next Steps\b/i.test(line.trim()) || /^##\s+Next\b/i.test(line.trim())) {
			inNext = true;
			continue;
		}
		if (inNext && /^##\s+/.test(line.trim())) break;
		if (inNext) {
			const match = line.match(/^\s*(?:[-*]|\d+\.)\s+(.+)$/);
			if (match?.[1]?.trim()) return match[1].trim();
		}
	}
	return null;
}

function updateWidget(ctx: ExtensionContext, config: SessionIntelConfig, handoffText: string | null, lastSyncTime: number) {
	try {
		if (!ctx.hasUI || !config.showWidget) return;
		if (!handoffText) {
			ctx.ui.setWidget(WIDGET_KEY, undefined);
			return;
		}

		const next = firstNextStep(handoffText);
		const ageMs = lastSyncTime ? Date.now() - lastSyncTime : 0;
		const age = ageMs > 0 ? `${Math.max(1, Math.round(ageMs / 60_000))}m` : "fresh";
		const pct = usagePercent(ctx);
		const pctText = pct === null ? "" : ` • ctx ${Math.round(pct * 100)}%`;
		const line = next
			? `Intel ${age}${pctText} — Next: ${next.slice(0, 130)}`
			: `Intel ${age}${pctText} — handoff saved`;
		ctx.ui.setWidget(WIDGET_KEY, [ctx.ui.theme.fg("muted", line)]);
	} catch {
		// Ignore stale/headless UI contexts after session replacement.
	}
}

function resolveSummaryModel(ctx: ExtensionContext, config: SessionIntelConfig): any | undefined {
	if (config.provider && config.model) {
		const explicit = ctx.modelRegistry.find(config.provider, config.model);
		if (explicit) return explicit;
	}

	const available = ctx.modelRegistry.getAvailable?.() ?? [];
	for (const wanted of PREFERRED_SUMMARY_MODELS) {
		const match = available.find((m: any) => m.provider === wanted.provider && m.id === wanted.id)
			?? available.find((m: any) => m.id === wanted.id);
		if (match) return match;
	}

	return ctx.model;
}

async function completeIntel(ctx: ExtensionContext, config: SessionIntelConfig, systemPrompt: string, userText: string, signal?: AbortSignal): Promise<string | null> {
	const model = resolveSummaryModel(ctx, config);
	if (!model) return null;
	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth?.ok || !auth.apiKey) return null;

	const response = await completeSimple(
		model,
		{
			systemPrompt,
			messages: [{ role: "user", content: [{ type: "text", text: userText }], timestamp: Date.now() }],
		},
		{
			apiKey: auth.apiKey,
			headers: auth.headers,
			maxTokens: config.maxSummaryTokens,
			signal,
		},
	);

	if (response.stopReason === "error" || response.stopReason === "aborted") return null;
	return stripCodeFences(extractText(response));
}

async function readDurableContext(ctx: ExtensionContext, config: SessionIntelConfig): Promise<{ handoff: string | null; autonomyStatus: string | null }> {
	const handoff = await readIfExists(handoffPath(ctx));
	const autonomyStatus = await readIfExists(path.join(ctx.cwd, ".pi", "autonomy", "status.md"));
	return {
		handoff: handoff ? trimForPrompt(handoff, config.maxInjectChars) : null,
		autonomyStatus: autonomyStatus ? trimForPrompt(autonomyStatus, config.maxInjectChars) : null,
	};
}

async function generateName(ctx: ExtensionContext, config: SessionIntelConfig, hint?: string): Promise<string | null> {
	const messages = getBranchMessages(ctx).slice(-12);
	const transcript = serializeMessages(messages, 12_000);
	const userText = [
		`Repo: ${repoName(ctx.cwd)}`,
		hint ? `Hint: ${hint}` : "Hint: none",
		"Conversation excerpt:",
		transcript,
	].join("\n\n");
	const raw = await completeIntel(ctx, { ...config, maxSummaryTokens: 80 }, NAME_SYSTEM_PROMPT, userText, ctx.signal);
	const title = raw ? normalizeTitle(raw) : null;
	return title && title.length >= 3 ? title : null;
}

async function generateHandoff(ctx: ExtensionContext, config: SessionIntelConfig, note: string, signal?: AbortSignal): Promise<string | null> {
	const { handoff, autonomyStatus } = await readDurableContext(ctx, config);
	const messages = getBranchMessages(ctx);
	const transcript = serializeMessages(messages, config.maxPromptChars);
	const userText = [
		`Repo: ${repoName(ctx.cwd)}`,
		`CWD: ${ctx.cwd}`,
		`Session file: ${ctx.sessionManager.getSessionFile?.() ?? "(ephemeral)"}`,
		`Timestamp: ${nowIso()}`,
		note ? `User note: ${note}` : "User note: none",
		handoff ? `<previous-handoff>\n${handoff}\n</previous-handoff>` : "<previous-handoff>None</previous-handoff>",
		autonomyStatus ? `<autonomy-status>\n${autonomyStatus}\n</autonomy-status>` : "<autonomy-status>None</autonomy-status>",
		`<conversation>\n${transcript}\n</conversation>`,
	].join("\n\n");
	return completeIntel(ctx, config, HANDOFF_SYSTEM_PROMPT, userText, signal);
}

async function writeHandoff(ctx: ExtensionContext, appendEntry: (customType: string, data?: unknown) => void, text: string): Promise<string> {
	const filePath = handoffPath(ctx);
	await fs.mkdir(path.dirname(filePath), { recursive: true });
	await fs.writeFile(filePath, text.trim() + "\n", "utf8");
	appendEntry(CUSTOM_TYPE, { kind: "handoff", path: filePath, timestamp: nowIso() });
	return filePath;
}

async function generateCompactionSummary(ctx: ExtensionContext, config: SessionIntelConfig, event: any): Promise<string | null> {
	const { preparation, customInstructions } = event;
	const { handoff, autonomyStatus } = await readDurableContext(ctx, config);
	const allMessages = [
		...(preparation.previousSummary ? [{ role: "custom", customType: "previous-compaction", content: preparation.previousSummary, display: false, timestamp: Date.now() }] : []),
		...(preparation.messagesToSummarize ?? []),
		...(preparation.turnPrefixMessages ?? []),
	];
	const transcript = serializeMessages(allMessages, config.maxPromptChars);
	const { readFiles, modifiedFiles } = getFileOps(preparation);

	const userText = [
		`Repo: ${repoName(ctx.cwd)}`,
		`CWD: ${ctx.cwd}`,
		`Timestamp: ${nowIso()}`,
		customInstructions ? `Custom compact instructions: ${customInstructions}` : "Custom compact instructions: none",
		preparation.previousSummary ? `<previous-summary>\n${preparation.previousSummary}\n</previous-summary>` : "<previous-summary>None</previous-summary>",
		handoff ? `<durable-handoff>\n${handoff}\n</durable-handoff>` : "<durable-handoff>None</durable-handoff>",
		autonomyStatus ? `<autonomy-status>\n${autonomyStatus}\n</autonomy-status>` : "<autonomy-status>None</autonomy-status>",
		`<read-files>\n${readFiles.join("\n") || "None"}\n</read-files>`,
		`<modified-files>\n${modifiedFiles.join("\n") || "None"}\n</modified-files>`,
		`<conversation-to-compact>\n${transcript}\n</conversation-to-compact>`,
	].join("\n\n");

	return completeIntel(ctx, config, COMPACTION_SYSTEM_PROMPT, userText, event.signal);
}

export default function sessionIntel(pi: ExtensionAPI) {
	const isHeadlessJson = process.argv.includes("--mode") && process.argv.includes("json") || process.argv.some((arg) => arg === "--mode=json");
	if (isHeadlessJson) return;

	let config: SessionIntelConfig = { ...DEFAULT_CONFIG };
	let latestCtx: ExtensionContext | undefined;
	let lastPrompt = "";
	let namedThisSession = false;
	let pendingName = false;
	let pendingHandoff = false;
	let turnsSinceHandoff = 0;
	let lastHandoffAt = 0;
	let cachedHandoff: string | null = null;

	async function refresh(ctx: ExtensionContext) {
		latestCtx = ctx;
		config = await loadConfig(ctx.cwd);
		cachedHandoff = await readIfExists(handoffPath(ctx));
		updateWidget(ctx, config, cachedHandoff, lastHandoffAt);
	}

	async function maybeAutoName(ctx: ExtensionContext) {
		if (!config.enabled || !config.autoName || namedThisSession || pendingName) return;
		let current = "";
		try {
			current = (pi.getSessionName?.() ?? "").trim();
		} catch {
			return;
		}
		if (current && current.length > 12 && !current.startsWith("/skill:")) return;
		pendingName = true;
		try {
			const title = await generateName(ctx, config, lastPrompt);
			if (title) {
				try {
					pi.setSessionName(title);
				} catch {
					return;
				}
				namedThisSession = true;
				try {
					if (config.verbose && ctx.hasUI) ctx.ui.notify(`[intel:name] ${title}`, "info");
				} catch {}
			}
		} catch (error) {
			console.error("[session-intel] auto-name failed:", error);
		} finally {
			pendingName = false;
		}
	}

	async function syncHandoff(ctx: ExtensionContext, note: string, options: { interactive?: boolean; signal?: AbortSignal } = {}) {
		if (!config.enabled || pendingHandoff) return null;
		pendingHandoff = true;
		try {
			const generated = await generateHandoff(ctx, config, note, options.signal);
			if (!generated) return null;
			let finalText = generated;
			if (options.interactive && ctx.hasUI) {
				const edited = await ctx.ui.editor("Review session handoff", generated);
				if (edited === undefined) return null;
				finalText = edited;
			}
			const filePath = await writeHandoff(ctx, pi.appendEntry.bind(pi), finalText);
			cachedHandoff = finalText;
			turnsSinceHandoff = 0;
			lastHandoffAt = Date.now();
			updateWidget(ctx, config, cachedHandoff, lastHandoffAt);
			if ((options.interactive || config.verbose) && ctx.hasUI) ctx.ui.notify(`Saved handoff: ${filePath}`, "info");
			return filePath;
		} catch (error) {
			console.error("[session-intel] handoff sync failed:", error);
			if (options.interactive && ctx.hasUI) ctx.ui.notify(`Handoff failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			return null;
		} finally {
			pendingHandoff = false;
		}
	}

	function shouldAutoHandoff(ctx: ExtensionContext): boolean {
		try {
			if (!config.autoHandoff || pendingHandoff) return false;
			if (turnsSinceHandoff < config.minTurnsBetweenHandoffs) return false;
			if (Date.now() - lastHandoffAt < config.minSecondsBetweenHandoffs * 1000) return false;
			const pct = usagePercent(ctx);
			return pct !== null && pct >= config.contextSyncThreshold;
		} catch {
			return false;
		}
	}

	pi.registerCommand("intel:settings", {
		description: "Create/show session-intel settings file",
		handler: async (_args, ctx) => {
			const filePath = await writeDefaultConfig(ctx);
			ctx.ui.notify(`Session-intel settings: ${filePath}`, "info");
			ctx.ui.setEditorText(`Edit ${filePath} and run /reload to apply changes.`);
		},
	});

	pi.registerCommand("intel:name", {
		description: "Generate a stable AI session name",
		handler: async (args, ctx) => {
			await refresh(ctx);
			const title = await generateName(ctx, config, args.trim());
			if (!title) {
				ctx.ui.notify("Could not generate a session name", "error");
				return;
			}
			pi.setSessionName(title);
			namedThisSession = true;
			ctx.ui.notify(`Session named: ${title}`, "info");
		},
	});

	pi.registerCommand("intel:handoff", {
		description: "Create/update a durable session handoff",
		handler: async (args, ctx) => {
			await refresh(ctx);
			await syncHandoff(ctx, args.trim(), { interactive: true, signal: ctx.signal });
		},
	});

	pi.registerCommand("intel:show", {
		description: "Open the current durable session handoff",
		handler: async (_args, ctx) => {
			await refresh(ctx);
			const filePath = handoffPath(ctx);
			const text = await readIfExists(filePath);
			if (!text) {
				ctx.ui.notify("No handoff yet. Run /intel:handoff.", "warning");
				return;
			}
			const edited = await ctx.ui.editor(`Session handoff — ${filePath}`, text);
			if (edited !== undefined) {
				await fs.writeFile(filePath, edited, "utf8");
				cachedHandoff = edited;
				updateWidget(ctx, config, cachedHandoff, lastHandoffAt);
				ctx.ui.notify("Updated handoff", "info");
			}
		},
	});

	pi.registerCommand("intel:path", {
		description: "Show the current session-intel handoff path",
		handler: async (_args, ctx) => {
			ctx.ui.notify(handoffPath(ctx), "info");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		namedThisSession = false;
		turnsSinceHandoff = 0;
		lastHandoffAt = 0;
		await refresh(ctx);
	});

	pi.on("before_agent_start", async (event, ctx) => {
		latestCtx = ctx;
		lastPrompt = event.prompt;
		if (!config.enabled || !config.injectHandoff) return;
		const { handoff, autonomyStatus } = await readDurableContext(ctx, config);
		const blocks: string[] = [];
		if (handoff) {
			blocks.push(`### Current session handoff (${handoffPath(ctx)})\n${handoff}`);
		}
		if (autonomyStatus) {
			blocks.push(`### Project autonomy status (.pi/autonomy/status.md)\n${autonomyStatus}`);
		}
		if (blocks.length === 0) return;
		return {
			systemPrompt: `${event.systemPrompt}\n\n## Session intelligence\nDurable session/project state exists outside this conversation. Use it as the current-state index; read the referenced files when the task depends on handoff details.\n\n${blocks.join("\n\n")}`,
		};
	});

	pi.on("agent_end", async (_event, ctx) => {
		latestCtx = ctx;
		turnsSinceHandoff++;
		updateWidget(ctx, config, cachedHandoff, lastHandoffAt);
		void maybeAutoName(ctx);
		if (shouldAutoHandoff(ctx)) {
			void syncHandoff(ctx, "Automatic handoff because context usage crossed threshold", { interactive: false, signal: undefined });
		}
	});

	pi.on("session_before_compact", async (event, ctx) => {
		if (!config.enabled || !config.customCompaction) return;
		try {
			// Save a handoff first while the full pre-compact context is still available.
			await syncHandoff(ctx, "Pre-compaction handoff", { interactive: false, signal: event.signal });
			const summary = await generateCompactionSummary(ctx, config, event);
			if (!summary) return;
			const { readFiles, modifiedFiles } = getFileOps(event.preparation);
			return {
				compaction: {
					summary,
					firstKeptEntryId: event.preparation.firstKeptEntryId,
					tokensBefore: event.preparation.tokensBefore,
					details: {
						source: CUSTOM_TYPE,
						generatedAt: nowIso(),
						handoffPath: handoffPath(ctx),
						readFiles,
						modifiedFiles,
					},
				},
			};
		} catch (error) {
			console.error("[session-intel] custom compaction failed; falling back to pi default:", error);
			return;
		}
	});

	pi.on("session_compact", async (_event, ctx) => {
		await refresh(ctx);
		if (ctx.hasUI && config.verbose) ctx.ui.notify("Session-intel compaction checkpoint saved", "info");
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		if (ctx.hasUI) ctx.ui.setWidget(WIDGET_KEY, undefined);
	});
}
