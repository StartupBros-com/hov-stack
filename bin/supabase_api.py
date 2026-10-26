#!/usr/bin/env python3
"""Supabase Management API access for your Supabase projects.

  supabase-api projects
  supabase-api sql PROJECT [QUERY | - | --file F] [--param V ...] [--write]
  supabase-api logs PROJECT (--service S | --sql Q) [--since 1h | --start ISO --end ISO]
  supabase-api advisors PROJECT security|performance
  supabase-api migrations PROJECT
  supabase-api api METHOD PATH [--project P] [--body FILE|-] [--query k=v ...]

PROJECT is an alias from the project map (config/supabase-projects.example.json
shows the shape) or a 20-letter project ref. In api paths, {ref} takes --project,
and an alias in /v1/projects/<alias> resolves to its ref.

The token resolves env SUPABASE_ACCESS_TOKEN, then the named line in
~/.secrets (parsed, never sourced). --where reports presence without reading
a value. Output and errors are scrubbed of personal access tokens, secret API
keys, every JWT except an anon key, and string values under secret-named keys
(passwords, *_secret, tokens, api, access and root keys, private JWKs, and
each value on the project secrets endpoints) other than anon and publishable
keys. A redacted value is a placeholder: a write whose body or query carries
one is refused before any token read, so omit the field instead.

Writes are fail-closed. GET and three read-only POSTs (database/query/read-only,
network-bans/retrieve, vanity-subdomain/check-availability) run, and so do the
listed configuration writes (project rename, action run status, backup
schedule, restore point, database webhooks enable, custom hostname initialize
and reverify). Every other non-GET (SQL writes, migrations, restores, branch
writes, deletes, pause, restart and upgrade, keys and secrets, auth, network
and SSL config, function deploys, spend, and any endpoint not listed) needs
--confirm-destructive, refused before any token read or network call. The
flag is an invocation guard, not human approval. Flags must be spelled in full.
"""
from __future__ import annotations

import argparse
import base64
import binascii
from datetime import datetime, timedelta, timezone
import http.client
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "0.1.0"
API_BASE = "https://api.supabase.com"
USER_AGENT = f"supabase-api/{VERSION} (StartupBros-com/hov-stack)"
TOKEN_ENV = "SUPABASE_ACCESS_TOKEN"
METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE")
MAX_BODY = 16 * 1024 * 1024
MAX_RETRIES = 2
MAX_WINDOW = timedelta(hours=24)
PROJECTS_ENV = "SUPABASE_API_PROJECTS_FILE"
PROJECTS_NAME = "supabase-projects.json"


def projects_file():
    """Alias map location: the env override, then supabase-projects.json in the overlay
    directory, HOV_STACK_OVERLAY or $XDG_CONFIG_HOME/hov-stack (default ~/.config/hov-stack),
    the directory the other overlay readers use."""
    override = os.environ.get(PROJECTS_ENV)
    if override:
        return Path(override)
    overlay = os.environ.get("HOV_STACK_OVERLAY")
    if overlay:
        return Path(overlay) / PROJECTS_NAME
    config_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(config_home) / "hov-stack" / PROJECTS_NAME


def load_projects():
    """Project alias -> 20-letter ref. Refs are service identifiers, so they live in the overlay,
    never in the tree; config/supabase-projects.example.json shows the shape. A missing file
    leaves the map empty and an alias then fails closed in project_ref()."""
    path = projects_file()
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        raise CliError(f"supabase-api: cannot read project map {path}: {exc}", "usage")
    if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) and REF.fullmatch(v)
                                             for k, v in data.items()):
        raise CliError(f"supabase-api: {path} must be a JSON object of alias -> 20-letter project ref", "usage")
    return data


REF = re.compile(r"[a-z]{20}\Z")
_projects_cache = None


def projects():
    """Alias map, read on first use so --help and argument parsing never touch the file."""
    global _projects_cache
    if _projects_cache is None:
        _projects_cache = load_projects()
    return _projects_cache


