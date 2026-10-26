---
name: verify
description: Run sequential verification phases (format → lint → typecheck, +test/audit/status) with project auto-detection and stop-on-failure.
argument-hint: "[quick|full|pre-pr]  (default: standard — format + lint + typecheck)"
disable-model-invocation: true
allowed-tools: Bash, Read, Grep
---

# Verify

Run verification phases against the current project. Detect the project type automatically, run the appropriate tools, stop on first failure.

**Mode**: $ARGUMENTS (default: standard)

## Modes

| Mode | Phases |
|------|--------|
| `quick` | typecheck only |
| (default) | format → lint → typecheck |
| `full` | format → lint → typecheck → test → audit → status |
| `pre-pr` | format → lint → typecheck → test → audit (strict) → status |

## Step 1: Detect Project Type

Check the working directory for config files. Use the FIRST match:

| Signal | Type | Notes |
|--------|------|-------|
| `turbo.json` | turbo-monorepo | Uses `pnpm` root scripts |
| `pyproject.toml` | python | Uses `ruff`, `pyright`, `pytest` |
| `package.json` | node | Inspect `scripts` to find available commands |
| None of above | minimal | Skip to audit phase |

For **node** projects, read `package.json` scripts to determine which commands exist. Map them:
- format: `format:fix` or `format` or `prettier --write .`
- lint: `lint:fix` or `lint`
- typecheck: `typecheck` or fall back to `tsc --noEmit`
- test: `test` or `test:run`

Determine the package manager: `pnpm-lock.yaml` → pnpm, `bun.lockb` → bun, `yarn.lock` → yarn, else npm.

## Step 2: Run Phases

Run each phase sequentially using Bash. **Stop immediately if any phase exits non-zero** — report the failure and do not continue. Use `pnpm` as default for this user (per global CLAUDE.md).

### FORMAT phase (skip in `quick` mode)

| Type | Command |
|------|---------|
| turbo-monorepo | `pnpm format:fix` |
| python | `ruff format .` |
| node | `{pm} run format:fix` or `{pm} run format` or skip if no script |
| minimal | skip |

### LINT phase (skip in `quick` mode)

| Type | Command |
|------|---------|
| turbo-monorepo | `pnpm lint:fix` |
| python | `ruff check --fix .` |
| node | `{pm} run lint:fix` or `{pm} run lint` or skip if no script |
| minimal | skip |

### TYPECHECK phase

| Type | Command |
|------|---------|
| turbo-monorepo | `pnpm typecheck` |
| python | `pyright .` |
| node | `{pm} run typecheck` or `npx tsc --noEmit` if tsconfig.json exists |
| minimal | skip |

### TEST phase (`full` and `pre-pr` only)

| Type | Command |
|------|---------|
| turbo-monorepo | `pnpm test` if script exists, else skip |
| python | `pytest` |
| node | `{pm} run test` or `{pm} run test:run` if exists |
| minimal | skip |

### AUDIT phase (`full` and `pre-pr` only)

Use Grep to scan **only files modified since last commit** (`git diff --name-only HEAD`) plus staged files (`git diff --name-only --cached`):

1. **console.log** — flag any `console.log` in `.ts`/`.tsx`/`.js`/`.jsx` files
2. **Secrets** — flag patterns: `sk-`, `sk_live`, `pk_live`, `api_key=`, `secret=`, `password=`, `token=`, `key=`
3. **Debug leftovers** — `debugger`, `TODO`, `FIXME`, `HACK`, `XXX`

In `pre-pr` mode: console.log findings are **failures** (non-zero exit). In `full` mode: they are **warnings**.

### STATUS phase (`full` and `pre-pr` only)

Run `git status` and `git diff --stat` to show what changed.

## Step 3: Report

After all phases complete (or on first failure), print a summary:

```
VERIFY [mode] — [project-type] detected

  FORMAT    ✓ passed
  LINT      ✓ passed (3 auto-fixed)
  TYPECHECK ✗ FAILED — 2 errors
  TEST      · skipped (blocked by typecheck failure)
  AUDIT     · skipped
  STATUS    · skipped
```

Use ✓ for pass, ✗ for fail, · for skipped, ⚠ for warnings.

If a phase fails, show the relevant error output immediately after the summary so the user can act on it.

## Rules

- **Never** run `pnpm build` as part of standard verify — it's slow and not needed for code quality checks. Only typecheck matters.
- If the project has no relevant tooling for a phase, **skip it silently** — don't install anything.
- Run format BEFORE lint — formatting fixes prevent false lint failures.
- Use the `--filter` flag if the user passes it (e.g., `/verify --filter acme-app`).
- Respect timeouts: 60s for format/lint, 120s for typecheck, 300s for tests.
