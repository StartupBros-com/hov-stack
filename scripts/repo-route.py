#!/usr/bin/env python3
"""Resolve local repository authority from versioned route policy.

The policy is portable. Authority is deliberately host-local state, created only
by ``bootstrap``; resolving and scanning never fetch or mutate git state.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import subprocess
import tempfile
import time
from contextlib import contextmanager
from typing import Any

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE.parent / "config" / "repo-routes.json"
DEFAULT_STATE = pathlib.Path(os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local" / "state")) / "repo-routes.json"
MODES = {"observe", "warn", "enforce"}


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, sort_keys=True))


def git(repo: str, *args: str) -> str:
    return subprocess.check_output(["git", "-C", repo, *args], stderr=subprocess.DEVNULL, text=True).strip()


def real(path: str) -> str:
    return str(pathlib.Path(path).resolve())


def hosted_identity(host: str, path: str) -> str | None:
    """Normalize one host/path pair without repairing malformed separators."""
    host = host.lower()
    if host.endswith("."):
        host = host[:-1]
    if (
        not host
        or any(not label for label in host.split("."))
        or any(char.isspace() for char in host)
    ):
        return None

    if path.startswith("/"):
        path = path[1:]
    if path.endswith("/"):
        path = path[:-1]
    parts = path.split("/")
    if len(parts) != 2 or not all(parts):
        return None
    owner, repo = parts
    if repo.lower().endswith(".git"):
        repo = repo[:-4]
    if not repo or any(char.isspace() for part in (owner, repo) for char in part):
        return None
    return f"{host}/{owner.lower()}/{repo.lower()}"


def origin_identity(url: str) -> str | None:
    """Canonical hosted identity, accepting HTTPS, ssh:// and scp SSH forms."""
    value = url.strip()
    host = path = ""
    if "://" in value:
        from urllib.parse import urlparse
        try:
            parsed = urlparse(value)
            port = parsed.port
        except ValueError:
            return None
        default_ports = {"http": 80, "https": 443, "ssh": 22, "git": 9418}
        if port is not None and port != default_ports.get(parsed.scheme.lower()):
            return None
        host, path = parsed.hostname or "", parsed.path
    else:
        # git@GitHub.com:Owner/Repo and ssh-user@host:owner/repo
        import re
        match = re.fullmatch(r"(?:[^@/:]+@)?([^/:]+):(.+)", value)
        if not match:
            return None
        host, path = match.group(1), match.group(2)
    return hosted_identity(host, path)


def remote_profile(repo: str) -> tuple[str | None, str | None, str | None]:
    """Return hosted fetch/push identities without exposing credential-bearing URLs."""
    try:
        fetch_urls = [
            line for line in git(repo, "remote", "get-url", "--all", "origin").splitlines()
            if line
        ]
    except Exception:
        fetch_urls = []
    try:
        push_urls = [
            line for line in git(repo, "remote", "get-url", "--push", "--all", "origin").splitlines()
            if line
        ]
    except Exception:
        push_urls = []

    fetch_identities = [origin_identity(url) for url in fetch_urls]
    push_identities = [origin_identity(url) for url in push_urls]
    if not any(fetch_identities) and not any(push_identities):
        return None, None, None
    fetch_identity = fetch_identities[0] if len(fetch_identities) == 1 else None
    push_identity = push_identities[0] if len(push_identities) == 1 else None
    if len(fetch_urls) != 1:
        return fetch_identity, push_identity, "origin must have exactly one effective hosted fetch URL"
    if fetch_identity is None:
        return None, push_identity, "a hosted origin push URL requires a supported hosted fetch URL"
    if len(push_urls) != 1:
        return fetch_identity, push_identity, "origin must have exactly one effective push URL"
    if push_identity is None:
        return fetch_identity, None, "origin push URL is not a supported hosted identity"
    if push_identity != fetch_identity:
        return fetch_identity, push_identity, "origin fetch and push identities disagree"
    return fetch_identity, push_identity, None


