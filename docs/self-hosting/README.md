# Self-hosting Tastatur

Tastatur is AGPL-3.0 and designed to be run by the person who owns the data.

This repository is the **community edition**, and every part of the product is in
it: the tracker, the ingest pipeline, the dashboard, goals, funnels, journeys,
shared dashboards, teams, two-factor, the compliance pages, and the billing and
revenue-attribution code. Billing is what `SELF_HOSTED=1` switches off, and it
also stays off until Stripe is configured. Revenue attribution is not gated on
either — it asks only whether Stripe Connect is configured, because it shows
*your* customers' revenue, and refusing it here would remove the point of it. What
the hosted
deployment adds is one *edition* (a Rails engine in `editions/`, kept in its own
repository) holding the pages that advertise that particular deployment: its
landing page, pricing, about and FAQ. Nothing you would want on your own hardware
is behind it, which is the test used to decide what stayed. See
[CLAUDE.md](../../CLAUDE.md) §20 if you want the whole rule.

## Deploying to Railway

If you are deploying to Railway, use [railway.md](railway.md) instead of this page.
Railway needs a TimescaleDB template rather than its default Postgres, and a
second Redis with no volume, neither of which is obvious from the dashboard.

## Requirements

- A host with Docker and Docker Compose. 2 vCPU and 2 GB of RAM is comfortable
  for a few million events a month.
- A domain name pointing at it, if you want HTTPS (you do — the tracker will be
  loaded from `https://` pages, and a browser will refuse to fetch it over
  plain HTTP).
- Ports 80 and 443 reachable.

No Ruby, no PostgreSQL, no Node, no separate certbot.

## Install

```bash
git clone https://github.com/streed/tastatur.git
cd tastatur

cp .env.production.example .env.production
$EDITOR .env.production          # set APP_DOMAIN, POSTGRES_PASSWORD, SECRET_KEY_BASE

docker compose -f docker-compose.prod.yml up -d
```

Generate the secret with:

```bash
docker compose -f docker-compose.prod.yml run --rm web bin/rails secret
```

Caddy requests a Let's Encrypt certificate on first boot, so the first request
may take a few seconds. Then open `https://your-domain` and you will land on the
**first-run setup** screen, which creates the owner account and your first site.
That screen is reachable only while the database has no users, so it closes
itself and cannot become a backdoor.

Enable country reporting (optional, one command):

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails tastatur:geoip:download
```

See [geolocation.md](geolocation.md) for the licence obligation that comes with it.

## What is running

| Service | Role | Published |
|---|---|---|
| `caddy` | TLS termination, automatic certificates, static caching | 80, 443 |
| `web` | Rails: dashboard and ingest endpoint | internal only |
| `worker` | Sidekiq: buffer flush, retention, reconciliation | internal only |
| `timescaledb` | PostgreSQL 17 + TimescaleDB | internal only |
| `redis` | Ingest buffer, cache, job queue. **Persistent** | internal only |
| `redis-privacy` | Visitor salt and session map. **Non-persistent, no volume** | internal only |

The last row is the one to understand before you touch backups. Read
[operations.md](operations.md#what-must-never-be-backed-up).

## Verify it works

```bash
curl https://your-domain/up
```

```json
{"status":"ok","version":"0.1.0",
 "checks":{"database":"ok","redis":"ok","redis_privacy":"ok"}}
```

`redis_privacy` is checked separately on purpose: if it is down, ingest cannot
compute a visitor identity at all, and a green health check that ignored it would
be actively misleading.

Then add the snippet to a page and load it. The installation screen polls and
tells you the moment the first event arrives.

## Configuration

Every variable is documented in [configuration.md](configuration.md). The ones
that matter on day one:

| Variable | |
|---|---|
| `APP_DOMAIN` | Public hostname. Caddy requests a certificate for it |
| `SECRET_KEY_BASE` | Rails session and cookie signing. Losing it logs everyone out |
| `POSTGRES_PASSWORD` | Database password |
| `SELF_HOSTED=1` | Already set in the prod compose file. Removes billing entirely |
| `ALLOW_SIGNUP` | Defaults to **off** when self-hosted, so an exposed instance cannot be signed up to by strangers. Set to `1` to open registration |
| `REDIS_PRIVACY_URL` | Already set. If you point it at your persistent Redis you lose the unlinkability guarantee, and the app will warn you at boot |

## Reverse proxy notes

If you put Tastatur behind your own proxy instead of the bundled Caddy, forward
the client address:

```
X-Forwarded-For: <client ip>
X-Forwarded-Proto: https
```

Without it, every visitor appears to come from your proxy and collapses into a
single visitor. Rails also needs to trust the proxy; see
[configuration.md](configuration.md#trusted-proxies).

## Upgrading

```bash
git pull
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
```

`web` runs `db:prepare` on boot, which runs pending migrations. There is no
schema file to load — migrations are the only source of truth, for reasons
explained in [../architecture/aggregates.md](../architecture/aggregates.md#migrations-and-why-there-is-no-schema-file).

Read [operations.md](operations.md) before your first upgrade.

## Scaling

The first thing to run out is usually ingest throughput, and the levers in order
are:

1. Raise `INGEST_FLUSH_SIZE` (default 250) so each INSERT covers more events.
2. Scale `worker`, which drains the buffer:
   `docker compose -f docker-compose.prod.yml up -d --scale worker=3`
3. Give ingest its own `web` process so a slow dashboard query cannot starve it.
4. Shorten `data_retention_days` per account, and let the columnstore policy
   compress older chunks.

Storage: a pageview is roughly 150–250 bytes uncompressed and compresses well in
the columnstore. A site doing 10M events a month should budget a couple of GB a
month before compression, considerably less after.

## Sending events from a server

The ingest endpoint is a plain HTTP API, so backend and mobile events work:

```bash
curl -X POST https://your-domain/api/event \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: <the end user's IP>' \
  -H 'User-Agent: <the end user's UA>' \
  -d '{"s":"YOUR_SITE_KEY","u":"https://example.com/checkout",
       "n":"Purchase","v":4900,"c":"EUR"}'
```

Pass the **end user's** address and user-agent, not your server's. Otherwise
every server-side event collapses into one visitor located wherever your server
is. Only do this from a host Rails trusts as a proxy.
