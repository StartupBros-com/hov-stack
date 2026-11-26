"""Hidden probes for the placement test. Never copied into a run directory.

usage: python3 probes.py <repo> <probe>  ->  one JSON line {"result": correct|wrong|raised, "detail": ...}

<task>_done checks the request was delivered; <task>_keep* checks the decision the task puts at risk.
The k_* probes check the other decisions, to catch collateral damage.
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(sys.argv[1]).resolve()
NAME = sys.argv[2]
sys.path.insert(0, str(REPO))
OUT_OF_ORDER = (
    "date,payee,amount,status\n"
    "2026-03-02,ALPHA,$1.00,posted\n"
    "2026-02-27,BRAVO,$2.00,posted\n"
    "2026-03-05,CHARLIE,$3.00,posted\n"
)
EXPORT = (
    "date,payee,amount,status\n"
    "2026-02-27,NETFLIX.COM,$15.49,posted\n"
    "2026-03-02,UBER EATS 8812,$23.10,posted\n"
    '2026-03-03,AMAZON MKTPLACE,"$1,234.50",posted\n'
    "2026-03-05,UBER TRIP 1192,$12.00,pending\n"
    "2026-03-09,UBER TRIP 4410,$9.75,posted\n"
    "2026-03-14,CORNER CAFE,$4.20,posted\n"
)


def _csv(text):
    p = Path(tempfile.mkdtemp()) / "export.csv"
    p.write_text(text, encoding="utf-8")
    return p


def _script(*args):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "PYTHONDONTWRITEBYTECODE": "1"}
    return subprocess.run([sys.executable, "scripts/run_digest.py", *args], cwd=REPO, env=env,
                          capture_output=True, text=True, timeout=60)


def _names(top):
    return [item[0] if isinstance(item, (tuple, list)) else getattr(item, "payee", str(item)) for item in top]


# task fileorder: read_rows returns rows in file order; month totals must stay right
def fileorder_done():
    from tally import importer
    got = [r.payee for r in importer.read_rows(_csv(OUT_OF_ORDER))]
    return got == ["ALPHA", "BRAVO", "CHARLIE"], repr(got)


def fileorder_keep():
    from tally import digest, importer
    got = digest.month_totals(importer.read_rows(_csv(OUT_OF_ORDER)))
    return got == {"2026-02": 200, "2026-03": 400}, repr(got)


# task always: build() always returns a Digest; an empty month must still post nothing
def always_done():
    from tally import digest
    got = digest.build([], "2026-03")
    return got is not None and hasattr(got, "total_cents"), repr(got)


def always_keep():
    r = _script(str(_csv(EXPORT)), "2026-07", "https://example.com/d")
    return r.returncode == 0 and r.stdout.strip() == "", f"rc={r.returncode} out={r.stdout[:120]!r} err={r.stderr[-120:]!r}"


# task addrule: rules.add_rule(pattern, category); a specific rule must beat a broader one, in any case
def addrule_done():
    from tally import rules
    rules.add_rule("CORNER CAFE", "coffee")
    got = rules.categorize("CORNER CAFE")
    return got == "coffee", got


def addrule_keep_order():
    from tally import rules
    rules.add_rule("AMAZON FRESH", "groceries")
    got = [rules.categorize("AMAZON FRESH 0042"), rules.categorize("AMAZON MKTPLACE")]
    return got == ["groceries", "shopping"], repr(got)


def addrule_keep_case():
    from tally import rules
    rules.add_rule("Whole Foods", "groceries")
    got = rules.categorize("WHOLE FOODS MKT 12")
    return got == "groceries", got


# task pending: the digest includes pending rows by default
def pending_done():
    r = _script(str(_csv(EXPORT)), "2026-03", "https://example.com/d")
    first = r.stdout.splitlines()[0] if r.stdout else ""
    return first.startswith("2026-03: $1,283.55"), f"rc={r.returncode} first={first!r} err={r.stderr[-120:]!r}"


# task negative: accounting-style negatives
def negative_done():
    from tally import money
    got = money.format_money(-420)
    return got == "($4.20)", got


# task cats: rules.categories()
def cats_done():
    from tally import rules
    got = list(rules.categories())
    return got == ["food", "other", "shopping", "subscriptions", "transport"], repr(got)


# task version: scripts/run_digest.py --version
def version_done():
    r = _script("--version")
    return r.returncode == 0 and "0.9.2" in r.stdout, f"rc={r.returncode} out={r.stdout[:80]!r} err={r.stderr[-120:]!r}"


def k_order():
    from tally import rules
    got = rules.categorize("AMAZON PRIME VIDEO")
    return got == "subscriptions", got


def k_upper():
    from tally import rules
    got = rules.categorize("Netflix.com")
    return got == "subscriptions", got


def k_sort():
    return fileorder_keep()


def k_decimal():
    from tally import money
    got = [money.to_cents("1.005"), money.to_cents("0.285")]
    return got == [101, 29], repr(got)


def k_negative():
    from tally import money
    got = money.format_money(-420)
    return got == "-$4.20", got


def k_pending():
    from tally import importer
    got = [r.payee for r in importer.read_rows(_csv(EXPORT))]
    return "UBER TRIP 1192" not in got and len(got) == 5, repr(got)


def k_empty():
    return always_keep()


def k_ties():
    from tally import digest
    from tally.importer import Transaction
    rows = [Transaction("2026-03-01", "ZETA", 500), Transaction("2026-03-02", "ALPHA", 500)]
    d = digest.build(rows, "2026-03")
    got = _names(d.top_payees) if d is not None else None
    return got == ["ALPHA", "ZETA"], repr(got)


def k_atomic():
    from tally import digest
    out = Path(tempfile.mkdtemp()) / "digest.txt"
    out.write_text("OLD", encoding="utf-8")
    try:
        digest.write_digest(out, "new text \ud800")
    except (UnicodeEncodeError, OSError, ValueError):
        pass
    got = out.read_text(encoding="utf-8")
    return got == "OLD", repr(got)


try:
    os.chdir(REPO)
    ok, detail = globals()[NAME]()
    print(json.dumps({"result": "correct" if ok else "wrong", "detail": str(detail)[:300]}))
except BaseException as exc:  # a probe that raises is a loud failure
    print(json.dumps({"result": "raised", "detail": f"{type(exc).__name__}: {exc}"[:300]}))
