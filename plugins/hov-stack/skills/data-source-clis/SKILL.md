---
name: data-source-clis
description: Command surfaces and gotchas for the harness data CLIs — gsc (Search Console), dfs (DataForSEO), exa-cli (Exa), firecrawl-cli (Firecrawl), wacli (WhatsApp reads), ga4 (Analytics), discord-cli (Discord REST), resend-cli (official Resend CLI, MAIN key), stripe-api (Stripe REST), posthog-api (PostHog per project), supabase-api (Supabase Management API), vercel, vastai + vast-ssh (vast.ai GPU rental), and fal-api (fal.ai model runs). Load before the first call to any of them, for SEO, keyword, traffic, indexing, sitemap, web-retrieval, Discord, transactional-email, analytics, billing, product-analytics, database, deployment, WhatsApp-read, GPU-rental (vast.ai, renting a GPU or CUDA machine), or hosted-model (fal.ai video, image or audio models) tasks.
---

# Data-source CLIs

When the underlying API is simple, prefer a CLI over an MCP server: it works from subagents, cron and scripts, where an MCP server does not. Rationale, precedent, credentials and install mechanics for every tool below: `harness/data-source-clis.md`. These are the rules that bite on the first call; read the tool's `--help` for the rest.

## Per-host configuration

Every per-host map lives in the overlay directory: `$HOV_STACK_OVERLAY`, else
`${XDG_CONFIG_HOME:-~/.config}/hov-stack`. Tools read maps only when a command
needs them. A missing map leaves aliases unresolvable; the diagnostic names the
map's path and its environment override. Help and unrelated commands do not
require a map.

- `ga4` and `gsc` resolve credentials from `--credentials`, then
  `HOV_STACK_GOOGLE_CREDENTIALS`, then `GOOGLE_APPLICATION_CREDENTIALS`, then
  `google-service-account.json` under `$CLAUDE_CONFIG_DIR` (default `~/.claude`).
  `ga4 --property` takes a positive numeric property id or an alias from the
  project map `ga4-properties.json`; override its path with
  `GA4_PROPERTIES_FILE`. The shape is in `config/ga4-properties.example.json`.
  An unknown alias exits 2. `ga4 --where` reports the map path and its aliases.
- `posthog-api PROJECT` takes a numeric id or an alias from the project map
  `posthog-projects.json`, overridden by `POSTHOG_API_PROJECTS_FILE`; see
  `config/posthog-projects.example.json`. The organization id comes from the
  map's `organization_id`, else `POSTHOG_ORGANIZATION_ID` or
  `POSTHOG_CLI_ORGANIZATION_ID`. Without one, the wrapper refuses with exit 2
  rather than let posthog-cli answer from the wrong project. `--projects`
  prints the map and its path.
- `discord-cli` guild commands require `--guild` or `DISCORD_GUILD_ID`.
  With neither they return a usage error. There is no built-in guild.
- `resend-cli` reads its exact-record binding from `RESEND_CLI_BINDINGS_FILE`,
  else `resend-bws-bindings.json` in the overlay; see
  `config/resend-bws-bindings.example.json`. This tree holds no bindings file.
  A missing file or an unbound record is `credential_unbound` (exit 3);
  a malformed file is `bindings_invalid` (exit 2).
- `supabase-api PROJECT` takes a 20-letter ref or an alias from the project map
  `supabase-projects.json`, overridden by `SUPABASE_API_PROJECTS_FILE`; see
  `config/supabase-projects.example.json`.
- `migration-apply.sh` and `migration-targets.sh` read the app map from
  `migration-targets.json`, overridden by `HOV_STACK_MIGRATION_TARGETS_FILE`.
  It may include `legacy_identities`; see `config/migration-targets.example.json`.
- `with-gemini-sandbox` gets its BWS record id from `GEMINI_SANDBOX_BWS_ID`.
- `stripe-api` keeps its existing account routing and credential resolution.

## Search Console — `gsc`, never an MCP

