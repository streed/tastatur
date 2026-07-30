# Plans, limits and billing

How the hosted service decides what an account is allowed, how it counts what an
account has used, and how Stripe is wired to it.

**None of this exists on a self-hosted install.** With `SELF_HOSTED=1` there are no
plans, no limits, no upgrade interface and no Stripe: every question routes through
`Account#billable?` first. If you are reading this to run your own instance, the
short version is that you can stop here.

## The two plans

| | Free | Pro |
|---|---|---|
| Price | $0 | $40/month |
| Events a month | 100,000 | 10,000,000 |
| Sites | 1 | 20 |
| Teammates | Unlimited | Unlimited |

A third key, `self_hosted`, is not an offer — it is what every account looks like
in that deployment mode, with both limits set to `Billing::Plan::UNLIMITED`.

Teammates are unlimited on purpose. Per-seat pricing on an analytics tool means the
person who most needs to see the numbers is the person nobody wants to pay for, and
the shared login that follows is worse for everybody including us.
`Billing::Plan::MEMBER_LIMIT` exists so the account screen can state it rather than
leaving it to be inferred from the absence of a check, and
`spec/models/account_spec.rb` asserts it both as the constant and as behaviour.

### The catalogue is code

`app/values/billing/plan.rb` holds the whole catalogue as frozen `Dry::Struct`
instances. There is no `plans` table, and the account row stores only the plan
*key*.

A table would buy the ability to edit an allowance without a deploy, at the cost of
every environment being able to disagree about what "free" means — including the
test suite, which would then be asserting against whatever a fixture happened to
say rather than against the offer we actually make.

A plan key is written in three places: `Billing::Plan::KEYS`, `Account::PLANS`
(which is assigned from it), and the `accounts_plan_check` CHECK constraint. Nothing
else compares them, so `spec/models/account_spec.rb` does — including reading the
constraint back out of `pg_constraint`. The constraint is not belt-and-braces: a
webhook handler writing an unrecognised plan would otherwise leave a row that
`Billing::Plan.find!` raises on every time the billing screen is opened.

### Limits are never read off the plan string

`Account#event_limit` and `Account#site_limit` are the only accessors. They resolve,
in order:

1. `Billing::Plan::UNLIMITED` if the account is not billable (self-hosted).
2. The `event_limit_override` / `site_limit_override` column, if set.
3. The plan's allowance.

The overrides are a support lever — "give this customer 5 sites while we sort
something out" — and exist so nobody edits a plan constant to accommodate one
account. They are deliberately **ignored when there is no billing**, so a value left
in the column by an import cannot throttle an instance somebody is running on their
own hardware. `Billing::EventQuota` short-circuits on the same condition; the two
disagreeing would mean the model reporting a limit that enforcement never applied.

An override of `0` is meaningful and is honoured. It only works because `0` is
truthy in Ruby, so there is an example pinning it: the obvious tidy-up
(`event_limit_override.presence`) would silently turn "record nothing" into the
plan's full allowance.

## The month is the UTC calendar month

Not the subscription's billing period, and the reasons compound:

- The free plan has no billing period at all, so a period-aligned window would need
  a second implementation and the free one would be arbitrary anyway.
- A window taken from Stripe depends on a webhook having arrived. A missed webhook
  would leave a stale window, and the failure mode of a stale window is locking a
  customer out of collection.
- `events_by_hour` buckets are UTC-hour-aligned. A calendar month is too; an
  arbitrary subscription anniversary (14:37:22 on the 14th) is not, and filtering
  `bucket >= from` on a non-aligned boundary silently includes or excludes a whole
  hour at each end.
- It can only err in the customer's favour. Someone who subscribes on the 14th gets
  the rest of that month plus a fresh allowance on the 1st.

## Metering

### On the ingest path

`Billing::EventQuota.allow?` is called once per event, from
`Ingest::RecordEvent`, and its whole budget is **one Redis command and no SQL**.

It gets there two ways. The account's limit is cached **in the process** for 60
seconds (`Concurrent::Map`), because a `Rails.cache` read is itself a Redis round
trip on the hottest path in the application, for a value that changes about once a
year per account. And the count is a single `INCRBY`, whose return value is the
comparison — so there is no separate read.

The cost of the process-local cache is that a plan change takes up to a minute to
be noticed by an already-warm process. That is the same bargain
`Ingest::SiteResolver` strikes for site deletion, and it is why the billing screen
promises that upgrades apply *within a minute* rather than instantly.
`Billing::SyncSubscription` calls `EventQuota.forget` so the process that handled
the webhook stops enforcing the old plan at once.

