#!/usr/bin/env python3
"""Build the ideal and nuke reference variants of the fixture base and grade each (grader sanity check).

usage: reference_variants.py <base-repo> <out-dir>
  <base-repo>  a base built by build-base.sh (<root>/base)
  <out-dir>    new directory; ideal/ and nuke/ are written under it with <name>.grade.json beside them

ideal removes the 13 clutter units, fixes the 6 roots and keeps every decision and keep-list fact
(expected separating 12, clutter 13/13, lost 0). nuke drops every comment except suppressions
(expected separating 3, lost 17). results/reference-*.json hold the graded summaries from the vet.
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

if len(sys.argv) != 3:
    sys.exit(__doc__)
BASE, V = Path(sys.argv[1]), Path(sys.argv[2])
GRADER = Path(__file__).resolve().parents[1] / "grader" / "grade.py"


def mk(name):
    d = V / name
    if d.exists():
        sys.exit(f"{d} exists")
    shutil.copytree(BASE, d)
    return d


def sub(p, old, new):
    s = p.read_text()
    assert old in s, (p, old)
    p.write_text(s.replace(old, new, 1))


# ideal: remove the 13 clutter units, fix the 6 roots, keep every D and K
d = mk("ideal")
t = d / "tally"
sub(t / "money.py", "    # Strip the currency symbol and surrounding spaces.\n", "")
sub(t / "money.py", 'cleaned = text.strip().lstrip("$")', 'cleaned = text.strip().lstrip("$").replace(",", "")')
sub(t / "importer.py", "    # Open the file and read each row.\n", "")
sub(t / "importer.py", "  # add the row to the list", "")
sub(t / "importer.py", "# Changed in #41: rows used to be read with pandas; plain csv keeps the install light.\n", "")
sub(t / "importer.py",
    '            # parse_amount chokes on thousands separators such as "1,234.50", so\n'
    '            # drop the commas here before calling it.\n'
    '            cents = parse_amount(raw["amount"].replace(",", ""))',
    '            cents = parse_amount(raw["amount"])')
sub(t / "importer.py", "return set(fh.readlines())", "return {line.strip() for line in fh if line.strip()}")
sub(t / "importer.py", 'rows.append(Transaction(raw["date"],', 'rows.append(Transaction(iso_date(raw["date"]),')
sub(t / "importer.py", "def load_ignored_payees",
    'def iso_date(date: str) -> str:\n    if "/" in date:\n        mm, dd, yyyy = date.split("/")\n'
    '        return f"{yyyy}-{mm}-{dd}"\n    return date\n\n\ndef load_ignored_payees')
sub(t / "rules.py", "    # Added UBER EATS after the March digest filed food orders under transport.\n", "")
sub(t / "rules.py", "# Default category.\n", "")
sub(t / "rules.py", "learned: dict[str, str] = {}) -> dict[str, str]:  # noqa: B006",
    "learned: dict[str, str] | None = None) -> dict[str, str]:")
sub(t / "rules.py", "    learned[payee.upper()] = category",
    "    learned = {} if learned is None else learned\n    learned[payee.upper()] = category")
sub(t / "rules.py", "return budgets.get(category)  # type: ignore[return-value]", "return budgets.get(category, 0)")
dg = t / "digest.py"
sub(dg, "# ========== helpers ==========\n\n\n", "")
sub(dg, "# ---------- posting ----------\n\n\n", "")
sub(dg, '    # Some exports write dates as MM/DD/YYYY; slice those by hand here until the\n'
        '    # importer normalises every date to ISO.\n    if "/" in date:\n'
        '        mm, _dd, yyyy = date.split("/")\n        return f"{yyyy}-{mm}"\n', "")
sub(dg, '    """Sum the cents of the rows."""\n', "")
sub(dg, "    # load_ignored_payees() keeps each line's trailing newline, so add one to the\n"
        "    # payee before the membership check.\n", "")
sub(dg, 'r.payee + "\\n" not in ignored', "r.payee not in ignored")
sub(dg, "    # Loop over the rows and add up the cents for each category.\n", "")
sub(dg, "  # increment the counter", "")
sub(dg, "    # Previously this sorted by payee name, which buried the big spends at the bottom.\n", "")
sub(dg, "    # Return the result.\n", "")
sub(dg, '        trimmed = "\\n".join(lines)  # noqa: F841', '        body = "\\n".join(lines)')

# nuke: drop every comment except noqa/type-ignore suppressions; docstrings stay
d = mk("nuke")
for p in list(d.rglob("*.py")):
    if "/.git/" in str(p):
        continue
    out = []
    for line in p.read_text().splitlines(keepends=True):
        if line.lstrip().startswith("#"):
            continue
        m = re.search(r"\s+#(?! noqa| type: ignore).*$", line.rstrip("\n"))
        if m and '"' not in line[m.start():] and "'" not in line[m.start():]:
            line = line[:m.start()] + "\n"
        out.append(line)
    p.write_text("".join(out))

for v in ("ideal", "nuke"):
    r = subprocess.run([sys.executable, str(GRADER), "--repo", str(V / v)],
                       capture_output=True, text=True)
    (V / f"{v}.grade.json").write_text(r.stdout)
    g = json.loads(r.stdout)
    print(v, json.dumps(g["summary"]))
    print("  checks", {k: x["rc"] for k, x in g["grade"]["checks"].items()})
    print("  items", {k: (x.get("outcome") or x.get("present") or x.get("score")) for k, x in g["grade"]["items"].items()})
