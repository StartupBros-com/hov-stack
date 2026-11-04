import assert from "node:assert/strict";
import {
  chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const helper = join(here, "autoupdate.mjs");

// What `claude plugin marketplace add StartupBros-com/hov-stack` left in a scratch config dir
// on Claude Code 2.1.318: the settings.json entry without autoUpdate, and the known entry.
const HOV_SOURCE = { source: "github", repo: "StartupBros-com/hov-stack" };
const knownEntry = (source, extra = {}) => ({
  source,
  installLocation: "/cfg/plugins/marketplaces/x",
  lastUpdated: "2026-11-04T01:52:21.794Z",
  ...extra,
});

// A scratch HOME with a config dir. `settings` and `known` are written as given: an object as
// JSON with two-space indent and a final newline, a string as is, undefined as no file.
function withHome({ settings, known } = {}, run) {
  const dir = mkdtempSync(join(tmpdir(), "hov-autoupdate-"));
  const home = join(dir, "home");
  const cfg = join(home, ".claude");
  mkdirSync(join(cfg, "plugins"), { recursive: true });
  const put = (p, v) => {
    if (v === undefined) return;
    writeFileSync(p, typeof v === "string" ? v : JSON.stringify(v, null, 2) + "\n");
  };
  put(join(cfg, "settings.json"), settings);
  put(join(cfg, "plugins", "known_marketplaces.json"), known);
  try {
    return run({ dir, home, cfg, settingsPath: join(cfg, "settings.json") });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function helperRun(ctx, args, env = {}) {
  return spawnSync(process.execPath, [helper, ...args], {
    encoding: "utf8",
    env: { PATH: process.env.PATH, HOME: ctx.home, CLAUDE_CONFIG_DIR: ctx.cfg, ...env },
  });
}

const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));
const backups = (home) => {
  const root = join(home, ".hov-stack-backups");
  return existsSync(root) ? readdirSync(root).map((d) => join(root, d, ".claude", "settings.json")) : [];
};

const freshAdd = () => ({
  settings: { model: "x", extraKnownMarketplaces: { hov: { source: HOV_SOURCE } }, enabledPlugins: { "papercut@hov": true } },
  known: { hov: knownEntry(HOV_SOURCE) },
});

test("turns auto-update on in the entry Claude Code wrote, backs up the old file, and changes nothing else", () => {
  withHome(freshAdd(), (ctx) => {
    const before = readFileSync(ctx.settingsPath, "utf8");
    const r = helperRun(ctx, ["hov"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const after = readJson(ctx.settingsPath);
    assert.equal(after.extraKnownMarketplaces.hov.autoUpdate, true);
    const want = JSON.parse(before);
    want.extraKnownMarketplaces.hov.autoUpdate = true;
    assert.equal(readFileSync(ctx.settingsPath, "utf8"), JSON.stringify(want, null, 2) + "\n");
    assert.deepEqual(Object.keys(after), ["model", "extraKnownMarketplaces", "enabledPlugins"]);
    const saved = backups(ctx.home);
    assert.equal(saved.length, 1);
    assert.equal(readFileSync(saved[0], "utf8"), before, "the backup is not the old file byte for byte");
    assert.match(r.stdout, new RegExp(`^hov: auto-update turned on in ${ctx.settingsPath} \\(the old file is at ${saved[0]}\\)\\.`, "m"));
    assert.match(r.stdout, /To turn it off, set "autoUpdate" to false under extraKnownMarketplaces\.hov there\./);
    assert.ok(!readdirSync(ctx.cfg).some((f) => f.includes(".tmp")), "a temporary file was left behind");
  });
});

test("--no-backup writes no backup", () => {
  withHome(freshAdd(), (ctx) => {
    const r = helperRun(ctx, ["--no-backup", "hov"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(readJson(ctx.settingsPath).extraKnownMarketplaces.hov.autoUpdate, true);
    assert.equal(existsSync(join(ctx.home, ".hov-stack-backups")), false);
    assert.doesNotMatch(r.stdout, /old file/);
  });
});

test("keeps the file's indentation, its missing final newline and its permission bits", () => {
  const settings = JSON.stringify({ extraKnownMarketplaces: { hov: { source: HOV_SOURCE } } }, null, "\t");
  withHome({ settings, known: { hov: knownEntry(HOV_SOURCE) } }, (ctx) => {
    chmodSync(ctx.settingsPath, 0o600);
    const r = helperRun(ctx, ["--no-backup", "hov"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const text = readFileSync(ctx.settingsPath, "utf8");
    assert.equal(text, JSON.stringify({ extraKnownMarketplaces: { hov: { source: HOV_SOURCE, autoUpdate: true } } }, null, "\t"));
    assert.equal(statSync(ctx.settingsPath).mode & 0o777, 0o600);
  });
});

test("several marketplaces are turned on in one write with one backup", () => {
  const codex = { source: "github", repo: "openai/codex-plugin-cc" };
  withHome(
    {
      settings: { extraKnownMarketplaces: { hov: { source: HOV_SOURCE }, "openai-codex": { source: codex } } },
      known: { hov: knownEntry(HOV_SOURCE), "openai-codex": knownEntry(codex) },
    },
    (ctx) => {
      const r = helperRun(ctx, ["hov", "openai-codex"]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      const s = readJson(ctx.settingsPath);
      assert.equal(s.extraKnownMarketplaces.hov.autoUpdate, true);
      assert.equal(s.extraKnownMarketplaces["openai-codex"].autoUpdate, true);
      assert.equal(backups(ctx.home).length, 1);
    },
  );
});

test("already on: says where, writes nothing, backs up nothing", () => {
  const settings = { extraKnownMarketplaces: { hov: { source: HOV_SOURCE, autoUpdate: true } } };
  withHome({ settings, known: { hov: knownEntry(HOV_SOURCE) } }, (ctx) => {
    const before = readFileSync(ctx.settingsPath, "utf8");
    const mtime = statSync(ctx.settingsPath).mtimeMs;
    const r = helperRun(ctx, ["hov"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(r.stdout, `hov: auto-update is on, set in ${ctx.settingsPath}\n`);
    assert.equal(readFileSync(ctx.settingsPath, "utf8"), before);
    assert.equal(statSync(ctx.settingsPath).mtimeMs, mtime);
    assert.equal(existsSync(join(ctx.home, ".hov-stack-backups")), false);
  });
  // Switched on in /plugin: the toggle's file decides when settings.json gives no value.
  withHome({ settings: { extraKnownMarketplaces: { hov: { source: HOV_SOURCE } } }, known: { hov: knownEntry(HOV_SOURCE, { autoUpdate: true }) } }, (ctx) => {
    const r = helperRun(ctx, ["hov"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(r.stdout, "hov: auto-update is on, switched on in /plugin\n");
    assert.equal(readJson(ctx.settingsPath).extraKnownMarketplaces.hov.autoUpdate, undefined);
  });
  // Anthropic's own marketplace is on by default.
  const official = { source: "github", repo: "anthropics/claude-plugins-official" };
  withHome({ settings: {}, known: { "claude-plugins-official": knownEntry(official) } }, (ctx) => {
    const r = helperRun(ctx, ["claude-plugins-official"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /auto-update is on, by Claude Code's default for its own marketplace/);
  });
});

test("a false someone set is left alone, wherever it is, and the way back is named", () => {
  const offInSettings = { extraKnownMarketplaces: { hov: { source: HOV_SOURCE, autoUpdate: false } } };
  withHome({ settings: offInSettings, known: { hov: knownEntry(HOV_SOURCE, { autoUpdate: true }) } }, (ctx) => {
    const before = readFileSync(ctx.settingsPath, "utf8");
    const r = helperRun(ctx, ["hov"]);
    assert.equal(r.status, 3, r.stdout + r.stderr);
    assert.equal(readFileSync(ctx.settingsPath, "utf8"), before);
    assert.match(r.stdout, new RegExp(`auto-update is off, set to false in ${ctx.settingsPath}, and was left off`));
    assert.match(r.stdout, /set "autoUpdate" to true under extraKnownMarketplaces\.hov there/);
    assert.equal(existsSync(join(ctx.home, ".hov-stack-backups")), false);
  });
  const declared = { extraKnownMarketplaces: { hov: { source: HOV_SOURCE } } };
  withHome({ settings: declared, known: { hov: knownEntry(HOV_SOURCE, { autoUpdate: false }) } }, (ctx) => {
    const before = readFileSync(ctx.settingsPath, "utf8");
    const r = helperRun(ctx, ["hov"]);
    assert.equal(r.status, 3, r.stdout + r.stderr);
    assert.equal(readFileSync(ctx.settingsPath, "utf8"), before);
    assert.match(r.stdout, /auto-update is off, switched off in \/plugin, and was left off\. To turn it on: \/plugin, Marketplaces, hov, Enable auto-update\./);
  });
});

test("--check reports off and changes nothing", () => {
  withHome(freshAdd(), (ctx) => {
    const before = readFileSync(ctx.settingsPath, "utf8");
    const r = helperRun(ctx, ["--check", "hov"]);
    assert.equal(r.status, 3, r.stdout + r.stderr);
    assert.equal(r.stdout, "hov: auto-update is off, Claude Code's default for a marketplace from another publisher\n");
    assert.equal(readFileSync(ctx.settingsPath, "utf8"), before);
    assert.equal(existsSync(join(ctx.home, ".hov-stack-backups")), false);
  });
});

test("refuses, changing nothing, when it cannot tell or must not write", () => {
  const cases = [
    ["a marketplace Claude Code does not have", { settings: {}, known: {} }, /hov: not changed: Claude Code has no marketplace named hov$/m],
    [
      "one added without a settings.json entry",
      { settings: { model: "x" }, known: { hov: knownEntry(HOV_SOURCE) } },
      /has no entry for it, so it was added some other way\. To turn auto-update on: \/plugin, Marketplaces, hov, Enable auto-update\./,
    ],
    ["no settings.json at all", { known: { hov: knownEntry(HOV_SOURCE) } }, /has no entry for it/],
    ["a settings.json that does not parse", { settings: '{ "model": ', known: { hov: knownEntry(HOV_SOURCE) } }, /settings\.json does not parse as JSON$/m],
    ["a settings.json that is a list", { settings: "[]\n", known: { hov: knownEntry(HOV_SOURCE) } }, /settings\.json is not a JSON object$/m],
    ["a known_marketplaces.json that does not parse", { settings: freshAdd().settings, known: "{" }, /known_marketplaces\.json does not parse as JSON$/m],
    [
      "an autoUpdate that is not true or false",
      { settings: { extraKnownMarketplaces: { hov: { source: HOV_SOURCE, autoUpdate: "yes" } } }, known: { hov: knownEntry(HOV_SOURCE) } },
      /gives hov an autoUpdate that is not true or false$/m,
    ],
  ];
  for (const [what, files, want] of cases) {
    withHome(files, (ctx) => {
      const before = existsSync(ctx.settingsPath) ? readFileSync(ctx.settingsPath, "utf8") : null;
      const r = helperRun(ctx, ["hov"]);
      assert.equal(r.status, 1, `${what}: ${r.stdout}${r.stderr}`);
      assert.match(r.stdout, want, what);
      assert.equal(existsSync(ctx.settingsPath) ? readFileSync(ctx.settingsPath, "utf8") : null, before, `${what}: settings.json changed`);
      assert.equal(existsSync(join(ctx.home, ".hov-stack-backups")), false, `${what}: a backup was made`);
    });
  }
});

test("one refusal does not stop another marketplace from being turned on", () => {
  withHome(freshAdd(), (ctx) => {
    const r = helperRun(ctx, ["--no-backup", "nope", "hov"]);
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stdout, /^nope: not changed: /m);
    assert.match(r.stdout, /^hov: auto-update turned on/m);
    assert.equal(readJson(ctx.settingsPath).extraKnownMarketplaces.hov.autoUpdate, true);
  });
});

test("a symlinked settings.json stays a link, and its target gets the change", () => {
  withHome({ known: { hov: knownEntry(HOV_SOURCE) } }, (ctx) => {
    const target = join(ctx.dir, "dotfiles-settings.json");
    writeFileSync(target, JSON.stringify(freshAdd().settings, null, 2) + "\n");
    symlinkSync(target, ctx.settingsPath);
    const r = helperRun(ctx, ["hov"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.ok(lstatSync(ctx.settingsPath).isSymbolicLink(), "the link was replaced by a file");
    assert.equal(readJson(target).extraKnownMarketplaces.hov.autoUpdate, true);
    assert.equal(backups(ctx.home).length, 1);
  });
});

test("names a switch that stops every plugin update, unless FORCE_AUTOUPDATE_PLUGINS is set", () => {
  withHome(freshAdd(), (ctx) => {
    const r = helperRun(ctx, ["--check", "hov"], { DISABLE_AUTOUPDATER: "1" });
    assert.match(r.stdout, /^note: DISABLE_AUTOUPDATER is set in the environment, which stops Claude Code updating any plugin/m);
    const forced = helperRun(ctx, ["--check", "hov"], { DISABLE_AUTOUPDATER: "1", FORCE_AUTOUPDATE_PLUGINS: "1" });
    assert.doesNotMatch(forced.stdout, /^note:/m);
    const zero = helperRun(ctx, ["--check", "hov"], { DISABLE_AUTOUPDATER: "0" });
    assert.doesNotMatch(zero.stdout, /^note:/m);
  });
  const s = freshAdd();
  s.settings.env = { DISABLE_UPDATES: "1" };
  withHome(s, (ctx) => {
    const r = helperRun(ctx, ["--check", "hov"]);
    assert.match(r.stdout, new RegExp(`^note: DISABLE_UPDATES is set in the env block of ${ctx.settingsPath}`, "m"));
  });
});

test("bad usage exits 2 and changes nothing", () => {
  withHome(freshAdd(), (ctx) => {
    const before = readFileSync(ctx.settingsPath, "utf8");
    for (const args of [[], ["--bogus", "hov"], ["--config-dir"], ["hov/../x"]]) {
      const r = helperRun(ctx, args);
      assert.equal(r.status, 2, `${args.join(" ")}: ${r.stdout}${r.stderr}`);
      assert.match(r.stderr, /usage: node autoupdate\.mjs/);
    }
    assert.equal(readFileSync(ctx.settingsPath, "utf8"), before);
  });
});

test("--config-dir overrides CLAUDE_CONFIG_DIR", () => {
  withHome(freshAdd(), (ctx) => {
    const r = helperRun(ctx, ["--no-backup", "--config-dir", ctx.cfg, "hov"], { CLAUDE_CONFIG_DIR: join(ctx.dir, "elsewhere") });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(readJson(ctx.settingsPath).extraKnownMarketplaces.hov.autoUpdate, true);
  });
});
