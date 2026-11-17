"use strict";
// A cheap hash gate keeps unchanged session starts out of bash entirely.
//
// Hook code on disk and its registration in settings.json move together. This hook is the
// backstop for a checkout moved by a route other than ./setup --sync (a hand `git pull`): when
// the inputs hash differs from the stamp it merges settings.json again, through sync.sh on a
// host sync.sh keeps a record for, through `./setup --sync --no-pull` on an install ./setup
// keeps a record for. It also starts the detached ./setup --sync that moves the checkout, once
// per interval, and shows the last such run's result once.
try {
  const fs = require("node:fs");
  const path = require("node:path");
  const os = require("node:os");
  const { spawnSync, spawn } = require("node:child_process");
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
    const state = path.join(cfg, ".hov-stack");
    const exists = (f) => {
      try {
        fs.statSync(f);
        return true;
      } catch {
        return false;
      }
    };
    const syncBase = exists(path.join(state, "settings-base.json"));
    const seedBase = exists(path.join(state, "setup-settings-base.json"));
    const setupFile = path.join(root, "setup");

    // A sync holds sync.lock (a directory with its pid) while it runs. A lock whose pid is dead,
    // or that is older than 15 minutes, is a crashed run's leftover and counts as absent, as
    // ./setup's own sync_lock_stale judges it (a lock with no pid yet is young for a minute).
    const lockLive = () => {
      const dir = path.join(state, "sync.lock");
      let st;
      try {
        st = fs.statSync(dir);
      } catch {
        return false;
      }
      const age = Date.now() - st.mtimeMs;
      let pid = "";
      try {
        pid = fs.readFileSync(path.join(dir, "pid"), "utf8").trim();
      } catch {}
      if (!/^[0-9]+$/.test(pid)) return age < 60 * 1000;
      if (age > 15 * 60 * 1000) return false;
      try {
        process.kill(Number(pid), 0);
        return true;
      } catch (e) {
        return e.code === "EPERM";
      }
    };

    // The last ./setup --sync result: claimed by renaming it, so the first session to start
    // shows it; a result equal to the one shown before stays quiet (an owner host syncs every
    // few minutes and a standing refusal must not print at every start). Nothing is shown
    // while a sync still holds its lock. Returns whether a result was claimed.
    const showResult = () => {
      try {
        const result = path.join(state, "sync-result");
        const shown = path.join(state, "sync-result.shown");
        if (!exists(result) || lockLive()) return false;
        const parse = (f) => {
          const [epoch, kind, ...rest] = fs
            .readFileSync(f, "utf8")
            .replace(/\n$/, "")
            .split("\t");
          return { epoch, kind, text: rest.join("\t") };
        };
        const now = parse(result);
        let before = null;
        try {
          before = parse(shown);
        } catch {}
        try {
          fs.renameSync(result, shown);
        } catch {
          return false;
        }
        const speak = ["moved", "notice", "warning", "blocked", "failed", "moving"];
        if (
          speak.includes(now.kind) &&
          !(before && before.kind === now.kind && before.text === now.text)
        )
          say(
            now.kind === "moving"
              ? `[hov-stack] ${now.text}; that sync did not finish, and ./setup --sync finishes it`
              : `[hov-stack] ${now.text}`,
          );
        return true;
      } catch {
        return false;
      }
    };
    showResult();

    const hash = require(path.join(root, "lib/settings-apply.js")).gateHash({
      cfg,
      home,
      env: process.env,
    });
    let stamp = "";
    try {
      stamp = fs
        .readFileSync(path.join(cfg, ".hov-stack/settings-apply.stamp"), "utf8")
        .trim();
    } catch {}
    if (stamp !== hash) {
      const timeout = Number(process.env.HOV_SETTINGS_APPLY_TIMEOUT_MS) || 15000;
      if (!syncBase && seedBase && exists(setupFile)) {
        // An install ./setup keeps a record for: the merge ./setup --sync makes, without a
        // pull, which is how a checkout moved by hand gets its settings.json registered.
        const run = spawnSync("bash", [setupFile, "--sync", "--no-pull"], {
          timeout,
          env: {
            ...process.env,
            CLAUDE_CONFIG_DIR: cfg,
            HOV_SYNC_LOCK_WAIT: "0",
          },
          stdio: ["ignore", "pipe", "ignore"],
          encoding: "utf8",
          maxBuffer: 256 * 1024,
        });
        const line = (run.stdout || "")
          .split("\n")
          .filter((s) => s.startsWith("sync: "))
          .at(-1);
        if (run.error || !line || (run.status !== 0 && !/^sync: (blocked|failed):/.test(line)))
          say(
            `[settings-apply] settings.json apply did not finish (exit ${run.status ?? run.error?.code ?? "unknown"}); ./setup --sync --no-pull shows why`,
          );
        else {
          // A change made is an event worth a line of its own. A refusal, a failure or a
          // warning goes through the result file, so it is claimed and deduplicated like a
          // background run's; setup could not write that file only when nothing was claimed.
          if (/^sync: current: .*merged [1-9][0-9]* change/.test(line))
            say("[settings-apply] " + line);
          const claimed = showResult();
          if (!claimed && /^sync: (blocked|failed|warning):/.test(line))
            say("[settings-apply] " + line);
        }
      } else {
        const run = spawnSync(
          "bash",
          [path.join(root, "sync.sh"), "apply-settings", "--quiet"],
          {
            timeout,
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

    // The trigger: ./setup --sync, detached, once per interval, on an install with a record
    // (without one --sync would only refuse; the adopt notice is launchpad-advisory's job).
    // 5 minutes where sync.sh keeps the record (an owner host), a day for a member.
    try {
      if (
        process.env.HOV_UPDATE !== "off" &&
        exists(setupFile) &&
        (syncBase || seedBase)
      ) {
        const given = process.env.HOV_SYNC_INTERVAL;
        const interval =
          given !== undefined && /^[0-9]+$/.test(given)
            ? Number(given)
            : syncBase
              ? 300
              : 86400;
        const started = path.join(state, "sync-started");
        let last = 0;
        try {
          last = fs.statSync(started).mtimeMs;
        } catch {}
        if (Date.now() - last >= interval * 1000 && !lockLive()) {
          fs.writeFileSync(started, String(Date.now()) + "\n");
          const fd = fs.openSync(path.join(state, "sync.log"), "w", 0o600);
          try {
            const child = spawn("bash", [setupFile, "--sync"], {
              detached: true,
              stdio: ["ignore", fd, fd],
              env: {
                ...process.env,
                CLAUDE_CONFIG_DIR: cfg,
                HOV_SYNC_LOCK_WAIT: "0",
              },
            });
            child.on("error", () => {});
            child.unref();
          } finally {
            fs.closeSync(fd);
          }
        }
      }
    } catch {}
  }
} catch {}
process.exitCode = 0;
