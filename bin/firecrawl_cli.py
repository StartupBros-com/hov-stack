#!/usr/bin/env python3
"""KTD1/KTD2: stdlib capability CLI over the official Firecrawl subprocess.

KTD8 pins the envelope and exits here. KTD4/KTD5 enforce the budget ledger.
KTD6/KTD7 gate and audit per-call code execution; KTD13 exposes job lifecycle.
This module never resolves credentials or vendor configuration.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime
from email.utils import parsedate_to_datetime
import fcntl
import functools
import http.client
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.error
from urllib.parse import urlsplit
import urllib.request

VERSION = "0.1.0"
EXIT_CODES = {
    0: {"meaning": "success", "retryable": False},
    1: {"meaning": "vendor or provider error", "retryable": False},
    2: {"meaning": "transient auth or provider failure; back off", "retryable": True},
    3: {"meaning": "budget refused", "retryable": False},
    4: {"meaning": "usage error", "retryable": False},
    5: {"meaning": "code mode refused", "retryable": False},
    6: {"meaning": "partial success", "retryable": False},
}
PROTECTED_FLAGS = {"--allow-code-exec", "--raise-budget"}
# Vendor and wrapper flags that take a value. Raw scanners consume the value so a
# value can never stand in for the subcommand (review 2026-09-13).
RAW_VALUE_FLAGS = frozenset({
    "--reason", "--scrape-id", "-s", "--code", "-c", "--prompt", "-p",
    "--timeout", "--output", "-o", "--api-key", "-k", "--api-url", "--token",
    "--format", "-f", "--limit", "--max-credits", "--model",
    "--schema", "--schema-file", "--query", "-Q", "--actions", "--actions-file",
    "--url", "-u", "--poll-interval", "--max-depth", "--exclude-paths",
    "--include-paths", "--sitemap", "--delay", "--max-concurrency",
    "--scrape-options", "--scrape-options-file", "--webhook",
    "--categories", "--sources", "--tbs", "--scrape-formats", "--max-age",
    "--location", "--country",
    # Vendor 1.26.x gov filters; a host on that version passes them through raw.
    "--jurisdiction", "--court", "--court-type", "--cites", "--domain",
    # Wrapper developer filters (vendor 1.26.24's `firecrawl developer` dropped them).
    "--types", "--repos", "--passages", "--language", "--topic", "--license",
    "--min-stars", "--max-stars", "--archived", "--fork",
})
# The wrapper's watchdog must outlive the vendor's own interact timeout so the
# vendor can report its outcome before the wrapper gives up.
INTERACT_TIMEOUT_MARGIN = 5
ACCOUNT_COMMANDS = {
    "login",
    "logout",
    "config",
    "view-config",
    "env",
    "setup",
    "init",
    "launch",
    "launcher",
    "make",
}
CREDENTIAL_FLAGS = {"--api-url", "--api-key", "-k", "--token"}
BODY_LIMIT = 24 * 1024
PARSE_EXTENSIONS = {
    ".html", ".htm", ".pdf", ".docx", ".doc", ".odt", ".rtf", ".xlsx", ".xls",
}
INJECTION_CHECK = (
    "unavailable through the vendor CLI v1.19.26; "
    "the API json-format option is not exposed"
)
SEARCH_CATEGORIES = ("github", "research", "pdf", "developer")
# Vendor CLI 1.19.26 validates categories client-side and omits developer
# (firecrawl/cli#222) while POST /v2/search accepts it, so that category is
# answered by the API directly, through the same envelope and budget.
API_ONLY_CATEGORIES = frozenset({"developer"})
SEARCH_SOURCES = ("web", "images", "news")
TBS_VALUES = ("qdr:h", "qdr:d", "qdr:w", "qdr:m", "qdr:y")
# API-direct verbs: the wrapper POSTs to these paths itself, so they need neither
# the vendor binary nor its version (the vendor's own gov and developer commands
# exist only from 1.26.x) and work without a key. FIRECRAWL_API_KEY, when the
# environment holds one, rides along as a Bearer for higher rate limits.
API_DIRECT_VERBS = {"gov": "/v2/search/gov", "developer": "/v2/search/developer"}
GOV_COURT_TYPES = (
    "federal-supreme", "federal-appellate", "federal-district", "federal-bankruptcy",
    "federal-special", "military", "state-supreme", "state-appellate", "state-trial",
    "state-special", "state-attorney-general",
)
# Wrapper flag to API body field; the API's own names, not the vendor's.
GOV_FILTERS = {
    "--limit": "k", "--jurisdiction": "jurisdiction", "--court": "court",
    "--court-type": "courtType", "--cites": "cites", "--domain": "domain",
}
DEVELOPER_TYPES = ("doc", "issue", "pull_request", "readme")
DEVELOPER_SOURCES_MAX = 20
DEVELOPER_SOURCE_CHARS = 512
DEVELOPER_PASSAGES_MAX = 5
DEVELOPER_FILTERS = {
    "--limit": "k", "--types": "types", "--repos": "repos", "--sources": "sources",
    "--skills-only": "skills", "--passages": "passages", "--language": "language",
    "--topic": "topic", "--license": "license", "--min-stars": "min_stars",
    "--max-stars": "max_stars", "--archived": "archived", "--fork": "fork",
}
KEYLESS_DEVELOPER_NOTE = (
    "keyless developer search: account floor unchecked; "
    "Firecrawl's keyless allowance applies"
)
# Free-first (#2118): a call whose keyed and keyless outputs were probed
# equivalent runs keyless first, since keyless calls never bill the account.
KEYLESS_NOTE = (
    "keyless: answered by Firecrawl's free keyless tier; no account credits spent, "
    "account floor unchecked"
)
# Routing notes start "keyless: " and never switch plain output to the envelope;
# KEYLESS_DEVELOPER_NOTE keeps doing so, as it always has.
KEYLESS_PREFIX = "keyless: "
KEYLESS_SCRAPE_ID_NOTE = (
    "keyless: scrape_id comes from a keyless fetch; interact runs keyed and may not "
    "find it, so refetch with FIRECRAWL_CLI_KEYLESS=0 before interact"
)
# The vendor goes keyless when it finds no key and the API URL is its default.
KEYLESS_STRIPPED = ("FIRECRAWL_API_KEY", "FIRECRAWL_API_URL")
KEYLESS_OFF = {"0", "false", "no", "off"}
# Failures that mean "this call needs the key", so the keyed leg runs once.
# Only the rate-limit refusal arms the cooldown; a 401 or 402 may be one
# combination's limit rather than the whole allowance. Anything else raises.
KEYLESS_FALLBACK_SHAPES = frozenset({
    "keyless_rate_limited", "auth_failure", "quota_exhausted", "credentials_missing",
    "rate_limited",
})
# A planted or skewed marker can hold eligible calls keyed for this long at most.
KEYLESS_COOLDOWN_CAP = 6 * 3600
# Probed equivalent (issue #2118 verdicts); anything else stays keyed.
KEYLESS_SCRAPE_FORMATS = frozenset({"summary", "markdown", "links", "html"})
KEYLESS_PARSE_FORMATS = frozenset({"summary", "markdown"})
KEYLESS_SEARCH_SOURCES = frozenset({"web", "images"})
KEYLESS_SEARCH_CATEGORIES = frozenset({"github", "research"})
KEYLESS_RESEARCH_COMMANDS = frozenset({"search-papers", "search-github"})
KEYLESS_LIMIT = 10
# Set by the first keyless refusal with no key to fall back on, so later targets
# of the same call fail without sending another refused request.
KEYLESS_REFUSED = None
# This process's own copy of the cooldown, for when the marker cannot be written.
KEYLESS_UNTIL = None
# Vendor 1.19.26 prints these successes as text whatever --json says (#2123):
# a --query answer (scrape.js:191-194, parse.js:212-215), and for a search whose
# web, images and news buckets are all empty, "No results found." or nothing
# (search.js:207-213).
VENDOR_NO_RESULTS = "No results found."
RESEARCH_BUCKET_NOTE = (
    "vendor counts only web, images and news results, so research-bucket "
    "results may be missing from an empty search (#2108)"
)
SEARCH_OPERATORS = (
    "quoted phrases, -term, site:host, inurl:term, intitle:term, related:host"
)
# Vendor help 1.19.26 lists these per surface; json needs a schema.
SCRAPE_FORMATS = (
    "markdown", "html", "rawHtml", "links", "images", "screenshot", "summary",
    "changeTracking", "json", "attributes", "branding",
)
PARSE_FORMATS = (
    "markdown", "html", "rawHtml", "links", "images", "summary", "json", "attributes",
)
DEFAULT_API_BASE = "https://api.firecrawl.dev"
LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}


class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """A 3xx from the API is a failure, never a hop: the bearer must not travel
    to whatever host a Location header names (review 2026-09-13)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECTS = urllib.request.build_opener(RefuseRedirects)
SECRET_FLAGS = {"--api-key", "-k", "--token"}
SECRETS = set()
ESTIMATED = "cost estimated, not measured"
BUDGET = None
# KTD4: credit estimates, seconds for windows, and host-local calendar days.
# Unclassified raw always uses at least the bounded-crawl rate, not raw_estimate.
BUDGET_DEFAULTS = {
    "floor": 200, "day_ceiling": 1000, "session_budget": 300,
    "daily_raise_bound": 500, "settle_window": 1800,
    "reservation_lifetime": 3600, "parse": 25, "raw_estimate": 25,
    "bounded_crawl": 100, "scrape": 1, "json_extraction": 5,
    "screenshot": 1, "search_per_ten": 2, "map": 1,
    "interact_per_minute": 7, "interact_code_per_minute": 2, "agent": 100,
    # Seconds a keyless refusal sends eligible calls straight to keyed when the
    # refusal names no Retry-After of its own (the vendor's never does).
    "keyless_cooldown": 3600,
}


def budget_constants():
    result = {}
    for key, default in BUDGET_DEFAULTS.items():
        name = "FIRECRAWL_CLI_" + key.upper()
        value = float(os.environ.get(name, default))
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"{name} must be positive and finite")
        result[key] = value
    if result["reservation_lifetime"] <= result["settle_window"]:
        raise ValueError("reservation lifetime must exceed the settle window")
    return result


def credit_number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


