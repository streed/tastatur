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
| `within_5_minutes` | Erasure reconciliation, usage reconciliation | A written privacy or plan claim starts slipping |
| `within_1_hour` | Nightly bulk work: retention, subscription reconciliation | Nothing, which is the point |

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

**A `button_to` must never be rendered inside a form,** and `f.actions` takes
`destroy_to:` — a URL — rather than a rendered button so that it cannot be. This
is not tidiness. `button_to` emits a `<form>`, so passing one in nested a form
inside a form; that is invalid HTML and the parser **discards the inner start
tag**, which leaves the delete button owned by the surrounding edit form and its
`data-turbo-confirm` attached to an element that no longer exists. Every delete
button on every edit screen therefore ran `update`: measured on the wire, Turbo
sent `_method=patch`, the record was SAVED, and the redirect landed back on it
looking like nothing had happened. Nothing raises, nothing logs, and no request
spec can catch it, because a request spec issues the clean DELETE that no
browser was ever going to send — `spec/requests/destructive_buttons_spec.rb`
scans the delivered markup instead. The builder emits the delete form into
`content_for(:detached_forms)`, which the layout yields outside every other
form, and associates the button with it by the HTML `form` attribute. The one
place `destroy_to:` still may not be used is a form rendered into a turbo frame:
Turbo extracts the frame and drops the rest, taking the detached form with it.

**`as: :combobox` is a text field that can also be picked from,** and it is used
by exactly one thing: the match value of a goal or a funnel step, which is a
string compared against a column. A typo there saves cleanly and then reports 0%
forever, which is indistinguishable from a page nobody converts on. Two halves
that must both stay as they are:

- **It stays free text.** A `<select>` would refuse a goal for a page that has
  not shipped yet, and refuse `/blog/**` outright — a wildcard is a pattern, so
  it will never appear in a list of things that happened.
- **The options it offers are a breakdown, so §13's threshold applies.**
  `Analytics::KnownValues` goes through `Analytics::Breakdown` for exactly that
  reason. Replacing it with a cheaper `SELECT DISTINCT path` would publish, in a
  form, the rows the Top pages panel withholds. The visible consequence is that a
  quiet site's picker is empty; the forms say so, in the same voice
  `spec/requests/breakdown_suppression_spec.rb` pins for the dashboard, rather
  than looking broken.

The picker needs the `kind` control and the field inside one
`data-controller="value-picker"` element, and one payload per page rather than
one per field — see `OffersKnownValues`, which is a `helper_method` and not a
`before_action` so a save that redirects never pays for the scan.

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
- **`robots.txt` does not disallow `/share/`,** and adding that line is the way
  to publish an unlisted dashboard rather than hide one. A crawler refused the
  page never loads the `noindex` meta tag it carries, so a slug that leaked
  through a referrer stays indexed — and the slug is the secret. Left crawlable,
  the tag is obeyed and the URL is dropped outright.
  `app/views/crawlers/robots.text.erb`
- **The sitemap lists literal route helpers** instead of walking the routing
  table for public GETs. The derived version is shorter and publishes
  `/share/:slug`, which is unauthenticated by design. Adding a page to
  `Seo::BuildSitemap` is meant to be a deliberate edit.
- **Every button that hands off to Stripe carries `data: { turbo: false }`,** and
  removing it breaks paying for the product. Turbo submits the form with `fetch`
  and then follows our 302 with `fetch` too, so the request that lands on
  `checkout.stripe.com` is cross-origin and Stripe's CORS policy refuses the
  preflight. The customer gets a console error and a button that does nothing;
  the server sees an ordinary POST and answers a perfectly good redirect, so
  there is nothing to log, alert on, or detect from Ruby. `allow_other_host:
  true` in `BillingController` is only the other half. `spec/requests/billing_spec.rb`
  pins the attribute onto the rendered forms.
- **`robots.txt` and `sitemap.xml` are served by the application, and
  `public/robots.txt` must stay deleted.** `ActionDispatch::Static` runs before
  the router, so a file there shadows the route silently while production stamps
  it with a one-year cache header — the `/t.js` bug again. `Sitemap:` also has
  no relative form, so a static file would advertise our host on every
  self-hosted install. `CrawlersController`

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

### 14. Plans and billing

Two plans on the hosted service — Free (500,000 events/month, 1 site) and Pro
($30/month, 10,000,000 events, 20 sites) — plus `self_hosted`, which is a deployment
mode rather than an offer. `Billing::Plan` in `app/values/billing/plan.rb` is the
source of truth if these numbers ever look wrong again. Teammates are unlimited on every plan. Full reasoning in
`docs/architecture/billing.md`; the rules an agent must not break:

