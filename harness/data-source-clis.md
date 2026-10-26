# Data-source CLIs: gsc, ga4, discord-cli, resend-cli, dfs, exa-cli, firecrawl-cli, stripe-api, posthog-api, supabase-api, vercel, vastai, and fal-api

Detail demoted out of the always-loaded `CLAUDE.md` (2026-08-11). That
file keeps the routing decision and the measured traps — the facts that change
what an agent does. Everything here is either recoverable from the tool's own
`--help` or needed only when you are installing, debugging, or re-permissioning
the tools.

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

## Why a CLI and not an MCP server

MCP adds a protocol, a session lifecycle, and a third-party package between the
agent and the API: it breaks on SDK drift, must be reconnected per session, and
is unreachable from Codex, cron jobs, and shell scripts. (Claude Code subagents
and Workflow agents DO reach a session's MCP servers through ToolSearch --
verified 2026-09-04 -- so the CLI case is the other lanes, not subagents.) A
CLI shells out from anywhere, pins its own deps, and fails with a readable
stack trace instead of `-32000`. Precedent: `mcp-gsc` died on
`ModuleNotFoundError: mcp.server.fastmcp` (2026-08-03) while the credentials
behind it were perfectly fine.

## Command surface

Run `gsc --help`, `ga4 --help`, `discord-cli --help`, `dfs --help`,
`exa-cli --help`, and `firecrawl-cli --help` —
they are the authority and they do not drift. Notes that `--help` does *not*
give you:

- `gsc`: put `--json` **after** the subcommand (`gsc sites --json`); the
  before-subcommand form is silently ignored by the current parser. `gsc url`
  is URL Inspection. `gsc sitemap list|submit` — `submit` is the only call
  that requests the writable scope; every read stays `webmasters.readonly`.
- `dfs`: `--json` / `--limit` / `--location` are global and must come *before*
  the subcommand (`dfs --limit 5 backlinks <domain>`). Traffic estimates and
  keyword difficulty are only reachable through `dfs raw <endpoint>`, not a
  named subcommand.
- `exa-cli`: two verbs, `exa-cli search <query>` and
  `exa-cli contents <url-or-id>...`. `--json` and the other global flags
  (`--timeout`) are accepted before or after the subcommand, but only the
  after-subcommand form (`exa-cli search "<query>" --json`) is prompt-free —
  it's the form the per-verb `Bash(exa-cli search:*)` /
  `Bash(exa-cli contents:*)` allow entries match, so put global flags after
  the subcommand. `--where` prints the resolved credential source and exits
  without calling Exa, and never prints any part of the key; `--version` and
  `--help` also exit without resolving a credential. Every `--json` response
  carries `via` (`exa/search` or `exa/contents`) and `cost_usd` (Exa's
  `costDollars.total`) at the top level, with Exa's payload nested unchanged
  under `data`; a `contents` response additionally carries one `items[]` entry
  per requested URL or id (`status`, `cached`, and on error Exa's `tag` and
  HTTP status). Exit 0 when at least one item succeeded, 1 on a provider or
  credential failure, 2 on a usage error, 3 when the response is well-formed
  but no requested item succeeded. Cost per call rides in `cost_usd` on every
  response — Exa bills `/search` around $7 per 1k requests and `/contents`
  around $1 per 1k. Tests point the stub-selection env var `EXA_API_BASE` at a
  loopback host (`127.0.0.1`, `::1`, `localhost` only — any other value exits
  1 before a credential is even read); it has no effect outside a test
  harness.
- `resend-cli`: the vendor command comes first and vendor options after it
  (`resend-cli emails list --limit 20 --after <cursor>`); `--json` is added
  for you. `resend-cli <command> --help` is the vendor's own help. Sends need
  `--confirm-send`, other writes `--confirm-write`, deletes and key or
  signing-secret operations `--confirm-destructive`; `--api-key`, `--profile`
  and `--insecure-storage` are refused everywhere. See "Resend" below.
- Which provider answers which request shape (search, fetch, rendered scrape,
  map/crawl, extraction, code/issue search, papers, library docs), and the
  triggers for escalating: `harness/cc-mcp-architecture.md` → "Web
  retrieval routing".

## Incidents (demoted from `CLAUDE.md`, 2026-09-21, dotfiles#1286)

- **GSC row-limit truncation.** In a measured incident,
  a page reporting thousands of impressions returned query rows
  totalling **22** when derived from a `page,query` pull; `--page` returned
  hundreds of queries and most of the impressions.
- **DataForSEO stale-credential misdiagnosis.** Demoted from
  `CLAUDE.md`: "On 2026-08-05 an agent grepped for the second pair,
  got a 401, and concluded the account was dead while the working credential
  sat four lines away in the same file."

## firecrawl-cli

`firecrawl-cli` is a thin capability wrapper over the official
`firecrawl` CLI, available to Claude Code, Codex, subagents, cron, and shell
scripts. Claude Code's Firecrawl MCP was retired on 2026-09-13 (#1178). Use
`firecrawl-cli capabilities --json` for the live flags, costs, limits, and
exit dictionary; it makes no vendor request.

| Verb | Use |
|---|---|
| `fetch <path-or-url>` | Parse a local document or scrape a URL; optional `--schema`, `--schema-file`, or `-Q` / `--query` for extraction; `--max-age <ms>` bounds staleness (0 forces a live fetch; URLs only); `--format <list>` replaces the default summary with vendor formats |
| `extract <path-or-url>` | Fetch with a required schema or question |
| `shot <url>` | Capture a screenshot |
| `act <url>` | Scrape after browser actions supplied with `--actions` or `--actions-file` |
| `agent <prompt-or-job-id>` | Run extraction, or use `--status`, `--wait`, or `--cancel` for a job; try cheaper `fetch --schema` first and bound jobs with `--max-credits` |
| `interact <text-or-stop>` | Prompt or stop a browser session; always pass an explicit `--scrape-id <id>` returned by `fetch` |
| `search <query>` | Discover pages; bound results with `--limit` (1–100); filter with `--categories github,research,pdf,developer`, `--sources web,images,news`, `--tbs qdr:h\|d\|w\|m\|y`, and `--location "<place>"`; the envelope's `search_id` feeds `raw -- search-feedback <id>` |
| `map <url>` | Discover site URLs; bound results with `--limit` |
| `raw -- <vendor-args>` | Pass vendor arguments unchanged; includes research, crawl, and monitor; request vendor `--json` after `--` |
| `capabilities` | Inspect the contract without vendor contact |
| `budget` | Inspect budget availability without vendor contact |

- **Canonical flag order:** global flags go after the verb, for example
  `firecrawl-cli fetch <url> --json --timeout 60`. For passthrough, put wrapper
  flags before the separator and vendor flags after it:
  `firecrawl-cli raw --json -- research search-github "<query>" --json`.
  Crawl and monitor are raw-only; credits scale with work, and raw cost is
  unknown until accounting settles.
