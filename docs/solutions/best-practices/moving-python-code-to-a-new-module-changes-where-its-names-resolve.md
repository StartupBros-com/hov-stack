---
title: "Moving Python code to a new module changes where its names resolve, even when the tests stay green"
date: "2026-11-19"
category: best-practices
module: python-code-extraction
problem_type: best_practice
component: development_workflow
severity: medium
applies_when:
  - "Moving a function, method or helper out of a Python module into a new sibling module, support file or mixin"
  - "Tests or callers override names on the original module (mock.patch targets, module attribute assignment, shadowed builtins)"
  - "A sibling helper is imported by bare name from a directory that another installed copy or test layout can also put on sys.path"
  - "Turning a direct call into a callback or wrapper as part of the move"
  - "Deciding whether passing the selected test suites proves an extraction preserved behavior"
tags:
  - python
  - refactor
  - module-extraction
  - name-resolution
  - monkeypatch
  - import-shadowing
  - pickle
  - unittest
---

# Moving Python code to a new module changes where its names resolve, even when the tests stay green

## Context

Issue #770 assessed whether a wave of large hov-stack files could be split without changing
behavior. Python extractions were tried as disposable patches against `bin/firecrawl_cli.py`,
`bin/papercut.py` with `plugins/papercut/papercut/cli.py`, `scripts/memory-audit.py`, three
harness-optimizer test runners (`run_native.py`, `run_behavioral.py`, `test_native_launch.py`) and
three test files (`tests/test_papercut.py`, `tests/test_memory_audit.py`,
`tests/test_reclaim_sweep.py`). Every extraction passed its selected suites. Every one still changed
observable behavior, and none shipped.

The cause is one Python rule. A function looks up a free name in `func.__globals__`, the namespace
of the module where its `def` ran, and then in that module's builtins. Where a name resolves is part
of a function's behavior, and moving the code moves it. No existing test happened to exercise the
difference, which is why the suites stayed green. The four shapes below were reproduced in #770. A
minimal standalone demo on Python 3.12 reproduced each one again before this was written.

## Guidance

### 1. Overrides on the old module stop reaching moved code

`result_sequence` (plugins/harness-optimizer/tests/run_native.py:1106) calls `enumerate` (line 1126),
`any` (line 1221) and `len` (line 1293). Moved into a helper module, it reads those names from the
helper. Replacing `run_native.any` during a call made the original raise. The moved copy never called
the replacement and returned a normal result. The same shape turned up in four more places:

- the Firecrawl validator's `getattr`
- the papercut signal helper's `str`
- `len` in the native-launch planted data, where an override gave 9,876 attempts on the original and 1 on the moved copy
- `all`, `any` and `len` in the behavioral measurement oracle

```python
# before: owner.py
def count(xs):
    return len(xs)

# after: owner.py re-exports it from helper.py
from helper import count

owner.len = lambda xs: 99      # or mock.patch("owner.len", create=True)
owner.count([1])               # 99 before the move, 1 after it
```

Forwarding a named list of dependencies does not close this. The Firecrawl candidate's second
version threaded 12 named dependencies through getters and passed 48 removal and fallback controls
across them. A `getattr` override on the original module was still ignored, because builtins and
every unlisted global keep resolving in the new module.

Before moving a function, list the names it reads: `co_names` of its code object, recursively
through nested code objects. Then decide, name by name, whether anything patches or overrides it on
the old module. Either move those patch targets on purpose, as a stated behavior change, or leave
the function where it is. An inventory is not coverage. In #770 the static inventory held 83
function/name pairs, and runtime override challenges reached 9 of them.

Rejected repair: rebuilding the helper's function against the old module's globals, as in
`types.FunctionType(helper.f.__code__, globals(), ...)`. It restored the tested lookups. But the
"extracted" module then no longer owns its code, since its body still depends on the runner's
namespace, and tracebacks gain an extra frame. That is relocation, not decomposition.

### 2. A bare sibling import can bind a different copy

`import helper` returns `sys.modules["helper"]` whenever anything has already imported that name,
whichever file sits next to the importer. The earlier import can come from another installed copy
of the plugin, a second test layout, or an earlier `sys.path` entry. In #770, a preloaded copy of the
native result helper took precedence over the intact adjacent file and changed `result_sequence([])`.
The planted-data and memory-index helpers showed the same override.

Load the resolved sibling by path to select the right source:

```python
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

path = Path(__file__).resolve().with_name("native_event_sequence.py")
spec = spec_from_file_location("_native_event_sequence", path)
helper = module_from_spec(spec)
spec.loader.exec_module(helper)
```

