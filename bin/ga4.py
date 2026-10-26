#!/usr/bin/env python3
"""On-demand Google Analytics access: named reads plus a validated Admin API passthrough.

Named commands are read-only (analytics.readonly). Native JSON requests preserve
filters, date/minute ranges, metric expressions, ordering, cohorts, comparisons
and quota reporting without an MCP process. Conversions/key-event reports are
ordinary `report` requests, not another API.

`ga4 admin METHOD PATH` is full Admin API access (create/update/archive/delete,
access bindings, links, retention, audiences...) against one fixed host. GET
mints read scopes; POST/PATCH/DELETE mint edit + user-management scopes. There is
no confirmation prompt by design. Writes are never retried.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "1.1.0"
CREDENTIALS = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
    "google-service-account.json",
)
AUTH = "https://www.googleapis.com/auth/"
SCOPES = [AUTH + "analytics.readonly"]
ADMIN_READ_SCOPES = [AUTH + "analytics.readonly", AUTH + "analytics.manage.users.readonly"]
ADMIN_WRITE_SCOPES = [AUTH + "analytics.edit", AUTH + "analytics.manage.users"]
PROPERTIES_ENV = "GA4_PROPERTIES_FILE"
PROPERTIES_NAME = "ga4-properties.json"
PROPERTY_HELP = "an alias from the property map (config/ga4-properties.example.json shows the shape) or a positive numeric GA4 property ID"
CREDENTIALS_HELP = (
    "service-account JSON; default HOV_STACK_GOOGLE_CREDENTIALS, then GOOGLE_APPLICATION_CREDENTIALS, then "
    + CREDENTIALS
)
DATA = "https://analyticsdata.googleapis.com/v1beta/"
ADMIN_HOST = "https://analyticsadmin.googleapis.com/"
ADMIN = ADMIN_HOST + "v1beta/"
ADMIN_ROOTS = ("accountSummaries", "accounts", "properties")
MAX_ERROR_BODY = 64 * 1024
TOKEN = "https://oauth2.googleapis.com/token"
MAX_LIMIT = 250_000
MAX_OFFSET = 2**63 - 1
MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 32 * 1024 * 1024
RETRY_STATUSES = {429, 500, 502, 503, 504}
ADMIN_METHODS = ("GET", "POST", "PATCH", "DELETE")


class CliError(Exception):
    """An intentionally safe-to-print diagnostic."""

    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


def properties_file():
    override = os.environ.get(PROPERTIES_ENV)
    if override:
        return Path(override)
    overlay = os.environ.get("HOV_STACK_OVERLAY")
    if overlay:
        return Path(overlay) / PROPERTIES_NAME
    return (
        Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        / "hov-stack"
        / PROPERTIES_NAME
    )


def properties():
    """Read the host's alias map on use; help and argument parsing stay offline."""
    path = properties_file()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise CliError(
            f"cannot read property map {path}: expected a UTF-8 JSON object", 2
        ) from None
    if not isinstance(data, dict) or not all(
        isinstance(k, str)
        and isinstance(v, str)
        and re.fullmatch(r"[1-9][0-9]{0,18}", v)
        for k, v in data.items()
    ):
        raise CliError(
            f"{path} must be a JSON object of alias -> positive numeric property ID string",
            2,
        )
    return data


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise CliError("redirect refused; authorization was not forwarded")


def opener():
    return urllib.request.build_opener(NoRedirect())


def error_status(exc):
    """Only Google's enum-shaped error.status (e.g. PERMISSION_DENIED); never message or body."""
    try:
        error = json.loads(exc.read(MAX_ERROR_BODY)).get("error")
        status = error.get("status") if isinstance(error, dict) else None
    except Exception:
        return ""
    return f" (status {status})" if isinstance(status, str) and re.fullmatch(r"[A-Z_]{1,64}", status) else ""


def unreadable(problem, write):
    """A 2xx body that cannot be used. For an admin write the status already proves it was applied."""
    if write:
        return CliError(f"{problem}; Google answered HTTP 2xx, so the admin write was applied: read the resource before retrying")
    return CliError(problem)