# Literal segments the spec puts where a ref usually goes.
PROJECT_LITERALS = {"available-regions"}
TOKEN_PATTERN = re.compile(r"sbp_[A-Za-z0-9_]{20,200}\Z")
PATH_PATTERN = re.compile(r"/v1(/[A-Za-z0-9_.~{}\-]+)+\Z")
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\Z")
SINCE = re.compile(r"([1-9][0-9]{0,3})([mh])\Z")
TOKEN_SCRUB = re.compile(r"sbp_[A-Za-z0-9_]{8,}")
SECRET_KEY_SCRUB = re.compile(r"sb_secret_[A-Za-z0-9_\-]{8,}")
JWT_SCRUB = re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]+")
SECRET_FIELD = re.compile(r"(secret|password|passwd|(\A|_)pass\Z|(\A|_)token(_new|_current)?\Z|private_?(key|jwk)|credential"
                          r"|(access|api|root|service(_role)?|signing|encryption)_?key\Z)", re.I)
REDACTED = re.compile(r"\[redacted(-token|-key|-jwt)?\]")

_P = r"/v1/projects/[a-z]{20}"
# POSTs that only read; they run unprompted and retry like GETs.
READ_POSTS = tuple(re.compile(_P + p) for p in (
    r"/database/query/read-only\Z",
    r"/network-bans/retrieve(/enriched)?\Z",
    r"/vanity-subdomain/check-availability\Z",
))
# Configuration writes that run without --confirm-destructive. Never retried.
CONFIG_WRITES = tuple((m, re.compile(_P + p)) for m, p in (
    ("PATCH", r"\Z"),
    ("PATCH", r"/actions/[A-Za-z0-9_\-]+/status\Z"),
    ("PATCH", r"/database/backups/schedule\Z"),
    ("POST", r"/database/backups/restore-point\Z"),
    ("POST", r"/database/webhooks/enable\Z"),
    ("POST", r"/custom-hostname/(initialize|reverify)\Z"),
))
# The secrets endpoints hold each credential under the neutral key "value",
# in {name, value} request bodies and GET responses alike. A miss here fails
# open, so the match ignores case.
SECRETS_PATH = re.compile(_P + r"/secrets\Z", re.I)
SECRETS_FIELD = re.compile(SECRET_FIELD.pattern + r"|\Avalue\Z", re.I)

LOG_SERVICES = {
    "api": ("edge_logs", "id, log_attributes['identifier'] as identifier, timestamp, event_message, "
            "log_attributes['request.method'] as method, log_attributes['request.path'] as path, "
            "log_attributes['response.status_code'] as status_code"),
    "branch-action": ("workflow_run_logs", "log_attributes['workflow_run'] as workflow_run, timestamp, id, event_message"),
    "postgres": ("postgres_logs", "log_attributes['identifier'] as identifier, timestamp, id, event_message, "
                 "log_attributes['parsed.error_severity'] as error_severity"),
    "edge-function": ("function_edge_logs", "id, timestamp, event_message, "
                      "log_attributes['response.status_code'] as status_code, log_attributes['request.method'] as method, "
                      "log_attributes['function_id'] as function_id, log_attributes['execution_time_ms'] as execution_time_ms, "
                      "log_attributes['deployment_id'] as deployment_id, log_attributes['version'] as version"),
    "edge-function-runtime": ("function_logs", "id, timestamp, event_message, severity_text, "
                              "log_attributes['level'] as level, log_attributes['event_type'] as event_type, "
                              "log_attributes['function_id'] as function_id, log_attributes['execution_id'] as execution_id, "
                              "log_attributes['deployment_id'] as deployment_id, log_attributes['version'] as version"),
    "auth": ("auth_logs", "id, timestamp, event_message, log_attributes['level'] as level, "
             "log_attributes['status'] as status, log_attributes['path'] as path, log_attributes['msg'] as msg, "
             "log_attributes['error'] as error"),
    "storage": ("storage_logs", "id, timestamp, event_message"),
    "realtime": ("realtime_logs", "id, timestamp, event_message"),
}


class CliError(Exception):
    def __init__(self, message, code="request_failed", status=None):
        super().__init__(message)
        self.code = code
        self.status = status


class Parser(argparse.ArgumentParser):
    # A parse failure is a usage error in the same JSON envelope as every
    # other refusal, not free text on stderr; subcommand parsers inherit this
    # class. --help and --version still exit 0.
    def error(self, message):
        raise CliError(f"{message}; see supabase-api --help.", "usage")


