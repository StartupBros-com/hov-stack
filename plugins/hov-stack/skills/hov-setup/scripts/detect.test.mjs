import assert from "node:assert/strict";
import {
  chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { EXTRAS, GROUPS, HELPERS, OFFERS, PLUGINS } from "./detect.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const detectPath = join(here, "detect.mjs");
const skillDir = join(here, "..");
const skillText = readFileSync(join(skillDir, "SKILL.md"), "utf8");
const offersJson = JSON.parse(readFileSync(join(here, "offers.json"), "utf8"));
const ORDER = ["sign-it", "wsl-cdp", "product-video", "token-eater", "pro-gate"];
const EXTRA_ORDER = ["harness-vet", "rent-check", "harness-optimizer"];
const HOV_ALL = [...ORDER, ...EXTRA_ORDER];
const ALL = offersJson.offers.map((o) => o.name);
const PLATFORMS = ["darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-aarch64"];

// A fake `claude` that logs each call and answers the two list commands from files. It uses
// /bin/cat because the tests give it a PATH that holds no system directories.
const FAKE_CLAUDE = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DIR/calls"
if [ -f "$FAKE_DIR/fail" ]; then echo "claude: not logged in" >&2; exit 7; fi
case "$*" in
  "plugin marketplace list --json") /bin/cat "$FAKE_DIR/marketplaces.json" ;;
  "plugin list --json") /bin/cat "$FAKE_DIR/plugins.json" ;;
  *) echo "unexpected: $*" >&2; exit 64 ;;
esac
`;

// A fake tool binary: running it leaves a marker file, so a test can prove nothing ran it.
const fakeTool = (name) => `#!/bin/sh\n: > "$FAKE_DIR/ran-${name}"\n`;

