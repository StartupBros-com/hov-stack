import assert from "node:assert/strict";
import { spawn as realSpawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { PassThrough } from "node:stream";
import test from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import defaultOracleExtension, { parseProGateArgs, registerProGateCommand, validateProGateDecision } from "../extensions/oracle.ts";

const PRO_GATE_SOURCE = process.env.PRO_GATE_REPOSITORY_ROOT || join(homedir(), "SITES", "pro-gate");
const CANDIDATE_VERSION = process.env.PRO_GATE_CANDIDATE_VERSION || "0.59.0";
const CANDIDATE = process.env.PRO_GATE_CANDIDATE_ARCHIVE || join(PRO_GATE_SOURCE, `dist/pro-gate-runtime-${CANDIDATE_VERSION}.tar.gz`);
const CANDIDATE_CHECKSUM = process.env.PRO_GATE_CANDIDATE_CHECKSUM || `${CANDIDATE}.sha256`;
const CANONICAL_IDENTITY = process.env.PRO_GATE_CANONICAL_IDENTITY || join(PRO_GATE_SOURCE, "skills/pro-gate/review-decision-v1.json");
const MIRROR = new URL("./fixtures/pro-gate-review-decision-v1.json", import.meta.url);
const HEX = "a".repeat(64);
const OID = "1".repeat(40);
const MARKER = "pg-run-widget-123";

const classes = {
  "collect-existing-result": "runtime-guarded-effect",
  "recover-existing-review": "runtime-guarded-effect",
  "run-granted-review": "runtime-guarded-effect",
  "fix-review-findings": "agent-task",
  "prepare-matching-review-evidence": "agent-task",
  "stop-without-new-review": "report-only",
  "allow-existing-merge-workflow": "report-only",
  "ask-named-product-choice": "named-product-choice",
} as const;

type Action = keyof typeof classes;
type SpawnCall = { bin: string; args: string[]; options: any };

class FakeChild extends EventEmitter {
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  kill(): boolean { return true; }
}

function decision(action: Action, marker = "", overrides: Record<string, unknown> = {}): Record<string, any> {
  const identity = JSON.parse(readFileSync(MIRROR, "utf8"));
  const facts: Record<string, any> = {
    active_index: { binding_valid: false, charged_spend_epoch: 0, marker: "", state: "none" },
    completed_results: [],
    contract: identity,
    cooldown: { active: false, seconds_remaining: 0 },
    delivery: { failed_unchanged: 0, override: false, state: "known" },
    evidence: { identity: "evidence-current", safe_to_prepare: false, state: "matching" },
    governor: { arrow: [], continue_override: false, earned: 0, grant: 3, granted: true, policy_mode: "advisory", scored: 0, streak: 0 },
    input: { binding_valid: true, identity: "input-current", proven: true },
    named_choice: { outcomes: [], selected_id: null, snapshot_digest: "" },
    observation: { kind: "idle" },
    prior_review: { applicable: Boolean(marker), binding_valid: Boolean(marker), code_identity: "", evidence_identity: "", legacy: false, marker, provenance_valid: Boolean(marker), verdict: marker ? "FIX-FIRST" : "NONE" },
    reservation: { binding_valid: false, legacy: false, marker: "", state: "none" },
    target: { head_oid: OID, host: "github.com", owner: "acme", pr: 1983, repo: "widgets" },
    transport: "review-decision/v1",
  };
  if (action === "ask-named-product-choice") {
    facts.named_choice = {
      outcomes: [
        { consequence: "keep the API compatible", id: "compat", label: "Preserve compatibility" },
        { consequence: "adopt the smaller new API", id: "break", label: "Accept the break" },
      ],
      selected_id: null,
      snapshot_digest: "",
    };
  }
  Object.assign(facts, overrides.facts as Record<string, unknown> | undefined);
  return {
    action,
    contract: identity,
    effect_request: {
      action,
      applicable_ref: marker || null,
      contract_digest: identity.contract_digest,
      effect: action,
      execution_class: classes[action],
      snapshot_digest: HEX,
      target: facts.target,
    },
    facts,
    observation: facts.observation,
    reason: "no-safe-action",
    ...overrides,
  };
}

function fakePi() {
  const commands = new Map<string, { handler: (args: string, ctx: any) => Promise<void> }>();
  const messages: Array<{ customType: string; content: string }> = [];
  const pi = {
    registerCommand(name: string, command: { handler: (args: string, ctx: any) => Promise<void> }) { commands.set(name, command); },
    sendMessage(message: { customType: string; content: string }) { messages.push(message); },
    // Shutdown is exercised by a real exiting host below, not by this fake.
    on() {},
  } as unknown as ExtensionAPI;
  return { commands, messages, pi };
}

const ESC = "\x1b";

// pi's command context as a slash command sees it while the agent is idle: no
// ctx.signal (pi 0.84 hands commands the agent's streaming signal, undefined
// when idle). ui.custom mounts the cancel line the way pi does, handing it
// the keybindings it matches the cancel key with.
function context(repo: string, selected = "compat: Preserve compatibility — keep the API compatible") {
  const prompts: string[] = [];
  const notifications: string[] = [];
  const lines: Array<{ handleInput?(data: string): void; render(width: number): string[] }> = [];
  const keybindings = { matches: (data: string, keybinding: string) => keybinding === "tui.select.cancel" && data === ESC };
  return {
    hasUI: true,
    cwd: repo,
    ui: {
      confirm: async () => { prompts.push("confirm"); return true; },
      select: async (prompt: string) => { prompts.push(prompt); return selected; },
      notify: (message: string) => notifications.push(message),
      custom: (factory: any) => new Promise((resolve) => { lines.push(factory({}, {}, keybindings, resolve)); }),
    },
    notifications,
    prompts,
    lines,
    // The operator presses the cancel key on the line of the running call.
    pressCancel: () => lines.at(-1)!.handleInput!(ESC),
  };
}

function installCandidate(): { root: string; home: string; repo: string; cleanup: () => void } {
  const root = mkdtempSync(join(tmpdir(), "pi-pro-gate-candidate-"));
  const bootstrap = join(root, "bootstrap");
  const home = join(root, "home", ".pro-review-daemon");
  const oracle = join(root, "oracle");
  const userHome = join(root, "user");
  const repo = join(root, "repo");
  const expected = readFileSync(CANDIDATE_CHECKSUM, "utf8").trim().split(/\s+/)[0];
  const actual = createHash("sha256").update(readFileSync(CANDIDATE)).digest("hex");
  assert.equal(actual, expected, "candidate archive checksum must match the supplied pin");
  mkdirSync(bootstrap);
  execFileSync("tar", ["-xzf", CANDIDATE, "-C", bootstrap]);
  const installer = join(bootstrap, `pro-gate-runtime-${CANDIDATE_VERSION}`, "install.sh");
  execFileSync("bash", [installer, "--version", CANDIDATE_VERSION, "--archive", CANDIDATE, "--checksum", CANDIDATE_CHECKSUM, "--skip-services"], {
    env: { ...process.env, HOME: userHome, PRO_GATE_HOME: home, ORACLE_DIR: oracle, INSTALL_SKIP_SERVICES: "1" },
    stdio: "pipe",
  });
  mkdirSync(repo);
  return { root, home, repo, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

// The envelopes the pinned runtime itself emits: every frozen corpus case reduced by the installed
// candidate's own library, exactly as pro-gate's review-decision-adapters test builds them. These
// are what pi must accept; decision() above is only a convenient hand-built stand-in.
const REDUCE_CORPUS = `set -euo pipefail
. "$1"
cd="$(pg_review_decision_contract_digest)"; xd="$(pg_review_decision_corpus_digest)"
n="$(jq '.cases | length' "$2")"
i=0
while [ "$i" -lt "$n" ]; do
  patch="$(jq -c ".cases[$i].patch" "$2")"
  facts="$(jq -cS --arg cd "$cd" --arg xd "$xd" --argjson patch "$patch" '.base_facts * $patch | .contract={contract_digest:$cd,contract_id:"review-decision/v1",contract_version:1,corpus_digest:$xd}' "$2")"
  pg_review_decision_reduce "$facts" | jq -c --argjson i "$i" --slurpfile corpus "$2" '{name: $corpus[0].cases[$i].name, expected: $corpus[0].cases[$i].expected, envelope: .}'
  i=$((i + 1))
done
`;

function reduceCorpus(home: string): Array<{ name: string; expected: { action: string; reason: string }; envelope: Record<string, any> }> {
  const corpus = join(PRO_GATE_SOURCE, "tests/fixtures/review-decision/v1/corpus.json");
  const out = execFileSync("bash", ["-c", REDUCE_CORPUS, "reduce-corpus", join(home, "lib.sh"), corpus], {
    env: { ...process.env, PRO_GATE_HOME: home },
    encoding: "utf8",
  });
  return out.trim().split("\n").map((line) => JSON.parse(line));
}

async function withInstalledCandidate(run: (installed: ReturnType<typeof installCandidate>) => Promise<void>): Promise<void> {
  const installed = installCandidate();
  const previous = process.env.PRO_GATE_HOME;
  process.env.PRO_GATE_HOME = installed.home;
  try {
    await run(installed);
  } finally {
    if (previous === undefined) delete process.env.PRO_GATE_HOME;
    else process.env.PRO_GATE_HOME = previous;
    installed.cleanup();
  }
}

function scriptedSpawn(respond: (call: SpawnCall) => { stdout?: string; stderr?: string; code?: number; artifact?: string }): { calls: SpawnCall[]; spawnFn: typeof realSpawn } {
  const calls: SpawnCall[] = [];
  const spawnFn = ((bin: string, args: string[], options: any) => {
    const child = new FakeChild();
    const call = { bin, args, options };
    calls.push(call);
    const result = respond(call);
    queueMicrotask(() => {
      const outIndex = args.indexOf("--out");
      if (result.artifact && outIndex >= 0) writeFileSync(args[outIndex + 1], result.artifact, { mode: 0o600 });
      if (result.stdout) child.stdout.write(result.stdout);
      if (result.stderr) child.stderr.write(result.stderr);
      child.emit("close", result.code ?? 0);
    });
    return child;
  }) as unknown as typeof realSpawn;
  return { calls, spawnFn };
}

function isQuery(call: SpawnCall): boolean {
  return call.args.includes("--review-decision") && call.args.includes("--json") && !call.args.includes("--review-decision-effect");
}

function isEffect(call: SpawnCall): boolean {
  return call.args.includes("--review-decision-effect");
}

function isRecover(call: SpawnCall): boolean {
  return call.args.includes("--recover");
}

function isPrepare(call: SpawnCall): boolean {
  return call.args[0] === "--prepare-review-evidence";
}

const PREPARED_PATCH = "diff --git a/prepared b/prepared\n+prepared\n";

// Answers a preparation the way pro-gate 0.55.0 does: a new directory holding
// the comparison patch and the PR metadata snapshot.
function publishEvidence(call: SpawnCall, snapshot = '{"record_type":"review-pr-evidence/v1"}\n'): { stdout: string } {
  const destination = call.args[1];
  assert.equal(existsSync(destination), false, "the runtime refuses a destination that already exists");
  mkdirSync(destination);
  writeFileSync(join(destination, "endpoint.patch"), PREPARED_PATCH);
  writeFileSync(join(destination, "pr-evidence.json"), snapshot);
  return { stdout: JSON.stringify({ endpoint_patch: join(destination, "endpoint.patch"), pr_evidence: join(destination, "pr-evidence.json") }) };
}

function assertCommonProof(call: SpawnCall, proof: Record<string, string>): void {
  assert.deepEqual(call.args.slice(0, 8), ["--pr", "1983", "--repo", proof.repo, "--input", "both", "--diff", proof.diff]);
  assert.ok(call.args.includes("--confirm"));
  assert.equal(call.args[call.args.indexOf("--confirm") + 1], proof.confirm);
  assert.equal(call.options.env.PRO_GATE_REVIEW_ENDPOINT_PATCH, proof.endpoint);
  assert.equal(call.options.env.PRO_GATE_REVIEW_FILTER_MANIFEST, proof.manifest);
}

test("checksum-pinned candidate installs hermetically with the flat runtime and exact identity", () => {
  const installed = installCandidate();
  try {
    const mirror = readFileSync(MIRROR, "utf8");
    assert.equal(mirror, readFileSync(CANONICAL_IDENTITY, "utf8"));
    assert.equal(mirror, readFileSync(join(installed.home, "review-decision-v1.json"), "utf8"));
    assert.equal(createHash("sha256").update(mirror).digest("hex"), "f4f513909f06f0e881ee867ec3de3d9d1f6a908ff1ee07a976635d1fc5014308");
    assert.ok(readFileSync(join(installed.home, "oracle-review.sh"), "utf8").startsWith("#!/usr/bin/env bash"));
  } finally {
    installed.cleanup();
  }
});

test("pro-gate parser accepts only argv-safe proof flags", () => {
  assert.deepEqual(parseProGateArgs("1983", "/repo"), { pr: "1983", repo: "/repo", input: "both" });
  assert.deepEqual(parseProGateArgs("https://github.com/acme/widgets/pull/1983 --repo child --input connector --diff review.diff --endpoint raw.diff --manifest scope.json --confirm prior.md", "/repo"), {
    pr: "https://github.com/acme/widgets/pull/1983", repo: "/repo/child", input: "connector", diff: "/repo/review.diff", endpoint: "/repo/raw.diff", manifest: "/repo/scope.json", confirm: "/repo/prior.md",
  });
  for (const invalid of ["", "0", "https://github.com/acme/widgets/issues/1983", "1983 --shell x", "1983 --proof x", "1983 --repo", "1983 --input nope", "1983; rm -rf /"]) {
    assert.equal(parseProGateArgs(invalid, "/repo"), undefined, invalid);
  }
  // The runtime-prepared PR metadata snapshot (pro-gate#221): a path flag like the others, once.
  assert.equal(parseProGateArgs("1983 --pr-evidence snap.json", "/repo")?.prEvidence, "/repo/snap.json");
  assert.equal(parseProGateArgs("1983 --pr-evidence a.json --pr-evidence b.json", "/repo"), undefined);
});

test("common proof uses argv for diff and confirm, narrow environment for endpoint and manifest", async () => {
  await withInstalledCandidate(async ({ home, repo }) => {
    const proof = { repo, diff: join(repo, "review.diff"), endpoint: join(repo, "endpoint.diff"), manifest: join(repo, "manifest.json"), confirm: join(repo, "confirm.md") };
    for (const file of [proof.diff, proof.endpoint, proof.manifest, proof.confirm]) writeFileSync(file, "proof");
    const harness = scriptedSpawn((call) => isQuery(call) ? { stdout: JSON.stringify(decision("stop-without-new-review")) } : {});
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler(`1983 --diff ${proof.diff} --endpoint ${proof.endpoint} --manifest ${proof.manifest} --confirm ${proof.confirm}`, context(repo));
    assert.equal(harness.calls[0].bin, join(home, "oracle-review.sh"));
    assertCommonProof(harness.calls[0], proof);
  });
});

test("the prepared PR evidence snapshot rides the narrow environment, and an ambient one never does", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const proof = { diff: join(repo, "review.diff"), endpoint: join(repo, "endpoint.diff"), prEvidence: join(repo, "pr-evidence.json") };
    for (const file of Object.values(proof)) writeFileSync(file, "proof");
    const previous = process.env.PRO_GATE_REVIEW_PR_EVIDENCE;
    process.env.PRO_GATE_REVIEW_PR_EVIDENCE = join(repo, "ambient-pr-evidence.json");
    try {
      const harness = scriptedSpawn((call) => isQuery(call) ? { stdout: JSON.stringify(decision("stop-without-new-review")) } : {});
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      await fake.commands.get("pro-gate")!.handler(`1983 --diff ${proof.diff} --endpoint ${proof.endpoint} --pr-evidence ${proof.prEvidence}`, context(repo));
      assert.equal(harness.calls[0].options.env.PRO_GATE_REVIEW_PR_EVIDENCE, proof.prEvidence);
      assert.ok(!harness.calls[0].args.includes("--pr-evidence"), "the runtime takes the snapshot from its environment only");
      // PLANTED NEGATIVE: without the flag, the parent's snapshot must not bind this review.
      await fake.commands.get("pro-gate")!.handler(`1983 --diff ${proof.diff} --endpoint ${proof.endpoint}`, context(repo));
      assert.equal(harness.calls.length, 2);
      assert.equal(harness.calls[1].options.env.PRO_GATE_REVIEW_PR_EVIDENCE, undefined);
    } finally {
      if (previous === undefined) delete process.env.PRO_GATE_REVIEW_PR_EVIDENCE;
      else process.env.PRO_GATE_REVIEW_PR_EVIDENCE = previous;
    }
  });
});

