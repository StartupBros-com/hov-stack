#!/usr/bin/env python3
"""Check the README's install line without running documentation.

The install smoke starts from actions/checkout, so it cannot catch a typo in
the documented clone (observed in dotfiles#652). Python suite discovery reads
the real README through this check (tests/test_readme.py), including README-only
changes. Retire this guard if a replacement exercises that command from the same
documentation.

The install section's bash block must open with INSTALL_LINE exactly: it is the
line the post-flip clean-machine run executes as written (restructure plan U26),
so any other spelling is a change to that run. This is an offline identity check,
not a shell interpreter, URL reachability check, anonymous access claim, or proof
that the installation works.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_HEADING = "Install, about a minute"
INSTALL_LINE = "git clone --depth 1 https://github.com/StartupBros-com/hov-stack ~/hov-stack && cd ~/hov-stack && ./setup"


def install_block(readme: str) -> str:
    """Read visible headings/fences; comments and fenced examples cannot win."""
    sections = 0
    in_section = False
    in_comment = False
    fence = None
    body = []
    blocks = []
    for raw in readme.splitlines():
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}[ \t]*", raw):
                fence = None
                if in_section:
                    blocks.append("\n".join(body))
                body = []
            elif in_section:
                body.append(raw)
            continue
        # HTML comments are Markdown only outside fenced code blocks.
        line = ""
        rest = raw
        while rest:
            marker = "-->" if in_comment else "<!--"
            before, found, after = rest.partition(marker)
            if not in_comment:
                line += before
            if not found:
                break
            in_comment = not in_comment
            rest = after
        heading = re.fullmatch(r" {0,3}(#{1,2})[ \t]+(.*)", line)
        if heading:
            title = re.sub(r"[ \t]+#+[ \t]*$", "", heading[2]).strip()
            title = re.sub(r"[ \t]+", " ", title)
            in_section = heading[1] == "##" and title == INSTALL_HEADING
            sections += int(in_section)
        opening = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", line)
        if opening:
            fence = opening[1]
            if in_section and opening[2].strip() != "bash":
                raise ValueError(f"{INSTALL_HEADING!r} needs a bash code block")
    if sections != 1:
        raise ValueError(f"expected exactly one visible {INSTALL_HEADING!r} section")
    if len(blocks) != 1 or (fence is not None and in_section):
        raise ValueError(f"{INSTALL_HEADING!r} needs exactly one closed bash code block")
    return blocks[0]


def without_comment(line: str) -> str:
    """A shell comment starts at a word boundary, never inside an argument."""
    quote = None
    escaped = False
    for i, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote is not None:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "#" and (i == 0 or line[i - 1] in " \t;&|()<>"):
            return line[:i]
    return line


def check_clone(readme: str) -> None:
    """Raise ValueError unless the install block opens with INSTALL_LINE and clones once."""
    lines = [without_comment(line).strip() for line in install_block(readme).splitlines()]
    lines = [line for line in lines if line]
    if not lines or lines[0] != INSTALL_LINE:
        found = lines[0] if lines else "nothing"
        raise ValueError(f"the install block must open with {INSTALL_LINE!r}, found {found!r}")
    for line in lines[1:]:
        words = line.split()
        if "git" in words and "clone" in words[words.index("git") + 1:]:
            raise ValueError("the install block must contain exactly one git clone command")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("readme", nargs="?", type=Path, default=REPO_ROOT / "README.md")
    args = parser.parse_args()
    try:
        content = args.readme.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        print(f"cannot read {args.readme}: {exc}", file=sys.stderr)
        return 1
    try:
        check_clone(content)
    except ValueError as exc:
        print(f"{args.readme}: {exc}", file=sys.stderr)
        return 1
    print("install line matches; network access and installation were not tested")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
