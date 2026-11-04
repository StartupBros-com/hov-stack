#!/usr/bin/env node
/*
  hov-setup auto-update helper: turns on Claude Code's auto-update for plugin marketplaces and
  says whether it is on (#395).

  Claude Code leaves auto-update off for a marketplace that is not its own. Its docs give three
  places that decide it, first match wins: `autoUpdate` on the marketplace's entry under
  `extraKnownMarketplaces` in settings.json, then `autoUpdate` on its entry in
  plugins/known_marketplaces.json (what the Enable auto-update switch in /plugin writes), then
  the default, on only for Anthropic's own marketplace. This helper sets the first one.
  OBSERVED on Claude Code 2.1.318 in a scratch config dir: `claude plugin marketplace add`
  writes the marketplace's settings.json entry without the key, and drops the key when it was
  already there, so this runs after the add; plugin install and update keep it.

  It changes that one key and nothing else, and only
  - on an entry Claude Code already wrote: it never declares a marketplace itself;
  - when the key is absent: a false, in either file, is someone's choice and is left alone;
  - in a settings.json that parses as a JSON object: anything else is refused, unchanged.
  The file is written once per run, through a temporary file renamed over it, keeping its key
  order, indentation and final newline; a symlinked settings.json is followed and the link kept.
  The old file is first copied to ~/.hov-stack-backups/<stamp>/ unless --no-backup.

  Usage:
    node autoupdate.mjs [--check] [--no-backup] [--config-dir <dir>] <marketplace>...

  --check says where each one stands and changes nothing. The config dir is $CLAUDE_CONFIG_DIR,
  else ~/.claude.

  Exit: 0 auto-update is on for every one named; 3 one is off and was left off (--check, or a
  false someone set); 1 one could not be read or changed, and nothing was written for it;
  2 bad usage.
*/
import {
  chmodSync, constants, copyFileSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

// Each of these switches off Claude Code's whole marketplace and plugin update pass, unless
// FORCE_AUTOUPDATE_PLUGINS is set too (Claude Code's plugin docs, "Which marketplaces and
// plugins auto-update"). They are reported, never changed.
export const OFF_SWITCHES = ["DISABLE_AUTOUPDATER", "DISABLE_UPDATES", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"];
export const FORCE_SWITCH = "FORCE_AUTOUPDATE_PLUGINS";
// Auto-update is on by default for Anthropic's own marketplace; the others offered are off.
const DEFAULT_ON = new Set(["claude-plugins-official"]);

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const own = (o, k) => isObject(o) && Object.prototype.hasOwnProperty.call(o, k);

export function configDir(env = process.env) {
  return env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
}

// { status: "missing" } | { status: "ok", value, text } | { status: "bad", why }
function readJsonObject(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    if (e.code === "ENOENT") return { status: "missing" };
    return { status: "bad", why: `could not be read (${e.code || e.message})` };
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return { status: "bad", why: "does not parse as JSON" };
  }
  if (!isObject(value)) return { status: "bad", why: "is not a JSON object" };
  return { status: "ok", value, text };
}

// The two files that decide auto-update, read once.
export function readFiles(cfg) {
  const settingsPath = join(cfg, "settings.json");
  const knownPath = join(cfg, "plugins", "known_marketplaces.json");
  return { settingsPath, knownPath, settings: readJsonObject(settingsPath), known: readJsonObject(knownPath) };
}

function entryOf(file, name, nested) {
  if (file.status !== "ok") return null;
  const parent = nested ? file.value.extraKnownMarketplaces : file.value;
  return own(parent, name) && isObject(parent[name]) ? parent[name] : null;
}

/*
  Where auto-update stands for one marketplace, by Claude Code's order:
    state   "on", "off", "turned-off" (a false someone set), "not-added", or "unknown" (a file
            that decides it could not be read, or holds an autoUpdate that is not true or false)
    where   "settings.json", "known_marketplaces.json" or "default" for on/off/turned-off, else null
    declared  whether settings.json has an entry for it, which is where this helper writes
    problem   for "unknown", what is wrong, in words
*/
export function stateOf(name, files) {
  const out = { state: "unknown", where: null, declared: false, problem: null };
  if (files.settings.status === "bad") {
    out.problem = `${files.settingsPath} ${files.settings.why}`;
    return out;
  }
  if (files.known.status === "bad") {
    out.problem = `${files.knownPath} ${files.known.why}`;
    return out;
  }
  const entry = entryOf(files.settings, name, true);
  const known = entryOf(files.known, name, false);
  out.declared = entry !== null;
  for (const [where, path, e] of [["settings.json", files.settingsPath, entry], ["known_marketplaces.json", files.knownPath, known]]) {
    if (!own(e, "autoUpdate")) continue;
    if (typeof e.autoUpdate !== "boolean") {
      out.problem = `${path} gives ${name} an autoUpdate that is not true or false`;
      return out;
    }
    out.where = where;
    out.state = e.autoUpdate ? "on" : "turned-off";
    return out;
  }
  if (!entry && !known) {
    out.state = "not-added";
    return out;
  }
  out.where = "default";
  out.state = DEFAULT_ON.has(name) ? "on" : "off";
  return out;
}

function truthy(v) {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0;
  if (typeof v === "string") return !["", "0", "false", "no", "off"].includes(v.trim().toLowerCase());
  return false;
}

// The switches that stop every plugin update here, each with where it is set: this process's
// environment, or the env block of settings.json. Empty when FORCE_AUTOUPDATE_PLUGINS is set.
export function updatesOffBy(env, files) {
  const senv = files.settings.status === "ok" && isObject(files.settings.value.env) ? files.settings.value.env : {};
  const where = (k) => (truthy(env[k]) ? "environment" : truthy(senv[k]) ? "settings.json" : null);
  if (where(FORCE_SWITCH)) return [];
  return OFF_SWITCHES.filter((k) => where(k)).map((k) => ({ name: k, where: where(k) }));
}

function indentOf(text) {
  const m = /^\{[ \t]*\r?\n([ \t]+)"/.exec(text);
  return m ? m[1] : 2;
}

function stamp(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// Writes `text` over `target` (a regular file) through a temporary file in its directory,
// keeping its permission bits.
function replaceFile(target, text) {
  const mode = statSync(target).mode & 0o777;
  const tmp = join(dirname(target), `.${basename(target)}.hov-setup-${process.pid}.tmp`);
  try {
    writeFileSync(tmp, text, { flag: "wx", mode });
    chmodSync(tmp, mode);
    renameSync(tmp, target);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* not made */ }
    throw e;
  }
}

function backupTo(source, shownPath, home) {
  const rel = relative(home, shownPath);
  const name = rel && !rel.startsWith("..") && !isAbsolute(rel) ? rel : basename(shownPath);
  // Never over an earlier backup: a second run in the same second gets its own directory.
  for (const dir of [stamp(), `${stamp()}-${process.pid}`]) {
    const dest = join(home, ".hov-stack-backups", dir, name);
    mkdirSync(dirname(dest), { recursive: true });
    try {
      copyFileSync(source, dest, constants.COPYFILE_EXCL);
      return dest;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
  }
  throw Object.assign(new Error("a backup of it already exists"), { code: "EEXIST" });
}

function onLine(name, s, files) {
  if (s.where === "settings.json") return `${name}: auto-update is on, set in ${files.settingsPath}`;
  if (s.where === "known_marketplaces.json") return `${name}: auto-update is on, switched on in /plugin`;
  return `${name}: auto-update is on, by Claude Code's default for its own marketplace`;
}

function offLine(name, s, files) {
  if (s.state === "turned-off" && s.where === "settings.json") {
    return `${name}: auto-update is off, set to false in ${files.settingsPath}, and was left off. To turn it on, set "autoUpdate" to true under extraKnownMarketplaces.${name} there.`;
  }
  if (s.state === "turned-off") {
    return `${name}: auto-update is off, switched off in /plugin, and was left off. To turn it on: /plugin, Marketplaces, ${name}, Enable auto-update.`;
  }
  return `${name}: auto-update is off, Claude Code's default for a marketplace from another publisher`;
}

/*
  Turns auto-update on for each named marketplace where it is off by default, or with --check
  only reports. Returns { code, lines }; never throws for a file problem.
*/
export function run(names, { check = false, backup = true, cfg = configDir(), env = process.env, home = homedir() } = {}) {
  const lines = [];
  let code = 0;
  const worse = (c) => {
    if (c === 1 || (c === 3 && code === 0)) code = c;
  };
  let files = readFiles(cfg);
  const toTurnOn = [];
  for (const name of names) {
    const s = stateOf(name, files);
    if (s.state === "on") {
      lines.push(onLine(name, s, files));
    } else if (s.state === "turned-off" || (s.state === "off" && check)) {
      lines.push(offLine(name, s, files));
      worse(3);
    } else if (s.state === "not-added") {
      lines.push(`${name}: not changed: Claude Code has no marketplace named ${name}`);
      worse(1);
    } else if (s.state === "unknown") {
      lines.push(`${name}: not changed: ${s.problem}`);
      worse(1);
    } else if (!s.declared) {
      lines.push(
        `${name}: not changed: ${files.settingsPath} has no entry for it, so it was added some other way. To turn auto-update on: /plugin, Marketplaces, ${name}, Enable auto-update.`,
      );
      worse(1);
    } else {
      toTurnOn.push(name);
    }
  }
  if (toTurnOn.length) {
    try {
      // Follow a symlinked settings.json, so the link stays and its target changes.
      let target = files.settingsPath;
      if (lstatSync(target).isSymbolicLink()) target = realpathSync(target);
      if (!statSync(target).isFile()) throw Object.assign(new Error("not a regular file"), { code: "ENOTFILE" });
      const before = files.settings.text;
      const value = files.settings.value;
      for (const name of toTurnOn) value.extraKnownMarketplaces[name].autoUpdate = true;
      let text = JSON.stringify(value, null, indentOf(before));
      if (/\r?\n$/.test(before)) text += before.endsWith("\r\n") ? "\r\n" : "\n";
      // Someone else (Claude Code itself, say) wrote the file since it was read: change nothing.
      if (readFileSync(target, "utf8") !== before) {
        throw Object.assign(new Error("it changed while this ran; run this again"), { code: "ECHANGED" });
      }
      const saved = backup ? backupTo(target, files.settingsPath, home) : null;
      replaceFile(target, text);
      for (const name of toTurnOn) {
        lines.push(
          `${name}: auto-update turned on in ${files.settingsPath}${saved ? ` (the old file is at ${saved})` : ""}. To turn it off, set "autoUpdate" to false under extraKnownMarketplaces.${name} there.`,
        );
      }
    } catch (e) {
      const why = e.code === "ECHANGED" ? e.message : `could not write it (${e.code || e.message})`;
      for (const name of toTurnOn) lines.push(`${name}: not changed: ${files.settingsPath} ${why}`);
      worse(1);
    }
    files = readFiles(cfg);
  }
  for (const off of updatesOffBy(env, files)) {
    const where = off.where === "environment" ? "in the environment" : `in the env block of ${files.settingsPath}`;
    lines.push(
      `note: ${off.name} is set ${where}, which stops Claude Code updating any plugin, so auto-update does nothing until it is unset or ${FORCE_SWITCH}=1 is set too.`,
    );
  }
  return { code, lines };
}

const USAGE = "usage: node autoupdate.mjs [--check] [--no-backup] [--config-dir <dir>] <marketplace>...";

function main(argv) {
  const names = [];
  let check = false;
  let backup = true;
  let cfg = configDir();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--check") check = true;
    else if (a === "--no-backup") backup = false;
    else if (a === "--config-dir") {
      if (!argv[i + 1]) {
        process.stderr.write(`hov-setup: --config-dir needs a directory\n${USAGE}\n`);
        return 2;
      }
      cfg = argv[++i];
    } else if (a.startsWith("-")) {
      process.stderr.write(`hov-setup: unknown argument ${a}\n${USAGE}\n`);
      return 2;
    } else if (!/^[A-Za-z0-9._-]+$/.test(a)) {
      process.stderr.write(`hov-setup: ${a} is not a marketplace name\n${USAGE}\n`);
      return 2;
    } else if (!names.includes(a)) names.push(a);
  }
  if (!names.length) {
    process.stderr.write(`hov-setup: name at least one marketplace\n${USAGE}\n`);
    return 2;
  }
  const { code, lines } = run(names, { check, backup, cfg });
  if (lines.length) process.stdout.write(lines.join("\n") + "\n");
  return code;
}

// Compare real paths: ./setup links the skill dir into the config dir (see detect.mjs).
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
