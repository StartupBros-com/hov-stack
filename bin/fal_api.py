#!/usr/bin/env python3
"""fal.ai model runs, uploads and Platform API access for agents.

  fal-api run ENDPOINT [--input FILE|-] [-d key=value ...] [--wait SECONDS]
  fal-api submit ENDPOINT [--input FILE|-] [-d key=value ...]
  fal-api status ENDPOINT REQUEST_ID [--logs]
  fal-api result ENDPOINT REQUEST_ID
  fal-api cancel ENDPOINT REQUEST_ID
  fal-api upload FILE [--content-type TYPE]
  fal-api api METHOD /v1/PATH [-d key=value ...] [--body FILE|-] [--paginate]

ENDPOINT is a model id such as fal-ai/flux/schnell. run submits to the queue,
polls until the request completes or --wait runs out (default 600 s, at most
1500 s, under the Bash tool's 30-minute ceiling), then prints the result; a
longer job is submit, then status and result. --input is a JSON object (- reads
stdin); -d sets string fields on top of it. upload returns a fal CDN URL to pass
as a model input. api reaches https://api.fal.ai/v1 (models, pricing, usage,
requests, keys, ...): GET pairs go in the query, write pairs in a flat JSON body.

The key resolves env FAL_KEY, the BWS record FAL_KEY, then ~/.secrets; --where
lists source metadata without reading it. It is sent only to queue.fal.run,
api.fal.ai and rest.fal.ai, never through a redirect, and queue URLs are built
from the endpoint's owner/app and a checked request id, never taken from a
response. Model runs and uploads spend credits without confirmation. Under api,
GET and POST /v1/models/pricing/estimate run as-is; every other write (keys,
compute, secrets, apps) needs --confirm-destructive, refused before any key
read; the flag is an invocation guard, not human approval. fal_webhook is
refused: it would send output to an arbitrary URL.

Exit 0 on success, 1 when fal or the credential chain refused (read
error.code), 2 for invalid input or a missing confirmation.
"""
from __future__ import annotations

import argparse
import http.client
import json
import mimetypes
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

VERSION = "0.1.0"
QUEUE_HOST = "queue.fal.run"
PLATFORM_HOST = "api.fal.ai"
REST_HOST = "rest.fal.ai"
CDN_HOST = "v3.fal.media"
# The only hosts that ever see the key. The CDN gets a short-lived upload
# token minted by rest.fal.ai, never the key.
KEY_HOSTS = frozenset({QUEUE_HOST, PLATFORM_HOST, REST_HOST})
ENV_NAME = "FAL_KEY"
BWS_TIMEOUT = 30
MAX_BODY = 32 * 1024 * 1024
MAX_RETRIES = 2
CDN_MAX = 100 * 1024 * 1024
MAX_UPLOAD = 4 * 1024 * 1024 * 1024
WAIT_MAX = 1500
# key_id:key_secret. Older keys are uuid:hex; keys minted in 2026 read
# xxx_xx_<32 alnum>:<32 alnum> (shape from a value-free probe of the dashboard).
_KEY_BODY = (r"(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
             r"|[A-Za-z0-9]{2,8}_[A-Za-z0-9]{1,8}_[A-Za-z0-9]{16,64}):[A-Za-z0-9]{16,128}")
KEY_PATTERN = re.compile(_KEY_BODY + r"\Z")
KEY_SCRUB = re.compile(_KEY_BODY)
# Segments start alphanumeric, so "." and ".." cannot pass; no query string,
# so fal_webhook cannot ride along.
ENDPOINT_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*(?:/[A-Za-z0-9][A-Za-z0-9_.-]*)+\Z")
REQUEST_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
API_PATH = re.compile(r"/v1/[A-Za-z0-9_.\-/]+\Z")
METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE")
# Writes that run without --confirm-destructive. A path missing here asks;
# add it when a consumer needs it.
READ_WRITES = (
    ("POST", re.compile(r"/v1/models/pricing/estimate\Z")),
)
BILLING_WORDS = re.compile(r"balance|locked|billing|credit|top.?up|payment|insufficient", re.I)