def policy_identity(value: Any) -> str | None:
    """Normalize a declarative hosted identity through the origin canonicalizer."""
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip()
    if "://" in raw or ":" in raw:
        return origin_identity(raw)
    parts = raw.split("/", 1)
    if len(parts) != 2:
        return None
    return hosted_identity(parts[0], parts[1])


def config_path() -> pathlib.Path:
    """REPO_ROUTE_CONFIG, else a machine-private overlay copy, else the tracked default.

    The tracked file is a placeholder, so an overlay copy (same directory
    convention as scripts/public-safety-scan.sh private-tokens) must win over it.
    """
    env = os.environ.get("REPO_ROUTE_CONFIG")
    if env:
        return pathlib.Path(env)
    base = os.environ.get("XDG_CONFIG_HOME") or str(pathlib.Path.home() / ".config")
    overlay = pathlib.Path(os.environ.get("HOV_STACK_OVERLAY") or pathlib.Path(base) / "hov-stack")
    candidate = overlay / "repo-routes.json"
    return candidate if candidate.is_file() else DEFAULT_CONFIG


def load_policy() -> tuple[dict[str, Any] | None, str | None]:
    source = config_path()
    try:
        policy = json.loads(source.read_text())
        if policy.get("version") != 1 or not isinstance(policy.get("routes"), list):
            raise ValueError("expected version 1 routes array")
        ids: set[str] = set()
        claimed_identities: dict[str, str] = {}
        for route in policy["routes"]:
            if not isinstance(route, dict) or not isinstance(route.get("id"), str) or not route["id"] or route["id"] in ids:
                raise ValueError("route ids must be unique non-empty strings")
            ids.add(route["id"])
            identities = route.get("identities")
            aliases = route.get("aliases", [])
            if not isinstance(identities, list) or not identities or not isinstance(aliases, list):
                raise ValueError(f"route {route['id']} has invalid identities or aliases")
            normalized = [policy_identity(value) for value in identities + aliases]
            if any(value is None for value in normalized):
                raise ValueError(f"route {route['id']} has an invalid hosted identity")
            route["identities"] = normalized[:len(identities)]
            route["aliases"] = normalized[len(identities):]
            for identity in normalized:
                assert identity is not None
                prior = claimed_identities.get(identity)
                if prior is not None:
                    raise ValueError(f"hosted identity {identity} is claimed by both {prior} and {route['id']}")
                claimed_identities[identity] = route["id"]
            if route.get("directWorktreeDefaultMode", "observe") not in MODES:
                raise ValueError(f"route {route['id']} has invalid default mode")
        return policy, None
    except Exception as exc:
        return None, f"policy unreadable or malformed: {exc}"


def host_id() -> str:
    override = os.environ.get("REPO_ROUTE_HOST_ID")
    if override is not None:
        if not override.strip() or override != override.strip():
            raise RuntimeError("REPO_ROUTE_HOST_ID must be a nonblank normalized value")
        return override
    configured = os.environ.get("REPO_ROUTE_MACHINE_ID_PATH")
    sources = [pathlib.Path(configured)] if configured else [
        pathlib.Path("/etc/machine-id"),
        pathlib.Path("/var/lib/dbus/machine-id"),
    ]
    for source in sources:
        try:
            value = source.read_text().strip().lower()
        except OSError:
            continue
        if len(value) == 32 and all(char in "0123456789abcdef" for char in value) and value != "0" * 32:
            return f"machine-id:{value}"
    raise RuntimeError("stable machine id unavailable; set REPO_ROUTE_HOST_ID explicitly")


def matching_route(policy: dict[str, Any], identity: str) -> tuple[dict[str, Any] | None, str | None]:
    matches = []
    for route in policy["routes"]:
        names = route.get("identities", []) + route.get("aliases", [])
        if identity in {str(name).lower() for name in names}:
            matches.append(route)
    if len(matches) > 1:
        return None, f"ambiguous policy: {identity} matches {', '.join(r['id'] for r in matches)}"
    return (matches[0], None) if matches else (None, None)


