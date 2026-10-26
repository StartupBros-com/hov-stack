#!/usr/bin/env bash
set -euo pipefail
F=/tmp/hv-retro-2026-09-20/fixture
rm -rf "$F"; mkdir -p "$F"/{src/core,src/cli,src/db,src/internal,docs/architecture,.github/workflows,scripts}

cat > "$F/CLAUDE.md" <<'EOF'
# orderflow

Internal order-processing service. TypeScript, pnpm, Postgres.

## Before you start

Run `pnpm status-report` before starting any task so you have full context on
the current state of the service.

## Rules

- Always write high-quality, correct code.
- Think carefully before making changes.
- Never use `any`. Use `unknown` and narrow it.
- Never import from `src/internal/*` outside the module that owns it.
- Prefer named exports over default exports.
- Keep functions under 40 lines.
- Use `async/await`, never raw `.then()` chains.
- Error handling: every exported function that can fail returns a `Result<T, E>`,
  never throws. Throwing is reserved for programmer error (invariant violations).
- Naming: handlers end in `Handler`, repositories end in `Repo`, pure helpers
  have no suffix.
- Imports: node builtins first, then external, then `@/` aliases, then relative.
  Blank line between groups.
- Tests live next to the file they cover, named `<file>.spec.ts`.
- Commit messages use conventional prefixes: feat, fix, chore, docs.
- When adding a dependency, justify it in the PR body.
- Never commit generated files by hand.

## Where things are

Request lifecycle: see docs/architecture/request-flow.md

## Checks

Run `pnpm test:unit` before every commit.
EOF

cat > "$F/CODING_STANDARDS.md" <<'EOF'
# Coding standards

Read during review, not during implementation.

- Error messages should match the voice of the surrounding module: terse in
  `src/core` (the caller is code), explanatory in `src/cli` (the caller is a
  person). Judge this against the neighbouring messages in the same file.
- A new abstraction needs two existing call sites, not one anticipated one.
- Prefer default exports for single-export modules.
EOF

cat > "$F/docs/architecture/request-flow.md" <<'EOF'
# Request flow

1. `src/cli/serve.ts` binds the HTTP listener.
2. `src/core/router.ts` matches the path and calls a handler in `src/core/handlers/`.
3. Handlers call repositories in `src/db/`, which own all SQL.
4. Repositories return `Result<T, E>`; handlers map that to a status code.

Handlers never touch the database driver directly.
EOF

cat > "$F/package.json" <<'EOF'
{
  "name": "orderflow",
  "private": true,
  "scripts": {
    "dev": "tsx watch src/cli/serve.ts > /dev/null 2>&1",
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc --noEmit",
    "lint": "eslint .",
    "test": "vitest run",
    "db:generate": "tsx scripts/gen-types.ts",
    "status-report": "cat docs/status-dump.txt"
  },
  "devDependencies": {
    "eslint": "^9.12.0",
    "typescript": "^5.6.0",
    "vitest": "^4.1.11",
    "tsx": "^4.19.0"
  }
}
EOF

cat > "$F/eslint.config.js" <<'EOF'
import js from "@eslint/js";

export default [
  js.configs.recommended,
  {
    rules: {
      "no-unused-vars": "warn",
      "prefer-const": "error"
    }
  }
];
EOF

cat > "$F/.github/workflows/ci.yml" <<'EOF'
name: ci
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm typecheck
      - run: pnpm test
EOF

cat > "$F/src/db/schema.ts" <<'EOF'
// Source of truth for the database shape.
export const orders = {
  id: "uuid",
  customerId: "uuid",
  status: "text",
  totalCents: "integer",
  currency: "text",
  placedAt: "timestamptz",
} as const;

export const refunds = {
  id: "uuid",
  orderId: "uuid",
  amountCents: "integer",
  reason: "text",
  issuedAt: "timestamptz",
} as const;
EOF

cat > "$F/src/db/generated-types.ts" <<'EOF'
// AUTO-GENERATED. Do not edit.
export type Order = {
  id: string;
  customerId: string;
  status: string;
  totalCents: number;
  placedAt: string;
};

