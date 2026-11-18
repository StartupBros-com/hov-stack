"""copy_seed: copy a vet fixture's seed app into a run directory under its real file names.

A seed app keeps each manifest under a name no dependency scanner reads: package.json is
committed as package.json.fixture. GitHub's dependency graph parses every package.json in
the tree, so a synthetic app's pinned versions became Dependabot alerts on this repository,
and Renovate rewrote learn-taste's acme-notes (#708, #709, #727) until it no longer matched
the session the vet planted. copy_seed strips the suffix in the copy, so a run sees the app
exactly as the vet recorded it. tests/vet-fixture-manifests.test.sh keeps manifest names out
of harness/vet-fixtures/ and builds each seed through its builder.
"""

import os
import shutil

SUFFIX = ".fixture"


def copy_seed(src, dst, expect=()):
    """Copy src to dst, rename every <name>.fixture to <name>, then require each path in expect."""
    shutil.copytree(src, dst)
    for root, _dirs, files in os.walk(dst):
        for name in files:
            if not name.endswith(SUFFIX):
                continue
            real = os.path.join(root, name[:-len(SUFFIX)])
            if os.path.lexists(real):
                raise SystemExit("copy_seed: %s holds both %s and %s" % (root, name, os.path.basename(real)))
            os.rename(os.path.join(root, name), real)
    for rel in expect:
        if not os.path.isfile(os.path.join(dst, rel)):
            raise SystemExit("copy_seed: %s has no %s after the copy" % (dst, rel))
