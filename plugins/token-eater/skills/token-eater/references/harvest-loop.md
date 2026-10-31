# Run loop

The run loop is token-eater's end-to-end runbook. It spends the service(s) you chose on safe, gate-verifiable maintenance work, one chore at a time, until the backlog is empty or the credits run out.

There is no posture engine, no tier routing, and no cost economy. **You picked the service; the loop spends it.** The only judgment per chore is: can a deterministic gate prove this correct (admit it), and is it a free tool chore or a credit-spending model chore?

## Loop invariants

- Do not do a chore unless `references/chore-discovery.md` admitted it with a deterministic gate.
- `exec: tool` chores run through `scripts/apply-tool.sh` — they never call a service, never spend credits.
- `exec: model` chores are done by a service you named (or your saved default), in the order you listed.
- Every gate-passing result goes through `references/result-handling.md`; nothing merges to the default branch.
- A chore whose gate fails rolls back cleanly and is not turned into a PR.

## Inputs

Load these before the first chore:

1. **Config** from `references/setup-and-config.md`: `services` (the ordered list to spend), `review_before_pr`, optional `stop_when_low`, and `result_dir`.
2. **Adapter registry** from `adapters.yaml`: the `invoke` template, `structured_output`, `result_capture`, `circuit_breaker`, and optional `balance_signal` for each service.
3. **Detection** from `scripts/detect-adapters.sh`: which CLIs are installed. A service must be both requested in config and available from detection before it can be spent.
4. **Backlog** from `references/chore-discovery.md`: admitted chores, each with an id, `exec` mode, gate, allowed files, success criterion, and either a `fixer_command` (tool chores) or a scope-fenced prompt (model chores).

## Service state

For each requested-and-available service, keep a small in-memory record for the run:

```yaml
id: grok
available: true
auth_preflight: unknown      # set by check-auth.sh before the first model chore
parked: false                # set true if the circuit breaker fires or it hits the failure limit
park_reason: null
consecutive_failures: 0
```

The state is per run. Parking just means "stop spending this service this run"; a later run may try again after credits reset.

## End-to-end procedure

1. **Detect.** Run `scripts/detect-adapters.sh`. If it exits `3`, stop with a plain explanation and make no changes. Keep only the requested services that detection reports `available`. If none of the requested services are available, stop and say so plainly.
2. **Build the backlog.** Follow `references/chore-discovery.md`. The backlog must contain only gate-backed chores with explicit file scope. If it is empty, end the run and explain what was skipped and why (e.g. "this project has no adopted formatter or test gate, so there was nothing safe to verify").
3. **Pick the next chore** in discovery order (deterministic tool chores first, then the smaller/faster gates).
4. **Branch by execution mode.**
   - **`exec: tool`** — do not touch a service. Create the worktree, write the allowed-files list, and run the fixer directly:

     ```bash
     bash <skill-dir>/scripts/apply-tool.sh <worktree> "<fixer-command>" <allowed-files-file>
     ```

     `apply-tool.sh` returns the same JSON shape and exit-code family the loop understands: `0` ok, `2` invoke-error, `4` scope-violation. Run the gate, then hand the outcome to `references/result-handling.md`. Deterministic chores are free; the credit-burn is for judgment chores.
   - **`exec: model`** — pick the service: the first one in your `services` list that is available and not parked. If every requested service is parked, stop the run (see stop conditions). Then:
     a. **Auth preflight, once per service, before its first model chore:**

        ```bash
        bash <skill-dir>/scripts/check-auth.sh <service>
        ```

        On exit `3` (needs-reauth), park the service for the run with the plain message it printed (e.g. grok's "Open a terminal, run `grok`, sign in, then run token-eater again") and move to the next service in your list; if no service remains, stop. Never invoke a CLI that could hang on an interactive sign-in. On exit `2` (unknown), proceed but note the risk in the summary. On exit `0`, proceed.
     b. **Delegate** via `references/delegation-invocation.md` (which creates the worktree, assembles the prompt, runs the service headlessly, captures the result, and runs the gate).
5. **Handle the outcome.**
   - Gate passes → `references/result-handling.md` opens the draft PR (after the optional review pass, if `review_before_pr` is set). Reset that service's `consecutive_failures` to `0`.
   - The service's output matches its `circuit_breaker` → its credits are spent. Park it with reason `credits-exhausted` and fall through to the next service in your list for the remaining chores. For the service you set out to drain, this is the **happy ending**, not an error.
   - Gate fails or the delegation errors for another reason → roll back the worktree (no PR), increment that service's `consecutive_failures`, and park it after 3 in a row.
   - Tool-chore failures count against no service (no service ran).
6. **Optional: stop when low.** If `stop_when_low` is set and onwatch is available, check `scripts/onwatch-usage.sh <service>` before each model chore and park the service when its remaining balance is at or below the threshold. With no onwatch, skip this check (run until the circuit breaker fires).
7. **Repeat** with the next chore. Stop when a stop condition is met.

## Stop conditions

End the run when any of these is true:

- The backlog is empty.
- Every requested service is parked (credits exhausted, needs-reauth, or repeated failures).
- `dry-run` was requested — stop after detection and backlog construction, having shown the plan, without spending or opening PRs.

Always finish through `references/result-handling.md` so you get a plain-language summary and the ledger reflects every chore that was done, skipped, or rolled back.

## Acceptance examples

### A formatter chore is free

The backlog has a formatting chore (`exec: tool`). It runs through `scripts/apply-tool.sh`, the gate confirms the formatter is idempotent, and `references/result-handling.md` opens a draft PR. No service was called and no credits were spent — even though you named one.

### The chosen service does a judgment chore

You ran `/token-eater grok`. The backlog has a dead-code-removal chore (`exec: model`). Grok's auth preflight passes, grok does the chore in a worktree, the gate (tests + typecheck) passes, and a draft PR opens. The credits spent were grok's, because that is the service you chose.

### A failed gate rolls back

A delegated chore returns a schema-valid result but the gate fails. `references/delegation-invocation.md` removes the worktree/temporary branch, opens no PR, leaves your working tree untouched, and the failure is recorded. After three such failures in a row the service is parked.

### Credits run out

Mid-run, grok's output matches its `circuit_breaker` regex. token-eater parks grok with reason `credits-exhausted`, says plainly that the expiring credits appear spent, and — if you also listed `codex` or `claude` — continues the remaining chores on the next service. If grok was the only service, the run ends.

### Two services, in order

You ran `/token-eater grok codex`. Grok does chores until its credits run out, then codex picks up whatever remains. There is no cost comparison or tier check — the loop simply spends the services in the order you listed.
