/**
 * Toolchain Guard Extension
 *
 * Python-only runtime enforcement for Pi's bash tool.
 *
 * Why this exists:
 * - This machine uses `pnpm` by default for Node repo work, but `npm`/`npx`/`yarn`
 *   are intentionally still allowed.
 * - Python package-manager guardrails remain useful, especially to keep agents on
 *   `uv`, avoid accidental `pip`/`poetry`, and prevent `python -m py_compile`
 *   from spraying `__pycache__` files around repos.
 * - The user works inside WSL on a Windows machine, so explicit Windows executables
 *   such as `python.exe`, `py.exe`, or `pip.exe` should be treated the same as their
 *   Unix counterparts.
 *
 * Enforcement layers:
 * 1. PATH shims in `intercepted-commands/` catch direct invocations that resolve via PATH.
 * 2. A spawn hook parses shell segments and catches explicit paths and module invocations
 *    that can bypass PATH shims.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { createBashTool } from "@mariozechner/pi-coding-agent";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const interceptedCommandsPath = join(__dirname, "intercepted-commands");

const directCommandMessages = {
	pip: [
		"Error: pip is disabled. Use the correct tool:",
		"",
		"  To add a project dependency:     uv add PACKAGE",
		"  To install in the active venv:   uv pip install PACKAGE",
		"  To install a CLI tool globally:  pipx install PACKAGE",
	].join("\n"),
	pip3: [
		"Error: pip3 is disabled. Use the correct tool:",
		"",
		"  To add a project dependency:     uv add PACKAGE",
		"  To install in the active venv:   uv pip install PACKAGE",
		"  To install a CLI tool globally:  pipx install PACKAGE",
	].join("\n"),
	poetry: [
		"Error: poetry is disabled. Use uv instead:",
		"",
		"  To initialize a project:         uv init",
		"  To add a dependency:             uv add PACKAGE",
		"  To sync dependencies:            uv sync",
		"  To run a command:                uv run COMMAND",
	].join("\n"),
} as const;

const pythonModuleMessages = {
	pip: [
		"Error: 'python -m pip' is disabled. Use the correct tool:",
		"",
		"  To add a project dependency:     uv add PACKAGE",
		"  To install in the active venv:   uv pip install PACKAGE",
		"  To install a CLI tool globally:  pipx install PACKAGE",
	].join("\n"),
	venv: [
		"Error: 'python -m venv' is disabled. Use uv instead:",
		"",
		"  To create a virtual environment: uv venv",
	].join("\n"),
	py_compile: [
		"Error: 'python -m py_compile' is disabled because it writes .pyc files to __pycache__.",
		"",
		"  To verify syntax without bytecode output: uv run python -m ast path/to/file.py >/dev/null",
	].join("\n"),
} as const;

function splitShellSegments(command: string): string[] {
	const segments: string[] = [];
	let current = "";
	let inSingle = false;
	let inDouble = false;
	let escaped = false;

	const pushCurrent = () => {
		const trimmed = current.trim();
		if (trimmed) segments.push(trimmed);
		current = "";
	};

	for (let i = 0; i < command.length; i += 1) {
		const char = command[i];
		const next = command[i + 1];

		if (escaped) {
			current += char;
			escaped = false;
			continue;
		}

		if (char === "\\" && !inSingle) {
			current += char;
			escaped = true;
			continue;
		}

		if (char === "'" && !inDouble) {
			inSingle = !inSingle;
			current += char;
			continue;
		}

		if (char === '"' && !inSingle) {
			inDouble = !inDouble;
			current += char;
			continue;
		}

		if (!inSingle && !inDouble) {
			if (char === "\n" || char === ";") {
				pushCurrent();
				continue;
			}

			if ((char === "&" || char === "|") && next === char) {
				pushCurrent();
				i += 1;
				continue;
			}

			if (char === "&" || char === "|") {
				pushCurrent();
				continue;
			}
		}

		current += char;
	}

	pushCurrent();
	return segments;
}

function tokenizeShellSegment(segment: string): string[] {
	const tokens: string[] = [];
	let current = "";
	let inSingle = false;
	let inDouble = false;
	let escaped = false;

	const pushCurrent = () => {
		if (current.length > 0) tokens.push(current);
		current = "";
	};

	for (let i = 0; i < segment.length; i += 1) {
		const char = segment[i];

		if (escaped) {
			current += char;
			escaped = false;
			continue;
		}

		if (char === "\\" && !inSingle) {
			escaped = true;
			continue;
		}

		if (char === "'" && !inDouble) {
			inSingle = !inSingle;
			continue;
		}

		if (char === '"' && !inSingle) {
			inDouble = !inDouble;
			continue;
		}

		if (!inSingle && !inDouble && /\s/.test(char)) {
			pushCurrent();
			continue;
		}

		current += char;
	}

	pushCurrent();
	return tokens;
}

function normalizeExecutableName(token: string): string {
	const basename = token
		.trim()
		.split(/[\\/]/)
		.pop() ?? token;

	return basename.toLowerCase().replace(/\.(?:exe|cmd|bat)$/i, "");
}

function isEnvAssignment(token: string): boolean {
	return /^[A-Za-z_][A-Za-z0-9_]*=.*/.test(token);
}

function isPythonLauncher(name: string): boolean {
	return /^(?:python(?:3(?:\.\d+)?)?|py)$/.test(name);
}

function getEntrypointIndex(tokens: string[]): number {
	let index = 0;

	while (index < tokens.length) {
		const token = tokens[index];
		const normalized = normalizeExecutableName(token);

		if (isEnvAssignment(token)) {
			index += 1;
			continue;
		}

		if (normalized === "env") {
			index += 1;
			while (index < tokens.length && isEnvAssignment(tokens[index])) {
				index += 1;
			}
			continue;
		}

		if (normalized === "command" || normalized === "builtin" || normalized === "exec") {
			index += 1;
			continue;
		}

		break;
	}

	return index;
}

function getBlockedCommandMessage(command: string): string | null {
	for (const segment of splitShellSegments(command)) {
		const tokens = tokenizeShellSegment(segment);
		if (tokens.length === 0) continue;

		const entrypointIndex = getEntrypointIndex(tokens);
		const entrypoint = tokens[entrypointIndex];
		if (!entrypoint) continue;

		const entrypointName = normalizeExecutableName(entrypoint);
		if (entrypointName in directCommandMessages) {
			return directCommandMessages[entrypointName as keyof typeof directCommandMessages];
		}

		if (!isPythonLauncher(entrypointName)) continue;

		for (let i = entrypointIndex + 1; i < tokens.length; i += 1) {
			const token = tokens[i];

			if (token === "--") break;

			if (token === "-m") {
				const moduleName = tokens[i + 1]?.toLowerCase();
				if (moduleName && moduleName in pythonModuleMessages) {
					return pythonModuleMessages[moduleName as keyof typeof pythonModuleMessages];
				}
				continue;
			}

			if (/^-m(?:pip|venv|py_compile)$/i.test(token)) {
				const moduleName = token.slice(2).toLowerCase() as keyof typeof pythonModuleMessages;
				return pythonModuleMessages[moduleName];
			}
		}
	}

	return null;
}

export default function (pi: ExtensionAPI) {
	const bashTool = createBashTool(process.cwd(), {
		commandPrefix: `export PATH="${interceptedCommandsPath}:$PATH"`,
		spawnHook: (ctx) => {
			const message = getBlockedCommandMessage(ctx.command);
			if (message) {
				throw new Error(message);
			}
			return ctx;
		},
	});

	pi.registerTool(bashTool);
}