class Budget:
    """KTD4/KTD5 reserve-then-reconcile, shared by every vendor entry point.

    Successful lag-billed holds become spent after the settle window; only
    abandoned in-flight reservations expire. Session totals survive midnight.
    Raises increase the named bucket, with one cumulative host/day raise bound.
    """

    def __init__(self):
        self.constants = budget_constants()
        override = os.environ.get("FIRECRAWL_CLI_STATE_DIR")
        self.root = (
            Path(override) if override else Path.home() / ".claude/state/firecrawl-cli"
        )
        self.host = socket.gethostname()
        self.session = os.environ.get("CLAUDE_CODE_SESSION_ID") or None
        self.spent = 0
        self.remaining = None
        self.local_remaining = self.constants[
            "session_budget" if self.session else "day_ceiling"
        ]
        self.notes = []
        self.repair_needed = False

    def warn(self, message):
        if message not in self.notes:
            self.notes.append(message)
            print("warning: " + message, file=sys.stderr)

    @staticmethod
    def fresh():
        return {"version": 1, "revision": 0, "hosts": {}}

    @staticmethod
    def valid(data):
        """Reject structurally valid JSON that cannot safely enforce a ceiling."""
        def require(condition):
            if not condition:
                raise ValueError("invalid ledger schema")

        try:
            require(data["version"] == 1 and isinstance(data["hosts"], dict))
            require(type(data["revision"]) is int and data["revision"] >= 0)
            for host in data["hosts"].values():
                for kind in ("days", "sessions"):
                    require(isinstance(host[kind], dict))
                    for bucket in host[kind].values():
                        require(credit_number(bucket["spent"]))
                        require(isinstance(bucket["tags"], list))
                        require(isinstance(bucket.get("scrapes", {}), dict))
                        require(all(
                            credit_number(t) for t in bucket.get("scrapes", {}).values()
                        ))
                        require(isinstance(bucket.get("interacted", {}), dict))
                        require(all(
                            type(v) is bool for v in bucket.get("interacted", {}).values()
                        ))
                for day in host["days"].values():
                    require(isinstance(day["raises"], list))
                    for entry in day["raises"]:
                        require(credit_number(entry["amount"]))
                        require(isinstance(entry["reason"], str))
                        require(entry["session"] is None or isinstance(entry["session"], str))
                require(isinstance(host["reservations"], dict))
                require(isinstance(host.get("job_costs", {}), dict))
                require(all(credit_number(cost) for cost in host.get("job_costs", {}).values()))
                for entry in host["reservations"].values():
                    require(credit_number(entry["amount"]))
                    require(credit_number(entry["created"]))
                    require(entry["state"] in {"active", "held"})
                    require(entry["day"] in host["days"])
                    require(entry["session"] is None or entry["session"] in host["sessions"])
            return True
        except (ValueError, KeyError, TypeError, AttributeError):
            return False

    def read(self):
        primary = self.root / "ledger.json"
        snapshot = self.root / "snapshot.json"
        self.repair_needed = not primary.exists() or not snapshot.exists()
        if not primary.exists() and not snapshot.exists():
            return self.fresh()
        candidates = []
        for path in (primary, snapshot):
            try:
                data = json.loads(path.read_text())
                if not self.valid(data):
                    raise ValueError("invalid ledger schema")
                candidates.append(data)
            except (OSError, ValueError):
                self.repair_needed = True
                self.warn(f"budget ledger unreadable at {path.name}; using last known good sub-budget")
        if candidates:
            if len(candidates) == 2 and candidates[0]["revision"] != candidates[1]["revision"]:
                self.repair_needed = True  # resync the file that lags
            # A crash between the two renames must not lose a completed charge.
            return max(candidates, key=lambda candidate: candidate["revision"])
        # Both files lost: keep a finite, conservative sub-budget, never infinity
        # or a permanently latched refusal. The vendor floor remains mandatory.
        self.warn("no readable budget snapshot; recovering with a reduced session budget")
        data = self.fresh()
        _, day, session = self.buckets(data)
        day["spent"] = self.constants["day_ceiling"] - min(
            self.constants["session_budget"], self.constants["day_ceiling"]
        )
        if session is not None:
            session["spent"] = self.constants["session_budget"] / 2
        return data

    def write(self, data):
        data["revision"] += 1
        encoded = json.dumps(data, allow_nan=False).encode()
        # Snapshot first: an interrupted reservation write is conservative.
        for name in ("snapshot.json", "ledger.json"):
            fd, temporary = tempfile.mkstemp(prefix=".ledger-", dir=self.root)
            try:
                with os.fdopen(fd, "wb") as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(encoded)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.root / name)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)

    @contextmanager
    def transaction(self):
        # Locally reimplemented directory-fd family_state_lock pattern.
        if self.root.is_symlink():
            raise CliError(
                f"budget ledger directory is a symlink at {self.root}; refusing",
                "point FIRECRAWL_CLI_STATE_DIR at a real directory",
            )
        try:
            self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.root.chmod(0o700)
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        except OSError as exc:
            # A sandbox with a read-only home (Codex workspace-write) lands here.
            # Never drop the ceiling: refuse and name the writable-root remedy.
            raise CliError(
                f"budget ledger directory is unwritable at {self.root}: {exc.strerror}",
                "point FIRECRAWL_CLI_STATE_DIR at a writable directory, "
                "or grant the sandbox write access to it",
            ) from exc
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            data = self.read()
            before = json.dumps(data, sort_keys=True)
            self.reap(data)
            try:
                yield data
            finally:
                self.local_remaining = self.available(data)
                # A read-only pass (every reap) skips the double fsync; a damaged
                # or missing file is still rewritten from the good copy.
                if self.repair_needed or json.dumps(data, sort_keys=True) != before:
                    self.write(data)
                    os.fsync(fd)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def buckets(self, data):
        host = data["hosts"].setdefault(
            self.host, {"days": {}, "sessions": {}, "reservations": {}}
        )
        day = host["days"].setdefault(
            datetime.now().date().isoformat(), {"spent": 0, "raises": [], "tags": []}
        )
        session = host["sessions"].setdefault(
            self.session, {"spent": 0, "tags": []}
        ) if self.session else None
        return host, day, session

    def reap(self, data):
        host, _, _ = self.buckets(data)
        for key, entry in list(host["reservations"].items()):
            age = time.time() - entry["created"]
            if entry["state"] == "held" and age >= self.constants["settle_window"]:
                self.charge(host, entry, entry["amount"])
                del host["reservations"][key]
            elif entry["state"] == "active" and age >= self.constants["reservation_lifetime"]:
                del host["reservations"][key]

    @staticmethod
    def charge(host, entry, amount):
        host["days"][entry["day"]]["spent"] += amount
        if entry["session"]:
            host["sessions"][entry["session"]]["spent"] += amount

    def available(self, data):
        host, day, session = self.buckets(data)
        held = list(host["reservations"].values())
        # Outstanding jobs from yesterday still compete for today's allowance.
        daily = self.constants["day_ceiling"] + sum(
            e["amount"] for e in day["raises"] if e["session"] is None
        ) - day["spent"] - sum(e["amount"] for e in held)
        if session is None:
            return max(0, daily)
        local = self.constants["session_budget"] + sum(
            e["amount"] for previous in host["days"].values()
            for e in previous["raises"] if e["session"] == self.session
        ) - session["spent"] - sum(
            e["amount"] for e in held if e["session"] == self.session
        )
        return max(0, min(daily, local))

    def view(self, amount=None, reason=None):
        with self.transaction() as data:
            host, day, session = self.buckets(data)
            if amount is not None:
                if amount <= 0 or not reason or not reason.strip():
                    raise CliError("--raise-budget needs a positive amount and --reason text", "firecrawl-cli budget --help")
                raised = sum(e["amount"] for e in day["raises"])
                if raised + amount > self.constants["daily_raise_bound"]:
                    raise CliError(
                        f"session budget raise exceeds cumulative daily bound {self.constants['daily_raise_bound']:g}",
                        "out-of-band operator action required", 3,
                    )
                day["raises"].append({
                    "amount": amount, "reason": reason, "session": self.session,
                    "at": time.time(),
                })
                print(f"session budget raised by {amount:g}: {redact(reason)}", file=sys.stderr)
            return {
                "available": True, "host": self.host,
                "day": datetime.now().date().isoformat(), "day_state": day,
                "session_id": self.session, "session": session,
                "reservations": host["reservations"], "raises": day["raises"],
                "tags": (session if session is not None else day)["tags"],
                "budget_remaining": self.available(data),
            }

    def code_attempt(self, granted, reason, scrape_id):
        """KTD6: consent is evidence for this call only, never a standing grant."""
        with self.transaction() as data:
            _, day, session = self.buckets(data)
            tag = redact({
                "kind": "code-mode", "granted": granted, "reason": reason,
                "scrape_id": scrape_id, "at": time.time(),
            })
            day["tags"].append(tag)
            if session is not None:
                session["tags"].append(tag)

    def touch_scrape(self, scrape_id, interact=False):
        with self.transaction() as data:
            _, day, session = self.buckets(data)
            bucket = session if session is not None else day
            previous = bucket.get("scrapes", {}).get(scrape_id)
            prior_interact = bucket.get("interacted", {}).get(scrape_id, False)
            now = time.time()
            if interact and previous is not None and now - previous > (
                300 if prior_interact else 600
            ):
                self.warn("interact session likely expired")
            for target in (day, session):
                if target is not None:
                    target.setdefault("scrapes", {})[scrape_id] = now
                    target.setdefault("interacted", {})[scrape_id] = interact

    def reserve(self, amount, keyless_rerun=None):
        with self.transaction() as data:
            remaining = self.available(data)
            host, _, _ = self.buckets(data)
            pending = sum(e["amount"] for e in host["reservations"].values())
            floor = self.constants["floor"]
            if self.remaining is not None and self.remaining - pending - amount < floor:
                # The account, not the session bucket, is short; --raise-budget
                # cannot lift it, so name the account remedy instead (#2105).
                next_action = (
                    "operator action: top up Firecrawl credits in the Firecrawl dashboard "
                    "or wait for the billing cycle reset; then check: firecrawl credit-usage --json"
                )
                if keyless_rerun:
                    next_action = (
                        f"rerun keyless, which spends no account credits: {keyless_rerun}; or {next_action}"
                    )
                raise CliError(
                    f"vendor balance refused: Firecrawl account has {self.remaining:g} credits; "
                    f"pending reservations {pending:g}; reservation {amount:g}; floor {floor:g}; "
                    "a session --raise-budget cannot lift the account balance",
                    next_action, 3,
                )
            if remaining < amount:
                raise CliError(
                    f"session budget refused: {remaining:g} credits remaining; reservation {amount:g}; "
                    f"vendor credits remaining {self.remaining}; floor {self.constants['floor']:g}; use --raise-budget <n> --reason <text>",
                    "firecrawl-cli budget --raise-budget <n> --reason <text> --json", 3,
                )
            key = uuid.uuid4().hex
            host["reservations"][key] = {
                "amount": amount, "created": time.time(), "state": "active",
                "day": datetime.now().date().isoformat(), "session": self.session,
            }
            return key

    def finish(self, key, amount=None, lag=False):
        with self.transaction() as data:
            host, _, _ = self.buckets(data)
            entry = host["reservations"].get(key)
            if entry is None:
                return
            if amount is not None and lag:
                entry.update(amount=amount, state="held", created=time.time())
            else:
                if amount is not None:
                    self.charge(host, entry, amount)
                del host["reservations"][key]
            return entry

    def adjust(self, entry, delta):
        with self.transaction() as data:
            host, _, _ = self.buckets(data)
            self.charge(host, entry, delta)

    def fields(self, result):
        result.update(
            credits_spent=self.spent, credits_remaining=self.remaining,
            budget_remaining=self.local_remaining,
        )
        result["degraded"] = list(dict.fromkeys(
            (result.get("degraded") or []) + self.notes
        )) or None
        return result


def reported_cost(payload):
    if not isinstance(payload, dict):
        return None
    for key in ("creditsUsed", "credits_spent"):
        if credit_number(payload.get(key)):
            return payload[key]
    # Scrape and parse report their charge inside the page metadata.
    metadata = payload.get("metadata")
    if isinstance(metadata, dict) and credit_number(metadata.get("creditsUsed")):
        return metadata["creditsUsed"]
    if isinstance(payload.get("items"), list):
        costs = [reported_cost(item) for item in payload["items"] if item_succeeded(item)]
        if costs and all(cost is not None for cost in costs):
            return sum(costs)
    return reported_cost(payload.get("data"))


TERMINAL_JOB_STATES = frozenset({"completed", "failed", "cancelled"})


def cost_final(payload, running=False):
    """Whether reported_cost(payload) is the whole charge (#2117). It is when the
    work behind it has finished: the job states a terminal status, or there is no
    job status at all (a synchronous scrape or search). A running job's
    creditsUsed is a running total, and a status this cannot read is not
    terminal. Walks the same path as reported_cost."""
    if not isinstance(payload, dict):
        return False
    if "status" in payload:
        status = payload["status"]
        running = running or not (isinstance(status, str) and status in TERMINAL_JOB_STATES)
    if any(credit_number(payload.get(key)) for key in ("creditsUsed", "credits_spent")):
        return not running
    metadata = payload.get("metadata")
    if isinstance(metadata, dict) and credit_number(metadata.get("creditsUsed")):
        return not running
    if isinstance(payload.get("items"), list):
        items = [item for item in payload["items"] if item_succeeded(item)]
        return bool(items) and all(cost_final(item, running) for item in items)
    return cost_final(payload.get("data"), running)


def read_credits(budget, timeout):
    for attempt in range(3):
        try:
            payload, _ = invoke_vendor(["credit-usage", "--json"], timeout)
            # Host-verified vendor shape: planCredits is the period total,
            # never the available balance used by the pre-call floor.
            data = payload.get("data")
            value = data.get("remainingCredits")
            # An overdrawn account reports a negative balance: a real reading for
            # reserve() to refuse against the floor, not a malformed one to retry (#2105).
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError("credit-usage response needs numeric data.remainingCredits")
            budget.remaining = value
            return value
        except (CliError, ValueError, AttributeError, TypeError) as exc:
            mapped = isinstance(getattr(exc, "error_code", None), str)
            if mapped and exc.code == 1:
                raise
            if attempt == 2:
                if mapped:
                    exc.args = (str(exc) + " Credit-usage read failed on all three retry attempts.",)
                    raise
                raise CliError(
                    "credit-usage read failed on all three retry attempts",
                    "retry after checking firecrawl credit-usage --json", 2,
                ) from None
            budget.warn("credit-usage read failed transiently; retrying with local session budget intact")
            time.sleep(0.05 * (attempt + 1))


def reservation_cost(args, surface):
    c = BUDGET.constants
    if args.verb == "raw":
        return max(c["raw_estimate"], c["bounded_crawl"]), True
    if surface == "parse":
        return c["parse"], False
    if args.verb == "agent":
        if args.status:
            # A status read incurs no new vendor spend; the job was reserved when
            # it was created (polling used to re-charge it every call).
            return 0, False
        return getattr(args, "max_credits", None) or c["agent"], True
    if args.verb == "interact" and args.target == "stop":
        return 0, False  # ending a session accrues nothing new
    if args.verb in {"search", "developer"}:
        # Developer reaches here only with a key; keyless never reserves.
        return c["search_per_ten"] * math.ceil((args.limit or 10) / 10), False
    if args.verb == "interact":
        rate = (
            "interact_code_per_minute"
            if args.code is not None and args.target is None
            else "interact_per_minute"
        )
        return c[rate] * max(1, math.ceil(args.timeout / 60)), False
    if args.verb == "shot":
        return c["screenshot"], False
    if args.verb == "extract" or any(
        getattr(args, name, None) for name in ("schema", "schema_file", "query")
    ):
        return c["json_extraction"], False
    # Only scrape and map reach here; both bill synchronously.
    return c.get(surface, c["bounded_crawl"]), False


@functools.lru_cache(maxsize=None)
def vendor_binary():
    """PATH does not change within one invocation; shutil.which is command -v."""
    return shutil.which("firecrawl")


