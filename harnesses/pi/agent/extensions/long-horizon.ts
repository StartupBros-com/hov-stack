/**
 * Long Horizon Autonomy Extension
 *
 * Research-backed support for multi-session, long-running coding work.
 *
 * Creates and maintains a lightweight autonomy workspace under `.pi/autonomy/`
 * inspired by Anthropic/OpenAI long-horizon agent guidance:
 * - spec.md     -> durable target / constraints / definition of done
 * - plan.md     -> milestone plan with acceptance criteria
 * - runbook.md  -> operating procedure for the agent
 * - status.md   -> compact durable project memory / next-step index
 *
 * Commands:
 * - /autonomy-init [goal]  -> scaffold the workspace
 * - /autonomy-sync [note]  -> refresh status.md from current session context
 */

import { promises as fs } from "node:fs";
import path from "node:path";

import { complete, type Api, type Message, type Model } from "@mariozechner/pi-ai";
import {
	BorderedLoader,
	convertToLlm,
	serializeConversation,
	type ExtensionAPI,
	type ExtensionContext,
	type SessionEntry,
} from "@mariozechner/pi-coding-agent";

const AUTONOMY_DIR = path.join(".pi", "autonomy");
const SPEC_FILE = "spec.md";
const PLAN_FILE = "plan.md";
const RUNBOOK_FILE = "runbook.md";
const STATUS_FILE = "status.md";
const FILE_NAMES = [SPEC_FILE, PLAN_FILE, RUNBOOK_FILE, STATUS_FILE] as const;
const STATUS_WIDGET_KEY = "long-horizon";
const STATUS_SNIPPET_MAX_CHARS = 2500;
const SESSION_SUMMARY_MAX_CHARS = 32000;
const AGENTS_MAX_CHARS = 6000;

const INIT_SYSTEM_PROMPT = `You are creating a durable long-horizon coding workspace for an autonomous terminal agent.
Generate exactly four markdown files with these names and purposes:

- spec.md: project goal, hard constraints, non-goals, deliverables, done-when
- plan.md: milestone plan with acceptance criteria and validation ideas
- runbook.md: operational instructions for the coding agent
- status.md: compact durable state for cross-session continuity

Requirements:
- Be practical, concise, and execution-oriented.
- Assume the workspace is for real software engineering work, not brainstorming.
- Prefer milestone-based execution with explicit verification.
- Encourage one milestone at a time, scoped diffs, and updating status after meaningful progress.
- status.md must be short and high-signal. It should work like a durable index, not a narrative log.
- Mention concrete validation commands only when strongly implied by the provided repo/project context. Otherwise use placeholders the user can refine.
- Do not invent technologies that are not implied by the input.

Output format:
=== FILE: spec.md ===
...markdown...
=== FILE: plan.md ===
...markdown...
=== FILE: runbook.md ===
...markdown...
=== FILE: status.md ===
...markdown...

Do not include any other text.`;

const SYNC_SYSTEM_PROMPT = `You update status.md for a long-running coding workspace.
Produce a compact, durable markdown status file that future sessions can read quickly.

Rules:
- Keep only high-signal project state.
- Prefer concrete next steps over broad summaries.
- Preserve unresolved risks, blockers, and important decisions.
- Mention exact file paths when they matter.
- Do not include speculation.
- Keep the result under ~120 lines.
- Use this structure exactly:

# Status

## Goal
- ...

## Current State
- ...

## Next
- ...

## Risks / Blockers
- ...

## Important Files
- ...

## Validation
- ...

## Last Updated
- ISO timestamp and a one-line note

If a section has no content, write a single bullet with "None".`;

async function pathExists(targetPath: string): Promise<boolean> {
	try {
		await fs.access(targetPath);
		return true;
	} catch {
		return false;
	}
}

async function readIfExists(targetPath: string): Promise<string | null> {
	try {
		return await fs.readFile(targetPath, "utf8");
	} catch {
		return null;
	}
}

