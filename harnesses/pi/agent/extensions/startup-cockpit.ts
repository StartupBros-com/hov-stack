import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext, ToolInfo } from "@mariozechner/pi-coding-agent";

type CommandInfo = {
	name: string;
	source: "extension" | "prompt" | "skill";
	description?: string;
};

type ProjectProfile = {
	match: string;
	headline: string;
	commands?: string[];
	tools?: string[];
	tips?: string[];
};

type CockpitConfig = {
	profiles?: ProjectProfile[];
};

const WIDGET_KEY = "startup-cockpit";
const CONFIG_PATH = path.join(os.homedir(), ".pi", "agent", "startup-cockpit.json");

const GROUPS: Array<{ title: string; items: Array<{ name: string; summary: string }> }> = [
	{
		title: "Delegation",
		items: [
			{ name: "agent", summary: "spawn an isolated tmux/worktree side-agent" },
			{ name: "agents", summary: "inspect side-agents and reclaim stale locks" },
			{ name: "subagents", summary: "open the reusable subagent manager" },
			{ name: "run", summary: "run one named subagent" },
			{ name: "chain", summary: "scout → planner → implementer pipelines" },
			{ name: "parallel", summary: "run multiple named subagents concurrently" },
			{ name: "subagents-doctor", summary: "diagnose subagent setup" },
		],
	},
	{
		title: "Workflow",
		items: [
			{ name: "review", summary: "launch the Compound Engineering review flow" },
			{ name: "workflows-review", summary: "canonical CE review command" },
			{ name: "end-review", summary: "finish the current review and return" },
			{ name: "review-start", summary: "start the lightweight review loop" },
			{ name: "review-skeptical", summary: "run skeptical review mode" },
			{ name: "ce-context", summary: "show or seed Compound Engineering context" },
		],
	},
	{
		title: "Daily leverage",
		items: [
			{ name: "todos", summary: "manage session todos quickly" },
			{ name: "files", summary: "jump to files, diffs, and editor actions" },
			{ name: "tools", summary: "toggle active tools interactively" },
			{ name: "preset", summary: "switch model/tool presets" },
			{ name: "context", summary: "inspect/curate session context" },
			{ name: "handoff", summary: "package work into a new thread" },
			{ name: "intel:handoff", summary: "write durable session state for compaction/resume" },
			{ name: "intel:name", summary: "generate a stable AI session name" },
			{ name: "session-sync", summary: "sync searchable session history index" },
			{ name: "answer", summary: "answer questions from the last reply fast" },
			{ name: "session-breakdown", summary: "analyze session usage/history" },
			{ name: "footer", summary: "toggle the compact dashboard footer" },
		],
	},
	{
		title: "Memory",
		items: [
			{ name: "intel:show", summary: "open this session's durable handoff" },
			{ name: "intel:settings", summary: "configure session intelligence" },
			{ name: "session-reindex", summary: "rebuild the searchable session index" },
			{ name: "session-embeddings-setup", summary: "enable hybrid semantic session search" },
			{ name: "welcome", summary: "reopen the compact startup cockpit" },
			{ name: "capabilities", summary: "open the expanded capability map" },
			{ name: "welcome-hide", summary: "hide the startup widget for this session" },
		],
	},
];

const TOOL_GROUPS: Array<{ title: string; items: Array<{ name: string; summary: string }> }> = [
	{
		title: "Research + web",
		items: [
			{ name: "WebSearch", summary: "current web discovery" },
			{ name: "WebFetch", summary: "fetch readable page content" },
			{ name: "CodeContextSearch", summary: "official docs + code usage lookup" },
			{ name: "SiteMap", summary: "map docs sites before fetching" },
		],
	},
	{
		title: "Execution",
		items: [
			{ name: "subagent", summary: "delegate to named agents/chains" },
			{ name: "subagent_status", summary: "inspect async subagent runs" },
			{ name: "start_background_service", summary: "launch detached servers/workers" },
			{ name: "list_background_services", summary: "inspect tracked background services" },
			{ name: "review_loop", summary: "automated review loop control" },
		],
	},
	{
		title: "Ops + memory",
		items: [
			{ name: "todo", summary: "session todo system" },
			{ name: "ce_todo", summary: "Compound Engineering markdown todos" },
			{ name: "session_search", summary: "search prior Pi sessions" },
			{ name: "session_read", summary: "read a prior Pi session" },
			{ name: "session_list", summary: "browse prior Pi sessions" },
			{ name: "ask_user_question", summary: "interrupt for fast choices" },
			{ name: "ssh_hosts", summary: "discover saved SSH aliases" },
			{ name: "generate_image", summary: "Gemini/Imagen image generation" },
		],
	},
];