_sent_secrets: set[str] = set()


class CliError(Exception):
    def __init__(self, message, code="request_failed", status=None, detail=None, request_id=None):
        super().__init__(message)
        self.code = code
        self.status = status
        self.detail = detail
        self.request_id = request_id


class Parser(argparse.ArgumentParser):
    # A parse failure is a usage error in the same JSON envelope as every
    # other refusal, not free text on stderr. --help and --version still exit 0.
    def error(self, message):
        raise CliError(f"{message}; see fal-api --help.", "usage")


def scrub(text):
    if not isinstance(text, str):
        return text
    for secret in _sent_secrets:
        text = text.replace(secret, "[redacted-key]")
    return KEY_SCRUB.sub("[redacted-key]", text)


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
    # allow_abbrev=False everywhere: a prefix like --confirm-destr must not
    # stand in for --confirm-destructive, or it would slip past the ask rule.
    parser = Parser(
        prog="fal-api", description=__doc__.split("\n\n")[0], allow_abbrev=False,
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1],
    )
    parser.add_argument("--version", action="version", version=f"fal-api {VERSION}")
    parser.add_argument("--where", action="store_true", help="credential source metadata only; no key read or network")
    verbs = parser.add_subparsers(dest="verb", metavar="VERB")

    def verb(name, help_text):
        sub = verbs.add_parser(name, help=help_text, allow_abbrev=False)
        sub.add_argument("--timeout", type=bounded_int(1, 600), default=60,
                         help="per-request timeout in seconds (default 60)")
        sub.add_argument("--json", action="store_true", help="JSON output (the default)")
        return sub

    for name, help_text in (("run", "submit to the queue and wait for the result"),
                            ("submit", "submit to the queue and print the request id")):
        sub = verb(name, help_text)
        sub.add_argument("endpoint", help="model id, e.g. fal-ai/flux/schnell")
        sub.add_argument("--input", metavar="FILE", help="JSON object input; - reads stdin")
        sub.add_argument("-d", "--data", action="append", type=pair, default=[], metavar="KEY=VALUE",
                         help="string input field; repeatable, applied over --input")
        if name == "run":
            sub.add_argument("--wait", type=bounded_int(1, WAIT_MAX), default=600,
                             help=f"seconds to wait for completion (default 600, max {WAIT_MAX})")
            sub.add_argument("--poll", type=bounded_int(1, 60), default=5, help="seconds between status checks (default 5)")
            sub.add_argument("--logs", action="store_true", help="include the runner's logs")
    for name, help_text in (("status", "queue status of a request"), ("result", "result of a completed request"),
                            ("cancel", "cancel a queued or running request")):
        sub = verb(name, help_text)
        sub.add_argument("endpoint")
        sub.add_argument("request_id")
        if name == "status":
            sub.add_argument("--logs", action="store_true", help="include the runner's logs")
    sub = verb("upload", "upload a file to fal storage and print its URL")
    sub.add_argument("file")
    sub.add_argument("--content-type", help="default: guessed from the file name")
    sub = verb("api", "Platform API request under https://api.fal.ai/v1")
    sub.add_argument("method", type=method)
    sub.add_argument("path", help="/v1/... optionally with ?query")
    sub.add_argument("-d", "--data", action="append", type=pair, default=[], metavar="KEY=VALUE",
                     help="query (GET) or flat JSON body field (writes); repeatable")
    sub.add_argument("--body", metavar="FILE", help="JSON body for a write; - reads stdin")
    sub.add_argument("--paginate", action="store_true", help="GET only: follow next_cursor while has_more")
    sub.add_argument("--max-pages", type=bounded_int(1, 100), default=20, help="page cap for --paginate (default 20)")
    sub.add_argument("--confirm-destructive", action="store_true",
                     help="confirm a write outside the read-only list after human approval")
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
    """Presence information only, not a claim that the key works."""
    home = Path.home()
    return {
        "resolved": False,
        "sources": {
            "env:" + ENV_NAME: bool(os.environ.get(ENV_NAME)),
            "bws:" + ENV_NAME: {
                "binary_present": shutil.which("bws") is not None,
                "access_token_configured": bool(os.environ.get("BWS_ACCESS_TOKEN")) or (home / ".config/bws/token").is_file(),
                "project_configured": bool(os.environ.get("BWS_PROJECT_ID")) or (home / ".config/bws/sb-project-id").is_file(),
            },
            "~/.secrets": (home / ".secrets").is_file(),
        },
        "key_hosts": sorted(KEY_HOSTS),
    }