- **Developer index:** `firecrawl-cli search "<q>" --categories developer --json`
  is answered by `POST /v2/search` directly, because vendor CLI 1.19.26 rejects
  that category client-side (firecrawl/cli#222). It needs `FIRECRAWL_API_KEY` in
  the environment (Claude lanes inherit it; a Codex lane may not), honors
  `FIRECRAWL_API_URL` only over https or to a loopback host, and shares the
  envelope, budget, failure shapes, and redaction with every other verb. Without
  the key it refuses with exit 4 and names
  `raw -- research search-github "<q>"` (repos, issues, PRs, READMEs) as the
  alternative. Every other category goes through the vendor CLI. A redirect
  from the API is refused, never followed with the key. Without the vendor
  binary on PATH the call still runs under the local session and day caps, but
  the account floor is unchecked and the envelope's `degraded` list says so.
- **JSON envelope:** `ok`, `surface`, `verb`, `credits_spent`,
  `credits_remaining`, `budget_remaining`, `degraded`, `error`, and `data`.
  Unavailable credit values may be null; `error` supplies a code, message,
  and `next_action`. Exit codes: **0** success; **1** vendor or provider error;
  **2** transient auth or provider failure (back off); **3** budget refused;
  **4** usage error; **5** code mode refused; **6** partial success.
- **Budget:** the default session allowance is 300 credits; unattended calls
  use the daily bucket (default ceiling 1,000). A refusal is exit 3; cron
  callers must alert on it themselves. `--raise-budget <credits>` requires
  `--reason "<reason>"` and increases the session or unattended day bucket
  within the cumulative daily raise bound (default 500). Ledger state lives
  under `~/.claude/state/firecrawl-cli/`; `capabilities --json` lists the
  budget settings and their environment overrides.
- **Interaction:** never rely on an implicit last session. Both
  `firecrawl-cli interact "<prompt>" --scrape-id <id> --json` and
  `firecrawl-cli interact stop --scrape-id <id> --json` require the ID.
  Code mode (`--code` with optional `--node`, `--python`, or `--bash`) needs
  `--allow-code-exec --reason "<reason>"` on that invocation; consent is never
  persisted. The same gate applies to raw interact code calls.
- **Gate scope:** budget and code-mode gates cover every Firecrawl call; the
  MCP that once bypassed them is retired (#1178).
- **Local documents and output:** PDFs use the `papers` skill's local
  extraction first and `firecrawl-cli fetch <path>` only on failure; all
  other local document formats use `firecrawl-cli fetch <path>` first.
  Two or more URLs through the vendor CLI write into the working directory;
  the wrapper fans out `fetch`, `shot`, and `act` one URL at a time. Raw is
  true passthrough and can retain vendor file effects.
- **Configuration:** `~/.config/firecrawl-cli/` belongs to the vendor; the
  wrapper never writes it. Credential details are in the Firecrawl
  two-credential paragraph below. For removal, see the rollback paragraph
  under [Install mechanics](#install-mechanics).
- **Sandboxes with a read-only home:** the ledger lives under
  `~/.claude/state/firecrawl-cli/` and `FIRECRAWL_CLI_STATE_DIR` relocates it.
  A root that cannot be created refuses with exit 4 naming that variable, never
  by dropping the ceiling. Codex's `auto` profile mounts `$HOME` read-only, so
  spell delegated calls as
  `FIRECRAWL_CLI_STATE_DIR=/tmp/firecrawl-state firecrawl-cli <verb> …`, or add
  the default directory to that profile's `writable_roots` to share one day
  bucket with the rest of the host. The vendor's throwaway working directory
  falls back to the system temp location on its own.

## GA4 and Discord: on-demand access

`ga4` replaces routine Analytics MCP startup and goes past it: named reports plus
the full Admin API (below). It uses `google-auth` from the existing disposable GSC
venv and fixed Google REST endpoints; no additional service-account key, login or
BWS materializer is needed. A plain API key cannot authenticate private GA reports.
Recreate the existing venv per `bin/gsc` if necessary; `ga4 --help`,
`--version` and `--where` work without dependencies or credentials.

```bash
ga4 accounts
ga4 metadata --property "$PROPERTY"
ga4 report --property "$PROPERTY" --request /tmp/traffic-report.json --limit 100 --offset 0
ga4 realtime --property "$PROPERTY" --request /tmp/realtime-report.json
```

Use native Data API JSON in the request file, for example:

```json
{"dateRanges":[{"startDate":"7daysAgo","endDate":"yesterday"}],"dimensions":[{"name":"pagePath"}],"metrics":[{"name":"sessions"}],"orderBys":[{"metric":{"metricName":"sessions"},"desc":true}]}
```

Choose a positive numeric property id or an alias from the project map described
above. Set `PROPERTY` in the examples to that explicit selection.
The CLI preserves filters, comparisons and other native report fields, returns
raw API JSON, warns when rowCount exceeds the returned slice and exposes offset
pagination. Admin lists return nextPageToken; use page-token to continue.
Historical conversions reports become ordinary reports using eventName and
supported eventCount/keyEvents metrics; inspect metadata rather than inventing a
special conversions endpoint. Property details, custom definitions, Google Ads
links and metadata are named read commands; they mint `analytics.readonly`. HTTP
failures do not print response bodies or bearer tokens, and redirects are refused.

`ga4 admin METHOD PATH` is the whole Admin API: create, update, archive and
delete custom definitions, key events, data streams, retention settings, product
links and access bindings. The host is fixed. PATH is a relative resource path
under `accountSummaries`, `accounts` or `properties`, with one optional trailing
`:customMethod`; property aliases resolve in it. `--body FILE|-` carries native
JSON for POST and PATCH, `--query KEY=VALUE` repeats (updateMask, pageSize,
pageToken, filter) and `--api v1alpha` reaches methods not yet in v1beta. GET
mints `analytics.readonly` plus `analytics.manage.users.readonly`; POST, PATCH
and DELETE mint `analytics.edit` plus `analytics.manage.users`. A write is sent
once and never retried, so after a timeout or an HTTP 5xx read the resource
before repeating it.
`ga4 --where` lists the scopes, map path and aliases.

```bash
ga4 admin GET properties/<property-id-or-alias>/customDimensions --query pageSize=200
ga4 admin GET accounts/<account-id>/accessBindings --api v1alpha
ga4 admin PATCH properties/<property-id-or-alias>/dataRetentionSettings --body /tmp/retention.json --query updateMask=eventDataRetention
```

What a call may do depends on the service account's GA4 role. In a read-only
probe on 2026-10-05, one account allowed access-binding reads while another
returned 403 on account-level calls but 200 on property-scoped change history.
Property editing rights do not imply account user-management rights; an account
Administrator must grant the latter. No live write confirmed those roles.

`discord-cli` is a stdlib-only request client, with no Gateway connection or
resident process. Named commands cover the observed guild/channel/message reads,
roles, scheduled events and member search, and message send/edit/delete;
`discord-cli api METHOD PATH` reaches the rest of the bot REST API. Token
resolution is `DISCORD_BOT_TOKEN` (legacy `DISCORD_TOKEN`) -> canonical BWS bot
token -> parsed `~/.secrets`. It keeps the existing bot identity; OAuth client
secrets are not bot tokens. BWS lookup and 429 retries are bounded. `--where`
reports source candidates without opening credentials or querying BWS. Requests
use a fixed v10 origin and refuse redirects. Only named reads and `api GET`
receive Bash permission grants. The registered WhatsApp shell guard also forces
a permission prompt, bypass mode included, when a command runs `discord-cli
send|edit|delete`, `discord-cli api` with any method other than a literal `GET`,
or a verb or api method it cannot read literally (a variable, a substitution, a
shell wrapper, `eval` of a held string, a method xargs supplies, an expansion
among the options before it). `python -m discord_cli` and abbreviated options
such as `--time 5` count the same. It never denies, and it passes reads, `api
GET`, unknown verbs, file operations, searches, git and commit messages that only
name the CLI. Renamed copies, `python -c`, a script read from stdin and raw
authenticated API calls are outside that recognizable-command boundary.

```bash
discord-cli channels
discord-cli messages <channel-id> --limit 50
discord-cli message <channel-id> <message-id>
# Only after explicit human authorization:
discord-cli send <channel-id> --content-file /tmp/message.txt --confirm-write
```

`discord-cli api METHOD PATH` covers threads, reactions, pins, moderation,
channel/role/member/webhook/automod administration and the audit log. METHOD is
an uppercase `GET`, `POST`, `PUT`, `PATCH` or `DELETE`. PATH is a route relative
to `https://discord.com/api/v10`; an origin, scheme, `.` or `..` segment, encoded
dot or slash, `?`, `#` or empty segment fails at parse time, so percent-encode an
emoji in a reaction route or use its `name:id` form. `--query KEY=VALUE` repeats;
`--body FILE|-` carries a JSON object or array (1 MiB at most) for non-GET
methods. A non-GET call needs human authorization and `--confirm-write`, checked
before the body file, a credential or the network is touched. It is sent once:
only a 429, which Discord did not process, is retried, so after a timeout, an
unreadable response or an HTTP 5xx read the resource before repeating it. A
body-less `PUT`, `POST` or `PATCH` goes out with `Content-Length: 0` and no content
type; no live Discord write has exercised that yet. Bodies are JSON only: there
is no multipart file upload and no `X-Audit-Log-Reason` header, so moderation
calls record no audit-log reason. Bot permissions still bound what succeeds.

```bash
discord-cli api GET /guilds/<guild-id>/audit-logs --query limit=50
discord-cli api GET /channels/<channel-id>/threads/archived/public
# Only after explicit human authorization:
discord-cli api PUT /channels/<channel-id>/messages/<message-id>/reactions/%F0%9F%91%8D/@me --confirm-write
discord-cli api POST /channels/<channel-id>/threads --body /tmp/thread.json --confirm-write
```

Response reads check the total time budget between exposed chunks and clamp
standard urllib socket idle timeouts. DNS, headers, and chunk framing follow
urllib blocking behavior and can extend elapsed wall time.

Message lists are a single bounded page; continue with before/after/around
message-ID cursors. Bot permissions/intents still determine what is visible.
Named message writes require human authorization and `--confirm-write`, consume
a content file, and disable automatic mentions. An `api` message body is sent as
written, so include `"allowed_mentions": {"parse": []}` to keep that default.
The larger Discord admin MCP remains available by deliberate project-scoped
opt-in from its existing checkout for its curated operations (its
`src/operations.json`); `discord-cli api` reaches the same REST surface without
it. To opt a repository in, add this server to that repository's `.mcp.json`; the
token stays an environment reference:

```json
{"mcpServers":{"discord":{"command":"/home/user/SITES/discord-mcp/.venv/bin/python","args":["-m","src.server"],"env":{"PYTHONPATH":"/home/user/SITES/discord-mcp","DISCORD_GUILD_ID":"000000000000000000","DISCORD_BOT_TOKEN":"${DISCORD_BOT_TOKEN}"}}}}
```

Doctor check 31 then warns on that registration until `discord` is added to
`CLI_SUPERSEDES_EXCEPTIONS` in `scripts/harness-doctor.sh` with a dated
reason; add it in the same change as the opt-in. Its maintenance timer and
`discord-notify.sh` webhook alerts are separate and remain intact.

The server has no write confirmation of its own. If the opt-in should prompt
before writes, put `mcp__discord__discord_execute` in that repository's
`permissions.ask` in the same change (the exception keeps check 31 quiet about
it). `mcp-retirement.py` leaves that repository's approvals, local
registrations and permission entries alone while its `.mcp.json` registers the
server, but still prunes the global `mcp__discord__` grants in
`~/.claude/settings.json`.

Shadcn's MCP has no observed retained transcript use and is retired from default
startup. Use the ordinary shadcn CLI when a UI task requires it.

### Retirement and activation

The owning repository changes `.mcp.json`; dotfiles supplies CLI links, routing,
grants and the doctor regression check. Activate the dotfiles CLI release before
merging the dependent members app registration PR. Existing sessions keep their
startup-time tool connections; these source changes do not reclaim their RAM.
Do not stop attached servers to accelerate reclamation while agents are working.

Runtime `settings.json` is intentionally not overwritten by sync, and
`~/.claude.json` is excluded from sync. Preview targeted cleanup explicitly:

```bash
python3 ~/.claude/scripts/mcp-retirement.py \
  --file ~/.claude/settings.json --file ~/.claude.json \
  --file ~/SITES/acme-app/.claude/settings.local.json \
  --file ~/SITES/acme-site/.claude/settings.local.json
```

Preview is read-only. In a quiet window after installing both replacement CLIs,
repeat with `--apply --quiescent`. It validates every target before writes, saves
mode-600 originals in a mode-700 backup directory, preserves unrelated JSON,
and compares the original immediately before replacing it atomically. This is
not a transaction across files or a lock on other applications: a competing
writer can race the comparison, so never apply beside the running fleet.

A project whose own `.mcp.json` still registers a retired server keeps that
server's approvals, local registrations and permission entries, in its
`<repo>/.claude/settings*.json` and in its `~/.claude.json` project entry. The
plan prints each one as `kept ... (registered in <repo>/.mcp.json)`; an
unreadable `.mcp.json` keeps every retired server for that project. That covers
repositories whose local agents or workflows still use the retired servers,
including the members app until its registration change merges. Re-run the plan after a repository drops its
registration to prune what it kept. A `<repo>/.mcp.json` passed as `--file` is
the registration itself and is pruned regardless. Shielding inherits check 31's
key matching, so any `discord-*` or `google-analytics-*` key in a project's
`.mcp.json` shields that server there.

The migration only removes retired entries; it adds no grants, and sync never
merges `permissions.allow` into the runtime file. Without the next step a
non-bypass session prompts for every `ga4` and `discord-cli` call. In the same
quiet window, append the tracked grants that the runtime file lacks (idempotent;
other keys and entries are untouched), review the diff, then move it into place:

```bash
jq --slurpfile t ~/hov-stack/settings.json '
  .permissions.allow += ([$t[0].permissions.allow[]
    | select(test("^Bash\\((ga4|discord-cli) "))] - .permissions.allow)
' ~/.claude/settings.json > /tmp/settings.next.json
diff ~/.claude/settings.json /tmp/settings.next.json
```

`ga4 admin DELETE` is deliberately not granted, so it still prompts outside
bypass mode. That is a narrow gate, not a destructive-action gate: POST and
PATCH are granted, and they carry archive custom methods, access-binding
creation and batch changes. The agent's own confirm-before-destructive rule
covers those.

Doctor check 31 checks suffixed registrations/grants, project settings and global
project approval arrays. GA/Discord retirement becomes active when its CLI is on
PATH; shadcn is checked unconditionally. A deliberate advanced Discord MCP
coexistence is an explicit audit exception, not justification to re-enable it by
default. Backups contain runtime credentials and stay host-local; never commit them.

References: [Google runReport](https://developers.google.com/analytics/devguides/reporting/data/v1/rest/v1beta/properties/runReport),
[Admin API v1beta](https://developers.google.com/analytics/devguides/config/admin/v1/rest),
[GA4 roles](https://support.google.com/analytics/answer/9305587),
[Discord authentication](https://docs.discord.com/developers/reference),
[Discord rate limits](https://docs.discord.com/developers/topics/rate-limits).

## Resend: the official CLI behind an exact-record BWS credential

`resend-cli` (dotfiles#1741) is a thin operator wrapper over the official
`resend-cli` npm package (https://resend.com/docs/cli), pinned to 2.23.0 and
installed by `scripts/resend-cli-install.sh` into
`~/.local/lib/resend-cli/v2.23.0`, a private pnpm prefix that never joins
PATH. The wrapper decides three things from argv alone — whether the command
may run, which confirmation flag it needs, and whether it needs the
credential — and then `execve`s the vendor binary, so argument parsing, JSON
output, cursor pagination (`--limit` 1–100, `--after`, `--before`) and exit
codes are the vendor's, unchanged. It is not an API reimplementation and
there is no Resend MCP server.

- **Credential:** only `RESEND_API_KEY_MAIN` (the primary account key,
  canonical in BWS), fetched by
  one `bws --color no secret get <uuid> -o json` against the exact record
  named in the overlay binding file (see Per-host configuration); the response's `id`,
  `key` and `projectId` must all match the file before the value is accepted,
  and the value is shape-checked and never printed. There is no fallback to
  `RESEND_API_KEY` in the environment, to `resend login` caches or to a
  secret-list search, and the wrapper never creates, rotates or deletes keys.
  The bindings file names the MAIN record by its exact secret UUID (an
  identifier, not a secret); with the slot empty or removed, every
  credentialed command exits 3 with `credential_unbound` rather than
  searching. The machine token comes from `BWS_ACCESS_TOKEN` or
  `~/.config/bws/token` and reaches only the bws child.
- **Distinct failures:** `credential_unbound` (exit 3) is not
  `bws_unavailable`, `bws_timeout`, `bws_failed`, `bws_missing_bootstrap`,
  `bws_identity_mismatch` or `credential_invalid` (exit 1), and none of those is the provider's scope denial, which is the vendor's
  own `{"error":{"code":"restricted_api_key"}}` with the vendor's exit 1
  passed through. Usage-class refusals exit 2: `unsupported_command`,
  `unlisted_command`, `confirmation_required`, `forbidden_flag`, `usage`.
  Wrapper errors are `{"ok": false, "error": {"code", "message", ...}}` on
  stdout; vendor output is whatever the vendor prints.
- **Tiers** (every leaf of `resend commands` at the pin is classified; the
  fixture test fails on drift): named reads — every `* list|get` outside
  the refused groups,
  `emails metrics|attachments|attachment`, the `emails receiving` reads,
  `broadcasts recipients|clicked-links`, `contacts segments|topics`,
  `segments contacts`, the `webhooks events` reads, `domains claim get`,
  `usage`, `api-keys list` (ids and names only), `oauth-grants list` — run
  as-is. `emails send|batch`, `emails receiving forward`, `broadcasts send`,
  `events send`, and `broadcasts create` with the vendor's `--send` or
  `--scheduled-at` option (the wrapper escalates that write to a send, so
  `--confirm-write` alone is refused) need `--confirm-send`; other creates, updates, cancels,
  verifies, publishes and replays need `--confirm-write`; every `delete`,
  `suppressions batch remove`, `api-keys create|update|delete`,
  `webhooks rotate-signing-secret` and `oauth-grants revoke` need
  `--confirm-destructive`. The flag is an invocation guard checked before any
  file, credential or network access, not authorization: a send still needs
  the operator's prior approval. `login`, `logout`, `auth *`, `doctor`,
  `open`, `docs`, `update`, `completion`, `careers *`, every `* open` and
  both `listen` commands are refused outright; `commands` runs without a
  credential and `whoami` is a read.
- **Environment and retention:** the vendor sees an allowlist (PATH, HOME,
  locale, TERM, TMPDIR, `MISE_*`) plus `DO_NOT_TRACK=1`,
  `RESEND_TELEMETRY_DISABLED=1`, `RESEND_NO_UPDATE_NOTIFIER=1`, `CI=1` and an
  isolated `XDG_CONFIG_HOME` (`~/.local/state/resend-cli/xdg`), so telemetry,
  the update check, interactive prompts and any `~/.config/resend` login
  cache are out of the path; `RESEND_BASE_URL`, `RESEND_PROFILE`,
  `RESEND_CREDENTIAL_STORE`, `NODE_OPTIONS` and the rest of the parent
  environment never reach it. `RESEND_API_KEY` is set only for credentialed
  classes and only in the child. Nothing is retained: no key is written
  anywhere, and `--where` lists any vendor file that appears under the
  isolated config home so a regression is visible.
- **`--where`:** binding state (bound, unbound or invalid; project; record
  UUID), bws binary and token *presence* (env set or file exists; the file is
  never read), vendor pin
  convergence, the isolated config home, and which parent variables were
  ignored. No credential read, no network; `--version` and `--help` are
  likewise credential-free, and a help run forwards only the command path
  plus `--help` (a stray `-h` among send arguments cannot become a send).
- **Pin and install:** the wrapper refuses a vendor whose `package.json` is
  not 2.23.0 (`vendor_version_mismatch`) or that is absent (`vendor_missing`,
  naming the installer). `scripts/resend-cli-install.sh install`
  converges the prefix (idempotent; a broken prefix is set aside under
  `~/.local/lib/tool-backups/resend-cli`; one install at a time under an
  exclusive flock on `~/.local/lib/resend-cli/.install.lock`: a second run
  waits up to `RESEND_CLI_INSTALL_LOCK_WAIT` seconds, default 600, then
  rechecks convergence under the lock, or fails typed on timeout) and
  `check` reports it without taking the lock. It runs on
  demand rather than from `sync.sh install`: the install-smoke image
  has no pnpm and the hermetic sync smoke must not reach npm. Bumping the
  pin: update `PIN_VERSION` and `VENDOR_PIN`, regenerate
  `tests/fixtures/resend-cli/commands-<pin>.json` from `resend
  commands`, classify any new leaf, and list any new send-capable option in
  `SEND_OPTIONS` (the fixture carries option flags; the suite fails on a
  `--send` option the map does not escalate).
- **Permissions:** the three `--confirm-*` forms are `ask` rules for the
  bare `resend-cli` shim, for any spelling that ends in it
  (`Bash(*resend-cli *--confirm-send*)`: the `~/.local/bin` link, an
  absolute path, `bash …/resend-cli`, `env`/`timeout` wrappers, a leading
  assignment, a `cd … &&` chain) and for any interpreter running the module
  (`Bash(*resend_cli.py *--confirm-send*)`; a bare `python3 …` shape would
  otherwise fall under the `Bash(python3:*)` allow rule). `defaultMode` here
  is `bypassPermissions`, so these rules are the only prompt in front of a
  send. Live probe, 2026-10-12, Claude Code 2.1.296, same method as the
  2026-10-07 probe below (`claude -p --setting-sources ""` with only this
  permissions block, a stub `resend-cli` and `resend_cli.py` that only log,
  one shape per run, the stub's log as the evidence): the bare shim, the
  absolute path, `env resend-cli`, `cd /tmp && resend-cli …`,
  `~/.venv/bin/python3 …/resend_cli.py` (which an allow rule also matches)
  and `/usr/bin/python3 …/resend_cli.py`, each with a confirm flag, were all
  denied under `default` and under `bypassPermissions`; the
  `python3 …/resend_cli.py emails list` control ran in both modes and the
  unmatched `<path>/resend-cli emails list` control ran only under bypass.
  No text rule covers a confirm flag spelled with quotes or escapes (the
  2026-10-07 probe), held in a variable (`flag=--confirm-send; resend-cli
  emails send "$flag"`) or hidden in a `bash -c` string: the wrapper still
  receives the expanded flag. That is why the registered WhatsApp shell guard
  also dispatches `hooks/PreToolUse/resend-write-guard.js` (pro-gate
  round 1 on dotfiles#1742): it asks, bypass mode included, whenever a
  command runs `resend-cli` / `resend_cli.py` / `python -m resend_cli` with a
  path whose tier is send, write or destructive (a mirror of the wrapper's
  `COMMANDS` map, cross-checked by its test; aliases such as `broadcasts rm`
  count) or a path it cannot read literally (a variable, a substitution, a
  glob or brace, a shell wrapper, `eval` of a held string, a here-string or
  heredoc fed to a shell, a process substitution). The decision is keyed on
  the command path, never on the flag text, so no spelling of the flag
  matters. Behind that structural reading sits a fail-closed text rule: from
  the first literal `resend-cli`/`resend_cli` in the command on, any send,
  write or destructive path asks unless it is an argv word of a simple command
  that provably carries a plain `help` first or a plain `-h`/`--help`,
  `--where` or `--version` (the wrapper runs nothing then). Provably means a
  small reading of the whole text as bash splits it (quotes, escapes,
  comments, heredoc bodies; only space, tab and newline separate words): the
  CLI is that command's command word, or the script of `bash`/`sh` or a
  python script or `-m` module, after any assignments; the flag is an
  unquoted whole word before any word bash may turn into `--` (an unquoted
  expansion or substitution, `"$BODY"` with no other text, `$@`, a brace or
  bracket set, a glob such as `-*`), and a process substitution glued to it
  (`-h<(true)`, which bash hands over as `-h/dev/fd/63`) makes it no flag;
  and the path itself is a word of that command whose value is certain, so
  a substitution inside a help call still asks. Help-like text in an operand (`--text "see --help here"`), a comment,
  a redirection target, `bash -c`'s `$0`, a substitution's output and an
  argument of another program (`echo`, `printf`, `xargs`, `env`) never
  exempt (Codex review on 0816d57b and its changed-hunk reviews). Over-asks
  kept on purpose: a quoted flag (`"--help"`), help after `"$BODY"`, an
  unquoted expansion in the CLI path (`$HOME/.local/bin/resend-cli`; quote
  it or use `~`), and help run through any other launcher or option
  (`command`, `exec`, `nohup`, `sudo`, `timeout`, `time -p`, `bash -x`,
  `npx`); run help as `resend-cli … --help`. The round-1 refute fleet showed why: a bash comment, `$'...'` escape or
  heredoc body holding an apostrophe desyncs the shared lexer (dotfiles#1748),
  and `$'resend-cli'`, `{resend-cli,}`, `echo '…' | setsid sh`, a
  printf-built line, `python3 -m runpy resend_cli`, `uv run python -m
  resend_cli` or `python3 $(echo …/resend_cli.py)` leave it no named
  executable, while the text still spells the write. The cost is that data
  which spells a write (`rg 'resend-cli emails send' docs/`, a commit message
  quoting one) asks too; keep such mentions to the read verbs. It never
  denies, and it passes reads, `--where`/`--version`/help, bare and group
  calls, refused and unlisted paths, file operations, searches, git and commit
  messages that only name the CLI; if the classifier cannot load, the
  registered guard asks on any named `resend-cli` command path at all. A
  command over 32 KiB that names the CLI asks unread: some of these readings
  are quadratic, and a hook killed at its 5 s timeout passes. The registered
  `whatsapp-guard.js` keeps its established posture past its 1 MB stdin cap
  (input it cannot parse passes), so no floor reads a Bash command that long;
  one tool call is not expected to carry one. A name
  that never appears literally (`r=resend; ${r}-cli`, `resend-c*`,
  `resend_c*.py`, a module name held in a variable) is outside any text
  classifier and is the open decision in dotfiles#1749; renamed copies,
  `python -c`, a script read from stdin and the vendor binary run outside the
  wrapper are outside that boundary too. There is no prompt-free grant for any
  `resend-cli` form yet, so named reads prompt in normal mode. Allow rules for
  the read verbs are the operator's call, proposed in dotfiles#1741's PR.
- **Seams:** `RESEND_CLI_VENDOR_PREFIX`, `RESEND_CLI_BINDINGS_FILE`,
  `RESEND_CLI_STATE_DIR`, `BWS_TOKEN_FILE` and `RESEND_CLI_BWS_TIMEOUT` are
  test seams the wrapper honors in production too; `--where` lists any that
  are set as `seam_overrides` (names only). They are not a boundary: a
  caller who can set them already controls `PATH`, which is where `bws` is
  found, and can read the token file directly.
- **Acceptance boundary:** `tests/test_resend_cli.py` is fixture-only
  (fake bws, fake vendor, fixture bindings) plus a credential-free run of the
  real pinned vendor where it is installed. The live authenticated read is a
  separate acceptance step: one `resend-cli emails get` of a known delivered
  PRBot email through the real wrapper and the bound MAIN record, checking
  only the returned id and status (2026-10-13 on dotfiles#1742).

## Stripe, PostHog, Supabase and Vercel: read/write admin through CLIs

Operator direction 2026-10-07 (dotfiles#1658): agents get read/write admin access
here, not the read-only vendor MCP servers. Each tool below covers at least what
its MCP server did. The destructive or money-moving forms carry an `ask` rule in
`settings.json`; everything else is allowed.

What is enforced and what is not: the CLIs refuse a gated write unless its
confirm flag is present, before any credential read. The operator prompt on
top of that is cooperative. Claude Code matches rules against the raw command
text. A probe on 2026-10-07 (Claude Code 2.1.292, renamed stub commands, the
rules of dotfiles#1661) showed every plainly spelled ask form prompting and
every listed allow form running. But `--confirm-"money"`, `--confirm-mon''ey`
and `--confirm-m\oney` ran without a prompt while the CLI still received
`--confirm-money`, and so did `python3 bin/stripe_api.py ...` through
the pre-existing `Bash(python3:*)` allow. A flag held in a variable or a raw
API call with the key goes around the rules the same way. Agents spell
confirm flags plainly and call the installed command, never the module.

**`stripe-api ACCOUNT METHOD PATH`** (ACCOUNT is a configured public product alias) calls the
Stripe REST API directly with that account's restricted live key. Whatever the
key grants is reachable. A 403 means the key lacks that resource; grant it in
the dashboard rather than switching keys.

```bash
stripe-api prbot GET /v1/subscriptions -d status=active -d limit=100 --paginate
stripe-api startupbros GET /v1/customers/search -d "query=email:'a@example.com'"
stripe-api startupbros POST /v1/webhook_endpoints/we_123 -d 'enabled_events[]=invoice.paid'
```

- Keys resolve env `STRIPE_RK_<ACCOUNT>`, then BWS (same
  names, seeded 2026-10-07 from the keys the `stripe-*` MCP servers used), then
  `~/.secrets`. `--where` reports presence only. A failed BWS read (retried
  once) is `credential_unavailable`: retry later, never re-seed. Only
  `credential_missing` means BWS answered without the key. On 2026-10-07 a
  transient BWS failure surfaced as "missing" before this split.
- `-d` pairs are query parameters on GET, form fields on `/v1` writes (Stripe's
  bracket syntax: `metadata[k]=v`, `expand[]=customer`), and a flat JSON object
  on `/v2` writes; `--json-body FILE|-` sends nested JSON to `/v2`, and most `/v2`
  endpoints also need `--stripe-version`.
- Every POST carries an `Idempotency-Key` that the invocation's own retries
  (429, 5xx, `Stripe-Should-Retry`) reuse. If the outcome is uncertain, the
  error prints the key. Re-run with `--idempotency-key <it>` and Stripe replays
  the first result instead of charging twice.
- Writes are fail-closed. A POST runs unprompted only when its path is on the
  `CONFIG_WRITES` list in `bin/stripe_api.py`: webhook endpoints,
  products and product features, prices, customers and customer tax ids, tax
  and shipping rates, billing portal and payment method configurations,
  payment method domains, files and file links, radar value lists, entitlement
  features, report runs, quotes before acceptance, checkout session expiry and
  `/v2` event destinations. Every other POST refuses without
  `--confirm-money`. Known money-moving paths are checked first, so a path on
  both lists still refuses: refunds, payouts, transfers, charges, payment
  intents, subscriptions (including the legacy
  `/v1/customers/{id}/subscriptions` route), invoices, credit notes, coupons,
  promotion codes, customer balances, disputes, top-ups, issuing, treasury,
  checkout session creation, payment links, connected and legacy account
  writes including payout destinations, customer sources, cards and bank
  accounts, application fee refunds, quote acceptance, tax, terminal,
  `/v1/billing` usage and credit grants, climate orders, card forwarding,
  balance settings, and `/v2` money management, billing and payments. A
  customer create or update that sets `balance`, `cash_balance`, `coupon`,
  `promotion_code` or `discounts` also refuses. Anything else (account links,
  setup intents, identity, test helpers, `/v2/core/accounts`, a new endpoint)
  refuses as unlisted: add it to `CONFIG_WRITES` when a consumer needs it
  unprompted. Every DELETE refuses without `--confirm-delete`. Both refusals
  happen before any key read. Both flags carry an ask rule, so the operator
  approves each such call, and the parser refuses abbreviations: argparse
  would otherwise accept `--confirm-mo` for `--confirm-money` while the ask
  rule, a substring match on the full flag, missed it. The standing ruling is
  unchanged: a money-moving write needs a per-action go; a configuration write
  does not, but always gets an API readback. Under it, a customer update that
  sets a payment source or default payment method (`source`,
  `default_source`, `invoice_settings[default_payment_method]`), price
  creation and updates, quote finalize and cancel, and checkout session expiry
  run as configuration writes; turning any of them into a money gate is one
  entry in `MONEY_PARAM` or `MONEY_PATTERNS`.
- Every refusal, a malformed or unknown argument included, prints the JSON
  error envelope (`{"ok": false, "error": {"code": "usage", ...}}`) on stdout
  and exits 2. A response cut off mid-body (`IncompleteRead`) is an uncertain
  outcome like a timeout: a write's error names its idempotency key.
- `stripe_analytics`-style revenue summaries have no single REST endpoint;
  compute them from `GET /v1/subscriptions --paginate` and
  `GET /v1/balance_transactions --paginate`.

**`posthog-api PROJECT ...`** (PROJECT is a numeric id or an alias from the project map) runs `posthog-cli api ...` against that
project. The command surface is `posthog-cli api --agent-help`, which is the
same tool set as the PostHog MCP `exec` tool. Use the wrapper rather than
`posthog-cli api` with env variables. posthog-cli 0.8.2 replaces a
project-only override with the login's server-side active team
unless an organization id is also set, and the unprefixed
`POSTHOG_PROJECT_ID` outranks `POSTHOG_CLI_PROJECT_ID`. The wrapper sets both
organization and project in every name the CLI reads. An allow rule also does
not match past a `VAR=value` prefix, so the env form prompts in every session.
`--dotenv-file` did not carry the override in testing. Destructive tools
refuse without posthog-cli's own `--confirm`, which carries an ask rule. Bare
`posthog-cli api` is allowed only for `--agent-help` and `skill ...`, the two
forms the posthog-cli skill runs; any other bare call prompts, since it would
answer from the wrong project.

```bash
posthog-api "$PROJECT" call --json execute-sql '{"query":"SELECT count() FROM events WHERE timestamp > now() - INTERVAL 1 DAY"}'
posthog-api "$PROJECT" search insight
```

**`supabase-api COMMAND ...`** calls the Supabase Management API with the
personal access token. PROJECT is an alias from the project map or a 20-letter ref. It covers what the
read-only Supabase MCP (`@supabase/mcp-server-supabase --read-only` in the members app
and another private project) did and the writes it refused: `sql` (read-only endpoint
by default, `--write` for the read/write one), `logs` (the MCP's per-service
queries or raw ClickHouse SQL), `advisors`, `migrations`, `projects`, and
`api METHOD PATH` for every operation in the
[Management API](https://api.supabase.com/api/v1-json) (169 on 2026-10-07).
The vendor `supabase` CLI stays the tool for local development; installed
2.84.2 has no remote logs command, and its `db query`, `db advisors` and
`migration list` need `supabase link` state or a database password.

```bash
supabase-api sql "$PROJECT" 'select count(*) from public.users'
supabase-api logs "$PROJECT" --service postgres --since 6h
supabase-api advisors "$PROJECT" security
supabase-api api GET /v1/projects/{ref}/config/auth --project "$PROJECT"
```

- The token resolves env `SUPABASE_ACCESS_TOKEN`, then the bws record of
  that name (seeded 2026-10-19 with the token minted that day, read through
  `bws secret list` like the Stripe keys), then the named line in
  `~/.secrets`, parsed and never sourced; `--where` reports presence only.
  A failed bws read (retried once) with no `~/.secrets` line is
  `credential_unavailable`: retry later, never re-seed. Only
  `credential_missing` means bws answered without the record. An env token
  that Supabase rejects with 401 is retried once with a different bws or
  `~/.secrets` token, and the result then carries `stale_env: true`: the
  shell outlived a rotation and still exports the revoked token. The
  `supabase` CLI and the migration scripts (`migration-apply.sh`, through
  `scripts/lib/supabase-access-token.sh`) take the same env → bws →
  `~/.secrets` order but never retry, so run them with
  `env -u SUPABASE_ACCESS_TOKEN` from such a shell.
  Output and errors redact `sbp_` tokens, `sb_secret_` keys, every JWT whose
  role is not `anon`, and string values under secret-named keys (`smtp_pass`,
  `jwt_secret`, `*_secret`, passwords, tokens, `*_api_key`, `*_access_key`,
  the pgsodium `root_key`, `private_jwk`), except anon and publishable keys.
  A provider message that echoes a secret-named value the request sent, in
  its body or `--query`, is masked too. A
  redacted value is a placeholder: a write whose body or query carries one
  exits 2 before any token read, so omit that field from the body instead.
  The project secrets endpoints (`/v1/projects/{ref}/secrets`) carry each
  credential under the neutral key `value`, which the spec types as a plain
  string, so there `value` is redacted in responses and masked when echoed,
  and only `name` and `updated_at` stay readable.
- `logs` needs a window of at most 24 hours (`--since 6h`, or `--start` and
  `--end` in UTC ending in `Z`). Without one the endpoint answers HTTP 200
  with an `error` body; the CLI checks the window first and exits 1 on such a
  body, after retrying one that asks for a retry.
- Writes are fail-closed. GET and three read-only POSTs
  (`database/query/read-only`, `network-bans/retrieve[/enriched]`,
  `vanity-subdomain/check-availability`) run unprompted and retry on 429 and
  5xx. The listed configuration writes run unprompted and are never retried:
  project rename (`PATCH /v1/projects/{ref}`), action run status, backup
  schedule, restore point, database webhooks enable, and custom hostname
  initialize and reverify. Every other non-GET (SQL writes, migrations,
  restores, branch writes, deletes, pause, restart and upgrade, keys,
  secrets, auth, network and SSL config, function deploys, spend, and any
  endpoint not listed) refuses before any token read unless given
  `--confirm-destructive`, which carries an ask rule; abbreviations are
  refused. A branch ref can be the production project, so branch writes are
  gated too. A write that fails uncertainly, a body cut off mid-read
  included, says to GET the resource before repeating it. After a
  configuration write, GET it back yourself. Every refusal, a malformed or
  unknown argument included, prints the JSON error envelope and exits 2.
- Verified read-only on 2026-10-07: project listing, advisors, migrations and
  bounded logs returned data; a `select 1` SQL query answered from the
  read-only endpoint. One `create table` probe was sent to
  that endpoint without prior clearance; it was refused (42501, permission
  denied) and `to_regclass` confirmed nothing was created. No other write
  statement was sent.

**`vercel`** is allowed in full, including `vercel api PATH` (`--paginate`).
Ask rules cover deletes (`rm`/`remove`/`del` at any depth, `vercel api` with
`DELETE`); production changes (`--prod` and its long form `--target
production`, `redeploy`, `alias`, `rr`/`rolling-release`, `promote`,
`rollback`); spending (`buy`, `domains buy|move|transfer-in`,
`integration add|accept-terms|update`); `disconnect` at any depth; `logout`;
`--dangerously-skip-permissions`; Blob store deletion (`blob delete-store`,
`blob empty-store`) and `cache dangerously-delete`; removing deployment
protection (`project protection disable`, either spelling of `project`);
`mcp`, which writes MCP client configuration; `login`; and every `vercel api`
call that is not a plain GET. `vercel api` defaults to GET but switches to
POST when `-F`, `-f` or `--input` supplies a body, so `-X`, `--method`, `-F`, `-f` and `--input`
each ask; no path glob can separate a production promote or a purchase from a
harmless write, and the named subcommands cover admin writes. vercel rejects
abbreviated options (`--deb` is "unknown or unexpected option"), so these
substring rules have no abbreviation gap. `redeploy` asks in every form because
its help does not say which target it keeps, and `alias` asks for `ls` too
because `set` is its default subcommand. vercel also confirms a delete
interactively unless `rm` gets `-y/--yes` or `vercel api` gets
`--dangerously-skip-permissions` (`--help`, CLI 51.2.1 as installed
2026-10-07); a headless agent cannot answer that prompt. Collectors never
issue a delete or any command above, and an approved delete passes the skip
flag. Those subcommand rules match only when the subcommand directly follows
`vercel`, and vercel accepts global options (`--cwd`, `--scope`, `--debug`,
`--token`) before it, so `vercel --scope x rm app` would match none of them.
`Bash(vercel -*)` therefore asks on any leading flag; agents put global
options after the subcommand (`vercel ls prbot --scope <team>`), where every
subcommand's help lists them.

Allowed by design, under the configuration-write ruling, with a readback
afterwards: environment variable writes in any environment, production
included (`env add|update NAME production`; pass the value on stdin, never
with `--value`, which puts it in the transcript); `domains add`;
`dns add|import`; and `cache purge|invalidate`. `env pull` and `env run` read
secrets, and secret reads stay a convention rather than a gate, as for
`~/.secrets`; `env run` executes nothing a Bash call could not.

## vast.ai GPU rental: `vastai` and `vast-ssh`

`vastai` (`bin/vastai`, a shim to `vastai_wrap.py`) wraps the vendor CLI
(PyPI `vastai==1.8.3`, pinned in a uv venv at `~/.local/share/vastai-cli/venv`)
so agents can search offers, rent a GPU instance, work on it over ssh, watch it
and destroy it. The vet behind every rule here:
`docs/vets/2026-10-13-vastai-cli-harness-vet.md`.

**This spends real money.** The account has auto top-up enabled and the vendor has no spend cap or TTL
flag, so the prepaid balance is not a ceiling. Label every instance with the
job or issue it serves, destroy it when done, and audit with
`vastai show instances --raw` before and after. `actual_status` says nothing
about the job: a box whose trainer had died stayed `running` and billing for
about 2.4 hours (~$10) because its keeper watched instance status only. An
unattended keeper has to read the job's own output and destroy on job exit or
stall.

| Step | Command |
|---|---|
| Find an offer | `vastai search offers --raw --limit 10 -o dph_total 'gpu_name=RTX_4090 num_gpus=1 verified=true rentable=true'`, then pick an `id`. `-o dph_total` sorts by hourly price. Any GPU class, count or price is the agent's call; nothing here caps it. Optional query fields (from `search offers --help`): `dph<2` (an hourly price ceiling, if the job wants one), `num_gpus>=2`, `gpu_ram>=24` (GB per GPU), `cuda_vers>=12.4`, `inet_down>=500` (Mb/s), `reliability>0.98`, `disk_space>=100` (GB), `geolocation=US` or `geolocation in [US,CA]` (two-letter codes). Results carry `dph_total` and `reliability2`; those are result fields, not query fields. `-i`/`--type bid` prices interruptible offers. The `--raw` result is a top-level array; `\| jq -r '.[] \| [.id,.gpu_name,.dph_total,.inet_down,.reliability2,.geolocation] \| @tsv'` prints one line per offer. |
| Rent | `vastai create instance <offer-id> --image <docker-image> --disk 40 --ssh --direct --label <job> --cancel-unavail --raw` answers `{"new_contract": <instance-id>, "success": true, "instance_api_key": "[redacted by the vastai wrapper]"}`: the vendor prints that per-instance credential in clear (observed live), and the wrapper redacts every `*api_key` string field on both streams, so create output is safe to quote. It redacts `jupyter_token` the same way, which `show instance(s) --raw` otherwise prints in clear for every instance (seen live on 2026-10-14). `--onstart-cmd '<shell>'` runs at boot; `--env '-e KEY=VAL -p 8080:8080'` sets env and port mappings; `--bid_price <$/h>` makes the instance interruptible (omit unless intended). Without `--cancel-unavail` a failed schedule leaves a stopped, storage-billed instance behind. Offer ids churn: a host is relisted under a new id within seconds, and `create instance` on an id from an earlier search answers `no_such_ask` (the wrapper exits 1; seen twice in the first live run). Search and create in one script, and on `no_such_ask` re-search and take the new top row instead of reusing the old id. |
| Wait for boot | poll `vastai show instance <id> --raw` until `.actual_status == "running"` (about 3.5 minutes observed for an 8x RTX 4090 with a 10 GB devel image; `actual_status` is null for the first seconds, then `loading` while `status_msg` shows the image pull). A slow-link host can sit in `loading` far longer (observed: 26 minutes before it was destroyed, with avoidable cost carried into the job's total); `inet_down>=500` in the query filters those hosts out, and a box still loading long after the image should have pulled is cheaper destroyed than waited out. While loading, `ssh-url` hands back the proxy endpoint and it answers `Connection refused`: the same not-ready state as a connect timeout. One status line with the cost so far, exit 1 once the instance is gone: `vastai show instance <id> --raw \| jq -e 'if .id then {id,label,actual_status,status_msg,dph_total,duration,num_gpus,cost_so_far:((.dph_total//0)*(.duration//0)/3600)} else null end'` (`duration` is seconds since start; the formula matched the bill in the first live run). |
| Shell, run | `vast-ssh <id> -- nvidia-smi -L` runs one command; `vast-ssh <id>` opens a shell. A connect timeout or `Connection refused` while booting is normal: poll and retry. With `--direct` the endpoint is the host's own IP and port, not the `ssh_host`/`ssh_port` proxy that `show instance` reports. `vast-ssh` passes `LogLevel=ERROR`, so the known-hosts notice and vast.ai's login banner that the first contact with a box used to put on stderr (three lines, observed; a second contact prints neither) are gone, and stderr carries only errors: never filter it, a `2>&1 \| grep -v …` pipe replaces ssh's exit status with grep's (the first live run did that on about 30 calls after seeing the banner once in a wait script's log). Piping a file in with `vast-ssh <id> -- 'cat > path'` works (36 MB observed, checksum matched). The vendor's `execute` is broken in 1.8.3; use ssh. |
| Logs | `vastai logs <id> --tail 200 --raw` (`--filter <grep>`; `--daemon-logs` for the host daemon). |
| Audit | `vastai show instances --raw` lists every instance (`id`, `label`, `actual_status`, `gpu_name`, `dph_total`); `--label <job>` and `-s running` filter. |
| Stop, resume | `vastai stop instance <id>` (storage still bills), `vastai start instance <id>`. |
| Destroy | `vastai destroy instance <id> -y`, then confirm with `vastai show instance <id> --raw`, which answers `{"instances": null}` for an id the account no longer owns (observed live for an unowned id; the first real destroy should be watched end to end). `vastai destroy instances -y <id> <id>…` for several. |
| Account | `vastai show user --raw \| jq '{id, credit, balance, balance_threshold_enabled}'`; never paste the whole object, it echoes `crisp_hmac` and `sid`. `vastai show invoices-v1 --raw` for charges. |
| SSH keys | `vastai show ssh-keys --raw`; `vastai attach ssh <id> "<pubkey>"` adds a key to one running instance. Registering a new account-wide key needs `user_write`, which the agent key lacks: use the console. |

Rules that bite on the first call:

- **Pass `--raw` to everything you parse.** Without it the wrapper adds
  `--full` (and `--no-color` when stdout is not a terminal) because the vendor
  pages long output through `less` with no TTY check; tables are for humans.
- **Check the exit status, then the field.** The vendor exits 0 after API
  errors; the wrapper exits 1 when the vendor's stderr carried
  `Failed with error NNN` or a `--raw` `{"error": true, "status_code": N,
  "msg": …}` object, relaying that stderr. A `show instance <bad-id> --raw`
  still answers `{"instances": null}` with exit 0, so test the field.
- **Credential:** env `VAST_API_KEY` → bws `VAST_API_KEY` → `~/.secrets`.
  `vastai --where` names the source and never the value. Exit 4: nothing
  found (seed with the account's secrets helper).
  Exit 5: bws failed or hung (retry, never re-seed). Exit 3: venv missing, the
  two recreate commands were printed. Exit 2: refused, reason on stderr.
- **Refused by the wrapper:** `set api-key` (plaintext key file), `--api-key`
  (key in argv), `--explain` and `--curl` (both print the full key), a
  non-loopback `--url` or `VAST_URL` (sends the key to that host), `update`
  (self-update outside the venv), and `destroy instance(s)` without `-y`
  (headless, the vendor prints `Aborted.` and exits 0 while billing continues).
  The flag guards read argparse prefix abbreviations the way the vendor does,
  so `--cur`, `--expl`, `--ur` and `--api` are refused too; spell flags out.
- **Key scope** (`agent-wsl-host`): user read, instances read and write, billing
  read, misc (offer search). No user write (cannot mint keys or account ssh
  keys), no billing write (cannot move credit). Every write it can do is an
  instance operation; the blast radius is instances and what they cost.
- **`ssh-url`** ignores `--raw`, prints `ssh://root@HOST:PORT`, and can cache a
  `-1` port if asked before the instance has one. `vast-ssh` accepts only a
  proper URL line and keeps a per-instance known_hosts file under
  `~/.ssh/known_hosts.vastai/`, because vast.ai proxies reuse host:port across
  instances and one shared file would false-alarm.
- **Long jobs over `vast-ssh`:** launch them detached from a script on the
  instance: pipe it in with `vast-ssh <id> -- 'cat > launch.sh'`, where the
  script's line is `nohup setsid bash run.sh > run.out 2>&1 < /dev/null &`,
  then `vast-ssh <id> -- bash launch.sh` and poll `run.out` with later calls.
  The inline form `vast-ssh <id> -- 'cd dir && nohup setsid bash run.sh >
  run.out 2>&1 < /dev/null & echo launched'` is not detached: the `&`
  backgrounds the whole `cd && nohup …` list as a subshell whose own stdout
  and stderr are still the ssh session, so the call lasts as long as the job
  (measured: 27 s for a 25 s sleep; in the first live run a setup launched
  this way held its call 43 s and two trainer launches held theirs past the
  Bash tool's default 300 s foreground timeout, after which the tool moves
  the call to the background without killing it). Group the launch instead, `cd dir && {
  nohup setsid bash run.sh >> run.out 2>&1 < /dev/null & }; echo launched`,
  which returned in 1 s with the job alive, or keep it in the shipped script.
  A remote `>` inside the quoted string also trips dcg's truncating-redirect
  rules (`redirect-truncate-root-home`, `redirect-truncate-dynamic-path`),
  which read it as a local redirect: use `>>`, or put the redirect in the
  script. The same script pattern is how a worktree session gets a loop onto
  the instance: its command-shape guard refuses a quoted compound command
  after `--`, such as `vast-ssh <id> -- 'timeout N bash -c "until …; done"'`
  (refused and papercut-logged the same day); `bash poll.sh` passes.
- **Interactive-only vendor paths:** `show invoices-v1 --charges` prompts even
  with `--full` (use `--raw`); `cloud copy --schedule` cannot be made headless.
- Every vendor process, `--version` included, fetches the GPU-name catalog
  from the console at import and creates XDG config, cache and state
  directories; the wrapper points credential-free commands at a closed
  loopback port instead. The first authenticated call writes
  `~/.config/vastai/vast_role`. Update nudges are off
  (`VASTAI_NO_UPDATE_CHECK=1`).
- **The vendor's `SKILL.md`** (in the wheel, linked from `vastai --help`) is
  not installed: it says `curl | bash` and `set api-key`, and names two
  commands that do not exist (`update instance --bid_price`, really
  `change bid <id> --price`; `create api-key --permissions`, really
  `--permission_file`). This section is the instruction channel.
- **Other hosts and Codex** need the venv (the wrapper prints the two `uv`
  commands on exit 3), a bws machine token, and their own ssh key (console, or
  `attach ssh` per instance; `VAST_SSH_KEY=<path>`). Under Codex's read-only
  `$HOME`, spell calls as `XDG_CONFIG_HOME=/tmp/vast-xdg
  XDG_CACHE_HOME=/tmp/vast-xdg XDG_STATE_HOME=/tmp/vast-xdg vastai …`.
- **Native Windows shells** (Claude Code's Git Bash tool, PowerShell, cmd,
  Codex on Windows) get `vastai` and `vast-ssh` as hops into this wrapper, not
  a second install: `windows/bin/{vastai,vast-ssh}` (sh, for Git Bash) and
  their `.cmd` twins, deployed by `install.sh` as real copies into
  `C:\Users\user\.local\bin` (`DOTFILES_COPIES` in `lib/manifest.sh`;
  `manifest_check` reports drift). Each runs `wsl.exe -e
  /home/user/.local/bin/<name> …`; the venv, the credential chain and every
  guard stay in WSL. The WSL shim puts `~/.local/bin` back on PATH because a
  non-login hop (or a systemd timer) arrives without it and `bws` lives there;
  before that fix the chain answered exit 5 "bws could not be read" from any
  non-login caller. The sh twins set `MSYS_NO_PATHCONV=1`, or Git Bash
  rewrites `/home/...` and any `/`-leading argument into `C:\Program
  Files\Git\...` paths. Nothing vast.ai is installed or stored on the Windows
  side: no vendor plugin (`vastai@claude-plugins-official`, which the vet
  skipped), no `pip install vastai`, no `set api-key`. A WSL session can
  exercise the hop: `cmd.exe /c %USERPROFILE%\.local\bin\vastai.cmd --where`
  and the sh twin under Git Bash (`"/mnt/c/Program Files/Git/bin/bash.exe" -c
  '~/.local/bin/vastai --where'`) both answered `bws:VAST_API_KEY` exit 0 on
  2026-10-22, a bogus subcommand passed the wrapper's exit 2 through, and an
  argv probe kept spaces, `=` and `/`-leading arguments intact. The fixed-path
  hop had passed the same --where probe on 2026-10-14 (an earlier session had
  seen vsock accept errors and this doc said re-entry was impossible; that was
  wrong). What such a probe proves is the shim and the wrapper under the
  operator's own token, never a sandboxed caller, which only a real Windows agent session
  can show. wsl.exe reports a launcher refusal as exit -1 (cmd
  `%errorlevel%`, PowerShell `$LASTEXITCODE`; Git Bash sees 127, a parent
  shell via `cmd /c` sees 255) while an inner exit is 0-255, so the `.cmd`
  twins branch on -1, print "WSL refused the hop" plus the whoami check on
  stderr, and `exit /b` with the original code; the sh twins add nothing
  because 127 is also a missing program or a remote `command not found`.
  The hop runs as whatever Windows account and token the caller holds, and
  WSL distributions are per user, so a sandboxed shell cannot reach the
  running distro. Codex's Windows sandbox answers `Access is denied. Error
  code: Wsl/Service/CreateInstance/E_ACCESSDENIED` (openai/codex#41415;
  confirmed 2026-10-14 from a Windows Codex session on this box, where
  `whoami` printed `<host>\codexsandboxoffline`: the `[windows] sandbox =
  "elevated"` service runs commands as `CodexSandboxOnline` or
  `CodexSandboxOffline`, and the Offline one means that chat also has no
  network); a hand-built restricted token of the same account dies in the
  client with "Not enough memory resources" instead. Either way the shell
  does not hold will's ordinary token: `whoami` names another account, or
  `whoami /groups | findstr /i "S-1-5-12 S-1-15-2"` lists a RESTRICTED or
  AppContainer SID (Codex's `unelevated` mode keeps will's name and restricts
  the token). The fix is to rerun outside the sandbox or with escalated
  permissions, never a vendor install. The agent cannot do that alone on
  this box: `C:\Users\user\.codex\config.toml` has `approval_policy =
  "never"`, so a sandboxed Codex chat never asks to escalate; the operator
  switches that chat to full access (the Codex app's permissions mode) or
  runs the command from WSL.
  Elevation is not the gate: the WSL service keys sessions by user SID and
  hands any same-user caller the running instance, a deny-only basic-user
  token (`runas /trustlevel:0x20000`) hops fine, and Claude Code on native
  Windows runs its shell commands unsandboxed.

## fal.ai model runs: `fal-api`, live money

`fal-api` (`bin/fal-api`, a shim to `fal_api.py`) is a stdlib client for
fal.ai's queue (`queue.fal.run`), storage (`rest.fal.ai` and the
`v3.fal.media` CDN) and Platform API (`api.fal.ai/v1`), so agents can find a
hosted model, price it, upload its inputs, run it and collect the result. No
vendor package is installed; the upload flow follows `fal_client` 1.0.3's
source. `fal-api --help` is the command surface.

**This spends real money.** `run`, `submit` and `upload` spend credits with no
prompt. Price a model before running it:
`fal-api api GET /v1/models/pricing -d endpoint_id=<id>` gives the unit price,
and `fal-api api POST /v1/models/pricing/estimate --body <file>` with
`{"estimate_type":"historical_api_price","endpoints":{"<id>":{"call_quantity":1}}}`
gives a per-call estimate. The two can disagree by far: for
`minimax/h3-max/recast` the first said $0.05 per unit and the second $4.52 per
call (both read 2026-10-23), so read the model page for what a unit is.

| Step | Command |
|---|---|
| Find a model | `fal-api api GET /v1/models -d q=kling -d limit=20`; `--paginate` follows `next_cursor` (20 pages unless `--max-pages`) and warns on stderr. |
| Upload an input | `fal-api upload clip.mp4` prints the CDN URL under `data.url`; pass it as the model's `video_url` or `image_url`. Up to 100 MiB goes through a short-lived CDN token; larger files (to 4 GiB) go through a signed upload URL, a path not yet exercised live. A 32-byte upload was fetched back byte-identical on 2026-10-23. |
| Run and wait | `fal-api run fal-ai/flux/schnell -d prompt='a red cube'`, or `--input in.json` (`-` reads stdin) for nested inputs; `-d` sets string fields on top. It polls every `--poll` seconds (default 5) for up to `--wait` (default 600, at most 1500, under the Bash tool's 30-minute ceiling). |
| Long job | `fal-api submit <endpoint> --input in.json` prints `request_id`; then `fal-api status <endpoint> <id> --logs` and `fal-api result <endpoint> <id>`. |
| Cancel | `fal-api cancel <endpoint> <id>`; a request that already finished counts as success. |

Rules that bite on the first call:

- **Pass the full model id to every verb.** Submission goes to the whole id
  (`fal-ai/kling-video/o3/pro/video-to-video/edit`); status, result and cancel
  go to its first two segments (`fal-ai/kling-video/requests/<id>`), and the
  wrapper builds both from the id you give. Asking for status under the full
  id answers 405 (observed for four deep ids on 2026-10-23).
- **A `timeout` leaves the job running and billing.** The error carries the
  `request_id` and the `status` and `result` commands to continue; collect it
  or cancel it. `model_failed` means fal finished the request with an error
  (its `error` and `error_type` are in the output).
- **Submissions are sent once.** A 5xx or transport failure on `submit` (or
  `run`'s submit) is not retried, because fal may already have queued it:
  check fal.ai/dashboard/requests before submitting again. Reads retry
  transient failures; a 429 is retried everywhere.
- **`billing`** (HTTP 402, or a 403 whose message says balance, locked,
  billing, credit, top up, payment or insufficient) means top up at fal.ai/dashboard/billing; retrying will not help.
  The mapping is inferred from those words: fal's real out-of-credit body has
  not been seen yet, so a plain `forbidden` may be the same condition.
- **The key goes only to fal's hosts.** It is sent to `queue.fal.run`,
  `api.fal.ai` and `rest.fal.ai` only, the CDN token only to `v3.fal.media`,
  and never through a redirect (`redirect_refused`). Queue URLs are built from
  the endpoint and a checked request id, never taken from a response.
  `fal_webhook` is refused: it would send the output to an arbitrary URL. All
  output is scrubbed of the key.
- **Platform API writes need `--confirm-destructive`.** Under `api`, GET and
  the pricing estimate POST run as-is; every other write (keys, secrets,
  compute, apps) is refused before any key read unless the flag is given,
  spelled in full, and the shell guard prompts on it. The flag is an
  invocation guard, not human approval: get the operator's word first.
- **Exit codes:** 0 success, 1 fal or the credential chain refused (read
  `error.code`: `auth_failed`, `not_found`, `wrong_path`, `invalid_input`,
  `rate_limited`, `billing`, `forbidden`, `server_error`, `timeout`,
  `model_failed`, `credential_unavailable`, ...), 2 invalid input or a missing
  confirmation. `credential_unavailable` means bws failed to answer: retry,
  never re-seed.

## Credentials and permissions

- GSC and GA4 use the same service-account credential chain (see Per-host
  configuration). Keep the runtime JSON mode 600, outside the repository, with
  only the scopes and roles needed. A historical read-only check confirmed GSC
  site access and GA4 data reports; it is not a fresh access test.
- A historical IAM check recorded this finding: exactly one
  user-managed key exists for the inspected service account, matching the runtime
  copy. This is dated evidence, not a fresh inventory; inspect current key metadata
  before proposing rotation or concluding that duplicate keys exist.
- `dfs` credential resolution order: env → **bws (canonical)** → `~/.secrets` →
  the file named by `DFS_LEGACY_ENV` (deprecated legacy dotenv source; skipped when unset). `dfs --where` names the
  source it resolved — run it before believing a 401.
- `~/.secrets` carries TWO DataForSEO pairs and only one works:
  `DATAFORSEO_LOGIN` / `DATAFORSEO_PASSWORD` is live;
  `DATAFORSEO_API_USER` / `DATAFORSEO_API_PASSWORD` is stale and returns
  `40100`. Both are in bws under the working names.
- `exa-cli` credential resolution order: env (`EXA_API_KEY`) → **bws
  (canonical)** → `~/.secrets` — the same order as `dfs`. `exa-cli --where`
  names the source it resolved and never prints any part of the key; the bws
  hop is bounded at 30 seconds separately from the request timeout.
- `vastai` credential resolution order: env (`VAST_API_KEY`) → **bws
  (canonical, key `VAST_API_KEY`)** → `~/.secrets`, the same order as `dfs`
  and `exa-cli`; `vastai --where` names the source and never the value, and
  the bws hop is bounded at 30 seconds. The stored key is the scoped
  `agent-wsl-host` key (no user write, no billing write, 2FA off); the vendor's
  plaintext key file is refused, and one left behind draws a warning naming
  its path. Rotation is console-only: mint a new key there, then
  `secrets.sh seed VAST_API_KEY`. The agent ssh key `vastai-agent@wsl-host`
  is `~/.ssh/vastai_ed25519`; `vast-ssh` uses it by
  default.
- `fal-api` credential resolution order: env (`FAL_KEY`) → **bws
  (canonical, key `FAL_KEY`)** → `~/.secrets`; `fal-api --where` names the
  candidates and never reads the value. The stored key uses fal's Full access
  preset (the ADMIN scope), all models, no expiry. Rotation is dashboard-only
  (fal.ai/dashboard/keys): mint the new key, replace the bws value, delete
  the old key there.
- Firecrawl has TWO live credentials and neither is in bws yet:
  `FIRECRAWL_API_KEY` in `~/.secrets` (the official `firecrawl` CLI reads it
  from the environment; `firecrawl --status` prints the auth source,
  concurrency, and remaining credits without the key), and a second key
  embedded in the hosted MCP URL inside `~/.claude.json`, which the
  2026-09-04 vet found differs from the `~/.secrets` one and which is never
  copied into dotfiles. `~/.secrets` uses `export`-style lines, so a
  line-anchored `^FIRECRAWL_API_KEY=` grep reads the present key as absent —
  the same false negative that once made a working DataForSEO pair look
  dead. bws consolidation of the CLI-side key is open (ideation 2026-09-04,
  idea 1); the MCP-URL key stays where it is by design.

### GCP: use the headless service account, never ask for a login

Provisioned 2026-09-12. **Do not hand the operator `gcloud auth login`** — human
Workspace accounts (`operator@`, `admin@example.com`) fail non-interactively with
`Reauthentication failed. cannot prompt during non-interactive execution`, because
Workspace forces periodic interactive re-login. Service-account keys do not expire
that way.

```bash
SA=<agent-service-account>
gcloud projects list --account=$SA
gcloud services api-keys list --project=<p> --account=$SA
```

- **Always pass `--account` explicitly.** The operator's default stays
  `operator@example.com`; an agent that changes the global default surprises them in
  their own terminal.
- Key: `~/.config/gcloud/agent-gcp-sa.json` (mode 600), also in bws as
  `GCP_AGENT_SA_KEY`.
- Roles, all at the organization: `roles/viewer`,
  `roles/serviceusage.serviceUsageConsumer`, `roles/serviceusage.apiKeysAdmin`.
- Revoke everything:
  `gcloud iam service-accounts delete $SA --project=example-agent-ops`.
- Proven 2026-09-12 by creating an API key, confirming its uid, and deleting it with
  no human credential in the loop.

Two traps that cost time:

- There is **no `roles/apikeys.admin`** — the real role is
  `roles/serviceusage.apiKeysAdmin` (API keys live under Service Usage). The wrong name
  fails with `Role X is not supported for this resource`, which reads like a *scope*
  problem, so you go hunting for the right resource level instead of the right name.
  Find roles with `gcloud iam roles list --filter="name~apiKeys"`.
- Monitoring/Billing REST calls bill against the SA's home project, which has no
  billing. Pass `-H "x-goog-user-project: <target-project>"` or they fail with
  "requires billing to be enabled" naming a project you did not query.

**bws is not broken if you see `Missing access token`.** The token lives at
`~/.config/bws/token`; raw `bws` reads only `$BWS_ACCESS_TOKEN` or `-t`, and the repo
tooling (`vault-pass.sh`, `scripts/secrets.sh`) exports it for you. In an agent script:
`BWS_ACCESS_TOKEN="$(cat ~/.config/bws/token)"; export BWS_ACCESS_TOKEN`.

### Cloudflare: bws plus curl, read-only token for looking

Check the account's credential registry and Cloudflare runbook before declaring
credentials unavailable. An empty environment or `wrangler whoami` tests ambient
state, while a secrets helper may resolve credentials on demand.
The secrets runbook keeps credentials out of ambient state on purpose. A
2026-10-04 vet concluded "no credential" from exactly that check and was wrong
(`docs/vets/2026-10-04-cloudflare-cli-harness-vet.md`, §8).

- **Reads use `CLOUDFLARE_READONLY_TOKEN`.** It holds Zone, Zone Settings, DNS,
  Zone WAF and Workers Routes Read on all zones, and Workers Scripts and Workers
  R2 Storage Read on all accounts. It cannot write. It does not cover account
  rulesets (bulk redirects), lists, analytics or `GET /user`. R2 Storage Read
  also reads objects.
- **Export only that one value for the task.** Never wrap an agent in `bws run` or
  `secrets.sh run`, which inject every secret in the project. In a worktree
  session, run it from a script file (`bash file.sh`), because inline the shape
  guard can refuse the nested `$( )`. It was verified as a script file:

  ```sh
  set +x
  BWS_ACCESS_TOKEN="$(cat ~/.config/bws/token)"; export BWS_ACCESS_TOKEN
  CF_RO="$(bws --color no secret list "$(cat ~/.config/bws/sb-project-id)" -o json \
    | jq -r '.[] | select(.key == "CLOUDFLARE_READONLY_TOKEN") | .value')"
  unset BWS_ACCESS_TOKEN
  if [ -n "$CF_RO" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$CF_RO" \
      | curl -sS --config - "https://api.cloudflare.com/client/v4/zones" | jq -r '.result[].name'
  else
    echo "CLOUDFLARE_READONLY_TOKEN lookup came back empty" >&2
  fi
  ```

  `set +x` comes first because a traced run (`bash -x file.sh`) would otherwise
  echo both secrets as they are assigned. `--color no` is required. Agent
  shells here export `FORCE_COLOR`, which makes bws 2.1.0 color its JSON even
  into a pipe; jq then fails and the variable comes back empty. `unset` keeps
  the Bitwarden access token out of everything launched after the lookup.
  `printf` is a builtin, so the token never reaches curl's argv.
- **Use curl against the API, not the `cf` CLI.** Measured 2026-10-04, 12 tasks
  run twice with each tool (48 runs): curl was correct 24/24 and `cf` 20/24.
  On the 10 tasks `cf` has a command for, both were 20/20, and curl took a
  median of 2 turns to `cf`'s 5 at about half the cost ($1.21 against $2.35
  for 20 runs each). `cf` has no command for Workers routes or custom domains.
- **Writes, and any token mint or delete, wait for the operator.** Minting or
  deleting a token is a credential change and a write changes production, so
  ask first (`CLAUDE.md`, Autonomy). With a go, mint one narrow token,
  use it, and delete it, as the runbook's "Reachable privilege, demonstrated"
  section shows.
- **Traps:**
  - Manage tokens at `/user/tokens` with `CLOUDFLARE_MANAGER_TOKEN`. For that
    token, `/accounts/{id}/tokens` answers Unauthorized, which twice led
    sessions to conclude, wrongly, that a human had to mint.
  - `/user/tokens/verify` works only for user-owned tokens. An account-owned
    token answers `Invalid API Token` there; check it at
    `/accounts/{account_id}/tokens/verify` instead.
  - A minted value is shown once. Store it before using it
    (`scripts/secrets.sh seed KEY` reads the value on stdin), and revoke the
    token if the store fails. Two minted values have been lost already.
  - A fresh token answers 401 for about 10 seconds. Retry before calling it dead.
  - `/zones` and `/accounts` return 200 with an empty list for a token that
    cannot see them. Count rows; do not read the status code.
  - Never print a value. That includes `${v:-…}`, which expands to the value
    when it is set; the 2026-08-08 purge-token leak came from exactly that.
  - The dashboard name "StartupBros Terraform" belongs to the Workers deploy
    token `CLOUDFLARE_API_TOKEN`, not to `CLOUDFLARE_TERRAFORM_TOKEN`.

## Install mechanics

Every deployed copy is a **symlink**, so edits to the versioned source take
effect immediately — no re-install step. `lib/manifest.sh`'s
`DOTFILES_LINKS` maps each wrapper (`bin/gsc`, `bin/dfs`,
`bin/exa-cli`, `bin/firecrawl-cli`, `bin/ga4`,
`bin/discord-cli`, `bin/resend-cli`, `bin/stripe-api`, `bin/posthog-api`, `bin/supabase-api`, `bin/fal-api`, `bin/vastai`, `bin/vast-ssh`) to `~/.local/bin/`, applied by `install.sh` through
`lib/link.sh` as a direct symlink into the repo checkout. Separately,
`sync.sh` symlinks the whole `bin` directory to
`~/.claude/bin` (not on PATH), so `gsc.py`, `ga4.py`, `discord_cli.py`, `resend_cli.py`, `stripe_api.py`, `posthog_api.py`, `supabase_api.py`, `fal_api.py`, `dfs.py`, and `exa.py` resolve
back into the checkout the same way. `resend-cli` additionally needs the
pinned vendor prefix from `scripts/resend-cli-install.sh install`
(see "Resend" above); the wrapper's `--where` says whether it is converged.

`gsc` needs a venv (local and disposable — recreate per the wrapper header).
`dfs`, `exa-cli`, and `firecrawl-cli` are stdlib-only (HTTP Basic, an `x-api-key`
header, and a subprocess of the vendor CLI respectively), so none has a venv to rot.

`vastai` needs a venv as well: `uv venv ~/.local/share/vastai-cli/venv --python 3.12`
then `uv pip install --python ~/.local/share/vastai-cli/venv/bin/python vastai==1.8.3`
(the wrapper prints both on exit 3; `VASTAI_VENV` relocates it). The vendor
binary stays off PATH on purpose: only the wrapper's name is in the
`settings.json` allow list, and the vendor's `update` and `install.sh` paths are
never used. To roll back, revert the two `DOTFILES_LINKS` rows
(`bin/vastai`, `bin/vast-ssh`) and the two allow entries, run
`dotup`, and remove the venv directory; the API key and the ssh key are deleted
in the vast.ai console, since the agent key cannot delete keys.

To roll back `firecrawl-cli`, revert its `DOTFILES_LINKS` manifest row and
re-run activation (`dotup`) to remove the command. Rollback is complete when
`firecrawl-cli --version` reports command-not-found and harness-doctor checks
31 and 32 read dormant for it. Orphaned ledger reservations expire by their
lifetime and need no cleanup.
