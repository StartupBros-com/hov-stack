# Delegation invocation

This playbook runs one eligible chore on one service. It is the isolation and verification boundary for token-eater: every delegated task runs in a fresh git worktree, returns a constrained 5-field result, and survives only if the deterministic gate passes (R12, R13, R15). Service failures are classified so the run loop can park a service and continue with the next one in your list.

The shape mirrors the proven Codex delegation harness: pass file paths instead of large file contents, launch headless work in the background, poll separately, and roll back the worktree on red.

## Recursion guard (do NOT block on the orchestrator's own session)

token-eater's orchestrator runs inside a model session **by design** - when invoked as `/token-eater` from Claude Code, `CLAUDECODE` (and similar interactive-session flags) is **always set**. That is the normal, expected entry point and MUST NOT block delegation. Treating `CLAUDECODE` / `CLAUDE_CODE_SANDBOX` / `CLAUDECODE`-style flags as a "don't delegate" signal is the bug that makes token-eater silently do the work *itself* instead of burning surplus - the whole product becomes a no-op. **Never block delegation just because the orchestrator is in a model session.**

The only real recursion to prevent is delegating to an adapter while this run is itself executing *inside a token-eater chore-worker* (self-nesting). Guard narrowly:

- Skip **all** delegation only if `TOKEN_EATER_DELEGATED=1` is set - the runners export this into every worker they launch, so a chore-worker that somehow re-invokes token-eater is refused. (Do not strip this var.)
- Skip the **codex** adapter specifically if `CODEX_SANDBOX` / `CODEX_SESSION_ID` is set (you are literally inside a codex worker); skip a given adapter only when inside that same adapter's worker sandbox.

Do NOT skip an adapter merely because a model-session flag is present - the orchestrator always has one. When a narrow guard does fire, report it in `issues[]`; it is not a gate failure.

## Result schema

Every delegated run must produce exactly this JSON shape. Extra keys are ignored by the orchestrator; missing or wrongly typed required keys make the result malformed.

```json
{
  "type": "object",
  "required": [
    "status",
    "files_modified",
    "issues",
    "summary",
    "verification_summary"
  ],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["completed", "partial", "failed"]
    },
    "files_modified": {
      "type": "array",
      "items": { "type": "string" }
    },
    "issues": {
      "type": "array",
      "items": { "type": "string" }
    },
    "summary": { "type": "string" },
    "verification_summary": { "type": "string" }
  },
  "additionalProperties": false
}
```

Write this schema to a per-run `schema.json` file. Adapters that take a schema *path* use `{schema_file}` (codex); adapters that take the schema *inline* use `{schema_json}` (grok, claude) - substitute the file's contents as a shell-escaped string. Read the result from the location named by the adapter's `result_capture` field: a `{result_file}` on disk (codex) or a field of the stdout JSON envelope (grok `.structuredOutput`, claude `.structured_output`).

## Auth preflight (before the headless-contract preflight)

Run this before an adapter's first real chore in a token-eater run, before the headless-contract preflight below. The auth preflight is intentionally earlier because the headless-contract preflight actually invokes the adapter CLI; if a token is expired, that invocation may drop into an interactive sign-in prompt and hang an unattended run.

From the token-eater skill directory:

```bash
bash <skill-dir>/scripts/check-auth.sh <adapter>
```

`check-auth.sh` prints one tab-separated line:

```text
<status>    <plain-language message>
```

Use the exit code, and keep the printed message for the run summary or `issues[]`:

| Exit | Status | Action |
| --- | --- | --- |
| `0` | `ready` | Proceed to the headless-contract preflight. |
| `3` | `needs-reauth` | Park this service for the run with the printed plain-language message and move to the next service in your list; if none remains, stop. Never invoke a CLI that could hang on interactive sign-in. |
| `2` | `unknown` | Proceed, but add the printed risk message to `issues[]` so the user can see what was uncertain. |

Example `needs-reauth` message for Grok: "Open a terminal, run `grok`, sign in, then run token-eater again." Keep this wording plain; users should not need to understand OAuth, tokens, or adapter internals.

This preflight is per adapter per run. Cache the outcome in provider state so one uncertain adapter does not repeat the same check before every chore.

## One-time headless-contract preflight

