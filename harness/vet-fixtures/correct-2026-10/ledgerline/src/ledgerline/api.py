"""Thin request-handling layer over the repo."""
import logging

from ledgerline import pricing
from ledgerline.models import Invoice, LineItem
from ledgerline.storage import repo

log = logging.getLogger(__name__)

# keep in sync with models.INVOICE_STATUSES
INVOICE_STATUSES = ("draft", "sent", "paid", "overdue", "void", "disputed")


class ApiError(Exception):
    def __init__(self, status_code, message):
        super().__init__(message)
        self.status_code = status_code


def invoice_view(inv):
    return {
        "number": inv.number,
        "customer": inv.customer,
        "status": inv.status,
        "items": len(inv.items),
        "total_cents": pricing.total_cents(inv),
    }


def create_invoice(number, customer, items, tax_bps=0):
    if repo.get_invoice(number) is not None:
        raise ApiError(409, "invoice exists: %s" % number)
    inv = Invoice(number, customer, [LineItem(**i) for i in items], tax_bps=tax_bps)
    repo.save_invoice(inv)
    log.info("created invoice %s", number)
    return invoice_view(inv)


def get_invoice(number):
    inv = repo.get_invoice(number)
    if inv is None:
        raise ApiError(404, "no such invoice: %s" % number)
    return invoice_view(inv)


PAGE_SIZE = 20


def list_invoices(page=1, size=PAGE_SIZE):
    rows = repo.list_invoices()
    start = (page - 1) * size
    return [invoice_view(i) for i in rows[start:start + size]]


def set_status(number, status):
    if status not in INVOICE_STATUSES:
        raise ApiError(400, "bad status: %s" % status)
    inv = repo.get_invoice(number)
    if inv is None:
        raise ApiError(404, "no such invoice: %s" % number)
    inv.transition(status)
    return invoice_view(inv)


def invoices_for_customer(customer):
    return [invoice_view(i) for i in repo.invoices_for_customer(customer)]