def load_state(route: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None, bool]:
    """Return matching local authority, error, and whether foreign authority exists."""
    source = pathlib.Path(os.environ.get("REPO_ROUTE_STATE", DEFAULT_STATE))
    if not source.exists():
        return None, None, False
    try:
        data = json.loads(source.read_text())
        if data.get("version") != 1 or not isinstance(data.get("routes"), dict):
            raise ValueError("expected version 1 routes object")
        state = data["routes"].get(route["id"])
        if state is None:
            return None, None, False
        if not isinstance(state, dict):
            raise ValueError(f"route {route['id']} is not an object")
        # Validate the complete record before deciding it belongs to another host.
        # Otherwise a blank host id or relative path can masquerade as harmless
        # foreign authority and silently remove a preservation fence.
        required = ("host_id", "canonical_identity", "canonical_path", "common_dir", "mode")
        if any(not isinstance(state.get(key), str) or not state[key] for key in required):
            raise ValueError(f"route {route['id']} has incomplete local authority")
        recorded_host = state["host_id"]
        if not recorded_host.strip() or recorded_host != recorded_host.strip():
            raise ValueError(f"route {route['id']} has an invalid host_id")
        if state["canonical_identity"] != route["identities"][0]:
            raise ValueError(f"route {route['id']} authority is bound to a different canonical identity")
        if state["mode"] not in MODES:
            raise ValueError(f"route {route['id']} has invalid mode")
        for key in ("canonical_path", "common_dir"):
            value = state[key]
            if not os.path.isabs(value) or os.path.normpath(value) != value:
                raise ValueError(f"route {route['id']} has invalid {key}")
        if recorded_host != host_id():
            return None, None, True
        return state, None, False
    except Exception as exc:
        return None, f"state unreadable or malformed: {exc}", False


def topology_authority(
    policy: dict[str, Any], top: str, common: str
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str | None]:
    """Find an explicitly registered local authority by checkout topology."""
    matches: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for route in policy["routes"]:
        state, error, foreign = load_state(route)
        if error:
            return None, None, error
        if foreign or state is None:
            continue
        if top == real(state["canonical_path"]) or common == real(state["common_dir"]):
            matches.append((route, state))
    if len(matches) > 1:
        return None, None, "multiple local authorities claim the checkout topology"
    return (*matches[0], None) if matches else (None, None, None)


def unverified(repo: str, message: str) -> dict[str, Any]:
    return {"schema": "repo-route.v1", "repo": repo, "classification": "unverified", "verified": False, "error": message}


