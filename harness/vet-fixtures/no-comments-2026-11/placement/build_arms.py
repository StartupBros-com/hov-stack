#!/usr/bin/env python3
"""build_arms.py <clean-variant-dir> <out-root> - build one base repository per placement arm.

Every arm holds the same code. Only the place where the 14 decisions are recorded differs:
comment (at the code), none, tests, doc, claudemd, history, stale (three false comments).
Each base is a fresh git repository so no arm can recover another arm's record from history.
"""
import shutil
import subprocess
import sys
from pathlib import Path

SRC = Path(sys.argv[1])
ROOT = Path(sys.argv[2])
BASES = ROOT / "bases"
HERE = Path(__file__).resolve().parent

# key, file, exact text in the clean variant, text left when the record is removed, symbol, fact
D = [
    ("order", "tally/rules.py",
     "# Order matters: the first matching rule wins, so a specific payee sits above the\n"
     "# broader pattern it would otherwise fall into.\n", "", "RULES",
     "Order matters: the first matching rule wins, so a specific payee sits above the broader pattern it would "
     "otherwise fall into."),
    ("upper", "tally/rules.py",
     "    # Match on the upper-cased payee so every rule can be written once, in capitals.\n", "", "categorize",
     "Match on the upper-cased payee so every rule can be written once, in capitals."),
    ("maxrows", "tally/importer.py",
     "MAX_ROWS = 50_000  # a busy account writes ~12k rows a year; past 50k it is the wrong export\n",
     "MAX_ROWS = 50_000\n", "MAX_ROWS",
     "A busy account writes ~12k rows a year; past 50k rows it is the wrong export."),
    ("iso", "tally/importer.py",
     "    date: str  # ISO date, YYYY-MM-DD; month_of() slices the first seven characters\n",
     "    date: str\n", "Transaction.date",
     "ISO date, YYYY-MM-DD; month_of() slices the first seven characters."),
    ("pending", "tally/importer.py",
     "            # Skip pending rows: the digest reports settled spending only, and a\n"
     "            # pending row's amount can still change before it settles.\n", "", "read_rows",
     "Skip pending rows: the digest reports settled spending only, and a pending row's amount can still change "
     "before it settles."),
    ("sort", "tally/importer.py",
     "    # Sort by date: month_totals() groups consecutive rows, so it relies on this order.\n", "", "read_rows",
     "Sort by date: month_totals() groups consecutive rows, so it relies on this order."),
    ("decimal", "tally/money.py",
     "    # Decimal, not float: binary floats drift by a cent over a long statement.\n", "", "to_cents",
     "Decimal, not float: binary floats drift by a cent over a long statement."),
    ("negative", "tally/money.py",
     "    # A negative total keeps its sign in front of the dollar sign (-$4.20), the\n"
     "    # form the post template expects.\n", "", "format_money",
     "A negative total keeps its sign in front of the dollar sign (-$4.20), the form the post template expects."),
    ("topn", "tally/digest.py",
     "TOP_N = 5  # the post has room for five payee lines once the header and link are counted\n",
     "TOP_N = 5\n", "TOP_N",
     "The post has room for five payee lines once the header and link are counted."),
    ("ignored", "tally/digest.py",
     "    # Ignored payees are dropped before the totals, not after, so they never count\n"
     "    # toward a category budget.\n", "", "build",
     "Ignored payees are dropped before the totals, not after, so they never count toward a category budget."),
    ("empty", "tally/digest.py",
     "    # An empty month posts nothing: a zero digest reads as an outage to subscribers.\n", "", "build",
     "An empty month posts nothing: a zero digest reads as an outage to subscribers."),
    ("refund", "tally/digest.py",
     "    # A refund counts in the month it lands, not the month of the original charge,\n"
     "    # so a month can total below zero.\n", "", "build",
     "A refund counts in the month it lands, not the month of the original charge, so a month can total below "
     "zero."),
    ("ties", "tally/digest.py",
     "    # Ties break on payee name so two runs over the same file print the same digest.\n", "", "build",
     "Ties break on payee name so two runs over the same file print the same digest."),
    ("atomic", "tally/digest.py",
     "    # Write a temp file and rename it, so a crash mid-write never leaves a half\n"
     "    # digest for the poster to pick up.\n", "", "write_digest",
     "Write a temp file and rename it, so a crash mid-write never leaves a half digest for the poster to pick "
     "up."),
]

# The three comments that are false in the stale arm. Each contradicts the code beside it.
STALE = {
    "order": "# Order does not matter: the longest matching pattern wins, so a new rule can go\n"
             "# anywhere in this list.\n",
    "sort": "    # Sorted by date so the preview reads in order; nothing else depends on this order.\n",
    "empty": "    # None here only saves the caller a little work; an empty month can be posted like any other.\n",
}

DOCS = [
    ("0001-categorisation-rules.md", "Categorisation rules", ["order", "upper"]),
    ("0002-money.md", "Money handling and formatting", ["decimal", "negative"]),
    ("0003-importing-exports.md", "Importing bank exports", ["maxrows", "iso", "pending", "sort"]),
    ("0004-digest-content.md", "What goes into a digest", ["topn", "ignored", "empty", "refund", "ties"]),
    ("0005-posting.md", "Writing the digest for the poster", ["atomic"]),
]

