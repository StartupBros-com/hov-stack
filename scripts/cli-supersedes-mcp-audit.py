#!/usr/bin/env python3
"""cli-supersedes-mcp-audit.py: a retired MCP server leaves nothing behind once its CLI exists.

Ceremony Test (harness/evidence-regime.md §1):
  consumer     harness-doctor.sh check 31 (Monday harness-weekly), and
               tests/cli-supersedes-mcp-audit.test.sh on every PR.
  gate         a finding turns the doctor red; inputs it cannot read exit 2
               and are reported as "did NOT run", never as clean.
  defect       OBSERVED, twice. seo-mcp -> dfs (#187) and mcp-gsc -> gsc each
               landed the CLI with no check in place. On 2026-09-04 the live
               settings still allowed mcp__google-search-console__* with gsc
               on PATH and no such server registered. The third retirement
               (exa -> exa-cli, dotfiles#977) is gated on this check existing
               first, so the drift is caught on arrival instead of a month on.
  delete-when  the harness stops routing data sources through CLIs, or every
               retirement row below has been clean for a year and the table
               is empty.

THE RULE
--------
Each row names one retirement: <cli>|<server-key>|<tool-prefix>|<doc-tokens>.

  cli          the replacement command on PATH, or ! for unconditional retirement
  server-key   the mcpServers key the server was registered under
  tool-prefix  the mcp__<server>__ prefix its permission entries carry
  doc-tokens   comma-separated tool names a harness doc might still cite
               (may be empty)

A row is DORMANT while its CLI is not on PATH: the MCP is still the only way
to reach that provider, so nothing about it is drift. Dormancy is what lets
this check sit green on main before a CLI ships and gate that CLI's landing.
The same rule cuts the other way: a CLI that later drops off PATH takes its
row dormant again, and a stale entry for that server stops being reported
until the CLI is back. Pruning happens while the CLI exists, or not at all.

Once the CLI is on PATH, three surfaces must be empty for that row, and each
survivor is one WARN line:

  settings   any permissions.allow / ask / deny entry starting with the
             tool prefix (a dead allow is a standing grant to a server that
             no longer exists; a dead deny hides a renamed tool)
  registry   a mcpServers entry keyed <server-key> or <server-key>-<suffix>
             in the global config (--claude-json, where http servers live)
             or in any repo .mcp.json passed as --repo-mcp-json (where stdio
             servers live per the placement doctrine; seo-mcp and the GSC
             server only ever lived there, under per-repo keys such as
             google-search-console-prbot). A repo file that does not exist
             is skipped with an info line; one that does not parse is exit 2.
  docs       any doc token, as a whole word and case-insensitively, in the
             scanned docs. --doc-dir scans that directory's top-level *.md
             only, on purpose: harness/vet-fixtures/ holds third-party
             skill fixtures under review, not harness reference docs.
             --doc-tree scans recursively; the doctor passes the memory
             mirror (memory), whose notes are loaded into sessions
             and can steer an agent at a retired tool as surely as a doc.

Optional --repo-settings-json scans project permission and approval lists.
Global project approval lists are also scanned; values are never printed.

A doc that legitimately keeps a retired tool name (a changelog line, a
retirement note) has no per-doc exception: the row-level --exception is the
only silencer, and it covers settings and registry too. Reword the doc
instead — the tokens are tool names, not concepts, so prose survives it.

A server key passed as --exception is a DOCUMENTED coexistence (the check 3
STDIO_EXCEPTIONS idiom): the row is reported and skipped, never warned.

EXIT CODES
----------
  0  every row checked, dormant, or excepted; no finding
  1  at least one WARN line
  2  did NOT run: no rows, or a settings / config / doc input could not be
     read or parsed. The doctor reports this as a warning, not a clean.

Read-only. No network, no subprocesses, no credential is opened: the global
config is parsed for its mcpServers KEYS only and no value is printed.
"""

import argparse
import glob
from decimal import Decimal
import math
import json
import os
import re
import shutil
import sys

PERMISSION_LISTS = ("allow", "ask", "deny")


def parse_row(text):
    parts = text.split("|")
    if len(parts) != 4 or not parts[0].strip() or not parts[1].strip() or not parts[2].strip():
        raise ValueError(f"malformed row (want cli|server|prefix|tokens): {text!r}")
    cli, server, prefix, tokens = (p.strip() for p in parts)
    return {
        "cli": cli,
        "server": server,
        "prefix": prefix,
        "tokens": [t.strip() for t in tokens.split(",") if t.strip()],
    }


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON object key")
        value[key] = item
    return value


