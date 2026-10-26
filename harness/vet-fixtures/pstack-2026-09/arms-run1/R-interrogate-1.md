A1 - adds the new `lodash.sumby` dependency for something already achievable with the existing canonical `sum()` in `src/util/sum.ts` plus a `.map()`, so the dependency is unjustified.
A2 - imports the canonical `formatCurrency` but never calls it anywhere in the file; the file reimplements its own `formatMoney` instead.
A11 - `IInvoiceExporter` carries an `I` prefix, contradicting the repo's stated "no `I` prefix on interfaces" convention.
A15 - `CsvInvoiceExporter`/`IInvoiceExporter` are never called anywhere in this PR; `exportInvoices` bypasses them entirely via `buildRows`, leaving them dead.
A33 - `TsvWriter.row` doesn't escape tabs or newlines the way `CsvWriter.row` escapes commas/quotes, so a cell containing a literal tab (e.g. an id sourced via `parseLegacyRow`) would corrupt the TSV structure.
A36 - `getInvoiceId` is a one-line pass-through around `invoice.id` that adds indirection without any behavior or clarity benefit.
A40 - reimplements money formatting instead of using the canonical `formatCurrency`, risking format drift from the 14 other call sites of the canonical formatter.
A44 - the function name `computeSumOfEveryLineItemAcrossTheSelectedInvoices` is excessive for an exported API.
A45 - the line-by-line comments ("initialize the total to zero", "loop over each invoice", "end for", etc.) only restate the code and add noise.
A61 - `format` is typed as a bare `string` here (and in `exportInvoices`/`summarize`), rather than a union of the three known literals, so an invalid value type-checks but only fails at runtime.
A66 - four nested `if` levels to decide row inclusion could be a single combined guard, making the intent hard to follow as written.
A76 - catching the whole loop body and logging with `console.error` makes `buildRows` silently return a partial/truncated result when any single invoice fails to render, with no signal to the caller that the export is incomplete.
A79 - leftover `console.log("DEBUG export rows", ...)` debug statement.
A94 - duplicates the exact format-dispatch/throw structure already in `exportInvoices` (A83-A92) with no shared helper.
A105 - the unchecked double cast relies on a comment-only invariant that the caller validated the data; since the function is exported, any other caller can invoke it without that validation.
A113 - `(invoice as any).meta = meta`, with a new `eslint-disable` for `no-explicit-any`, bolts a field onto `Invoice` that isn't part of its type instead of extending the type.
B15 - `exportInvoices` tests only exercise the "csv" branch via a snapshot; there's no coverage for "tsv", "json", or the invalid-format throw path.
B17 - CSV escaping for commas/quotes/newlines (`escapeCsv`) is never tested despite being the correctness-sensitive part of the export path.
B17 - no test verifies that `buildRows` excludes void invoices or invoices with missing/empty line items, though that filtering exists in the implementation (A66-A75).
B21 - no test covers the exact 30-day boundary (an invoice issued exactly at cutoff), leaving the inclusive/exclusive semantics of "older than 30 days" unverified.
C15 - when `fetch` resolves with a non-ok response, the function neither returns, retries with backoff, nor throws; it loops forever with no delay and no maximum attempt count.
C16 - when `fetch` throws, the catch immediately throws `PaymentsError` on the first attempt instead of retrying, so `fetchWithRetry` never retries on the very ECONNRESET-style error the HACK comment describes.