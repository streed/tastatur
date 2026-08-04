# Development

## Getting started

```bash
git clone https://github.com/streed/tastatur.git
cd tastatur
docker compose up
```

That is the whole setup. The working directory is bind-mounted into the
containers, so editing a file reloads Rails and rebuilds the CSS without a
restart. Open <http://localhost:3000> and sign in as `user@example.com` /
`password`.

Fill the dashboard with plausible traffic:

```bash
docker compose exec web bin/rails tastatur:demo_data DAYS=90
```

That also builds four funnels on the demo site and sends a share of the traffic
walking them, dropping out step by step — so the funnel screens have something
to report rather than the flat lines independently-drawn pages produce. It is
idempotent: the site's events are replaced and the funnels are rebuilt from the
declaration in `lib/tasks/demo_data.rake` on every run.

Prefer running Ruby on the host?

```bash
docker compose up -d timescaledb redis redis-privacy   # dependencies only
bin/dev-setup
bin/dev
```

## Everyday commands

```bash
bin/dspec                        # full suite, in the container, against the test DB
bin/dspec spec/lib               # a subset
bin/dspec spec/services/analytics/funnel_report_spec.rb:64

docker compose logs -f web css worker
docker compose exec web bin/rails console
docker compose exec timescaledb psql -U postgres -d tastatur_development
```

## The footguns

These have all bitten during development. Each is now either enforced by code or
covered by a spec, but knowing why saves an hour.

### There is no schema file, and adding one back is a mistake

`pg_dump --schema-only` of a TimescaleDB database emits **none** of
`create_hypertable`, `WITH (timescaledb.continuous)`, or the retention and
columnstore policies. A continuous aggregate dumps as a plain `CREATE VIEW`.
Loading such a dump gives you ordinary tables instead of hypertables and views
that re-scan raw events with no materialisation — a database that works but is
quietly wrong, with nothing raising an error.

So `dump_schema_after_migration` and `maintain_test_schema` are both `false`,
there is no `db/schema.rb` or `db/structure.sql`, and every environment is built
by running migrations. `spec/rails_helper.rb` runs pending migrations against the
test database at boot.

Verified end to end: dropping `tastatur_test` and running `db:prepare` produces
1 hypertable, 3 continuous aggregates and 14 tables.

### Migrations that create a continuous aggregate need `disable_ddl_transaction!`

```
ERROR: CREATE MATERIALIZED VIEW ... WITH DATA cannot run inside a transaction block
```

### Materialise before adding the refresh policy

Adding the policy first schedules a background refresh that begins immediately,
and the migration's own refresh then collides with it:

```
PG::LockNotAvailable: could not refresh continuous aggregate "events_by_hour"
due to a concurrent refresh
```

This failed `db:prepare` on a fresh database. Order: create → refresh → add
policy.

### Specs that need materialised aggregate data must be tagged

```
ERROR: refresh_continuous_aggregate() cannot run inside a transaction block
```

So RSpec's transactional fixtures cannot force a refresh. Tag the example:

```ruby
it "rolls up visitors", :continuous_aggregate do
```

which drops the transaction and truncates afterwards instead. Most specs do not
need this — `Breakdown`, `FunnelReport` and `GoalReport` all read raw events.

### Procedure versus function

```sql
CALL   refresh_continuous_aggregate('events_by_hour', NULL, NULL);   -- procedure
CALL   add_columnstore_policy('events', after => INTERVAL '14 days'); -- procedure
SELECT add_retention_policy('events', drop_after => INTERVAL '790 days'); -- function
SELECT add_continuous_aggregate_policy(...);                          -- function
```

Getting it backwards raises *"... is a procedure"*.

### `only: :index` in a callback breaks controllers without an index

Since Rails 7.1, naming an action in `only:` that the controller does not define
raises. `ApplicationController` therefore uses `if:`/`unless:` predicates that
test `action_name` at request time.

### Distinct counts must never be summed across buckets

`events_by_hour.visitors` is exact for that hour. Summing 24 of them counts every
returning visitor once per active hour: 1,200 instead of 40 on the demo dataset.
Range-wide unique counts come from `visitor_days`. See
[architecture/aggregates.md](architecture/aggregates.md).

### Daily aggregates are UTC-bucketed

A non-UTC site's "today" slices through two UTC day buckets, so
`Analytics::Scope#aggregated?` refuses the aggregate unless the range aligns to
its bucket boundaries and falls back to an exact raw scan. Do not "optimise" that
check away.

### Tailwind's watcher misses new directories