def keyless_shape(args, surface, command):
    """Whether this argv is one the #2118 probe found keyless-equivalent. Reads the
    produced command, never args.target: a multi-URL call passes its list here."""
    verb = args.verb
    if verb == "raw":
        return (
            len(command) >= 2 and command[0] == "research"
            and command[1] in KEYLESS_RESEARCH_COMMANDS
            and not {"--help", "-h"} & set(command)
        )
    if verb == "developer":
        return args.limit is None or args.limit <= KEYLESS_LIMIT
    if verb == "search":
        filters = search_filters(args)
        return (
            surface == "search" and (args.limit is None or args.limit <= KEYLESS_LIMIT)
            and set(filters["sources"]) <= KEYLESS_SEARCH_SOURCES
            and set(filters["categories"]) <= KEYLESS_SEARCH_CATEGORIES
        )
    if verb == "shot":
        return surface == "scrape"
    if verb not in {"fetch", "extract"} or surface not in {"scrape", "parse"}:
        return False  # act, interact, map, agent: probed unequal or never keyless
    options = command[2:]
    formats = options[options.index("--format") + 1].split(",") if "--format" in options else []
    query = getattr(args, "query", None)
    if surface == "parse":
        # Only PDFs were probed, and a parse question was not.
        return (
            Path(command[1]).suffix.lower() == ".pdf" and not query
            and bool(formats) and set(formats) <= KEYLESS_PARSE_FORMATS
        )
    if args.schema or args.schema_file:
        return formats == ["json"] and not query
    if query:
        return not formats
    return bool(formats) and set(formats) <= KEYLESS_SCRAPE_FORMATS


def vendor_login():
    """The vendor's stored login (credentials.js:50-67). Stripping the environment
    cannot hide it, and any file there may hold a key or another API URL."""
    home = Path.home()
    base = {
        "darwin": home / "Library/Application Support",
        "win32": home / "AppData/Roaming",
    }.get(sys.platform, home / ".config")
    return (base / "firecrawl-cli/credentials.json").exists()


def keyless_ready(args, surface, command, api):
    if os.environ.get("FIRECRAWL_CLI_KEYLESS", "").strip().lower() in KEYLESS_OFF:
        return False
    if not keyless_shape(args, surface, command):
        return False
    if api:
        return True  # The wrapper itself omits the Bearer.
    url = os.environ.get("FIRECRAWL_API_URL")
    return vendor_binary() is not None and url in {None, "", DEFAULT_API_BASE} and not vendor_login()


def keyless_cooldown_path():
    return BUDGET.root / "keyless-cooldown.json"


def keyless_cooldown():
    """When eligible keyed calls may try keyless again, or None. Read without the
    ledger lock; anything unreadable is no cooldown, and a planted or skewed
    marker holds calls keyed for KEYLESS_COOLDOWN_CAP at most."""
    try:
        until = json.loads(keyless_cooldown_path().read_text())["until"]
    except (OSError, ValueError, TypeError, KeyError):
        until = None
    now = time.time()
    if type(until) not in (int, float) or not math.isfinite(until):
        until = None
    until = max(until or 0, KEYLESS_UNTIL or 0)
    return min(until, now + KEYLESS_COOLDOWN_CAP) if until > now else None


def arm_keyless_cooldown(stated):
    """Best effort: a marker that cannot be written costs a refused attempt later,
    never this call. Returns the cooldown's end and any note to surface."""
    global KEYLESS_UNTIL
    seconds = min(stated or BUDGET.constants["keyless_cooldown"], KEYLESS_COOLDOWN_CAP)
    until = KEYLESS_UNTIL = max(time.time() + seconds, keyless_cooldown() or 0)
    try:
        if BUDGET.root.is_symlink():
            raise OSError(f"{BUDGET.root} is a symlink")
        BUDGET.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".keyless-", dir=BUDGET.root)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump({"until": until, "set_at": time.time()}, stream)
            os.replace(temporary, keyless_cooldown_path())
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except OSError as exc:
        return until, f"{KEYLESS_PREFIX}cooldown not recorded: {exc.strerror or exc}"
    return until, None


def local_time(epoch):
    return datetime.fromtimestamp(epoch).astimezone().isoformat(timespec="minutes")


def budgeted_invoke(args, surface, command):
    global KEYLESS_REFUSED
    api = uses_api(args)
    if api and not api_billed(args):
        # Free class: gov always, developer without a key. Nothing to read,
        # reserve, or settle; the envelope reports credits_spent 0.
        payload, notes = invoke_api(
            api_path(args), api_body(args), command, args.timeout, args.retry_command
        )
        if args.verb == "developer":
            notes.append(KEYLESS_DEVELOPER_NOTE)
        return payload, notes
    vendor_present = vendor_binary() is not None
    if not vendor_present and not api:
        return invoke_vendor(command, args.timeout, args.verb == "raw")
    if args.timeout >= BUDGET.constants["reservation_lifetime"]:
        raise CliError("wrapper timeout must be shorter than reservation lifetime", "reduce --timeout")
    # This exact validated argv prints local help without spending account credits.
    if args.verb == "raw" and command == ["research", "--help"]:
        return invoke_vendor(command, args.timeout, True, args.retry_command)
    # Free-first (#2118): an eligible call tries keyless, then runs keyed once when
    # keyless refuses it. Without a key keyless is the only leg, cooldown or not.
    fallback = []
    if keyless_ready(args, surface, command, api):
        keyed = bool(os.environ.get("FIRECRAWL_API_KEY"))
        cooling = keyless_cooldown() if keyed else None
        if cooling:
            fallback.append(
                f"{KEYLESS_PREFIX}skipped, ran keyed: the free tier refused a call "
                f"recently; it is tried again after {local_time(cooling)}"
            )
        elif KEYLESS_REFUSED is not None and not keyed:
            error = CliError(
                f"error: not sent: the keyless free tier refused an earlier target of "
                f"this call at {shlex.join(command[:2])}",
                KEYLESS_REFUSED.next_action, KEYLESS_REFUSED.code,
            )
            error.error_code = KEYLESS_REFUSED.error_code
            error.metadata = KEYLESS_REFUSED.metadata
            raise error
        else:
            try:
                if api:
                    payload, notes = invoke_api(
                        api_path(args), api_body(args), command, args.timeout,
                        args.retry_command, keyless=True,
                    )
                else:
                    payload, notes = invoke_vendor(
                        command, args.timeout, args.verb == "raw", args.retry_command,
                        keyless=True,
                    )
            except CliError as exc:
                tag = getattr(exc, "error_code", None)
                if tag not in KEYLESS_FALLBACK_SHAPES:
                    raise
                # Arm before the keyed leg, so its own refusal still leaves the cooldown.
                until, note = (
                    arm_keyless_cooldown(getattr(exc, "retry_after", None))
                    if tag == "keyless_rate_limited" else (None, None)
                )
                if not keyed:
                    if until:
                        exc.next_action = exc.next_action.replace(
                            "later:", f"after about {local_time(until)}:", 1
                        )
                    exc.degraded = [*(exc.degraded or []), *filter(None, [note])] or None
                    if until:
                        KEYLESS_REFUSED = exc
                    raise
                why = str(exc).splitlines()[0].removeprefix("error: ")
                fallback.append(f"{KEYLESS_PREFIX}{tag}: {why}; ran keyed instead")
                if until:
                    fallback.append(
                        f"{KEYLESS_PREFIX}eligible calls run keyed until {local_time(until)}"
                    )
                if note:
                    fallback.append(note)
            else:
                notes.append(KEYLESS_DEVELOPER_NOTE if args.verb == "developer" else KEYLESS_NOTE)
                if args.verb == "fetch" and returned_scrape_id(payload):
                    notes.append(KEYLESS_SCRAPE_ID_NOTE)
                return payload, notes
    try:
        return keyed_invoke(args, surface, command, api, vendor_present, fallback)
    except CliError as exc:
        if fallback:
            exc.degraded = [*fallback, *(exc.degraded or [])]
            if exc.code == 3:
                exc.args = (f"keyless leg unavailable, and the keyed fallback was refused: {exc}",)
        raise


def keyed_invoke(args, surface, command, api, vendor_present, fallback):
    # The API transport needs no vendor binary. Without one the local ledger still
    # caps the session and the day, but the account floor cannot be read.
    before = read_credits(BUDGET, args.timeout) if vendor_present else None
    estimate, lag = reservation_cost(args, surface)
    # After a keyless refusal, or during its cooldown, a keyless rerun would fail too.
    keyless_rerun = (
        f"env -u FIRECRAWL_API_KEY {args.retry_command}"
        if args.verb == "developer" and not fallback else None
    )
    key = BUDGET.reserve(estimate, keyless_rerun)
    try:
        if getattr(args, "scrape_id", None):
            BUDGET.touch_scrape(args.scrape_id, interact=True)
        wrapper_timeout = args.timeout + (
            INTERACT_TIMEOUT_MARGIN if args.verb == "interact" else 0
        )
        if api:
            payload, notes = invoke_api(
                api_path(args), api_body(args), command, wrapper_timeout,
                args.retry_command,
            )
        else:
            payload, notes = invoke_vendor(
                command, wrapper_timeout, args.verb == "raw", args.retry_command
            )
        if args.verb == "fetch":
            scrape_id = returned_scrape_id(payload)
            if scrape_id:
                BUDGET.touch_scrape(scrape_id)
    except BaseException:
        BUDGET.finish(key)
        raise
    notes[:0] = fallback
    if isinstance(payload, dict) and isinstance(payload.get("items"), list) and not any(
        item_succeeded(item) for item in payload["items"]
    ):
        BUDGET.finish(key)
        return payload, notes
    reported = reported_cost(payload)
    free_read = args.verb == "agent" and getattr(args, "status", False)
    cost = 0 if free_read else (reported if reported is not None else estimate)
    # Raw holds the bounded-crawl reservation unless the vendor reported a final
    # cost; a finished job's creditsUsed is the charge (#2117).
    raw_unsettled = args.verb == "raw" and not (reported is not None and cost_final(payload))
    # Commit the known outcome before optional accounting I/O, so interruption
    # during a post-call read can never release a successful paid invocation.
    held_cost = max(estimate, cost) if raw_unsettled else cost
    try:
        entry = BUDGET.finish(key, held_cost if lag else cost, lag)
    except OSError as exc:
        # The vendor already answered: keep the payload, say the charge is not durable.
        entry = None
        notes.append(f"charge not durably recorded: {exc.strerror or exc}")
    BUDGET.spent += cost
    if not free_read and (reported is None or raw_unsettled):
        notes.append(ESTIMATED)
    if not vendor_present:
        notes.append("credit floor unchecked: vendor firecrawl absent; local ledger only")
    BUDGET.notes.extend(note for note in notes if note not in BUDGET.notes)
    if not lag and vendor_present:
        try:
            after = read_credits(BUDGET, args.timeout)
            if reported is None and before > after and entry is not None:
                delta = before - after - cost
                BUDGET.adjust(entry, delta)
                BUDGET.spent += delta
        except CliError:
            BUDGET.warn("post-call credit-usage unavailable; reservation charged locally")
    return payload, notes


def remember_secrets(argv):
    """KTD9: retain flag values only for redacting subsequent diagnostics."""
    SECRETS.clear()
    for index, arg in enumerate(argv):
        name, separator, value = arg.partition("=")
        if name in SECRET_FLAGS:
            if separator:
                SECRETS.add(value)
            elif index + 1 < len(argv):
                SECRETS.add(argv[index + 1])
        elif arg.startswith("-k") and len(arg) > 2:
            SECRETS.add(arg[2:])
    SECRETS.discard("")


def redact(value):
    if isinstance(value, dict):
        return {redact(k): redact(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    if not isinstance(value, str):
        return value
    # CSI and OSC terminal controls, including color and hyperlink sequences.
    value = re.sub(
        r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))", "", value
    )
    for secret in sorted(SECRETS, key=len, reverse=True):
        value = value.replace(shlex.quote(secret), "[REDACTED]")
        value = value.replace(secret, "[REDACTED]")
    value = re.sub(r"(?i)(\bbearer\s+)[a-z0-9._~+/-]+=*", r"\1[REDACTED]", value)
    # The keyless refusal's per-install signup link (#2118).
    value = re.sub(r"(?i)\bhttps?://(?:www\.)?firecrawl\.dev/k/[^\s\"'<>)]+", "[REDACTED]", value)
    value = re.sub(
        r"\b(?:fc-[A-Za-z0-9_-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b",
        "[REDACTED]", value,
    )
    value = re.sub(r"(?<!\S)(-k)(?!\[REDACTED\])[^\s=]+", r"\1[REDACTED]", value)
    return re.sub(
        r"((?:--api-key|--token|(?<!\w)-k)(?:=|\s+))('[^']*'|\"[^\"]*\"|\S+)",
        r"\1[REDACTED]",
        value,
    )


class CliError(Exception):
    def __init__(self, message, next_action, code=4, data=None, degraded=None):
        super().__init__(message)
        self.code = code
        self.next_action = next_action
        self.data = data
        self.degraded = degraded

    def error_object(self):
        return {
            "code": getattr(self, "error_code", self.code),
            "message": str(self),
            "next_action": self.next_action,
            "retryable": EXIT_CODES[self.code]["retryable"],
            **{"http_status": None, **getattr(self, "metadata", {})},
        }


