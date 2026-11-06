#!/usr/bin/env node
/*
  hov-setup detector: which of the things /hov-setup offers are installed, in walkthrough
  order, the next step for each, and which other hov plugins ./setup already installed (for the
  closing tour). What is offered lives in offers.json beside this file: plugins on the hov
  marketplace, plugins on another publisher's marketplace, programs on PATH, a paid skill set
  with its manager program, and the helper programs some of those need.

  Read-only. It runs `claude plugin marketplace list --json` and `claude plugin list --json`
  and no other program, and reads settings.json and plugins/known_marketplaces.json in the
  Claude Code config dir ($CLAUDE_CONFIG_DIR, else ~/.claude) for each marketplace's
  auto-update setting, the way autoupdate.mjs beside it does: a tool is found by looking for an executable file of its name in the
  PATH directories and a few usual install directories, never by running it. One of hov-stack's
  own commands that runs from a Python environment (`venv` in offers.json) counts as installed
  only once that environment's file is there too, checked the same way, and is not applicable
  where ./setup has not linked the command. A plugin counts
  only when it is installed at user scope, the rule ./setup uses; a project-scope copy is named
  in `otherScopes` and does not count. A plugin from another publisher's marketplace is found
  by where its marketplace comes from (its GitHub repository), not by the name the user gave
  that marketplace.

  Usage:
    node detect.mjs [--json]

  Exit: 0 report printed; 1 a claude read failed (its error is passed through, and nothing
  is reported as absent); 2 bad usage.

  Test-only environment overrides:
    HOV_SETUP_PROC_VERSION     the file read to tell WSL2 apart (default /proc/version).
    HOV_SETUP_PLATFORM         the platform name, e.g. linux-x86_64 (default: from the machine).
    HOV_SETUP_EXTRA_BIN_DIRS   a ':'-separated list that replaces the extra directories searched
                               after PATH (default ~/.local/bin, /opt/homebrew/bin, /usr/local/bin).
*/
import { accessSync, constants, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, isAbsolute, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { configDir, readFiles, stateOf, updatesOffBy } from "./autoupdate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
// The skill directory: the one holding SKILL.md, the parent of the scripts directory.
const SKILL_DIR = dirname(here);
const AUTOUPDATE = join(here, "autoupdate.mjs");

const data = JSON.parse(readFileSync(new URL("./offers.json", import.meta.url), "utf8"));

export const MARKETPLACE = data.marketplace;
export const GROUPS = data.groups;
export const OFFERS = data.offers;
export const HELPERS = data.helpers;

// The hov plugins that need a login, a paid plan or a choice, in walkthrough order, and the
// free tuning plugins. Derived from offers.json so nothing that imports them breaks.
export const PLUGINS = OFFERS.filter((o) => o.kind === "plugin" && o.group !== "tuning").map(
  ({ name, what, wslOnly }) => (wslOnly ? { name, what, wslOnly } : { name, what }),
);
export const EXTRAS = OFFERS.filter((o) => o.kind === "plugin" && o.group === "tuning").map(
  ({ name, what, wslOnly }) => (wslOnly ? { name, what, wslOnly } : { name, what }),
);

// What ./setup installs (lib/default-plugins.txt) and the skill pack, for the closing tour.
// A hov plugin not named here is still listed, with `what` and `start` null.
export const KNOWN = {
  papercut: { what: "notices when tools trip Claude up and ranks the repeat offenders", start: "/papercut:papercut" },
  "skill-tuner": { what: "tells you whether a change to your instructions for Claude helped", start: "/skill-tuner:tune" },
  "memory-dream": { what: "tidies Claude's memory notes, with your OK on every change", start: "/memory-dream:dream" },
  "design-rails": { what: "keeps Claude on your app's design system", start: "/design-rails:design-rails" },
  "hov-stack": { what: "the hov-stack skill pack", start: null },
};

const NOT_WSL = "WSL2 only; on macOS or native Windows, use the Claude in Chrome extension";

class ReadError extends Error {}

function readClaudeJson(args) {
  const r = spawnSync("claude", args, { encoding: "utf8" });
  const cmd = `claude ${args.join(" ")}`;
  if (r.error) throw new ReadError(`could not run '${cmd}': ${r.error.message}`);
  if (r.status !== 0) {
    const why = (r.stderr || "").trim() || `exit ${r.status}`;
    throw new ReadError(`'${cmd}' exited ${r.status}: ${why}`);
  }
  try {
    const rows = JSON.parse(r.stdout);
    if (!Array.isArray(rows)) throw new Error("not a list");
    return rows;
  } catch (e) {
    throw new ReadError(`'${cmd}' printed output that is not a JSON list: ${e.message}`);
  }
}

function onWsl() {
  const file = process.env.HOV_SETUP_PROC_VERSION || "/proc/version";
  try {
    return /microsoft/i.test(readFileSync(file, "utf8"));
  } catch {
    return false;
  }
}

function platformName() {
  const override = process.env.HOV_SETUP_PLATFORM;
  if (override) return override;
  const { platform, arch } = process;
  if (platform === "darwin" && arch === "arm64") return "darwin-arm64";
  if (platform === "linux" && arch === "x64") return "linux-x86_64";
  if (platform === "linux" && arch === "arm64") return "linux-aarch64";
  return `${platform}-${arch}`;
}

// Where to look for a program: the PATH directories in order, then the usual install
// directories, with no repeats.
export function searchDirs() {
  const pathDirs = (process.env.PATH || "").split(delimiter).filter(Boolean);
  const extraEnv = process.env.HOV_SETUP_EXTRA_BIN_DIRS;
  const extra =
    extraEnv !== undefined
      ? extraEnv.split(":").filter(Boolean)
      : [join(homedir(), ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin"];
  const dirs = [...new Set([...pathDirs, ...extra])];
  return { dirs, onPath: new Set(pathDirs) };
}

function isExecutableFile(p) {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// Finds `bin` without running it: the first candidate directory holding an executable regular
// file of that name.
export function findBin(bin, search) {
  for (const d of search.dirs) {
    const p = join(d, bin);
    if (isExecutableFile(p)) return { path: p, onPath: search.onPath.has(d) };
  }
  return { path: null, onPath: false };
}

// The user-scope row for `id` decides the state; rows at other scopes are named but do not count.
function pluginState(id, installed, wslOnly, wsl) {
  const rows = installed.filter((r) => r && r.id === id);
  const user = rows.find((r) => r.scope === "user");
  const out = {
    state: "absent",
    version: user ? user.version || null : null,
    installPath: user ? user.installPath || null : null,
    otherScopes: rows.filter((r) => r.scope !== "user").map((r) => r.scope),
    next: `claude plugin install ${id} --scope user`,
  };
  if (wslOnly && !wsl) {
    out.state = "not-applicable";
    out.next = NOT_WSL;
  } else if (user && user.enabled === false) {
    out.state = "disabled";
    out.next = `claude plugin enable ${id} --scope user`;
  } else if (user) {
    out.state = "installed";
    out.next = null;
  }
  return out;
}

function sourceMatches(m, github) {
  if (!m) return false;
  const want = github.toLowerCase();
  if (typeof m.repo === "string" && m.repo.toLowerCase() === want) return true;
  if (typeof m.url === "string") {
    const url = m.url.toLowerCase().replace(/\/+$/, "").replace(/\.git$/, "").replace(/\/+$/, "");
    return url === `https://github.com/${want}`;
  }
  return false;
}

// Where auto-update stands for one marketplace (autoupdate.mjs has the states), and the line
// that turns it on: run it after adding the marketplace, or now when it is off by default.
// added is whether Claude Code lists the marketplace. next is offered only where the helper
// can act: an entry in this settings.json for it to set.
function autoUpdateOf(name, files, added) {
  const s = stateOf(name, files);
  const out = { state: s.state, where: s.where, problem: s.problem, next: null };
  if (s.state === "not-added" && added) {
    // Listed, yet neither file here names it: it came from a project's or an organization's settings.
    out.state = "unknown";
    out.problem = `neither ${files.settingsPath} nor ${files.knownPath} lists ${name}, so it was added some other way, such as a project's settings`;
  } else if (s.state === "not-added" || (s.state === "off" && s.declared)) {
    out.next = `node "${AUTOUPDATE}" ${name}`;
  } else if (s.state === "off") {
    out.problem = `${files.settingsPath} has no entry for ${name}, so it was added some other way. To turn auto-update on: /plugin, Marketplaces, ${name}, Enable auto-update.`;
  }
  return out;
}

function fill(line, uvPath) {
  return line.split("<skill-dir>").join(SKILL_DIR).split("<uv>").join(uvPath);
}

// The folder of the Python environment a hov-stack command runs from: the path in its
// override variable when that is set, else its folder under the home directory.
function venvDir(v) {
  const override = v.env ? process.env[v.env] : undefined;
  return override || join(homedir(), v.dir);
}

// Shared by tools, paid-skills and helpers: where the program is and what to run if it is not.
// A hov-stack command with a venv is ready only once that environment is built, and is not
// applicable where ./setup has not linked it.
function toolFields(o, platform, search, uvPath) {
  const keys = Object.keys(o.install);
  if (!keys.includes(platform)) {
    return {
      bin: o.bin,
      path: null,
      onPath: false,
      venv: null,
      state: "not-applicable",
      next: `only offered on ${keys.join(", ")}`,
    };
  }
  const found = findBin(o.bin, search);
  if (o.venv) {
    if (!found.path) {
      return { bin: o.bin, path: null, onPath: false, venv: null, state: "not-applicable", next: "comes with a hov-stack checkout: its ./setup links it into ~/.local/bin" };
    }
    const dir = venvDir(o.venv);
    const built = isAbsolute(dir) && isExecutableFile(join(dir, o.venv.file));
    return {
      bin: o.bin,
      path: found.path,
      onPath: found.onPath,
      venv: dir,
      state: built ? "installed" : "absent",
      next: built ? null : fill(o.install[platform], uvPath),
    };
  }
  return {
    bin: o.bin,
    path: found.path,
    onPath: found.onPath,
    venv: null,
    state: found.path ? "installed" : "absent",
    next: found.path ? null : fill(o.install[platform], uvPath),
  };
}

export function detect() {
  const marketplaces = readClaudeJson(["plugin", "marketplace", "list", "--json"]);
  const installed = readClaudeJson(["plugin", "list", "--json"]);
  const wsl = onWsl();
  const platform = platformName();
  const search = searchDirs();
  const files = readFiles(configDir());

  // <uv> in an install line is the uv the detector found, else plain `uv`.
  const uvHelper = HELPERS.find((h) => h.name === "uv");
  const uvFound = uvHelper ? findBin(uvHelper.bin, search) : { path: null };
  const uvPath = uvFound.path || "uv";
  const helpers = HELPERS.map((h) => {
    const f = toolFields(h, platform, search, uvPath);
    return { name: h.name, publisher: h.publisher, what: h.what, bin: f.bin, path: f.path, onPath: f.onPath, state: f.state, next: f.next };
  });

  const plugins = OFFERS.map((o) => {
    const head = { name: o.name, kind: o.kind, group: o.group, publisher: o.publisher, what: o.what };
    if (o.kind === "plugin") {
      const id = `${o.name}@${MARKETPLACE}`;
      const s = pluginState(id, installed, o.wslOnly, wsl);
      return {
        ...head,
        state: s.state,
        next: s.next,
        version: s.version,
        installPath: s.installPath,
        otherScopes: s.otherScopes,
      };
    }
    if (o.kind === "other-plugin") {
      const matched = [];
      for (const m of marketplaces) {
        if (sourceMatches(m, o.marketplace.github) && typeof m.name === "string" && !matched.includes(m.name)) matched.push(m.name);
      }
      let id;
      let mname;
      let marketplaceAdd = null;
      if (matched.length) {
        const hit = matched.find((n) => installed.some((r) => r && r.id === `${o.plugin}@${n}` && r.scope === "user"));
        mname = hit ?? matched[0];
      } else {
        mname = o.marketplace.name;
        marketplaceAdd = `claude plugin marketplace add ${o.marketplace.github}`;
      }
      id = `${o.plugin}@${mname}`;
      const s = pluginState(id, installed, o.wslOnly, wsl);
      return {
        ...head,
        state: s.state,
        next: s.next,
        version: s.version,
        installPath: s.installPath,
        otherScopes: s.otherScopes,
        id,
        marketplaceAdd,
        autoUpdate: autoUpdateOf(mname, files, matched.length > 0),
      };
    }
    // tool and paid-skills
    const f = toolFields(o, platform, search, uvPath);
    const needs = (o.needs || []).map((n) => {
      const h = helpers.find((x) => x.name === n);
      return { name: n, path: h ? h.path : null, onPath: h ? h.onPath : false, next: h ? h.next : null };
    });
    return { ...head, state: f.state, next: f.next, bin: f.bin, path: f.path, onPath: f.onPath, venv: f.venv, needs };
  });

  const offeredNames = new Set(OFFERS.map((p) => p.name));
  const suffix = `@${MARKETPLACE}`;
  const alsoInstalled = installed
    .filter((r) => r && typeof r.id === "string" && r.id.endsWith(suffix) && r.scope === "user")
    .filter((r) => !offeredNames.has(r.id.slice(0, -suffix.length)))
    .map((r) => {
      const name = r.id.slice(0, -suffix.length);
      const known = KNOWN[name] || { what: null, start: null };
      return { name, version: r.version || null, enabled: r.enabled !== false, what: known.what, start: known.start };
    });
  const added = marketplaces.some((m) => m && m.name === MARKETPLACE);
  return {
    marketplace: {
      name: MARKETPLACE,
      added,
      autoUpdate: autoUpdateOf(MARKETPLACE, files, added),
    },
    updatesOff: updatesOffBy(process.env, files),
    platform,
    wsl,
    plugins,
    helpers,
    alsoInstalled,
  };
}

function line(p) {
  const isPlugin = p.kind === "plugin" || p.kind === "other-plugin";
  const ver = isPlugin && p.version ? ` ${p.version}` : "";
  const scopes = isPlugin ? p.otherScopes.join(", ") : "";
  if (p.state === "installed") {
    if (isPlugin) return `  ${p.name}: installed${ver}${scopes ? ` (also at ${scopes} scope)` : ""}`;
    return `  ${p.name}: installed (${p.path})${p.onPath ? "" : ". Not on PATH"}`;
  }
  if (p.state === "disabled") return `  ${p.name}: installed${ver} but disabled. Enable: ${p.next}`;
  if (p.state === "not-applicable") return `  ${p.name}: not applicable here: ${p.next}`;
  const only = scopes ? ` (installed at ${scopes} scope only, which does not count)` : "";
  if (p.marketplaceAdd) return `  ${p.name}: absent${only}. Add its marketplace first: ${p.marketplaceAdd}. Then install: ${p.next}`;
  if (p.venv && p.path) return `  ${p.name}: ${p.path} is linked, but its Python environment (${p.venv}) is not built. Install: ${p.next}`;
  return `  ${p.name}: absent${only}. Install: ${p.next}`;
}

function autoUpdateLine(a) {
  const head = `  auto-update for ${MARKETPLACE}:`;
  if (a.state === "on") return `${head} on`;
  if (a.state === "turned-off") return `${head} off, switched off by someone, so left alone`;
  if (a.state === "off") return a.next ? `${head} off. Turn on: ${a.next}` : `${head} off. ${a.problem}`;
  return `${head} could not tell: ${a.problem}`;
}

function text(report) {
  const lines = [];
  if (report.marketplace.added) {
    lines.push(`hov-setup: the ${MARKETPLACE} marketplace is added.`);
  } else {
    lines.push(
      `hov-setup: the ${MARKETPLACE} marketplace is not added, so none of the install lines below work yet.`,
      "  Re-run ./setup from your hov-stack checkout (it adds the marketplace), then run this again.",
    );
  }
  if (report.marketplace.added) lines.push(autoUpdateLine(report.marketplace.autoUpdate));
  for (const off of report.updatesOff) {
    lines.push(`  note: ${off.name} is set (${off.where}), which stops Claude Code updating any plugin`);
  }
  for (const p of report.plugins) lines.push(line(p));
  for (const h of report.helpers) lines.push(line({ ...h, kind: "helper" }));
  if (report.alsoInstalled.length) {
    const names = report.alsoInstalled.map(
      (p) => `${p.name}${p.version ? ` ${p.version}` : ""}${p.enabled ? "" : " (disabled)"}`,
    );
    lines.push(`also installed: ${names.join(", ")}`);
  }
  return lines.join("\n");
}

function main(argv) {
  const json = argv.includes("--json");
  const unknown = argv.filter((a) => a !== "--json");
  if (unknown.length) {
    process.stderr.write(`hov-setup: unknown argument ${unknown[0]}\nusage: node detect.mjs [--json]\n`);
    return 2;
  }
  let report;
  try {
    report = detect();
  } catch (e) {
    if (!(e instanceof ReadError)) throw e;
    process.stderr.write(`hov-setup: ${e.message}\n`);
    return 1;
  }
  process.stdout.write((json ? JSON.stringify(report, null, 2) : text(report)) + "\n");
  return 0;
}

// Compare real paths: ./setup links the skill dir into the config dir, so argv[1] can be the
// linked path while Node loads the module from its target, and main would silently not run.
function isMain() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (process.argv[1] && isMain()) {
  process.exitCode = main(process.argv.slice(2));
}
