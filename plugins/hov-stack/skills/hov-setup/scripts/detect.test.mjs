import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { PLUGINS } from "./detect.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const detectPath = join(here, "detect.mjs");
const skillText = readFileSync(join(here, "..", "SKILL.md"), "utf8");
const ORDER = ["pro-gate", "wsl-cdp", "token-eater", "product-video", "sign-it"];

// A fake `claude` that logs each call and answers the two list commands from files.
const FAKE_CLAUDE = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DIR/calls"
if [ -f "$FAKE_DIR/fail" ]; then echo "claude: not logged in" >&2; exit 7; fi
case "$*" in
  "plugin marketplace list --json") cat "$FAKE_DIR/marketplaces.json" ;;
  "plugin list --json") cat "$FAKE_DIR/plugins.json" ;;
  *) echo "unexpected: $*" >&2; exit 64 ;;
esac
`;

function withFake({ marketplaces = [{ name: "hov" }], plugins = [], wsl = true, fail = false, raw } = {}, run) {
  const dir = mkdtempSync(join(tmpdir(), "hov-setup-"));
  try {
    writeFileSync(join(dir, "claude"), FAKE_CLAUDE);
    chmodSync(join(dir, "claude"), 0o755);
    writeFileSync(join(dir, "marketplaces.json"), JSON.stringify(marketplaces));
    writeFileSync(join(dir, "plugins.json"), raw ?? JSON.stringify(plugins));
    writeFileSync(
      join(dir, "proc-version"),
      wsl ? "Linux version 6.6.0-microsoft-standard-WSL2\n" : "Linux version 6.8.0-generic\n",
    );
    if (fail) writeFileSync(join(dir, "fail"), "");
    return run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function detect(dir, ...args) {
  return detectAt(detectPath, dir, ...args);
}

function detectAt(script, dir, ...args) {
  return spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${dir}:${process.env.PATH}`,
      FAKE_DIR: dir,
      HOV_SETUP_PROC_VERSION: join(dir, "proc-version"),
    },
  });
}

function report(dir) {
  const r = detect(dir, "--json");
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}

const row = (rep, name) => rep.plugins.find((p) => p.name === name);
const user = (name, extra = {}) => ({
  id: `${name}@hov`,
  scope: "user",
  version: "1.2.3",
  enabled: true,
  installPath: `/plugins/cache/hov/${name}/1.2.3`,
  ...extra,
});

test("with every plugin absent, lists the five in walkthrough order with their install lines", () => {
  withFake({}, (dir) => {
    const r = detect(dir);
    assert.equal(r.status, 0, r.stderr);
    const lines = r.stdout.split("\n").filter((l) => l.startsWith("  "));
    assert.deepEqual(lines, ORDER.map((p) => `  ${p}: absent. Install: claude plugin install ${p}@hov --scope user`));
    const rep = report(dir);
    assert.equal(rep.marketplace.added, true);
    assert.deepEqual(rep.plugins.map((p) => [p.name, p.state]), ORDER.map((p) => [p, "absent"]));
  });
});

test("an installed pro-gate gets no install line and reports its version and path", () => {
  withFake({ plugins: [user("pro-gate", { version: "0.65.2", installPath: "/cache/pro-gate/0.65.2" })] }, (dir) => {
    const r = detect(dir);
    assert.equal(r.status, 0, r.stderr);
    assert.ok(r.stdout.includes("  pro-gate: installed 0.65.2\n"), r.stdout);
    assert.equal(r.stdout.includes("install pro-gate@hov"), false);
    for (const p of ORDER.slice(1)) assert.ok(r.stdout.includes(`claude plugin install ${p}@hov --scope user`), p);
    const pg = row(report(dir), "pro-gate");
    assert.deepEqual(
      [pg.state, pg.version, pg.installPath, pg.next],
      ["installed", "0.65.2", "/cache/pro-gate/0.65.2", null],
    );
  });
});

test("a project-scope copy does not count, the rule ./setup uses", () => {
  withFake({ plugins: [user("sign-it", { scope: "project" })] }, (dir) => {
    const s = row(report(dir), "sign-it");
    assert.deepEqual([s.state, s.otherScopes, s.installPath], ["absent", ["project"], null]);
    assert.match(detect(dir).stdout, /sign-it: absent \(installed at project scope only, which does not count\)\. Install:/);
  });
});

test("a plugin of the same name from another marketplace does not count", () => {
  withFake({ plugins: [{ ...user("token-eater"), id: "token-eater@elsewhere" }] }, (dir) => {
    assert.equal(row(report(dir), "token-eater").state, "absent");
  });
});

