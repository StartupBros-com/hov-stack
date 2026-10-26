"""Child-launch and result-envelope helpers used by memory-mine-controller.py, moved out of the retired loop_quality package (#1914)."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Mapping

# Only these names are copied into a child. An allowlist, not a denylist: a
# denylist has to predict every credential variable that might exist, and the
# one it fails to predict is the one that leaks.
_ENV_ALLOWLIST = frozenset(
    {
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TZ",
        "TERM",
        "XDG_RUNTIME_DIR",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
    }
)
_ENV_REQUIRED = ("PATH", "HOME")

# States a finished invocation can land in. Only `complete` advances a stage.
_STATE_COMPLETE = "complete"
_STATE_PAUSED = "paused"
_STATE_INTERRUPTED = "interrupted"
_STATE_BLOCKED = "blocked"
# A denial the guard blocked, in a stage that still finished. Advances only
# if its artifact verifies; the denial is recorded either way. (dotfiles#952)
_STATE_DENIED_COMPLETE = "denied-complete"

# terminal_reason -> outcome. `paused` means the run stopped at a configured
# ceiling and is resumable; `interrupted` means it stopped for a reason the
# controller did not choose.
_TERMINAL_STATES = {
    "completed": _STATE_COMPLETE,
    "max_budget": _STATE_PAUSED,
    "max_turns": _STATE_PAUSED,
    "max_tokens": _STATE_PAUSED,
    "timeout": _STATE_INTERRUPTED,
    "error": _STATE_INTERRUPTED,
    "cancelled": _STATE_INTERRUPTED,
}


class SessionError(Exception):
    """Base class for every session-seam failure."""


class LaunchError(SessionError):
    """A child could not be prepared safely, so none was launched."""


class EnvelopeError(SessionError):
    """A result envelope was absent, malformed, or bound to another call."""


@dataclass(frozen=True)
class InvocationOutcome:
    """What one finished invocation actually proved. Inert data."""

    state: str
    advances: bool
    cost_usd: str | None
    served_model: str | None
    terminal_reason: str | None
    stop_reason: str | None
    session_id: str | None
    permission_denials: tuple = field(default=())
    detail: str = ""
    # The model's own text output. Carried so a stage adapter can look for a
    # verified artifact in it; never itself treated as proof of anything.
    result_text: str = ""
    # --json-schema places the validated object here. Presence is separate from
    # value so a malformed structured_output can fail closed rather than falling
    # back to a plausible free-text result.
    structured_output_present: bool = False
    structured_output: Any = None


def _money_str(value: Any) -> str:
    """Normalise a reported cost to a decimal string.

    The CLI reports `total_cost_usd` as a float. Decimal(float) would carry the
    binary artifact into a money field, so it is stringified here at the
    boundary — the state layer refuses floats outright for the same reason.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise EnvelopeError("cost is not a number")
    try:
        amount = Decimal(str(value))
    except InvalidOperation as error:
        raise EnvelopeError("cost is not a decimal") from error
    if not amount.is_finite() or amount < 0:
        raise EnvelopeError("cost is not a finite non-negative amount")
    return format(amount, "f")


def build_child_environment(
    base_env: Mapping[str, str], *, proxy_url: str
) -> dict[str, str]:
    """Construct a child environment from an allowlist.

    A dispatched run must route through the local proxy. An ambient
    `ANTHROPIC_API_KEY` reaching the child could flip the run onto direct,
    unmetered billing, so credential-bearing variables are not filtered out —
    they are simply never copied in.
    """
    if not isinstance(proxy_url, str) or not proxy_url.strip():
        raise LaunchError(
            "no proxy URL: refusing to launch, an ambient key would bill directly"
        )
    if not re.match(r"^https?://[^\s]+$", proxy_url):
        raise LaunchError(f"proxy URL is not http(s): {proxy_url!r}")

    child: dict[str, str] = {}
    for name in sorted(_ENV_ALLOWLIST):
        value = base_env.get(name)
        if isinstance(value, str) and value:
            child[name] = value
    for name in _ENV_REQUIRED:
        if name not in child:
            raise LaunchError(f"${name} is required to launch a child and is unset")
    child["ANTHROPIC_BASE_URL"] = proxy_url
    return child