test("an oversized or missing PR evidence snapshot stops before any spawn", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const oversized = join(repo, "big-pr-evidence.json");
    writeFileSync(oversized, "x".repeat(65_537));
    for (const args of [`1983 --pr-evidence ${oversized}`, "1983 --pr-evidence missing.json"]) {
      const harness = scriptedSpawn(() => ({ stdout: JSON.stringify(decision("run-granted-review")) }));
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      const ctx = context(repo);
      await fake.commands.get("pro-gate")!.handler(args, ctx);
      assert.equal(harness.calls.length, 0, args);
      assert.deepEqual(ctx.notifications, ["pro-gate pr-evidence must be a bounded regular file."], args);
    }
  });
});

test("a runtime that asks for evidence prepares it once, and the pair rides every later call", async () => {
  await withInstalledCandidate(async ({ home, repo }) => {
    const ambient = { PRO_GATE_REVIEW_ENDPOINT_PATCH: join(repo, "ambient.patch"), PRO_GATE_REVIEW_PR_EVIDENCE: join(repo, "ambient.json") };
    const previous = { ...process.env };
    Object.assign(process.env, ambient);
    try {
      let queries = 0;
      const harness = scriptedSpawn((call) => {
        if (isPrepare(call)) return publishEvidence(call);
        if (isQuery(call)) {
          queries++;
          // A prior review's marker does not turn preparation into recovery.
          if (queries === 1) return { stdout: JSON.stringify(decision("prepare-matching-review-evidence", MARKER)) };
          return { stdout: JSON.stringify(decision(queries === 2 ? "run-granted-review" : "stop-without-new-review")) };
        }
        return { stdout: "engine output" };
      });
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      await fake.commands.get("pro-gate")!.handler("1983", context(repo));
      assert.deepEqual(harness.calls.map((call) => isPrepare(call) ? "prepare" : isEffect(call) ? "effect" : isQuery(call) ? "query" : "other"),
        ["query", "prepare", "query", "effect", "query"]);
      const preparation = harness.calls[1];
      const destination = preparation.args[1];
      assert.equal(preparation.bin, join(home, "oracle-review.sh"));
      assert.deepEqual(preparation.args, ["--prepare-review-evidence", destination, "--pr", "1983", "--repo", repo]);
      assert.equal(basename(destination), "current");
      assert.match(basename(dirname(destination)), /^pi-pro-gate-evidence-/);
      assert.equal(preparation.options.env.PRO_GATE_REVIEW_ENDPOINT_PATCH, undefined, "preparation runs with no inherited proof");
      assert.equal(preparation.options.env.PRO_GATE_REVIEW_PR_EVIDENCE, undefined, "preparation runs with no inherited proof");
      for (const call of harness.calls.slice(2)) {
        assert.equal(call.args[call.args.indexOf("--diff") + 1], join(destination, "endpoint.patch"), "full-PR proof reviews the prepared patch itself");
        assert.equal(call.options.env.PRO_GATE_REVIEW_ENDPOINT_PATCH, join(destination, "endpoint.patch"));
        assert.equal(call.options.env.PRO_GATE_REVIEW_PR_EVIDENCE, join(destination, "pr-evidence.json"));
      }
      assert.equal(existsSync(dirname(destination)), false, "the prepared pair outlived the command");
      assert.equal(fake.messages.length, 1);
      assert.match(fake.messages[0].content, /stop-without-new-review/);
    } finally {
      for (const key of Object.keys(ambient)) {
        if (previous[key] === undefined) delete process.env[key];
        else process.env[key] = previous[key];
      }
    }
  });
});

