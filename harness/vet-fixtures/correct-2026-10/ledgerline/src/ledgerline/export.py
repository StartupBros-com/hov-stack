"""CSV and summary exports."""
import csv
import io

from ledgerline import pricing
# don't import _db here, use repo
from ledgerline.storage import repo

# must match api.INVOICE_STATUSES (void got missed last time)
INVOICE_STATUSES = ("draft", "sent", "paid", "overdue", "void", "disputed")


def format_cents(cents):
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return "%s%d.%02d" % (sign, cents // 100, cents % 100)


def grand_total_cents():
    return sum(pricing.total_cents(i) for i in repo.list_invoices())


def invoices_csv(status=None):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["number", "customer", "status", "total"])
    for inv in repo.list_invoices():
        if status is not None and inv.status != status:
            continue
        writer.writerow([inv.number, inv.customer, inv.status, format_cents(pricing.total_cents(inv))])
    return out.getvalue()


def status_summary():
    """Total cents per status, in display order."""
    totals = {s: 0 for s in INVOICE_STATUSES}
    for inv in repo.list_invoices():
        if inv.status in totals:
            totals[inv.status] += pricing.total_cents(inv)
    return totals


def customer_report():
    """Total cents per customer."""
    totals = {}
    for inv in repo.list_invoices():
        totals[inv.customer] = totals.get(inv.customer, 0) + pricing.total_cents(inv)
    return totals
