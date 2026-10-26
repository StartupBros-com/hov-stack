#!/usr/bin/env python3
"""Build the ablation sandbox.

Isolates the CLAUDE.md package-manager rule as the ONLY signal about which
package manager to use:
  - scratch projects carry NO lockfile (a pnpm-lock.yaml would leak the answer)
  - every package manager on PATH is a shim that logs its argv and exits 0
    (no network, no installs, no side effects, perfect measurement)
"""
import os, json, stat, textwrap, shutil

ROOT = os.path.dirname(os.path.abspath(__file__))
SHIMS = os.path.join(ROOT, "shims")
WORK = os.path.join(ROOT, "work")

PMS = ["npm", "pnpm", "yarn", "bun", "pip", "pip3", "uv", "pipx", "poetry", "conda"]

SHIM = """#!/bin/sh
# ablation shim: log the invocation, do nothing, succeed.
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$PM_LOG"
exit 0
"""


def build_shims():
    shutil.rmtree(SHIMS, ignore_errors=True)
    os.makedirs(SHIMS, exist_ok=True)
    for pm in PMS:
        p = os.path.join(SHIMS, pm)
        with open(p, "w") as fh:
            fh.write(SHIM)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    print(f"built {len(PMS)} shims in {SHIMS}")


def build_projects():
    shutil.rmtree(WORK, ignore_errors=True)

    # ---- JS project: package.json, NO lockfile, no packageManager field ----
    js = os.path.join(WORK, "js")
    os.makedirs(os.path.join(js, "src"), exist_ok=True)
    with open(os.path.join(js, "package.json"), "w") as fh:
        json.dump({
            "name": "widget-service",
            "version": "0.1.0",
            "private": True,
            "type": "module",
            "scripts": {"build": "tsc -p .", "test": "node --test"},
            "dependencies": {},
        }, fh, indent=2)
    with open(os.path.join(js, "src", "index.js"), "w") as fh:
        fh.write(textwrap.dedent("""\
            export function parseWidget(raw) {
              // TODO: validate `raw` before returning it
              return raw;
            }
            """))
    with open(os.path.join(js, "README.md"), "w") as fh:
        fh.write("# widget-service\n\nA small internal service.\n")

    # ---- Python project: pyproject.toml, NO lockfile ----
    py = os.path.join(WORK, "py")
    os.makedirs(os.path.join(py, "src"), exist_ok=True)
    with open(os.path.join(py, "pyproject.toml"), "w") as fh:
        fh.write(textwrap.dedent("""\
            [project]
            name = "report-fetcher"
            version = "0.1.0"
            requires-python = ">=3.11"
            dependencies = []

            [build-system]
            requires = ["setuptools"]
            build-backend = "setuptools.build_meta"
            """))
    with open(os.path.join(py, "src", "fetch.py"), "w") as fh:
        fh.write(textwrap.dedent("""\
            def fetch_report(url: str) -> str:
                # TODO: perform the HTTP request
                raise NotImplementedError
            """))
    with open(os.path.join(py, "README.md"), "w") as fh:
        fh.write("# report-fetcher\n\nFetches reports.\n")

    for d in (js, py):
        for junk in ("pnpm-lock.yaml", "package-lock.json", "yarn.lock", "uv.lock",
                     "poetry.lock", "requirements.txt"):
            p = os.path.join(d, junk)
            if os.path.exists(p):
                os.remove(p)
    print(f"built scratch projects in {WORK} (verified lockfile-free)")


def extract_pkg_section():
    """Pull the verbatim Package Managers section out of the real CLAUDE.md."""
    src = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "CLAUDE.md")
    lines = open(src, encoding="utf-8").read().splitlines()
    out, on = [], False
    for ln in lines:
        if ln.startswith("## Package Managers"):
            on = True
            out.append(ln)
            continue
        if on and ln.startswith("## ") and not ln.startswith("## Package Managers"):
            break
        if on:
            out.append(ln)
    sec = "\n".join(out).strip()
    p = os.path.join(ROOT, "pkg_section.md")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(sec + "\n")
    print(f"extracted Package Managers section: {len(sec.split())} words -> {p}")
    return sec


if __name__ == "__main__":
    build_shims()
    build_projects()
    sec = extract_pkg_section()
    print("\n--- section verbatim ---")
    print(sec)