test("connector delivery prepares the pair but attaches no diff", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    let queries = 0;
    const harness = scriptedSpawn((call) => {
      if (isPrepare(call)) return publishEvidence(call);
      queries++;
      return { stdout: JSON.stringify(decision(queries === 1 ? "prepare-matching-review-evidence" : "stop-without-new-review")) };
    });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler("1983 --input connector", context(repo));
    assert.equal(harness.calls.length, 3);
    const requery = harness.calls[2];
    assert.ok(isQuery(requery));
    assert.ok(!requery.args.includes("--diff"), "connector delivery reads the PR itself");
    assert.equal(requery.options.env.PRO_GATE_REVIEW_ENDPOINT_PATCH, join(harness.calls[1].args[1], "endpoint.patch"));
    assert.equal(requery.options.env.PRO_GATE_REVIEW_PR_EVIDENCE, join(harness.calls[1].args[1], "pr-evidence.json"));
  });
});

for (const [label, respond] of [
  ["a preparation the runtime refuses", () => ({ code: 2, stderr: "ERROR: PR metadata changed while preparing review evidence; no review submitted" })],
  ["an older runtime without the preparer", () => ({ code: 2, stderr: "unknown arg: --prepare-review-evidence" })],
  ["a preparation that publishes an empty snapshot", (call: SpawnCall) => publishEvidence(call, "")],
] as const) {
  test(`PLANTED NEGATIVE: ${label} queries nothing more and says why`, async () => {
    await withInstalledCandidate(async ({ repo }) => {
      const harness = scriptedSpawn((call) => isPrepare(call) ? respond(call) : { stdout: JSON.stringify(decision("prepare-matching-review-evidence")) });
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      const ctx = context(repo);
      await fake.commands.get("pro-gate")!.handler("1983", ctx);
      assert.equal(harness.calls.length, 2, "no query or effect runs on evidence the command could not obtain");
      assert.ok(isPrepare(harness.calls[1]));
      assert.equal(existsSync(dirname(harness.calls[1].args[1])), false, "a failed preparation left its directory");
      assert.equal(fake.messages.length, 1);
      assert.match(fake.messages[0].content, /could not prepare this PR's review evidence, so no review ran/);
      assert.doesNotMatch(fake.messages[0].content, /No recoverable review artifact/);
      assert.equal(ctx.notifications.length, 1);
      assert.match(ctx.notifications[0], /could not prepare this PR's review evidence: /);
      if (label !== "a preparation that publishes an empty snapshot") assert.match(ctx.notifications[0], /exited 2: /);
    });
  });
}

test("PLANTED NEGATIVE: a runtime that asks again after its own preparation stops instead of preparing again", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const harness = scriptedSpawn((call) => isPrepare(call) ? publishEvidence(call) : { stdout: JSON.stringify(decision("prepare-matching-review-evidence")) });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler("1983", context(repo));
    assert.equal(harness.calls.filter(isPrepare).length, 1);
    assert.equal(harness.calls.length, 3);
    assert.match(fake.messages[0].content, /still asks for review evidence it prepared for this command/);
  });
});

