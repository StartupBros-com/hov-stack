# Papers workflow overlay

## Source identity

Copied on **2026-09-24** from the installed
`~/.claude/skills/papers/scripts/workflow.py`.

The publisher is [Jeffrey's Skills](https://jeffreys-skills.md). Its catalogue
identifies the package as follows (queried with `jsm --json show papers` and
`jsm --json versions papers` on 2026-09-24):

- Skill: `papers`, ID `c735eea2-efe7-4730-a17a-14b46c424972`.
- Author: **Jacob Rothfield**.
- Catalogue revision: **5**, version ID `3d977b98-6f6e-47a0-bfe1-d82d33fe7f7a`,
  created 2026-05-15T02:32:52.706Z.
- Catalogue content hash:
  `0edcbd91d45e20bfb6ad141cd477813fdc12750f5bfa0c72c7dc359573e78a70`.
- Licence: `mit`; distribution policy: `public`; share status: `approved`.

The local installation record also reports catalogue revision 5, installed
2026-06-15. The bundled `skill.manifest.yaml` separately reports **3.0.0**;
that internal version is not the catalogue revision.

The unmodified installed `scripts/workflow.py` has SHA-256:
`0930bbfea99dbd26d302d72872f434d118fe43c202259fe2d385b401a000452f`.
This is a file-byte identity, distinct from the publisher's catalogue content
hash. The catalogue does not provide a Git repository or commit, so the
retrievable package/version identifiers above are recorded instead; no Git
revision is invented. These records do not assert that the local installation
was independently compared with a freshly downloaded revision-5 archive.

## Licence notice

The installed `SKILL.md` declares `license: MIT`, corroborated by the publisher's
catalogue. Neither the installed package nor its metadata supplies a separate
licence file or copyright notice (`copyright` is null). `LICENSE` therefore
includes the standard MIT permission/warranty text identified by that declaration,
not a purported verbatim copy of a nonexistent upstream file. The author is
credited above; no copyright holder or year has been invented.

This missing upstream notice is a disclosed provenance limitation, not a claim
that a Git snapshot and verbatim upstream licence were available.

## Local changes

1. Replace the successful `full_preprint_workflow` branch's premature `return {`
   with `result = {`, allowing warning attachment and the final return to run.
2. Normalize warning payloads through JSON with `default=str`. Real provider
   errors can retain exception objects (for example `URLError.reason` containing
   `socket.gaierror`); retaining those warnings must not break CLI JSON output.

The empty-result branch and unrelated workflow behavior remain intact. The
existing skill localizer applies the overlay to both installed Claude and Codex
copies. `tests/papers-workflow-warnings.test.sh` executes the actual
overlaid implementation with controlled dependencies and real exception-valued
error details. Those tests exercise error propagation, not live provider quality.
