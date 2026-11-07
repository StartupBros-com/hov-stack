#!/usr/bin/env python3
"""Detect trigger collisions and duplicate names across the installed skill roster.

WHY THIS EXISTS
    Every skill loads name+description at session start so the model can route.
    When two installed skills carry near-identical descriptions, routing between
    them is a coin flip -- and nothing in the harness catches it. The existing
    doctor check (section 13) only verifies that skillOverrides keys RESOLVE to
    an installed dir; it says nothing about two dirs competing for the same
    trigger.

    This is the failure mode the `-local` fork convention creates by design:
    retired-skills.txt already warns that the BASE name of every `-local` fork
    must be retired "otherwise `jsm install-all` resurrects the pristine
    upstream original *alongside* the fork (double-load)". That doctrine is
    enforced by convention only. Measured 2026-08-05: `deadlock-finder-and-fixer`
    and `deadlock-finder-and-fixer-local` carry BYTE-IDENTICAL descriptions.

SEVERITY MODEL (the part a generic linter gets wrong)
    A collision only misroutes if BOTH sides are visible to the model. The
    harness deliberately runs base+fork pairs where the base is demoted via
    `skillOverrides: user-invocable-only` -- that demotion neutralizes the
    collision. So findings are graded:

      LIVE    both sides model-visible          -> real routing ambiguity, warn
      LATENT  one side demoted / manual-invoke   -> armed trap, fires the moment
                                                    the override is removed, note

    Only LIVE findings set the failing exit code. LATENT findings are reported
    so a future "clean up dead overrides" pass can't silently re-arm them.

    A skill is model-invisible when it is `user-invocable-only` or `off` in
    settings.json skillOverrides, or carries `disable-model-invocation: true`
    in its own frontmatter. Only the frontmatter flag hides a plugin skill:
    Claude Code does not apply skillOverrides to plugin skills.

SCAN SET
    By default: ~/.claude/skills, the skills of each skills-dir plugin kept
    there (~/.claude/skills/<dir>/.claude-plugin/plugin.json), and the skills
    of each enabled user-scope marketplace install in
    ~/.claude/plugins/installed_plugins.json. A plugin skill is reported as
    <plugin>:<dir>. --sources replaces the whole set.

Usage:
    skill-collision-check.py [--threshold 0.75] [--sources DIR ...] [--json]
                             [--include-latent]

Exit codes: 0 clean (no LIVE collisions), 1 LIVE collisions found, 2 scan
corpus unavailable (harness-doctor friendly).
"""

import argparse
import json
import os
import re
import sys
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from floor_assert import FloorNotMet, require_floor  # noqa: E402

FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*$", re.DOTALL | re.MULTILINE)
# Grab a top-level `key:` value up to the next top-level key or end of block.
# Handles plain scalars, quoted scalars, and `>-` / `|` folded blocks alike,
# because we only ever compare the flattened text.
FIELD_RE = r"^{key}:[ \t]*(.*?)(?=\n[A-Za-z_][A-Za-z0-9_-]*:|\Z)"

# Dropped before comparison: articles/prepositions plus the boilerplate that
# appears in nearly every skill description ("Use when ...") and would otherwise
# inflate every pairwise score toward a false positive.
STOPWORDS = frozenset("""
a an and any are as at be been but by can do does for from has have how in into is it
its of on or that the their them then there these this to use used uses using was were
what when where which who will with you your skill skills claude agent user users
""".split())

WORD_RE = re.compile(r"[a-z0-9][a-z0-9+.#/-]*")


def _field(block: str, key: str) -> str:
    m = re.search(FIELD_RE.format(key=re.escape(key)), block, re.DOTALL | re.MULTILINE)
    if not m:
        return ""
    val = m.group(1).strip()
    # Strip a leading YAML block indicator (>-, |, |-, >) and matching quotes.
    val = re.sub(r"\A[>|][-+]?\s*", "", val)
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        val = val[1:-1]
    return " ".join(val.split())


