# Storage and aggregates

Everything here was verified against the running TimescaleDB 2.29 / PostgreSQL 17
instance rather than taken from documentation. Several of these behaviours differ
from what most TimescaleDB blog posts and older docs describe, so re-probe before
"correcting" anything below.

## The events hypertable

One row per event, in `events`. It is a hypertable partitioned by time only:

```sql
SELECT create_hypertable(
  'events',
  by_range('occurred_at', INTERVAL '7 days'),
  create_default_indexes => false
);
```

**Why 7-day chunks.** Small installs get a handful of chunks instead of hundreds
of near-empty daily ones, while a site doing 10M events a month still lands about
2.3M rows per chunk, comfortably inside the "recent chunks should fit in memory"
guidance.

**Why time-only partitioning.** Space partitioning on `site_id` is a common
suggestion and is usually wrong on a single node: it multiplies chunk count,
gains nothing for queries that already filter on time, and the tenant locality it
would provide is delivered instead by `segmentby = 'site_id'` in the columnstore.

**Why `create_default_indexes => false`.** Timescale would create an index on
`occurred_at` alone. Every query in this application filters by site first, so
that index is pure write overhead. Ours are:

| Index | Serves |
|---|---|
| `(site_id, occurred_at DESC)` | every dashboard query |
| `(site_id, visitor_hash, occurred_at)` | funnels, walking one visitor in order |
| `(site_id, event_name, occurred_at DESC)` where `event_name <> 'pageview'` | goals and custom-event breakdowns; partial because pageviews are the overwhelming majority and are never looked up this way |

**No primary key.** A hypertable requires any unique index to include the
partitioning column:

```
ERROR: cannot create a unique index without the column "occurred_at" (used in partitioning)
```

An analytics event needs no durable identity, so the table simply has no primary
key. `Event.implicit_order_column` is set to `occurred_at`, without which
ActiveRecord raises `MissingRequiredOrderError` on `first`/`last`.

**Columnstore and retention.** Chunks older than 14 days are converted to
columnar storage, segmented by `site_id` and ordered by `occurred_at DESC`. A
global retention policy drops chunks after 790 days as a backstop, deliberately set
ABOVE the 760-day (25 month) per-account maximum so it never pre-empts a legitimate
setting; per-account
retention is enforced separately (see below).

Note the procedure-vs-function distinction, which is easy to get wrong:

```sql
CALL add_columnstore_policy('events', after => INTERVAL '14 days');   -- procedure
SELECT add_retention_policy('events', drop_after => INTERVAL '790 days'); -- function
```

`SELECT add_columnstore_policy(...)` fails with *"add_columnstore_policy(...) is
a procedure"*.

## The three continuous aggregates

A continuous aggregate is only worth its write cost where it collapses many rows
into few. These three do:

| Aggregate | Grain | Collapses to | Serves |
|---|---|---|---|
| `events_by_hour` | `(hour, site_id)` | 24 rows per site per day, **independent of traffic volume** | headline metrics, the timeseries chart |
| `visitor_days` | `(day, site_id, visitor_hash)` | one row per visitor per day | unique visitor totals over a range |
| `session_days` | `(day, site_id, session_hash)` | one row per session per day | bounce rate, visit duration |

Measured on a 15k-event demo dataset: `events_by_hour` 721 rows, `visitor_days`
451 rows, `session_days` 3601 rows against 3601 raw events. The first two collapse
substantially; `session_days` collapses only as much as visitors view multiple
pages, but bounce rate cannot be derived from any event-grain aggregate, so it
earns its place regardless.

