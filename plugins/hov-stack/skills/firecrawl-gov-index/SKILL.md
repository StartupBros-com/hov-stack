---
name: firecrawl-gov-index
description: Find US statutes, regulations, codes, court opinions, and agency guidance via Firecrawl's free Government Index. Use for compliance questions, "is X legal in state Y", "what does the rule require", case law interpreting a rule, and citation lookups (U.S.C., CFR, case cites). US federal, state, and local material only; not for non-US law.
---

# Firecrawl Government Index

Find the legal or regulatory text behind a US question: federal, state, and
local statutes, regulations, codes, court opinions, and agency publications.
Ranked matches also include historical versions, bill text, agency guidance, and
third-party reproductions, so a match is a lead to verify, not a statement of
current governing law. Coverage is US only, and a page the index has not seen
is not there; court labels are most complete for federal courts and case-law
collections.

## Tools

One verb, called through the harness wrapper (the Firecrawl MCP is retired and
the vendor `firecrawl gov` command does not exist on the pinned 1.19.26):

`firecrawl-cli gov "<question, jurisdiction, date>" [filters] --json`

It is free: `credits_spent` is 0 and no key is needed. A key in
`FIRECRAWL_API_KEY` is sent only for higher rate limits.

- `--limit N` (1-100, default 10). Never `-k`, which is the API-key option.
- `--jurisdiction CODE`: `us` for federal, or `us-` plus a state or territory
  code (`us-ca`, `us-dc`). Use whenever the question is about one state.
- `--court ID`: one CourtListener court (`scotus`, `ca9`, `nysd`).
- `--court-type TYPE`: `federal-supreme`, `federal-appellate`,
  `federal-district`, `federal-bankruptcy`, `federal-special`, `military`,
  `state-supreme`, `state-appellate`, `state-trial`, `state-special`,
  `state-attorney-general`. Use to restrict to a class of courts.
- `--cites CITATION`: pages citing a printed citation (`42 U.S.C. § 1983`,
  `5 U.S. 137`) or an id (`us:usc:42:1983`).
- `--domain HOST`: one site, such as `irs.gov`.
- `--timeout S`, `--full`, `-o PATH` are the wrapper-common flags.

Filters combine with AND and keep only pages the index has labeled, so a
filtered search can drop relevant pages. If a filtered query is empty, retry
with fewer filters before concluding anything.

Results are in `data.data.web[]` (the envelope's `data` is the API payload):

```json
{"surface":"gov","verb":"gov","credits_spent":0,
 "data":{"success":true,"data":{"web":[
  {"url":"https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?lawCode=CIV&sectionNum=1798.82",
   "title":"California Code, CIV 1798.82",
   "description":"Code Section > Code Text > ... 1798.82. (a) (1) An individual or business that conducts business in California ...",
   "position":2}]}}}
```

`description` is the matched excerpt and is often long statute text. The
wrapper bounds body text at 24,576 characters; pass `--full` to lift that when
you need every excerpt. A bad filter value exits 4 with no call; an API 400
(unknown court id, unreadable citation) exits 1 with the API's reason in
`error.message`; 429 and 5xx exit 2 and are worth retrying.

## Match the approach to the question

- **Compliance requirement** ("allergen labeling rules", "data breach notice
  deadline") → plain-language query plus `--jurisdiction`. Run `us` and the
  state separately when both may apply.
- **Case law interpreting a rule** → query the rule and the issue, add
  `--court-type` for a class of courts, or `--court` for one court.
- **Agency publication or guidance** ("IRS guidance on X") → `--domain` set to
  the agency site.
- **Citation chase** (who cites a statute or case) → `--cites` with the printed
  citation. Combine with `--court-type` to see how courts treat it.
- **Single named section** ("Cal. Civ. Code 1798.82") → query the citation text
  with its `--jurisdiction`; then fetch the page to read the whole section.
- **Does the rule exist at all** → search broadly first, filter second. Filters
  hide unlabeled pages.

## Verify before citing

- Check the issuer, jurisdiction, enacted or effective status, and version.
  Bill text, agency guidance, historical versions, and third-party copies all
  rank beside the current code.
- Read the source: `firecrawl-cli fetch <url> --json`. An excerpt alone rarely
  settles scope, exceptions, or effective dates. Check a bill's status rather
  than inferring it from its title.
- Cite the controlling section and the supporting passage; give a page,
  section, or date only when the evidence shows it.
- No results is not no law. State what you searched and what could be missing.
- Ask for the jurisdiction when it is missing before naming a governing rule.
- This finds sources. It is not legal advice.

## Routing

- **Non-US law, or US coverage the index lacks** (unlabeled courts, municipal
  ordinances, very recent changes) → plain web search: `exa-cli search`, then
  `firecrawl-cli search`.
- **The user supplied a source URL** → skip search and read it with
  `firecrawl-cli fetch <url> --json`.
- **Library, API, or code questions** → `firecrawl-developer-index`; **papers**
  → `firecrawl-research-index`.