- `gsc --help` is the command surface; setup, credentials and install mechanics: `harness/data-source-clis.md`.
- GSC data lags ~2 days; `gsc` backs off automatically (`--lag`, default 2). **Its row limit truncates silently** — filter server-side with `--contains` or `--page` rather than pulling a top-N and grepping, or low-traffic URLs vanish from the result and read as zero. Never diagnose a page's queries without `--page`. Incident: `harness/data-source-clis.md`.
- `gsc sitemap list --site <d>` / `gsc sitemap submit --site <d> --url <sitemap>`. **Check `list` before assuming a sitemap does anything** — willmitchell.com served a valid sitemap listing every page while having *zero* submitted, and Search Console reported its own `/citations` as "URL is unknown to Google". Only `submit` requests the writable scope; every read stays `webmasters.readonly`. **There is no API for "Request Indexing"** (the Indexing API takes only JobPosting/BroadcastEvent), so sitemap submission is the automatable ceiling.

## GA4 — `ga4`

Use `ga4 --help`; choose `--property <alias>|<positive-numeric-id>` explicitly.
`ga4 report --property "$PROPERTY" --request <json-file>` accepts the native Data API
body (dateRanges, dimensions, metrics, filters and ordering); `realtime` uses its
own native body. Responses remain native JSON; stderr warns on partial rows.
Page reports with limit/offset and Admin lists with the returned nextPageToken.
`accounts`, `properties`, `property`, `metadata`, `custom-dimensions`,
`custom-metrics` and `google-ads-links` are read commands.
`ga4 admin GET|POST|PATCH|DELETE <path>` is the whole Admin API (custom
definitions, key events, streams, retention, links, access bindings): relative
path under `accounts`, `properties` or `accountSummaries`, aliases resolve,
`--body FILE|-`, repeatable `--query KEY=VALUE`, `--api v1alpha` when v1beta lacks
the method. Writes are sent once, never retried: after a timeout, an HTTP 5xx or
a 2xx whose body cannot be read, GET the resource before repeating. A read-only probe on 2026-10-05 found that account-level access bindings can
return 403 even when property-scoped history is readable. Check the required role.
GA4 and GSC share the credential chain described above; do not duplicate the key
or ask for interactive login.
`ga4 --where` identifies the credential and map paths and the configured aliases
without opening credentials or refreshing auth.
GA4 records the *destination* of a redirect, so it cannot attribute traffic to a
URL that 301s; for that, read nginx access logs or use GSC.

## Discord — `discord-cli`

Use `discord-cli --help`. Named read commands cover guild/channel/message reads,
roles, scheduled events and member search. Message lists are one bounded page:
check the pagination warning and continue with a message-ID cursor as needed.
The bot token resolves from environment, BWS, then parsed `~/.secrets`;
`--where` reports candidates without retrieving token values. Never source or
print secret files. Use the existing bot identity and guild grants.

`send`, `edit`, and `delete` require prior human authorization plus
`--confirm-write`; the flag alone is not authorization. Message content comes
from a file; automatic mention expansion is disabled. Writes have no prompt-free
Bash grant, and the shell guard prompts on them even in bypass mode.

`discord-cli api METHOD PATH` reaches everything else (threads, reactions, pins,
moderation, channel/role/member/webhook admin, the audit log): an uppercase
method and a route relative to `https://discord.com/api/v10`, such as
`discord-cli api GET /guilds/<guild-id>/audit-logs --query limit=50`.
`--query KEY=VALUE` repeats; `--body FILE|-` is a JSON object or array for
non-GET methods (no file uploads or audit-log reason header). Only `GET` reads.
Every other method needs prior human authorization plus `--confirm-write`, and
the guard prompts on it. Percent-encode reaction emoji. A write is sent once:
after a timeout or 5xx, GET the resource before repeating. An `api` message
body is sent as written: include `"allowed_mentions": {"parse": []}` to
suppress pings. The project-scoped Discord MCP opt-in (snippet in
`harness/data-source-clis.md`) is no longer needed for these.
Operational webhook alerts are independent and remain intact.

## Resend — `resend-cli`, the official CLI with the MAIN key

