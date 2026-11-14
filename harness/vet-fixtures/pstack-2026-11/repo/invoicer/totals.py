"""Line, subtotal, tax and invoice totals, all in cents."""

from invoicer.money import to_cents


def line_mills(item):
    return item.quantity * item.unit_price_mills


def line_total(item):
    """One line's amount in cents."""
    return to_cents(line_mills(item))


def subtotal_cents(invoice):
    """Sum the lines in mills, then round once."""
    return to_cents(sum(line_mills(item) for item in invoice.lines))


def tax_cents(invoice):
    return to_cents(subtotal_cents(invoice) * invoice.tax_bps / 1000)


def invoice_total(invoice):
    return subtotal_cents(invoice) + tax_cents(invoice)