def _jwt(match):
    try:
        segment = match.group(0).split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))
    except (ValueError, UnicodeError, binascii.Error):
        return "[redacted-jwt]"
    return match.group(0) if isinstance(claims, dict) and claims.get("role") == "anon" else "[redacted-jwt]"


def scrub(text, token=None):
    """Redact credentials from serialized output; anon keys are public and pass."""
    if not isinstance(text, str):
        return text
    if token:
        text = text.replace(token, "[redacted-token]")
    text = TOKEN_SCRUB.sub("[redacted-token]", text)
    text = SECRET_KEY_SCRUB.sub("[redacted-key]", text)
    return JWT_SCRUB.sub(_jwt, text)


def _public(text):
    # Anon JWTs and publishable keys are public by design, even under api_key.
    match = JWT_SCRUB.fullmatch(text)
    return text.startswith("sb_publishable_") or (match is not None and _jwt(match) == text)


def secret_keys(path):
    """The pattern naming secret keys for a request path."""
    return SECRETS_FIELD if SECRETS_PATH.match(path) else SECRET_FIELD


def redact_fields(value, secret=False, keys=SECRET_FIELD):
    """Blank string values under secret-named keys (smtp_pass, *_secret, ...)."""
    if isinstance(value, dict):
        return {k: redact_fields(v, secret or bool(keys.search(str(k))), keys) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_fields(v, secret, keys) for v in value]
    if secret and isinstance(value, str) and value and not _public(value):
        return "[redacted]"
    return value


def carries_placeholder(value):
    """True when a request value holds a redaction placeholder copied from this CLI's output."""
    if isinstance(value, dict):
        return any(carries_placeholder(k) or carries_placeholder(v) for k, v in value.items())
    if isinstance(value, (list, tuple)):
        return any(carries_placeholder(v) for v in value)
    return isinstance(value, str) and bool(REDACTED.search(value))


def secret_forms(value, secret=False, keys=SECRET_FIELD):
    """Each spelling of a request's secret-named values that a provider message could echo back."""
    if isinstance(value, dict):
        return {f for k, v in value.items() for f in secret_forms(v, secret or bool(keys.search(str(k))), keys)}
    if isinstance(value, list):
        return {f for v in value for f in secret_forms(v, secret, keys)}
    if secret and isinstance(value, str) and len(value) >= 4 and not _public(value):
        return {value, json.dumps(value)[1:-1], json.dumps(value, ensure_ascii=False)[1:-1]}
    return set()


def mask(value, forms):
    """Blank echoed request secrets inside string values, never in the JSON around them."""
    if isinstance(value, dict):
        return {k: mask(v, forms) for k, v in value.items()}
    if isinstance(value, list):
        return [mask(v, forms) for v in value]
    if isinstance(value, str):
        for form in sorted(forms, key=len, reverse=True):
            value = value.replace(form, "[redacted]")
    return value


def bounded_int(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"must be an integer from {low} to {high}") from None
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"must be an integer from {low} to {high}")
        return number
    return parse


def pair(value):
    key, sep, val = value.partition("=")
    if not sep or not key:
        raise argparse.ArgumentTypeError("must be key=value")
    return key, val


def method(value):
    upper = value.upper()
    if upper not in METHODS:
        raise argparse.ArgumentTypeError("must be GET, POST, PUT, PATCH or DELETE")
    return upper


