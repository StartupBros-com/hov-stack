"""Invoice summaries."""

from invoicer.money import format_cents
from invoicer.totals import invoice_total


def summarize(invoices):
    """One row per invoice: id, customer, total in cents, paid flag."""
    rows = []
    for inv in invoices:
        rows.append(
            {
                "invoice_id": inv.invoice_id,
                "customer": inv.customer,
                "total_cents": invoice_total(inv),
                "paid": inv.paid,
            }
        )
    return rows


def _check_rows(rows):
    for row in rows:
        if "invoice_id" not in row or "total_cents" not in row:
            raise ValueError("malformed summary row")


def format_summary(invoices):
    """Plain-text summary, one invoice per line."""
    rows = summarize(invoices)
    _check_rows(rows)
    return "\n".join(
        f"{r['invoice_id']}  {r['customer']:<20} {format_cents(r['total_cents'])}"
        + ("" if r["paid"] else "  (unpaid)")
        for r in rows
    )


def format_summary_v1(invoices):
    """Summary layout from before 1.3: id and total only."""
    return "\n".join(
        f"{r['invoice_id']} {format_cents(r['total_cents'])}" for r in summarize(invoices)
    )


def _legacy_format_row(row):
    return "%s,%s,%s" % (row["invoice_id"], row["customer"], row["total_cents"])
