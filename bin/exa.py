#!/usr/bin/env python3
"""Agent-native Exa web search and page contents access.

WHY THIS EXISTS

Every agent lane in the harness -- Claude Code sessions and subagents, Codex,
and shell scripts -- reaches Exa through one command instead of Claude Code's
Exa MCP registration, with the resolved credential source and the dollar
cost of each call visible on every response.

Same shape as `dfs`: Exa is REST+JSON behind an `x-api-key` header, so this
file is stdlib-only, no venv.

CREDENTIAL RESOLUTION, in order:

  1. EXA_API_KEY in the environment
  2. Bitwarden Secrets Manager  <- CANONICAL, put it here
     EXA_API_KEY in the account's secrets project, bounded at BWS_TIMEOUT_SECONDS
  3. ~/.secrets                 (local cache, parsed, never sourced)

`--where` reports which source resolved without ever printing the key.

`search` and `contents` call Exa's REST API. Every provider, transport, or
unexpected failure renders through one contract --
`{error, http_status, tag, request_id, via}` -- as the only stdout under
`--json`, or one line on stderr without it; never a traceback. `EXA_API_BASE`
overrides the base URL for tests, honored only for a loopback host. A
`contents` response's `items[]` always carries `tag`/`http_status` keys,
`null` outside an error, so a caller can read `item["tag"]` uniformly.

Usage:
  exa.py search <query>          [--json] [--text] [--type T] [--limit N] [--max-chars N]
  exa.py contents <url-or-id>... [--json] [--ids] [--text] [--max-age-hours H] [--max-chars N]

  --json     machine-readable (accepted before or after the subcommand)
  --timeout  outbound request timeout in seconds (parent-only, default 90)
  --where    print which credential source resolved, then exit
  --version  print the version and exit
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

VERSION = "0.1.0"

SECRETS_FILE = os.path.expanduser("~/.secrets")
BWS_TOKEN = os.path.expanduser("~/.config/bws/token")
BWS_PROJECT = os.path.expanduser("~/.config/bws/sb-project-id")

# Overridable only so exa-cli.test.sh can bound a hung fake `bws` without
# waiting out the real bound; the live default is always 30 seconds (R18).
BWS_TIMEOUT_SECONDS = int(os.environ.get("EXA_BWS_TIMEOUT_SECONDS", "30"))

DEFAULT_TIMEOUT_SECONDS = 90
SEARCH_TYPES = ("instant", "fast", "auto", "deep-lite", "deep", "deep-reasoning")

DEFAULT_BASE = "https://api.exa.ai"
# EXA_API_BASE overrides the endpoint, honored only for a loopback host (KTD11).
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


class _BwsTimeout(Exception):
    """bws did not respond within BWS_TIMEOUT_SECONDS."""


def _from_secrets_file():
    """EXA_API_KEY from ~/.secrets. Parsed, never sourced."""
    try:
        with open(SECRETS_FILE, "r", encoding="utf-8") as handle:
            body = handle.read()
    except (OSError, UnicodeDecodeError):
        # A non-UTF-8 file is treated as "no key here", same as a missing
        # file -- never a traceback out of the never-a-traceback contract.
        return None

    match = re.search(r"^(?:export\s+)?EXA_API_KEY=(.*)$", body, re.M)
    if not match:
        return None
    value = match.group(1).strip().strip("\"'")
    if not value:
        return None
    return value, "~/.secrets"


def _from_bws():
    """Canonical source. Absent bws or absent secrets both fall through;
    a hang past the bound raises _BwsTimeout so the caller can name the
    real cause instead of reporting a plain not-found.
    """
    import subprocess

    try:
        token = open(BWS_TOKEN, encoding="utf-8").read().strip()
        project = open(BWS_PROJECT, encoding="utf-8").read().strip()
    except (OSError, UnicodeDecodeError):
        return None

    try:
        out = subprocess.run(
            ["bws", "--color", "no", "secret", "list", project],
            capture_output=True, text=True, timeout=BWS_TIMEOUT_SECONDS,
            errors="replace",  # garbled bws stdout must decode, never raise
            env={**os.environ, "BWS_ACCESS_TOKEN": token},
        )
    except subprocess.TimeoutExpired:
        raise _BwsTimeout(BWS_TIMEOUT_SECONDS)
    except OSError:
        return None

    if out.returncode != 0:
        return None
    try:
        secrets = {s.get("key"): s.get("value") for s in json.loads(out.stdout)}
    except (json.JSONDecodeError, TypeError, AttributeError):
        return None

    value = secrets.get("EXA_API_KEY")
    if value:
        return value, "bws (EXA_API_KEY)"
    return None


def credentials():
    """Return (key, source). Exits with guidance if none found."""
    value = os.environ.get("EXA_API_KEY")
    if value:
        return value, "env"

    try:
        got = _from_bws()
    except _BwsTimeout as exc:
        sys.exit(f"Exa credentials: bws (Bitwarden Secrets Manager) did not respond within {exc}s.")
    if got:
        return got

    got = _from_secrets_file()
    if got:
        return got

    sys.exit("No Exa credentials found. Checked: env (EXA_API_KEY), bws (Bitwarden Secrets Manager), ~/.secrets.")


def resolve_base():
    """EXA_API_BASE default https://api.exa.ai. Honored only for an exact
    loopback hostname -- never a substring match, so a lookalike like
    127.0.0.1.evil.com is rejected -- and checked before credentials() runs.
    An unrestricted override would let an inherited env var route the live
    key to any host on the next unprompted call (KTD11)."""
    base = os.environ.get("EXA_API_BASE")
    if base is None:
        return DEFAULT_BASE
    host = urllib.parse.urlparse(base).hostname
    if host not in LOOPBACK_HOSTS:
        sys.exit(
            f"EXA_API_BASE={base!r} is not a loopback host. "
            "Refusing to send Exa credentials anywhere but "
            "127.0.0.1, ::1, or localhost."
        )
    return base


def _limit_type(value):
    """argparse type for --limit: 1-100 (R20), rejected before any request
    by argparse itself, which is what makes this run before parsing finishes."""
    n = int(value)
    if not 1 <= n <= 100:
        raise argparse.ArgumentTypeError(f"must be between 1 and 100 (got {n})")
    return n


def _timeout_type(value):
    """argparse type for --timeout: at least 1 second, rejected before any
    request by argparse itself (mirrors _limit_type)."""
    n = int(value)
    if n < 1:
        raise argparse.ArgumentTypeError(f"must be at least 1 (got {n})")
    return n


def build_parser():
    parser = argparse.ArgumentParser(
        prog="exa-cli",
        description="Agent-native Exa web search and page contents access.",
    )
    parser.add_argument("--json", action="store_true", default=False, help="machine-readable output")
    parser.add_argument(
        "--timeout", type=_timeout_type, default=DEFAULT_TIMEOUT_SECONDS,
        help=f"outbound request timeout in seconds (default: {DEFAULT_TIMEOUT_SECONDS})",
    )
    parser.add_argument("--where", action="store_true", help="print the resolved credential source and exit")
    parser.add_argument("--version", action="version", version=f"exa-cli {VERSION}")
    sub = parser.add_subparsers(dest="cmd")

    search_p = sub.add_parser("search", help="search the web")
    search_p.add_argument("query")
    # SUPPRESS default: an absent --json here must not clobber a parent-level
    # --json on merge (KTD2; the defect this guards is gsc.py:267,271, where
    # the subparser's plain False default overwrites the parent's True).
    search_p.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    search_p.add_argument("--text", action="store_true", help="request full page text instead of highlights")
    search_p.add_argument("--type", choices=SEARCH_TYPES, default="auto", help="Exa search type")
    search_p.add_argument("--limit", type=_limit_type, default=10, help="number of results (1-100)")
    search_p.add_argument("--max-chars", type=int, default=None, help="cap on returned characters")

    contents_p = sub.add_parser("contents", help="fetch page contents")
    contents_p.add_argument("targets", nargs="+", metavar="url-or-id")
    contents_p.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    contents_p.add_argument("--ids", action="store_true", help="treat targets as Exa ids, not URLs")
    contents_p.add_argument("--text", action="store_true", help="request full page text instead of highlights")
    contents_p.add_argument(
        "--max-age-hours", type=int, default=None,
        help="force a fresh crawl with 0, or cache-only with -1",
    )
    contents_p.add_argument("--max-chars", type=int, default=None, help="cap on returned characters")

    return parser


_REMEDIATION_402 = {
    "NO_MORE_CREDITS": "Exa account is out of credits. Add credits or wait for the next billing cycle.",
    "API_KEY_BUDGET_EXCEEDED": "This API key's budget is exhausted. Raise the key's budget or use a different key.",
    "TEAM_BUDGET_EXCEEDED": "The team's budget is exhausted. Raise the team budget in the Exa dashboard.",
}


def _parse_json_object(raw):
    """Best-effort JSON parse. Returns {} for an HTML error page or a
    truncated body alike -- both real Exa failure modes -- so callers never
    branch on a decode exception."""
    try:
        obj = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}
    return obj if isinstance(obj, dict) else {}


def _error_from_http(exc, source, via):
    """Build the KTD5 error object from an HTTPError. Branches on the HTTP
    status first, then best-effort JSON, so a 502 HTML page or a truncated
    500 body still renders through the same contract instead of raising."""
    status = exc.code
    try:
        raw = exc.read().decode("utf-8", "replace")
    except OSError:
        raw = ""
    body = _parse_json_object(raw)

    tag = body.get("tag")
    request_id = body.get("requestId")
    message = body.get("error")

    if status == 402 and tag in _REMEDIATION_402:
        message = _REMEDIATION_402[tag]
    elif status == 401:
        # Names the resolved credential SOURCE (env/bws/~/.secrets), never
        # anything derived from the key itself.
        message = f"Invalid Exa API key (source: {source})."
    elif 300 <= status < 400:
        message = f"Exa answered with a redirect (HTTP {status}); refusing to follow it with credentials."
    elif not message:
        message = f"Exa returned HTTP {status}."

    return {
        "error": message,
        "http_status": status,
        "tag": tag,
        "request_id": request_id,
        "via": via,
    }


def _error_from_transport(exc, via):
    """Build the KTD5 error object for a connection failure or timeout --
    no HTTP response was ever received, so http_status/tag/request_id stay
    null rather than guessed."""
    return {
        "error": f"Exa request failed: {exc}",
        "http_status": None,
        "tag": None,
        "request_id": None,
        "via": via,
    }


def emit_error(err, as_json):
    """Print the KTD5 error contract and return the exit code (always 1 for
    a provider/transport failure). Under --json the error object is the
    ONLY stdout; otherwise one line on stderr and nothing on stdout."""
    if as_json:
        print(json.dumps(err, sort_keys=True))
    else:
        print(f"exa: {err['error']}", file=sys.stderr)
    return 1


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses every redirect. The default opener resends the x-api-key
    header to whatever host a 3xx names -- resolve_base()'s loopback check
    only inspects the DECLARED base, never a redirect target, so an
    unrefused redirect would leak the key to any host (KTD11 extension).
    Returning None here makes urllib fall through to
    HTTPDefaultErrorHandler, which raises HTTPError so the 3xx renders
    through the normal error contract instead of being followed."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect())


def call_exa(base, path, payload, key, source, timeout, via):
    """The one HTTP POST helper shared by search and contents (KTD3: each
    caller assembles its own body, this only sends it). Returns
    (data, None) on 2xx or (None, error_dict) on any failure -- never
    raises, so callers don't need their own try/except."""
    url = base.rstrip("/") + path
    body = json.dumps(payload, sort_keys=True).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={"x-api-key": key, "Content-Type": "application/json"},
    )
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            status = resp.status
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return None, _error_from_http(exc, source, via)
    except (urllib.error.URLError, OSError) as exc:
        return None, _error_from_transport(exc, via)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        # A 2xx status means no HTTPError was raised -- this is a distinct
        # failure from both _error_from_http (real HTTP error status) and
        # _error_from_transport (no response at all).
        return None, {
            "error": f"Exa returned an unparseable body (HTTP {status}).",
            "http_status": status, "tag": None, "request_id": None, "via": via,
        }
    if not isinstance(data, dict):
        # E.g. a bare array -- valid JSON, but callers (_cost_usd, .get)
        # need an object.
        return None, {
            "error": f"Exa returned a non-object body (HTTP {status}).",
            "http_status": status, "tag": None, "request_id": None, "via": via,
        }
    return data, None


