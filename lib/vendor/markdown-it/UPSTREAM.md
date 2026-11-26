# Upstream provenance

Source: https://github.com/markdown-it/markdown-it
Package: `markdown-it@15.0.3` from https://registry.npmjs.org/markdown-it/-/markdown-it-15.0.3.tgz
Tarball integrity (npm registry, verified on download): `sha512-+Az7Ojz3iRGu8KYMvJ6xVhvrxP3eE+vEtJX75Ow88XBpcQNV/0lGX5ZynIIBftREo4DC2jsveAMDaeltmm8QvQ==`
Upstream commit (`gitHead` in the registry record): a8c00d474ec9b304fad9b71c16d6fa8b4909279e
Fetched: 2026-11-25
License: MIT (`LICENSE`, verbatim from the tarball)

File vendored: `dist/browser/markdown-it.umd.min.js`, byte-verbatim, as `markdown-it.umd.min.js`.

sha256: `391f2aa638e75e6c7859d0a5c5650ef0956722a45998f17e05b83bc655778e1e`

`tests/open-deliverable.test.sh` fails when the file's hash differs from the line above, so a
new build is adopted by editing this record in the same change.

## What is inside the bundle

Upstream's build inlines the package's runtime dependencies. Their licence texts are in
`licenses/`, copied from the packages' current npm tarballs on the fetch date (the bundle
holds whichever versions upstream's own lockfile resolved inside the ranges below):

| Package | Range in markdown-it 15.0.3 | Licence | File |
|---|---|---|---|
| entities | ^8.1.0 | BSD-2-Clause | `licenses/entities.LICENSE` |
| linkify-it | ^6.1.0 | MIT | `licenses/linkify-it.LICENSE` |
| mdurl | ^2.1.0 | MIT | `licenses/mdurl.LICENSE` |
| punycode.js | ^2.3.1 | MIT | `licenses/punycode.js.LICENSE` |
| uc.micro | ^3.0.0 | MIT | `licenses/uc.micro.LICENSE` |

## Why it is vendored

`bin/open-deliverable` renders a Markdown report to a page before the browser opens it, through
`lib/deliverable-render.js`. `./setup` already requires node and installs no packages, and CI
has node and no Markdown library, so one pinned parser in the tree is the only renderer that
is the same on every host and can be tested. Vet record: `docs/vets/2026-11-25-markdown-it-vendor-vet.md`.

## Local changes

None. Behaviour is configured from `lib/deliverable-render.js` (`html: false`, so raw HTML in a
report is shown as text).