// pathBins sit in a directory that is on PATH; extraBins in the extra directory the detector
// also searches (HOV_SETUP_EXTRA_BIN_DIRS), which is not on PATH. No real tool is visible.
// cfg is the Claude Code config dir every run gets (CLAUDE_CONFIG_DIR), so no test reads this
// machine's own settings; settings and known become its settings.json and
// plugins/known_marketplaces.json (an object as JSON, a string as is, undefined as no file).
function withFake(
  {
    marketplaces = [{ name: "hov" }], plugins = [], wsl = true, fail = false, raw, pathBins = [], extraBins = [],
    settings, known,
  } = {},
  run,
) {
  const dir = mkdtempSync(join(tmpdir(), "hov-setup-"));
  try {
    mkdirSync(join(dir, "cfg", "plugins"), { recursive: true });
    for (const [p, v] of [[join(dir, "cfg", "settings.json"), settings], [join(dir, "cfg", "plugins", "known_marketplaces.json"), known]]) {
      if (v !== undefined) writeFileSync(p, typeof v === "string" ? v : JSON.stringify(v, null, 2) + "\n");
    }
    writeFileSync(join(dir, "claude"), FAKE_CLAUDE);
    chmodSync(join(dir, "claude"), 0o755);
    writeFileSync(join(dir, "marketplaces.json"), JSON.stringify(marketplaces));
    writeFileSync(join(dir, "plugins.json"), raw ?? JSON.stringify(plugins));
    writeFileSync(
      join(dir, "proc-version"),
      wsl ? "Linux version 6.6.0-microsoft-standard-WSL2\n" : "Linux version 6.8.0-generic\n",
    );
    if (fail) writeFileSync(join(dir, "fail"), "");
    for (const [sub, names] of [["pbin", pathBins], ["xbin", extraBins]]) {
      mkdirSync(join(dir, sub));
      for (const n of names) {
        writeFileSync(join(dir, sub, n), fakeTool(n));
        chmodSync(join(dir, sub, n), 0o755);
      }
    }
    return run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function detect(dir, ...args) {
  return detectAt(detectPath, dir, {}, ...args);
}

function detectEnv(dir, env, ...args) {
  return detectAt(detectPath, dir, env, ...args);
}

function detectAt(script, dir, env, ...args) {
  const preload = join(dir, "platform-preload.mjs");
  return spawnSync(process.execPath, [...(existsSync(preload) ? ["--import", preload] : []), script, ...args], {
    encoding: "utf8",
    env: {
      PATH: `${dir}:${join(dir, "pbin")}`,
      FAKE_DIR: dir,
      HOV_SETUP_PROC_VERSION: join(dir, "proc-version"),
      HOV_SETUP_EXTRA_BIN_DIRS: join(dir, "xbin"),
      HOV_SETUP_PLATFORM: "linux-x86_64",
      CLAUDE_CONFIG_DIR: join(dir, "cfg"),
      ...env,
    },
  });
}

function report(dir, env = {}) {
  const r = detectEnv(dir, env, "--json");
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}

const row = (rep, name) => rep.plugins.find((p) => p.name === name);
const fakeMac = (dir, { arch = "x64", output = "0", status = 0, missing = false } = {}) => {
  writeFileSync(join(dir, "platform-preload.mjs"), `
    Object.defineProperty(process, "platform", { value: "darwin" });
    Object.defineProperty(process, "arch", { value: ${JSON.stringify(arch)} });
  `);
  if (!missing) {
    writeFileSync(join(dir, "sysctl"), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DIR/sysctl-calls"
printf '%s\\n' '${output}'
exit ${status}
`);
    chmodSync(join(dir, "sysctl"), 0o755);
  }
};

for (const [label, probe, expected] of [
  ["Intel", { output: "0" }, "darwin-x86_64"],
  ["Rosetta", { output: " \n\t1 \n" }, "darwin-arm64"],
  ["missing sysctl", { missing: true }, "darwin-x86_64"],
  ["failed sysctl with misleading output", { output: "1", status: 1 }, "darwin-x86_64"],
  ["unexpected sysctl output", { output: "2" }, "darwin-x86_64"],
  ["malformed Rosetta output", { output: "1 extra" }, "darwin-x86_64"],
]) {
  test(`native macOS detection distinguishes ${label}`, () => {
    withFake({}, (dir) => {
      fakeMac(dir, probe);
      const rep = report(dir, { HOV_SETUP_PLATFORM: "" });
      assert.equal(rep.platform, expected);
      if (!probe.missing) assert.equal(readFileSync(join(dir, "sysctl-calls"), "utf8"), "-n sysctl.proc_translated\n");
    });
  });
}

test("native ARM macOS and an explicit platform override do not probe Rosetta", () => {
  withFake({}, (dir) => {
    fakeMac(dir, { arch: "arm64", output: "1" });
    assert.equal(report(dir, { HOV_SETUP_PLATFORM: "" }).platform, "darwin-arm64");
    assert.equal(existsSync(join(dir, "sysctl-calls")), false);
    fakeMac(dir, { output: "1" });
    assert.equal(report(dir, { HOV_SETUP_PLATFORM: "darwin-x86_64" }).platform, "darwin-x86_64");
    assert.equal(existsSync(join(dir, "sysctl-calls")), false);
  });
});

const user = (name, extra = {}) => ({
  id: `${name}@hov`,
  scope: "user",
  version: "1.2.3",
  enabled: true,
  installPath: `/plugins/cache/hov/${name}/1.2.3`,
  ...extra,
});

test("with everything absent, lists every offer and helper with the line to run", () => {
  withFake({}, (dir) => {
    const r = detect(dir);
    assert.equal(r.status, 0, r.stderr);
    const lines = r.stdout.split("\n").filter((l) => l.startsWith("  "));
    for (const p of HOV_ALL) {
      const want = `  ${p}: absent. Install: claude plugin install ${p}@hov --scope user`;
      assert.ok(lines.includes(want), want);
    }
    assert.ok(
      lines.includes(
        "  last30days: absent. Add its marketplace first: claude plugin marketplace add mvanhorn/last30days-skill. Then install: claude plugin install last30days@last30days-skill --scope user",
      ),
      lines.join("\n"),
    );
    // One row per offer and helper, plus hov's auto-update line. The fake's config dir is empty,
    // so Claude Code lists hov while neither file names it.
    assert.equal(lines.length, ALL.length + HELPERS.length + 1);
    assert.equal(lines.filter((l) => l.startsWith("  auto-update for hov: could not tell: neither ")).length, 1, lines.join("\n"));
    assert.equal(r.stdout.includes("also installed"), false);
    const rep = report(dir);
    assert.equal(rep.marketplace.added, true);
    assert.deepEqual(rep.plugins.map((p) => [p.name, p.state]), ALL.map((p) => [p, "absent"]));
    assert.deepEqual(rep.alsoInstalled, []);
  });
});

test("the derived exports keep their old shape: PLUGINS the five guided hov plugins, EXTRAS the three tuning ones", () => {
  assert.deepEqual(PLUGINS.map((p) => p.name), ORDER);
  assert.deepEqual(EXTRAS.map((p) => p.name), EXTRA_ORDER);
  assert.deepEqual(Object.keys(PLUGINS[0]), ["name", "what"]);
  assert.deepEqual(PLUGINS.filter((p) => p.wslOnly).map((p) => p.name), ["wsl-cdp"]);
});

test("alsoInstalled lists the other hov plugins at user scope, with what they do and how to start them", () => {
  const plugins = [
    user("papercut", { version: "0.1.23" }),
    user("memory-dream", { enabled: false }),
    user("brand-new"),
    user("sign-it"),
    user("skill-tuner", { scope: "project" }),
    { ...user("design-rails"), id: "design-rails@elsewhere" },
  ];
  withFake({ plugins }, (dir) => {
    const rep = report(dir);
    assert.deepEqual(
      rep.alsoInstalled.map((p) => [p.name, p.version, p.enabled, p.start]),
      [
        ["papercut", "0.1.23", true, "/papercut:papercut"],
        ["memory-dream", "1.2.3", false, "/memory-dream:dream"],
        ["brand-new", "1.2.3", true, null],
      ],
    );
    assert.match(rep.alsoInstalled[0].what, /tools trip Claude up/);
    assert.equal(rep.alsoInstalled[2].what, null);
    assert.equal(row(rep, "sign-it").state, "installed");
    assert.match(detect(dir).stdout, /^also installed: papercut 0\.1\.23, memory-dream 1\.2\.3 \(disabled\), brand-new 1\.2\.3$/m);
  });
});

test("an installed pro-gate gets no install line and reports its version and path", () => {
  withFake({ plugins: [user("pro-gate", { version: "0.65.2", installPath: "/cache/pro-gate/0.65.2" })] }, (dir) => {
    const r = detect(dir);
    assert.equal(r.status, 0, r.stderr);
    assert.ok(r.stdout.includes("  pro-gate: installed 0.65.2\n"), r.stdout);
    assert.equal(r.stdout.includes("install pro-gate@hov"), false);
    for (const p of HOV_ALL.filter((n) => n !== "pro-gate")) {
      assert.ok(r.stdout.includes(`claude plugin install ${p}@hov --scope user`), p);
    }
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
    const r = detectAt(join(link, "scripts", "detect.mjs"), dir, {}, "--json");
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

test("SKILL.md has one section per offer, in offers.json order", () => {
  assert.deepEqual(OFFERS.map((o) => o.name), ALL);
  assert.deepEqual([...sections(skillText).keys()], ALL);
});

// A first-time user was told to start a new session and type /hov-setup again after the
// install (U26, 2026-11-03). A plugin installed mid-session loads with /reload-plugins.
test("SKILL.md finishes in one session: /reload-plugins, never a restart or a second /hov-setup", () => {
  assert.ok(skillText.includes("`/reload-plugins`"), "no /reload-plugins step");
  assert.doesNotMatch(skillText, /start a new (Claude Code )?session/i);
  assert.doesNotMatch(skillText, /\b(restart|relaunch) (Claude Code|the session|your session)\b(?! or to type)/i);
});

// Outside bypass mode, Claude Code refused `SKILL_DIR="..."; node "$SKILL_DIR/..."` with "A variable
// set in this command can't be checked before it runs" (U26 rerun, 2026-11-03).
test("SKILL.md runs the detector with the path written in, not through a shell variable", () => {
  assert.ok(skillText.includes('node "<skill-dir>/scripts/detect.mjs" --json'), "no plain detector line");
  assert.doesNotMatch(skillText, /^[A-Z_]+="[^"\n]*";\s*node\b/m);
});

// Through `!`, a bare `gh auth login` printed its help and logged nothing in; the web flow
// showed its one-time code live (U26, 2026-11-03).
test("SKILL.md's GitHub login line uses the web flow, which works through `!`", () => {
  const lines = skillText.split("\n").filter((l) => /^!\s*gh auth login\b/.test(l.trim()));
  assert.ok(lines.length > 0, "no `! gh auth login` line");
  for (const l of lines) assert.match(l, /--web\b/, l);
  assert.doesNotMatch(skillText, /`gh auth login` in their own terminal/);
});

// The card is what the user reads first. It says what the offer does, costs and needs, in
// plain words; the words below were in the run that a first-time user called jargon.
const cardOf = (body) => body.split("\n").find((l) => l.startsWith("**Card:**"));

test("each offer section opens with a card in plain words", () => {
  const jargon = /\b(doctor|runtime|smoke|blocking|pinned|scope|exit code|dependenc(y|ies)|CLI)\b/i;
  for (const [name, body] of sections(skillText)) {
    const card = cardOf(body);
    assert.ok(card, `${name} has no card`);
    assert.ok(body.indexOf(card) < body.indexOf("Check"), `${name}: the card comes after its check`);
    assert.doesNotMatch(card, jargon, `${name}'s card uses a word a first-time user called jargon`);
  }
});

test("a card names its publisher when it is not hov-stack, and cass and jeffreys-skills say what they must", () => {
  const all = sections(skillText);
  for (const o of OFFERS) {
    const card = cardOf(all.get(o.name) ?? "");
    assert.ok(card, `${o.name} has no card`);
    if (o.publisher !== "hov-stack") assert.ok(card.includes(o.publisher), `${o.name}'s card does not name ${o.publisher}`);
  }
  const cass = cardOf(all.get("cass") ?? "");
  assert.ok(cass && cass.includes("OpenAI"), "cass card does not say OpenAI");
  assert.ok(cass.includes("Anthropic"), "cass card does not say Anthropic");
  const js = cardOf(all.get("jeffreys-skills") ?? "");
  assert.ok(js && js.includes("$20 a month"), "jeffreys-skills card does not give the price");
  assert.ok(js.includes("never hands out"), "jeffreys-skills card does not say what it never hands out");
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
  for (const name of ["wsl-cdp", "token-eater", "pro-gate", "gh", "codex", "last30days", "jeffreys-skills"]) {
    const body = all.get(name);
    assert.ok(body, `${name} has no section`);
    const cred = body.indexOf("**Credentials:**");
    const firstStep = body.search(/^1\. /m);
    assert.ok(cred >= 0, `${name} has no credential instruction`);
    assert.ok(firstStep >= 0, `${name} has no numbered steps`);
    assert.ok(cred < firstStep, `${name}: the credential instruction comes after step 1`);
  }
});

// ---- the wider offer list: other publishers' plugins, programs, the paid skill set

const CE = "compound-engineering";
const CE_GIT = { name: "every-marketplace", source: "git", url: "https://github.com/EveryInc/compound-engineering-plugin.git" };
const aliasUser = (extra = {}) => ({ ...user(CE, extra), id: `${CE}@every-marketplace` });

test("rows follow offers.json order and carry each offer's kind, group and publisher; helpers are listed", () => {
  withFake({}, (dir) => {
    const rep = report(dir);
    assert.deepEqual(
      rep.plugins.map((p) => [p.name, p.kind, p.group, p.publisher, p.what]),
      offersJson.offers.map((o) => [o.name, o.kind, o.group, o.publisher, o.what]),
    );
    assert.deepEqual(
      rep.helpers.map((h) => [h.name, h.publisher, h.what, h.bin]),
      offersJson.helpers.map((h) => [h.name, h.publisher, h.what, h.bin]),
    );
    assert.equal(rep.platform, "linux-x86_64");
    assert.deepEqual(GROUPS, offersJson.groups);
    assert.deepEqual(HELPERS, offersJson.helpers);
  });
});

test("an other-plugin with no matching marketplace gets the marketplace line and offers.json's marketplace name", () => {
  withFake({ marketplaces: [{ name: "hov" }, { name: "unrelated", source: "github", repo: "someone/else" }] }, (dir) => {
    const ce = row(report(dir), CE);
    assert.equal(ce.kind, "other-plugin");
    assert.equal(ce.marketplaceAdd, "claude plugin marketplace add EveryInc/compound-engineering-plugin");
    assert.equal(ce.id, `${CE}@compound-engineering-plugin`);
    assert.equal(ce.next, `claude plugin install ${CE}@compound-engineering-plugin --scope user`);
    assert.equal(ce.state, "absent");
  });
});

test("a marketplace the user named differently is found by its source, and its installed plugin counts", () => {
  withFake({ marketplaces: [{ name: "hov" }, CE_GIT], plugins: [aliasUser({ version: "3.4.5" })] }, (dir) => {
    const ce = row(report(dir), CE);
    assert.deepEqual(
      [ce.state, ce.id, ce.marketplaceAdd, ce.version, ce.next],
      ["installed", `${CE}@every-marketplace`, null, "3.4.5", null],
    );
    assert.match(detect(dir).stdout, /^  compound-engineering: installed 3\.4\.5$/m);
  });
});

test("a github-source marketplace matches ignoring case; an absent plugin installs from the user's alias", () => {
  const mk = { name: "mine", source: "github", repo: "everyinc/COMPOUND-engineering-plugin" };
  withFake({ marketplaces: [{ name: "hov" }, mk] }, (dir) => {
    const ce = row(report(dir), CE);
    assert.deepEqual([ce.state, ce.id, ce.marketplaceAdd], ["absent", `${CE}@mine`, null]);
    assert.equal(ce.next, `claude plugin install ${CE}@mine --scope user`);
  });
  const url = { name: "u", source: "git", url: "HTTPS://GitHub.com/EveryInc/Compound-Engineering-Plugin/" };
  withFake({ marketplaces: [{ name: "hov" }, url] }, (dir) => {
    assert.equal(row(report(dir), CE).id, `${CE}@u`);
  });
});

test("with two matching marketplaces, the one holding the installed plugin is preferred", () => {
  const first = { name: "first", source: "github", repo: "EveryInc/compound-engineering-plugin" };
  withFake({ marketplaces: [{ name: "hov" }, first, CE_GIT], plugins: [aliasUser()] }, (dir) => {
    assert.equal(row(report(dir), CE).id, `${CE}@every-marketplace`);
  });
  withFake({ marketplaces: [{ name: "hov" }, first, CE_GIT] }, (dir) => {
    assert.equal(row(report(dir), CE).id, `${CE}@first`);
  });
});

test("a disabled other-plugin is offered the enable line with the alias id; a project-scope copy does not count", () => {
  withFake({ marketplaces: [{ name: "hov" }, CE_GIT], plugins: [aliasUser({ enabled: false })] }, (dir) => {
    const ce = row(report(dir), CE);
    assert.deepEqual([ce.state, ce.next], ["disabled", `claude plugin enable ${CE}@every-marketplace --scope user`]);
    assert.match(
      detect(dir).stdout,
      /compound-engineering: installed 1\.2\.3 but disabled\. Enable: claude plugin enable compound-engineering@every-marketplace --scope user/,
    );
  });
  withFake({ marketplaces: [{ name: "hov" }, CE_GIT], plugins: [aliasUser({ scope: "project" })] }, (dir) => {
    const ce = row(report(dir), CE);
    assert.deepEqual([ce.state, ce.otherScopes], ["absent", ["project"]]);
  });
});

test("a tool on PATH is installed and on PATH; one only in an extra directory is installed but not on PATH", () => {
  withFake({ pathBins: ["gh"], extraBins: ["cass"] }, (dir) => {
    const rep = report(dir);
    const gh = row(rep, "gh");
    assert.deepEqual([gh.state, gh.path, gh.onPath, gh.next], ["installed", join(dir, "pbin", "gh"), true, null]);
    const cass = row(rep, "cass");
    assert.deepEqual([cass.state, cass.path, cass.onPath, cass.next], ["installed", join(dir, "xbin", "cass"), false, null]);
    assert.match(detect(dir).stdout, /^  cass: installed \(.*cass\)\. Not on PATH$/m);
  });
});

test("a file that is not executable, or is a directory, is not a tool", () => {
  withFake({}, (dir) => {
    writeFileSync(join(dir, "pbin", "gh"), "#!/bin/sh\n");
    chmodSync(join(dir, "pbin", "gh"), 0o644);
    mkdirSync(join(dir, "pbin", "cass"));
    const rep = report(dir);
    assert.equal(row(rep, "gh").state, "absent");
    assert.equal(row(rep, "cass").state, "absent");
  });
});

test("an absent tool's install line names the absolute skill directory and the installer", () => {
  withFake({}, (dir) => {
    const gh = row(report(dir), "gh");
    assert.equal(gh.state, "absent");
    assert.equal(gh.path, null);
    assert.equal(gh.onPath, false);
    assert.equal(gh.next, `bash "${skillDir}/scripts/install-release.sh" gh`);
    assert.ok(gh.next.includes(`${skillDir}/scripts/install-release.sh" gh`));
    assert.equal(gh.next.includes("<skill-dir>"), false);
    assert.match(detect(dir).stdout, /^  gh: absent\. Install: bash "/m);
  });
});

test("needs: with uv absent the install line says plain uv and carries uv's own install line", () => {
  withFake({}, (dir) => {
    const rep = report(dir);
    const sp = row(rep, "synthetic-panel");
    assert.ok(sp.next.startsWith("uv tool install"), sp.next);
    assert.equal(sp.needs.length, 1);
    assert.equal(sp.needs[0].name, "uv");
    assert.equal(sp.needs[0].path, null);
    assert.equal(sp.needs[0].onPath, false);
    assert.equal(sp.needs[0].next, `bash "${skillDir}/scripts/install-release.sh" uv`);
    assert.deepEqual(row(rep, "gh").needs, []);
    assert.equal(rep.helpers[0].state, "absent");
  });
});

test("needs: with uv present the install line uses uv's absolute path", () => {
  withFake({ pathBins: ["uv"] }, (dir) => {
    const rep = report(dir);
    const uv = join(dir, "pbin", "uv");
    const sp = row(rep, "synthetic-panel");
    assert.ok(sp.next.startsWith(`${uv} tool install`), sp.next);
    assert.ok(row(rep, "ast-grep").next.startsWith(`${uv} tool install ast-grep-cli`));
    assert.deepEqual([sp.needs[0].path, sp.needs[0].onPath], [uv, true]);
    assert.deepEqual([rep.helpers[0].state, rep.helpers[0].path], ["installed", uv]);
  });
});

test("linux platforms install synthetic-panel with the CPU torch backend; macOS does not", () => {
  withFake({}, (dir) => {
    for (const platform of ["linux-x86_64", "linux-aarch64"]) {
      const sp = row(report(dir, { HOV_SETUP_PLATFORM: platform }), "synthetic-panel");
      assert.ok(sp.next.includes("--torch-backend cpu"), `${platform}: ${sp.next}`);
    }
    const mac = row(report(dir, { HOV_SETUP_PLATFORM: "darwin-arm64" }), "synthetic-panel");
    assert.equal(mac.next.includes("--torch-backend"), false, mac.next);
    assert.ok(mac.next.startsWith("uv tool install"));
  });
});

test("Intel Macs offer supported tools and keep cass and synthetic-panel unavailable", () => {
  withFake({ pathBins: ["cass", "synthetic-panel"] }, (dir) => {
    const rep = report(dir, { HOV_SETUP_PLATFORM: "darwin-x86_64" });
    for (const [name, line] of [
      ["gh", `bash "${join(here, "install-release.sh")}" gh`],
      ["jeffreys-skills", `bash "${join(here, "install-release.sh")}" jsm`],
      ["ast-grep", "uv tool install ast-grep-cli"],
    ]) {
      assert.deepEqual([row(rep, name).state, row(rep, name).next], ["absent", line], name);
    }
    assert.deepEqual([rep.helpers[0].state, rep.helpers[0].next], ["absent", `bash "${join(here, "install-release.sh")}" uv`]);
    for (const name of ["cass", "synthetic-panel"]) {
      const p = row(rep, name);
      assert.deepEqual([p.state, p.path], ["not-applicable", null], name);
      assert.equal(p.next, "only offered on darwin-arm64, linux-x86_64, linux-aarch64", name);
    }
  });
});

test("an unsupported platform makes every tool, paid-skills row and helper not applicable; plugins are unaffected", () => {
  withFake({ pathBins: ["gh"] }, (dir) => {
    const env = { HOV_SETUP_PLATFORM: "freebsd-x64" };
    const rep = report(dir, env);
    assert.equal(rep.platform, "freebsd-x64");
    const want = (o) => `only offered on ${Object.keys(o.install).join(", ")}`;
    const programs = rep.plugins.filter((x) => x.kind === "tool" || x.kind === "paid-skills");
    assert.equal(programs.length, 5);
    for (const p of programs) {
      const offer = offersJson.offers.find((o) => o.name === p.name);
      assert.deepEqual([p.state, p.next, p.path], ["not-applicable", want(offer), null], p.name);
    }
    assert.deepEqual(rep.helpers.map((h) => [h.state, h.next]), [["not-applicable", want(offersJson.helpers[0])]]);
    assert.equal(row(rep, "sign-it").state, "absent");
    assert.equal(row(rep, CE).state, "absent");
    const t = detectEnv(dir, env);
    assert.match(t.stdout, /^  gh: not applicable here: only offered on darwin-arm64, darwin-x86_64, linux-x86_64, linux-aarch64$/m);
  });
});

test("it runs nothing but the two claude list commands, never a tool it finds", () => {
  withFake({ pathBins: ["gh", "uv", "cass"], extraBins: ["jsm", "ast-grep", "synthetic-panel"] }, (dir) => {
    const rep = report(dir);
    for (const n of ["gh", "uv", "cass", "jeffreys-skills", "ast-grep", "synthetic-panel"]) {
      const state = (row(rep, n) ?? rep.helpers.find((h) => h.name === n)).state;
      assert.equal(state, "installed", n);
    }
    assert.deepEqual(readFileSync(join(dir, "calls"), "utf8").trim().split("\n"), [
      "plugin marketplace list --json",
      "plugin list --json",
    ]);
    assert.deepEqual(readdirSync(dir).filter((f) => f.startsWith("ran-")), []);
  });
});

test("offers.json has a valid shape", () => {
  const kinds = ["plugin", "other-plugin", "tool", "paid-skills"];
  const groups = offersJson.groups.map((g) => g.key);
  const names = [...offersJson.offers, ...offersJson.helpers].map((o) => o.name);
  assert.equal(new Set(names).size, names.length, "names are not unique");
  const helperNames = offersJson.helpers.map((h) => h.name);
  for (const o of offersJson.offers) {
    assert.ok(kinds.includes(o.kind), `${o.name}: kind ${o.kind}`);
    assert.ok(groups.includes(o.group), `${o.name}: group ${o.group}`);
    assert.ok(o.publisher && o.what, `${o.name}: publisher and what are required`);
    if (o.kind === "plugin") assert.equal("install" in o, false, `${o.name}: a plugin has no install map`);
    if (o.kind === "tool" || o.kind === "paid-skills") {
      assert.ok(o.bin, `${o.name}: no bin`);
      assert.ok(o.install && Object.keys(o.install).length, `${o.name}: no install`);
    }
    if (o.kind === "other-plugin") {
      assert.ok(o.plugin, `${o.name}: no plugin`);
      assert.ok(o.marketplace && o.marketplace.name && o.marketplace.github, `${o.name}: marketplace needs name and github`);
    }
    for (const n of o.needs ?? []) assert.ok(helperNames.includes(n), `${o.name} needs ${n}, which is not a helper`);
  }
  for (const h of [...offersJson.helpers, ...offersJson.offers.filter((o) => o.install)]) {
    assert.ok(h.bin, `${h.name}: no bin`);
    for (const k of Object.keys(h.install)) assert.ok(PLATFORMS.includes(k), `${h.name}: install key ${k}`);
  }
});

// Auto-update (#395): where each marketplace stands, read from the config dir's files.
const HOV_SRC = { source: "github", repo: "StartupBros-com/hov-stack" };
const knownOf = (source, extra = {}) => ({ source, installLocation: "/m", lastUpdated: "2026-11-04T00:00:00.000Z", ...extra });
const turnOn = (name) => `node "${join(here, "autoupdate.mjs")}" ${name}`;

test("reports hov's auto-update: off after a plain add, with the line that turns it on", () => {
  const files = { settings: { extraKnownMarketplaces: { hov: { source: HOV_SRC } } }, known: { hov: knownOf(HOV_SRC) } };
  withFake(files, (dir) => {
    const rep = report(dir);
    assert.deepEqual(rep.marketplace.autoUpdate, { state: "off", where: "default", problem: null, next: turnOn("hov") });
    assert.deepEqual(rep.updatesOff, []);
    const r = detect(dir);
    assert.ok(r.stdout.split("\n").includes(`  auto-update for hov: off. Turn on: ${turnOn("hov")}`), r.stdout);
  });
});

test("the line it gives turns auto-update on, and the next detector run says so", () => {
  const files = { settings: { extraKnownMarketplaces: { hov: { source: HOV_SRC } } }, known: { hov: knownOf(HOV_SRC) } };
  withFake(files, (dir) => {
    const next = report(dir).marketplace.autoUpdate.next;
    const [, script, name] = /^node "([^"]+)" (\S+)$/.exec(next);
    const r = spawnSync(process.execPath, [script, "--no-backup", name], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: dir, CLAUDE_CONFIG_DIR: join(dir, "cfg") },
    });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const rep = report(dir);
    assert.deepEqual(rep.marketplace.autoUpdate, { state: "on", where: "settings.json", problem: null, next: null });
    assert.ok(detect(dir).stdout.split("\n").includes("  auto-update for hov: on"));
  });
});