def _validate_key(value):
    value = value.strip() if isinstance(value, str) else value
    if not isinstance(value, str) or not KEY_PATTERN.fullmatch(value):
        raise CliError("FAL_KEY has an invalid format (expected key_id:key_secret).", "credential_invalid")
    return value


def _bws_key():
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
    # One retry: a transient bws failure must not read as a missing key, whose
    # fix (re-seeding) would replace a live value.
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
    if result.returncode or len(result.stdout) > 4 * 1024 * 1024:
        return None, "bws_unavailable"
    try:
        entries = json.loads(result.stdout)
    except (ValueError, TypeError):
        return None, "bws_unavailable"
    if not isinstance(entries, list):
        return None, "bws_unavailable"
    for item in entries:
        if isinstance(item, dict) and item.get("key") == ENV_NAME and item.get("value"):
            return _validate_key(item["value"]), None
    return None, None


def _secrets_key():
    body = _read(Path.home() / ".secrets", 1024 * 1024)
    if body is None:
        return None
    for line in body.splitlines():
        match = re.match(r"^\s*(?:export\s+)?([A-Z0-9_]+)\s*=(.*)$", line)
        if not match or match[1] != ENV_NAME:
            continue
        try:
            values = shlex.split(match[2], comments=True, posix=True)
        except ValueError:
            continue
        if len(values) == 1 and KEY_PATTERN.fullmatch(values[0]):
            return values[0]
    return None


def credentials():
    value = os.environ.get(ENV_NAME)
    if value:
        value, source = _validate_key(value), "env:" + ENV_NAME
    else:
        value, failure = _bws_key()
        source = "bws:" + ENV_NAME
        if not value:
            value, source = _secrets_key(), "~/.secrets"
        if not value:
            if failure == "bws_timeout":
                raise CliError(f"BWS did not respond within {BWS_TIMEOUT} seconds and no local {ENV_NAME} was found.",
                               "credential_timeout")
            if failure == "bws_unavailable":
                raise CliError(f"BWS could not be read (bws failed twice or returned unreadable output) and no local "
                               f"{ENV_NAME} was found. Retry later or check bws access; do not re-seed the key, which "
                               "may still exist.", "credential_unavailable")
            raise CliError(f"No fal key: checked env {ENV_NAME}, BWS {ENV_NAME}, and ~/.secrets. Mint one at "
                           "fal.ai/dashboard/keys and seed it with your secrets helper: secrets.sh seed FAL_KEY.",
                           "credential_missing")
    _sent_secrets.add(value)
    return value, source


def _json_object(source, flag):
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
        raise CliError(f"{flag} must name a readable file (or -) holding one JSON object.", "usage")
    return value


def check_endpoint(endpoint):
    if "fal_webhook" in endpoint:
        raise CliError("fal_webhook is refused: it would send the output to an arbitrary URL. Poll with "
                       "fal-api status instead.", "usage")
    if not ENDPOINT_PATTERN.fullmatch(endpoint):
        raise CliError("ENDPOINT must be a model id like fal-ai/flux/schnell (owner/app[/path]), not a URL.", "usage")
    return endpoint


