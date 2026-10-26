/**
 * Verify Extension for pi-local
 *
 * Two deterministic improvements ported from the Claude Code harness:
 *
 * 1. Auto-format after edit/write (tool_result event)
 *    Mirrors ~/dotfiles/hooks/PostToolUse/auto-format.js — detects
 *    Biome/Prettier and formats the file inline after each edit.
 *
 * 2. System prompt injection (before_agent_start)
 *    Tells the model to run `bun run lint && bun run typecheck && bun run format`
 *    before declaring a task complete. This replaces the verify skill with a
 *    deterministic instruction that's always in context.
 *
 * 3. /verify command
 *    Explicitly runs the verification chain and reports results.
 *
 * Note: pi's agent_settled event is informational only — it cannot block "done"
 * the way Claude Code's Stop hook can. The system prompt injection is the
 * primary gate; the /verify command is the manual escape hatch.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

// ── Helpers ─────────────────────────────────────────────────────

function findProjectRoot(startDir: string): string | null {
  let dir = startDir;
  while (dir !== path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, "package.json"))) return dir;
    dir = path.dirname(dir);
  }
  return null;
}

function detectFormatter(projectRoot: string): "biome" | "prettier" | null {
  // Biome: check for biome.json or biome.jsonc
  if (
    fs.existsSync(path.join(projectRoot, "biome.json")) ||
    fs.existsSync(path.join(projectRoot, "biome.jsonc"))
  ) {
    return "biome";
  }
  // Prettier: check for .prettierrc or prettier config in package.json
  if (
    fs.existsSync(path.join(projectRoot, ".prettierrc")) ||
    fs.existsSync(path.join(projectRoot, ".prettierrc.json")) ||
    fs.existsSync(path.join(projectRoot, ".prettierrc.js")) ||
    fs.existsSync(path.join(projectRoot, ".prettierrc.cjs"))
  ) {
    return "prettier";
  }
  // Fall back to checking package.json
  try {
    const pkg = JSON.parse(
      fs.readFileSync(path.join(projectRoot, "package.json"), "utf-8"),
    );
    if (pkg.devDependencies?.biome || pkg.dependencies?.biome) return "biome";
    if (pkg.devDependencies?.prettier || pkg.dependencies?.prettier)
      return "prettier";
  } catch {
    // Not a valid package.json
  }
  return null;
}

function resolveFormatterBin(
  projectRoot: string,
  formatter: "biome" | "prettier",
): { bin: string; prefix: string[] } | null {
  const localBin = path.join(projectRoot, "node_modules", ".bin", formatter);
  if (fs.existsSync(localBin)) {
    return { bin: localBin, prefix: [] };
  }
  // Fall back to bunx
  return { bin: "bunx", prefix: [formatter] };
}

function formatFile(filePath: string): void {
  const resolved = path.resolve(filePath);
  if (!/\.(ts|tsx|js|jsx)$/.test(resolved)) return;

  const projectRoot = findProjectRoot(path.dirname(resolved));
  if (!projectRoot) return;

  const formatter = detectFormatter(projectRoot);
  if (!formatter) return;

  const resolved_ = resolveFormatterBin(projectRoot, formatter);
  if (!resolved_) return;

  const args =
    formatter === "biome"
      ? [...resolved_.prefix, "check", "--write", resolved]
      : [...resolved_.prefix, "--write", resolved];

  try {
    execFileSync(resolved_.bin, args, {
      cwd: projectRoot,
      stdio: ["pipe", "pipe", "pipe"],
      timeout: 15000,
    });
  } catch {
    // Formatter not installed, file missing, or failed — non-blocking
  }
}

const VERIFY_INJECTION = `
## Verification Protocol (harness-enforced)

After making ANY code changes, you MUST run verification before declaring the task complete:

\`\`\`
bun run lint && bun run typecheck && bun run format
\`\`\`

If any step fails, fix the issue and re-run. Do not report success until all three pass.
You can also run /verify explicitly to check at any time.
`.trim();

// ── Extension ───────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  // 1. Auto-format after edit/write
  pi.on("tool_result", async (event) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    const filePath = (event.input as { file_path?: string }).file_path;
    if (!filePath) return;
    formatFile(filePath);
  });

  // 2. Inject verify instruction into system prompt
  pi.on("before_agent_start", async (event) => {
    // Only inject if there's a package.json (this is a JS/TS project)
    const cwd = event.systemPromptOptions?.cwd ?? process.cwd();
    if (!findProjectRoot(cwd)) return;
    return {
      systemPrompt: event.systemPrompt + "\n\n" + VERIFY_INJECTION,
    };
  });

  // 3. /verify command
  pi.registerCommand("verify", {
    description: "Run lint + typecheck + format and report results",
    handler: async (_args, ctx) => {
      const cwd = process.cwd();
      const projectRoot = findProjectRoot(cwd);
      if (!projectRoot) {
        if (ctx.hasUI) ctx.ui.notify("No package.json found", "warning");
        return;
      }

      const steps: Array<{ name: string; cmd: string; args: string[] }> = [
        { name: "format", cmd: "bun", args: ["run", "format"] },
        { name: "lint", cmd: "bun", args: ["run", "lint"] },
        { name: "typecheck", cmd: "bun", args: ["run", "typecheck"] },
      ];

      const results: Array<{ name: string; passed: boolean; output: string }> =
        [];

      for (const step of steps) {
        if (ctx.hasUI)
          ctx.ui.setStatus("verify", `Running ${step.name}...`);

        const result = spawnSync(step.cmd, step.args, {
          cwd: projectRoot,
          stdio: ["pipe", "pipe", "pipe"],
          timeout: 120000,
          env: { ...process.env, CI: "1", FORCE_COLOR: "0" },
        });

        const stdout = result.stdout?.toString().trim() ?? "";
        const stderr = result.stderr?.toString().trim() ?? "";
        const output = [stdout, stderr].filter(Boolean).join("\n");
        const passed = result.status === 0;

        results.push({ name: step.name, passed, output });

        if (!passed) {
          // Stop on first failure
          break;
        }
      }

      if (ctx.hasUI) {
        ctx.ui.clearStatus("verify");
        const summary = results
          .map((r) => `${r.passed ? "✓" : "✗"} ${r.name}`)
          .join("  ");
        const allPassed = results.every((r) => r.passed);
        if (allPassed) {
          ctx.ui.notify(`Verify: all passed\n${summary}`, "info");
        } else {
          const failed = results.find((r) => !r.passed);
          ctx.ui.notify(
            `Verify: ${failed?.name} FAILED\n${summary}\n\n${failed?.output.slice(-2000)}`,
            "error",
          );
        }
      }
    },
  });
}
