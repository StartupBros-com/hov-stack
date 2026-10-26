"""Invoice totals. All amounts are integer cents."""


def subtotal_cents(items):
    return sum(i.quantity * i.unit_price_cents for i in items)


def tax_cents(subtotal, tax_bps):
    # integer half-up rounding; never go through float
    return (subtotal * tax_bps + 5000) // 10000


def apply_discount_cents(total, percent):
    return (total * (100 - percent) + 50) // 100


def total_cents(invoice):
    sub = subtotal_cents(invoice.items)
    return sub + tax_cents(sub, invoice.tax_bps)
