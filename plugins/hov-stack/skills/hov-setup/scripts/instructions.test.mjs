import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
const here = dirname(fileURLToPath(import.meta.url));
const sources = join(here, "../instructions");
const offers = JSON.parse(readFileSync(join(here, "offers.json"))).offers;
const source = (name) => readFileSync(join(sources, `${name}.md`), "utf8").trim();
test("instruction files are nonempty Markdown named for an offer", () => {
  const files = readdirSync(sources);
  assert.ok(files.length);
  for (const file of files) {
    assert.ok(file.endsWith(".md"), file);
    assert.ok(
      offers.some((o) => o.name === file.slice(0, -3)),
      file,
    );
    assert.ok(readFileSync(join(sources, file), "utf8").trim(), file);
  }
});
function withFake(run) {
  const dir = mkdtempSync(join(tmpdir(), "hov-instructions-"));
  try {
    const cfg = join(dir, "cfg"),
      target = join(cfg, "rules/hov-stack-tools.md");
    mkdirSync(cfg);
    writeFileSync(join(dir, "plugins.json"), "[]");
    writeFileSync(
      join(dir, "claude"),
      `#!/bin/sh
if [ -f "$FAKE_DIR/fail" ]; then echo 'claude: not logged in' >&2; exit 7; fi
case "$*" in
  'plugin marketplace list --json') echo '[]' ;;
  'plugin list --json') /bin/cat "$FAKE_DIR/plugins.json" ;;
  *) exit 64 ;;
esac
`,
    );
    chmodSync(join(dir, "claude"), 0o755);
    const env = {
      PATH: dir,
      FAKE_DIR: dir,
      HOV_SETUP_EXTRA_BIN_DIRS: "",
      HOV_SETUP_PLATFORM: "linux-x86_64",
    };
    const cli = (...args) =>
      spawnSync(
        process.execPath,
        [join(here, "instructions.mjs"), "--config-dir", cfg, ...args],
        { encoding: "utf8", env },
      );
    const bin = (name, where = dir) => {
      mkdirSync(where, { recursive: true });
      writeFileSync(join(where, name), "#!/bin/sh\nexit 99\n");
      chmodSync(join(where, name), 0o755);
    };
    const tool = () => bin("gh");
    const plugins = (rows) =>
      writeFileSync(join(dir, "plugins.json"), JSON.stringify(rows));
    run({ dir, cfg, target, cli, env, bin, tool, plugins });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
test("installed tools and plugins contribute in offer order; a disabled plugin does not", () =>
  withFake(({ target, cli, bin, tool, plugins }) => {
    tool();
    bin("codex");
    plugins([
      { id: "pro-gate@hov", scope: "user" },
      { id: "codex@openai-codex", scope: "user", enabled: false },
    ]);
    const r = cli("--json");
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(r.stdout).tools, ["gh", "pro-gate"]);
    assert.deepEqual(JSON.parse(r.stdout).leftOut, []);
    const text = readFileSync(target, "utf8");
    assert.ok(text.includes(source("gh")));
    assert.ok(text.includes(source("pro-gate")));
    assert.ok(text.indexOf("- Use `gh`") < text.indexOf("- One `/pro-gate`"));
    assert.ok(!text.includes("Delegate implementation"));
  }));
test("a plugin installed only at another scope contributes nothing", () =>
  withFake(({ target, cli, bin, plugins }) => {
    bin("codex");
    plugins([{ id: "codex@openai-codex", scope: "project", projectPath: "/p" }]);
    const r = cli("--json");
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(r.stdout).tools, []);
    assert.deepEqual(JSON.parse(r.stdout).leftOut, []);
    assert.equal(existsSync(target), false);
  }));
test("a tool found only off PATH is left out, with where it is", () =>
  withFake(({ dir, target, cli, env, bin }) => {
    const off = join(dir, "off");
    bin("gh", off);
    env.HOV_SETUP_EXTRA_BIN_DIRS = off;
    const r = cli("--json");
    assert.equal(r.status, 0, r.stderr);
    const out = JSON.parse(r.stdout);
    assert.deepEqual(out.tools, []);
    assert.deepEqual(out.leftOut, [
      { name: "gh", why: `${join(off, "gh")} is not on PATH` },
    ]);
    assert.match(out.reason, /left out: gh \(.* is not on PATH\)/);
    assert.equal(existsSync(target), false);
    env.PATH = `${dir}:${off}`;
    assert.deepEqual(JSON.parse(cli("--json").stdout).tools, ["gh"]);
    assert.ok(readFileSync(target, "utf8").includes(source("gh")));
  }));
test("codex contributes only with the codex program on PATH", () =>
  withFake(({ target, cli, bin, plugins }) => {
    plugins([{ id: "codex@openai-codex", scope: "user" }]);
    let out = JSON.parse(cli("--json").stdout);
    assert.deepEqual(out.tools, []);
    assert.deepEqual(out.leftOut, [
      { name: "codex", why: "the codex program is not on PATH" },
    ]);
    assert.equal(existsSync(target), false);
    bin("codex");
    out = JSON.parse(cli("--json").stdout);
    assert.deepEqual(out.tools, ["codex"]);
    assert.ok(readFileSync(target, "utf8").includes(source("codex")));
  }));
