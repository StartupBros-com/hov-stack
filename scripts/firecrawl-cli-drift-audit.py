#!/usr/bin/env python3
"""KTD11: compare the hand-maintained verb map with offline vendor help.

Consumer: harness-doctor check 32 and its planted-negative shell suite.
Help-text drift only: silent Spark 1 -> spark-2 routing and the parse format
undercount pass unchanged help. Billing and model routing need manual review.
The parse --only-main-content API-side default is true, but CLI 1.19.26 help
states false; the map deliberately records the CLI text. The injection check
has no exposed CLI option (see the map's notes), so no default can be checked.
Settings are read for permissions.allow keys only; no values elsewhere in the
settings or vendor diagnostics are printed. No data command or network call.
Exit 0: clean/dormant; 1: WARN findings; 2: could not run, never a clean.
"""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


# The Firecrawl MCP retired on 2026-09-13 (#1178): no allow entry may survive.
APPROVED = set()
NAME = r"[a-z][a-z0-9-]*"
FLAG = r"--[a-z-]+"


def load_json(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"{label} could not be read/parsed ({path})") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"{label} is not an object")
    return data


def load_map(path):
    data = load_json(path, "verb map")
    try:
        assert data["schema_version"] == 1
        assert isinstance(data["vendor_version"], str) and data["vendor_version"]
        commands, groups = data["commands"], data["command_groups"]
        assert isinstance(commands, dict) and commands
        assert isinstance(groups, dict) and groups.get("")
        for parent, names in groups.items():
            assert parent == "" or parent in commands
            assert isinstance(names, list) and names
            assert all(isinstance(n, str) and re.fullmatch(NAME, n) for n in names)
        for command, row in commands.items():
            assert re.fullmatch(rf"{NAME}(?: {NAME})*", command)
            parent, _, name = command.rpartition(" ")
            assert name in groups[parent]
            assert isinstance(row, dict)
            flags, defaults = row["flags"], row["defaults"]
            assert isinstance(flags, list) and flags
            assert all(isinstance(f, str) and re.fullmatch(FLAG, f) for f in flags)
            assert len(flags) == len(set(flags))
            assert isinstance(defaults, dict) and set(defaults) <= set(flags)
            assert all(v is None or isinstance(v, str) for v in defaults.values())
    except (AssertionError, KeyError, TypeError) as exc:
        raise RuntimeError("verb map has an invalid schema") from exc
    return data


def tokenize(text, label):
    """Read declaration rows, not flag mentions in descriptions or examples."""
    if not re.search(r"^Usage:\s+firecrawl\b", text, re.MULTILINE):
        raise RuntimeError(f"{label} did not return recognizable help")
    section = None
    commands, options = set(), {}
    current = None
    for line in text.splitlines():
        if line and not line[0].isspace():
            section = line.strip()
            current = None
            continue
        if section == "Commands:":
            match = re.match(rf"^  ({NAME})(?:\|{NAME})*(?=\s|$)", line)
            if match:
                commands.add(match[1])
        elif section == "Options:":
            match = re.match(rf"^\s+(?:-[A-Za-z],\s+)?({FLAG})(?=\s|$)", line)
            if match:
                current = match[1]
                options[current] = line[match.end():]
            elif current and line.strip():
                options[current] += " " + line.strip()
    defaults = {}
    for flag, description in options.items():
        # Commander also uses '(1-300, default: 30)' and wraps long defaults.
        match = re.search(r"\([^()]*?\bdefault:\s*([^)]*)\)", description)
        defaults[flag] = " ".join(match[1].split()) if match else None
    return commands, defaults


def live_help(binary, command):
    label = "firecrawl" + (" " + command if command else "") + " --help"
    try:
        result = subprocess.run(
            [binary, *command.split(), "--help"],
            capture_output=True,
            text=True,
            timeout=20,
            env=None,
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as exc:
        raise RuntimeError(f"{label} could not run ({type(exc).__name__})") from exc
    if result.returncode:
        raise RuntimeError(f"{label} exited {result.returncode}")
    return tokenize(result.stdout, label)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--settings", required=True)
    parser.add_argument(
        "--verb-map",
        default=Path(__file__).resolve().parents[1] / "bin/firecrawl-cli-verbmap.json",
    )
    args = parser.parse_args(argv)
    binary = shutil.which("firecrawl")
    if binary is None:
        if shutil.which("firecrawl-cli") is not None:
            # The wrapper is deployed but its vendor is gone: every vendor-bound
            # verb fails, so this is a finding, never a dormant pass.
            print("WARN firecrawl-cli-drift: firecrawl-cli is on PATH but the vendor firecrawl is not")
            print("firecrawl-cli-drift: 0 subcommand(s), 0 flag(s), 0 default(s) checked, 1 finding(s)")
            return 1
        print("info: firecrawl not on PATH; drift check dormant")
        print("firecrawl-cli-drift: 0 subcommand(s), 0 flag(s), 0 default(s) checked, 0 finding(s)")
        return 0

    try:
        verbmap = load_map(args.verb_map)
        settings = load_json(args.settings, "settings")
        permissions = settings.get("permissions", {})
        if not isinstance(permissions, dict):
            raise RuntimeError("settings permissions is not an object")
        allow = permissions.get("allow", [])
        if not isinstance(allow, list):
            raise RuntimeError("settings permissions.allow is not a list")
        if not all(isinstance(entry, str) for entry in allow):
            raise RuntimeError("settings permissions.allow contains a non-string entry")
        allowed = {entry for entry in allow if entry.startswith("mcp__firecrawl__")}
        help_text = {"": live_help(binary, "")}
        # Parents before children: a removed command warns without invoking it.
        for command in sorted(verbmap["commands"], key=lambda c: (c.count(" "), c)):
            parent, _, name = command.rpartition(" ")
            if parent in help_text and name in help_text[parent][0]:
                help_text[command] = live_help(binary, command)
    except RuntimeError as exc:
        print(f"did NOT run: {exc}", file=sys.stderr)
        return 2

    findings = []
    subcommands = flags = defaults = 0
    for parent, expected in verbmap["command_groups"].items():
        if parent not in help_text:
            continue
        actual = help_text[parent][0]
        subcommands += len(expected)
        prefix = parent + " " if parent else ""
        for name in sorted(set(expected) - actual):
            findings.append(f"missing subcommand '{prefix}{name}'")
        for name in sorted(actual - set(expected)):
            findings.append(f"new subcommand '{prefix}{name}'; update the verb map")
    for command, row in verbmap["commands"].items():
        if command not in help_text:
            continue
        actual = help_text[command][1]
        for flag in row["flags"]:
            flags += 1
            if flag not in actual:
                findings.append(f"{command}: missing flag {flag}")
        for flag, expected in row["defaults"].items():
            if flag not in actual:
                continue
            defaults += 1
            if actual[flag] != expected:
                before = repr(expected) if expected is not None else "<not stated>"
                after = repr(actual[flag]) if actual[flag] is not None else "<not stated>"
                findings.append(f"{command} {flag}: default changed from {before} to {after}")
    for entry in sorted(allowed - APPROVED):
        findings.append(f"surviving permissions.allow entry '{entry}' (the Firecrawl MCP is retired, #1178)")
    for finding in findings:
        print(f"WARN firecrawl-cli-drift: {finding}")
    print(
        f"firecrawl-cli-drift: {subcommands} subcommand(s), {flags} flag(s), "
        f"{defaults} default(s) checked, {len(findings)} finding(s)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
