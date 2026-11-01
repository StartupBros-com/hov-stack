#!/usr/bin/env python3
"""resend-cli: operator wrapper over the official Resend CLI (npm `resend-cli`).

The wrapper owns three things and nothing else: which vendor commands may run,
which of them need an explicit confirmation flag, and how the one credential
reaches the vendor. Everything else -- argument parsing, JSON output,
pagination, exit codes -- is the official CLI's, executed unchanged through
os.execve of the pinned vendor binary.

Credentials: one per account. The default account reads RESEND_API_KEY_MAIN;
the bindings file may name more accounts (an "accounts" object of account name
to record name, plus "default_account"), chosen by the wrapper's own --account
flag, which never reaches the vendor. Each is read from one exact Bitwarden
Secrets Manager record named in the host overlay resend-bws-bindings.json
(RESEND_CLI_BINDINGS_FILE, then $HOV_STACK_OVERLAY, then
${XDG_CONFIG_HOME:-$HOME/.config}/hov-stack). The record id,
the record key and the project id are all checked against that file before
the value is accepted. There is no fallback to another account, to
RESEND_API_KEY in the
environment, to `resend login` caches, or to any secret-list search. An
empty binding slot is reported as credential_unbound, which is distinct from
a bws outage (bws_unavailable, bws_timeout, bws_failed) and from the
provider's own scope denial (the vendor's restricted_api_key error, which
passes through unchanged with the vendor's exit status).

Classes (see COMMANDS): metadata runs without a credential; read runs with
one; send needs --confirm-send; write needs --confirm-write; destructive
needs --confirm-destructive; refused never runs. A vendor option that sends
on the spot (SEND_OPTIONS, e.g. `broadcasts create --send`) escalates a write
to send. The class is decided from argv before any file, credential or
network access; --where, --version and --help never read the bws token or
the credential (token presence is reported by existence only). Confirmation flags are
invocation guards, not authorization: a send or write still needs the
operator's prior approval.

Child environment is an allowlist: PATH/HOME/locale/TERM/TMPDIR plus the
vendor switches that disable telemetry, the update check and interactive
prompts, an isolated XDG_CONFIG_HOME so login caches are never consulted,
and RESEND_API_KEY only for credentialed classes. RESEND_BASE_URL,
RESEND_PROFILE, RESEND_CREDENTIAL_STORE, NODE_OPTIONS and the rest of the
parent environment never reach the vendor.

Test seams (production sets none; --where lists any that are set as
seam_overrides): RESEND_CLI_VENDOR_PREFIX, RESEND_CLI_BINDINGS_FILE,
RESEND_CLI_STATE_DIR, BWS_TOKEN_FILE, RESEND_CLI_BWS_TIMEOUT. They are not a
boundary: a caller who can set them already controls PATH (the bws lookup)
and can read the token file directly.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

WRAPPER_VERSION = "1.1.0"
VENDOR_PACKAGE = "resend-cli"
VENDOR_PIN = "2.23.0"
RECORD_NAME = "RESEND_API_KEY_MAIN"
# One Resend team per account, each read through its own exact BWS record. With no
# "accounts" object in the bindings file the only account is "main"; a host overlay
# names its own accounts there, so no account name lives in the tree.
BUILTIN_ACCOUNTS = {"main": RECORD_NAME}
BUILTIN_DEFAULT = "main"
ACCOUNT_FLAG = "--account"
ACCOUNT_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
RECORD_NAME_RE = re.compile(r"^RESEND_API_KEY_[A-Z0-9_]{1,64}$")
INSTALL_HINT = "scripts/resend-cli-install.sh install"

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# Resend keys are `re_` followed by a URL-safe token; the shape check rejects
# empty, whitespace or clearly foreign values without ever printing one.
KEY_RE = re.compile(r"^re_[A-Za-z0-9_-]{8,200}$")

METADATA, READ, SEND, WRITE, DESTRUCTIVE, REFUSED = (
    "metadata", "read", "send", "write", "destructive", "refused")
CONFIRM_FLAG = {SEND: "--confirm-send", WRITE: "--confirm-write", DESTRUCTIVE: "--confirm-destructive"}
WRAPPER_FLAGS = {"--where", "--version", *CONFIRM_FLAG.values()}
# Vendor options that would move the credential or its storage out of the
# wrapper's control. Refused wherever they appear.
FORBIDDEN_FLAGS = {"--api-key", "-p", "--profile", "--insecure-storage"}
JSON_FLAGS = {"--json", "-q", "--quiet"}
HELP_FLAGS = {"-h", "--help"}
# Vendor aliases, each tried in order against the canonical names at that depth.
ALIASES = {"ls": ("list",), "rm": ("delete", "remove")}

# Every leaf of `resend commands` at the pinned version, classified exactly
# once. tests/test_resend_cli.py holds that fixture and fails when the
# two drift. An argv path that reaches no entry here is unlisted_command.
COMMANDS = {
    "login": REFUSED,
    "emails list": READ, "emails send": SEND, "emails get": READ, "emails batch": SEND,
    "emails cancel": WRITE, "emails update": WRITE, "emails share": WRITE,
    "emails metrics": READ, "emails attachments": READ, "emails attachment": READ,
    "emails receiving list": READ, "emails receiving get": READ,
    "emails receiving listen": REFUSED, "emails receiving attachments": READ,
    "emails receiving attachment": READ, "emails receiving forward": SEND,
    "broadcasts create": WRITE, "broadcasts open": REFUSED, "broadcasts send": SEND,
    "broadcasts get": READ, "broadcasts list": READ, "broadcasts recipients": READ,
    "broadcasts update": WRITE, "broadcasts cancel": WRITE, "broadcasts duplicate": WRITE,
    "broadcasts delete": DESTRUCTIVE, "broadcasts clicked-links": READ,
    "automations create": WRITE, "automations get": READ, "automations list": READ,
    "automations update": WRITE, "automations delete": DESTRUCTIVE,
    "automations duplicate": WRITE, "automations stop": WRITE, "automations open": REFUSED,
    "automations runs list": READ, "automations runs get": READ,
    "events create": WRITE, "events get": READ, "events list": READ, "events update": WRITE,
    "events delete": DESTRUCTIVE, "events open": REFUSED, "events send": SEND,
    "templates create": WRITE, "templates get": READ, "templates open": REFUSED,
    "templates list": READ, "templates update": WRITE, "templates delete": DESTRUCTIVE,
    "templates publish": WRITE, "templates duplicate": WRITE,
    "contacts create": WRITE, "contacts get": READ, "contacts list": READ,
    "contacts update": WRITE, "contacts delete": DESTRUCTIVE, "contacts segments": READ,
    "contacts add-segment": WRITE, "contacts remove-segment": WRITE, "contacts topics": READ,
    "contacts update-topics": WRITE, "contacts imports create": WRITE,
    "contacts imports get": READ, "contacts imports list": READ,
    "contact-properties create": WRITE, "contact-properties get": READ,
    "contact-properties list": READ, "contact-properties update": WRITE,
    "contact-properties delete": DESTRUCTIVE,
    "segments contacts": READ, "segments create": WRITE, "segments get": READ,
    "segments list": READ, "segments update": WRITE, "segments delete": DESTRUCTIVE,
    "topics create": WRITE, "topics get": READ, "topics list": READ, "topics update": WRITE,
    "topics delete": DESTRUCTIVE,
    "domains create": WRITE, "domains verify": WRITE, "domains get": READ, "domains list": READ,
    "domains update": WRITE, "domains delete": DESTRUCTIVE, "domains claim create": WRITE,
    "domains claim get": READ, "domains claim verify": WRITE,
    "logs get": READ, "logs list": READ, "logs open": REFUSED,
    "usage": READ,
    "careers apply": REFUSED, "careers list": REFUSED,
    "suppressions list": READ, "suppressions add": WRITE, "suppressions get": READ,
    "suppressions delete": DESTRUCTIVE, "suppressions batch add": WRITE,
    "suppressions batch remove": DESTRUCTIVE,
    "api-keys create": DESTRUCTIVE, "api-keys list": READ, "api-keys update": DESTRUCTIVE,
    "api-keys delete": DESTRUCTIVE,
    "webhooks create": WRITE, "webhooks get": READ, "webhooks events list": READ,
    "webhooks events get": READ, "webhooks events attempts": READ,
    "webhooks events replay": WRITE, "webhooks listen": REFUSED, "webhooks list": READ,
    "webhooks update": WRITE, "webhooks rotate-signing-secret": DESTRUCTIVE,
    "webhooks delete": DESTRUCTIVE,
    "oauth-grants list": READ, "oauth-grants revoke": DESTRUCTIVE,
    "auth login": REFUSED, "auth logout": REFUSED, "auth list": REFUSED, "auth switch": REFUSED,
    "auth rename": REFUSED, "auth remove": REFUSED,
    "logout": REFUSED, "whoami": READ, "doctor": REFUSED, "open": REFUSED, "docs": REFUSED,
    "update": REFUSED, "commands": METADATA, "completion": REFUSED,
}
GROUPS = {" ".join(key.split()[:n]) for key in COMMANDS for n in range(1, len(key.split()))}
# Vendor options that make a WRITE leaf send on the spot (from `resend
# commands` at the pin: `broadcasts create --send` ships the broadcast instead
# of saving a draft, and its `--scheduled-at` is only valid with --send). The
# tier is escalated to SEND when one of these appears after the command, so
# --confirm-write alone never sends. The fixture test fails if a future pin
# adds a `--send` option to a leaf that is neither SEND nor listed here.
SEND_OPTIONS = {"broadcasts create": ("--send", "--scheduled-at")}

# Parent variables the vendor may see. Everything else is dropped, including
# RESEND_API_KEY, RESEND_PROFILE, RESEND_BASE_URL, RESEND_CREDENTIAL_STORE,
# RESEND_USER_AGENT, NODE_OPTIONS, NODE_EXTRA_CA_CERTS, FORCE_COLOR and any
# proxy variable. PATH stays because the vendor's pnpm shim execs `node`.
ENV_PASSTHROUGH = {"PATH", "HOME", "USER", "LOGNAME", "LANG", "LANGUAGE", "TERM", "TMPDIR", "TZ", "NO_COLOR"}
ENV_PASSTHROUGH_PREFIXES = ("LC_", "MISE_")
# Vendor switches (read from dist/cli.cjs at 2.23.0): the two telemetry
# opt-outs stop both the PostHog capture and the telemetry-id file, the
# notifier switch stops the GitHub releases lookup, and CI=1 turns every
# interactive prompt off so the vendor can never wait on a TTY.
ENV_FIXED = {"DO_NOT_TRACK": "1", "RESEND_TELEMETRY_DISABLED": "1", "RESEND_NO_UPDATE_NOTIFIER": "1", "CI": "1"}
IGNORED_PARENT_VARS = ("RESEND_API_KEY", "RESEND_PROFILE", "RESEND_BASE_URL", "RESEND_CREDENTIAL_STORE", "NODE_OPTIONS")
SEAM_VARS = ("RESEND_CLI_VENDOR_PREFIX", "RESEND_CLI_BINDINGS_FILE", "RESEND_CLI_STATE_DIR", "BWS_TOKEN_FILE",
             "RESEND_CLI_BWS_TIMEOUT")

USAGE_CODES = {"usage", "unsupported_command", "unlisted_command", "confirmation_required", "forbidden_flag"}
UNBOUND_EXIT = 3


class CliError(Exception):
    def __init__(self, message, code, **extra):
        super().__init__(message)
        self.code = code
        self.extra = extra


def usage_text():
    return (
        "usage: resend-cli [--account NAME] <vendor command> [vendor options]\n"
        "       resend-cli --where | --version | --help\n"
        "\n"
        "Operator wrapper over the official resend-cli " + VENDOR_PIN + ". --account picks the Resend\n"
        "team and its exact BWS record (the names are in the bindings file; --where lists them).\n"
        "Named reads run as-is; sends need --confirm-send; other\n"
        "writes need --confirm-write; deletes, API-key and signing-secret operations need\n"
        "--confirm-destructive. login/logout/auth, doctor, open, docs, update, completion,\n"
        "careers and the listen commands are refused. --api-key, --profile and\n"
        "--insecure-storage are refused everywhere. --json is added for you.\n"
        "`resend-cli <command> --help` shows the vendor's own help without a credential.\n"
    )


# ── paths and seams ────────────────────────────────────────────────────────────


def repo_claude_dir():
    return Path(__file__).resolve().parent.parent


def bindings_path():
    override = os.environ.get("RESEND_CLI_BINDINGS_FILE")
    if override:
        return Path(override)
    overlay = os.environ.get("HOV_STACK_OVERLAY")
    if overlay:
        return Path(overlay) / "resend-bws-bindings.json"
    return (
        Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        / "hov-stack"
        / "resend-bws-bindings.json"
    )


def vendor_prefix():
    override = os.environ.get("RESEND_CLI_VENDOR_PREFIX")
    return Path(override) if override else Path.home() / ".local" / "lib" / VENDOR_PACKAGE / ("v" + VENDOR_PIN)


def state_dir():
    override = os.environ.get("RESEND_CLI_STATE_DIR")
    return Path(override) if override else Path.home() / ".local" / "state" / "resend-cli"


def token_file():
    override = os.environ.get("BWS_TOKEN_FILE")
    return Path(override) if override else Path.home() / ".config" / "bws" / "token"


def bws_timeout():
    raw = os.environ.get("RESEND_CLI_BWS_TIMEOUT", "")
    try:
        value = float(raw) if raw else 25.0
    except ValueError:
        value = 25.0
    return value if value > 0 else 25.0


# ── argv classification ───────────────────────────────────────────────────────


class Invocation:
    def __init__(self):
        self.where = False
        self.version = False
        self.help = False
        self.account = None
        self.confirms = set()
        self.path = []
        self.rest = []
        self.json_flagged = False
        self.kind = None


def classify(argv):
    """Decide what argv asks for. Reads nothing but argv."""
    inv = Invocation()
    tokens = list(argv)
    passthrough = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            passthrough.extend(tokens[i:])
            break
        if tok == ACCOUNT_FLAG or tok.startswith(ACCOUNT_FLAG + "="):
            # The value is never echoed: a mistyped argv could hold anything.
            if tok == ACCOUNT_FLAG:
                if i + 1 == len(tokens):
                    raise CliError("--account needs an account name", "usage")
                i += 1
                name = tokens[i]
            else:
                name = tok.split("=", 1)[1]
            if inv.account is not None:
                raise CliError("--account is given more than once", "usage")
            if not ACCOUNT_RE.match(name):
                raise CliError("--account needs a configured account name (see --where)", "usage")
            inv.account = name
        elif tok in WRAPPER_FLAGS:
            if tok == "--where":
                inv.where = True
            elif tok == "--version":
                inv.version = True
            else:
                inv.confirms.add(tok)
        else:
            if tok in HELP_FLAGS:
                inv.help = True
            passthrough.append(tok)
        i += 1
    for tok in passthrough:
        if tok == "--":
            break
        name = tok.split("=", 1)[0]
        # The vendor's short options are -v, -q and -p, so a commander-style
        # attached value (-pwork) or cluster (-qp work) still names the profile.
        if name not in FORBIDDEN_FLAGS and name.startswith("-") and not name.startswith("--") and "p" in name[1:]:
            name = "-p"
        if name in FORBIDDEN_FLAGS:
            raise CliError("%s is refused: the credential and its storage are the wrapper's, never argv" % name, "forbidden_flag")
    if inv.where or inv.version:
        if passthrough or inv.confirms or inv.account:
            raise CliError("--where and --version take no other arguments (--where reports every account)", "usage")
        return inv
    if passthrough and passthrough[0] == "help":
        inv.help = True
        passthrough = passthrough[1:]
    if not any(tok not in HELP_FLAGS for tok in passthrough):
        if inv.help:
            inv.kind = METADATA  # wrapper usage; the vendor is not run
            return inv
        raise CliError("a vendor command, --where, --version or --help is required", "usage")
    # The command path is the leading run of non-option tokens, resolved
    # against COMMANDS. A vendor option before the path is complete is a
    # usage error; a token that is neither a group nor a leaf is unlisted.
    # The vendor's -q/--json are program options it reads after the path
    # too, so a leading one is kept and forwarded after the path below.
    leading_json = []
    j = 0
    while j < len(passthrough):
        tok = passthrough[j]
        if tok == "--":
            break
        if tok.startswith("-"):
            if tok in JSON_FLAGS:
                inv.json_flagged = True
                leading_json.append(tok)
                j += 1
                continue
            if tok in HELP_FLAGS:
                j += 1
                continue
            raise CliError("vendor options go after the command (%s before %s)" % (tok, " ".join(inv.path) or "any command"), "usage")
        candidate = " ".join(inv.path + [tok])
        if candidate not in COMMANDS and candidate not in GROUPS:
            for canonical in ALIASES.get(tok, ()):
                if " ".join(inv.path + [canonical]) in COMMANDS:
                    candidate = " ".join(inv.path + [canonical])
                    break
        if candidate in COMMANDS:
            inv.path = candidate.split()
            j += 1
            break
        if candidate in GROUPS:
            inv.path = candidate.split()
            j += 1
            continue
        raise CliError("%s is not a command of the pinned resend-cli %s" % (candidate, VENDOR_PIN), "unlisted_command")
    inv.rest = passthrough[j:]
    for tok in inv.rest:
        if tok == "--":
            break
        if tok in JSON_FLAGS:
            inv.json_flagged = True
    key = " ".join(inv.path)
    if key in COMMANDS:
        inv.kind = COMMANDS[key]
    elif inv.help or not inv.rest:
        inv.help = True  # a bare group shows the vendor's group help, no credential
    else:
        raise CliError("%s is a command group; choose one of its commands" % key, "unlisted_command")
    if inv.help:
        inv.kind = METADATA
        return inv
    if inv.kind == REFUSED:
        raise CliError("%s is not available through this wrapper (login caches, browsers, listeners, self-update and careers stay with the operator)" % key, "unsupported_command")
    for tok in inv.rest:
        if tok == "--":
            break
        if tok.split("=", 1)[0] in SEND_OPTIONS.get(key, ()):
            inv.kind = SEND  # a vendor flag that sends outranks the path's write tier
            break
    needed = CONFIRM_FLAG.get(inv.kind)
    if needed and needed not in inv.confirms:
        raise CliError("%s is a %s command: it needs the operator's prior approval and %s on this invocation" % (key, inv.kind, needed), "confirmation_required", required_flag=needed)
    stray = sorted(inv.confirms - ({needed} if needed else set()))
    if stray:
        raise CliError("%s does not apply to %s (%s)" % (", ".join(stray), key, inv.kind), "usage")
    inv.rest = leading_json + inv.rest
    return inv


# ── vendor ────────────────────────────────────────────────────────────────────


def vendor_binary(prefix):
    return prefix / "bin" / "resend"


def vendor_package_version(prefix):
    """The pinned package's own version, read from pnpm's layout; never by exec."""
    matches = sorted(prefix.glob("*/node_modules/" + VENDOR_PACKAGE + "/package.json"))
    if len(matches) != 1:
        return None
    try:
        data = json.loads(matches[0].read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("name") != VENDOR_PACKAGE:
        return None
    version = data.get("version")
    return version if isinstance(version, str) else None


def check_vendor(prefix):
    binary = vendor_binary(prefix)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise CliError("pinned %s %s is not installed at %s; run %s" % (VENDOR_PACKAGE, VENDOR_PIN, prefix, INSTALL_HINT), "vendor_missing", prefix=str(prefix))
    version = vendor_package_version(prefix)
    if version != VENDOR_PIN:
        raise CliError("installed %s reports %s, wrapper is pinned to %s; run %s" % (VENDOR_PACKAGE, version or "no readable version", VENDOR_PIN, INSTALL_HINT), "vendor_version_mismatch", installed=version, pinned=VENDOR_PIN)
    return binary


def ensure_xdg_home():
    """A private, empty-by-design config home so vendor login caches never apply."""
    xdg = state_dir() / "xdg"
    xdg.mkdir(parents=True, exist_ok=True)
    os.chmod(xdg, stat.S_IRWXU)
    return xdg


def child_env(credential=None):
    env = {}
    for name, value in os.environ.items():
        if name in ENV_PASSTHROUGH or name.startswith(ENV_PASSTHROUGH_PREFIXES):
            env[name] = value
    env.setdefault("HOME", str(Path.home()))
    env.update(ENV_FIXED)
    env["XDG_CONFIG_HOME"] = str(ensure_xdg_home())
    if credential is not None:
        env["RESEND_API_KEY"] = credential
    return env


def vendor_argv(binary, inv):
    argv = [str(binary)] + list(inv.path)
    if inv.help:
        # A help run carries nothing but the command path: a -h/--help token
        # anywhere in argv turns the call into help (no confirmation, no
        # credential), so the other arguments must not reach the vendor
        # either, or `emails send --from a@b.c -h` would be a send attempt.
        return argv + ["--help"]
    if not inv.json_flagged:
        argv.append("--json")
    return argv + list(inv.rest)


def exec_vendor(argv, env):
    """Replaced by tests; production never returns from here."""
    os.execve(argv[0], argv, env)


# ── credential ────────────────────────────────────────────────────────────────


def parse_accounts(data, path):
    """(accounts, default) from a parsed bindings object. Without an "accounts"
    object the only account is BUILTIN_ACCOUNTS; with one it is exactly that."""
    def bad(why):
        return CliError("bindings file %s: %s" % (path, why), "bindings_invalid", path=str(path))

    extra = data.get("accounts")
    if extra is None:
        accounts = dict(BUILTIN_ACCOUNTS)
    else:
        if not isinstance(extra, dict) or not extra:
            raise bad("accounts must be a non-empty object of account name -> record name")
        for name, record in extra.items():
            if not ACCOUNT_RE.match(name) or not isinstance(record, str) or not RECORD_NAME_RE.match(record):
                raise bad("accounts entries must map a lowercase account name to a RESEND_API_KEY_* record name")
        accounts = dict(extra)
    default = data.get("default_account")
    if default is None:
        default = BUILTIN_DEFAULT if BUILTIN_DEFAULT in accounts else None
    if default is None or default not in accounts:
        raise bad("default_account must name one of the accounts")
    return accounts, default


def known_accounts(path):
    """Accounts and default for classification, help and --where. Lenient: an
    absent or malformed file yields the built-in account, and load_binding
    reports the file's fault when a credential is actually needed."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return parse_accounts(data, path)
    except (OSError, ValueError, CliError):
        pass
    return dict(BUILTIN_ACCOUNTS), BUILTIN_DEFAULT


