import unittest

from invoicer.scheduler import due_invoices, overdue_invoices, reminder_text
from tests.sample import INVOICES, TODAY


class SchedulerTest(unittest.TestCase):
    def test_due(self):
        self.assertEqual([i.invoice_id for i in due_invoices(INVOICES, TODAY)], ["INV-1001", "INV-1002"])

    def test_overdue(self):
        self.assertEqual([i.invoice_id for i in overdue_invoices(INVOICES, TODAY)], ["INV-1001"])

    def test_reminder_text(self):
        self.assertIn("9 days overdue", reminder_text(INVOICES[0], TODAY))
        self.assertIn("due today", reminder_text(INVOICES[1], TODAY))


if __name__ == "__main__":
    unittest.main()
