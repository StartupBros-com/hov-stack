# Upstream provenance (test fixture, dotfiles#1202)

Overlay applied over a jsm-managed skill from https://github.com/fixture-owner/fixture-repo
`overlay/nested/path` at commit deadbeef00deadbeef00deadbeef00deadbeef0. This
fixture exercises two things at once: an UPSTREAM.md nested two levels under
skills-patches/ ("at any depth"), and the optional `path:` line reaching gh as
a query parameter. The pin differs from the fixture's gh-head.sha, so a check
against it must read "MOVED".

path: overlay/nested/path