def build_parser():
    # allow_abbrev=False on every parser: a prefix like --confirm-destr must not
    # stand in for --confirm-destructive, or it would slip past the ask rule.
    parser = Parser(
        prog="supabase-api", description=__doc__.split("\n\n")[0], allow_abbrev=False,
        epilog="Examples: supabase-api sql prbot 'select count(*) from public.users' | "
               "supabase-api logs prbot --service postgres --since 1h | "
               "supabase-api api GET /v1/projects/prbot/config/auth",
    )
    parser.add_argument("--version", action="version", version=f"supabase-api {VERSION}")
    parser.add_argument("--where", action="store_true", help="token source presence only; no reads or network")
    parser.add_argument("--timeout", type=bounded_int(1, 120), default=30, help="per-request timeout in seconds (default 30)")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")

    sub.add_parser("projects", allow_abbrev=False, help="list projects with their aliases")

    sql = sub.add_parser("sql", allow_abbrev=False, help="run SQL (read-only unless --write)")
    sql.add_argument("project")
    sql.add_argument("query", nargs="?", help="SQL text, or - for stdin")
    sql.add_argument("--file", help="read the SQL from this file")
    sql.add_argument("--param", action="append", default=[], help="text parameter for $1, $2, ...; repeatable")
    sql.add_argument("--write", action="store_true", help="use the read/write endpoint (needs --confirm-destructive)")
    sql.add_argument("--confirm-destructive", action="store_true", help="confirm a gated write after human approval")

    logs = sub.add_parser("logs", allow_abbrev=False, help="query project logs (window of at most 24 hours)")
    logs.add_argument("project")
    source = logs.add_mutually_exclusive_group(required=True)
    source.add_argument("--service", choices=sorted(LOG_SERVICES))
    source.add_argument("--sql", help="ClickHouse SQL over the logs table, e.g. from logs where source = 'edge_logs'")
    logs.add_argument("--since", help="window ending now, like 15m or 6h (default 1h, at most 24h)")
    logs.add_argument("--start", help="window start, UTC ISO 8601 ending in Z")
    logs.add_argument("--end", help="window end, UTC ISO 8601 ending in Z")
    logs.add_argument("--limit", type=bounded_int(1, 1000), default=100, help="rows for --service (default 100)")

    advisors = sub.add_parser("advisors", allow_abbrev=False, help="security or performance advisor lints")
    advisors.add_argument("project")
    advisors.add_argument("kind", choices=("security", "performance"))

    migrations = sub.add_parser("migrations", allow_abbrev=False, help="applied migration history")
    migrations.add_argument("project")

    api = sub.add_parser("api", allow_abbrev=False, help="any Management API endpoint")
    api.add_argument("method", type=method)
    api.add_argument("path", help="/v1/... path, optionally with ?query; {ref} takes --project")
    api.add_argument("--project", help="alias or ref that fills {ref} in PATH")
    api.add_argument("--body", metavar="FILE", help="JSON request body; - reads stdin")
    api.add_argument("--query", action="append", type=pair, default=[], metavar="KEY=VALUE", help="query parameter; repeatable")
    api.add_argument("--confirm-destructive", action="store_true", help="confirm a gated write after human approval")
    return parser


def project_ref(value):
    known = projects()
    if value in known:
        return known[value]
    if REF.fullmatch(value or ""):
        return value
    if not known:
        raise CliError(f"{value!r} is not a 20-letter ref and no project aliases are configured; "
                       f"set {PROJECTS_ENV} or create {projects_file()} "
                       f"(shape: config/supabase-projects.example.json).", "usage")
    raise CliError(f"{value!r} is not a project alias ({', '.join(known)}) or a 20-letter ref.", "usage")


def via(ref):
    alias = next((name for name, known in projects().items() if known == ref), None)
    return "supabase/" + (alias or ref)


def is_read(method_name, path):
    return method_name == "GET" or (method_name == "POST" and any(p.match(path) for p in READ_POSTS))


def gated(method_name, path):
    """True when the request needs --confirm-destructive."""
    return not is_read(method_name, path) and not any(m == method_name and p.match(path) for m, p in CONFIG_WRITES)


def _read(path, maximum):
    try:
        with Path(path).open("rb") as handle:
            data = handle.read(maximum + 1)
        if len(data) > maximum:
            return None
        return data.decode("utf-8")
    except (OSError, UnicodeError):
        return None


def _stdin():
    try:
        raw = sys.stdin.buffer.read(MAX_BODY + 1)
        return raw.decode("utf-8") if len(raw) <= MAX_BODY else None
    except (OSError, UnicodeError):
        return None


def source_metadata():
    """Presence information only, not a claim that the token works."""
    return {
        "resolved": False,
        "env:" + TOKEN_ENV: bool(os.environ.get(TOKEN_ENV)),
        "~/.secrets": (Path.home() / ".secrets").is_file(),
        "projects": projects(),
    }


