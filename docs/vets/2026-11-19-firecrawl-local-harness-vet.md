# Harness vet: Firecrawl Local (`firecrawl-local` 0.1.1) and Firecrawl self-hosting

- Date: 2026-11-19. Skill: harness-vet, run by hand from its SKILL.md. Phase 3 was one Workflow (source readers and a discovery sweep); everything in §2 was run on this host against a release build, a fake Firecrawl cloud and a 40-URL fixture. Landing: this note; proposal issue #807 (local tier in `firecrawl-cli`); defect issue #805 (two `firecrawl-cli` bugs found on the way). A fuller private copy (billing receipts, the hosted app's internals) lives in the operator's private config repository.
- Operator ask: "Firecrawl is a big expense for us so this has high potential to be something that we adopt across our stack … see what we want to do with this and how we should integrate it deeply into the opinionated hov-stack (and/or dotfiles)".

## Verdict in one screen

**ADAPT Firecrawl Local as a first tier inside `firecrawl-cli fetch`, on the condition that the wrapper forces off mode, `--public-only` and a scrubbed environment. SKIP everything else it ships (`serve`, `map`, `crawl` as a tier, `login`); REJECT `mcp` and `init` for agent hosts. SKIP self-hosting the full Firecrawl API.**

1. **The money is small; the friction is not.** The operator's receipts (private copy) show a fixed yearly plan plus a capped monthly overage. A local tier can only remove the agents' share of the overage, a small number of dollars a month, and the plan stays because the hosted app's Firecrawl calls (LLM extract and search) are cloud-only. What a local tier does remove is the agent-side cost of fetching: the 300-credit session cap that stopped two large agent sessions this month, most of the two to three seconds a cloud fetch takes, and every fetched URL leaving the host.
2. **Firecrawl Local passes on coverage, fidelity, latency, and egress; it does not pass SSRF as the rule was frozen.** Off mode with `--public-only`: 37 of the 39 pages the cloud covered, plus the one page the cloud refuses as an unsupported site; word recall 0.93 against the cloud; a blind judge preferred the cloud outright on 6 of 37 pages (16%), 0.4-0.5 s a page, and zero cloud connections. The SSRF guard refused every loopback and metadata form it was given on the CLI and on `serve`, but with `HTTP_PROXY` set it hands loopback names to the proxy unrefused, its `map` verb has no guard at all, and the browser path's refusal is read in the source, not measured. The adapted tier closes the first two by construction and carries the third as an acceptance test.
3. **Its defaults are not agent-safe.** The default `FIRECRAWL_CLOUD=auto` sends any page that fails or looks blocked to Firecrawl's cloud, with a random install id, keyless or with a saved login's key. `init` writes an MCP entry into every agent config it finds that runs an unpinned `npx -y firecrawl-mcp` with the key injected. The wrapper never runs those paths.
4. **Contenders:** crw (fastCRW 0.46.3, Rust, AGPL) matched Firecrawl Local on fidelity but its CLI fetched every IP-literal loopback form and its server listens on all interfaces with no key by default: SKIP. Trafilatura covered 23-27 of 39: SKIP. About 40 other tools were triaged (§5).
5. **Audit dividend:** `firecrawl-cli`'s `redact()` rewrites fetched page text, and keyed vendor calls inherit `FIRECRAWL_API_URL` without the https-or-loopback check the API-direct verbs get. Filed as #805.

**Not vetted here:** the Docker self-host (no image was pulled on this host), Firecrawl Local's `auto` mode against the real cloud (measured against a fake cloud only), and `crawl` beyond one 10-page docs crawl.

## 1. Source identity, targets, run choices

| Item | Identity |
|---|---|
| Source | github.com/firecrawl/firecrawl @ `dc37f52f9670be4ef3077f97f31096b2d0657205` (2026-11-19), app `apps/local` |
| Crate | `firecrawl-local` 0.1.1, AGPL-3.0, committed `apps/local/Cargo.lock` |
| Build here | `cargo build --release` against that lockfile: about 1 h 25 min on 28 CPUs at load 50-110. Binary 23,899,344 bytes, sha256 `00b7b669ecc0d768c20e7441d5de017a970a4dd117e2afd25149e48b6a667805`, dynamically linked against libgcc_s, libm and libc only |
| Browser | the host's own Chrome, found by `find_chrome` (`apps/local/src/browser.rs:226-268`); nothing is downloaded (`browser.rs:3`); every launch uses a throwaway profile under the temp directory, deleted afterwards (`browser.rs:285-300`, `:489-495`), never the user's profile |
| Verbs | `scrape`, `crawl`, `map`, `serve` (127.0.0.1:3002), `mcp`, `init`, and the cloud verbs `search`, `find-tools`, `data`, `login` |
| Cloud modes | `FIRECRAWL_CLOUD=auto` (default: failed or blocked pages go to the cloud), `search` (only search does), `off` |

