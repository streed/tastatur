# Revenue attribution

Which acquisition channel produced paying customers, rather than which produced
visitors.

> **Status: not shipped.** The design below is settled and most of it is built.
> What it is not is available: the three Stripe Connect variables are unset on the
> hosted service, so `Tastatur.revenue_enabled?` is false and every endpoint here
> is dark. Nothing was removed or gated further to achieve that — launching is a
> deploy, not a rewrite. The docs section and the in-app Revenue card both say it
> is coming.
>
> A deployment that also serves a marketing site repeats that status on
> `/revenue`, `/revenue.md` and the pricing page, and offers a waitlist in place
> of a connect button — all of which live in an edition (CLAUDE.md §19, §20) and
> are pinned by that edition's own suite, so a half-launch cannot leave one
> surface claiming otherwise. The community edition holds no addresses for people
> who are not users, so here the card states the fact and stops.

This is the only *pipeline* in Tastatur that stores data about identifiable
people, and the only part that is not anonymous by construction. That is
deliberate, it is confined to five tables, and this document exists so nobody has
to reverse-engineer why from the schema. (The waitlist above is the other place an
address is held on the hosted service; it lives in an edition, it is a mailing list
rather than a measurement pipeline, and nothing joins the two.)

## The two pipelines

```
  browser                                      customer's server
     │                                                │
     │ POST /api/event                                │ POST /api/v1/identify
     │ site token (public)                            │ API key (secret)
     ▼                                                ▼
  events (hypertable)                             customers
  salted hash, salt destroyed nightly             external_id, stripe_customer_id
  anonymous by construction                       email_hash, first touch
     │                                                │
     └────────────────┬───────────────────────────────┘
                      │  joined ONLY on channel strings,
                      │  never on visitor_hash
                      ▼
              attribution_rollups
                                     ▲
                                     │
                        Stripe Connect webhooks
                        customer_subscriptions, revenue_events
```

**The two halves never join on a visitor.** There is no column linking a `Customer`
to a `visitor_hash`, and there must not be. Adding one would make the anonymous
side retroactively identifiable and would break the claim on `/privacy` that
visitor identifiers stop working after 24 hours. They meet only at the rollup, on
the channel strings both sides independently derive.

## Why the customer side is identifiable, and why that is fine

`events` is anonymous because the identifier is a salted hash whose salt is
destroyed nightly and never derivable (see `docs/privacy/identity.md`). That
property is what lets the tracker run with no consent banner.

`customers` is fed by a completely different pipe:

- written only by `/api/v1/identify` and by Stripe Connect webhooks
- both server-to-server and authenticated
- both carrying data the customer's own application already holds about somebody
  who has signed up for it

The legal basis is theirs and already exists; we are a processor for it. No
browser session is ever load-bearing for a financial fact — which is the point,
because a closed tab, a rotated salt, or a payment completed three days later on
a different device must not be able to lose one.

The email address is the exception worth calling out: it is hashed on receipt
(`Customer.hash_email`) and the raw value is never stored. It is unsalted, because
its only purpose is an equality join against another hash of the same address, and
a per-site salt would make that impossible.

## First touch, write-once

Attribution is **first touch**, written once, not configurable.

An application calls `identify` on every sign-in, not only at signup. Under
last-write-wins, a customer acquired from a Reddit post in January is
re-attributed to Google organic the first time they search their own brand name
in March — so every paid channel slowly loses its customers to whatever people
type when they already know the name, and paid-acquisition numbers decay towards
zero on their own. That decay looks exactly like a campaign that stopped working.

Enforced field by field in `Revenue::IdentifyCustomer`, so an app that learns the
landing path later than the source can fill the gap without overwriting anything.

Two values are allowed to win against an existing one, both because they are
strictly better information:

- `first_seen_at` may move **earlier**, never later.
- `(pre-install)` may be replaced **once** by a real attribution. It means "we
  looked and there was nothing", not "they came from nowhere" — without this the
  Stripe backfill would permanently pin every customer it imported, destroying the
  data it exists to make room for.

## How attribution survives a payment

The browser knows where somebody came from. The payment happens somewhere else,
possibly days later, possibly on a device that has never seen our tracker. Nothing
that reconnects those two ends with a session, a cookie or a hash can work here —
the identifier is *designed* to expire every midnight.

So it is not reconnected. It travels with the payment:

1. On the landing page, the host app calls `tastatur.attribution()` and stores the
   result in **its own** user record.
