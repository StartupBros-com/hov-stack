"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { applySettings } = require("../../lib/settings-apply");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { inputsHash } = require("../../lib/settings-apply");
const apply = (desired, base, live, extra = {}) =>
  applySettings({
    desired,
    base,
    live,
    cfg: "/tmp/fixture/.claude",
    home: "/tmp/fixture",
    ...extra,
  });
test("scalar three-way branches and retained conflict base", () => {
  for (const [d, b, l, want, conflict] of [
    [2, 1, 1, 2, 0],
    [2, 1, 2, 2, 0],
    [2, 1, 3, 3, 1],
    [1, 1, 3, 3, 0],
    [2, undefined, undefined, 2, 0],
    [2, undefined, 2, 2, 0],
    [undefined, 1, undefined, undefined, 0],
    [undefined, 1, 1, undefined, 0],
    [undefined, 1, 3, 3, 1],
    [2, undefined, 3, 3, 1],
    [2, 1, undefined, 2, 0],
  ]) {
    const wrap = (v) => (v === undefined ? {} : { x: v });
    const r = apply(wrap(d), wrap(b), wrap(l));
    assert.equal(r.result.x, want);
    assert.equal(r.conflicts.length, conflict);
    if (conflict) assert.deepEqual(r.nextBase, wrap(b));
  }
});
test("first-run differences become repeated conflicts", () => {
  const r = apply({ x: 2 }, null, { x: 3 });
  assert.equal(r.firstRun.length, 1);
  assert.equal(apply({ x: 2 }, r.nextBase, r.result).conflicts.length, 1);
});
test("objects remove settled keys and keep independent live additions", () => {
  assert.deepEqual(
    apply({}, { gone: { x: 1 } }, { gone: { x: 1 } }).result,
    {},
  );
  const r = apply({}, { gone: { x: 1 } }, { gone: { x: 1, local: 2 } });
  assert.deepEqual(r.result, { gone: { local: 2 } });
  assert.deepEqual(r.nextBase, {});
  const first = apply({ branch: { x: 2 } }, null, {
    branch: { x: 3, local: 4 },
  });
  assert.equal(first.firstRun.length, 1);
  assert.equal(
    apply({ branch: { x: 2 } }, first.nextBase, first.result).conflicts.length,
    1,
  );
  assert.equal(
    apply(
      { permissions: { deny: ["guard"] } },
      { permissions: { deny: ["guard"] } },
      {},
    ).result.permissions.deny[0],
    "guard",
  );
});
test("non-string arrays are atomic and first-run string lists only add", () => {
  const r = apply({ x: [{ v: 2 }] }, { x: [{ v: 1 }] }, { x: [{ v: 3 }] });
  assert.equal(r.conflicts.length, 1);
  assert.deepEqual(r.result.x, [{ v: 3 }]);
  assert.deepEqual(apply({ x: ["new"] }, null, { x: ["local"] }).result.x, [
    "local",
    "new",
  ]);
});
test("lists preserve live additions and deny removals remain held", () => {
  const d = { permissions: { allow: ["new"], deny: ["keep"] } },
    b = { permissions: { allow: ["old"], deny: ["old", "keep"] } },
    l = { permissions: { allow: ["old", "local"], deny: ["old"] } };
  const r = apply(d, b, l);
  assert.deepEqual(r.result.permissions, {
    allow: ["local", "new"],
    deny: ["old", "keep"],
  });
  assert.equal(r.held.length, 1);
  assert.equal(apply(d, r.nextBase, r.result).held.length, 1);
  assert.equal(
    apply(d, r.nextBase, { permissions: { allow: [], deny: ["keep"] } }).held
      .length,
    0,
  );
});
test("live-owned paths and secret keys never enter the base", () => {
  const r = apply(
    {
      model: "repo",
      statusLine: { command: "repo" },
      env: { ANTHROPIC_CUSTOM_HEADERS: "fixture-header-value", X: "new" },
    },
    null,
    {
      model: "local",
      statusLine: { command: "local" },
      env: { ANTHROPIC_CUSTOM_HEADERS: "fixture-header-value" },
    },
  );
  assert.equal(r.result.model, "local");
  assert.equal(r.result.env.ANTHROPIC_CUSTOM_HEADERS, "fixture-header-value");
  assert.equal(r.nextBase.env.ANTHROPIC_CUSTOM_HEADERS, undefined);
});
const hook = (command) => ({
  SessionStart: [{ hooks: [{ type: "command", command, timeout: 20 }] }],
});
test("hook spelling, removals, missing targets and retry", () => {
  const cmd =
    '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/SessionStart/fixture.js"';
  const d = { hooks: hook(cmd) },
    l = { hooks: hook(cmd.replaceAll("$HOME", "/tmp/fixture")) };
  assert.deepEqual(apply(d, null, l).result, l);
  const grouped = {
    hooks: {
      SessionStart: [
        ...d.hooks.SessionStart,
        { hooks: [{ type: "command", command: "echo fixture" }] },
      ],
    },
  };
  assert.deepEqual(apply(grouped, null, {}).nextBase, grouped);
  assert.deepEqual(apply({ hooks: {} }, d, l).result.hooks, undefined);
  const r = apply(d, {}, {}, { hookTargetExists: () => false });
  assert.equal(r.skipped.length, 1);
  const retry = apply(d, r.nextBase, r.result);
  assert.equal(retry.changes.length, 1);
  assert.equal(retry.result.hooks.SessionStart[0].hooks[0].command, cmd);
  const mapped = apply(
    { hooks: hook('node "/tmp/fixture/.claude/hooks/missing.js"') },
    {},
    {},
    { cfg: "/tmp/custom-config", hookTargetExists: () => false },
  );
  assert.equal(mapped.skipped[0].path, "/tmp/custom-config/hooks/missing.js");
});
test("dcg version pin is equivalent", () => {
  const d = { hooks: hook("$HOME/.local/bin/dcg") },
    l = { hooks: hook("/tmp/fixture/.local/lib/dcg/v0.16.0/dcg") };
  assert.deepEqual(apply(d, d, l).result, l);
});
test("hook metadata updates preserve commands, matcher keying and duplicates", () => {
  const command = "$HOME/.claude/hooks/fixture.js";
  const b = { hooks: hook(command) },
    d = structuredClone(b),
    l = structuredClone(b);
  d.hooks.SessionStart[0].hooks[0].timeout = 30;
  l.hooks.SessionStart[0].hooks[0].command =
    "/tmp/fixture/.claude/hooks/fixture.js";
  const r = apply(d, b, l, { hookTargetExists: () => false });
  assert.equal(r.skipped.length, 0);
  assert.equal(r.result.hooks.SessionStart[0].hooks[0].timeout, 30);
  assert.equal(
    r.result.hooks.SessionStart[0].hooks[0].command,
    l.hooks.SessionStart[0].hooks[0].command,
  );
  l.hooks.SessionStart[0].hooks.push(
    structuredClone(l.hooks.SessionStart[0].hooks[0]),
  );
  assert.deepEqual(apply(b, b, l).result, l);
  d.hooks.SessionStart[0].matcher = "startup";
  const changed = apply(d, b, l);
  assert.equal(changed.result.hooks.SessionStart.length, 1);
  assert.equal(changed.result.hooks.SessionStart[0].matcher, "startup");
});
test("backstop gates on links and hashes and reports child outcomes fail-open", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "settings-hook-"));
  try {
    const root = path.join(tmp, "root"),
      cfg = path.join(tmp, "cfg"),
      home = path.join(tmp, "home");
    fs.mkdirSync(path.join(root, "hooks/SessionStart"), { recursive: true });
    fs.mkdirSync(path.join(root, "lib"));
    fs.mkdirSync(path.join(root, "hooks/lib"));
    fs.copyFileSync(
      path.resolve(__dirname, "../lib/hook-output.js"),
      path.join(root, "hooks/lib/hook-output.js"),
    );
    fs.mkdirSync(path.join(cfg, ".hov-stack"), { recursive: true });
    fs.mkdirSync(home);
    fs.copyFileSync(
      path.resolve(__dirname, "../SessionStart/settings-apply.js"),
      path.join(root, "hooks/SessionStart/settings-apply.js"),
    );
    fs.copyFileSync(
      path.resolve(__dirname, "../../lib/settings-apply.js"),
      path.join(root, "lib/settings-apply.js"),
    );
    fs.writeFileSync(path.join(cfg, "settings.json"), "{}");
    fs.symlinkSync(path.join(root, "hooks"), path.join(cfg, "hooks"));
    const log = path.join(tmp, "calls");
    fs.writeFileSync(
      path.join(root, "sync.sh"),
      '#!/bin/bash\nprintf "%s|%s\\n" "$*" "$CLAUDE_HOME" >> "$FIXTURE_LOG"\n[ "$FIXTURE_SLEEP" != 1 ] || sleep 1\nprintf "settings: %s\\n" "$FIXTURE_STATUS"\nexit "${FIXTURE_RC:-0}"\n',
    );
    const env = {
      ...process.env,
      HOME: home,
      CLAUDE_HOME: cfg,
      HOV_STACK_OVERLAY: path.join(tmp, "overlay"),
      FIXTURE_LOG: log,
      FIXTURE_STATUS: "applied 2",
    };
    const run = (extra) =>
      spawnSync(
        process.execPath,
        [path.join(root, "hooks/SessionStart/settings-apply.js")],
        { env: { ...env, ...extra }, encoding: "utf8", timeout: 3000 },
      );
    const stamp = path.join(cfg, ".hov-stack/settings-apply.stamp");
    fs.writeFileSync(
      stamp,
      inputsHash({
        root,
        cfg,
        overlayDir: env.HOV_STACK_OVERLAY,
        dcgPath: path.join(home, ".local/bin/dcg"),
      }),
    );
    assert.equal(run().stdout, "");
    assert.equal(fs.existsSync(log), false);
    fs.writeFileSync(path.join(root, "settings.json"), "{}");
    assert.equal(
      run().stdout,
      "[settings-apply] settings.json: applied 2 change(s) from the harness checkout\n",
    );
    assert.equal(
      fs.readFileSync(log, "utf8"),
      `apply-settings --quiet|${cfg}\n`,
    );
    for (const status of [
      "unchanged",
      "skipped (host role undeclared: only workstation and satellite hosts apply automatically)",
      "skipped (another apply held the lock for 10s)",
    ])
      assert.equal(run({ FIXTURE_STATUS: status }).stdout, "");
    assert.match(
      run({ FIXTURE_STATUS: "unchanged; 1 conflict(s), see sync.sh check" })
        .stdout,
      /settings.json: unchanged; 1 conflict/,
    );
    assert.match(
      run({ FIXTURE_STATUS: "unchanged; 1 setting(s) skipped (failed validation)" }).stdout,
      /settings.json: unchanged; 1 setting\(s\) skipped/,
    );
    for (const extra of [
      { FIXTURE_RC: "1" },
      { FIXTURE_SLEEP: "1", HOV_SETTINGS_APPLY_TIMEOUT_MS: "20" },
    ]) {
      const r = run(extra);
      assert.equal(r.status, 0);
      assert.match(r.stdout, /apply did not finish/);
    }
    fs.unlinkSync(path.join(cfg, "hooks"));
    fs.mkdirSync(path.join(cfg, "hooks"));
    fs.symlinkSync(path.join(root, "lib"), path.join(cfg, "lib"));
    fs.copyFileSync(path.join(root, "sync.sh"), path.join(cfg, "sync.sh"));
    const before = fs.readFileSync(log, "utf8");
    assert.equal(run().stdout, "");
    assert.equal(fs.readFileSync(log, "utf8"), before);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("command-less hooks are distinct, retained and removed", () => {
  const d = { hooks: { Stop: [{ hooks: [
    { type: "prompt", prompt: "one" }, { prompt: "two", type: "prompt" },
  ] }] } };
  const r = apply(d, {}, {});
  assert.equal(r.changes.length, 2);
  assert.deepEqual(r.result, d);
  assert.equal(apply(d, d, r.result).changes.length, 0);
  const removed = apply({}, d, r.result);
  assert.equal(removed.changes.length, 2);
  assert.equal(removed.result.hooks, undefined);
});
test("malformed and pre-existing empty hooks survive untouched", () => {
  for (const hooks of [{ Stop: {} }, { Stop: [{matcher:"q"}] },
    {Stop: [{hooks:[]}], SessionStart: []}]) {
    const live = {hooks};
    const r = apply({hooks:{}}, {hooks:{}}, live);
    assert.deepEqual(r.result, live);
    assert.equal(r.changes.length, 0);
  }
  const old = {hooks:{Stop:[{hooks:[{type:"prompt",prompt:"old"}]}, {matcher:"empty",hooks:[]}]}};
  const r = apply({}, old, old);
  assert.deepEqual(r.result.hooks.Stop, [{matcher:"empty",hooks:[]}]);
});
test("dangerous keys are ignored at every depth and preserved in live", () => {
  const d = JSON.parse('{"__proto__":{"x":1},"constructor":2,"prototype":3,"nested":{"__proto__":4,"constructor":5,"prototype":6,"safe":7}}');
  const l = JSON.parse('{"__proto__":{"local":true},"nested":{"__proto__":"local"}}');
  const r = apply(d, {}, l);
  assert.deepEqual(r.result, JSON.parse('{"__proto__":{"local":true},"nested":{"__proto__":"local","safe":7}}'));
  assert.deepEqual(r.nextBase, {nested:{safe:7}});
  assert.equal(r.changes.length, 1);
  assert.equal({}.x, undefined);
});
test("dcg upgrades do not change bin spelling", () => {
  const b = {hooks:hook("$HOME/.local/lib/dcg/v0.15.0/dcg")};
  const d = {hooks:hook("$HOME/.local/lib/dcg/v0.16.0/dcg")};
  const l = {hooks:hook("$HOME/.local/bin/dcg")};
  const r = apply(d,b,l);
  assert.equal(r.changes.length,0);
  assert.deepEqual(r.result,l);
});
test("skipped setting keeps live and old base then retries", () => {
  const b = {env:{X:"old"}}, d = {env:{X:"new"}}, l = {env:{X:"old"}};
  const r = apply(d,b,l,{skipPaths:{"env.X":"invalid"}});
  assert.deepEqual(r.result,l);
  assert.deepEqual(r.nextBase,b);
  assert.equal(r.skipped[0].reason,"invalid");
  assert.equal(apply(d,r.nextBase,r.result).result.env.X,"new");
  assert.deepEqual(apply(d,{}, {},{skipPaths:{"env.X":"invalid"}}).nextBase,{env:{}});
});
test("role and live deny inputs invalidate stamps without processes", () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(),"settings-hash-"));
  try {
    fs.mkdirSync(path.join(tmp,"lib"));
    const args = {root:tmp,cfg:tmp,overlayDir:tmp,env:{}};
    const hash = () => inputsHash(args);
    fs.writeFileSync(path.join(tmp,"settings.json"),'{"permissions":{"deny":["a","b"]}}');
    let before = hash();
    fs.writeFileSync(path.join(tmp,"hosts.tsv"),"fixture\tworkstation\n");
    assert.notEqual(hash(),before);
    before = hash();
    args.env.DOTFILES_ROLE = "satellite";
    assert.equal(hash(), before);
    before = hash(); fs.writeFileSync(path.join(tmp,"settings.json"),'{"permissions":{"deny":["a"]}}');
    assert.notEqual(hash(),before);
  } finally {fs.rmSync(tmp,{recursive:true,force:true});}
});
test("CLI unchanged malformed hooks preserve bytes, mtime and backups", () => {
  const tmp=fs.mkdtempSync(path.join(os.tmpdir(),"settings-cli-"));
  try {
    const live=path.join(tmp,"settings.json"), desired=path.join(tmp,"desired.json"), base=path.join(tmp,"base.json");
    fs.writeFileSync(live,'{ "hooks": { "Stop": {}, "Other": [{"matcher":"q"}], "Empty": [] } }\n');
    fs.writeFileSync(desired,'{"hooks":{}}');fs.writeFileSync(base,'{"hooks":{}}');
    const bytes=fs.readFileSync(live),mtime=fs.statSync(live).mtimeMs;
    const r=spawnSync(process.execPath,[path.resolve(__dirname,"../../lib/settings-apply.js"),"--live",live,"--desired",desired,"--base",base,"--home",tmp,"--config-dir",tmp],{encoding:"utf8"});
    assert.equal(r.status,0,r.stderr);
    assert.match(r.stdout,/settings: unchanged/);
    assert.deepEqual(fs.readFileSync(live),bytes);
    assert.equal(fs.statSync(live).mtimeMs,mtime);
    assert.equal(fs.existsSync(path.join(tmp,"backups")),false);
  } finally {fs.rmSync(tmp,{recursive:true,force:true});}
});
test("added hooks keep desired's grouping and order", () => {
  const h = (command) => ({ type: "command", command });
  const g = (cmds, matcher) => ({
    ...(matcher === undefined ? {} : { matcher }),
    hooks: cmds.map(h),
  });
  // wm after #484: a new matcher-less group ahead of an existing matcher-less one.
  const before = { SessionStart: [g(["echo a"]), g(["echo b"], "startup|resume")] };
  const desired = {
    SessionStart: [g(["echo new"]), g(["echo a"]), g(["echo b"], "startup|resume")],
  };
  const r = apply({ hooks: desired }, { hooks: before }, { hooks: before });
  assert.equal(r.changes.length, 1);
  assert.deepEqual(r.result.hooks, desired);
  // Settled: a second run changes nothing.
  assert.equal(apply({ hooks: desired }, r.nextBase, r.result).changes.length, 0);
  // A new group after its neighbour, and live's own groups stay where they are.
  const tail = { SessionStart: [g(["echo a"]), g(["echo new"])] };
  const mine = { SessionStart: [g(["echo mine"]), g(["echo a"])] };
  assert.deepEqual(
    apply({ hooks: tail }, { hooks: { SessionStart: [g(["echo a"])] } }, { hooks: mine })
      .result.hooks,
    { SessionStart: [g(["echo mine"]), g(["echo a"]), g(["echo new"])] },
  );
  // Joining a group live already has: between its desired neighbours.
  const joined = { PostToolUse: [g(["echo x", "echo new", "echo z"], "Bash")] };
  const partial = { PostToolUse: [g(["echo x", "echo z"], "Bash")] };
  assert.deepEqual(
    apply({ hooks: joined }, { hooks: partial }, { hooks: partial }).result.hooks,
    joined,
  );
  // Two new hooks of one new group land together, in desired's order.
  const pair = { Stop: [g(["echo p", "echo q"]), g(["echo old"])] };
  const old = { Stop: [g(["echo old"])] };
  assert.deepEqual(
    apply({ hooks: pair }, { hooks: old }, { hooks: old }).result.hooks,
    pair,
  );
  // An event live lacks entirely still gets desired's groups.
  assert.deepEqual(apply({ hooks: pair }, {}, {}).result.hooks, pair);
});

