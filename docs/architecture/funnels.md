# Sessions, goals and funnels

How multi-step behaviour is measured when there is no persistent identifier, and
what that genuinely costs.

## Sessions

A session is *the same visitor with no gap longer than 30 minutes*. That is a
sliding window, so it is implemented as a Redis key with a TTL: the key holds the
session id, `GETEX` reads it and extends its expiry in one round trip, and if the
visitor goes quiet the key evaporates and the next event opens a fresh session.

The first event of a session is stamped `is_entry = true` at ingest time, which is
what makes entry-page and bounce reporting possible without re-deriving session
boundaries at query time.

Details and the failure modes in [../privacy/identity.md](../privacy/identity.md).

### Bounce rate and visit duration

Both are session-level, so they need a session-grain rollup: you cannot tell how
many sessions had exactly one pageview from any event-grain count.

```sql
SELECT COUNT(*)                                        AS sessions,
       COUNT(*) FILTER (WHERE pageviews <= 1)          AS bounces,
       AVG(EXTRACT(EPOCH FROM ended_at - started_at))  AS avg_duration
FROM session_days
WHERE site_id = ? AND bucket >= ? AND bucket < ?
```

When filters are applied — which the aggregates cannot answer, having no
dimension columns — the same shape is computed from raw events with an inner
`GROUP BY session_hash`.

One known imprecision: `session_days` buckets by `time_bucket('1 day',
occurred_at)`, so a session spanning midnight appears as two rows with partial
durations. It affects a small fraction of sessions and is the standard trade;
bucketing sessions hourly would be far worse, splitting every session that
crosses an hour boundary.

## Goals

A goal matches either a **page path** or a **custom event name**, with `exact`,
`prefix` or `wildcard` matching. Wildcards compile to a SQL `LIKE` so the prefix
case can still use a b-tree index; `*` matches within a path segment and `**`
across them.

### Getting the denominator right

This is where goal reporting is usually wrong. A conversion rate is

> converting **visitors** ÷ **visitors** in the same window, under the same filters

Two mistakes are easy and both inflate the number:

- dividing unique converting visitors by **sessions**
- dividing by a total computed **without the filters applied**

`Analytics::GoalReport` computes the denominator from the same `Scope` as the
numerator, and both are `COUNT(DISTINCT visitor_hash)`.

A pageview goal is also constrained to `event_name = 'pageview'` and an event goal
to `event_name <> 'pageview'`, so a custom event that happens to carry the same
string as a path cannot satisfy a pageview goal.

## Funnels

### The query, and why it is not the obvious one

The obvious implementation computes, per visitor, `MIN(occurred_at) FILTER (WHERE
<step n matches>)` in a single `GROUP BY`, then checks the timestamps increase.
One pass, elegant, and **wrong**.

Consider a visitor who does this:

```
10:00  /pricing      ← first time step 2 matches
10:01  /             ← first time step 1 matches
10:02  /pricing
10:03  Signup
```

They completed the funnel in order. But `MIN(...) FILTER` records their *first*
`/pricing` at 10:00, which precedes their first `/` at 10:01, so the monotonicity
check fails and they are dropped entirely. Backtracking is extremely common
behaviour, so this undercounts systematically rather than at the margins.

Instead each step is a CTE that searches only the window **after** the previous
step's timestamp for that same visitor:

```sql
WITH s0 AS (
  SELECT e.visitor_hash, MIN(e.occurred_at) AS t
  FROM events e
  WHERE e.site_id = ? AND e.occurred_at >= ? AND e.occurred_at < ?
    AND e.event_name = 'pageview' AND e.path = '/'
  GROUP BY e.visitor_hash
),
s1 AS (
  SELECT p.visitor_hash, MIN(e.occurred_at) AS t
  FROM s0 p
  JOIN events e
    ON e.site_id = ?
   AND e.visitor_hash = p.visitor_hash
   AND e.occurred_at >= p.t
   AND e.occurred_at <= p.t + (? * INTERVAL '1 second')
   AND e.event_name = 'pageview' AND e.path = '/pricing'
  GROUP BY p.visitor_hash
)
-- ... one CTE per step ...
SELECT (SELECT COUNT(*) FROM s0) AS step_0,
       (SELECT COUNT(*) FROM s1) AS step_1
```

The chain narrows at every stage, and each lookup rides the
`(site_id, visitor_hash, occurred_at)` index that exists for exactly this query.
Measured: **34 ms** for a 3-step funnel over 15k events.

Both behaviours are covered by spec: a visitor who backtracks and then completes
in order **is** counted; a visitor whose step 3 occurs only before step 2 is
**not**.

### The honest limitation

A funnel window longer than the identifier's lifetime will undercount, because
the same person is a different `visitor_hash` on the far side of the daily salt
rotation. There is no way around this without storing something durable, which is
the thing we are not doing.

So:

- the default window is **24 hours**
- `Funnel#window_exceeds_identity_lifetime?` is true above that, and the funnel
  view says so in a notice rather than quietly reporting a low number
- the maximum is 30 days, and choosing it is an informed decision

This is a genuine functional cost of cookieless measurement. Stating it is better
than the alternative, which is a customer eventually noticing the numbers are low
and losing trust in everything else on the page.

### Performance at scale

Funnels cannot use the continuous aggregates — they need per-visitor event
ordering, which no aggregate preserves. The mitigations already in place are the
bounded reporting period, the bounded completion window, and the composite index.

If a funnel over a very large site becomes slow, the intended next step is a
`funnel_results` table refreshed by a Sidekiq cron job rather than computing on
request. That is not built, because at the scale this currently targets a 34 ms
query does not need a cache, and an unnecessary materialisation is a correctness
risk (stale funnels) for no gain.

## Referrers and campaigns

`Ingest::Referrer` produces a **source** (what a human reads: "Google", "Hacker
News", "example.com") and a **channel** (how a marketer groups it: Organic
Search, Social, Email, Referral, Direct, Paid).

- **UTM beats the referrer header** when both are present. A UTM tag is an
  explicit statement of intent by whoever built the link; the referrer is a guess.
- **Only the referrer's host is kept.** A full referring URL can contain search
  terms, session tokens, or a path identifying an individual — a password-reset
  link, a private document. The host answers "where did they come from" and none
  of the rest.
- **Subdomains resolve to their parent**, so `news.google.com` maps to Google
  without needing its own entry.
- **Self-referrals are not a source.** A link from one page of the site to another
  would otherwise make every site its own top referrer.

The mapping is a hand-maintained list in `config/referrer_sources.yml` — about 90
entries covering what sites actually see, including AI assistants. Matomo's and
Snowplow's lists are thousands of entries covering dead search engines and carry
their own licences. Unknown hosts fall through to "Referral" labelled with the
bare hostname, which is a perfectly good answer.