2. At signup it POSTs that to `/api/v1/identify`.
3. When creating a Checkout Session it attaches `tastatur.checkoutMetadata()`,
   which Stripe stores and hands back on every event about that subscription
   forever.

```javascript
stripe.checkout.sessions.create({
  mode: 'subscription',
  line_items: [...],
  client_reference_id: user.id,
  metadata: tastatur.checkoutMetadata(attribution)
})
```

**`Revenue::Checkout` is ours, not theirs.** It is the Ruby half — it reads the
metadata back off a webhook, and `.metadata` exists for our own self-measurement
and for specs. A customer's application cannot call it, so the browser helper
above is what they actually use. Anyone not running our tracker builds the hash by
hand; it is flat and prefixed:

```
tst_source  tst_medium  tst_campaign  tst_content  tst_term
tst_landing_path  tst_referrer_host  tst_first_seen_at
```

Keys are prefixed `tst_` so they cannot collide with the customer's own metadata,
and values are truncated to Stripe's 500-character limit — a value over it fails
the whole Checkout Session, and an analytics helper that breaks a customer's
checkout is the worst thing this library could do.

**`tst_referrer_host` is load-bearing and was missing at first.** The tracker
sends a bare referrer host and no source for any visit carrying no UTM tags —
which is all organic and word-of-mouth traffic. Left off `Checkout::FIELDS` it was
dropped on the way into Stripe, so the customer created from
`checkout.session.completed` had nothing to classify and fell back to Direct:
every tagged campaign attributed correctly, every untagged referral silently
relabelled. `spec/lib/revenue/tracker_contract_spec.rb` pins the field list, the
prefix and the length limit against the tracker's source, because there is no
JavaScript runtime in the app container and every way these two can disagree fails
silently.

`tastatur.attribution()` returns **raw** values: `referrer_host` is a bare
hostname, not "Hacker News", and no medium is invented when `utm_medium` is
absent. Both so the server can classify it and the anonymous pageview identically.
See "one vocabulary" below.

## One vocabulary, or the report splits in two

`Revenue::Channel` is the single place that names a channel.

The visitor count comes from the events hypertable, where a source was classified
server-side by `Ingest::Referrer` against `config/referrer_sources.yml`. The
revenue comes from `customers`, where a source arrived from a browser that has
never heard of that file.

Left alone those produce different spellings of the same channel, and the failure
is silent and ugly: a Hacker News visit counted under "Hacker News" on the traffic
side and "news.ycombinator.com" on the revenue side, so the flagship screen shows
two rows — one with all the visitors and no money, one with all the money and no
visitors. Both wrong, neither empty, nothing raised, and the conversion rate reads
0% for the channel that is actually working.

So every source entering the revenue side is classified through the same table at
**write** time. Sentinels (`Direct`, `(none)`, `(pre-install)`) are applied at
**read** time only — `Channel.resolve_source` returns nil rather than a sentinel,
because attribution is write-once and a stored sentinel would lock the column
against the real value forever.

## Stripe Connect

A **second, separate** Stripe integration from `Billing::`. That one takes money
from our customers; this one reads revenue belonging to them. Two features that
both say "Stripe" and mean opposite directions do not share a namespace, a
controller, a webhook endpoint or a signing secret.

- **The integration is a Stripe App, not a Connect "platform".** It was designed
  for the legacy Connect *Extension* registration — the only kind that could
  request `read_only` and connect accounts already attached to another platform —
  but Stripe closed new Extension registrations when Stripe Apps replaced them
  (2022); the Connect settings page now offers only Platform/Marketplace, and
  neither fits. The app in `stripe-app/` is the successor: read-only-ness lives in
  its manifest's permission list (every permission ends in `_read`), Stripe review
  approves that list, and the customer sees it item by item at install. Customers
  authorize through the app's OAuth install link
  (`marketplace.stripe.com/oauth/v2/authorize`), which works for accounts that
  already belong to another platform.
- **No access token is stored.** Stripe returns one; we discard it. Every call
  uses the platform secret key plus a `Stripe-Account` header, which reaches the
  same data — so there is no long-lived third-party credential on disk to encrypt,
  rotate, or leak in a backup. `Revenue::StripeAccount` is the only place that
  builds those options.
- **The Connect webhook needs its own endpoint and its own secret.** A dashboard
  endpoint is either "account" or "connect", never both. Pointing Connect
  deliveries at `/billing/stripe/webhook` fails every signature check — and since
  that controller answers 400, Stripe disables it after three days, taking our own
  subscription billing down as collateral.