# KTD9: HTTP codes take precedence; substrings recover CLI-only diagnostics.
# A substring on an HTTP row refines that status (403 requires the injection
# tag; 429 distinguishes concurrency). The final 429 row is its default.
FAILURE_SHAPES = (
    # The keyless free tier's refusal: HTTP 429 from the API, and from the vendor
    # only this text on stderr with exit 1 (measured 2026-10-30, #2118).
    # Exit 1, not 2: the window runs for hours, so backing off and retrying is wrong.
    ({429}, ("keyless free tier",), 1, "keyless_rate_limited",
     "Firecrawl's keyless free tier refused the call: its small allowance (about "
     "15 calls, then a window measured at over 40 minutes) is used up for now.",
     "set FIRECRAWL_API_KEY in this process's environment to run it keyed, or "
     "retry keyless later: {retry}", True),
    ({402}, ("insufficient credits", "payment required"), 1, "quota_exhausted",
     "Insufficient credits; Firecrawl quota exhausted.",
     "operator action: top up Firecrawl credits in the Firecrawl dashboard; "
     "then check: firecrawl --status", True),
    ({403}, ("scrape_prompt_injection_detected",), 1, "injection_blocked",
     "Page blocked as injected content by the vendor prompt-injection check; "
     "not retryable as-is.",
     "narrow the schema or prompt; try: {narrow}; or fetch the page as plain text "
     "and read it as data: {fetch}", False),
    ({401}, ("unauthorized", "invalid token", "credential validation unavailable"),
     2, "auth_failure", "Authentication failed; credential source: {source}. {backoff}",
     "firecrawl --status; then retry: {retry}", True),
    ({408}, ("request timeout",), 2, "request_timeout",
     "Provider request timed out. {backoff}", "{retry}", True),
    ({429}, ("concurrency limit reached",), 2, "concurrency_limited",
     "Firecrawl concurrency limit reached; let active requests finish. {backoff}",
     "{retry}", True),
    ({429}, ("rate limit exceeded",), 2, "rate_limited",
     "Firecrawl rate limit exceeded. {backoff}", "{retry}", True),
    (set(range(500, 600)),
     ("internal server error", "bad gateway", "service unavailable", "gateway timeout"),
     2, "provider_failure", "Firecrawl provider failure. {backoff}", "{retry}", True),
    (set(), ("we do not support this site",), 1, "unsupported_site",
     "Firecrawl does not support this site.", "{contents}", True),
    # With no key and no stored login the vendor prints its interactive login
    # menu and exits 0; neither a retry nor the drift check can fix that.
    (set(), ("authenticate with your firecrawl account",), 1, "credentials_missing",
     "The vendor CLI found no Firecrawl credential (FIRECRAWL_API_KEY unset, no "
     "stored login) and printed its interactive login menu instead of JSON.",
     "set FIRECRAWL_API_KEY in this process's environment, or run firecrawl login "
     "once on this host; then check: firecrawl --status", False),
    (set(), (), 2, "vendor_output_changed",
     "Vendor returned no valid JSON; vendor output changed; run the drift check "
     "(harness-doctor check 32). {backoff}", "harness-doctor check 32", False),
)


def error_metadata(payload, detail):
    """Read only error metadata, never HTTP-looking text from scraped data."""
    records = []

    def collect(value):
        if isinstance(value, dict):
            records.append(value)
            for key in ("error", "details", "headers"):
                collect(value.get(key))

    collect(payload)
    try:
        collect(json.loads(detail))
    except ValueError:
        pass
    diagnostic = "\n".join([
        detail,
        *(record[key] for record in records for key in ("error", "message", "text")
          if isinstance(record.get(key), str)),
    ])
    status = None
    retry_after = None
    for record in records:
        for key, value in record.items():
            name = key.lower().replace("_", "").replace("-", "")
            if name in {"status", "statuscode", "httpstatus", "httpstatuscode"}:
                if status is None and re.fullmatch(r"[45]\d\d", str(value)):
                    status = int(value)
            # The keyless refusal's body says retry_after_seconds (#2118).
            if name in {"retryafter", "retryafterseconds"}:
                retry_after = value
    if status is None:
        match = re.search(
            r"(?i)\b(?:HTTP(?:/\d(?:\.\d)?)?|status(?:\s+code)?)\s*[:=]?\s*([45]\d\d)\b",
            diagnostic,
        )
        if match:
            status = int(match[1])
    if retry_after is None:
        match = re.search(r"(?im)\bRetry-After\s*:\s*([^\r\n]+)", diagnostic)
        if match:
            retry_after = match[1].strip()
    delay = 5
    stated = None  # the server's own Retry-After in seconds, when it gave one
    if retry_after is not None:
        try:
            value = float(retry_after)
        except (ValueError, TypeError):
            try:
                value = parsedate_to_datetime(str(retry_after)).timestamp() - time.time()
            except (ValueError, TypeError, OverflowError):
                value = 0
        if math.isfinite(value) and value > 0:
            stated = math.ceil(value)
            delay = max(delay, stated)
    return status, delay, stated


def exa_fallback(query):
    """KTD10: local credential presence is not a provider health check."""
    try:
        response = subprocess.run(
            ["exa-cli", "--where"], capture_output=True, text=True,
            errors="replace", timeout=5,
        )
        source = " ".join(response.stdout.split()) if response.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        source = ""
    if not source:
        return "Exa: no credential resolved — operator action: add EXA_API_KEY to bws"
    # Quote the query for a literal, copy-pasteable shell argument.
    quoted = '"' + re.sub(r'([\\"$`])', r'\\\1', query) + '"'
    return redact(
        f"Exa: credential present (source: {source}), live status unknown — "
        f"try: exa-cli search {quoted} --limit 3 --json"
    )


def vendor_failure(command, payload, detail, timing="", retry=None, malformed=False):
    """One renderer for shaped, raw, and per-item provider failures (KTD9)."""
    status, delay, stated = error_metadata(payload, detail)
    vendor_error = payload.get("error", payload.get("text", "")) if isinstance(payload, dict) else ""
    evidence = redact("; ".join(filter(None, (detail, str(vendor_error)))))
    # The injection tag can also be supplied in details rather than error text.
    if isinstance(payload, dict) and payload.get("details") is not None:
        evidence += "; " + json.dumps(redact(payload["details"]), ensure_ascii=False)
    lowered = evidence.lower()
    shape = None
    for row in FAILURE_SHAPES:
        statuses, substrings, _, tag, *_ = row
        if status not in statuses:
            continue
        if tag in {"keyless_rate_limited", "injection_blocked", "concurrency_limited"} and not any(
            text in lowered for text in substrings
        ):
            continue
        shape = row
        break
    if shape is None:
        for row in FAILURE_SHAPES:
            statuses, substrings, *_ = row
            if status is not None and statuses and status not in statuses:
                continue
            if any(text in lowered for text in substrings):
                shape = row
                break
    if shape is None and malformed:
        shape = next(row for row in FAILURE_SHAPES if row[3] == "vendor_output_changed")
    target = next((arg for arg in command[1:] if is_url(arg)), None)
    query = (
        command[1]
        if command[0] in {"search", *API_DIRECT_VERBS} and len(command) > 1
        else target
    )
    retry = retry or shlex.join(["firecrawl-cli", "raw", "--json", "--", *command])
    values = {
        "source": (
            "env (FIRECRAWL_API_KEY)" if os.environ.get("FIRECRAWL_API_KEY")
            else "vendor-managed configuration (resolve with firecrawl --status)"
        ),
        "backoff": f"retry after {delay}s, doubling to {max(60, delay)}s.",
        "retry": retry,
        "fetch": shlex.join(["firecrawl-cli", "fetch", target or "<url>", "--full", "--json"]),
        "narrow": shlex.join([
            "firecrawl-cli", "extract", target or "<url>",
            "-Q", "Extract only the page title", "--json",
        ]),
        "contents": shlex.join(["exa-cli", "contents", target or "<url>", "--json"]),
    }
    if shape:
        _, _, code, tag, reason, action, fallback = shape
        reason, action = reason.format(**values), action.format(**values)
    else:
        code, tag, reason, action, fallback = (
            1, 1, "The vendor rejected the call; inspect its diagnostic.",
            "firecrawl --status", False,
        )
    location = shlex.join(command[:2])
    what = {
        "vendor_output_changed": "could not decode vendor output",
        "credentials_missing": "vendor has no Firecrawl credential",
        "keyless_rate_limited": "keyless free tier refused the call",
    }.get(tag, "vendor rejected the call")
    message = f"error: {what} at {location}"
    if timing:
        message += f" ({timing})"
    message += f"\nwhy: {reason}"
    if evidence:
        message += " Vendor: " + " ".join(evidence.splitlines())
    if fallback and query:
        action += "\n" + exa_fallback(query)
    elif fallback:
        action += "\noperator action: check Firecrawl account/provider status with firecrawl --status"
    error = CliError(redact(message), redact(action), code, payload)
    error.error_code = tag
    error.metadata = {"http_status": status}
    error.retry_after = stated
    return error


class Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)

    def error(self, message):
        raise CliError(message, f"{self.prog} --help")