async function getAutonomyPaths(cwd: string) {
	const dir = path.join(cwd, AUTONOMY_DIR);
	return {
		dir,
		spec: path.join(dir, SPEC_FILE),
		plan: path.join(dir, PLAN_FILE),
		runbook: path.join(dir, RUNBOOK_FILE),
		status: path.join(dir, STATUS_FILE),
	};
}

function trimForPrompt(text: string, maxChars: number): string {
	if (text.length <= maxChars) return text;
	return `${text.slice(0, maxChars)}\n\n[truncated]`;
}

function extractText(responseContent: Array<{ type: string; text?: string }>): string {
	return responseContent
		.filter((item): item is { type: "text"; text: string } => item.type === "text" && typeof item.text === "string")
		.map((item) => item.text)
		.join("\n")
		.trim();
}

function parseGeneratedFiles(text: string): Partial<Record<(typeof FILE_NAMES)[number], string>> {
	const matches = Array.from(text.matchAll(/^=== FILE: (spec\.md|plan\.md|runbook\.md|status\.md) ===\s*$/gm));
	const parsed: Partial<Record<(typeof FILE_NAMES)[number], string>> = {};

	for (let i = 0; i < matches.length; i++) {
		const match = matches[i];
		const fileName = match[1] as (typeof FILE_NAMES)[number];
		const start = match.index! + match[0].length;
		const end = i + 1 < matches.length ? matches[i + 1].index! : text.length;
		parsed[fileName] = text.slice(start, end).trim();
	}

	return parsed;
}

function nowIso(): string {
	return new Date().toISOString();
}

function buildFallbackScaffold(goal: string): Record<(typeof FILE_NAMES)[number], string> {
	const createdAt = nowIso();

	return {
		"spec.md": `# Spec\n\n## Goal\n- ${goal}\n\n## Success Criteria\n- The implementation directly addresses the goal above.\n- Work is reviewable, testable, and scoped.\n- Changes leave the repo in a clean, understandable state.\n\n## Constraints\n- Prefer small, verifiable milestones.\n- Keep diffs scoped to the current milestone.\n- Verify meaningful changes before marking progress complete.\n\n## Non-Goals\n- Avoid unrelated refactors unless required to complete the goal safely.\n- Avoid speculative architecture changes without evidence.\n\n## Deliverables\n- Working code or configuration changes tied to the goal\n- Updated tests / docs / validation notes as needed\n- A current status.md for the next session\n\n## Done When\n- Acceptance criteria for the final milestone are met\n- Validation has been run and recorded\n- Remaining risks or follow-ups are clearly documented\n`,
		"plan.md": `# Plan\n\n## Milestones\n\n### M1 — Recon / setup\n- Understand the relevant codepaths, constraints, and validation path\n- Acceptance criteria:\n  - Relevant files / commands / constraints identified\n  - status.md updated with a concrete next step\n\n### M2 — First implementation slice\n- Implement the smallest meaningful part of the goal\n- Acceptance criteria:\n  - A scoped, reviewable diff exists\n  - Basic validation for that slice has been run\n\n### M3 — Complete and harden\n- Finish remaining work, edge cases, and cleanup\n- Acceptance criteria:\n  - Final behavior matches the goal\n  - Validation is green or any remaining failures are documented\n\n## Validation Ideas\n- Replace with project-specific commands after initial repo analysis\n- Example buckets:\n  - format / lint\n  - typecheck / build\n  - targeted tests\n  - manual smoke test\n`,
		"runbook.md": `# Runbook\n\n## Operating Rules\n- Read status.md before doing large or autonomous changes.\n- Work one milestone at a time.\n- Keep diffs narrowly scoped to the active milestone.\n- Verify before marking progress complete.\n- If uncertain, record the blocker instead of guessing.\n- Update status.md after each meaningful milestone or context handoff.\n\n## Session Start Checklist\n1. Read status.md\n2. Re-open spec.md / plan.md if the task is ambiguous\n3. Identify the smallest next step\n4. Confirm how the change will be validated\n\n## Session End Checklist\n1. Make sure the repo is in a legible, reviewable state\n2. Capture what changed and what remains\n3. Update status.md with next action, blockers, and important files\n\n## Quality Bar\n- Prefer reversible steps\n- Prefer exact file paths over vague references\n- Preserve durable decisions in status.md\n- Avoid hidden work or undocumented progress\n`,
		"status.md": `# Status\n\n## Goal\n- ${goal}\n\n## Current State\n- Workspace initialized\n\n## Next\n- Read the repo / AGENTS context and refine plan.md with concrete validation commands\n\n## Risks / Blockers\n- None\n\n## Important Files\n- .pi/autonomy/spec.md\n- .pi/autonomy/plan.md\n- .pi/autonomy/runbook.md\n- .pi/autonomy/status.md\n\n## Validation\n- None yet\n\n## Last Updated\n- ${createdAt} — Initialized autonomy workspace\n`,
	};
}

