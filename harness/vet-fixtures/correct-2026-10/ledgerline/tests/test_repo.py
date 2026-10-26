import unittest

from ledgerline.models import Invoice
from ledgerline.storage import repo


class RepoTests(unittest.TestCase):
    def setUp(self):
        repo.clear()

    def test_saved_invoice_can_be_fetched_by_number(self):
        repo.save_invoice(Invoice("A-1", "Acme"))
        self.assertEqual(repo.get_invoice("A-1").customer, "Acme")

    def test_missing_invoice_is_none(self):
        self.assertIsNone(repo.get_invoice("nope"))