const DEFAULT_PROFILES: ProjectProfile[] = [
	{
		match: "prbot",
		headline: "PRBot operating mode: parallelize changes, keep review and todos tight.",
		commands: ["agent", "agents", "subagents", "run", "chain", "parallel", "subagents-doctor", "review", "workflows-review", "todos", "preset"],
		tools: ["WebSearch", "WebFetch", "CodeContextSearch", "subagent", "ce_todo"],
		tips: [
			"Use /agent for repo work that deserves an isolated branch/worktree.",
			"Use subagents for focused delegation, parallel experiments, and planned decomposition.",
			"Use /review or /workflows-review before shipping meaningful changes.",
		],
	},
	{
		match: "paperclip",
		headline: "Paperclip mode: agent-native product work, review aggressively, parallelize wisely.",
		commands: ["agent", "subagents", "run", "chain", "parallel", "subagents-doctor", "review", "ce-context", "todos"],
		tools: ["subagent", "CodeContextSearch", "todo", "review_loop"],
		tips: [
			"Prefer /agent for isolated feature branches, /chain for planned decomposition, and /parallel for independent review passes.",
			"Keep agent-native parity in mind when adding product capabilities.",
		],
	},
	{
		match: "pi-subagents",
		headline: "Pi package mode: dogfood the package, validate with tests, preserve command ergonomics.",
		commands: ["subagents", "run", "chain", "parallel", "subagents-doctor", "review", "files"],
		tools: ["CodeContextSearch", "subagent", "todo"],
		tips: [
			"After extension changes, /reload the outer Pi session to verify runtime behavior.",
			"Keep docs and tests in lockstep with command/tool changes.",
		],
	},
	{
		match: "pi-compound-engineering",
		headline: "Compound Engineering mode: workflows, review quality, and institutional memory are first-class.",
		commands: ["review", "workflows-review", "ce-context", "todos", "subagents", "run", "chain", "parallel"],
		tools: ["ce_todo", "review_loop", "subagent"],
		tips: [
			"Use CE review flows instead of ad-hoc reviews when possible.",
			"Capture durable learnings instead of repeating discoveries.",
		],
	},
	{
		match: "pi-*",
		headline: "Pi package dev mode: ship small, dogfood locally, and validate the UX every time.",
		commands: ["agent", "subagents", "run", "chain", "parallel", "review", "files", "preset"],
		tools: ["CodeContextSearch", "WebFetch", "todo"],
		tips: [
			"Prefer local repo paths in settings while developing Pi packages.",
			"Treat ergonomics and discoverability as product features, not polish.",
		],
	},
];

function loadConfig(): CockpitConfig {
	try {
		if (!fs.existsSync(CONFIG_PATH)) return {};
		return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8")) as CockpitConfig;
	} catch {
		return {};
	}
}

function getCommands(pi: ExtensionAPI): CommandInfo[] {
	return pi.getCommands() as CommandInfo[];
}

function getTools(pi: ExtensionAPI): ToolInfo[] {
	return pi.getAllTools();
}

function commandMap(pi: ExtensionAPI): Map<string, CommandInfo> {
	return new Map(getCommands(pi).map((command) => [command.name, command]));
}

function toolMap(pi: ExtensionAPI): Map<string, ToolInfo> {
	return new Map(getTools(pi).map((tool) => [tool.name, tool]));
}

function sourceCounts(pi: ExtensionAPI) {
	const commands = getCommands(pi);
	let extension = 0;
	let skill = 0;
	let prompt = 0;
	for (const command of commands) {
		if (command.source === "extension") extension += 1;
		else if (command.source === "skill") skill += 1;
		else if (command.source === "prompt") prompt += 1;
	}
	return { extension, skill, prompt };
}

function toolCounts(pi: ExtensionAPI) {
	const total = pi.getAllTools().length;
	const active = pi.getActiveTools().length;
	return { total, active };
}

function formatCommandSpan(ctx: ExtensionContext, name: string): string {
	return ctx.ui.theme.fg("accent", `/${name}`);
}

function formatToolSpan(ctx: ExtensionContext, name: string): string {
	return ctx.ui.theme.fg("accent", name);
}

function bullet(ctx: ExtensionContext, text: string, color: "dim" | "muted" = "dim"): string {
	return `${ctx.ui.theme.fg("muted", "•")} ${ctx.ui.theme.fg(color, text)}`;
}

function visibleCommands(pi: ExtensionAPI, names: string[]): string[] {
	const map = commandMap(pi);
	return names.filter((name) => map.has(name));
}

