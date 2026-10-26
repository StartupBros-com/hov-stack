/**
 * DCG Guard Extension
 *
 * Routes Pi bash tool calls through destructive_command_guard's stable robot
 * API before execution. Exit code 1 is an authoritative denial. Interactive
 * parent sessions fail open on runtime errors with a conspicuous warning;
 * headless pi-subagent children fail closed because their stderr is buffered.
 *
 * https://github.com/Dicklesworthstone/destructive_command_guard/blob/v0.6.5/docs/pi-integration.md
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_DCG_BIN = join(homedir(), ".local", "bin", "dcg");
export const DEFAULT_DCG_TIMEOUT_MS = 3_000;
export const DEFAULT_DCG_OUTPUT_LIMIT_BYTES = 64 * 1024;

type SpawnFunction = typeof spawn;

export interface DcgDecision {
	deny: boolean;
	reason: string;
	warning?: string;
}

export interface DcgDecisionOptions {
	bin?: string;
	failClosed?: boolean;
	timeoutMs?: number;
	outputLimitBytes?: number;
	spawnFn?: SpawnFunction;
}

export interface DcgGuardOptions extends DcgDecisionOptions {
	warn?: (message: string, ctx: ExtensionContext) => void;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function resolveDcgBin(env: NodeJS.ProcessEnv = process.env): string {
	const override = env.DCG_BIN?.trim();
	return override || DEFAULT_DCG_BIN;
}

function deniedReason(stdout: string): string {
	let reason = "Blocked by DCG (destructive command).";

	try {
		const parsed: unknown = JSON.parse(stdout);
		if (!isRecord(parsed)) return reason;

		if (typeof parsed.reason === "string" && parsed.reason.trim()) {
			reason = parsed.reason.trim();
		} else if (typeof parsed.explanation === "string" && parsed.explanation.trim()) {
			reason = parsed.explanation.trim();
		}

		const identifiers = [parsed.pack_id, parsed.rule_id].filter(
			(value): value is string => typeof value === "string" && value.trim().length > 0,
		);
		if (identifiers.length > 0) {
			reason += ` [${identifiers.join("/")}]`;
		}
	} catch {
		// Exit code 1 remains authoritative even if the optional JSON is malformed.
	}

	return reason;
}

function runtimeFailure(detail: string, bin: string, failClosed: boolean): DcgDecision {
	const disposition = failClosed ? "FAILING CLOSED" : "FAILING OPEN";
	const warning = `DCG GUARD FAILURE - ${disposition}: ${detail}. Verify ${bin}.`;

	return {
		deny: failClosed,
		reason: failClosed
			? `DCG guard unavailable (${detail}); refusing an unchecked bash command.`
			: "",
		warning,
	};
}

function positiveInteger(value: number | undefined, fallback: number): number {
	return Number.isFinite(value) && (value ?? 0) > 0 ? Math.floor(value as number) : fallback;
}

/**
 * Ask DCG for a decision without executing the candidate command.
 *
 * This function is exported so the process boundary can be tested without a
 * live Pi runtime. `spawn` is deliberately used without a shell: the candidate
 * command is a single argv value passed to DCG, never evaluated by this guard.
 */
export function dcgDecision(command: string, options: DcgDecisionOptions = {}): Promise<DcgDecision> {
	const bin = options.bin?.trim() || resolveDcgBin();
	const failClosed = options.failClosed ?? false;
	const timeoutMs = positiveInteger(options.timeoutMs, DEFAULT_DCG_TIMEOUT_MS);
	const outputLimitBytes = positiveInteger(options.outputLimitBytes, DEFAULT_DCG_OUTPUT_LIMIT_BYTES);
	const spawnFn = options.spawnFn ?? spawn;

	return new Promise((resolve) => {
		let child: ReturnType<SpawnFunction>;
		let settled = false;
		let timeout: NodeJS.Timeout | undefined;
		let stdoutBytes = 0;
		const stdoutChunks: Buffer[] = [];

		const settle = (decision: DcgDecision) => {
			if (settled) return;
			settled = true;
			if (timeout) clearTimeout(timeout);
			resolve(decision);
		};

		const terminateAndFailOpen = (detail: string) => {
			if (settled) return;
			settle(runtimeFailure(detail, bin, failClosed));
			try {
				child.kill("SIGKILL");
			} catch {
				// The warning already tells the operator that the guard failed open.
			}
		};

		try {
			child = spawnFn(bin, ["--robot", "test", command], {
				stdio: ["ignore", "pipe", "ignore"],
			});
		} catch (error) {
			const detail = error instanceof Error ? error.message : String(error);
			settle(runtimeFailure(`could not start DCG (${detail})`, bin, failClosed));
			return;
		}

		child.stdout.on("data", (chunk: Buffer | string) => {
			if (settled) return;
			const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
			stdoutBytes += buffer.length;

			if (stdoutBytes > outputLimitBytes) {
				terminateAndFailOpen(`DCG output exceeded ${outputLimitBytes} bytes`);
				return;
			}

			stdoutChunks.push(buffer);
		});

		child.stdout.once("error", (error) => {
			terminateAndFailOpen(`could not read DCG output (${error.message})`);
		});

		child.once("error", (error) => {
			settle(runtimeFailure(`DCG process error (${error.message})`, bin, failClosed));
		});

		child.once("close", (code, signal) => {
			if (settled) return;

			if (code === 1) {
				settle({
					deny: true,
					reason: deniedReason(Buffer.concat(stdoutChunks).toString("utf8")),
				});
				return;
			}

			if (code === 0) {
				settle({ deny: false, reason: "" });
				return;
			}

			const status = signal ? `signal ${signal}` : `exit code ${String(code)}`;
			settle(runtimeFailure(`DCG ended with ${status}`, bin, failClosed));
		});

		timeout = setTimeout(() => {
			terminateAndFailOpen(`DCG timed out after ${timeoutMs}ms`);
		}, timeoutMs);
	});
}

function commandFromInput(input: unknown): string {
	if (!isRecord(input)) return "";
	return String(input.command ?? "");
}

function warnFailOpen(message: string, ctx: ExtensionContext): void {
	const rendered = `⚠️ ${message}`;
	console.error(`[dcg-guard] ${rendered}`);

	try {
		ctx.ui?.notify?.(rendered, "warning");
	} catch {
		// Headless and minimal UI modes still receive the stderr warning above.
	}
}

export function registerDcgGuard(pi: ExtensionAPI, options: DcgGuardOptions = {}): void {
	const { warn = warnFailOpen, ...decisionOptions } = options;

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = commandFromInput(event.input);
		if (!command.trim()) return undefined;

		const decision = await dcgDecision(command, decisionOptions);
		if (decision.warning) warn(decision.warning, ctx);

		if (decision.deny) {
			return { block: true, reason: decision.reason };
		}

		return undefined;
	});
}

export function shouldFailClosedForRuntime(env: NodeJS.ProcessEnv = process.env): boolean {
	return env.PI_SUBAGENT_CHILD === "1";
}

export default function (pi: ExtensionAPI): void {
	registerDcgGuard(pi, { failClosed: shouldFailClosedForRuntime() });
}