def build_parser():
    parser = Parser(
        prog="firecrawl-cli",
        description="Firecrawl capabilities: documents, extraction, screenshots, and browser tasks.",
        epilog=(
            "A bare URL or local path infers fetch. "
            "Put --json after the verb (canonical); before the verb also works. "
            "Use capabilities --json for flags, costs, limits, and exits. "
            "raw -- <vendor args> passes arguments unchanged; add vendor --json for "
            "research and search, never for crawl or monitor, which print JSON by "
            "default and reject it. "
            "monitor and crawl are raw-only; credits scale with work. A raw call whose "
            "output reports creditsUsed for finished work (job status completed, failed "
            "or cancelled, or no job status) is charged that; any other raw call holds "
            "the bounded-crawl reservation (100 credits by default) and counts it as "
            "spent once the settle window passes. "
            "Free-first: a call whose keyless answer was probed equivalent tries "
            "Firecrawl's free keyless tier before spending credits, key or not, and "
            "runs keyed once if refused (capabilities warnings list them); "
            "FIRECRAWL_CLI_KEYLESS=0 turns that off. "
            "Exit codes: "
            + "; ".join(f"{k}={v['meaning']}" for k, v in EXIT_CODES.items())
            + ". Exit 3 refuses the session budget; cron callers must alert on it themselves."
        ),
    )
    parser.add_argument(
        "--json", action="store_true", help="emit a JSON response envelope"
    )
    parser.add_argument(
        "--version", action="version", version=f"firecrawl-cli {VERSION}"
    )
    def budget_flags(p, default=None):
        p.add_argument("--raise-budget", type=int, default=default,
                       help="increase session budget within the daily raise bound")
        p.add_argument("--reason", default=default, help="reason for a budget raise or per-call code consent")

    budget_flags(parser)
    sub = parser.add_subparsers(dest="verb", required=True)
    registry = {}

    def verb(name, description, cost_class):
        p = sub.add_parser(name, help=description, description=description)
        p.add_argument(
            "--json",
            action="store_true",
            default=argparse.SUPPRESS,
            help="emit a JSON response envelope (canonical: after the verb)",
        )
        registry[name] = {"parser": p, "cost_class": cost_class}
        budget_flags(p, argparse.SUPPRESS)
        if cost_class != "offline":
            p.add_argument(
                "--timeout", type=float, default=30 if name == "interact" else 120,
                help=(
                    "vendor and wrapper timeout in seconds (1-300; default: 30)"
                    if name == "interact"
                    else "wrapper subprocess timeout in seconds (default: 120)"
                ),
            )
        if name not in {"raw", "budget", "capabilities"}:
            p.add_argument(
                "--full", action="store_true",
                help="request full text and lift the 24576-character body bound",
            )
            p.add_argument(
                "-o", "--output", help="write the response envelope to this path"
            )
        return p

    def schema(p):
        group = p.add_mutually_exclusive_group()
        group.add_argument(
            "--schema", help="inline JSON schema for structured extraction"
        )
        group.add_argument(
            "--schema-file", help="path to JSON schema for structured extraction"
        )

    for name in ("fetch", "extract"):
        p = verb(
            name,
            "Parse a local file or scrape a URL"
            if name == "fetch"
            else "Fetch with a required schema or question",
            "scrape" if name == "fetch" else "json_extraction",
        )
        p.add_argument(
            "target", metavar="path|url", nargs="+" if name == "fetch" else None
        )
        p.add_argument(
            "--vendor-timeout", type=int,
            help="vendor parse timeout in milliseconds (local files only)",
        )
        p.add_argument(
            "--max-age", type=int, metavar="MS",
            help="accept indexed content up to MS milliseconds old; 0 forces a live fetch (URLs only)",
        )
        p.add_argument(
            "--format", metavar="LIST",
            help="comma-separated vendor formats replacing the default summary: "
            + ", ".join(SCRAPE_FORMATS) + " (json needs --schema or --schema-file)",
        )
        p.epilog = (
            "Injection check " + INJECTION_CHECK + ". Firecrawl may serve recently "
            "indexed content instead of refetching; --max-age 0 forces a live fetch "
            "and a small --max-age bounds staleness. URLs with summary, markdown, "
            "links, or html formats, a schema alone, or a question alone, and PDFs to "
            "summary or markdown, go keyless first and spend no credits; interact "
            "runs keyed, so refetch with FIRECRAWL_CLI_KEYLESS=0 before interact."
        )
        schema(p)
        p.add_argument("-Q", "--query", help="question about the content; answer in data.answer")
    p = verb("shot", "Capture a URL screenshot", "screenshot")
    p.add_argument("target", metavar="url", nargs="+")
    p = verb("act", "Scrape a URL after running browser actions", "scrape")
    p.add_argument("target", metavar="url", nargs="+")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--actions", help="inline JSON actions array")
    group.add_argument("--actions-file", help="path to JSON actions array")
    p = verb(
        "agent",
        "Try cheaper fetch --schema first. Run an extractor prompt or inspect a job ID; "
        "vendor default cap: 2,500 credits. Use --max-credits under your budget.",
        "agent",
    )
    p.add_argument("target", metavar="prompt|job-id")
    schema(p)
    p.add_argument("--status", action="store_true", help="check job status")
    p.add_argument("--wait", action="store_true", help="wait for job completion")
    p.add_argument("--cancel", action="store_true", help="cancel an active job ID")
    p.add_argument("--model", help="vendor model name (Spark 1 names route to spark-2)")
    p.add_argument("--max-credits", type=int, help="vendor maximum credits for the job")
    p = verb(
        "interact",
        "Send an explicit text prompt, or stop a browser session",
        "interact_per_minute",
    )
    p.epilog = (
        "Try cheaper fetch --schema first. Sessions expire after 10 minutes or 5 idle "
        "minutes; expiry is accepted cleanup, or use stop --scrape-id <id>. "
        "Each --timeout is 1-300 seconds (default 30); minimum one browser-minute: "
        "7 credits with a prompt, 2 code-only. Code consent is per call, never persisted."
    )
    p.add_argument("target", metavar="text|stop", nargs="?")
    p.add_argument("-c", "--code", help="code to execute; needs --allow-code-exec --reason <text>")
    runtimes = p.add_mutually_exclusive_group()
    for runtime in ("node", "python", "bash"):
        runtimes.add_argument("--" + runtime, action="store_true", help="execute code as " + runtime)
    p.add_argument(
        "--scrape-id", help="required explicit scrape session ID from fetch"
    )
    p.add_argument(
        "--allow-code-exec",
        action="store_true",
        help="allow code execution for this invocation only; also requires --reason",
    )
    p = verb("search", "Search the web", "search")
    p.add_argument("target", metavar="query")
    p.add_argument("--limit", type=int, help="maximum results (1-100)")
    p.add_argument(
        "--categories", metavar="LIST",
        help="comma-separated: " + ", ".join(SEARCH_CATEGORIES)
        + " (developer is answered by the API directly and needs FIRECRAWL_API_KEY; "
        "the developer verb is the keyless, filtered path)",
    )
    p.add_argument(
        "--sources", metavar="LIST",
        help="comma-separated: " + ", ".join(SEARCH_SOURCES) + " (vendor default: web)",
    )
    p.add_argument(
        "--tbs", metavar="QDR",
        help="time bound: " + ", ".join(TBS_VALUES) + " (hour, day, week, month, year)",
    )
    p.add_argument(
        "--location", metavar="PLACE",
        help='geo-target the search, for example "Germany" or '
        '"San Francisco,California,United States" (--country is raw-only)',
    )
    p.epilog = (
        "Operators: " + SEARCH_OPERATORS + ". Results are titles, URLs, and "
        "descriptions; fetch a chosen URL for its content. The envelope's search_id "
        "feeds raw -- search-feedback <id> when a result is wrong. Web or images "
        "sources, github or research categories, and --limit 10 or less go keyless "
        "first and spend no credits."
    )
    p = verb(
        "gov",
        "Search US federal, state, and local law: statutes, regulations, codes, "
        "court opinions, and agency publications (free, keyless)",
        "free",
    )
    p.add_argument("target", metavar="query")
    p.add_argument("--limit", type=int, help="maximum results (1-100; API default 10)")
    p.add_argument(
        "--jurisdiction", metavar="CODE",
        help="us for federal, or us- plus a two-letter state or territory code, "
        "for example us-ca or us-dc",
    )
    p.add_argument(
        "--court", metavar="ID",
        help="one CourtListener court id, for example scotus, ca9, or nysd",
    )
    p.add_argument(
        "--court-type", metavar="TYPE", help="one of: " + ", ".join(GOV_COURT_TYPES)
    )
    p.add_argument(
        "--cites", metavar="CITATION",
        help='pages citing a printed citation ("42 U.S.C. § 1983", "5 U.S. 137") '
        "or a citation id (us:usc:42:1983)",
    )
    p.add_argument("--domain", metavar="HOST", help="one site, for example irs.gov")
    p.epilog = (
        "Answered by POST /v2/search/gov directly: no vendor binary, no key, no "
        "credits, no ledger reservation. Filters combine with AND and keep only "
        "pages the index has labeled, so no results does not mean none exist. US "
        "material only; results can be historical versions, bill text, or "
        "third-party copies: verify issuer, jurisdiction, and effective status, and "
        "fetch the source URL before citing. Not legal advice."
    )
    p = verb(
        "developer",
        "Search the Developer Index: GitHub issues, merged PRs, READMEs, and "
        "curated docs, with matched passages (keyless first; 2 credits per 10 "
        "results when it runs keyed)",
        "search",
    )
    p.add_argument("target", metavar="query")
    p.add_argument("--limit", type=int, help="maximum results (1-100; API default 10)")
    p.add_argument(
        "--types", metavar="LIST",
        help="comma-separated subset of " + ", ".join(DEVELOPER_TYPES)
        + " (default: all four)",
    )
    p.add_argument(
        "--repos", metavar="LIST",
        help="comma-separated owner/name slugs; scopes issue, pull_request, and readme results",
    )
    p.add_argument(
        "--sources", metavar="LIST",
        help=f"comma-separated documentation source ids (at most {DEVELOPER_SOURCES_MAX}); "
        "scopes doc results",
    )
    p.add_argument(
        "--skills-only", action="store_true",
        help="search only indexed agent-skill files",
    )
    p.add_argument(
        "--passages", type=int, metavar="N",
        help=f"matched passages per result (1-{DEVELOPER_PASSAGES_MAX}; API default 1)",
    )
    p.add_argument("--language", metavar="NAME", help="repository language, for example Rust")
    p.add_argument("--topic", metavar="NAME", help="repository topic, for example async")
    p.add_argument("--license", metavar="NAME", help="repository license, for example MIT")
    p.add_argument("--min-stars", type=int, metavar="N", help="minimum repository stars")
    p.add_argument("--max-stars", type=int, metavar="N", help="maximum repository stars")
    p.add_argument("--archived", metavar="true|false", help="include archived repositories")
    p.add_argument("--fork", metavar="true|false", help="include forks")
    p.epilog = (
        "Answered by POST /v2/search/developer directly: no vendor binary needed. "
        "Without FIRECRAWL_API_KEY the call is free and outside the ledger at any "
        "--limit; with the key, --limit 10 or less still tries keyless first, and a "
        "keyed run costs 2 credits per 10 results, rounded up, reserved and read like "
        "search. Repository filters (--language, --topic, --license, stars, "
        "--archived, --fork) without --sources return no doc results by design. "
        "Results carry doc:, issue:, pull_request:, and readme: ids with markdown "
        "passages; with no --types they can also carry web: pages (forum threads, "
        "blogs, docs mirrors). coverage, when the API sends it, says why a type is missing."
    )
    p = verb("map", "Discover URLs on a site", "map")
    p.add_argument("target", metavar="url")
    p.add_argument("--limit", type=int, help="maximum URLs")
    p = verb(
        "raw",
        "True vendor passthrough; charged the reported creditsUsed of finished work, "
        "else holds the bounded-crawl reservation until it settles; vendor --json for "
        "research and search, not crawl or monitor",
        "raw-unknown",
    )
    p.add_argument("--allow-code-exec", action="store_true", help="per-call interact code consent; also needs --reason")
    p.add_argument("vendor_args", nargs=argparse.REMAINDER, metavar="-- vendor-args")
    p.epilog = (
        "Writes are reported using a best-effort, non-exclusive "
        "working-directory snapshot. raw -- research search-papers and "
        "search-github go keyless first, outside the ledger."
    )
    verb(
        "capabilities",
        "Show this live command contract without vendor contact",
        "offline",
    )
    p = verb("budget", "Show budget availability without vendor contact", "offline")
    return parser, registry


def flags(parser):
    return {
        flag: action for action in parser._actions for flag in action.option_strings
    }


def one_edit(a, b):
    """One insertion, deletion, substitution, or adjacent transposition (AE7)."""
    if abs(len(a) - len(b)) > 1 or a == b:
        return False
    if len(a) == len(b):
        indexes = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
        return len(indexes) == 1 or (
            len(indexes) == 2
            and indexes[1] == indexes[0] + 1
            and a[indexes[0]] == b[indexes[1]]
            and a[indexes[1]] == b[indexes[0]]
        )
    short, long = (a, b) if len(a) < len(b) else (b, a)
    return any(long[:i] + long[i + 1 :] == short for i in range(len(long)))


def normalize(argv, parser, registry):
    """Correct only option tokens, never their values or raw vendor arguments."""
    result = list(argv)
    top_level = flags(parser)
    options = top_level
    verb = None
    i = 0
    while i < len(result):
        token = result[i]
        if token == "--":
            break
        if verb is None and not token.startswith("-"):
            if token in {"scrape", "parse"}:
                print(
                    f"warning: {token} is fetch here; use firecrawl-cli fetch <path|url>",
                    file=sys.stderr,
                )
                result[i] = token = "fetch"
            if token not in registry:
                if token in {"crawl", "monitor"}:
                    # Vendor crawl and monitor print JSON by default and reject
                    # --json, so it stays on the wrapper side of the separator.
                    wrapper_flags = [arg for arg in result[:i] if arg != "--json"]
                    if "--json" in result:
                        wrapper_flags.append("--json")
                    raise CliError(
                        f"{token} is raw-only; credits scale with work",
                        shlex.join([
                            "firecrawl-cli", "raw", *wrapper_flags, "--",
                            *(arg for arg in result[i:] if arg != "--json"),
                        ]),
                    )
                if Path(token).exists() or is_url(token):
                    result.insert(i, "fetch")
                    print(
                        "warning: inferred fetch; use firecrawl-cli fetch <path|url>",
                        file=sys.stderr,
                    )
                    token = "fetch"
                else:
                    raise CliError(
                        f"unknown verb {token!r}", "firecrawl-cli capabilities --json"
                    )
            verb = token
            options = {**top_level, **flags(registry[verb]["parser"])}
            if verb == "raw":
                # Only --json before the separator belongs to the wrapper.
                return result
            i += 1
            continue
        if token.startswith("-"):
            name, sep, value = token.partition("=")
            if name not in options:
                candidates = sorted(
                    f for f in options.keys() | PROTECTED_FLAGS if one_edit(name, f)
                )
                if len(candidates) == 1:
                    intended = candidates[0]
                    corrected = result.copy()
                    corrected[i] = intended + (sep + value if sep else "")
                    if intended in PROTECTED_FLAGS:
                        raise CliError(
                            f"refusing typo {name!r}; intended flag {intended}",
                            shlex.join(["firecrawl-cli", *corrected]),
                        )
                    print(redact(f"warning: corrected {name} to {intended}"), file=sys.stderr)
                    result[i] = corrected[i]
                    name = intended
            action = options.get(name)
            if action is not None and action.nargs != 0 and not sep:
                i += 1  # A value that looks like a flag is never rewritten.
        i += 1
    return result


def is_url(value):
    try:
        parsed = urlsplit(value)
        return parsed.scheme in {"http", "https"} and bool(parsed.hostname)
    except ValueError:
        return False


def validate_json(value, filename, expected, label):
    if value is None and filename is None:
        return
    try:
        content = Path(filename).read_text(encoding="utf-8") if filename else value
        parsed = json.loads(content)
        if not isinstance(parsed, expected):
            raise ValueError(f"expected {expected.__name__}")
    except (OSError, ValueError) as exc:
        raise CliError(
            f"invalid {label}: {exc}",
            f"firecrawl-cli {'act' if label == 'actions' else 'fetch'} --help",
        ) from None


def raw_subcommand(raw):
    """The first bare token after the vendor's global options and their values.

    A value flag or a stray "--" ahead of the subcommand never hides it (review
    2026-09-13); a bare word after the subcommand is positional data, never a
    second command.
    """
    index = 0
    while index < len(raw):
        token = raw[index]
        name, sep, _ = token.partition("=")
        if token == "--":
            index += 1
        elif token.startswith("-"):
            index += 2 if name in RAW_VALUE_FLAGS and not sep else 1
        else:
            return token
    return None


def raw_arguments(args, parser, registry):
    raw = list(args.vendor_args)
    if raw and raw[0] == "--":
        raw.pop(0)
    if not raw:
        raise CliError(
            "raw needs vendor arguments",
            "firecrawl-cli raw -- scrape https://example.com --json",
        )
    # Inspect before typo diagnostics so a credential value cannot be echoed.
    if raw_subcommand(raw) in ACCOUNT_COMMANDS or any(
        token.split("=", 1)[0] in CREDENTIAL_FLAGS or token.startswith("-k")
        for token in raw
    ):
        raise CliError(
            "raw refuses account administration and flags that expose or redirect the credential",
            "firecrawl --status",
        )
    known = set(flags(parser)) | PROTECTED_FLAGS
    for entry in registry.values():
        known.update(flags(entry["parser"]))
    for token in raw:
        name = token.split("=", 1)[0]
        if name.startswith("-") and name not in known:
            candidates = sorted(f for f in known if one_edit(name, f))
            if len(candidates) == 1:
                raise CliError(
                    f"raw never corrects arguments; intended flag {candidates[0]}",
                    shlex.join(
                        [
                            "firecrawl-cli",
                            "raw",
                            "--",
                            *[
                                candidates[0] + arg[len(name) :]
                                if arg == token
                                else arg
                                for arg in raw
                            ],
                        ]
                    ),
                )
    return raw


