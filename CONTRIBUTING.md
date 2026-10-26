# Contributing

This is the harness I work in every day, published as it is. The expected way to use it is to fork it and make it yours, not to send your setup back here.

## Pull requests I take

- Fixes to `setup`, `lib/settings-seed.js` and `tests/repo/setup.test.sh`, with the test that proves the fix.
- Fixes to a guard under `hooks/` with its test under `hooks/tests/`.
- Corrections to the README, `CLAUDE.md` or `HARNESS.md` where the text and the code disagree. `scripts/check-readme-counts.py` recomputes every count the README states from the tree and names the one that is wrong.
- A permission entry that is wrong or dangerous, with the command that showed it.

## Pull requests I do not take

- New skills, agents or commands. Publish them as a plugin on your own marketplace; the companion plugins are on the `hov` marketplace this repository serves, `StartupBros-com/hov-stack`.
- Machine-specific config: model pins, API gateways, status lines, units, paths that only exist on your machine.
- Style rewrites of the rules file. Every line in it paid rent through a refusal or a bad run; a change needs the run that motivates it.

## Before you open one

Run the same checks CI runs. CI installs Node 22, ripgrep, gawk, PyYAML, Python's venv and minisign before the suites, so have them locally too:

```bash
bash tests/repo/setup.test.sh
bash tests/repo/layout.test.sh
bash hooks/tests/run.sh
bash tests/repo/run-claude-tests.test.sh
bash tests/run-claude-tests.sh
bash scripts/public-safety-scan.sh   # the working tree; --rev HEAD scans the commit instead
```

Keep the PR to one change. Say in the body what broke and how the test shows it is fixed. Secrets never go in a PR; `gitleaks` runs on every push and the allowlist in `.gitleaks.toml` covers only the test fixtures. Neither does a home-directory path, a personal address, a private-network host or a private repository name: `scripts/public-safety-scan.sh` runs on every push, and the rare exception needs a row in `.public-safety-allow` that says why.

## Issues

Open an issue for anything the README promises that did not happen on your machine. Say the OS, the Claude Code version and what `./setup` printed.