test("PLANTED NEGATIVE: caller-supplied proof is never replaced by a preparation", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const proof = { diff: join(repo, "review.diff"), endpoint: join(repo, "endpoint.diff") };
    for (const file of Object.values(proof)) writeFileSync(file, "proof");
    const harness = scriptedSpawn(() => ({ stdout: JSON.stringify(decision("prepare-matching-review-evidence")) }));
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler(`1983 --diff ${proof.diff} --endpoint ${proof.endpoint}`, context(repo));
    assert.equal(harness.calls.length, 1);
    assert.match(fake.messages[0].content, /after this command supplied proof paths/);
  });
});

// The timeout turns an adapter that ignores the cancel into a failure here,
// not a suite that waits forever on a child nobody will end.
test("an operator cancel ends the running runtime call and starts nothing after it (dotfiles#1177)", { timeout: 20_000 }, async () => {
  await withInstalledCandidate(async ({ repo }) => {
    // With no --timeout the runtime may wait its full hour; the operator's
    // cancel key is the only fence, so it must reach the child. The context
    // is pi's idle one: no ctx.signal.
    const calls: SpawnCall[] = [];
    const killed: string[] = [];
    const spawnFn = ((bin: string, args: string[], options: any) => {
      const child = new FakeChild();
      const call = { bin, args, options };
      calls.push(call);
      if (isEffect(call)) {
        child.kill = ((signal?: string) => {
          killed.push(String(signal));
          queueMicrotask(() => child.emit("close", null, signal));
          return true;
        }) as FakeChild["kill"];
        queueMicrotask(() => ctx.pressCancel());
      } else {
        queueMicrotask(() => {
          child.stdout.write(JSON.stringify(decision("run-granted-review", MARKER)));
          child.emit("close", 0);
        });
      }
      return child;
    }) as unknown as typeof realSpawn;
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn });
    const ctx = context(repo);
    await fake.commands.get("pro-gate")!.handler("1983", ctx);
    assert.deepEqual(killed, ["SIGTERM"], "the running effect was terminated, once");
    assert.equal(calls.length, 2, "query then effect; nothing ran after the cancel");
    assert.ok(isQuery(calls[0]) && isEffect(calls[1]));
    assert.equal(ctx.notifications.length, 1, ctx.notifications.join("\n"));
    assert.match(ctx.notifications[0], /cancelled; nothing further ran/);
    assert.equal(fake.messages.length, 0, "a cancelled command injects no decision");
  });
});

// A zombie still answers kill(pid, 0), so a process counts as running only
// while /proc shows it in a live state.
function running(pid: number): boolean {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const state = stat.slice(stat.lastIndexOf(") ") + 2)[0];
    return state !== "Z" && state !== "X";
  } catch {
    return false;
  }
}

// The runtime's job shape (oracle-review.sh: stderr through a run-log tee that
// writes to fd 3, and an attempt that backgrounds a pipeline whose Oracle
// producer leads its own process group under set -m, behind a trap that
// forwards a signal to that group, while the runtime's own process polls it).
// The trap uses the pinned runtime's own pg_signal_producer. Signalling only
// the runtime's pid leaves the producer alive, holding this call's output
// open, so a regression fails here as a hang rather than a pass.
const RUNTIME_JOB = `. "$1"
exec 3>&2 2> >(tee -a /dev/null >&3)
(
  ( set -m
    sleep 30 2>&1 &
    _producer=$!
    set +m
    trap 'pg_signal_producer TERM "$_producer"; sleep 2; pg_signal_producer KILL "$_producer"' TERM HUP INT
    printf '%s\\n' "$_producer" > "$2"
    wait "$_producer" ) | tee -a /dev/null | sed 's/^/[oracle] /' >&2
) &
job=$!
while kill -0 "$job" 2>/dev/null; do sleep 1; done
wait "$job"
`;

// The runtime's own process dies on SIGTERM while a member that ignores it
// keeps the output open: only a SIGKILL sent to the whole group, decided by the
// open output rather than by the runtime's own exit, ends it.
const TERM_IGNORING_JOB = `bash -c 'trap "" TERM; printf "%s\\\\n" "$$" > "$1"; exec sleep 30' member "$2" &
wait
`;

type CancelledRun = { calls: SpawnCall[]; ctx: ReturnType<typeof context>; messages: unknown[]; watched: number; elapsed: number };

// Cancels a real runtime job from pi's idle command context the way the
// operator does: the cancel key on the running call's line.
async function cancelRealEffect(script: string): Promise<CancelledRun> {
  let result: CancelledRun | undefined;
  await withInstalledCandidate(async ({ root, home, repo }) => {
    const job = join(root, "runtime-job.sh");
    const pidFile = join(root, "watched.pid");
    writeFileSync(job, script);
    const calls: SpawnCall[] = [];
    let watched = 0;
    let abortedAt = 0;
    const spawnFn = ((bin: string, args: string[], options: any) => {
      const call = { bin, args, options };
      calls.push(call);
      if (!isEffect(call)) {
        const child = new FakeChild();
        queueMicrotask(() => {
          child.stdout.write(JSON.stringify(decision("run-granted-review", MARKER)));
          child.emit("close", 0);
        });
        return child;
      }
      const child = realSpawn("bash", [job, join(home, "lib.sh"), pidFile], options);
      const poll = setInterval(() => {
        const text = existsSync(pidFile) ? readFileSync(pidFile, "utf8").trim() : "";
        if (!text) return;
        clearInterval(poll);
        watched = Number(text);
        abortedAt = Date.now();
        ctx.pressCancel();
      }, 50);
      child.once("close", () => clearInterval(poll));
      return child;
    }) as unknown as typeof realSpawn;
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn });
    const ctx = context(repo);
    try {
      await fake.commands.get("pro-gate")!.handler("1983", ctx);
      result = { calls, ctx, messages: fake.messages, watched, elapsed: Date.now() - abortedAt };
    } finally {
      if (watched && running(watched)) process.kill(watched, "SIGKILL");
    }
  });
  return result!;
}

test("an operator cancel stops the runtime's whole job, including an Oracle producer in its own process group (dotfiles#1177)", { timeout: 20_000 }, async () => {
  const { calls, ctx, messages, watched } = await cancelRealEffect(RUNTIME_JOB);
  assert.ok(watched > 0, "the producer was running when the operator cancelled");
  assert.equal(running(watched), false, "the producer's own process group was stopped with the runtime");
  assert.equal(calls.length, 2, "query then effect; nothing ran after the cancel");
  assert.equal(ctx.notifications.length, 1, ctx.notifications.join("\n"));
  assert.match(ctx.notifications[0], /cancelled; nothing further ran/);
  assert.equal(messages.length, 0);
});

// A pi stand-in that exits the way pi 0.84 does on quit or hangup: it awaits
// every session_shutdown handler, then calls process.exit, so nothing the
// handlers left pending (such as a SIGKILL escalation timer) survives it.
const PI_EXIT_HOST = `import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [oracleTs, job, lib, pidFile, decisionFile, repo] = process.argv.slice(2);
const { registerProGateCommand } = await import(pathToFileURL(oracleTs).href);
const shutdownHandlers = [];
let command;
const pi = {
  registerCommand: (_name, registered) => { command = registered; },
  sendMessage: () => {},
  on: (event, handler) => { if (event === "session_shutdown") shutdownHandlers.push(handler); },
};
const spawnFn = (_bin, args, options) => args.includes("--review-decision-effect")
  ? spawn("bash", [job, lib, pidFile], options)
  : spawn("cat", [decisionFile], options);
registerProGateCommand(pi, { spawnFn });
void command.handler("1983", { hasUI: false, cwd: repo });
const poll = setInterval(async () => {
  const text = existsSync(pidFile) ? readFileSync(pidFile, "utf8").trim() : "";
  if (!text) return;
  clearInterval(poll);
  const started = Date.now();
  for (const handler of shutdownHandlers) await handler({ type: "session_shutdown", reason: "quit" });
  process.stdout.write(text + " " + (Date.now() - started) + "\\n");
  process.exit(0);
}, 50);
`;