def prepare_interact(args):
    """KTD6/KTD7: parse per-call consent, audit it, and require explicit IDs."""
    if args.verb == "interact":
        code_mode = args.target != "stop" and (args.code is not None or any(
            getattr(args, runtime) for runtime in ("node", "python", "bash")
        ))
    elif args.verb == "raw":
        raw = list(args.vendor_args)
        if raw and raw[0] == "--":
            raw.pop(0)
        value_flags = RAW_VALUE_FLAGS
        # interact anywhere in the vendor arguments gates the call: vendor global
        # options, their values, and stray "--" tokens ahead of it never hide it.
        if "interact" not in raw:
            return
        clean = []
        code_mode = False
        args.scrape_id = None
        i = 0
        while i < len(raw):
            token = raw[i]
            name, sep, value = token.partition("=")
            if token == "--":
                clean.append(token)
                i += 1
                continue
            if name == "--allow-code-exec" and not sep:
                args.allow_code_exec = True
                i += 1
                continue
            if name in value_flags:
                pair = [token]
                if not sep and i + 1 < len(raw):
                    i += 1
                    value = raw[i]
                    pair.append(value)
                if name == "--reason":
                    args.reason = value
                else:
                    clean.extend(pair)
                if name in {"--scrape-id", "-s"}:
                    args.scrape_id = value
                if name in {"--code", "-c"}:
                    code_mode = True
            else:
                clean.append(token)
                if name in {"--node", "--python", "--bash"} or (
                    token.startswith("-c") and not token.startswith("--")
                ):
                    code_mode = True
                if token.startswith("-s") and not token.startswith("--") and len(token) > 2:
                    args.scrape_id = token[2:]
            i += 1
        args.vendor_args = clean
    else:
        return
    if code_mode:
        granted = bool(args.allow_code_exec and args.reason and args.reason.strip())
        BUDGET.code_attempt(granted, args.reason, args.scrape_id)
        if not granted:
            raise CliError(
                "code mode requires --allow-code-exec and --reason <text> on the same invocation",
                "firecrawl-cli interact 'Describe the page' --scrape-id <id> --json",
                5,
            )
    if not args.scrape_id or not args.scrape_id.strip():
        raise CliError(
            "run a fetch first, then pass --scrape-id <id>",
            "firecrawl-cli interact 'Describe the page' --scrape-id <id> --json",
        )


def vendor_arguments(args, parser, registry):
    """KTD2/KTD13: translate one validated target to official v1.19.26 argv."""
    verb = args.verb
    if verb == "raw":
        return "raw", raw_arguments(args, parser, registry)
    target = args.target
    if verb in API_DIRECT_VERBS:
        if not target.strip():
            raise CliError("query must not be empty", f"firecrawl-cli {verb} --help")
        # Validate every filter and the API base before any ledger or network contact.
        api_body(args)
        api_base()
        return verb, [verb, target]
    if verb in {"fetch", "extract"}:
        if verb == "extract" and not (args.schema or args.schema_file or args.query):
            raise CliError(
                "extract requires a schema or prompt",
                f"firecrawl-cli extract {shlex.quote(target)} -Q 'Describe the fields' --json",
            )
        local = Path(target).is_file()
        if not local and not is_url(target):
            raise CliError(
                f"not an existing file or HTTP(S) URL: {target}",
                "firecrawl-cli fetch ./report.pdf --json",
            )
        surface = "parse" if local else "scrape"
        if local:
            path = Path(target)
            if path.suffix.lower() not in PARSE_EXTENSIONS:
                alternative = (
                    "read it locally" if path.suffix.lower() in {".txt", ".md"}
                    else "convert it to PDF or HTML before parsing"
                )
                raise CliError(
                    f"unsupported parse extension {path.suffix or '(none)'}; {alternative}",
                    alternative,
                )
            size = path.stat().st_size
            if size > 50 * 1024 * 1024:
                raise CliError(
                    f"parse input is {size / (1024 * 1024):g} MB ({size} bytes); maximum is 50 MB; split it into smaller files",
                    "split the PDF or document into files under 50 MB",
                )
            target = str(path.resolve())
        if local and (args.schema or args.schema_file):
            raise CliError(
                "vendor parse does not support schema flags; use a question",
                f"firecrawl-cli fetch {shlex.quote(target)} -Q 'Extract the fields' --json",
            )
        command = [surface, target]
        if (args.schema or args.schema_file) and not args.format:
            command.extend(["--format", "json"])
    elif verb in {"shot", "act", "map"}:
        if not is_url(target):
            raise CliError(
                f"{verb} needs an HTTP(S) URL", f"firecrawl-cli {verb} --help"
            )
        surface = "map" if verb == "map" else "scrape"
        command = [surface, target]
        if verb == "shot":
            command.append("--screenshot")
    elif verb == "interact":
        surface = "interact"
        if not 1 <= args.timeout <= 300:
            raise CliError("interact --timeout must be 1-300 seconds", "firecrawl-cli interact --help")
        if target == "stop":
            if args.code is not None or any(
                getattr(args, runtime) for runtime in ("node", "python", "bash")
            ):
                raise CliError(
                    "stop does not accept code or a runtime flag",
                    "firecrawl-cli interact stop --scrape-id <id>",
                )
            # -s belongs to the parent; also give stop its own positional ID so
            # cleanup never depends on inheritance or the vendor's last-scrape file.
            command = [surface, "-s", args.scrape_id, "stop", args.scrape_id]
        else:
            if target is None and args.code is None:
                raise CliError("interact needs a prompt or --code", "firecrawl-cli interact --help")
            if args.code is None and any(
                getattr(args, runtime) for runtime in ("node", "python", "bash")
            ):
                raise CliError("code runtime flags require --code", "firecrawl-cli interact --help")
            command = [surface]
            if target is not None:
                command.extend(["--prompt", target])
            if args.code is not None:
                command.extend(["-c", args.code])
                command.extend(
                    "--" + runtime for runtime in ("node", "python", "bash")
                    if getattr(args, runtime)
                )
            command.extend(["-s", args.scrape_id, "--timeout", f"{args.timeout:g}"])
    else:
        surface = verb
        command = [surface, target]
    validate_json(
        getattr(args, "schema", None),
        getattr(args, "schema_file", None),
        dict,
        "schema",
    )
    validate_json(
        getattr(args, "actions", None),
        getattr(args, "actions_file", None),
        list,
        "actions",
    )
    if surface in {"scrape", "parse"}:
        command.append("--only-main-content")
        formats = requested_formats(args, surface)
        if formats:
            if (
                getattr(args, "schema", None) or getattr(args, "schema_file", None)
            ) and "json" not in formats:
                formats.append("json")
            command.extend(["--format", ",".join(formats)])
        elif verb != "shot" and not any(
            getattr(args, key, None) for key in ("schema", "schema_file", "query")
        ):
            # Prefer a server-side summary before bounding returned body text.
            command.extend(["--format", "markdown" if args.full else "summary"])
        max_age = getattr(args, "max_age", None)
        if max_age is not None:
            if surface != "scrape" or max_age < 0:
                raise CliError(
                    "--max-age must be zero or more milliseconds and applies to URL targets only",
                    "firecrawl-cli fetch https://example.com --max-age 0 --json",
                )
            command.extend(["--max-age", str(max_age)])
    vendor_timeout = getattr(args, "vendor_timeout", None)
    if vendor_timeout is not None:
        if surface != "parse" or vendor_timeout <= 0:
            raise CliError(
                "--vendor-timeout must be positive and is supported only for local parse inputs",
                "firecrawl-cli fetch ./report.pdf --vendor-timeout 30000 --timeout 60 --json",
            )
        command.extend(["--timeout", str(vendor_timeout)])
    for name in (
        "schema",
        "schema_file",
        "query",
        "actions",
        "actions_file",
        "limit",
        "max_credits",
        "model",
    ):
        value = getattr(args, name, None)
        if value is not None:
            if name in {"schema_file", "actions_file"}:
                value = str(Path(value).resolve())
            if name in {"limit", "max_credits"} and (
                value < 1 or (verb == "search" and name == "limit" and value > 100)
            ):
                raise CliError(
                    f"invalid --{name.replace('_', '-')}: {value}",
                    f"firecrawl-cli {verb} --help",
                )
            command.extend(["--" + name.replace("_", "-"), str(value)])
    for name in ("status", "wait", "cancel"):
        if getattr(args, name, False):
            command.append("--" + name)
    if verb == "search":
        filters = search_filters(args)
        for name in ("categories", "sources", "tbs"):
            if filters[name]:
                command.extend(["--" + name, ",".join(filters[name])])
        if args.location:
            command.extend(["--location", args.location])
        if API_ONLY_CATEGORIES & set(filters["categories"]):
            api_preflight(args)  # Refuse before any credit read or reservation.
    return surface, [*command, "--json"]


def requested_formats(args, surface):
    """Validate --format against the vendor's list for this surface (KTD2)."""
    raw = getattr(args, "format", None)
    if raw is None:
        return []
    allowed = SCRAPE_FORMATS if surface == "scrape" else PARSE_FORMATS
    formats = [item.strip() for item in raw.split(",")]
    unknown = [item for item in formats if item not in allowed]
    if unknown or len(set(formats)) != len(formats):
        raise CliError(
            f"invalid --format {raw!r}; {surface} formats: {', '.join(allowed)}",
            f"firecrawl-cli {args.verb} --help",
        )
    if "json" in formats and not (
        getattr(args, "schema", None) or getattr(args, "schema_file", None)
    ):
        raise CliError(
            "--format json needs --schema or --schema-file",
            "firecrawl-cli extract <target> --schema '{\"type\": \"object\"}' --json",
        )
    return formats


def search_filters(args):
    """Validate the shaped search filters against the vendor's documented values."""
    filters = {}
    for name, allowed in (("categories", SEARCH_CATEGORIES), ("sources", SEARCH_SOURCES)):
        raw = getattr(args, name, None)
        values = [item.strip() for item in raw.split(",")] if raw is not None else []
        unknown = [item for item in values if item not in allowed]
        if unknown or len(set(values)) != len(values):
            raise CliError(
                f"invalid --{name} {raw!r}; valid {name}: {', '.join(allowed)}",
                "firecrawl-cli search --help",
            )
        filters[name] = values
    tbs = getattr(args, "tbs", None)
    if tbs is not None and tbs not in TBS_VALUES:
        raise CliError(
            f"invalid --tbs {tbs!r}; valid values: {', '.join(TBS_VALUES)}",
            "firecrawl-cli search --help",
        )
    filters["tbs"] = [tbs] if tbs else []
    return filters


def uses_api(args):
    """API-direct verbs and a search naming an API-only category leave the vendor CLI."""
    if args.verb in API_DIRECT_VERBS:
        return True
    return args.verb == "search" and bool(
        API_ONLY_CATEGORIES & set(search_filters(args)["categories"])
    )


def api_billed(args):
    """Which API-direct calls touch the ledger: search (always keyed) and
    developer with a key. gov is free, and keyless developer runs on Firecrawl's
    keyless allowance with nothing to reserve or read."""
    if args.verb == "gov":
        return False
    if args.verb == "developer":
        return bool(os.environ.get("FIRECRAWL_API_KEY"))
    return True


def api_path(args):
    return API_DIRECT_VERBS.get(args.verb, "/v2/search")


def api_body(args):
    if args.verb == "gov":
        return gov_body(args)
    if args.verb == "developer":
        return developer_body(args)
    return search_body(args)


def text_filter(args, flag, verb):
    """A free-text filter: forwarded as given, but never blank."""
    value = getattr(args, flag.lstrip("-").replace("-", "_"), None)
    if value is None:
        return None
    if not value.strip():
        raise CliError(f"{flag} must not be empty", f"firecrawl-cli {verb} --help")
    return value.strip()


def bounded_int(args, flag, verb, low, high):
    value = getattr(args, flag.lstrip("-").replace("-", "_"), None)
    if value is not None and not low <= value <= high:
        raise CliError(
            f"invalid {flag}: {value} (must be {low}-{high})",
            f"firecrawl-cli {verb} --help",
        )
    return value


def comma_list(args, flag, verb):
    raw = getattr(args, flag.lstrip("-"), None)
    if raw is None:
        return None
    values = [item.strip() for item in raw.split(",")]
    if any(not item for item in values) or len(set(values)) != len(values):
        raise CliError(
            f"invalid {flag} {raw!r}; comma-separated, no blanks, no repeats",
            f"firecrawl-cli {verb} --help",
        )
    return values


def gov_body(args):
    """Validate the shaped Government Index filters client-side and name them as
    the API does. Court ids and citations are free text the API validates; its
    400 text surfaces in error.message."""
    body = {"query": args.target}
    limit = bounded_int(args, "--limit", "gov", 1, 100)
    if limit is not None:
        body["k"] = limit  # /v2/search/gov rejects limit: "Unrecognized key".
    jurisdiction = text_filter(args, "--jurisdiction", "gov")
    if jurisdiction is not None:
        code = jurisdiction.lower()
        if not re.fullmatch(r"us(-[a-z]{2})?", code):
            raise CliError(
                f"invalid --jurisdiction {jurisdiction!r}; use us for federal, or us- "
                "plus a two-letter state or territory code such as us-ca",
                "firecrawl-cli gov --help",
            )
        body["jurisdiction"] = code
    court_type = text_filter(args, "--court-type", "gov")
    if court_type is not None:
        if court_type not in GOV_COURT_TYPES:
            raise CliError(
                f"invalid --court-type {court_type!r}; valid court types: "
                + ", ".join(GOV_COURT_TYPES),
                "firecrawl-cli gov --help",
            )
        body["courtType"] = court_type
    for flag in ("--court", "--cites", "--domain"):
        value = text_filter(args, flag, "gov")
        if value is not None:
            body[GOV_FILTERS[flag]] = value
    return body