class SessionRuntime:
    """Owns conversation identity and the judgement of one invocation."""

    def __init__(
        self,
        state_dir: os.PathLike[str] | str,
        required_capabilities: Mapping[str, Any] | None = None,
    ) -> None:
        self._dir = Path(state_dir)
        self._required = dict(required_capabilities or {})

    def classify(
        self, *, exit_code: int, raw: str, expected_session: str
    ) -> InvocationOutcome:
        """Decide what an invocation proved. Never writes state.

        Exit status is not consulted for success: a cut-short run and a finished
        run can both exit 0. Only a well-formed envelope bound to this
        conversation, reporting a clean terminal state with no permission
        denials, advances a stage.
        """

        def interrupted(detail: str, **kwargs) -> InvocationOutcome:
            return InvocationOutcome(
                state=_STATE_INTERRUPTED,
                advances=False,
                cost_usd=kwargs.get("cost_usd"),
                served_model=kwargs.get("served_model"),
                terminal_reason=kwargs.get("terminal_reason"),
                stop_reason=kwargs.get("stop_reason"),
                session_id=kwargs.get("session_id"),
                result_text=kwargs.get("result_text", ""),
                structured_output_present=kwargs.get(
                    "structured_output_present", False
                ),
                structured_output=kwargs.get("structured_output"),
                detail=detail,
            )

        if not isinstance(raw, str) or not raw.strip():
            return interrupted("no output; the child produced no result envelope")
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            return interrupted("output is not JSON; no structured result to judge")
        if not isinstance(doc, dict):
            return interrupted("result envelope is not an object")
        if doc.get("type") != "result":
            return interrupted(f"envelope type is {doc.get('type')!r}, not a result")

        session_id = doc.get("session_id")
        if session_id != expected_session:
            return interrupted(
                "envelope is bound to another conversation", session_id=session_id
            )

        try:
            cost = _money_str(doc.get("total_cost_usd"))
        except EnvelopeError as error:
            return interrupted(f"unusable cost: {error}", session_id=session_id)

        served = self._served_model(doc.get("modelUsage"))
        terminal = doc.get("terminal_reason")
        stop = doc.get("stop_reason")
        result_text = doc.get("result")
        structured_output_present = "structured_output" in doc
        common = {
            "cost_usd": cost,
            "served_model": served,
            "terminal_reason": terminal,
            "stop_reason": stop,
            "session_id": session_id,
            "result_text": result_text if isinstance(result_text, str) else "",
            "structured_output_present": structured_output_present,
            "structured_output": (
                doc.get("structured_output") if structured_output_present else None
            ),
        }

        if doc.get("is_error") is True:
            return interrupted("the run reported is_error", **common)

        raw_denials = doc.get("permission_denials")
        if raw_denials is None:
            denials = []
        elif isinstance(raw_denials, list):
            denials = raw_denials
        else:
            # The CLI contract is a list. Any value of another type is still
            # evidence that the denial field is untrustworthy; treating malformed
            # evidence as empty would let a completed envelope advance fail-open.
            denials = [raw_denials]
        if denials:
            # A fenced run did not do the work; it was stopped from doing it.
            # Current Claude Code envelopes use tool_name/tool_input/tool_use_id;
            # older captured fixtures used tool. Only the name is diagnostic-safe:
            # tool_input may contain credentials or other sensitive command text.
            def bounded_name(value: Any) -> str | None:
                if not isinstance(value, str) or not value.strip():
                    return None
                name = " ".join(value.split())
                return name if len(name) <= 128 else f"{name[:125]}..."

            def denial_tool_name(denial: Any) -> str:
                if isinstance(denial, Mapping):
                    for key in ("tool_name", "tool"):
                        name = bounded_name(denial.get(key))
                        if name:
                            return name
                    return "unnamed tool"
                return bounded_name(denial) or "unnamed tool"

            tools = tuple(denial_tool_name(denial) for denial in denials)
            # Name them. The count alone tells an operator that something was
            # fenced and nothing about what to change -- and the names are
            # already in hand here, one line above where they used to be
            # dropped. Deduplicated and capped, because a run that trips the
            # same guard forty times should not render forty times.
            unique = sorted({name for name in tools if name})
            shown = ", ".join(unique[:5]) or "unnamed tool"
            if len(unique) > 5:
                shown += f", and {len(unique) - 5} more"

            # A denial the guard already blocked did not do any harm -- nothing
            # prohibited executed. If the stage then went on to finish and
            # produce structured output, fencing it destroys real work over an
            # attempt that was already neutralised. Measured across two #900
            # canary runs: five stages fenced, ~$65, and in three of them the
            # child recovered on its own and wrote a valid artifact.
            #
            # So a denial alone no longer decides. It downgrades to a state the
            # caller must still prove: the artifact has to verify like any other
            # (`run_stage` refuses it otherwise), the denial travels in the
            # outcome so it is recorded rather than forgotten, and a stage that
            # did NOT finish is blocked exactly as before. (dotfiles#952)
            if structured_output_present and stop == "end_turn":
                return InvocationOutcome(
                    state=_STATE_DENIED_COMPLETE,
                    advances=True,
                    permission_denials=tools,
                    detail=(
                        f"{len(denials)} permission denial(s) were blocked and the "
                        f"stage finished anyway: {shown}"
                    ),
                    **common,
                )
            return InvocationOutcome(
                state=_STATE_BLOCKED,
                advances=False,
                permission_denials=tools,
                detail=(
                    f"{len(denials)} permission denial(s) fenced this run: {shown}"
                ),
                **common,
            )

        state = _TERMINAL_STATES.get(terminal, _STATE_INTERRUPTED)
        return InvocationOutcome(
            state=state,
            advances=state == _STATE_COMPLETE,
            detail=f"terminal_reason={terminal!r} exit={exit_code}",
            **common,
        )

    @staticmethod
    def _served_model(model_usage: Any) -> str | None:
        """The model that actually answered, not the one that was requested.

        Requested is not served: a proxy can satisfy a Claude-named request from
        another account entirely, and this is the only per-call evidence of it.
        """
        if not isinstance(model_usage, Mapping) or not model_usage:
            return None
        def rank(name: str) -> tuple:
            usage = model_usage.get(name)
            tokens = usage.get("outputTokens", 0) if isinstance(usage, Mapping) else 0
            return (tokens if isinstance(tokens, int) else 0, name)
        return max(sorted(model_usage), key=rank)

    def require_served_model(self, outcome: InvocationOutcome, *, expected: str) -> None:
        if outcome.served_model != expected:
            raise EnvelopeError(
                f"served model was {outcome.served_model!r}, not the pinned {expected!r}"
            )