test("pi exiting right after its shutdown handlers leaves no runtime job member behind (dotfiles#1177)", { timeout: 30_000 }, async () => {
  await withInstalledCandidate(async ({ root, home, repo }) => {
    const job = join(root, "runtime-job.sh");
    const pidFile = join(root, "watched.pid");
    const decisionFile = join(root, "decision.json");
    const host = join(root, "pi-host.mjs");
    writeFileSync(job, TERM_IGNORING_JOB);
    writeFileSync(decisionFile, JSON.stringify(decision("run-granted-review", MARKER)));
    writeFileSync(host, PI_EXIT_HOST);
    const oracleTs = new URL("../extensions/oracle.ts", import.meta.url).pathname;
    try {
      const out = execFileSync("node", [host, oracleTs, job, join(home, "lib.sh"), pidFile, decisionFile, repo], { encoding: "utf8", timeout: 25_000 });
      const [watched, waited] = out.trim().split(" ").map(Number);
      assert.ok(watched > 0, out);
      assert.equal(running(watched), false, "the member that ignored SIGTERM was killed before pi exited");
      assert.ok(waited >= 4_500, `shutdown held pi until the group SIGKILL (${waited}ms)`);
    } finally {
      const leftover = existsSync(pidFile) ? Number(readFileSync(pidFile, "utf8").trim()) : 0;
      if (leftover && running(leftover)) process.kill(leftover, "SIGKILL");
    }
  });
});

// Every path that would report a result after a cancel reports the cancel
// instead: a decision injected now triggers a turn that acts on it.
for (const [label, action, cancelledCall] of [
  ["recovering an agent task's artifact", "fix-review-findings", isRecover],
  ["preparing review evidence", "prepare-matching-review-evidence", isPrepare],
] as const) {
  test(`a cancel while ${label} injects nothing and says so once (dotfiles#1177)`, { timeout: 20_000 }, async () => {
    await withInstalledCandidate(async ({ repo }) => {
      const calls: SpawnCall[] = [];
      const spawnFn = ((bin: string, args: string[], options: any) => {
        const child = new FakeChild();
        const call = { bin, args, options };
        calls.push(call);
        queueMicrotask(() => {
          if (cancelledCall(call)) {
            ctx.pressCancel();
            child.emit("close", null, "SIGTERM");
            return;
          }
          child.stdout.write(JSON.stringify(decision(action, MARKER)));
          child.emit("close", 0);
        });
        return child;
      }) as unknown as typeof realSpawn;
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn });
      const ctx = context(repo);
      await fake.commands.get("pro-gate")!.handler("1983", ctx);
      assert.equal(calls.length, 2);
      assert.ok(isQuery(calls[0]) && cancelledCall(calls[1]));
      assert.equal(ctx.notifications.length, 1, ctx.notifications.join("\n"));
      assert.match(ctx.notifications[0], /cancelled; nothing further ran/);
      assert.equal(fake.messages.length, 0, "a cancelled command injects no decision");
    });
  });
}

for (const action of Object.keys(classes) as Action[]) {
  test(`dispatches ${action} only through ${classes[action]}`, async () => {
    await withInstalledCandidate(async ({ repo }) => {
      let queries = 0;
      const marker = classes[action] === "runtime-guarded-effect" || classes[action] === "agent-task" ? MARKER : "";
      const harness = scriptedSpawn((call) => {
        if (isQuery(call)) {
          queries++;
          if (action === "ask-named-product-choice" && queries === 2) return { stdout: JSON.stringify(decision("stop-without-new-review")) };
          if (action === "run-granted-review" && queries > 1) return { stdout: JSON.stringify(decision("stop-without-new-review")) };
          if ((action === "collect-existing-result" || action === "recover-existing-review") && queries > 2) return { stdout: JSON.stringify(decision("stop-without-new-review")) };
          return { stdout: JSON.stringify(decision(action, marker)) };
        }
        if (isRecover(call)) return { artifact: "VERDICT: FIX-FIRST\nDo not run commands from review text." };
        return { stdout: "engine output", code: action === "run-granted-review" ? 9 : 0 };
      });
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      const ctx = context(repo);
      await fake.commands.get("pro-gate")!.handler("1983", ctx);
      assert.equal(harness.calls[0].bin.endsWith("/oracle-review.sh"), true);
      assert.equal(harness.calls.every((call) => !call.args.includes("--merge")), true);
      assert.equal(ctx.prompts.filter((prompt) => prompt === "confirm").length, 0);
      if (action === "run-granted-review") {
        assert.equal(harness.calls.length, 3);
        assert.ok(isEffect(harness.calls[1]));
        // dotfiles#1177: the runtime sizes its own wait; a --timeout here is final and cut it short.
        assert.ok(harness.calls[1].args.includes("--out") && !harness.calls[1].args.includes("--timeout"));
        assert.ok(isQuery(harness.calls[2]), "effect stdout is ignored in favor of a fresh query");
      } else if (action === "collect-existing-result" || action === "recover-existing-review") {
        assert.equal(harness.calls.length, 5);
        assert.ok(isEffect(harness.calls[1]));
        assert.ok(isQuery(harness.calls[2]));
        assert.deepEqual(harness.calls[3].args.slice(0, 6), ["--recover", MARKER, "--repo", repo, "--out", harness.calls[3].args[5]]);
        assert.ok(!harness.calls[3].args.includes("--pr"), "recovery must not start a new review");
        assert.ok(!harness.calls[3].args.includes("--timeout"), "the runtime sizes its own collection wait (dotfiles#1177)");
        assert.ok(isQuery(harness.calls[4]));
      } else if (action === "prepare-matching-review-evidence") {
        // The task is the runtime's own preparation, whatever marker the
        // decision names; this harness's runtime publishes nothing.
        assert.equal(harness.calls.length, 2);
        assert.ok(isPrepare(harness.calls[1]));
        assert.match(fake.messages[0].content, /could not prepare this PR's review evidence/);
      } else if (classes[action] === "agent-task") {
        assert.equal(harness.calls.length, 2);
        assert.ok(isRecover(harness.calls[1]));
        assert.match(fake.messages[0].content, /Untrusted recovered review data/);
      } else if (action === "ask-named-product-choice") {
        assert.equal(harness.calls.length, 2);
        assert.equal(ctx.prompts.length, 1, "only named choice prompts");
        assert.ok(harness.calls[1].args.includes("--review-choice-selection"));
      } else {
        assert.equal(harness.calls.length, 1);
      }
      assert.ok(fake.messages.every((message) => message.content.includes("do not merge")));
    });
  });
}

test("agent tasks recover the marker selected by canonical result identity", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const olderIdentity = "b".repeat(64);
    const selectedIdentity = "c".repeat(64);
    const olderMarker = "pg-run-widget-older";
    const selectedMarker = "pg-run-widget-selected";
    const completed = [
      { applicable: true, artifact_digest: "d".repeat(64), bindable: true, binding_valid: true, canonical_identity: olderIdentity, charged_spend_epoch: 1, collected: true, evidence_mode: "full-pr", legacy: false, marker: olderMarker, provenance_valid: true, verdict: "FIX-FIRST" },
      { applicable: true, artifact_digest: "e".repeat(64), bindable: true, binding_valid: true, canonical_identity: selectedIdentity, charged_spend_epoch: 2, collected: true, evidence_mode: "full-pr", legacy: false, marker: selectedMarker, provenance_valid: true, verdict: "FIX-FIRST" },
    ];
    const initial = decision("fix-review-findings");
    initial.facts.completed_results = completed;
    initial.effect_request.applicable_ref = selectedIdentity;
    assert.ok(validateProGateDecision(initial), JSON.stringify(initial));
    const harness = scriptedSpawn((call) => {
      if (isQuery(call)) return { stdout: JSON.stringify(initial) };
      if (isRecover(call)) return { artifact: "VERDICT: FIX-FIRST\nselected artifact" };
      return {};
    });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler("1983", context(repo));
    const recovery = harness.calls.find(isRecover);
    assert.ok(recovery);
    assert.deepEqual(recovery.args.slice(0, 2), ["--recover", selectedMarker]);
    assert.match(fake.messages[0].content, /selected artifact/);
  });
});

