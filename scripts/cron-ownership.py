#!/usr/bin/env python3
"""Bounded cron ownership parser and record-scoped CAS for two timers.

Cron input is always treated as inert text. Diagnostics identify timers and
states only; they never echo a cron record.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import posixpath
import re
import shlex
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Job:
    suffix: str
    timer: str


JOBS = (
    Job("/.local/bin/update-mcp-servers.sh", "mcp-servers-update.timer"),
    Job("/.local/bin/update-skills.sh", "skills-update.timer"),
)
JOBS_BY_TIMER = {job.timer: job for job in JOBS}

ENVIRONMENT_RECORD = re.compile(
    r"""^\s*[A-Za-z_][A-Za-z0-9_]*=(?:
        "(?:[^"\\]|\\.)*"
        |'(?:[^']*)'
        |[^\s#]*
    )(?:\s+\#.*)?\s*$""",
    re.VERBOSE,
)
HOME_ASSIGNMENT = re.compile(r"^[ \t]*HOME[ \t]*=[ \t]*(?P<value>.*?)[ \t]*$")
SCHEDULE_RECORD = re.compile(
    r"^\s*(?P<minute>\S+)\s+(?P<hour>\S+)\s+(?P<day>\S+)\s+"
    r"(?P<month>\S+)\s+(?P<weekday>\S+)\s+(?P<command>.+?)\s*$"
)
SCHEDULE_FIELD = re.compile(r"^[0-9*/,\-]+$")
REDIRECTION_WITH_TARGET = re.compile(r"^(?:[012]?>>?|[012]?<|&>)\S+$")
REDIRECTION_OPERATOR = re.compile(r"^(?:[012]?>>?|[012]?<|&>)$")
FD_DUPLICATION = re.compile(r"^[012]?>&[012]$")
LOGGER_TAG = re.compile(r"^[A-Za-z0-9_.:-]+$")
MARKER_PREFIX = "# critical-silence: suspended "
MARKER = re.compile(
    r"^# critical-silence: suspended ([A-Za-z0-9_.@-]+\.timer) sha256=([0-9a-f]{64})$"
)


class ContractError(Exception):
    """A safe, record-free contract failure."""


def _read_lines(path: Path) -> tuple[bytes, list[bytes]]:
    try:
        raw = path.read_bytes()
        raw.decode("utf-8", errors="strict")
    except (OSError, UnicodeError) as exc:
        raise ContractError("cron input is unreadable or not UTF-8") from exc
    if b"\0" in raw:
        raise ContractError("cron input contains a NUL byte")
    return raw, raw.splitlines(keepends=True)


def _line_text(raw_line: bytes) -> str:
    return raw_line.rstrip(b"\r\n").decode("utf-8", errors="strict")


def _canonical_home(home: str) -> str:
    normalized = _known_absolute_home(home)
    if normalized is None:
        raise ContractError("canonical HOME is not a static absolute path")
    return normalized


def _known_absolute_home(raw_value: str) -> str | None:
    value = raw_value
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    if not value.startswith("/"):
        return None
    if any(character in value for character in "$`\\~*?[]{}()"):
        return None
    return posixpath.normpath(value)


def _home_assignment_value(record: str) -> str | None:
    """Return a standalone HOME value without interpreting cron text."""
    assignment = HOME_ASSIGNMENT.fullmatch(record)
    if assignment is None:
        return None
    return assignment.group("value")


def _home_variant(job: Job) -> str:
    return f"$HOME{job.suffix}"


def _literal_variant(job: Job, canonical_home: str) -> str:
    return f"{canonical_home.rstrip('/')}{job.suffix}"


def _job_for_token(
    token: str, canonical_home: str, effective_home: str | None
) -> Job | None:
    for job in JOBS:
        if token == _literal_variant(job, canonical_home):
            return job
        if effective_home == canonical_home and token == _home_variant(job):
            return job
    return None


def _mentioned_jobs(
    record: str, canonical_home: str, effective_home: str | None
) -> set[Job]:
    mentioned: set[Job] = set()
    for job in JOBS:
        if _literal_variant(job, canonical_home) in record:
            mentioned.add(job)
        elif effective_home != canonical_home and effective_home is not None:
            continue
        elif _home_variant(job) in record:
            mentioned.add(job)
    return mentioned


def _redirections_only(tokens: list[str]) -> bool:
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if FD_DUPLICATION.fullmatch(token):
            index += 1
            continue
        if REDIRECTION_OPERATOR.fullmatch(token):
            if index + 1 >= len(tokens) or tokens[index + 1] in {"|", ";", "&&", "||"}:
                return False
            index += 2
            continue
        if REDIRECTION_WITH_TARGET.fullmatch(token):
            index += 1
            continue
        return False
    return True


