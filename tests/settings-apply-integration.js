"use strict";
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawnSync, spawn } = require("node:child_process");
const tree = process.env.SETTINGS_APPLY_TREE;
const sourceSettings = fs.readFileSync(path.join(tree, "settings.json"));
let pass = 0,
  fail = 0;
function fixture() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "settings-apply-test-"));
  const root = path.join(tmp, "src"),
    home = path.join(tmp, "home"),
    cfg = path.join(home, ".claude");
  fs.mkdirSync(root);
  fs.mkdirSync(cfg, { recursive: true });
  for (const f of [
    "sync.sh",
    "settings.json",
    "lib",
    "scripts/lib",
    "hooks",
    "mods",
    "managed-settings.json",
  ])
    fs.cpSync(path.join(tree, f), path.join(root, f), { recursive: true });
  fs.writeFileSync(
    path.join(root, "hosts.tsv"),
    os.hostname().split(".")[0] + "\tworkstation\n",
  );
  fs.symlinkSync(path.join(root, "hooks"), path.join(cfg, "hooks"));
  fs.symlinkSync(path.join(root, "mods"), path.join(cfg, "mods"));
  fs.writeFileSync(path.join(cfg,"claude-env.sh"), "# fixture env\n");
  fs.mkdirSync(path.join(home, ".local/lib/dcg/v0.16.0"), { recursive: true });
  fs.mkdirSync(path.join(home, ".local/bin"), { recursive: true });
  const dcg = path.join(home, ".local/lib/dcg/v0.16.0/dcg");
  fs.writeFileSync(dcg, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  fs.symlinkSync(dcg, path.join(home, ".local/bin/dcg"));
  const env = {
    ...process.env,
    HOME: home,
    CLAUDE_HOME: cfg,
    HOV_STACK_OVERLAY: path.join(tmp, "overlay"),
    DOTFILES_ROLE_FILE: path.join(root, "hosts.tsv"),
    CLAUDE_SYNC_MANAGED_LOCK: path.join(root, "managed-settings.json"),
    CLAUDE_WINDOWS_HOME: path.join(tmp, "windows-absent"),
  };
  delete env.XDG_CONFIG_HOME;
  delete env.DOTFILES_ROLE;
  const tracked = path.join(root, "settings.json"),
    live = path.join(cfg, "settings.json");
  const original = fs.readFileSync(tracked);
  assert.deepEqual(
    original,
    sourceSettings,
    "the copied template must come from the selected fixture tree",
  );
  const read = (f) => JSON.parse(fs.readFileSync(f));
  const write = (f, v) =>
    fs.writeFileSync(f, JSON.stringify(v, null, 2) + "\n");
  const run = (args, extra = {}) =>
    spawnSync("bash", [path.join(root, "sync.sh"), ...args], {
      env: { ...env, ...extra },
      encoding: "utf8",
      timeout: 30000,
      stdio: ["ignore", "pipe", "pipe"],
    });
  const apply = (...args) => {
    const r = run(["apply-settings", ...args]);
    assert.equal(r.status, 0, r.stderr + r.stdout);
    return r.stdout;
  };
  const seed = spawnSync(
    "node",
    [path.join(root, "lib/settings-seed.js"), tracked, live, cfg, home, dcg],
    { env: { ...env, SETTINGS_SEED_ALL_KEYS: "1" }, encoding: "utf8" },
  );
  assert.equal(seed.status, 0, seed.stderr);
  const edit = (f, fn) => {
    const v = read(f);
    fn(v);
    write(f, v);
  };
  const backups = () =>
    fs.existsSync(path.join(cfg, "backups"))
      ? fs
          .readdirSync(path.join(cfg, "backups"))
          .filter((f) => f.startsWith("settings-apply-"))
      : [];
  return {
    tmp,
    root,
    home,
    cfg,
    env,
    tracked,
    live,
    read,
    write,
    edit,
    run,
    apply,
    backups,
    original,
  };
}
async function test(name, fn) {
  if (process.env.SETTINGS_APPLY_CASE && !name.includes(process.env.SETTINGS_APPLY_CASE)) return;
  let f;
  try {
    f = fixture();
    await fn(f);
    pass++;
    console.log("PASS " + name);
  } catch (e) {
    fail++;
    console.log("FAIL " + name + ": " + e.message);
  } finally {
    if (f) fs.rmSync(f.tmp, { recursive: true, force: true });
  }
}
const hook = () => ({
  hooks: [
    {
      type: "command",
      command:
        '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/SessionStart/planted.js"',
      timeout: 20,
    },
  ],
});
const addHook = (f) =>
  f.edit(f.tracked, (v) => v.hooks.SessionStart.push(hook()));