**Components.** C1 the `firecrawl-local` binary; C2 the Docker self-host of the full Firecrawl API; C3 the repository's five `firecrawl-build-*` skills; C4 its pointer READMEs.

**Targets.** T1 the global harness: `firecrawl-cli` (`bin/firecrawl_cli.py`), which every agent on a hov-stack host uses for web fetches. T2 a team's hosted web app that calls Firecrawl's cloud API from serverless functions (details in the private copy). T3 per-host configuration in the operator's private config repository.

**Run choices.**
- Fixture: 40 public URLs chosen to stress extraction (docs, news, forums, code-heavy pages, math, PDFs, JavaScript-rendered pages, a statute, a LinkedIn company page). Slugs `u00`-`u39` below; the URL list is in the private copy. The cloud refused `u30` as an unsupported site in all three runs, so every comparison is over the other 39.
- Arms, each run three times, one URL at a time: the cloud through `firecrawl-cli fetch --format markdown --full` with keyless-first off; Firecrawl Local in off mode (plus one pass with the exact argv proposed for the wrapper, `--public-only`); crw with its browser tier; crw with no JavaScript renderer; Trafilatura 2.3.1.
- Scoring: a page counts as covered when it returns at least 200 characters, no 401/403/407/429/503 status, and no bot-check page (a fixed phrase list, widened twice during the cloud and crw arms, then frozen and applied to every arm). Recall and precision are word-level against the cloud's markdown; the median of three runs decides.
- Decision rule, frozen before any Firecrawl Local run: (1) coverage at least 85% (34 of 39) in off mode; (2) recall at least 0.80, and a blind judge prefers the cloud outright on at most 30% of pages; (3) no Authorization header the wrapper did not budget; (4) zero Firecrawl egress in off mode; (5) every SSRF probe refused. Countermetrics: median latency at most 2x the cloud, peak memory at most 2 GB.
- Blind judge: 8 judges (Sonnet, read-only), each page judged in both orders; a side wins only when both orders agree, and a flip counts as a tie.
- Key and SSRF probes: a fake Firecrawl cloud on loopback records every request's path, Authorization and headers; a block server counts SSRF hits; every probe runs under `env -i` with a scratch HOME.
- Egress: an `LD_PRELOAD` shim logs every `connect()` and name lookup of every process, Chrome included, and `FIRECRAWL_API_URL` points at a dead loopback port so an off-mode cloud call shows up as a connect to it. A confound check fetched one browser-rendered page with and without the shim: identical output.

