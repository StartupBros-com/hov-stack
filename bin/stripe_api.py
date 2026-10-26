#!/usr/bin/env python3
"""Stripe REST access for the configured accounts.

  stripe-api ACCOUNT METHOD PATH [-d key=value ...] [flags]

ACCOUNT is prbot or startupbros. METHOD is GET, POST or DELETE. PATH starts
with /v1/ or /v2/ and may carry a query string. -d pairs go in the query for
GET, form-encoded in the body for /v1 writes (Stripe's bracket syntax works:
-d 'metadata[k]=v' -d 'expand[]=customer'), and as a flat JSON object for /v2
writes. --json-body FILE (or - for stdin) sends a JSON body to /v2 instead.

Keys resolve env STRIPE_RK_<ACCOUNT>, canonical BWS STRIPE_RK_<ACCOUNT>, then
parsed ~/.secrets. --where lists source metadata without reading a key. Every
POST carries an Idempotency-Key (generated, or --idempotency-key); retries of
one invocation reuse it, and a failure whose outcome is uncertain names it.

Writes are fail-closed. A POST runs without confirmation only when it is a
listed configuration write (webhook endpoints, products, prices, customers
without credit or discount fields, tax and shipping rates, billing portal
and payment method configuration, files, radar lists, entitlement features,
report runs, quotes before acceptance, checkout session expiry, v2 event
destinations). Every other POST, money-moving or simply unlisted, needs
--confirm-money, and every DELETE needs --confirm-delete. Both are refused
before any credential or network access; the flags are invocation guards,
not human approval. Flags must be spelled in full.
"""
from __future__ import annotations

import argparse
import http.client
import json
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
import uuid

VERSION = "0.1.0"
API_BASE = "https://api.stripe.com"
ACCOUNTS = ("prbot", "startupbros")
METHODS = ("GET", "POST", "DELETE")
BWS_TIMEOUT = 30
MAX_BODY = 16 * 1024 * 1024
MAX_RETRIES = 2
KEY_PATTERN = re.compile(r"(?:rk|sk)_(?:live|test)_[A-Za-z0-9]{10,250}\Z")
KEY_SCRUB = re.compile(r"\b(?:rk|sk|pk)_(?:live|test)_[A-Za-z0-9*]+")
PATH_PATTERN = re.compile(r"/v[12]/[A-Za-z0-9_./\-]+\Z")

# Matched against the path without its query string, for POST and DELETE.
# Broad on purpose: a subscription metadata edit asks too, which is cheaper
# than a price change or cancellation slipping through as "config".
MONEY_PATTERNS = tuple(re.compile(p) for p in (
    r"/v1/refunds(/|\Z)",
    r"/v1/payouts(/|\Z)",
    r"/v1/transfers(/|\Z)",
    r"/v1/charges(/|\Z)",
    r"/v1/payment_intents(/|\Z)",
    r"/v1/setup_intents/[^/]+/confirm\Z",
    r"/v1/subscriptions(/|\Z)",
    r"/v1/subscription_items(/|\Z)",
    r"/v1/subscription_schedules(/|\Z)",
    r"/v1/invoices(/|\Z)",
    r"/v1/invoiceitems(/|\Z)",
    r"/v1/credit_notes(/|\Z)",
    r"/v1/coupons(/|\Z)",
    r"/v1/promotion_codes(/|\Z)",
    r"/v1/customers/[^/]+/(balance_transactions|cash_balance|funding_instructions)(/|\Z)",
    r"/v1/customers/[^/]+/discount\Z",
    r"/v1/disputes(/|\Z)",
    r"/v1/topups(/|\Z)",
    r"/v1/application_fees/[^/]+/refunds?(/|\Z)",
    # Legacy nested routes: subscriptions and saved cards or bank accounts.
    r"/v1/customers/[^/]+/(subscriptions|cards|bank_accounts)(/|\Z)",
    r"/v1/issuing(/|\Z)",
    r"/v1/treasury(/|\Z)",
    r"/v1/checkout/sessions\Z",
    r"/v1/payment_links(/|\Z)",
    # Payout destinations and schedules, saved sources, quote acceptance, tax
    # collection, in-person payments, usage billing, purchases, card forwarding.
    r"/v1/accounts?(/|\Z)",
    r"/v1/customers/[^/]+/sources(/|\Z)",
    r"/v1/quotes/[^/]+/accept\Z",
    r"/v1/tax(/|\Z)",
    r"/v1/terminal(/|\Z)",
    r"/v1/billing(/|\Z)",
    r"/v1/climate(/|\Z)",
    r"/v1/forwarding(/|\Z)",
    r"/v1/balance_settings(/|\Z)",
    r"/v2/money_management(/|\Z)",
    r"/v2/billing(/|\Z)",
    r"/v2/payments(/|\Z)",
))
# POST /v1/customers[/<id>] with one of these keys sets credit or a discount.
CUSTOMER_PATH = re.compile(r"/v1/customers(/[^/]+)?\Z")
MONEY_PARAM = re.compile(r"(balance|cash_balance|coupon|promotion_code|discounts)(\[|\Z)")
# The only POSTs that run without --confirm-money, checked after the money
# patterns so /v1/quotes/<id>/accept cannot pass as a quote update. A path
# missing here asks; add it when a consumer needs it.
CONFIG_WRITES = tuple(re.compile(p) for p in (
    r"/v1/webhook_endpoints(/[^/]+)?\Z",
    r"/v1/products(/[^/]+)?\Z",
    r"/v1/products/[^/]+/features\Z",
    r"/v1/prices(/[^/]+)?\Z",
    r"/v1/customers(/[^/]+)?\Z",
    r"/v1/customers/[^/]+/tax_ids\Z",
    r"/v1/tax_rates(/[^/]+)?\Z",
    r"/v1/shipping_rates(/[^/]+)?\Z",
    r"/v1/billing_portal/configurations(/[^/]+)?\Z",
    r"/v1/payment_method_configurations(/[^/]+)?\Z",
    r"/v1/payment_method_domains(/[^/]+(/validate)?)?\Z",
    r"/v1/files\Z",
    r"/v1/file_links(/[^/]+)?\Z",
    r"/v1/radar/value_lists(/[^/]+)?\Z",
    r"/v1/radar/value_list_items\Z",
    r"/v1/entitlements/features(/[^/]+)?\Z",
    r"/v1/reporting/report_runs\Z",
    r"/v1/quotes(/[^/]+)?\Z",
    r"/v1/quotes/[^/]+/(finalize|cancel)\Z",
    r"/v1/checkout/sessions/[^/]+/expire\Z",
    r"/v2/core/event_destinations(/[^/]+(/(enable|disable|ping))?)?\Z",
))


