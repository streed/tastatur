---
paths:
  - "app/services/analytics/**/*.rb"
  - "app/values/analytics/**/*.rb"
  - "app/lib/analytics/**/*.rb"
  - "spec/services/analytics/**/*.rb"
  - "app/helpers/flow_map_helper.rb"
  - "app/models/funnel*.rb"
  - "app/controllers/shared_dashboards_controller.rb"
  - "spec/requests/journeys_spec.rb"
  - "spec/requests/breakdown_suppression_spec.rb"
  - "docs/architecture/aggregates.md"
  - "docs/architecture/funnels.md"
---

### 12. Things that look like bugs but are deliberate (analytics reports)

Before "fixing" any of these, read the linked document.

- **Breakdowns scan raw events** instead of an aggregate. The aggregates carry no
  dimension columns on purpose; a wide one would be ~1 row per event.
  `docs/architecture/aggregates.md`
- **Public shared dashboards ignore filter parameters.** Filtering someone else's
  audience is a re-identification tool.
- **`Analytics::PageFlow` counts the step taken IMMEDIATELY next, and that is what
  makes it not a funnel.** The tempting refactor is to reuse `FunnelReport`'s
  chained CTE, whose steps are satisfied by a match anywhere later in the visit.
  Do that and a visitor who went `/` → `/docs` → `/pricing` lands in both the
  `/docs` and the `/pricing` branch of the same node, the branches sum past the
  node's own visitor count, and the percentages exceed 100% — a co-occurrence
  table drawn as a flow diagram. Each level joins on `n + 1`, and
  `spec/services/analytics/page_flow_spec.rb` pins exactly that case. Three
  further halves that are load-bearing: it walks `session_hash`, not
  `visitor_hash`, so a journey is one sitting and survives the midnight salt
  rotation intact; consecutive repeats of one step collapse, or the commonest
  "next page" for every page on the site is itself; and the anchor CTE is
  `DISTINCT ON (session_hash)` rather than a `GROUP BY` including `visitor_hash`,
  because a visit spanning that rotation holds two visitor hashes and would
  otherwise be walked, and counted, twice. Suppression applies at every level and
  includes the terminal "left the site" row — the node total is on screen, so
  that row is `total − Σvisible` and is precisely what complementary suppression
  exists to protect. There is deliberately **no `(site_id, session_hash,
  occurred_at)` index**: it was built and measured, and the planner declined it in
  favour of `idx_events_site_time` plus a sort. Re-measure before adding it. Note
  also that `CREATE INDEX CONCURRENTLY` is refused outright on a hypertable —
  `WITH (timescaledb.transaction_per_chunk)` is the form that works.
- **A step is a page OR a custom event, and it is an `Analytics::FlowStep` — a
  (kind, value) pair — everywhere, never a bare string.** The click between two
  pages is usually the interesting part of the journey, so the Journeys screen
  passes `include_events: true` and the event lands BETWEEN the two pages rather
  than beside them. The kind test stays *inside* each branch of the chained CTE
  for the reason the funnel bullet below gives: a customer may name an event
  after the page it leads to, and `WHERE value = ?` alone makes the two one step.
  Three consequences worth knowing before they look like bugs. `include_events`
  defaults to **false**, because `Analytics::Dashboard`'s two flow panels are
  titled "The page before/after this one" and a site firing one event per page
  would have them report nothing else — the screen that wants events asks. The
  URL carries kinds in a **parallel `kind[]` array that is omitted entirely when
  every step is a page**, so links written before this existed still work and the
  common one is unchanged. And `STEP_ORDER` breaks an `occurred_at` tie by putting
  the pageview first — a click and the page it fired on arrive in separate
  beacons and tie often, and two window functions over an unstable order will
  number the steps one way and collapse the repeats another.

- **A funnel step's matcher lives in `funnel_step_conditions`, not on the step,**
  and the `kind` / `match_value` / `match_type` columns were REMOVED from
  `funnel_steps` rather than kept alongside it. A step is satisfied by any ONE of
  its conditions, each with its own kind — "the /welcome pageview OR the Signup
  event" — because real flows branch, and without OR such a flow has to be split
  into one funnel per branch, which cannot be added back together: a visitor who
  took both is counted in both. Restoring a matcher onto the step would give it
  two places to say what it matches, one of which the report reads. The OR is the
  step's predicate inside the same chained CTE, so ordering is unchanged, and the
  kind test stays *inside* each branch or a custom event named `/welcome` starts
  satisfying a step that asks for the page. `docs/architecture/funnels.md`
- **The Journeys report is not reachable from a public shared dashboard,** and
  the flow panels never render there. A journey is a conjunction that narrows the
  crowd at every hop, so it is a sharper re-identification tool than any single
  filter — the reason the bullet above exists, one step further along.

- **The sites index totals are ALL TIME and carry no visitor figure.** Both halves
  are load-bearing. A period switcher there would be lying: `Analytics::Period`
  resolves a preset against ONE site's timezone, so "last 30 days" across sites in
  Berlin, Kolkata and UTC is three different windows added together — a lifetime
  total has no boundary to get wrong. And the metrics are exactly the columns of
  `events_by_hour` that may be SUMmed across buckets: pageviews, custom events, and
  `entries` (one per session, so it counts visits started). `visitors` and
  `sessions` are distinct counts, which §8 forbids summing; even taken exactly from
  `visitor_days` an all-time unique count would be a count of visitor-days wearing
  the word "visitors", because the salt rotates at each site's midnight.
  `Analytics::SiteTotals` reads the aggregate and never the hypertable, which is
  what makes an unbounded total affordable — `COUNT(*)` over `events` with no time
  bound is a scan of every chunk on the instance, the trap `Admin::InstanceSummary`
  avoids by bounding its own count to 24 hours. Note the spec hazard this creates:
  materialized aggregate rows survive the suite's truncation, and an all-time query
  has no window to exclude a recycled site id's leftovers with — see
  `Tastatur::TestDatabase.clear_materialized_aggregates!`.