- **`Billing::Plan` is the catalogue.** Never read an allowance off the `plan`
  string, and never add a limit to a plan without a migration: the key set is pinned
  by `Account::PLANS`, by `Billing::Plan::KEYS`, and by the `accounts_plan_check`
  CHECK constraint, and `spec/models/account_spec.rb` compares all three.
- **`Account#event_limit` and `Account#site_limit` are the only accessors.** They
  return `Billing::Plan::UNLIMITED` (Float::INFINITY) when there is no cap, so no
  caller needs a nil branch. The `event_limit_override` / `site_limit_override`
  columns are a support lever, are usually NULL, and are ignored entirely when
  `SELF_HOSTED=1`.
- **The quota gate belongs exactly where it is** — in `Ingest::RecordEvent`, after
  the bot check and the hostname policy, before the identifier. Moving it earlier
  charges customers for traffic that is never stored; moving it later means counting
  something already written.
- **The meter counts events RECEIVED, including refused ones.** That is what makes
  one counter enough (`refused = used - limit`). `Billing::UsageMeter#repair` only
  ever raises a counter; lowering it hands back consumed allowance every hour,
  forever.
- **Any new path that bulk-INSERTS or backfills historical events must call
  `Analytics::ReconcileAggregates`**, for the same reason section 8 requires it for
  bulk deletes: the `events_by_hour` refresh policy looks back three days, so an
  older invalidation is never processed and the metered total is permanently wrong.
- **Webhooks stay idempotent through `ProcessedWebhookEvent`.** The receipt means
  "applied", not "seen", and must be released when the work fails — otherwise
  Stripe's retry is discarded as a duplicate and the change is lost silently.
- **Never write `subscription.current_period_end`.** On the pinned Stripe API
  version that reader does not exist and raises `NoMethodError`; the field lives on
  subscription items. Read with `[]` and take the max across items.
- **Billing is owner-only** (`AccountPolicy#manage_billing?`), one rung tighter than
  everything else there, because these buttons commit the account to a recurring
  charge.
- **`Tastatur.billing_enabled?` is the only gate.** Never write
  `unless Tastatur.self_hosted?` to guard a billing feature: billing is off when
  self-hosted OR when the Stripe variables are unset, and enforcing a plan limit on an
  instance that cannot sell an upgrade is a paywall with no cashier. Routes exist in
  all deployments so `billing_path` cannot raise inside a view whose guard someone
  forgot, and the controllers refuse. The one exception is the webhook endpoint's
  missing-signing-secret branch, which answers 503 before that gate so the delivery is
  retried rather than discarded.

### 15. Two-factor authentication, and why sign-in is two controllers

Optional, per user, by emailed six-digit code. `TwoFactor::IssueChallenge` owns the
code's length, lifetime, attempt budget and resend interval; nothing else may decide
any of those. The rules an agent must not break:

- **A correct password must not produce a session of any kind.** This is the whole
  design and the one thing that looks over-engineered until you know why. The obvious
  implementation — let Warden sign the user in, then block every request with a
  `before_action` until the code is entered — is wrong *here*, because `/sidekiq` is
  mounted behind `authenticate :user, ->(u) { u.admin? }` inside `config/routes.rb`.
  That is a Warden check no ApplicationController callback can reach, so a "signed in
  but gated" session would walk a stolen admin password into the job console. So
  `Users::SessionsController` tears the session down and leaves only
  `TwoFactor::PendingSignIn`, which authorizes nothing.
- **The pending marker carries `authenticatable_salt`**, compared on the way out for
  the same reason Devise carries it in a real session: a password reset performed
  *because* the password was stolen must invalidate a sign-in already in flight.
- **Devise's trackable is suppressed on the password request and re-run explicitly**
  at the point sign-in actually completes (`devise.skip_trackable`). Otherwise a
  correct password followed by an abandoned challenge is recorded as a sign-in — in
  the very field a customer reads when working out whether they have been broken
  into. The same request's `after_authentication` hook records the "Signed In" funnel
  step and reads `sign_in_count` *before* trackable increments it, so if you move
  either one, move both and re-read `spec/requests/auth_funnel_spec.rb`.
- **A trusted device is a receipt, not a bypass.** `TwoFactor::TrustDevice` is only
  ever called after a challenge has been answered. The row holds a SHA-256 digest —
  deliberately not bcrypt, because the token is 32 random bytes with no keyspace to
  grind and the digest is a lookup key. Check `device.user_id` against the person
  signing in; a cookie is not a bearer of somebody else's trust.
- **Switching two-factor off destroys every trusted device** (`TwoFactor::Disable`),
  or they come back to life when it is switched on again months later.
