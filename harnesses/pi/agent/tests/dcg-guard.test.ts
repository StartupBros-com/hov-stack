import assert from "node:assert/strict";
import type { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import {
	DEFAULT_DCG_BIN,
	dcgDecision,
	registerDcgGuard,
	resolveDcgBin,
	shouldFailClosedForRuntime,
} from "../extensions/dcg-guard.ts";

type SpawnFunction = typeof spawn;

class FakeChild extends EventEmitter {
	readonly stdout = new PassThrough();
	readonly killSignals: Array<NodeJS.Signals | number | undefined> = [];

	kill(signal?: NodeJS.Signals | number): boolean {
		this.killSignals.push(signal);
		return true;
	}
}

interface SpawnHarness {
	child: FakeChild;
	spawnFn: SpawnFunction;
	calls: Array<{ bin: string; args: string[]; options: unknown }>;
}

function spawnHarness(action?: (child: FakeChild) => void): SpawnHarness {
	const child = new FakeChild();
	const calls: SpawnHarness["calls"] = [];
	const spawnFn = ((bin: string, args: string[], options: unknown) => {
		calls.push({ bin, args, options });
		if (action) queueMicrotask(() => action(child));
		return child;
	}) as unknown as SpawnFunction;

	return { child, spawnFn, calls };
}

function closeWith(code: number, stdout = ""): (child: FakeChild) => void {
	return (child) => {
		if (stdout) child.stdout.write(stdout);
		child.emit("close", code, null);
	};
}

test("uses the absolute default binary and honors DCG_BIN", () => {
	assert.equal(resolveDcgBin({}), DEFAULT_DCG_BIN);
	assert.equal(resolveDcgBin({ DCG_BIN: "/opt/dcg/bin/dcg" }), "/opt/dcg/bin/dcg");
	assert.equal(resolveDcgBin({ DCG_BIN: "   " }), DEFAULT_DCG_BIN);
});

test("passes the candidate command as one argv value without a shell", async () => {
	const command = "printf safe; git reset --hard HEAD~1";
	const harness = spawnHarness(closeWith(0));

	const decision = await dcgDecision(command, {
		bin: "/test/dcg",
		spawnFn: harness.spawnFn,
	});

	assert.deepEqual(decision, { deny: false, reason: "" });
	assert.equal(harness.calls.length, 1);
	assert.deepEqual(harness.calls[0].args, ["--robot", "test", command]);
	assert.deepEqual(harness.calls[0].options, { stdio: ["ignore", "pipe", "ignore"] });
	assert.equal("shell" in (harness.calls[0].options as object), false);
});

test("exit code 1 blocks and carries the DCG reason and identifiers", async () => {
	const output = JSON.stringify({
		reason: "Refusing destructive Git recovery",
		pack_id: "core.git",
		rule_id: "git.reset-hard",
	});
	const harness = spawnHarness(closeWith(1, output));

	const decision = await dcgDecision("git reset --hard HEAD~1", { spawnFn: harness.spawnFn });

	assert.equal(decision.deny, true);
	assert.match(decision.reason, /Refusing destructive Git recovery/);
	assert.match(decision.reason, /core\.git\/git\.reset-hard/);
	assert.equal(decision.warning, undefined);
});

test("exit code 1 remains blocking when DCG output is malformed", async () => {
	const harness = spawnHarness(closeWith(1, "not-json"));
	const decision = await dcgDecision("dangerous candidate", { spawnFn: harness.spawnFn });

	assert.deepEqual(decision, {
		deny: true,
		reason: "Blocked by DCG (destructive command).",
	});
});

test("spawn errors fail open with a warning and settle only once", async () => {
	const harness = spawnHarness((child) => {
		child.emit("error", new Error("ENOENT"));
		child.emit("close", 1, null);
	});

	const decision = await dcgDecision("candidate", { bin: "/missing/dcg", spawnFn: harness.spawnFn });

	assert.equal(decision.deny, false);
	assert.match(decision.warning ?? "", /FAILING OPEN/);
	assert.match(decision.warning ?? "", /ENOENT/);
	assert.match(decision.warning ?? "", /\/missing\/dcg/);
});

test("abnormal exit codes fail open with a warning", async () => {
	const harness = spawnHarness(closeWith(3));
	const decision = await dcgDecision("candidate", { spawnFn: harness.spawnFn });

	assert.equal(decision.deny, false);
	assert.match(decision.warning ?? "", /exit code 3/);
});

test("pi-subagent children fail closed when DCG has a runtime error", async () => {
	assert.equal(shouldFailClosedForRuntime({ PI_SUBAGENT_CHILD: "1" }), true);
	assert.equal(shouldFailClosedForRuntime({}), false);

	const harness = spawnHarness(closeWith(3));
	const decision = await dcgDecision("candidate", {
		failClosed: true,
		spawnFn: harness.spawnFn,
	});

	assert.equal(decision.deny, true);
	assert.match(decision.reason, /refusing an unchecked bash command/);
	assert.match(decision.warning ?? "", /FAILING CLOSED/);
});

test("timeout kills DCG and fails open", async () => {
	const harness = spawnHarness();
	const decision = await dcgDecision("candidate", {
		spawnFn: harness.spawnFn,
		timeoutMs: 5,
	});

	assert.equal(decision.deny, false);
	assert.match(decision.warning ?? "", /timed out after 5ms/);
	assert.deepEqual(harness.child.killSignals, ["SIGKILL"]);
});

test("oversized output kills DCG and fails open without buffering it", async () => {
	const harness = spawnHarness((child) => {
		child.stdout.write(Buffer.alloc(17, "x"));
		child.emit("close", 1, null);
	});

	const decision = await dcgDecision("candidate", {
		spawnFn: harness.spawnFn,
		outputLimitBytes: 16,
	});

	assert.equal(decision.deny, false);
	assert.match(decision.warning ?? "", /exceeded 16 bytes/);
	assert.deepEqual(harness.child.killSignals, ["SIGKILL"]);
});

test("Pi handler ignores non-bash and empty calls", async () => {
	let handler: ((event: any, ctx: any) => Promise<unknown>) | undefined;
	const pi = {
		on: (_event: string, callback: typeof handler) => {
			handler = callback;
		},
	} as unknown as ExtensionAPI;
	const harness = spawnHarness(closeWith(1));
	registerDcgGuard(pi, { spawnFn: harness.spawnFn });

	assert.ok(handler);
	assert.equal(await handler!({ toolName: "read", input: {} }, {}), undefined);
	assert.equal(await handler!({ toolName: "bash", input: { command: "  " } }, {}), undefined);
	assert.equal(harness.calls.length, 0);
});

test("Pi handler blocks denials and reports fail-open warnings", async () => {
	let handler: ((event: any, ctx: ExtensionContext) => Promise<unknown>) | undefined;
	const pi = {
		on: (_event: string, callback: typeof handler) => {
			handler = callback;
		},
	} as unknown as ExtensionAPI;

	const denied = spawnHarness(closeWith(1, JSON.stringify({ reason: "Denied by test DCG" })));
	registerDcgGuard(pi, { spawnFn: denied.spawnFn });
	assert.ok(handler);
	assert.deepEqual(
		await handler!({ toolName: "bash", input: { command: "candidate" } }, {} as ExtensionContext),
		{ block: true, reason: "Denied by test DCG" },
	);

	const warnings: string[] = [];
	const errored = spawnHarness(closeWith(3));
	registerDcgGuard(pi, {
		spawnFn: errored.spawnFn,
		warn: (message) => warnings.push(message),
	});
	assert.equal(
		await handler!({ toolName: "bash", input: { command: "candidate" } }, {} as ExtensionContext),
		undefined,
	);
	assert.equal(warnings.length, 1);
	assert.match(warnings[0], /FAILING OPEN/);
});