def check_request_id(request_id):
    if not REQUEST_ID.fullmatch(request_id):
        raise CliError("REQUEST_ID must be the uuid fal-api submit printed.", "usage")
    return request_id


def queue_url(endpoint, request_id=None, tail=""):
    """Submit goes to the full endpoint id; status, result and cancel to its owner/app only.

    fal answers 405 for a request path under a deeper id (probed 2026-10-23:
    fal-ai/kling-video/requests/<id>/status 404, .../o3/pro/video-to-video/edit/requests/<id>/status 405).
    """
    if request_id is None:
        return f"https://{QUEUE_HOST}/{endpoint}"
    app = "/".join(endpoint.split("/")[:2])
    return f"https://{QUEUE_HOST}/{app}/requests/{request_id}{tail}"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _body(response, expect_json=True):
    raw = response.read(MAX_BODY + 1)
    if len(raw) > MAX_BODY:
        raise CliError("fal response exceeded the 32 MiB limit.", "response_too_large")
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError):
        if not expect_json:
            return None
        raise CliError("fal returned invalid JSON.", "response_invalid") from None


def _header(response, name):
    headers = getattr(response, "headers", None)
    return headers.get(name) if headers is not None else None


def _message(body):
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict) and isinstance(error.get("message"), str):
            return error["message"], error.get("type")
        detail = body.get("detail")
        if isinstance(detail, str):
            return detail, None
        if isinstance(detail, list):
            parts = [d.get("msg") if isinstance(d, dict) else str(d) for d in detail]
            return "; ".join(p for p in parts if p), "validation_error"
        if isinstance(body.get("status"), str):
            return body["status"], None
    return None, None


def provider_error(status, body, request_id=None):
    message, kind = _message(body)
    code = {401: "auth_failed", 404: "not_found", 405: "wrong_path", 422: "invalid_input",
            400: "invalid_input", 429: "rate_limited"}.get(status, "http_error")
    if status in {402, 403}:
        code = "billing" if status == 402 or (message and BILLING_WORDS.search(message)) else "forbidden"
    if status >= 500:
        code = "server_error"
    if not message:
        message = {401: "fal rejected the key.", 403: "fal refused the request for this key.",
                   404: "fal could not find the endpoint or request.", 429: "fal rate limit exceeded; retry later."
                   }.get(status, f"fal returned HTTP {status}.")
    if code == "billing":
        message += " Top up at fal.ai/dashboard/billing; retrying will not help."
    elif code == "wrong_path":
        message += " Status, result and cancel take the request's own endpoint id; fal-api builds their path from its owner/app."
    return CliError(message, code, status, {"type": kind} if kind else None, request_id)


