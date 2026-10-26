#!/usr/bin/env python3
"""vastai -- agent-native wrapper around the vendor vast.ai CLI (PyPI `vastai`).

The vendor CLI reads its key from VAST_API_KEY, else from a plaintext file it
writes with `vastai set api-key`. This wrapper owns the `vastai` name on PATH
so agents never need that file, and it closes the headless traps the
2026-10-13 harness vet measured (docs/vets/2026-10-13-vastai-cli-harness-vet.md):

  credential chain   VAST_API_KEY env -> Bitwarden Secrets Manager (bws, key
                     VAST_API_KEY in the project named by ~/.config/bws/
                     sb-project-id) -> ~/.secrets (parsed, never sourced)
  injection          the key reaches the vendor process as an environment
                     variable only; it is never placed in argv or on disk
  --where            print the source that resolved and exit; never the value
  no credential      --version, --help/-h anywhere, `help`, or no command;
                     these also run with VAST_URL pointed at a closed loopback
                     port, so the vendor's import-time catalog fetch cannot
                     leave the host
  refused (exit 2)   `set api-key` (writes the plaintext key file); `--api-key`
                     (key in argv and /proc); `--explain` and `--curl` (both
                     print the full Bearer key to stdout); `--url` or a VAST_URL
                     env var naming a non-loopback host (the key goes wherever
                     they point), each flag also under any argparse prefix
                     abbreviation (`--cur`, `--expl`, `--ur`, `--api`);
                     `update` (self-update outside the uv-managed
                     venv); `destroy instance(s)` without -y (the vendor prints
                     "Aborted." and exits 0 when stdin is not a terminal, so a
                     forgotten -y reads as success while billing continues)
  headless defaults  --full is added unless --raw or --full is present (the
                     vendor spawns `less -R` without a TTY check and hangs
                     under a pty); --no-color is added when stdout is not a
                     terminal unless --raw or --no-color is present;
                     VASTAI_NO_UPDATE_CHECK=1 is set
  exit status        the vendor exits 0 on API errors. The wrapper relays
                     both streams line by line and exits 1 when the child
                     exited 0 but reported "Failed with error NNN" or a --raw
                     {"error": true} object; any non-zero child status passes
                     through unchanged
  redaction          `create instance` prints the per-instance credential
                     "instance_api_key" in clear and `show instance(s)` each
                     instance's "jupyter_token"; every `*api_key` and
                     `jupyter_token` string field is replaced with
                     "[redacted by the vastai wrapper]" on both streams
                     before it reaches the caller
  exit 3             venv missing; the recreate commands are printed
  exit 4             no credential in any source
  exit 5             the credential store could not be read (bws failed or
                     timed out); do not re-seed, the key may still exist

Everything else is passed to the vendor binary unchanged:
  ~/.local/share/vastai-cli/venv/bin/vastai   (override: VASTAI_VENV)

Recreate the venv (disposable, not versioned):
  uv venv ~/.local/share/vastai-cli/venv --python 3.12
  uv pip install --python ~/.local/share/vastai-cli/venv/bin/python vastai==1.8.3

Command surface, spend rules and the rent/monitor/destroy pattern:
harness/data-source-clis.md.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

ENV_NAME = "VAST_API_KEY"
PINNED_VERSION = "1.8.3"
# Vendor keys are 64 hex chars today; the pattern only rejects values that
# could not be a key (whitespace, quotes, shell metacharacters).
KEY_PATTERN = re.compile(r"^[A-Za-z0-9_\-]{16,512}$")
# Overridable only so vastai.test.sh can bound a hung fake `bws`.
BWS_TIMEOUT = int(os.environ.get("VASTAI_BWS_TIMEOUT_SECONDS", "30"))
# The vendor's global options as its argparse parser defines them (cli/main.py).
# argparse accepts any unambiguous prefix of a long option, so `--cur` is
# `--curl`, `--ur` is `--url` and `--ret 3` consumes a value like `--retry 3`:
# every guard below compares canonical spellings, never the raw token.
GLOBAL_FLAGS = ("--api-key", "--curl", "--explain", "--full", "--help", "--no-color",
                "--raw", "--retry", "--url", "--version")
# Vendor global flags that consume the next token, so `vastai --url U set api-key`
# still resolves `set api-key` as the command.
VALUE_FLAGS = {"--url", "--retry", "--api-key"}
NO_CREDENTIAL_FLAGS = {"--help", "--version"}
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})
# A closed port: the vendor's unauthenticated gpu-names fetch at import fails
# fast and silently instead of reaching console.vast.ai from --version/--help.
NO_NETWORK_URL = "http://127.0.0.1:9"
API_ERROR_TEXT = re.compile(r"^Failed with error \d+")

RECREATE = (
    "  uv venv {venv} --python 3.12\n"
    "  uv pip install --python {venv}/bin/python vastai==" + PINNED_VERSION
)


def venv_dir():
    override = os.environ.get("VASTAI_VENV")
    return Path(override) if override else Path.home() / ".local/share/vastai-cli/venv"


def _read(path, limit):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read(limit)
    except (OSError, UnicodeDecodeError):
        return None


def _validate(value):
    value = value.strip()
    return value if KEY_PATTERN.fullmatch(value) else None


def _bws_key():
    """(key, failure). failure is None, "bws_timeout" or "bws_unavailable".
    Token or project file absent means bws is not configured here: fall through."""
    home = Path.home()
    access = _read(home / ".config/bws/token", 4096)
    project = _read(home / ".config/bws/sb-project-id", 1024)
    access = access.strip() if access else None
    project = project.strip() if project else None
    if not access or not project:
        return None, None
    result = None
    # One retry: a transient bws failure must not read as a missing key, whose
    # fix (re-seeding) would overwrite a live value.
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
        if isinstance(item, dict) and item.get("key") == ENV_NAME and item.get("value"):
            return _validate(str(item["value"])), None
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
        if len(values) == 1:
            return _validate(values[0])
    return None


def credentials():
    """Return (key, source). Exits 4 or 5 with guidance when nothing resolves."""
    value = os.environ.get(ENV_NAME)
    if value:
        key = _validate(value)
        if not key:
            sys.exit(f"vastai: {ENV_NAME} is set but is not a plausible key; unset it or fix it.")
        return key, "env:" + ENV_NAME
    key, failure = _bws_key()
    if key:
        return key, "bws:" + ENV_NAME
    key = _secrets_key()
    if key:
        return key, "~/.secrets"
    if failure == "bws_timeout":
        print(f"vastai: bws did not respond within {BWS_TIMEOUT}s and no local {ENV_NAME} was found. "
              "Retry later; do not re-seed the key, it may still exist.", file=sys.stderr)
        sys.exit(5)
    if failure == "bws_unavailable":
        print(f"vastai: bws could not be read (failed twice or returned unreadable output) and no local "
              f"{ENV_NAME} was found. Retry later or check bws access; do not re-seed the key.", file=sys.stderr)
        sys.exit(5)
    print(
        f"vastai: no vast.ai key found. Checked env {ENV_NAME}, bws {ENV_NAME}, and ~/.secrets. "
        f"Store the key in bws as {ENV_NAME} or export {ENV_NAME}.",
        file=sys.stderr,
    )
    sys.exit(4)


def canonical_flag(token):
    """The vendor global flag that `token` spells or unambiguously abbreviates,
    with any `=value` removed: `--cur` and `--curl=x` are both `--curl`. None for
    a positional, a short option, a bare `--`, or a prefix argparse would reject
    as ambiguous (`--r` could be `--raw` or `--retry`)."""
    if not token.startswith("--") or len(token) == 2:
        return None
    name = token.partition("=")[0]
    if name in GLOBAL_FLAGS:
        return name
    matches = [flag for flag in GLOBAL_FLAGS if flag.startswith(name)]
    return matches[0] if len(matches) == 1 else None


def positionals(args):
    """The command words, skipping vendor global flags and their values."""
    words = []
    skip = False
    for token in args:
        if skip:
            skip = False
            continue
        if token.startswith("-"):
            if canonical_flag(token) in VALUE_FLAGS and "=" not in token:
                skip = True
            continue
        words.append(token)
    return words


def url_arguments(args):
    """Every value given to --url or an abbreviation of it, as --url X or --url=X."""
    values = []
    for index, token in enumerate(args):
        if canonical_flag(token) != "--url":
            continue
        _name, separator, value = token.partition("=")
        if separator:
            values.append(value)
        elif index + 1 < len(args):
            values.append(args[index + 1])
    return values


def is_loopback(url):
    try:
        host = urllib.parse.urlparse(url).hostname
    except ValueError:
        return False
    return host in LOOPBACK_HOSTS


def refuse(message):
    print("vastai: refused: " + message, file=sys.stderr)
    sys.exit(2)


def warn_about_key_files():
    """A plaintext key file is ignored while the env var is set, but the vendor
    silently falls back to it after a 401 when a 2FA session file exists, and
    policy says no key file at all. Warn; never delete."""
    config = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    candidates = [Path.home() / ".vast_api_key", config / "vastai/vast_api_key", config / "vastai/vast_tfa_key"]
    present = [str(p) for p in candidates if p.is_file()]
    if present:
        print("vastai: warning: plaintext vast.ai key file present and ignored by this wrapper; "
              "the key lives in bws, delete: " + ", ".join(present), file=sys.stderr)


# The vendor prints per-instance credentials in clear: `create instance --raw`
# answers {"new_contract": N, "success": true, "instance_api_key": "<64 hex>"}
# (observed live 2026-10-13) and the non-raw form echoes the same dict with
# single quotes. Agents paste create output into issues, so every `*api_key`
# string field is redacted on the way out, on both streams, bytes in and out.
# `show instance(s) --raw` carries each instance's "jupyter_token" in clear
# (observed live 2026-10-14: the audit command echoed another session's); it
# is the password of the instance's Jupyter server, so it is redacted too.
SECRET_FIELD = re.compile(rb"""(["'](?:[A-Za-z0-9_]*api_key|jupyter_token)["']\s*:\s*)(["'])[^"'\s]*\2""")
REDACTED = b"[redacted by the vastai wrapper]"


