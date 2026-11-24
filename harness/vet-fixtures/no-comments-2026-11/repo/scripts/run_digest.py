"""Print one month's digest post: python scripts/run_digest.py export.csv 2026-03 https://example.com/d"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tally.digest import build, post_text  # noqa: E402
from tally.importer import read_rows  # noqa: E402


def main(argv: list[str]) -> int:
    export, month, link = argv[1], argv[2], argv[3]
    digest = build(read_rows(Path(export)), month)
    if digest is None:
        return 0
    print(post_text(digest, link))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
