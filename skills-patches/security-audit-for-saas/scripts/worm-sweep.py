#!/usr/bin/env python3
"""Look for the files, hooks, services and git traces npm/PyPI worms leave behind.

Run this BEFORE rotating any credential. Several worms in the Shai-Hulud family
install a monitor that wipes the home directory when the stolen token is revoked,
and plant hooks that re-run the payload in every new agent or editor session.
Rotation only helps once those are gone.

What it checks (all read-only, nothing is executed):
  repos   payload and exfiltration file names anywhere in the tree, node_modules
          included; agent and editor auto-run config (.claude/settings*.json
          SessionStart hooks, .vscode/tasks.json folderOpen tasks, .cursor/rules);
          worm branches, workflows and commits in git history (all refs)
  home    gh-token-monitor and sysmon services, LaunchAgents and scripts; user-level
          Claude hooks naming a payload file; .pth start-up files in user, mise,
          uv, pipx and repo virtualenvs
  tmp     the worms' lock and log files in TMPDIR and /tmp
  github  (only with --github, needs gh) repos on your account named or described
          the way the worm names its exfiltration repos

Every indicator cites the public write-up it came from. A clean result means none
of these known traces were found; it does not prove a machine is clean.

Usage: worm-sweep.py [--repo DIR]... [--home DIR | --no-home] [--tmp DIR]...
                     [--github] [--json FILE]
Exit status: 2 any critical finding, 1 a check could not run, 0 otherwise.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

S = {  # sources, cited in every finding
    "datadog-sh": "Datadog Security Labs, Shai-Hulud open-source framework (2026)",
    "datadog-cd": "Datadog Security Labs, ChainDrop npm worm (Aug 2026)",
    "elastic-cd": "Elastic Security Labs, Shai-Hulud CHAINDROP (Aug 2026)",
    "checkmarx": "Checkmarx, Shai-Hulud keyv/cacheable (2026)",
    "mend": "Mend.io, Shai-Hulud SAP CAP via Claude Code (2026)",
    "upwind": "Upwind, Mini Shai-Hulud npm worm (2026)",
    "stepsec": "StepSecurity, Miasma / Phantom Gyp npm worm (2026)",
    "phoenix": "Phoenix Security, Miasma Red Hat npm wave (Jun 2026)",
    "flashpoint": "Flashpoint, Mini Shai-Hulud and CI/CD exploitation (2026)",
    "socket": "Socket, tensorlake ChainDrop compromise (2026)",
    "sh2": "Sha1-Hulud: The Second Coming write-ups (Aikido, Datadog; Nov 2025)",
    "sh3": "Aikido, Shai-Hulud 3.0 test strain (Dec 2025)",
    "sh1": "Shai-Hulud first wave write-ups (StepSecurity, Sep 2025)",
    "litellm": "BerriAI/litellm issue 24521; Datadog, StepSecurity, Trend Micro (2026)",
    "ghtm": "gh-token-monitor dead-man switch: Socket, Snyk, Orca, JFrog, Securonix (2026)",
}

# Payload and dropper names that worms ship inside packages; critical anywhere.
PAYLOAD = {
    "setup_bun.js": "sh2", "bun_environment.js": "sh2", "bun_installer.js": "sh3",
    "environment_source.js": "sh3", "router_init.js": "upwind", "router_runtime.js": "upwind",
    "tanstack_runner.js": "upwind",
}
# Files the payload writes stolen secrets into before upload; critical anywhere.
# (The plain-English names cloud.json, contents.json, environment.json are too common to flag.)
EXFIL = {
    "truffleSecrets.json": "sh2", "actionsSecrets.json": "sh2",
    "3nvir0nm3nt.json": "sh3", "cl0vd.json": "sh3", "c9nt3nts.json": "sh3", "c0nt3nts.json": "sh3",
    "pigS3cr3ts.json": "sh3",
}
# Files planted in a repo's agent/editor config dirs so the payload re-runs per session.
AGENT_DROP = {
    ".claude": {"setup.mjs": "elastic-cd", "execution.js": "mend", "router_runtime.js": "upwind",
                "router_init.js": "upwind", "Math_Symbol.js": "elastic-cd", "math_init.js": "elastic-cd"},
    ".vscode": {"setup.mjs": "datadog-cd"},
}
KNOWN_FILES = set(PAYLOAD) | {n for d in AGENT_DROP.values() for n in d}
LOCKS = {"tmp.987654321.lock": "phoenix", "tmp.0987654321.lock": "phoenix"}
BRANCHES = {"shai-hulud": "sh1", "dependabot/github_actions/format/setup-formatter": "checkmarx"}
FORGED_AUTHOR = "github-advanced-security[bot]"
TOKEN_NAME = "IfYouRevokeThisToken"
REPO_DESC = re.compile(r"Sha[i1]-Hulud|Here We Go Again", re.I)
PTH_RISKY = re.compile(r"\b(exec|eval|compile|b64decode|base64|subprocess|urlopen|urllib|socket|marshal|zlib)\b")


class Sweep:
    def __init__(self):
        self.findings, self.errors, self.checked, self.skipped = [], [], {}, []

    def hit(self, level, what, where, src):
        self.findings.append({"level": level, "what": what, "where": str(where), "source": S.get(src, src)})

    def count(self, key, n=1):
        self.checked[key] = self.checked.get(key, 0) + n


def hook_commands(settings):
    """Every hook command string in a Claude settings object, per event."""
    out = []
    hooks = settings.get("hooks") if isinstance(settings, dict) else None
    if not isinstance(hooks, dict):
        return out
    for event, groups in hooks.items():
        for g in groups if isinstance(groups, list) else []:
            for h in (g.get("hooks") or []) if isinstance(g, dict) else []:
                if isinstance(h, dict) and isinstance(h.get("command"), str):
                    out.append((event, h["command"]))
    return out


def names_known(text):
    return sorted(n for n in KNOWN_FILES if n in text)


def check_claude_settings(sw, path, repo_level):
    try:
        doc = json.loads(Path(path).read_text(errors="replace"))
    except (OSError, ValueError) as e:
        sw.errors.append(f"{path}: {e}")
        return
    for event, cmd in hook_commands(doc):
        sw.count("claude hooks")
        known = names_known(cmd)
        if known:
            sw.hit("critical", f"{event} hook runs {', '.join(known)}: {cmd[:160]}", path, "elastic-cd")
        elif repo_level and event == "SessionStart" and re.search(r"\b(node|bun|deno)\b", cmd):
            sw.hit("review", f"repo-level SessionStart hook runs a script on every agent session: {cmd[:160]}",
                   path, "datadog-cd")


def check_vscode_tasks(sw, path):
    try:
        text = Path(path).read_text(errors="replace")
    except OSError as e:
        sw.errors.append(f"{path}: {e}")
        return
    sw.count("vscode tasks files")
    if '"folderOpen"' not in text:
        return
    known = names_known(text)
    level = "critical" if known else "review"
    sw.hit(level, "task runs on folder open" + (f" and names {', '.join(known)}" if known else ""), path, "datadog-cd")


def check_pth(sw, path):
    sw.count(".pth files")
    name = os.path.basename(path)
    if name == "litellm_init.pth":
        sw.hit("critical", "litellm_init.pth start-up hook (compromised litellm release)", path, "litellm")
        return
    try:
        lines = Path(path).read_text(errors="replace").splitlines()
    except OSError as e:
        sw.errors.append(f"{path}: {e}")
        return
    code = [ln for ln in lines if ln.lstrip().startswith("import ")]
    risky = [ln for ln in code if PTH_RISKY.search(ln)]
    if risky:
        sw.hit("review", f".pth runs code at every Python start: {risky[0].strip()[:140]}", path, "litellm")


def walk_repo(sw, root, include_nested):
    for dirpath, dirs, files in os.walk(root, followlinks=False):
        if ".git" in dirs:
            dirs.remove(".git")
        if not include_nested:
            nested = [d for d in dirs if os.path.lexists(os.path.join(dirpath, d, ".git"))]
            for d in nested:
                dirs.remove(d)
                sw.skipped.append(os.path.join(dirpath, d))
        parent = os.path.basename(dirpath)
        sw.count("files walked", len(files))
        for f in files:
            p = os.path.join(dirpath, f)
            if parent in AGENT_DROP and f in AGENT_DROP[parent]:
                sw.hit("critical", f"{parent}/{f} planted to re-run the payload", p, AGENT_DROP[parent][f])
            elif f in PAYLOAD:
                sw.hit("critical", f"worm payload file {f}", p, PAYLOAD[f])
            elif f in EXFIL:
                sw.hit("critical", f"worm secret-dump file {f}", p, EXFIL[f])
            elif f == "package-updated.tgz":
                sw.hit("review", "package-updated.tgz, the tarball the worm re-publishes", p, "mend")
            if parent == ".claude" and f in ("settings.json", "settings.local.json"):
                check_claude_settings(sw, p, repo_level=True)
            elif parent == ".vscode" and f == "tasks.json":
                check_vscode_tasks(sw, p)
            elif parent == "rules" and f == "setup.mdc" and os.path.basename(os.path.dirname(dirpath)) == ".cursor":
                sw.hit("critical", ".cursor/rules/setup.mdc planted for Cursor sessions", p, "stepsec")
            elif f.endswith(".pth") and parent == "site-packages":
                check_pth(sw, p)


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, errors="replace")
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:200])
    return r.stdout


def check_git(sw, repo):
    try:
        if git(repo, "rev-parse", "--is-inside-work-tree").strip() != "true":
            return
        refs = git(repo, "for-each-ref", "--format=%(refname)").split()
        sw.count("git refs", len(refs))
        for ref in refs:
            short = re.sub(r"^refs/(heads|remotes/[^/]+|tags)/", "", ref)
            if short in BRANCHES:
                sw.hit("critical", f"worm branch {short}", f"{repo} {ref}", BRANCHES[short])
        for sha in git(repo, "log", "--all", "-F", f"--grep={TOKEN_NAME}", "--format=%H").split():
            sw.hit("critical", f"commit message carries the {TOKEN_NAME}... marker", f"{repo} {sha}", "datadog-sh")
        log = git(repo, "log", "--all", "--diff-filter=A", "--name-only", "--format=@%H%x09%an <%ae>",
                  "--", ".github/workflows", ".claude", ".vscode", ".cursor")
        sha = author = ""
        for line in log.splitlines():
            if line.startswith("@"):
                sha, _, author = line[1:].partition("\t")
                sw.count("git commits read")
                continue
            if not line:
                continue
            base = os.path.basename(line)
            where = f"{repo} {sha[:12]} {line}"
            if line.startswith(".github/workflows/"):
                if base == "shai-hulud-workflow.yml":
                    sw.hit("critical", "worm exfiltration workflow added", where, "sh1")
                elif re.fullmatch(r"formatter_\d+\.ya?ml", base):
                    sw.hit("critical", "worm secrets-dump workflow added", where, "sh2")
                elif FORGED_AUTHOR in author:
                    sw.hit("critical", f"workflow added under forged author {FORGED_AUTHOR}", where, "checkmarx")
                elif base == "discussion.yaml":
                    sw.hit("review", "discussion.yaml added: the worm's self-hosted-runner backdoor uses this name",
                           where, "sh2")
            elif base in KNOWN_FILES and line.split("/")[0] in AGENT_DROP:
                sw.hit("critical", f"{line} committed to history (it re-runs on checkout of that ref)", where,
                       AGENT_DROP[line.split("/")[0]].get(base, "upwind"))
            elif line == ".cursor/rules/setup.mdc":
                sw.hit("critical", ".cursor/rules/setup.mdc committed to history", where, "stepsec")
    except (RuntimeError, OSError) as e:
        sw.errors.append(f"git checks in {repo}: {e}")


def check_home(sw, home):
    h = Path(home)
    exact = {
        ".config/systemd/user/gh-token-monitor.service": "ghtm", ".local/bin/gh-token-monitor.sh": "ghtm",
        ".config/gh-token-monitor": "ghtm", "Library/LaunchAgents/com.user.gh-token-monitor.plist": "ghtm",
        ".config/sysmon/sysmon.py": "litellm", ".config/systemd/user/sysmon.service": "litellm",
    }
    for rel, src in exact.items():
        sw.count("home paths checked")
        if (h / rel).exists():
            sw.hit("critical", f"persistence file {rel}", h / rel, src)
    for unit_dir in (h / ".config/systemd/user", h / "Library/LaunchAgents"):
        for f in sorted(unit_dir.glob("*")) if unit_dir.is_dir() else []:
            if not f.is_file() or f.name in ("gh-token-monitor.service", "sysmon.service",
                                             "com.user.gh-token-monitor.plist"):
                continue
            sw.count("user units read")
            try:
                text = f.read_text(errors="replace")
            except OSError:
                continue
            if "gh-token-monitor" in text or "sysmon.py" in text:
                sw.hit("critical", "user service starts gh-token-monitor or sysmon.py", f, "ghtm")
    for name in ("settings.json", "settings.local.json"):
        p = h / ".claude" / name
        if p.is_file():
            check_claude_settings(sw, p, repo_level=False)
    for f in sorted(h.glob("*")):
        if f.name in EXFIL:
            sw.hit("critical", f"worm secret-dump file {f.name}", f, EXFIL[f.name])
    pats = [".local/lib/python*/site-packages/*.pth",
            ".local/share/mise/installs/python/*/lib/python*/site-packages/*.pth",
            ".local/share/uv/python/*/lib/python*/site-packages/*.pth",
            ".local/share/uv/tools/*/lib/python*/site-packages/*.pth",
            ".local/share/pipx/venvs/*/lib/python*/site-packages/*.pth",
            ".local/pipx/venvs/*/lib/python*/site-packages/*.pth",
            ".cache/uv/archive-v0/*/*.pth"]
    for pat in pats:
        for p in sorted(glob.glob(str(h / pat))):
            check_pth(sw, p)


def check_tmp(sw, tmp):
    d = Path(tmp)
    if not d.is_dir():
        return
    try:
        entries = sorted(d.iterdir())
    except OSError as e:
        sw.errors.append(f"{tmp}: {e}")
        return
    sw.count("tmp entries read", len(entries))
    for f in entries:
        if f.name in LOCKS:
            sw.hit("critical", f"worm lock file {f.name}", f, LOCKS[f.name])
        elif f.name.startswith("gh-token-monitor") and f.name.endswith(".log"):
            sw.hit("critical", "gh-token-monitor log: the dead-man switch has run here", f, "ghtm")
        elif f.name in EXFIL:
            sw.hit("critical", f"worm secret-dump file {f.name}", f, EXFIL[f.name])


def check_github(sw):
    r = subprocess.run(["gh", "repo", "list", "--limit", "1000", "--json", "nameWithOwner,description"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sw.errors.append(f"gh repo list: {r.stderr.strip()[:200]}")
        return
    repos = json.loads(r.stdout)
    sw.count("github repos read", len(repos))
    for repo in repos:
        text = f"{repo['nameWithOwner']} {repo.get('description') or ''}"
        if REPO_DESC.search(text):
            sw.hit("critical", f"exfiltration-style repo: {text[:160]}", repo["nameWithOwner"], "sh2")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", action="append", help="repo or directory to sweep (repeatable; default .)")
    ap.add_argument("--home", default=os.environ.get("HOME"), help="home directory to sweep (default $HOME)")
    ap.add_argument("--no-home", action="store_true", help="skip the home checks")
    ap.add_argument("--tmp", action="append", help="temp directory to sweep (repeatable; default $TMPDIR and /tmp)")
    ap.add_argument("--github", action="store_true", help="also list your GitHub repos with gh (read-only)")
    ap.add_argument("--json", metavar="FILE", help="write findings as JSON")
    ap.add_argument("--include-nested", action="store_true",
                    help="also walk nested checkouts (worktrees, submodules); slow on agent-heavy repos")
    a = ap.parse_args()

    sw = Sweep()
    for repo in a.repo or ["."]:
        repo = str(Path(repo).resolve())
        if not os.path.isdir(repo):
            sw.errors.append(f"{repo}: not a directory")
            continue
        walk_repo(sw, repo, a.include_nested)
        if os.path.exists(os.path.join(repo, ".git")):
            check_git(sw, repo)
    if not a.no_home and a.home:
        check_home(sw, a.home)
    tmps = a.tmp or list(dict.fromkeys(t for t in (os.environ.get("TMPDIR"), "/tmp") if t))
    for t in tmps:
        check_tmp(sw, t)
    if a.github:
        check_github(sw)

    order = {"critical": 0, "review": 1}
    for f in sorted(sw.findings, key=lambda f: (order[f["level"]], f["where"])):
        print(f"{f['level'].upper():8}  {f['what']}\n          {f['where']}\n          source: {f['source']}")
    for e in sw.errors:
        print(f"ERROR     {e}")
    print("checked: " + ", ".join(f"{k} {v}" for k, v in sw.checked.items()))
    if sw.skipped:
        print(f"not walked: {len(sw.skipped)} nested checkouts (worktrees, submodules), e.g. {sw.skipped[0]}; "
              "pass them with --repo, or use --include-nested")
    crit = sum(f["level"] == "critical" for f in sw.findings)
    rev = len(sw.findings) - crit
    if crit:
        print("Do not revoke or rotate tokens yet: remove the persistence above first, on every affected "
              "machine, then rotate (references/INCIDENT-RESPONSE.md, Rotation Playbook).")
    if a.json:
        Path(a.json).write_text(json.dumps({"findings": sw.findings, "errors": sw.errors,
                                            "checked": sw.checked}, indent=1) + "\n")
    note = f"; {len(sw.errors)} check(s) could not run" if sw.errors else ""
    print(f"result: {crit} critical, {rev} to review{note}")
    return 2 if crit else (1 if sw.errors else 0)


if __name__ == "__main__":
    sys.exit(main())
