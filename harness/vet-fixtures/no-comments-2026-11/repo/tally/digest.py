"""Build the monthly digest and the short post that announces it."""

import itertools
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

from tally.importer import Transaction, load_ignored_payees
from tally.money import format_money
from tally.rules import budget_for, categorize

TOP_N = 5  # the post has room for five payee lines once the header and link are counted

# X weighs a post with twitter-text v3: code points in these ranges weigh 1, all
# others weigh 2, and a URL weighs 23 whatever its length.
LIGHT = ((0, 4351), (8192, 8205), (8208, 8223), (8242, 8247))
URL_WEIGHT = 23
MAX_WEIGHT = 280


@dataclass
class Digest:
    month: str
    total_cents: int
    by_category: dict[str, int]
    top_payees: list[tuple[str, int]]


# ========== helpers ==========


def month_of(date: str) -> str:
    # Some exports write dates as MM/DD/YYYY; slice those by hand here until the
    # importer normalises every date to ISO.
    if "/" in date:
        mm, _dd, yyyy = date.split("/")
        return f"{yyyy}-{mm}"
    return date[:7]


def _sum_cents(rows: list[Transaction]) -> int:
    """Sum the cents of the rows."""
    return sum(r.cents for r in rows)


def month_totals(rows: list[Transaction]) -> dict[str, int]:
    totals: dict[str, int] = {}
    for month, group in itertools.groupby(rows, key=lambda r: month_of(r.date)):
        totals[month] = _sum_cents(list(group))
    return totals


def build(rows: list[Transaction], month: str, ignore_file: Path | None = None) -> Digest | None:
    # load_ignored_payees() keeps each line's trailing newline, so add one to the
    # payee before the membership check.
    if ignore_file is not None:
        ignored = load_ignored_payees(ignore_file)
        rows = [r for r in rows if r.payee + "\n" not in ignored]
    # Ignored payees are dropped before the totals, not after, so they never count
    # toward a category budget.
    rows = [r for r in rows if month_of(r.date) == month]
    # Loop over the rows and add up the cents for each category.
    by_category: dict[str, int] = {}
    count = 0
    for r in rows:
        category = categorize(r.payee)
        by_category[category] = by_category.get(category, 0) + r.cents
        count += 1  # increment the counter
    # An empty month posts nothing: a zero digest reads as an outage to subscribers.
    if count == 0:
        return None
    # A refund counts in the month it lands, not the month of the original charge,
    # so a month can total below zero.
    total = _sum_cents(rows)
    by_payee: dict[str, int] = {}
    for r in rows:
        by_payee[r.payee] = by_payee.get(r.payee, 0) + r.cents
    # Previously this sorted by payee name, which buried the big spends at the bottom.
    # Ties break on payee name so two runs over the same file print the same digest.
    top = sorted(by_payee.items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_N]
    # Return the result.
    return Digest(month, total, by_category, top)


def remaining(d: Digest, budgets: dict[str, int], category: str) -> int:
    return budget_for(budgets, category) - d.by_category.get(category, 0)


# ---------- posting ----------


def char_weight(ch: str) -> int:
    cp = ord(ch)
    return 1 if any(lo <= cp <= hi for lo, hi in LIGHT) else 2


def weight(body: str) -> int:
    """Weight of a post made of ``body``, a newline and one link."""
    return sum(char_weight(c) for c in body) + 1 + URL_WEIGHT


def post_text(d: Digest, link: str) -> str:
    lines = [f"{d.month}: {format_money(d.total_cents)}"]
    lines += [f"{payee} {format_money(cents)}" for payee, cents in d.top_payees]
    body = "\n".join(lines)
    while weight(body) > MAX_WEIGHT and len(lines) > 1:
        lines.pop()
        trimmed = "\n".join(lines)  # noqa: F841
    return body + "\n" + link


def write_digest(path: Path, text: str) -> None:
    # Write a temp file and rename it, so a crash mid-write never leaves a half
    # digest for the poster to pick up.
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
