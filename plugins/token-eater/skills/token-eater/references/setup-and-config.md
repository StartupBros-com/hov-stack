# Setup and config

Config exists so the user types `/token-eater` and nothing else — **ever**. The first
run asks a short interactive preflight (plain language), saves the answers, and every run after that
is zero-questions. Config records only the user's *choices* (which credits, what task) — never
secrets, postures, tiers, idle windows, or reserve floors (those concepts are gone).

## Interactive preflight (asked once, then persisted)

Run the preflight when there is **no readable config** and no relevant `$ARGUMENTS`, or when the
`setup` token is passed. Use the **AskUserQuestion tool** so the user clicks plain-language choices —
they never type a flag. Ask only what isn't already known:

1. **"What should I do?"** — plain-language options that map to skills (see SKILL.md's mapping table).
   Mark the safest/most-broadly-useful *(Recommended)*. → saved as `task`.
2. **"Which credits should I use?"** — only if more than one service is signed in (else pick the one
   that is, silently). Plain wording: "Claude / Grok / Codex credits". → saved as `services`.

Before any shell command, present the informed-consent caveat from `SKILL.md` and ask whether to
continue. Only an explicit yes permits `--trust-repo-caveat 1`, where `1` is the exact caveat version
just shown. Never reuse an affirmation after that version changes. The engine records consent outside
the repository, keyed by canonical path and caveat version. Project config never counts as consent.

After consent, offer only services that `scripts/detect-adapters.sh` reports `available`. **Save the
answers to `./.token-eater.yaml`** and continue the run.

If `$ARGUMENTS` already names a service and/or skill (power user), skip the matching question(s); offer
to save them once.

## Config locations

Load config in this order; the first one found wins (a project file overrides the user default):

1. **Per-project:** `./.token-eater.yaml` in the repository where the skill is running.
2. **User-scoped:** `${XDG_CONFIG_HOME:-~/.config}/token-eater/config.yaml` (Linux / XDG).
3. **macOS fallback:** `$HOME/Library/Application Support/token-eater/config.yaml` when XDG is unset.
4. **Windows fallback:** `%APPDATA%\token-eater\config.yaml` under Windows-native Claude Code.

Write the user-scoped config by default. Write `./.token-eater.yaml` only when the user wants a different default service for one specific project. Never write secrets — config records the choice of service only.

## Schema

Schema version `2` is YAML, intentionally small enough for an agent to read and edit without a YAML library.

```yaml
version: 2
services: [grok]              # which service(s) to spend by default, in order. The first available,
                              # un-parked service does each model chore; later ones pick up the rest.
task: simplify-and-refactor-code-isomorphically  # the skill the user chose in the preflight ("what
                              # should I do?"). Persisted so /token-eater never re-asks. `setup` rewrites it.
review_before_pr: false       # optional: run one review pass before opening each draft PR
                              # (default off — review the draft PR yourself, e.g. with /ce-code-review)
stop_when_low: null           # optional/advanced: e.g. "20%" to stop spending a service when onwatch
                              # reports it near its limit. Needs onwatch; ignored if onwatch is absent.
result_dir: .token-eater/runs # where run artifacts and the ledger live (local audit trail)
```

Field meanings:

| Field | Meaning |
| ----- | ------- |
| `version` | Config schema version. Current value: `2`. An unknown version should stop and ask to re-run setup rather than guess. |
| `services` | Ordered list of service ids from `adapters.yaml` to spend. A service must also be detected before it can be used. A command-line service argument overrides this list for that run. |
| `task` | The skill chosen in the preflight (plain-language "what should I do?" → skill name). Persisted so the user is never re-asked. Omitted/empty → ask the preflight question. A skill argument overrides it for that run. |
| `review_before_pr` | When `true`, run the optional pass in `references/review-pipeline.md` before each draft PR. Default `false`. |
| `stop_when_low` | Optional balance guard, e.g. `"20%"`. Only has effect when onwatch is available (`scripts/onwatch-usage.sh`); otherwise the run simply continues until each service's circuit breaker fires. |
| `result_dir` | Repo-relative directory for run artifacts and the ledger. Defaults to `.token-eater/runs`. |

Anything not listed here (old `posture`, `tier`, `idle_window`, `reserve_floor`, `run_config`, `schedule` keys from schema v1) is obsolete. **Loading a v1 config is non-blocking:** read its `providers[].id` list, in order, as the new `services` list (so a v1 file with grok, codex, claude becomes `services: [grok, codex, claude]`), ignore every other key, and proceed with the run. Do not stop to migrate. Add one line to the run summary offering `/token-eater setup` to write a clean v2 file when convenient.

## Round-trip behavior

Every normal invocation resolves **service + task** before doing work:

1. If `$ARGUMENTS` names a service and/or skill, use them for this run.
2. Else if the `setup` token is present, run the interactive preflight (and rewrite the saved file).
3. Else if a readable config exists, load it; use its `services` and `task`. Any field it's missing,
   ask just that one preflight question.
4. Else run the interactive preflight and **persist `{services, task}` to `./.token-eater.yaml`**.
5. If config parsing fails, do not guess — report the path and the problem, and offer to re-run the
   preflight and replace the file.

The goal: after the very first run, `/token-eater` on that project asks **nothing** — it reads the
saved `{services, task}` and the engine's per-repo trust cache and just runs.

After resolving the service, the run loop still runs `scripts/detect-adapters.sh`: config is intent, detection is current capability. A service must be both chosen and currently installed to be spent.