test("a disabled plugin is offered the enable line, not the install line", () => {
  withFake({ plugins: [user("product-video", { enabled: false })] }, (dir) => {
    const pv = row(report(dir), "product-video");
    assert.deepEqual([pv.state, pv.next], ["disabled", "claude plugin enable product-video@hov --scope user"]);
  });
});

test("off WSL2, wsl-cdp is not applicable and gets no install line", () => {
  withFake({ wsl: false }, (dir) => {
    const rep = report(dir);
    assert.equal(rep.wsl, false);
    assert.equal(row(rep, "wsl-cdp").state, "not-applicable");
    assert.match(row(rep, "wsl-cdp").next, /WSL2 only/);
    assert.equal(detect(dir).stdout.includes("install wsl-cdp@hov"), false);
    assert.equal(row(rep, "product-video").state, "absent");
  });
});

test("a missing hov marketplace says so and points at ./setup", () => {
  withFake({ marketplaces: [{ name: "other" }] }, (dir) => {
    assert.equal(report(dir).marketplace.added, false);
    assert.match(detect(dir).stdout, /marketplace is not added[^]*Re-run \.\/setup/);
  });
});

test("a failing claude read exits 1 with its error and reports nothing absent", () => {
  withFake({ fail: true }, (dir) => {
    for (const args of [[], ["--json"]]) {
      const r = detect(dir, ...args);
      assert.equal(r.status, 1);
      assert.match(r.stderr, /exited 7: claude: not logged in/);
      assert.equal(r.stdout, "");
    }
  });
});

test("output from claude that is not a JSON list exits 1", () => {
  withFake({ raw: "{\"id\": \"pro-gate@hov\"}" }, (dir) => {
    const r = detect(dir, "--json");
    assert.equal(r.status, 1);
    assert.match(r.stderr, /not a JSON list/);
    assert.equal(r.stdout, "");
  });
});

test("it only reads, through the two list commands", () => {
  withFake({ plugins: [user("pro-gate"), user("sign-it", { enabled: false })] }, (dir) => {
    detect(dir, "--json");
    assert.deepEqual(readFileSync(join(dir, "calls"), "utf8").trim().split("\n"), [
      "plugin marketplace list --json",
      "plugin list --json",
    ]);
  });
});

test("run through a symlinked skill dir, the way ./setup links skills, it still reports", () => {
  withFake({ plugins: [user("pro-gate")] }, (dir) => {
    const link = join(dir, "skill-link");
    symlinkSync(join(here, ".."), link, "dir");
    const r = detectAt(join(link, "scripts", "detect.mjs"), dir, "--json");
    assert.equal(r.status, 0, r.stderr);
    assert.equal(row(JSON.parse(r.stdout), "pro-gate").state, "installed");
  });
  assert.ok(existsSync(join(here, "..", "SKILL.md")), "cleanup followed the link into the skill");
});

test("an unknown argument is a usage error", () => {
  withFake({}, (dir) => {
    const r = detect(dir, "--dry-run");
    assert.equal(r.status, 2);
    assert.match(r.stderr, /usage: node detect\.mjs \[--json\]/);
  });
});

// The skill text: one section per plugin, in the detector's order, and the credential
// instruction ahead of the first step in each section whose steps need one.
function sections(text) {
  const out = new Map();
  const parts = text.split(/^### /m).slice(1);
  for (const part of parts) out.set(part.slice(0, part.indexOf("\n")).trim(), part);
  return out;
}

test("SKILL.md has one section per plugin, in the detector's order", () => {
  assert.deepEqual(PLUGINS.map((p) => p.name), ORDER);
  assert.deepEqual([...sections(skillText).keys()], ORDER);
});

test("SKILL.md states the credential rule before Step 1, naming where a credential never goes", () => {
  const rule = skillText.split("\n").find((l) => l.startsWith("- **Credentials:**"));
  assert.ok(rule, "no credential rule in the rules list");
  assert.ok(skillText.indexOf(rule) < skillText.indexOf("## Step 1"));
  for (const where of ["this chat", "command argument", "a log", "`env` or `settings.json`"]) {
    assert.ok(rule.includes(where), `the rule does not name ${where}`);
  }
});

test("SKILL.md puts the credential instruction before the first step of each plugin that needs one", () => {
  const all = sections(skillText);
  for (const name of ["pro-gate", "wsl-cdp", "token-eater"]) {
    const body = all.get(name);
    const cred = body.indexOf("**Credentials:**");
    const firstStep = body.search(/^1\. /m);
    assert.ok(cred >= 0, `${name} has no credential instruction`);
    assert.ok(firstStep >= 0, `${name} has no numbered steps`);
    assert.ok(cred < firstStep, `${name}: the credential instruction comes after step 1`);
  }
});