def reject_constant(_value):
    raise ValueError("non-finite JSON number")


def preserving_float(text):
    value = float(text)
    # JSON rewriting must not turn overflow into Infinity, underflow into zero,
    # or a high-precision unrelated number into a different decimal value.
    if not math.isfinite(value) or Decimal(text) != Decimal(str(value)):
        raise ValueError("JSON number cannot be preserved by this parser")
    return value


def strict_json(text):
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=reject_constant,
                      parse_float=preserving_float)


def load_json(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            data = strict_json(handle.read())
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"{label} could not be read/parsed ({path}): {exc}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"{label} is not a JSON object ({path})")
    return data


def collect_docs(doc_paths, doc_dirs, doc_trees):
    docs = []
    for path in doc_paths:
        if not os.path.isfile(path):
            raise RuntimeError(f"doc missing: {path}")
        docs.append(path)
    for directory in doc_dirs:
        if not os.path.isdir(directory):
            raise RuntimeError(f"doc dir missing: {directory}")
        docs.extend(sorted(glob.glob(os.path.join(directory, "*.md"))))
    for tree in doc_trees:
        if not os.path.isdir(tree):
            raise RuntimeError(f"doc tree missing: {tree}")
        docs.extend(sorted(glob.glob(os.path.join(tree, "**", "*.md"), recursive=True)))
    return docs


def registry_keys(server, keys):
    """Registration keys that belong to <server>: exact, or <server>-<suffix> (per-repo naming)."""
    return sorted(k for k in keys if k == server or k.startswith(server + "-"))


def retired_permission(entry, server, prefix):
    """Match the exact MCP namespace or its hyphenated project aliases."""
    if not isinstance(entry, str):
        return False
    if entry.startswith(prefix):
        return True
    if not entry.startswith("mcp__") or "__" not in entry[5:]:
        return False
    namespace = entry[5:].split("__", 1)[0]
    return bool(registry_keys(server, [namespace]))


def settings_surfaces(path, data, include_projects=False):
    surfaces = [(path, data)]
    if include_projects:
        projects = data.get("projects", {})
        if not isinstance(projects, dict):
            raise RuntimeError(f"projects is not an object ({path})")
        for key, value in projects.items():
            if not isinstance(value, dict):
                raise RuntimeError(f"project settings is not an object ({path})")
            surfaces.append((f"{path}:projects[{key}]", value))
    for label, value in surfaces:
        permissions = value.get("permissions", {})
        if not isinstance(permissions, dict):
            raise RuntimeError(f"settings permissions is not an object ({label})")
        for key in PERMISSION_LISTS:
            if key in permissions and (not isinstance(permissions[key], list) or
                                       any(not isinstance(x, str) for x in permissions[key])):
                raise RuntimeError(f"settings permissions.{key} is not a list ({label})")
        for key in ("enabledMcpjsonServers", "disabledMcpjsonServers"):
            if key in value and (not isinstance(value[key], list) or
                                 any(not isinstance(x, str) for x in value[key])):
                raise RuntimeError(f"settings {key} is not a string list ({label})")
    return surfaces


def load_registries(global_path, repo_paths):
    registries = [(global_path, load_json(global_path, "global config"))]
    skipped = []
    for path in repo_paths:
        if not os.path.isfile(path):
            skipped.append(path)
            continue
        registries.append((path, load_json(path, "repo mcp config")))
    result = []
    for path, data in registries:
        servers = data.get("mcpServers", {})
        if not isinstance(servers, dict):
            raise RuntimeError(f"mcpServers is not an object ({path})")
        result.append((path, servers))
    global_data = registries[0][1]
    for project, data in global_data.get("projects", {}).items():
        servers = data.get("mcpServers", {})
        if not isinstance(servers, dict):
            raise RuntimeError(f"project mcpServers is not an object ({global_path})")
        if servers:
            result.append((f"{global_path}:projects[{project}]", servers))
    return result, skipped


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError as exc:
        raise RuntimeError(f"doc could not be read ({path}): {exc}") from exc


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--settings", required=True, help="Claude Code settings.json to scan (the live one)")
    parser.add_argument("--claude-json", required=True, help="global ~/.claude.json (mcpServers keys only are read)")
    parser.add_argument("--repo-settings-json", action="append", default=[], help="optional project settings.json/settings.local.json")
    parser.add_argument("--repo-mcp-json", action="append", default=[], help="a repo .mcp.json (keys only; missing file is skipped)")
    parser.add_argument("--doc", action="append", default=[], help="a doc file to scan for retired tool names")
    parser.add_argument("--doc-dir", action="append", default=[], help="a directory whose top-level *.md files are scanned")
    parser.add_argument("--doc-tree", action="append", default=[], help="a directory scanned recursively for *.md")
    parser.add_argument("--row", action="append", default=[], help="retirement row: cli|server-key|tool-prefix|tok,tok")
    parser.add_argument("--exception", action="append", default=[], help="server key with a documented coexistence")
    args = parser.parse_args(argv)

    try:
        rows = [parse_row(r) for r in args.row]
        if not rows:
            raise RuntimeError("no retirement rows given; nothing to audit")
        settings = load_json(args.settings, "settings")
        surfaces = settings_surfaces(args.settings, settings)
        surfaces += settings_surfaces(args.claude_json, load_json(args.claude_json, "global config"), True)
        for path in args.repo_settings_json:
            surfaces += settings_surfaces(path, load_json(path, "repo settings"))
        registries, skipped_repo_mcp = load_registries(args.claude_json, args.repo_mcp_json)
        docs = collect_docs(args.doc, args.doc_dir, args.doc_tree)
        doc_text = {path: read_text(path) for path in docs}
    except (RuntimeError, ValueError) as exc:
        print(f"did NOT run: {exc}", file=sys.stderr)
        return 2

    for path in skipped_repo_mcp:
        print(f"info: repo mcp config missing, skipped: {path}")
    exceptions = set(args.exception)
    findings = dormant = excepted = checked = 0

    for row in rows:
        cli, server, prefix, tokens = row["cli"], row["server"], row["prefix"], row["tokens"]
        if cli != "!" and shutil.which(cli) is None:
            dormant += 1
            print(f"info: {cli} not on PATH; {server} row dormant (the MCP is still the path)")
            continue
        if server in exceptions:
            excepted += 1
            print(f"info: {server} row excepted (documented coexistence with {cli})")
            continue
        checked += 1
        replacement = cli if cli != "!" else "unconditional retirement"
        reason = f"{cli} is on PATH" if cli != "!" else "retirement is unconditional"
        for label, value in surfaces:
            for list_name in PERMISSION_LISTS:
                for entry in value.get("permissions", {}).get(list_name, []):
                    if retired_permission(entry, server, prefix):
                        findings += 1
                        print(f"WARN {label}: {list_name} entry '{entry}' survives the "
                              f"{server} -> {replacement} retirement (prune it; {reason})" )
            for list_name in ("enabledMcpjsonServers", "disabledMcpjsonServers"):
                for key in registry_keys(server, value.get(list_name, [])):
                    findings += 1
                    print(f"WARN {label}: {list_name}.{key} survives retirement")
        for path, servers in registries:
            for key in registry_keys(server, servers):
                findings += 1
                # A repo .mcp.json is tracked in that repo: the fix is a commit there.
                if path == args.claude_json:
                    remedy = f"claude mcp remove --scope user {key}"
                elif path.startswith(f"{args.claude_json}:projects["):
                    remedy = f"claude mcp remove --scope local {key}, run from that project"
                else:
                    remedy = f"delete mcpServers.{key} from this file and commit it in its repo"
                print(
                    f"WARN {path}: mcpServers.{key} is still registered while "
                    f"{reason} ({remedy})"
                )
        for token in tokens:
            pattern = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(token) + r"(?![A-Za-z0-9_])", re.IGNORECASE)
            for path in docs:
                if pattern.search(doc_text[path]):
                    findings += 1
                    print(f"WARN {path}: names retired MCP tool '{token}' (repoint to {cli})")

    print(
        f"cli-supersedes-mcp: {len(rows)} row(s), {checked} checked, {dormant} dormant, "
        f"{excepted} excepted, {len(registries)} registr{'y' if len(registries) == 1 else 'ies'}, "
        f"{len(docs)} doc(s) scanned, {findings} finding(s)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