test("a false someone set reads as turned-off, with nothing to run", () => {
  for (const files of [
    { settings: { extraKnownMarketplaces: { hov: { source: HOV_SRC, autoUpdate: false } } }, known: { hov: knownOf(HOV_SRC, { autoUpdate: true }) } },
    { settings: { extraKnownMarketplaces: { hov: { source: HOV_SRC } } }, known: { hov: knownOf(HOV_SRC, { autoUpdate: false }) } },
  ]) {
    withFake(files, (dir) => {
      const a = report(dir).marketplace.autoUpdate;
      assert.equal(a.state, "turned-off");
      assert.equal(a.next, null);
      assert.ok(detect(dir).stdout.includes("  auto-update for hov: off, switched off by someone, so left alone"));
    });
  }
});

test("a settings.json that does not parse makes auto-update unknown, and the rest of the report still runs", () => {
  withFake({ settings: "{ nope", known: { hov: knownOf(HOV_SRC) } }, (dir) => {
    const rep = report(dir);
    assert.equal(rep.marketplace.autoUpdate.state, "unknown");
    assert.match(rep.marketplace.autoUpdate.problem, /settings\.json does not parse as JSON$/);
    assert.equal(rep.marketplace.autoUpdate.next, null);
    assert.equal(rep.plugins.length, ALL.length);
  });
});

