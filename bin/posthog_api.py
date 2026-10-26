#!/usr/bin/env python3
"""Run `posthog-cli api` against one named PostHog project.

  posthog-api PROJECT [posthog-cli api arguments ...]
  posthog-api --projects

PROJECT is an alias from the host project map (for example acme-web) or a numeric
project id. Everything after it passes to `posthog-cli api` unchanged, so the
command surface is `posthog-cli api --agent-help`; destructive tools there
still refuse without their own --confirm.

Why a wrapper: posthog-cli 0.8.2 resolves the project from env, but when no
organization id is set it calls setDefaultOrganizationAndProject, which
replaces the project with the account's server-side active team. A
project-only override therefore silently answers from the wrong project. This
wrapper sets the organization AND project in every env name
the CLI reads (the unprefixed POSTHOG_* names win over POSTHOG_CLI_*), and
gives permission rules a command name to match, since an allow rule does
not match past a VAR=value prefix.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
from pathlib import Path

VERSION = "0.1.0"
PROJECTS_ENV = "POSTHOG_API_PROJECTS_FILE"
PROJECTS_NAME = "posthog-projects.json"
PROJECT_ENV = ("POSTHOG_PROJECT_ID", "POSTHOG_CLI_PROJECT_ID", "POSTHOG_CLI_ENV_ID")
ORG_ENV = ("POSTHOG_ORGANIZATION_ID", "POSTHOG_CLI_ORGANIZATION_ID")
USAGE = "usage: posthog-api PROJECT [posthog-cli api arguments ...] | posthog-api --projects"


def projects_file():
    override = os.environ.get(PROJECTS_ENV)
    if override:
        return Path(override)
    overlay = os.environ.get("HOV_STACK_OVERLAY")
    if overlay:
        return Path(overlay) / PROJECTS_NAME
    return (
        Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        / "hov-stack"
        / PROJECTS_NAME
    )


def load_projects():
    """Read the private map only after parsing help/version and usage."""
    path = projects_file()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"projects": {}}
    except (OSError, ValueError):
        raise ValueError(
            f"cannot read project map {path}: expected a UTF-8 JSON object"
        ) from None
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("projects"), dict)
        or not all(
            isinstance(k, str)
            and isinstance(v, str)
            and re.fullmatch(r"[1-9][0-9]{0,11}", v)
            for k, v in data["projects"].items()
        )
        or (
            data.get("organization_id") is not None
            and not (
                isinstance(data["organization_id"], str)
                and re.fullmatch(
                    r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
                    data["organization_id"],
                )
            )
        )
    ):
        raise ValueError(
            f"{path} must hold projects (alias -> numeric ID string) and an optional organization_id UUID"
        )
    return data


def resolve(project, projects):
    if re.fullmatch(r"[1-9][0-9]{0,11}", project):
        return project
    return projects.get(project)


def child_env(project_id, organization_id, base=None):
    env = dict(os.environ if base is None else base)
    for name in PROJECT_ENV:
        env[name] = project_id
    for name in ORG_ENV:
        env[name] = organization_id
    return env


def main(argv=None, execvpe=os.execvpe):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in {"-h", "--help"}:
        print(
            __doc__.strip() if argv else USAGE, file=sys.stdout if argv else sys.stderr
        )
        return 0 if argv else 2
    if argv[0] == "--version":
        print(f"posthog-api {VERSION}")
        return 0
    try:
        data = load_projects()
    except ValueError as exc:
        print(f"posthog-api: {exc}", file=sys.stderr)
        return 2
    projects = data["projects"]
    organization_id = data.get("organization_id") or next(
        (os.environ[name] for name in ORG_ENV if os.environ.get(name)), None
    )
    if argv[0] == "--projects":
        print(
            json.dumps(
                {
                    "organization_id": organization_id,
                    "projects": projects,
                    "projects_file": str(projects_file()),
                },
                sort_keys=True,
            )
        )
        return 0
    project_id = resolve(argv[0], projects)
    if project_id is None:
        print(
            f"posthog-api: unknown project {argv[0]!r}; use an alias from {projects_file()} "
            f"(set {PROJECTS_ENV}; aliases: {', '.join(sorted(projects))}) or a numeric project id.",
            file=sys.stderr,
        )
        return 2
    if not organization_id:
        print(
            f"posthog-api: organization id required: set organization_id in {projects_file()} "
            f"(set {PROJECTS_ENV}), or export POSTHOG_ORGANIZATION_ID or POSTHOG_CLI_ORGANIZATION_ID.",
            file=sys.stderr,
        )
        return 2
    binary = shutil.which("posthog-cli")
    if binary is None:
        print(
            "posthog-api: posthog-cli is not on PATH; install it and run `posthog-cli login`.",
            file=sys.stderr,
        )
        return 1
    execvpe(binary, [binary, "api", *argv[1:]], child_env(project_id, organization_id))
    return 1  # execvpe only returns in tests


if __name__ == "__main__":
    sys.exit(main())