const target = (f) =>
  fs.writeFileSync(
    path.join(f.root, "hooks/SessionStart/planted.js"),
    "process.exit(0);\n",
  );
(async () => {

  await test("T1 plan writes nothing, real apply lands", (f) => {
    f.apply();
    f.edit(f.tracked, v => v.fixturePlan = true);
    const files = [f.live, path.join(f.cfg,".hov-stack/settings-base.json"), path.join(f.cfg,".hov-stack/settings-apply.stamp")];
    const before = files.map(file => [fs.readFileSync(file),fs.statSync(file).mtimeMs]);
    const backups = f.backups();
    f.apply("--plan");
    files.forEach((file,i) => {
      assert.deepEqual(fs.readFileSync(file),before[i][0]);
      assert.equal(fs.statSync(file).mtimeMs,before[i][1]);
    });
    assert.deepEqual(f.backups(),backups);
    f.apply();
    assert.equal(f.read(f.live).fixturePlan,true);
  });
  await test("T2 backup holds old live; T6 exact mode under umask", (f) => {
    f.apply();
    fs.chmodSync(f.live,0o664);
    const old = fs.readFileSync(f.live), prior = f.backups();
    f.edit(f.tracked,v => v.fixtureBackup = true);
    f.apply();
    const added = f.backups().filter(x => !prior.includes(x));
    assert.equal(added.length,1);
    assert.deepEqual(fs.readFileSync(path.join(f.cfg,"backups",added[0],"settings.json")),old);
    assert.equal(fs.statSync(f.live).mode & 0o777,0o664);
  });
  await test("T4 concurrent edit retries once and aborts twice without backups", (f) => {
    f.apply();
    f.edit(f.tracked,v => v.fixtureRace = true);
    const script = path.join(f.tmp,"race");
    const marker = path.join(f.tmp,"race-marker");
    fs.writeFileSync(script, '#!/usr/bin/env node\nconst fs=require("fs");const file=process.argv[2];if(process.env.RACE_ALWAYS || !fs.existsSync(process.env.RACE_MARKER)){const v=JSON.parse(fs.readFileSync(file));v.concurrent=(v.concurrent||0)+1;fs.writeFileSync(file,JSON.stringify(v));fs.writeFileSync(process.env.RACE_MARKER,"1");}\n', {mode:0o755});
    const extra = {HOV_SETTINGS_APPLY_TEST_BEFORE_RECHECK:script,RACE_MARKER:marker};
    let before = f.backups().length;
    let r = f.run(["apply-settings"],extra);
    assert.equal(r.status,0,r.stderr);
    assert.equal(f.read(f.live).fixtureRace,true);
    assert.equal(f.read(f.live).concurrent,1);
    assert.equal(f.backups().length,before+1);
    f.edit(f.tracked,v => v.fixtureRaceAgain = true);
    const base = fs.readFileSync(path.join(f.cfg,".hov-stack/settings-base.json"));
    before = f.backups().length;
    r = f.run(["apply-settings"],{...extra,RACE_ALWAYS:"1"});
    assert.equal(r.status,3,r.stderr);
    assert.equal(f.read(f.live).concurrent,3);
    assert.equal(f.read(f.live).fixtureRaceAgain,undefined);
    assert.deepEqual(fs.readFileSync(path.join(f.cfg,".hov-stack/settings-base.json")),base);
    assert.equal(f.backups().length,before);
  });
  await test("T6 corrupt base check reports engine failure", (f) => {
    f.apply();
    fs.writeFileSync(path.join(f.cfg,".hov-stack/settings-base.json"),"{");
    assert.match(f.run(["check"]).stdout,/DRIFT: settings.json apply check failed:/);
    f.write(path.join(f.cfg,".hov-stack/settings-base.json"),{});
    f.write(f.live,[]);
    assert.match(f.run(["check"]).stdout,/DRIFT: settings.json apply check failed:/);
    fs.unlinkSync(f.live);
    fs.symlinkSync(f.tracked,f.live);
    assert.match(f.run(["check"]).stdout,/DRIFT: settings.json apply check failed:/);
  });
  await test("T6 invalid mapped env skipped and retried", (f) => {
    f.apply();
    const baseFile = path.join(f.cfg,".hov-stack/settings-base.json");
    const previous = f.read(baseFile).env?.CLAUDE_ENV_FILE;
    const target = path.join(f.cfg,"fixture-env.sh");
    f.edit(f.tracked,v => v.env.CLAUDE_ENV_FILE = target);
    const live = f.read(f.live).env.CLAUDE_ENV_FILE;
    assert.match(f.apply(),/skipped env.CLAUDE_ENV_FILE/);
    assert.equal(f.read(f.live).env.CLAUDE_ENV_FILE,live);
    assert.equal(f.read(baseFile).env?.CLAUDE_ENV_FILE,previous);
    fs.writeFileSync(target,"# fixture");
    f.apply();
    assert.equal(f.read(f.live).env.CLAUDE_ENV_FILE,target);
  });
  await test("T6 role changes and deny drop wake backstop", (f) => {
    f.apply();
    const engine = require(path.join(f.root,"lib/settings-apply.js"));
    const args = {root:f.root,cfg:f.cfg,overlayDir:f.env.HOV_STACK_OVERLAY,dcgPath:path.join(f.home,".local/lib/dcg/v0.16.0/dcg"),env:f.env};
    const stamp = path.join(f.cfg,".hov-stack/settings-apply.stamp");
    assert.equal(fs.readFileSync(stamp,"utf8").trim(),engine.inputsHash(args));
    fs.appendFileSync(path.join(f.root,"hosts.tsv"),"# changed role roster\n");
    assert.notEqual(fs.readFileSync(stamp,"utf8").trim(),engine.inputsHash(args));
    f.apply();
    const entry = f.read(f.live).permissions.deny[0];
    f.edit(f.live,v => v.permissions.deny.shift());
    assert.notEqual(fs.readFileSync(stamp,"utf8").trim(),engine.inputsHash(args));
    const r = spawnSync("node",[path.join(f.root,"hooks/SessionStart/settings-apply.js")],{env:f.env,encoding:"utf8"});
    assert.equal(r.status,0);
    assert.ok(f.read(f.live).permissions.deny.includes(entry));
  });
  await test("T6 invalid plugin list kept out until manifest exists", (f) => {
    f.apply();
    const previous = f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS;
    const mod = path.join(f.cfg,"mods/fixture-mod");
    f.edit(f.tracked,v => v.env.CLAUDE_CODE_PLUGIN_DIRS=mod);
    assert.match(f.apply(),/skipped env.CLAUDE_CODE_PLUGIN_DIRS/);
    assert.equal(f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS,previous);
    fs.mkdirSync(path.join(mod,".claude-plugin"),{recursive:true});
    fs.writeFileSync(path.join(mod,".claude-plugin/plugin.json"),'{}');
    f.apply();
    assert.equal(f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS,mod);
    for (const value of ["",mod+"::"+mod,mod+"\n"+mod]) {
      f.edit(f.tracked,v => v.env.CLAUDE_CODE_PLUGIN_DIRS=value);
      assert.match(f.apply(),/skipped env.CLAUDE_CODE_PLUGIN_DIRS/);
      assert.equal(f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS,mod);
    }
  });
  await test("T6 overlay plugin-dirs appended after the tracked list", (f) => {
    // The fixture copies no Docker policy helper, so check would report that
    // drift on every run; a passing stub leaves only this case's findings.
    fs.writeFileSync(path.join(f.root,"scripts/docker-daemon-config.py"),"import sys\nsys.exit(0)\n");
    f.apply();
    const tracked = f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS;
    assert.match(tracked, /\/mods\/.*:.*\/mods\//, "the fixture's tracked list must be the mods");
    const engine = require(path.join(f.root,"lib/settings-apply.js"));
    const args = {root:f.root,cfg:f.cfg,overlayDir:f.env.HOV_STACK_OVERLAY,dcgPath:path.join(f.home,".local/lib/dcg/v0.16.0/dcg"),env:f.env};
    const stamp = path.join(f.cfg,".hov-stack/settings-apply.stamp");
    assert.equal(fs.readFileSync(stamp,"utf8").trim(),engine.inputsHash(args));
    const extra = path.join(f.tmp,"host-plugin");
    fs.mkdirSync(path.join(extra,".claude-plugin"),{recursive:true});
    fs.writeFileSync(path.join(extra,".claude-plugin/plugin.json"),'{"name":"host-plugin"}');
    fs.mkdirSync(f.env.HOV_STACK_OVERLAY,{recursive:true});
    const list = path.join(f.env.HOV_STACK_OVERLAY,"plugin-dirs");
    fs.writeFileSync(list,`# this host's own plugins\n${extra}\n${tracked.split(":")[0]}\n`);
    // The session-start backstop re-applies when this file changes.
    assert.notEqual(fs.readFileSync(stamp,"utf8").trim(),engine.inputsHash(args));
    f.apply();
    assert.equal(f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS,tracked+":"+extra);
    const clean = f.run(["check"]);
    assert.doesNotMatch(clean.stdout,/^DRIFT: settings.json/m);
    assert.equal(clean.status,0,clean.stdout);
    // PLANTED NEGATIVE: lines that cannot be loaded are left out, check names
    // them and exits non-zero, and the loadable list is still written.
    const bare = path.join(f.tmp,"no-manifest");
    fs.mkdirSync(bare);
    fs.appendFileSync(list,`${bare}\n${extra}:${bare}\n`);
    f.apply();
    assert.equal(f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS,tracked+":"+extra);
    const bad = f.run(["check"]);
    assert.notEqual(bad.status,0,bad.stdout);
    const report = bad.stdout;
    assert.match(report,/plugin-dirs names \S*no-manifest, which is left out of CLAUDE_CODE_PLUGIN_DIRS: it has no \.claude-plugin\/plugin\.json/);
    assert.match(report,/plugin-dirs names \S*host-plugin:\S*no-manifest, which is left out of CLAUDE_CODE_PLUGIN_DIRS: it contains a colon/);
    // Deleting the file returns the live list to the tracked one.
    fs.unlinkSync(list);
    f.apply();
    assert.equal(f.read(f.live).env.CLAUDE_CODE_PLUGIN_DIRS,tracked);
  });
  await test("T6 seed bad rev exits 2 for every role", (f) => {
    for (const role of ["workstation","satellite","member",""]) {
      fs.writeFileSync(path.join(f.root,"hosts.tsv"),role ? os.hostname().split(".")[0]+"	"+role+"\n" : "");
      const r = f.run(["apply-settings","--seed-base","missing-fixture-rev"]);
      assert.equal(r.status,2);
      assert.match(r.stderr,/invalid seed revision/);
    }
  });
  await test("1 new hook without a reconciler", (f) => {
    f.apply();
    target(f);
    addHook(f);
    f.apply();
    assert.ok(
      JSON.stringify(f.read(f.live).hooks).includes(
        "$HOME/.claude/hooks/SessionStart/planted.js",
      ),
    );
  });
  await test("2 deny removal held repeatedly and shown by check", (f) => {
    f.apply();
    const entry = f.read(f.tracked).permissions.deny[0];
    f.edit(f.tracked, (v) => v.permissions.deny.shift());
    f.apply();
    assert.ok(f.read(f.live).permissions.deny.includes(entry));
    assert.match(f.apply("--plan"), /held permissions.deny/);
    assert.match(f.run(["check"]).stdout, /removals from deny/);
    assert.match(f.apply(), /held permissions.deny/);
    f.edit(
      f.live,
      (v) =>
        (v.permissions.deny = v.permissions.deny.filter((x) => x !== entry)),
    );
    assert.doesNotMatch(f.apply(), /held permissions.deny/);
  });
  await test("3 hook removal", (f) => {
    target(f);
    addHook(f);
    f.apply();
    f.edit(f.tracked, (v) => v.hooks.SessionStart.pop());
    f.apply();
    assert.ok(!JSON.stringify(f.read(f.live).hooks).includes("planted.js"));
  });
  await test("4 live edits survive unrelated repo change", (f) => {
    f.apply();
    f.edit(f.live, (v) => {
      v.effortLevel = "fixture-effort";
      v.model = "fixture-model";
      v.statusLine = { command: "fixture-status" };
      v.permissions.allow.push("Bash(fixture-local:*)");
    });
    f.edit(f.tracked, (v) => (v.fixtureNew = true));
    f.apply();
    const v = f.read(f.live);
    assert.equal(v.fixtureNew, true);
    assert.equal(v.effortLevel, "fixture-effort");
    assert.equal(v.model, "fixture-model");
    assert.deepEqual(v.statusLine, { command: "fixture-status" });
    assert.ok(v.permissions.allow.includes("Bash(fixture-local:*)"));
  });
  await test("5 conflict retained until resolved", (f) => {
    f.apply();
    f.edit(f.tracked, (v) => (v.env.BASH_MAX_TIMEOUT_MS = "fixture-repo"));
    f.edit(f.live, (v) => (v.env.BASH_MAX_TIMEOUT_MS = "fixture-live"));
    const output = f.apply() + f.apply("--plan") + f.run(["check"]).stdout;
    assert.match(output, /1 conflict/);
    assert.doesNotMatch(output, /fixture-repo|fixture-live/);
    assert.match(f.apply(), /1 conflict/);
    assert.equal(f.read(f.live).env.BASH_MAX_TIMEOUT_MS, "fixture-live");
    assert.match(
      f.run(["check"]).stdout,
      /conflict at env.BASH_MAX_TIMEOUT_MS/,
    );
    f.edit(f.live, (v) => (v.env.BASH_MAX_TIMEOUT_MS = "fixture-repo"));
    assert.doesNotMatch(f.apply(), /conflict/);
  });
  await test("6 unchanged bytes mtime and backups", (f) => {
    f.apply();
    const bytes = fs.readFileSync(f.live),
      mtime = fs.statSync(f.live).mtimeMs,
      n = f.backups().length;
    f.apply();
    assert.deepEqual(fs.readFileSync(f.live), bytes);
    assert.equal(fs.statSync(f.live).mtimeMs, mtime);
    assert.equal(f.backups().length, n);
  });
  await test("7 hook spelling equivalence", (f) => {
    f.apply();
    f.edit(f.live, (v) => {
      for (const groups of Object.values(v.hooks))
        for (const g of groups)
          for (const h of g.hooks)
            h.command = h.command.replaceAll(
              f.home + "/.claude",
              "$HOME/.claude",
            );
    });
    const bytes = fs.readFileSync(f.live);
    f.apply();
    assert.deepEqual(fs.readFileSync(f.live), bytes);
  });
  await test("8 concurrent applies serialize", async (f) => {
    f.apply();
    f.edit(f.tracked, (v) => (v.fixtureConcurrent = true));
    const before = f.backups().length;
    const run = () =>
      new Promise((resolve) => {
        const c = spawn(
          "bash",
          [path.join(f.root, "sync.sh"), "apply-settings"],
          { env: f.env, stdio: "ignore" },
        );
        c.on("exit", resolve);
      });
    assert.deepEqual(await Promise.all([run(), run()]), [0, 0]);
    assert.equal(f.backups().length, before + 1);
    assert.equal(f.read(f.live).fixtureConcurrent, true);
  });
  await test("9 permission drop push guard", (f) => {
    f.edit(f.tracked, (v) =>
      v.permissions.allow.push("Bash(fixture-push-guard:*)"),
    );
    const r = f.run(["push"]);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr + r.stdout, /fixture-push-guard/);
    assert.doesNotMatch(
      f.run(["push"], { SYNC_ALLOW_PERMISSION_DROP: "1" }).stderr,
      /push refused: live settings.*fixture-push-guard/,
    );
  });
  await test("10 missing hook target reported and retried", (f) => {
    f.apply();
    addHook(f);
    assert.match(f.apply(), /hook\(s\) skipped/);
    assert.ok(!JSON.stringify(f.read(f.live)).includes("planted.js"));
    assert.match(f.run(["check"]).stdout, /hook in the repo has no target/);
    target(f);
    f.apply();
    assert.ok(JSON.stringify(f.read(f.live)).includes("planted.js"));
  });
  await test("deny re-add, secrets and private base permissions", (f) => {
    f.apply();
    const entry = f.read(f.tracked).permissions.deny[0];
    f.edit(f.live, (v) => {
      v.permissions.deny.shift();
      v.env.ANTHROPIC_AUTH_TOKEN = "fixture-auth-value";
      v.env.ANTHROPIC_CUSTOM_HEADERS = "fixture-header-value";
    });
    f.edit(f.tracked, (v) => (v.fixtureSecretTest = true));
    let output = "";
    for (const args of [
      ["apply-settings"],
      ["apply-settings", "--plan"],
      ["check"],
    ]) {
      const r = f.run(args);
      output += r.stdout + r.stderr;
      if (args[0] === "apply-settings") assert.equal(r.status, 0);
    }
    assert.doesNotMatch(output, /fixture-auth-value|fixture-header-value/);
    const base = path.join(f.cfg, ".hov-stack/settings-base.json");
    assert.doesNotMatch(
      fs.readFileSync(base, "utf8"),
      /ANTHROPIC_AUTH_TOKEN|ANTHROPIC_CUSTOM_HEADERS|fixture-auth-value|fixture-header-value/,
    );
    assert.equal(fs.statSync(base).mode & 0o777, 0o600);
    assert.equal(fs.statSync(path.dirname(base)).mode & 0o777, 0o700);
    assert.equal(
      f.read(f.live).env.ANTHROPIC_CUSTOM_HEADERS,
      "fixture-header-value",
    );
    assert.equal(f.read(f.live).env.ANTHROPIC_AUTH_TOKEN, "fixture-auth-value");
    assert.doesNotMatch(
      fs.readFileSync(
        path.join(f.cfg, ".hov-stack/settings-apply.stamp"),
        "utf8",
      ),
      /fixture-header-value|fixture-auth-value/,
    );
    assert.ok(f.read(f.live).permissions.deny.includes(entry));
  });
  await test("invalid JSON and symlink refuse without backup", (f) => {
    fs.writeFileSync(f.live, "{ invalid fixture JSON");
    assert.notEqual(f.run(["apply-settings"]).status, 0);
    assert.equal(fs.readFileSync(f.live, "utf8"), "{ invalid fixture JSON");
    f.write(f.live, []);
    assert.notEqual(f.run(["apply-settings"]).status, 0);
    fs.unlinkSync(f.live);
    fs.symlinkSync(f.tracked, f.live);
    assert.notEqual(f.run(["apply-settings"]).status, 0);
    assert.equal(f.backups().length, 0);
  });
  await test("undeclared role skips and plan still runs", (f) => {
    fs.writeFileSync(path.join(f.root, "hosts.tsv"), "");
    const before = fs.readFileSync(f.live);
    assert.match(f.apply(), /settings: skipped/);
    assert.ok(
      fs.existsSync(path.join(f.cfg, ".hov-stack/settings-apply.stamp")),
    );
    assert.deepEqual(fs.readFileSync(f.live), before);
    assert.match(f.apply("--plan"), /settings: plan/);
  });
  await test("seed-base previews without writes and bootstraps removals", (f) => {
    const git = (args) => {
      const r = spawnSync("git", ["-C", f.root, ...args], {
        encoding: "utf8",
        env: {
          ...f.env,
          GIT_AUTHOR_NAME: "Fixture",
          GIT_AUTHOR_EMAIL: "fixture@example.invalid",
          GIT_COMMITTER_NAME: "Fixture",
          GIT_COMMITTER_EMAIL: "fixture@example.invalid",
        },
      });
      assert.equal(r.status, 0, r.stderr);
      return r.stdout.trim();
    };
    git(["init", "-q"]);
    git(["add", "."]);
    git(["commit", "-qm", "first fixture"]);
    const first = git(["rev-parse", "HEAD"]);
    f.edit(f.tracked, (v) => (v.fixtureRemoved = "present"));
    f.edit(f.live, (v) => (v.fixtureRemoved = "present"));
    git(["add", "settings.json"]);
    git(["commit", "-qm", "seed fixture"]);
    const seed = git(["rev-parse", "HEAD"]);
    f.edit(f.tracked, (v) => delete v.fixtureRemoved);
    git(["add", "settings.json"]);
    git(["commit", "-qm", "removed fixture"]);
    assert.notEqual(first, seed);
    const bytes = fs.readFileSync(f.live);
    assert.match(
      f.apply("--plan", "--seed-base", seed),
      /remove fixtureRemoved/,
    );
    assert.deepEqual(fs.readFileSync(f.live), bytes);
    assert.equal(
      fs.existsSync(path.join(f.cfg, ".hov-stack/settings-base.json")),
      false,
    );
    assert.equal(f.backups().length, 0);
    fs.writeFileSync(path.join(f.root,"hosts.tsv"),os.hostname().split(".")[0]+"\tmember\n");
    const refused = f.run(["apply-settings","--seed-base",seed]);
    assert.equal(refused.status,2);
    assert.match(refused.stdout,/--seed-base needs a workstation or satellite host/);
    assert.equal(fs.existsSync(path.join(f.cfg,".hov-stack/settings-apply.stamp")),false);
    fs.writeFileSync(path.join(f.root,"hosts.tsv"),os.hostname().split(".")[0]+"\tworkstation\n");
    f.apply("--seed-base", seed);
    assert.equal(f.read(f.live).fixtureRemoved, undefined);
    assert.equal(f.run(["apply-settings", "--seed-base", seed]).status, 2);
  });
  await test("just-applied settings check and measured stdin-closed activation", (f) => {
    // Match the live file's approximate size when measuring the hash gate.
    f.edit(f.live, v => v.statusLine = {command:"fixture-status", padding:"x".repeat(Math.max(0, 50 * 1024 - fs.statSync(f.live).size))});
    f.apply();
    assert.doesNotMatch(f.run(["check"]).stdout, /^DRIFT: settings.json/m);
    const times = [];
    for (let i = 0; i < 20; i++) {
      const start = performance.now();
      const r = spawnSync(
        "node",
        [path.join(f.root, "hooks/SessionStart/settings-apply.js")],
        { env: f.env, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" },
      );
      times.push(performance.now() - start);
      assert.equal(r.status, 0);
      assert.equal(r.stdout, "");
    }
    times.sort((a, b) => a - b);
    const timed = () => {
      const start = performance.now();
      f.apply("--quiet");
      return performance.now() - start;
    };
    const unchanged = timed();
    f.edit(f.tracked, (v) => (v.fixtureTiming = true));
    const changed = timed();
    console.log(
      `TIMING hook 20 runs median=${((times[9] + times[10]) / 2).toFixed(2)}ms max=${times.at(-1).toFixed(2)}ms; apply unchanged=${unchanged.toFixed(2)}ms changed=${changed.toFixed(2)}ms (stdin closed)`,
    );
  });
  assert.deepEqual(
    fs.readFileSync(path.join(tree, "settings.json")),
    sourceSettings,
    "the suite must not modify the selected checkout",
  );
  await test("satellite apply reads the overlay URL and never writes loopback", (f) => {
    // The SessionStart settings hook runs the apply with Claude Code's env, which
    // carries no CCFLARE_URL_SATELLITE; the apply used to write the tracked
    // loopback over the satellite's live URL there.
    fs.writeFileSync(
      path.join(f.root, "hosts.tsv"),
      os.hostname().split(".")[0] + "\tsatellite\n",
    );
    fs.mkdirSync(f.env.HOV_STACK_OVERLAY, { recursive: true });
    const sat = "https://satellite-proxy.example.net",
      moved = "https://moved-proxy.example.net";
    const url = () => f.read(f.live).env.ANTHROPIC_BASE_URL;
    const apply = (value) => {
      const r = f.run(["apply-settings"], { CCFLARE_URL_SATELLITE: value });
      assert.equal(r.status, 0, r.stderr + r.stdout);
      return r.stdout;
    };
    f.edit(f.live, (v) => {
      v.env = { ...(v.env || {}), ANTHROPIC_BASE_URL: sat };
    });
    apply(sat);
    assert.equal(url(), sat);
    const out = apply("");
    assert.equal(url(), sat, "a satellite with no URL anywhere must keep live's URL\n" + out);
    assert.match(out, /skipped env\.ANTHROPIC_BASE_URL \(this host is a satellite/);
    fs.writeFileSync(
      path.join(f.env.HOV_STACK_OVERLAY, "env"),
      `CCFLARE_URL_SATELLITE=${moved}\n`,
    );
    apply("");
    assert.equal(url(), moved, "the overlay env's URL must reach live when none is exported");
  });
  await test("install reaches apply and writes its base", (f) => {
    fs.copyFileSync(
      path.join(tree, "claude-env.sh"),
      path.join(f.root, "claude-env.sh"),
    );
    fs.writeFileSync(
      path.join(f.root, "hosts.tsv"),
      os.hostname().split(".")[0] + "\tsatellite\n",
    );
    const bin = path.join(f.tmp, "test-bin");
    fs.mkdirSync(bin);
    for (const command of ["systemctl", "sudo"])
      fs.writeFileSync(path.join(bin, command), "#!/bin/sh\nexit 1\n", {
        mode: 0o755,
      });
    const r = f.run(["install"], {
      CCFLARE_URL_SATELLITE: "http://127.0.0.1:8788",
      PATH: bin + ":" + f.env.PATH,
      CLAUDE_SYNC_SKIP_HOOK_RECONCILE: "0",
      CLAUDE_SYNC_CLAUDE_BIN: path.join(f.tmp, "no-claude"),
      CLAUDE_SYNC_MANAGED_LOCK: path.join(f.tmp, "etc-managed/settings.json"),
      CLAUDE_SYNC_SYSTEM_SYS_DIR: path.join(f.tmp, "etc-systemd"),
    });
    assert.ok(
      fs.existsSync(path.join(f.cfg, ".hov-stack/settings-base.json")),
      r.stdout + r.stderr,
    );
    assert.match(r.stdout, /settings: /);
  });
  await test("install reports settings and papercut failures together", (f) => {
    fs.copyFileSync(
      path.join(tree, "claude-env.sh"),
      path.join(f.root, "claude-env.sh"),
    );
    fs.writeFileSync(
      path.join(f.root, "hosts.tsv"),
      os.hostname().split(".")[0] + "\tsatellite\n",
    );
    const bin = path.join(f.tmp, "test-bin");
    fs.mkdirSync(bin);
    for (const command of ["systemctl", "sudo", "claude"])
      fs.writeFileSync(path.join(bin, command), "#!/bin/sh\nexit 1\n", {
        mode: 0o755,
      });
    const sync = path.join(f.root,"sync.sh");
    fs.writeFileSync(sync, fs.readFileSync(sync,"utf8").replace("apply_settings || settings_apply_failed=1", "false || settings_apply_failed=1"));
    // The aggregation test needs a working user manager to reach closeout.
    fs.writeFileSync(path.join(bin,"systemctl"), '#!/bin/sh\ncase "$*" in *is-active*) echo inactive; exit 3 ;; esac\nexit 0\n', {mode:0o755});
    const r = f.run(["install"], {
      CCFLARE_URL_SATELLITE: "http://127.0.0.1:8788",
      PATH: bin + ":" + f.env.PATH,
      CLAUDE_SYNC_SKIP_HOOK_RECONCILE: "0",
      CLAUDE_SYNC_CLAUDE_BIN: path.join(bin, "claude"),
      CLAUDE_SYNC_MANAGED_LOCK: path.join(f.tmp, "etc-managed/settings.json"),
      CLAUDE_SYNC_SYSTEM_SYS_DIR: path.join(f.tmp, "etc-systemd"),
    });
    assert.notEqual(r.status,0);
    assert.match(r.stderr,/settings apply failed/);
    assert.match(r.stderr,/FAILED to install/);
  });
  console.log(`${pass} passed; ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
