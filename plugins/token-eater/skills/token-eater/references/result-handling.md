# Result handling

Result handling turns each delegated chore outcome into a reviewable artifact, an append-only ledger entry, and a plain-language user summary. A gate-passing worktree becomes a branch plus a draft PR when a remote is available, or a branch-only result when no remote exists. Nothing ever auto-merges to the default branch (R14).

This playbook is called after every delegated chore and once at the end of the run.

## Non-negotiable rules

- Never merge, rebase onto, fast-forward, or push to the default branch.
- Never run `gh pr merge`, `git merge`, `git push origin main`, `git push origin master`, or any equivalent default-branch update.
- Open draft PRs only: `gh pr create --draft` (R14).
- If there is no usable git remote or `gh` is unavailable, keep a local branch and report it as branch-only.
- Append one ledger entry per chore attempt, including provider used, gate outcome, spend estimate, and PR/branch reference (R17).
- End the run with a plain-language summary that says what was cleaned and what to review, without requiring the user to understand model routing, worktrees, or gates (R20).

## Artifact locations

Use `defaults.result_dir` from config when present; otherwise use `.token-eater/runs`.

```text
.token-eater/
  runs/
    ledger.jsonl
    summaries/
      2026-06-27T030000Z.md
    <run-id>/
      prompt.txt
      schema.json
      result.json
      stdout.log
      stderr.log
      gate.log
```

The ledger is a simple append-only JSON Lines file at `.token-eater/runs/ledger.jsonl` unless config overrides the run directory. Store run summaries under `.token-eater/runs/summaries/<timestamp>.md` and also print the final summary in the agent response.

Do not require `.token-eater/` to be committed. It is a local audit trail unless the project chooses otherwise.

## Chore result input

Result handling receives a normalized outcome from `references/delegation-invocation.md` and `references/harvest-loop.md`:

```yaml
run_id: token-eater-20260627-030000-grok-format
chore_id: formatter-idempotency-001
chore_title: Make formatter check pass
provider: grok
worktree: ../token-eater-token-eater-20260627-030000-grok-format
branch: token-eater/token-eater-20260627-030000-grok-format
gate:
  command: "pnpm exec prettier --check ."
  outcome: pass
  log: .token-eater/runs/token-eater-20260627-030000-grok-format/gate.log
adapter_result:
  status: completed
  files_modified:
    - src/example.ts
  issues: []
  summary: "Formatted one TypeScript file."
  verification_summary: "prettier --check passed"
spend_estimate: "unknown"
plain_sentence: "Formatted one TypeScript file because the formatter can verify the result."
```

`spend_estimate` may be `unknown` when the adapter exposes no usage total. Do not invent a precise cost. Prefer one of: `unknown`, `low`, `medium`, `high`, or a provider-reported token/credit count when available.

## Gate-passing path: branch and draft PR (R14)

Use this path only when the deterministic gate passed and the worktree contains useful changes.

1. **Confirm default branch safety.** From the main repository, identify the default branch without checking it out:

   ```bash
   git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##'
   ```

   If that fails, use the current branch name only for reporting. Do not merge into it.

2. **Confirm the branch exists in the worktree.** The delegation harness should already have created `token-eater/<run-id>`. If not, create it from inside the token-eater worktree before any PR work:

   ```bash
   git switch -c "token-eater/<run-id>"
   ```

3. **Commit the gate-passing changes on the token-eater branch.** Keep the commit message plain and scoped:

   ```bash
   git add -u                     # tracked modifications/deletions only — never stage stray artifacts
   git add -- <allowed_files>     # plus any NEW files the chore was scope-fenced to create
   git commit -m "chore(token-eater): <short chore title>"
   ```

   Do **not** use `git add --all` / `git add .` — run artifacts (`prompt.txt`, `schema.json`, `result.json`) and injected deps (`node_modules`/`.venv` symlinks) must never land in the PR. Stage only the chore's tracked edits and its allowed new files. Run artifacts live under the main repo's `.token-eater/runs/<run-id>/`, not in the worktree.

4. **Resolve the target repo — always the user's OWN remote, NEVER an upstream parent.** The PR must land on `origin`. `gh pr create` defaults a *fork's* PR to its upstream parent, which would open a PR on a **third party's repo** — never allow that.

   ```bash
   ORIGIN_URL="$(git -C "$WORKTREE" remote get-url origin)" || { echo "no origin -> keep local branch"; }
   # owner/name from git@host:O/N.git or https://host/O/N.git
   ORIGIN_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')"
   BASE="$(git -C "$WORKTREE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)"
   ```

   If origin cannot be resolved, skip PR creation and keep the local branch. If `origin` is a fork (`gh repo view "$ORIGIN_SLUG" --json isFork`), still target `$ORIGIN_SLUG` — say plainly in the summary that the PR was opened on the user's fork, not upstream.

5. **Push only the token-eater branch to origin.**

   ```bash
   git -C "$WORKTREE" push -u origin "token-eater/<run-id>"
   ```

   Never push the default branch.

6. **Open a draft PR ON ORIGIN, when `gh` is available.** Always pass `--repo "$ORIGIN_SLUG"` and `--base "$BASE"`. Do not use `--fill` (it can fail or pull the wrong title).

   ```bash
   gh pr create --repo "$ORIGIN_SLUG" --base "$BASE" --head "token-eater/<run-id>" --draft \
     --title "chore(token-eater): <short chore title>" \
     --body-file ".token-eater/runs/<run-id>/pr-body.md"
   ```

   If `gh pr create` still errors (e.g. "No commits between..."), fall back to the API on the **same** repo, never the parent:

   ```bash
   gh api "repos/$ORIGIN_SLUG/pulls" -f head="token-eater/<run-id>" -f base="$BASE" -F draft=true \
     -f title="chore(token-eater): <short chore title>"
   ```

