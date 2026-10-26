# Harness vet: Cloudflare CLI `cf` beta (npm `cf` 1.0.0-beta.12)

> **Correction, 2026-10-04 (same day, after operator challenge):** the premise "agents on this host hold no Cloudflare credential" (verdict item 3, §3, §5, §7) is wrong. Any agent process here resolves four live Cloudflare tokens from Bitwarden through `~/.config/bws/token`, and agents have done Cloudflare admin over the API since at least August 2026. §8 records that evidence and the agent comparison the false premise had excused. The verdicts stand; the reason for the global SKIP is now measured, not assumed. After the correction the operator approved a read-only Cloudflare token for agents, minted the same day (§8, dividend 5), so the header's "no credential provisioned" no longer holds.

- Date: 2026-10-04. Skill: harness-vet. Landing: report plus this note, PR for review. Nothing installed into any target and no instruction line added. No credential was provisioned by the vet itself; a read-only Cloudflare token was minted afterwards, on operator approval (§8, dividend 5).
- Operator ask: "our members app monorepo may find this relevant, or maybe not since we use IaC tf/ansible and all that too. it may also make our agents more productive and capable aside from that."

## Verdict in one screen

**SKIP in every target for now. The delivery is clean; the content is a fast-moving beta that does not fit the members app's deploy path, and agents already reach Cloudflare through bws plus curl, which §8 measured faster, cheaper and more complete than `cf`.** (Originally this line said `cf` "gives agents nothing until someone hands them a Cloudflare token"; that premise was wrong, see §8.)

1. **Workers deploy for the members app (`apps/acme-web-funnels`): SKIP.** Cloudflare's own docs say "Astro 6 and later does not build with `cf` during the beta" (the members app is on Astro 7; documented, not reproduced). `cf deploy` reads only `cloudflare.config.ts`, while the members app's deploy contract is the adapter-emitted `dist/server/wrangler.json`. `cf` has no Worker `rollback` and no `tail` (the docs say to keep using `npx wrangler tail`). `cf migrate` on a scratch copy of the funnels config, with the members app's installed wrangler 4.114.0 linked in, wrote `cloudflare.config.ts` and `wrangler.config.ts` but exited 1 with nine `[required]` config follow-ups: Durable Object bindings, Durable Object migrations and `keep_vars`, each in all three environments (a tenth asks to install `cf@latest`, because the run passed `--no-install`). The generated `cloudflare.config.ts` throws until they are resolved, and `wrangler.config.ts` imports `wrangler/experimental-config`, so migrating would not remove wrangler. The incumbent pipeline is hardened and working, and no wrangler pain is recorded.
2. **Agent read-only triage of live Cloudflare state for the members app: SKIP pending a need.**
   - No recorded incident shows an agent lacking a Cloudflare read path. Past diagnoses used public-URL `curl`, smoke scripts, and Terraform/HCP plans.
   - The read an agent would most plausibly need for funnels is "which hostname or route serves this Worker". The funnels `wrangler.jsonc` declares no `routes` or `custom_domain`, and `cf` beta.12 has no command for Workers routes or Workers custom domains.
3. **`cf` as a general agent CLI (global harness), including the `/cf/agents/` CLAUDE.md line: SKIP.**
   - ~~Agents on this host hold no Cloudflare credential: no `CLOUDFLARE_*` env and no wrangler login.~~ **Wrong (§8):** agents resolve Cloudflare tokens from Bitwarden per task. The SKIP stands on the measured comparison in §8.
   - `cf cli search` found the right command first for 6 of 13 covered tasks. It has no relevance threshold, so it returns five confident commands even for "bake a chocolate cake".
   - Non-DELETE mutations (PATCH and POST) fire non-interactively with no prompt.
   - 13 betas shipped in 7 days.
4. **Delivery (npm package): pass, no REJECT.** It is published by Cloudflare's `wrangler-publisher` with SLSA provenance, the tarball sha512 matches the registry integrity, and the package has no install scripts. Telemetry is on by default, but every documented opt-out silenced it when tested alone.

**Not vetted here:** Cloudflare's `/agent-setup/` plugin (`/plugin marketplace add cloudflare/skills`, which installs Cloudflare Skills and registers the Cloudflare MCP servers). It is a separate candidate with a different risk shape (marketplace-updated instructions plus remote MCP).