@dataclass(frozen=True)
class ProcessObservation:
    """A single read of whether a fenced pid is still the prior invocation."""

    alive: bool
    start_time: int | None


def default_process_probe(pid: int) -> ProcessObservation:
    """Observe a pid's liveness and start time without signalling it.

    Uses the Linux procfs start-time field so a recycled pid is distinguishable
    from the original process. On kernels without procfs the start time is
    unavailable, which the caller treats as an unfenceable observation.
    """
    stat_path = Path("/proc") / str(pid) / "stat"
    try:
        raw = stat_path.read_text(encoding="utf-8", errors="replace")
    except (FileNotFoundError, NotADirectoryError, PermissionError, ProcessLookupError):
        try:
            os.kill(pid, 0)
        except (ProcessLookupError, PermissionError, OSError):
            return ProcessObservation(alive=False, start_time=None)
        return ProcessObservation(alive=True, start_time=None)
    # The comm field may contain spaces and parentheses; fields are counted
    # from the final ')' so a process named "a) b" cannot shift the index.
    tail = raw.rpartition(")")[2].split()
    if len(tail) < 20:
        return ProcessObservation(alive=True, start_time=None)
    try:
        start_time = int(tail[19])
    except ValueError:
        return ProcessObservation(alive=True, start_time=None)
    return ProcessObservation(alive=True, start_time=start_time)


__all__ = [
    "SessionError",
    "LaunchError",
    "EnvelopeError",
    "InvocationOutcome",
    "build_child_environment",
    "SessionRuntime",
    "ProcessObservation",
    "default_process_probe",
]