One knowable bias rides along with `session_days`: its grain is *(day, session)*,
so a session that crosses UTC midnight materialises as two rows — counted as two
visits, each fragment bouncing or not on its own pageviews, each contributing its
own shorter duration to the average. The raw-scan path folds the same session into
one row, so the aggregated and raw paths can disagree by exactly the number of
midnight-spanning sessions in the window. This is the same splitting problem that
disqualifies an hour-grain session rollup (discussed under the timezone cliff
below) at 1/24th the frequency: only sessions active across midnight UTC are
affected, a fraction of a percent for most sites. Exactness would mean re-folding
on `session_hash` across the boundary, which stops the aggregate being a plain
per-bucket read — not worth it at this size, but the asymmetry is real and
deliberate, so do not "fix" one path to match the other without reading this.

### What was considered and rejected

**A wide "every dimension" aggregate** grouped by visitor *and* path *and*
referrer *and* country *and* device. For real traffic this produces roughly one
row per event, so it would double storage while collapsing nothing. Breakdowns
are answered from the raw hypertable instead, which is also what exact
`COUNT(DISTINCT)` under arbitrary filters requires.

**Hyperloglog / `approx_count_distinct`.** These live in `timescaledb_toolkit`,
which is **not present** in the `timescale/timescaledb:latest-pg17` image. Verified:

```sql
SELECT name, installed_version FROM pg_available_extensions
WHERE name IN ('timescaledb_toolkit', 'hll');
-- neither is available
```

Which turned out not to matter, because of the next section.

## `COUNT(DISTINCT)` works in a continuous aggregate

Historically this was forbidden. In TimescaleDB 2.29 it is accepted **and
correct**. Verified with a 7-day bucket deliberately spanning seven 1-day chunks,
a visitor present in every chunk, and a visitor hitting 50 times inside one
bucket:

- cross-chunk deduplication: exact match against ground truth
- within-bucket deduplication: exact match
- a late-arriving row inserted into an already-materialised bucket, then
  re-refreshed: exact match (14 → 15)
- `EXPLAIN` confirms reads hit the materialisation hypertable
  (`_hyper_9_15_chunk`), so it is genuinely materialised rather than silently
  falling back to the raw table

Also accepted in a CAGG definition here, contrary to older documentation:
`COUNT(*) FILTER (WHERE …)`, a `WHERE` clause, `ORDER BY`, grouping by a
high-cardinality column, and a CAGG built on top of another CAGG.

## The one rule that governs every query

> **A distinct count is correct within a bucket and must never be summed across
> buckets.**

`events_by_hour.visitors` is the exact unique visitor count for that hour. Adding
24 of them does not give you the day's unique visitors — it counts every
returning visitor once per hour they were active. Demonstrated on the demo
dataset:

| | |
|---|---|
| `SUM(visitors)` over hourly rows, 30 days | **1,200** |
| `COUNT(DISTINCT visitor_hash)` from `visitor_days` | **40** |
| ground truth from raw events | **40** |

Any range-wide unique count therefore comes from `visitor_days`, never from
summing `events_by_hour`.

### The honest caveat about multi-day uniques

Because the salt rotates at each site's local midnight, the same person produces a *different*
`visitor_hash` tomorrow. So a 30-day unique count from `visitor_days` equals the
sum of 30 daily counts either way — the aggregate is exact as a distinct count,
but the underlying identifiers are not stable across days, and no query can
recover cross-day identity. This is inherent to cookieless measurement and is
stated plainly in the UI rather than papered over. See
[../privacy/identity.md](../privacy/identity.md).

## Timezones and bucket alignment

Continuous aggregate buckets are UTC-aligned, because one aggregate serves every
site and cannot be bucketed per-site-timezone. For a site reporting in
`Europe/Berlin`, "today" is 22:00 UTC yesterday to 22:00 UTC today, which slices
through the middle of two UTC day buckets. Filtering `bucket >= from` would
silently drop the bucket the range starts inside and report a number wrong by
most of a day, with nothing to indicate it.

`Analytics::Scope` therefore refuses to use an aggregate unless the requested
range aligns to its bucket boundaries:

```ruby
def aggregated?       = filters.empty? && aligned_to?(1.day)
def hourly_aggregated? = filters.empty? && aligned_to?(1.hour)
```

Consequences:

- Default `Etc/UTC` sites take the fast path for everything.
- Non-UTC whole-hour offsets take the fast path for hourly charts and fall back
  to raw scans for day-aligned reports.
- The `:30` and `:45` offsets (India, Nepal, Chatham Islands, parts of Australia)
  fall back to raw scans throughout.
- **Any filter forces a raw scan**, because the aggregates carry no dimension
  columns.

Raw scans are exact, but they are not free, and an earlier version of this
paragraph said they were on the strength of a 15k-event measurement. Extrapolating
from 15k events to "fast at the scale where this arises" was wrong: the scale where
this arises is *any* non-UTC site at *any* volume, and the cost grows linearly with
event count.

Measured on 1,494,000 events over 90 days, timezone toggled between runs, three
paths interleaved seven times and medianed (with `ActiveRecord::Base.uncached` —
without it the query cache returns 1 ms for everything and the numbers are
meaningless):

| Report | `Etc/UTC` | `Europe/Berlin` | `Asia/Kolkata` | Penalty |
|---|---|---|---|---|
| 30-day summary | **148 ms** | 1,049 ms | 990 ms | 7.1× |
| 90-day summary | **144 ms** | 2,068 ms | 1,942 ms | **14.4×** |
| 30-day timeseries | **64 ms** | 424 ms | 433 ms | 6.6× |
| 90-day timeseries | **172 ms** | 1,315 ms | 1,421 ms | 7.6× |

Berlin and Kolkata land in the same place, which is the point worth internalising:
`hourly_aggregated?` being true buys a whole-hour-offset site nothing at all for a
day-grain report. **Choosing a non-UTC reporting timezone is a performance
decision**, not only a presentation one.

The obvious fix is a trap. Re-bucketing `events_by_hour` into local days means
summing its `visitors` column across hours, and distinct counts do not sum:
measured over 30 days, `SUM(events_by_hour.visitors)` gives **428,660** against a
ground truth of **60,000**. Bounce rate and duration cannot be salvaged that way
either, because an hour-grain session rollup splits every session that crosses an
hour boundary into two rows that each look like a separate one-pageview visit. An
`(hour, site_id, visitor_hash)` aggregate would be exact but collapses only 14%
(1,285,816 rows against 1,494,000 raw), which fails the test at the top of this
document for whether an aggregate is worth its write cost.

If the cliff is ever worth closing, the route is **boundary trimming**: split a
non-UTC range into a UTC-aligned interior plus two sub-24-hour edge slivers, read
the interior from the aggregates as usual, raw-scan only the edges, and take
`COUNT(DISTINCT)` once over the union rather than summing per bucket. Sessions need
re-folding on `session_hash` across the seam or bounce rate goes wrong there. That
turns a 90-day scan into a 48-hour one while staying exact, and needs no new
aggregate and no change to the write path.

## Deleting raw rows does not delete aggregate rows

This is the sharpest edge in the whole storage design, and it fails silently.

`DELETE FROM events` does **not** remove the corresponding rows from a continuous
aggregate. TimescaleDB records an invalidation and reconciles it on the next
scheduled refresh — but each policy only looks back `start_offset`:

| Aggregate | `start_offset` |
|---|---|
| `events_by_hour` | 3 days |
| `visitor_days` | 10 days |
| `session_days` | 10 days |

An invalidation older than that window is **never processed**. So deleting
historical events leaves the aggregates reporting them permanently.

Measured, before this was fixed: creating a site, writing 40 events backdated 200
days, refreshing, then running `Sites::Delete` left **0 raw events and 40 rows in
each of the three aggregates** — including `visitor_days`, which holds visitor
hashes. Both the UI and `docs/privacy/data-requests.md` promised erasure was
immediate and complete. It was neither.

Deleting from the aggregate directly is not available:

```
ERROR:  cannot delete from view "visitor_days"
DETAIL: Views containing UNION, INTERSECT, or EXCEPT are not automatically updatable.
```

