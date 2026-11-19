---
paths:
  - "db/**/*.rb"
  - "app/services/analytics/**/*.rb"
  - "app/models/event.rb"
  - "spec/support/test_database.rb"
  - "config/application.rb"
---

### 8. TimescaleDB rules

Analytics events live in a TimescaleDB hypertable, not an ordinary table. The
following are hard constraints, each verified against the running TimescaleDB
2.29 / PostgreSQL 17 instance — do not take them on faith from a doc page, and
do not "fix" them without re-probing.

**There is no schema file, on purpose.** `pg_dump --schema-only` does not emit
`create_hypertable(...)`, does not emit `WITH (timescaledb.continuous)`, and
does not emit retention or columnstore policies — a continuous aggregate dumps
as a plain `CREATE VIEW`. Loading such a dump produces a database that *works
but is silently wrong*: ordinary tables instead of hypertables, and views that
re-scan raw events with no materialization. Nothing raises. So:

- `dump_schema_after_migration` and `maintain_test_schema` are both `false`
- migrations are the single source of truth for every environment
- never add `db/schema.rb` or `db/structure.sql` back
- write Timescale DDL idempotently (`if_not_exists => true`) so re-running is safe

**Migrations that create continuous aggregates need `disable_ddl_transaction!`.**
`CREATE MATERIALIZED VIEW ... WITH DATA cannot run inside a transaction block`.

**`refresh_continuous_aggregate()` cannot run inside a transaction either.**
Specs that assert on materialized aggregate data must be tagged
`:continuous_aggregate`, which drops the transactional fixture and truncates
afterwards. See `spec/support/test_database.rb`.

**Unique indexes on a hypertable must include the partitioning column.**
`CREATE UNIQUE INDEX ON events (visitor_hash)` fails with *cannot create a
unique index without the column "occurred_at" (used in partitioning)*. The
events hypertable therefore has no plain `id` primary key.

**Procedure vs function matters.** `refresh_continuous_aggregate` and
`add_columnstore_policy` are procedures — invoke with `CALL`.
`add_retention_policy` and `add_continuous_aggregate_policy` are functions —
invoke with `SELECT`. Getting it wrong raises *"... is a procedure"*.

**Deleting raw rows does NOT delete aggregate rows, and it never self-heals.**
`DELETE FROM events` records an invalidation, but each refresh policy only looks
back `start_offset` (3 days for `events_by_hour`, 10 for the others), so an older
invalidation is never processed. Measured: deleting a site left 0 raw events and
40 rows in each of the three aggregates, including the visitor-grain one. Deleting
from the aggregate is impossible (it is a UNION view under real-time aggregation),
so the fix is to re-refresh the affected window — which is what
`Analytics::ReconcileAggregates` does and why `Sites::Delete` and
`Privacy::EnforceDataRetention` both call it. **Any new code path that bulk-deletes
historical events must call it too**, or reports will keep showing data that has
been erased.

**`COUNT(DISTINCT)` is allowed in a continuous aggregate here and is exact** —
verified across chunk boundaries and across incremental re-refresh. This is
newer behaviour than most documentation and blog posts describe, and it is why
we need neither `timescaledb_toolkit` (not available in our image) nor
hyperloglog. **But distinct counts still cannot be summed across buckets** — a
daily aggregate's `visitors` column must never be `SUM()`ed to produce a weekly
unique count. Use the visitor-grain aggregate for arbitrary date ranges.
