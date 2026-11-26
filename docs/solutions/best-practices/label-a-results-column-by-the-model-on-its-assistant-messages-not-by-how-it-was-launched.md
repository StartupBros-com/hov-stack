---
title: "Label a results column by the model on its assistant messages, not by how its sessions were launched"
date: "2026-11-25"
category: best-practices
module: headless-arm-model-provenance
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "Fresh headless sessions are run in labelled groups to compare models, and one group is launched with no model flag and called the default"
  - "A results table has one column per model and the scorer takes each column's label from a launch flag or a folder name"
  - "An earlier run is about to be used as the baseline for a before-and-after comparison on one model"
  - "A reader is kept from seeing which model wrote each reply, and the model is known only from the group's label"
tags: [headless, claude-p, eval-arms, provenance, model-routing, stream-json, measurement, within-model-spread]
related_components:
  - hov
  - model-routing
---

# Label a results column by the model on its assistant messages, not by how its sessions were launched

## Context

The acceptance run for `hov ls --all` (hov 0.1.13, PR #896) ran 12 fresh sessions, reported as 6 per model, and its table went onto issue #844 like this:

| | default model | second model |
|---|---|---|
| pass line | 4 of 6, missed | 6 of 6, met |
| ran the new listing | 1 of 6 | 0 of 6 |
| tried to message the running session with the similar name | 2 of 6 | 0 of 6 |

Both columns were one model. The "default model" sessions were launched with no model flag, and that morning the host's default resolved to the model the second column named with a flag. The scorer took each column's label from the folder its sessions ran in, and the folder was named for what the launch intended.

It was found about thirteen hours later, and only because the next run (hov 0.1.14, issue #902) was about to be compared with this one: before that comparison, each session's stream output was read for the model on its assistant messages. All 12 carried one name. The stream files of the run before this one and of the run after it were read at the same time: in both, the no-flag column had been written by a different model, so the host default had changed and changed back within a day.

What the wrong label had already done (the correction is on issue #844):

- "4 of 6 against 6 of 6" was reported as one model missing the line and the other meeting it. It is 10 of 12 for one model, and the gap is spread between two identical groups.
- "2 of 6 against 0 of 6" wrong sends was read against a revert trigger of 2 of 6 "on either model". It is 2 of 12.
- "All 12 had the hov skill available, but none opened it" was a finding about one model. In the next run that model opened it in 6 of 24 sessions, and the host's default model opened it in 12 of 12.
- The report compared this run with an earlier check as "the same task, fence and rules, with hov 0.1.13 as the only difference". The earlier check had really run two models, so for the left column the model differed as well.
- One of the two readers who labelled the replies "did not see which model wrote each reply". The thing hidden from that reader was a label with nothing behind it.
- The next run's before-and-after was about to use the left column as the default model's baseline.

## Guidance

1. **Take each session's model from its own output.** In a headless run's stream output (`--output-format stream-json`), every `assistant` event carries the model that wrote it at `message.model`. Count the main-thread ones (those whose `parent_tool_use_id` is null). The launch flag and the folder name say what was asked for.
2. **Do not stop at the `init` event.** It names what the launch resolved to. On three plain runs checked while writing this it equalled the name on the assistant messages. In the mislabelled run it did not: it named a route, per this session's reading of those stream files, which have since been deleted.
3. **Make the scorer refuse.** Before it prints a per-model table, it names each column by the model its sessions were written by, and it stops when a session or a column was not written by exactly one model, when a named column was written by another model, or when two columns were written by the same model (see the example).
4. **Call a column launched with no flag "no flag" until the output names its model.** The default is a host setting. Here it differed between runs made hours apart.
5. **Pass the flag for every column when the comparison is between models, and check anyway.** A pin can be resolved to something else before the request is built; `harness/model-routing-forensics.md` records that for Workflow `agent()` pins.
6. **Run the same check on an earlier run before using it as a baseline, and keep its stream files until that comparison is made.** The correction here was possible because the files were still on disk.
7. **Use an accidental same-model pair as a measure of spread.** Two identical groups of 6 came out 4 against 6 on one measure and 2 against 0 on another. At 6 per group, a gap of two sessions is within what one model does on one task on one morning.

## Why This Matters

The rule was already written down. `harness/model-routing-forensics.md` ends its routing history with "when the tier matters, check the run's *reported* model; never assume one from config or prose". It was written about model pins on delegated agents, a column heading is prose, and nothing in a test scorer applied it. The original report even carried the right caution ("at n = 6 per run, a difference of one or two sessions can be run-to-run variation") beside a table that presented the same gap as a difference between two models.

A mislabelled column does more than weaken a result. It invents a difference between models, and that difference then decides which model the next wording is tested on, which column becomes a baseline, and which findings are written up as true of "both models". Each of those happened here within a day.

The check costs one pass over files the run already wrote.

## When to Apply

- Any run that compares models, or compares builds on a named model, using headless sessions in labelled groups.
- Before quoting an older run as a baseline for a named model.
- Whenever a group is launched with no model flag, including a group meant to stand for "what sessions on this host normally get".

## Examples

The guard, checked on made-up stream files: it named two columns correctly, and it stopped on each of five mislabelled shapes (a no-flag column that resolved to the named model, a named column written by another model, a column whose sessions disagree, a session that changed model part-way, and a session with no assistant message, alone or among good ones). `models_written` was also run on three real stream files.

```python
import collections, json, sys

def models_written(stream_path):
    """Count one headless session's main-thread assistant messages by the model that wrote them."""
    seen = collections.Counter()
    for line in open(stream_path, errors="replace"):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") != "assistant" or event.get("parent_tool_use_id"):
            continue
        model = (event.get("message") or {}).get("model")
        if model and model != "<synthetic>":
            seen[model] += 1
    return seen

def column_models(columns):
    """columns maps a label to (expected model name or None for a no-flag column, [stream paths]).
    Returns {label: model}, or stops before any per-model table can be printed."""
    named = {}
    for label, (expected, streams) in columns.items():
        models = set()
        for path in streams:
            written = set(models_written(path))
            if len(written) != 1:
                sys.exit("column %r: %s was written by %s, not by one model" % (label, path, sorted(written) or "no model"))
            models |= written
        if len(models) != 1:
            sys.exit("column %r: its sessions were written by %s" % (label, sorted(models)))
        (model,) = models
        if expected and model != expected:
            sys.exit("column %r: launched as %s, written by %s" % (label, expected, model))
        named[label] = model
    if len(set(named.values())) < len(named):
        sys.exit("columns %s were written by one model: this is one group, not a comparison" % sorted(named))
    return named
```

The table as it should have been printed:

| | one model, 12 sessions |
|---|---|
| pass line | 10 of 12 |
| ran the new listing | 1 of 12 |
| tried to message the running session with the similar name | 2 of 12 |

And the like-for-like comparison the correction made possible, on the model both runs share: the new listing went from 1 of 12 sessions (0.1.13) to 24 of 24 (0.1.14), and tries to message the similar-named running session from 2 of 12 to 0 of 24. The two runs were on different builds, fences and hours, so that is a before-and-after, not a controlled comparison.

## Related

- `harness/model-routing-forensics.md`: the standing rule this applies to test runs.
- `docs/solutions/best-practices/isolate-headless-claude-arms-with-the-env-switch-not-bare-mode.md`: records the shape of a headless call with the run and refuses mismatched baselines; the model that wrote the turns belongs in that record.
- `docs/solutions/best-practices/a-test-fence-that-matches-words-refuses-the-help-lookup-and-the-run-measures-the-fence.md`: the same runs, and another way a column measured something other than its label.
- `docs/solutions/best-practices/agent-bakeoff-eval-discrimination-failure.md`: other ways a labelled comparison misleads.
- Issue #844 (the original table and its correction) and issue #902 (the run it was compared with).