def load_binding(path, account=None):
    """The exact-record binding for the account's record, or credential_unbound."""
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise CliError(
            "bindings file %s is missing (set RESEND_CLI_BINDINGS_FILE; see config/resend-bws-bindings.example.json)"
            % path,
            "credential_unbound",
            path=str(path),
        )
    except OSError:
        raise CliError(
            "bindings file %s is unreadable" % path, "bindings_invalid", path=str(path)
        )
    except UnicodeError:
        raise CliError(
            "bindings file %s is not valid UTF-8 JSON" % path,
            "bindings_invalid",
            path=str(path),
        ) from None
    try:
        data = json.loads(raw)
    except ValueError:
        raise CliError("bindings file %s is not valid JSON" % path, "bindings_invalid", path=str(path))
    if not isinstance(data, dict):
        raise CliError("bindings file %s must hold an object" % path, "bindings_invalid", path=str(path))
    unknown = sorted(k for k in data if k not in {"project_id", "records", "accounts", "default_account"} and not k.startswith("_"))
    if unknown:
        raise CliError("bindings file %s has unknown keys: %s" % (path, ", ".join(unknown)), "bindings_invalid", path=str(path))
    project = data.get("project_id")
    records = data.get("records")
    if not isinstance(project, str) or not UUID_RE.match(project):
        raise CliError("bindings file %s needs a UUID project_id" % path, "bindings_invalid", path=str(path))
    if not isinstance(records, dict):
        raise CliError("bindings file %s needs a records object" % path, "bindings_invalid", path=str(path))
    seen = set()
    for name, record in records.items():
        if not isinstance(record, dict) or set(record) != {"id", "key"}:
            raise CliError(
                "bindings file %s: record %s must be {id, key}" % (path, name),
                "bindings_invalid",
                path=str(path),
            )
        if record["key"] != name:
            raise CliError(
                "bindings file %s: record %s names key %r"
                % (path, name, record["key"]),
                "bindings_invalid",
                path=str(path),
            )
        if not isinstance(record["id"], str) or not UUID_RE.match(record["id"]):
            raise CliError(
                "bindings file %s: record %s needs a UUID id" % (path, name),
                "bindings_invalid",
                path=str(path),
            )
        if record["id"] in seen:
            raise CliError(
                "bindings file %s: record id %s is bound twice" % (path, record["id"]),
                "bindings_invalid",
                path=str(path),
            )
        seen.add(record["id"])
    accounts, default = parse_accounts(data, path)
    account = account or default
    if account not in accounts:
        raise CliError("unknown --account value; use one of: %s" % ", ".join(accounts), "usage")
    name = accounts[account]
    record = records.get(name)
    if record is None:
        raise CliError(
            "%s (account %s) is not bound: add its exact BWS record id to %s (set RESEND_CLI_BINDINGS_FILE; no enumeration, no fallback to RESEND_API_KEY or another account)"
            % (name, account, path),
            "credential_unbound",
            path=str(path),
            project_id=project,
            account=account,
            record=name,
        )
    return {"project_id": project, "id": record["id"], "key": name}