class CliError(Exception):
    def __init__(self, message, code="request_failed", status=None, stripe_error=None, request_id=None):
        super().__init__(scrub(message))
        self.code = code
        self.status = status
        self.stripe_error = stripe_error if isinstance(stripe_error, dict) else {}
        self.request_id = request_id


class Parser(argparse.ArgumentParser):
    # A parse failure is a usage error in the same JSON envelope as every
    # other refusal, not free text on stderr. --help and --version still exit 0.
    def error(self, message):
        raise CliError(f"{message}; see stripe-api --help.", "usage")


def scrub(text):
    return KEY_SCRUB.sub("[redacted-key]", text) if isinstance(text, str) else text


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
        raise argparse.ArgumentTypeError("must be GET, POST or DELETE")
    return upper


def build_parser():
    # allow_abbrev=False: a prefix like --confirm-mo must not stand in for
    # --confirm-money, or it would slip past the permission ask rules.
    parser = Parser(
        prog="stripe-api", description=__doc__.split("\n\n")[0], allow_abbrev=False,
        epilog="Examples: stripe-api prbot GET /v1/subscriptions -d status=active --paginate | "
               "stripe-api startupbros POST /v1/webhook_endpoints/we_123 -d 'enabled_events[]=invoice.paid'",
    )
    parser.add_argument("--version", action="version", version=f"stripe-api {VERSION}")
    parser.add_argument("--where", action="store_true", help="source metadata only; no key reads or network")
    parser.add_argument("account", nargs="?", choices=ACCOUNTS)
    parser.add_argument("method", nargs="?", type=method)
    parser.add_argument("path", nargs="?", help="/v1/... or /v2/..., optionally with ?query")
    parser.add_argument("-d", "--data", action="append", type=pair, default=[], metavar="KEY=VALUE",
                        help="query (GET) or body (POST/DELETE) parameter; repeatable")
    parser.add_argument("--json-body", metavar="FILE", help="JSON object body for /v2 writes; - reads stdin")
    parser.add_argument("--idempotency-key", help="reuse this key (default: generated per invocation)")
    parser.add_argument("--stripe-version", help="Stripe-Version header (required by most /v2 endpoints)")
    parser.add_argument("--paginate", action="store_true", help="GET only: follow has_more across pages")
    parser.add_argument("--max-pages", type=bounded_int(1, 100), default=20, help="page cap for --paginate (default 20)")
    parser.add_argument("--confirm-money", action="store_true", help="confirm a money-moving write after human approval")
    parser.add_argument("--confirm-delete", action="store_true", help="confirm a DELETE after human approval")
    parser.add_argument("--timeout", type=bounded_int(1, 120), default=30, help="per-request timeout in seconds (default 30)")
    parser.add_argument("--json", action="store_true", help="JSON output (the default)")
    return parser