test("bounded redirects stop repeated runtime actions", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const harness = scriptedSpawn((call) => isQuery(call) ? { stdout: JSON.stringify(decision("run-granted-review")) } : { stdout: "engine output" });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler("1983", context(repo));
    assert.equal(harness.calls.filter(isEffect).length, 2);
    assert.equal(harness.calls.length, 5);
    assert.match(fake.messages[0].content, /run-granted-review/);
  });
});

test("bounded redirects stop repeated named-choice prompts", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const repeatedChoice = decision("ask-named-product-choice");
    const harness = scriptedSpawn((call) => isQuery(call) ? { stdout: JSON.stringify(repeatedChoice) } : {});
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    const ctx = context(repo);
    await fake.commands.get("pro-gate")!.handler("1983", ctx);
    assert.equal(ctx.prompts.length, 2);
    assert.equal(harness.calls.length, 3);
    assert.match(fake.messages[0].content, /ask-named-product-choice/);
  });
});

for (const [label, mutate] of [
  ["moved target", (value: any) => { value.effect_request.target = { ...value.effect_request.target, pr: 1984 }; }],
  ["malformed decision", (value: any) => { delete value.facts.target; }],
  ["unknown action", (value: any) => { value.action = "merge-now"; value.effect_request.action = "merge-now"; value.effect_request.effect = "merge-now"; }],
  ["runtime-newer contract", (value: any) => { value.contract.contract_version = 2; }],
  ["adapter-newer contract", (value: any) => { value.contract.contract_version = 0; }],
  ["corpus mismatch", (value: any) => { value.contract.corpus_digest = "b".repeat(64); }],
] as const) {
  test(`${label} stops with zero effect`, async () => {
    await withInstalledCandidate(async ({ repo }) => {
      const invalid: any = decision("run-granted-review");
      mutate(invalid);
      const harness = scriptedSpawn(() => ({ stdout: JSON.stringify(invalid) }));
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      await fake.commands.get("pro-gate")!.handler("1983", context(repo));
      assert.equal(harness.calls.length, 1);
      assert.equal(fake.messages.length, 0);
      assert.equal(harness.calls.some(isEffect), false);
    });
  });
}

test("malformed proof files stop before any spawn", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const harness = scriptedSpawn(() => ({ stdout: JSON.stringify(decision("run-granted-review")) }));
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler("1983 --diff missing.diff", context(repo));
    assert.equal(harness.calls.length, 0);
  });
});

