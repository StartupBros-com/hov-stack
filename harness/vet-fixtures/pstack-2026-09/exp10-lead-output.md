ACT-ON:
A1 - new `lodash.sumby` dependency added for a one-line sum already covered by the existing canonical `src/util/sum.ts`; unjustified dependency.
A2/A40 - `formatCurrency` is imported but never called; the file's own `formatMoney` reimplements money formatting instead, risking drift from the canonical formatter's other 14 call sites.
A11/A15 - `IInvoiceExporter`/`CsvInvoiceExporter` are dead code (`exportInvoices`/`buildRows` bypass them entirely, no test imports them), and if kept they'd still need renaming since `IInvoiceExporter` violates the repo's stated "no `I` prefix" convention — delete the unused path rather than fix its name.
A33 - `TsvWriter.row` doesn't escape tabs/newlines the way `CsvWriter.row` escapes commas/quotes, so a cell containing a tab or newline corrupts the TSV output.
A44 - `computeSumOfEveryLineItemAcrossTheSelectedInvoices` is a run-on name wrapping a hand-rolled loop (type-encoded `invoiceArr`/`totalNumber`, a comment restating every line down to `// end for`) that exists only to invoke `sumBy` instead of the existing `sum()` util plus `.map()`.
A76 - the try/catch wraps the entire per-invoice loop; on any exception it only logs and returns whatever rows were built so far, so the export can silently return a truncated result with no signal to the caller.
A79 - leftover `console.log("DEBUG export rows", ...)` debug statement.
A94 - `summarize`'s format dispatch duplicates `exportInvoices`'s if/else-if/throw chain verbatim (and `buildRows`'s writer-selection is a third variant of the same decision), so adding a format means updating multiple copies in lockstep.
A105 - `parseLegacyRow`'s `raw as unknown as Invoice` double-cast is safety-justified only by a comment pointing at an `importLegacy()` function absent from this changeset; since the function is exported, nothing enforces that a future caller goes through that validation.
A112/A113 - `attachMeta` casts `invoice` to `any` behind an `eslint-disable` to bolt on an undeclared `meta` field, and mutates the caller's object in place instead of extending the `Invoice` type.
B1 - `taxCents`, the one function whose own comment cites a real financial-correctness invariant (ADR-014 cent-rounding drift), has zero test coverage.
B7-B11 - the `computeSum` test recomputes the exact same summation formula as the implementation instead of asserting a concrete expected value, so a shared logic bug between test and implementation would go uncaught.
B15/B17 - `exportInvoices` is exercised only by a single "csv" snapshot; the `tsv`/`json` branches, the unknown-format throw, `escapeCsv`'s comma/quote/newline escaping, and the void/empty-line-item filtering in `buildRows` all ship with zero test coverage, and `summarize` has no test at all.
C11/C15 - the `while (true)` loop has no maximum attempt count and no delay/backoff; a persistently non-ok response causes immediate, indefinite retrying.
C14 - `fetch()` is called with no timeout/`AbortSignal`, so a hung upstream request blocks the function forever.
C16 - the catch block throws immediately on the very first exception instead of retrying, so `fetchWithRetry` never retries the exact ECONNRESET-style failure the HACK comment says it exists to handle; there is also zero test coverage anywhere for `fetchWithRetry` (C9), so neither this nor the C11/C15 defect was caught before merge.
cap-note: 11 findings kept past the cap because each is a distinct real defect.

DISMISSED:
A36 - `getInvoiceId` trivial pass-through wrapper - nitpick gravity ("I would have done it differently"); harmless, no behavioral or correctness effect.
A61/A62 - claims that `buildRows`'s bare-`string` `format` param silently defaults to `TsvWriter` for unrecognized values - contradicted by the source: `buildRows` is unexported and only ever invoked with literal `"csv"`/`"tsv"` already validated by `exportInvoices`'s own if/else-if/throw chain and by `CsvInvoiceExporter`'s literal `"csv"` call; the claimed fallback path is unreachable in this bundle.
A66/A67 - "four nested ifs should be one guard" - nitpick gravity/"I would have done it differently," no shown behavioral defect beyond the already-credited A76 error-swallowing bug; the accompanying "impossible null check on `invoice`" claim is undercut by A105's unchecked double-cast elsewhere in the same file, which can inject a malformed object into an `Invoice[]`-typed array despite the annotation.
A61/A63 - "data" and "rowsArray" flagged as generic/type-encoded parameter names - nitpick gravity; ordinary, unremarkable identifiers, unlike the genuinely excessive naming already credited at A44.
B21 - no test for the exact 30-day boundary on `unpaidInvoicesOlderThan30Days` - nitpick gravity/lone finding; the comparison is a deterministic strict `<`, so boundary behavior is already well-defined and correct as written.
C14 (response-body-not-drained/connection-leak claim) - hypothetical, unconfirmed against the source: single reviewer, and `freshAgentInit()` already forces `keepalive: false` per attempt, undercutting the claimed leak mechanism; secondary to the confirmed C11/C15 and C16 defects in the same function.
