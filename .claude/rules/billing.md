---
paths:
  - "app/services/billing/**/*.rb"
  - "app/lib/billing/**/*.rb"
  - "app/values/billing/**/*.rb"
  - "app/controllers/billing_controller.rb"
  - "app/controllers/billing/**/*.rb"
  - "app/views/billing/**/*.erb"
  - "app/models/account.rb"
  - "app/models/processed_webhook_event.rb"
  - "app/policies/account_policy.rb"
  - "spec/requests/billing*_spec.rb"
  - "spec/models/account_spec.rb"
  - "spec/lib/billing/**/*.rb"
  - "docs/architecture/billing.md"
---

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

### 12. Things that look like bugs but are deliberate (Stripe hand-off buttons)

Before "fixing" any of these, read the linked document.

- **Every button that hands off to Stripe carries `data: { turbo: false }`,** and
  removing it breaks paying for the product. Turbo submits the form with `fetch`
  and then follows our 302 with `fetch` too, so the request that lands on
  `checkout.stripe.com` is cross-origin and Stripe's CORS policy refuses the
  preflight. The customer gets a console error and a button that does nothing;
  the server sees an ordinary POST and answers a perfectly good redirect, so
  there is nothing to log, alert on, or detect from Ruby. `allow_other_host:
  true` in `BillingController` is only the other half. `spec/requests/billing_spec.rb`
  pins the attribute onto the rendered forms.
