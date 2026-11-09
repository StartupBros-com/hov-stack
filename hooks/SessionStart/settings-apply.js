"use strict";
// A cheap hash gate keeps unchanged session starts out of bash entirely.
try {
  const fs = require("node:fs");
  const path = require("node:path");
  const os = require("node:os");
  const { spawnSync } = require("node:child_process");
  const say = (text) => {
    const { writeHookOutput } = require("../lib/hook-output");
    writeHookOutput(text + "\n");
  };
  const home = os.homedir();
  const cfg =
    process.env.CLAUDE_HOME ||
    process.env.CLAUDE_CONFIG_DIR ||
    path.join(home, ".claude");
  if (
    fs.realpathSync(path.join(cfg, "hooks")) ===
      fs.realpathSync(path.resolve(__dirname, "..")) &&
    fs.statSync(path.join(cfg, "settings.json")).isFile()
  ) {
    const root = path.dirname(fs.realpathSync(path.join(cfg, "hooks")));
    const xdg = process.env.XDG_CONFIG_HOME;
    let overlayDir =
      process.env.HOV_STACK_OVERLAY ||
      path.join(
        xdg && path.isAbsolute(xdg) ? xdg : path.join(home, ".config"),
        "hov-stack",
      );
    if (!path.isAbsolute(overlayDir)) overlayDir = "";
    let dcgPath = path.join(home, ".local/bin/dcg");
    try {
      dcgPath = fs.realpathSync(dcgPath);
    } catch {}
    const hash = require(path.join(root, "lib/settings-apply.js")).inputsHash({
      root,
      overlayDir,
      dcgPath,
      cfg,
      env: process.env,
    });
    let stamp = "";
    try {
      stamp = fs
        .readFileSync(path.join(cfg, ".hov-stack/settings-apply.stamp"), "utf8")
        .trim();
    } catch {}
    if (stamp !== hash) {
      const run = spawnSync(
        "bash",
        [path.join(root, "sync.sh"), "apply-settings", "--quiet"],
        {
          timeout: Number(process.env.HOV_SETTINGS_APPLY_TIMEOUT_MS) || 15000,
          env: { ...process.env, CLAUDE_HOME: cfg },
          stdio: ["ignore", "pipe", "ignore"],
          encoding: "utf8",
          maxBuffer: 256 * 1024,
        },
      );
      const line = (run.stdout || "")
        .split("\n")
        .filter((s) => s.startsWith("settings: "))
        .at(-1);
      if (run.error || run.status !== 0 || !line)
        say(
          `[settings-apply] settings.json apply did not finish (exit ${run.status ?? run.error?.code ?? "unknown"}); sync.sh apply-settings --plan shows why`,
        );
      else {
        const status = line.slice(10);
        // sync.sh's own skips (host role, lock held) are deliberate or retried
        // next session; report only what needs a look.
        if (
          !status.startsWith("skipped (") &&
          /conflict\(s\)|held deny|skipped/.test(status)
        )
          say("[settings-apply] settings.json: " + status);
        else if (status.startsWith("applied "))
          say(
            `[settings-apply] settings.json: applied ${status.match(/^applied (\d+)/)[1]} change(s) from the harness checkout`,
          );
      }
    }
  }
} catch {}
process.exitCode = 0;
