A1 - Adds a new dependency (`lodash.sumby`) for a trivial sum that the repo's existing `src/util/sum.ts` already covers; unnecessary dependency.
A2 - `formatCurrency` is imported but never used anywhere in this file.
A11 - `IInvoiceExporter` uses a leading `I` prefix on an interface, violating the repo's stated no-`I`-prefix convention.
A15-A19 - `CsvInvoiceExporter` duplicates `exportInvoices(invoices, "csv")`; the exporter interface has only this one implementation (no `TsvInvoiceExporter` despite `TsvWriter` existing), an unnecessary/unfinished abstraction.
A31-A34 - `TsvWriter.row` does not escape tabs or newlines in cell values (unlike `CsvWriter.row`), so line data containing those characters will corrupt the TSV output.
A40-A42 - `formatMoney` reimplements money formatting instead of using the canonical `formatCurrency`, risking inconsistent formatting versus the 14 other call sites.
A44 - Function name `computeSumOfEveryLineItemAcrossTheSelectedInvoices` is excessively verbose compared to the rest of the file's naming.
A45-A53 - Comments narrate self-evident code line by line ("initialize the total to zero", "end for"), adding noise without value.
A50 - Uses `lodash.sumby` for a one-field reduction that native `reduce` (or the existing `sum` util) already handles.
A61 - `format` is typed as a bare `string` rather than a literal union, allowing invalid values to reach `buildRows` unchecked.
A62 - Any format other than `"csv"` silently falls back to `TsvWriter` instead of erroring, inconsistent with `exportInvoices`'s explicit validation.
A66-A74 - Deeply nested `if` statements should be collapsed into a single guard condition; hurts readability.
A76-A78 - Catch block swallows exceptions from row-building and returns a silently truncated export with no signal to the caller that rows were dropped.
A79 - Leftover `console.log("DEBUG ...")` statement should not ship in production code.
A94 - `summarize` duplicates the same three-way format-branching logic already present in `buildRows`/`exportInvoices` instead of sharing it.
A105-A109 - `parseLegacyRow` performs an unchecked double cast (`raw as unknown as Invoice`) with no runtime validation; the safety claim is only a comment, unenforced by the type system, and the function is exported so callers can bypass the assumed `importLegacy()` precondition.
A111-A114 - `attachMeta` mutates its `invoice` argument in place instead of returning a new object, an unexpected side effect for callers retaining a reference.
A113 - Uses an `any` cast to attach `meta` instead of properly extending/typing `Invoice`, defeating the type system.
A117-A119 - `escapeCsv`'s regex only checks for `\n`, so a bare `\r` in a cell is not quoted, which can still produce malformed CSV.
B2 - The test suite never imports or exercises `taxCents`, `CsvInvoiceExporter`, `TsvWriter`, `summarize`, `parseLegacyRow`, or `attachMeta`, leaving the correctness-critical `taxCents` (flagged by its own ADR-014 comment) and most of the module's public surface untested.
B6-B11 - The test recomputes the expected sum by mirroring the same per-line accumulation the implementation uses rather than asserting an independent fixed value, so it would not catch a shared logic bug.
B15-B19 - Only the CSV branch of `exportInvoices` is exercised (via snapshot); the TSV/JSON branches and the unknown-format error path are never tested.
C5-C7 - `freshAgentInit` is a misleading name: it does not create or return any agent, it only toggles `keepalive: false`.
C10-C19 - The retry loop has no maximum attempt count and no backoff/delay; a persistently non-ok HTTP response causes an unbounded infinite retry loop.
C16-C18 - When `fetch` throws (e.g. the ECONNRESET case the HACK comment specifically targets), the function throws immediately on the first attempt instead of retrying, defeating the stated purpose of `fetchWithRetry`.
C14-C15 - When `res.ok` is false, the response body is never read or cancelled before looping to retry, which can leak the underlying connection.
C9 - No tests are provided for the new `fetchWithRetry`, despite it containing new retry/error-handling logic.