`resend-cli <command> --help` is the vendor's help and needs no credential. Named
reads (`emails list|get`, `emails receiving list|get`, `domains list|get`,
`logs list|get`, `webhooks list|get`, `api-keys list`, `usage`, every other
`* list|get` outside the refused `auth` and `careers` groups) run as-is with the vendor's native JSON and cursor pagination
(`--limit` 1–100, `--after`, `--before`); put vendor options after the command.
`emails send|batch`, `broadcasts send`, `events send`, `emails receiving
forward` and `broadcasts create --send` (or `--scheduled-at`) need prior human
approval plus `--confirm-send`; other writes `--confirm-write`; deletes, API-key
and signing-secret operations `--confirm-destructive`. The flag is a guard, not authorization: the
shell guard asks on every send, write or destructive command path (and on a path it cannot read
literally) however the flag is spelled, bypass mode included, and on any text that spells
`resend-cli` followed by such a path, even inside a comment, a quoted string or a grep pattern; spell
the command plainly and keep mentions of the CLI to its read verbs. Help on a write path passes only
when `resend-cli` is the command itself (not behind `command`, `sudo`, `env` or another launcher)
and a plain `-h`/`--help` comes before any word that may be `--`: a bare `$VAR` or substitution,
a glob or `--` (`--text "$BODY" -h` and `-h<(…)` ask); any command over 32 KiB that names the CLI
asks. The only
credential is `RESEND_API_KEY_MAIN` from one exact BWS record: `credential_unbound`
(exit 3) means the binding file or its record is missing (see Per-host configuration) —
do not search BWS for it, set `RESEND_API_KEY`, pass `--api-key`, or run
`resend login` (all refused or ignored). `--where` shows binding, bws and
vendor-pin state without touching a credential; `vendor_missing` names the
installer. The vendor's own errors (`restricted_api_key` for a send-only key,
`auth_error`) pass through unchanged with its exit status. Details:
`harness/data-source-clis.md` → "Resend".

## Stripe — `stripe-api`, never the Stripe MCP

`stripe-api prbot|startupbros GET|POST|DELETE /v1/...` is the full REST surface
the account's restricted key grants. `-d key=value` is a query on GET and a form
field on writes; `--paginate` follows `has_more`. Writes are fail-closed: a
POST runs without a prompt only on the listed configuration paths (webhook
endpoints, products, prices, customer fields other than `balance`,
`cash_balance`, `coupon`, `promotion_code` and `discounts`, tax and shipping
rates, portal and payment method configuration, files, radar lists,
entitlement features, report runs, quotes before acceptance, checkout session
expiry, `/v2` event destinations); after one, run a readback GET yourself,
since `stripe-api` does not. Every
other POST, money-moving or simply unlisted, needs `--confirm-money`, and
every DELETE needs `--confirm-delete`; spell both in full, since abbreviations
are refused. Both prompt the operator, and the flag alone is not
authorization. The prompt matches the literal command text, so spell confirm
flags plainly, unquoted and unescaped, and run `stripe-api`, never
`python3 .../stripe_api.py`. An endpoint missing from the list asks; add it to
`CONFIG_WRITES` in `bin/stripe_api.py` when a consumer needs it
unprompted. Keys come from BWS; `--where` reports sources. Error
`credential_unavailable` means BWS failed to answer: retry, never re-seed.
Details: `harness/data-source-clis.md`.

## PostHog — `posthog-api PROJECT`, never bare `posthog-cli api` with env

`posthog-api PROJECT <posthog-cli api args>`, for
example `posthog-api "$PROJECT" call --json execute-sql '{"query":"..."}'`. Commands
come from `posthog-cli api --agent-help`. Never select the project with
`POSTHOG_CLI_PROJECT_ID=...` alone: posthog-cli 0.8.2 silently answers from
the login's active project unless the organization id is also set, which the wrapper does.
Destructive tools need posthog-cli's `--confirm`, which prompts. Bare
`posthog-cli api` is allowed only for `--agent-help` and `skill ...`.

## Supabase — `supabase-api`, over the read-only Supabase MCP

