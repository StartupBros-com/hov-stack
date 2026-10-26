# Hugging Face: the `hf` CLI, Jobs, and the spend model

Adopted 2026-08-14 after two vets: `memory/hf-cli-vet-2026-08.md` for the CLI,
`memory/hf-compute-for-agents-2026-08.md` for the compute surface. The CLI itself
is a plain tool and needs no doctrine. The **billing** does, because HF is the
only paid surface in this harness with no hard spending cap.

## The spend model — read this before writing any HF call

**There is no user-settable hard spending cap on a personal or PRO account.**
Verified against a known-positive: the org-level control is real and documented
(`docs/hub/enterprise`, "Usage & billing control" = ❌ Free-org / ✅ Team / ✅
Enterprise), and the personal equivalent is documented nowhere. The comparison
table has no personal-account column at all.

- The $10 / $50 / $100 milestone emails are **alerts, not stops**. HF staff, on
  the record: *"The $100 is the threshold limit and please note it doesn't act
  as a spending cap."*
- **The only cap that works is mechanical**: no card on file, or auto-recharge
  off, plus a manually pre-loaded balance. `docs/hub/jobs-pricing`: *"Jobs are
  available to any user or organization with a positive credit balance."* Spend
  stops at zero and stays stopped. **Keep auto-recharge off while the prepaid
  balance is the guard. Do not turn it on merely to unblock a job.**
- An undocumented `$300/mo` PRO cap for Inference Providers is referenced in an
  HF staff forum reply and corroborated by a 2026-08-06 user hitting `403: You
  have exceeded your monthly spending limit for Inference Providers`. It is in
  no current doc, and it covers Inference Providers only, **never Jobs**. Do not
  treat it as a backstop.
- **Jobs bill per MINUTE, not per second.** `docs/hub/jobs-pricing` says
  "computed by the minute"; `docs/hub/jobs` and `jobs-overview` both say "only
  pay for seconds used". HF's own docs contradict each other, and the CLI
  settles it: `hf jobs hardware` prints a **`cost/min`** column. A 10-second job
  bills a full minute — batch work into one job rather than spraying many small
  ones.
- **`--timeout` counts SECONDS by default.** `int` with `s` / `m` / `h` / `d`
  suffixes, `s` implied. `--timeout 30` is thirty *seconds*; you want
  `--timeout 30m`. Always pass a suffix.

**`hf jobs hardware` is the authoritative price list** — it prints all 26
flavors with cost/min and cost/hour, live. Never quote prices from docs when
that command exists. Anchors as of 2026-08-14: `cpu-basic` $0.01/hr ·
`a10g-large` $1.50/hr · `a100-large` $2.50/hr · `h200` $5.00/hr ·
`rtx-pro-6000x8` $22.00/hr · `l40sx8` $23.50/hr · `a100x8` $20.00/hr ·
**`h200x8` $40.00/hr**, the ceiling worth fearing at $960/day if left running.

Note there is **no H100 flavor in Jobs at all** — H100 is an Inference Endpoints
instance type, a different product on a different bill (AWS $4.50/hr, GCP
$10.00/hr; pick AWS). Do not mix the two price lists.
`docs/inference-endpoints/pricing` is stale (no B200, no RTX, no AWS H100 row);
`huggingface.co/pricing` is current.

## Subscription and organization scope

A PRO subscription multiplies included credits and quota; it is not a gate to
Jobs, Inference Providers or Endpoints. A positive credit balance is what permits
compute. Team-organization spending limits apply to Inference Providers only.
Using an organization's billing requires the operator's decision and an admin role;
it is not a personal-account spending cap or a Jobs backstop.

## What this is for, and what it is not

**Use Inference Providers for the narrow slice OpenRouter structurally cannot
serve**: embeddings, rerankers, ASR, classification outputs. OpenRouter's
411-model catalog contains **zero** models with those output types — it is a
chat-completions router, so this is permanent, not a catalog gap.
`BAAI/bge-reranker-v2-m3` (18.5M downloads) is warm on HF and will never appear
on OR. Chat models stay on OpenRouter: GLM-5.2 is live on both and cheaper to
keep where it already runs.

**Use Jobs on demand, not on a schedule.** Demand was refuted at adoption time —
<mac-host> (M3 Ultra, 512GB) already does MLX fine-tuning to 70B for free, and no
blocked workload could be named. Jobs is documented here so it is reachable in
one command when something genuinely does not fit; wiring it into a timer needs
three concrete jobs <mac-host> cannot serve.