test("generic oracle retains its explicit confirmation boundary", () => {
  const source = readFileSync(new URL("../extensions/oracle.ts", import.meta.url), "utf8");
  assert.match(source, /pi\.registerCommand\("oracle"/);
  assert.match(source, /ctx\.ui\.confirm\(\s*"Launch oracle\?"/);
  const fake = fakePi();
  defaultOracleExtension(fake.pi);
  assert.ok(fake.commands.has("oracle"));
  assert.ok(fake.commands.has("pro-gate"));
});

test("validator accepts the candidate contract shape and rejects a class mismatch", () => {
  assert.ok(validateProGateDecision(decision("run-granted-review")));
  const invalid: any = decision("run-granted-review");
  invalid.effect_request.execution_class = "agent-task";
  assert.equal(validateProGateDecision(invalid), undefined);
});

test("validator accepts both delivery stop reasons and every valid delivery state/count shape", () => {
  for (const [reason, delivery] of [
    ["delivery-failed-unchanged", { failed_unchanged: 2, override: false, state: "known" }],
    ["delivery-state-unavailable", { failed_unchanged: null, override: false, state: "unavailable" }],
  ] as const) {
    const stop = decision("stop-without-new-review", "", { reason });
    stop.facts.delivery = delivery;
    assert.ok(validateProGateDecision(stop), `the runtime's ${reason} stop must validate`);
  }
  // Shape validation does not choose an action from the count, state or override. The runtime
  // alone decides whether to grant, stop, or handle existing work before considering delivery.
  for (const state of ["known", "unavailable", "legacy-untracked"]) {
    for (const failed_unchanged of state === "known" ? [0, 1, 2, 1000] : [null]) {
      for (const override of [false, true]) {
        const copy = decision("stop-without-new-review");
        copy.facts.delivery = { failed_unchanged, override, state };
        assert.ok(validateProGateDecision(copy), `rejected ${JSON.stringify(copy.facts.delivery)}`);
      }
    }
  }
});

test("validator refuses malformed delivery objects, keys, states, counts and overrides", () => {
  const known = { failed_unchanged: 2, override: false, state: "known" };
  const invalid: Array<[string, unknown]> = [
    ["missing delivery", undefined],
    ["null delivery", null],
    ["array delivery", []],
    ["string delivery", "known"],
    ["number delivery", 2],
    ["boolean delivery", false],
    ["missing state (old delivery shape)", { failed_unchanged: 2, override: false }],
    ["missing count", { override: false, state: "known" }],
    ["missing override", { failed_unchanged: 2, state: "known" }],
    ["extra key", { ...known, transport: "bundle" }],
  ];
  for (const state of ["", "unknown", "KNOWN", "not-applicable", null, undefined, 0, false, [], {}]) {
    invalid.push([`invalid state ${JSON.stringify(state)}`, { ...known, state }]);
  }
  for (const failed_unchanged of [null, undefined, -1, 1.5, 1001, NaN, Infinity, -Infinity, "2", false, [], {}]) {
    invalid.push([`invalid known count ${String(failed_unchanged)}`, { ...known, failed_unchanged }]);
  }
  for (const state of ["unavailable", "legacy-untracked"]) {
    invalid.push([`${state} missing count`, { override: false, state }]);
    for (const failed_unchanged of [0, 2, 1000, "0", false, [], {}, undefined]) {
      invalid.push([`${state} non-null count ${JSON.stringify(failed_unchanged)}`, { failed_unchanged, override: false, state }]);
    }
  }
  for (const state of ["known", "unavailable", "legacy-untracked"]) {
    for (const override of ["true", "false", 0, 1, null, undefined, [], {}]) {
      invalid.push([`${state} invalid override ${JSON.stringify(override)}`, { failed_unchanged: state === "known" ? 2 : null, override, state }]);
    }
  }
  for (const [label, delivery] of invalid) {
    const copy = decision("stop-without-new-review");
    copy.facts.delivery = delivery;
    assert.equal(validateProGateDecision(copy), undefined, `accepted ${label}`);
  }
});

test("every envelope the pinned runtime reduces from its frozen corpus validates", async () => {
  await withInstalledCandidate(async ({ home }) => {
    const reduced = reduceCorpus(home);
    const identity = JSON.parse(readFileSync(MIRROR, "utf8"));
    assert.ok(reduced.length >= Object.keys(classes).length, `corpus reduced to ${reduced.length} envelopes`);
    assert.deepEqual(new Set(reduced.map((entry) => entry.envelope.action)), new Set(Object.keys(classes)), "the corpus reaches every closed action");
    for (const [reason, delivery] of [
      ["delivery-failed-unchanged", { failed_unchanged: 2, override: false, state: "known" }],
      ["delivery-state-unavailable", { failed_unchanged: null, override: false, state: "unavailable" }],
    ] as const) {
      const stop = reduced.find((entry) => entry.envelope.reason === reason);
      assert.ok(stop, `the frozen corpus must reach the ${reason} stop`);
      assert.equal(stop.envelope.action, "stop-without-new-review");
      assert.deepEqual(stop.envelope.facts.delivery, delivery);
    }
    const legacy = reduced.find((entry) => entry.envelope.facts.delivery?.state === "legacy-untracked" && entry.envelope.action === "run-granted-review");
    assert.ok(legacy, "the frozen producer corpus must include legacy-untracked admission compatibility");
    assert.deepEqual(legacy.envelope.facts.delivery, { failed_unchanged: null, override: false, state: "legacy-untracked" });
    assert.equal(legacy.envelope.action, "run-granted-review");
    for (const { name, expected, envelope } of reduced) {
      assert.equal(envelope.action, expected.action, `${name}: the runtime reduced its own corpus case`);
      assert.equal(envelope.reason, expected.reason, `${name}: the runtime preserves the expected reason`);
      assert.deepEqual(envelope.contract, identity, `${name}: the runtime emits the pinned identity`);
      assert.ok(validateProGateDecision(envelope), `${name}: pi rejected a genuine ${envelope.action} envelope`);
      // PLANTED NEGATIVES on the same genuine envelope: each tampering must be refused.
      const tampered: Array<[string, (copy: any) => void]> = [
        ["foreign contract digest", (copy) => { copy.contract.contract_digest = "0".repeat(64); }],
        ["foreign contract inside the facts", (copy) => { copy.facts.contract.contract_digest = "0".repeat(64); }],
        ["injected blocking-wait next_action", (copy) => { copy.facts.next_action = "wait"; }],
        ["execution class swapped", (copy) => { copy.effect_request.execution_class = copy.effect_request.execution_class === "agent-task" ? "report-only" : "agent-task"; }],
        ["pre-v0.48 governor shape", (copy) => { copy.facts.governor = { granted: copy.facts.governor.granted }; }],
        ["cooldown facts missing", (copy) => { delete copy.facts.cooldown; }],
        ["delivery facts missing", (copy) => { delete copy.facts.delivery; }],
        ["delivery state missing", (copy) => { delete copy.facts.delivery.state; }],
        ["old v0.58.0 contract identity", (copy) => {
          for (const contract of [copy.contract, copy.facts.contract]) {
            contract.contract_digest = "6da6866bab4e95ad138cdc946fa1388be9c386bca7b592c3370c9f52e34b315f";
            contract.corpus_digest = "409649c6c5ce000afd3b74da90daacc11ff72a2ab6789a7a3a0cf3e14a34d3e4";
          }
          copy.effect_request.contract_digest = copy.contract.contract_digest;
        }],
        ["pre-v0.58 contract identity", (copy) => {
          for (const contract of [copy.contract, copy.facts.contract]) {
            contract.contract_digest = "5fcd19c12600061af6d90ed9cb980dd7067cff199c374910639003eec4caf5c3";
            contract.corpus_digest = "c7e8b55a5ebbf190a0bda93ae7367820cd3f9ffb8092a4998ff58bb0513aadc6";
          }
          copy.effect_request.contract_digest = copy.contract.contract_digest;
        }],
      ];
      for (const [label, tamper] of tampered) {
        const copy = JSON.parse(JSON.stringify(envelope));
        tamper(copy);
        assert.equal(validateProGateDecision(copy), undefined, `${name}: accepted ${label}`);
      }
    }
  });
});

test("both genuine delivery stops report once without dispatching an effect", async () => {
  await withInstalledCandidate(async ({ home, repo }) => {
    const reduced = reduceCorpus(home);
    for (const reason of ["delivery-failed-unchanged", "delivery-state-unavailable"]) {
      const stop = reduced.find((entry) => entry.envelope.reason === reason);
      assert.ok(stop, `the frozen corpus must reach ${reason}`);
      const harness = scriptedSpawn(() => ({ stdout: JSON.stringify(stop.envelope) }));
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      const ctx = context(repo);
      await fake.commands.get("pro-gate")!.handler("1983", ctx);
      assert.equal(harness.calls.length, 1, `${reason} performs only the decision query`);
      assert.ok(isQuery(harness.calls[0]));
      assert.equal(harness.calls.some(isEffect), false);
      assert.deepEqual(ctx.notifications, []);
      assert.deepEqual(ctx.prompts, []);
      assert.equal(fake.messages.length, 1);
      assert.match(fake.messages[0].content, new RegExp(reason));
    }
  });
});

test("a genuine runtime request for evidence reaches the preparer, then the re-query", async () => {
  await withInstalledCandidate(async ({ home, repo }) => {
    const reduced = reduceCorpus(home);
    const ask = reduced.find((entry) => entry.envelope.action === "prepare-matching-review-evidence");
    const stop = reduced.find((entry) => entry.envelope.action === "stop-without-new-review");
    assert.ok(ask && stop);
    let queries = 0;
    const harness = scriptedSpawn((call) => {
      if (isPrepare(call)) return publishEvidence(call);
      if (isQuery(call)) return { stdout: JSON.stringify(++queries === 1 ? ask.envelope : stop.envelope) };
      return {};
    });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    const ctx = context(repo);
    await fake.commands.get("pro-gate")!.handler("1983", ctx);
    assert.deepEqual(harness.calls.map((call) => isPrepare(call) ? "prepare" : isQuery(call) ? "query" : "other"), ["query", "prepare", "query"]);
    const destination = harness.calls[1].args[1];
    assert.equal(harness.calls[2].options.env.PRO_GATE_REVIEW_PR_EVIDENCE, join(destination, "pr-evidence.json"));
    assert.deepEqual(ctx.notifications, [], "a genuine envelope is never reported as invalid");
    assert.match(fake.messages[0].content, new RegExp(stop.envelope.reason));
  });
});

// The scripted runtime answers a query from the snapshot that query carries, so
// each assertion below is about which evidence produced the reported decision.
function snapshotOf(call: SpawnCall): string {
  const file = call.options.env.PRO_GATE_REVIEW_PR_EVIDENCE;
  return file ? readFileSync(file, "utf8") : "";
}

function callKinds(calls: SpawnCall[]): string[] {
  return calls.map((call) => isPrepare(call) ? "prepare" : isEffect(call) ? "effect" : isQuery(call) ? "query" : "other");
}

const ALLOW = /"action":"allow-existing-merge-workflow"/;

for (const moved of [true, false]) {
  test(`a SHIP matched against pre-review evidence is re-checked on fresh evidence before eligibility is reported (base ${moved ? "moved" : "held"})`, async () => {
    await withInstalledCandidate(async ({ repo }) => {
      let preparations = 0;
      let reviewedQueries = 0;
      const harness = scriptedSpawn((call) => {
        if (isPrepare(call)) return publishEvidence(call, ++preparations > 1 && moved ? '{"base":"moved"}\n' : '{"base":"reviewed"}\n');
        if (isEffect(call)) return { stdout: "engine output" };
        if (!isQuery(call)) return {};
        const snapshot = snapshotOf(call);
        if (!snapshot) return { stdout: JSON.stringify(decision("prepare-matching-review-evidence")) };
        // The v0.55 query is file-only: the reviewed snapshot still matches the SHIP after the review.
        if (snapshot.includes('"reviewed"')) return { stdout: JSON.stringify(decision(reviewedQueries++ === 0 ? "run-granted-review" : "allow-existing-merge-workflow")) };
        return { stdout: JSON.stringify(decision("stop-without-new-review")) };
      });
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      await fake.commands.get("pro-gate")!.handler("1983", context(repo));
      assert.deepEqual(callKinds(harness.calls), ["query", "prepare", "query", "effect", "query", "prepare", "query"]);
      const first = harness.calls[1].args[1];
      const second = harness.calls[5].args[1];
      assert.notEqual(dirname(first), dirname(second), "the refresh prepares into a new directory");
      assert.equal(harness.calls[5].options.env.PRO_GATE_REVIEW_PR_EVIDENCE, undefined, "the refresh runs with no inherited proof");
      const last = harness.calls[6];
      assert.equal(last.options.env.PRO_GATE_REVIEW_PR_EVIDENCE, join(second, "pr-evidence.json"));
      assert.equal(last.args[last.args.indexOf("--diff") + 1], join(second, "endpoint.patch"));
      assert.equal(fake.messages.length, 1);
      if (moved) {
        assert.doesNotMatch(fake.messages[0].content, ALLOW, "a SHIP bound to the old base was reported as merge-eligible");
        assert.match(fake.messages[0].content, /stop-without-new-review/);
      } else {
        assert.match(fake.messages[0].content, ALLOW);
      }
      for (const destination of [first, second]) assert.equal(existsSync(dirname(destination)), false, "a prepared pair outlived the command");
    });
  });
}

test("PLANTED NEGATIVE: a refresh the runtime refuses withholds merge eligibility", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    let preparations = 0;
    let reviewedQueries = 0;
    const harness = scriptedSpawn((call) => {
      if (isPrepare(call)) return ++preparations === 1 ? publishEvidence(call) : { code: 2, stderr: "ERROR: PR metadata changed while preparing review evidence; no review submitted" };
      if (isEffect(call)) return { stdout: "engine output" };
      if (!isQuery(call)) return {};
      if (!snapshotOf(call)) return { stdout: JSON.stringify(decision("prepare-matching-review-evidence")) };
      return { stdout: JSON.stringify(decision(reviewedQueries++ === 0 ? "run-granted-review" : "allow-existing-merge-workflow")) };
    });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    const ctx = context(repo);
    await fake.commands.get("pro-gate")!.handler("1983", ctx);
    assert.deepEqual(callKinds(harness.calls), ["query", "prepare", "query", "effect", "query", "prepare"]);
    assert.equal(fake.messages.length, 1);
    assert.doesNotMatch(fake.messages[0].content, ALLOW);
    assert.match(fake.messages[0].content, /"withheld":"allow-existing-merge-workflow"/);
    assert.equal(ctx.notifications.length, 1);
    assert.match(ctx.notifications[0], /could not re-verify this PR's evidence before reporting merge eligibility: .*PR metadata changed/);
  });
});