## 1. Source identity, targets, run choices

| Item | Identity |
|---|---|
| Changelog | https://developers.cloudflare.com/changelog/post/2026-09-28-cloudflare-cli-beta/ (2026-09-28) |
| X post | https://x.com/CFchangelog/status/2106463076417499484 (2026-10-03, @CFchangelog). A single post linking the changelog: "unifies Workers, DNS, and security management into a single tool that works great with coding agents". No thread or self-corrections. |
| Package | npm `cf` 1.0.0-beta.12, tarball sha512 `tyQ+Jpnw…0vp2Aw==` (matches registry `dist.integrity`), 22 MB unpacked, 299 files, `engines.node >=22`. Maintainers: petebd, dimitropoulos, penalosa, dcartertwo, wrangler-publisher. SLSA v1 provenance attestation present. The npm name dates from 2013; the 0.0.x versions are an unrelated older package. |
| Source | github.com/cloudflare/cf, tag `cf@1.0.0-beta.12`, commit `5b9eefbf3d3dbfc6d5c6800389ab1bd29fa601e1`, `packages/cli` |
| Release cadence | beta.0 2026-09-25 through beta.12 2026-10-02, 13 betas in 7 days. Each minor regenerates the command surface from the OpenAPI spec. CHANGELOG records flag renames and command moves between betas (`cf telemetry` became `cf cli telemetry` in beta.3). |

**Targets.**
- **T1:** the members app monorepo (`acme-org/announce-bot` @ `66968d0e`). Task (a): Workers dev/build/deploy for `apps/acme-web-funnels`. Task (b): agents reading live Cloudflare state (DNS, Worker versions and deployments, R2, rules, cache) during incidents, drift triage, or verification.
- **T2:** the global agent harness (`~/.claude`, Codex). Task: an agent asked to do anything Cloudflare can find and run the right command.
- Both targets were inferred from the ask. Runtime: unattended and interactive Claude Code and Codex on WSL2.

**Run choices.**
- Three readers ran in parallel, each carrying the frozen digest: the CLI source (lean-reader), the docs fact-check (lean-collector), and the members app fit (lean-reader on 16 files exported from `origin/main`).
- Sandbox measurements ran inline.
- Landing depth: PR for review, in `docs/vets/` as established.

**Install state.**
- `cf` is not installed anywhere. There is no global `wrangler` binary either: the members app pins it per app, at `^4.83.0` in `apps/acme-web-funnels/package.json:67`. Local dev runs on this host log wrangler 4.114.0.
- No Cloudflare MCP server is configured (global, project, or the members app `.mcp.json`), and no Cloudflare plugin is installed.
- A jsm-managed global `wrangler` skill exists at `~/.claude/skills/wrangler`. It is written against wrangler 4.59 (June 2026), is not in the always-on listing, and is not a `cf` copy.

**Prior verdict.** None found. Searched:
- `docs/vets/` (12 notes)
- `memory/**`
- `~/.claude/projects/*/memory/`
- `harness/`
- the members app `docs/` and `.claude/`

Search terms: "cloudflare cli", `cf auth`, `cf cli search`, `npm install --global cf`, `cloudflare-cli`, `cf-cli`.

## 2. Measured, not inferred

**Setup.** Sandbox: fresh `HOME`/`XDG_*` under `/tmp/cfcli-vet-6a5d/sbx`, `pnpm add --ignore-scripts cf@1.0.0-beta.12` (37 packages, 368 MB `node_modules`, 2 minutes). Node 24.12.0, pnpm 10.33.2.

**Egress capture.** A `NODE_OPTIONS=--require` shim logged `fetch`, `http(s).request`, the undici diagnostics channel, raw `net` sockets and worker threads. API behaviour was tested against a localhost capture server via `CLOUDFLARE_API_BASE_URL`, with fake tokens only. No real Cloudflare credential was used. Scratch files are not committed.

### Egress (default run, inside Claude Code)

