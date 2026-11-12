"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { isDeepStrictEqual } = require("node:util");
const LIVE_OWNED = [
  "statusLine",
  "spinnerVerbs",
  "feedbackSurveyState",
  "model",
  "env.ANTHROPIC_AUTH_TOKEN",
  "env.ANTHROPIC_CUSTOM_HEADERS",
];
const object = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const forbidden = (k) => ["__proto__", "constructor", "prototype"].includes(k);
const put = (o, k, v) => Object.defineProperty(o, k, {value:v, enumerable:true, writable:true, configurable:true});
const copy = (v) => (v === undefined ? undefined : structuredClone(v));
function stripOwned(v) {
  const clean = (x) => Array.isArray(x) ? x.map(clean) : object(x) ? Object.fromEntries(Object.entries(x).filter(([k]) => !forbidden(k)).map(([k,v]) => [k, clean(v)])) : x;
  v = clean(v);
  for (const p of LIVE_OWNED) {
    const parts = p.split("."),
      key = parts.pop();
    let parent = v;
    for (const part of parts) parent = parent?.[part];
    if (object(parent)) delete parent[key];
  }
  return v;
}
function inputsHash({ root, overlayDir, dcgPath, cfg, env = process.env }) {
  const h = crypto.createHash("sha256");
  const files = [
    "settings.json",
    "lib/settings-seed.js",
    "lib/settings-apply.js",
    "sync.sh",
    "lib/profile.sh",
    "lib/overlay.sh",
  ].map((f) => path.join(root, f));
  files.push(
    ...["settings.json", "env", "plugin-dirs"].map((f) =>
      overlayDir ? path.join(overlayDir, f) : "",
    ),
    path.join(cfg, ".hov-stack/settings-base.json"),
  );
  files.push(env.DOTFILES_ROLE_FILE || "", env.DOTFILES ? path.join(env.DOTFILES, "hosts.tsv") : "", path.join(root, "hosts.tsv"), overlayDir ? path.join(overlayDir, "hosts.tsv") : "");
  for (const key of ["DOTFILES_ROLE", "DOTFILES_ROLE_FILE", "DOTFILES"]) h.update(JSON.stringify([key, env[key] ?? null]));
  h.update(require("node:os").hostname().split(".")[0]);
  try { h.update(JSON.stringify(JSON.parse(fs.readFileSync(path.join(cfg, "settings.json"))).permissions?.deny?.slice().sort() ?? [])); } catch { h.update("<invalid-live-deny>"); }
  for (const f of files) {
    let bytes;
    try {
      bytes = fs.readFileSync(f);
    } catch (e) {
      if (!["ENOENT", "ENOTDIR"].includes(e.code)) throw e;
      bytes = Buffer.from("<absent>");
    }
    h.update(`${bytes.length}:`);
    h.update(bytes);
  }
  h.update(dcgPath || "");
  return h.digest("hex");
}
function applySettings({
  desired,
  base,
  live,
  cfg,
  home,
  hookTargetExists = () => true,
  skipPaths = {},
}) {
  const initial = base === null;
  desired = stripOwned(desired);
  base = stripOwned(base || {});
  const changes = [],
    conflicts = [],
    held = [],
    skipped = [],
    firstRun = [];
  const render = (s) =>
    s
      .split("$HOME/.claude")
      .join(cfg)
      .split("$HOME/")
      .join(home + "/");
  const commandKey = (s) => {
    s = render(s);
    const prefix = home + "/.local/lib/dcg/v";
    return s === home + "/.local/bin/dcg" ||
      (s.startsWith(prefix) &&
        /^\d+\.\d+\.\d+\/dcg$/.test(s.slice(prefix.length)))
      ? "<dcg>"
      : s;
  };
  const normalize = (v) =>
    typeof v === "string"
      ? commandKey(v)
      : Array.isArray(v)
        ? v.map(normalize)
        : object(v)
          ? Object.fromEntries(
              Object.keys(v)
                .filter(k => !forbidden(k))
                .sort()
                .map((k) => [k, normalize(v[k])]),
            )
          : v;
  const equal = (a, b) => isDeepStrictEqual(normalize(a), normalize(b));
  const rendered = (v) =>
    typeof v === "string"
      ? render(v)
      : Array.isArray(v)
        ? v.map(rendered)
        : object(v)
          ? Object.fromEntries(
              Object.entries(v).map(([k, x]) => [k, rendered(x)]),
            )
          : v;
  function scalar(d, b, l, p) {
    if (
      d === undefined &&
      b !== undefined &&
      equal(l, b) &&
      p !== "permissions" && !object(l)
    ) {
      changes.push({ action: "remove", path: p });
      return [undefined, undefined];
    }
    if (object(d) && l === undefined && Object.keys(skipPaths).some(k => k.startsWith(p + "."))) return merge(d, b || {}, {}, p);
    if (
      p === "permissions" &&
      object(d) &&
      l === undefined &&
      (b === undefined || object(b))
    )
      return merge(d, b || {}, {}, p);
    if (
      object(d ?? b) &&
      object(l) &&
      (b === undefined || object(b)) &&
      (d === undefined || object(d))
    ) {
      const pair = merge(d || {}, b || {}, l, p);
      if (d === undefined) {
        if (Object.keys(pair[0]).length === 0) pair[0] = undefined;
        if (Object.keys(pair[1]).length === 0) pair[1] = undefined;
      }
      return pair;
    }
    if (equal(d, b) || equal(d, l)) return [copy(l), copy(d)];
    if (l === undefined || (b !== undefined && equal(l, b))) {
      changes.push({
        action: d === undefined ? "remove" : l === undefined ? "add" : "update",
        path: p,
      });
      return [rendered(d), copy(d)];
    }
    (initial ? firstRun : conflicts).push({ path: p });
    return [copy(l), copy(b)];
  }
  function lists(d = [], b = [], l = [], p) {
    const result = copy(l),
      next = copy(d);
    for (const entry of b)
      if (!d.some((x) => equal(x, entry)) && l.some((x) => equal(x, entry))) {
        if (p === "permissions.deny") {
          held.push({ path: p, entry });
          next.push(entry);
        } else {
          for (let i = result.length - 1; i >= 0; i--)
            if (equal(result[i], entry)) result.splice(i, 1);
          changes.push({ action: "remove", path: p, entry });
        }
      }
    for (const entry of d)
      if (
        (p === "permissions.deny" || !b.some((x) => equal(x, entry))) &&
        !result.some((x) => equal(x, entry))
      ) {
        result.push(render(entry));
        changes.push({ action: "add", path: p, entry: render(entry) });
      }
    return [result, next];
  }
  function hooks(d = {}, b = {}, l = {}) {
    const identity = (h) => typeof h.command === "string" ? commandKey(h.command) : JSON.stringify(normalize(h));
    const touched = new Set();
    const emptied = new Set();
    function flatten(tree) {
      const m = new Map();
      for (const [event, groups] of Object.entries(tree).filter(([k]) => !forbidden(k)))
        for (const group of Array.isArray(groups) ? groups : [])
          for (const hook of Array.isArray(group?.hooks) ? group.hooks : []) {
            const key = JSON.stringify([
              event,
              group.matcher || "",
              identity(hook),
            ]);
            if (!m.has(key))
              m.set(key, { event, matcher: group.matcher, hook });
          }
      return m;
    }
    function insert(tree, item) {
      if (!Array.isArray(tree[item.event])) put(tree, item.event, []);
      const groups = tree[item.event];
      let group = groups.find(
        (g) => Array.isArray(g?.hooks) && (g.matcher || "") === (item.matcher || ""),
      );
      if (!group) {
        group = {
          ...(item.matcher === undefined ? {} : { matcher: item.matcher }),
          hooks: [],
        };
        groups.push(group);
      }
      group.hooks.push(copy(item.hook));
    }
    // An added hook goes where desired has it, so live keeps the tracked file's
    // grouping: check compares that shape and push copies it back. It joins the
    // live group holding its desired group-mates, else desired's group is
    // inserted beside the live counterpart of its nearest desired neighbour.
    function place(tree, item) {
      const want = Array.isArray(d[item.event]) ? d[item.event] : [];
      const id = identity(item.hook);
      const same = (g, m) => Array.isArray(g?.hooks) && (g.matcher || "") === (m || "");
      const gi = want.findIndex((g) => same(g, item.matcher) && g.hooks.some((h) => identity(h) === id));
      if (gi < 0) return insert(tree, item);
      if (!Array.isArray(tree[item.event])) put(tree, item.event, []);
      const groups = tree[item.event];
      const hook = copy(item.hook);
      const counterpart = (dg, skip) => {
        const ids = new Set(dg.hooks.map(identity).filter((k) => k !== skip));
        return groups.find((g) => same(g, dg.matcher) && g.hooks.some((h) => ids.has(identity(h))));
      };
      const mates = want[gi].hooks;
      const live = counterpart(want[gi], id);
      if (live) {
        const at = mates.findIndex((h) => identity(h) === id);
        const pos = (h) => live.hooks.findIndex((x) => identity(x) === identity(h));
        for (let i = at - 1; i >= 0; i--)
          if (pos(mates[i]) >= 0) return void live.hooks.splice(pos(mates[i]) + 1, 0, hook);
        for (let i = at + 1; i < mates.length; i++)
          if (pos(mates[i]) >= 0) return void live.hooks.splice(pos(mates[i]), 0, hook);
        return void live.hooks.push(hook);
      }
      const group = {
        ...(item.matcher === undefined ? {} : { matcher: item.matcher }),
        hooks: [hook],
      };
      for (let i = gi - 1; i >= 0; i--) {
        const c = same(want[i], want[i]?.matcher) && counterpart(want[i]);
        if (c) return void groups.splice(groups.indexOf(c) + 1, 0, group);
      }
      for (let i = gi + 1; i < want.length; i++) {
        const c = same(want[i], want[i]?.matcher) && counterpart(want[i]);
        if (c) return void groups.splice(groups.indexOf(c), 0, group);
      }
      groups.push(group);
    }
    const dm = flatten(d),
      bm = flatten(b),
      lm = flatten(l),
      result = copy(l),
      next = copy(d);
    for (const key of new Set([...dm.keys(), ...bm.keys()])) {
      const di = dm.get(key),
        bi = bm.get(key),
        li = lm.get(key),
        item = di || bi;
      const p = `hooks.${item.event}[${item.matcher || ""}].${commandKey(item.hook.command || "")}`;
      // Hook objects are atomic values; metadata changes must not merge fields.
      let value, nb;
      if (equal(di?.hook, bi?.hook) || equal(di?.hook, li?.hook)) {
        value = copy(li?.hook);
        nb = copy(di?.hook);
      } else if (!li || (bi && equal(li.hook, bi.hook))) {
        value = copy(di?.hook);
        nb = copy(di?.hook);
      } else {
        value = copy(li.hook);
        nb = copy(bi?.hook);
        (initial ? firstRun : conflicts).push({ path: p });
      }
      if (value && (!li || !equal(value.command, li.hook.command))) {
        const cmd = render(value.command || ""),
          quoted = [...cmd.matchAll(/"(\/[^"\n]*)"/g)];
        const rawTarget = quoted.length
          ? quoted.at(-1)[1]
          : cmd.startsWith("/")
            ? cmd.split(" ")[0]
            : "";
        // Match target_in_harness_home for an absolute default-config path too.
        const defaultCfg = home + "/.claude";
        const target =
          rawTarget === defaultCfg
            ? cfg
            : rawTarget.startsWith(defaultCfg + "/")
              ? cfg + rawTarget.slice(defaultCfg.length)
              : rawTarget;
        const launcher = cfg + "/hooks/bin/node-hook";
        const missing =
          cmd.startsWith('"' + launcher + '"') &&
          !hookTargetExists(launcher, "executable")
            ? launcher
            : target &&
                (target.startsWith(cfg + "/") ||
                  hookTargetExists(path.dirname(target), "directory")) &&
                !hookTargetExists(target, "file")
              ? target
              : "";
        if (missing) {
          skipped.push({ ...item, path: missing, command: value.command });
          value = copy(li?.hook);
          nb = copy(bi?.hook);
        }
      }
      // Keep desired's grouping and spelling for settled keys. Only unresolved
      // keys roll back to their previous base state.
      if (!equal(nb, di?.hook)) {
        for (const group of Array.isArray(next[item.event]) ? next[item.event] : []) {
          if (Array.isArray(group?.hooks) && (group.matcher || "") === (item.matcher || ""))
            group.hooks = group.hooks.filter(
              (h) => identity(h) !== identity(item.hook),
            );
        }
        if (Array.isArray(next[item.event])) {
          next[item.event] = next[item.event].filter(
            (group) => !Array.isArray(group?.hooks) || group.hooks.length,
          );
          if (!next[item.event].length) delete next[item.event];
        }
        if (nb) insert(next, { ...item, hook: nb });
      }
      if (equal(value, li?.hook)) continue;
      if (li) {
        for (const group of Array.isArray(result[item.event]) ? result[item.event] : [])
          if (Array.isArray(group?.hooks) && (group.matcher || "") === (item.matcher || ""))
            { const had = group.hooks.length;
            group.hooks = group.hooks.flatMap((h) =>
              identity(h) === identity(li.hook)
                ? value
                  ? [{ ...value, ...(typeof h.command === "string" ? {command: h.command} : {}) }]
                  : []
                : [h],
            );
            if (had && !group.hooks.length) emptied.add(group);
          }
      } else if (value) {
        if (typeof value.command === "string" && cfg === home + "/.claude")
          value.command = value.command
            .split(cfg)
            .join("$HOME/.claude")
            .split(home + "/")
            .join("$HOME/");
        place(result, { ...item, hook: value });
      }
      if (li && !value) touched.add(item.event);
      changes.push({
        action: !value ? "remove" : li ? "update" : "add",
        path: p,
        hook: true,
        event: item.event,
        matcher: item.matcher,
        command: value?.command || item.hook.command,
      });
    }
    for (const event of touched) {
      result[event] = result[event].filter((g) => !emptied.has(g) || g.hooks.length);
      if (!result[event].length) delete result[event];
    }
    return [result, next];
  }
  function merge(d, b, l, p = "") {
    const result = copy(l),
      next = {};
    for (const k of new Set([...Object.keys(d), ...Object.keys(b)])) {
      const q = p ? p + "." + k : k;
      if (forbidden(k) || LIVE_OWNED.includes(q)) continue;
      if (Object.hasOwn(skipPaths, q)) {
        skipped.push({path:q, reason:skipPaths[q], setting:true});
        if (Object.hasOwn(b,k)) put(next,k,copy(b[k]));
        continue;
      }
      let pair;
      if (
        q === "hooks" &&
        [d[k], b[k], l[k]].every((v) => v === undefined || object(v))
      )
        pair = hooks(d[k], b[k], l[k]);
      else if (
        [d[k], b[k], l[k]].every(
          (v) =>
            v === undefined ||
            (Array.isArray(v) && v.every((x) => typeof x === "string")),
        ) &&
        [d[k], b[k], l[k]].some(Array.isArray)
      )
        pair = lists(d[k], b[k], l[k], q);
      else pair = scalar(d[k], b[k], l[k], q);
      // Empty set/tree projections must not materialize a missing live key.
      if (
        (l[k] === undefined || (q === "hooks" && changes.some(c => c.hook) && Object.keys(l[k] || {}).length > 0)) &&
        ((Array.isArray(pair[0]) && pair[0].length === 0) ||
          (q === "hooks" &&
            object(pair[0]) &&
            Object.keys(pair[0]).length === 0))
      )
        pair[0] = undefined;
      if (pair[0] === undefined) delete result[k];
      else put(result, k, pair[0]);
      if (pair[1] !== undefined) put(next, k, pair[1]);
    }
    return [result, next];
  }
  const [result, nextBase] = merge(desired, base, live);
  return { result, nextBase, changes, conflicts, held, skipped, firstRun };
}
module.exports = { applySettings, inputsHash, LIVE_OWNED, stripOwned };
const digest = (bytes) =>
  crypto.createHash("sha256").update(bytes).digest("hex");
