import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import os from "node:os";
import path from "node:path";

const SCAN_SCRIPT = path.join(os.homedir(), ".pi", "agent", "bin", "pi-maintenance-scan");
const SYNC_SCRIPT = path.join(os.homedir(), ".pi", "agent", "bin", "pi-maintenance-sync-backup");
const TOOL_PARAMS = Type.Object({
  action: StringEnum(["scan", "sync_backup"] as const),
  fetch: Type.Optional(Type.Boolean({ description: "When action=scan, fetch configured remotes before generating the report." })),
});

type MaintenanceResult = {
  command: string;
  code: number;
  output: string;
  reportPath?: string;
  auditOk?: boolean;
  backupInSync?: boolean;
  repos?: Array<{ name: string; recommendation: string; dirty: boolean }>;
};

function parseOutput(output: string, command: string, code: number): MaintenanceResult {
  const result: MaintenanceResult = {
    command,
    code,
    output,
  };

  for (const line of output.split(/\r?\n/)) {
    if (line.startsWith("REPORT_PATH=")) result.reportPath = line.slice("REPORT_PATH=".length).trim();
    if (line.startsWith("AUDIT_OK=")) result.auditOk = line.slice("AUDIT_OK=".length).trim() === "1";
    if (line.startsWith("BACKUP_IN_SYNC=")) result.backupInSync = line.slice("BACKUP_IN_SYNC=".length).trim() === "1";
    if (line.startsWith("REPO=")) {
      const payload = line.slice("REPO=".length).trim();
      const [name, recommendation, dirtyPart] = payload.split("|");
      result.repos ??= [];
      result.repos.push({
        name,
        recommendation,
        dirty: dirtyPart === "dirty=1",
      });
    }
  }

  return result;
}

async function runScript(pi: ExtensionAPI, command: string, args: string[] = [], signal?: AbortSignal): Promise<MaintenanceResult> {
  const result = await pi.exec(command, args, { signal, timeout: 300000 });
  const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim() || "(no output)";
  return parseOutput(output, [command, ...args].join(" "), result.code);
}

function buildContinuationPrompt(reportPath: string): string {
  return [
    "Run the monthly Pi maintenance workflow carefully.",
    "",
    `First, read the maintenance report at @${reportPath}.`,
    "Use the `pi_maintenance` tool if you need to rescan or sync the dotfiles backup.",
    "",
    "Goals:",
    "- Keep the local Pi setup as the canonical, high-signal setup with beneficial upstream changes incorporated.",
    "- Keep the dotfiles backup current without clobbering unrelated local work.",
    "- Keep StartupBros-owned Pi repos healthy and current.",
    "- Only open or update upstream/community PRs when the diff is isolated, reviewable, and honestly described.",
    "",
    "Safety rules:",
    "- Never overwrite, commit, or reset over a dirty repo.",
    "- For StartupBros-owned repos, small targeted PRs are acceptable after local verification.",
    "- For fork/upstream repos, default to review-only. Do not submit a PR if the branch drags in unrelated sync work or misleadingly large diffs.",
    "- If the report shows dotfiles backup drift, sync the backup first and then rescan before making bigger decisions.",
    "- If a repo needs judgment, stop and summarize instead of improvising a risky update.",
    "",
    "Deliverables:",
    "1. Runtime health status",
    "2. Backup status",
    "3. Safe actions taken",
    "4. Remaining manual-review items",
  ].join("\n");
}

export default function piMaintenanceExtension(pi: ExtensionAPI) {
  const state = globalThis as typeof globalThis & { __piMaintenanceExtensionLoaded?: boolean };
  if (state.__piMaintenanceExtensionLoaded) return;
  state.__piMaintenanceExtensionLoaded = true;

  pi.registerTool({
    name: "pi_maintenance",
    label: "Pi Maintenance",
    description: "Scan or sync the local Pi maintenance setup, including backup drift and managed Pi package repo status.",
    promptSnippet: "Scan the managed Pi setup, dotfiles backup drift, and repo maintenance status.",
    promptGuidelines: [
      "Use this tool for the monthly Pi maintenance workflow before touching multiple Pi repos.",
      "Use action=sync_backup before re-scanning when the report says the dotfiles backup is out of sync.",
    ],
    parameters: TOOL_PARAMS,
    async execute(_toolCallId, params, signal, onUpdate) {
      if (params.action === "sync_backup") {
        onUpdate?.({ content: [{ type: "text", text: "Syncing ~/.pi/agent into the dotfiles backup..." }] });
        const result = await runScript(pi, SYNC_SCRIPT, [], signal);
        return {
          content: [{ type: "text", text: result.output }],
          details: result,
        };
      }

      onUpdate?.({ content: [{ type: "text", text: "Scanning Pi maintenance status..." }] });
      const args = params.fetch === false ? ["--no-fetch"] : [];
      const result = await runScript(pi, SCAN_SCRIPT, args, signal);
      return {
        content: [{ type: "text", text: result.output }],
        details: result,
      };
    },
  });

  pi.registerCommand("pi-maintenance", {
    description: "Run the careful monthly Pi maintenance workflow",
    handler: async (args, ctx) => {
      const mode = String(args || "run").trim() || "run";

      if (mode === "sync-backup") {
        const result = await runScript(pi, SYNC_SCRIPT, [], ctx.signal);
        ctx.ui.notify(`Pi backup sync complete (${result.code === 0 ? "ok" : "check output"})`, result.code === 0 ? "success" : "error");
        return;
      }

      const result = await runScript(pi, SCAN_SCRIPT, [], ctx.signal);
      if (!result.reportPath) {
        ctx.ui.notify("Pi maintenance scan finished but no report path was returned.", "error");
        return;
      }

      if (mode === "scan") {
        ctx.ui.notify(`Pi maintenance report written to ${result.reportPath}`, result.code === 0 ? "success" : "warning");
        return;
      }

      ctx.ui.notify(`Pi maintenance report ready: ${result.reportPath}`, result.code === 0 ? "success" : "warning");
      pi.sendUserMessage(buildContinuationPrompt(result.reportPath));
    },
  });
}