**Prior verdict.** None: no Firecrawl Local vet in `docs/vets/`. Related shipped work: the keyless-first ladder in `firecrawl-cli` and the raw `--help` hold fix (#560).

## 2. Measured, not inferred

### Coverage, fidelity and speed (median of 3 runs, over the 39 pages the cloud covered)

| Arm | Covered of 39 | Recall | Precision | Median per page | Peak memory |
|---|---|---|---|---|---|
| Cloud (`firecrawl-cli`) | 39 | 1.0 (reference) | 1.0 | 1.9-3.1 s | n/a |
| **Firecrawl Local, off** | **37, 37, 37** | **0.93** | **0.957** | 0.37-0.41 s | 1,897-1,924 MB |
| Firecrawl Local, off, `--public-only` (proposed argv, 1 run) | 37 | 0.93 | same | 0.52 s | 1,864 MB |
| crw, browser tier | 33, 34, 34 (straddles 34: undecided) | 0.913-0.929 | 0.965 | 0.35-0.44 s | not sampled |
| crw, no JavaScript | 31, 31, 31 | 0.889 | n/a | 0.28-0.39 s | n/a |
| Trafilatura | 27, 23, 23 | 0.60-0.67 | n/a | 0.41-0.65 s | n/a |

- Firecrawl Local's two misses are the same in every run: `u31` (status 403) and `u38` (a bot-check page). Both are pages that refuse this machine; the cloud fetches them. The reverse case: `u30`, which the cloud refuses as an unsupported site, came back from Firecrawl Local's browser engine at 11,730 characters (crw returned 10 characters). Engines over the 120 off-mode fetches (3 runs of 40): 99 `local-fetch`, 15 `local-browser`, 6 `local-pdf`.
- Peak memory is the summed RSS of Firecrawl Local and its Chrome children during one browser-rendered page (the runner fetches one URL at a time), so pages Chrome shares between processes are counted more than once. A fetch-only page or a 10-page docs crawl peaked at 35 MB.
- The vendor's "11 MB idle" figure is plausible for fetch-only use; it does not describe a browser render.

### Blind judge (pairs where both sides were covered)

| Contender vs cloud | Judged | Contender wins | Cloud wins | Ties | Cloud-outright share |
|---|---|---|---|---|---|
| Firecrawl Local | 37 | 21 | 6 | 10 | 0.16 (pass) |
| crw | 33 | 18 | 2 | 13 | 0.06 (pass) |

The six cloud wins over Firecrawl Local name its silent losses: multi-line code blocks collapsed onto one line (`u39`), two list items dropped (`u35`), math variables dropped from prose (`u10`), a docs page's navigation taken from the wrong product (`u21`), a cookie banner kept (`u25`), and table rows padded with empty cells (`u01`). Most of its 21 wins were the reverse: the cloud's markdown kept cookie banners, share links and form noise, or lost the page title, while the local copy did not. Confound: the cloud arm's text passed through `firecrawl-cli`'s `redact()`, which rewrote two fixture pages (§6) and which one judge noticed in a code sample; it does not change the result.

### Egress in off mode

- Zero connections to the dead cloud port across all four fixture passes (160 fetches), a 10-page crawl, two maps and two redirect fetches. No Firecrawl hostname was looked up. No install id file was written.
- Every host the netlog shows belongs to the fetched page or to Chrome's own background traffic (Google update, sync and fonts hosts, routed through Firecrawl Local's guard proxy). The analytics hosts seen (`us-assets.i.posthog.com`, `cdn.segment.com`) are scripts on the fetched pages; the binary and `apps/local/src` contain no analytics or telemetry client.

### Cloud and key handling (fake cloud on loopback)

| Probe | Result |
|---|---|
| Off mode, saved login present, page refused (403) | no cloud request; the warning says the cloud could fetch it |
| `auto` (default), saved login, page refused | page sent to `/v2/scrape` with `Bearer <saved key>`, headers `x-origin: cli@local-0.1.1`, `x-firecrawl-install: <uuid>`, `user-agent: firecrawl-local/0.1.1`; an `install-id` file is written |
| `auto`, no key, unreachable URL (`FETCH_FAILED`) | URL sent to the cloud keyless with the install id: an unreachable intranet URL leaves the host |
| `auto` with `--public-only`, private target | refused locally (`BLOCKED_TARGET`), nothing sent |
| `search` mode | scrapes stay local; search goes to the cloud with the saved key |
| Environment key and saved login both set | the environment key wins |
| Saved `apiUrl` over plain http | accepted and sent the bearer (tested against a loopback fake only; a non-loopback plain-http URL was not tried) |
| `serve` without `--token` | any Authorization value is accepted |
| `serve`, `auto`, no server key, `/v2/extract` | forwarded with the caller's key; with a server key, the server key is used |
| `serve`, off mode, `/v2/extract` | 501 `CLOUD_ONLY`, nothing sent |
| `serve`, foreign `Host` header | 403 `HOST_NOT_ALLOWED` (DNS-rebinding guard) |
| `serve`, unsupported formats (`summary`, `json`) | 200 with the markdown and a warning that those formats were skipped |
| `firecrawl-cli` pointed at `serve`, off mode | fails: the vendor CLI's credit read gets 501, so every call errors out |
| `firecrawl-cli` pointed at `serve`, `auto` | works, but the credit reads go to the cloud with the wrapper's key |

### SSRF guard

