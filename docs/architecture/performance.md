# Dashboard performance

Numbers, and the decisions taken from them. Every figure here was measured on this
codebase rather than reasoned about, because the reasoning was wrong twice.

## Method

`ActiveRecord::Base.uncached`, five runs, median reported. Without `uncached` the
query cache returns about 1 ms for everything and the numbers are meaningless — the
first attempt at this measured 1.0 ms across the board and had to be thrown away.

Two datasets:

- **Small**: 17,771 events over 90 days. A real hobby site.
- **Large**: 600,000 events over 90 days, 40,000 distinct visitors, 500 paths.
  About 6,700 events a day, which is a busy small business.

## Where the time goes

| | 17k events | 600k events |
|---|---|---|
| 7-day summary | 9 ms | 12 ms |
| 30-day summary | 13 ms | 5 ms |
| 12-month summary | 18 ms | 5 ms |
| 30-day timeseries | 6 ms | 3 ms |
| Goal report | 7 ms | 1 ms |
| Realtime | 0.4 ms | 0.9 ms |
| **Eight breakdown panels** | **48 ms** | **1,233 ms** |
| 30-day summary, filtered | 19 ms | 78 ms |

The headline metrics barely move with volume, because they read the continuous
aggregates — `visitor_days` and `events_by_hour` grow with distinct visitors and
with hours, not with events. The breakdowns scan raw events, by design (the
aggregates carry no dimension columns; see [aggregates.md](aggregates.md)), and
they are effectively the entire cost of the page.

## What was changed

**The eight panels now come from one scan.** They ran the same query with the same
conditions eight times over. `Analytics::Breakdown.batch` asks for all eight
groupings in a single pass with `GROUPING SETS`.

```
eight separate scans   1,233 ms
one GROUPING SETS pass   836 ms   (1.48x, 397 ms off every dashboard render)
```

The suppression code was deliberately left alone. `Breakdown#partition` and
`#to_row` are shared by both paths and receive exactly the same row shape, so
k-anonymity cannot have been altered by the change — and
`spec/services/analytics/breakdown_batch_spec.rb` asserts the batch output is
identical to the per-dimension output, row for row, including the suppression
counts, with and without a threshold and with and without filters.

## What was tried and rejected

**Two-phase distinct counting in the batch query.** Grouping by
`(value, visitor_hash)` and counting rows beats `COUNT(DISTINCT)` for a single
dimension, which is why the single-dimension query uses it. Applied to eight
grouping sets it is *slower than doing nothing*:

```
eight separate scans, two-phase   1,233 ms
one scan, COUNT(DISTINCT)           836 ms
one scan, two-phase               1,356 ms
```

Each grouping set's intermediate is one row per `(value, visitor)` pair, and eight
of those have to be materialised before the outer aggregate runs. The optimisation
that helps one dimension hurts eight.

**Re-bucketing `events_by_hour` to serve non-UTC day-grain reports.** Would require
summing a distinct count across buckets: measured 428,660 against a ground truth of
60,000. See [aggregates.md](aggregates.md).

**Raising `SIDEKIQ_CONCURRENCY` for ingest throughput.** 150,000 buffered events
flushed in 6.85 s at concurrency 5 and 8.39 s at 15. The multi-row INSERT is the
bottleneck; more threads only add contention.

## Still on the table

Not done, with the reason:

- **Caching summary, timeseries and breakdowns.** The obvious next step for the
  breakdowns, and the one with real risk attached: the key has to include the
  k-anonymity threshold and the site's timezone, or a cached response can leak a row
  that the current threshold would withhold. Worth doing deliberately.
- **Splitting ingest onto its own Puma process** so a slow dashboard query cannot
  occupy a thread that a beacon needs. Currently mitigated by the 15-second
  `statement_timeout` on web (see `config/database.yml`), which bounds the damage
  rather than preventing it.
- **Boundary trimming for non-UTC ranges.** Described in
  [aggregates.md](aggregates.md). Turns a 90-day raw scan into a 48-hour one while
  staying exact, and needs no new aggregate.

## If you are measuring this yourself

The realtime counter and the goal report are already trivial; the summary and
timeseries are bounded by the aggregates. If a dashboard feels slow, it is the
breakdowns, and the two questions worth asking first are whether a filter is forcing
a raw scan and whether the site's timezone is UTC.