- **The 503 branch must be checked before the config gate.** `Tastatur.revenue_enabled?`
  itself requires the signing secret, so testing it first makes the 503 unreachable
  and a deployment that lost only its secret answers 404 — which Stripe treats as
  permanent, discarding revenue a retry would have recovered.

### Configuration

```
STRIPE_SECRET_KEY=sk_...                # also used by billing; makes the Stripe-Account calls
STRIPE_CONNECT_CLIENT_ID=...            # the Stripe App's OAuth client id (app details page)
STRIPE_CONNECT_WEBHOOK_SECRET=whsec_... # a DIFFERENT secret from STRIPE_WEBHOOK_SECRET
```

### Operating the Stripe App

The app is defined by `stripe-app/stripe-app.json` — id `dev.tastatur.revenue`,
OAuth authentication, public distribution, and seven read permissions matching
exactly what `Revenue::ApplyConnectEvent` consumes. To set it up on a Stripe
account (once per mode):

1. `stripe login` (interactive), then `stripe plugin install apps`.
2. From `stripe-app/`: `stripe apps upload`. The first upload registers the app;
   the dashboard's **Developers → Apps** page then shows it.
3. The OAuth client id and pre-review **External test** authorize links live on
   the app's details page. The public install links only work after app review;
   external-test links work immediately and with other accounts, which is how the
   integration is exercised before publishing.
