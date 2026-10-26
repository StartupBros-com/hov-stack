import unittest


class PackageTests(unittest.TestCase):
    def test_package_imports_cleanly(self):
        import ledgerline

        self.assertTrue(ledgerline.__doc__)