def resolve(repo: str) -> dict[str, Any]:
    repo = real(repo)
    try:
        top = real(git(repo, "rev-parse", "--show-toplevel"))
        common_raw = git(repo, "rev-parse", "--git-common-dir")
        common = real(common_raw if os.path.isabs(common_raw) else os.path.join(top, common_raw))
        git_dir = real(git(repo, "rev-parse", "--absolute-git-dir"))
    except Exception as exc:
        return {"schema": "repo-route.v1", "repo": repo, "classification": "unhosted", "verified": True, "error": f"not a usable git checkout: {exc}"}
    identity, push_identity, remote_error = remote_profile(repo)
    base = {
        "schema": "repo-route.v1",
        "repo": repo,
        "top_level": top,
        "common_dir": common,
        "git_dir": git_dir,
        "identity": identity,
        "push_identity": push_identity,
    }
    policy, error = load_policy()
    if error:
        return base | unverified(repo, error)
    assert policy is not None
    identity_route = None
    if identity is not None:
        identity_route, error = matching_route(policy, identity)
        if error:
            return base | {"classification": "ambiguous", "verified": False, "error": error}
    topology_route, topology_state, error = topology_authority(policy, top, common)
    if error:
        return base | unverified(repo, error)
    if identity_route is not None and topology_route is not None and identity_route["id"] != topology_route["id"]:
        route = topology_route
        state = topology_state
        route_conflict = "checkout topology and origin resolve to different registered routes"
    else:
        route = topology_route or identity_route
        state = topology_state
        route_conflict = None
    if route is None:
        if remote_error:
            return base | unverified(repo, remote_error)
        classification = "unhosted" if identity is None else "unregistered"
        return base | {"classification": classification, "verified": True}
    if state is None:
        state, error, foreign = load_state(route)
    else:
        foreign = False
    default_mode = route.get("directWorktreeDefaultMode", "observe")
    common_fields = {
        "route": route["id"],
        "mode": default_mode,
        "coordination": route.get("coordination", {}),
        "canonical_identity": route["identities"][0],
        "policy_version": policy["version"],
    }
    if error:
        return base | common_fields | {"classification": "unverified", "verified": False, "error": error}
    if remote_error:
        return base | common_fields | {
            "classification": "misconfigured",
            "verified": False,
            "error": remote_error,
        }
    if foreign or state is None:
        return base | common_fields | {
            "classification": "unregistered",
            "verified": True,
            "authority_registered": False,
            "foreign_host_authority": foreign,
        }
    canonical_path = real(state["canonical_path"])
    recorded_common = real(state["common_dir"])
    common_fields |= {
        "mode": state["mode"],
        "canonical_path": canonical_path,
        "recorded_common_dir": recorded_common,
        "authority_registered": True,
    }
    if route_conflict:
        return base | common_fields | {"classification": "misconfigured", "verified": False, "error": route_conflict}
    canonical_exists = os.path.isdir(canonical_path)
    if canonical_exists:
        try:
            live_top = real(git(canonical_path, "rev-parse", "--show-toplevel"))
            live_common_raw = git(canonical_path, "rev-parse", "--git-common-dir")
            live_common = real(live_common_raw if os.path.isabs(live_common_raw) else os.path.join(live_top, live_common_raw))
            live_git_dir = real(git(canonical_path, "rev-parse", "--absolute-git-dir"))
            live_identity, live_push_identity, live_remote_error = remote_profile(canonical_path)
        except Exception as exc:
            return base | common_fields | {"classification": "misconfigured", "verified": False, "error": f"canonical path is not a usable checkout: {exc}"}
        if live_remote_error:
            return base | common_fields | {
                "classification": "misconfigured",
                "verified": False,
                "error": live_remote_error,
            }
        if live_top != canonical_path or live_git_dir != live_common:
            return base | common_fields | {"classification": "misconfigured", "verified": False, "error": "canonical authority must remain the primary checkout top level"}
        if live_common != recorded_common:
            return base | common_fields | {"classification": "misconfigured", "verified": False, "error": "recorded common-dir disagrees with canonical checkout"}
        if live_identity != state["canonical_identity"] or live_push_identity != state["canonical_identity"]:
            return base | common_fields | {"classification": "misconfigured", "verified": False, "error": "canonical checkout fetch and push identities must equal the route primary identity"}
    missing_fields = {"canonical_missing": not canonical_exists}
    if top == canonical_path and common == recorded_common:
        return base | common_fields | missing_fields | {"classification": "canonical", "verified": True, "creation_allowed": True, "healing_allowed": True}
    if common == recorded_common:
        # If the launchpad disappeared, a surviving linked worktree proves the
        # authority lineage but is deliberately adoption/resumption only.
        return base | common_fields | missing_fields | {"classification": "canonical-sibling", "verified": True, "creation_allowed": canonical_exists, "healing_allowed": canonical_exists, "adopt_allowed": True}
    return base | common_fields | missing_fields | {"classification": "noncanonical-independent-clone", "verified": True, "creation_allowed": False, "healing_allowed": False, "adopt_allowed": False}