**It fails open.** If Redis cannot answer, the event is recorded and the incident is
reported to Sentry. This is not a swallowed error: refusing a paying customer's
traffic because we cannot count it would turn a monitoring problem into permanent
data loss. The same Redis is needed by the write buffer two lines later, so a real
outage stops ingest anyway, through `Ingest::RecordEvent`'s own handling.

### Where the gate sits, and why it matters

In `Ingest::RecordEvent#call`, **after** the bot check, the URL parse and the
hostname policy, and **before** the identifier is computed.

Everything above that line is an event that was never going to be stored: a crawler,
an unparseable URL, a hostname that is not the customer's. Charging a customer's
allowance for traffic we throw away would be indefensible, and it would also make
the number on their billing screen disagree with the number on their dashboard.
Everything below the line does get stored, so it is the last honest place to count.
`spec/services/ingest/record_event_spec.rb` asserts each of those cases spends
nothing.

A refused event is recorded through `Ingest::RejectionCounter` under the reason
`plan_limit`, and surfaces on the site settings screen as "Over plan limit". The
HTTP response is still 202, like every other outcome on that endpoint — see
[ingest.md](ingest.md).

### What the counter means

**Events received, including the ones refused.** Not "events stored".

That is what makes one counter enough: the refused figure is
`max(0, used - limit)`, so nothing is tracked twice and there is no second counter
to drift from the first. It also lets the billing screen say "we received 118,402
events; your plan covers 100,000" instead of the uselessly self-fulfilling "you used
exactly your limit".

Keys are `tastatur:usage:{account_id}:{YYYYMM}` with a 62-day TTL, so the previous
month is still readable throughout the current one and the key space is bounded at
about two per account. The TTL is issued only when `INCRBY` returns the first
increment, so the steady-state cost really is one command.

### Reconciliation, hourly and upward only

`Billing::ReconcileUsage` (cron `13 * * * *`, queue `within_5_minutes`) recomputes
each active account's total from `events_by_hour` in **one grouped query for the
whole instance** and raises any counter that has fallen behind.

Redis is the right store for a per-event counter and the wrong store to trust: a
restart, an eviction or a deploy mid-increment loses counts, and every count lost is
allowance given away with nothing to show it happened.

`UsageMeter#repair` never *lowers* a counter. The counter counts events received and
the aggregate counts events stored, so the counter being higher is the truth rather
than drift. Lowering it would hand back allowance that was genuinely consumed —
and worse, would do so every hour: an account parked at its limit would be reset to
its limit and let another hour of events through, forever.

It uses `INCRBY` rather than `SET`, so an event arriving between reading the current
total and applying the correction is added on top instead of being overwritten.

`pageviews + custom_events` is the definition of "events recorded" because
`events_by_hour`'s two counters `FILTER` on `event_name = 'pageview'` and on its
negation, which is a complete partition — `event_name` is `NOT NULL`. There is an
example asserting the identity against raw rows, so a migration that ever made the
column nullable would fail a test rather than quietly under-report.

### The trap for anything that writes history

`events_by_hour`'s refresh policy only looks back three days, so an invalidation
older than that is **never processed**. A row inserted with an `occurred_at` behind
the materialization watermark is therefore invisible to the aggregate permanently —
which means invisible to metering.

**Any code path that bulk-inserts or backfills historical events must call
`Analytics::ReconcileAggregates` for the affected window**, exactly as
`Sites::Delete` and `Privacy::EnforceDataRetention` must for bulk *deletes* (see
CLAUDE.md section 8). `lib/tasks/demo_data.rake` does both: it refreshes all three
aggregates and then runs `Billing::ReconcileUsage` so the demo account's plan screen
is not reporting zero against months of stored traffic.

Note also that `events_by_hour` is retained for five years while raw `events` are
dropped after 790 days. Beyond about two years the aggregate is the only source of an
event count, so a metering path that fell back to `COUNT(*)` on `events` would
silently report zero for old periods.

### Warnings

`Billing::NotifyUsageThreshold` emails **owners and admins** at 80% and again once
the allowance is gone. Members and viewers are not told, because they cannot change
the plan and it would be noise they cannot act on.

Once per level per month, guarded by a Redis `SET NX` key containing the month. A
boolean column would need clearing on the first of the month by something, and that
something is another scheduled job that can fail silently; a key whose name contains
the month cannot fail to reset.

A quota nobody is warned about is indistinguishable from a bug. The visible symptom
of hitting the cap is "my numbers stopped moving", which is exactly what a broken
installation looks like — so the customer's first assumption is that we are broken,
and they are right to think so if we never said anything. The same reasoning is why
the installation screen stops polling and explains itself when the allowance is
gone, rather than waiting forever for something that cannot arrive.

## Stripe

### What lives where

