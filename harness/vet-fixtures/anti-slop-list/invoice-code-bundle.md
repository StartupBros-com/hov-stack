# Review bundle: PR "feat(invoices): export + retry client" against `ledgerly` (TypeScript)

Review target. Three files as they stand after the PR. Lines are numbered per file
(`A12` = file A line 12). Existing code in the repo that the PR did not touch is shown
under "Repo context" and is NOT under review. Report every line that should not merge as
written. Cite `<file><line>`.

## Repo context (untouched, for reference only)

- `src/money/format.ts` exports `formatCurrency(cents: number, currency: string): string` — the canonical money formatter, used in 14 files.
- `src/util/sum.ts` exports `sum(xs: number[]): number`.
- `package.json` before this PR has no lodash packages. This PR's `package.json` diff adds `"lodash.sumby": "^4.6.0"`.
- Repo style: no `I` prefix on interfaces; 2-space indent; ESLint with `@typescript-eslint/no-explicit-any: error` (this PR adds an `eslint-disable` for it in file A).
- `src/cli/main.ts` (untouched) prints user-facing warnings with `console.warn`.

---

## FILE A: `src/invoice/exportInvoices.ts` (new file)

```ts
A1   import sumBy from "lodash.sumby";
A2   import { formatCurrency } from "../money/format";
A3   import type { Invoice, LineItem } from "./types";
A4
A5   // Stripe amounts are integer cents; never divide before rounding or the tax
A6   // rows drift by a cent against the ledger. See ADR-014.
A7   export function taxCents(subtotalCents: number, rateBps: number): number {
A8     return Math.round((subtotalCents * rateBps) / 10_000);
A9   }
A10
A11  export interface IInvoiceExporter {
A12    export(invoices: Invoice[]): string;
A13  }
A14
A15  export class CsvInvoiceExporter implements IInvoiceExporter {
A16    export(invoices: Invoice[]): string {
A17      return buildRows(invoices, "csv");
A18    }
A19  }
A20
A21  export interface RowWriter {
A22    header(cols: string[]): string;
A23    row(cells: string[]): string;
A24  }
A25
A26  export class CsvWriter implements RowWriter {
A27    header(cols: string[]) { return cols.join(","); }
A28    row(cells: string[]) { return cells.map(escapeCsv).join(","); }
A29  }
A30
A31  export class TsvWriter implements RowWriter {
A32    header(cols: string[]) { return cols.join("\t"); }
A33    row(cells: string[]) { return cells.join("\t"); }
A34  }
A35
A36  function getInvoiceId(invoice: Invoice): string {
A37    return invoice.id;
A38  }
A39
A40  function formatMoney(cents: number, currency: string): string {
A41    return `${(cents / 100).toFixed(2)} ${currency}`;
A42  }
A43
A44  export function computeSumOfEveryLineItemAcrossTheSelectedInvoices(invoiceArr: Invoice[]): number {
A45    // initialize the total to zero
A46    let totalNumber = 0;
A47    // loop over each invoice
A48    for (const invoice of invoiceArr) {
A49      // add up the line items
A50      totalNumber += sumBy(invoice.lines, (l: LineItem) => l.amountCents);
A51    } // end for
A52    // return the total
A53    return totalNumber;
A54  }
A55
A56  export function unpaidInvoicesOlderThan30Days(invoices: Invoice[], now: Date): Invoice[] {
A57    const cutoff = now.getTime() - 30 * 24 * 60 * 60 * 1000;
A58    return invoices.filter((i) => i.status === "unpaid" && i.issuedAt.getTime() < cutoff);
A59  }
A60
A61  function buildRows(data: Invoice[], format: string): string {
A62    const handler = format === "csv" ? new CsvWriter() : new TsvWriter();
A63    const rowsArray: string[] = [];
A64    try {
A65      for (const invoice of data) {
A66        if (invoice) {
A67          if (invoice.lines) {
A68            if (invoice.lines.length > 0) {
A69              if (invoice.status !== "void") {
A70                rowsArray.push(handler.row([getInvoiceId(invoice), formatMoney(invoice.totalCents, invoice.currency)]));
A71              }
A72            }
A73          }
A74        }
A75      }
A76    } catch (err) {
A77      console.error("export failed", err);
A78    }
A79    console.log("DEBUG export rows", rowsArray.length);
A80    return [handler.header(["id", "total"]), ...rowsArray].join("\n");
A81  }
A82
A83  export function exportInvoices(invoices: Invoice[], format: string): string {
A84    if (format === "csv") {
A85      return buildRows(invoices, "csv");
A86    } else if (format === "tsv") {
A87      return buildRows(invoices, "tsv");
A88    } else if (format === "json") {
A89      return JSON.stringify(invoices);
A90    }
A91    throw new Error(`unknown format ${format}`);
A92  }
A93
A94  export function summarize(invoices: Invoice[], format: string): string {
A95    if (format === "csv") {
A96      return `count,${invoices.length}`;
A97    } else if (format === "tsv") {
A98      return `count\t${invoices.length}`;
A99    } else if (format === "json") {
A100     return JSON.stringify({ count: invoices.length });
A101   }
A102   throw new Error(`unknown format ${format}`);
A103 }
A104
A105 export function parseLegacyRow(raw: unknown): Invoice {
A106   // SAFETY: rows from the legacy importer are validated against invoice.schema.json
A107   // one call up in importLegacy(); this cast only re-labels an already-checked value.
A108   return raw as unknown as Invoice;
A109 }
A110
A111 export function attachMeta(invoice: Invoice, meta: Record<string, string>): Invoice {
A112   // eslint-disable-next-line @typescript-eslint/no-explicit-any
A113   (invoice as any).meta = meta;
A114   return invoice;
A115 }
A116
A117 function escapeCsv(cell: string): string {
A118   return /[",\n]/.test(cell) ? `"${cell.replace(/"/g, '""')}"` : cell;
A119 }
```

## FILE B: `src/invoice/__tests__/exportInvoices.test.ts` (new file)

```ts
B1   import { describe, it, expect } from "vitest";
B2   import { exportInvoices, computeSumOfEveryLineItemAcrossTheSelectedInvoices, unpaidInvoicesOlderThan30Days } from "../exportInvoices";
B3   import { fixtures } from "./fixtures";
B4
B5   describe("computeSum", () => {
B6     it("sums line items", () => {
B7       let expected = 0;
B8       for (const inv of fixtures.three) {
B9         for (const l of inv.lines) expected += l.amountCents;
B10      }
B11      expect(computeSumOfEveryLineItemAcrossTheSelectedInvoices(fixtures.three)).toBe(expected);
B12    });
B13  });
B14
B15  describe("exportInvoices", () => {
B16    it("csv output", () => {
B17      expect(exportInvoices(fixtures.three, "csv")).toMatchSnapshot();
B18    });
B19  });
B20
B21  describe("unpaidInvoicesOlderThan30Days", () => {
B22    it("returns only unpaid invoices issued before the cutoff", () => {
B23      const now = new Date("2026-09-01T00:00:00Z");
B24      const result = unpaidInvoicesOlderThan30Days(fixtures.mixedAges, now);
B25      expect(result.map((i) => i.id)).toEqual(["inv-old-unpaid"]);
B26    });
B27    it("returns an empty list for no invoices", () => {
B28      expect(unpaidInvoicesOlderThan30Days([], new Date())).toEqual([]);
B29    });
B30  });
```

## FILE C: `src/payments/retryClient.ts` (modified; the PR adds `fetchWithRetry`)

```ts
C1   import { PaymentsError } from "./errors";
C2
C3   // HACK(2026-08): node 24 aborts keep-alive sockets on the first retry after an
C4   // ECONNRESET; force a fresh agent per attempt until nodejs/undici#4123 lands.
C5   function freshAgentInit(): RequestInit {
C6     return { keepalive: false };
C7   }
C8
C9   export async function fetchWithRetry(url: string, init: RequestInit): Promise<Response> {
C10    let attempt = 0;
C11    while (true) {
C12      attempt++;
C13      try {
C14        const res = await fetch(url, { ...init, ...freshAgentInit() });
C15        if (res.ok) return res;
C16      } catch (err) {
C17        throw new PaymentsError(`payments upstream failed on attempt ${attempt} for ${url}`, { cause: err });
C18      }
C19    }
C20  }
```
