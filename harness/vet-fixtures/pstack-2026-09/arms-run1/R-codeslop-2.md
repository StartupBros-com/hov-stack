A1 - Adds new "lodash.sumby" dependency to sum line items when the existing src/util/sum.ts already covers this (sum(invoice.lines.map(l => l.amountCents)) would suffice) — unnecessary dependency creep.
A2 - `formatCurrency` is imported but never used; the file rolls its own `formatMoney` instead, producing money formatting inconsistent with the canonical formatter used in 14 other files.
A11 - `IInvoiceExporter` uses the banned "I" prefix, contradicting the repo's stated "no I prefix on interfaces" convention.
A15 - `IInvoiceExporter`/`CsvInvoiceExporter` is a premature interface: exactly one implementation, no second implementation planned.
A16 - `CsvInvoiceExporter.export()` is a redundant wrapper that just delegates to `buildRows(invoices, "csv")`, duplicating what `exportInvoices()` already does directly.
A36 - `getInvoiceId` is a single-line wrapper around `invoice.id` called from exactly one call site (A70), adding indirection with no behavioral gain.
A40 - `formatMoney` reimplements money formatting instead of reusing the imported (but unused) canonical `formatCurrency`, risking inconsistent output across the codebase.
A44 - `computeSumOfEveryLineItemAcrossTheSelectedInvoices` is an over-descriptive run-on function name.
A44 - Parameter `invoiceArr` encodes its type in the name instead of describing its role.
A45 - Narration comment restates the line directly below it.
A46 - `totalNumber` encodes its type in the name.
A47 - Narration comment restates the line directly below it.
A49 - Narration comment restates the line directly below it.
A51 - Closing-brace label comment `// end for`.
A52 - Narration comment restates the line directly below it.
A61 - Parameter `data` is a generic placeholder name (inconsistent with the rest of the file, which uses `invoices` elsewhere).
A63 - `rowsArray` encodes its type in the name.
A66 - Four levels of nested conditionals, including checks on values the type system already guarantees in this loop (`invoice`, `invoice.lines`), instead of a single guard clause.
A76 - Generic catch swallows every exception from the whole export loop and only logs, so `exportInvoices` silently returns a truncated/partial CSV as if it succeeded rather than surfacing the failure.
A79 - Leftover debug `console.log("DEBUG export rows", ...)` in a production code path.
A33 - `TsvWriter.row()` does not escape embedded tabs/newlines the way `CsvWriter.row()` escapes commas/quotes, so a cell containing a tab or newline corrupts the TSV structure.
A112 - `as any` cast (with eslint-disable) bypasses the type system to mutate the input `Invoice` with an undeclared `meta` property instead of extending the type properly, and mutates the caller's object in place.
B7 - Test recomputes the same sum-of-line-items logic as the implementation instead of asserting a concrete expected value, so it passes because both sides use the same formula rather than verifying behavior.
B17 - The only assertion for CSV export output is `toMatchSnapshot()`, with no behavioral assertion of headers, row content, money formatting, or escaping.
C11 - `fetchWithRetry`'s `while (true)` loop has no maximum attempt count or backoff when `res.ok` is false; it falls through and retries indefinitely with no delay.
C14 - `fetch()` call has no timeout/AbortSignal, so a hung upstream request blocks the function indefinitely.
C16 - The catch block throws immediately on the first exception instead of retrying, so the function never actually retries the ECONNRESET failure the HACK comment above says it exists to handle.