def fetch(request, timeout, retries=0, write=False):
    """Bounded transport. Do not print response bodies, URLs or exception text."""
    for attempt in range(retries + 1):
        try:
            with opener().open(request, timeout=timeout) as response:
                data = response.read(MAX_RESPONSE + 1)
                if len(data) > MAX_RESPONSE:
                    # The report-limit hint is read advice; a write gets the applied note instead.
                    raise unreadable("response exceeds 32 MiB" + ("" if write else "; reduce the report limit"), write)
                return data, dict(response.headers)
        except urllib.error.HTTPError as exc:
            # No error body/message is surfaced: providers may reflect request data.
            code = exc.code
            retry_after = exc.headers.get("Retry-After", "") if exc.headers else ""
            if code in RETRY_STATUSES and attempt < retries:
                exc.close()
                delay = min(float(retry_after), 10.0) if re.fullmatch(r"\d+(?:\.\d+)?", retry_after) else 2**attempt
                time.sleep(delay)
                continue
            status = error_status(exc)
            exc.close()
            if write and code >= 500:
                # Google may commit the write and still answer 5xx.
                raise CliError(f"Google API returned HTTP {code}{status}; the admin write may already have been applied, so read the resource before retrying") from None
            raise CliError(f"Google API returned HTTP {code}{status}; check access, request schema or quota") from None
        # HTTPException covers a garbled status line and a body cut off mid-read (IncompleteRead).
        except (TimeoutError, urllib.error.URLError, OSError, http.client.HTTPException):
            if write:
                # The request may have reached Google before the connection failed.
                raise CliError("network request failed or timed out; the admin write may already have been applied, so read the resource before retrying") from None
            raise CliError("network request failed or timed out; check connectivity and --timeout") from None
    raise CliError("request attempts exhausted")


class AuthResponse:
    def __init__(self, data, headers):
        self.status = 200
        self.data = data
        self.headers = headers


class AuthRequest:
    """google-auth request protocol, restricted to the OAuth token origin."""
    def __init__(self, timeout):
        self.timeout = timeout

    def __call__(self, url, method="GET", body=None, headers=None, **_kwargs):
        if url != TOKEN or method.upper() != "POST":
            raise CliError("credential token endpoint is unsupported; expected Google's OAuth token endpoint")
        data, response_headers = fetch(
            urllib.request.Request(url, data=body, headers=headers or {}, method="POST"),
            self.timeout,
        )
        return AuthResponse(data, response_headers)


def access_token(path, timeout, scopes=SCOPES):
    try:
        from google.oauth2 import service_account
    except ImportError:
        raise CliError(
            "google-auth is missing; install with: uv pip install --python "
            "~/.local/share/gsc-cli/venv/bin/python google-auth "
            "(create that venv with uv venv first)"
        ) from None
    try:
        credentials = service_account.Credentials.from_service_account_file(path, scopes=list(scopes))
        credentials.refresh(AuthRequest(timeout))
        token = credentials.token
        if not isinstance(token, str) or not token or "\n" in token or "\r" in token:
            raise CliError("credential refresh did not yield a usable token")
        return token
    except CliError:
        raise
    except Exception:
        # Credential parse/refresh errors can embed private keys or response bodies.
        raise CliError("credential load/refresh failed; check --credentials, file permissions and service-account access") from None


def positive_id(value, kind="property"):
    if kind == "property" and not re.fullmatch(r"[1-9][0-9]{0,18}", value):
        value = properties().get(value, value)
        if not re.fullmatch(r"[1-9][0-9]{0,18}", value):
            raise CliError(
                f"property must be {PROPERTY_HELP}; no alias in {properties_file()} (set {PROPERTIES_ENV})",
                2,
            )
    if not re.fullmatch(r"[1-9][0-9]{0,18}", value):
        raise CliError(f"{kind} must be a positive numeric ID")
    return value


def bounded_int(value, label, low, high):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
        raise CliError(f"{label} must be an integer from {low} to {high}")
    if len(str(value)) > 19:
        raise CliError(f"{label} must be an integer from {low} to {high}")
    number = int(value)
    if not low <= number <= high:
        raise CliError(f"{label} must be an integer from {low} to {high}")
    return number


def read_json_object(source):
    try:
        if source == "-":
            text = sys.stdin.read(MAX_REQUEST + 1)
        else:
            with Path(source).open(encoding="utf-8") as stream:
                text = stream.read(MAX_REQUEST + 1)
        if len(text.encode("utf-8")) > MAX_REQUEST:
            raise CliError("request exceeds 1 MiB")
        body = json.loads(text)
    except (OSError, ValueError):
        raise CliError("request must be a readable UTF-8 JSON object") from None
    if not isinstance(body, dict):
        raise CliError("request must be a JSON object")
    return body