function atomic(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(file), 0o700);
  if (fs.existsSync(file)) fs.chmodSync(file, mode);
  if (fs.existsSync(file) && fs.readFileSync(file).equals(Buffer.from(bytes)))
    return;
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = path.join(
    path.dirname(file),
    "." +
      path.basename(file) +
      ".apply." +
      crypto.randomBytes(8).toString("hex"),
  );
  const fd = fs.openSync(temp, "wx", mode);
  try {
    fs.fchmodSync(fd, mode);
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temp, file);
}
function cli() {
  const args = {};
  const skipPaths = {};
  for (let i = 2; i < process.argv.length; i++) {
    const key = process.argv[i];
    if (key === "--skip-path") {
      const entry = process.argv[++i], at = entry.indexOf("=");
      if (at < 1) throw Error("invalid skip path");
      put(skipPaths, entry.slice(0, at), entry.slice(at + 1).replace(/[\r\n]/g, " "));
    } else if (key === "--plan") args.plan = true;
    else if (key.startsWith("--") && i + 1 < process.argv.length)
      args[key.slice(2)] = process.argv[++i];
    else throw Error("invalid arguments");
  }
  for (const key of ["desired", "live", "base", "config-dir", "home"])
    if (!args[key]) throw Error("missing --" + key);
  const stat = fs.lstatSync(args.live);
  if (!stat.isFile() || stat.isSymbolicLink())
    throw Error("live settings must be a regular file, not a symlink");
  const desired = JSON.parse(fs.readFileSync(args.desired));
  if (!object(desired)) throw Error("desired settings must be a JSON object");
  const base = fs.existsSync(args.base)
    ? JSON.parse(fs.readFileSync(args.base))
    : null;
  if (base !== null && !object(base)) throw Error("base settings must be a JSON object");
  const plan = args.plan || args.report === "check";
  let report, backup;
  for (let attempt = 0; attempt < 2; attempt++) {
    const bytes = fs.readFileSync(args.live),
      live = JSON.parse(bytes);
    if (!object(live)) throw Error("live settings must be a JSON object");
    report = applySettings({
      desired,
      skipPaths,
      base,
      live,
      cfg: args["config-dir"],
      home: args.home,
      hookTargetExists: (file, kind) => {
        try {
          if (kind === "executable") {
            fs.accessSync(file, fs.constants.X_OK);
            return true;
          }
          const s = fs.statSync(file);
          return kind === "directory" ? s.isDirectory() : s.isFile();
        } catch {
          return false;
        }
      },
    });
    if (plan || !report.changes.length || isDeepStrictEqual(report.result, live)) break;
    const temp = path.join(
      path.dirname(args.live),
      ".settings.json.apply." + crypto.randomBytes(8).toString("hex"),
    );
    const fd = fs.openSync(temp, "wx", stat.mode & 0o777 || 0o600);
    try {
      fs.fchmodSync(fd, stat.mode & 0o777 || 0o600);
      fs.writeFileSync(fd, JSON.stringify(report.result, null, 2) + "\n");
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    // Test-only race injection, never used unless explicitly requested.
    if (process.env.HOV_SETTINGS_APPLY_TEST_BEFORE_RECHECK) require("node:child_process").execFileSync(process.env.HOV_SETTINGS_APPLY_TEST_BEFORE_RECHECK, [args.live]);
    if (digest(fs.readFileSync(args.live)) !== digest(bytes)) {
      fs.unlinkSync(temp);
      if (attempt === 1) {
        process.exitCode = 3;
        throw Error(
          "live settings changed twice during the apply; nothing written",
        );
      }
      continue;
    }
    const root =
      args["backup-root"] || path.join(path.dirname(args.live), "backups");
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
    const date = new Date()
      .toISOString()
      .replace(/[-:]/g, "")
      .replace("T", "-")
      .slice(0, 15);
    const candidateBackup = fs.mkdtempSync(
      path.join(root, "settings-apply-" + date + "-"),
    );
    fs.chmodSync(candidateBackup, 0o700);
    fs.writeFileSync(path.join(candidateBackup, "settings.json"), bytes, {
      mode: 0o600,
    });
    fs.renameSync(temp, args.live);
    backup = candidateBackup;
    break;
  }
  if (!plan) {
    atomic(args.base, JSON.stringify(report.nextBase, null, 2) + "\n");
    if (args.stamp)
      atomic(
        args.stamp,
        inputsHash({
          root: path.resolve(__dirname, ".."),
          overlayDir: args["overlay-dir"],
          dcgPath: args["dcg-path"],
          cfg: args["config-dir"],
          env: process.env,
        }) + "\n",
      );
  }
  const { changes, conflicts, held, skipped, firstRun } = report;
  if (args.report === "check") {
    if (base === null)
      console.log(
        "  note: settings.json has no apply base yet; sync.sh apply-settings writes one (--seed-base <rev> to start from a known in-sync commit)",
      );
    for (const c of conflicts)
      console.log(
        `DRIFT: settings.json conflict at ${c.path}: live and the repo both changed it since the last apply; live was kept`,
      );
    for (const c of held)
      console.log(
        `DRIFT: settings.json permissions.deny entry the repo dropped is still live (removals from deny are never applied automatically): ${c.entry}`,
      );
    for (const c of skipped)
      console.log(
        `DRIFT: settings.json hook in the repo has no target on disk: ${c.event} [${c.matcher || ""}] ${c.path}`,
      );
    if (changes.length)
      console.log(
        `DRIFT: settings.json has ${changes.length} repo change(s) not yet applied (sync.sh apply-settings)`,
      );
    return;
  }
  for (const c of changes)
    console.log(
      c.hook
        ? `  ${c.action} hook ${c.event} [${c.matcher || ""}] ${JSON.stringify(c.command)}`
        : `  ${c.action} ${c.path}${c.entry === undefined || !c.path.startsWith("permissions.") ? "" : " " + JSON.stringify(c.entry)}`,
    );
  for (const c of conflicts)
    console.log(
      `  conflict ${c.path} (live and the repo both changed it since the last apply; live kept)`,
    );
  for (const c of held)
    console.log(
      `  held permissions.deny ${JSON.stringify(c.entry)} (removals from deny are never applied automatically)`,
    );
  for (const c of skipped)
    console.log(c.setting ? `  skipped ${c.path} (${c.reason})` :
      `  skipped hook ${c.event} [${c.matcher || ""}] ${JSON.stringify(c.command)} (target missing at ${c.path})`,
    );
  for (const c of firstRun)
    console.log(`  first run: ${c.path} differs from the repo; live kept`);
  console.log(
    `settings: ${plan ? "plan " + changes.length + " change(s)" : backup ? "applied " + changes.length : "unchanged"}${conflicts.length ? `; ${conflicts.length} conflict(s), see sync.sh check` : ""}${held.length ? `; ${held.length} held deny removal(s), see sync.sh check` : ""}${skipped.some(c => !c.setting) ? `; ${skipped.filter(c => !c.setting).length} hook(s) skipped (target missing)` : ""}${skipped.some(c => c.setting) ? `; ${skipped.filter(c => c.setting).length} setting(s) skipped (failed validation)` : ""}${backup ? `; backup at ${backup}/settings.json` : ""}`,
  );
}
if (require.main === module) {
  try {
    cli();
  } catch (e) {
    console.error(
      "settings-apply: " +
        (e instanceof SyntaxError
          ? "invalid JSON settings"
          : e.message.split("\n")[0]),
    );
    process.exitCode ||= 1;
  }
}
