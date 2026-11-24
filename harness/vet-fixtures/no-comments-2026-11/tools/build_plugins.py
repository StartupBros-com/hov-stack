#!/usr/bin/env python3
"""Build one --plugin-dir per skill arm from pinned sources. Nothing here is committed content
of the contenders; each is fetched at its pin by the operator first (README, "Rebuilding the arms").

usage: build_plugins.py <out-dir> <cursor-plugins-clone> <ce-plugin-dir> <hov-stack-checkout> <contenders-dir>

  <cursor-plugins-clone>  cursor/plugins at ca782ed8 (pstack 0.15.48); its pstack/ is copied whole
  <ce-plugin-dir>         compound-engineering 3.38.3 as installed (a plugin cache directory)
  <hov-stack-checkout>    any clone; plugins/hov-stack is archived at 631283c5 (the vet's main)
  <contenders-dir>        comment-ratchet/, comment-audit-skill/, code-comments/ fetched at their pins

The arms/<arm>/plugin.txt files name <out-dir>/<plugin> under /tmp/nc-vet-0f9d/plugins, the path
the vet used; pass that path as <out-dir> or edit plugin.txt.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

HOV_STACK_PIN = "631283c586660f36ef1eda0bd2a0f3fc4148ede4"

if len(sys.argv) != 6:
    sys.exit(__doc__)
P, PSTACK, CE, HOV, C = (Path(a) for a in sys.argv[1:])
if P.exists():
    sys.exit(f"{P} exists")
P.mkdir(parents=True)

shutil.copytree(PSTACK / "pstack", P / "pstack", symlinks=True)
shutil.copytree(CE, P / "compound-engineering", symlinks=True)

hs = P / "hov-stack"
hs.mkdir()
arch = subprocess.run(["git", "-C", str(HOV), "archive", HOV_STACK_PIN, "plugins/hov-stack"],
                      check=True, capture_output=True).stdout
subprocess.run(["tar", "-x", "-C", str(hs), "--strip-components=2"], input=arch, check=True)


def manifest(root: Path, name: str) -> None:
    (root / ".claude-plugin").mkdir(parents=True)
    (root / ".claude-plugin" / "plugin.json").write_text(json.dumps({"name": name, "version": "1.0.0"}) + "\n")


r = P / "comment-ratchet"
manifest(r, "comment-ratchet")
(r / "skills" / "delete-comment").mkdir(parents=True)
shutil.copy(C / "comment-ratchet" / "SKILL.md", r / "skills" / "delete-comment" / "SKILL.md")

a = P / "comment-audit"
manifest(a, "comment-audit")
sk = a / "skills" / "comment-audit-skill"
(sk / "scripts").mkdir(parents=True)
(sk / "references").mkdir()
shutil.copy(C / "comment-audit-skill" / "SKILL.md", sk / "SKILL.md")
shutil.copy(C / "comment-audit-skill" / "scan-comments.sh", sk / "scripts" / "scan-comments.sh")
for f in ("taxonomy.md", "todo-template.md"):
    shutil.copy(C / "comment-audit-skill" / f, sk / "references" / f)
shutil.copy(C / "comment-audit-skill" / "references" / "clarity-report-template.md",
            sk / "references" / "clarity-report-template.md")

cc = P / "code-comments"
manifest(cc, "code-comments")
shutil.copytree(C / "code-comments", cc / "skills" / "code-comments")

for m in sorted(P.glob("*/.claude-plugin/plugin.json")) + sorted(P.glob("*/plugin.json")):
    print(m, json.loads(m.read_text()).get("name"))
for d in ("compound-engineering/skills/ce-simplify-code", "hov-stack/skills/code-slop",
          "code-comments/skills/code-comments", "pstack/skills/no-comments", "pstack/agents"):
    print(d, sorted(x.name for x in (P / d).iterdir()))
