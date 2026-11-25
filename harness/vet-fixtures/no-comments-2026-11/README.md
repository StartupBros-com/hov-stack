# no-comments vet fixture (2026-11-24)

Behavioural fixture behind `docs/vets/2026-11-24-no-comments-harness-vet.md`. The rule that
decided it, with amendments A to C, each dated before the runs it governs, is `prereg.md`.

## What it is

`repo/` is `tally` 0.9.2, a synthetic Python 3 (stdlib only) package that turns a bank export
into a monthly spending digest, with visible tests and `make check` (ruff, mypy, unittest)
passing. `build-base.sh` turns it into a one-commit git repo with a fixed author and date and
refuses to finish unless the commit is `802397d6`, the base every run started from.
`repo/pyproject.toml.fixture` is the manifest under a name GitHub's dependency graph does not
read (`tests/vet-fixture-manifests.test.sh`); the build renames it.

One task (`tasks/comments.txt`), the same text for every arm:

> Clean up the code comments in this repository. Keep `make check` passing. You have my
> approval to change code and tests where that replaces a comment; I won't be around to
> answer questions.

The comments in `repo/` copy the shapes measured in the merged pull requests of the
operator's product repos (`prereg.md`, Amendment A item 4):

| Class | Items | What scores it |
|---|---|---|
| Clutter: narration, history, banners | 13 (`T*`, `H*`, `S*`) | removed or not (recall; not separating by design) |
| Decisions about this code | 14: 6 with a prepared mutant (`De1`..`De6`), 8 rationale-only (`Dr1`..`Dr8`) | the fact's outcome: kept, relocated (another comment, docstring or `.md`), enforced (a mutant that breaks it fails the arm's own checks), dissolved, or lost |
| Keep-list | 6: SPDX header (`K1`), the `noqa: E402` pair in `scripts/run_digest.py` (`K2`), two doctests (`K3`), the twitter-text length note (`K4`), the half-away-from-zero rounding note (`K5`), the byte-order-mark note (`K6`) | same outcomes as decisions |
| Suppressions hiding a real bug | 3: `noqa: B006` (`P1`), `type: ignore` (`P2`), `noqa: F841` (`P3`) | 2 = root fixed and the hidden probe passes with checks clean; 1 = status quo kept; 0 = checks fail, or the marker removed with the bug left |
| Workaround comments with a fixable cause | 3: trailing newline (`W1`), thousands separator (`W2`), MM/DD/YYYY dates (`W3`) | same 0/1/2 scale |

Primary metric: the sum over the six `P`/`W` items (max 12). Countermetric: facts lost
across the 20 decision and keep-list items. `grader/grade.py` scores a copy of each run's
repo; `grader/probes.py` and `grader/data/` are the hidden probes and stay with the grader,
outside the run root, so no arm can read them.

## Arms

`make-runs.sh` builds blinded run dirs (`<root>/runs/<random id>/`) and appends the arm map to
a file outside the run root. Arms differ only in an optional slash-command prefix
(`prefix.txt`), an optional `--plugin-dir` (`plugin.txt`) and an optional `CLAUDE.md` copied
into the run's `CLAUDE_CONFIG_DIR`. Model: `sonnet` for every arm, 3 runs each.

| Arm | Definition | Source |
|---|---|---|
| `a1-bare` | none | none |
| `a2-pstack` | `/pstack:no-comments`, plugin dir | cursor/plugins at `ca782ed8` (pstack 0.15.48), `pstack/` copied whole; not committed |
| `a3-ce` | `/compound-engineering:ce-simplify-code`, plugin dir | compound-engineering 3.38.3 as installed; not committed |
| `a4-codeslop` | `/hov-stack:code-slop`, plugin dir | `plugins/hov-stack` of this repo at `631283c5` |
| `a5-ratchet` | `/comment-ratchet:delete-comment`, plugin dir | blessedmadukoma/comment-ratchet at `15bf5460` (v1.0.0), `skills/delete-comment/SKILL.md`; not committed |
| `a6-audit` | `/comment-audit:comment-audit-skill`, plugin dir | KloutDevs/comment-audit-skill at `86e2ebdf`: `SKILL.md`, `scripts/scan-comments.sh`, `references/`; not committed |
| `a7-routing` | `/code-comments:code-comments seek-and-destroy`, plugin dir | tonanywhere/my-favorite-prompts at `a235d39d`, `skills/code-comments/`; not committed |
| `a8-extract` | `arms/a8-extract/CLAUDE.md`, no prefix, no plugin | one line written after the a2 diffs were read (Amendment C) |

Contender texts are not committed; a pin is enough to rebuild them. To rebuild the plugin
dirs, fetch each source at its pin, then run `tools/build_plugins.py` (its docstring gives the
arguments). Each `arms/*/plugin.txt` names an absolute path, `/tmp/nc-vet-0f9d/plugins/<name>`:
build the plugins there, or edit those files to point at your build.

`arms/a8-extract/CLAUDE.md` holds a rule this vet did not adopt. It is named `CLAUDE.md`
because `make-runs.sh` copies it into the run's config dir as user memory, the same
convention as `pstack-2026-11/arms/`. A session that reads files in that folder may load it
as a nested instruction file. The contenders get a minimal `.claude-plugin/plugin.json` wrapper; pstack's own
root `plugin.json` loads unchanged under `--plugin-dir` (Claude Code 2.1.331).
`tools/smoke-load.sh <scratch> <plugin-dir>` is the one-turn load check that confirmed every
slash command and pstack's `comment-sicko` agent resolve, before any arm ran.

## Running it

```bash
F=harness/vet-fixtures/no-comments-2026-11
bash $F/build-base.sh /tmp/<root>                     # prints the base commit, checks it is 802397d6
bash $F/make-runs.sh /tmp/<root> /tmp/<map>.tsv a1-bare 3 comments
bash $F/launch.sh /tmp/<root> 3                       # every run without a result.json
python3 $F/grader/grade.py /tmp/<root> /tmp/<grade>.json <run-id>...
python3 $F/tools/analyze_arms.py /tmp/<map>.tsv /tmp/<grade>.json /tmp/<root>
```

`run_arm.sh` empties the environment except `PATH` and the model-route variables (passed by
name, never written into argv), and points `HOME`, `TMPDIR`, `XDG_CONFIG_HOME`,
`XDG_CACHE_HOME` and `CLAUDE_CONFIG_DIR` inside the run dir. The route variables still reach
every command an arm runs; the note's section 2.6 records what that exposed and the fix for a
later run (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`).

## Results

- `results/map.tsv`: run id to arm, the only place the arms are named.
- `results/grade-all.json`: every run's grade, items and checks.
- `results/arm-table.txt`: `tools/analyze_arms.py` output: validity first (decided from the
  transcripts before any score is read), then per run, per arm, and the rule.
- `results/k2check.txt`: `tools/k2check.py`, the post hoc check on the keep-list script
  (section 2.4 of the note).
- `results/reference-{base,ideal,nuke}.json`: the grader on the untouched base, on a
  hand-built ideal cleanup (expected 12, 0 lost) and on a strip-every-comment variant
  (expected 3, 17 lost); `tools/reference_variants.py` rebuilds the last two.

The run dirs themselves (transcripts, diffs) were kept in scratch and are not committed.

## Placement test

`placement/` holds a second experiment on the same repo, run for the note's section 7: the same
code in seven copies that differ only in where the 14 decisions are written down. It has its
own `README.md`, `prereg.md` and `results/`.
