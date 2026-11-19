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
    Success(Stripe::Charge.create(customer: @user.stripe_customer_id,
                                  amount: @amount_cents, currency: "usd"))
  rescue Stripe::StripeError => e
    Failure(stripe_error: e.message)
  end
end
```

Callers pattern-match the result (`case Svc.call(...) in Success(x) ... in Failure(...)`).
Full example with caller: `.claude/rules/service-objects.md`.

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

**Queue names are SLAs.** Four tiers, in strict priority order: `within_5_seconds`,
`within_30_seconds`, `within_5_minutes`, `within_1_hour`. Every queue you enqueue
to must be listed in `config/sidekiq.yml`. Job queues: see `.claude/rules/job-queues.md`.

### 6. Authorization is Pundit, always

Every controller action that touches a record runs through `authorize` or
`policy_scope`. No ad-hoc `if current_user.admin?` checks scattered in
controllers.

### 7. Idempotency for webhooks and external side-effects

Stripe webhooks and other external callbacks must be idempotent. Track
processed event IDs (e.g. a `processed_webhook_events` table) and short-circuit
duplicates.

### 8. TimescaleDB rules

Analytics events live in a TimescaleDB hypertable. There is no schema file, on
purpose: migrations are the single source of truth (never add `db/schema.rb` or
`db/structure.sql`). Never bulk-delete or bulk-insert historical events without
calling `Analytics::ReconcileAggregates`; never `SUM()` distinct counts across
buckets. See `.claude/rules/timescaledb.md` before touching `db/` or analytics.

## Topic sections (rules files load automatically for matching paths)

Section numbers (§9, §12, ...) are referenced across the rules files.

- §9 Forms (`TastaturFormBuilder`; never hand-roll inputs; no `button_to` in a form): `.claude/rules/forms.md`
- §10 Public identifiers are never primary keys (`PubliclyIdentified`, `find_by_public_id!`): `.claude/rules/public-identifiers.md`
- §11 Authorization takes a context, not a user: `.claude/rules/authorization-context.md`
- §12 Things that look like bugs but are deliberate (read before "fixing"):
  `.claude/rules/deliberate-ingest.md`, `deliberate-analytics-reports.md`,
  `campaigns.md`, `public-pages.md`, and the Stripe hand-off buttons in `billing.md`
- §14 Plans and billing: `.claude/rules/billing.md`
- §15 Two-factor authentication: `.claude/rules/two-factor.md`
- §16 Confirmed email required to create a site: `.claude/rules/confirmed-email-site-creation.md`
- §17 What a crawler and an answer engine are told: `.claude/rules/seo-crawlers.md`
- §18 Revenue attribution: `.claude/rules/revenue.md`
- §19 The waitlist (never on a self-hosted install): `.claude/rules/waitlist.md`
- §20 One repository; what `SELF_HOSTED=1` takes away (`marketing_site?`, `waitlist_enabled?`):
  `.claude/rules/hosted-vs-self-hosted.md`
- Seeded development users: `.claude/rules/dev-seeds.md`; routes provided out of the box: `.claude/rules/routes.md`

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
  historical salt regenerable forever, so nothing is ever actually destroyed. Note
  that `Ingest::SaltStore` keying a salt by *date* is the opposite thing: the date
  names the Redis key, while the value under it is `SecureRandom` and is never
  recomputed.
- **Each site's salt rotates at midnight in that site's own timezone**, and there
  is no rotation job — the key carries the site-local date and the retired one dies
  on its TTL. Both halves are load-bearing. A day on the dashboard is a day in
  `site.timezone`, so the instance-wide 04:07 job this replaced rotated *inside*
  the reporting day for every site not set to UTC, splitting one visitor into two
  on the same report. And a cron entry that silently stops produces no error and no
  symptom while the product ceases to be anonymous. Do not reintroduce either.
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
