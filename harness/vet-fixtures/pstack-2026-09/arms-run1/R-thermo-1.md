A1 - adds new "lodash.sumby" dependency (see package.json diff) for a one-line sum that the repo's canonical `src/util/sum.ts` already covers; unjustified bespoke/duplicate dependency.
A2 - `formatCurrency` is imported from the canonical money formatter but never used anywhere in this file; a bespoke `formatMoney` (A40-42) duplicates it instead.
A11 - `IInvoiceExporter` uses the `I` prefix, which violates the stated repo convention of no `I` prefix on interfaces.
A15 - `CsvInvoiceExporter`/`IInvoiceExporter` are never used by `exportInvoices`/`buildRows` (which dispatch on a raw string instead) and there is no Tsv/Json counterpart, so this is a half-built, disconnected abstraction rather than the real dispatch mechanism.
A33 - `TsvWriter.row` does not escape tabs or newlines in cell values the way `CsvWriter.row` escapes commas/quotes, so the two `RowWriter` implementations silently honor different contracts.
A36 - `getInvoiceId` is a one-line pass-through around `invoice.id` that adds indirection without clarifying anything.
A44 - function name `computeSumOfEveryLineItemAcrossTheSelectedInvoices` is excessively verbose/non-idiomatic, and the trivial loop is over-commented (A45,A47,A49,A51-A53) explaining self-evident code.
A50 - reimplements a manual accumulation loop plus `sumBy` per-invoice instead of a single flat sum via the existing `sum()` util, duplicating logic the codebase already owns.
A61 - `format` is typed as a loose `string`; an unrecognized value silently falls back to `TsvWriter` instead of surfacing an error, hiding an implicit invariant that should be a typed union.
A64 - the try/catch wraps the entire per-invoice loop and, on any exception, swallows it (only logging) and returns whatever partial rows were built so far, silently producing an incomplete/degraded export with no signal to the caller that data was dropped.
A66 - four nested `if` statements (`invoice`, `invoice.lines`, `invoice.lines.length > 0`, `invoice.status !== "void"`) form an unnecessary pyramid that should be a single combined condition or early `continue`.
A79 - leftover `console.log("DEBUG export rows", ...)` debug statement left in production code.
A83 - `exportInvoices`'s if/else-if/else format dispatch is duplicated almost verbatim in `summarize` (A94-A103); the repeated conditional chain signals a missing shared dispatcher/map.
A94 - duplicates the same format-dispatch chain as `exportInvoices` (A83-A92) instead of sharing one implementation.
A108 - `raw as unknown as Invoice` is a double cast that fully bypasses the type system, and the function name `parseLegacyRow` implies parsing/validation that never actually happens here; nothing enforces the comment's claim that all callers pre-validate.
A112 - `eslint-disable` for `no-explicit-any` is only needed because `Invoice` isn't modeled with a `meta` field; the type boundary should be widened instead of bypassing the lint rule.
A113 - casts `invoice` to `any` to attach `meta` and mutates the caller's object in place rather than returning a new value, obscuring the real `Invoice` contract.
B17 - relies solely on a snapshot for the "csv output" case, so the new filtering (void invoices, empty `lines`) and the try/catch's error-swallowing behavior added in `buildRows` are never actually asserted; no coverage exists for `tsv`, `json`, or the unknown-format throw path either.
C10 - the `while (true)` loop has no maximum attempt count and no delay/backoff; a persistently non-ok response (e.g. a 4xx that will never succeed) causes an unbounded, immediate-retry infinite loop.
C16 - the catch block throws immediately on the very first exception instead of retrying, which directly contradicts the function's stated purpose (per the HACK comment at C3-C4) of retrying after an ECONNRESET-style thrown error.
C9 - no test coverage exists anywhere in the bundle for `fetchWithRetry`, despite it containing the infinite-loop and no-retry-on-exception defects above.