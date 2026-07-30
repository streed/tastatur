# Architecture overview

The whole system in one page. Each section links to the detail.

## Shape

```
visitor's browser
      │  POST /api/event   (sendBeacon, text/plain, ~200 bytes)
      ▼
Api::EventsController ──── opt-out check (DNT / Sec-GPC) ──► 202, nothing stored
      │                    prefetch check                 ──► 202, nothing stored
      │
      ▼
IngestEventContract         bounds every field of untrusted input
      │
      ▼
Ingest::RecordEvent
      ├─ Ingest::UserAgent      bot? ──► 202, nothing stored
      ├─ Ingest::Identifier     HMAC(salt, site ‖ ip ‖ ua)     ◄── privacy Redis
      ├─ Ingest::SessionWindow  30-min sliding TTL              ◄── privacy Redis
      ├─ Ingest::PathScrubber   strips PII from path + query
      ├─ Ingest::Referrer       host + grouped source
      └─ Ingest::Geolocation    country code only
      │
      ▼
Ingest::WriteBuffer ──► Redis list ──► FlushEventBufferJob ──► multi-row INSERT
                                                                    │
                                                                    ▼
                                                          events (hypertable)
                                                                    │
                                              ┌─────────────────────┼──────────────────┐
                                              ▼                     ▼                  ▼
                                       events_by_hour        visitor_days       session_days
                                              │                     │                  │
                                              └─────────────────────┼──────────────────┘
                                                                    ▼
                                                            Analytics::Scope
                                              (decides: aggregate or raw scan?)
                                                                    │
                        ┌───────────────┬───────────────┬───────────┴───────┬─────────────┐
                        ▼               ▼               ▼                   ▼             ▼
                     Summary       Timeseries      Breakdown          FunnelReport   GoalReport
```

## The stack, and why

| Choice | Reason |
|---|---|
| **Rails 8** | The starter template this is built on; boring, fast enough, and the ingest path is a single controller action |
| **PostgreSQL 17 + TimescaleDB 2.29** | One database for both relational and timeseries data. Hypertables give chunked storage, columnar compression and retention policies; continuous aggregates give the dashboard sub-10 ms queries. No second datastore to operate |
| **Two Redis instances** | One persistent (ingest buffer, cache, Sidekiq). One **non-persistent** for the visitor salt and session map, because a salt written to disk is a salt that is not destroyed. See [../privacy/identity.md](../privacy/identity.md) |
| **Sidekiq** | Buffer flush, retention enforcement, reconciliation |
| **Hotwire + importmap, no npm** | A privacy tool should not ask users to load a bundle. Charts are server-rendered inline SVG; the only JavaScript is three small Stimulus controllers |
| **Tailwind v4** | CSS-first config, no JS build |

## Data model

Relational (ordinary Postgres tables):

```
Account ──┬── Membership ── User
          └── Site ──┬── Goal
                     ├── Funnel ── FunnelStep
                     └── SharedLink
```

`Site#public_token` is what goes in `data-site=`. It is deliberately **not** the
primary key: it appears in the HTML of every measured page, so it must not leak
row counts or be guessable into another tenant's data. 16 characters of a
32-symbol Crockford alphabet, about 1.2 × 10²⁴ possibilities.

Timeseries: `events`, a hypertable with no primary key. See
[aggregates.md](aggregates.md).

## Authorization

Every policy is handed an `AuthorizationContext` (user **and** the account they
are acting as) rather than a bare `User`. A user can belong to several accounts
with different roles, and a policy given only a user would have to re-derive the
account — which is the step that gets forgotten in one policy out of twelve and
becomes a cross-tenant leak.

`ApplicationPolicy::Scope#resolve` returns `scope.none`, not `scope.all`. A
subclass that forgets to override it shows an empty page — a bug someone reports
— rather than every tenant's data.

Roles, most to least privileged: `owner`, `admin`, `member`, `viewer`.
`Membership#at_least?(:admin)` relies on that ordering.

The riskiest endpoint is `SharedDashboardsController`: unauthenticated, and it
renders another tenant's statistics. It never reads an id or a domain from
params — only an unguessable 143-bit slug — and resolves the site *through* the
link, so the link is the sole authority on what is visible.

## Request paths

**Ingest** (`POST /api/event`) — answers 202 for everything, always. Whether we
accepted, dropped a bot, or did not recognise the token is not the browser's
business: a distinguishable response would let anyone probe which site tokens are
valid, and an error in a stranger's console on someone else's website is noise the
site owner cannot act on. Measured warm latency ~8 ms in development mode.

**Dashboard** (`GET /sites/:public_token`) — `Analytics::Dashboard` composes
Summary, Timeseries, eight Breakdowns, GoalReport and Realtime. Filter and period
state lives entirely in the URL, so a filtered dashboard is shareable and Turbo
Frames can refresh a panel by fetching a URL rather than holding client state.

## Where the interesting decisions are documented

- Why breakdowns scan raw events instead of an aggregate, and the rule about
  distinct counts → [aggregates.md](aggregates.md)
- Why the funnel query is a chain of CTEs rather than one `GROUP BY` →
  [funnels.md](funnels.md)
- Why the write path buffers in Redis and what that trades away →
  [ingest.md](ingest.md)
- Why the salt lives in a Redis with persistence disabled →
  [../privacy/identity.md](../privacy/identity.md)
- Why there is no `schema.rb` → [aggregates.md](aggregates.md) and
  [../../CLAUDE.md](../../CLAUDE.md)