def request(method_name, url, *, key=None, token=None, body=None, content_type=None, headers=None,
            timeout=60, idempotent=True, expect_json=True):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        raise CliError("Refusing a non-https URL.", "host_refused")
    if key is not None and parts.hostname not in KEY_HOSTS:
        raise CliError(f"Refusing to send the fal key to {parts.hostname}.", "host_refused")
    if token is not None and parts.hostname != CDN_HOST:
        raise CliError(f"Refusing to send the upload token to {parts.hostname}.", "host_refused")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    sent = {"User-Agent": f"fal-api/{VERSION} (StartupBros-com/hov-stack)", "Accept": "application/json", **(headers or {})}
    if key is not None:
        sent["Authorization"] = "Key " + key
    if token is not None:
        sent["Authorization"] = token
    if content_type:
        sent["Content-Type"] = content_type
    last = None
    for attempt in range(MAX_RETRIES + 1):
        if attempt:
            time.sleep(0.5 * 2 ** (attempt - 1))
        if hasattr(body, "seek"):
            body.seek(0)
        req = urllib.request.Request(url, data=body, method=method_name, headers=sent)
        try:
            with opener.open(req, timeout=timeout) as response:
                status = response.getcode()
                request_id = _header(response, "x-fal-request-id")
                if not 200 <= status < 300:
                    raise provider_error(status, None, request_id)
                return status, _body(response, expect_json)
        except urllib.error.HTTPError as exc:
            request_id = _header(exc, "x-fal-request-id")
            try:
                body_json = _body(exc, expect_json=False)
            except (CliError, OSError, ValueError, http.client.HTTPException):
                body_json = None
            finally:
                exc.close()
            if 300 <= exc.code < 400:
                last = CliError("fal returned a redirect; refusing to follow it with credentials.", "redirect_refused",
                                exc.code, None, request_id)
                break
            last = provider_error(exc.code, body_json, request_id)
            last.body = body_json
            # A 429 was refused before anything ran, so even a submit may repeat it.
            if not (exc.code == 429 or (idempotent and exc.code >= 500)):
                break
        except CliError as exc:
            last = exc
            break
        except (TimeoutError, urllib.error.URLError, OSError, http.client.HTTPException):
            last = CliError("fal connection failed or timed out.", "transport_error")
            if not idempotent:
                break
    if not idempotent and (last.code in {"transport_error", "response_invalid"} or (last.status or 0) >= 500):
        raise CliError(f"{last} fal may already have accepted this {method_name}; check fal.ai/dashboard/requests "
                       "before repeating it.", last.code, last.status, last.detail, last.request_id)
    raise last


def _input(args):
    payload = _json_object(args.input, "--input") if args.input else {}
    payload.update(dict(args.data))
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


def submit(endpoint, body, key, timeout):
    _, data = request("POST", queue_url(endpoint), key=key, body=body, content_type="application/json",
                      timeout=timeout, idempotent=False)
    request_id = data.get("request_id") if isinstance(data, dict) else None
    if not isinstance(request_id, str) or not REQUEST_ID.fullmatch(request_id):
        raise CliError("fal accepted the submit but returned no request id; check fal.ai/dashboard/requests.",
                       "response_invalid")
    return request_id, data


def status(endpoint, request_id, key, timeout, logs=False):
    url = queue_url(endpoint, request_id, "/status") + ("?logs=1" if logs else "")
    return request("GET", url, key=key, timeout=timeout)[1]


def result(endpoint, request_id, key, timeout):
    return request("GET", queue_url(endpoint, request_id), key=key, timeout=timeout)[1]


def next_steps(endpoint, request_id):
    return {"status": f"fal-api status {endpoint} {request_id}", "result": f"fal-api result {endpoint} {request_id}",
            "cancel": f"fal-api cancel {endpoint} {request_id}"}


def run_verb(args, body, key, source):
    endpoint = args.endpoint
    request_id, _ = submit(endpoint, body, key, args.timeout)
    deadline = time.monotonic() + args.wait
    state = {}
    while True:
        state = status(endpoint, request_id, key, args.timeout, args.logs) or {}
        if state.get("status") == "COMPLETED":
            break
        if time.monotonic() + args.poll > deadline:
            raise CliError(f"Request is still {state.get('status', 'pending')} after {args.wait} s; it keeps running "
                           f"and spending. Continue with: fal-api status {endpoint} {request_id}, then "
                           f"fal-api result {endpoint} {request_id}.", "timeout", None, None, request_id)
        time.sleep(args.poll)
    if state.get("error"):
        raise CliError(f"The model reported an error: {state.get('error')}", "model_failed", None,
                       {"type": state.get("error_type")}, request_id)
    data = result(endpoint, request_id, key, args.timeout)
    out = {"ok": True, "via": "fal", "verb": "run", "endpoint": endpoint, "request_id": request_id,
           "credential_source": source, "inference_time": (state.get("metrics") or {}).get("inference_time"),
           "data": data}
    if args.logs:
        out["logs"] = state.get("logs")
    return out


