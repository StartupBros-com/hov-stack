---
title: "A grepped implementation string in a test is a caller a rename sweep never sees"
date: "2026-09-10"
category: best-practices
module: harness-installer-test-anchors
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "A test locates a fact by grepping the source for an exact implementation string, then asserts on the line number it gets back"
  - "Renaming a loop variable, flag, function signature, or any other code fragment that a test may pin as a literal"
  - "A CI failure names a property violation in a test file the triggering change never opened"
  - "Deciding which suites to run locally before pushing a rename, when the rename looks confined to one file"
related_components:
  - "tests/wacli-install.test.sh"
  - "tests/sync-install-smoke.test.sh"
  - "sync.sh"
tags:
  - test-anchors
  - hidden-caller
  - rename-sweep
  - line-number-anchor
  - compound-assertion
  - false-accusation
  - ci-triage
  - bash-tests

---

# A grepped implementation string in a test is a caller a rename sweep never sees

## Context

`tests/wacli-install.test.sh` pins the installer lifecycle — preflight, then the guard hook, then the binary, then the unit copy — by grepping the source for five exact strings and comparing the line numbers it gets back (`tests/wacli-install.test.sh:402`-`406`). One of them located the unit-copy loop:

```bash
unit_line=$(grep -nF "for u in \$UNITS; do" "$REPO/sync.sh" | awk -F: -v after="$wacli_line" '$1 > after { print $1; exit }')
```

PR #1096 added workstation-scoped cass unit selection, which renamed that loop to iterate `$SELECTED_UNITS` instead. The grep stopped matching, `unit_line` came back empty, and the suite reported:

```
FAIL: install lifecycle is not preflight -> hook -> binary -> unit
```

The ordering was fine. Nothing about the lifecycle had moved. The test failed because one of its five locators had died, and it said so in the vocabulary of the property it could no longer check.

Three details make this worth writing down rather than filing as a typo.

**The rename looked safe by every normal check.** `UNITS` was not deleted — it is still the variable holding the unit inventory (`sync.sh:142`), and `SELECTED_UNITS=$UNITS` (`sync.sh:147`) is what the role-scoped selection narrows. So a symbol search for `UNITS` returns plenty of live, correct hits. Only a search for the *exact loop literal* `for u in $UNITS; do` would have surfaced the dead anchor, and that literal is not an identifier anyone thinks to grep.

**The coupling lives in a file the change never opened.** `tests/wacli-install.test.sh` does not source `sync.sh`, call into it, or import anything from it. Its entire dependency on the rename is a string argument to `grep -nF`. A reviewer scoping "what does this PR touch" never lands there, and neither does a caller sweep that scopes to code referencing the identifier.

**The failure accused the wrong thing.** The compound guard at `tests/wacli-install.test.sh:410`-`418` ANDs five anchor-resolved checks, two shebang checks, a workflow-call count, and three ordering comparisons, then routes every possible failure to one `bad` message. An empty `unit_line` fails the `[ -n "$unit_line" ]` clause and short-circuits past the `-lt` comparisons into the same `else` a genuine ordering regression would reach. From the output alone, a dead anchor and a real lifecycle break are indistinguishable — so the next reader goes hunting through `install.sh` and `sync.sh` call ordering for a regression that was never there.

This is not a one-off. The repo currently holds eight such anchors: five in `tests/wacli-install.test.sh:402`-`406` and three in `tests/sync-install-smoke.test.sh:1657`-`1659`, the latter pinning `ExecCondition=` lines in a unit file. Every one is exposed to the same rot.

## Guidance

### Sweep tests for the literal, not the identifier

Before renaming a code fragment, grep the test tree for the exact string, not just the symbol:

```bash
rg -F 'for u in $UNITS; do' tests/
```

The usual "grep every caller before editing" habit scopes to things that reference the identifier — call sites, imports, sourcing. A test that pins behavior by string match is a caller too, one hop down, legible only to a search for the same literal. When the identifier survives the rename in other roles (as `UNITS` did here), searching for the identifier actively misleads: it returns hits, they all look fine, and the dead one is not among them.

### Give anchor resolution its own assertion and its own message

Split "the anchor resolved" from "the property holds" so a stale anchor names itself instead of blaming the property:

```bash
if [ -n "$preflight_line" ] && [ -n "$harness_line" ] && [ -n "$guard_line" ] \
   && [ -n "$wacli_line" ] && [ -n "$unit_line" ]; then
  ok
else
  bad "a lifecycle anchor no longer matches sync.sh/install.sh — a pinned literal was probably renamed"
fi

if [ "$preflight_line" -lt "$harness_line" ] \
   && [ "$guard_line" -lt "$wacli_line" ] && [ "$wacli_line" -lt "$unit_line" ]; then
  ok
else
  bad "install lifecycle is not preflight -> hook -> binary -> unit"
fi
```

The ordering block is only meaningful once every anchor resolved, so checking resolution first is also the correct evaluation order, not merely a nicer message.

### A relevance-filtered local run cannot catch this

The whole point is that the coupled test lives somewhere the change has no reason to touch. `tests/wacli-install.test.sh` was not in PR #1096's edit loop and was not in the local verification script assembled for it; it passed locally by never running, and failed the moment CI ran the suites the branch does not own. Before pushing a rename, run the suites that pin structure, not the subset that looks related.

### Read each failure in a multi-failure CI run separately

The same run failed three suites, and the three had nothing in common: this anchor rot; `tests/cass-index-unit.test.sh` failing because `systemd-analyze --user verify` needs an `XDG_RUNTIME_DIR` a CI runner does not provide (a host gap misreported as a unit defect, fixed by having the suite create its own at `tests/cass-index-unit.test.sh:16`); and `tests/unit-path-coverage.test.sh` catching a genuine contract violation, a new managed-path service with no `Environment=PATH`. Two of the three failure messages pointed away from their actual causes. A single "fix the CI break" framing would have found one and papered over the others.

## Why This Matters

The cost is not the one-line fix — it is the search the message sends you on. A test that says the install lifecycle is broken is making a specific, alarming claim about ordering in production installer code, and the honest response is to go read that code. Here that search was guaranteed to come up empty, because the only thing that changed was a string the test uses to find its way around.

There is a second cost that compounds. These anchors encode a real invariant that nothing else checks — that the binary is published and verified before user units are copied. An anchor that rots into a permanently-red or hand-waved assertion is an invariant quietly going unguarded. Eight anchors currently carry that weight across two files.

## When to Apply

- Renaming any code fragment — a loop variable, a flag, a signature, a directive — in a file that structural tests read as text rather than execute. Sweep the test tree for the literal first.
- Writing a new test that locates something by `grep -nF` and asserts on the line number. Give anchor resolution its own assertion before you write the property assertion that consumes it.
- Triaging a CI failure that names a property in a file the change never opened. Check whether the test's locators still resolve before you go looking for the property violation it claims.
- Choosing what to run locally before pushing a rename that "only touches one file."

## Related

- [make-test-assertions-falsifiable-by-the-defect-they-guard](make-test-assertions-falsifiable-by-the-defect-they-guard.md) —
  the closest sibling, and worth reading alongside this one. Its Trap 2 is the
  same underlying rule seen from the other side: several refusal paths sharing
  one `exit 2` meant a guard could pass for the wrong reason, and the fix was to
  assert each branch's own message. That doc covers the false-PASS direction
  (an assertion that cannot go red); this one covers the false-FAIL direction
  (an assertion that goes red and names the wrong cause). Kept separate because
  the trigger and the sweep discipline differ — that doc is about auditing an
  assertion's failure condition, this one is about a coupling that a rename
  breaks from outside the test. If a third instance turns up, the two are a
  consolidation candidate for `ce-compound-refresh`.
- [verify-a-pagination-sentinel-is-not-a-corpus-count-before-diagnosing](verify-a-pagination-sentinel-is-not-a-corpus-count-before-diagnosing.md) —
  a structural cousin in a different domain: diagnose the instrument before
  trusting its output. There a pagination sentinel was read as a corpus count;
  here a failed grep was read as a property violation.
- issue #1065 —
  a different fragility class in this same test file, where `run_installer()`
  calls omit a fake process-root fixture and unrelated host process state can
  fail assertions before they reach their intended check. Prior art that this
  file's grounding has more than one weak seam.
- PR #1096 is where the rename, the resulting false accusation, and the fix all
  landed; the failure surfaced in that PR's own CI run and was fixed before merge.