def _cost_usd(data):
    """Exa's costDollars.total, surfaced at the envelope top level (KTD9:
    no client-side spend cap, so this visibility is the whole mechanism).
    null when Exa omits the block entirely."""
    cost = data.get("costDollars")
    if isinstance(cost, dict):
        return cost.get("total")
    return None


def _first_snippet(result):
    """First available text for a one-line human summary: a highlight beats
    full text beats nothing."""
    highlights = result.get("highlights")
    if isinstance(highlights, list) and highlights:
        return highlights[0]
    text = result.get("text")
    if isinstance(text, str) and text:
        return text
    return ""


def _print_search_summary(data):
    results = data.get("results") or []
    if not results:
        print("No results.")
        return
    for i, result in enumerate(results, 1):
        title = result.get("title") or result.get("url") or "(untitled)"
        print(f"{i}. {title}")
        print(f"   {result.get('url', '')}")
        snippet = _first_snippet(result)
        if snippet:
            print(f"   {snippet[:200]}")


def _contents_items(data):
    """Map Exa's statuses[] one-to-one into the envelope's items[] (KTD4).
    tag/http_status are always-present keys, null outside an error, so a
    caller can read item["tag"] uniformly instead of guarding a KeyError."""
    items = []
    for status in data.get("statuses") or []:
        err = status.get("error") or {}
        items.append({
            "id": status.get("id"),
            "status": status.get("status"),
            "cached": status.get("source") == "cached",
            "tag": err.get("tag"),
            "http_status": err.get("httpStatusCode"),
        })
    return items