def _secrets_token():
    body = _read(Path.home() / ".secrets", 1024 * 1024)
    if body is None:
        return None
    for line in body.splitlines():
        match = re.match(r"^\s*(?:export\s+)?([A-Z0-9_]+)\s*=(.*)$", line)
        if not match or match[1] != TOKEN_ENV:
            continue
        try:
            values = shlex.split(match[2], comments=True, posix=True)
        except ValueError:
            continue
        if len(values) == 1 and TOKEN_PATTERN.fullmatch(values[0]):
            return values[0]
    return None


def credentials():
    value = os.environ.get(TOKEN_ENV)
    if value:
        if not TOKEN_PATTERN.fullmatch(value):
            raise CliError(f"{TOKEN_ENV} has an invalid format (expected a personal access token, sbp_...).", "credential_invalid")
        return value, "env:" + TOKEN_ENV
    value = _secrets_token()
    if value:
        return value, "~/.secrets"
    raise CliError(f"No Supabase access token: checked env {TOKEN_ENV} and ~/.secrets. See the startupbros "
                   "Supabase credential runbook; do not mint a new token as a diagnostic.", "credential_missing")


def _utc(text, flag):
    if not ISO.fullmatch(text or ""):
        raise CliError(f"{flag} must be UTC ISO 8601 ending in Z, like 2026-10-07T00:00:00Z.", "usage")
    fmt = "%Y-%m-%dT%H:%M:%S.%fZ" if "." in text else "%Y-%m-%dT%H:%M:%SZ"
    try:
        return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
    except ValueError:
        raise CliError(f"{flag} is not a valid date and time.", "usage") from None


def _iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def log_window(args):
    if args.since and (args.start or args.end):
        raise CliError("Use --since or --start/--end, not both.", "usage")
    if args.start or args.end:
        if not (args.start and args.end):
            raise CliError("--start and --end go together.", "usage")
        start, end = _utc(args.start, "--start"), _utc(args.end, "--end")
    else:
        match = SINCE.fullmatch(args.since or "1h")
        if not match:
            raise CliError("--since takes minutes or hours, like 15m or 6h.", "usage")
        amount = int(match[1])
        span = timedelta(minutes=amount) if match[2] == "m" else timedelta(hours=amount)
        end = now()
        start = end - span
    if not start < end:
        raise CliError("The log window must end after it starts.", "usage")
    if end - start > MAX_WINDOW:
        raise CliError("The log window is at most 24 hours; narrow it.", "usage")
    return _iso(start), _iso(end)


def _sql_text(args):
    sources = [s for s in (args.query, args.file) if s is not None]
    if len(sources) != 1:
        raise CliError("Give the SQL once: as QUERY, - for stdin, or --file F.", "usage")
    if args.file is not None:
        text = _read(args.file, MAX_BODY)
    elif args.query == "-":
        text = _stdin()
    else:
        text = args.query
    if not text or not text.strip():
        raise CliError("The SQL is empty or unreadable.", "usage")
    return text


def _api_path(args):
    raw_path, _, raw_query = args.path.partition("?")
    segments = raw_path.split("/")
    if (not PATH_PATTERN.fullmatch(raw_path) or any(s in {".", ".."} for s in segments)
            or any("{" in s or "}" in s for s in segments if s != "{ref}")):
        raise CliError("PATH must be a Management API path like /v1/projects/{ref}/config/auth, not a URL.", "usage")
    if "{ref}" in segments:
        if not args.project:
            raise CliError("PATH has {ref}; give --project with an alias or ref.", "usage")
        ref = project_ref(args.project)
        segments = [ref if s == "{ref}" else s for s in segments]
    elif args.project:
        raise CliError("--project only fills {ref} in PATH.", "usage")
    ref = None
    if len(segments) > 3 and segments[2] == "projects":
        if segments[3] not in PROJECT_LITERALS:
            segments[3] = ref = project_ref(segments[3])
    query = urllib.parse.parse_qsl(raw_query, keep_blank_values=True) + list(args.query)
    return "/".join(segments), query, ref


