#!/usr/bin/env python3
"""Run this repository's CI steps on this host, in front of CI.

Read .github/workflows/ci.yml (or --workflow), in job and step order.
Checkout, setup actions and provisioning commands are skipped. Other actions,
CI-only conditions, non-bash shells and commands that cannot run here are
reported. Single-line bash/python3/node/uv commands run once per run text,
with the step's env and working-directory. Lint commands come from the workflow.

A thread pool of --jobs runs suites under CI's bash -eo pipefail shell, with
umask 022, process groups and a per-suite timeout (default: 1800 seconds).
Interrupts kill children too. Logs live in a unique /tmp directory, removed
after every executed suite passes unless --keep-scratch was given.

This screen is not a sandbox: the workflow is trusted, reviewed code. Suites
use the real $HOME and host tools, in parallel. Suites writing shared host
state (~/.claude, user units, docker, fixed /tmp paths) can collide; run those
with --jobs 1. This is not CI proof. CI remains the gate on every run.

A clean committed head with an origin can record its result for --read;
--no-lint and CLAUDE_LOOP_GUARD=1 refuse records. --applies checks for a draft
aggregate in the tree's or base ref's workflow. Records retain unrun steps as
partial evidence. Exit codes: 0 every executed suite passed or --dry-run;
1 a suite failed; 2 bad arguments, workflow, file or git state;
3 nothing runnable; 4 --read found no record; 130 interrupted.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"

# Single-line commands supported on a developer host.
RUNNABLE_PREFIXES = ("bash ", "python3 ", "node ", "uv run ")
FORBIDDEN_TOKENS = (
    "sudo ",
    "apt-get",
    "dcg/install.sh",
    "$GITHUB_",
    "${GITHUB_",
    "$RUNNER_",
    "${RUNNER_",
    "${{",
    "::group::",
)
# A bare step carrying one of these provisions the runner; it is CI's own and
# is never listed as "not run locally".
PROVISION_TOKENS = ("sudo ", "apt-get", "dcg/install.sh")
# A CI step that appends NAME=value to $GITHUB_ENV hands NAME to every later
# step of its job. The runner never runs such a step, so a suite that reads
# NAME would run here without it and read red (usage-source-roots.test.py
# raised on a missing CODEX_CLOUD_CCUSAGE_BIN, dotfiles#1598).
ENV_EXPORT_RE = re.compile(r"""["'\s]([A-Z][A-Z0-9_]*)=""")
# The shell GitHub gives a run: step with no shell: key on a Linux runner, so a
# pipeline fails here exactly when it fails there.
CI_SHELL = ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]

Plan = list[tuple[str, str, Path, dict]]  # label, cmd, cwd, env
Report = list[tuple[str, str]]  # label, reason


class UsageError(Exception):
    """Bad arguments, workflow, file or git state: exit 2."""


class Step:
    def __init__(self, name: str, run: str, wd: str | None, env: dict):
        self.name = name
        self.run = run
        self.wd = wd
        self.env = env

    def runnable_reason(self) -> str | None:
        """None when the step can run here, else why it is reported instead."""
        text = self.run.strip()
        if "\n" in text:
            return "multi-line CI step"
        for tok in FORBIDDEN_TOKENS:
            if tok in text:
                return f"CI step uses {tok.strip()}"
        if not text.startswith(RUNNABLE_PREFIXES):
            return "CI step is not a bash/python3/node/uv command"
        return None

    def is_provisioning(self) -> bool:
        return any(tok in self.run for tok in PROVISION_TOKENS)

    def label(self) -> str:
        return self.name or self.run.strip().splitlines()[0]


def load_workflow(path: Path) -> dict:
    import yaml

    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        raise UsageError("workflow must contain jobs")
    return doc


def workflow_steps(doc: dict):
    """Every step paired with its job's condition, in workflow order."""
    for job in doc["jobs"].values():
        for step in job.get("steps") or []:
            yield step, job.get("if")


