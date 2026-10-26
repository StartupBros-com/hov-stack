import {
	getAgentDir,
	SettingsManager,
	type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";

// Temporary local workaround for:
// https://github.com/earendil-works/pi/issues/4945#issuecomment-4577087287
//
// Pi 0.78.1 hard-codes the Codex SSE response-header timeout at 10s inside
// @earendil-works/pi-ai. This narrowly redirects only that specific timer to
// the normal Pi httpIdleTimeoutMs setting, leaving all other timers untouched.

const CODEX_SSE_HEADER_TIMEOUT_MS = 10_000;
const PATCH_KEY = Symbol.for("pi.extension.codexSseHeaderTimeoutPatch");
const ORIGINAL_TIMEOUT_ERROR = `Codex SSE response headers timed out after ${CODEX_SSE_HEADER_TIMEOUT_MS}ms`;
const MAX_NODE_TIMEOUT_MS = 2_147_483_647;

type PatchState = {
	originalSetTimeout: typeof globalThis.setTimeout;
	originalAbort: typeof AbortController.prototype.abort;
	timeoutMs: number;
};

export default function (pi: ExtensionAPI) {
	const validationError = validateInstalledCodexProvider();
	if (validationError) {
		const message = `Codex SSE timeout extension disabled: ${validationError}`;
		console.warn(`[codex-sse-timeout] ${message}`);
		pi.on("session_start", (_event, ctx) => {
			if (ctx.hasUI) ctx.ui.notify(message, "warning");
		});
		return;
	}

	installPatch();
}

function installPatch(): void {
	const global = globalThis as unknown as Record<
		symbol,
		PatchState | undefined
	>;
	const state: PatchState = global[PATCH_KEY] ?? {
		originalSetTimeout: globalThis.setTimeout,
		originalAbort: AbortController.prototype.abort,
		timeoutMs: getEffectiveHttpIdleTimeoutMs(),
	};
	state.timeoutMs = getEffectiveHttpIdleTimeoutMs();

	globalThis.setTimeout = ((
		handler: TimerHandler,
		timeout?: number,
		...args: unknown[]
	) => {
		if (timeout === CODEX_SSE_HEADER_TIMEOUT_MS && isCodexSseHeaderTimer()) {
			return state.originalSetTimeout(handler, state.timeoutMs, ...args);
		}

		return state.originalSetTimeout(handler, timeout, ...args);
	}) as typeof globalThis.setTimeout;

	AbortController.prototype.abort = function patchedAbort(
		this: AbortController,
		reason?: unknown,
	): void {
		if (isCodexSseTimeoutError(reason)) {
			reason = new Error(
				`Codex SSE response headers timed out after ${state.timeoutMs}ms`,
			);
		}
		return state.originalAbort.call(this, reason);
	};

	global[PATCH_KEY] = state;
}

function getEffectiveHttpIdleTimeoutMs(): number {
	const timeoutMs = SettingsManager.create(
		process.cwd(),
		getAgentDir(),
	).getHttpIdleTimeoutMs();
	if (timeoutMs === 0) return MAX_NODE_TIMEOUT_MS;
	return Math.min(timeoutMs, MAX_NODE_TIMEOUT_MS);
}

function isCodexSseHeaderTimer(): boolean {
	const stack = new Error().stack ?? "";
	return (
		stack.includes("createSSEHeaderTimeout") &&
		stack.includes("openai-codex-responses")
	);
}

function isCodexSseTimeoutError(reason: unknown): reason is Error {
	return (
		reason instanceof Error &&
		reason.message === ORIGINAL_TIMEOUT_ERROR &&
		(reason.stack ?? "").includes("openai-codex-responses")
	);
}

function validateInstalledCodexProvider(): string | undefined {
	const providerPath = resolveCodexProviderPath();
	if (!providerPath) return "could not locate installed Codex provider file";

	const source = readFileSync(providerPath, "utf8");
	const requiredSnippets = [
		"const DEFAULT_SSE_HEADER_TIMEOUT_MS = 10_000;",
		"function createSSEHeaderTimeout()",
		"Codex SSE response headers timed out after ${DEFAULT_SSE_HEADER_TIMEOUT_MS}ms",
		"const headerTimeout = createSSEHeaderTimeout();",
	];

	const missing = requiredSnippets.filter(
		(snippet) => !source.includes(snippet),
	);
	return missing.length === 0
		? undefined
		: `provider code did not match expected implementation; missing ${missing.length} validation snippet(s)`;
}

function resolveCodexProviderPath(): string | undefined {
	const cliPath = process.argv[1] ? realpathSync(process.argv[1]) : undefined;
	if (!cliPath) return undefined;

	const packageRoot = dirname(dirname(cliPath));
	const providerRelativePath = join(
		"dist",
		"providers",
		"openai-codex-responses.js",
	);
	const candidates = [
		// npm-style nested dependency layout
		join(
			packageRoot,
			"node_modules",
			"@earendil-works",
			"pi-ai",
			providerRelativePath,
		),
		// pnpm-style sibling dependency layout used by this machine's global install
		join(dirname(packageRoot), "pi-ai", providerRelativePath),
	];

	return candidates.find((providerPath) => existsSync(providerPath));
}
