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
    before = hash(); args.env.DOTFILES_ROLE="satellite"; assert.notEqual(hash(),before);
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