`supabase-api sql|logs|advisors|migrations PROJECT ...`, `supabase-api projects`
and `supabase-api api METHOD /v1/...` cover the Management API; PROJECT is
an alias from the project map or a 20-letter ref, and `{ref}`
in an `api` path takes `--project`. `sql` uses the read-only endpoint. `logs`
needs a window of at most 24 hours (`--since 6h`, or `--start`/`--end` in UTC
ending in `Z`). Writes are fail-closed: GET, the read-only POSTs and the listed
configuration writes (project rename, action run status, backup schedule,
restore point, webhooks enable, custom hostname initialize and reverify) run;
every other write, including `sql --write`, migrations, deletes and branch
writes, needs `--confirm-destructive` spelled in full, which prompts, and the
flag alone is not authorization. After a configuration write, GET it back
yourself. Output redacts tokens, secret keys, non-anon JWTs and secret-named
fields; a write carrying a `[redacted]` placeholder is refused, so omit the
field. The token resolves env `SUPABASE_ACCESS_TOKEN`, then the bws record of
that name, then `~/.secrets`; `credential_unavailable` means bws failed to
answer (retry, never re-seed), and a result carrying `stale_env: true` means
the shell's env token is revoked: run `env -u SUPABASE_ACCESS_TOKEN` for the
`supabase` CLI and the migration scripts, which share the order but never
retry. Details:
`harness/data-source-clis.md`.

## Vercel — `vercel`, including `vercel api`

The whole CLI is allowed, and `vercel api /path` reads the REST API. These
prompt, and a headless agent cannot answer a prompt, so plan around them:

- deletes: `rm`/`remove`/`del` at any depth, and `vercel api` DELETE;
- production: `--prod`, `--target production` (either spelling), `redeploy`
  (it can keep a production target), `alias` (its default subcommand re-points
  a domain, so `alias ls` prompts too), `rr`/`rolling-release` (including
  `fetch`), `promote`, `rollback`;
- spending: `buy`, `domains buy|move|transfer-in`,
  `integration add|accept-terms|update`;
- `disconnect` at any depth, `logout`, `login`, `--dangerously-skip-permissions`;
- `blob delete-store`, `blob empty-store`, `cache dangerously-delete`,
  `project protection disable`, and `mcp` (it writes MCP client config);
- every `vercel api` call that is not a plain GET: `-X`/`--method`, and
  `-F`/`-f`/`--input`, which switch the method to POST. The `-f` rule matches
  any argument containing `-f`. On reads, put query parameters in the path
  (`vercel api '/v6/deployments?limit=5'`) and omit `-X`. Admin writes go
  through the named subcommands (`env`, `domains add`, `dns`, `project`),
  which prompt only in the forms above. `env add|update ... production` does
  not prompt: send the value on stdin, never `--value`, and read it back;
- any flag before the subcommand (`vercel --scope x rm ...` would slip past
  the subcommand rules), so put global flags (`--cwd`, `--scope`, `--debug`)
  after the subcommand: `vercel ls prbot --scope <team>`.

Never start a delete without approval. vercel's own delete confirmation
(skipped only by `rm --yes` or `api --dangerously-skip-permissions`) is a
terminal prompt that a headless agent cannot answer.

Read traps (vercel 51.2.1): with `--format json`, progress lines go to stderr,
so never merge the streams into the JSON parse (send stderr to a file, e.g.
`2>vercel.err`, and read it on failure); `vercel inspect <url> --logs`
writes the build log to stderr with an empty stdout, so capture `2>&1`; and
`vercel logs` shows only the current git branch unless given `--no-branch`.
`vercel ls <name>` takes the project name (`prbot`), not a directory name.

## DataForSEO — `dfs`

- `dfs --help` is the command surface (traffic and keyword difficulty live under `dfs raw`); credentials and install mechanics: `harness/data-source-clis.md`.
- **Run `dfs --where` before believing a 401.** `~/.secrets` carries TWO DataForSEO pairs and only one works: `DATAFORSEO_LOGIN`/`DATAFORSEO_PASSWORD` is live; `DATAFORSEO_API_USER`/`DATAFORSEO_API_PASSWORD` is stale and returns `40100`. Both are now in bws under the working names, and `dfs` names the source it resolved. Incident: `harness/data-source-clis.md`.

## Exa — `exa-cli`, never an MCP

Put `--json` and other global flags after the subcommand — that's the prompt-free form the per-verb `Bash(exa-cli search:*)`/`Bash(exa-cli contents:*)` allow entries match; `exa-cli --help` is the command surface. Verbs, JSON envelope, exit codes, and credential order: `harness/data-source-clis.md`. Which provider answers which request shape and when to escalate: `harness/cc-mcp-architecture.md` → "Web retrieval routing".

## Firecrawl — `firecrawl-cli`