def token_presence():
    """Where a bws machine token would come from, without reading it: 'env',
    'file' or 'none'. --where uses this; only resolve_credential reads."""
    if os.environ.get("BWS_ACCESS_TOKEN"):
        return "env"
    return "file" if token_file().is_file() else "none"


def token_source():
    """Where the bws machine token comes from: ('env'|'file', value) or ('none', None).
    The only reader of the token file; called from resolve_credential alone."""
    env_token = os.environ.get("BWS_ACCESS_TOKEN")
    if env_token:
        return "env", env_token
    path = token_file()
    try:
        value = path.read_text().strip()
    except OSError:
        return "none", None
    return ("file", value) if value else ("none", None)


def resolve_credential(binding):
    """One exact `bws secret get`, identity-checked. Never logs or prints the value."""
    source, token = token_source()
    if token is None:
        raise CliError("no bws machine token: set BWS_ACCESS_TOKEN or create %s" % token_file(), "bws_missing_bootstrap")
    bws = shutil.which("bws")
    if not bws:
        raise CliError("bws is not on PATH", "bws_unavailable")
    argv = [bws, "--color", "no", "secret", "get", binding["id"], "-o", "json"]
    env = {"PATH": os.environ.get("PATH", ""), "HOME": str(Path.home()), "BWS_ACCESS_TOKEN": token}
    try:
        proc = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=bws_timeout(), check=False)
    except FileNotFoundError:
        raise CliError("bws is not executable", "bws_unavailable")
    except subprocess.TimeoutExpired:
        raise CliError("bws did not answer within %gs" % bws_timeout(), "bws_timeout")
    if proc.returncode != 0:
        raise CliError("bws exited %d fetching the bound record" % proc.returncode, "bws_failed", exit_status=proc.returncode)
    try:
        payload = json.loads(proc.stdout)
    except ValueError:
        raise CliError("bws returned no JSON record", "invalid_response")
    if not isinstance(payload, dict):
        raise CliError("bws returned no JSON record", "invalid_response")
    if (payload.get("id"), payload.get("key"), payload.get("projectId")) != (binding["id"], binding["key"], binding["project_id"]):
        raise CliError("bws record identity does not match the binding (id, key or project)", "bws_identity_mismatch")
    value = payload.get("value")
    if not isinstance(value, str) or not KEY_RE.match(value.strip()):
        raise CliError("bound record holds no Resend API key shaped value", "credential_invalid")
    return value.strip()