The view is a UNION because real-time aggregation is enabled. The supported
mechanism is to **re-refresh the affected window** once the raw rows are gone,
which recomputes the buckets and drops the materialized rows:

```sql
CALL refresh_continuous_aggregate('visitor_days', '<from>', '<to>');
```

`Analytics::ReconcileAggregates` does this, and two callers must use it:

- **`Sites::Delete`** captures the site's event window *before* deleting (there is
  nothing to derive it from afterwards) and enqueues reconciliation.
- **`Privacy::EnforceDataRetention`** reconciles the window it swept, otherwise
  retention is not actually enforced for anything a report reads.

Two constraints on the reconciliation:

1. **It cannot run inside a transaction**, so it happens after `Sites::Delete`'s
   transaction commits, in a job.
2. **It is global across tenants.** The aggregates are not partitioned by site, so
   recomputing a window recomputes every site's buckets in it. That is why
   callers pass the actual range they deleted rather than `(NULL, NULL)`, and why
   the work is enqueued rather than done in a web request.

The window is widened to whole days on both sides, because a bucket is only
recomputed if the refresh window fully contains it.

## Retention, in two layers

Both are needed and they are not redundant.

1. **TimescaleDB's retention policy** on `events` DROPS whole chunks, which is
   fast and physically reclaims storage. But it can only express one global
   window, because a chunk holds rows for every site at once.
2. **`Privacy::EnforceDataRetention`**, nightly, enforces each account's own
   window with a `DELETE`. Retention is a compliance control a controller may be
   obliged to set tighter than our default, so it has to be per-account.

A `DELETE` leaves dead tuples for autovacuum rather than reclaiming space
immediately. That is the unavoidable cost of per-tenant retention; the global
chunk-drop policy is what keeps total storage bounded.

`visitor_days` and `session_days` follow the raw-event window (790 days) rather
than the longer aggregate window, because they contain per-visitor and
per-session rows. Keeping a visitor-grain table for five years would undercut the
retention promise made about `events` itself. `events_by_hour` holds no
identifiers and is kept for five years.

## Migrations, and why there is no schema file

`pg_dump --schema-only` against a database containing a hypertable, a continuous
aggregate and policies emits **none** of `create_hypertable`,
`WITH (timescaledb.continuous)`, `add_retention_policy`, or
`add_columnstore_policy`. With the `_timescaledb_*` schemas excluded the entire
output is:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA public;
CREATE TABLE public.ev ( ... );
CREATE VIEW public.ev_daily AS ...;      -- a PLAIN VIEW
CREATE INDEX ...
```

Loading that produces a database that **works but is silently wrong**: `ev` is an
ordinary table with no chunking, compression or retention, and `ev_daily` is a
plain view that re-scans raw events with zero materialisation. Nothing errors.
You find out when production gets slow.

So:

- `config.active_record.dump_schema_after_migration = false`
- `config.active_record.maintain_test_schema = false`
- no `db/schema.rb`, no `db/structure.sql`, ever
- every environment — development, test, CI, a fresh production install — is
  built by `bin/rails db:migrate`
- Timescale DDL in migrations is written idempotently so re-running is safe

Two migration constraints follow from TimescaleDB itself:

```
ERROR: CREATE MATERIALIZED VIEW ... WITH DATA cannot run inside a transaction block
ERROR: refresh_continuous_aggregate() cannot run inside a transaction block
```

So any migration creating a CAGG needs `disable_ddl_transaction!`, and specs that
assert on materialised data must be tagged `:continuous_aggregate` to drop the
transactional fixture (see `spec/support/test_database.rb`).

One ordering trap, found by a failing migration on a fresh database: the initial
`refresh_continuous_aggregate` must run **before** `add_continuous_aggregate_policy`,
or the migration's refresh collides with the background job the policy just
scheduled:

```
PG::LockNotAvailable: could not refresh continuous aggregate "events_by_hour"
due to a concurrent refresh
```