def _print_contents_summary(items):
    if not items:
        print("No items.")
        return
    for item in items:
        marker = "ok" if item["status"] == "success" else "FAIL"
        cache = "cached" if item["cached"] else "crawled"
        line = f"[{marker}] {item['id']} ({cache})"
        if item["tag"]:
            line += f" -- {item['tag']}"
        print(line)


def _content_spec(args):
    """The content field both verbs send: highlights by default, text with
    --text, either one carrying maxCharacters when --max-chars is given."""
    key = "text" if args.text else "highlights"
    value = {"maxCharacters": args.max_chars} if args.max_chars is not None else True
    return key, value


def cmd_search(args):
    base = resolve_base()
    key, source = credentials()
    via = "exa/search"

    content_key, content_value = _content_spec(args)
    contents = {content_key: content_value}

    payload = {
        "query": args.query,
        "type": args.type,
        "numResults": args.limit,
        "contents": contents,
    }

    data, err = call_exa(base, "/search", payload, key, source, args.timeout, via)
    if err:
        return emit_error(err, args.json)

    if args.json:
        print(json.dumps({"via": via, "cost_usd": _cost_usd(data), "data": data}, sort_keys=True))
    else:
        _print_search_summary(data)
    return 0


def cmd_contents(args):
    base = resolve_base()
    key, source = credentials()
    via = "exa/contents"

    payload = {"ids" if args.ids else "urls": args.targets}
    content_key, content_value = _content_spec(args)
    payload[content_key] = content_value
    if args.max_age_hours is not None:
        payload["maxAgeHours"] = args.max_age_hours

    data, err = call_exa(base, "/contents", payload, key, source, args.timeout, via)
    if err:
        return emit_error(err, args.json)

    items = _contents_items(data)
    ok = any(item["status"] == "success" for item in items)

    if args.json:
        envelope = {"via": via, "cost_usd": _cost_usd(data), "data": data, "items": items}
        print(json.dumps(envelope, sort_keys=True))
    else:
        _print_contents_summary(items)
    return 0 if ok else 3


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.where:
        # Same never-a-traceback contract as the verbs below, but plain text:
        # credential-phase failures are never JSON (there is no --json state
        # to render them into yet).
        try:
            _, source = credentials()
        except SystemExit:
            raise
        except Exception as exc:
            print(f"Exa credentials: unexpected error resolving credential source: {exc}", file=sys.stderr)
            return 1
        print(source)
        return 0

    if not args.cmd:
        parser.error("a subcommand is required: search, contents")

    try:
        if args.cmd == "search":
            return cmd_search(args)
        if args.cmd == "contents":
            return cmd_contents(args)
    except SystemExit:
        raise
    except Exception as exc:  # top-level contract boundary: never a traceback (KTD5)
        via = f"exa/{args.cmd}"
        err = {"error": f"Unexpected error: {exc}", "http_status": None, "tag": None, "request_id": None, "via": via}
        return emit_error(err, args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