function visibleTools(pi: ExtensionAPI, names: string[]): string[] {
	const map = toolMap(pi);
	return names.filter((name) => map.has(name));
}

function findGitRoot(start: string): string | null {
	let current = path.resolve(start);
	while (true) {
		if (fs.existsSync(path.join(current, ".git"))) return current;
		const parent = path.dirname(current);
		if (parent === current) return null;
		current = parent;
	}
}

function repoNameForCwd(cwd: string): string {
	const gitRoot = findGitRoot(cwd);
	return path.basename(gitRoot ?? cwd) || cwd;
}

function matchesProfile(pattern: string, repoName: string): boolean {
	const trimmed = pattern.trim();
	if (!trimmed) return false;
	if (trimmed.endsWith("*")) {
		return repoName.startsWith(trimmed.slice(0, -1));
	}
	return repoName === trimmed;
}

function resolveProfile(repoName: string, config: CockpitConfig): ProjectProfile | undefined {
	const profiles = [...(config.profiles ?? []), ...DEFAULT_PROFILES];
	return profiles.find((profile) => matchesProfile(profile.match, repoName));
}

function buildCompactWidget(pi: ExtensionAPI, ctx: ExtensionContext, config: CockpitConfig): string[] {
	const counts = sourceCounts(pi);
	const tools = toolCounts(pi);
	const repoName = repoNameForCwd(ctx.cwd);
	const profile = resolveProfile(repoName, config);
	const parallelLane = visibleCommands(pi, ["agent", "agents"]);
	const subagentLane = visibleCommands(pi, ["subagents", "run", "chain", "parallel", "subagents-doctor"]);
	const daily = visibleCommands(pi, ["review", "workflows-review", "todos", "files", "preset", "tools", "handoff", "intel:handoff", "intel:name"]);
	const keyTools = visibleTools(pi, ["WebSearch", "WebFetch", "CodeContextSearch", "subagent", "review_loop", "start_background_service", "session_search"]);

	return [
		ctx.ui.theme.fg("accent", ctx.ui.theme.bold(`Pi cockpit — ${repoName}`)),
		ctx.ui.theme.fg(
			"muted",
			`${counts.extension} ext cmds • ${counts.skill} skills • ${counts.prompt} prompts • ${tools.active}/${tools.total} tools active`,
		),
		...(profile ? ["", ctx.ui.theme.fg("accent", profile.headline)] : []),
		"",
		ctx.ui.theme.fg("accent", "Mental model"),
		bullet(
			ctx,
			`${parallelLane.map((name) => `/${name}`).join(" ")} = isolated tmux/worktree side-agents`,
		),
		bullet(
			ctx,
			`${subagentLane.map((name) => `/${name}`).join(" ")} = orchestrated reusable subagents`,
		),
		bullet(ctx, "Use side-agents for parallel teammate work; use subagents for decomposition, focused review, and parallel research."),
		"",
		ctx.ui.theme.fg("accent", "Daily leverage"),
		bullet(ctx, daily.map((name) => `/${name}`).join(" ")),
		ctx.ui.theme.fg("accent", "Tool powers"),
		bullet(ctx, keyTools.join(" • ")),
		ctx.ui.theme.fg("muted", "Ctrl+Shift+A → subagent manager • /welcome to reopen • /capabilities for the full map"),
	];
}

