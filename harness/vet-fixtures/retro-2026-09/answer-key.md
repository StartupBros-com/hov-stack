# Answer key — orderflow repository

Nine real defects were planted in this repository and its session transcript.
Three items are deliberate traps: they LOOK like defects but are correct, and
reporting them as problems is a false finding.

## Real defects (a report earns credit for each one it names)

D1. CLAUDE.md contains no-op steering lines that cannot change behaviour:
    "Always write high-quality, correct code." and "Think carefully before
    making changes."

D2. CLAUDE.md states two MECHANICAL rules as prose with no enforcement behind
    them: "Never use `any`" and "Never import from `src/internal/*` outside the
    module that owns it". The transcript shows BOTH violated (an `any` return in
    orderRepo.ts, and router.ts importing ../internal/pg-driver.js) and the
    reviewer agent approved anyway. Credit requires noting these should become
    deterministic checks (eslint rule / no-restricted-imports / CI), not prose.
    Partial credit for spotting the violations without proposing the check.

D3. `lint` exists in package.json ("eslint .") but nothing ever runs it: the CI
    workflow runs only typecheck and test, and there is no pre-commit hook. An
    existing check sits unwired.

D4. src/db/generated-types.ts is generated from src/db/schema.ts by
    `pnpm db:generate` (scripts/gen-types.ts), and NOTHING in CLAUDE.md or the
    docs records that dependency. The transcript shows the agent hand-editing
    the generated file; the user reports the change disappeared. The hidden
    file-to-file dependency is the defect. (CLAUDE.md's "Never commit generated
    files by hand" names no files and gives no regeneration command.)

D5. CLAUDE.md mandates `pnpm status-report` before EVERY task. It cats a
    419-line status dump. The transcript shows it returned nothing relevant.
    An expensive, mandatory, low-yield tool call.

D6. The `dev` script pipes all output to /dev/null
    ("tsx watch src/cli/serve.ts > /dev/null 2>&1"), so the agent can never see
    dev-server logs or errors. The transcript shows it starting the server,
    seeing no output, retrying twice and abandoning runtime confirmation.

D7. CLAUDE.md carries a long inline rules list (exports, function length,
    async style, Result types, naming suffixes, import ordering, test location,
    commit prefixes, dependency justification) that is always in context but
    belongs in CODING_STANDARDS.md, a linter, or a pointer.

D8. CLAUDE.md instructs "Run `pnpm test:unit` before every commit" but that
    script DOES NOT EXIST in package.json. The transcript shows it failing with
    ERR_PNPM_NO_SCRIPT. An actively wrong instruction, not merely a no-op.

D9. CLAUDE.md and CODING_STANDARDS.md contradict each other on exports:
    CLAUDE.md says "Prefer named exports over default exports"; CODING_STANDARDS.md
    says "Prefer default exports for single-export modules."

## Traps (reporting any of these as a problem is a FALSE finding)

T1. CODING_STANDARDS.md's error-message-voice rule ("terse in src/core,
    explanatory in src/cli, judge against neighbouring messages") is a genuine
    judgement call. Proposing a linter rule or any deterministic check for it,
    or calling it vague and cuttable, is a false finding.

T2. CI DOES exist and DOES run typecheck and test (.github/workflows/ci.yml).
    Claiming the repo has no guardrail, no CI, or no automated checks at all is
    a false finding. (The true finding is D3: lint specifically is unwired.)

T3. CLAUDE.md's "Request lifecycle: see docs/architecture/request-flow.md" is an
    accurate, load-bearing navigation pointer; the file exists and matches the
    code. Calling it a no-op, redundant, or proposing to cut it is a false
    finding.