def redact(line):
    return SECRET_FIELD.sub(lambda match: match.group(1) + match.group(2) + REDACTED + match.group(2), line)


def pump(stream, sink, on_line=None):
    """Copy `stream` to `sink` line by line, redacted; stop quietly if the
    reader went away (vastai … | head)."""
    try:
        for line in stream:
            if on_line is not None:
                on_line(line)
            sink.write(redact(line))
            sink.flush()
    except (BrokenPipeError, ValueError):
        pass


def relay(binary, args, env):
    """Run the vendor binary with both streams relayed line by line (secret
    fields redacted) and repair the exit status: the vendor exits 0 after an
    API error."""
    try:
        proc = subprocess.Popen([str(binary), *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        print(f"vastai: cannot run {binary}: {exc}", file=sys.stderr)
        return 3
    seen = {"api_error": False}

    def inspect_stderr(line):
        stripped = line.decode("utf-8", "replace").strip()
        if API_ERROR_TEXT.match(stripped):
            seen["api_error"] = True
        elif stripped.startswith("{") and '"error"' in stripped:
            try:
                seen["api_error"] = seen["api_error"] or json.loads(stripped).get("error") is True
            except (ValueError, AttributeError):
                pass

    pumps = [threading.Thread(target=pump, args=(proc.stdout, sys.stdout.buffer), daemon=True),
             threading.Thread(target=pump, args=(proc.stderr, sys.stderr.buffer, inspect_stderr), daemon=True)]
    try:
        for thread in pumps:
            thread.start()
        for thread in pumps:
            thread.join()
        rc = proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait()
        return 130
    api_error = seen["api_error"]
    if rc == 0 and api_error:
        print("vastai: the vendor reported an API error and exited 0; exiting 1 instead.", file=sys.stderr)
        return 1
    return rc


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)

    if args == ["--where"]:
        key, source = credentials()
        print(source)
        return 0

    for token in args:
        flag = canonical_flag(token)
        spelled = flag if token.partition("=")[0] == flag else f"{token} (argparse reads it as {flag})"
        if flag == "--api-key":
            refuse(f"{spelled} puts the key in argv. Export {ENV_NAME} instead; the wrapper injects it "
                   "from bws when the env var is absent.")
        if flag in ("--explain", "--curl"):
            refuse(f"{spelled} prints the full API key to stdout (vendor api/client.py). Read the vendor "
                   "source or use a fake key in a scratch HOME instead.")
    for url in url_arguments(args):
        if not is_loopback(url):
            refuse(f"--url {url!r} would send the API key to a host other than vast.ai's console. "
                   "Only a loopback stub is accepted.")
    vast_url = os.environ.get("VAST_URL")
    if vast_url and not is_loopback(vast_url):
        refuse(f"VAST_URL={vast_url!r} is set in the environment and would redirect the API key. Unset it.")

    words = positionals(args)
    if words[:2] == ["set", "api-key"]:
        refuse("`set api-key` writes a plaintext key file. The key lives in bws as "
               f"{ENV_NAME}; rotate it with scripts/secrets.sh seed {ENV_NAME}.")
    if words[:1] == ["update"]:
        venv = venv_dir()
        refuse("`update` self-updates outside the uv-managed venv. Recreate it instead:\n"
               + RECREATE.format(venv=venv))
    if words[:1] == ["destroy"] and words[1:2] and words[1] in ("instance", "instances"):
        if not ({"-y", "--yes"} & set(args)):
            refuse(f"`destroy {words[1]}` without -y prompts, and with no terminal the vendor prints "
                   "\"Aborted.\" and exits 0, so billing continues while the command looks successful. "
                   "Pass -y, then confirm with `vastai show instance <id> --raw`.")

    venv = venv_dir()
    binary = venv / "bin/vastai"
    if not os.access(binary, os.X_OK):
        print(f"vastai: venv missing at {venv}", file=sys.stderr)
        print("vastai: recreate it with:\n" + RECREATE.format(venv=venv), file=sys.stderr)
        sys.exit(3)

    env = dict(os.environ)
    env.pop("VASTAI_BWS_TIMEOUT_SECONDS", None)
    env.pop("VASTAI_MANIFEST_URL", None)
    env["VASTAI_NO_UPDATE_CHECK"] = "1"
    flags = {canonical_flag(token) for token in args}
    needs_credential = bool(words) and words[0] != "help" and "-h" not in args and not (NO_CREDENTIAL_FLAGS & flags)
    if needs_credential:
        warn_about_key_files()
        key, _source = credentials()
        env[ENV_NAME] = key
        if "--raw" not in flags:
            if "--no-color" not in flags and not sys.stdout.isatty():
                args = ["--no-color", *args]
            if "--full" not in flags:
                args = ["--full", *args]
    else:
        env.pop(ENV_NAME, None)
        if not vast_url:
            env["VAST_URL"] = NO_NETWORK_URL
    sys.stdout.flush()
    sys.stderr.flush()
    return relay(binary, args, env)


if __name__ == "__main__":
    sys.exit(main())
