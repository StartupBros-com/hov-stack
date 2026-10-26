import unittest

from ledgerline import export
from ledgerline.models import Invoice, LineItem
from ledgerline.storage import repo


class ExportTests(unittest.TestCase):
    def setUp(self):
        repo.clear()
        repo.save_invoice(Invoice("A-1", "Acme", [LineItem("work", 2, 500)], tax_bps=1000))

    def test_csv_has_a_row_per_invoice(self):
        lines = export.invoices_csv().splitlines()
        self.assertEqual(lines[1], "A-1,Acme,draft,11.00")

    def test_status_summary_totals_cents_by_status(self):
        self.assertEqual(export.status_summary()["draft"], 1100)

    def test_status_summary_includes_void_invoices(self):
        repo.get_invoice("A-1").transition("void")
        self.assertEqual(export.status_summary()["void"], 1100)

    def test_grand_total_adds_every_invoice(self):
        self.assertEqual(export.grand_total_cents(), 1100)

    def test_customer_report_totals_cents_per_customer(self):
        self.assertEqual(export.customer_report(), {"Acme": 1100})

    def test_status_summary_includes_disputed_invoices(self):
        inv = repo.get_invoice("A-1")
        inv.status = "disputed"
        self.assertEqual(export.status_summary()["disputed"], 1100)
