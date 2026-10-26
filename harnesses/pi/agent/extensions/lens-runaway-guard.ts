/**
 * Lens Runaway Guard
 *
 * Prevents broad pi-lens project-wide LSP scans from wedging Pi when a session is
 * started from a workspace-of-workspaces such as ~/SITES. `lens_diagnostics
 * mode=full` walks every LSP-supported file under cwd and can spawn many language
 * servers; at ~/SITES that includes many repos and agent worktrees.
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const homeDir = os.homedir();
const knownBroadRoots = new Set([
	path.resolve(homeDir),
	path.resolve(homeDir, "SITES"),
]);

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function resolveFromCwd(cwd: string, maybePath: unknown): string | undefined {
	if (typeof maybePath !== "string" || maybePath.trim() === "") return undefined;
	return path.resolve(cwd, maybePath.replace(/^~(?=$|\/)/, homeDir));
}

function countImmediateRepoLikeChildren(dir: string): number {
	try {
		let count = 0;
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			if (!entry.isDirectory() || entry.name === "node_modules" || entry.name === ".git") continue;
			const child = path.join(dir, entry.name);
			if (fs.existsSync(path.join(child, ".git")) || fs.existsSync(path.join(child, "package.json"))) {
				count += 1;
			}
			if (count >= 6) return count;
		}
		return count;
	} catch {
		return 0;
	}
}

function isBroadWorkspace(dir: string): boolean {
	const resolved = path.resolve(dir);
	if (knownBroadRoots.has(resolved)) return true;
	return countImmediateRepoLikeChildren(resolved) >= 6;
}

function describeAlternatives(cwd: string): string {
	return [
		"Blocked a broad pi-lens LSP scan to keep Pi responsive.",
		`cwd: ${cwd}`,
		"Use `lens_diagnostics` with `mode: \"all\"` for cached session diagnostics,",
		"or run `lsp_diagnostics` on a specific repo/file/files list instead of ~/SITES.",
		"Override for one Pi process with `PI_LENS_ALLOW_BROAD_FULL=1 pi`.",
	].join("\n");
}

function notify(ctx: ExtensionContext, message: string) {
	try {
		ctx.ui?.notify?.(message, "warning");
	} catch {
		// Notification support varies by mode; blocking reason is still returned.
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", (event, ctx) => {
		if (process.env.PI_LENS_ALLOW_BROAD_FULL === "1") return;

		const cwd = path.resolve(ctx.cwd || process.cwd());
		const input = isRecord(event.input) ? event.input : {};

		if (event.toolName === "lens_diagnostics" && input.mode === "full" && isBroadWorkspace(cwd)) {
			const reason = describeAlternatives(cwd);
			notify(ctx, "Blocked broad lens_diagnostics mode=full");
			return { block: true, reason };
		}

		if (event.toolName === "lsp_diagnostics") {
			const target = resolveFromCwd(cwd, input.filePath) ?? cwd;
			const hasExplicitFileBatch = Array.isArray(input.filePaths) && input.filePaths.length > 0;
			if (!hasExplicitFileBatch && isBroadWorkspace(target)) {
				const reason = describeAlternatives(target);
				notify(ctx, "Blocked broad lsp_diagnostics directory scan");
				return { block: true, reason };
			}
		}
	});
}
