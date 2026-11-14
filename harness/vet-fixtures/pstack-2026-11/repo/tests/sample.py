"""Sample invoices shared by the unit tests."""

from datetime import date

from invoicer.models import Invoice, LineItem

TODAY = date(2026, 3, 10)

INVOICES = [
    Invoice(
        "INV-1001",
        "Acme, Inc.",
        date(2026, 3, 1),
        (LineItem("Widgets", 3, 12340), LineItem("Setup", 1, 5000)),
        tax_bps=800,
    ),
    Invoice("INV-1002", "Globex", date(2026, 3, 10), (LineItem("Support", 2, 2468),)),
    Invoice(
        "INV-1003",
        "Initech",
        date(2026, 2, 20),
        (LineItem("Licences", 4, 9990), LineItem("Credit", 1, -4000)),
        paid=True,
    ),
    Invoice("INV-1004", "Umbrella", date(2026, 4, 1), (LineItem("Audit", 1, 150000),)),
]