test("another publisher's plugin carries its marketplace's auto-update, by the name it is added under", () => {
  const codex = { source: "github", repo: "openai/codex-plugin-cc" };
  // Not added yet: the line to run after marketplaceAdd names the marketplace's own name.
  withFake({}, (dir) => {
    const r = row(report(dir), "codex");
    assert.ok(r.marketplaceAdd);
    assert.deepEqual(r.autoUpdate, { state: "not-added", where: null, problem: null, next: turnOn("openai-codex") });
  });
  // Added under another name, with auto-update on there.
  withFake(
    {
      marketplaces: [{ name: "hov" }, { name: "my-codex", source: "github", repo: "openai/codex-plugin-cc" }],
      settings: { extraKnownMarketplaces: { "my-codex": { source: codex, autoUpdate: true } } },
      known: { "my-codex": knownOf(codex) },
    },
    (dir) => {
      const r = row(report(dir), "codex");
      assert.equal(r.marketplaceAdd, null);
      assert.equal(r.id, "codex@my-codex");
      assert.deepEqual(r.autoUpdate, { state: "on", where: "settings.json", problem: null, next: null });
    },
  );
});

test("names a switch that stops every plugin update, from the environment or settings.json", () => {
  withFake({ settings: { env: { DISABLE_UPDATES: "1" } } }, (dir) => {
    assert.deepEqual(report(dir).updatesOff, [{ name: "DISABLE_UPDATES", where: "settings.json" }]);
    assert.deepEqual(report(dir, { DISABLE_AUTOUPDATER: "1" }).updatesOff, [
      { name: "DISABLE_AUTOUPDATER", where: "environment" },
      { name: "DISABLE_UPDATES", where: "settings.json" },
    ]);
    assert.deepEqual(report(dir, { FORCE_AUTOUPDATE_PLUGINS: "1" }).updatesOff, []);
    assert.ok(detect(dir).stdout.includes("  note: DISABLE_UPDATES is set (settings.json), which stops Claude Code updating any plugin"));
  });
});