Run this once per adapter before its first real chore in a token-eater run. Cache the outcome in the run ledger; do not keep trying a failing adapter.

The preflight proves three things:

1. **Closed stdin does not hang.** Invoke the adapter with stdin closed or redirected from `/dev/null` unless the adapter template intentionally consumes `{prompt_file}` on stdin.
2. **Structured output works on success and error paths.** A trivial prompt must produce the 5-field schema on success; an intentionally impossible prompt must either produce schema-valid `status: failed` JSON or exit non-zero.
3. **Failures are signaled.** A CLI transport/auth/rate-limit failure must exit non-zero or match the adapter's `circuit_breaker` regex. Silent success with no result file is a task failure, not a usable adapter.

Preflight prompt:

```text
You are being preflighted by token-eater. Do not edit files. Return only the required JSON result schema. Use status "completed", files_modified [], issues [], summary "preflight ok", and verification_summary "no project gate run".
```

Preflight steps:

1. Create a temporary directory outside the project worktree.
2. Write `prompt.txt`, `schema.json`, `result.json`, `stdout.log`, and `stderr.log` paths there.
3. Read the adapter's `invoke` template from `adapters.yaml` and substitute `{prompt_file}`, `{schema_file}`, and `{result_file}`. Use shell-safe absolute paths.
4. Launch it with closed stdin where possible. If it fails to exit within the local preflight timeout, kill it and park the provider.
5. Parse `result.json` if the template writes one; otherwise parse stdout only if the adapter contract says stdout is the result channel.
6. Validate the 5 fields and types.

Verified contracts (2026-06-27): all three v1 adapters are confirmed - see `references/adapter-contract.md` "Verified headless contracts". `claude -p --output-format json --json-schema '<schema>' --permission-mode acceptEdits` emits the schema in its stdout `.structured_output`; `grok --prompt-file <file> --json-schema '<schema>' --always-approve` emits `.structuredOutput` (soft - may be `null`, in which case the gate decides); `codex exec -s workspace-write --output-schema <file> -o <file> - < <prompt>` writes the result file. The preflight still runs once per adapter per machine to catch auth or version drift, but it no longer needs to *discover* the contract.

## Per-chore harness

Run these steps for each chore selected by the harvest loop.

1. **Prepare names.** Pick a stable run id such as `token-eater-YYYYMMDD-HHMMSS-<provider>-<slug>`. Keep all run artifacts under `.token-eater/runs/<run-id>/` in the main repository and copy the prompt/schema/result paths into the worktree as needed.
2. **Create a fresh worktree** with `scripts/wt.sh` (see `references/worktree-lifecycle.md`) - it owns collision-safe naming, env/dependency setup, the dep exclude, and the per-repo lock, so do not call `git worktree add` directly:

   ```bash
   WT="$(bash <skill-dir>/scripts/wt.sh create "$REPO" "$RUN_ID" "$CHORE_SLUG")"
   ```

   The branch is `token-eater/<run-id>-<chore-slug>` and the worktree is `<repo>/.claude/worktrees/te-<run-id>-<chore-slug>`, cut from a committed ref - the user's uncommitted changes and current branch are never touched (R12). On completion call `bash <skill-dir>/scripts/wt.sh cleanup "$REPO" "$WT" keep` (gate passed -> branch is the PR) or `... drop` (rolled back). The "Worktree rollback rules" below describe what to capture before cleanup.

   **Worktree dependencies (load-bearing for non-trivial gates).** A fresh worktree has no `node_modules`, `.venv`, build cache, etc., so a real gate (`vitest`, `pytest`, `tsc`) cannot run there. Inject them - symlink the project's `node_modules` / virtualenv into the worktree (fast) or install in the worktree (slow). Then **exclude the injected paths from change detection**, or they register as stray files and trip the scope check. A worktree's `.git` is a *file*, so write to the path `git -C "$WORKTREE" rev-parse --git-path info/exclude` (not `<worktree>/.git/info/exclude`). The adapter runners also defensively ignore symlinks in their git-derived file list. Verified in the first real run (2026-06-27): a `node_modules` symlink the repo's `node_modules/` gitignore pattern did not match (symlink != directory) surfaced as a false scope violation until excluded.