def _supported_tail(tokens: list[str]) -> bool:
    if "|" not in tokens:
        return _redirections_only(tokens)
    if tokens.count("|") != 1:
        return False
    pipe_index = tokens.index("|")
    if not _redirections_only(tokens[:pipe_index]):
        return False
    logger = tokens[pipe_index + 1 :]
    return (
        len(logger) == 3
        and logger[0] in {"logger", "/usr/bin/logger"}
        and logger[1] == "-t"
        and LOGGER_TAG.fullmatch(logger[2]) is not None
    )


def _owned_job_and_tail(
    tokens: list[str],
    canonical_home: str,
    effective_home: str | None,
) -> tuple[Job, list[str]] | None:
    if not tokens:
        return None
    direct_job = _job_for_token(tokens[0], canonical_home, effective_home)
    if direct_job is not None:
        return direct_job, tokens[1:]
    return None


def classify_record(
    raw_line: bytes, canonical_home: str, effective_home: str | None
) -> tuple[str, set[Job]]:
    """Return ignored/active/ambiguous and the affected mapped jobs."""
    record = _line_text(raw_line)
    stripped = record.strip()
    if (
        not stripped
        or stripped.startswith("#")
        or HOME_ASSIGNMENT.fullmatch(record)
        or ENVIRONMENT_RECORD.fullmatch(record)
    ):
        return "ignored", set()

    mentioned = _mentioned_jobs(record, canonical_home, effective_home)
    if not mentioned:
        return "unrelated", set()
    schedule_match = SCHEDULE_RECORD.fullmatch(record)
    if schedule_match is None or len(mentioned) != 1:
        return "ambiguous", mentioned
    if any(
        SCHEDULE_FIELD.fullmatch(schedule_match.group(field)) is None
        for field in ("minute", "hour", "day", "month", "weekday")
    ):
        return "ambiguous", mentioned

    try:
        command_tokens = shlex.split(
            schedule_match.group("command"), comments=False, posix=True
        )
    except ValueError:
        return "ambiguous", mentioned
    owned = _owned_job_and_tail(command_tokens, canonical_home, effective_home)
    if owned is None:
        return "ambiguous", mentioned
    job, tail = owned
    if job not in mentioned or not _supported_tail(tail):
        return "ambiguous", mentioned
    return "active", {job}


def _scan_lines(lines: list[bytes], home: str) -> dict[Job, tuple[str, str]]:
    canonical_home = _canonical_home(home)
    effective_home: str | None = canonical_home
    exact: dict[Job, list[bytes]] = {job: [] for job in JOBS}
    ambiguous: set[Job] = set()
    for raw_line in lines:
        record = _line_text(raw_line)
        home_value = _home_assignment_value(record)
        if home_value is not None:
            effective_home = _known_absolute_home(home_value)
            continue
        if ENVIRONMENT_RECORD.fullmatch(record):
            continue
        state, jobs = classify_record(raw_line, canonical_home, effective_home)
        if state == "active":
            job = next(iter(jobs))
            exact[job].append(raw_line)
        elif state == "ambiguous":
            ambiguous.update(jobs)

    result: dict[Job, tuple[str, str]] = {}
    for job in JOBS:
        if job in ambiguous or len(exact[job]) > 1:
            result[job] = ("ambiguous", "-")
        elif len(exact[job]) == 1:
            digest = hashlib.sha256(exact[job][0]).hexdigest()
            result[job] = ("active", digest)
        else:
            result[job] = ("absent", "-")
    return result


def scan(path: Path, home: str) -> list[tuple[Job, str, str]]:
    _, lines = _read_lines(path)
    classified = _scan_lines(lines, home)
    return [(job, *classified[job]) for job in JOBS]


def _original_record(path: Path, timer: str, home: str) -> tuple[bytes, Job]:
    raw, lines = _read_lines(path)
    if len(lines) != 1 or not raw.endswith((b"\n", b"\r")):
        raise ContractError(
            "original record file must contain exactly one terminated record"
        )
    job = JOBS_BY_TIMER.get(timer)
    if job is None:
        raise ContractError("timer is outside the two-job ownership map")
    canonical_home = _canonical_home(home)
    state, jobs = classify_record(lines[0], canonical_home, canonical_home)
    if state != "active" or jobs != {job}:
        raise ContractError("original record does not exactly own the requested timer")
    return raw, job


def _marker(timer: str, original: bytes) -> str:
    return f"{MARKER_PREFIX}{timer} sha256={hashlib.sha256(original).hexdigest()}"