def _json_body(source):
    text = _stdin() if source == "-" else _read(source, MAX_BODY)
    try:
        value = json.loads(text) if text is not None else None
    except ValueError:
        value = None
    if not isinstance(value, (dict, list)):
        raise CliError("--body must name a readable file (or -) holding a JSON object or array.", "usage")
    return value


def plan(args):
    """Validate the whole request before any token read or network call."""
    command = args.command
    if command == "projects":
        return {"method": "GET", "path": "/v1/projects", "query": [], "body": None, "via": "supabase/all"}
    if command not in {"sql", "logs", "advisors", "migrations", "api"}:
        raise CliError("Usage: supabase-api COMMAND ...; see --help.", "usage")
    if command == "api":
        path, query, ref = _api_path(args)
        if args.body is not None and args.method == "GET":
            raise CliError("--body does not apply to GET.", "usage")
        body = _json_body(args.body) if args.body is not None else None
        spec = {"method": args.method, "path": path, "query": query, "body": body,
                "via": via(ref) if ref else "supabase/api"}
    else:
        ref = project_ref(args.project)
        base = f"/v1/projects/{ref}"
        spec = {"method": "GET", "query": [], "body": None, "via": via(ref)}
        if command == "sql":
            body = {"query": _sql_text(args)}
            if args.param:
                body["parameters"] = list(args.param)
            spec.update(method="POST", body=body,
                        path=base + ("/database/query" if args.write else "/database/query/read-only"))
        elif command == "logs":
            start, end = log_window(args)
            if args.sql is not None:
                if not args.sql.strip():
                    raise CliError("--sql is empty.", "usage")
                sql = args.sql
            else:
                table, columns = LOG_SERVICES[args.service]
                sql = f"select {columns}\nfrom logs\nwhere source = '{table}'\norder by timestamp desc\nlimit {args.limit}"
            spec.update(path=base + "/analytics/endpoints/logs", window={"start": start, "end": end},
                        query=[("sql", sql), ("iso_timestamp_start", start), ("iso_timestamp_end", end)])
        elif command == "advisors":
            spec["path"] = f"{base}/advisors/{args.kind}"
        else:
            spec["path"] = base + "/database/migrations"
    if not is_read(spec["method"], spec["path"]) and carries_placeholder([spec["body"], spec["query"]]):
        raise CliError("The request carries a [redacted...] placeholder copied from supabase-api output; omit that "
                       "field instead of writing the placeholder back.", "usage")
    if gated(spec["method"], spec["path"]) and not args.confirm_destructive:
        raise CliError(f"{spec['method']} {spec['path']} is not a read or a listed configuration write; it requires "
                       "human approval and --confirm-destructive on this invocation.", "confirmation_required")
    return spec


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _parse(response):
    raw = response.read(MAX_BODY + 1)
    if len(raw) > MAX_BODY:
        raise CliError("Supabase response exceeded the 16 MiB limit.", "response_too_large")
    if not raw:
        return None
    try:
        text = raw.decode("utf-8")
    except UnicodeError:
        raise CliError("Supabase returned a body that is not UTF-8.", "response_invalid") from None
    try:
        return json.loads(text)
    except ValueError:
        # Some endpoints (metrics) answer in plain text.
        return text
    except RecursionError:
        raise CliError("Supabase returned JSON nested too deeply to parse.", "response_invalid") from None


def _provider_error(status, payload):
    message = None
    if isinstance(payload, dict):
        for key in ("message", "error", "msg"):
            if isinstance(payload.get(key), str) and payload[key]:
                message = payload[key]
                break
    if not message:
        message = {
            401: "Supabase rejected the access token.",
            403: "The access token lacks permission for this project or organization.",
            404: "Supabase could not find the requested resource.",
            429: "Supabase rate limit exceeded; retry later.",
        }.get(status, "Supabase returned a server error." if status >= 500 else "Supabase refused the request.")
    return CliError(message[:2000], "http_error", status)