def parse_skill(skill_md: Path) -> dict | None:
    """Return {dir, name, description, self_disabled} or None if unparseable."""
    try:
        text = skill_md.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None
    fm = m.group(1)
    desc = _field(fm, "description")
    if not desc:
        return None
    return {
        "dir": skill_md.parent.name,
        "path": str(skill_md.parent),
        "name": _field(fm, "name") or skill_md.parent.name,
        "description": desc,
        # A skill that opts out of model invocation never competes for routing.
        "self_disabled": _field(fm, "disable-model-invocation").lower() == "true",
    }


def content_words(text: str) -> frozenset[str]:
    return frozenset(w for w in WORD_RE.findall(text.lower()) if w not in STOPWORDS)


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def load_settings(settings: Path) -> dict:
    try:
        data = json.loads(settings.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load_overrides(settings: Path) -> dict[str, str]:
    overrides = load_settings(settings).get("skillOverrides", {})
    return overrides if isinstance(overrides, dict) else {}


def manifest_name(root: Path) -> str | None:
    """The plugin name `root` declares in .claude-plugin/plugin.json, else None."""
    try:
        data = json.loads((root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    name = data.get("name") if isinstance(data, dict) else None
    return name if isinstance(name, str) and name else root.name


def plugin_sources(claude: Path, settings: dict) -> list[tuple[Path, str]]:
    """(skills dir, plugin name) for each plugin a session loads skills from.

    The same rule as hooks/UserPromptSubmit/skill-mention-resolver.js: a
    skills-dir plugin (<claude>/skills/<dir>/.claude-plugin/plugin.json) counts
    unless enabledPlugins["<name>@skills-dir"] is false; an installed
    marketplace plugin counts when enabledPlugins["<key>"] is true and it has a
    user-scope install. Project-scope installs depend on the project and are
    not scanned.
    """
    enabled = settings.get("enabledPlugins")
    enabled = enabled if isinstance(enabled, dict) else {}
    out: list[tuple[Path, str]] = []
    skills = claude / "skills"
    if skills.is_dir():
        for entry in sorted(skills.iterdir()):
            if entry.name.startswith("."):
                continue
            name = manifest_name(entry)
            if name is None or enabled.get(f"{name}@skills-dir") is False:
                continue
            out.append((entry / "skills", name))
    try:
        installed = json.loads(
            (claude / "plugins" / "installed_plugins.json").read_text(encoding="utf-8")
        ).get("plugins") or {}
    except (OSError, ValueError, AttributeError):
        installed = {}
    if not isinstance(installed, dict):
        installed = {}
    for key in sorted(installed):
        if enabled.get(key) is not True:
            continue
        records = installed[key] if isinstance(installed[key], list) else [installed[key]]
        for r in records:
            # Manifests from before project scope existed carry no scope field.
            if (isinstance(r, dict) and isinstance(r.get("installPath"), str)
                    and r.get("scope", "user") == "user"):
                out.append((Path(r["installPath"]) / "skills", key.split("@")[0]))
                break
    return out


def discover(sources: list[Path], plugins: dict[Path, str] | None = None) -> list[dict]:
    """Parse every skill under `sources`. A source that is a plugin's skills dir
    (named in `plugins`, or whose parent carries a plugin manifest) tags its
    skills with that plugin."""
    plugins = plugins or {}
    skills, seen = [], set()
    for src in sources:
        if not src.is_dir():
            continue
        plugin = plugins.get(src) or manifest_name(src.parent)
        for entry in sorted(src.iterdir()):
            # Skip jsm's .trash/ archive and any other dot-dir bookkeeping.
            if entry.name.startswith(".") or not entry.is_dir():
                continue
            parsed = parse_skill(entry / "SKILL.md")
            if not parsed:
                continue
            # A skill symlinked into two roots (the ~/.codex/skills bridge does
            # this) is one skill, not a collision with itself.
            real = os.path.realpath(parsed["path"])
            if real in seen:
                continue
            seen.add(real)
            parsed["plugin"] = plugin
            parsed["id"] = f"{plugin}:{parsed['dir']}" if plugin else parsed["dir"]
            skills.append(parsed)
    return skills


def visibility(skill: dict, overrides: dict[str, str]) -> tuple[bool, str]:
    """(model_visible, reason)."""
    if skill["self_disabled"]:
        return False, "disable-model-invocation"
    # Claude Code's skills docs: "Plugin skills are not affected by skillOverrides".
    if skill.get("plugin"):
        return True, "on"
    ov = overrides.get(skill["dir"]) or overrides.get(skill["name"])
    if ov in ("user-invocable-only", "off"):
        return False, ov
    return True, "on"


def main() -> int:
    home = Path.home()
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--threshold", type=float, default=0.75,
                    help="Jaccard similarity at or above which a pair collides (default 0.75)")
    ap.add_argument("--sources", nargs="*", type=Path, default=None,
                    help="skill roots to scan (default ~/.claude/skills plus the skills "
                         "of every plugin a session loads)")
    ap.add_argument("--settings", type=Path, default=home / ".claude" / "settings.json")
    ap.add_argument("--include-latent", action="store_true",
                    help="also fail (exit 1) on LATENT collisions")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    settings = load_settings(args.settings)
    plugins: dict[Path, str] = {}
    if args.sources is None:
        found = plugin_sources(home / ".claude", settings)
        plugins = dict(found)
        args.sources = [home / ".claude" / "skills"] + [src for src, _ in found]

    skills = discover(args.sources, plugins)
    try:
        require_floor(len(skills), 1, "skill collision corpus")
    except FloorNotMet as error:
        print(error, file=sys.stderr)
        return 2

    overrides = load_overrides(args.settings)
    for s in skills:
        s["visible"], s["visibility_reason"] = visibility(s, overrides)
        s["words"] = content_words(s["description"])

    findings = []

    # 1. Duplicate `name:` fields. Two dirs declaring the same skill name is
    #    always wrong regardless of visibility -- `/name` becomes ambiguous.
    by_name: dict[str, list[dict]] = {}
    for s in skills:
        by_name.setdefault(s["name"], []).append(s)
    for name, group in sorted(by_name.items()):
        if len(group) > 1:
            findings.append({
                "kind": "duplicate-name",
                "severity": "LIVE",
                "score": 1.0,
                "skills": [g["id"] for g in group],
                "detail": f"{len(group)} dirs declare name '{name}'",
            })

    # 2. Description collisions.
    for a, b in combinations(skills, 2):
        if a["name"] == b["name"]:
            continue  # already reported as duplicate-name
        score = jaccard(a["words"], b["words"])
        if score < args.threshold:
            continue
        both_visible = a["visible"] and b["visible"]
        exact = a["description"] == b["description"]
        findings.append({
            "kind": "description-collision",
            "severity": "LIVE" if both_visible else "LATENT",
            "score": round(score, 3),
            "exact": exact,
            "skills": [a["id"], b["id"]],
            "visibility": {a["id"]: a["visibility_reason"], b["id"]: b["visibility_reason"]},
            "detail": ("byte-identical descriptions" if exact
                       else f"description similarity {score:.2f}"),
        })

    findings.sort(key=lambda f: (f["severity"] != "LIVE", -f["score"]))
    live = [f for f in findings if f["severity"] == "LIVE"]
    latent = [f for f in findings if f["severity"] == "LATENT"]

    if args.json:
        print(json.dumps({"scanned": len(skills), "live": live, "latent": latent}, indent=2))
    else:
        print(f"scanned {len(skills)} skills across "
              f"{', '.join(str(s) for s in args.sources)}")
        for f in findings:
            tag = "COLLISION" if f["severity"] == "LIVE" else "latent"
            print(f"  {tag}: {' <-> '.join(f['skills'])} — {f['detail']}")
            if f["severity"] == "LATENT":
                vis = f.get("visibility", {})
                hidden = [d for d, r in vis.items() if r != "on"]
                if hidden:
                    print(f"      neutralized by: "
                          + ", ".join(f"{d} is {vis[d]}" for d in hidden))
        if not findings:
            print("  no collisions")
        print(f"skill-collision-check: {len(live)} live, {len(latent)} latent")

    return 1 if (live or (args.include_latent and latent)) else 0


if __name__ == "__main__":
    sys.exit(main())