function buildExpandedWidget(pi: ExtensionAPI, ctx: ExtensionContext, config: CockpitConfig): string[] {
	const counts = sourceCounts(pi);
	const tools = toolCounts(pi);
	const commands = commandMap(pi);
	const toolInfo = toolMap(pi);
	const repoName = repoNameForCwd(ctx.cwd);
	const profile = resolveProfile(repoName, config);
	const lines: string[] = [
		ctx.ui.theme.fg("accent", ctx.ui.theme.bold("Pi capability map")),
		ctx.ui.theme.fg(
			"muted",
			`${counts.extension} ext cmds • ${counts.skill} skills • ${counts.prompt} prompts • ${tools.active}/${tools.total} tools active • repo: ${repoName}`,
		),
		"",
	];

	if (profile) {
		lines.push(ctx.ui.theme.fg("accent", "Project focus"));
		lines.push(bullet(ctx, profile.headline));
		if (profile.commands && profile.commands.length > 0) {
			const present = visibleCommands(pi, profile.commands);
			if (present.length > 0) lines.push(bullet(ctx, `Pinned commands: ${present.map((name) => `/${name}`).join(" ")}`));
		}
		if (profile.tools && profile.tools.length > 0) {
			const presentTools = visibleTools(pi, profile.tools);
			if (presentTools.length > 0) lines.push(bullet(ctx, `Pinned tools: ${presentTools.join(" • ")}`));
		}
		for (const tip of profile.tips ?? []) lines.push(bullet(ctx, tip));
		lines.push("");
	}

	lines.push(ctx.ui.theme.fg("accent", "Mental model"));
	lines.push(bullet(ctx, "/agent + /agents = real isolated parallel worktrees in tmux."));
	lines.push(bullet(ctx, "/subagents + /run + /chain + /parallel = reusable orchestration."));
	lines.push(bullet(ctx, "Use /review for deliberate review flows, not just ad-hoc prompts."));
	lines.push("");

	for (const group of GROUPS) {
		const present = group.items.filter((item) => commands.has(item.name));
		if (present.length === 0) continue;
		lines.push(ctx.ui.theme.fg("accent", group.title));
		for (const item of present) {
			lines.push(
				`${formatCommandSpan(ctx, item.name)} ${ctx.ui.theme.fg("muted", "—")} ${ctx.ui.theme.fg("dim", item.summary)}`,
			);
		}
		lines.push("");
	}

	for (const group of TOOL_GROUPS) {
		const present = group.items.filter((item) => toolInfo.has(item.name));
		if (present.length === 0) continue;
		lines.push(ctx.ui.theme.fg("accent", group.title));
		for (const item of present) {
			lines.push(
				`${formatToolSpan(ctx, item.name)} ${ctx.ui.theme.fg("muted", "—")} ${ctx.ui.theme.fg("dim", item.summary)}`,
			);
		}
		lines.push("");
	}

	const coveredCommands = new Set(GROUPS.flatMap((group) => group.items.map((item) => item.name)));
	const otherExtensionCommands = getCommands(pi)
		.filter((command) => command.source === "extension" && !coveredCommands.has(command.name))
		.map((command) => command.name)
		.sort();
	if (otherExtensionCommands.length > 0) {
		lines.push(ctx.ui.theme.fg("accent", "Other extension commands"));
		lines.push(bullet(ctx, otherExtensionCommands.map((name) => `/${name}`).join(" ")));
		lines.push("");
	}

	lines.push(ctx.ui.theme.fg("accent", "Habits"));
	lines.push(bullet(ctx, "Inside tmux: /agent for true parallel coding sprints."));
	lines.push(bullet(ctx, "Named-agent orchestration: /subagents, /run, /chain, /parallel, /subagents-doctor."));
	lines.push(bullet(ctx, "After runtime/config changes: /reload."));
	lines.push(bullet(ctx, "Use /welcome when you forget the setup; use /capabilities for the full map."));
	lines.push(bullet(ctx, "Skills are on-demand: use /skill:name when you want to force one."));
	return lines;
}

function renderWidget(pi: ExtensionAPI, ctx: ExtensionContext, expanded: boolean, config: CockpitConfig): void {
	if (!ctx.hasUI) return;
	ctx.ui.setWidget(WIDGET_KEY, expanded ? buildExpandedWidget(pi, ctx, config) : buildCompactWidget(pi, ctx, config));
}

export default function startupCockpitExtension(pi: ExtensionAPI) {
	let hiddenForSession = false;
	const config = loadConfig();

	function showCompact(ctx: ExtensionContext) {
		hiddenForSession = false;
		renderWidget(pi, ctx, false, config);
	}

	function showExpanded(ctx: ExtensionContext) {
		hiddenForSession = false;
		renderWidget(pi, ctx, true, config);
	}

	function hide(ctx: ExtensionContext) {
		if (!ctx.hasUI) return;
		hiddenForSession = true;
		ctx.ui.setWidget(WIDGET_KEY, undefined);
	}

	pi.on("session_start", async (_event, ctx) => {
		showCompact(ctx);
	});

	pi.on("session_switch", async (_event, ctx) => {
		showCompact(ctx);
	});

	pi.on("input", async (_event, ctx) => {
		if (!hiddenForSession) hide(ctx);
		return { action: "continue" as const };
	});

	pi.registerCommand("welcome", {
		description: "Show the startup cockpit widget again",
		handler: async (_args, ctx) => {
			showCompact(ctx);
			ctx.ui.notify("Startup cockpit shown", "info");
		},
	});

	pi.registerCommand("capabilities", {
		description: "Show the expanded capability map widget",
		handler: async (_args, ctx) => {
			showExpanded(ctx);
			ctx.ui.notify("Expanded capability map shown", "info");
		},
	});

	pi.registerCommand("welcome-hide", {
		description: "Hide the startup cockpit for the current session",
		handler: async (_args, ctx) => {
			hide(ctx);
			ctx.ui.notify("Startup cockpit hidden for this session", "info");
		},
	});
}