4. Create the Connect webhook endpoint (dashboard → Webhooks → "Listen to events
   on Connected accounts") pointing at `/stripe/connect/webhook`, subscribed to
   the `ConnectEvent::HANDLED` list; its signing secret is
   `STRIPE_CONNECT_WEBHOOK_SECRET`. For local work,
   `stripe listen --forward-connect-to localhost:3000/stripe/connect/webhook`
   prints an equivalent secret.
5. Submitting for review (needed before outside customers can install from the
   marketplace) starts from the same details page; the install URL to give review
   is the site's Attribution screen, which initiates the OAuth flow.

**There are two shapes of install link, and the published one does not work
until the app is published.** The Settings tab's public link is
`marketplace.stripe.com/oauth/v2/authorize?...`; the External test tab's link —
the only one that installs the app before app review — is
`marketplace.stripe.com/oauth/v2/chnlink_.../authorize?...`, carrying a channel
id that is not derivable from the client id or anything else we hold. Pointing
the published form at an unpublished app is answered with "The provided OAuth
link is invalid", which names no cause. So `STRIPE_CONNECT_INSTALL_URL`
overrides the base until the app is published, and is dropped afterwards; the
controller discards any query string on it and rebuilds the parameters, because
the dashboard hands you a complete URL and pasting it whole is the obvious move.

**The exchange key must match the install link's mode.** The code is exchanged
with this instance's own `STRIPE_SECRET_KEY`, and Stripe requires the key for
the link's mode: a live link needs the live key, a test link the test key, a
sandbox install the managed sandbox's key. An instance running on a live key
therefore cannot complete a sandbox install — the customer sees "Stripe refused
the connection" — which also means the "connected in TEST MODE" branch is only
reachable where the instance's own key is a test key (development, mostly).

**The open question the live external test must answer** (task list; also in
CLAUDE.md §18): whether platform-key + `Stripe-Account` reads are honoured for
an account that installed an oauth-type app, or whether Stripe insists on the
access/refresh tokens its docs describe. The sandbox proved the negative case
(no install → refused, "application access") but a self-install cannot prove
the positive one. If Stripe refuses, the "no token stored" invariant needs a
decision, not a workaround — stop and take it to the owner.

**App ids are globally unique across all of Stripe, and effectively
unreclaimable.** The first sandbox copy was uploaded as `dev.tastatur.revenue`
and squatted the name for every other account forever — ids are immutable, and
deleting an app does not reliably release its id. The production app is
therefore `dev.tastatur.attribution`, and any future sandbox or test copy must
take its own id (`dev.tastatur.attribution.test`) from the start.

Two things learned the hard way, both invisible until they refuse you:

- **An account with a Connect *platform* registration cannot own this app** —
  upload fails with "you cannot choose the public distribution at this time",
  and the registration is not self-serve removable. Clicking through the
  Connect onboarding while exploring the dashboard is how an account acquires
  one, so the app should be uploaded from an account that never touched
  Settings → Connect.
- **External testing (the pre-review OAuth install links) only works from a
  live account.** In a sandbox the External test tab renders and its "Set
  version" button silently does nothing. A sandbox can build, upload and
  self-install the app — enough to verify webhooks and the platform-key read
  path — but minting an install link another account can use requires the app
  uploaded to a live account.

### Exercising the whole thing on a laptop

Four things have to be true at once, and each of them fails in a way that looks
like one of the others.

**1. HTTPS, because Stripe will not accept an `http://` redirect URI.**

```bash
bin/dev-ssl    # mints the certificate if needed, then serves 3000 AND 3443
```

`stripe-app/stripe-app.json` pins `https://localhost:3443/stripe/connect/callback`,
so the port is not a preference — a different one is not in the manifest and the
install is refused with a redirect-uri mismatch. The certificate is self-signed,
so the browser needs one "Proceed anyway" on `https://localhost:3443` before the
OAuth round trip will complete; taken during the redirect it looks like Stripe
failing rather than a certificate prompt.

**It is a separate script from `bin/dev` because `bin/rails server` cannot do
this, and fails at it silently.** `rails server` builds its own bind list and
clears whatever `config/puma.rb` declared, so the `ssl_bind` is discarded: puma
boots, announces the plain listener, never mentions 3443, and reports no error.
`Procfile.dev.ssl` therefore runs `bundle exec puma -C config/puma.rb` instead,
which is the only entry point that honours the config file's binds. Measured both
ways — the same config produces two listeners under puma and one under `rails
server`.

Note also that `config/puma.rb` must use plain Ruby rather than `.present?` in
that block. Puma loads the file itself, before any Rails boot, so ActiveSupport's
core extensions are not there — and the resulting NoMethodError appears only
under `bundle exec puma`, which is to say only in production and in this script.

**2. Connect deliveries forwarded, signed with the secret the app is configured with.**

```bash
bin/stripe-connect-listen
```

The CLI must be logged in as the account that **owns** the app, not the one that
installed it — connect deliveries are addressed to the platform, and a listener on
the connected account sees nothing while looking exactly like a broken
integration. The script checks that `STRIPE_CONNECT_WEBHOOK_SECRET` matches what
the listener signs with, because a mismatch there is the specific silent failure
`revenue_enabled?` requires the variable to prevent: connecting works, the
backfill works, historical revenue appears, and nothing new ever arrives.

**3. A SECOND Stripe account playing the customer.** A self-install works and
proves less than it appears to: it cannot distinguish "the platform key reads
installed accounts" from "it read my own account", which is the open question in
the note above. Install from a sandbox via the **External test** link
(`STRIPE_CONNECT_INSTALL_URL`) — not the published `/oauth/v2/authorize` form,
which answers "The provided OAuth link is invalid" until the app is published and
names no cause.

**4. Data, created with the connected account's own key.**

```bash
STRIPE_SANDBOX_SECRET_KEY=sk_test_… bin/rails tastatur:revenue:seed SITE=<public_token>
bin/rails runner 'RollupAttributionJob.perform_now(Site.find_by(public_token: "…").id)'
bin/rails tastatur:revenue:status SITE=<public_token>
```

**That key is deliberately a different variable from `STRIPE_SECRET_KEY`, and the
task refuses a live one.** Creating subscriptions and refunds is a *write*, and
the access model this whole document describes — platform key plus
`Stripe-Account`, against a manifest where every permission ends in `_read` —
cannot make one and must never be able to. So the seed writes as the customer's
own application would: with the customer's own test key, used nowhere else in the
codebase. If `tastatur:revenue:seed` could run on the platform key, that would be
the bug.

The scenarios exist to cover the traps this document records rather than to look
like a business: both `kind` families, an expansion and a churn so the sign
convention is exercised in both directions, a EUR subscription so
`normalized_cents` stays NULL and `unconverted_events` has something to count, a
customer with no attribution at all that the backfill must label `(pre-install)`
rather than folding into Direct, and an untagged referral — the case
`tst_referrer_host` was added for, and the one that silently collapsed to Direct
without it. `tastatur:revenue:sweep` deletes the Stripe side afterwards; the local
rows are left alone.

`checkout.session.completed` is the one path the seed cannot drive: completing a
Checkout Session needs a browser. Attribution metadata is written onto the Stripe
**customer** instead, which `ApplyConnectEvent` and `BackfillStripe` both read
through the same `Checkout.extract_attribution`. Drive the session path by hand,
or with `stripe trigger`, when it is specifically what is being tested.

`Tastatur.revenue_enabled?` is the only gate. It is deliberately **not** gated on
`billing_enabled?`: billing is about whether *we* can charge, this is about whether
a customer can connect *their* processor. A self-hosted install has no billing by
definition and every reason to want revenue analytics.

## Two families of `revenue_events.kind`

One column, two meanings, and conflating them is the easiest mistake in a revenue
schema to make and the hardest to notice:

| Kinds | `amount_cents` is |
|---|---|
| `new`, `expansion`, `contraction`, `churn`, `reactivation` | an **MRR delta** |
| `payment`, `one_time`, `refund`, `dispute` | **cash** that moved |

An annual subscription writes a `new` of 4,000 (its monthly worth) and a `payment`
of 48,000 (what was charged). Add those and the customer appears to have paid
52,000, which is not a number that exists. `RevenueEvent::MRR_KINDS` and
`CASH_KINDS` are the two lists; every consumer reads one or the other, never `.all`.

Amounts are **signed** — a churn is negative, a refund is negative. Storing
magnitudes plus a direction implied by `kind` means every consumer re-derives the
sign, and one of them eventually reports churn as growth. The one exception is
`attribution_rollups.churned_mrr_cents`, which is stored positive because it is
read under a heading that already says "Churned".

## Currency

`Revenue::Normalize` converts same-currency amounts and returns **nil** for
everything else. There is no FX rate table yet.

Both shortcuts are worse than doing nothing. Treating an unconvertible €40 as $40
reports a number wrong by however far the pair has moved and looks entirely
normal. Treating it as $0 silently deletes real revenue — and the customers it
deletes are exactly the international ones somebody is deciding whether to keep
selling to.

So the row keeps `normalized_cents` NULL, `attribution_rollups.unconverted_events`
counts it, and the screen says so in words. `Normalize.rate_for` is the seam:
give it a rates table and the ledger column, the counter and the wording all start
working with no other edit.

## Rollups

`attribution_rollups` is an ordinary table, not a continuous aggregate: a
continuous aggregate can read only one hypertable, and this row is a join across
both pipelines. It is written only by `Revenue::RollupAttribution` and read only by
`Revenue::AttributionReport`.

Days are the **site's local days**, matching every other screen (§13 explains why
the salt rotates on the same boundary). A revenue table disagreeing with the
traffic table about where Tuesday ends would make the two halves of the flagship
screen not add up.