`cf cli search "list DNS records for a zone"` sent two POSTs to `https://sparrow.cloudflare.com/api/v1/event`, with a `Sparrow-Source-Key` that is inlined in the published build. Body fields:
- `deviceId` (a random UUID)
- `osVersion` (the full kernel string)
- `agent: "claude-code"`
- `agentSessionKey` (a hash over device id, agent, and Claude Code session id)
- `isCI`, `cliMode`
- `searchQuery: "list DNS records for a zone"`, verbatim

No cwd, file paths, repo names or account id appeared in the bodies. Positional arguments are dropped; free-form flag values are redacted (source: `src/lib/telemetry/sanitization.ts:81-106`).

### Telemetry opt-outs

Each was tested alone, and each produced zero outbound requests:
- `DO_NOT_TRACK=1`
- `CF_SEND_TELEMETRY=false`
- `WRANGLER_SEND_METRICS=false` (the members app CI already sets this)
- stored `cf cli telemetry disable`

### Channel that survives every opt-out

With all three env opt-outs set, API requests still carry `User-Agent: cf-cli/1.0.0-beta.12`, `X-CF-CLI-Mode: non-interactive` and `X-CF-CLI-Agent: claude-code`. The agent header was `null` once `CLAUDECODE` and `CLAUDE_CODE_SESSION_ID` were unset. It goes only to the API host the token already authenticates against, so this is low sensitivity, but it is an identity signal that no telemetry switch removes.

### Update check

Source shows `GET registry.npmjs.org/cf/latest` at most once per 24h. It runs only on a TTY, outside CI, and has no auto-install (`src/lib/update-check.ts`, `src/index.ts:443-480`). Not observed, because the sandbox had no TTY. Unattended agent runs do not trigger it.

### Credentials

- `CLOUDFLARE_API_TOKEN` from env works.
- A token placed only in the cwd's `.env` was picked up silently: the capture server saw `Bearer fake-do…`.
- Docs: `cf` keeps its own credentials and does not reuse a wrangler login.
- `cf auth login` accepts `--scopes` (`src/commands/auth/login.ts:56-60`). The default scope set lives in the external `@cloudflare/workers-auth` package, so it is not read.

### Mutation safety (non-interactive, fake token)

- **DELETE** `cf dns records delete <id>` without `--force` prints `Aborted.` to stderr, sends nothing, and **exits 0**. An agent cannot tell "declined" from "done" by exit code.
- **PATCH** `cf zones settings edit security_level --body '{"value":"under_attack"}'` was **sent immediately**, with no prompt and no `--force`, and exited 0.
- **POST** `cf dns records create --body '{…}'` was **sent immediately** and exited 0.
- `--dry-run` printed the full request JSON (method, URL, path params) and sent nothing.
- There is no read-only mode, so the only real guard is the token's scope.

### Output

- Generated read commands print indented JSON on stdout, with the `result` unwrapped and nothing on stderr.
- Help output, when an agent is detected, opens with a fixed local "STOP: AGENT COMMAND DISCOVERY" banner steering the agent to `cf cli search`.

### `cf cli search` accuracy

Telemetry was off. The fixture had 15 tasks taken from members-app-shaped needs plus 3 controls. Ground truth came from the bundled catalog `dist/_meta/commands.json` (2,940 commands) and `schemas.json` (1,788 distinct API paths).

| Bucket | Tasks | Result |
|---|---|---|
| Covered, right command first | T01 DNS list, T03 Worker versions list, T05 cache purge, T07 R2 buckets list, T11 Turnstile list, T14 token verify | 6 of 13 |
| Covered, right command in the top 5 only | T06 R2 CORS (`cors delete` ranked **first**, `cors get` second), T12 Worker secrets list (4th) | 8 of 13 in top 5 |
| Covered but missed entirely | T02 deployed Worker version (`workers deployments list`), T04 Worker rollback (`workers deployments create` at 100%), T08 zone WAF custom rules (`rulesets account-rulesets phases get` with a zone), T09 SSL mode (`zones settings get ssl`), T13 under-attack mode (`zones settings edit security_level`; search offered `bot-management update`) | 5 of 13 |
| Not covered by any command, yet five confident hits returned | T10 Workers custom domains, T15 Workers routes | 2 of 2 |
| Controls | "bake a chocolate cake", "open a pull request on GitHub", "dns recrods lsit" | 3 of 3 returned five commands. The typo missed `dns records list`. |

