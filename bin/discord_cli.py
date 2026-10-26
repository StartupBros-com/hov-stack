#!/usr/bin/env python3
"""On-demand Discord REST reads, confirmed message writes, and an API passthrough.

No Gateway connection, background worker, or API-base configuration: `api`
reaches routes relative to the fixed v10 origin only. Credentials resolve env
DISCORD_BOT_TOKEN, env DISCORD_TOKEN, canonical BWS DISCORD_BOT_TOKEN, then
parsed ~/.secrets. --where lists source metadata without reading a credential
or contacting BWS/Discord. JSON is the output format; --json is accepted for
consistency with other harness CLIs.

--confirm-write is an invocation guard, not a substitute for human approval.
send, edit, delete, and every non-GET api call require it.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "0.2.0"
API_BASE = "https://discord.com/api/v10"
BWS_TIMEOUT = 30
MAX_BODY = 4 * 1024 * 1024
MAX_RETRIES = 2
MAX_RETRY_WAIT = 10
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_.-]{1,256}\Z")
WRITES = frozenset({"send", "edit", "delete"})
API_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE")
MAX_API_BODY = 1024 * 1024
# Route segments: unreserved characters plus Discord's @me and name:id emoji
# forms, or percent escapes. No dot, so "." and ".." segments cannot occur.
API_SEGMENT = re.compile(r"(?:[A-Za-z0-9_~@:-]|%[0-9A-Fa-f]{2})+\Z")
API_QUERY_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_.]{0,63}\Z")


class CliError(Exception):
    def __init__(self, message, code="request_failed", status=None, discord_code=None):
        super().__init__(message)
        self.code = code
        self.status = status
        self.discord_code = discord_code


def snowflake(value):
    if not re.fullmatch(r"[1-9][0-9]{0,19}", value) or int(value) > 2**64 - 1:
        raise argparse.ArgumentTypeError("must be a positive decimal Discord snowflake (64-bit)")
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


def search_query(value):
    if not 1 <= len(value.strip()) <= 100:
        raise argparse.ArgumentTypeError("query must contain 1-100 characters")
    return value


def api_path(value):
    """A route relative to the v10 origin: no origin, scheme, traversal, query, or fragment."""
    route = value[1:] if value.startswith("/") else value
    if (len(value) > 2048 or re.match(r"[A-Za-z][A-Za-z0-9+.-]*:", route)
            or not all(API_SEGMENT.match(part) for part in route.split("/"))
            or re.search(r"%(?:2[EeFf]|5[Cc])", route)):
        raise argparse.ArgumentTypeError(
            "must be a Discord API v10 route such as /guilds/<id>/audit-logs: no origin, scheme, "
            "'.' or '..' segment, encoded dot or slash, '?', '#', or empty segment; percent-encode emoji")
    return "/" + route


def api_query(value):
    key, separator, item = value.partition("=")
    if not separator or not API_QUERY_KEY.match(key) or len(item) > 2048:
        raise argparse.ArgumentTypeError("must be KEY=VALUE with a simple key and at most 2048 value characters")
    return key, item


def _common(parser, child=False):
    default = argparse.SUPPRESS if child else False
    parser.add_argument("--json", action="store_true", default=default, help="JSON output (the default)")
    parser.add_argument("--timeout", type=bounded_int(1, 30),
                        default=argparse.SUPPRESS if child else 15,
                        help="request timeout in seconds (1-30; default 15)")


def build_parser():
    parser = argparse.ArgumentParser(prog="discord-cli", description=__doc__.split("\n\n")[0])
    _common(parser)
    parser.add_argument("--version", action="version", version=f"discord-cli {VERSION}")
    parser.add_argument("--where", action="store_true", help="source metadata only; no credential reads or network")
    commands = parser.add_subparsers(dest="command")
    for name, help_text in [
        ("guild", "get guild details"),
        ("channels", "list guild channels"),
        ("channel", "get channel details"),
        ("messages", "get one page of channel messages"),
        ("message", "get one message"),
        ("roles", "list guild roles"),
        ("events", "list scheduled guild events"),
        ("members-search", "search guild members"),
        ("send", "send a message (human approval and --confirm-write required)"),
        ("edit", "edit a message (human approval and --confirm-write required)"),
        ("delete", "delete a message (human approval and --confirm-write required)"),
    ]:
        child = commands.add_parser(name, help=help_text)
        _common(child, child=True)
        if name in {"guild", "channels", "roles", "events", "members-search"}:
            child.add_argument(
                "--guild",
                type=snowflake,
                default=os.environ.get("DISCORD_GUILD_ID") or None,
                help="guild snowflake (default DISCORD_GUILD_ID)",
            )
        if name in {"channel", "messages", "message", "send", "edit", "delete"}:
            child.add_argument("channel_id", type=snowflake)
        if name == "message":
            child.add_argument("message_id", type=snowflake)
        if name in {"edit", "delete"}:
            child.add_argument("message_id", type=snowflake, nargs="?")
            child.add_argument(
                "--message-id-file", help="UTF-8 file containing one message snowflake"
            )
        if name in {"send", "edit"}:
            child.add_argument(
                "--content-file",
                required=True,
                help="UTF-8 message content file, or - for stdin (1-2000 characters)",
            )
        if name in WRITES:
            child.add_argument(
                "--confirm-write",
                action="store_true",
                help="confirm this write after obtaining human approval",
            )
        if name == "messages":
            child.add_argument("--limit", type=bounded_int(1, 100), default=50)
            cursor = child.add_mutually_exclusive_group()
            for flag in ["before", "after", "around"]:
                cursor.add_argument("--" + flag, type=snowflake)
        if name == "members-search":
            child.add_argument("query", type=search_query)
            child.add_argument("--limit", type=bounded_int(1, 1000), default=100)
        if name == "events":
            child.add_argument("--with-user-count", action="store_true")
    api = commands.add_parser("api", help="call a Discord API v10 route (non-GET: human approval and --confirm-write required)")
    _common(api, child=True)
    api.add_argument("method", choices=API_METHODS, help="HTTP method, uppercase")
    api.add_argument("path", type=api_path, help="route relative to https://discord.com/api/v10, e.g. /guilds/<id>/audit-logs")
    api.add_argument("--query", type=api_query, action="append", default=[], metavar="KEY=VALUE",
                     help="query parameter; repeat for more")
    api.add_argument("--body", metavar="FILE",
                     help="UTF-8 JSON object or array request body file, or - for stdin (non-GET only, 1 MiB max)")
    api.add_argument("--confirm-write", action="store_true",
                     help="confirm a non-GET call after obtaining human approval")
    return parser


def _read(path, maximum):
    try:
        with Path(path).open("rb") as handle:
            data = handle.read(maximum + 1)
        if len(data) > maximum:
            return None
        return data.decode("utf-8")
    except (OSError, UnicodeError):
        return None


def source_metadata():
    """Presence information only, not a claim that these credentials work."""
    home = Path.home()
    return {
        "resolved": False,
        "sources": {
            "env:DISCORD_BOT_TOKEN": bool(os.environ.get("DISCORD_BOT_TOKEN")),
            "env:DISCORD_TOKEN": bool(os.environ.get("DISCORD_TOKEN")),
            "bws:DISCORD_BOT_TOKEN": {
                "binary_present": shutil.which("bws") is not None,
                "access_token_configured": bool(os.environ.get("BWS_ACCESS_TOKEN")) or (home / ".config/bws/token").is_file(),
                "project_configured": bool(os.environ.get("BWS_PROJECT_ID")) or (home / ".config/bws/sb-project-id").is_file(),
            },
            "~/.secrets": (home / ".secrets").is_file(),
        },
    }


def _validate_token(value):
    if not isinstance(value, str) or not TOKEN_PATTERN.fullmatch(value):
        raise CliError("Discord bot credential has an invalid format.", "credential_invalid")
    return value


def _bws_credential():
    home = Path.home()
    if shutil.which("bws") is None:
        return None, None
    access = os.environ.get("BWS_ACCESS_TOKEN")
    if not access:
        access = _read(home / ".config/bws/token", 65536)
        access = access.strip() if access else None
    project = os.environ.get("BWS_PROJECT_ID")
    if not project:
        project = _read(home / ".config/bws/sb-project-id", 1024)
        project = project.strip() if project else None
    if not access or not project:
        return None, None
    try:
        result = subprocess.run(
            ["bws", "--color", "no", "secret", "list", project],
            capture_output=True, text=True, errors="replace", timeout=BWS_TIMEOUT,
            env={**os.environ, "BWS_ACCESS_TOKEN": access},
        )
    except subprocess.TimeoutExpired:
        return None, "bws_timeout"
    except OSError:
        return None, "bws_unavailable"
    if result.returncode or len(result.stdout) > 1024 * 1024:
        return None, "bws_unavailable"
    try:
        entries = json.loads(result.stdout)
    except (ValueError, TypeError):
        return None, "bws_unavailable"
    if not isinstance(entries, list):
        return None, "bws_unavailable"
    for item in entries:
        if isinstance(item, dict) and item.get("key") == "DISCORD_BOT_TOKEN" and item.get("value"):
            return _validate_token(item["value"]), None
    return None, None


def _secrets_credential():
    body = _read(Path.home() / ".secrets", 1024 * 1024)
    if body is None:
        return None
    found = {}
    for line in body.splitlines():
        match = re.match(r"^\s*(?:export\s+)?(DISCORD_BOT_TOKEN|DISCORD_TOKEN)\s*=(.*)$", line)
        if not match:
            continue
        try:
            values = shlex.split(match[2], comments=True, posix=True)
        except ValueError:
            continue
        if len(values) == 1 and TOKEN_PATTERN.fullmatch(values[0]):
            found[match[1]] = values[0]
    return found.get("DISCORD_BOT_TOKEN") or found.get("DISCORD_TOKEN")


def credentials():
    for name in ["DISCORD_BOT_TOKEN", "DISCORD_TOKEN"]:
        value = os.environ.get(name)
        if value:
            return _validate_token(value), "env:" + name
    value, failure = _bws_credential()
    if value:
        return value, "bws:DISCORD_BOT_TOKEN"
    value = _secrets_credential()
    if value:
        return value, "~/.secrets"
    if failure == "bws_timeout":
        raise CliError("BWS did not respond within 30 seconds and no local Discord credential was found.", "credential_timeout")
    raise CliError("No Discord bot credential found: checked environment, BWS DISCORD_BOT_TOKEN, and ~/.secrets.", "credential_missing")


def _input(filename, maximum):
    """UTF-8 text of a file or - (stdin); None when unreadable or over maximum bytes."""
    if filename != "-":
        return _read(filename, maximum)
    try:
        raw = sys.stdin.buffer.read(maximum + 1)
        return raw.decode("utf-8") if len(raw) <= maximum else None
    except (OSError, UnicodeError):
        return None


def _message_content(filename):
    value = _input(filename, 8000)
    if value is None or not value.strip() or len(value) > 2000:
        raise CliError("Message content must be readable UTF-8 containing 1-2000 characters.", "usage")
    return value


def _reject_constant(name):
    raise ValueError(name)


def _api_body(filename):
    text = _input(filename, MAX_API_BODY)
    try:
        value = json.loads(text, parse_constant=_reject_constant) if text is not None else None
        # A lone surrogate parses but cannot be sent as UTF-8, and 1e400 parses
        # to inf, which would be sent as the non-JSON token Infinity.
        json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
    except (ValueError, RecursionError):
        value = None
    if not isinstance(value, (dict, list)):
        raise CliError("--body must be a readable UTF-8 JSON object or array of at most 1 MiB.", "usage")
    return value


def operation(args):
    """Validate writes before reading any file, credential, or network."""
    if args.command == "api":
        if args.method != "GET" and not args.confirm_write:
            raise CliError("This write requires human approval and --confirm-write on this invocation.", "write_confirmation_required")
        if args.method == "GET" and args.body is not None:
            raise CliError("--body is only accepted for POST, PUT, PATCH, and DELETE.", "usage")
        payload = _api_body(args.body) if args.body is not None else None
        return args.method, args.path, list(args.query), payload
    if args.command in WRITES and not args.confirm_write:
        raise CliError("This write requires human approval and --confirm-write on this invocation.", "write_confirmation_required")
    message_id = getattr(args, "message_id", None)
    if args.command in {"edit", "delete"}:
        if bool(message_id) == bool(args.message_id_file):
            raise CliError("Supply one message ID or --message-id-file.", "usage")
        if args.message_id_file:
            raw = _read(args.message_id_file, 100)
            try:
                message_id = snowflake(raw.strip()) if raw else None
            except argparse.ArgumentTypeError:
                message_id = None
            if not message_id:
                raise CliError("Message ID file must contain one valid Discord snowflake.", "usage")
    name = args.command
    channel = getattr(args, "channel_id", None)
    guild = getattr(args, "guild", None)
    if name in {"guild", "channels", "roles", "events", "members-search"} and not guild:
        raise CliError(
            "Supply --guild or set DISCORD_GUILD_ID for this command.", "usage"
        )
    query = {}
    payload = None
    method = "GET"
    if name == "guild":
        path = f"/guilds/{guild}"
    elif name in {"channels", "roles"}:
        path = f"/guilds/{guild}/{name}"
    elif name == "events":
        path = f"/guilds/{guild}/scheduled-events"
        if args.with_user_count:
            query["with_user_count"] = "true"
    elif name == "members-search":
        path = f"/guilds/{guild}/members/search"
        query = {"query": args.query, "limit": args.limit}
    elif name == "channel":
        path = f"/channels/{channel}"
    elif name in {"messages", "send"}:
        path = f"/channels/{channel}/messages"
        if name == "messages":
            query["limit"] = args.limit
            for cursor in ["before", "after", "around"]:
                value = getattr(args, cursor)
                if value:
                    query[cursor] = value
        else:
            method = "POST"
    else:
        path = f"/channels/{channel}/messages/{message_id}"
        if name == "edit":
            method = "PATCH"
        elif name == "delete":
            method = "DELETE"
    if name in {"send", "edit"}:
        payload = {"content": _message_content(args.content_file), "allowed_mentions": {"parse": []}}
    return method, path, query, payload


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _response_body(response, deadline, idle_timeout):
    raw = bytearray()
    # HTTPResponse.read(n) can wait for the whole body while a peer keeps the
    # idle timeout alive. read1 exposes smaller chunks for budget checks, also
    # at EOF and in error bodies. urllib chunk framing may still block inside
    # read1, so these checks do not interrupt every internal transport operation.
    read = getattr(response, "read1", response.read)
    while True:
        if time.monotonic() >= deadline:
            raise CliError("Discord request exceeded its time budget.", "request_timeout")
        # urllib's standard HTTPResponse retains the socket through its buffered
        # file; HTTPError wraps that response once. Clamp its idle timeout to
        # the remaining budget. In-memory/closed responses have no socket.
        stream = getattr(response, "fp", None)
        if isinstance(response, urllib.error.HTTPError):
            stream = getattr(stream, "fp", None)
        sock = getattr(getattr(stream, "raw", None), "_sock", None)
        try:
            if sock is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise CliError("Discord request exceeded its time budget.", "request_timeout")
                sock.settimeout(min(idle_timeout, remaining))
            chunk = read(min(65536, MAX_BODY - len(raw) + 1))
        except OSError:
            if time.monotonic() >= deadline:
                raise CliError("Discord request exceeded its time budget.", "request_timeout") from None
            raise CliError("Discord connection failed or timed out.", "transport_error") from None
        if time.monotonic() >= deadline:
            raise CliError("Discord request exceeded its time budget.", "request_timeout")
        if not chunk:
            break
        raw.extend(chunk)
        if len(raw) > MAX_BODY:
            raise CliError("Discord response exceeded the 4 MiB limit.", "response_too_large")
    try:
        return json.loads(raw.decode("utf-8")) if raw else None
    except (ValueError, UnicodeError, RecursionError):
        raise CliError("Discord returned invalid JSON.", "response_invalid") from None


def _provider_error(status, body):
    code = body.get("code") if isinstance(body, dict) else None
    if type(code) is not int:
        code = None
    message = {
        401: "Discord rejected the bot credential.",
        403: "The bot lacks permission for this operation.",
        404: "Discord could not find the requested resource.",
        429: "Discord rate limit exceeded; retry later.",
    }.get(status, "Discord refused the request.")
    if 300 <= status < 400:
        message = "Discord returned a redirect; refusing to follow it with credentials."
    elif status >= 500:
        message = "Discord returned a server error."
    return CliError(message, "http_error", status, code)


# Failures after a request was sent: a write may already have taken effect.
# A 5xx is one too; 4xx and 429 mean Discord did not process the request.
UNCERTAIN_OUTCOME = frozenset({"transport_error", "request_timeout", "response_invalid", "response_too_large"})


def request(method, path, query, payload, token, timeout):
    try:
        return _request(method, path, query, payload, token, timeout)
    except CliError as error:
        server_error = error.code == "http_error" and (error.status or 0) >= 500
        if method == "GET" or not (error.code in UNCERTAIN_OUTCOME or server_error):
            raise
        raise CliError(f"{error} Discord may already have applied this {method}; read the affected resource before retrying.",
                       error.code, error.status, error.discord_code) from None


def _request(method, path, query, payload, token, timeout):
    url = API_BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
    headers = {
        "Authorization": "Bot " + token,
        "User-Agent": f"DiscordBot (https://github.com/StartupBros-com/hov-stack, {VERSION})",
        "Accept": "application/json",
    }
    # Body-less writes go out with http.client's Content-Length: 0 and no type.
    if encoded is not None:
        headers["Content-Type"] = "application/json"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    deadline = time.monotonic() + timeout + MAX_RETRY_WAIT
    for attempt in range(MAX_RETRIES + 1):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CliError("Discord request exceeded its time budget.", "request_timeout")
        req = urllib.request.Request(url, data=encoded, method=method, headers=headers)
        try:
            with opener.open(req, timeout=min(timeout, remaining)) as response:
                status = response.getcode()
                if not 200 <= status < 300:
                    raise _provider_error(status, None)
                return _response_body(response, deadline, timeout)
        except urllib.error.HTTPError as exc:
            try:
                body = _response_body(exc, deadline, timeout)
            except CliError as body_error:
                if body_error.code == "request_timeout":
                    raise
                body = None
            finally:
                exc.close()
            if exc.code == 429 and attempt < MAX_RETRIES and isinstance(body, dict):
                retry = body.get("retry_after")
                remaining = deadline - time.monotonic()
                if type(retry) in {int, float} and math.isfinite(retry) and 0 <= retry <= MAX_RETRY_WAIT and retry < remaining:
                    time.sleep(retry)
                    continue
            raise _provider_error(exc.code, body) from None
        except (TimeoutError, urllib.error.URLError, OSError):
            raise CliError("Discord connection failed or timed out.", "transport_error") from None
    raise CliError("Discord rate limit exceeded; retry later.", "http_error", 429)


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.where:
        print(json.dumps(source_metadata(), sort_keys=True))
        return 0
    if not args.command:
        parser.error("a command or --where is required")
    try:
        method, path, query, payload = operation(args)
        token, source = credentials()
        data = request(method, path, query, payload, token, args.timeout)
        if args.command == "messages" and isinstance(data, list) and len(data) == args.limit:
            ids = []
            for item in data:
                value = item.get("id") if isinstance(item, dict) else None
                if isinstance(value, str):
                    try:
                        ids.append(int(snowflake(value)))
                    except argparse.ArgumentTypeError:
                        pass
            cursor = ""
            if ids:
                if args.after:
                    cursor = f" Continue with --after {max(ids)}."
                elif args.around:
                    cursor = f" Older: --before {min(ids)}; newer: --after {max(ids)}."
                else:
                    cursor = f" Continue with --before {min(ids)}."
            print(f"Warning: Discord returned the requested {args.limit} messages; more may exist.{cursor}", file=sys.stderr)
        print(json.dumps({"ok": True, "via": "discord/" + args.command, "credential_source": source, "data": data}, ensure_ascii=False))
        return 0
    except CliError as exc:
        print(json.dumps({"ok": False, "error": {"code": exc.code, "message": str(exc), "http_status": exc.status, "discord_code": exc.discord_code}}))
        return 2 if exc.code in {"usage", "write_confirmation_required"} else 1
    except Exception:
        # Never include exception text: transports and credential helpers can
        # contain Authorization values in their messages.
        print(json.dumps({"ok": False, "error": {"code": "internal_error", "message": "Discord CLI failed unexpectedly.", "http_status": None, "discord_code": None}}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