One product with one recurring monthly price (`STRIPE_PRICE_PRO`). One Stripe
customer per account, created by `Billing::StartCheckout` before the session so the
portal is reachable immediately and an abandoned checkout still leaves something
behind.

Payment is **hosted Checkout**; card management, invoices, VAT ids, proration and
cancellation are the **billing portal**. Neither is rebuilt here. No card number
ever touches this application or its logs, which keeps the PCI obligation at SAQ-A,
and it means there is nothing for a Content Security Policy to allow — the only
thing this app does is issue a redirect.

The account reference travels twice: `client_reference_id` on the session, and
`subscription_data.metadata.account_public_id` so that later
`customer.subscription.*` events — which carry no session — are still attributable.
It is the **public** id, never the primary key (CLAUDE.md rule 10): this value is
visible in the Stripe dashboard, which is exactly the sort of place a sequential id
leaks how many customers exist.

### Webhooks

Endpoint: `POST /billing/stripe/webhook`, subscribed to the events in
`Billing::ApplyStripeEvent::HANDLED`:

```
checkout.session.completed
customer.subscription.created
customer.subscription.updated
customer.subscription.deleted
invoice.paid
invoice.payment_failed
```

The controller inherits `ActionController::API`, and that is a security decision
rather than a style one. Forgery protection would reject every webhook, which is
normally escaped with `skip_forgery_protection` — but the test environment disables
forgery protection globally, so a controller that forgot the skip would pass every
request spec and fail only in production. An API controller has nothing to forget.
The same inheritance keeps `authenticate_user!`, Pundit's `verify_authorized` and the
first-run redirect off this path.

It reads no client address; the signature is what authenticates a request, and an
address allowlist would be weaker and one more thing to keep current as Stripe's
ranges change.

It is exempt from Rack::Attack's per-client throttle. Stripe delivers every
customer's events from a small fixed set of its own addresses, so under a per-client
limit the whole instance shares one throttle key — and a 429 is a failed delivery.

### Every handler re-fetches

`Billing::SyncSubscription` never trusts the object in the payload. Stripe does not
guarantee delivery order: an `updated` from a cancellation and one from a plan
change can arrive either way round, and applying the older one last would leave the
account permanently wrong with nothing to correct it. Re-fetching costs one API call
on an endpoint that sees a handful of events per customer per month, and it makes
ordering irrelevant — whatever is at Stripe now is what gets written.

For invoice events the subscription id comes from the account's own record rather
than from the invoice, because the invoice's link to its subscription has moved
between API versions (it now lives under `parent.subscription_details`). The account
was found by customer id, so it is the same subscription either way.

### Idempotency

Stripe delivers at least once. `ProcessedWebhookEvent` is a receipt keyed by event
id with a unique index, and the index is the guarantee: an `exists?` check followed
by a create would let two concurrent deliveries both pass, which is exactly what
happens when a retry lands alongside the original.

**The receipt means the work was applied, not that the event was seen.** It is
released when the work fails — otherwise Stripe's retry, the only mechanism that
fixes a transient outage, is discarded as a duplicate and the subscription change is
lost permanently with nothing raised.

Receipts hold no payload. A Stripe event body carries the customer's email, address
and card details, none of which is needed to answer "have I already handled this?".
They are pruned after 30 days by `Billing::ReconcileSubscriptions`.

### What each response code means to Stripe

A non-2xx is a failed delivery: Stripe retries with backoff for three days and
disables an endpoint that keeps failing. So 2xx means "do not send this again".

| Situation | Status | Why |
|---|---|---|
| Applied | 200 | |
| Duplicate delivery | 200 | Already applied |
| No matching account | 200 | Retrying will never make the account exist |
| Event type not handled | 200 | Nothing to do |
| Bad or stale signature | 400 | Not from Stripe, or replayed |
| Body is not JSON | 400 | `construct_event` raises `JSON::ParserError`, not a `StripeError` |
| Envelope missing required fields | 400 | Contract refused it |
| Stripe unreachable while applying | 503 | A retry is exactly what is wanted |
| `STRIPE_WEBHOOK_SECRET` unset | 503 | Ours to fix; a retry afterwards succeeds |
| Self-hosted | 404 | The endpoint genuinely does not exist there |

### The API-version hazard

`stripe` 19.3.1 pins API version **2026-06-24.dahlia**, and on it
`Stripe::Subscription` has **no `current_period_end` reader at all** — the field
moved onto subscription items in the 2025-03-31 "basil" release, and the gem
generates its readers from the version it pins.