function extractNextBullet(statusText: string): string | null {
	const lines = statusText.split(/\r?\n/);
	let inNextSection = false;

	for (const line of lines) {
		if (/^##\s+Next\b/i.test(line.trim())) {
			inNextSection = true;
			continue;
		}
		if (inNextSection && /^##\s+/.test(line.trim())) {
			break;
		}
		if (inNextSection) {
			const bulletMatch = line.match(/^\s*[-*]\s+(.+)$/);
			if (bulletMatch && bulletMatch[1].trim() && !/^none$/i.test(bulletMatch[1].trim())) {
				return bulletMatch[1].trim();
			}
		}
	}

	const inlineMatch = statusText.match(/^Next:\s*(.+)$/im);
	if (inlineMatch?.[1]?.trim()) {
		return inlineMatch[1].trim();
	}

	return null;
}

function updateStatusWidget(ctx: ExtensionContext, statusText: string | null): void {
	if (!ctx.hasUI) return;
	if (!statusText) {
		ctx.ui.setWidget(STATUS_WIDGET_KEY, undefined);
		return;
	}

	const next = extractNextBullet(statusText);
	if (!next) {
		ctx.ui.setWidget(STATUS_WIDGET_KEY, [ctx.ui.theme.fg("muted", "Autonomy workspace active")]);
		return;
	}

	const display = next.length > 120 ? `${next.slice(0, 117)}...` : next;
	ctx.ui.setWidget(STATUS_WIDGET_KEY, [ctx.ui.theme.fg("accent", `Next: ${display}`)]);
}

async function getProjectContext(cwd: string): Promise<{ agentsText: string | null }> {
	const agentsCandidates = [path.join(cwd, "AGENTS.md"), path.join(cwd, "CLAUDE.md")];
	for (const candidate of agentsCandidates) {
		const text = await readIfExists(candidate);
		if (text) {
			return { agentsText: trimForPrompt(text, AGENTS_MAX_CHARS) };
		}
	}
	return { agentsText: null };
}

async function runModelTask(
	ctx: ExtensionContext,
	systemPrompt: string,
	userText: string,
	loaderTitle: string,
): Promise<string | null> {
	if (!ctx.hasUI || !ctx.model) return null;
	const apiKey = await ctx.modelRegistry.getApiKey(ctx.model);
	if (!apiKey) return null;

	const result = await ctx.ui.custom<string | null>((tui, theme, _kb, done) => {
		const loader = new BorderedLoader(tui, theme, loaderTitle);
		loader.onAbort = () => done(null);

		const run = async () => {
			const userMessage: Message = {
				role: "user",
				content: [{ type: "text", text: userText }],
				timestamp: Date.now(),
			};

			const response = await complete(
				ctx.model as Model<Api>,
				{ systemPrompt, messages: [userMessage] },
				{ apiKey, signal: loader.signal },
			);

			if (response.stopReason === "aborted" || response.stopReason === "error") {
				done(null);
				return;
			}

			done(extractText(response.content));
		};

		run().catch((error) => {
			console.error(`${loaderTitle} failed:`, error);
			done(null);
		});

		return loader;
	});

	return result;
}