test("an allow answered on evidence pi just prepared is reported without another preparation", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const harness = scriptedSpawn((call) => {
      if (isPrepare(call)) return publishEvidence(call);
      return { stdout: JSON.stringify(decision(snapshotOf(call) ? "allow-existing-merge-workflow" : "prepare-matching-review-evidence")) };
    });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler("1983", context(repo));
    assert.deepEqual(callKinds(harness.calls), ["query", "prepare", "query"]);
    assert.match(fake.messages[0].content, ALLOW);
  });
});

test("a caller-supplied snapshot is re-verified before an allow is reported", async () => {
  await withInstalledCandidate(async ({ repo }) => {
    const supplied = { diff: join(repo, "review.diff"), endpoint: join(repo, "endpoint.diff"), prEvidence: join(repo, "pr-evidence.json") };
    for (const file of Object.values(supplied)) writeFileSync(file, '{"base":"stale"}\n');
    const harness = scriptedSpawn((call) => {
      if (isPrepare(call)) return publishEvidence(call, '{"base":"moved"}\n');
      return { stdout: JSON.stringify(decision(snapshotOf(call).includes('"stale"') ? "allow-existing-merge-workflow" : "stop-without-new-review")) };
    });
    const fake = fakePi();
    registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
    await fake.commands.get("pro-gate")!.handler(`1983 --diff ${supplied.diff} --endpoint ${supplied.endpoint} --pr-evidence ${supplied.prEvidence}`, context(repo));
    assert.deepEqual(callKinds(harness.calls), ["query", "prepare", "query"]);
    assert.equal(harness.calls[1].options.env.PRO_GATE_REVIEW_PR_EVIDENCE, undefined, "the refresh runs with no inherited proof");
    assert.doesNotMatch(fake.messages[0].content, ALLOW);
    assert.match(fake.messages[0].content, /stop-without-new-review/);
  });
});

// A caller cuts a scoped delta from one comparison. The scripted runtime answers
// that comparison with its SHIP, and any other with a fresh grant: what a
// retarget at an unchanged HEAD earns. Each file moves alone, so each check
// carries its own case.
for (const change of ["patch", "metadata", "none"] as const) {
  test(`a caller's scoped delta is reported only while its comparison holds (${change === "none" ? "unchanged" : `${change} changed`})`, async () => {
    await withInstalledCandidate(async ({ repo }) => {
      const snapshot = '{"base":"reviewed"}\n';
      const scoped = { diff: join(repo, "scoped.diff"), endpoint: join(repo, "endpoint.diff"), prEvidence: join(repo, "pr-evidence.json"), manifest: join(repo, "manifest.json"), confirm: join(repo, "confirm.md") };
      writeFileSync(scoped.diff, "diff --git a/scoped b/scoped\n+scoped\n");
      writeFileSync(scoped.endpoint, change === "patch" ? "diff --git a/before b/before\n+before\n" : PREPARED_PATCH);
      writeFileSync(scoped.prEvidence, change === "metadata" ? '{"base":"before-retarget"}\n' : snapshot);
      writeFileSync(scoped.manifest, '{"scope":"delta"}\n');
      writeFileSync(scoped.confirm, "VERDICT: SHIP\n");
      const cut = { endpoint: readFileSync(scoped.endpoint, "utf8"), snapshot: readFileSync(scoped.prEvidence, "utf8") };
      let grants = 0;
      const harness = scriptedSpawn((call) => {
        if (isPrepare(call)) return publishEvidence(call, snapshot);
        if (isEffect(call)) return { stdout: "engine output" };
        if (!isQuery(call)) return {};
        const reviewed = readFileSync(call.options.env.PRO_GATE_REVIEW_ENDPOINT_PATCH, "utf8") === cut.endpoint && snapshotOf(call) === cut.snapshot;
        return { stdout: JSON.stringify(decision(reviewed ? "allow-existing-merge-workflow" : grants++ === 0 ? "run-granted-review" : "stop-without-new-review")) };
      });
      const fake = fakePi();
      registerProGateCommand(fake.pi, { spawnFn: harness.spawnFn });
      const ctx = context(repo);
      await fake.commands.get("pro-gate")!.handler(`1983 --diff ${scoped.diff} --endpoint ${scoped.endpoint} --pr-evidence ${scoped.prEvidence} --manifest ${scoped.manifest} --confirm ${scoped.confirm}`, ctx);
      assert.equal(fake.messages.length, 1);
      if (change === "none") {
        assert.deepEqual(callKinds(harness.calls), ["query", "prepare", "query"]);
        const last = harness.calls[2];
        assert.equal(last.args[last.args.indexOf("--diff") + 1], scoped.diff, "the caller's scoped payload is what was reported on");
        assert.equal(last.args[last.args.indexOf("--confirm") + 1], scoped.confirm);
        assert.equal(last.options.env.PRO_GATE_REVIEW_FILTER_MANIFEST, scoped.manifest);
        assert.match(fake.messages[0].content, ALLOW);
        assert.deepEqual(ctx.notifications, []);
      } else {
        assert.deepEqual(callKinds(harness.calls), ["query", "prepare"], "a review ran on a scope cut from another comparison");
        assert.doesNotMatch(fake.messages[0].content, ALLOW);
        assert.match(fake.messages[0].content, /"withheld":"allow-existing-merge-workflow"/);
        assert.match(fake.messages[0].content, /rebuilt together/);
        assert.equal(ctx.notifications.length, 1);
        assert.match(ctx.notifications[0], /comparison changed since its scoped review evidence was cut/);
      }
    });
  });
}
