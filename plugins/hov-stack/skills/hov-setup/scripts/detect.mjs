#!/usr/bin/env node
/*
  hov-setup detector: which of the optional plugins on the hov marketplace are installed, in
  walkthrough order, the next step for each, and which other hov plugins ./setup already
  installed (for the closing tour).

  Read-only. It runs `claude plugin marketplace list --json` and `claude plugin list --json`
  and nothing else. A plugin counts only when it is installed at user scope, the rule
  ./setup uses; a project-scope copy is named in `otherScopes` and does not count.

  Usage:
    node detect.mjs [--json]

  Exit: 0 report printed; 1 a claude read failed (its error is passed through, and nothing
  is reported as absent); 2 bad usage.

  HOV_SETUP_PROC_VERSION names the file read to tell WSL2 apart (default /proc/version).
*/
import { readFileSync, realpathSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const MARKETPLACE = "hov";

// The guided plugins: each needs a login, a password or Windows prompt, a paid plan or a
// choice. Walkthrough order: the quickest win first, wsl-cdp before product-video (whose live
// recording uses its browser), and pro-gate, which has the most steps, last.
export const PLUGINS = [
  { name: "sign-it", what: "signs PDFs and Word documents with your own saved signature" },
  { name: "wsl-cdp", what: "lets Claude in WSL2 use your logged-in Windows browser", wslOnly: true },
  { name: "product-video", what: "turns a click-through of your product into a captioned video" },
  { name: "token-eater", what: "spends spare AI credits on code cleanup you review before it lands" },
  { name: "pro-gate", what: "a last review of your code changes by ChatGPT's Pro model" },
];

// Extras for people who tune their own Claude Code setup: free, nothing to set up.
export const EXTRAS = [
  { name: "harness-vet", what: "checks someone else's skill, plugin or tool before you add it" },
  { name: "rent-check", what: "shows which always-loaded instructions earn their cost, and what to cut" },
  { name: "harness-optimizer", what: "digs into a setup problem that keeps coming back and proposes fixes" },
];

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

export function detect() {
  const marketplaces = readClaudeJson(["plugin", "marketplace", "list", "--json"]);
  const installed = readClaudeJson(["plugin", "list", "--json"]);
  const wsl = onWsl();
  const offered = [
    ...PLUGINS.map((p) => ({ ...p, group: "guided" })),
    ...EXTRAS.map((p) => ({ ...p, group: "extra" })),
  ];
  const plugins = offered.map(({ name, what, group, wslOnly }) => {
    const id = `${name}@${MARKETPLACE}`;
    const rows = installed.filter((r) => r && r.id === id);
    const user = rows.find((r) => r.scope === "user");
    const row = {
      name,
      what,
      group,
      state: "absent",
      version: user ? user.version || null : null,
      installPath: user ? user.installPath || null : null,
      otherScopes: rows.filter((r) => r.scope !== "user").map((r) => r.scope),
      next: `claude plugin install ${id} --scope user`,
    };
    if (wslOnly && !wsl) {
      row.state = "not-applicable";
      row.next = NOT_WSL;
    } else if (user && user.enabled === false) {
      row.state = "disabled";
      row.next = `claude plugin enable ${id} --scope user`;
    } else if (user) {
      row.state = "installed";
      row.next = null;
    }
    return row;
  });
  const offeredNames = new Set(offered.map((p) => p.name));
  const suffix = `@${MARKETPLACE}`;
  const alsoInstalled = installed
    .filter((r) => r && typeof r.id === "string" && r.id.endsWith(suffix) && r.scope === "user")
    .filter((r) => !offeredNames.has(r.id.slice(0, -suffix.length)))
    .map((r) => {
      const name = r.id.slice(0, -suffix.length);
      const known = KNOWN[name] || { what: null, start: null };
      return { name, version: r.version || null, enabled: r.enabled !== false, what: known.what, start: known.start };
    });
  return {
    marketplace: { name: MARKETPLACE, added: marketplaces.some((m) => m && m.name === MARKETPLACE) },
    wsl,
    plugins,
    alsoInstalled,
  };
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
  for (const p of report.plugins) {
    const ver = p.version ? ` ${p.version}` : "";
    const scopes = p.otherScopes.join(", ");
    if (p.state === "installed") lines.push(`  ${p.name}: installed${ver}${scopes ? ` (also at ${scopes} scope)` : ""}`);
    else if (p.state === "disabled") lines.push(`  ${p.name}: installed${ver} but disabled. Enable: ${p.next}`);
    else if (p.state === "not-applicable") lines.push(`  ${p.name}: not applicable here: ${p.next}`);
    else lines.push(`  ${p.name}: absent${scopes ? ` (installed at ${scopes} scope only, which does not count)` : ""}. Install: ${p.next}`);
  }
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
