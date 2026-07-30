# CLAUDE.md

Guidance for Claude / AI agents working in this Rails codebase. Read this
before writing code.

## Stack

- Ruby on Rails 8+, PostgreSQL, Redis
- **Sidekiq** for background jobs (NOT Solid Queue — it has been removed)
- **Devise** for authentication (confirmable, lockable, trackable enabled)
- **Pundit** for authorization
- **Stripe** for payments
- **dry-rb** (dry-monads, dry-validation, dry-struct, dry-types) for service
  objects, contracts, and value objects
- **RSpec** + FactoryBot + Faker for tests
- **Lograge** + **Sentry** for observability
- **Rack::Attack** + **Rack::Cors** for API hardening
- **Email**: Resend in production, letter_opener in development, `:test` in test
  - Default `from:` set in `ApplicationMailer` via `MAIL_FROM` env var
  - Mailers extend `ApplicationMailer` and use Rails' standard ActionMailer API.
    Do not call `Resend.send_email` directly — go through ActionMailer so
    previews, tests, and the `:test` delivery method work uniformly.

## Architectural rules

### 1. Service objects, not fat models or fat controllers

Any non-trivial business operation lives in `app/services/` as a subclass of
`ApplicationService`. A service:

- Has a single public entrypoint: `call` (invoke via `MyService.call(...)`)
- Returns a `Dry::Monads::Result` — `Success(value)` or `Failure(reason)`
- Never raises for expected failure modes; reserve exceptions for bugs
- Is named for what it does: `CreateSubscription`, `ImportCsv`, `ChargeCustomer`

```ruby
class ChargeCustomer < ApplicationService
  def initialize(user:, amount_cents:)
    @user = user
    @amount_cents = amount_cents
  end

  def call
    return Failure(:no_payment_method) unless @user.stripe_customer_id

    charge = Stripe::Charge.create(
      customer: @user.stripe_customer_id,
      amount:   @amount_cents,
      currency: "usd"
    )
    Success(charge)
  rescue Stripe::StripeError => e
    Failure(stripe_error: e.message)
  end
end
```

Callers pattern-match the result:

```ruby
case ChargeCustomer.call(user:, amount_cents: 1500)
in Success(charge) then redirect_to charge_path(charge.id)
in Failure(:no_payment_method) then redirect_to billing_path
in Failure(stripe_error:) then flash[:error] = stripe_error
end
```

### 2. Validate input at the boundary with dry-validation

Controller params and external payloads (Stripe webhooks, API requests) get
validated by a `Dry::Validation::Contract` BEFORE they reach a service. Do not
rely on Rails strong params alone for non-trivial shapes.

```ruby
class CreateOrderContract < Dry::Validation::Contract
  params do
    required(:user_id).filled(:integer)
    required(:items).array(:hash) do
      required(:sku).filled(:string)
      required(:qty).filled(:integer, gt?: 0)
    end
  end
end
```

### 3. Value objects are dry-struct, not Hash or OpenStruct

Anything passed between layers (parser results, API responses, computed
summaries) is a `Dry::Struct` with explicit, typed attributes. No untyped
hashes flowing through service boundaries.

### 4. Models stay thin

Models hold associations, scopes, validations, and trivial query helpers.
They DO NOT hold multi-step business logic, third-party API calls, or
side-effecting orchestration. Push that into a service.

### 5. Background jobs are thin wrappers

A Sidekiq job's only responsibility is to deserialize arguments and call a
service. Business logic belongs in the service so it stays testable
synchronously.

```ruby
class ImportCsvJob < ApplicationJob
  # Queues are named for the latency they promise, not for the subject matter.
  # Pick the tier by asking what breaks if this backs up.
  queue_as :within_5_minutes

  def perform(import_id)
    ImportCsv.call(import_id: import_id)
  end
end
```

**Queue names are SLAs.** The four tiers, in strict priority order:

| Queue | For | What a backlog means |
|---|---|---|
| `within_5_seconds` | Transactional mail | Somebody is on the signup screen waiting |
| `within_30_seconds` | The measurement pipeline | Dashboards silently stop advancing |
| `within_5_minutes` | Salt rotation, erasure reconciliation | A written privacy claim starts slipping |
| `within_1_hour` | Nightly bulk work | Nothing, which is the point |

