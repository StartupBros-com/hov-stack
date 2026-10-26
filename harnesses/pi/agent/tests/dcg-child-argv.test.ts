import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const subagentsRoot = process.env.PI_SUBAGENTS_SOURCE || join(homedir(), "SITES", "pi-subagents");
const { buildPiArgs } = (await import(
	pathToFileURL(join(subagentsRoot, "src", "runs", "shared", "pi-args.ts")).href
)) as { buildPiArgs: (options: any) => { args: string[] } };

const configUrl = new URL("../extensions/subagent/config.json", import.meta.url);
const config = JSON.parse(readFileSync(configUrl, "utf8")) as {
	defaultChildExtensions: string[];
	requiredChildExtensions: string[];
};
const guard = "~/.pi/agent/extensions/dcg-guard.ts";

function extensionValues(args: string[]): string[] {
	const values: string[] = [];
	for (let index = 0; index < args.length - 1; index += 1) {
		if (args[index] === "--extension") values.push(args[index + 1]);
	}
	return values;
}

test("the canonical required extension reaches the real pi-subagents child argv", () => {
	assert.deepEqual(config.defaultChildExtensions, []);
	assert.deepEqual(config.requiredChildExtensions, [guard]);
	const result = buildPiArgs({
		baseArgs: [],
		extensions: config.defaultChildExtensions,
		inheritProjectContext: false,
		inheritSkills: true,
		sessionEnabled: false,
		subagentOnlyExtensions: config.requiredChildExtensions,
		task: "non-destructive argv probe",
	});

	assert.ok(result.args.includes("--no-extensions"));
	assert.ok(extensionValues(result.args).includes(guard));
	assert.equal(result.env.PI_SUBAGENT_CHILD, "1");
});

test("explicit child extensions retain DCG through subagentOnlyExtensions", () => {
	const result = buildPiArgs({
		baseArgs: [],
		extensions: ["/tmp/custom-extension.ts"],
		inheritProjectContext: false,
		inheritSkills: true,
		sessionEnabled: false,
		subagentOnlyExtensions: config.requiredChildExtensions,
		task: "non-destructive explicit-extension probe",
	});
	const extensions = extensionValues(result.args);

	assert.ok(extensions.includes("/tmp/custom-extension.ts"));
	assert.ok(extensions.includes(guard));
});
