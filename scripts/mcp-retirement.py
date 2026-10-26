#!/usr/bin/env python3
"""Plan retirement of shadcn/default GA4/Discord MCPs; apply only in a quiet window.

Only explicitly supplied files are written. Each project's own .mcp.json is read
for its server keys: a project that still registers a retired server keeps that
server's approvals, local registrations and permission entries (an unreadable
one keeps all of them). No tools or provider APIs run.
Runtime JSON may contain secrets: summaries name keys only; backups are mode 600.
Compare-before-replace detects observed edits, not non-cooperating writers racing
with rename. --quiescent is required to apply; never run apply beside the fleet.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

RETIRED = ("shadcn", "discord", "google-analytics")
APPROVALS = ("enabledMcpjsonServers", "disabledMcpjsonServers")
spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("cli-supersedes-mcp-audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def retired_servers(key):
    return {server for server in RETIRED if isinstance(key, str) and audit.registry_keys(server, [key])}


def still_registered(root):
    """Retired servers <root>/.mcp.json still registers, and why; a missing file keeps none."""
    if root is None:
        return set(), ""
    path = Path(root) / ".mcp.json"
    if not path.exists():
        return set(), ""
    try:
        data = audit.strict_json(path.read_bytes())
        servers = data.get("mcpServers", {}) if isinstance(data, dict) else None
        if not isinstance(servers, dict):
            raise ValueError("mcpServers must be an object")
    except (OSError, ValueError, RuntimeError, TypeError):
        # Never surface parser text; the file can hold credentials.
        return set(RETIRED), f"{path} is unreadable"
    return set().union(*map(retired_servers, servers)), f"registered in {path}"


def project_root(path):
    """<repo> for a <repo>/.claude/settings*.json target; ~/.claude is global, not a project."""
    parent = path.parent
    if parent.name != ".claude" or parent == Path.home() / ".claude":
        return None
    return parent.parent


def transform(data, root=None, kept=None):
    """Remove retired entries; <kept>, when given, collects what a project still uses."""
    audit.settings_surfaces("input", data, True)  # preflight types, including every project
    changes = []
    kept = [] if kept is None else kept

    def visit(value, label, keep, reason):
        held = set()

        def drop(servers):
            held.update(servers & keep)
            return bool(servers - keep)

        if "mcpServers" in value:
            servers = value["mcpServers"]
            if not isinstance(servers, dict):
                raise ValueError("mcpServers must be an object")
            for key in list(servers):
                if drop(retired_servers(key)):
                    del servers[key]
                    changes.append(f"{label}mcpServers.{key}")
        for name in APPROVALS:
            old = value.get(name, [])
            removed = [x for x in old if drop(retired_servers(x))]
            if removed:
                value[name] = [x for x in old if x not in removed]
                changes.extend(f"{label}{name}.{key}" for key in removed)
        for name, old in value.get("permissions", {}).items():
            if name not in audit.PERMISSION_LISTS:
                continue
            removed = [x for x in old if drop({s for s in RETIRED if audit.retired_permission(x, s, f"mcp__{s}__")})]
            if removed:
                value["permissions"][name] = [x for x in old if x not in removed]
                changes.append(f"{label}permissions.{name}: {len(removed)} retired entries")
        if held:
            kept.append(f"{label.rstrip('.') or 'top level'}: {', '.join(sorted(held))} ({reason})")

    visit(data, "", *still_registered(root))
    for key, value in data.get("projects", {}).items():
        visit(value, f"projects[{key}].", *still_registered(key))
    return data, changes


def prepare(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"target must be a regular, non-symlink file: {path}")
    info = path.stat()
    original = path.read_bytes()
    try:
        data = audit.strict_json(original)
        if not isinstance(data, dict):
            raise ValueError("JSON root must be an object")
        kept = []
        changed, changes = transform(data, project_root(path), kept)
        updated = (json.dumps(changed, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()
    except (ValueError, RuntimeError, TypeError) as exc:
        # Parser exceptions can quote source fragments; never surface them.
        raise ValueError(f"invalid MCP/settings JSON structure: {path}") from exc
    return path, original, updated, changes, (info.st_dev, info.st_ino), stat.S_IMODE(info.st_mode), kept


def unchanged(item):
    path, original, _, _, identity, *_ = item
    if path.is_symlink():
        return False
    info = path.stat()
    return (info.st_dev, info.st_ino) == identity and path.read_bytes() == original


def apply(prepared, backup_parent):
    changed = [item for item in prepared if item[3]]
    for item in prepared:
        if not unchanged(item):
            raise ValueError(f"target changed since plan: {item[0]}")
    if not changed:
        return None
    backup_parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_dir = Path(tempfile.mkdtemp(prefix="mcp-retirement-", dir=backup_parent))
    for number, item in enumerate(changed):
        path, original, updated, _, _, mode, _ = item
        backup = backup_dir / f"{number}-{path.name}"
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(original)
            f.flush()
            os.fsync(f.fileno())
        fd, name = tempfile.mkstemp(prefix=".mcp-retirement-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as f:
                os.fchmod(f.fileno(), mode)
                f.write(updated)
                f.flush()
                os.fsync(f.fileno())
            if not unchanged(item):
                raise ValueError(f"target changed since plan: {path}; earlier targets may be applied, backups in {backup_dir}")
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    return backup_dir


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file", action="append", required=True, help="explicit runtime/settings/repo .mcp.json target; repeat")
    parser.add_argument("--apply", action="store_true", help="write targeted removals with backups")
    parser.add_argument("--quiescent", action="store_true", help="acknowledge no agents/config writers are using these files")
    parser.add_argument("--backup-dir", type=Path, default=Path.home()/".claude/backups")
    args = parser.parse_args(argv)
    try:
        if args.apply and not args.quiescent:
            raise ValueError("apply requires --quiescent; wait for a quiet activation window")
        targets = list(dict.fromkeys(Path(x).absolute() for x in args.file))
        prepared = [prepare(path) for path in targets]  # validate ALL before any write
        if args.apply and any(item[3] for item in prepared):
            for cli in ("ga4", "discord-cli"):
                if shutil.which(cli) is None:
                    raise ValueError(f"replacement command missing from PATH: {cli}; install before retirement")
        for path, _, _, changes, _, _, kept in prepared:
            print(f"{path}: {len(changes)} removal(s)")
            for change in changes:
                print(f"  {change}")
            for entry in kept:
                print(f"  kept {entry}")
        if args.apply:
            backup = apply(prepared, args.backup_dir)
            print(f"applied; backups: {backup}" if backup else "no changes; no backups created")
        else:
            print("plan only; no writes. Apply after CLI installation in a quiet window with --apply --quiescent.")
        return 0
    except (ValueError, RuntimeError) as exc:
        print(f"mcp-retirement: {exc}", file=sys.stderr)
        return 2
    except OSError:
        print("mcp-retirement: filesystem operation failed; inspect target/backup permissions. Earlier targets may be applied; retain backups.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