def env_name(account):
    return "STRIPE_RK_" + account.upper()


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
    """Presence information only, not a claim that these keys work."""
    home = Path.home()
    bws = {
        "binary_present": shutil.which("bws") is not None,
        "access_token_configured": bool(os.environ.get("BWS_ACCESS_TOKEN")) or (home / ".config/bws/token").is_file(),
        "project_configured": bool(os.environ.get("BWS_PROJECT_ID")) or (home / ".config/bws/sb-project-id").is_file(),
    }
    return {
        "resolved": False,
        "accounts": {
            account: {
                "env:" + env_name(account): bool(os.environ.get(env_name(account))),
                "bws:" + env_name(account): bws,
                "~/.secrets": (home / ".secrets").is_file(),
            } for account in ACCOUNTS
        },
    }


def _validate_key(value):
    if not isinstance(value, str) or not KEY_PATTERN.fullmatch(value):
        raise CliError("Stripe key has an invalid format (expected rk_/sk_ live or test).", "credential_invalid")
    return value


def _bws_key(name):
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
    # One retry: a transient bws failure (rate limit, network) must not read as
    # a missing key, whose fix (re-seeding) would overwrite a live value.
    for attempt in range(2):
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
        if not result.returncode:
            break
        if not attempt:
            time.sleep(2)
    if result.returncode or len(result.stdout) > 1024 * 1024:
        return None, "bws_unavailable"
    try:
        entries = json.loads(result.stdout)
    except (ValueError, TypeError):
        return None, "bws_unavailable"
    if not isinstance(entries, list):
        return None, "bws_unavailable"
    for item in entries:
        if isinstance(item, dict) and item.get("key") == name and item.get("value"):
            return _validate_key(item["value"]), None
    return None, None


def _secrets_key(name):
    body = _read(Path.home() / ".secrets", 1024 * 1024)
    if body is None:
        return None
    for line in body.splitlines():
        match = re.match(r"^\s*(?:export\s+)?([A-Z0-9_]+)\s*=(.*)$", line)
        if not match or match[1] != name:
            continue
        try:
            values = shlex.split(match[2], comments=True, posix=True)
        except ValueError:
            continue
        if len(values) == 1 and KEY_PATTERN.fullmatch(values[0]):
            return values[0]
    return None


def credentials(account):
    name = env_name(account)
    value = os.environ.get(name)
    if value:
        return _validate_key(value), "env:" + name
    value, failure = _bws_key(name)
    if value:
        return value, "bws:" + name
    value = _secrets_key(name)
    if value:
        return value, "~/.secrets"
    if failure == "bws_timeout":
        raise CliError(f"BWS did not respond within {BWS_TIMEOUT} seconds and no local {name} was found.", "credential_timeout")
    if failure == "bws_unavailable":
        raise CliError(f"BWS could not be read (bws failed twice or returned unreadable output) and no local {name} "
                       "was found. Retry later or check bws access; do not re-seed the key, which may still exist.",
                       "credential_unavailable")
    raise CliError(f"No Stripe key for {account}: checked env {name}, BWS {name}, and ~/.secrets. "
                   "Seed it with your secrets helper: secrets.sh seed " + name + ".", "credential_missing")


def gated_write(method_name, bare_path, keys=()):
    """Why a write needs --confirm-money: "money", "unlisted", or None."""
    if method_name not in {"POST", "DELETE"}:
        return None
    if any(p.match(bare_path) for p in MONEY_PATTERNS):
        return "money"
    # A customer write is configuration unless it sets credit or a discount.
    if CUSTOMER_PATH.match(bare_path) and any(MONEY_PARAM.match(key) for key in keys):
        return "money"
    # A DELETE is gated by --confirm-delete; only POST falls back to the list.
    if method_name == "POST" and not any(p.match(bare_path) for p in CONFIG_WRITES):
        return "unlisted"
    return None


def _json_body(source):
    if source == "-":
        try:
            raw = sys.stdin.buffer.read(MAX_BODY + 1)
            text = raw.decode("utf-8") if len(raw) <= MAX_BODY else None
        except (OSError, UnicodeError):
            text = None
    else:
        text = _read(source, MAX_BODY)
    try:
        value = json.loads(text) if text is not None else None
    except ValueError:
        value = None
    if not isinstance(value, dict):
        raise CliError("--json-body must name a readable file (or -) holding one JSON object.", "usage")
    return value


