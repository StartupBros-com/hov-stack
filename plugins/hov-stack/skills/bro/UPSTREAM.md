# Upstream provenance

Source: https://github.com/luchasarie/bro-skill
path: SKILL.md
Pinned at commit 01e51f8092973be58eff3b7271282bd8488a02ae.

`SKILL.md` is byte-identical to the upstream file at the pin: both are git blob
aeb322110b87e0aa06311e72d8aa43585c970fba. `LICENSE` is the upstream MIT licence at the
pin, byte-for-byte ("Copyright (c) 2026 Hermes Agent + Luka"). The upstream README,
examples and install script are not vendored.

Re-pull and compare:

    gh api 'repos/luchasarie/bro-skill/contents/SKILL.md?ref=HEAD' --jq .sha
    git hash-object plugins/hov-stack/skills/bro/SKILL.md