async function buildScaffold(ctx: ExtensionContext, goal: string): Promise<Record<(typeof FILE_NAMES)[number], string>> {
	const cwd = ctx.cwd;
	const { agentsText } = await getProjectContext(cwd);
	const paths = await getAutonomyPaths(cwd);
	const existingStatus = await readIfExists(paths.status);
	const existingSpec = await readIfExists(paths.spec);

	const userText = [
		`Current working directory: ${cwd}`,
		`Goal: ${goal}`,
		agentsText ? `Project instructions excerpt:\n${agentsText}` : "Project instructions excerpt: None",
		existingSpec ? `Existing spec excerpt:\n${trimForPrompt(existingSpec, 3000)}` : "Existing spec excerpt: None",
		existingStatus ? `Existing status excerpt:\n${trimForPrompt(existingStatus, 2000)}` : "Existing status excerpt: None",
	].join("\n\n");

	const generated = await runModelTask(ctx, INIT_SYSTEM_PROMPT, userText, "Generating autonomy workspace...");
	if (!generated) {
		return buildFallbackScaffold(goal);
	}

	const parsed = parseGeneratedFiles(generated);
	const fallback = buildFallbackScaffold(goal);

	return {
		"spec.md": parsed["spec.md"]?.trim() || fallback["spec.md"],
		"plan.md": parsed["plan.md"]?.trim() || fallback["plan.md"],
		"runbook.md": parsed["runbook.md"]?.trim() || fallback["runbook.md"],
		"status.md": parsed["status.md"]?.trim() || fallback["status.md"],
	};
}

function getBranchMessages(ctx: ExtensionContext): Array<Message> {
	return ctx.sessionManager
		.getBranch()
		.filter((entry): entry is SessionEntry & { type: "message" } => entry.type === "message")
		.map((entry) => entry.message);
}

async function buildStatusUpdate(ctx: ExtensionContext, note: string): Promise<string | null> {
	const cwd = ctx.cwd;
	const paths = await getAutonomyPaths(cwd);
	const existingStatus = (await readIfExists(paths.status)) ?? "";
	const existingPlan = (await readIfExists(paths.plan)) ?? "";
	const existingSpec = (await readIfExists(paths.spec)) ?? "";
	const branchMessages = getBranchMessages(ctx);

	if (branchMessages.length === 0) {
		return existingStatus || buildFallbackScaffold(note || "Continue the current project goal")["status.md"];
	}

	const llmMessages = convertToLlm(branchMessages);
	const serializedConversation = trimForPrompt(serializeConversation(llmMessages), SESSION_SUMMARY_MAX_CHARS);
	const userText = [
		`Current working directory: ${cwd}`,
		`Update note: ${note || "Refresh current durable state"}`,
		existingSpec ? `Existing spec excerpt:\n${trimForPrompt(existingSpec, 2500)}` : "Existing spec excerpt: None",
		existingPlan ? `Existing plan excerpt:\n${trimForPrompt(existingPlan, 2500)}` : "Existing plan excerpt: None",
		existingStatus ? `Existing status.md:\n${trimForPrompt(existingStatus, 2500)}` : "Existing status.md: None",
		`Conversation transcript excerpt:\n${serializedConversation}`,
		`Timestamp: ${nowIso()}`,
	].join("\n\n");

	return runModelTask(ctx, SYNC_SYSTEM_PROMPT, userText, "Refreshing autonomy status...");
}