Every queue you enqueue to must be listed in `config/sidekiq.yml`, which is what
a worker actually serves. This is not bookkeeping. `FlushEventBufferJob` once
declared `queue_as :ingest` with no `sidekiq.yml` present, and a bare
`bundle exec sidekiq` serves only `default` — so the job that moves buffered
events into PostgreSQL was enqueued every minute by cron and executed never.
Redis grew, dashboards froze, ingest kept answering 202, and nothing raised.

`spec/jobs/queue_names_spec.rb` compares job classes, the cron schedule, and the
framework defaults against that file, so the mismatch now fails a test instead of
silently losing data. Note that the test adapter runs jobs inline and never
consults a queue name, which is why no other spec could have caught it.

### 6. Authorization is Pundit, always

Every controller action that touches a record runs through `authorize` or
`policy_scope`. No ad-hoc `if current_user.admin?` checks scattered in
controllers.

### 7. Idempotency for webhooks and external side-effects

Stripe webhooks and other external callbacks must be idempotent. Track
processed event IDs (e.g. a `processed_webhook_events` table) and short-circuit
duplicates.

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

### 9. One form pattern, and the builder enforces it

`TastaturFormBuilder` is the application's default form builder, which means it
applies to Devise's views too. Every field is a micro-label, a control and an
optional hint, in that order, with the same spacing:

```erb
<%= form_with model: @site, class: "card card-body space-y-6" do |f| %>
  <%= f.error_summary %>
  <%= f.field :domain, "Domain", hint: "Just the hostname." %>
  <%= f.field :timezone, "Timezone", as: :select, choices: zones %>
  <%= f.actions "Save", cancel_to: sites_path %>
<% end %>
```

Do not hand-roll `<input>` or `<label>` markup. A form whose object is not an
ActiveRecord model still gets the builder — give it an `ActiveModel` form object
(see `MemberInvitation`) rather than dropping to raw HTML, which is how a
codebase ends up with four subtly different forms.

### 10. Public identifiers are never primary keys

Nothing routable is addressed by its `id`. Sequential integers in URLs tell
anyone who sees one roughly how many sites and goals exist across the whole
instance, and they make enumeration the obvious first thing to try.

Primary keys stay `bigint` — they index better and keep foreign keys cheap, and
none of that is visible outside the database. Only the routed identifier changes:

| Model | Routed by | Why |
|---|---|---|
| `Site` | `public_token` (16-char Crockford base32) | pasted into a script tag, so short and readable matters |
| `SharedLink` (public URL) | `slug` (24 chars, ~143 bits) | the only thing protecting an unlisted dashboard |
| Everything else | `public_id` (UUID v4) | |

Include `PubliclyIdentified` and declare it:

```ruby
class Goal < ApplicationRecord
  include PubliclyIdentified
  public_identifier                    # defaults to :public_id
end

class Site < ApplicationRecord
  include PubliclyIdentified
  public_identifier :public_token
end
```

**The footgun this concern exists to prevent.** `resources :sites, param:
:public_token` renames the route *segment*, but `site_path(site)` still calls
`to_param`, which defaults to `id`. Every generated link then points at
`/sites/2` while the route expects a token, so **every link 404s** — with no
error at boot and nothing wrong in the routes file. Renaming a route param
without overriding `to_param` is a silent, total break, and a spec that builds
paths by hand will not catch it. `spec/requests/public_identifiers_spec.rb`
asserts on the URLs the app *generates* and then follows them, which does.

Look records up with `find_by_public_id!`, never `find`.

### 11. Authorization takes a context, not a user

Policies receive an `AuthorizationContext` carrying both the user **and** the
account they are currently acting as. A user can belong to several accounts with
different roles; a policy handed only a `User` would have to re-derive the
account, and that is the step that gets forgotten in one policy out of twelve and
becomes a cross-tenant leak.

`ApplicationPolicy::Scope#resolve` returns `scope.none`, not `scope.all`. A
subclass that forgets to override it shows an empty page — a bug someone reports
— rather than every tenant's data.

Callbacks use `if:`/`unless:` predicates rather than `only: :index`. Since Rails
7.1, naming an action in `only:` that the controller does not define raises, so
`only: :index` breaks every controller without an index action.

### 12. Things that look like bugs but are deliberate

Before "fixing" any of these, read the linked document.

