# Pi Setup Conventions

## Package strategy

- **StartupBros Pi packages under `~/SITES/pi-*` are dogfooded from local repo paths during active development.**
- Prefer local repo paths in `~/.pi/agent/settings.json` over `git:github.com/StartupBros/...` for day-to-day work.
- Use git-installed package specs only for release-validation or install-path smoke tests.
- If a public package exists, do **not** keep a duplicate ad-hoc copy of the same extension in `~/.pi/agent/extensions/`.

## What stays local

Keep these in `~/.pi/agent/extensions/` when they are personal, machine-specific, or policy-specific:

- guardrails
- local workflow shims
- notification integrations
- personal UI tweaks
- experimental one-off extensions

Only package and publish extensions that are broadly reusable.

## Always-on vs opt-in

- `~/.pi/agent/extensions/` is for always-on extensions.
- `~/.pi/agent/optional-extensions/` is for opt-in extensions, especially anything that overrides built-in tools or changes execution environment.

## Cross-harness compatibility

- `~/.claude/skills` is intentionally loaded in Pi for shared-skill compatibility.
- Treat that as a compatibility bridge, not as StartupBros package dogfooding.
- Avoid duplicating the same skill/package in multiple places unless explicitly testing precedence.

## Working rule

When changing a StartupBros Pi package, the local Pi environment should use that repo directly so daily usage exercises the real package source.

## Third-party runtime dependencies

- Do **not** point live Pi runtime config at `~/.cache/checkouts/...` paths.
- For third-party Pi packages, prefer Pi-managed package sources in `settings.json` (`npm:` or `git:`), so `pi update` can refresh them.
- For third-party skill repos that are not clean Pi packages, use a stable vendored clone path under `~/.pi/vendor/...`, not the checkout cache.
- No scheduled updater for third-party Pi dependencies ships here; refresh them with `pi update` when you want them moved.

## Node toolchain policy

- `pnpm` remains the default package manager for repo work.
- `npm`/`npx`/`yarn` are **not blocked** at the Pi environment level anymore.
- Keep Python package-manager guardrails (`pip`, `poetry`, `python -m pip`, etc.), but do not add new Node package-manager interception unless there is a very strong reason.

## Machine-specific server notes

- On the CI host, the operator's user is already in the `docker` group.
- For the Discord bot compose file at `/opt/example-bot/docker-compose.yml`, prefer plain `docker compose ...` over `sudo docker compose ...`.
- A machine-specific workflow shim under `~/.pi/agent/extensions/` exposes status and logs for a CI Discord bot.

## Parallel agent workflow

- `pi-subagents` is the active subagent package on this machine, loaded from `~/SITES/pi-subagents`.
- Use the `subagent` tool, `/run`, `/chain`, `/parallel`, and `/subagents-doctor` for delegation workflows.
- DCG is supplied through pi-subagents' `requiredChildExtensions`, which appends the guard even when an agent declares its own `extensions:` or comes from a project/package discovery root. Keep `defaultChildExtensions` empty to preserve the child extension sandbox, and run `~/.pi/agent/bin/pi-dcg-doctor` after changing either setting.
- Avoid loading multiple subagent/side-agent packages at once unless explicitly testing a replacement; overlapping delegation commands/tools create confusion.
- Startup memory aid: the local `startup-cockpit` extension shows a capability map on session start; use `/welcome` to reopen it and `/capabilities` for the expanded view.