def developer_body(args):
    """Validate the shaped Developer Index filters client-side and name them as
    the API does. Repo slugs and source ids are free text the API validates."""
    body = {"query": args.target}
    limit = bounded_int(args, "--limit", "developer", 1, 100)
    if limit is not None:
        body["k"] = limit
    types = comma_list(args, "--types", "developer")
    if types is not None:
        unknown = [item for item in types if item not in DEVELOPER_TYPES]
        if unknown:
            raise CliError(
                f"invalid --types {args.types!r}; valid types: " + ", ".join(DEVELOPER_TYPES),
                "firecrawl-cli developer --help",
            )
        body["types"] = types
    repos = comma_list(args, "--repos", "developer")
    if repos is not None:
        body["repos"] = repos
    sources = comma_list(args, "--sources", "developer")
    if sources is not None:
        if len(sources) > DEVELOPER_SOURCES_MAX or any(
            len(item) > DEVELOPER_SOURCE_CHARS for item in sources
        ):
            raise CliError(
                f"--sources takes at most {DEVELOPER_SOURCES_MAX} ids of up to "
                f"{DEVELOPER_SOURCE_CHARS} characters each",
                "firecrawl-cli developer --help",
            )
        body["sources"] = sources
    if args.skills_only:
        body["skills"] = "only"
    passages = bounded_int(args, "--passages", "developer", 1, DEVELOPER_PASSAGES_MAX)
    if passages is not None:
        body["passages"] = passages
    for flag in ("--language", "--topic", "--license"):
        value = text_filter(args, flag, "developer")
        if value is not None:
            body[DEVELOPER_FILTERS[flag]] = value
    for flag in ("--min-stars", "--max-stars"):
        value = getattr(args, flag.lstrip("-").replace("-", "_"))
        if value is not None:
            if value < 0:
                raise CliError(
                    f"invalid {flag}: {value} (must be 0 or more)",
                    "firecrawl-cli developer --help",
                )
            body[DEVELOPER_FILTERS[flag]] = value
    if (
        body.get("min_stars") is not None and body.get("max_stars") is not None
        and body["min_stars"] > body["max_stars"]
    ):
        raise CliError("--min-stars exceeds --max-stars", "firecrawl-cli developer --help")
    for flag in ("--archived", "--fork"):
        value = getattr(args, flag.lstrip("-"))
        if value is not None:
            lowered = value.strip().lower()
            if lowered not in {"true", "false"}:
                raise CliError(
                    f"invalid {flag} {value!r}; use true or false",
                    "firecrawl-cli developer --help",
                )
            body[DEVELOPER_FILTERS[flag]] = lowered == "true"
    return body


def search_body(args):
    filters = search_filters(args)
    body = {"query": args.target}
    if args.limit is not None:
        body["limit"] = args.limit
    if filters["categories"]:
        body["categories"] = filters["categories"]
    if filters["sources"]:
        body["sources"] = [{"type": source} for source in filters["sources"]]
    if filters["tbs"]:
        body["tbs"] = filters["tbs"][0]
    if args.location:
        body["location"] = args.location
    return body


def api_base():
    """FIRECRAWL_API_URL is the vendor's own override. The wrapper honors it only
    over https, or plain http to a loopback host for tests, so an inherited
    variable can never route the key to an arbitrary host."""
    base = os.environ.get("FIRECRAWL_API_URL") or DEFAULT_API_BASE
    parsed = urlsplit(base)
    plain_http_elsewhere = parsed.scheme == "http" and parsed.hostname not in LOOPBACK_HOSTS
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or plain_http_elsewhere:
        raise CliError(
            f"FIRECRAWL_API_URL={redact(base)!r} must be an https URL, or http to a loopback host",
            "unset FIRECRAWL_API_URL, or point it at https://api.firecrawl.dev",
        )
    return base.rstrip("/")


def api_preflight(args):
    """The developer category bypasses the vendor CLI; refuse before any spend."""
    if not os.environ.get("FIRECRAWL_API_KEY"):
        raise CliError(
            "search --categories developer is answered by the API directly (vendor CLI "
            "1.19.26 rejects the category; firecrawl/cli#222) and needs "
            "FIRECRAWL_API_KEY in the environment; the developer verb is the keyless, "
            "filtered path",
            shlex.join(["firecrawl-cli", "developer", args.target, "--json"]),
        )
    api_base()


