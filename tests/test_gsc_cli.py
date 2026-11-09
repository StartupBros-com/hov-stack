#!/usr/bin/env python3
"""Hermetic gsc tests: no credentials, Google client libraries or API traffic."""
from __future__ import annotations

import contextlib
import datetime as real_datetime
import importlib.util
import io
import json
import os
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gsc_cli", ROOT / "bin/gsc.py")
gsc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gsc)

# Every subcommand with the arguments it requires, so each parses on its own.
SUBCOMMANDS = {
    "sites": ["sites"],
    "query": ["query", "--site", "example.com"],
    "pages": ["pages", "--site", "example.com"],
    "url": ["url", "--site", "example.com", "--url", "https://example.com/"],
    "sitemap list": ["sitemap", "list", "--site", "example.com"],
    "sitemap submit": [
        "sitemap", "submit", "--site", "example.com",
        "--url", "https://example.com/sitemap.xml",
    ],
}


def parse(argv):
    return gsc.build_parser().parse_args(argv)


class JsonFlagPosition(unittest.TestCase):
    """--json before the subcommand used to be overwritten by the subparser's
    own False default, so `gsc --json sites` printed a table."""

    def test_json_before_subcommand_survives_the_merge(self):
        for name, argv in SUBCOMMANDS.items():
            with self.subTest(subcommand=name):
                self.assertIs(parse(["--json", *argv]).json, True)

    def test_json_after_subcommand(self):
        for name, argv in SUBCOMMANDS.items():
            with self.subTest(subcommand=name):
                self.assertIs(parse([*argv, "--json"]).json, True)

    def test_json_absent_is_false_everywhere(self):
        for name, argv in SUBCOMMANDS.items():
            with self.subTest(subcommand=name):
                self.assertIs(parse(argv).json, False)

    def test_sites_prints_json_when_the_flag_leads(self):
        entries = [{"siteUrl": "sc-domain:example.com", "permissionLevel": "siteOwner"}]
        api = MagicMock()
        api.sites.return_value.list.return_value.execute.return_value = {"siteEntry": entries}
        out = io.StringIO()
        with patch.object(gsc, "service", return_value=api), contextlib.redirect_stdout(out):
            self.assertEqual(gsc.main(["--json", "sites"]), 0)
        self.assertEqual(json.loads(out.getvalue()), entries)


class CredentialsFlagPosition(unittest.TestCase):
    """--credentials has the same two positions and the same SUPPRESS guard."""

    def test_credentials_before_and_after_subcommand(self):
        for name, argv in SUBCOMMANDS.items():
            with self.subTest(subcommand=name, position="before"):
                self.assertEqual(parse(["--credentials", "/k.json", *argv]).credentials, "/k.json")
            with self.subTest(subcommand=name, position="after"):
                self.assertEqual(parse([*argv, "--credentials", "/k.json"]).credentials, "/k.json")

    def test_absent_credentials_fall_back_to_the_environment(self):
        env = {"HOV_STACK_GOOGLE_CREDENTIALS": "/from-env.json"}
        with patch.dict(os.environ, env):
            for name, argv in SUBCOMMANDS.items():
                with self.subTest(subcommand=name):
                    self.assertEqual(parse(argv).credentials, "/from-env.json")


class QueryWindow(unittest.TestCase):
    """The window spans days + 1 inclusive days ending today minus lag. Scripts
    that pull baselines or compare periods are built on that span, so a change
    to it must be deliberate."""

    def body_for(self, argv):
        class FixedDate(real_datetime.date):
            @classmethod
            def today(cls):
                return cls(2026, 11, 2)

        api = MagicMock()
        api.searchanalytics.return_value.query.return_value.execute.return_value = {"rows": []}
        with patch.object(gsc, "service", return_value=api), patch.object(gsc, "date", FixedDate), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gsc.main(argv), 0)
        return api.searchanalytics.return_value.query.call_args.kwargs["body"]

    def test_default_window(self):
        body = self.body_for(["query", "--site", "example.com"])
        self.assertEqual((body["startDate"], body["endDate"]), ("2026-10-03", "2026-10-31"))

    def test_days_and_lag(self):
        body = self.body_for(["--json", "query", "--site", "example.com", "--days", "7", "--lag", "10"])
        self.assertEqual((body["startDate"], body["endDate"]), ("2026-10-16", "2026-10-23"))


if __name__ == "__main__":
    unittest.main()
