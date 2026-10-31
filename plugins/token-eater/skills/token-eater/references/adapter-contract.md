# Adapter contract

An **adapter** is the thin description of one model CLI that token-eater can delegate to. Adapters live as entries in `adapters.yaml`. The harvest loop reads them generically, so adding a provider is a registry entry, never a change to the loop (R3).

## The contract (five load-bearing fields)

Each adapter declares:

1. **invoke** — the headless invocation template, run with the worktree as cwd (so no `--cwd` is needed). token-eater substitutes shell-escaped placeholders: `{prompt_file}` / `{prompt_text}` (prompt as a path or inline string), `{schema_file}` / `{schema_json}` (schema as a path or inline string), and `{result_file}` (where the adapter writes its result). Each adapter uses whichever form its CLI expects — they differ. The call must be non-interactive and must not open a TUI.
2. **structured_output** — names the flag/mechanism that constrains the CLI to emit the 5-field result schema (`status`, `files_modified`, `issues`, `summary`, `verification_summary`) consumed by the delegation harness (see `delegation-invocation.md`).
3. **result_capture** — tells the harness *where* that result is — `file:{result_file}` when the CLI writes it to a file (codex), or `stdout:<field>` when the result lives in a field of the CLI's stdout JSON envelope (grok's `.structuredOutput`, claude's `.structured_output`).
4. **circuit_breaker** — a regex that matches the CLI's rate-limit / credit-exhaustion output. When it fires, the service is parked for the run. For the service you are draining, this regex is the normal "credits all spent" stop — not an error.
5. **balance_signal** — optional. `none` or the name of an oracle that can report remaining budget. Only the advanced `stop_when_low` setting reads it (via `scripts/onwatch-usage.sh`). A service with no balance signal simply runs until the circuit breaker fires or the backlog empties — that is the common, default case.

## The three v1 adapters

| id | prompt input | schema | result | file-edit flag |
|----|--------------|--------|--------|----------------|
| `grok` | `--prompt-file` | `--json-schema` (soft) | stdout `.structuredOutput` | `--always-approve` |
| `codex` | stdin (`- <`) | `--output-schema` (hard) | `-o` file | `-s workspace-write` |
| `claude` | `-p "<text>"` | `--json-schema` (hard) | stdout `.structured_output` | `--permission-mode acceptEdits` |

- **grok**: its `--json-schema` is *soft* — the prompt must ask for the result schema, and `structuredOutput` can come back `null`; the deterministic gate, not the result JSON, is the real safety net.
- **codex**: reuses the established `codex exec --output-schema` contract; needs `-s workspace-write` to edit files in the worktree.
- **claude**: `claude -p --output-format json --json-schema` enforces the schema, and its envelope additionally reports `total_cost_usd` and `usage` (usable for spend self-metering).

### Verified headless contracts (2026-06-27)

Confirmed against the installed CLIs with live calls; these resolve the former `claude` `tbd-preflight`:

- `grok --prompt-file <file> --json-schema '<schema>' --always-approve` → prints a JSON envelope to stdout; the structured result is `.structuredOutput` (or `null` with `.structuredOutputError`). `--json-schema` implies `--output-format json`. **Observed in a real run:** grok frequently returns `.structuredOutput: null` and instead embeds the result JSON in a ```json fence inside `.text` (and may use a non-enum status like `"success"`). Extract from the `.text` fence as a best-effort fallback for the summary/ledger, normalize the status, and treat grok's self-report as advisory — the **gate is authoritative** for keep/rollback.
- `codex exec -s workspace-write --output-schema <file> -o <file> - < <prompt>` → writes the schema-conformant result to the `-o` file; prompt on stdin.
- `claude -p "<prompt>" --output-format json --json-schema '<schema>' --permission-mode acceptEdits` → prints a JSON envelope to stdout; the structured result is `.structured_output`. Enforced; envelope also carries `total_cost_usd` / `usage`.

The placeholder substitution differs per adapter (path vs. inline string; stdin vs. arg) — see `adapters.yaml` and the `result_capture` field.

### Balance signal — `scripts/onwatch-usage.sh` (2026-06-27)

token-eater can optionally read credit/quota balances from **onwatch** when it is running, to support the `stop_when_low` setting. `onwatch-usage.sh <provider>` returns `{util_percent, resets_at, status}` and exits 3 when onwatch is absent (the common user case) — the run just continues until the circuit breaker fires. Sources: **grok** from onwatch's SQLite DB (`~/.onwatch/data/onwatch.db`, table `grok_quota_values`); **anthropic / codex** from onwatch's open Prometheus `/metrics` (seven-day window). Verified: grok 11%, resets 2026-07-01.

**Self-contained (no-onwatch) grok balance — finding, not yet built.** onwatch itself polls grok credits via the gRPC method `grok.com/grok_api_v2.GrokBuildBilling/GetGrokCredits` (`application/grpc-web+proto`), authenticated with the bearer token in `~/.grok/auth.json` (`.key` field). Replicating it directly — so users without onwatch get a native grok balance — needs the request message `.proto` shape: the empty-message call returns `grpc-status 12` (unimplemented). Tracked as a follow-up.

## Detection

`scripts/detect-adapters.sh` reads the registry, runs `command -v` for each `id`, and reports which adapters are available. With none available, token-eater stops and changes nothing (R4).

## Adding a provider

Append an entry to `adapters.yaml` with all contract fields (`id`, `invoke`, `structured_output`, `result_capture`, `circuit_breaker`, and optionally `balance_signal`). Confirm the headless contract with the one-time preflight in `references/delegation-invocation.md` before first use. No loop code changes (R3).
