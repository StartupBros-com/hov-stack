# Upstream provenance (test fixture, dotfiles#1202)

Frozen snapshot of https://github.com/fixture-owner/unreachable-repo at commit
0123456789abcdef0123456789abcdef01234567. The fixture's stubbed gh always fails
for `unreachable-repo`, so a check against it must read "unreachable" and must
not print a WARN line.