The mechanism behind these results is local MiniSearch over the bundled metadata (prefix plus fuzzy 0.2, top 5, `src/commands/cli/search.ts:41-87`) with no score threshold. A task `cf` cannot do gets no "no match" signal. Search is offline, but its query is sent in telemetry when telemetry is on.

### Coverage claim

"More than 2,900 commands cover the public Cloudflare API" is **PARTIAL**. The command count holds (2,940), but there are no endpoints for `/zones/{id}/workers/routes` or `/accounts/{id}/workers/domains` in beta.12. Zone rulesets are reachable through the account-or-zone ruleset commands.

### `cf migrate` on the members app's config

Setup: a scratch copy of the funnels `wrangler.jsonc`, `package.json`, `astro.config.mjs` and a stub `src/worker.ts`, committed to a fresh git repo, then `cf migrate --dry-run --no-install`.

First run, with no `node_modules` in the scratch copy: exit 1. The message was: "Generating wrangler.config.ts requires wrangler 4.100.0 or newer because earlier versions do not export wrangler/experimental-config. No local Wrangler installation was found." `cf` also selected "the Wrangler bundler because @cloudflare/vite-plugin is not declared". So for this project the output would be a `wrangler.config.ts` built through wrangler's own export. The working tree was unchanged afterwards.

Re-run with wrangler present (a Pro review finding: the first run failed only because the scratch copy had no installed wrangler). The same files, plus `node_modules/wrangler` linked to the members app's installed wrangler 4.114.0. The dry-run ran with `node_modules/` untracked; the real run used a fresh copy with `node_modules/` gitignored and committed, because the codemod refuses a dirty tree:
- `cf migrate --dry-run --no-install`: exit 1, "Would update 2 file(s)" (`cloudflare.config.ts`, `wrangler.config.ts`), 10 `[required]` follow-ups. Nine are config: `durable_objects.bindings.0`, `migrations` ("Wrangler Durable Object migrations are unsupported") and `keep_vars`, each at the top level and under `env.preview` and `env.production`. The tenth asks to install `cf@latest`, an artifact of `--no-install`.
- `cf migrate --no-install`: exit 1, wrote both files, the same 10 follow-ups.
- The generated `cloudflare.config.ts` (195 lines) has an unconditional top-level `throw new Error("Migration incomplete. ...")` at line 50, before its `export default`. The config cannot load until every TODO is resolved and the throw is removed.
- The generated `wrangler.config.ts` imports `defineWranglerConfig` from `wrangler/experimental-config`. Migrating keeps wrangler as a dependency.
- With `node_modules/` untracked, the real run refused: "Git worktree is not clean. Commit or stash your changes before running a codemod, or rerun with `--force`."

### Not run

- `cf dev`, `cf build` or `cf deploy` on the real Astro 7 app. The vendor documents that it does not build, and the SKIP rests on the other legs too.
- Any authenticated live read, because no credential was provisioned. **Superseded (§8):** credentials existed; the live reads were later run over the API with the read-only token.
- A Claude-with-`cf` versus Claude-with-`curl` agent comparison. It would not change a verdict that already rests on missing need and missing credentials. **Superseded (§8):** the credentials were not missing, and the comparison was run: curl 24/24, `cf` 20/24.

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| npm package delivery (provenance, integrity, no install scripts) | shared | pass (no REJECT) | n/a | n/a | measured | n/a |
| `cf dev`/`build`/`deploy` | T1 members app funnels | SKIP | no installation | none | docs (Astro 7 unsupported, no rollback or tail) + measured (`cf migrate` exit 1, still wrangler-backed) | not installed |
| Generated API commands for read-only triage | T1 members app | SKIP pending need | no installation; a trial is described in §4 | none | measured (coverage gap, search accuracy, unguarded PATCH/POST); live reads PARTIAL (no credential; wrong, see §8) | not installed |
| `cf` + `cf cli search` as a general agent tool | T2 global | SKIP | no installation | none | measured | not installed |
| `/cf/agents/` CLAUDE.md line ("use the `cf` CLI unless the project has a Wrangler configuration file") | T2 global | SKIP | not added | none | follows from the row above; would cost always-on context for a tool agents cannot authenticate (wrong premise; §8 measures the tool slower than curl instead) | not added |
| Cloudflare Skills plugin + MCP servers (`/agent-setup/`) | either | **not vetted** | n/a | n/a | separate candidate | n/a |

