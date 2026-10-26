#!/usr/bin/env python3
"""Build a fixture "box" that satisfies a profile's required_capabilities.

Used by the suites that run the real entrypoint. The capability probe reads the
world, so a hermetic run needs a world to read -- one whose CE install, local
skills, pro-gate resolver and identity attestation match the profile under test.

Built FROM the profile rather than hard-coded: if the profile's pins change, the
fixture follows, and the suites keep testing the shipped contract instead of a
snapshot of it that quietly drifts.

Usage: quality-capability-box.py <dest-dir> <profile.json>
"""
import json
import pathlib
import sys

dest = pathlib.Path(sys.argv[1])
profile = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
required = profile["profiles"][0]["required_capabilities"]

ce_version = next(
    (v for k, v in required["ce_skills"].items() if k.startswith("ce-")), "0.0.0"
)
ce_root = dest / "cache/compound-engineering" / ce_version
local_skills = dest / "skills"
for skill in required["ce_skills"]:
    # ce-* ships inside the plugin; anything else is a local user skill, which
    # is where the probe looks for it.
    target = (ce_root / "skills" / skill) if skill.startswith("ce-") else (local_skills / skill)
    target.mkdir(parents=True, exist_ok=True)
    (target / "SKILL.md").write_text("fixture\n", encoding="utf-8")

(dest / "installed_plugins.json").write_text(
    json.dumps({
        "version": 2,
        "plugins": {
            "compound-engineering@every-marketplace": [{"installPath": str(ce_root)}]
        },
    }),
    encoding="utf-8",
)

resolver = dest / "pro-plugin/skills/pro-gate/scripts/resolve-identity.sh"
resolver.parent.mkdir(parents=True, exist_ok=True)
# The resolver reports the version the PROFILE approves, so the fixture box is a
# satisfied one. A suite that wants the mismatch case overwrites this file.
resolver.write_text(
    "#!/usr/bin/env bash\n"
    f"printf '{required['pro']['version']}\\t{required['pro']['contract']}"
    f"\\t{required['pro']['contract_version']}\\t{'d' * 64}\\t{'c' * 64}\\n'\n",
    encoding="utf-8",
)
resolver.chmod(0o755)

print(str(dest))
