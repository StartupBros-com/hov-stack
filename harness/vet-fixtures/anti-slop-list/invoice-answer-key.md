# Answer key (judge only) — ledgerly invoice code bundle

Hit = right location + right problem class. Partial (0.5) = right location, wrong or vague
reason. False accusation = a control flagged as a defect, or a defect invented that is not
planted. Unplanned observations neither credited nor penalized.

Doctrine columns: T = thermo-nuclear names it; S = code-slop names it; P = VIBE P-list or
CE persona names it. "none" = no incumbent or candidate names it explicitly.

## Planted defects (K1-K18)

| ID | Loc | Defect class | T | S | P |
|---|---|---|---|---|---|
| K1 | A45, A47, A49, A52 | narration comments restating the code | - | S | P11 |
| K2 | A51 | closing-brace label `} // end for` | - | S | - |
| K3 | A61-A62 | generic names `data`, `handler` | - | S | CE persona |
| K4 | A44, A46, A63 | type-in-name `invoiceArr`, `totalNumber`, `rowsArray` | - | S | - |
| K5 | A44 | over-descriptive run-on name | - | S | - |
| K6 | A11-A19 | premature interface `IInvoiceExporter` with one impl, `I` prefix against repo style | T (abstraction) | S | CE Speculative Generality |
| K7 | A36-A38 | identity wrapper `getInvoiceId` | T | S | P8 |
| K8 | A64-A78 | defensive try/catch around pure in-memory loop, swallows to console.error | - | S | P1 |
| K9 | A112-A113 | `as any` + eslint-disable to bypass the type system | T | S | CE / P15 |
| K10 | A79 | debug `console.log` left in | - | S | P30 |
| K11 | B5-B13 | test mirrors the implementation (recomputes with the same loop) | - | S | - |
| K12 | B15-B19 | snapshot test standing in for a behavioral assertion | - | S | - |
| K13 | A1, A50 + package.json note | dependency creep: `lodash.sumby` added when `sum()` / `reduce` exist | - | S | ponytail ladder (CLAUDE.md "ask before reimplementing" is the inverse) |
| K14 | C9-C20 | missing real defense: unbounded `while(true)` retries, no timeout, no backoff, non-ok response loops forever | - | S (defensive-missing-real) | - |
| K15 | A66-A74 | four-level nesting that guard clauses would flatten | - | - | cursor-team-kit deslop only |
| K16 | A40-A42 | duplicate helper `formatMoney` beside canonical `formatCurrency` (repo context) | T | - | CE anchor-100 |
| K17 | A83-A103 | third mode as parallel if/else-if chains in two functions; a table or writer map is the fix | T | - | CE "intentional divergence hidden in branches" |
| K18 | A76-A77 | catch swallows and continues, so a thrown error yields a silently truncated export | - | S | P1 |

K8 and K18 share a location; credit K8 for "unneeded try/catch" and K18 for "swallowed error / truncated output". A single finding that says both earns both.

## Honest controls (H1-H8) — flagging any as a defect is a false accusation

| ID | Loc | Why it is fine |
|---|---|---|
| H1 | A5-A9 | comment explains a non-obvious invariant with a reference |
| H2 | C13-C18 | try/catch at a network boundary that rethrows with context (the *retry loop* is K14; the catch itself is fine) |
| H3 | A105-A109 | `as unknown as` with a SAFETY comment naming the validation site |
| H4 | A21-A34 | `RowWriter` interface with two real implementations |
| H5 | C3-C7 | dated HACK comment naming the upstream bug and exit condition |
| H6 | A56-A59 | long but honest, specific name |
| H7 | B21-B30 | behavioral assertions plus an empty-input edge case |
| H8 | A117-A119 | correct CSV escaping, no defect |

Note for the judge: H2 is a trap for arms that flag "every try/catch"; K14 is the real
problem in file C. An arm that flags C13-C18 as "unnecessary try/catch" gets an FA; an arm
that flags C11 or C15 for the unbounded loop / non-ok path gets K14.