def report_body(args, property_id):
    body = read_json_object(args.request)
    if "property" in body:
        if body.pop("property") != f"properties/{property_id}":
            raise CliError("request property does not match --property")
    if not isinstance(body.get("metrics"), list) or not body["metrics"]:
        raise CliError("request must include a non-empty metrics array")
    limit = args.limit if args.limit is not None else body.get("limit", 1000)
    body["limit"] = str(bounded_int(limit, "limit", 1, MAX_LIMIT))
    if args.command == "report":
        offset = args.offset if args.offset is not None else body.get("offset", 0)
        body["offset"] = str(bounded_int(offset, "offset", 0, MAX_OFFSET))
    elif "offset" in body:
        raise CliError("realtime reports do not support offset")
    return body


def admin_path(path):
    """Validate a relative Admin API resource path; resolve property aliases."""
    if not isinstance(path, str) or not 0 < len(path) <= 512:
        raise CliError("admin path must be 1..512 characters")
    segments = path.split("/")
    match = re.fullmatch(r"([A-Za-z0-9_~-]+)(?::([A-Za-z]+))?", segments[-1])
    if not match or not all(re.fullmatch(r"[A-Za-z0-9_~-]+", part) for part in segments[:-1]):
        raise CliError("admin path segments must match [A-Za-z0-9_~-]+ with one optional trailing :customMethod")
    segments[-1], method = match.group(1), match.group(2)
    if segments[0] not in ADMIN_ROOTS:
        raise CliError("admin path must start with accountSummaries, accounts or properties")
    if len(segments) > 1 and segments[0] != "accountSummaries":
        segments[1] = positive_id(segments[1], "property" if segments[0] == "properties" else "account")
    return "/".join(segments) + (":" + method if method else "")


def admin_query(items):
    params = []
    for item in items or ():
        key, sep, value = item.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z][A-Za-z0-9.]{0,63}", key):
            raise CliError("--query must be KEY=VALUE with KEY matching [A-Za-z][A-Za-z0-9.]{0,63}")
        if len(value) > 2048:
            raise CliError("--query value exceeds 2048 characters")
        params.append((key, value))
    return urllib.parse.urlencode(params)


def build_admin_request(args):
    """Validate an admin passthrough call; returns (method, url, body)."""
    bounded_int(args.timeout, "timeout", 1, 120)
    bounded_int(args.retries, "retries", 0, 3)
    method = str(args.method).upper()
    if method not in ADMIN_METHODS:
        raise CliError("method must be GET, POST, PATCH or DELETE")
    if args.api not in ("v1beta", "v1alpha"):
        raise CliError("--api must be v1beta or v1alpha")
    url = f"{ADMIN_HOST}{args.api}/{admin_path(args.path)}"
    query = admin_query(args.query)
    if query:
        url += "?" + query
    if args.body is not None and method not in ("POST", "PATCH"):
        raise CliError("--body is only allowed for POST and PATCH")
    body = (read_json_object(args.body) if args.body is not None else {}) if method in ("POST", "PATCH") else None
    return method, url, body


def build_request(args):
    """Validate request before loading credentials or making any network call."""
    bounded_int(args.timeout, "timeout", 1, 120)
    bounded_int(args.retries, "retries", 0, 3)
    body = None
    params = {}
    if args.command in ("report", "realtime"):
        prop = positive_id(args.property)
        body = report_body(args, prop)
        action = "runReport" if args.command == "report" else "runRealtimeReport"
        url = f"{DATA}properties/{prop}:{action}"
    elif args.command == "metadata":
        prop = positive_id(args.property)
        url = f"{DATA}properties/{prop}/metadata"
    elif args.command in ("accounts", "properties"):
        params["pageSize"] = str(bounded_int(args.page_size, "page size", 1, 200))
        url = ADMIN + ("accountSummaries" if args.command == "accounts" else "properties")
        if args.command == "properties":
            params["filter"] = "parent:accounts/" + positive_id(args.account, "account")
    else:
        prop = positive_id(args.property)
        url = f"{ADMIN}properties/{prop}"
        resource = {"custom-dimensions": "customDimensions", "custom-metrics": "customMetrics", "google-ads-links": "googleAdsLinks"}.get(args.command)
        if resource:
            url += "/" + resource
            params["pageSize"] = str(bounded_int(args.page_size, "page size", 1, 200))
    if getattr(args, "page_token", None) is not None:
        if len(args.page_token) > 8192:
            raise CliError("page token is too long")
        params["pageToken"] = args.page_token
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return url, body