COMMITS = [
    ("Add money helpers and project tooling",
     ["Makefile", "pyproject.toml", "README.md", "tally/__init__.py", "tally/money.py"], ["decimal", "negative"]),
    ("Add the bank export importer", ["tally/importer.py"], ["maxrows", "iso", "pending", "sort"]),
    ("Add payee categorisation rules", ["tally/rules.py"], ["order", "upper"]),
    ("Add the monthly digest and its post", ["tally/digest.py", "scripts"],
     ["topn", "ignored", "empty", "refund", "ties", "atomic"]),
    ("Add tests", ["tests"], []),
]

BY = {d[0]: d for d in D}
ENV = {"GIT_AUTHOR_NAME": "tally", "GIT_AUTHOR_EMAIL": "tally@example.invalid", "GIT_COMMITTER_NAME": "tally",
       "GIT_COMMITTER_EMAIL": "tally@example.invalid", "GIT_AUTHOR_DATE": "2026-11-01T12:00:00Z",
       "GIT_COMMITTER_DATE": "2026-11-01T12:00:00Z", "PATH": "/usr/bin:/bin", "HOME": str(ROOT)}


def git(repo, *args):
    subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *args], cwd=repo,
                   env=ENV, check=True, capture_output=True)


def fresh(name):
    dest = BASES / name
    if dest.exists():
        sys.exit(f"{dest} exists; move it aside first")
    shutil.copytree(SRC, dest, ignore=shutil.ignore_patterns(".git", "__pycache__", ".mypy_cache", ".ruff_cache"))
    return dest


def swap(repo, key, new):
    _, rel, old, _, _, _ = BY[key]
    p = repo / rel
    s = p.read_text(encoding="utf-8")
    if s.count(old) != 1:
        sys.exit(f"{key}: expected the comment exactly once in {rel}")
    p.write_text(s.replace(old, new, 1), encoding="utf-8")


def strip_all(repo):
    for key, _, _, bare, _, _ in D:
        swap(repo, key, bare)


def one_commit(repo):
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "tally 0.9.2")


BASES.mkdir(parents=True, exist_ok=True)

one_commit(fresh("comment"))

r = fresh("none")
strip_all(r)
one_commit(r)

r = fresh("tests")
strip_all(r)
shutil.copy(HERE / "test_decisions.py", r / "tests" / "test_decisions.py")
one_commit(r)

r = fresh("doc")
strip_all(r)
(r / "docs" / "decisions").mkdir(parents=True)
index = ["# Decisions", "", "Why tally does what it does, where the code cannot say so itself.", ""]
for fname, title, keys in DOCS:
    num = fname.split("-")[0]
    body = [f"# {num} {title}", "", "Status: accepted", "", "## Decisions", ""]
    for k in keys:
        _, rel, _, _, sym, fact = BY[k]
        body.append(f"- `{rel}`, `{sym}`: {fact}")
    (r / "docs" / "decisions" / fname).write_text("\n".join(body) + "\n", encoding="utf-8")
    index.append(f"- [{num} {title}]({fname})")
(r / "docs" / "decisions" / "README.md").write_text("\n".join(index) + "\n", encoding="utf-8")
readme = r / "README.md"
readme.write_text(readme.read_text(encoding="utf-8").rstrip("\n")
                  + "\n\nDesign decisions and the reasons behind them are recorded in `docs/decisions/`.\n",
                  encoding="utf-8")
one_commit(r)

r = fresh("claudemd")
strip_all(r)
lines = ["# tally", "", "`make check` runs the linter, the type checker and the unit tests.", "",
         "## Decisions the code does not show", ""]
for _, rel, _, _, sym, fact in D:
    lines.append(f"- `{rel}`, `{sym}`: {fact}")
(r / "CLAUDE.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
one_commit(r)

r = fresh("history")
strip_all(r)
git(r, "init", "-q")
for subject, paths, keys in COMMITS:
    msg = subject
    if keys:
        msg += "\n\nWhy it is built this way:\n\n" + "\n".join(
            f"- {BY[k][1]}, {BY[k][4]}: {BY[k][5]}" for k in keys)
    git(r, "add", "--", *paths)
    git(r, "commit", "-q", "-m", msg)
left = subprocess.run(["git", "status", "--porcelain"], cwd=r, env=ENV, capture_output=True, text=True).stdout
if left.strip():
    sys.exit(f"history arm left files uncommitted:\n{left}")

r = fresh("stale")
for key, text in STALE.items():
    swap(r, key, text)
one_commit(r)

for arm in ("comment", "none", "tests", "doc", "claudemd", "history", "stale"):
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=BASES / arm, env=ENV,
                          capture_output=True, text=True).stdout.strip()
    n = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=BASES / arm, env=ENV,
                       capture_output=True, text=True).stdout.strip()
    print(f"{arm:9} head={head} commits={n}")