`RollupAttributionJob` recomputes the last **three** days nightly, not one. Stripe
retries a failed delivery for three days, so a payment can legitimately arrive on
Thursday for a Tuesday invoice and belongs on Tuesday's row. Recomputation
replaces a day rather than adding to it, so re-running always converges.

**`lifetime_revenue_cents` is a snapshot and must never be summed across days.**
It is "everything this channel has ever produced, as of the night this was
written", so it appears in full on every day's row; summing 30 days multiplies the
business by thirty, and the number looks plausible. `AttributionReport` reads it
from the latest row only. This is the same trap §8 documents for distinct counts.

## What is deliberately absent

- **No revenue on public shared dashboards.** `SharedDashboardsController` renders
  traffic only and never calls `AttributionReport`. Publishing a company's MRR to
  an unguessable-but-public URL is not something anybody should be one checkbox
  away from.
- **No multi-touch attribution.** First touch, documented, not configurable — a
  number that moves because a dropdown moved is a number nobody believes.
- **No write access to a connected Stripe account,** and no code path that could
  acquire it.
- **No user-agent, IP or device data on any of these tables.** §13 applies here
  exactly as it does everywhere else.

## Jobs

| Job | Queue | Schedule |
|---|---|---|
| `ApplyConnectEventJob` | `within_30_seconds` | on delivery |
| `RetryConnectEventsJob` | `within_5_minutes` | every 7 minutes |
| `RollupAttributionJob` | `within_1_hour` | 03:51 daily |
| `BackfillStripeJob` | `within_1_hour` | on connect, and on demand |

`ApplyConnectEvent` records failures on the row and returns a Failure rather than
raising, so a stuck event is diagnosable from the database. `RetryConnectEvents`
is therefore the only thing that retries it — sweeping the backlog in event order,
which matters, because applying a cancellation before the subscription it cancels
leaves the row wrong.