def request(method_name, path, query, body, token, timeout, retry):
    url = API_BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    headers = {"Authorization": "Bearer " + token, "User-Agent": USER_AGENT, "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif method_name != "GET":
        data = b""
    last = None
    for attempt in range(MAX_RETRIES + 1 if retry else 1):
        if attempt:
            time.sleep(0.5 * 2 ** (attempt - 1))
        req = urllib.request.Request(url, data=data, method=method_name, headers=headers)
        try:
            with opener.open(req, timeout=timeout) as response:
                return _parse(response)
        except urllib.error.HTTPError as exc:
            try:
                payload = _parse(exc)
            except (CliError, OSError, ValueError, http.client.HTTPException):
                payload = None
            finally:
                exc.close()
            if 300 <= exc.code < 400:
                last = CliError("Supabase returned a redirect; refusing to follow it with credentials.", "http_error", exc.code)
                break
            last = _provider_error(exc.code, payload)
            if not (exc.code == 429 or exc.code >= 500):
                break
        except CliError as exc:
            last = exc
            break
        except (TimeoutError, urllib.error.URLError, OSError, http.client.HTTPException):
            # HTTPException covers IncompleteRead: a body cut off after a write
            # may have been applied is an uncertain outcome too.
            last = CliError("Supabase connection failed or timed out.", "transport_error")
    uncertain = last.code in {"transport_error", "response_invalid", "response_too_large"} or (last.status or 0) >= 500
    if not retry and uncertain:
        raise CliError(f"{last} Supabase may already have applied this {method_name}; GET the resource before retrying.",
                       last.code, last.status)
    raise last


def _logs(spec, token, timeout):
    # The logs endpoint can answer HTTP 200 with an error body; a transient
    # one says to retry.
    for attempt in range(MAX_RETRIES + 1):
        if attempt:
            time.sleep(0.5 * 2 ** (attempt - 1))
        data = request("GET", spec["path"], spec["query"], None, token, timeout, True)
        error = data.get("error") if isinstance(data, dict) else None
        if not error:
            return data
        message = error if isinstance(error, str) else (error.get("message") if isinstance(error, dict) else None)
        message = message if isinstance(message, str) and message else json.dumps(error)[:2000]
        if "retry" not in message.lower():
            break
    raise CliError(f"Supabase logs query failed: {message[:2000]}", "logs_error", 200)


def run(args, state):
    spec = plan(args)
    keys = secret_keys(spec["path"])
    state["secrets"] = secret_forms([spec["body"], [{key: value} for key, value in spec["query"]]], keys=keys)
    token, source = credentials()
    state["token"] = token
    if spec["method"] == "GET" and spec["path"].endswith("/analytics/endpoints/logs"):
        data = _logs(spec, token, args.timeout)
    else:
        data = request(spec["method"], spec["path"], spec["query"], spec["body"], token, args.timeout,
                       is_read(spec["method"], spec["path"]))
    result = {"ok": True, "via": spec["via"], "method": spec["method"], "path": spec["path"],
              "credential_source": source}
    if args.command == "projects" and isinstance(data, list):
        aliases = {ref: name for name, ref in projects().items()}
        data = [{**p, "alias": aliases.get(p.get("ref") or p.get("id"))} if isinstance(p, dict) else p for p in data]
    if args.command == "logs":
        result["window"] = spec["window"]
        data = data.get("result") if isinstance(data, dict) else data
    if isinstance(data, list):
        result["row_count"] = len(data)
    result["data"] = redact_fields(data, keys=keys)
    return result


def main(argv=None):
    parser = build_parser()
    state = {"token": None, "secrets": set()}
    try:
        args = parser.parse_args(argv)
        if args.where:
            print(json.dumps(source_metadata(), sort_keys=True))
            return 0
        result = run(args, state)
        print(scrub(json.dumps(mask(result, state["secrets"]), ensure_ascii=False), state["token"]))
        return 0
    except CliError as exc:
        message = mask(str(exc), state["secrets"])
        print(scrub(json.dumps({"ok": False, "error": {"code": exc.code, "message": message, "http_status": exc.status}}),
                    state["token"]))
        return 2 if exc.code in {"usage", "confirmation_required"} else 1
    except Exception:
        # Never include exception text: a transport message can carry the token.
        print(json.dumps({"ok": False, "error": {"code": "internal_error", "message": "supabase-api failed unexpectedly.",
                                                 "http_status": None}}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
