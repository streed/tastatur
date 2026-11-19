---
paths:
  - "app/services/revenue/**/*.rb"
  - "app/lib/revenue/**/*.rb"
  - "app/values/revenue/**/*.rb"
  - "app/controllers/revenue/**/*.rb"
  - "app/controllers/api/**/*.rb"
  - "app/models/customer*.rb"
  - "app/models/revenue_event.rb"
  - "app/models/attribution_rollup.rb"
  - "app/models/api_key.rb"
  - "app/models/stripe_connection.rb"
  - "spec/services/revenue/**/*.rb"
  - "spec/lib/revenue/**/*.rb"
  - "spec/requests/revenue_screens_spec.rb"
  - "spec/requests/identify_spec.rb"
  - "spec/requests/connect_webhooks_spec.rb"
  - "docs/architecture/revenue.md"
---

### 18. Revenue attribution, and the one place identifiable data lives

The revenue layer answers "which channel produced paying customers". It is the
only place in THIS repository that stores data about identifiable people — the
only *pipeline* anywhere that does — confined to five tables, and full reasoning is
in `docs/architecture/revenue.md`. The hosted service has one more, the waitlist (§19), which joins to
nothing here.

**The feature is not shipped.** The docs section says so, and the in-app Revenue
card says so wherever `Tastatur.revenue_enabled?` is false and the instance is not
self-hosted. None of the code below was removed or gated further: it is dark
because the three Stripe Connect variables are unset, which is also what makes
launching it a deploy rather than a rewrite. A deployment that also serves a
marketing site repeats the same status on `/revenue`, `/revenue.md` and the
pricing page and offers the waitlist in place of a connect button — the card
renders the same form where `Tastatur.waitlist_enabled?`. On a self-hosted install
the card states the fact and stops, which is the honest version anyway: there is no
list for a self-hoster to join.

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
