---
paths:
  - "app/models/campaign*.rb"
  - "app/controllers/campaigns_controller.rb"
  - "app/controllers/sites/**/*.rb"
  - "app/views/campaigns/**/*.erb"
  - "app/services/analytics/campaign*.rb"
  - "app/javascript/controllers/campaign_builder_controller.js"
  - "spec/models/campaign*_spec.rb"
  - "spec/requests/*campaigns_spec.rb"
  - "spec/requests/cross_tenant_isolation_spec.rb"
---

### 12. Things that look like bugs but are deliberate (campaigns)

Before "fixing" any of these, read the linked document.

- **A campaign link is validated against `Ingest::PathScrubber` before it is
  saved, and that is the whole reason the builder is in the product.** The
  scrubber discards a `utm_*` value that reads as a token — 25+ characters of
  `[A-Za-z0-9\-_.]`, or anything containing `@` — because mail platforms put a
  per-recipient hash in `utm_content` and that is a visitor identifier wearing a
  marketing label. A link carrying one saves cleanly, is sent to a mailing list,
  and reports 0 forever, which on screen is indistinguishable from a campaign
  nobody clicked. So `CampaignLink` calls `PathScrubber.storable_param_value?`,
  the one the ingest path itself calls, rather than copying the regexes — a
  second copy would drift, and the drift would be silent in exactly the same
  way. Note the collateral: `summer-sale-2026-newsletter` is 27 characters and
  is refused; the error says to break it with a space, which survives because a
  space is not in that character class.
- **A campaign OWNS its tag, and its links carry a copy.** A `Campaign` is a name
  and a `utm_campaign`; every `CampaignLink` under it is one channel — Discord,
  Facebook, the newsletter — differing in source and medium. The tag is copied
  down by `CampaignLink#adopt_campaign_tag` on every save, and `Campaign` moves it
  onto every link in one statement when it is renamed. Both halves are
  load-bearing. The copy exists because the five values are the join key that
  matches a link to its events and that key is enforced by a unique index, which
  cannot span a join. The copy being *maintained* is what stops a rename leaving
  the heading grouping by one spelling while its own links measure another —
  which is the split campaign this whole screen exists to make visible, produced
  by the screen itself. `utm_campaign` is in neither controller's permitted params
  for the same reason: one place to say what a campaign is called.
- **A campaign's own figure is NOT the sum of its links' rows, and may never
  become one.** `visitors` and `visits` are `COUNT(DISTINCT)`, so adding the
  Discord row to the Facebook row counts everybody who followed both of them
  twice and claims an audience larger than the one that existed — §8's rule
  against summing distinct counts, one grain down. `CampaignReport#for_campaign`
  reads its own `GROUP BY utm_campaign` over the same events. The note under the
  table says the heading is smaller than the rows on purpose, because a total
  under the numbers it sits above reads as a bug until you know why. This is also
  why a pure folder — links keeping their own tags — was rejected: with no shared
  value to group by, the only total available is the forbidden sum.
- **THERE ARE TWO CAMPAIGN SCREENS AND THEY DIVIDE ON ONE LINE: the builder is
  under the site, the list is not.** `/sites/:token/campaigns` is where a
  campaign is built, edited and read link by link, beside Goals and Funnels,
  because a campaign is a property of a site — its tag is unique per site and
  its links are validated against that site's own hostnames. `/campaigns` is a
  list across every site the viewer can read and has no builder, no `?site=`,
  and nothing you can change from it. This replaced an arrangement where the
  builder itself was top level with the site as a `?site=` parameter and a
  switcher on the screen, which cost two things: `CampaignScreen` had to
  re-implement the tenant check `SiteScoped` already owned, and reading what a
  campaign did and then wanting anything else about that site meant picking the
  site again. The tenant boundary is now SiteScoped's, in one place, and
  `spec/requests/cross_tenant_isolation_spec.rb` holds it there.
- **The list may carry a period; it may not carry a total.** `Analytics::Period`
  resolves a preset against ONE site's timezone, so "last 30 days" across sites
  in Berlin, Kolkata and UTC is three different windows — which is fine per row
  and a lie the moment anything is added. So the rows are grouped BY SITE, each
  group states the window and the timezone it was measured in, and there is no
  cross-site figure anywhere on the page. Presets only: a custom range is two
  absolute dates resolved in a site's own zone, which several sites cannot agree
  on. No "all time" either, unlike the sites index — that one reads
  `events_by_hour`, and the aggregates carry no UTM columns (§8), so an
  unbounded campaign total would scan every chunk on the instance. The list also
  states no withheld COUNT, deliberately: every campaign the account built is
  named on it whether or not it has a figure, so "2 withheld" beside three
  dashes would say "somebody came, fewer than k of them" about a campaign that
  can be sent to one person. The dash conflating "nobody" with "too few" is the
  protection.
- **`Analytics::CampaignPerformance` owns the campaign grain, for one site and
  for many, and both screens read it.** The site's own screen calls it through
  `Analytics::CampaignReport#for_campaign`; the list calls it once for every site
  on the page. A second copy would drift on the part that matters most and drift
  silently — which campaigns the k-anonymity threshold withholds — and two
  screens disagreeing about whether a campaign exists at all is worse than either
  being wrong on its own. It is ONE query whatever the site count (the same rule
  `Analytics::SiteTotals` follows, and it matters more here because this reads the
  raw hypertable), each site's window OR'd into the WHERE clause, and each site's
  rows partitioned on that site's OWN threshold — a shared partition would apply
  one customer's rule to another customer's visitors.
- **`Analytics::CampaignReport` groups by all FIVE utm columns, and is not
  `Analytics::Breakdown` with `utm_campaign` as its dimension.** That panel
  answers "which campaign"; a campaign LINK is a tuple, and the email, the tweet
  and the banner of one campaign are one row there with one figure — the number
  already on the dashboard. The tuple is also the join key back to
  `campaign_links`, which is why a unique index forbids two links sharing one
  (they would be one row of visitors and two rows on screen each claiming all of
  it) and why the index `COALESCE`s the two nullable columns: in a unique index
  NULL never equals NULL, and no term and no content is by a distance the
  commonest shape of link. Values are lower-cased on write because the match is
  exact and case-sensitive — `Newsletter` beside `newsletter` is the split
  campaign this screen exists to make visible, which is what the "Campaigns not
  built here" table is for.
- **The campaign pickers take their options from the report already on the page,
  not from a second `Breakdown` call.** §9 requires a picker's observed values to
  carry the k-anonymity threshold, and the tuple threshold is stricter than any
  single column's, so this satisfies the rule more tightly and costs no extra
  scan. The site's own saved values are unioned in unsuppressed, because they are
  the customer's own rows rather than a statement about visitors. A saved link
  whose row was withheld shows a dash, and the note under the table says the dash
  means "nobody, or too few to report" without saying which — naming the second
  would publish "somebody came, fewer than k of them" for a link that can be sent
  to one person.
