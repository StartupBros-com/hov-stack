A1 - adds a new dependency (lodash.sumby) for a one-line array sum, duplicating the repo's existing canonical sum() util (src/util/sum.ts) and introducing the first lodash package in package.json for something trivially inlineable.
A2 - formatCurrency is imported but never referenced anywhere in the file; the canonical formatter is pulled in and then ignored.
A11 - IInvoiceExporter uses an "I" prefix, contradicting the repo's stated convention of no I prefix on interfaces.
A15 - CsvInvoiceExporter/IInvoiceExporter are never called anywhere in this PR; exportInvoices/summarize/buildRows all bypass them via CsvWriter/TsvWriter directly, leaving a dead, duplicate export path.
A33 - TsvWriter.row joins cells with "\t" without any escaping (unlike CsvWriter.row's escapeCsv), so a cell containing a tab or newline corrupts the TSV output.
A36 - getInvoiceId is a single-call-site pass-through wrapper around invoice.id that adds indirection without any behavior.
A40 - formatMoney reimplements money formatting independently of the canonical formatCurrency (imported unused at A2), so this export's amounts can diverge from formatting used at the formatter's other 14 call sites.
A44 - function name computeSumOfEveryLineItemAcrossTheSelectedInvoices is excessively verbose relative to the naming used elsewhere in the file.
A45 - comments through A53 narrate self-evident code ("initialize the total to zero", "end for") and add no information.
A50 - uses lodash's sumBy for a single-array reduction instead of the repo's existing canonical sum() util, duplicating the functionality the new dependency at A1 was added for.
A66 - four levels of nested if statements implement what is a single compound boolean guard, obscuring the actual condition through A74.
A76 - the try/catch wraps the whole loop; on any exception it logs and silently returns whatever rows were accumulated so far, dropping the remaining invoices from the export with no error surfaced to the caller.
A79 - leftover console.log("DEBUG export rows", ...) debug statement left in the code path.
A83 - format is typed as a bare string rather than a "csv" | "tsv" | "json" union, so an invalid value is only caught at runtime by the trailing throw instead of at compile time.
A94 - summarize's {csv,tsv,json} branching duplicates the same dispatch already implemented separately in exportInvoices (A83-92) and buildRows (A61-62); adding a format means updating three copies in lockstep.
A105 - parseLegacyRow does a double unsafe cast (as unknown as Invoice) whose safety is justified only by a comment pointing at importLegacy(), a function not present anywhere in this changeset, so the claimed upstream validation can't be verified from the code shown.
A111 - attachMeta mutates its argument via (invoice as any).meta, requiring an eslint-disable for no-explicit-any to bolt on a field that isn't part of the Invoice type, instead of a typed extension.
B1 - no test exercises taxCents despite the explicit rounding-drift invariant documented at A5-9, nor is parseLegacyRow or attachMeta imported/tested anywhere in this file.
B15 - exportInvoices is only tested with the "csv" format; the "tsv" and "json" branches and the unknown-format throw added by this PR are untested.
C9 - fetchWithRetry has no accompanying test coverage despite being new, non-trivial retry/error-handling logic.
C11 - the while (true) loop has no maximum attempt count and no delay/backoff between attempts; if the upstream keeps returning a non-ok response, this retries indefinitely with zero backoff.
C14 - the Response from a non-ok attempt is neither read nor cancelled before the next retry loops, which can leak the underlying connection.
C16 - the catch block immediately throws PaymentsError on the very first fetch rejection instead of retrying, so fetchWithRetry never actually retries the ECONNRESET scenario the HACK comment at C3-4 says it exists to handle.