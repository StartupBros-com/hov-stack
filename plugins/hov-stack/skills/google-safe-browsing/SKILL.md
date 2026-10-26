---
name: google-safe-browsing
description: 'Prevent and fix Google Safe Browsing "Dangerous site" flags. Use when launching a public web app, buying/picking a domain, building a login or signup page, or when any site shows a red "Dangerous site" / "Deceptive site" warning in Chrome, Brave, Safari, Firefox, or Edge. Triggers on "dangerous site", "deceptive site", "site blocked", "safe browsing", "phishing flag", "red warning screen".'
---

<!-- Adapted from davidondrej/skills (MIT) — LICENSE + UPSTREAM.md in this directory carry full attribution and rationale. -->

# Google Safe Browsing: Prevent and Fix

One upstream blocklist (Google Safe Browsing) feeds Chrome, Brave, Safari, Firefox, and Edge. A flag there blocks the site in every browser at once. It is a classification of the public surface, not a hack — do not start by debugging code.

## Quick check: is a site flagged?

```bash
# Replace the domain. Check apex AND www — they are scored separately.
curl -s "https://transparencyreport.google.com/transparencyreport/api/v3/safebrowsing/status?site=example.com"
```

Response is `)]}'` followed by `[["sb.ssr", STATUS, bool, bool, bool, bool, bool, timestamp_ms, "site"]]`:

- `STATUS 1` + all `false` = clean.
- `STATUS 2` + any `true` = flagged. The browser interstitial text tells the category: "trick you into revealing passwords" = deceptive/social-engineering; "install dangerous programs" = malware.

Human-readable version: `https://transparencyreport.google.com/safe-browsing/search?url=example.com`

## Our stack: check Search Console coverage first

`gsc sites --json` lists every property this account can read — check it BEFORE assuming a domain needs (re-)verification. The `<analytics-service-account>` service account already holds `siteFullUser` on `sc-domain:startupbros.com` and `sc-domain:prbot.ai`; a flag on either domain (or any subdomain of either) skips straight to Recovery below — no TXT record needed.

For any OTHER domain, `gsc` cannot add a new property (only `webmasters.readonly` + sitemap-submit are wired — see the `data-source-clis` skill, "Search Console"); verifying a brand-new domain is still a manual Search Console UI step (add Domain property → drop the TXT record at the registrar).

## Prevention checklist (every new public web project)

1. **No third-party trademarks in the domain.** `youtube-x.com`, `paypal-tool.io` = brand + login form = automated phishing flag, and a trademark complaint risk. Use subdomains of a domain you own (`tool.yourname.com`).
2. **Crawlers must never land on a credential form.** Root URL for anonymous visitors goes to a neutral landing page: no inputs, clear owner ("Operated by X"), explicit "Not affiliated with [brand]" if the product touches one. Login lives behind a link.
3. **Search Console on day one, every domain.** Run `gsc sites --json` to confirm it's already covered (see above); if not, add a Domain property and drop the TXT record at the registrar. It is the only channel where Google warns you BEFORE users see red screens, and the only door to request a review after a flag.
4. **Public URL = public site.** "Internal tool" means nothing to a classifier. Kill stray waitlist/signup forms on tools that are actually invite-only; young domain + email-collection forms looks like a harvesting kit.
5. **Verify like a stranger.** `curl -sL https://the-domain/` and check: lands on neutral content, no password field, no third-party brand in title/headings.

## Diagnosis workflow (site already flagged)

1. Run the Quick check on apex and www. Confirm flag + category.
2. Fetch the site anonymously (`curl -sL`), see exactly what Googlebot sees. Look for: brand names in domain/title/headings, immediate redirect to a credential form, public email-collection forms, young domain age (`whois`).
3. Git history is usually a red herring — the trigger is a re-crawl/reclassification or a user report, not a recent commit. Skim it only to rule out injected scripts or a compromised dependency.
4. If user uploads or third-party content are hosted on the domain, check whether a specific uploaded file/page tripped the flag — Search Console's Security Issues report lists sample URLs, but there is no API for it; check the UI.

## Recovery

1. Fix the public surface first (checklist above) and deploy. Reviews against an unchanged phishy surface get denied and repeat offenses take longer.
2. Confirm coverage: `gsc sites --json` — already listed (true today for `startupbros.com` and `prbot.ai`) → skip to step 3. Otherwise verify the domain (DNS TXT at the registrar, propagates in minutes).
3. Search Console > Security Issues > Request Review. One or two factual sentences: what the site is, who uses it, what was changed. **No API path exists for this step** (`gsc`'s scope is read + sitemap-submit only, same shape as the "no Request Indexing API" gap) — it is a manual UI action every time.
4. Typical turnaround 1-3 days. Validate: re-run the Quick check until it returns `STATUS 1`, then confirm in a browser.
5. If the domain itself contains someone else's trademark, treat the cleared flag as temporary — it stays re-flag-prone. The durable fix is moving to a neutral domain.

## Worked example

`example-tool.com` (illustrative domain, incident from 2026-07): an internal team tool used a third-party brand in its real domain and redirected anonymous visitors straight to a similarly branded email+password form, plus a public waitlist form. Flagged as deceptive site; blocked in Brave/Chrome. Fix: deleted waitlist page, added neutral `/welcome` landing (ownership + non-affiliation notice), de-branded all logged-out pages, then Search Console review. Code was never the problem.
