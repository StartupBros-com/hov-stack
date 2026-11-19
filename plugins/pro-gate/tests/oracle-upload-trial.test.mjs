import test from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, spawnSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { makePackage } from "./fixtures/oracle-upload/package.mjs";
import { scoreUpload, summarize, decide } from "../bin/oracle-upload-trial.mjs";
const cli = fileURLToPath(
  new URL("../bin/oracle-upload-trial.mjs", import.meta.url),
);
const [chip, drop] = JSON.parse(
  readFileSync(
    new URL("./fixtures/oracle-upload/recorded.json", import.meta.url),
  ),
);
const summary = (failures = 0, extra = {}) => ({
  counted: 20,
  failures,
  inconclusive: 0,
  broken: null,
  stopped: "count",
  ...extra,
});
test("block-2 readings preserve the real trial-12 2xx then cancel and trial-15 drop", () => {
  assert.deepEqual(
    scoreUpload(chip.requests, chip.phases.cleanupStart),
    chip.upload,
  );
  assert.deepEqual(
    scoreUpload(drop.requests, drop.phases.cleanupStart),
    drop.upload,
  );
  const s = summarize([chip, drop], { stopped: "count", wallMs: 25580 });
  assert.equal(s.counted, 2);
  assert.equal(s.failures, 1);
  assert.equal(s.inconclusive, 0);
  assert.equal(s.outcomes.chip, 1);
  assert.equal(s.outcomes.drop, 1);
  assert.equal(s.wallMs, 25580);
});
test("counting excludes overlaps and pre-upload errors; signal and doubles are failures", () => {
  const noSignal = { ...chip, requests: [] };
  const double = {
    ...chip,
    requests: [
      ...chip.requests,
      chip.requests.find((q) => q.path === "/backend-api/files"),
    ],
  };
  const s = summarize([
    chip,
    drop,
    noSignal,
    double,
    { outcome: "upload-error", phases: { uploadStart: 0 } },
    { ...chip, reviewOverlap: true },
    { outcome: "pre-upload-error", phases: {} },
    { outcome: "harness-error" },
  ]);
  assert.equal(s.counted, 5);
  assert.equal(s.failures, 4);
  assert.equal(s.inconclusive, 3);
});
test("the predeclared signal requires all three 2xx responses before cleanup", () => {
  for (const method of ["POST", "PUT"]) {
    const late = chip.requests.map((q) =>
      q.phase === "upload" && q.method === method
        ? { ...q, statusMs: chip.phases.cleanupStart + 1 }
        : q,
    );
    assert.equal(scoreUpload(late, chip.phases.cleanupStart).signal, false);
  }
  const cancelOnly = chip.requests.map((q) =>
    q.path === "/backend-api/files/process_upload_stream"
      ? { ...q, status: null, failedMs: chip.phases.cleanupStart + 1 }
      : q,
  );
  assert.deepEqual(
    scoreUpload(cancelOnly, chip.phases.cleanupStart).finalClasses,
    ["cancel-after-cleanup"],
  );
  assert.equal(summarize([{ ...chip, requests: cancelOnly }]).failures, 1);
});
for (const [name, c, k, expected] of [
  ["pass zero", summary(), null, "pass"],
  ["pass two", summary(2), null, "pass"],
  ["needs control", summary(3), null, "needs-control"],
  ["reject", summary(3), summary(2), "reject"],
  ["defer both fail", summary(3), summary(3), "defer"],
  ["broken candidate", summary(0, { broken: "import" }), null, "broken"],
  ["broken control", summary(3), summary(0, { broken: "block" }), "broken"],
  ["inconclusive candidate", summary(0, { inconclusive: 4 }), null, "defer"],
  [
    "short candidate",
    summary(0, { counted: 19, stopped: "deadline" }),
    null,
    "defer",
  ],
  [
    "inconclusive control",
    summary(3),
    summary(0, { counted: 19, stopped: "deadline" }),
    "defer",
  ],
  [
    "early failed candidate",
    summary(3, { counted: 3, stopped: "failures" }),
    summary(),
    "reject",
  ],
])
  test("decision: " + name, () => assert.equal(decide(c, k).verdict, expected));