def parser():
    p = argparse.ArgumentParser(prog="ga4", description="On-demand GA4 access: named reads plus a validated Admin API passthrough")
    p.add_argument("--version", action="version", version=f"ga4 {VERSION}")
    p.add_argument("--where", action="store_true", help="show implementation/credential locations offline (alias for where)")
    p.add_argument(
        "--credentials",
        default=os.environ.get("HOV_STACK_GOOGLE_CREDENTIALS")
        or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        or CREDENTIALS,
        help=CREDENTIALS_HELP,
    )
    sub = p.add_subparsers(dest="command")
    where = sub.add_parser("where", help="show implementation/credential locations without reading credentials")
    where.add_argument(
        "--credentials", default=argparse.SUPPRESS, help=CREDENTIALS_HELP
    )

    def common(child):
        child.add_argument(
            "--credentials", default=argparse.SUPPRESS, help=CREDENTIALS_HELP
        )
        child.add_argument("--timeout", type=int, default=30, help="timeout per network operation, 1..120 seconds (default 30)")
        child.add_argument("--retries", type=int, default=0, help="additional API attempts for 429/5xx, 0..3 (default 0)")
        child.add_argument("--raw", action="store_true", help="emit untouched response JSON instead of pretty printing")

    def property_arg(child):
        child.add_argument("--property", required=True, help=PROPERTY_HELP)

    def paging(child):
        child.add_argument("--page-size", type=int, default=50, help="one page, 1..200 resources (default 50)")
        child.add_argument("--page-token", help="nextPageToken from a previous response; other options must match")

    admin = sub.add_parser(
        "admin",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        help="full Admin API passthrough: ga4 admin METHOD PATH [--body FILE|-] [--query K=V ...]",
        description="Call the GA4 Admin API (https://analyticsadmin.googleapis.com, fixed host) as the service account.\n"
        "GET mints analytics.readonly + analytics.manage.users.readonly; POST/PATCH/DELETE mint\n"
        "analytics.edit + analytics.manage.users. No confirmation prompt: writes apply immediately.\n"
        "Writes are never retried, whatever --retries says (a retried create can double-apply).\n"
        "GET honours --retries.",
        epilog="examples:\n"
        "  ga4 admin GET accountSummaries\n"
        "  ga4 admin GET properties/<alias>/customDimensions --query pageSize=200\n"
        "  ga4 admin GET accounts/100000001/accessBindings --api v1alpha\n"
        "  ga4 admin PATCH properties/123456789/dataRetentionSettings --body body.json --query updateMask=eventDataRetention\n"
        "  ga4 admin POST properties/123456789/customDimensions/123:archive\n"
        "  ga4 admin DELETE properties/123456789/keyEvents/456\n"
        "PATH: accountSummaries|accounts|properties first segment; segments [A-Za-z0-9_~-]+; optional\n"
        "single trailing :customMethod; properties/<alias> resolve to IDs.\n"
        "Use --api v1alpha for accessBindings, audiences, bigQueryLinks, channelGroups, calculatedMetrics etc.",
    )
    common(admin)
    admin.add_argument("method", type=str.upper, choices=ADMIN_METHODS, metavar="METHOD", help="GET, POST, PATCH or DELETE (case-insensitive)")
    admin.add_argument(
        "path",
        help="relative Admin API resource path, e.g. properties/<alias>/customDimensions",
    )
    admin.add_argument("--body", help="JSON object file or '-' for stdin, max 1 MiB; POST/PATCH only (default {})")
    admin.add_argument("--query", action="append", default=[], metavar="KEY=VALUE", help="query parameter, repeatable (updateMask, pageSize, pageToken, filter, showDeleted...)")
    admin.add_argument("--api", default="v1beta", choices=("v1beta", "v1alpha"), help="Admin API version (default v1beta)")
    for command, description in [("report", "runReport from a native JSON request (includes conversion/key-event reports)"), ("realtime", "runRealtimeReport from a native JSON request")]:
        child = sub.add_parser(command, help=description)
        common(child)
        property_arg(child)
        child.add_argument("--request", required=True, help="native JSON request file, or '-' for stdin")
        child.add_argument("--limit", type=int, help="override request limit, 1..250000; otherwise request value or 1000")
        if command == "report":
            child.add_argument("--offset", type=int, help="override request offset; otherwise request value or 0")
    for command in ("accounts", "properties", "property", "metadata", "custom-dimensions", "custom-metrics", "google-ads-links"):
        help_text = "discover accounts and child property summaries" if command == "accounts" else "read " + command.replace("-", " ") + " via Analytics " + ("Data" if command == "metadata" else "Admin") + " API"
        child = sub.add_parser(command, help=help_text)
        common(child)
        if command == "properties":
            child.add_argument("--account", required=True, help="positive numeric parent account ID")
        elif command != "accounts":
            property_arg(child)
        if command not in ("property", "metadata"):
            paging(child)
    return p