def cancel(endpoint, request_id, key, timeout):
    try:
        return request("PUT", queue_url(endpoint, request_id, "/cancel"), key=key, timeout=timeout)[1]
    except CliError as exc:
        body = getattr(exc, "body", None)
        if exc.status == 400 and isinstance(body, dict) and body.get("status") == "ALREADY_COMPLETED":
            return body
        raise


def upload(path, content_type, key, timeout):
    file = Path(path)
    try:
        size = file.stat().st_size
    except OSError:
        raise CliError(f"Cannot read {path}.", "usage") from None
    if not file.is_file() or size > MAX_UPLOAD:
        raise CliError(f"{path} must be a regular file of at most {MAX_UPLOAD // 1024 ** 3} GiB.", "usage")
    content_type = content_type or mimetypes.guess_type(file.name)[0] or "application/octet-stream"
    if size <= CDN_MAX:
        # fal_client's single-shot path: a CDN token from rest.fal.ai, then one POST to the CDN.
        _, grant = request("POST", f"https://{REST_HOST}/storage/auth/token?storage_type=fal-cdn-v3", key=key,
                           body=b"{}", content_type="application/json", timeout=timeout)
        if not isinstance(grant, dict) or not grant.get("token") or not grant.get("token_type"):
            raise CliError("fal returned no upload token.", "response_invalid")
        token = f"{grant['token_type']} {grant['token']}"
        _sent_secrets.add(grant["token"])
        _, data = request("POST", f"https://{CDN_HOST}/files/upload", token=token, body=file.read_bytes(),
                          content_type=content_type, headers={"X-Fal-File-Name": file.name},
                          timeout=max(timeout, 300))
        url = data.get("access_url") if isinstance(data, dict) else None
    else:
        # Larger files: a signed upload URL from rest.fal.ai, then a PUT that carries no credential.
        _, grant = request("POST", f"https://{REST_HOST}/storage/upload/initiate?storage_type=gcs", key=key,
                           body=json.dumps({"file_name": file.name, "content_type": content_type}).encode(),
                           content_type="application/json", timeout=timeout)
        signed = grant.get("upload_url") if isinstance(grant, dict) else None
        url = grant.get("file_url") if isinstance(grant, dict) else None
        if not isinstance(signed, str) or not isinstance(url, str):
            raise CliError("fal returned no upload URL.", "response_invalid")
        with file.open("rb") as handle:
            request("PUT", signed, body=handle, content_type=content_type,
                    headers={"Content-Length": str(size)}, timeout=max(timeout, 1800), expect_json=False)
    if not isinstance(url, str) or not url.startswith("https://"):
        raise CliError("fal returned no file URL.", "response_invalid")
    return {"url": url, "bytes": size, "content_type": content_type}


def plan_api(args):
    """Validate an api request before any credential read or network call."""
    raw_path, _, raw_query = args.path.partition("?")
    if not API_PATH.fullmatch(raw_path) or "//" in raw_path or "/../" in raw_path + "/" or "/./" in raw_path + "/":
        raise CliError("PATH must be a Platform API path like /v1/models, not a URL.", "usage")
    query = urllib.parse.parse_qsl(raw_query, keep_blank_values=True)
    if args.paginate and args.method != "GET":
        raise CliError("--paginate only applies to GET.", "usage")
    if args.body and args.method == "GET":
        raise CliError("--body only applies to a write.", "usage")
    if args.body and args.data:
        raise CliError("Use -d pairs or --body, not both.", "usage")
    listed = any(m == args.method and p.fullmatch(raw_path) for m, p in READ_WRITES)
    if args.method != "GET" and not listed and not args.confirm_destructive:
        raise CliError(f"{args.method} {raw_path} changes the fal account (keys, compute, secrets, apps or other "
                       "state); it requires human approval and --confirm-destructive on this invocation.",
                       "confirmation_required")
    body = None
    if args.method == "GET":
        query += args.data
    elif args.body or args.data or args.method in {"POST", "PUT", "PATCH"}:
        payload = _json_object(args.body, "--body") if args.body else dict(args.data)
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return raw_path, query, body


