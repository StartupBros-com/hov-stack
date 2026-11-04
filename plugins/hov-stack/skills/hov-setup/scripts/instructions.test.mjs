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
    const cli = (...args) =>
      spawnSync(
        process.execPath,
        [join(here, "instructions.mjs"), "--config-dir", cfg, ...args],
        {
          encoding: "utf8",
          env: {
            PATH: dir,
            FAKE_DIR: dir,
            HOV_SETUP_EXTRA_BIN_DIRS: "",
            HOV_SETUP_PLATFORM: "linux-x86_64",
          },
        },
      );
    const tool = () => {
      writeFileSync(join(dir, "gh"), "#!/bin/sh\nexit 99\n");
      chmodSync(join(dir, "gh"), 0o755);
    };
    run({ dir, cfg, target, cli, tool });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
test("installed tools and plugins contribute in offer order; disabled and other scopes do not", () =>
  withFake(({ dir, target, cli, tool }) => {
    tool();
    writeFileSync(
      join(dir, "plugins.json"),
      JSON.stringify([
        { id: "pro-gate@hov", scope: "user" },
        { id: "codex@openai-codex", scope: "user", enabled: false },
      ]),
    );
    const r = cli("--json");
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(r.stdout).tools, ["gh", "pro-gate"]);
    const text = readFileSync(target, "utf8");
    assert.ok(
      text.includes(readFileSync(join(sources, "gh.md"), "utf8").trim()),
    );
    assert.ok(
      text.includes(readFileSync(join(sources, "pro-gate.md"), "utf8").trim()),
    );
    assert.ok(text.indexOf("- Use `gh`") < text.indexOf("- One `/pro-gate`"));
    assert.ok(!text.includes("Delegate implementation"));
  }));
test("absent lines disappear and no contributors removes the generated file", () =>
  withFake(({ dir, target, cli, tool }) => {
    tool();
    assert.equal(cli().status, 0);
    rmSync(join(dir, "gh"));
    assert.equal(cli().status, 0);
    assert.equal(existsSync(target), false);
  }));
test("a second run preserves bytes and mtime", () =>
  withFake(({ target, cli, tool }) => {
    tool();
    assert.equal(cli().status, 0);
    const before = readFileSync(target),
      mtime = statSync(target).mtimeMs;
    assert.equal(cli().status, 0);
    assert.deepEqual(readFileSync(target), before);
    assert.equal(statSync(target).mtimeMs, mtime);
  }));
for (const kind of [
  "rules directory symlink",
  "rules file symlink",
  "unowned file",
]) {
  test(`${kind} is blocked and untouched`, () =>
    withFake(({ dir, cfg, target, cli, tool }) => {
      tool();
      const outside = join(dir, "outside");
      mkdirSync(outside);
      if (kind === "rules directory symlink")
        symlinkSync(outside, join(cfg, "rules"));
      else {
        mkdirSync(join(cfg, "rules"));
        if (kind === "rules file symlink") {
          writeFileSync(join(outside, "mine"), "mine");
          symlinkSync(join(outside, "mine"), target);
        } else writeFileSync(target, "mine");
      }
      const r = cli();
      assert.equal(r.status, 1);
      assert.match(r.stdout, /blocked/);
      assert.match(r.stdout, /symlink|not generated/);
      assert.deepEqual(
        readdirSync(outside),
        kind === "rules file symlink" ? ["mine"] : [],
      );
      if (kind !== "rules directory symlink")
        assert.equal(readFileSync(target, "utf8"), "mine");
    }));
}
test("check reports missing stale and ok without writing", () =>
  withFake(({ dir, target, cli, tool }) => {
    tool();
    let r = cli("--check");
    assert.equal(r.status, 3);
    assert.match(r.stdout, /missing/);
    assert.equal(existsSync(target), false);
    assert.equal(cli().status, 0);
    const before = readFileSync(target),
      mtime = statSync(target).mtimeMs;
    r = cli("--check");
    assert.equal(r.status, 0);
    assert.match(r.stdout, /ok/);
    rmSync(join(dir, "gh"));
    r = cli("--check");
    assert.equal(r.status, 3);
    assert.match(r.stdout, /stale/);
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
      assert.match(r.stdout + r.stderr, /exited 7: claude: not logged in/);
    }
    assert.deepEqual(readFileSync(target), before);
    assert.equal(statSync(target).mtimeMs, mtime);
  }));