def plan(args):
    """Validate the whole request before any credential read or network call."""
    if not (args.account and args.method and args.path):
        raise CliError("Usage: stripe-api ACCOUNT METHOD PATH [-d key=value ...]; see --help.", "usage")
    raw_path, _, raw_query = args.path.partition("?")
    if not PATH_PATTERN.fullmatch(raw_path) or "//" in raw_path or "/../" in raw_path + "/" or "/./" in raw_path + "/":
        raise CliError("PATH must be an API path like /v1/customers or /v2/core/events, not a URL.", "usage")
    version = raw_path[1:3]
    query = urllib.parse.parse_qsl(raw_query, keep_blank_values=True)
    if args.paginate and args.method != "GET":
        raise CliError("--paginate only applies to GET.", "usage")
    if args.json_body and (version != "v2" or args.method == "GET"):
        raise CliError("--json-body only applies to /v2 POST or DELETE.", "usage")
    if args.json_body and args.data:
        raise CliError("Use -d pairs or --json-body, not both.", "usage")
    if args.method == "DELETE" and not args.confirm_delete:
        raise CliError("DELETE requires human approval and --confirm-delete on this invocation.", "confirmation_required")
    keys = [key for key, _ in args.data + query]
    reason = gated_write(args.method, raw_path, keys)
    if reason and not args.confirm_money:
        if reason == "money":
            raise CliError(f"{args.method} {raw_path} moves money or changes billing; it requires human approval "
                           "and --confirm-money on this invocation.", "confirmation_required")
        raise CliError(f"POST {raw_path} is not a known configuration write; it requires human approval and "
                       "--confirm-money, the gated-write confirmation, on this invocation.", "confirmation_required")
    body = None
    content_type = None
    if args.method == "GET":
        query += args.data
    elif version == "v2":
        payload = _json_body(args.json_body) if args.json_body else dict(args.data)
        if payload or args.method == "POST":
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            content_type = "application/json"
    elif args.data or args.method == "POST":
        # An empty POST still sends Content-Length: 0 (e.g. /v1/invoices/<id>/pay).
        body = urllib.parse.urlencode(args.data).encode("ascii")
        content_type = "application/x-www-form-urlencoded"
    idem = None
    if args.method == "POST":
        idem = args.idempotency_key or str(uuid.uuid4())
    return {"path": raw_path, "query": query, "body": body, "content_type": content_type, "idempotency_key": idem}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _body(response):
    raw = response.read(MAX_BODY + 1)
    if len(raw) > MAX_BODY:
        raise CliError("Stripe response exceeded the 16 MiB limit.", "response_too_large")
    try:
        return json.loads(raw.decode("utf-8")) if raw else None
    except (ValueError, UnicodeError):
        raise CliError("Stripe returned invalid JSON.", "response_invalid") from None


def _header(response, name):
    headers = getattr(response, "headers", None)
    return headers.get(name) if headers is not None else None


def _provider_error(status, body, request_id):
    error = body.get("error") if isinstance(body, dict) else None
    message = error.get("message") if isinstance(error, dict) else None
    if not isinstance(message, str) or not message:
        message = {
            401: "Stripe rejected the key.",
            403: "The restricted key lacks permission for this endpoint.",
            404: "Stripe could not find the requested resource.",
            429: "Stripe rate limit exceeded; retry later.",
        }.get(status, "Stripe refused the request.")
        if status >= 500:
            message = "Stripe returned a server error."
    if status == 403:
        message += " Grant the resource on the restricted key in the Stripe dashboard, or use another account."
    return CliError(message, "http_error", status, error, request_id)


def _retryable(status, should_retry):
    if should_retry == "false":
        return False
    return should_retry == "true" or status == 429 or status >= 500


