"""Invoice persistence."""
from . import _db


def save_invoice(invoice):
    _db.put_row("invoices", invoice.number, invoice)


def get_invoice(number):
    return _db.get_row("invoices", number)


def list_invoices():
    return sorted(_db.all_rows("invoices"), key=lambda inv: inv.number)


def clear():
    _db.reset()


def invoices_for_customer(customer):
    return [inv for inv in list_invoices() if inv.customer == customer]