| Form | CLI `scrape --public-only` | `serve` (public-only by default) |
|---|---|---|
| `127.0.0.1`, decimal, hex, octal, short `127.1`, `[::ffff:127.0.0.1]` | refused, 0 target hits | refused, 0 target hits |
| `localtest.me`, `127.0.0.1.nip.io` (names resolving to loopback) | refused, 0 hits | refused, 0 hits |
| `169.254.169.254` (metadata) | refused | refused |
| 6to4 `[2002:7f00:1::]` | attempted, unreachable on this host (no IPv6 route), not refused | same |
| Redirect from a public page to loopback or metadata | not measurable: both public redirectors tried (httpbin, httpbingo) refuse internal targets themselves. Read: every redirect hop goes back through `guard::check_url` (`apps/local/src/fetch.rs:175-182`) and the guarded DNS resolver (`:189`) | same |
| `HTTP_PROXY` set, name resolving to loopback | **FAIL**: handed to the proxy unrefused (the HTTP client honours proxy variables, and the proxy resolves the name) | not tried |
| Chrome subresources and navigation | control measured: a loopback page's `<img>` reached a second loopback port by IP and by `localtest.me` through the guard proxy. Refusal under `--public-only`: read in `netguard.rs` (SOCKS guard proxy, `host-resolver-rules=MAP * ~NOTFOUND`, QUIC and non-proxied UDP off), not measured, because no public echo service serves unescaped HTML | not tried |
| `scrape` without `--public-only` (CLI default) | reaches loopback by design ("a person at their own terminal may scrape their own localhost") | n/a |
| `map` | **no guard**: no `--public-only` flag, private targets always allowed (`main.rs:457`); measured fetching a loopback page and its sitemap | n/a |

### `init` and `mcp`

- `init --dry-run` with a scratch HOME names `~/.claude.json`, `~/.cursor/mcp.json` and `~/.codex/config.toml`, the configs of tools whose directories exist (`apps/local/src/init.rs:202-262`). Each is backed up to `<file>.firecrawl-bak` and gets a `firecrawl` entry that runs `firecrawl-local mcp`. The dry run also prints the cloud disclosure: search queries, blocked page URLs, data-provider calls, and "a random install ID and the name of your AI tool".
- `mcp` executes `npx -y firecrawl-mcp` (unpinned) with the inherited environment plus `FIRECRAWL_API_KEY` from the saved login and `FIRECRAWL_API_URL` pointing at an internal `serve` port.

### crw (contender) security

- CLI: every IP-literal loopback form (plain, decimal, hex, octal, short, v4-mapped) reached the target; names that resolve to loopback were refused; 6to4 and metadata were attempted and unreachable, not refused.
- `serve` with default configuration (run inside an empty network namespace): listens on `0.0.0.0:3000` (`config.rs:707-708`), processes requests with no key (`AuthConfig::default()` has none), refuses all nine SSRF forms with 400.
- With no renderer on PATH it downloads LightPanda 1.0.4 (77 MB, SHA-256 pinned) mid-request; `CRW_CDP_URL` skips that. There is no flag to turn JavaScript rendering off.

### Not run

The Docker self-host; `auto` mode against the real cloud; `crawl` and `map` comparisons beyond one docs site; the browser-path refusal (above); Firecrawl Local on macOS or under Codex.

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| C1 `scrape` | T1 `firecrawl-cli fetch` | **ADAPT** (conditional) | a tier in front of the keyless-then-keyed ladder in `budgeted_invoke` | eligible fetches when the binary is present; `FIRECRAWL_CLI_LOCAL=0` turns it off | §2 tables, judge | measured; browser refusal read |
| C1 `crawl` | T1 | SKIP for now | n/a | n/a | 10 pages in 0.98 s, 35 MB, robots honoured | measured once |
| C1 `map` | T1 | SKIP | n/a | n/a | no guard (`main.rs:457`), measured | measured |
| C1 `serve` | T1 | SKIP | n/a | n/a | wrapper fails against it in off mode; any token accepted | measured |
| C1 `mcp`, `init` | T1 and T3 | REJECT | n/a | n/a | unpinned `npx` run with the key injected; edits every agent's MCP config | measured, read |
| C1 `login` | T1 | SKIP | n/a | n/a | a saved login turns every `auto` fallback into a keyed call | measured |
| C1 `search`, `find-tools`, `data` | T1 | SKIP | n/a | n/a | cloud calls; the wrapper already covers search | read |
| C2 Docker self-host | T2 hosted app | SKIP | n/a | n/a | the app's spend is LLM extract and search; needs an always-on server; app hardcodes the cloud endpoint | **PARTIAL**: read, not run |
| C3 `firecrawl-build-*` skills | T1 | SKIP | n/a | n/a | vendor build guides for apps using the cloud API; the harness has `firecrawl-cli` and its index skills | read |
| C4 pointer READMEs | all | SKIP | n/a | n/a | no content beyond the docs | read |
| crw 0.46.3 (contender) | T1 | SKIP | n/a | n/a | IP-literal SSRF on the CLI, open server by default, auto-download | measured |
| Trafilatura 2.3.1 (contender) | T1 | SKIP | n/a | n/a | coverage 23-27 of 39 | measured |
| T3 private config | T3 | no change | n/a | n/a | the tier needs no host config | n/a |

