import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";

const AUDIT_SCRIPT = path.join(os.homedir(), ".pi", "agent", "bin", "pi-audit-local-packages");
const HEAL_SCRIPT = path.join(os.homedir(), ".pi", "agent", "bin", "pi-heal-local-packages");
const REPORT_DIR = path.join(os.homedir(), ".pi", "agent", "tmp");
const TOOL_PARAMS = Type.Object({
  fix: Type.Optional(Type.Boolean({ description: "Run the healing flow before re-auditing local Pi packages." })),
});

type ScriptResult = {
  command: string;
  code: number;
  output: string;
  reportPath: string;
};

async function ensureReportDir(): Promise<void> {
  await fs.mkdir(REPORT_DIR, { recursive: true });
}

function buildReportPath(kind: "audit" | "heal"): string {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  return path.join(REPORT_DIR, `package-health-${kind}-${stamp}.log`);
}

function summarize(result: ScriptResult): string {
  if (result.code === 0) {
    return `Pi package health check passed. Report: ${result.reportPath}`;
  }
  return `Pi package health check failed (exit ${result.code}). Report: ${result.reportPath}`;
}

async function runScript(pi: ExtensionAPI, command: string, signal?: AbortSignal): Promise<ScriptResult> {
  await ensureReportDir();
  const reportPath = buildReportPath(command === HEAL_SCRIPT ? "heal" : "audit");
  const result = await pi.exec(command, [], { signal, timeout: 240000 });
  const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim() || "(no output)";
  await fs.writeFile(reportPath, `${output}\n`, "utf8");
  return {
    command,
    code: result.code,
    output,
    reportPath,
  };
}

async function executeHealthCheck(pi: ExtensionAPI, ctx: ExtensionContext, fix: boolean): Promise<ScriptResult> {
  const command = fix ? HEAL_SCRIPT : AUDIT_SCRIPT;
  return runScript(pi, command, ctx.signal);
}

export default function packageHealthExtension(pi: ExtensionAPI) {
  const state = globalThis as typeof globalThis & { __packageHealthExtensionLoaded?: boolean };
  if (state.__packageHealthExtensionLoaded) return;
  state.__packageHealthExtensionLoaded = true;

  pi.registerTool({
    name: "doctor_packages",
    label: "Doctor Packages",
    description: "Audit local Pi path packages for missing peer deps and broken extension entrypoints.",
    promptSnippet: "Audit local Pi path packages for dependency/runtime drift.",
    promptGuidelines: [
      "Use this tool when Pi behaves differently across folders and you suspect broken local dogfooded packages.",
      "Set fix=true only when the user wants the local dependency graph healed before re-auditing.",
    ],
    parameters: TOOL_PARAMS,
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      onUpdate?.({ content: [{ type: "text", text: params.fix ? "Healing and auditing local Pi packages..." : "Auditing local Pi packages..." }] });
      const result = await runScript(pi, params.fix ? HEAL_SCRIPT : AUDIT_SCRIPT, signal ?? ctx.signal);
      return {
        content: [{ type: "text", text: `${summarize(result)}\n\n${result.output}` }],
        details: result,
      };
    },
  });

  pi.registerCommand("doctor-packages", {
    description: "Audit local Pi path packages and write a report under ~/.pi/agent/tmp",
    handler: async (_args, ctx) => {
      const result = await executeHealthCheck(pi, ctx, false);
      ctx.ui.notify(summarize(result), result.code === 0 ? "success" : "error");
    },
  });

  pi.registerCommand("heal-packages", {
    description: "Run local Pi package dependency healing, then re-audit",
    handler: async (_args, ctx) => {
      if (ctx.hasUI) {
        const confirmed = await ctx.ui.confirm(
          "Heal local Pi packages?",
          "This may run package-manager installs in local dogfooded Pi repos.",
        );
        if (!confirmed) return;
      }
      const result = await executeHealthCheck(pi, ctx, true);
      ctx.ui.notify(summarize(result), result.code === 0 ? "success" : "error");
    },
  });
}