This fixes which file runs, nothing more. The helper keeps its own globals, so point 1 still
applies. Each owner that loads it gets a separate module object. A module under a private name that
is not in `sys.modules` also cannot be imported back by `pickle` (point 4).

### 3. Wrapping a call in a lambda moves when the callee is looked up

In `revision(before[key])` (plugins/harness-optimizer/tests/run_behavioral.py:240), Python looks up
the module-level `revision` (run_behavioral.py:188) before it evaluates `before[key]`. The oracle
extraction instead passed `lambda files: revision(files)` to a helper that runs
`callback(before[key])`. Now the argument is evaluated first, and `revision` is looked up afterward.
A valid dict subclass whose `__getitem__` rebinds `revision` shows the difference: the original
called the first function and the candidate called the second. Plain dicts and every existing test
agree, and the final diagnostics were identical. Equal outputs did not mean equal effects.

### 4. Test methods moved into a mixin or support module change identity

- **Pickling.** Functions pickle by module plus qualified name. The papercut classifier tests moved
  into a mixin loaded with `spec_from_file_location("_papercut_classifier_support", ...)`. In both the
  root and plugin copies, all 12 inherited methods then raised `PicklingError`, because their
  `__module__` named a module `pickle` cannot import. Test selectors and pass counts did not change.
- **Qualified selection.** The memory-audit test module came to import its support file by bare
  name (`import memory_cited_enforcer_test_support`). Run from the repo root with no `PYTHONPATH`,
  `python -m unittest tests.test_memory_audit` then raised `ModuleNotFoundError`, because `tests/`
  is not on `sys.path`. That failure appeared only after the extraction.
- **Copied bindings.** A `bind(globals())` helper copied six names out of
  `tests/test_reclaim_sweep.py` into the support module. Rebinding or deleting the original
  `_patched` (tests/test_reclaim_sweep.py:138) afterward no longer reached the moved code. In
  memory-audit, a moved `setUp` likewise ignored a rebinding of the original module's `tempfile`.
- **Metadata.** `__qualname__`, `__module__` and docstrings change as well. A comparison that checks
  only the last component of a qualified name hides this.

An alternative worth testing, not yet proven: keep concrete test methods on the original class and
have them forward to support functions. The method objects and setup then stay with their owner.

## Why This Matters

A passing suite proves only the behaviors it exercises, and these differences sit exactly where
nobody has a test yet. They surface the first time someone adds `mock.patch("run_native.len")`,
installs a second copy of a plugin, selects a test by its qualified name in a bare environment, or
serializes a test callable. The refactor that caused them will be long merged by then. Each one
ships behind a green CI run, so they stay invisible to review that trusts the suite.

## When to Apply

- Proposing or reviewing an "extract to a helper, support module or mixin" change to Python code in
  this repo
- Judging a refactor whose only evidence of safety is that the existing suites pass
- Choosing a split boundary: a function that many tests patch on its owner is a poor candidate to
  move, whatever its length

## Examples

Inventory the global names a function reads. It over-approximates, because attribute names land in
`co_names` too.

```python
import types

import run_native   # plugins/harness-optimizer/tests on sys.path

def global_names(code):
    names = set(code.co_names)
    for const in code.co_consts:
        if isinstance(const, types.CodeType):
            names |= global_names(const)
    return names

global_names(run_native.result_sequence.__code__)   # includes "enumerate", "any", "len"
```

Then challenge each name the moved code may read, and run the same call against the original and
the candidate:

```python
from unittest import mock

with mock.patch.object(run_native, "any", side_effect=RuntimeError("owner lookup"), create=True):
    run_native.result_sequence(events)   # the original raises; a moved copy that ignores the owner does not
```

Whatever the inventory found that the challenge did not reach, report as not demonstrated. Do not
count it as covered.

## Related

- [capture-payload-through-stub-seam-to-prove-refactor-safe](capture-payload-through-stub-seam-to-prove-refactor-safe.md)
  shows how to prove one component's output is byte-identical across a refactor. This learning
  covers what that kind of proof and a green suite miss in Python code moves: name resolution,
  import selection and callable identity.
- [verify-parity-claims-by-exercising-both-sides](verify-parity-claims-by-exercising-both-sides.md)
  covers the same principle of running both sides rather than trusting a description.
- Issue #770, the decomposition assessment these counterexamples came from. Its recommendation is
  not to adopt the tested extractions.