def _bound_marker_count(lines: list[bytes], timer: str, original: bytes) -> int:
    marker = _marker(timer, original)
    original_digest = hashlib.sha256(original).hexdigest()
    bound_markers = 0
    for line in lines:
        text = _line_text(line)
        if not text.lstrip().startswith("# critical-silence:"):
            continue
        parsed = MARKER.fullmatch(text)
        if parsed is None or parsed.group(1) not in JOBS_BY_TIMER:
            raise ContractError("malformed suspension marker")
        marker_timer, marker_digest = parsed.groups()
        if marker_timer == timer or marker_digest == original_digest:
            if text != marker:
                raise ContractError("suspension marker target/hash conflict")
            bound_markers += 1
    return bound_markers


def _candidate_bytes(
    mode: str, current: bytes, original: bytes, timer: str, home: str
) -> bytes:
    lines = current.splitlines(keepends=True)
    marker = _marker(timer, original)
    original_digest = hashlib.sha256(original).hexdigest()
    job = JOBS_BY_TIMER[timer]
    bound_markers = _bound_marker_count(lines, timer, original)
    current_state, current_digest = _scan_lines(lines, home)[job]

    if mode == "suspend":
        if bound_markers:
            raise ContractError("target already has a suspension marker")
        if current_state != "active" or current_digest != original_digest:
            raise ContractError("target record conflict")
        positions = [index for index, line in enumerate(lines) if line == original]
        if len(positions) != 1:
            raise ContractError("target record conflict")
        ending = b"\r\n" if original.endswith(b"\r\n") else b"\n"
        lines[positions[0]] = marker.encode("utf-8") + ending
    else:
        if bound_markers != 1:
            raise ContractError("bound suspension marker conflict")
        if current_state != "absent":
            raise ContractError("target ownership conflict outside suspension marker")
        positions = [
            index for index, line in enumerate(lines) if _line_text(line) == marker
        ]
        if len(positions) != 1:
            raise ContractError("bound suspension marker conflict")
        if mode == "rollback":
            lines[positions[0]] = original
        elif mode == "remove":
            del lines[positions[0]]
        else:  # argparse prevents this; retain a closed invariant for callers.
            raise ContractError("unsupported CAS transition")

    candidate = b"".join(lines)
    candidate_lines = candidate.splitlines(keepends=True)
    candidate_state, candidate_digest = _scan_lines(candidate_lines, home)[job]
    candidate_markers = _bound_marker_count(candidate_lines, timer, original)
    if mode == "suspend":
        valid = candidate_state == "absent" and candidate_markers == 1
    elif mode == "rollback":
        valid = (
            candidate_state == "active"
            and candidate_digest == original_digest
            and candidate_markers == 0
        )
    else:
        valid = candidate_state == "absent" and candidate_markers == 0
    if not valid:
        raise ContractError("candidate ownership postcondition failed")
    return candidate


def write_candidate(
    mode: str,
    timer: str,
    original_path: Path,
    input_path: Path,
    output_path: Path,
    home: str,
) -> None:
    if output_path.exists():
        raise ContractError("candidate output already exists")
    if input_path.resolve() == output_path.resolve():
        raise ContractError("candidate output must differ from input")
    original, _ = _original_record(original_path, timer, home)
    current, _ = _read_lines(input_path)
    candidate = _candidate_bytes(mode, current, original, timer, home)

    if not output_path.parent.is_dir():
        raise ContractError("candidate output directory does not exist")
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{output_path.name}.", dir=output_path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(candidate)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output_path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    scan_parser = subcommands.add_parser("scan")
    scan_parser.add_argument("--home", default=os.path.expanduser("~"))
    scan_parser.add_argument("input", type=Path)

    cas_parser = subcommands.add_parser("cas")
    cas_parser.add_argument("mode", choices=("suspend", "rollback", "remove"))
    cas_parser.add_argument("--timer", required=True)
    cas_parser.add_argument("--original", required=True, type=Path)
    cas_parser.add_argument("--home", default=os.path.expanduser("~"))
    cas_parser.add_argument("input", type=Path)
    cas_parser.add_argument("output", type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "scan":
            for job, state, digest in scan(args.input, args.home):
                print(f"{job.timer}\t{state}\t{digest}")
        else:
            write_candidate(
                args.mode,
                args.timer,
                args.original,
                args.input,
                args.output,
                args.home,
            )
    except ContractError as exc:
        print(f"cron ownership contract failure: {exc}", file=sys.stderr)
        return 2
    except OSError:
        print(
            "cron ownership contract failure: candidate could not be written",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