// ---- ./setup --sync: the member gate, the trigger and the shown result ----------------------
const { gateHash } = require("../../lib/settings-apply");
// A fixture checkout holding the hook, the library, a sync.sh and a setup that log their calls.
function syncFixture() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "settings-sync-"));
  const root = path.join(tmp, "root"),
    cfg = path.join(tmp, "cfg"),
    home = path.join(tmp, "home");
  fs.mkdirSync(path.join(root, "hooks/SessionStart"), { recursive: true });
  fs.mkdirSync(path.join(root, "hooks/lib"));
  fs.mkdirSync(path.join(root, "lib"));
  fs.mkdirSync(path.join(cfg, ".hov-stack"), { recursive: true });
  fs.mkdirSync(home);
  fs.copyFileSync(
    path.resolve(__dirname, "../lib/hook-output.js"),
    path.join(root, "hooks/lib/hook-output.js"),
  );
  fs.copyFileSync(
    path.resolve(__dirname, "../SessionStart/settings-apply.js"),
    path.join(root, "hooks/SessionStart/settings-apply.js"),
  );
  fs.copyFileSync(
    path.resolve(__dirname, "../../lib/settings-apply.js"),
    path.join(root, "lib/settings-apply.js"),
  );
  fs.writeFileSync(path.join(cfg, "settings.json"), "{}");
  fs.symlinkSync(path.join(root, "hooks"), path.join(cfg, "hooks"));
  const log = path.join(tmp, "calls");
  fs.writeFileSync(
    path.join(root, "sync.sh"),
    '#!/bin/bash\nprintf "sync.sh %s|%s\\n" "$*" "$CLAUDE_HOME" >> "$FIXTURE_LOG"\nprintf "settings: unchanged\\n"\n',
  );
  fs.writeFileSync(
    path.join(root, "setup"),
    '#!/bin/bash\nprintf "setup %s|%s|%s\\n" "$*" "$CLAUDE_CONFIG_DIR" "$HOV_SYNC_LOCK_WAIT" >> "$FIXTURE_LOG"\n[ -z "$FIXTURE_SYNC" ] || printf "sync: %s\\n" "$FIXTURE_SYNC"\n[ -z "$FIXTURE_RESULT" ] || printf "1700000000\\t%s\\n" "$FIXTURE_RESULT" > "$CLAUDE_CONFIG_DIR/.hov-stack/sync-result"\nexit "${FIXTURE_RC:-0}"\n',
  );
  const env = {
    ...process.env,
    HOME: home,
    CLAUDE_HOME: cfg,
    HOV_STACK_OVERLAY: path.join(tmp, "overlay"),
    HOV_UPDATE: "off",
    FIXTURE_LOG: log,
    FIXTURE_SYNC: "",
    FIXTURE_RESULT: "",
  };
  delete env.XDG_CONFIG_HOME;
  delete env.HOV_SYNC_INTERVAL;
  const run = (extra = {}) =>
    spawnSync(
      process.execPath,
      [path.join(root, "hooks/SessionStart/settings-apply.js")],
      { env: { ...env, ...extra }, encoding: "utf8", timeout: 5000 },
    );
  const state = (f) => path.join(cfg, ".hov-stack", f);
  const calls = () => (fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "");
  const quiet = () => fs.writeFileSync(state("settings-apply.stamp"), gateHash({ cfg, home, env }));
  const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  const waitFor = (pred, ms = 4000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (pred()) return true;
      sleep(25);
    }
    return pred();
  };
  const settle = () => sleep(400);
  const forget = () => fs.rmSync(log, { force: true });
  return { tmp, root, cfg, home, env, run, state, calls, quiet, waitFor, settle, forget };
}
test("gate: a member install (setup's record) merges through setup --sync --no-pull; an owner host and a host with no record are unchanged", () => {
  const f = syncFixture();
  try {
    const { run, calls, state } = f;
    // Member: setup's record, no sync.sh record.
    fs.writeFileSync(state("setup-settings-base.json"), "{}");
    assert.equal(run({ FIXTURE_SYNC: "current: at abc1234; nothing to merge into settings.json" }).stdout, "");
    assert.equal(calls(), `setup --sync --no-pull|${f.cfg}|0\n`);
    f.forget();
    // It speaks when it merged changes, or failed or was blocked; not otherwise.
    assert.match(
      run({ FIXTURE_SYNC: "current: at abc1234; merged 2 change(s) into settings.json" }).stdout,
      /^\[settings-apply\] sync: current: at abc1234; merged 2 change\(s\) into settings.json\n$/,
    );
    assert.match(
      run({ FIXTURE_SYNC: "failed: the merge did not finish", FIXTURE_RC: "1" }).stdout,
      /^\[settings-apply\] sync: failed:/,
    );
    assert.match(run({ FIXTURE_SYNC: "blocked: no record", FIXTURE_RC: "1" }).stdout, /sync: blocked:/);
    assert.equal(run({ FIXTURE_SYNC: "skipped (another sync is running, pid 7)" }).stdout, "");
    assert.match(run({ FIXTURE_RC: "1" }).stdout, /apply did not finish.*setup --sync --no-pull shows why/);
    // The stamp is setup's to write: nothing in the hook wrote one, and sync.sh was never asked.
    assert.equal(fs.existsSync(state("settings-apply.stamp")), false);
    assert.equal(calls().includes("sync.sh"), false);
    // Owner: sync.sh's record wins over setup's, exactly as before.
    f.forget();
    fs.writeFileSync(state("settings-base.json"), "{}");
    run();
    assert.equal(calls(), `sync.sh apply-settings --quiet|${f.cfg}\n`);
    // Neither record: today's call.
    f.forget();
    fs.rmSync(state("settings-base.json"));
    fs.rmSync(state("setup-settings-base.json"));
    run();
    assert.equal(calls(), `sync.sh apply-settings --quiet|${f.cfg}\n`);
    // A member install whose checkout has no setup file falls back to sync.sh's stamping call.
    f.forget();
    fs.writeFileSync(state("setup-settings-base.json"), "{}");
    fs.rmSync(path.join(f.root, "setup"));
    run();
    assert.equal(calls(), `sync.sh apply-settings --quiet|${f.cfg}\n`);
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});
test("gate: the inputs hash covers setup's record, and the CLI form writes the stamp the hook compares with", () => {
  const f = syncFixture();
  try {
    fs.writeFileSync(f.state("setup-settings-base.json"), "{}");
    f.quiet();
    assert.equal(f.run().stdout, "");
    assert.equal(f.calls(), "");
    // Planted negative: the record changes (a merge ran elsewhere) and the same stamp no longer matches.
    fs.writeFileSync(f.state("setup-settings-base.json"), '{"a":1}');
    f.run();
    assert.equal(f.calls(), `setup --sync --no-pull|${f.cfg}|0\n`);
    f.forget();
    const w = spawnSync(
      process.execPath,
      [path.join(f.root, "lib/settings-apply.js"), "--write-gate-stamp", "--config-dir", f.cfg],
      { env: f.env, encoding: "utf8" },
    );
    assert.equal(w.status, 0, w.stderr);
    assert.equal(
      fs.readFileSync(f.state("settings-apply.stamp"), "utf8"),
      gateHash({ cfg: f.cfg, home: f.home, env: f.env }) + "\n",
    );
    assert.equal(f.run().stdout, "");
    assert.equal(f.calls(), "");
    // Misuse of the CLI form fails and writes nothing.
    fs.rmSync(f.state("settings-apply.stamp"));
    const bad = spawnSync(
      process.execPath,
      [path.join(f.root, "lib/settings-apply.js"), "--write-gate-stamp"],
      { env: f.env, encoding: "utf8" },
    );
    assert.notEqual(bad.status, 0);
    assert.equal(fs.existsSync(f.state("settings-apply.stamp")), false);
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});
test("trigger: setup --sync starts detached once per interval, never with HOV_UPDATE=off or without a record", () => {
  const f = syncFixture();
  try {
    const { run, calls, state, waitFor, settle } = f;
    f.quiet();
    const lines = () => calls().split("\n").filter(Boolean);
    const on = { HOV_UPDATE: "", HOV_SYNC_INTERVAL: "3600" };
    // Planted negative: no record, no spawn (--sync would only refuse; the adopt notice is another hook's).
    run(on);
    settle();
    assert.deepEqual(lines(), []);
    assert.equal(fs.existsSync(state("sync-started")), false);
    fs.writeFileSync(state("setup-settings-base.json"), "{}");
    f.quiet();
    // Planted negative: HOV_UPDATE=off, no spawn.
    run({ ...on, HOV_UPDATE: "off" });
    settle();
    assert.deepEqual(lines(), []);
    assert.equal(fs.existsSync(state("sync-started")), false);
    // First run: it spawns, detached, with the lock wait at 0 and the config dir named.
    assert.equal(run(on).stdout, "");
    assert.ok(waitFor(() => lines().length === 1), "the detached setup --sync never ran");
    assert.deepEqual(lines(), [`setup --sync|${f.cfg}|0`]);
    assert.ok(fs.existsSync(state("sync-started")));
    assert.ok(fs.existsSync(state("sync.log")));
    // Second run inside the interval: nothing.
    run(on);
    settle();
    assert.equal(lines().length, 1);
    // The interval passed: it spawns again, and sync.log is truncated each run.
    fs.writeFileSync(state("sync.log"), "OLD LOG\n");
    const agePast = (secs) => {
      const t = new Date(Date.now() - secs * 1000);
      fs.utimesSync(state("sync-started"), t, t);
    };
    agePast(2 * 3600);
    run({ ...on, FIXTURE_SYNC: "current: fresh" });
    assert.ok(waitFor(() => lines().length === 2), "it did not spawn after the interval passed");
    assert.ok(waitFor(() => fs.readFileSync(state("sync.log"), "utf8").includes("sync: current: fresh")));
    assert.equal(fs.readFileSync(state("sync.log"), "utf8").includes("OLD LOG"), false);
    // The default interval: a day for a member, 5 minutes where sync.sh keeps the record.
    const defaults = { HOV_UPDATE: "", HOV_SYNC_INTERVAL: undefined };
    agePast(7200);
    run(defaults);
    settle();
    assert.equal(lines().length, 2, "a member synced again after two hours");
    agePast(2 * 86400);
    run(defaults);
    assert.ok(waitFor(() => lines().length === 3), "a member did not sync after two days");
    fs.writeFileSync(state("settings-base.json"), "{}");
    f.quiet();
    agePast(120);
    run(defaults);
    settle();
    assert.equal(lines().length, 3, "an owner host synced again after two minutes");
    agePast(900);
    run(defaults);
    assert.ok(waitFor(() => lines().length === 4), "an owner host did not sync after 15 minutes");
    // A missing setup file never throws or blocks the hook.
    fs.rmSync(path.join(f.root, "setup"));
    agePast(900);
    const r = run(defaults);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, "");
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});
test("result: the last background result is shown once, claimed by rename, deduplicated, and held back while the lock exists", () => {
  const f = syncFixture();
  try {
    const { run, state } = f;
    f.quiet();
    const put = (kind, text) => fs.writeFileSync(state("sync-result"), `1700000000\t${kind}\t${text}\n`);
    put("blocked", "hov-stack not updated: HEAD is detached");
    // Planted negative: while a sync holds its lock the result is neither shown nor claimed.
    fs.mkdirSync(state("sync.lock"));
    assert.equal(run().stdout, "");
    assert.ok(fs.existsSync(state("sync-result")));
    fs.rmdirSync(state("sync.lock"));
    // First session shows it and claims it.
    assert.equal(run().stdout, "[hov-stack] hov-stack not updated: HEAD is detached\n");
    assert.equal(fs.existsSync(state("sync-result")), false);
    assert.ok(fs.existsSync(state("sync-result.shown")));
    // Second session: nothing left to show.
    assert.equal(run().stdout, "");
    // Planted negative: the same state and text again (a standing refusal) is claimed and not repeated.
    put("blocked", "hov-stack not updated: HEAD is detached");
    assert.equal(run().stdout, "");
    assert.equal(fs.existsSync(state("sync-result")), false);
    // A different text is shown.
    put("blocked", "hov-stack not updated: no upstream");
    assert.equal(run().stdout, "[hov-stack] hov-stack not updated: no upstream\n");
    // `current` is quiet, but resets what a later refusal is compared with.
    put("current", "hov-stack is up to date at abc1234; nothing to merge into settings.json");
    assert.equal(run().stdout, "");
    put("blocked", "hov-stack not updated: no upstream");
    assert.equal(run().stdout, "[hov-stack] hov-stack not updated: no upstream\n");
    put("moved", "hov-stack updated a -> b (2 commit(s)); merged 1 change(s) into settings.json");
    assert.match(run().stdout, /^\[hov-stack\] hov-stack updated a -> b/);
    put("notice", "hov-stack is 3 commit(s) behind origin/main: ./setup --update brings it current");
    assert.match(run().stdout, /^\[hov-stack\] hov-stack is 3 commit/);
    put("failed", "hov-stack not updated: could not fetch origin (offline?)");
    assert.match(run().stdout, /could not fetch origin/);
    // A `moving` result left by a run that died (no lock) is shown, saying so.
    put("moving", "hov-stack updated a -> b; merging");
    assert.match(run().stdout, /^\[hov-stack\] hov-stack updated a -> b; merging; that sync did not finish/);
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});

test("result: a newer result a sync writes while the hook reads one is kept for the next session, not marked shown", () => {
  const f = syncFixture();
  try {
    const { run, state } = f;
    f.quiet();
    // The race made deterministic: on the hook's first read of the pending result (sync-result
    // itself, or its claimed name), this preload lands a newer failure the way setup writes one
    // (a temp file renamed over sync-result), then hands the hook the bytes it read.
    const preload = path.join(f.tmp, "race-preload.js");
    fs.writeFileSync(
      preload,
      `const fs = require("fs"), path = require("path");
const real = fs.readFileSync;
let done = false;
fs.readFileSync = function (p, ...rest) {
  const out = real.call(fs, p, ...rest);
  const base = path.basename(String(p));
  if (!done && (base === "sync-result" || base.startsWith("sync-result.claim."))) {
    done = true;
    const tmp = path.join(path.dirname(String(p)), ".sync-result.race");
    fs.writeFileSync(tmp, "1700000001\\tfailed\\thov-stack not updated: could not fetch origin (offline?)\\n");
    fs.renameSync(tmp, path.join(path.dirname(String(p)), "sync-result"));
    fs.writeFileSync(process.env.RACE_MARK, "");
  }
  return out;
};
`,
    );
    const mark = path.join(f.tmp, "race.done");
    fs.writeFileSync(state("sync-result"), "1700000000\tcurrent\thov-stack is up to date at abc1234\n");
    const r1 = run({ NODE_OPTIONS: `--require ${preload}`, RACE_MARK: mark });
    assert.ok(fs.existsSync(mark), "the preload never fired, so nothing was tested");
    // The session that took the `current` result says nothing (current is quiet)...
    assert.equal(r1.stdout, "");
    // ...and the failure written meanwhile is still pending, not swallowed into .shown.
    assert.ok(fs.existsSync(state("sync-result")), "the newer failure was marked shown unread");
    assert.match(fs.readFileSync(state("sync-result"), "utf8"), /\tfailed\t/);
    assert.match(fs.readFileSync(state("sync-result.shown"), "utf8"), /\tcurrent\t/, "shown is not the result that was handled");
    assert.deepEqual(fs.readdirSync(state("")).filter((n) => n.startsWith("sync-result.claim.")), [], "a claim file was left behind");
    // The next session shows it.
    assert.equal(run().stdout, "[hov-stack] hov-stack not updated: could not fetch origin (offline?)\n");
    assert.equal(fs.existsSync(state("sync-result")), false);
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});

test("gate: a refusal from the member gate is claimed and shown once, not printed inline at every start", () => {
  const f = syncFixture();
  try {
    const { run, state } = f;
    fs.writeFileSync(state("setup-settings-base.json"), "{}");
    const refuse = { FIXTURE_SYNC: "blocked: not moved", FIXTURE_RESULT: "blocked\thov-stack not updated: not moved", FIXTURE_RC: "1" };
    // The gate runs at every start (no stamp), and its refusal reads once.
    assert.equal(run(refuse).stdout, "[hov-stack] hov-stack not updated: not moved\n");
    assert.equal(fs.existsSync(state("sync-result")), false, "the result was left unclaimed");
    // Planted negative: the same refusal again is not printed again (inline printing would).
    assert.equal(run(refuse).stdout, "");
    // A different one is.
    const other = { ...refuse, FIXTURE_SYNC: "failed: x", FIXTURE_RESULT: "failed\thov-stack not updated: x" };
    assert.equal(run(other).stdout, "[hov-stack] hov-stack not updated: x\n");
    // A warning speaks too.
    const warn = { FIXTURE_SYNC: "warning: held", FIXTURE_RESULT: "warning\thov-stack is at abc (no pull); the merge left something for you: applied 1; 1 hook(s) skipped (target missing)" };
    assert.match(run(warn).stdout, /^\[hov-stack\] hov-stack is at abc \(no pull\); the merge left something for you: applied 1; 1 hook\(s\) skipped/);
    // A change made is still its own line, and the result (current) stays quiet.
    const merged = { FIXTURE_SYNC: "current: at abc1234; merged 2 change(s) into settings.json", FIXTURE_RESULT: "current\tat abc1234; merged 2 change(s) into settings.json" };
    assert.equal(run(merged).stdout, "[settings-apply] sync: current: at abc1234; merged 2 change(s) into settings.json\n");
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});
test("lock: a dead or old lock counts as absent for the shown result and the trigger; a live one holds both back", () => {
  const f = syncFixture();
  try {
    const { run, state, calls, waitFor, settle } = f;
    f.quiet();
    fs.writeFileSync(state("setup-settings-base.json"), "{}");
    f.quiet();
    const lock = state("sync.lock");
    const put = (text) => fs.writeFileSync(state("sync-result"), `1700000000\tblocked\t${text}\n`);
    const mklock = (pid) => {
      fs.mkdirSync(lock);
      if (pid !== null) fs.writeFileSync(path.join(lock, "pid"), `${pid}\n`);
    };
    // A pid that is certainly dead.
    const dead = (() => {
      const r = spawnSync(process.execPath, ["-e", "process.stdout.write(String(process.pid))"], { encoding: "utf8" });
      return Number(r.stdout);
    })();
    // Live holder (this test process): result held back, trigger does not spawn or stamp.
    const on = { HOV_UPDATE: "", HOV_SYNC_INTERVAL: "0" };
    put("one");
    mklock(process.pid);
    assert.equal(run(on).stdout, "");
    settle();
    assert.equal(calls(), "", "a trigger spawned while a sync held the lock");
    assert.equal(fs.existsSync(state("sync-started")), false);
    assert.equal(fs.existsSync(state("sync.log")), false);
    assert.ok(fs.existsSync(state("sync-result")));
    fs.rmSync(lock, { recursive: true });
    // Planted negatives: a dead holder's lock does not hide the result or stop the trigger.
    mklock(dead);
    assert.equal(run(on).stdout, "[hov-stack] one\n");
    assert.ok(waitFor(() => calls().includes("setup --sync|")), "the trigger did not run past a dead holder's lock");
    fs.rmSync(lock, { recursive: true, force: true });
    // An old lock directory with a live pid is a hung run's leftover: absent too.
    f.forget();
    put("two");
    mklock(process.pid);
    const old = new Date(Date.now() - 20 * 60 * 1000);
    fs.utimesSync(lock, old, old);
    assert.equal(run(on).stdout, "[hov-stack] two\n");
    // The trigger runs past it too. Waiting for the detached stub also keeps it from writing
    // into the fixture while the cleanup below removes it (ENOTEMPTY under load).
    assert.ok(waitFor(() => calls().includes("setup --sync|")), "the trigger did not run past an old lock");
  } finally {
    fs.rmSync(f.tmp, { recursive: true, force: true });
  }
});