def ci_env_exports(doc: dict) -> dict[str, str]:
    """NAME -> the CI step that exports it through $GITHUB_ENV."""
    exports: dict[str, str] = {}
    for job in (doc.get("jobs") or {}).values():
        for st in job.get("steps") or []:
            run = st.get("run")
            if isinstance(run, str) and "GITHUB_ENV" in run:
                for name in ENV_EXPORT_RE.findall(run):
                    exports.setdefault(
                        name, str(st.get("name") or run.strip().splitlines()[0])
                    )
    return exports


def ci_provided(cmd: str, cwd: Path, env: dict, exports: dict[str, str]) -> list[str]:
    """The CI-exported names a suite reads that this host does not set, from
    its command and the files the command names. Decided before anything
    runs, so a real failure is never reported as not run."""
    missing = [n for n in exports if n not in os.environ and n not in env]
    if not missing:
        return []
    texts = [cmd]
    for tok in cmd.split():
        path = cwd / tok
        if path.is_file():
            try:
                texts.append(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                pass
    text = "\n".join(texts)
    return sorted(n for n in missing if re.search(rf"\b{re.escape(n)}\b", text))


def lint_commands(bare: list[Step]) -> list[tuple[str, str, Step]]:
    """(label, command, step) for the bash -n loop and the shellcheck line,
    taken verbatim from the workflow's own run text so the operand lists
    never drift from CI's."""
    out: list[tuple[str, str, Step]] = []
    for st in bare:
        for line in st.run.splitlines():
            s = line.strip()
            if s.startswith("for f in ") and "bash -n" in st.run:
                operands = s[len("for f in ") :].split(";")[0].strip()
                out.append(
                    (
                        "bash -n",
                        f'for f in {operands}; do bash -n "$f" || exit 1; done',
                        st,
                    )
                )
            elif s.startswith("shellcheck -S error"):
                out.append(("shellcheck", s, st))
    return out


# Every suite process still running, so an interrupt can kill their process
# groups: a suite started in its own session never sees the terminal's Ctrl-C.
_live: set[subprocess.Popen] = set()
_live_lock = threading.Lock()


def kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass


def kill_live() -> int:
    with _live_lock:
        procs = list(_live)
    for proc in procs:
        kill_group(proc)
    return len(procs)


def run_one(
    label: str, cmd: str, cwd: Path, env: dict, log_path: Path, timeout: int
) -> tuple[str, int, float]:
    """Run one suite under CI's shell in its own process group so a timeout
    or an interrupt kills the suite's children too, not only the bash that
    started them."""
    start = time.monotonic()
    with open(log_path, "wb") as fh:
        try:
            proc = subprocess.Popen(
                CI_SHELL + [cmd],
                cwd=cwd,
                env=env,
                stdout=fh,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as exc:
            fh.write(f"run-affected-suites: could not start: {exc}\n".encode())
            return label, 126, time.monotonic() - start
        with _live_lock:
            _live.add(proc)
        try:
            try:
                rc = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                kill_group(proc)
                proc.wait()
                fh.write(
                    f"\nrun-affected-suites: timed out after {timeout}s; process group killed\n".encode()
                )
                rc = 124
        finally:
            with _live_lock:
                _live.discard(proc)
    return label, rc, time.monotonic() - start


def tail(path: Path, lines: int = 60) -> str:
    try:
        data = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(data[-lines:])


def remove_scratch(scratch: Path, created: os.stat_result) -> None:
    """Remove only the /tmp directory this run created, never a replacement."""
    if scratch.parent != Path("/tmp") or not scratch.name.startswith(
        "run-affected-suites."
    ):
        return
    try:
        current = scratch.lstat()
        if scratch.resolve().parent != Path("/tmp") or (
            current.st_dev,
            current.st_ino,
        ) != (created.st_dev, created.st_ino):
            return
        shutil.rmtree(scratch)
    except OSError as exc:
        print(
            f"affected-suites: could not remove scratch {scratch}: {exc}",
            file=sys.stderr,
        )


# dotfiles#1598: a draft's evidence is this run's result, recorded against the
# commit it tested. One JSON record per commit plus the suites' combined log,
# outside the owner's fenced state root so a fix session can record and the
# owner can read. Readers ask --applies before taking a draft path and --read
# for the record at a head.
RECORD_SCHEMA = 1
RECORD_KEEP_DAYS = 14
READ_ABSENT_EXIT = 4  # 3 stays the nothing-runnable exit
DRAFT_CONTEXT = "Harness suites (draft)"


def record_root() -> Path:
    return Path.home() / ".claude" / ".loop-state" / "local-suites"


def origin_slug(repo: Path) -> str | None:
    """owner--repo from the origin remote, lowercased like pr-owner's keys."""
    try:
        url = subprocess.check_output(
            ["git", "remote", "get-url", "origin"],
            cwd=repo,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$", url)
    if not m:
        return None
    return f"{m.group(1)}--{m.group(2)}".lower()


def resolve_commit(repo: Path, rev: str) -> str | None:
    try:
        return (
            subprocess.check_output(
                ["git", "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
                cwd=repo,
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            or None
        )
    except (OSError, subprocess.CalledProcessError):
        return None


class Recorder:
    """Record a clean committed head when the full local plan was requested."""

    def __init__(self, repo: Path, args: argparse.Namespace):
        self.repo = repo
        self.args = args
        self.sha: str | None = None
        self.dir: Path | None = None
        self.why_not: str | None = None
        # The record stands in for CI's suites at this commit, and CI runs the
        # bash -n and shellcheck steps; a run without them proves less.
        if args.no_lint:
            self.why_not = "--no-lint skips the lint steps CI runs at this commit"
            return
        # The suites that drive pr-owner and the pro-gate loop refuse under the
        # loop-authority fence by design, so a fenced fix session would record
        # them red. pr-owner.sh refuses the fence, so the owner runs unfenced and
        # records the head itself when no record exists.
        if os.environ.get("CLAUDE_LOOP_GUARD") == "1":
            self.why_not = "CLAUDE_LOOP_GUARD=1: suites that refuse under the loop-authority fence would read red; the PR owner records this commit unfenced"
            return
        slug = origin_slug(repo)
        if not slug:
            self.why_not = "no GitHub origin remote to key the record by"
            return
        self.sha = resolve_commit(repo, "HEAD")
        if not self.sha:
            self.why_not = "HEAD does not resolve to a commit"
            return
        try:
            dirty = subprocess.check_output(
                ["git", "status", "--porcelain"], cwd=repo, text=True
            )
        except (OSError, subprocess.CalledProcessError):
            dirty = "?"
        if dirty.strip():
            self.why_not = "the working tree has uncommitted or untracked changes, so this run did not test HEAD alone"
            return
        self.dir = record_root() / slug

    def write(
        self,
        selected: list[str],
        results: list[tuple[str, int, float]],
        not_run: Report,
        log_names: dict[str, Path] | None = None,
    ) -> None:
        if self.why_not or self.dir is None or self.sha is None:
            print(f"local result not recorded: {self.why_not}")
            return
        if resolve_commit(self.repo, "HEAD") != self.sha:
            print("local result not recorded: HEAD moved during the run")
            return
        failed = sorted(label for label, rc, _ in results if rc != 0)
        outcome = "fail" if failed else ("partial" if not_run else "pass")
        record = {
            "schema": RECORD_SCHEMA,
            "repo": self.dir.name,
            "sha": self.sha,
            "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "host": socket.gethostname(),
            "base_ref": self.args.base_ref,
            "selected": selected,
            "ran": [
                {"suite": label, "exit": rc, "seconds": round(secs, 1)}
                for label, rc, secs in results
            ],
            "failed": failed,
            "not_run": [{"suite": key, "reason": why} for key, why in not_run],
            "outcome": outcome,
        }
        self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        log_path = self.dir / f"{self.sha}.log"
        record["log"] = str(log_path)
        parts: list[str] = []
        for label, rc, secs in results:
            body = ""
            if log_names and label in log_names:
                try:
                    body = log_names[label].read_text(
                        encoding="utf-8", errors="replace"
                    )
                except OSError:
                    body = "(log unreadable)\n"
            parts.append(f"=== {label} (exit {rc}, {secs:.1f}s) ===\n{body}")
        atomic_write(log_path, "".join(parts))
        out = self.dir / f"{self.sha}.json"
        atomic_write(out, json.dumps(record, indent=2) + "\n")
        prune_records(self.dir, keep=(out, log_path))
        print(f"local result recorded: {outcome} at {out}")


def atomic_write(path: Path, data: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def prune_records(directory: Path, keep: tuple[Path, ...]) -> None:
    cutoff = time.time() - RECORD_KEEP_DAYS * 86400
    for entry in directory.iterdir():
        if entry in keep or entry.suffix not in (".json", ".log"):
            continue
        try:
            if entry.stat().st_mtime < cutoff:
                entry.unlink()
        except OSError:
            pass


def read_record(repo: Path, rev: str) -> int:
    sha = resolve_commit(repo, rev)
    if not sha:
        print(
            f"affected-suites: {rev} does not resolve to a commit in {repo}",
            file=sys.stderr,
        )
        return 2
    slug = origin_slug(repo)
    if not slug:
        print(f"affected-suites: {repo} has no GitHub origin remote", file=sys.stderr)
        return 2
    path = record_root() / slug / f"{sha}.json"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return READ_ABSENT_EXIT
    except (OSError, ValueError) as exc:
        print(f"affected-suites: unreadable record {path}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(record))
    return 0


def gate_applies(repo: Path, base_ref: str = "origin/main") -> bool:
    """Find the draft aggregate in the tree or the base workflow."""
    import yaml

    rel = ".github/workflows/ci.yml"
    docs = []
    try:
        docs.append(load_workflow(repo / rel))
    except Exception:  # noqa: BLE001 -- unreadable or unparsable: no gate here
        pass
    try:
        base = subprocess.run(
            ["git", "show", f"{base_ref}:{rel}"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        )
        docs.append(yaml.safe_load(base.stdout) or {})
    except Exception:  # noqa: BLE001 -- absent, unreadable or unparsable base: the tree decides
        pass
    return any(
        DRAFT_CONTEXT in str((job or {}).get("name") or "")
        for doc in docs
        for job in ((doc.get("jobs") if isinstance(doc, dict) else None) or {}).values()
    )


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--repo",
        default=str(REPO_ROOT),
        help="repository root (default: this checkout)",
    )
    parser.add_argument(
        "--workflow",
        default=None,
        help="ci.yml (default: <repo>/.github/workflows/ci.yml)",
    )
    parser.add_argument(
        "--base-ref", default="origin/main", help="base workflow ref for --applies"
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=max(1, (os.cpu_count() or 2) - 2),
        help="parallel suites",
    )
    # pr-owner.test.sh takes 1224.7s under a full 26-worker run (418s alone).
    parser.add_argument(
        "--timeout",
        type=int,
        default=1800,
        help="seconds per suite (default: %(default)s)",
    )
    parser.add_argument(
        "--keep-scratch",
        action="store_true",
        help="keep /tmp suite logs even when every executed suite passes",
    )
    parser.add_argument(
        "--no-lint", action="store_true", help="skip bash -n and shellcheck"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print the plan, run nothing"
    )
    parser.add_argument(
        "--read",
        metavar="REV",
        help="print the recorded local result for REV (a SHA or HEAD) as JSON; exit 4 when none exists",
    )
    parser.add_argument(
        "--applies",
        metavar="REPO",
        help="exit 0 when REPO carries the draft gate (a draft-named aggregate in REPO's workflow or --base-ref's), else 1",
    )
    return parser.parse_args(argv)


def build_plan(doc: dict, repo: Path, lint: bool) -> tuple[Plan, Report, list[str]]:
    """Classify every workflow step; preserve labels in workflow order."""
    plan: Plan = []
    not_run: Report = []
    selected: list[str] = []
    planned_commands: set[str] = set()
    for raw, job_condition in workflow_steps(doc):
        action = raw.get("uses")
        if action and re.match(r"actions/(?:checkout@|setup-[^@]+@)", action):
            continue
        run = raw.get("run")
        if not action and not isinstance(run, str):
            continue
        st = Step(
            str(raw.get("name") or ""),
            run or "",
            raw.get("working-directory"),
            dict(raw.get("env") or {}),
        )
        label = (st.name or action) if action else run.strip().splitlines()[0]
        lints = lint_commands([st]) if not action else []
        if not action and st.is_provisioning() and not lints:
            continue
        why = None
        if action:
            why = f"`uses: {action}` runs only in CI"
        elif "shell" in raw and raw["shell"] != "bash":
            why = f"shell {raw['shell']} runs only in CI"
        else:
            for condition in (job_condition, raw.get("if")):
                if condition is None:
                    continue
                cond = str(condition).strip()
                if cond.startswith("${{") and cond.endswith("}}"):
                    cond = cond[3:-2].strip()
                if cond not in ("!cancelled()", "always()", "success()"):
                    why = f"runs only when {condition}, which CI evaluates"
                    break
        if not why and lints:
            if lint:
                for lint_label, cmd, _ in lints:
                    selected.append(lint_label)
                    tool = "shellcheck" if lint_label == "shellcheck" else "bash"
                    if shutil.which(tool) is None:
                        not_run.append(
                            (
                                lint_label,
                                f"{tool} is not installed on this host; CI provisions it",
                            )
                        )
                    else:
                        plan.append((lint_label, cmd, repo, {}))
            continue
        why = why or st.runnable_reason()
        if not why and run.strip() in planned_commands:
            continue
        selected.append(label)
        if why:
            not_run.append((label, why))
        else:
            planned_commands.add(run.strip())
            plan.append((label, run.strip(), repo / (st.wd or "."), st.env))
    return plan, not_run, selected


def screen_plan(
    plan: Plan, not_run: Report, exports: dict[str, str] | None = None
) -> tuple[Plan, Report]:
    """Step env and working-directory come from the workflow too; an Actions
    expression there cannot be evaluated here, and a missing directory would
    abort the pool, so both are screened before anything runs, as is a
    suite that reads env an earlier CI step exports (ci_env_exports)."""
    screened: Plan = []
    for label, cmd, cwd, env in plan:
        bad = [k for k, v in env.items() if "${{" in str(v)]
        needs = ci_provided(cmd, cwd, env, exports or {}) if cwd.is_dir() else []
        if bad:
            not_run.append(
                (label, f"step env {', '.join(bad)} uses an Actions expression")
            )
        elif not cwd.is_dir():
            not_run.append((label, f"working-directory {cwd} does not exist"))
        elif needs:
            by = ", ".join(sorted({repr((exports or {})[n]) for n in needs}))
            not_run.append(
                (
                    label,
                    f"needs {', '.join(needs)}, which CI step {by} exports; not set here",
                )
            )
        else:
            screened.append((label, cmd, cwd, env))
    return screened, not_run


def _on_term(signum, frame) -> None:
    raise KeyboardInterrupt


def execute(
    plan: Plan, jobs: int, timeout: int, scratch: Path
) -> tuple[list[tuple[str, int, float]], dict[str, Path], bool]:
    """Run the plan; (results, log paths, interrupted). On Ctrl-C or SIGTERM
    the queued suites are cancelled, the running ones' process groups killed,
    and the results so far returned with interrupted=True."""
    results: list[tuple[str, int, float]] = []
    # CI creates files under umask 022. A group-writable default (0002 here)
    # reds every suite that refuses a group-writable parent directory
    # (docker-daemon-config.py), so the suites run under CI's umask.
    os.umask(0o022)
    base_env = dict(os.environ)
    log_names: dict[str, Path] = {}
    for i, (label, _, _, _) in enumerate(plan):
        log_names[label] = scratch / (
            f"{i:03d}-" + re.sub(r"[^A-Za-z0-9._-]+", "_", label)[:80] + ".log"
        )
    interrupted = False
    signal.signal(signal.SIGTERM, _on_term)

    def launch(items: Plan, workers: int) -> None:
        nonlocal interrupted
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
            futures = []
            for label, cmd, cwd, env in items:
                merged = dict(base_env)
                merged.update({k: str(v) for k, v in env.items()})
                futures.append(
                    pool.submit(
                        run_one, label, cmd, cwd, merged, log_names[label], timeout
                    )
                )
            try:
                for fut in concurrent.futures.as_completed(futures):
                    label, rc, secs = fut.result()
                    results.append((label, rc, secs))
                    print(
                        f"  {'pass' if rc == 0 else 'FAIL'}  {secs:6.1f}s  {label}",
                        flush=True,
                    )
            except KeyboardInterrupt:
                interrupted = True
                queued = sum(1 for f in futures if f.cancel())
                killed = kill_live()
                print(
                    f"\ninterrupted: {killed} running suite(s) killed, {queued} queued suite(s) not started",
                    flush=True,
                )
                # The killed suites' workers return now; the pool's exit
                # waits for them, briefly.

    # The whole-tree shellcheck is the one memory-heavy step (a tree-wide run
    # has been measured past 13 GB); it runs alone, after the pool drains.
    heavy = [p for p in plan if p[0] == "shellcheck"]
    pooled = [p for p in plan if p[0] != "shellcheck"]
    launch(pooled, jobs)
    if not interrupted:
        launch(heavy, 1)
    return results, log_names, interrupted


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = Path(args.repo).resolve()
    if args.applies:
        return 0 if gate_applies(Path(args.applies).resolve(), args.base_ref) else 1
    if args.read:
        return read_record(repo, args.read)
    recorder = None if args.dry_run else Recorder(repo, args)
    workflow_path = (
        Path(args.workflow) if args.workflow else repo / ".github/workflows/ci.yml"
    )
    try:
        doc = load_workflow(workflow_path)
        plan, not_run, selected = build_plan(doc, repo, lint=not args.no_lint)
        plan, not_run = screen_plan(plan, not_run, ci_env_exports(doc))
        order = {label: i for i, label in enumerate(selected)}
        not_run.sort(key=lambda item: order[item[0]])
    except Exception as exc:
        print(f"affected-suites: cannot read workflow: {exc}", file=sys.stderr)
        return 2
    workflow_label = (
        workflow_path.relative_to(repo)
        if workflow_path.is_relative_to(repo)
        else workflow_path
    )
    print(
        f"workflow: {workflow_label}; {len(plan)} runnable here; {len(not_run)} not run locally (CI remains the gate)"
    )
    if not plan:
        print("affected-suites: nothing runnable on this host (CI remains the gate)")
        for key, why in not_run:
            print(f"not run locally: {key} ({why})")
        if recorder:
            recorder.write(selected, [], not_run)
        return 0 if args.dry_run else 3

    if args.dry_run:
        for label, cmd, cwd, env in plan:
            print(
                f"would run: {label}: {cmd}"
                + (
                    f" (cwd {cwd.relative_to(repo) if cwd != repo else '.'})"
                    if cwd != repo
                    else ""
                )
            )
        for key, why in not_run:
            print(f"not run locally: {key} ({why})")
        return 0

    scratch = Path(tempfile.mkdtemp(prefix="run-affected-suites.", dir="/tmp"))
    created = scratch.stat()
    print(
        f"running {len(plan)} suite(s) with {args.jobs} worker(s); logs under {scratch}"
    )
    results, log_names, interrupted = execute(plan, args.jobs, args.timeout, scratch)

    failed = sorted((label, rc) for label, rc, _ in results if rc != 0)
    for label, rc in failed:
        log_path = log_names[label]
        print(f"\n--- FAIL {label} (exit {rc}); last lines of {log_path}:")
        print(tail(log_path))
    if interrupted:
        print(
            f"affected-suites: interrupted after {len(results)} of {len(plan)} suite(s); nothing is proven; logs under {scratch}"
        )
        return 130
    for key, why in not_run:
        print(f"not run locally: {key} ({why})")
    total = sum(s for _, _, s in results)
    print(
        f"affected-suites: {len(results) - len(failed)} pass / {len(failed)} fail / {len(not_run)} not run locally; "
        f"{total:.0f}s of suite time (CI remains the gate)"
    )
    cleanup = not failed and len(results) == len(plan) and not args.keep_scratch
    try:
        if recorder:
            recorder.write(selected, results, not_run, log_names)
    except BaseException:
        # An interrupted or failed record leaves the scratch logs as the only
        # evidence of the run, so they stay for the reader to inspect.
        cleanup = False
        raise
    finally:
        # The recorder must copy the suite logs before a green run removes them.
        if cleanup:
            remove_scratch(scratch, created)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
