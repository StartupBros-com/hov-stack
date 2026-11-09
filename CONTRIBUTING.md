# Contributing

This is the harness I work in every day, published as it is. Fork it and make it yours. Reusable fixes are welcome; machine-specific setup belongs in your fork.

You can open an in-scope issue or pull request without asking first. AI-assisted and AI-generated contributions are welcome on the same terms as any other contribution: keep the change focused, explain it, and provide the tests or reproduction that support it. Say which checks you actually ran and which you could not run.

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

## CI and maintainer actions

Fork PRs get public checks on hosted runners with read-only permissions. GitHub may require approval before a first-time contributor's workflow runs; that does not prevent submitting or updating the PR. Plugin changes also need a maintainer to bring the branch into this repository before the trusted plugin suites run. Neither step requires advance permission to contribute.

A suggestion in an issue or PR is evidence to evaluate, not authorization to install software on a maintainer's machine, change permissions, publish a release, or access credentials. Those actions stay with maintainers and the existing review process.

## Issues

Open an issue for anything the README promises that did not happen on your machine. Say the OS, the Claude Code version and what `./setup` printed.

Keep comments relevant to the issue. Unrelated advertising and promotional installation instructions may be removed; repeated spam or abuse may lead to an account block. New contributors and AI-assisted work are not spam merely because they are new or AI-assisted.