test("absent lines disappear and no contributors removes the generated file", () =>
  withFake(({ dir, target, cli, tool }) => {
    tool();
    assert.equal(cli().status, 0);
    rmSync(join(dir, "gh"));
    const r = cli();
    assert.equal(r.status, 0);
    assert.equal(
      r.stdout,
      "ok: rules/hov-stack-tools.md removed; no installed tool needs instruction lines\n",
    );
    assert.equal(existsSync(target), false);
  }));
test("a second run preserves bytes and mtime and says the file is current", () =>
  withFake(({ target, cli, tool }) => {
    tool();
    assert.equal(cli().stdout, "ok: rules/hov-stack-tools.md updated; mentions gh\n");
    const before = readFileSync(target),
      mtime = statSync(target).mtimeMs;
    const r = cli();
    assert.equal(r.status, 0);
    assert.equal(r.stdout, "ok: rules/hov-stack-tools.md is current; mentions gh\n");
    assert.deepEqual(readFileSync(target), before);
    assert.equal(statSync(target).mtimeMs, mtime);
  }));
for (const [kind, fix] of [
  ["rules file symlink", /is a symlink, so it is left as it is: remove it and run \.\/setup again/],
  ["unowned file", /was not written by \.\/setup, so it is left as it is: move it aside and run \.\/setup again/],
  ["rules directory symlink to a file", /rules\/ is a symlink to something that is not a directory.*run \.\/setup again/],
]) {
  test(`${kind} is blocked with its fix and untouched`, () =>
    withFake(({ dir, cfg, target, cli, tool }) => {
      tool();
      const outside = join(dir, "outside");
      mkdirSync(outside);
      writeFileSync(join(outside, "mine"), "mine");
      if (kind === "rules directory symlink to a file")
        symlinkSync(join(outside, "mine"), join(cfg, "rules"));
      else {
        mkdirSync(join(cfg, "rules"));
        if (kind === "rules file symlink") symlinkSync(join(outside, "mine"), target);
        else writeFileSync(target, "mine");
      }
      for (const args of [[], ["--check"]]) {
        const r = cli(...args);
        assert.equal(r.status, 1);
        assert.match(r.stdout, /^blocked: /);
        assert.match(r.stdout, fix);
      }
      assert.deepEqual(readdirSync(outside), ["mine"]);
      assert.equal(readFileSync(join(outside, "mine"), "utf8"), "mine");
      if (kind === "unowned file") assert.equal(readFileSync(target, "utf8"), "mine");
    }));
}
test("a symlinked rules/ is never written; it is missing until a rules file there has the lines", () =>
  withFake(({ dir, cfg, cli, tool }) => {
    tool();
    const outside = join(dir, "outside");
    mkdirSync(outside);
    symlinkSync(outside, join(cfg, "rules"));
    for (const args of [[], ["--check"]]) {
      const r = cli(...args);
      assert.equal(r.status, 3);
      assert.match(r.stdout, /^missing: rules\/ is a symlink, so \.\/setup writes nothing into it: add the lines in .*gh\.md to a rules file there\n$/);
      assert.deepEqual(readdirSync(outside), []);
    }
    mkdirSync(join(outside, "mine"));
    writeFileSync(join(outside, "mine", "tools.md"), `# mine\n${source("gh")}\n`);
    const r = cli();
    assert.equal(r.status, 0, r.stdout);
    assert.equal(r.stdout, "ok: rules/ is a symlink, and a rules file there has the lines for gh\n");
    assert.deepEqual(readdirSync(outside), ["mine"]);
  }));
test("check reports missing stale and ok without writing", () =>
  withFake(({ dir, target, cli, tool }) => {
    tool();
    let r = cli("--check");
    assert.equal(r.status, 3);
    assert.equal(r.stdout, "missing: rules/hov-stack-tools.md is not written yet: run ./setup\n");
    assert.equal(existsSync(target), false);
    assert.equal(cli().status, 0);
    const before = readFileSync(target),
      mtime = statSync(target).mtimeMs;
    r = cli("--check");
    assert.equal(r.status, 0);
    assert.match(r.stdout, /^ok: /);
    rmSync(join(dir, "gh"));
    r = cli("--check");
    assert.equal(r.status, 3);
    assert.equal(
      r.stdout,
      "stale: rules/hov-stack-tools.md names tools that are no longer installed: run ./setup\n",
    );
    assert.deepEqual(readFileSync(target), before);
    assert.equal(statSync(target).mtimeMs, mtime);
  }));
test("failed detection leaves the existing file untouched", () =>
  withFake(({ dir, target, cli, tool }) => {
    tool();
    assert.equal(cli().status, 0);
    const before = readFileSync(target),
      mtime = statSync(target).mtimeMs;
    writeFileSync(join(dir, "fail"), "");
    for (const args of [[], ["--check"]]) {
      const r = cli(...args);
      assert.equal(r.status, 1);
      assert.match(r.stdout, /^blocked: .*exited 7: claude: not logged in/);
      assert.equal(r.stdout.split("\n").length, 2, r.stdout);
    }
    assert.deepEqual(readFileSync(target), before);
    assert.equal(statSync(target).mtimeMs, mtime);
  }));