### Price checks

- **Context cost.** Zero unless the CLAUDE.md line is added. Tool-count cost: none, because it is a CLI and not an MCP server.
- **Placement and off-switch.** A project-local devDependency would be the narrowest placement. Note that `bin/cf` delegates to any `node_modules/cf` in the cwd (`src/lib/delegate.ts:123-166`, source-confirmed, not run).
- **Delivery vs content.** Delivery passes. The content is unstable: generated flags change with each minor, and "Commands, configuration, and Build Output can change before the stable release".
- **Supply chain.**
  - 368 MB install, including `miniflare 5.20260930.0-alpha`. Transitive install scripts (for example `sharp`, `workerd`) were skipped by `--ignore-scripts` and not audited.
  - Combined risk: project-local delegation plus silent `.env` token pickup. Running `cf` in an untrusted checkout executes that checkout's `cf` with that checkout's token.
  - the residual risk tracked in a members-app issue (wrangler is resolved from the dispatched ref's lockfile and run with the shared deploy token) applies equally to any npm-delivered deploy CLI. `cf` does not close it.

## 4. If a read-only trial is wanted later (proposal, not applied)

The defensible shape, if a members app repository incident shows the need:
1. Use a dedicated read-only Cloudflare token. One now exists: `CLOUDFLARE_READONLY_TOKEN`, minted 2026-10-04 after the §8 correction (dividend 5). Its permission groups, by Cloudflare's exact names: Zone Read, Zone Settings Read, DNS Read, Zone WAF Read and Workers Routes Read on all zones; Workers Scripts Read and Workers R2 Storage Read on all accounts. Zone settings such as `ssl` sit under Zone Settings Read, separate from Zone Read, and the zone `http_request_firewall_custom` phase sits under Zone WAF Read. With this token the DNS, SSL-setting and WAF-entrypoint reads behind step 4 returned 200 over the API (curl, not `cf`).
2. Pin `cf` exactly as a devDependency in a tooling package. No global install.
3. Set `CF_SEND_TELEMETRY=false` in the agent env.
4. Give agents the exact commands rather than relying on `cf cli search`. For example:
   - `cf workers deployments list --worker <name>`
   - `cf dns records list --zone <zone>`
   - `cf zones settings get ssl --zone <zone>`
   - `cf rulesets account-rulesets phases get http_request_firewall_custom --zone <zone>`
5. Do not rely on `cf` confirmations, because PATCH and POST fire without a prompt. The read-only token's scope bounds what is done with that token. It does not stop the same agent from resolving a write-capable token: a broad secrets-manager principal may also resolve write-capable tokens (dividend 5). Token scope becomes the effective guard only once the agent's bws principal cannot read the write-capable tokens.

`TFR:40` ("Attack Mode is a time-boxed CLI switch, not a resource", `infra/terraform/README.md`) names a sanctioned out-of-band mutation without naming a tool. `cf zones settings edit security_level` could serve it, but only as a spelled-out operator runbook step: search did not find it (T13).

## 5. Shared vs target-specific findings

- **Shared artifact findings** (carry to any future target):
  - telemetry defaults and opt-outs
  - the agent header surviving every opt-out
  - unguarded non-DELETE mutations
  - DELETE abort exiting 0
  - search with no threshold
  - the Workers routes and custom domains coverage gap
  - `.env` token pickup plus project-local delegation
  - no install scripts
  - valid provenance
- **Target-specific (the members app):** Astro 7 unsupported; the adapter-emitted wrangler.json deploy contract; Terraform owns zones and R2 (`infra/terraform/README.md:27-28`, `STACKS.md:18,24`), so CLI writes to those would be drift.
- **Target-specific (global):** ~~no agent credential exists; adding one is a security-posture decision.~~ **Wrong (§8):** agents already held write-capable Cloudflare tokens through Bitwarden. A read-only one was added on 2026-10-04.

## 6. Audit dividend

1. **The members app root `AGENTS.md:251` is stale.** It says "Cloudflare Pages serves static marketing", but `apps/acme-web-funnels` deploys to Cloudflare Workers via `deploy-acme-web-funnels-workers.yml`.
2. **The funnels Worker's hostname binding is not in the repo.** `apps/acme-web-funnels/wrangler.jsonc` has no `routes` or `custom_domain`, and the funnels Worker is not in the Terraform ownership tables (`infra/terraform/README.md`, `STACKS.md`). The owner of that binding is unrecorded.
3. **Stale version comments in the members app's deploy workflow.** `deploy-acme-web-funnels-workers.yml:385,489` say "Measured on wrangler 4.50.0", but `package.json:67` now floors at `^4.83.0` and local runs show 4.114.0. The telemetry-banner and script-free-install claims in those comments have not been re-measured on the current version.
4. **wrangler fetches Cloudflare's skills list on this host.** wrangler 4.114 fetches the list and caches it in `~/.config/.wrangler/cloudflare-skills-repo-cache.json` (last update 2026-10-03). It also ships `--install-skills` ("Install Cloudflare skills for detected AI coding agents", default false). That is a remote instruction channel inside the incumbent, currently off. Leave it unused, and treat any automation that passes `--install-skills` as installing the unvetted Cloudflare skills bundle.

## 7. Do-not-retry unless

- **Workers deploy (T1):** `cf` docs or a reproduction show an Astro 7 project with `@astrojs/cloudflare` building and deploying through `cf`, AND `cf` ships Worker rollback and log tailing. Alternatively, the members app starts a new Worker app created with `cf init`. A stable 1.0 release alone is not enough.
- **Read-only triage (T1):** a recorded members-app incident where an agent needed live Cloudflare state that public-URL checks and Terraform plans could not give in time, AND the operator decides to provision a read-only agent token. The Workers routes and custom domains gap must also be closed if the incident concerns a Worker hostname. **Replaced in §8** (the token clause is spent).
- **Global agent tool (T2):** agents are given a Cloudflare credential for some task, OR `cf cli search` gains a relevance threshold or "no match" result. Re-run the §2 fixture (15 tasks + 3 controls, ground truth from `dist/_meta/commands.json`); this run's baseline is top-1 6/13, top-5 8/13, controls 3/3 misrouted. **Replaced in §8:** the credential clause was already true; the new trigger is the curl-versus-`cf` comparison.
- **Re-audit trigger for any adoption:** non-DELETE generated commands gaining a confirmation, or a read-only mode. Until then, token scope is the only guard.

## 8. Correction: agents already reach Cloudflare natively (2026-10-04, later the same day)

### What was wrong

§1 to §7 concluded "agents on this host hold no Cloudflare credential" from two checks: no `CLOUDFLARE_*` variable in the session environment and no wrangler login. Both checks look at ambient credentials. The author's infrastructure runbook deliberately keeps credentials out of ambient state: export only the variables a task needs instead of wrapping an agent in `bws run`. The checks tested the surface the policy keeps empty, not the path agents actually use.

### Credential reach

A local secrets-manager bootstrap and credential registry can provide tokens on
demand even when environment and interactive-login checks are empty. Inspect the
registry's metadata and run its read-only liveness check without printing token
values. Check both API scopes and the secrets-manager principal: a read-only API
token does not constrain an agent that can also retrieve write-capable tokens.

### What agents have actually done

Sources: three read-only collectors over the StartupBros security docs and registry, memory notes in every project, and `cass` session history (12 sessions classified). `cass` hit counts were inflated by tokenization, so absence there is weak evidence.

Agent-performed Cloudflare operations, all over the API with bws-resolved tokens or through Terraform:
- 2026-08-07: minted `CLOUDFLARE_PURGE_TOKEN` end to end, no browser (`cloudflare.md:53-58`).
- 2026-08: attributed tokens through seven days of `GET /accounts/{id}/logs/audit` (`cloudflare.md:7-29`).
- 2026-08-08: retired the Global API Key and migrated its seven holders; the only console step was the final key roll (`cloudflare.md:138-216`).
- 2026-08-08 and 2026-08-30: rolled `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_TERRAFORM_TOKEN` in place with `PUT /user/tokens/{id}/value` using `CLOUDFLARE_MANAGER_TOKEN` (`docs/security/creds-registry.md`, the rows for those two keys).
- 2026-08-21 to 2026-08-26: minted, used and revoked the R2 media token family (the members app memory `the-r2-credential-family-lives-in-cloudflares-user-token-store.md`).
- Also: cache purges, a Workers KV namespace, and Terraform applies of bulk redirects, WAF rules and DNS through repo workflows.

No session used the Cloudflare dashboard or a Cloudflare CLI for these.

Recorded friction is about the API's traps, not about access:
- `/accounts/{id}/tokens` falsely answers Unauthorized, so two sessions wrongly concluded a token had to be made by hand.
- `/user/tokens/verify` fails for account-owned tokens.
- Two tokens carry dashboard names that invert their role.
- Freshly minted values are shown once, and two were lost.
- A `${v:-GONE}` check echoed a token into a transcript and forced a roll.

The papercut log has 1 Cloudflare entry in about 2,000 (a trailing-whitespace lint).

### The comparison §2 skipped: an agent with `curl` versus an agent with `cf`

The skip rested on the false premise, so this run measures it.

**Setup**
- 48 headless `claude -p` runs: 12 tasks × 2 arms × 2 repetitions.
- Model `claude-opus-5-5`, max 25 turns, tools `Bash,Read,Glob,Grep`.
- Each run had its own fresh `CLAUDE_CONFIG_DIR` (the `experiments/seo-arm-fixture-2026-09-05/run_arm.sh` pattern). That removes host skills, CLAUDE.md, plugins and the Workflow relay.
- Both arms got the same scenario text (account ID, zone, Worker name, bucket) and the same task line. They differed only in the tool line:
  - **curl arm:** use curl with the given API base URL and a bearer token.
  - **cf arm:** use `cf`, pre-authenticated, on `PATH`.
- Requests went to a localhost Cloudflare API v4 stand-in with canned bodies. A per-run URL prefix attributed each request, and only a dummy token was used.
- Grading came from the request log: the method, path and (for mutations) body had to match, plus the task's key fact had to appear in the final answer.
- The harness, manifest, request log and grades are archived in `experiments/cf-cli-vs-curl-2026-10-04/`, with re-run steps.

**Tasks**
- T01 DNS list
- T02 deployed Worker version
- T03 Worker versions
- T04 Worker rollback
- T05 purge two URLs
- T06 R2 CORS
- T08 zone WAF custom rules
- T09 SSL mode
- T10 Workers custom domains
- T12 Worker secret names
- T13 Under Attack Mode
- T15 Workers routes

T10 and T15 have no `cf` command in beta.12.

**Results**

| | curl + API | cf |
|---|---|---|
| Correct, all 12 tasks | **24/24** | 20/24 |
| Correct, the 10 tasks `cf` covers | 20/20 | 20/20 |
| Median turns (covered tasks) | **2** | 5 |
| Median wall time (covered tasks) | **8.2 s** | 17.9 s |
| Cost (covered tasks, 20 runs) | **$1.21** | $2.35 |
| T10 and T15 (no `cf` command) | 4/4, median 2 turns | 0/4, all answered NOT POSSIBLE after 11 to 13 turns |
| Unrequested mutations | 0 | 0 |
| `--help` calls / `cf cli search` calls | 0 / 0 | 76 / 30 |
| Fell back to curl when `cf` lacked a command | n/a | 0 of 4 (not possible: the cf arm had no API token or base URL) |

Medians are over 20 runs: the mean of the two middle runs. The curl wall time first read 8.3 s here, the upper middle run (8.28 s) rather than the mean (8.18 s); corrected 2026-10-05 to match the published `results.csv`.

**Checks on the run itself**
- Blinding: 0 meta-disclosure words in the 72 arm-visible prompts and shims.
- Confounds:
  - Both arms used only Bash (29 calls versus 133).
  - 0 runs mentioned `api.cloudflare.com`.
  - 0 runs touched bws, `creds.sh` or a secrets script.
  - 0 runs listed processes or opened the stand-in.
  - All 48 exited 0.

**Limits**
- The stand-in's state is static, so a read after a write shows the old value. Four mutation runs (T04 rollback and T13, two per arm) sent exactly the right request, then correctly declined to claim success when the read-back did not change. Those are scored on the request, and the artifact hit both arms equally.
- n=2 per cell, on one model.
- The task set comes from members-app-shaped needs, not a random sample of Cloudflare work.
- The arms were matched to how each tool is used: the curl arm got a base URL and token, and the cf arm got a pre-authenticated binary. So the cf arm could not fall back to the API, and its 0/4 on T10 and T15 is a forced-tool result. An agent given both `cf` and an API token was not measured. It would likely recover those tasks; how many turns it would spend in `cf` before falling back is unknown.

### Revised verdicts and triggers

- **T2 global agent tool: SKIP, unchanged.** The reason is now measured: agents already reach Cloudflare through bws and curl. `cf` only matched curl's correctness where it has a command, and took 2.5x the turns, twice the time and 1.9x the cost doing it. On the two tasks it has no command for, the cf-only arm gave up after 11 to 13 turns (a forced-tool result; see Limits). It adds discovery overhead and coverage gaps, not capability. The `/cf/agents/` CLAUDE.md line ("use the `cf` CLI unless the project has a Wrangler configuration file") would make agents slower.
- **T1 read-only triage: SKIP, unchanged.** The agent path already existed. Its precondition, an operator-provisioned read-only token, was met on 2026-10-04 (dividend 5), and the triage path that token serves is bws plus curl, which this comparison measured ahead of `cf`. The §7 T1 trigger's "operator decides to provision a read-only agent token" clause is therefore spent; T1 now uses the global trigger below.
- **T1 Workers deploy: unchanged.** It never depended on credentials.
- **§7 global trigger replaced.** "Agents are given a Cloudflare credential" was already true. The new trigger: re-run this comparison's task set (harness in `experiments/cf-cli-vs-curl-2026-10-04/`) and adopt only if `cf` matches curl on correctness and does not exceed it on median turns or cost, or `cf` ships a raw API passthrough plus Workers routes and custom-domain commands. The baseline is the table above.

### Audit dividend, added

5. **The agent-native gap was scope, not access. The Cloudflare half closed on 2026-10-04.**
   - Every Cloudflare token reachable by agents could write.
   - With operator approval, `CLOUDFLARE_READONLY_TOKEN` was minted the same day with `CLOUDFLARE_MANAGER_TOKEN` and stored in Bitwarden before first use. Groups, by Cloudflare's exact names: Zone Read, Zone Settings Read, DNS Read, Zone WAF Read and Workers Routes Read on all zones; Workers Scripts Read and Workers R2 Storage Read on all accounts.
   - Evidence: the Manager policy readback showed no Write or Edit group. Seven real reads returned 200 (DNS records, SSL setting, zone WAF entrypoint, Workers routes, scripts, custom domains, R2 buckets). Token mint, a zone-setting edit with an invalid value and a DNS create with an empty body returned 403.
   - Registration is proposed in acme-org/site#708 (an open draft at the time of writing): registry row, consumer, a verify script that fails if the token stops reading or gains write, and a runbook recipe for per-task export.
   - `Workers R2 Storage Read` also reads objects, and S3 credentials are derivable from any API token, so this token can download R2 bucket contents.
   - A read-only API token bounds actions only if the secrets-manager principal cannot retrieve broader tokens; scope both layers.
6. **The Cloudflare API traps live only in the StartupBros runbook.** `harness/data-source-clis.md` has zero Cloudflare mentions, so an agent in the members app or dotfiles meets them by searching another repo. A short Cloudflare section there would cover them: per-task export, the `/user/tokens` versus `/accounts/{id}/tokens` trap, verify for account-owned tokens, store a minted value before use, never echo a value. It is a small extraction with a named consumer and a named defect class (two wrong "needs a human" conclusions, two lost tokens, one leaked token). Follow-up: a separate dotfiles PR adds it, because `harness/` doctrine takes its own inward vet.
7. **`cf` writes `.cloudflare/cache/cloudflare-account.json` into the directory it runs in.** In an agent's repo worktree that is an untracked file nothing ignores.
8. **`bws secret list -o json` colors its output even into a pipe.** bws 2.1.0's output starts `\033[3` without `--color no` (first bytes inspected). jq then fails with "Invalid numeric literal", and a per-task token export silently comes back empty. The StartupBros scripts pass `--color no`. A hand-written agent recipe that omits it fails, which is how this was found while writing the runbook recipe for dividend 5.