function fixture(t) {
  const dir = mkdtempSync(path.join(tmpdir(), "upload-fixture-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const root = path.join(dir, "oracle");
  makePackage(root);
  return { dir, root };
}
function invoke(args, env = {}) {
  return spawnSync(process.execPath, [cli, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
    timeout: 30000,
  });
}
function auditOf(cand, live, ...extra) {
  const r = invoke(["audit", "--oracle-root", cand, "--baseline-root", live, ...extra]);
  return { status: r.status, out: JSON.parse(r.stdout) };
}
// Put a risky line inside one fixture function's body, as a real Oracle edit would.
function inject(root, file, fn, line) {
  const p = path.join(root, "dist/src/browser", file);
  const anchor = `return call('${fn}',...args);`;
  const src = readFileSync(p, "utf8");
  assert.ok(src.includes(anchor), `fixture has ${fn}`);
  writeFileSync(p, src.replace(anchor, `\n  ${line}\n  ${anchor}`));
}
test("audit against the live build: only new risky lines need the exact acknowledgement", (t) => {
  const { dir } = fixture(t),
    live = path.join(dir, "live"),
    cand = path.join(dir, "candidate");
  makePackage(live);
  makePackage(cand);
  const audit = (...extra) => auditOf(cand, live, ...extra);
  // Legitimate pre-submit clicks that the live build already has are known, not new.
  for (const root of [live, cand])
    inject(root, "actions/navigation.js", "ensureChatMode", "button.click();");
  let r = audit();
  assert.equal(r.status, 0);
  assert.deepEqual([r.out.ok, r.out.known, r.out.hits.length], [true, 1, 0]);
  // PLANTED NEGATIVE: a submit path the candidate adds stops the audit.
  inject(cand, "actions/navigation.js", "ensureNotBlocked", "form.requestSubmit();");
  r = audit();
  assert.equal(r.status, 1);
  assert.deepEqual(
    r.out.hits.map((h) => [h.kind, h.file, h.text]),
    [["line", "src/browser/actions/navigation.js", "form.requestSubmit();"]],
  );
  assert.match(r.out.digest, /^[0-9a-f]{64}$/);
  const digest = r.out.digest;
  assert.equal(audit("--ack", "0".repeat(64)).status, 1);
  r = audit("--ack", digest);
  assert.equal(r.status, 0);
  assert.equal(r.out.acknowledged, true);
  // A second copy of a known line is new, and the earlier acknowledgement no longer covers the set.
  inject(cand, "actions/navigation.js", "ensureChatMode", "button.click();");
  r = audit("--ack", digest);
  assert.equal(r.status, 1);
  assert.equal(r.out.hits.length, 2);
  // A function the trial calls that is no longer exported is broken whatever the acknowledgement.
  const nav = path.join(cand, "dist/src/browser/actions/navigation.js");
  writeFileSync(
    nav,
    readFileSync(nav, "utf8").replace(
      "export async function ensureLoggedIn",
      "async function ensureLoggedIn",
    ),
  );
  r = audit("--ack", r.out.digest);
  assert.equal(r.status, 1);
  assert.ok(r.out.missing.some((m) => m.function === "ensureLoggedIn"));
});
test("audit does not require a helper the candidate no longer has", (t) => {
  const { root } = fixture(t);
  const file = path.join(root, "dist/src/browser/actions/promptComposer.js");
  writeFileSync(
    file,
    readFileSync(file, "utf8").replace(
      /^export async function dispatchClearEvents.*$/m,
      "",
    ),
  );
  const r = invoke(["audit", "--oracle-root", root]);
  assert.equal(r.status, 0, r.stdout);
  assert.deepEqual(JSON.parse(r.stdout).missing, []);
});
test("audit without a baseline flags submit, click, Enter, missing exports and helper changes", (t) => {
  const { root } = fixture(t);
  let r = invoke(["audit", "--oracle-root", root]);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.equal(JSON.parse(r.stdout).ok, true);
  const file = path.join(root, "dist/src/browser/actions/navigation.js"),
    source = readFileSync(file, "utf8");
  for (const bad of [
    "form.requestSubmit();",
    "button.click();",
    'Input.dispatchKeyEvent({key:"Enter"});',
  ]) {
    writeFileSync(
      file,
      source.replace("return call('ensureNotBlocked',...args);", bad),
    );
    r = invoke(["audit", "--oracle-root", root]);
    assert.equal(r.status, 1);
    assert.ok(JSON.parse(r.stdout).hits.length);
  }
  writeFileSync(
    file,
    source.replace(
      "export async function ensureNotBlocked",
      "async function ensureNotBlocked",
    ),
  );
  r = invoke(["audit", "--oracle-root", root]);
  assert.equal(r.status, 1);
  assert.ok(
    JSON.parse(r.stdout).missing.some((x) =>
      JSON.stringify(x).includes("ensureNotBlocked"),
    ),
  );
  writeFileSync(
    file,
    source.replace("return call('navigateOnce',...args);", "button.click();"),
  );
  assert.equal(invoke(["audit", "--oracle-root", root]).status, 1);
});
// PLANTED NEGATIVES: each form reached a send path in no function the trial names, so a
// scan limited to the trial's call graph, or to the CDP method names, missed it.
for (const [name, file, line] of [
  ["arrow function in a new file", "src/browser/late.js", "export const go = (el) => el.click();"],
  ["synthetic mouse event", "src/browser/late.js", "el.dispatchEvent(new MouseEvent('click', { bubbles: true }));"],
  ["Enter by key code", "src/browser/late.js", "send({ type: 'keyDown', code: 'Enter' });"],
  ["computed click", "src/browser/late.js", "button['click']();"],
  ["click through call", "src/browser/late.js", "HTMLElement.prototype.click.call(button);"],
  ["module outside src", "cli/late.mjs", "export const go = (el) => el.requestSubmit();"],
  ["CommonJS file", "vendor/late.cjs", "module.exports = (el) => el.click();"],
])
  test("audit sees a send path the call graph never reaches: " + name, (t) => {
    const { dir } = fixture(t),
      live = path.join(dir, "live"),
      cand = path.join(dir, "candidate");
    makePackage(live);
    makePackage(cand);
    assert.equal(auditOf(cand, live).status, 0);
    const dest = path.join(cand, "dist", file);
    mkdirSync(path.dirname(dest), { recursive: true });
    writeFileSync(dest, line + "\n");
    const r = auditOf(cand, live);
    assert.equal(r.status, 1);
    assert.deepEqual(
      r.out.hits.map((h) => [h.file, h.text]),
      [[file, line]],
    );
  });
test("audit compares whole lines and ignores where a known line moved", (t) => {
  const { dir } = fixture(t),
    live = path.join(dir, "live"),
    cand = path.join(dir, "candidate");
  makePackage(live);
  makePackage(cand);
  inject(live, "actions/navigation.js", "ensureChatMode", "button.click();");
  inject(cand, "actions/attachments.js", "isAttachmentVisible", "button.click();");
  let r = auditOf(cand, live);
  assert.deepEqual([r.status, r.out.known, r.out.hits.length], [0, 1, 0]);
  // A change past the first 200 characters of a known line is a new line.
  const head = "const label = '" + "x".repeat(220) + "'; ";
  inject(live, "actions/navigation.js", "ensureNotBlocked", head + "button.click();");
  inject(cand, "actions/navigation.js", "ensureNotBlocked", head + "form.requestSubmit();");
  r = auditOf(cand, live);
  assert.equal(r.status, 1);
  assert.deepEqual(r.out.hits.map((h) => h.text), [head + "form.requestSubmit();"]);
});
test("audit flags new dependencies, install scripts, launchers, links and an unreadable manifest", (t) => {
  const { dir } = fixture(t),
    live = path.join(dir, "live"),
    cand = path.join(dir, "candidate");
  makePackage(live);
  makePackage(cand);
  const manifest = (root, extra) =>
    writeFileSync(
      path.join(root, "package.json"),
      JSON.stringify({ type: "module", version: "1.0.0", dependencies: { a: "1" }, bin: { oracle: "dist/bin/oracle.js" }, ...extra }),
    );
  manifest(live, {});
  manifest(cand, {});
  assert.deepEqual([auditOf(cand, live).status, auditOf(cand, live).out.known], [0, 2]);
  manifest(cand, { dependencies: { a: "1", b: "1" } });
  assert.deepEqual(auditOf(cand, live).out.hits.map((h) => [h.kind, h.text]), [["dependency", "b"]]);
  manifest(cand, { optionalDependencies: { c: "1" } });
  assert.deepEqual(auditOf(cand, live).out.hits.map((h) => [h.kind, h.text]), [["dependency", "c"]]);
  manifest(cand, { scripts: { postinstall: "node x.js", test: "node t.js" } });
  assert.deepEqual(auditOf(cand, live).out.hits.map((h) => [h.kind, h.text]), [["script", "postinstall: node x.js"]]);
  manifest(cand, { bin: { oracle: "dist/bin/other.js" } });
  assert.deepEqual(auditOf(cand, live).out.hits.map((h) => [h.kind, h.text]), [["bin", "oracle: dist/bin/other.js"]]);
  manifest(cand, {});
  symlinkSync("/dev/null", path.join(cand, "dist/src/browser/linked.js"));
  assert.deepEqual(auditOf(cand, live).out.hits.map((h) => [h.kind, h.text]), [["symlink", "src/browser/linked.js"]]);
  writeFileSync(path.join(cand, "package.json"), "{not json");
  const r = auditOf(cand, live);
  assert.equal(r.status, 1);
  assert.deepEqual(r.out.missing, [{ function: "package.json unreadable" }]);
});
test("an acknowledgement covers only the candidate and live versions it was printed for", (t) => {
  const { dir } = fixture(t),
    live = path.join(dir, "live"),
    cand = path.join(dir, "candidate");
  makePackage(live);
  makePackage(cand);
  const version = (root, v) =>
    writeFileSync(path.join(root, "package.json"), JSON.stringify({ type: "module", version: v }));
  version(live, "1.0.0");
  version(cand, "1.0.1");
  inject(cand, "actions/navigation.js", "ensureNotBlocked", "form.requestSubmit();");
  const first = auditOf(cand, live);
  assert.deepEqual([first.out.candidateVersion, first.out.baselineVersion], ["1.0.1", "1.0.0"]);
  assert.equal(auditOf(cand, live, "--ack", first.out.digest).status, 0);
  // The same new line in the next release needs a fresh look.
  version(cand, "1.0.2");
  const next = auditOf(cand, live, "--ack", first.out.digest);
  assert.equal(next.status, 1);
  assert.notEqual(next.out.digest, first.out.digest);
});
for (const scenario of [
  "chip",
  "drop",
  "send",
  "arm-error",
  "blocked",
  "logged-out",
  "tripwire",
  "network-send",
  "pre-error",
  "no-signal",
  "sticky-close",
  "stuck-tab",
  "chip-gone",
  "probe-error",
])
  test("fake CDP end to end: " + scenario, (t) => {
    const { dir, root } = fixture(t),
      bin = path.join(dir, "bin"),
      out = path.join(dir, "out"),
      calls = path.join(dir, "calls");
    mkdirSync(bin);
    writeFileSync(calls, "");
    writeFileSync(path.join(bin, "pgrep"), "#!/bin/sh\nexit 1\n", {
      mode: 0o755,
    });
    const r = invoke(
      [
        "run",
        "--oracle-root",
        root,
        "--out",
        out,
        "--count",
        "2",
        "--gap-ms",
        "0",
        "--stop-at-failures",
        "1",
      ],
      {
        FAKE_SCENARIO: scenario,
        FAKE_CALLS: calls,
        PATH: bin + ":" + process.env.PATH,
      },
    );
    const s = JSON.parse(readFileSync(path.join(out, "summary.json"))),
      log = readFileSync(calls, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map(JSON.parse),
      names = log.map((x) => x.name);
    const broken = [
      "send",
      "arm-error",
      "blocked",
      "logged-out",
      "tripwire",
      "network-send",
      "stuck-tab",
    ].includes(scenario);
    assert.equal(r.status, broken ? 1 : 0, r.stderr + r.stdout);
    assert.equal(Boolean(s.broken), broken);
    if (scenario === "arm-error")
      assert.equal(names.includes("navigateToChatGPT"), false);
    else
      assert.ok(
        names.indexOf("Fetch.enable") < names.indexOf("navigateToChatGPT"),
      );
    assert.ok(names.includes("close"));
    if (scenario === "send")
      assert.ok(
        log.some(
          (x) =>
            x.name === "Fetch.failRequest" &&
            x.args.errorReason === "BlockedByClient",
        ),
      );
    if (scenario === "chip") {
      assert.equal(s.counted, 2);
      assert.equal(s.failures, 0);
      assert.ok(log.some((x) => x.name === "Fetch.continueRequest"));
    }
    if (["drop", "no-signal"].includes(scenario)) {
      assert.equal(s.counted, 1);
      assert.equal(s.failures, 1);
      assert.equal(s.stopped, "failures");
    }
    // PLANTED NEGATIVE: an upload whose chip is gone by cleanup, or whose final probe
    // fails, is a failure even when every network response succeeded.
    if (["chip-gone", "probe-error"].includes(scenario)) {
      assert.equal(s.counted, 1);
      assert.equal(s.failures, 1);
      assert.equal(s.stopped, "failures");
      assert.deepEqual(s.outcomes, {
        [scenario === "chip-gone" ? "chip-gone" : "chip-unverified"]: 1,
      });
    }
    if (scenario === "pre-error") {
      assert.equal(s.counted, 0);
      assert.equal(s.inconclusive, 4);
      assert.equal(s.stopped, "inconclusive");
    }
    const record = readFileSync(path.join(out, "open-target.txt"), "utf8");
    // PLANTED NEGATIVE: a close that did not take falls back to Chrome's target endpoint,
    // and a tab that survives that keeps its record and stops the run as broken.
    if (scenario === "sticky-close") {
      assert.ok(names.includes("closeRemoteChromeTarget"));
      assert.equal(s.counted, 2);
      assert.equal(record, "");
    } else if (scenario === "stuck-tab") {
      assert.equal(names.filter((n) => n === "closeRemoteChromeTarget").length, 2);
      assert.equal(s.broken, "own tab fixture-target not closed");
      assert.equal(record, "fixture-target\n");
    } else assert.equal(record, "");
  });
// PLANTED NEGATIVE: a trial needs its own 240 s plus 30 s to close its tab, so a deadline
// inside that margin stops the run before it connects.
for (const seconds of [20, 260])
  test(`a deadline ${seconds} s away prevents even connecting`, (t) => {
    const { dir, root } = fixture(t),
      out = path.join(dir, "out"),
      calls = path.join(dir, "calls");
    writeFileSync(calls, "");
    const r = invoke(
      [
        "run",
        "--oracle-root",
        root,
        "--out",
        out,
        "--count",
        "20",
        "--deadline-epoch",
        String(Math.floor(Date.now() / 1000) + seconds),
      ],
      { FAKE_CALLS: calls, FAKE_SCENARIO: "chip" },
    );
    assert.equal(r.status, 0, r.stderr);
    const s = JSON.parse(readFileSync(path.join(out, "summary.json")));
    assert.deepEqual([s.stopped, s.counted, s.inconclusive], ["deadline", 0, 0]);
    assert.equal(readFileSync(calls, "utf8"), "");
  });
test("import failure is broken", (t) => {
  const { dir, root } = fixture(t),
    out = path.join(dir, "out");
  rmSync(path.join(root, "dist/src/browser/chromeLifecycle.js"));
  const b = invoke([
    "run",
    "--oracle-root",
    root,
    "--out",
    out,
    "--count",
    "20",
  ]);
  assert.equal(b.status, 1);
  assert.ok(JSON.parse(readFileSync(path.join(out, "summary.json"))).broken);
});
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"])
  test(signal + " closes the own fake tab and stops promptly", async (t) => {
    const { dir, root } = fixture(t),
      calls = path.join(dir, "calls"),
      out = path.join(dir, "out"),
      bin = path.join(dir, "bin");
    mkdirSync(bin);
    writeFileSync(calls, "");
    writeFileSync(path.join(bin, "pgrep"), "#!/bin/sh\nexit 1\n", {
      mode: 0o755,
    });
    const child = spawn(
      process.execPath,
      [cli, "run", "--oracle-root", root, "--out", out, "--count", "20"],
      {
        env: {
          ...process.env,
          FAKE_SCENARIO: "hang",
          FAKE_CALLS: calls,
          PATH: bin + ":" + process.env.PATH,
        },
        stdio: "ignore",
      },
    );
    t.after(() => {
      if (child.exitCode === null) child.kill("SIGKILL");
    });
    const exit = new Promise((resolve) =>
      child.once("exit", (code) => resolve(code)),
    );
    for (
      let i = 0;
      i < 200 && !readFileSync(calls, "utf8").includes("ensurePromptReady");
      i++
    )
      await sleep(10);
    assert.ok(readFileSync(calls, "utf8").includes("ensurePromptReady"));
    child.kill(signal);
    assert.equal(
      await Promise.race([exit, sleep(3000).then(() => "timeout")]),
      1,
    );
    assert.ok(readFileSync(calls, "utf8").includes('"close"'));
    assert.equal(
      JSON.parse(readFileSync(path.join(out, "summary.json"))).broken,
      signal,
    );
  });
// A review queued for a slot the bump holds shows only its wrapper; the processes that
// drive the browser are Oracle and the salvage helper.
for (const [name, busy, overlaps] of [
  ["a queued review wrapper", "oracle-review\\.sh", false],
  ["Oracle", "oracle-cli\\.js", true],
  // PLANTED NEGATIVE: harvest and recovery drive the browser through the salvage helper
  // without a slot, so it counts even with no review wrapper running.
  ["the salvage helper", "cdp-salvage\\.mjs", true],
])
  test("review overlap: " + name + (overlaps ? " counts" : " does not count"), (t) => {
    const { dir, root } = fixture(t),
      bin = path.join(dir, "bin"),
      out = path.join(dir, "out"),
      calls = path.join(dir, "calls");
    mkdirSync(bin);
    writeFileSync(calls, "");
    writeFileSync(
      path.join(bin, "pgrep"),
      `#!/bin/sh\n[ "$2" = '${busy}' ] && { echo 1; exit 0; }\nexit 1\n`,
      { mode: 0o755 },
    );
    const r = invoke(
      ["run", "--oracle-root", root, "--out", out, "--count", "2", "--gap-ms", "0"],
      { FAKE_SCENARIO: "chip", FAKE_CALLS: calls, PATH: bin + ":" + process.env.PATH },
    );
    assert.equal(r.status, 0, r.stderr + r.stdout);
    const s = JSON.parse(readFileSync(path.join(out, "summary.json")));
    if (overlaps) {
      assert.equal(s.counted, 0);
      assert.equal(s.stopped, "inconclusive");
      assert.equal(readFileSync(calls, "utf8").includes("connectToRemoteChrome"), false);
    } else {
      assert.equal(s.counted, 2);
      assert.equal(s.failures, 0);
      assert.equal(s.inconclusive, 0);
    }
  });
// PLANTED NEGATIVE: a signal that lands before the trial's race starts still stops it
// before it opens a tab.
test("a signal during prompt assembly stops the trial before it connects", async (t) => {
  const { dir, root } = fixture(t),
    calls = path.join(dir, "calls"),
    out = path.join(dir, "out"),
    bin = path.join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(calls, "");
  writeFileSync(path.join(bin, "pgrep"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  const child = spawn(
    process.execPath,
    [cli, "run", "--oracle-root", root, "--out", out, "--count", "20"],
    {
      env: {
        ...process.env,
        FAKE_SCENARIO: "slow-assemble",
        FAKE_CALLS: calls,
        PATH: bin + ":" + process.env.PATH,
      },
      stdio: "ignore",
    },
  );
  t.after(() => {
    if (child.exitCode === null) child.kill("SIGKILL");
  });
  const exit = new Promise((resolve) => child.once("exit", (code) => resolve(code)));
  for (let i = 0; i < 200 && !readFileSync(calls, "utf8").includes("assembleBrowserPrompt"); i++)
    await sleep(10);
  child.kill("SIGTERM");
  assert.equal(await Promise.race([exit, sleep(3000).then(() => "timeout")]), 1);
  assert.equal(readFileSync(calls, "utf8").includes("connectToRemoteChrome"), false);
  assert.equal(JSON.parse(readFileSync(path.join(out, "summary.json"))).broken, "SIGTERM");
});
