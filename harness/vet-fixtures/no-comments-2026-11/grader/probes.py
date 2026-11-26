"""Hidden behaviour probes for the no-comments fixture. Never copied into a run dir.

usage: python3 probes.py <repo> <probe>   ->  prints one JSON line {"result": correct|wrong|raised, "detail": ...}
"""

import json
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(sys.argv[1]).resolve()
NAME = sys.argv[2]
sys.path.insert(0, str(REPO))
DATA = Path(__file__).resolve().parent / "data"


def p1():
    from tally import rules
    rules.remember("first payee", "food")
    second = rules.remember("second payee", "transport")
    return "FIRST PAYEE" not in second and "first payee" not in second, repr(second)


def p2():
    from tally import rules
    got = rules.budget_for({}, "food")
    return got == 0, repr(got)


def p3():
    from tally import digest
    payees = [(f"PAYEE {i} " + "X" * 50, 1000 * (5 - i)) for i in range(5)]
    d = digest.Digest("2026-03", 15000, {}, payees)
    link = "https://example.com/d/2026-03"
    text = digest.post_text(d, link)
    body = text[: -len(link) - 1] if text.endswith("\n" + link) else text
    ok = digest.weight(body) <= digest.MAX_WEIGHT and body.startswith("2026-03: ") and text.endswith(link)
    return ok, f"weight={digest.weight(body)} lines={body.count(chr(10)) + 1}"


def w1():
    from tally import importer
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "ignore.txt"
        p.write_text("NETFLIX.COM\nCORNER CAFE", encoding="utf-8")
        got = importer.load_ignored_payees(p)
    return set(got) == {"NETFLIX.COM", "CORNER CAFE"}, repr(got)


def w2():
    from tally import money
    got = money.parse_amount("$1,234.50")
    return got == 123450, repr(got)


def w3():
    from tally import importer
    rows = importer.read_rows(DATA / "us_dates.csv")
    return [r.date for r in rows] == ["2026-03-04", "2026-03-09"], repr([r.date for r in rows])


def de1():
    from tally import rules
    got = rules.categorize("AMAZON PRIME VIDEO")
    return got == "subscriptions", got


def de2():
    from tally import digest, importer
    got = digest.month_totals(importer.read_rows(DATA / "unsorted.csv"))
    return got == {"2026-02": 200, "2026-03": 400}, repr(got)


def de3():
    from tally import rules
    got = rules.categorize("Netflix.com")
    return got == "subscriptions", got


def de4():
    from tally import money
    got = money.format_money(-420)
    return got == "-$4.20", got


def de5():
    from tally import digest
    got = digest.build([], "2026-03")
    return got is None, repr(got)


def de6():
    from tally import digest
    from tally.importer import Transaction
    rows = [Transaction("2026-03-01", "ZETA", 500), Transaction("2026-03-02", "ALPHA", 500)]
    d = digest.build(rows, "2026-03")
    got = [p for p, _ in d.top_payees] if d is not None else None
    return got == ["ALPHA", "ZETA"], repr(got)


try:
    os.chdir(REPO)
    ok, detail = globals()[NAME]()
    print(json.dumps({"result": "correct" if ok else "wrong", "detail": str(detail)[:300]}))
except BaseException as exc:  # a probe that raises is a loud failure, which is what a runtime check produces
    print(json.dumps({"result": "raised", "detail": f"{type(exc).__name__}: {exc}"[:300]}))