def api_verb(args, raw_path, query, body, key):
    def fetch(extra):
        merged = [(k, v) for k, v in query if k not in extra] + list(extra.items())
        url = f"https://{PLATFORM_HOST}{raw_path}" + ("?" + urllib.parse.urlencode(merged) if merged else "")
        return request(args.method, url, key=key, body=body,
                       content_type="application/json" if body is not None else None,
                       timeout=args.timeout, idempotent=args.method in {"GET", "PUT", "DELETE"})[1]

    data = fetch({})
    pages = 1
    if args.paginate and isinstance(data, dict):
        lists = [k for k, v in data.items() if isinstance(v, list)]
        while len(lists) == 1 and data.get("has_more") and data.get("next_cursor") and pages < args.max_pages:
            page = fetch({"cursor": data["next_cursor"]})
            if not isinstance(page, dict):
                break
            data = {**page, lists[0]: data[lists[0]] + list(page.get(lists[0]) or [])}
            pages += 1
        if data.get("has_more"):
            print(f"Warning: stopped after {pages} pages with more results; raise --max-pages (max 100) or narrow "
                  "the query.", file=sys.stderr)
    return data, pages


def run(args):
    """Every refusal that needs no network happens before the key is read."""
    if args.verb is None:
        raise CliError("Usage: fal-api VERB ...; see fal-api --help.", "usage")
    if args.verb in {"run", "submit", "status", "result", "cancel"}:
        check_endpoint(args.endpoint)
    if args.verb in {"status", "result", "cancel"}:
        check_request_id(args.request_id)
    if args.verb in {"run", "submit"}:
        body = _input(args)
    if args.verb == "api":
        raw_path, query, api_body = plan_api(args)
    if args.verb == "upload" and not Path(args.file).is_file():
        raise CliError(f"{args.file} is not a readable file.", "usage")
    key, source = credentials()
    base = {"ok": True, "via": "fal", "verb": args.verb, "credential_source": source}
    if args.verb == "run":
        return run_verb(args, body, key, source)
    if args.verb == "submit":
        request_id, data = submit(args.endpoint, body, key, args.timeout)
        return {**base, "endpoint": args.endpoint, "request_id": request_id,
                "queue_position": data.get("queue_position"), "next": next_steps(args.endpoint, request_id)}
    if args.verb == "status":
        data = status(args.endpoint, args.request_id, key, args.timeout, args.logs)
        return {**base, "endpoint": args.endpoint, "request_id": args.request_id, "data": data}
    if args.verb == "result":
        data = result(args.endpoint, args.request_id, key, args.timeout)
        return {**base, "endpoint": args.endpoint, "request_id": args.request_id, "data": data}
    if args.verb == "cancel":
        data = cancel(args.endpoint, args.request_id, key, args.timeout)
        return {**base, "endpoint": args.endpoint, "request_id": args.request_id, "data": data}
    if args.verb == "upload":
        return {**base, **upload(args.file, args.content_type, key, args.timeout)}
    data, pages = api_verb(args, raw_path, query, api_body, key)
    return {**base, "method": args.method, "path": raw_path, "pages": pages, "data": data}


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        if args.where:
            print(json.dumps(source_metadata(), sort_keys=True))
            return 0
        print(scrub(json.dumps(run(args), ensure_ascii=False)))
        return 0
    except CliError as exc:
        print(scrub(json.dumps({"ok": False, "error": {
            "code": exc.code, "message": str(exc), "http_status": exc.status,
            "fal_type": (exc.detail or {}).get("type"), "request_id": exc.request_id,
        }}, ensure_ascii=False)))
        return 2 if exc.code in {"usage", "confirmation_required"} else 1
    except Exception:
        # Never include exception text: a transport message can carry the key.
        print(json.dumps({"ok": False, "error": {"code": "internal_error", "message": "fal-api failed unexpectedly.",
                                                 "http_status": None, "fal_type": None, "request_id": None}}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
