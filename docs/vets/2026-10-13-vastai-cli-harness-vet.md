# Harness vet: vast.ai CLI (PyPI `vastai` 1.8.3) and its shipped `SKILL.md`

- Date: 2026-10-13. Skill: harness-vet, run as a 12-agent Workflow (source readers, a docs and supply-chain collector, refute-by-default verifiers; 0 agent errors, 1.54M subagent tokens, 750 s) plus inline live measurements against the real account. Landing: wrapper, tests, docs and this note in one PR (dotfiles#1767).
- Operator ask: "give my ai agents in claude code cli and elsewhere agent-native persistent access to my vast.ai account in case they want to rent GPUs for anything … create keys, get ssh set up … integrate with bws … /harness-vet and maybe /rent-check or something and tell agents that they have this ability now. you will likely need to install the cli tool too."
- Verifier tally over the readers' claims: 48 CONFIRMED, 3 REFUTED, 16 PARTIAL. Every item below that cites a `file:line` was confirmed against the vendor source at the pinned release; items marked *live* were run against the account.

## Verdict in one screen

**ADOPT the vendor CLI behind a harness wrapper. EXTRACT the usable facts from the vendor's shipped `SKILL.md` into `harness/data-source-clis.md`. SKIP the vendor `SKILL.md` as a skill, SKIP the vendor `install.sh`/`vastai update` path, and SKIP the vendor's plaintext key file.**

1. **Vendor CLI through `bin/vastai`: ADOPT.** The CLI is the right primitive (every rent/monitor/destroy operation is one command, `--raw` gives JSON), but headless it has four key-leak paths and an exit-0-on-error habit. The wrapper closes them: key reaches the vendor as an environment variable only, resolved env → bws → `~/.secrets`; `--explain`, `--curl`, `--api-key`, a non-loopback `--url`/`VAST_URL`, `set api-key`, `update`, and `destroy` without `-y` are refused before any exec; `--full` (and `--no-color` off a terminal) are added unless `--raw`; a vendor exit 0 after an API error becomes exit 1. `vast-ssh <id>` gives a shell on an instance with the dedicated agent key.
2. **Vendor `SKILL.md` as an installed skill: SKIP, facts extracted.** It tells agents to `curl | bash` the installer and run `vastai set api-key` (both conflict with the harness), carries `allowed-tools: Bash(vastai:*)`, "Always …" directives, and two commands that do not exist in 1.8.3 (`update instance --bid_price`, `create api-key --permissions`). The CLI's own `--help` epilog (`cli/main.py:101`) points agents at a mutable raw-GitHub URL for it, so it is a self-updating instruction channel. It is not auto-discovered from the venv (confirmed), so nothing had to be removed.
3. **Vendor `install.sh` and `vastai update`: SKIP.** The installer edits rc files when run at a TTY, trusts TLS only (no signature or attestation), and honours `VASTAI_CLI_BASE_URL`/`VASTAI_PIP_SPEC` overrides. The pinned uv venv (`vastai==1.8.3`) replaces it; `update`/`uninstall` only print hints and exit 1 inside a venv anyway.
4. **Delivery (PyPI wheel): pass, no REJECT.** Installed wheel sha256 `8c50b291…7010` and sdist `bb4911f7…5778` match PyPI; every RECORD hash matches; pure `py3-none-any`; no install scripts. Weak points for the re-audit trigger: the publish workflow uses a long-lived PyPI token, no attestations or signing, and is not test-gated; `cryptography==49.0.0` is pinned but never imported.
5. **Account posture: auto top-up is enabled.** Agent spend is therefore not bounded by the prepaid balance. This vet changed nothing in billing; it is the operator's decision and is reported first in the hand-off. The API key minted for agents has no `billing_write`, so an agent cannot change it either way.

**Not vetted here:** the serverless/endpoint/workergroup command family (its key travels in a JSON body and, on the data plane, in a URL query, see §2), the vast.ai MCP server if one exists, and the Codex/other-host install (documented in §4, not run).

## 1. Source identity, targets, run choices

| Item | Identity |
|---|---|
| Package | PyPI `vastai` 1.8.3, wheel sha256 `8c50b291dd92feecc4e0a7eb57b365afe6f9ab719c4d6b4f681d0af367757010`, sdist `bb4911f7…605778`; both match PyPI's published digests; `py3-none-any`; non-`.py` payload: `pdf/vast.ai-logo*.png`, `pdf/watcher.sh`, `SKILL.md` |
| Source | github.com/vast-ai/vast-cli @ `8d0d31c9…` (clone read by the reader fleet) |
| Release cadence | 64 PyPI releases; the last five span 2026-09-11 to 2026-10-02 (every 2 to 10 days) |
| Install here | `uv venv ~/.local/share/vastai-cli/venv --python 3.12` (Python 3.12.3) then `uv pip install … vastai==1.8.3`; the vendor binary is not on PATH, only the wrapper is |
| Account | An individual account with billing configured and auto top-up enabled (verified with `show user --raw`) |
| API key | `agent-<wsl-host>`, Standard type: User Read, Instances Read+Write, Billing Read, Misc; **no** User Write, **no** Billing Write, every 2FA toggle off. Per https://docs.vast.ai/api-reference/permissions: offer search is `misc`, create/destroy instance is `instance_write`, create ssh-key/api-key is `user_write` (not granted), transfer credit is `billing_write` (not granted). Seeded to bws as `VAST_API_KEY` from the browser clipboard; the value never entered a transcript. `show api-keys --raw` lists keys with `"key": null`. |
| SSH key | `vastai-agent@<wsl-host>`, ed25519, registered in the console; private key `~/.ssh/vastai_ed25519` (0600) |

**Targets.**
- **T1:** Claude Code on this host: interactive sessions, background jobs, subagents, cron. Task: find an offer, rent it, work on it over ssh, watch it, destroy it.
- **T2:** "elsewhere": Codex lanes on this host and other machines holding a bws machine token. Same task; §4 lists what each needs.

**Run choices.** Readers (lean-reader on the vendor clone and wheel; lean-collector for PyPI, GitHub workflow and docs facts) produced claims with `file:line`; verifiers re-read the cited lines with a refute-by-default lens. Live measurements ran inline with the real key for reads and offer search only; no instance was created (§2 "Not run"). Landing depth: PR for review, in `docs/vets/` as established.

**Prior verdict.** None in `docs/vets/`; no `vastai` or `vast.ai` mention anywhere in the repo before this PR.

## 2. Measured, not inferred

### Where the key travels
- Core commands: `Authorization: Bearer <key>` header (`api/client.py:129-134`).
- Serverless endpoint and workergroup commands: key in the JSON request body (`api/endpoints.py`). Serverless data plane: key in a URL query string (`serverless/…/connection.py:118`). These families are not covered by the wrapper's refusals beyond the URL pin; they are not in the documented command set.
- **`--explain` and `--curl` print the full key, unredacted, to stdout** (`api/client.py:158` and `:46-48,161-163`). `--curl` exits 0 without sending the request and may print the `detect_role` `GET /users/current` call too. Wrapper: refused. The vendor parser keeps argparse's default `allow_abbrev`, so `--cur` and `--expl` are the same flags; the first adversarial round reproduced the key on stdout through `--cur` against an exact-token guard, and the wrapper now canonicalizes every long option (`canonical_flag`) before any guard runs.
- **`--url URL` and the `VAST_URL` env var send the Bearer key to any host; there is no allow-list** (`api/client.py:19`, `cli/utils.py:11-18`). Wrapper: only a loopback URL is accepted (needed by the test fixtures), anything else is refused before credential resolution.
- An empty `VAST_API_KEY` sends `Authorization: Bearer ` (empty). Wrapper: an env value that does not match `^[A-Za-z0-9_\-]{16,512}$` is refused.
- Key files: `set api-key` writes `$XDG_CONFIG_HOME/vastai/vast_api_key` in plaintext with umask mode (`cli/commands/auth.py:208`); a legacy `~/.vast_api_key` is copied to the XDG path at import (`cli/util.py:181-183`); on a 401 with a stale `vast_tfa_key` present, the CLI silently swaps the env key for the file key and retries (`cli/main.py:224-235`). Wrapper: `set api-key` refused; a present key file draws a stderr warning naming the path and is never deleted.
- REFUTED reader claim: "the SDK ignores `VAST_API_KEY`". `vastai/_base.py:20-21` reads it first.

### Egress and side effects of every process
- Every invocation, including `--version` and `--help`, performs an unauthenticated `GET {server_url_default}/api/v0/gpu_names/unique/` at import time to build an argparse `choices` list (`cli/commands/instances.py:549` → `cli/util.py:97-128`, 24-hour cache in `$XDG_CACHE_HOME`) and creates the XDG config, cache and state directories (`cli/util.py:87-90`). `server_url_default` honours `VAST_URL`, so the wrapper runs credential-free commands with `VAST_URL=http://127.0.0.1:9`: *live*, `vastai --version` answers `1.8.3` in 0.65 s with no network.
- The first authenticated command runs `detect_role` (an extra `GET /users/current` with the key) and writes `$XDG_CONFIG_HOME/vastai/vast_role`.
- Update nudge: `GET https://vast.ai/cli/manifest.json`, at most once per 24 h, only when stderr is a TTY; suppressed by `VASTAI_NO_UPDATE_CHECK=1`, `CI`, or `--raw` (`cli/selfupdate.py`). Wrapper sets `VASTAI_NO_UPDATE_CHECK=1`.
- No telemetry endpoint was found in the source.

### Exit status and headless behaviour
- API errors go through `_emit_error` to stderr and the process exits 0 (`cli/main.py:40-60`, `:237-238`). Under `--raw` the stderr line is `{"error": true, "status_code": N, "msg": "…"}`. *Live:* a bad key produced `{"error": true, "status_code": 401, "msg": "Invalid user key"}` on stderr with vendor exit 0; the wrapper exits 1 and says why.
- `--raw` turns an integer failure return into stdout `1` with exit 0 (`cli/main.py:204-212`).
- `destroy instance` without `-y` reads a confirmation from stdin; with no terminal it prints `Aborted.` to stdout and returns, exit 0, no request sent (`cli/commands/instances.py:238-247`, same for `destroy instances` `:258-270`). `destroy instance -y --raw` prints nothing on success (`:248`). Wrapper: `destroy` without `-y`/`--yes` is refused with the explanation; the follow-up is `show instance <id> --raw`.
- Bulk create/destroy print nothing under `--raw` and retry five times on HTTP 500, still exiting 0.
- `create instance … --raw` → `{"new_contract": N, "success": true}`. `show instance <unknown> --raw` → `{"instances": null}` exit 0; non-raw exits 1. *Live:* `vastai show instance 1 --raw` (an id this account does not own) printed `{"instances": null}` and exited 0. The docs use that answer as the post-destroy confirmation; it was observed for an unowned id, not yet for a destroyed one.
- `search offers` query fields are the vendor's own (`dph`, `reliability`, `cuda_vers`, `gpu_ram`, `inet_down`, `disk_space`, `geolocation`, `num_gpus`, `gpu_name`, `verified`, `rentable`; full list in `search offers --help`); results carry `dph_total` and `reliability2`, which are not accepted as query fields. A first draft of the docs quoted the result names; corrected before merge.
- `print_or_page` pipes output into `less -R` whenever the line count exceeds the terminal height (fallback 24) with **no isatty check** (`cli/display.py:464-476`); under a pty this hangs. Wrapper adds `--full` unless `--raw`/`--full` is present. *Live:* `vastai show instances` (0 instances) printed its summary box and exited 0.
- `show invoices-v1 --charges` prompts even with `--full` (`cli/commands/billing.py:472-476`): use `--raw`. `cloud copy --schedule` has an unbypassable `input()` (`cli/commands/storage.py:272-282`).
- `execute` is broken in 1.8.3 when the API returns a `result_url` (`cli/commands/misc.py:80`, AttributeError): use ssh.
- `ssh-url` ignores `--raw`, prints `ssh://root@HOST:PORT`, and can cache `port -1` permanently in `ssh_<id>.json` (`cli/commands/misc.py:193`) when asked before the instance has a port. `vast-ssh` takes only a line matching `^ssh://[^@ ]+@[^: ]+:[0-9]+$` and fails fast with ConnectTimeout 20 s so a poll-and-retry loop works.
- No cost-cap or TTL flag exists anywhere in the CLI. `--cancel-unavail` is opt-in; without it a failed schedule leaves a *stopped*, storage-billed instance. `create instance --ssh --direct` sends `runtype "ssh_direc ssh_proxy"` (vendor spelling, works). `search offers` accepts `gpu_name=RTX_4090 num_gpus=1 verified=true rentable=true`, sends `num_gpus` as a string, and pages only with `--limit`/`-o`. *Live:* `search offers --raw --limit 3 -o dph_total '…RTX_4090…'` returned three offers at $0.41-0.42/h.
- `vastai update` and `uninstall` detect "not managed" inside a venv, print hints and exit 1.

### Vendor `SKILL.md` (shipped in the wheel)
- Install instruction is `curl … | bash`; auth instruction is `vastai set api-key`; frontmatter `allowed-tools: Bash(vastai:*)`; several "Always …" directives.
- Factual errors against 1.8.3's parser: `update instance --bid_price` (the real command is `change bid <id> --price`), `create api-key --permissions` (the real flag is `--permission_file`).
- `create ssh-key` with no argument generates a new keypair and backs up and overwrites `~/.ssh/id_ed25519` (`cli/util.py:374-449`; `-y` makes it headless). Our key is a separate file and the API key cannot call this endpoint.
- Not loaded by Claude Code from the venv (confirmed by listing the skill sources); EXTRACT, do not install.

### Supply chain
- Wheel and sdist digests match PyPI; RECORD hashes all match the files on disk.
- Publish workflow (`.github/workflows`) uploads with a long-lived PyPI API token; no Trusted Publishing, attestations or Sigstore; the publish job is not gated on the test job.
- `install.sh`: edits shell rc files when stdin is a TTY, pins nothing by default (`VASTAI_PIP_SPEC` override), trust root is TLS to `VASTAI_CLI_BASE_URL`.

### Wrapper and tests
- `bash tests/vastai.test.sh`: 153 passed, 0 failed (hermetic: scratch HOME, fake `bws`, fake venv binary that records argv and env, fake `ssh`). Planted negatives: a key in argv, a forwarded test-only timeout, a reached vendor on any refusal, a deleted key file.
- `shellcheck -S error` clean on the shim, `vast-ssh` and the test; `py_compile` clean.
- *Live through the wrapper:* `--version` (no network), `show user --raw`, `show instances` (non-raw, no hang, no color), forced 401 → exit 1, `search offers` → 3 offers.

### Not run
- **No instance was created or destroyed.** The rent → ssh → destroy loop is documented from source and help text, exercised only against fixtures. The first real rental should be watched end to end (and is the moment to confirm `--cancel-unavail` and `vast-ssh` behaviour on a direct-ssh instance).
- Serverless/endpoint commands, `launch instance`, volumes, snapshots, teams.
- Codex and other hosts (§4).
- `vastai delete api-key`/`delete ssh-key` need `user_write`: key revocation is console-only for this key by design, not measured.

## 3. Verdicts

| Component | Target | Verdict | Placement | Activation | Evidence | State |
|---|---|---|---|---|---|---|
| Vendor CLI 1.8.3 via `bin/vastai` | T1, T2 | ADOPT | uv venv at `~/.local/share/vastai-cli/venv` (disposable); wrapper + `vast-ssh` symlinked to `~/.local/bin` by `lib/manifest.sh` | `settings.json` allow `Bash(vastai:*)`, `Bash(vast-ssh:*)`; one clause in `CLAUDE.md`; sections in `data-source-clis` skill and harness doc | measured + live | installed |
| `vast-ssh <id> [-- cmd]` | T1 | ADOPT | sibling of the wrapper | same | measured (fixtures) | installed, no live instance yet |
| Scoped API key `agent-<wsl-host>` in bws as `VAST_API_KEY` | T1, T2 | ADOPT | bws project `startupbros` | wrapper's credential chain | live | seeded |
| Agent SSH key `vastai-agent@<wsl-host>` | T1 | ADOPT | `~/.ssh/vastai_ed25519`; registered in the console | `vast-ssh` default, `VAST_SSH_KEY` override | live | registered |
| Vendor `SKILL.md` | either | SKIP, facts extracted | not installed | none | measured (self-updating URL, factual errors, conflicting install/auth) | absent |
| Vendor `install.sh`, `vastai update` | either | SKIP | n/a | `update` refused by wrapper | measured | n/a |
| Plaintext key file (`set api-key`) | either | SKIP | n/a | refused by wrapper; warning if present | measured | absent |
| Auto Top-Up | account | operator decision | n/a | n/a | live (`balance_threshold_enabled: true`) | enabled, untouched |

### Price checks
- **Context cost.** One sentence in the always-on `CLAUDE.md` data-source paragraph plus three trigger words in the `data-source-clis` skill description. The command surface loads only with that skill or the harness doc.
- **Money.** Live account with real billing. Guards are procedural, not enforced: `--label` every instance with the job id, `destroy instance <id> -y` when done and confirm with `show instance`, `show instances --raw` before and after a job, `--cancel-unavail` on create, no `--bid_price` unless interruptible is intended. The vendor has no spend cap; the account's auto top-up means the balance is not one either.
- **Placement and off-switch.** Revert the two `DOTFILES_LINKS` rows and the two allow entries, run `dotup`; delete the API key and the SSH key in the console (the key cannot delete itself: no `user_write`). The venv directory is disposable.
- **Supply chain.** Pinned exact version in a venv; the wrapper prints the recreate commands on a missing venv. Re-audit on any bump (§7).

## 4. Other hosts and Codex (T2): what they need, not run here

1. The venv, created with the two commands in the wrapper header (the wrapper prints them on exit 3).
2. A bws machine token at `~/.config/bws/token` and the project id at `~/.config/bws/sb-project-id`; the wrapper then resolves `VAST_API_KEY` itself. Never `bws run`-wrap the agent.
3. Their own SSH keypair. The API key lacks `user_write`, so a new key cannot be registered on the account from the CLI; either add it in the console or attach it to one running instance with `vastai attach ssh <instance-id> "<pubkey>"` (an instance-level call). Point `VAST_SSH_KEY` at the private key.
4. Codex's read-only `$HOME` profile: the vendor writes XDG config/cache/state at import. Spell delegated calls with `XDG_CONFIG_HOME=/tmp/vast-xdg XDG_CACHE_HOME=/tmp/vast-xdg XDG_STATE_HOME=/tmp/vast-xdg vastai …`, or add the three default directories to that profile's writable roots.

## 5. Shared vs target-specific findings

- **Shared artifact findings** (any host, any agent runtime): the four key-leak paths (`--explain`, `--curl`, `--url`/`VAST_URL`, `--api-key`/key file); exit 0 after API errors; `destroy` aborting with exit 0 headless; the pager without an isatty check; the import-time catalog GET from every process; the self-updating `SKILL.md` channel; no spend cap or TTL in the product.
- **Target-specific (this host):** venv path, agent SSH key file, bws token present, `~/.local/bin` symlinks.
- **Target-specific (account):** auto top-up enabled; a single scoped key shared by every agent host (rotation is one `secrets.sh seed VAST_API_KEY` after minting a new key in the console).

## 6. Audit dividend

1. **Auto Top-Up is on**. Found while reading the billing page to confirm key scope; nothing was changed. If the operator wants a hard ceiling, the vendor offers none; turning auto top-up off makes the prepaid balance the ceiling.
2. **`show user --raw` echoes `crisp_hmac` and `sid`**, session-like values alongside the profile. Agents should select fields with `jq` and never paste the whole object into an issue or PR.
3. **The vendor's `--help` epilog points at a mutable raw-GitHub `SKILL.md`** (`cli/main.py:101`). Any agent that follows `--help` literally reads an instruction channel the vendor can change at will. The wrapper does not alter help output; the harness docs are the instruction channel instead.
4. **`tool-smoke.sh` and harness CI** now cover `vastai --version`/`--help` and run `vastai.test.sh` in the `tools` batch, so a venv rot or wrapper regression shows up in the weekly smoke, not at rental time.

## 7. Do-not-retry unless

- **Installing the vendor `SKILL.md` as a skill:** it pins to a release instead of a raw-GitHub URL, drops `curl | bash` and `set api-key`, and the two non-existent commands are fixed.
- **Vendor `install.sh` or `vastai update`:** the release is signed or attested and a managed install replaces the venv.
- **Loosening the `--url`/`VAST_URL` refusal:** a documented need to talk to a non-console endpoint through this CLI; the serverless data plane has its own client and is out of scope anyway.
- **Dropping the `destroy -y` refusal or the exit-status repair:** the vendor exits non-zero on abort and on API errors (check `cli/main.py` `_emit_error` and `cli/commands/instances.py` `destroy__instance` at the new release).
- **Re-audit trigger for any version bump past 1.8.3:** re-check `api/client.py` (`--explain`/`--curl` printing, `server_url_default`), `cli/util.py` (`_get_gpu_names` URL and key-file copy), `cli/display.py` (`print_or_page`), `cli/main.py` (`_emit_error`, 2FA key swap), and re-run `bash tests/vastai.test.sh` plus the five live checks in §2.