def request(method_name, path, query, body, content_type, idem, key, timeout, stripe_version=None):
    url = API_BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    headers = {
        "Authorization": "Bearer " + key,
        "User-Agent": f"stripe-api/{VERSION} (StartupBros-com/hov-stack)",
        "Accept": "application/json",
    }
    if content_type:
        headers["Content-Type"] = content_type
    if idem:
        headers["Idempotency-Key"] = idem
    if stripe_version:
        headers["Stripe-Version"] = stripe_version
    last = None
    for attempt in range(MAX_RETRIES + 1):
        if attempt:
            time.sleep(0.5 * 2 ** (attempt - 1))
        req = urllib.request.Request(url, data=body, method=method_name, headers=headers)
        try:
            with opener.open(req, timeout=timeout) as response:
                status = response.getcode()
                request_id = _header(response, "Request-Id")
                if not 200 <= status < 300:
                    raise _provider_error(status, None, request_id)
                return _body(response), request_id
        except urllib.error.HTTPError as exc:
            request_id = _header(exc, "Request-Id")
            should_retry = (_header(exc, "Stripe-Should-Retry") or "").lower()
            try:
                body_json = _body(exc)
            except (CliError, OSError, ValueError, http.client.HTTPException):
                body_json = None
            finally:
                exc.close()
            last = _provider_error(exc.code, body_json, request_id)
            if 300 <= exc.code < 400:
                last = CliError("Stripe returned a redirect; refusing to follow it with credentials.", "http_error", exc.code, None, request_id)
                break
            if not _retryable(exc.code, should_retry):
                break
        except CliError as exc:
            last = exc
            break
        except (TimeoutError, urllib.error.URLError, OSError, http.client.HTTPException):
            # HTTPException covers IncompleteRead: a body cut off after Stripe
            # may have applied the write is an uncertain outcome too.
            last = CliError("Stripe connection failed or timed out.", "transport_error")
            if method_name == "DELETE":
                break
    uncertain = last.code in {"transport_error", "response_invalid", "response_too_large"} or (last.status or 0) >= 500
    if method_name != "GET" and uncertain:
        hint = f" Re-run with --idempotency-key {idem} to retry safely." if idem else ""
        raise CliError(f"{last} Stripe may already have applied this {method_name}; read the resource before retrying.{hint}",
                       last.code, last.status, last.stripe_error, last.request_id)
    raise last


def paginate(first, fetch, max_pages):
    items = list(first.get("data") or [])
    pages = 1
    current = first
    # Tracked per page: a later page with no body ends the loop with
    # has_more still true, which the caller reports as truncation.
    has_more = bool(first.get("has_more"))
    while has_more and pages < max_pages:
        if current.get("object") == "search_result":
            token = current.get("next_page")
            if not token:
                break
            current = fetch({"page": token})
        else:
            last_id = items[-1].get("id") if items and isinstance(items[-1], dict) else None
            if not last_id:
                break
            current = fetch({"starting_after": last_id})
        if not isinstance(current, dict):
            break
        items.extend(current.get("data") or [])
        has_more = bool(current.get("has_more"))
        pages += 1
    merged = {**first, "data": items, "has_more": has_more, "pages": pages}
    merged.pop("next_page", None)
    return merged


def run(args):
    spec = plan(args)
    key, source = credentials(args.account)

    def fetch(extra):
        query = [(k, v) for k, v in spec["query"] if k not in extra] + list(extra.items())
        return request(args.method, spec["path"], query, spec["body"], spec["content_type"],
                       spec["idempotency_key"], key, args.timeout, args.stripe_version)

    data, request_id = fetch({})
    if args.paginate and isinstance(data, dict) and data.get("object") in {"list", "search_result"}:
        data = paginate(data, lambda extra: fetch(extra)[0], args.max_pages)
        if data.get("has_more"):
            print(f"Warning: stopped after {data['pages']} pages with more results; raise --max-pages (max 100) "
                  "or narrow the query.", file=sys.stderr)
    return {
        "ok": True, "via": "stripe/" + args.account, "method": args.method, "path": spec["path"],
        "credential_source": source, "request_id": request_id,
        "idempotency_key": spec["idempotency_key"], "data": data,
    }


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        if args.where:
            print(json.dumps(source_metadata(), sort_keys=True))
            return 0
        print(json.dumps(run(args), ensure_ascii=False))
        return 0
    except CliError as exc:
        error = exc.stripe_error
        print(json.dumps({"ok": False, "error": {
            "code": exc.code, "message": str(exc), "http_status": exc.status,
            "stripe_type": scrub(error.get("type")), "stripe_code": scrub(error.get("code")),
            "param": scrub(error.get("param")), "doc_url": error.get("doc_url"), "request_id": exc.request_id,
        }}))
        return 2 if exc.code in {"usage", "confirmation_required"} else 1
    except Exception:
        # Never include exception text: a transport message can carry the key.
        print(json.dumps({"ok": False, "error": {"code": "internal_error", "message": "stripe-api failed unexpectedly.",
                                                 "http_status": None, "stripe_type": None, "stripe_code": None,
                                                 "param": None, "doc_url": None, "request_id": None}}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
