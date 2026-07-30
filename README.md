# Tastatur

Cookieless web analytics. One script tag, no cookies, no local storage, no
device identifier, no fingerprinting, so there is nothing of Tastatur's for a
consent banner to ask about.

Built on Ruby on Rails 8 and TimescaleDB. Free software under the
[AGPL-3.0](LICENSE); run it yourself or use the hosted service.

Developed, maintained and supported by **[Reedster LLC](https://reedster.llc)**.

> I have a portfolio of projects that I want to see what people do on them, but I
> do not like using tracking cookies to do this, so a lot of services were cut
> out. I enjoy building projects, and worked on this to monitor all of my
> projects.
>
> — Sean Reed, Reedster LLC

```html
<script defer data-site="YOUR_SITE_KEY" src="https://your-tastatur/t.js"></script>
```

---

## Contents

- [What it does](#what-it-does)
- [What it deliberately does not do](#what-it-deliberately-does-not-do)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Documentation](#documentation)
- [Development](#development)
- [Licence](#licence)

---

## What it does

| | |
|---|---|
| **Traffic over time** | Visitors, pageviews and visits bucketed by hour, day, week or month, in the site's own timezone |
| **Breakdowns** | Pages, entry pages, sources, referrers, countries, devices, browsers, operating systems, screen classes, and every `utm_*` field |
| **Filters** | Click any row to filter the whole dashboard. Filter state lives in the URL, so a filtered view is shareable and bookmarkable |
| **Goals** | Match a page path (exact, prefix or wildcard) or a custom event name, with conversion rates and optional revenue |
| **Funnels** | Ordered multi-step funnels with per-step drop-off, correct even when a visitor backtracks |
| **Campaigns** | Referrers grouped into recognisable sources; full UTM campaign reporting |
| **Realtime** | Visitors active in the last five minutes |
| **Shared dashboards** | Read-only public links, optionally password-protected and expiring |
| **Custom events** | `tastatur('event', 'Signup', { props: { plan: 'pro' } })`, with revenue support |

## What it deliberately does not do

This is the honest list. Tastatur measures without tracking, and that has real
costs. A tool claiming otherwise is either keeping something durable or not
telling you about it.

- **No cross-day unique visitors.** The visitor identifier is derived from a
  secret replaced every 24 hours, so a returning visitor is a new visitor. A
  30-day figure is the sum of 30 daily figures, not a count of distinct humans.
- **No cross-site or cross-device identity.** By construction.
- **Small breakdown rows are withheld.** A row describing a handful of visitors
  can identify them, so rows below a configurable threshold are suppressed, plus
  a second row wherever withholding one would let you recover it by subtraction.
- **Country-level geography only.** No region, no city, no coordinates.
- **We will not tell you that you need no consent banner.** That depends on your
  jurisdiction, your configuration, and every other script on your site.
  Tastatur stores nothing on your visitors' devices, which is the trigger for
  ePrivacy Article 5(3); the rest is your counsel's call. See
  [docs/privacy/claims.md](docs/privacy/claims.md) for the language this project
  refuses to use, and why.

## Quick start

You need Docker and Docker Compose. Nothing else: no Ruby, no Postgres, no Node.

```bash
git clone https://github.com/streed/tastatur.git
cd tastatur
docker compose up
```

Open <http://localhost:3000> and sign in as `user@example.com` / `password`.
To fill the dashboard with realistic traffic:

```bash
docker compose exec web bin/rails tastatur:demo_data DAYS=90
```

Running natively instead of in Docker:

```bash
docker compose up -d timescaledb redis redis-privacy   # dependencies only
bin/dev-setup                                          # env files, gems, database
bin/dev                                                # web + css + worker
```

For a real deployment see [docs/self-hosting/README.md](docs/self-hosting/README.md).

## How it works

A visitor loads a page. The script sends the path, the referrer's host, a window
width and the event name, and nothing else. That complete list is `payload()` in
[`public/t.js`](public/t.js), which is served unminified so it can be audited.

The visitor's IP address and user-agent arrive too, because every HTTP request
carries them. They are used, in memory, to compute three things and are then
discarded:

1. a **visitor identifier**: `HMAC-SHA256(rotating_salt, site_id ‖ ip ‖ ua)`,
   truncated to 128 bits
2. a **coarse device profile**: browser family and major version, OS, and one of
   desktop / mobile / tablet
3. a **two-letter country code**

Neither the IP nor the user-agent string is written to the database, to a log, or
to disk anywhere. The only code that touches an IP is
[`app/lib/ingest/identifier.rb`](app/lib/ingest/identifier.rb).

The salt is replaced every 24 hours and the previous value destroyed. It lives
only in a Redis instance running with persistence switched off and excluded from
backups: a salt written into a snapshot would sit in a backup next to the events
it would de-anonymise, and a restore would bring it back. Once it is gone, the
identifiers made with it cannot be recomputed by anyone, including us.

Events land in a TimescaleDB hypertable through a Redis-buffered batch writer,
and three continuous aggregates make the dashboard fast. Full detail in
[docs/architecture/overview.md](docs/architecture/overview.md).

## Documentation

**Architecture**
- [Overview](docs/architecture/overview.md) — the whole system in one page
- [Storage and aggregates](docs/architecture/aggregates.md) — the hypertable, the three continuous aggregates, and the rule about distinct counts
- [Performance](docs/architecture/performance.md) — where the dashboard actually spends its time, measured, including two optimisations that made it slower
- [Ingest pipeline](docs/architecture/ingest.md) — the tracker, the endpoint, the write buffer, throughput
- [Sessions and funnels](docs/architecture/funnels.md) — sessionisation without a cookie, and why the funnel query looks the way it does
- [Plans and billing](docs/architecture/billing.md) — the two hosted plans, how the monthly event allowance is metered and enforced, and how Stripe is wired to it. **None of it exists on a self-hosted install**

**Privacy and compliance**
- [Visitor identity](docs/privacy/identity.md) — the salt, its rotation, and what "unlinkable" does and does not mean
- [Claims](docs/privacy/claims.md) — what this project will and will not say, with reasons
- [Data requests](docs/privacy/data-requests.md) — subject access and erasure when nothing is linkable

**Operating it**
- [Railway](docs/self-hosting/railway.md) — deploying to Railway, which is where the hosted instance runs
- [Self-hosting](docs/self-hosting/README.md) — production deployment on a plain VPS
- [Configuration](docs/self-hosting/configuration.md) — every environment variable
- [Geolocation](docs/self-hosting/geolocation.md) — the optional country database
- [Operations](docs/self-hosting/operations.md) — backups, upgrades, and what must never be restored

**Contributing**
- [Development](docs/development.md) — the suite, conventions, and the TimescaleDB footguns
- [CLAUDE.md](CLAUDE.md) — architectural rules, including those learned the hard way

## Development

```bash
bin/dspec                 # full spec suite in the container
bin/dspec spec/lib        # a subset
docker compose logs -f web
docker compose exec web bin/rails console
```

The working directory is bind-mounted into the containers, so editing a file
reloads Rails and rebuilds the CSS without a restart.

**One thing to know before touching the database:** this project keeps no
`schema.rb` or `structure.sql`, on purpose. A `pg_dump` of a TimescaleDB
database silently loses hypertables and degrades continuous aggregates into
plain views, producing a database that works but is quietly wrong. Migrations
are the only source of truth and every environment is built by running them.
The full list of TimescaleDB constraints is in
[CLAUDE.md](CLAUDE.md).

## Licence and attribution

[AGPL-3.0](LICENSE). You may run, modify and self-host Tastatur freely. If you
offer it to others as a network service, the AGPL requires you to publish your
modifications.

Tastatur is developed and maintained by [Reedster LLC](https://reedster.llc). That
is a statement about **authorship** and is true of every copy of the software.

Who is **responsible for the data** in a given instance is a separate question,
and depends on who is running it. On a self-hosted install that is you, not
Reedster: set `LEGAL_ENTITY`, `LEGAL_EMAIL` and `LEGAL_JURISDICTION` so the
generated privacy policy and terms name the right party. Until you do, both pages
render a visible "not configured" banner rather than quietly publishing a document
that names nobody. See
[docs/self-hosting/configuration.md](docs/self-hosting/configuration.md#legal-identity).

IP geolocation by [DB-IP](https://db-ip.com), used under CC BY 4.0.
User-agent parsing by [device_detector](https://github.com/podigee/device_detector), LGPL-3.0.
