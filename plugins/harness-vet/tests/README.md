# Scope decision fixtures

[`scope_cases.json`](scope_cases.json) contains thirteen independent behavioral
fixtures for the v0.2.0 through v0.3.0 scope decisions in
[`SKILL.md`](../skills/harness-vet/SKILL.md),
[`DIGEST.md`](../skills/harness-vet/DIGEST.md),
[`EVIDENCE.md`](../skills/harness-vet/EVIDENCE.md) and
[`VERDICTS.md`](../skills/harness-vet/VERDICTS.md).

The v0.2.0 single-run decision smoke passed its eight cases with independent
semantic review; the prior rejected draft failed its negative control. See
[final responses](scope-smoke-final.json) and [initial strict-score failures](scope-smoke-results.json).
The four surviving v0.2.1 cases (the candidate's own copy at another scope, a
target's first instruction surface, an unmeasured tool-heavy MCP server, a
skill pack with operator-named skills) plus the eight v0.2.0 cases were run
against the v0.2.1 files; v0.2.2 removed a fifth, an unlicensed verbatim copy,
together with the licence rule it tested. v0.3.0 adds a thirteenth case, a
discovered contender slated with no incumbent, whose planted wrong answer
is SKIP-as-covered. The case itself has had structural validation only, no
fresh-model smoke, as of this revision. The protocol path it encodes has run
once live, in [#25](https://github.com/StartupBros-com/harness-vet/issues/25):
a vet of jakubkrehel/skills `teardown` under the v0.3.0 text, where discovery
slated two contenders with no incumbent and phase 4 ran bare, the candidate and
both contenders as isolated arms, three runs each, under a both-order judge.
That run ended SKIP because the candidate lost every representative-task pair
to bare, not SKIP-as-covered, so it never faced the case's choice between ADOPT
and SKIP-as-covered. It shows the path runs end to end on a real candidate; it
is not a smoke of the case. See
[the v0.2.1 receipt](scope-smoke-v0.2.1.json) and [VERIFICATION.md](VERIFICATION.md).
Their scenarios stipulate synthetic observations so a model can make a decision
without external access. Statements that a scenario's runtime checks passed
are inputs to that hypothetical case, not claims that this repository task ran
those checks. Structural validation does not establish correct model behavior,
an estate dry run, runtime isolation or a deployed release.

Each case has an `id`, a plain-text `scenario`, an `expected` array of
`{target, verdict}` pairs and a `forbidden_claims` array. Targets are `project-a`,
`project-b`, `global` or `unresolved`; verdicts are `ADOPT`, `ADAPT`, `EXTRACT`,
`SKIP` or `REJECT`. The `expected` pairs are the required recommendations, not
permission to install. For the unresolved case, `SKIP` means pending evidence
and requires an observable retry condition. The forbidden claims describe
semantic errors; they are not strings to match mechanically.

## Structural validation

Run this from the repository root with Node.js already available. It needs no
package installation, external access, test engine or CI configuration. It
checks JSON parsing, schema version and fields, exactly thirteen cases, unique
nonempty IDs, nonempty scenarios and expected arrays, valid targets and
verdicts, and nonempty forbidden-claim strings.

```sh
node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const fixture = JSON.parse(readFileSync('tests/scope_cases.json', 'utf8'));
const fields = (value, expected) => {
  assert(value && typeof value === 'object' && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort());
};
const nonempty = (value) => typeof value === 'string' && value.trim().length > 0;
const targets = new Set(['project-a', 'project-b', 'global', 'unresolved']);
const verdicts = new Set(['ADOPT', 'ADAPT', 'EXTRACT', 'SKIP', 'REJECT']);
const ids = new Set();

fields(fixture, ['schema_version', 'cases']);
assert.equal(fixture.schema_version, 1);
assert(Array.isArray(fixture.cases));
assert.equal(fixture.cases.length, 13);
for (const item of fixture.cases) {
  fields(item, ['id', 'scenario', 'expected', 'forbidden_claims']);
  assert(nonempty(item.id));
  assert(!ids.has(item.id), `Duplicate case ID: ${item.id}`);
  ids.add(item.id);
  assert(nonempty(item.scenario), `Empty scenario: ${item.id}`);
  assert(Array.isArray(item.expected) && item.expected.length > 0);
  const seenTargets = new Set();
  for (const row of item.expected) {
    fields(row, ['target', 'verdict']);
    assert(targets.has(row.target), `Invalid target: ${item.id}`);
    assert(verdicts.has(row.verdict), `Invalid verdict: ${item.id}`);
    assert(!seenTargets.has(row.target), `Duplicate target: ${item.id}`);
    seenTargets.add(row.target);
  }
  assert(Array.isArray(item.forbidden_claims) && item.forbidden_claims.length > 0);
  assert(item.forbidden_claims.every(nonempty));
}
console.log(`Validated structure of ${fixture.cases.length} scope cases; no behavioral evaluation run.`);
NODE
```

## Behavioral evaluation with a fresh model

1. Select one case locally. Start a fresh model session with the current four
   skill documents linked above and the neutral prompt below. Supply only that
   case's `scenario` text. Withhold `expected`, `forbidden_claims`, the case ID
   and every other case from the model under evaluation; do not attach the
   fixture file or give it access to the answer key.
2. Ask for a report-only hypothetical decision. Treat the supplied observations
   as established case facts. Do not invoke tools, fetch sources, install the
   candidate or ask the model to manufacture command outputs. A scenario's
   verified observations may support its recommendation, but the model must
   not claim to have performed them itself.
3. Save the response before a separate reviewer receives that case's
   `expected` pairs and `forbidden_claims`. The reviewer checks every requested
   target, the reasoning and any additional recommendations. Merely discussing
   the historical global SKIP is allowed; proposing a global installation in a
   project-only case is not. Check forbidden claims by meaning, including
   unsupported implications, rather than exact wording.
4. Repeat in a fresh session for each case. Keep model version, supplied skill
   revision, settings and prompt consistent, and record actual responses and
   reviewer findings. If comparing skill revisions, use matched conditions and
   repeated runs before claiming an improvement. Report cases actually run,
   failures and omissions separately from structural validation.

Neutral prompt to accompany the four skill documents and one scenario:

```text
Apply the supplied harness-vet method to the hypothetical scenario below.
Treat its stated observations as established facts for this case. Return exactly one
final rollup row per target the scenario asks about, using canonical target IDs
project-a/project-b/global, or unresolved when no destination is defensible.
Put component and delivery sub-verdicts, prior verdicts and the state of any
other scope in the explanation, not in extra rollup rows. Explain the verdict, shared artifact findings versus target
fit, placement, activation and any required packaging change. State evidence
limits and the relevant retry or review conditions; include provenance,
update and rollback requirements when proposing adoption or adaptation.
Do not use tools or perform installations. Do not claim that you ran the
scenario's checks or that a recommendation has been implemented.

Scenario:
<paste only the selected scenario text here>
```

An eventual behavioral result measures decision behavior on these supplied
facts. Actual adoption still requires the current skill's artifact inspection,
target-task evidence, price checks and fresh target/control runtime checks;
fixture answers cannot establish those real-world results.