export default function longHorizonExtension(pi: ExtensionAPI) {
	pi.registerCommand("autonomy-init", {
		description: "Create a long-horizon autonomy workspace in .pi/autonomy",
		handler: async (args, ctx) => {
			const goal = args.trim() || (await ctx.ui.input("Autonomy goal", "Ship X safely with milestones"));
			if (!goal) {
				ctx.ui.notify("Cancelled", "info");
				return;
			}

			const paths = await getAutonomyPaths(ctx.cwd);
			const dirExists = await pathExists(paths.dir);
			if (dirExists) {
				const overwrite = await ctx.ui.confirm(
					"Autonomy workspace exists",
					"Overwrite spec.md, plan.md, runbook.md, and status.md?",
				);
				if (!overwrite) {
					ctx.ui.notify("Cancelled", "info");
					return;
				}
			}

			const scaffold = await buildScaffold(ctx, goal);
			await fs.mkdir(paths.dir, { recursive: true });
			await fs.writeFile(paths.spec, scaffold["spec.md"], "utf8");
			await fs.writeFile(paths.plan, scaffold["plan.md"], "utf8");
			await fs.writeFile(paths.runbook, scaffold["runbook.md"], "utf8");
			await fs.writeFile(paths.status, scaffold["status.md"], "utf8");

			updateStatusWidget(ctx, scaffold["status.md"]);
			ctx.ui.notify("Created .pi/autonomy workspace", "info");
			ctx.ui.setEditorText(
				"Read @.pi/autonomy/status.md, @.pi/autonomy/spec.md, and @.pi/autonomy/plan.md, then proceed with the next milestone.",
			);
		},
	});

	pi.registerCommand("autonomy-sync", {
		description: "Refresh .pi/autonomy/status.md from current session context",
		handler: async (args, ctx) => {
			const paths = await getAutonomyPaths(ctx.cwd);
			if (!(await pathExists(paths.dir))) {
				ctx.ui.notify("No .pi/autonomy workspace found. Run /autonomy-init first.", "warning");
				return;
			}

			const note = args.trim();
			const generated = await buildStatusUpdate(ctx, note);
			if (!generated) {
				ctx.ui.notify("Could not generate status update", "error");
				return;
			}

			const edited = await ctx.ui.editor("Review status.md", generated);
			if (edited === undefined) {
				ctx.ui.notify("Cancelled", "info");
				return;
			}

			await fs.writeFile(paths.status, edited, "utf8");
			updateStatusWidget(ctx, edited);
			ctx.ui.notify("Updated .pi/autonomy/status.md", "info");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		const paths = await getAutonomyPaths(ctx.cwd);
		const statusText = await readIfExists(paths.status);
		updateStatusWidget(ctx, statusText);
	});

	pi.on("session_switch", async (_event, ctx) => {
		const paths = await getAutonomyPaths(ctx.cwd);
		const statusText = await readIfExists(paths.status);
		updateStatusWidget(ctx, statusText);
	});

	pi.on("before_agent_start", async (event, ctx) => {
		const paths = await getAutonomyPaths(ctx.cwd);
		const statusText = await readIfExists(paths.status);
		if (!statusText) return;

		const presentFiles: string[] = [];
		for (const fileName of FILE_NAMES) {
			const filePath = path.join(paths.dir, fileName);
			if (await pathExists(filePath)) {
				presentFiles.push(path.posix.join(AUTONOMY_DIR.replaceAll(path.sep, "/"), fileName));
			}
		}

		const statusSnippet = trimForPrompt(statusText, STATUS_SNIPPET_MAX_CHARS);
		const appendedPrompt = `${event.systemPrompt}\n\n## Long-horizon autonomy workspace\nThis project has a durable autonomy workspace for multi-session work.\n- If the task is multi-step, long-running, or handoff-sensitive, prefer consulting these files before large changes: ${presentFiles.join(", ")}\n- Treat status.md as the compact durable index for current state and next step.\n- When you materially advance a milestone or create a useful handoff point, ask the user to run /autonomy-sync (or update status.md yourself if explicitly requested).\n\n### status.md snapshot\n${statusSnippet}`;

		return {
			systemPrompt: appendedPrompt,
		};
	});
}
