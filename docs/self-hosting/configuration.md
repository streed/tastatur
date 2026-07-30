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

Only needed for confirmations, password resets and invitations.

| Variable | Notes |
|---|---|
| `MAIL_FROM` | Envelope sender |
| `RESEND_API_KEY` | Resend is wired in production; `letter_opener` is used in development |

## Observability

| Variable | Notes |
|---|---|
| `SENTRY_DSN` | Optional. Unset disables Sentry |
| `RAILS_LOG_TO_STDOUT` | Set to `1` under Docker so `docker compose logs` is the single place to look |

## Billing

Only read when `SELF_HOSTED` is not `1`.

| Variable |
|---|
| `STRIPE_PUBLISHABLE_KEY` |
| `STRIPE_SECRET_KEY` |
| `STRIPE_WEBHOOK_SECRET` |

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

The privacy threshold can be set to `0` to disable row suppression. That is only
offered because a site owner looking at their own low-traffic blog is not a
privacy risk to anyone; on a public shared dashboard the threshold always applies.
