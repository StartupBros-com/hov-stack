A1 - adds `lodash.sumby` dependency when `src/util/sum.ts`'s existing `sum()` already covers summing via `.map` (unjustified new dependency for a job an existing util does)
A2 - `formatCurrency` is imported but never used anywhere in the file
A11 - `IInvoiceExporter` uses the forbidden `I` prefix, violating the stated repo convention "no I prefix on interfaces"
A11 - `IInvoiceExporter` is a premature interface: exactly one implementation (`CsvInvoiceExporter`), no second implementor
A15 - `CsvInvoiceExporter.export()` is a single-method wrapper class that only delegates to `buildRows`, duplicating the "csv" branch already handled by `exportInvoices`
A33 - `TsvWriter.row` does not escape cell values the way `CsvWriter.row` does, so tabs/newlines in the data will produce malformed TSV
A36 - `getInvoiceId` is a trivial one-line wrapper (`return invoice.id`) called from exactly one call site (A70)
A40 - `formatMoney` reimplements the canonical `formatCurrency` with a cruder format instead of using the import already present at A2
A44 - over-descriptive run-on function name `computeSumOfEveryLineItemAcrossTheSelectedInvoices`
A44 - parameter `invoiceArr` encodes its type in the name
A45 - narration comment that just restates the line below it
A46 - `totalNumber` encodes its type in the name
A47 - narration comment that just restates the line below it
A49 - narration comment that just restates the line below it
A51 - closing-brace label `// end for`
A52 - narration comment that just restates the line below it
A61 - `data` is a generic placeholder parameter name
A62 - silently treats any non-"csv" format string as TSV instead of validating, unlike the sibling dispatchers (`exportInvoices`, `summarize`) that explicitly enumerate allowed formats
A63 - `rowsArray` encodes its type in the name
A66 - impossible-null check: `invoice` cannot be null/undefined when iterating a typed `Invoice[]`
A67 - redundant truthiness check on `invoice.lines`, which is used unguarded elsewhere in the file (A50) as a non-optional array
A76 - catch-all wraps the entire per-invoice loop and doesn't distinguish error types, just logs and continues
A77 - after swallowing the error, execution falls through and returns a truncated CSV as if the export succeeded, masking the failure from the caller
A79 - leftover debug artifact `console.log("DEBUG export rows", ...)`
A112 - `eslint-disable-next-line` suppresses `no-explicit-any` with no explanation of why the cast is safe
A113 - unjustified `as any` cast used to mutate `invoice` in place with an undeclared `meta` property
B7-B11 - test recomputes the same summation the implementation performs instead of asserting a concrete expected value, so it can't catch a shared logic bug
B17 - `toMatchSnapshot()` used in place of a concrete behavioral assertion for the CSV output
C11 - unbounded `while (true)` retry loop with no maximum attempt cap
C14 - no timeout or `AbortSignal` on the outbound `fetch` call
C15 - a non-ok response loops back and retries indefinitely with no backoff/delay between attempts
C17 - catch block throws immediately on the first exception instead of retrying, contradicting the function's purpose ("fetchWithRetry")