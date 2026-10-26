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