Calling `subscription.current_period_end` therefore raises `NoMethodError` rather
than returning `nil`, so a `subscription.current_period_end || item...` fallback
chain crashes instead of falling through. `Billing::SyncSubscription` reads both
positions with `[]` (nil-safe on a Stripe object) and takes the **max across
items**, so a subscription that ever gains a metered add-on still reports the end of
the period the customer paid through.

Two related traps in the same gem:

- The second positional argument of the resource-style `retrieve` is `opts`, not
  params, and any key it does not recognise becomes an HTTP header — so
  `Stripe::Subscription.retrieve(id, expand: [...])` fails inside `Net::HTTP` before
  a request is sent. The safe form folds the id into the params hash:
  `retrieve({ id: id, expand: [...] })`. Nothing here needs `expand`; a subscription
  already carries its items, and each item its full price.
- The API version is **not** pinned in `config/initializers/stripe.rb`. The gem
  already sends its own, so pinning a second version string would create two sources
  of truth that can silently disagree.

### Entitlement

`Billing::SyncSubscription::ENTITLING_STATUSES` is the single place that decides,
and it writes the answer to `plan`.

| Stripe status | Plan | Why |
|---|---|---|
| `active`, `trialing` | Pro | Paid up |
| `past_due` | Pro | Stripe retries for about two weeks. Cutting off measurement on the first failed charge destroys data the customer can never recover, usually over a card that has merely expired |
| `unpaid` | Free | Those retries are finished and failed |
| `canceled`, `incomplete`, `incomplete_expired`, `paused` | Free | Never paid, or no longer paying |

`Account::PAYMENT_PROBLEM_STATUSES` (`past_due`, `unpaid`) is a different set and
drives only the banner. Entitlement and "your card needs attention" are separate
questions.

### Downgrade

**Nothing is ever deleted.** An account that cancels Pro keeps all twenty sites and
they all keep collecting; it simply cannot add a twenty-first until it is back under
the limit. The site limit is validated `on: :create` only — an unscoped validation
would refuse every save on all twenty sites, so changing a timezone would fail with
a message about site limits and the only way out would be deleting nineteen sites.

The honest consequence: somebody can pay for one month, create twenty sites, cancel,
and keep them. That is bounded by the free plan's 100,000 events, which is the limit
that actually costs us anything, and it is a much better trade than deleting a
customer's measurement as a billing action.

## Scheduled jobs

| Job | Cron | Queue | What breaks if it stops |
|---|---|---|---|
| `ReconcileUsageJob` | `13 * * * *` | `within_5_minutes` | The counter enforcement reads drifts below reality, so published allowances quietly stop being the allowances applied. Warning emails also stop |
| `ReconcileSubscriptionsJob` | `41 4 * * *` | `within_1_hour` | A webhook Stripe gave up delivering is never noticed, so an account stays on a plan nobody is paying for — or an upgraded account stays capped. Webhook receipts also stop being pruned |

## Setting it up

1. In Stripe, create one product with a recurring monthly price matching
   `Billing::Plan::PRO`.
2. Set `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_PRICE_PRO`.
3. Add a webhook endpoint at `https://YOUR_HOST/billing/stripe/webhook` subscribed
   to the six events above, and set `STRIPE_WEBHOOK_SECRET` from it.
4. Enable the customer portal in the Stripe dashboard (it needs a configuration
   before `BillingPortal::Session.create` will succeed).
5. Run `bin/rails tastatur:billing:verify`.

`required_env.rb` logs an error at boot for any of these that is missing on a
non-self-hosted deployment, `STRIPE_WEBHOOK_SECRET` especially: without it the
endpoint refuses every delivery, so subscriptions are bought and never applied —
Stripe shows the charge, the customer stays on Free, and nothing raises.

### Verifying the price

```bash
bin/rails tastatur:billing:verify
```

Checks that the Stripe price still costs what `/pricing` publishes, in the same
currency, recurring monthly, and active. The failure it exists to catch is a price
edited in the dashboard with nothing in the application noticing: the pricing page
keeps saying $40, customers are charged something else, and the first report comes
from somebody reading their card statement.

It is a task rather than a boot check because `assets:precompile` boots the app in
production mode inside the Docker build, with no Stripe key and no network — a check
at boot would fail the image build.

### Testing locally

```bash
stripe listen --forward-to localhost:3000/billing/stripe/webhook
stripe trigger customer.subscription.updated
```

`stripe listen` prints its own signing secret; put that in `STRIPE_WEBHOOK_SECRET`
for development. Replaying the same event twice is a good check of the idempotency
path — the second delivery should answer 200 and change nothing.

The test suite never reaches Stripe: `spec/support/stripe.rb` points `Stripe.api_base`
at a closed local port and zeroes the retries, so any unstubbed call fails instantly
and names itself instead of hanging for eighty seconds and then failing for an
unrelated reason.