3. **Assemble a scope-fenced prompt.** The prompt must include only the chore the provider is allowed to do:
   - Task title and one-paragraph objective.
   - Explicit repo-relative file list the adapter may read and modify.
   - Explicit files or paths it must not touch.
   - Success criterion tied to the deterministic gate.
   - The gate command token-eater will run after delegation.
   - The service id doing the chore.
   - Safety constraints from `references/chore-discovery.md`, including "never simplify away a safety check" for deslop/simplify chores.
   - The required 5-field JSON result schema.

   The file list is load-bearing. Do not delegate a vague "clean up the repo" prompt.

4. **Write schema and result paths.** Put `prompt.txt`, `schema.json`, `result.json`, `stdout.log`, `stderr.log`, and `pid` under the run artifact directory. Use absolute paths when substituting the invoke template.
5. **Build the adapter command.** Read the adapter's `invoke` value from `adapters.yaml`. Replace `{prompt_file}`, `{schema_file}`, and `{result_file}` with shell-escaped absolute paths. Run the command with the worktree as its current directory.
6. **Launch in the background.** Start the adapter as a background process and return control immediately:

   ```bash
   (cd "$WORKTREE" && eval "$ADAPTER_COMMAND") >"$STDOUT_LOG" 2>"$STDERR_LOG" &
   echo $! >"$PID_FILE"
   ```

   Do not foreground a long-running model command with `&` and then wait in the same tool call. The foregrounded wait hits the approximately two-minute host timeout. Launch and poll are separate steps.

7. **Poll separately.** In a later step, read the PID and check whether it is still running. While running, report concise progress and keep polling at a reasonable interval. When it exits, capture the exit code. If the shell cannot recover the original exit code, classify the result by the presence and validity of `result.json` plus circuit-breaker output, then err conservative.
8. **Classify the adapter result.** Use the table below before touching the diff.
9. **Run the deterministic gate.** If the adapter result is usable, run `scripts/run-gate.sh "$WORKTREE" "$GATE_COMMAND"` when the chore supplied an explicit gate. If no explicit command was supplied, run `scripts/run-gate.sh "$WORKTREE"` and let it auto-detect. Gate exit code is authoritative (R13).
10. **Keep or roll back.** Keep gate-passing worktree changes for `references/result-handling.md` to branch/PR. Remove the worktree with `git worktree remove --force "$WORKTREE"` on gate failure, malformed result, `status: failed`, or CLI failure (R15).

## Result classification

| Adapter exit / result                          | Classification    | Action                                                                                                                                              |
| ---------------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Exit code non-zero                             | CLI failure       | Park provider for this run if the output matches `circuit_breaker`; otherwise count toward the consecutive failure limit (R16). Roll back worktree. |
| Exit code zero, missing result                 | Task failure      | Treat as malformed delegation. Roll back worktree.                                                                                                  |
| Exit code zero, malformed JSON or wrong schema | Task failure      | Roll back worktree. Count a provider failure.                                                                                                       |
| Schema-valid `status: failed`                  | Task failure      | Roll back worktree. Keep the issue text for the run summary.                                                                                        |
| Schema-valid `status: partial`                 | Partial success   | Run the gate. If green, keep the worktree and finish remaining cleanup locally before result handling; if red, roll back.                           |
| Schema-valid `status: completed`               | Candidate success | Run the gate. Keep only if the gate passes.                                                                                                         |

The deterministic gate is still required for `status: completed`. A model's self-report never substitutes for the project gate.

## Worktree rollback rules

Rollback means:

1. Capture `stdout.log`, `stderr.log`, `result.json` if present, and the gate output in the run artifact directory.
2. From the main repository, run `git worktree remove --force <worktree>`.
3. Delete the temporary branch if it was created and no PR/branch result should remain:

   ```bash
   git branch -D token-eater/<run-id>
   ```

4. Confirm the main working tree was not modified by the delegation. If it changed, stop and report the exact files; do not attempt broad cleanup.

Never roll back or reset the user's original worktree. The only destructive operation permitted here is removing the token-eater-created worktree/branch.

## Gate invocation

`scripts/run-gate.sh` is the standard gate runner. It accepts:

```bash
scripts/run-gate.sh [target-dir] [explicit gate command...]
```

Examples:

```bash
scripts/run-gate.sh "$WORKTREE" "pnpm exec prettier --check ."
scripts/run-gate.sh "$WORKTREE" "pnpm test"
scripts/run-gate.sh "$WORKTREE"
```

When the chore has a known gate, pass it explicitly. Auto-detection is a fallback for broad project gates only.

## Prompt skeleton

Use this structure, filling every bracketed field:

```text
You are running one token-eater maintenance chore in an isolated git worktree.

Task: [specific chore]
Service: [provider id]

Allowed files:
- [repo-relative path]

Do not touch:
- [repo-relative path or glob]

Success criterion:
[A concrete condition that the deterministic gate verifies.]

Gate token-eater will run after you finish:
[gate command]

Safety constraints:
- Stay inside the allowed file list.
- Make the smallest maintainable change that satisfies the task.
- Do not change public behavior unless the chore explicitly asks for it and the gate covers it.
- Never simplify away a safety check, validation, permission check, rate-limit check, or error handling branch.
- Do not create commits, push branches, open PRs, install dependencies, or edit token-eater config.

Return only JSON matching the required 5-field result schema:
{status, files_modified, issues, summary, verification_summary}
```

## Service parking

Park a service for the current run when:

- The auth preflight returns `needs-reauth`.
- The adapter output matches its `circuit_breaker` regex (credits exhausted — for the service you are spending, this is the expected stop).
- It reaches three consecutive failures.
- It repeatedly produces malformed or missing result JSON.

Parking is per run, not permanent. Later runs may try the service again after its credits reset or after the user re-authenticates.

## Adapter runners (`scripts/delegate-<adapter>.sh`)

There is one runner per adapter - `delegate-grok.sh`, `delegate-codex.sh`, `delegate-claude.sh` - and they share an identical exit-code contract and output shape, so the harvest loop treats them uniformly. All three derive `files_modified` from `git` (ground truth), enforce the optional allowed-files scope fence, detect the circuit breaker, and leave keep/rollback to the deterministic gate. They differ only in the verified per-adapter invocation and where each CLI puts its result.

Grok's self-report is unreliable - `.structuredOutput` is frequently `null` and the result JSON appears (or not) in a `.text` fence, sometimes with a non-enum status like `"success"`. `scripts/delegate-grok.sh` wraps the grok adapter so the harvest loop never depends on that: it runs the verified contract, then derives the trustworthy facts from ground truth (verified across live runs 2026-06-27).

```bash
scripts/delegate-grok.sh <worktree-dir> <prompt-file> [schema-file] [allowed-files-file]
```

It prints a JSON object and returns an exit code the loop acts on:

| exit | meaning | loop action |
| --- | --- | --- |
| 0 | grok ran; `made_changes` + `files_modified` derived from `git` | if `made_changes`: run the gate (keep on pass, roll back on fail); else no-op (skip PR) |
| 2 | invoke error (grok missing, no JSON envelope) | task failure - roll back |
| 3 | `circuit_breaker` (credit / rate-limit signal matched) | park grok for the run (R16) - roll back |
| 4 | `scope_violation` - grok changed a file outside the allowed list | roll back (R12) |

`files_modified` comes from `git diff` + untracked in the worktree, not grok's word. The optional allowed-files list enforces the scope fence against ground truth (`scope_offenders` lists any stray files). `summary` defaults to a ground-truth line and is enriched with grok's own summary only when it parses cleanly. The deterministic gate stays authoritative for keep/rollback - `delegate-grok.sh` reports only *what changed* and *whether it stayed in scope*. `jq` is used for best-effort self-report parsing when available; the ground-truth facts work without it.

`delegate-codex.sh` and `delegate-claude.sh` follow the same contract but lean on reliable self-reports: codex writes the schema-valid result to its `-o` file, and claude returns it in the stdout envelope's `.structured_output` and additionally reports `total_cost_usd` (surfaced as `cost_usd` for spend self-metering). Both still derive `files_modified` and the scope check from `git`. All three normalize the advisory `self_status` (e.g. `success` -> `completed`); the gate sets the authoritative status. Verified live 2026-06-27: grok, codex, and claude each ran the unused-imports chore in an isolated worktree, passed the ruff gate, and were correctly kept; a grok scope-violation case returned exit 4. (The three runners share ~70% of their logic - extracting a common library is tracked as a follow-up.)