- **No user-agent, IP or location on the device list.** Every comparable product puts
  them there and they would genuinely help; §13 is why we do not, and
  `spec/privacy_invariants_spec.rb` fails the migration that adds one.
- **An instance administrator can turn it OFF and must never be able to turn it ON.**
  The off switch is the remedy for a mailbox that stopped working; an on switch would
  let an operator aim a customer's codes at an address they control. There is no
  route, no policy predicate and no controller action for the second.
- **The code email contains nothing to click.** An email that trains people to follow
  a link to a sign-in page trains them to follow somebody else's, and a one-time code
  is what a phishing page is for. A spec pins the set of links to the two the shared
  layout gives every email.

### 16. A confirmed email address is required to create a site

`SitePolicy#create?` requires `user.confirmed?` as well as the role. Today that is
unreachable through the sign-in form — `allow_unconfirmed_access_for` is `0.days`, so
an unconfirmed user cannot hold a session at all — and that is precisely why it is
written down rather than left implicit. Relaxing that setting so new users can look
around before confirming is an ordinary thing to want, and it would otherwise hand
site creation to anybody who can type an address they do not own. A site mints a
public token and starts accepting traffic from somebody else's website; that is an
obligation, and obligations need a proven address.

Reading and deleting are deliberately NOT gated. Confirmation is a precondition for
taking something on, not for looking at what you already have, and least of all for
getting out.

`SitesController` explains the refusal before the policy delivers it, because "You do
not have access to that" reads like a permissions problem to ask an admin about. Note
also that `sites#index` only redirects an empty account to the form when the viewer
could actually use it: without that guard the form refuses, `deny_access` redirects
back via the referer, and the two bounce forever.

### 17. What a crawler and an answer engine are told

Four surfaces publish this instance to machines: `robots.txt` and `sitemap.xml`
(§12), `llms.txt`, and the metadata block in the application layout. The rules:

- **The metadata block is opt-in, page by page.** `SeoHelper#seo` sets the title,
  description, canonical, Open Graph and Twitter tags and the JSON-LD; a page that
  does not call it renders exactly the `<title>` it always did. This is the same
  decision `Seo::BuildSitemap` makes and it is not tidiness. The application layout
  is shared with every authenticated screen, so a block rendered unconditionally
  would put a customer's own domain into `og:title` on `/sites/:token` and hand it
  to any scraper that followed a pasted link — the thing §10 exists to prevent. It
  also keeps the canonical tag honest: dropping the query string to build one is
  right for `/docs` and flatly wrong for a filtered dashboard, where `?path=/x` is
  a different report. `spec/requests/page_metadata_spec.rb` asserts the block is
  absent on an authenticated page.
- **`seo` replaces `content_for :title`, it does not accompany it.** `content_for`
  appends, so two callers produce "Pricing · Tastatur · Tastatur".
- **One sentence describes the product, and it lives in `Tastatur::DESCRIPTION`.**
  Five things quote it and four of them are invisible in a browser — the meta
  description, `og:description`, and the `description` of both the `WebSite` and
  `SoftwareApplication` nodes — so a drifting copy is not something anyone would
  notice by looking at the site.
- **The author and the operator are different JSON-LD nodes.** Reedster LLC wrote
  every copy, so it is `author` on every instance. Who *operates* the instance is a
  different question with a different answer on a self-hosted install, so the
  `Organization` node appears only where `Tastatur.legal_configured?`. Publishing
  ours as the operator of a stranger's install is the `Sitemap:` bug in another
  costume. That node carries name and URL only — the operator's contact address is
  already on `/privacy-policy` in prose, and restating it in a machine-readable
  block served to every scraper is a harvesting convenience, not a disclosure.
- **Never interpolate a plan limit into JSON-LD without the `UNLIMITED` guard.**
  `Billing::Plan::UNLIMITED` is `Float::INFINITY`, which is correct everywhere else
  and is not representable in JSON — `JSON.generate` raises on it. Only `FREE` and
  `PRO` are in `OFFERED` today, so the failure is one edit away and would surface
  as a 500 on the marketing page, three files from the cause.
- **The `.md` renderings are `rel="alternate"`, never sitemap entries.** Two copies
  of one document are not two pages; `alternate` points a machine reader at the
  markdown while telling a search engine which copy is canonical.
- **`Seo::Faq` is a code catalogue, like `Billing::Plan`.** Three things render it —
  `/faq`, `/faq.md`, and the `FAQPage` JSON-LD — and a `FAQPage` whose structured
  answers differ from its visible ones is treated as cloaking. Answers are plain-text
  paragraphs with links in a separate typed field, because markup that suits one of
  those three renderings corrupts the other two.