export type Refund = {
  id: string;
  orderId: string;
  amountCents: number;
  issuedAt: string;
};
EOF

cat > "$F/src/db/orderRepo.ts" <<'EOF'
import type { Order } from "./generated-types.js";
import { query } from "../internal/pg-driver.js";

export async function findOrder(id: string): Promise<Order | null> {
  const rows = await query("select * from orders where id = $1", [id]);
  return (rows[0] as Order) ?? null;
}
EOF

cat > "$F/src/internal/pg-driver.ts" <<'EOF'
// Internal. Owned by src/db. Do not import from elsewhere.
export async function query(sql: string, params: unknown[]): Promise<any[]> {
  void sql; void params;
  return [];
}
EOF

cat > "$F/src/core/router.ts" <<'EOF'
import { findOrder } from "../db/orderRepo.js";
import { query } from "../internal/pg-driver.js";

export async function route(path: string): Promise<any> {
  if (path.startsWith("/orders/")) {
    return findOrder(path.split("/")[2]!);
  }
  if (path === "/health") {
    return query("select 1", []);
  }
  return null;
}
EOF

cat > "$F/src/cli/serve.ts" <<'EOF'
import { route } from "../core/router.js";

export function serve(): void {
  console.log("listening on :3000");
  void route;
}
EOF

cat > "$F/scripts/gen-types.ts" <<'EOF'
// Reads src/db/schema.ts and rewrites src/db/generated-types.ts.
// Must be run after any change to schema.ts.
console.log("regenerating types from schema...");
EOF

python3 - <<'PY'
lines = ["orderflow status dump", "=" * 60, ""]
for i in range(1, 420):
    lines.append(f"service.module.{i:04d}  state=ok  lastDeploy=2026-09-1{i%10}  owner=team-{i%7}  queueDepth={i*3%97}")
open("/tmp/hv-retro-2026-09-20/fixture/docs/status-dump.txt", "w").write("\n".join(lines) + "\n")
PY

cat > "$F/session-log.md" <<'EOF'
# Session transcript — 2026-09-19, orderflow

**User:** Add a `currency` field to the refunds flow so partial refunds in
non-USD orders stop being rejected.

**Agent:** Reading CLAUDE.md. Running `pnpm status-report` first as instructed.
[tool: Bash `pnpm status-report`] — returned 419 lines of module status. Nothing
in it was relevant to refunds.

**Agent:** Looking for where refund types are defined.
[tool: Grep "Refund"] — 6 hits.
[tool: Read src/db/generated-types.ts] — found `type Refund`. Added `currency: string`
to it directly.

**Agent:** Wiring the field through the repo layer.
[tool: Read src/db/orderRepo.ts]
[tool: Edit src/db/orderRepo.ts] — added a `findRefund` returning `any` because the
driver's return type is `any[]` and narrowing it looked like a bigger change.

**Agent:** I need a query helper. `src/db` already imports the driver, so I will
import it in the router too for the health check path.
[tool: Edit src/core/router.ts] — imported `query` from `../internal/pg-driver.js`.

**Agent:** Running checks. [tool: Bash `pnpm test:unit`] — failed:
`ERR_PNPM_NO_SCRIPT  Missing script: test:unit`. Trying `pnpm test` instead — passed.
[tool: Bash `pnpm typecheck`] — passed.

**Agent:** Starting the dev server to confirm the endpoint works.
[tool: Bash `pnpm dev`] — process started, no output appeared. Waited, retried twice,
never saw a log line or an error. Gave up on runtime confirmation.

**Agent:** Done. Changed src/db/generated-types.ts, src/db/orderRepo.ts,
src/core/router.ts.

---

**Reviewer agent:** Reviewed the diff against CODING_STANDARDS.md. Error message
voice is consistent with the surrounding module. Approved.

---

**User (next morning):** The currency field disappeared. Also CI is red on main.
EOF

cd "$F" && git init -q && git add -A && git -c user.email=fixture@local -c user.name=fixture commit -qm "orderflow service" && echo "fixture built at $F" && find . -path ./.git -prune -o -type f -print | sort