Tailwind v4 registers filesystem watches for directories that exist at startup.
Create a new one and nothing in it is scanned, so utilities used only in those
templates are silently absent and the page renders half-styled with no error.
`bin/tailwind-watch` polls mtimes instead, and `app/assets/tailwind/application.css`
declares explicit `@source` globs so content detection is deterministic.

### The flag font is first in the font stack, and moving it breaks Windows

`app/assets/fonts/twemoji-country-flags.woff2` exists because the country
breakdown draws its flags from the country code itself — two regional indicator
letters that an emoji font composes into one glyph. macOS and Linux do that with
their own emoji fonts. Windows does not: Segoe UI Emoji ships no flag glyphs at
all, and because it *does* cover the two letters individually, font fallback
stops there and draws two boxed capitals. Listing our font anywhere but FIRST in
`--font-sans` means Windows never reaches it, which is why
`spec/requests/country_flags_spec.rb` asserts the position rather than only that
the panel renders. The `unicode-range` is the other half: it keeps the 76KB off
every page that has no flag on it.

The alternative was ~250 vendored SVGs to licence-check and keep in step with ISO
3166. Third-party attribution: the file is Twemoji Mozilla, taken from
`country-flag-emoji-polyfill` 0.1.10 (MIT); the artwork is Twemoji, © Twitter
Inc. and contributors, CC-BY 4.0.

### Files written by the container are root-owned

The dev container runs as root, so `rails generate` produces root-owned files on
the host. Fix with:

```bash
docker compose exec --user root web chown -R 1000:1000 /app/<path>
```

## Conventions

[CLAUDE.md](../CLAUDE.md) is the authority. In brief:

- **Services** in `app/services/`, subclassing `ApplicationService`, one public
  `call`, returning `Success`/`Failure`. Callers pattern match.
- **Contracts** in `app/contracts/` validate anything crossing a boundary.
  `IngestEventContract` is the important one: it bounds every field of genuinely
  untrusted input.
- **Value objects** in `app/values/` as `Dry::Struct`. No untyped hashes across
  layers, no `OpenStruct`.
- **Infrastructure collaborators** in `app/lib/` — things that are neither models
  nor services (`Ingest::SaltStore`, `Analytics::Scope`).
- **Models stay thin.** Associations, scopes, validations, trivial helpers.
- **Jobs are thin wrappers** that call a service.
- **Pundit always.** Policies receive an `AuthorizationContext` (user *and*
  account), and `ApplicationPolicy::Scope#resolve` returns `none` so a forgotten
  override shows an empty page rather than every tenant's data.
- **One form pattern.** `TastaturFormBuilder` is the default builder, including
  for Devise's views. Use `f.field`, `f.error_summary`, `f.actions`; do not
  hand-roll inputs.

## Where to add things

| Adding | Goes in |
|---|---|
| A new breakdown dimension | `Analytics::Filters::DIMENSIONS` and `Analytics::Dashboard::PANELS` |
| A new event field | the migration, `Ingest::WriteBuffer::COLUMNS`, `Ingest::RecordEvent#row`, and `lib/tracker/t.js` `payload()` |
| A new referrer source | `config/referrer_sources.yml` |
| A scheduled job | `config/schedule.yml` plus a thin job in `app/jobs/` |
| A new report | `app/services/analytics/`, reading through `Analytics::Scope` |

Adding an event field touches four places on purpose: the write buffer's column
list is asserted against the table by spec, so a mismatch fails a test rather
than production.

## Testing notes

- `spec/support/event_helpers.rb` gives `create_event(site, path:, visitor:, at:)`
  for backdated events, which the ingest path cannot produce since it always
  stamps the current time.
- Factories use traits over separate factories: `create(:site, :no_suppression)`,
  `create(:user, :unconfirmed)`.
- The suite runs in about a second. Keep it that way; it is checked on every
  change and a slow suite stops being run.

The highest-value specs, and why they exist:

| Spec | Guards |
|---|---|
| `spec/policies/site_policy_spec.rb` | cross-tenant isolation, including the crafted-`?account=` case |
| `spec/requests/api/events_spec.rb` | bots, DNT/GPC, prefetch, unknown tokens, and that no column resembles an IP or user-agent |
| `spec/lib/ingest/identifier_spec.rb` | the salt rolling over at the site's local midnight, keeping sessions intact while making yesterday unlinkable; IPv6 /64 |
| `spec/lib/ingest/path_scrubber_spec.rb` | personal data in customer URLs |
| `spec/services/analytics/breakdown_spec.rb` | k-anonymity, including complementary suppression |
| `spec/services/analytics/funnel_report_spec.rb` | step ordering when a visitor backtracks |