- **Every FAQ answer is bound by `docs/privacy/claims.md`,** and this is the most
  likely place in the codebase for a banned claim to reappear, because a FAQ is
  written in the voice of the question and the question is usually the banned claim
  ("Is Tastatur GDPR compliant?"). The ban therefore applies to **answers, not
  questions** — a heading quoting a reader asserts nothing. `spec/values/seo/faq_spec.rb`
  enforces both halves.
- **Markdown templates are whitespace-sensitive and ERB eats whitespace.** Rails
  trims any line holding only a scriptlet tag, newline included. Paragraphs emitted
  one per line through a loop arrive with nothing between them and render as one
  run-on paragraph — every word present, all structure gone. Join on a double
  newline instead. And remember an ERB comment ends at the first closing delimiter
  inside it, so a comment showing an example tag prints its own remainder into the
  document (the trap already documented in `crawlers/sitemap.xml.erb`).

### 18. Revenue attribution, and the one place identifiable data lives

The revenue layer answers "which channel produced paying customers". It is the
only part of this codebase that stores data about identifiable people, it is
confined to five tables, and full reasoning is in `docs/architecture/revenue.md`.
The rules an agent must not break:

- **The two pipelines never join on a visitor.** There is no column linking a
  `Customer` to a `visitor_hash` and there must not be. `customers` is written only
  by `/api/v1/identify` and Stripe Connect webhooks — server-to-server,
  authenticated, carrying data the customer's own app already holds under its own
  basis. Adding a link would make the anonymous side retroactively identifiable and
  falsify the §13 claim that visitor identifiers stop working after 24 hours. The
  two halves meet only at `attribution_rollups`, on channel strings.
- **`Revenue::Channel` is the single vocabulary,** and it exists because the report
  is a join between a server-classified source (`Ingest::Referrer`) and one that
  arrived from a browser. Two spellings of one channel produce two rows — all the
  visitors on one, all the money on the other, nothing raised, and 0% conversion
  shown for the channel that works. Sources are classified on WRITE; sentinels
  (`Direct`, `(none)`, `(pre-install)`) are applied on READ only. A stored sentinel
  is a bug: attribution is write-once, so it locks the column against the real
  value forever.
- **Attribution is first-touch and write-once**, enforced in one place
  (`Revenue::IdentifyCustomer`). Apps call identify on every sign-in, so
  last-write-wins re-attributes January's Reddit customer to March's brand-name
  search and decays every paid channel to zero on its own. Only two things may
  overwrite: `first_seen_at` moving EARLIER, and `(pre-install)` being replaced
  once by a real value.
- **`revenue_events.kind` holds two families.** `new/expansion/contraction/churn/
  reactivation` carry an MRR delta; `payment/one_time/refund/dispute` carry cash.
  Never sum across them — an annual plan writes both a 4,000 `new` and a 48,000
  `payment`, and adding them yields a number that does not exist. Amounts are
  signed.
- **`attribution_rollups.lifetime_revenue_cents` is a snapshot, never summed across
  days.** It appears in full on every day's row, so a 30-day sum multiplies the
  business by thirty and looks plausible. Same trap as §8's distinct counts.
- **Stripe Connect is a SEPARATE integration from `Billing::`** — their money
  versus ours. Its own endpoint, its own signing secret, and a **Stripe App**
  (`stripe-app/stripe-app.json`) whose manifest holds an all-`_read` permission
  list — that list, fixed by Stripe's app review and shown to the customer at
  install, is where read-only-ness lives now that the legacy Extension
  registration (and its `read_only` scope) no longer exists. Customers authorize
  via the app's OAuth install link; the code is exchanged by `Revenue::AppOAuth`.
  **No access token is stored**: the platform key plus `Stripe-Account` reaches the
  same data, so there is no third-party credential on disk. On the webhook, the
  missing-secret 503 must be checked BEFORE `Tastatur.revenue_enabled?`, or that
  gate — which requires the secret — makes the 503 unreachable and Stripe discards
  the delivery against a 404.
- **`Tastatur.revenue_enabled?` is the only gate, and is NOT gated on billing.**
  Billing is whether we can charge; this is whether a customer can connect their
  own processor. Refusing it on a self-hosted install would remove the point of the
  product from the deployment most likely to be evaluating it.
- **Revenue never appears on a public shared dashboard.** Publishing MRR to an
  unguessable-but-public URL is not something anybody should be one checkbox away
  from.
- **API keys are not the site token.** The site token is public by construction
  (§12) and everything it authorizes is harmless to forge. An API key attaches a
  NAME to a person, so it is bcrypt-digested, prefix-indexed (one comparison per
  request, or the endpoint is a bcrypt DoS), shown once, and revoked rather than
  deleted.

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