**Do not use**: dedicated Inference Endpoints (no lifetime cap — an a100 left
running is ~$1,800/month), ZeroGPU (Gradio-locked, auto-bills overage at $1 per
10 min), or the HF hosted MCP server (its 4 base tools duplicate `curl`, and its
opt-in tier adds Run-and-Manage-Jobs — a standing checkbox wired to billable
compute).

## Command surface

`hf --help` is the authority. Notes it does not give you:

- `hf jobs run [OPTIONS] IMAGE COMMAND...` — options come *before* the image;
  `IMAGE` and `COMMAND...` are positional and both required. `--flavor` defaults
  to `cpu-basic` (the $0.01/hr one), which is the right default to leave alone.
  `-d/--detach` returns a job ID instead of blocking.
- `hf jobs hardware` lists flavors with live prices. `hf jobs ps` lists running
  jobs, `-a` includes finished and failed. `hf jobs wait` blocks on completion.
- `--secrets HF_TOKEN` (bare, no `=value`) forwards your own token into the job
  without putting it in `--env`, where it would be stored as a plain label.
  Prefer `--secrets` for anything credential-shaped.
- Job stage enum is `COMPLETED | CANCELED | ERROR | DELETED | RUNNING |
  SCHEDULING`. There is no TIMEOUT stage, so a timed-out job presumably lands in
  `ERROR` and exits non-zero — **inferred from the enum, not tested**, because
  testing it costs money. Verify before relying on exit code alone.
- Pure-HTTP path if you would rather not shell out: **13 `/api/jobs/*` paths (14
  operations) plus 7 `/api/scheduled-jobs/*` paths (9 operations)** — re-counted
  against the live spec 2026-08-14. Includes `/logs`, `/metrics`, `/events`,
  `/cancel`, `/duplicate`, and the full `/api/scheduled-jobs/{ns}/{id}/{run,
  suspend, resume, schedule}` set.
- **The spec is at `https://huggingface.co/.well-known/openapi.json`** (254
  paths, ~950 KB, no auth). `https://huggingface.co/api/openapi.json` looks
  right and returns `401 {"error":"Invalid username or password."}` *even with a
  valid token* — it is not the spec, and the 401 will send you hunting for a
  credential problem you do not have.
- Read-only balance check:
  `curl -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/settings/billing/usage/jobs`
- The update nag goes to **stderr only**; `hf <cmd> --json` stdout stays valid
  JSON, so `hf` is script-safe. `HF_HUB_DISABLE_UPDATE_CHECK=1` silences it.

## Credentials

`HF_TOKEN` is in **bws (canonical)**, with a runtime copy in `~/.secrets`
sourced by `~/dotfiles/.bashrc`. Both verified identical by sha256 on
2026-08-14. `HUGGINGFACE_HUB_TOKEN` in the same file is an alias (`="$HF_TOKEN"`),
not a second credential — there is only one token here.

`HF_TOKEN` takes precedence over any stored login, so subagents and cron get
non-interactive auth for free with no `hf auth login` step.

## Install mechanics

```
pipx install hf          # package `hf` == HF's CLI-only split-out of huggingface_hub, same 1.27.0 release line
```

**Never use the standalone `curl | bash` installer.** Verified at
`install.sh:394` (sha256 `6915d02a…`): it runs
`hf skills add hf-cli --global --claude --force`, which writes a 31,931-byte
SKILL.md into `~/.agents/skills/` and symlinks it into `~/.claude/skills/` —
a jsm-managed directory. Its always-on description is 1,008 chars and claims
*"anything related to the Hugging Face ecosystem and to AI and ML in general"*.
The installer also appends to `~/.bashrc` unless given `--no-modify-path`.

`pipx install hf` writes **zero** skill artifacts — verified 2026-08-14 by
diffing `~/.claude/skills` and `~/.agents/skills` before and after. The skill has
only ever come from an explicit `hf skills add`.

If the skill is ever wanted, the safe route is `hf skills add --dest
<path-under-dotfiles>` (bare `add`, no `--claude`) as a hand-trimmed,
git-committed snapshot, plus a `skillOverrides` demotion to
`user-invocable-only`. Bare `add` writes a project-local `.agents/skills/...`
file that Claude Code never reads; only `--claude` creates the live symlink.