**Decision-rule scorecard for C1 under the proposed argv.** (1) coverage 37 of 39 = 95% (plus `u30`): pass. (2) recall 0.93, cloud-outright 16%: pass. (3) no Authorization header leaves the host in off mode: pass for the proposed configuration; the default `auto` mode fails it with a saved login. (4) zero cloud egress in off mode: pass. (5) every SSRF probe refused: **not met** (one fail with `HTTP_PROXY`, the browser refusal unmeasured, `map` unguarded, 6to4 and redirects not refused-measured). Countermetrics: latency 0.2x the cloud, pass; peak memory 1.86-1.92 GB, narrowly inside the 2 GB bound.

Criterion 5 is why the verdict is ADAPT and not ADOPT. The adapted tier only runs `scrape --public-only`, never `map`; it builds the child environment from nothing, so no proxy variable reaches it; and the browser refusal becomes acceptance test 4 in #807.

### Price checks

- **Context cost.** Nothing enters agent context except a one-line `local:` note on calls the tier served, and one sentence in the Firecrawl paragraph of the `data-source-clis` skill (`--cloud` to skip the tier). No skill, hook or MCP server is installed.
- **Armor test.** The armor is the wrapper's: off mode forced, `--public-only` forced, the environment rebuilt without keys, cloud URL or proxies, `map`/`serve`/`mcp`/`init` never called. The off-mode probes (no cloud request with a saved login, a 501 from `serve` instead of forwarding, a private target refused locally even in `auto`) and the SSRF table show each piece holding; `HTTP_PROXY` and `map` show what happens without it.
- **Placement and off switch.** Inside `bin/firecrawl_cli.py`, optional binary, `FIRECRAWL_CLI_LOCAL=0` or uninstalling the binary restores today's behaviour exactly. A per-call `--cloud` covers the known local losses.
- **Delivery versus content.** The binary is delivery: nothing it ships is read by an agent as instructions. Its fetched pages are untrusted content, exactly as the cloud's are today.
- **Supply chain.** AGPL-3.0, run unmodified as a separate process: no obligation arises for internal use. No release binary at this commit, so it is built from source pinned by commit and lockfile, which takes long on a loaded host. Its crates come from crates.io under the lockfile. The only network code that runs in off mode is the page fetch and Chrome. The risky surfaces (`mcp`'s unpinned `npx`, `init`'s config edits, `login`'s saved key) are verbs the wrapper never calls.

## 4. Proposed changes

All in #807; nothing is applied by this note.

| Change | Files | Provenance and pin | Owner | Rollback |
|---|---|---|---|---|
| Local tier for eligible `fetch` calls | `bin/firecrawl_cli.py` (`budgeted_invoke`, `:793`), its tests | firecrawl/firecrawl @ `dc37f52f`, `firecrawl-local` 0.1.1, `cargo install --locked --git … --rev dc37f52f…` | hov-stack maintainers | `FIRECRAWL_CLI_LOCAL=0`, or uninstall the binary |
| `--cloud` per-call override | same | n/a | same | remove the flag |
| Offer the binary in `/hov-setup`, report it in `harness-doctor` | `plugins/hov-stack/skills/hov-setup/SKILL.md`, `scripts/harness-doctor.sh` | same pin | same | drop the offer and the check |
| One sentence in the Firecrawl paragraph | `skills/data-source-clis/SKILL.md` and its plugin copy, `harness/data-source-clis.md` | n/a | same | revert the sentence |

**Which calls the tier would serve.** Over the last 30 days of agent transcripts on this host (696 sessions that ran `firecrawl-cli fetch`; 3,397 parsed fetch commands, `--help` excluded), 66% asked for formats the tier serves (2,032 `--format markdown`, 169 `--full`, 35 other markdown, html, rawHtml or links requests) and 34% (1,161) used the default server-side `summary`, which stays on the cloud's keyless-first path. These are commands, not credits: the ledger does not record formats, and both groups try Firecrawl's free keyless tier first, so the keyed share of each is not measured.

## 5. Shared versus target-specific, and dropped hits

**Shared:** Firecrawl Local's off-mode egress and guard results hold wherever it runs. **T1 only:** the wrapper's ledger, keyless ladder and session cap are what make the tier worth having. **T2 only:** the hosted app runs on serverless functions and spends on cloud-only features, so neither the binary nor the self-host fits it.

**Contenders (Phase 3 discovery: GitHub search over four passes, READMEs, benchmarks; about 40 admitted).** Measured: crw (closest substitute: one Rust binary with scrape, crawl, map and a Firecrawl-shaped API) and Trafilatura (the no-browser baseline). Triaged and not measured:
- Crawl-and-scrape substitutes: Crawl4AI (Python with Playwright or Docker), Scrapling, Hound, Spider (spider-rs), webclaw (AGPL, Rust), Jina Reader self-host, Crawlee, siteforge, Crawl0, docrawl, doc-scraper, DocSnap, pagesift, tearsheet, Searcharvester, Draco (repository not found), fetchmd, url2md. None offered more than Firecrawl Local's single binary with a guard and an off switch, and the Python and Node ones bring a browser install and a runtime the wrapper does not otherwise need.
- Single-page extractors and converters (complements, not substitutes): rs-trafilatura, Defuddle, dom_smoothie, htmd, xberg html-to-markdown, MinerU-HTML, firecrawl html-extractor, anymd. PDF and document converters: MarkItDown, Docling, OpenDataLoader PDF, Marker, PyMuPDF4LLM, Firecrawl's AnyDoc and pdf-inspector. Firecrawl Local already parses PDFs locally (6 `local-pdf` fetches here).
- Browser pieces: Patchright, Lightpanda, wreq.
- Collapsed as thin wrappers: scrapling-fetch-mcp, crawlmd. Self-host "alternatives" that repackage Firecrawl's own compose file were dropped.

## 6. Audit dividend

Items 1-3 are defects in `firecrawl-cli` on `main`, found while measuring and independent of Firecrawl Local; filed as #805. Item 4 is a spend observation.

1. **`redact()` rewrites fetched page text.** It runs over the whole vendor envelope (`bin/firecrawl_cli.py:2616`), and its pattern rules (`:993-1005`) match ordinary prose and docs examples: "Require bearer tokens for API endpoints" came back as "Require bearer [REDACTED] for API endpoints" on two fixture pages.
2. **Keyed vendor calls skip the API URL check.** `api_base()` (`:2234-2246`) refuses a plain-http non-loopback `FIRECRAWL_API_URL` only for API-direct verbs; keyed vendor calls inherit it (`:2533`). With a dummy key and a non-routed plain-http address, `fetch` connected there three times; `developer` refused it.
3. **Keyless-first is turned off by a trailing slash** on an explicitly set default API URL (`keyless_ready`, `:744`, exact string comparison).
4. **A few large fetches carry much of the keyed spend.** In a sample of 252 keyed call envelopes from agent transcripts, 1-credit calls were 49% of credits, and six single calls (PDFs billed per page, a LinkedIn page billed 10) carried about two fifths. Firecrawl Local parses PDFs locally, so an eligible PDF fetch costs nothing instead of a credit per page.

## 7. Do not retry unless

- **Firecrawl Local `map`:** it gains `--public-only` (or honours the guard), then re-run the loopback map probe.
- **Proxy handling:** it stops honouring proxy variables or applies the guard to proxied requests; then the wrapper's scrub becomes defence in depth instead of the fix.
- **`mcp` and `init`:** `mcp` pins its npm package or ships its own server, and `init` asks before editing each agent's config.
- **Pin moves:** before moving past `dc37f52f` or 0.1.x, re-run the fixture, the off-mode egress check and the SSRF table; re-measure at once if the default cloud mode, the guard defaults or the install-id behaviour change.
- **Browser refusal:** a public fixture page that references `localtest.me` exists (acceptance test 4); until then the browser path is read, not measured.
- **crw:** its CLI refuses IP-literal private targets and `serve` binds loopback or requires a key by default.
- **Trafilatura:** only as a no-browser fallback if Firecrawl Local stops being maintained.
- **Docker self-host for the hosted app:** the app's own Firecrawl use exceeds the plan's included credits for two months running, or the app gains an always-on server.