test("a marketplace Claude Code lists but these files do not, or that settings.json lacks, gets no line to run", () => {
  // Listed, in neither file: added from somewhere else.
  withFake({}, (dir) => {
    const a = report(dir).marketplace.autoUpdate;
    assert.equal(a.state, "unknown");
    assert.equal(a.next, null);
    assert.match(a.problem, /nor .*known_marketplaces\.json lists hov, so it was added some other way/);
  });
  // In known_marketplaces.json only: off by default, but the helper has no entry to set.
  withFake({ known: { hov: knownOf(HOV_SRC) } }, (dir) => {
    const a = report(dir).marketplace.autoUpdate;
    assert.equal(a.state, "off");
    assert.equal(a.next, null);
    assert.match(a.problem, /settings\.json has no entry for hov, so it was added some other way\. To turn auto-update on: \/plugin, Marketplaces, hov, Enable auto-update\.$/);
    assert.ok(detect(dir).stdout.includes(`  auto-update for hov: off. ${a.problem}`));
  });
  // Another publisher's marketplace listed under its own name, in neither file.
  withFake({ marketplaces: [{ name: "hov" }, { name: "openai-codex", source: "github", repo: "openai/codex-plugin-cc" }] }, (dir) => {
    const r = row(report(dir), "codex");
    assert.equal(r.marketplaceAdd, null);
    assert.equal(r.autoUpdate.state, "unknown");
    assert.equal(r.autoUpdate.next, null);
  });
});