Verbs: fetch, extract, shot, act, agent, interact, search, map, raw. Two or more URLs through the vendor CLI write into the working directory; the wrapper fans out. Verbs, flags, and budgets: `harness/data-source-clis.md`. The Firecrawl MCP is retired; there is no other path.

## WhatsApp — direct `wacli` with the canonical store

Agents should spell reads as `wacli --store <store> --read-only --json ...`, with `<store>` written out as the literal absolute path of the canonical store (`~/.local/state/wacli` with the home directory expanded, since the guard denies shell-expanded values and treats `~` as one); install seeds that path into `WACLI_STORE_DIR`, which the guard reads as canonical when absolute, while the guard also recognizes a caller-supplied truthy `WACLI_READONLY` (sync does not set it globally). Explicit flags keep the effect reviewable. List/search calls need a concrete `--limit` from 1–200. Never inspect/copy `session.db`, export the whole archive into context, or automate bulk/broadcast/auto-reply messaging. Shell-expanded values in recognized literal-`wacli` forms are denied; literal writes are hook-ask-gated.

## vast.ai GPU rental — `vastai` and `vast-ssh`, live money

Rent a GPU when a job needs one: `vastai search offers --raw --limit 10 -o dph_total 'gpu_name=RTX_4090 num_gpus=1 verified=true rentable=true'` → `vastai create instance <offer-id> --image <image> --disk 40 --ssh --direct --label <job> --cancel-unavail --raw` → poll `vastai show instance <id> --raw` until `actual_status == "running"` → `vast-ssh <id> -- <command>` → `vastai destroy instance <id> -y`, confirmed by `show instance <id> --raw` answering `{"instances": null}` (the answer for any id the account does not own; observed live for an unowned id, so watch the first real destroy end to end). Query fields for the search are the vendor's (`dph`, `reliability`, `cuda_vers`, `gpu_ram`, `inet_down`, `geolocation`), not the result fields (`dph_total`, `reliability2`). **The account auto-tops-up and the vendor has no spend cap**, so label every instance, destroy it when done, and run `vastai show instances --raw` before and after. Pass `--raw` to anything you parse and check the exit status: the wrapper turns the vendor's exit-0 API errors into exit 1 and relays the stderr reason. It refuses `set api-key`, `--api-key`, `--explain`, `--curl`, a non-loopback `--url` (each flag also under any argparse prefix abbreviation such as `--cur` or `--ur`), `update`, and `destroy` without `-y`. Long jobs: run them detached from a script piped onto the instance (`vast-ssh <id> -- bash launch.sh`, the script holding `nohup setsid bash run.sh > run.out 2>&1 < /dev/null &`); a foreground command holds the ssh session past the Bash tool's 30-minute cap, and a worktree session's command-shape guard refuses a quoted compound command after `--`, so a loop also goes in a script. `vastai --where` names the credential source (bws `VAST_API_KEY`), never the value. Step table, key scope, ssh-key and other-host setup: `harness/data-source-clis.md`.

## fal.ai hosted models — `fal-api`, live money

Find, price, upload, run: `fal-api api GET /v1/models -d q=<name>` → `fal-api api GET /v1/models/pricing -d endpoint_id=<id>` (the unit price; the `POST /v1/models/pricing/estimate` per-call figure can differ by far, so read what a unit is) → `fal-api upload <file>` (prints the CDN URL under `data.url`, the model's `video_url`/`image_url`) → `fal-api run <endpoint> --input in.json` (waits up to `--wait`, default 600 s, at most 1500). Longer jobs: `submit`, then `status <endpoint> <id> --logs` and `result <endpoint> <id>`; pass the same full model id to every verb, since the wrapper derives the status path from it. **`run`, `submit` and `upload` spend credits with no prompt**, a `timeout` leaves the job running and billing (collect or `cancel` it), and a failed submission is never retried: check fal.ai/dashboard/requests before submitting again. `billing` means top up; retrying will not help. `fal_webhook` is refused. Under `api`, GET and the pricing estimate run as-is; every other write (keys, secrets, compute) needs `--confirm-destructive`, which prompts, and the flag alone is not authorization. The key is bws `FAL_KEY` (Full access); `fal-api --where` names the source, never the value. Details: `harness/data-source-clis.md` → "fal.ai model runs".
