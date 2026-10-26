#!/usr/bin/env python3
"""Static checks for src/. Standard library only. Exit 1 on any finding."""
import ast
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

def no_print(rel, tree):
    found = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "print"
        ):
            found.append(
                "%s:%d: print() is not allowed in src/; "
                "use logging.getLogger(__name__).info(...)" % (rel, node.lineno)
            )
    return found


CHECKS = [no_print]


def source_files():
    return sorted(SRC.rglob("*.py"))


def main():
    problems = []
    for path in source_files():
        rel = path.relative_to(ROOT)
        tree = ast.parse(path.read_text(), filename=str(path))
        for check in CHECKS:
            problems.extend(check(rel, tree))
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
