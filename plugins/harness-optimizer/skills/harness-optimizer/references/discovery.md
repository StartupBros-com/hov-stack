# Lane Discovery

## Scope and lane selection

Declare one selected scope and every lane's disposition before substantive investigation.
Explicit scope and lane selection wins. Otherwise use the unambiguous current project
or established operator scope; outside one, ask one scope question. A home directory
or tool installation does not imply global scope. Papercut-only selects only `friction`;
it is not a broad audit. Without explicit lane selection, account for all six lanes.

Launch each selected, authorized, accessible lane as a separate assignment of the
[investigator](../../../agents/harness-optimizer-investigator.md), with a fresh read-only context.
Give concrete reasons for lanes not investigated: excluded by selection, source absent,
unauthorized, inaccessible or dispatch unavailable. Source absence is not completed
investigation. Distinguish it from failed launches and unavailable dispatch.
All lanes can use supplied evidence without private infrastructure.

## Evidence lanes

The lane IDs below identify assignments, not installed plugins. Instructions and
context are distinct; repository learnings belong with memory, and CLI/automation
belongs with tooling. Anti-ceremony is cross-cutting, not a seventh lane.

| Lane           | Sources within selected scope                                                                    | Candidate routes and boundaries                                                                                                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `friction`     | Supplied failures, supported scoped friction queries, existing work/adoption records.            | Papercut or ordinary repair. Not a correction miner; investigation echoes are not organic recurrence.                                                                                                          |
| `memory`       | Named authorized notes, repository learnings, supplied corrections or completed capture outputs. | Memory-mine, memory-dream, ce-compound-refresh, or narrow memory-audit under their actual contracts. No implicit session mining, consolidation, recall evaluation or memory writes.                            |
| `instructions` | Named skills, agents and instructions; supplied task/routing evidence.                           | Skill-tuner:tune or writing guidance. No silent tuning; pruning needs retained-behavior evidence.                                                                                                              |
| `context`      | Scoped inventory and supplied loading/usage evidence.                                            | Rent-check or skill-tuner:portfolio. Low use is not removal evidence; user-only audit/apply rules persist.                                                                                                     |
| `permissions`  | Named calls and relevant permitted policy excerpts.                                              | Denial-triage or other candidates only after contract inspection. No widening; fix command defects before proposing policy changes.                                                                            |
| `tooling`      | Named tool sources/manifests, supported diagnostics and explicit repeated-work evidence.         | CLI ergonomics, harness doctor, automation handoff or external-addition vetting. No installs, activation or schedules; CLI doctor adoption remains unsupported until its documented contradiction is resolved. |

[Operation compatibility](integrations.md) remains authoritative for effective
installed contracts. Routes are candidates, not an invocation chain or compatibility
claim. Preserve public invocation and consent requirements; discovery cannot clone
restricted audit, mining or apply workflows. An operation called audit is not
automatically read-only. Where a specialist is user-only or unavailable, investigate
only independently authorized supplied evidence and state the missing coverage;
offer its required handoff rather than silently invoking it or claiming it ran.

## Assignment packet and collection defaults

Assemble the complete shared discovery packet before launching any investigator.
Supply the lane ID, selected scope, exact source handles/revisions where available,
authorized files/subtrees, allowed read boundary, lane brief and common return contract below.
Launch only fully assigned investigations: no unassigned, placeholder or probe agents,
and no replenishment calls. A fully assigned investigation may legitimately find
no useful increment; that is not a failed dispatch.
The boundary limits enumeration/search as well as file reads: direct-read named files,
scope Glob/Grep to authorized sources, and never broaden then filter. Missing sources
do not authorize searching outside scope. Include relevant
evidence only, not other lanes' histories. The investigator has Read/Glob/Grep only;
the coordinator obtains necessary CLI evidence through supported read operations
and supplies bounded packets. Read the selected operation's contract first. Targeted
scripts may answer scoped hypotheses, but must not replace orchestration or expand sources.
When supplied sources leave a named question unanswered, use supported public operations
and bundled collectors for routine collection.
Only when those surfaces cannot answer the named hypothesis, state the question,
bounded inputs, expected output and limits before writing a temporary diagnostic
script. Exclude unselected histories, refused operations, orchestration replacement,
restricted-specialist reimplementation or a new consent store. Repeated useful
collectors become separately tested helper candidates, not automatic additions.

Choose the smallest sufficient authorized source batch per lane to test the
claim and a plausible refutation. Use supplied authoritative sources before broader diagnostics;
expand collection only for a named unanswered question within the authorized boundary.
Keep one declared source batch per lane. For otherwise unbounded supplied sources,
use at most 20 named files or 100 event records; these are ceilings, not collection targets.
Select and declare the applicable source boundary, rather than treating both as additive quotas.
The friction default window is the latest 7 days. Smaller specialist bounds win.
Declare sampling and omissions before collection. Coverage is not exhaustive by
default; stop at the batch boundary even when more sources exist.

## Common return

Four required fields:

- `lane`: the assigned lane ID.
- `status`: `complete` when the declared batch was inspected; `partial` when some
  usable evidence was inspected but coverage or return is incomplete; `unavailable`
  when authorized sources or dispatch cannot be accessed; `failed` when a launched
  attempt fails. Explain the specific cause in coverage. The coordinator records
  unavailable dispatch and launch failures when the investigator cannot return.
- `coverage`: actual sources, revision, window, sample boundary, omissions and reasons.
  Preserve producing operation/source identity in these existing packet/coverage fields
  when needed to reproduce a measurement. State which checks actually ran and which
  sources were absent or inaccessible.
  Completion refers only to that declared boundary, never to the whole backlog.
- `findings`: zero to three candidates; an empty list is valid with supported coverage.

Each candidate contains a bounded claim, target, evidence locators/provenance,
causal hypothesis or uncertainty, and a refuting observation; expected behavioral benefit,
recurrence/exposure when known, and existing work references when found. No invented
patch, global priority or callability. Preserve origin event IDs or source locator plus version/time.
Distinguish operator corrections, execution friction, investigation-generated evidence
and synthetic fixtures. Return summaries/locators only, not private bodies or secrets.

The coordinator checks lane identity, required fields, bounds and evidence locators
against the packet. Malformed is not successful empty: mark the return failed, name
the defect and do not admit its candidates as validated findings. Empty findings
require actual coverage, not fabricated success. Supported partial candidates may
be used with omissions visible. Over-limit returns are partial: retain at most three
candidates in supplied order, disclose truncation and do not claim extras examined.

## Discovery launch budget

Declare a discovery budget separate from repairs and review: at most 6 launched investigators,
one per active lane. A launched failure consumes an attempt; no same-batch redispatch.
Do not replenish the discovery budget by opening another batch. Capacity rejection
before launch remains queued, not successful; when supported capacity cannot recover, record
eventual unavailability explicitly. Never silently substitute coordinator-only
investigation for a missing fresh lane context.

Host cancellation and limits govern actual execution. These are prompt-defined
bounds, not hard runtime enforcement; report interruptions and incomplete coverage.
The existing collection barrier and subsequent selection/review flow retain their
own limits (at most 3 selected families and 18 reviewer attempts); discovery does
not spend or enlarge those budgets. Six lanes with at most three candidates each
allow at most 18 candidates before deduplication. The combined ceiling of
24 discovery-plus-review attempts is not a total model-call or billing ceiling;
coordinator turns, tool use and authorized specialist work are separate.

## Collection barrier and central reconciliation

Freeze the selected-lane packets before launch. Launch independent lanes together
within host capacity; queue the remainder rather than substituting coordinator
investigation. Collect all launched terminal results or explicit failures/unavailability
before ranking or selecting families.
Account for every selected lane, including queued lanes that became unavailable;
apply the return checks above and disclose partial/nonexhaustive coverage. A fast
or convenient first source cannot select the batch while other lanes are pending.

Reconcile centrally in two passes:

1. **Origin events.** The same origin event cited by multiple lanes counts once.
   Preserve the shared event ID or source/version/time mapping; multiple reports
   are not independent recurrence. For example, one malformed invocation appearing
   in friction and permissions is one event and one causal family when both trace
   the same command defect, not a reason to widen permissions. Uncertain event
   identity stays uncertain rather than inflating recurrence.
2. **Causes.** Merge only findings with the same mechanism and repair boundary;
   filename or word similarity is insufficient. Preserve competing explanations
   and refuting observations. Attach findings to known work rather than creating
   duplicate repairs or issues; existing declines and pending decisions carry on.

## Importance, readiness and provisional selection

Rank correctness/data-loss and blocked eligible work first, then evidence strength,
organic recurrence/exposure and expected benefit versus regression risk and effort.
No fabricated scores. Harmless high-volume telemetry does not automatically outrank
a reproduced failure; missing recurrence does not erase a single reproduced
correctness defect. Explain ordering from observed evidence and uncertainty.

Classify readiness separately: ready / concrete human decision /
unsupported-or-insufficiently-evidenced. Name the missing invocation, patch-specific
decision, supported operation or evidence, without lowering the finding's importance.
Continue independent ready work while a more important family is blocked; retain
all higher-priority blocked findings and every known pending/declined concrete
decision in the remainder when not selected. Include reasons for other deferrals
and unavailable lanes so the report cannot imply exhaustive coverage.

Propose at most three causal families, or the operator's smaller limit, for the
existing diagnosis checkpoint. Selection is provisional until objections are
reconciled and the reviewed batch is accepted. Send deduplicated evidence, coverage,
selection reasons and remainder, not all raw records. There is no replenishment
after batch acceptance; later findings belong in the remainder. An inspected
no-useful-increment conclusion still gets applicable diagnosis review; no inspectable
evidence makes it inapplicable, not passed. Read [checkpoints](checkpoints.md) for
review roles and applicability, then return to the skill's supported preparation,
application and outcome flow. No per-lane reviews or replacement execution engine.
