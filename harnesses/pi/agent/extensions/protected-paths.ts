/**
 * Protected Paths Extension
 *
 * Prompts for confirmation before write/edit operations to protected paths.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const protectedPaths = [".env", ".git/", "node_modules/"];

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "write" && event.toolName !== "edit") {
			return undefined;
		}

		const path = event.input.path as string;
		const isProtected = protectedPaths.some((p) => path.includes(p));

		if (isProtected && ctx.hasUI) {
			const answer = await ctx.ui.select(
				`Write to protected path: ${path} — allow?`,
				["Yes, allow this write", "No, block it"],
			);

			if (!answer || answer.startsWith("No")) {
				return { block: true, reason: `User denied write to "${path}"` };
			}
		}

		return undefined;
	});
}
