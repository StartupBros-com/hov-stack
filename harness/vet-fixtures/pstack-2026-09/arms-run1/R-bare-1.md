A1 - Adds a new dependency (lodash.sumby) for a single trivial reduction that the existing `src/util/sum.ts` (or a plain map+reduce) already covers.
A2 - `formatCurrency` is imported but never called; the file reimplements its own money formatting instead of reusing the canonical formatter.
A11 - `IInvoiceExporter` uses an `I` prefix, violating the repo's stated interface-naming convention.
A15 - `CsvInvoiceExporter.export` duplicates the exact CSV path already provided by `exportInvoices(..., "csv")` via `buildRows`, adding an untested, redundant public API surface.
A34 - `TsvWriter.row` does not escape tabs/newlines in cell values (unlike `CsvWriter.row`), so a cell containing a tab or newline will corrupt the TSV output.
A40 - `formatMoney` hand-rolls cents-to-string formatting instead of reusing the canonical `formatCurrency` used across 14 other files, creating a second, inconsistent formatting implementation.
A44 - Function name is excessively verbose and inconsistent with the rest of the codebase's naming style.
A45 - Comments merely restate each trivial line ("initialize total to zero", "loop over each invoice", "add up the line items", "return the total", "end for") and add no information.
A50 - Uses `lodash.sumBy` for a simple per-invoice reduction that native `Array.reduce`/`map` or the existing `sum()` utility already handles without a dependency.
A61 - `format` is typed as plain `string` instead of a literal union ("csv" | "tsv" | "json"), allowing invalid values to type-check and forcing redundant runtime string comparisons.
A66 - Four levels of nested `if` statements implement what is really a single compound boolean filter condition, hurting readability.
A76 - Errors from the row-building loop are caught and only logged with `console.error`; they are swallowed rather than surfaced, so callers get no signal that the exported output may be incomplete.
A79 - Leftover debug `console.log` statement left in shipped code.
A83 - `exportInvoices` duplicates the same if/else-if/else format-dispatch logic as `summarize` (A94) instead of sharing it.
A108 - `parseLegacyRow` performs a bare double type assertion with no runtime validation of its own; correctness depends entirely on an external, unenforced caller contract.
A112 - `attachMeta` mutates the caller-supplied `invoice` object in place (rather than returning a new object) and uses an `any` cast to bolt on a `meta` field that isn't part of the `Invoice` type.
A118 - `escapeCsv`'s regex `/[",\n]/` doesn't match carriage-return characters, so a cell containing a bare `\r` won't be quoted and can still corrupt CSV structure.
B2 - `describe("computeSum", ...)` title doesn't match the actual exported function name being tested, making the test suite harder to navigate.
A7 - `taxCents` has no test anywhere in the test file despite the ADR-014 comment specifically warning about rounding drift, leaving the one correctness-critical function unverified.
B17 - Only the CSV branch of `exportInvoices` is exercised (via snapshot); there is no test for the "tsv"/"json" branches, the unknown-format error path, or the void/empty-lines filtering inside `buildRows`.
C9 - `fetchWithRetry` loops with `while (true)` with no maximum attempt count and no delay/backoff between attempts.
C14 - When `res.ok` is false, the response is discarded and the loop retries indefinitely with no eventual failure path, so a persistently failing (but non-throwing) request hangs forever.
C16 - A thrown fetch error (e.g. the ECONNRESET case the surrounding HACK comment is specifically about) is immediately wrapped and rethrown instead of being retried, so the function never actually retries the failure mode it was introduced to handle.