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
  queue_as :default

  def perform(import_id)
    ImportCsv.call(import_id: import_id)
  end
end
```

### 6. Authorization is Pundit, always

Every controller action that touches a record runs through `authorize` or
`policy_scope`. No ad-hoc `if current_user.admin?` checks scattered in
controllers.

### 7. Idempotency for webhooks and external side-effects

Stripe webhooks and other external callbacks must be idempotent. Track
processed event IDs (e.g. a `processed_webhook_events` table) and short-circuit
duplicates.

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