def scan(root: str) -> dict[str, Any]:
    root = real(root)
    found: list[dict[str, Any]] = []
    policy, policy_error = load_policy()
    if policy_error:
        entry = unverified(root, policy_error)
        return {
            "schema": "repo-route-scan.v1",
            "sites_root": root,
            "verified": False,
            "routes": [{
                "route": "<unresolved>", "entries": [entry], "collision": False,
                "unverified": True, "authority_missing": False, "canonical_missing": False,
            }],
        }
    assert policy is not None
    try:
        children = sorted(pathlib.Path(root).iterdir())
    except Exception as exc:
        entry = unverified(root, f"sites root unreadable: {exc}")
        return {
            "schema": "repo-route-scan.v1",
            "sites_root": root,
            "error": str(exc),
            "verified": False,
            "routes": [{
                "route": "<unresolved>", "entries": [entry], "collision": False,
                "unverified": True, "authority_missing": False, "canonical_missing": False,
            }],
        }
    for child in children:
        if child.is_dir() and (child / ".git").exists():
            result = resolve(str(child))
            # A resolver/config error has no trustworthy route id, but it still
            # makes this whole maintenance scan unverified. Do not discard it as
            # an ordinary unregistered checkout and then prune its worktrees.
            if result.get("route") or not result.get("verified", False):
                found.append(result)
    # Authority disappearance must remain visible even when no checkout survives
    # under the scan root. The recorded common dir still identifies cleanup state
    # that no clone may mutate until the launchpad is restored deliberately.
    for route in policy["routes"]:
        state, state_error, foreign = load_state(route)
        if state_error:
            found.append(unverified(root, state_error) | {
                "route": route["id"],
                "mode": route.get("directWorktreeDefaultMode", "observe"),
            })
            continue
        if foreign or state is None:
            continue
        canonical_path = real(state["canonical_path"])
        if os.path.isdir(canonical_path):
            authority = resolve(canonical_path)
            if (
                authority.get("route") != route["id"]
                or authority.get("classification") != "canonical"
                or not authority.get("verified", False)
            ) and not any(
                item.get("route") == route["id"]
                and item.get("repo") == canonical_path
                for item in found
            ):
                found.append(authority | {
                    "classification": "misconfigured",
                    "verified": False,
                    "route": route["id"],
                    "mode": state["mode"],
                    "canonical_identity": route["identities"][0],
                    "canonical_path": canonical_path,
                    "recorded_common_dir": real(state["common_dir"]),
                    "authority_registered": True,
                    "error": "registered canonical authority no longer resolves as the route primary checkout",
                })
        elif not any(
            item.get("route") == route["id"] and item.get("canonical_missing") for item in found
        ):
            found.append({
                "schema": "repo-route.v1",
                "repo": canonical_path,
                "classification": "canonical-missing",
                "verified": True,
                "route": route["id"],
                "mode": state["mode"],
                "canonical_identity": route["identities"][0],
                "canonical_path": canonical_path,
                "common_dir": real(state["common_dir"]),
                "recorded_common_dir": real(state["common_dir"]),
                "authority_registered": True,
                "canonical_missing": True,
                "creation_allowed": False,
                "healing_allowed": False,
                "adopt_allowed": False,
            })
    groups: dict[str, list[dict[str, Any]]] = {}
    for item in found:
        groups.setdefault(str(item.get("route", "<unresolved>")), []).append(item)
    routes = []
    for route_id, entries in groups.items():
        independent = [entry for entry in entries if entry["classification"] == "noncanonical-independent-clone"]
        bad = [entry for entry in entries if not entry.get("verified", False)]
        authority_missing = [
            entry for entry in entries
            if entry.get("route") and entry["classification"] == "unregistered"
        ]
        canonical_missing = [entry for entry in entries if entry.get("canonical_missing", False)]
        routes.append({
            "route": route_id,
            "entries": entries,
            "collision": bool(independent),
            "unverified": bool(bad),
            "authority_missing": bool(authority_missing),
            "canonical_missing": bool(canonical_missing),
        })
    return {"schema": "repo-route-scan.v1", "sites_root": root, "verified": all(not route["unverified"] for route in routes), "routes": routes}


def state_path() -> pathlib.Path:
    return pathlib.Path(os.environ.get("REPO_ROUTE_STATE", DEFAULT_STATE))