7. **Record the PR URL or branch reference.** If the draft PR was created, store its URL. If push or `gh` failed but the local branch exists, store `branch-only: token-eater/<run-id>` with the reason.

8. **Keep the worktree only as long as needed.** After the branch/PR reference is recorded, the orchestrator may remove the extra worktree. Do not delete the branch that backs a PR or branch-only result.

## No-remote or no-`gh` path

When the project has no remote, the user still gets a reviewable branch:

1. Commit the gate-passing changes on `token-eater/<run-id>` in the worktree.
2. Do not push.
3. Do not try to create a PR.
4. Record `branch-only: token-eater/<run-id>` and the reason, such as `no git remote` or `gh unavailable`.
5. Tell the user plainly: "I left this as a local branch because this repository does not have a remote configured."

Branch-only is a valid R14 outcome.

## Failed, skipped, and malformed chores

Do not create a PR or branch result for these outcomes:

- Adapter CLI failure.
- Malformed or missing result JSON.
- Adapter returned `status: failed`.
- Deterministic gate failed.
- Chore skipped because all requested services are parked (credits exhausted, needs-reauth, or repeated failures).
- Chore skipped because no deterministic gate existed.

For a gate failure, `references/delegation-invocation.md` rolls back the worktree and deletes the temporary branch. Result handling only records the failure and adds a plain summary sentence. This is the AE4 path: worktree rolled back, no PR opened, working tree untouched.

## Ledger format (R17)

Append one compact JSON object per chore attempt to `.token-eater/runs/ledger.jsonl`:

```json
{"timestamp":"2026-06-27T03:00:00Z","run_id":"token-eater-20260627-030000-grok-format","chore_id":"formatter-idempotency-001","chore_title":"Make formatter check pass","provider":"grok","gate_outcome":"pass","gate_command":"pnpm exec prettier --check .","adapter_status":"completed","spend_estimate":"unknown","result_ref":"https://github.com/acme/app/pull/123","files_modified":["src/example.ts"],"issues":[]}
```

Required fields:

| Field | Meaning |
| ----- | ------- |
| `timestamp` | UTC ISO-8601 time when the outcome was recorded. |
| `run_id` | Stable id from the delegation harness. |
| `chore_id` / `chore_title` | Backlog identity from `references/chore-discovery.md`. |
| `provider` | Service id (e.g. `grok`), `tool` for a free tool chore, or `none` for a chore that never ran. |
| `gate_outcome` | `pass`, `fail`, `not_run`, or `skipped`. |
| `gate_command` | The command intended or run; `null` only for skipped ungated candidates. |
| `adapter_status` | `completed`, `partial`, `failed`, `cli_failure`, `malformed`, or `not_run`. |
| `spend_estimate` | Provider-reported spend, qualitative estimate, or `unknown`. |
| `result_ref` | Draft PR URL, branch name, `rolled-back`, or skip reason. |
| `files_modified` | Repo-relative paths from the adapter result; empty on skipped/failed work. |
| `issues` | Short machine-readable issue strings useful for audit. |

Append-only means do not rewrite older rows during normal operation. If a later step enriches a result, append a new row with the same `run_id` and `event: "update"` rather than editing history.

## Draft PR body

When opening a draft PR, write `.token-eater/runs/<run-id>/pr-body.md` with:

```markdown
## What changed

- <plain description of the cleanup>

## Why token-eater picked this

- The chore had a deterministic gate: `<gate command>`.
- Service used: `<provider>`.

## Verification

- `<gate command>` passed.

## Review notes

- Review the changed files normally before merging.
- token-eater did not merge this branch.
```

Keep this review-focused. Avoid model internals unless they help the reviewer decide whether to merge.

## Plain-language run summary (R20)

At the end of every run, write and show a summary with these sections:

```markdown
# token-eater summary

Cleaned:
- Formatted two TypeScript files. Draft PR: <url>

Needs review:
- Review the draft PR before merging. token-eater did not merge anything.

Skipped:
- Skipped dependency updates because this project has no test or build gate to verify them.

Credits spent:
- grok handled one cleanup. Spend estimate: unknown.
```

Use everyday language:

- Say "formatted files" instead of "formatter idempotency chore".
- Say "the safety check failed, so I threw away that attempt" instead of "gate red caused rollback".
- Say "grok's credits ran out, so I stopped" instead of "circuit breaker matched, service parked".
- Say "nothing eligible was found to clean up" if the backlog was empty.

Always include whether there is anything to review. If nothing changed, say that no PR or branch was created.

## Per-chore procedure

For each outcome from the harvest loop:

1. Normalize the provider, gate, adapter status, spend estimate, files, and issue fields.
2. If the gate passed and there are changes, follow the draft-PR or branch-only path.
3. If the gate failed or the adapter failed, confirm no PR was created and use `result_ref: rolled-back` or the skip reason.
4. Append the ledger row immediately.
5. Add one plain-language sentence to the in-memory run summary.

At run end:

1. Write the markdown summary under `.token-eater/runs/summaries/`.
2. Print the same summary to the user.
3. Mention draft PR URLs and branch-only refs explicitly.
4. State that nothing was auto-merged to the default branch.
