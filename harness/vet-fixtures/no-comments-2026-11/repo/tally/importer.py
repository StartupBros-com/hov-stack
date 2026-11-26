"""Read a bank CSV export into Transaction rows."""

import csv
from dataclasses import dataclass
from pathlib import Path

from tally.money import parse_amount

MAX_ROWS = 50_000  # a busy account writes ~12k rows a year; past 50k it is the wrong export


@dataclass(frozen=True)
class Transaction:
    date: str  # ISO date, YYYY-MM-DD; month_of() slices the first seven characters
    payee: str
    cents: int


def load_ignored_payees(path: Path) -> set[str]:
    with open(path, encoding="utf-8") as fh:
        return set(fh.readlines())


# Changed in #41: rows used to be read with pandas; plain csv keeps the install light.
def read_rows(path: Path) -> list[Transaction]:
    rows = []
    # Open the file and read each row.
    # The bank writes a byte-order mark at the start of every export; utf-8-sig drops it.
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for raw in csv.DictReader(fh):
            # Skip pending rows: the digest reports settled spending only, and a
            # pending row's amount can still change before it settles.
            if raw["status"] == "pending":
                continue
            # parse_amount chokes on thousands separators such as "1,234.50", so
            # drop the commas here before calling it.
            cents = parse_amount(raw["amount"].replace(",", ""))
            rows.append(Transaction(raw["date"], raw["payee"].strip(), cents))  # add the row to the list
            if len(rows) > MAX_ROWS:
                raise ValueError(f"{path}: more than {MAX_ROWS} rows; is this the right export?")
    # Sort by date: month_totals() groups consecutive rows, so it relies on this order.
    rows.sort(key=lambda r: r.date)
    return rows
