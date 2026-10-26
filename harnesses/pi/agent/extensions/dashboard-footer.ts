/**
 * Dashboard Footer
 *
 * Single-line footer replacing the built-in 2-3 line footer.
 * Shows the metrics that matter, at a glance:
 *
 *   ████████░░ 42% │ ↑12.3k ↓8.1k │ $2.47 │ opus-4-6 high │ main │ T15
 *
 * Visual context bar is color-coded: green <50%, yellow 50-75%, red >75%.
 * Segments drop progressively on narrow terminals.
 * Extension statuses appear on a second line when present.
 *
 * Toggle: /footer
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { keyText } from "@mariozechner/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@mariozechner/pi-tui";

function fmtTokens(n: number): string {
	if (n < 1_000) return `${n}`;
	if (n < 10_000) return `${(n / 1_000).toFixed(1)}k`;
	if (n < 1_000_000) return `${Math.round(n / 1_000)}k`;
	if (n < 10_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
	return `${Math.round(n / 1_000_000)}M`;
}

function fmtCost(n: number): string {
	if (n >= 10) return `$${n.toFixed(1)}`;
	if (n >= 1) return `$${n.toFixed(2)}`;
	return `$${n.toFixed(3)}`;
}

function shortModel(id: string): string {
	const slash = id.indexOf("/");
	const name = slash >= 0 ? id.slice(slash + 1) : id;
	return name.replace(/^claude-/, "");
}

function compactKeybinding(id: string, fallback: string): string {
	const key = keyText(id);
	if (!key) return fallback;
	return key
		.replace(/ctrl\+/gi, "^")
		.replace(/shift\+/gi, "⇧")
		.replace(/alt\+/gi, "⌥")
		.replace(/enter/gi, "↵")
		.replace(/escape|esc/gi, "esc")
		.replace(/space/gi, "space");
}

function buildShortcutLine(theme: any): string {
	const items = [
		`${compactKeybinding("app.session.new", "F2")} new`,
		`${compactKeybinding("app.session.tree", "F3")} tree`,
		`${compactKeybinding("app.session.resume", "F4")} resume`,
		`${compactKeybinding("app.session.fork", "F5")} fork`,
		`${compactKeybinding("app.message.followUp", "⌥↵")} follow`,
		`${compactKeybinding("app.message.dequeue", "⌥↑")} dequeue`,
		`${compactKeybinding("app.tools.expand", "^O")} expand`,
	];
	return theme.fg("dim", items.join(" · "));
}

export default function (pi: ExtensionAPI) {
	let enabled = true;

	function applyFooter(ctx: ExtensionContext) {
		if (!ctx.hasUI) return;

		ctx.ui.setFooter((tui, theme, footerData) => {
			const unsub = footerData.onBranchChange(() => tui.requestRender());
			const shortcutLine = buildShortcutLine(theme);

			return {
				dispose: unsub,
				invalidate() {},
				render(width: number): string[] {
					// Session stats from all entries (includes pre-compaction for accurate totals)
					let turns = 0;
					let input = 0;
					let output = 0;
					let cost = 0;

					for (const e of ctx.sessionManager.getEntries()) {
						const entry = e as any;
						if (entry.type !== "message") continue;
						const msg = entry.message;
						if (!msg || msg.role !== "assistant") continue;
						turns++;
						const u = msg.usage;
						if (!u) continue;
						input += Number(u.input ?? 0) || 0;
						output += Number(u.output ?? 0) || 0;
						const c = u.cost;
						cost += Number(typeof c === "object" ? c?.total : c) || 0;
					}

					// Context window
					const usage = ctx.getContextUsage();
					const ctxTokens = usage?.tokens;
					const ctxWindow = usage?.contextWindow ?? 0;
					const pct =
						ctxTokens != null && ctxWindow > 0
							? Math.min(100, Math.round((ctxTokens / ctxWindow) * 100))
							: null;

					// Visual bar
					const barLen = 10;
					const filled =
						pct != null ? Math.round((pct / 100) * barLen) : 0;
					const barColor =
						pct == null
							? "dim"
							: pct > 75
								? "error"
								: pct > 50
									? "warning"
									: "success";
					const bar =
						theme.fg(barColor, "\u2588".repeat(Math.min(filled, barLen))) +
						theme.fg("dim", "\u2591".repeat(Math.max(0, barLen - filled)));
					const pctStr =
						pct != null
							? theme.fg(barColor, `${pct}%`)
							: theme.fg("dim", "?%");

					// Model + thinking
					const modelId = (ctx as any).model?.id;
					const model = modelId ? shortModel(modelId) : "\u2014";
					const reasoning = (ctx as any).model?.reasoning;
					const thinkingLevel = (ctx as any).state?.thinkingLevel;
					let modelStr = theme.fg("accent", model);
					if (reasoning && thinkingLevel && thinkingLevel !== "off") {
						modelStr += " " + theme.fg("dim", thinkingLevel);
					}

					// Git branch
					const branch = footerData.getGitBranch() ?? "";

					// Build segments in priority order
					const sep = theme.fg("dim", " \u2502 ");
					const segments: string[] = [];
					segments.push(`${bar} ${pctStr}`);
					segments.push(
						theme.fg("dim", `\u2191${fmtTokens(input)} \u2193${fmtTokens(output)}`),
					);
					if (cost > 0) segments.push(theme.fg("dim", fmtCost(cost)));
					segments.push(modelStr);
					if (branch) segments.push(theme.fg("dim", branch));
					segments.push(theme.fg("dim", `T${turns}`));

					// Progressive addition — keep adding segments while they fit
					let line = segments[0]!;
					for (let i = 1; i < segments.length; i++) {
						const candidate = line + sep + segments[i]!;
						if (visibleWidth(candidate) > width) break;
						line = candidate;
					}

					return [
						truncateToWidth(line, width),
						truncateToWidth(shortcutLine, width),
					];
				},
			};
		});
	}

	pi.on("session_start", async (_event, ctx) => {
		if (enabled) applyFooter(ctx);
	});

	pi.on("session_switch", async (_event, ctx) => {
		if (enabled) applyFooter(ctx);
	});

	pi.registerCommand("footer", {
		description: "Toggle dashboard footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			if (enabled) {
				applyFooter(ctx);
				ctx.ui.notify("Dashboard footer enabled", "info");
			} else {
				ctx.ui.setFooter(undefined);
				ctx.ui.notify("Default footer restored", "info");
			}
		},
	});
}