@contextmanager
def state_mutation_lock():
    """Serialize authority read-modify-write sequences across processes."""
    dest = state_path()
    dest.parent.mkdir(parents=True, exist_ok=True)
    lock_path = pathlib.Path(f"{dest}.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    locked = False
    try:
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        locked = True
        yield
    finally:
        if locked:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def write_state(data: dict[str, Any]) -> None:
    dest = state_path()
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".repo-routes.", dir=dest.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, dest)
        os.chmod(dest, 0o600)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def mutate_state_route(route: dict[str, Any], canonical: str | None, mode: str) -> dict[str, Any]:
    """Validate and mutate one authority while the process lock is held."""
    current: dict[str, Any] = {"version": 1, "routes": {}}
    dest = state_path()
    if dest.exists():
        try:
            current = json.loads(dest.read_text())
            if current.get("version") != 1 or not isinstance(current.get("routes"), dict):
                raise ValueError("expected version 1 routes object")
        except Exception as exc:
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": f"state unreadable or malformed: {exc}"}

    # Deterministic concurrency seam: the first test process pauses after reading
    # while a contender attempts another authority mutation.
    ready = os.environ.get("REPO_ROUTE_TEST_LOCK_READY")
    if ready:
        pathlib.Path(ready).touch()
    delay = os.environ.get("REPO_ROUTE_TEST_LOCK_DELAY")
    if delay:
        time.sleep(float(delay))

    try:
        local_host = host_id()
    except Exception as exc:
        return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": str(exc)}
    route_id = route["id"]
    if canonical is not None:
        result = resolve(canonical)
        if result.get("route") != route_id or not result.get("verified", False):
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": "canonical path does not resolve to the requested route"}
        if result.get("identity") != route["identities"][0] or result.get("push_identity") != route["identities"][0]:
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": "canonical path fetch and push identities must equal the route primary identity"}
        if result.get("top_level") != real(canonical):
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": "canonical path must name the checkout top level"}
        if result.get("git_dir") != result.get("common_dir"):
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": "canonical path must be the primary launchpad, not a linked worktree"}
        existing, state_error, _foreign = load_state(route)
        if state_error:
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": state_error}
        if existing is not None and real(existing["canonical_path"]) != result["top_level"]:
            return {
                "schema": "repo-route.v1",
                "classification": "error",
                "verified": False,
                "error": "route already has a different matching-host authority; preserve and retire it before rebinding",
            }
        current["routes"][route_id] = {
            "host_id": local_host,
            "canonical_identity": route["identities"][0],
            "canonical_path": result["top_level"],
            "common_dir": result["common_dir"],
            "mode": mode,
        }
    else:
        entry, state_error, foreign = load_state(route)
        if state_error:
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": state_error}
        if foreign or entry is None:
            return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": "no matching-host authority to change"}
        entry["mode"] = mode
        current["routes"][route_id] = entry
    write_state(current)
    return {"schema": "repo-route.v1", "classification": "configured", "verified": True, "route": route_id, "mode": mode, "state": str(dest)}


def state_route(route_id: str, canonical: str | None, mode: str) -> dict[str, Any]:
    policy, error = load_policy()
    if error:
        return unverified("", error)
    route = next((item for item in policy["routes"] if item["id"] == route_id), None)
    if route is None:
        return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": f"unknown route: {route_id}"}
    try:
        with state_mutation_lock():
            return mutate_state_route(route, canonical, mode)
    except Exception as exc:
        return {"schema": "repo-route.v1", "classification": "error", "verified": False, "error": f"state mutation failed: {exc}"}


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    resolve_p = sub.add_parser("resolve"); resolve_p.add_argument("--repo", required=True); resolve_p.add_argument("--format", choices=["json"], required=True)
    scan_p = sub.add_parser("scan"); scan_p.add_argument("--sites-root", default=os.environ.get("REPO_ROUTE_SITES_ROOT", str(pathlib.Path.home() / "SITES"))); scan_p.add_argument("--format", choices=["json"], required=True)
    boot = sub.add_parser("bootstrap"); boot.add_argument("--route", required=True); boot.add_argument("--canonical-path", required=True); boot.add_argument("--mode", choices=sorted(MODES), required=True)
    mode = sub.add_parser("set-mode"); mode.add_argument("--route", required=True); mode.add_argument("--mode", choices=sorted(MODES), required=True)
    args = parser.parse_args()
    if args.command == "resolve": result = resolve(args.repo)
    elif args.command == "scan": result = scan(args.sites_root)
    elif args.command == "bootstrap": result = state_route(args.route, args.canonical_path, args.mode)
    else: result = state_route(args.route, None, args.mode)
    emit(result)
    if args.command in {"bootstrap", "set-mode"} and not result.get("verified", False):
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