def main(argv=None):
    cli_parser = parser()
    args = cli_parser.parse_args(argv)
    if args.where and args.command not in (None, "where"):
        cli_parser.error("--where cannot be combined with an API command")
    if args.command is None and not args.where:
        cli_parser.error("a command is required unless --where is used")
    if args.command == "admin" and args.body is not None and args.method not in ("POST", "PATCH"):
        cli_parser.error("--body is only allowed for POST and PATCH")
    try:
        if args.where or args.command == "where":
            print(
                json.dumps(
                    {
                        "implementation": str(Path(__file__).resolve()),
                        "credentials": args.credentials,
                        "python": sys.executable,
                        "properties_file": str(properties_file()),
                        "aliases": sorted(properties()),
                        "scopes": {
                            "read": SCOPES,
                            "admin_get": ADMIN_READ_SCOPES,
                            "admin_write": ADMIN_WRITE_SCOPES,
                        },
                    },
                    indent=2,
                )
            )
            return 0
        is_admin = args.command == "admin"
        if is_admin:
            method, url, body = build_admin_request(args)
            scopes = ADMIN_READ_SCOPES if method == "GET" else ADMIN_WRITE_SCOPES
            retries = args.retries if method == "GET" else 0
        else:
            url, body = build_request(args)
            method, scopes, retries = (
                ("POST" if body is not None else "GET"),
                SCOPES,
                args.retries,
            )
        token = access_token(args.credentials, args.timeout, scopes)
        headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(
            url, data=payload, headers=headers, method=method
        )
        # Data API reports are POST reads, so only admin non-GET calls are writes.
        write = is_admin and method != "GET"
        data, _headers = fetch(request, args.timeout, retries, write=write)
        try:
            result = json.loads(data if data.strip() or not is_admin else b"{}")
            # json.loads also accepts UTF-16/32; --raw prints Google's bytes, so they must be UTF-8.
            text = data.decode("utf-8") if args.raw and data.strip() else None
        except (ValueError, UnicodeDecodeError):
            raise unreadable("Google API returned invalid JSON", write) from None
        if not isinstance(result, dict):
            raise unreadable("Google API returned an unexpected JSON shape", write)
        if not is_admin and body is not None:
            count = result.get("rowCount")
            rows = result.get("rows", [])
            if not isinstance(rows, list):
                raise CliError("Google API returned an unexpected rows shape")
            returned = len(rows)
            offset = int(body.get("offset", "0"))
            if isinstance(count, int) and count > offset + returned:
                detail = (
                    f"; next offset {offset + returned}"
                    if args.command == "report"
                    else "; narrow dimensions/filters or increase limit"
                )
                print(
                    f"ga4: WARNING: partial report, {returned} rows returned of {count}{detail}",
                    file=sys.stderr,
                )
        elif method == "GET" and result.get("nextPageToken"):
            option = "--query pageToken=TOKEN" if is_admin else "--page-token"
            print(
                f"ga4: WARNING: more resources exist; repeat with {option} from nextPageToken",
                file=sys.stderr,
            )
        print(text if text is not None else json.dumps(result, indent=2))
        return 0
    except CliError as exc:
        print(f"ga4: {exc}", file=sys.stderr)
        return exc.status


if __name__ == "__main__":
    sys.exit(main())
