# Configuration

Every environment variable Tastatur reads. Anything not listed here is standard
Rails.

## Required in production

| Variable | Notes |
|---|---|
| `SECRET_KEY_BASE` | Session and cookie signing. Generate with `bin/rails secret`. Changing it signs everyone out |
| `DATABASE_URL` | `postgres://user:pass@host:5432/tastatur_production` |
| `APP_HOST` | Public host, e.g. `analytics.example.com`. Used to build the tracker URL shown on the installation screen, and for mailer links |
| `APP_DOMAIN` | Used by the bundled Caddyfile to request a certificate. Usually the same value as `APP_HOST` |
| `POSTGRES_PASSWORD` | Read by the prod compose file |

## Redis

| Variable | Default | Notes |
|---|---|---|
| `REDIS_URL` | `redis://localhost:6379/0` | Ingest buffer, cache, Sidekiq. Should be persistent |
| `REDIS_PRIVACY_URL` | falls back to `REDIS_URL` with a boot warning | Visitor salt and session map. **Must point at a Redis with persistence disabled** |
| `REDIS_POOL_SIZE` | `10` | Connections per pool |

`REDIS_PRIVACY_URL` is the one setting where the default is deliberately a
warning rather than a convenience. Pointing it at a persistent Redis means the
salt is written to disk, which is the one thing that must not happen — see
[../privacy/identity.md](../privacy/identity.md#it-lives-only-in-redis-never-in-postgresql).

## Deployment mode

| Variable | Default | Notes |
|---|---|---|
| `SELF_HOSTED` | `0` | `1` disables billing entirely: Stripe is never touched, plan limits do not apply, and upgrade UI is hidden |
| `ALLOW_SIGNUP` | `1` hosted, **`0` self-hosted** | Public registration. Off by default when self-hosted so an internet-exposed instance cannot be signed up to by strangers |
| `TRACKER_URL` | `{APP_HOST}/t.js` | Override if you serve the script from a CDN or a proxied path |
| `INGEST_URL` | `{APP_HOST}/api/event` | Override if events are proxied separately. The script normally derives this from its own `src`, so you rarely need it |
| `SELF_MEASUREMENT_SITE_TOKEN` | unset | A site key **on this instance** to measure this instance's own dashboard with. Unset means no tracker is served on any page of the app, which is the right default for a self-hosted install: nothing measures you, and nothing is sent anywhere. The hosted service sets it to the key of its own site |

## Ingest tuning

| Variable | Default | Notes |
|---|---|---|
| `INGEST_FLUSH_SIZE` | `250` | Buffer depth that triggers a flush. Raise it under high volume so each INSERT covers more events |
| `INGEST_FLUSH_INTERVAL_SECONDS` | `10` | Age-based flush target. The cron backstop runs every minute regardless |
| `SESSION_TIMEOUT_MINUTES` | `30` | Inactivity gap that ends a session. 30 is the long-standing convention; changing it makes your numbers incomparable to other tools |
| `SIDEKIQ_CONCURRENCY` | `5` | Worker threads. Raising it does **not** raise ingest throughput: 150,000 buffered events flushed in 6.85 s at 5 and 8.39 s at 15, because the multi-row INSERT is the bottleneck and extra threads only contend. It also sizes Sidekiq's own Redis pool while leaving the ActiveRecord pool at `RAILS_MAX_THREADS`, so pushing it far enough exhausts database connections instead of going faster |
| `DB_STATEMENT_TIMEOUT` | `15s` | Ceiling on any single statement. **Set it to `0` on the worker process and nowhere else.** The cap stops one expensive dashboard query holding a connection indefinitely; the worker is the opposite case, since `refresh_continuous_aggregate` and the nightly retention delete legitimately run for minutes. Cancelling those leaves aggregates unreconciled after an erasure and stops retention enforcing the window you publish. `docker-compose.prod.yml` does this for you; on Railway the worker is a separate service and you must set it yourself |

`WEB_CONCURRENCY` × `RAILS_MAX_THREADS` + `SIDEKIQ_CONCURRENCY` must stay under the
database's `max_connections`. `WEB_CONCURRENCY=auto` resolves to the host's core
count, which is a trap on a large machine: 24 cores × 3 threads + 5 is 77
connections from one deployment against a stock PostgreSQL's ~97. It will not fail
at boot, because ActiveRecord pools are lazy — it fails later as intermittent
`FATAL: too many connections` under load.

## Geolocation

| Variable | Default | Notes |
|---|---|---|
| `GEOIP_DB_PATH` | `db/geoip/country.mmdb` | Absent file means country reporting is simply off; everything else works |

See [geolocation.md](geolocation.md).

## TLS

Both supported deployments terminate TLS in front of the app (Railway's edge, or
the bundled Caddy), so the app sees plain HTTP on the inside of an HTTPS request.

| Variable | Default | Notes |
|---|---|---|
| `ASSUME_SSL` | `1` | Treat every request as already secure. Required behind a TLS-terminating proxy |
| `FORCE_SSL` | `1` | Strict-Transport-Security and `secure` session cookies |

Leave both at `1` unless you are running behind a proxy that does **not** terminate
TLS. Getting this wrong is a real footgun in both directions:

- `FORCE_SSL=1` with `ASSUME_SSL=0` behind a terminating proxy gives a redirect
  loop, because Rails sees http, redirects to https, and the proxy forwards it
  back as http.
- `ASSUME_SSL=1` over genuinely plain HTTP marks session cookies `secure`, so the
  browser never sends them back and nobody can stay signed in.

`/up` is excluded from the https redirect regardless, because a 301 there fails a
platform health check and takes the whole deploy down with it.

## Legal identity

The privacy policy and terms are templates. Until these are set, both pages
render a loud "not configured" banner instead of quietly publishing a document
that names nobody. `LEGAL_ADDRESS` and `LEGAL_DPO_EMAIL` are optional; the other
three are required to clear the banner.

| Variable | Example |
|---|---|
| `LEGAL_ENTITY` | `Reed Analytics Ltd` |
| `LEGAL_ADDRESS` | `1 Example Street, City, Country` |
| `LEGAL_EMAIL` | `privacy@yourdomain.com` |
| `LEGAL_JURISDICTION` | `England and Wales` |
| `LEGAL_DPO_EMAIL` | `dpo@yourdomain.com` |

A policy naming no entity, and terms governed by no jurisdiction, are worse than
none: they look like diligence while providing neither the disclosure the law
requires nor the protection you wanted. Have your own counsel review both before
relying on them.

## Email

Needed for confirmations, password resets, invitations and two-factor sign-in codes.

| Variable | Notes |
|---|---|
| `MAIL_FROM` | Envelope sender |
| `RESEND_API_KEY` | Resend is wired in production; `letter_opener` is used in development |

**If anyone on your instance switches on two-factor authentication, mail delivery
stops being optional for them.** Their sign-in codes go to the address on their
account, so a broken relay locks them out rather than merely inconveniencing them.

There is a way back and it does not need a Rails console: any instance administrator
can turn two-factor authentication off for somebody from **Admin → Users → that
person → Turn off two-factor authentication**. It can only turn the feature off, never
on, so an administrator cannot use it to redirect a customer's codes to an address
they control. Keep at least two instance administrators for the same reason you keep
two of anything that unlocks a door.

The first-run wizard creates its user already confirmed and without two-factor, so a
fresh install is always reachable before mail is configured.

## Observability

| Variable | Notes |
|---|---|
| `SENTRY_DSN` | Optional. Unset disables Sentry |
| `RAILS_LOG_TO_STDOUT` | Set to `1` under Docker so `docker compose logs` is the single place to look |

## Billing

**Not read at all when `SELF_HOSTED=1`.** A self-hosted install has no plans, no
event or site limits, no upgrade interface, and never contacts Stripe — every
billing question asks `Tastatur.billing_enabled?` first. You can leave this whole
section blank.

**And billing stays off until these are set, even without `SELF_HOSTED=1`.** An
instance that cannot take a payment does not enforce a plan limit either, because a
limit nobody can lift is a dead end rather than a business model. It switches itself
on the moment the variables are present. `required_env.rb` logs
`BILLING IS DISABLED` at boot with the missing names, so the safe state is never a
silent one.

On the hosted service the three the application actually uses are required, and
`required_env.rb` logs an error at boot for any of those that is missing.
`STRIPE_PUBLISHABLE_KEY` is not checked, because nothing reads it — see the table.

| Variable | Default | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | unset | `sk_live_…`. Checkout and the billing portal raise without it |
| `STRIPE_PUBLISHABLE_KEY` | unset | `pk_live_…`. **Nothing reads it**, and there is no boot warning for it: payment happens on Stripe's hosted Checkout, so this application renders no card form and loads no Stripe.js. It is kept because it is half of the pair every deployment expects to set, and because an embedded payment form would need it |
| `STRIPE_WEBHOOK_SECRET` | unset | `whsec_…`, from the webhook endpoint you create at `https://APP_HOST/billing/stripe/webhook`. **The one whose absence fails invisibly**: the endpoint refuses every delivery, so a subscription is paid for and never applied — Stripe shows the charge, the customer stays on the free plan, and nothing raises |
| `STRIPE_PRICE_PRO` | unset | `price_…`, the recurring monthly price for the Pro plan. Without it the plan cannot be bought |

Run `bin/rails tastatur:billing:verify` after setting these. It checks that the
Stripe price still costs what `/pricing` publishes, in the same currency, recurring
monthly — the failure being a price edited in the dashboard with nothing in the
application noticing.

The full design, including what happens when an account passes its monthly
allowance, is in [../architecture/billing.md](../architecture/billing.md).

## Revenue attribution (Stripe Connect)

A **different Stripe integration from the one above**, pointing the other way. The
variables above let this instance charge *its* customers. These let a customer
connect *their own* Stripe account, read-only, so the attribution screen can show
which acquisition channel produced paying customers.

**This works on a self-hosted install.** `Tastatur.revenue_enabled?` is
deliberately not gated on billing: billing is about whether this instance can
charge, and this is about whether a site owner can see their own revenue. Leave
these unset and the feature is simply absent — no screens, no endpoints, and the
attribution page says so rather than looking broken.

**Set it up by uploading the Stripe App in `stripe-app/`**, not from the Connect
settings page. The Connect page's Platform/Marketplace choices are for routing
payments and cannot grant the read-only access this feature uses; the legacy
"Extension" registration that could no longer exists. Instead: `stripe login`,
`stripe plugin install apps`, then `stripe apps upload` from `stripe-app/` — the
app's details page (**Developers → Apps**) then shows the OAuth client id and the
install links. What the app may read is fixed by the manifest's permission list,
every entry of which ends in `_read`. The step-by-step runbook is in
`docs/architecture/revenue.md` under "Operating the Stripe App".

| Variable | Default | Notes |
|---|---|---|
| `STRIPE_CONNECT_CLIENT_ID` | unset | the OAuth client id from the app's details page |
| `STRIPE_CONNECT_WEBHOOK_SECRET` | unset | `whsec_…`, from a **Connect** webhook endpoint at `https://APP_HOST/stripe/connect/webhook`. **A different secret from `STRIPE_WEBHOOK_SECRET`** — a Stripe endpoint is either "account" or "connect", never both, and each has its own. **The one whose absence fails invisibly**: connecting succeeds, the historical backfill runs and fills the charts, and then no ongoing revenue is ever recorded because every delivery is refused. `required_env.rb` logs an error at boot for the half-configured combination |

`STRIPE_SECRET_KEY` is shared with billing above and is required here too: every
call into a connected account is made with it plus a `Stripe-Account` header. **No
access token is stored** — the one Stripe returns during OAuth is discarded, so
there is no long-lived third-party credential on disk to encrypt, rotate or leak in
a backup.

Subscribe the Connect endpoint to: `customer.created`, `customer.updated`,
`customer.subscription.created|updated|deleted`, `checkout.session.completed`,
`invoice.paid`, `invoice.payment_failed`, `charge.refunded`,
`charge.dispute.created`, and `account.application.deauthorized` — the last one is
how uninstalling the app from the Stripe side disconnects the site here.

The full design — including why `customers` is the one identifiable table, how
attribution survives a payment, and the two families of `revenue_events.kind` — is
in [../architecture/revenue.md](../architecture/revenue.md).

## Trusted proxies

Rails computes `request.remote_ip` from `X-Forwarded-For`, and that value feeds
both the visitor hash and the country lookup. It must be trustworthy: a
spoofable client address means a visitor could choose their own identity, and an
untrusted one means every visitor collapses into your proxy's address and appears
as a single visitor.

Rails trusts private ranges by default, which covers the bundled Caddy setup. If
your proxy sits in a public range, add it explicitly:

```ruby
# config/application.rb
config.action_dispatch.trusted_proxies =
  ActionDispatch::RemoteIp::TRUSTED_PROXIES + [IPAddr.new("203.0.113.7")]
```

Do **not** add a wide public range. Anything you trust can set its own address.

## Per-site and per-account settings

Some things are deliberately not environment variables, because they are
compliance decisions that belong to whoever owns the data rather than to whoever
runs the server:

| Setting | Where | Default |
|---|---|---|
| Reporting timezone | Site settings | `Etc/UTC` |
| Privacy threshold (`k`) | Site settings | `25` |
| Raw event retention | Account settings | 12 months (max 25) |
| Monthly event allowance | `accounts.event_limit_override` | unset — the plan decides |
| Site allowance | `accounts.site_limit_override` | unset — the plan decides |

The two `*_override` columns are a support lever for the hosted service, not a
setting with an interface: they exist so one customer can be lifted over a cap
without inventing a plan for them or editing a constant. Both are ignored entirely
when `SELF_HOSTED=1`, so a value left in either column cannot throttle an instance
you are running yourself.

The privacy threshold can be set to `0` to disable row suppression. That is only
offered because a site owner looking at their own low-traffic blog is not a
privacy risk to anyone; on a public shared dashboard the threshold always applies.