- **The ingest endpoint always returns 202**, even for an unknown site token or a
  malformed payload. A distinguishable response lets anyone enumerate valid
  tokens, and an error in a stranger's console on a customer's site is noise they
  cannot act on. `docs/architecture/ingest.md`
- **CORS allows any origin** on ingest. The site token is public by construction,
  so an allowlist protects nothing and breaks staging domains, proxies and
  iframes.
- **Rate-limit keys are hashed, not raw IPs.** A stock Rack::Attack config writes
  every visitor's IP into Redis, which is the thing this codebase avoids
  everywhere else.
- **Breakdowns scan raw events** instead of an aggregate. The aggregates carry no
  dimension columns on purpose; a wide one would be ~1 row per event.
  `docs/architecture/aggregates.md`
- **Public shared dashboards ignore filter parameters.** Filtering someone else's
  audience is a re-identification tool.
- **`Ingest::PathScrubber` keeps four-digit years** but collapses other long
  numbers. Date-organised URLs are common and collapsing the year destroys the
  top-pages report.
- **The write buffer builds its INSERT by hand.** It is the ingest hot path;
  `insert_all` per event costs an order of magnitude. Values are all passed
  through `connection.quote` and the column list is a frozen constant. The
  Brakeman warning is a reviewed false positive recorded in
  `config/brakeman.ignore`.

### 13. The privacy invariants

These are not preferences. Each one is load-bearing for a claim made on `/privacy`,
and each has a spec.

- **The IP address and user-agent are never persisted.** They exist as local
  variables inside `Ingest::Identifier#call` and nowhere else. A spec asserts the
  resulting value object exposes exactly three fields and contains neither input.
- **The salt lives only in the non-persistent Redis** (`REDIS_PRIVACY_URL`). A
  salt written to an AOF or RDB file is not destroyed; it sits in a backup next to
  the events it would de-anonymise.
- **Never derive salts from a master key.** `HKDF(master, date)` makes every
  historical salt regenerable forever, so nothing is ever actually destroyed.
- **Personal data is stripped from paths, not just query strings.** Customer sites
  put emails and tokens in path segments constantly.
- **k-anonymity includes complementary suppression.** Hiding a single row protects
  nothing when its value is `total − Σvisible`.
- **Do Not Track and GPC are honoured**, in the tracker and again server-side.

## Testing rules

- RSpec, not Minitest
- One spec file per service; cover Success and Failure branches explicitly
- Use FactoryBot factories, not fixtures
- Stub external HTTP (Stripe, etc.) — never hit the network in tests
- Integration specs go in `spec/requests/`, not `spec/features/`

## Things NOT to do

- Do not reintroduce Solid Queue / Solid Cache / Solid Cable — Sidekiq + Redis
  is the chosen stack
- Do not add `rescue => e` blocks that swallow errors. If you can't handle it,
  let it raise to Sentry
- Do not put business logic in controllers, models, or jobs
- Do not return raw hashes from services — return monadic Results wrapping
  typed values
- Do not use `OpenStruct` — use `Dry::Struct`
- Do not skip validation contracts for "simple" endpoints; they grow
- Do not bypass Pundit authorization with `skip_authorization` unless the
  action is genuinely public, and document why

## Conventions

- Service files: `app/services/<verb>_<noun>.rb` defining `class VerbNoun`
- Contract files: `app/contracts/<name>_contract.rb`
- Value objects: `app/values/<name>.rb` (or colocated next to their service)
- Job files: `app/jobs/<name>_job.rb`, one job per file, thin wrapper only

## Running things

```bash
bin/dev-setup        # one-shot: bundle, db:prepare, db:seed
bin/dev              # web + css + worker (Procfile.dev)
bundle exec sidekiq  # background worker (standalone)
bin/rails db:migrate
bin/rails db:seed    # idempotent
bundle exec rspec
```

## Seeded users (development)

- `admin@example.com` / `password` — admin (can access `/sidekiq`)
- `user@example.com`  / `password` — regular user
- Plus 5 random Faker users in development

Seeds are idempotent — re-running `db:seed` is safe.

## Routes provided out of the box

- `/`            — public home page
- `/dashboard`   — authenticated landing page
- `/up`          — health check (DB + Redis ping), returns JSON
- `/sidekiq`     — Sidekiq web UI, gated on `current_user.admin?`
- Devise routes (`/users/sign_in`, `/users/sign_up`, etc.)