# ── reporting ─────────────────────────────────────────────────────────────────


def binding_report(bpath, account, record):
    binding = {"file": str(bpath), "record": record, "bound": False, "valid": False, "project_id": None, "record_id": None, "error": None}
    try:
        info = load_binding(bpath, account)
        binding.update(bound=True, valid=True, project_id=info["project_id"], record_id=info["id"])
    except CliError as exc:
        binding["error"] = exc.code
        binding["valid"] = exc.code == "credential_unbound"
        binding["project_id"] = exc.extra.get("project_id")
    return binding


def where_report():
    """Metadata only: no credential value, token value or network."""
    prefix = vendor_prefix()
    binary = vendor_binary(prefix)
    version = vendor_package_version(prefix)
    bpath = bindings_path()
    names, default = known_accounts(bpath)
    accounts = {name: binding_report(bpath, name, record) for name, record in names.items()}
    source = token_presence()
    xdg = state_dir() / "xdg"
    stray = []
    if (xdg / "resend").is_dir():
        stray = sorted(p.name for p in (xdg / "resend").iterdir())
    return {
        "wrapper": {"version": WRAPPER_VERSION, "module": str(Path(__file__).resolve())},
        "vendor": {"package": VENDOR_PACKAGE, "pinned": VENDOR_PIN, "prefix": str(prefix),
                   "binary_present": binary.is_file() and os.access(binary, os.X_OK),
                   "installed": version, "converged": version == VENDOR_PIN and binary.is_file(),
                   "node_on_path": shutil.which("node") is not None, "install": INSTALL_HINT},
        # binding is the default account's, in the shape it had before --account.
        "binding": accounts[default],
        "default_account": default,
        "accounts": accounts,
        "bws": {"binary_on_path": shutil.which("bws") is not None, "token_source": source, "token_file": str(token_file())},
        "config_home": {"path": str(xdg), "vendor_entries": stray},
        "ignored_parent_env": [name for name in IGNORED_PARENT_VARS if name in os.environ],
        "seam_overrides": [name for name in SEAM_VARS if name in os.environ],
    }


def emit(payload):
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    sys.stdout.flush()


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        inv = classify(argv)
        if inv.version:
            sys.stdout.write(
                "resend-cli wrapper %s (vendor pin %s %s)\n"
                % (WRAPPER_VERSION, VENDOR_PACKAGE, VENDOR_PIN)
            )
            return 0
        if inv.where:
            emit({"ok": True, "where": where_report()})
            return 0
        if inv.help and not inv.path:
            sys.stdout.write(usage_text())
            return 0
        binary = check_vendor(vendor_prefix())
        credential = None
        if inv.kind != METADATA:
            credential = resolve_credential(load_binding(bindings_path(), inv.account))
        env = child_env(credential)
        del credential
        exec_vendor(vendor_argv(binary, inv), env)
        return 0
    except CliError as exc:
        error = {"code": exc.code, "message": str(exc)}
        error.update(exc.extra)
        emit({"ok": False, "error": error})
        if exc.code in USAGE_CODES or exc.code == "bindings_invalid":
            return 2
        if exc.code == "credential_unbound":
            return UNBOUND_EXIT
        return 1
    except Exception as exc:  # never echo the text; it could carry a value
        emit(
            {
                "ok": False,
                "error": {"code": "internal_error", "message": type(exc).__name__},
            }
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