def invoke_api(path, body, command, timeout, retry, keyless=False):
    """POST one API path the vendor CLI cannot answer here; same envelope,
    failure shapes, and redaction as the subprocess path. The key is sent only
    when the environment holds one and the call is not keyless; the API-direct
    verbs work without it."""
    key = None if keyless else os.environ.get("FIRECRAWL_API_KEY")
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "firecrawl-cli/" + VERSION,
    }
    if key:
        SECRETS.add(key)
        headers["Authorization"] = "Bearer " + key
    timing = f"wrapper --timeout={timeout:g} s; transport=api"
    request = urllib.request.Request(
        api_base() + path,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        try:
            response = NO_REDIRECTS.open(request, timeout=timeout)
        except urllib.error.HTTPError as exc:
            response = exc  # An error response is still a response to read.
        try:
            status, headers = response.code, response.headers
            text = response.read().decode("utf-8", errors="replace")
        finally:
            response.close()
    except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
        reason = getattr(exc, "reason", exc)
        if isinstance(reason, (socket.timeout, TimeoutError)):
            raise CliError(
                f"wrapper request timeout ({timing})",
                "increase wrapper --timeout or reduce the work", 1,
            ) from None
        raise CliError(
            f"could not reach the Firecrawl API ({timing}): {redact(str(reason))}",
            "check network access, then retry: " + retry, 2,
        ) from None
    if 300 <= status < 400:
        location = headers.get("Location") if headers else None
        raise CliError(
            f"the Firecrawl API answered with a redirect (HTTP {status}); the wrapper "
            "never follows one, so the key cannot travel to another host"
            + (f": {redact(location)}" if location else ""),
            "point FIRECRAWL_API_URL at the API's final address, or unset it for "
            + DEFAULT_API_BASE, 1,
        )
    detail = ""
    if status >= 400:
        detail = f"HTTP {status}"
        retry_after = headers.get("Retry-After") if headers else None
        if retry_after:
            detail += f"\nRetry-After: {retry_after}"
    try:
        payload = json.loads(text)
    except ValueError:
        payload = None
    if payload is None or status >= 400 or not item_succeeded(payload):
        record = payload if isinstance(payload, dict) else {"error": text.strip()[:500]}
        error = vendor_failure(
            command, record, detail, timing, retry,
            malformed=payload is None and status < 400,
        )
        if status == 400 and command[0] in API_DIRECT_VERBS:
            # The API named the bad filter value; the fix is a flag, not account state.
            error.next_action = (
                f"fix the filter the API named; flags: firecrawl-cli {command[0]} --help"
            )
        raise error
    return redact(payload), []


def capabilities(registry):
    verbs = {}
    for name, entry in registry.items():
        verbs[name] = {
            "flags": sorted(flags(entry["parser"])),
            "cost_class": entry["cost_class"],
        }
    verbs["fetch"]["cost_classes"] = ["scrape", "parse", "json_extraction"]
    constants = budget_constants()
    return {
        "version": VERSION,
        "verbs": verbs,
        "exit_codes": EXIT_CODES,
        "injection_check": INJECTION_CHECK,
        "budget": constants,
        "parse_extensions": sorted(PARSE_EXTENSIONS),
        "search_categories": list(SEARCH_CATEGORIES),
        "api_only_categories": sorted(API_ONLY_CATEGORIES),
        "api_direct_verbs": list(API_DIRECT_VERBS),
        "api_direct_paths": dict(API_DIRECT_VERBS),
        "gov_filters": dict(GOV_FILTERS),
        "gov_court_types": list(GOV_COURT_TYPES),
        "developer_filters": dict(DEVELOPER_FILTERS),
        "developer_types": list(DEVELOPER_TYPES),
        "search_sources": list(SEARCH_SOURCES),
        "search_tbs": list(TBS_VALUES),
        "search_operators": SEARCH_OPERATORS,
        "fetch_formats": {"scrape": list(SCRAPE_FORMATS), "parse": list(PARSE_FORMATS)},
        "budget_environment": {
            key: "FIRECRAWL_CLI_" + key.upper() for key in BUDGET_DEFAULTS
        },
        "limits": {
            "targets_per_call": 1,
            "multi_url_verbs": ["fetch", "shot", "act"],
            "body_chars": BODY_LIMIT,
            "parse_max_upload_mb": 50,
            "search_max_results": 100,
            "session_budget": constants["session_budget"],
            "code_mode_available": True,
        },
        "warnings": [
            "raw is true passthrough; add vendor --json for research and search; vendor crawl and monitor print JSON by default and reject --json; cost is unknown",
            "monitor and crawl are raw-only; credits scale with work",
            "raw reserves at least the bounded crawl cost; a reported creditsUsed for finished work (job status completed, failed or cancelled, or no job status) replaces the hold and settles as reported; every other raw hold settles into spent credits in full after settle_window",
            "raises increase the session (or unattended day) bucket within a cumulative daily bound",
            "error.code is the wrapper exit code as an integer unless a vendor failure shape matched, then its snake_case tag",
            "search --categories developer is answered by the API directly and needs FIRECRAWL_API_KEY in the environment; every other category goes through the vendor CLI; the developer verb is the keyless, filtered path with passages",
            "search envelopes carry search_id; raw -- search-feedback <id> reports a wrong result",
            "fetch --max-age 0 forces a live fetch; Firecrawl may otherwise serve recently indexed content",
            "search --country has no shaped equivalent; it is raw -- search <q> --country DE --json",
            "gov and developer are API-direct (POST /v2/search/gov and /v2/search/developer): no vendor binary, no key needed; gov is free with no credit read or reservation; developer without FIRECRAWL_API_KEY is keyless at any limit and runs outside the ledger with a degraded note; with the key, limit 10 or less goes keyless first, and a keyed run costs 2 credits per 10 results",
            "free-first (#2118): with or without FIRECRAWL_API_KEY, an eligible call tries Firecrawl's free keyless tier first, spends no credits, and carries a degraded note starting 'keyless: ' that never wraps plain output (developer keeps its 'keyless developer search:' note, which wraps plain output as it always has). Eligible: fetch or extract of a URL to summary, markdown, links, or html, a schema alone, or a question alone; shot; a PDF to summary or markdown; search over web or images sources and github or research categories with limit 10 or less; developer with limit 10 or less; raw -- research search-papers or search-github. A keyless refusal runs the call keyed once and keeps eligible keyed calls off the keyless tier for its stated window (keyless_cooldown seconds when none is stated, 6 hours at most); without a key the refusal exits 1 as keyless_rate_limited. FIRECRAWL_CLI_KEYLESS=0, a stored vendor login, or a non-default FIRECRAWL_API_URL keeps vendor calls keyed. A keyless fetch's scrape_id may not resolve in keyed interact",
            "without the vendor firecrawl binary, keyed API-direct calls (search --categories developer, developer with a key) still run under the local session and day caps, but the account floor is unchecked",
            "gov filters combine with AND over labeled pages only; no results does not mean no law; US material only; verify issuer, jurisdiction, and effective status before citing",
        ],
    }


def envelope(verb, surface, data=None, error=None):
    return {
        "ok": error is None,
        "surface": surface,
        "verb": verb,
        "credits_spent": None,
        "credits_remaining": None,
        "budget_remaining": None,
        "degraded": None,
        "error": error,
        "data": data,
    }


def item_succeeded(item):
    return not isinstance(item, dict) or (
        item.get("ok", item.get("success", True)) is not False and not item.get("error")
    )


def returned_scrape_id(payload):
    """Accept vendor scrape IDs without mistaking arbitrary extracted IDs for one."""
    if not isinstance(payload, dict):
        return None
    for key in ("scrape_id", "scrapeId", "id"):
        if isinstance(payload.get(key), str) and payload[key].strip():
            return payload[key]
    metadata = payload.get("metadata")
    if isinstance(metadata, dict):
        for key in ("scrapeId", "scrape_id"):
            if isinstance(metadata.get(key), str) and metadata[key].strip():
                return metadata[key]
    return returned_scrape_id(payload.get("data"))


def wrap_payload(verb, surface, payload):
    result = envelope(verb, surface, payload)
    if verb == "fetch":
        scrape_id = returned_scrape_id(payload)
        if scrape_id:
            result["scrape_id"] = scrape_id
    if verb == "search" and isinstance(payload, dict):
        search_id = payload.get("id")
        if isinstance(search_id, str) and search_id.strip():
            result["search_id"] = search_id
    code = 0
    # Normalize both vendor multi-item payloads and sequential fan-out results.
    if isinstance(payload, dict) and isinstance(payload.get("items"), list):
        items = []
        for original in payload["items"]:
            item = original if isinstance(original, dict) else {}
            successful = item_succeeded(item)
            error = item.get("error")
            if not successful:
                if not isinstance(error, dict) or "retryable" not in error:
                    error = vendor_failure(
                        [surface, item.get("url", "<target>")], item, ""
                    ).error_object()
            entry = {
                "ok": successful,
                "error": error,
                "credits_spent": item.get("credits_spent"),
                "data": item.get("data", original),
            }
            if "url" in item:
                entry["url"] = item["url"]
            items.append(entry)
        result["data"] = {**payload, "items": items}
        failures = sum(not item["ok"] for item in items)
        result["ok"] = failures == 0
        code = 6 if 0 < failures < len(items) else (1 if failures else 0)
        if code == 1 and all(item["error"]["retryable"] for item in items):
            code = 2
    return result, code


SNAPSHOT_PRUNE = frozenset({".git", "node_modules", "__pycache__", ".venv"})


@functools.lru_cache(maxsize=None)
def isolation_root():
    """Where the vendor's throwaway working directory goes.

    Home keeps the byproducts on one filesystem with the rest of the agent state; a
    sandbox that mounts home read-only (Codex workspace-write) falls back to the
    system temp location, where None means tempfile's own default.
    """
    home = Path.home()
    return home if os.access(home, os.W_OK) else None


def directory_snapshot():
    """KTD7: best-effort metadata snapshot; concurrent writers are indistinguishable."""
    snapshot = {}
    for root, dirs, files in os.walk(".", followlinks=False):
        dirs[:] = [d for d in dirs if d not in SNAPSHOT_PRUNE]
        for name in dirs + files:
            path = Path(root, name)
            try:
                stat = path.lstat()
                snapshot[str(path)] = (
                    stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns,
                )
            except OSError:
                continue
    return snapshot


def plain_text_payload(command, stdout, payload, decoded):
    """Map the vendor's text-only successes (#2123) to payloads; None for anything else.

    A --query answer is text, and may itself be JSON. With an empty answer the
    vendor prints its document (metadata), envelope (success) or serializer
    failure (error) instead, so only an object without those keys is an answer.
    Search reads only undecodable output, so a JSON envelope keeps its own buckets.
    """
    text = stdout.strip()
    options = command[2:]  # command[1] is the target, which may look like a flag
    if command[0] in {"scrape", "parse"} and "--query" in options:
        vendor_shape = isinstance(payload, dict) and not {
            "metadata", "success", "error"
        }.isdisjoint(payload)
        if text and not (decoded and vendor_shape):
            return {"answer": text}, []
        return None
    if command[0] == "search" and not decoded and text in {"", VENDOR_NO_RESULTS}:
        def listed(flag):
            return options[options.index(flag) + 1].split(",") if flag in options else []
        sources = listed("--sources") or ["web"]
        notes = [RESEARCH_BUCKET_NOTE] if "research" in listed("--categories") else []
        return {"success": True, "data": {source: [] for source in sources}}, notes
    return None


def invoke_vendor(command, timeout=120, raw=False, retry=None, keyless=False):
    """keyless runs the vendor without the wrapper's credential variables, so it
    answers from Firecrawl's free keyless tier (#2118); the caller has already
    checked that no stored vendor login would stand in for them."""
    env = {k: v for k, v in os.environ.items() if k not in KEYLESS_STRIPPED} if keyless else None
    binary = vendor_binary()
    if binary is None:
        raise CliError(
            "vendor firecrawl is missing from PATH",
            # Nothing in this repo installs the vendor; this is the pinned reinstall (#2105).
            "reinstall the pinned vendor: pnpm add -g firecrawl-cli@1.19.26; "
            "pnpm's global bin directory (pnpm bin -g) must be on PATH",
        )
    binary = str(Path(binary).absolute())
    vendor_timeout = "vendor default"
    timeout_unit = " s" if command[0] == "interact" else " ms"
    for index, arg in enumerate(command):
        if arg == "--timeout" and index + 1 < len(command):
            vendor_timeout = command[index + 1] + timeout_unit
        elif arg.startswith("--timeout="):
            vendor_timeout = arg.split("=", 1)[1] + timeout_unit
    timing = f"wrapper --timeout={timeout:g} s; vendor --timeout={vendor_timeout}"
    before = directory_snapshot() if raw else {}
    degraded = []
    failure = None
    response = None
    try:
        if raw:
            response = subprocess.run(
                [binary, *command], capture_output=True, text=True,
                errors="replace", timeout=timeout, env=env,
            )
        else:
            # KTD3/R9: isolate vendor caches/artifacts; local inputs are absolute.
            with tempfile.TemporaryDirectory(
                prefix="firecrawl-cli-", dir=isolation_root()
            ) as cwd:
                response = subprocess.run(
                    [binary, *command], capture_output=True, text=True,
                    errors="replace", timeout=timeout, cwd=cwd, env=env,
                )
    except subprocess.TimeoutExpired as exc:
        detail = exc.stderr or ""
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", errors="replace")
        failure = CliError(
            f"wrapper subprocess timeout ({timing})" + (f": {redact(detail)}" if detail else ""),
            "increase wrapper --timeout or reduce the work", 1,
        )
    except OSError as exc:
        failure = CliError(
            f"could not execute vendor ({timing}): {exc}", "firecrawl --status", 1
        )
    finally:
        if raw:
            after = directory_snapshot()
            degraded = [
                f"vendor wrote {path}" for path in sorted(after)
                if before.get(path) != after[path]
            ]
    if failure:
        failure.degraded = degraded or None
        raise failure
    detail = redact(response.stderr.strip())
    try:
        payload, decoded = json.loads(response.stdout), True
    except ValueError:
        payload, decoded = None, False
    if not raw and not response.returncode:
        recovered = plain_text_payload(command, response.stdout, payload, decoded)
        if recovered:
            (payload, notes), decoded = recovered, True
            degraded.extend(notes)
    if not decoded:
        if raw:
            payload = {"text": response.stdout}
        else:
            raise vendor_failure(
                command, None, detail or response.stdout.strip(), timing, retry,
                malformed=not response.returncode,
            )
    if raw:
        if isinstance(payload, dict):
            payload = {**payload, "exitCode": response.returncode}
        else:
            payload = {"value": payload, "exitCode": response.returncode}
    payload = redact(payload)
    # KTD9: vendor exit numbers are never wrapper codes.
    multi = isinstance(payload, dict) and isinstance(payload.get("items"), list)
    item_failures = multi and any(not item_succeeded(item) for item in payload["items"])
    if not item_failures and (response.returncode or not item_succeeded(payload)):
        failure = vendor_failure(command, payload, detail, timing, retry)
        failure.degraded = degraded or None
        raise failure
    if item_failures:
        payload["items"] = [
            {
                **item,
                "error": vendor_failure(
                    [command[0], item.get("url", command[1] if len(command) > 1 else "<target>")],
                    item, "", timing, retry,
                ).error_object(),
            } if not item_succeeded(item) else item
            for item in payload["items"]
        ]
    if detail:
        print(detail, file=sys.stderr)
    return payload, degraded


def bound_body(payload):
    """KTD13: cap aggregate body strings without truncating serialized JSON."""
    remaining = BODY_LIMIT
    truncated = False
    body_keys = {
        "markdown", "html", "rawHtml", "summary", "highlights", "text",
        "content", "output", "description",
    }

    def visit(value, body=False):
        nonlocal remaining, truncated
        if isinstance(value, str) and body:
            result = value[:remaining]
            remaining -= len(result)
            truncated |= len(result) < len(value)
            return result
        if isinstance(value, dict):
            return {
                key: visit(item, body or key in body_keys)
                for key, item in value.items()
            }
        if isinstance(value, list):
            return [visit(item, body) for item in value]
        return value

    result = visit(payload, isinstance(payload, str))
    notes = (
        [f"body truncated at {BODY_LIMIT} chars; --full lifts the bound"]
        if truncated else []
    )
    return result, notes


def execute(args, parser, registry):
    target = getattr(args, "target", None)
    targets = target if isinstance(target, list) else [target]
    calls = []
    # Preflight every target before any chargeable call.
    for target in targets:
        single = argparse.Namespace(**vars(args))
        single.target = target
        calls.append(vendor_arguments(single, parser, registry))
    if len(calls) == 1:
        surface, command = calls[0]
        try:
            payload, degraded = budgeted_invoke(args, surface, command)
        except CliError as exc:
            exc.surface = surface
            raise
    else:
        items, degraded = [], []
        for target, (surface, command) in zip(targets, calls):
            try:
                before_spent = BUDGET.spent
                payload, notes = budgeted_invoke(args, surface, command)
                result, _ = wrap_payload(args.verb, surface, payload)
                degraded.extend(notes)
                items.append({
                    "url": target, "ok": result["ok"], "error": result["error"],
                    "credits_spent": BUDGET.spent - before_spent, "data": result["data"],
                })
            except CliError as exc:
                if exc.code in {2, 3}:
                    exc.data = {"items": items}
                    exc.surface = surface
                    raise
                items.append({
                    "url": target, "ok": False, "error": exc.error_object(),
                    "credits_spent": 0, "data": exc.data,
                })
        surface = calls[0][0] if len({call[0] for call in calls}) == 1 else "mixed"
        payload = {"items": items}
    if args.verb != "raw" and not args.full:
        payload, notes = bound_body(payload)
        degraded.extend(notes)
        if notes:
            full_command = shlex.split(args.retry_command)
            full_command.insert(
                full_command.index("--") if "--" in full_command else len(full_command),
                "--full",
            )
            degraded.append("next: " + shlex.join(full_command))
    return surface, payload, degraded


RESULT_BUCKETS = ("items", "data", "web", "news", "images", "research", "links", "results")


def empty_payload(payload):
    # Empty only when every bucket present is empty: search with --sources web,news,
    # or --categories research from 2026-11-16, fills one bucket and leaves web=[] (#2108).
    if payload == []:
        return True
    if isinstance(payload, dict):
        buckets = [payload[key] for key in RESULT_BUCKETS if key in payload]
        return bool(buckets) and all(empty_payload(bucket) for bucket in buckets)
    return False


def emit(value, stream=sys.stdout):
    print(json.dumps(redact(value), ensure_ascii=False, allow_nan=False), file=stream)


def main(argv=None):
    global BUDGET, KEYLESS_REFUSED, KEYLESS_UNTIL
    BUDGET = None
    KEYLESS_REFUSED = KEYLESS_UNTIL = None
    argv = list(sys.argv[1:] if argv is None else argv)
    json_requested = "--json" in argv
    remember_secrets(argv)
    parser, registry = build_parser()
    verb = surface = None
    degraded = []
    try:
        BUDGET = Budget()
        normalized = normalize(argv, parser, registry)
        # --help and --version exit inside parse_args, before any ledger access.
        args = parser.parse_args(normalized)
        args.retry_command = shlex.join(["firecrawl-cli", *normalized])
        verb = args.verb
        ledger = None
        if verb != "capabilities":
            ledger = BUDGET.view()  # Reap expired reservations on every ledger-bearing invocation.
        prepare_interact(args)
        if (
            args.reason is not None and args.raise_budget is None
            and verb not in {"interact", "raw"}
        ):
            raise CliError("--reason requires --raise-budget", "firecrawl-cli budget --help")
        if args.raise_budget is not None:
            ledger = BUDGET.view(args.raise_budget, args.reason)
        timeout = getattr(args, "timeout", 120)
        if not math.isfinite(timeout) or timeout <= 0:
            raise CliError(
                "--timeout must be a positive finite number of seconds",
                f"firecrawl-cli {verb} --help",
            )
        if verb == "capabilities":
            surface, payload = "local", capabilities(registry)
        elif verb == "budget":
            surface = "local"
            payload = ledger
        else:
            surface, payload, degraded = execute(args, parser, registry)
        result, code = wrap_payload(verb, surface, payload)
        result["degraded"] = degraded or None
        BUDGET.fields(result)
        output = getattr(args, "output", None)
        if output:
            with Path(output).open("w", encoding="utf-8") as stream:
                emit(result, stream)
        if code == 6:
            print("partial success: inspect data.items for failures", file=sys.stderr)
        if empty_payload(payload):
            print(
                "hint: empty result; try a broader query or another target",
                file=sys.stderr,
            )
        # Keyless routing notes describe where the answer came from, not a gap in it.
        wrapped = args.json or verb == "raw" or code in {1, 2} or any(
            not note.startswith(KEYLESS_PREFIX) for note in result["degraded"] or []
        )
        emit(
            result if wrapped else result["data"],
            sys.stderr if code in {1, 2} and not args.json else sys.stdout,
        )
        return code
    except CliError as exc:
        result = envelope(
            verb,
            getattr(exc, "surface", surface),
            data=exc.data,
            error=exc.error_object(),
        )
        result["degraded"] = exc.degraded
        if BUDGET is not None:
            BUDGET.fields(result)
        # --json puts the envelope on stdout for every exit code and keeps the
        # human line on stderr; without --json the envelope is a diagnostic.
        if json_requested:
            print(redact(f"{exc}\nnext: {exc.next_action}"), file=sys.stderr)
            emit(result)
        elif hasattr(exc, "error_code") and verb != "raw":
            print(redact(f"{exc}\nnext: {exc.next_action}"), file=sys.stderr)
        else:
            emit(result, sys.stderr)
        return exc.code
    except (OSError, ValueError) as exc:
        failure = CliError(str(exc), "firecrawl-cli --help")
        result = envelope(verb, surface, error=failure.error_object())
        if BUDGET is not None:
            BUDGET.fields(result)
        print(redact(f"{failure}\nnext: {failure.next_action}"), file=sys.stderr)
        emit(result, sys.stdout if json_requested else sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main())
