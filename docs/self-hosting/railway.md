# Deploying to Railway

Tastatur needs four services on Railway: the app, a worker, PostgreSQL **with the
TimescaleDB extension**, and two Redis instances. The second Redis is not
redundancy; it is a deliberate part of the privacy design and is configured
differently from the first.

Total: five services. Two of them are not Railway defaults, and this page is
mostly about those two.

---

## 1. PostgreSQL with TimescaleDB

**Railway's standard PostgreSQL will not work.** Tastatur's events table is a
hypertable with three continuous aggregates, so the `timescaledb` extension has to
be present. Railway's default Postgres does not have it, and it cannot be added
with `CREATE EXTENSION` because the extension has to be in
`shared_preload_libraries`.

Deploy a TimescaleDB template instead. Railway has several; any of these works,
provided it is **PostgreSQL 17 or newer with TimescaleDB 2.18 or newer**:

- [TimescaleDB](https://railway.com/deploy/timescaledb)
- [TimescaleDB + PostGIS (PG17)](https://railway.com/deploy/ZZURpX)
- [PostgreSQL 18 + TimescaleDB + PostGIS](https://railway.com/deploy/postgresql-18-timescaledb-postgis)

PostGIS is not used by Tastatur; those templates are simply the better-maintained
ones. The 2.18 floor is enforced by the first migration, which refuses to run on
anything older, because later migrations use the columnstore API introduced there.

Verify after deploying, from the Railway shell on the database service:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
-- expect 2.18 or higher
```

If that returns no rows, you deployed plain Postgres. Stop and redeploy the
correct template; migrating later means dumping and restoring, which
[has its own procedure](operations.md#restoring-is-not-just-pg_restore).

### If you deploy the image directly instead of a template

Perfectly reasonable — it pins the version you tested against. Add a service from
the Docker image `timescale/timescaledb:latest-pg17`, set `POSTGRES_USER`,
`POSTGRES_PASSWORD` and `POSTGRES_DB`, attach a volume at
`/var/lib/postgresql/data`, and then set one more variable that is not obvious:

```
PGDATA=/var/lib/postgresql/data/pgdata
```

**Without it the database never initialises.** A Railway volume is a mount point and
arrives containing a `lost+found` directory, so `initdb` refuses:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
initdb: detail: It contains a lost+found directory, perhaps due to it being a mount point.
initdb: hint: Using a mount point directly as the data directory is not recommended.
           Create a subdirectory under the mount point.
```

Postgres then crash-loops while Railway reports the *deployment* as successful,
because the container is running. The symptom you actually see is the app service
timing out its health check with a connection error to the database. Railway's own
managed Redis template solves the same problem the other way, with
`rm -rf $RAILWAY_VOLUME_MOUNT_PATH/lost+found/` in its start command; the `PGDATA`
subdirectory is the cleaner fix and is what `initdb` itself recommends.

## 2. Redis (persistent)

A standard Railway Redis. This holds the ingest buffer, the cache and the Sidekiq
queue, all of which should survive a restart.

## 3. Redis (NON-persistent) — the important one

Add a **second** Redis service, deployed from the `redis:7-alpine` Docker image
with a custom start command and, critically, **no volume attached**:

```
redis-server --save "" --appendonly no --maxmemory-policy noeviction
```

This one holds the rotating visitor salt and the session map, and nothing else.

Persistence is off on purpose. The claim that stored analytics are unlinkable
rests on yesterday's salt being *destroyed* — and a salt written into an AOF file
or an RDB snapshot is not destroyed. It sits on disk, very likely inside a
backup, next to the events it would de-anonymise, and a restore brings it back.

**Do not attach a volume to this service.** Losing it costs one session-timeout
window of split visits, which is the intended trade. See
[../privacy/identity.md](../privacy/identity.md).

If you point `REDIS_PRIVACY_URL` at the persistent Redis instead, the app logs a
warning at boot and the unlinkability claim on your privacy page stops being true.

## 4. The app service

Point a new service at this repository. `railway.toml` is committed, so the build
method, start command and health check are already configured.

The image bakes in the country database at build time, so geolocation works with
no volume and no post-deploy step.

### Railway does not run the Docker ENTRYPOINT

This is the single thing most likely to cost you an afternoon, because it produces
two failures that look unrelated and neither error message mentions the cause.

When a service has a custom start command, Railway runs it directly instead of
through the image's `ENTRYPOINT`. `bin/docker-entrypoint` therefore never executes,
and it is doing two jobs:

| What the entrypoint does | What happens on Railway | How it presents |
|---|---|---|
| Bridges `PORT` to Thruster's `HTTP_PORT` | Never runs, so Thruster stays on `:80` | Health check fails against a port nothing is listening on. Logs show a clean, healthy boot |
| Runs `db:prepare` before the server | Never runs, so the database has no schema | `/up` returns 503 because its database check fails, the deploy is torn down, and the edge answers `Application not found` |

Both are already handled for you in the committed configuration:

- `railway.toml` sets `preDeployCommand = "bin/rails db:prepare"`, which is the
  better mechanism anyway — it runs once per deployment before traffic shifts,
  rather than once per replica at boot.
- Set `HTTP_PORT` explicitly as a variable. Thruster reads it directly, so nothing
  has to bridge anything. `HTTP_PORT=8080` is fine; any port works as long as it is
  the one Railway routes to.

If you ever see the app boot cleanly in the logs and still fail its health check,
check which port Thruster reported (`Server started ... http=":80"`) against what
Railway is probing. That mismatch is this bug.

### Variables

Use Railway's variable references so a rotated database password propagates
without editing anything:

| Variable | Value |
|---|---|
| `DATABASE_URL` | `${{TimescaleDB.DATABASE_URL}}` |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` |
| `REDIS_PRIVACY_URL` | `${{Redis-Privacy.REDIS_URL}}` |
| `SECRET_KEY_BASE` | generate with `openssl rand -hex 64` |
| `HTTP_PORT` | `8080`. Thruster reads this directly. Required because Railway skips the entrypoint that would otherwise bridge `PORT` — see above |
| `APP_HOST` | your public domain, e.g. `analytics.example.com` |
| `RAILS_ENV` | `production` |
| `RAILS_LOG_TO_STDOUT` | `1` |
| `RAILS_MAX_THREADS` | `5` (see the pool note below) |
| `SELF_HOSTED` | `1` unless you are running the billed hosted service |
| `ALLOW_SIGNUP` | `0` to keep an internet-exposed instance invite-only |
| `MAIL_FROM` | `no-reply@yourdomain.com` |
| `RESEND_API_KEY` | from Resend. Leave it unset and email is written to the log instead of sent, so confirmation links appear there in plain text — usable for a first boot, wrong to leave that way |
| `LEGAL_ENTITY`, `LEGAL_EMAIL`, `LEGAL_JURISDICTION` | see [configuration.md](configuration.md#legal-identity) |
| `LEGAL_UPDATED_ON` | `YYYY-MM-DD`, the date you last revised the policy and terms. Unset shows no date, which is better than the alternative it replaced: the pages used to render today's date and so claimed to have been revised daily |

Substitute the actual service names Railway assigned; the references above assume
`TimescaleDB`, `Redis` and `Redis-Privacy`.

### Leave these alone

Variables that appear in `.env.production.example` and should **not** be set on
Railway, because the defaults are already right and changing them breaks things:

| Variable | Why not |
|---|---|
| `ASSUME_SSL`, `FORCE_SSL` | Both default to `1`, which is correct: Railway's edge terminates TLS, so the app sees plain HTTP inside an HTTPS request. Setting `ASSUME_SSL=0` here marks session cookies `secure` over a connection Rails believes is insecure, and nobody can stay signed in |
| `APP_DOMAIN` | Only used by the bundled Caddy to request a certificate. Railway issues its own |
| `POSTGRES_PASSWORD` | Only used by the Postgres container in `docker-compose.prod.yml`. Railway's template supplies `DATABASE_URL` directly |

Genuinely optional: `LEGAL_ADDRESS` and `LEGAL_DPO_EMAIL` (shown only if set),
and `SENTRY_DSN` (error reporting is simply off without it).

`RAILS_MAX_THREADS` sets both Puma's thread count and the ActiveRecord pool
(`database.yml` maps it to `max_connections`), so they cannot drift apart. Keep it
at or below what your database plan allows per connection.

## 5. The worker service

Sidekiq runs three jobs that matter, so this is not optional. Add a second
service on the same repository:

- **Start command:** `bundle exec sidekiq`. No queue flags: `config/sidekiq.yml`
  lists the four queues and their priority order, and passing `-q` on the command
  line would silently override it.
- **Config-as-code file:** set it to `railway.worker.toml`. In Railway this is
  Settings → Config-as-code on the worker service.

  **This one is not optional and the failure is quiet.** Both services build from
  the same repository, and `railway.toml` — which Railway picks up by default —
  declares `startCommand = "./bin/thrust ./bin/rails server"`. Config as code
  overrides per-service settings, so without pointing the worker at its own file
  it comes up as a *second web server*: Sidekiq running nowhere, cron firing into
  an empty room, and buffered events never reaching PostgreSQL. Both services show
  green. What you observe is a dashboard that works and numbers that never move,
  which is about the hardest symptom to trace back to its cause.

  `railway.worker.toml` is committed alongside `railway.toml` for exactly this.
- **No health check.** It serves no HTTP and Railway would fail the deploy waiting
  for a port that never opens.
- **Same variables as the app**, Railway shared variables being the tidy way, plus
  the one override below.

### `DB_STATEMENT_TIMEOUT=0` on the worker, and only the worker

**Set this or the worker will be broken in a way that takes months to notice.**

`config/database.yml` caps every statement at 15 seconds so one expensive dashboard
query cannot hold a connection indefinitely. That is right for the app and wrong for
the worker: `refresh_continuous_aggregate` over a wide window and the nightly
retention delete across compressed chunks both run for minutes by design. With the
cap in place they are cancelled part-way, which means aggregates are left
unreconciled after an erasure — data a person asked to have deleted keeps appearing
in reports — and retention silently stops enforcing the window on your privacy page.

The bundled `docker-compose.prod.yml` sets this on the worker service for you.
Railway's worker is a separate service, so it has to be set there by hand.

| Variable | Value | Where |
|---|---|---|
| `DB_STATEMENT_TIMEOUT` | `0` | **worker service only** |

Leave it unset on the app service, where the 15-second default is the point.

What it runs:

| Job | Schedule | Consequence if it stops |
|---|---|---|
| `rotate_visitor_salt` | daily 04:07 | Stored data quietly stops being unlinkable. Nothing errors, and your privacy page becomes inaccurate |
| `enforce_data_retention` | daily 03:23 | You hold data longer than you told people you would |
| `flush_event_buffer` | every minute | Events sit in Redis instead of PostgreSQL. The ingest path also triggers a flush on buffer size, so a busy site still writes; a quiet one stops recording |

The first two are worth alerting on rather than retrying quietly.

## 6. Domain and the tracker

Add your custom domain in Railway. TLS is issued automatically, and the bundled
`Caddyfile` and `docker-compose.prod.yml` are **not used on Railway** — they exist
for a plain-VPS deploy.

Set `APP_HOST` to the same domain so the installation screen shows the right
snippet and mailer links resolve.

Then confirm the tracker is reachable cross-origin, which is the one thing a
misconfigured proxy breaks:

```bash
curl -I https://your-domain/t.js
# expect 200 and Access-Control-Allow-Origin: *

curl -X POST https://your-domain/api/event \
  -H 'Content-Type: text/plain' \
  -H 'User-Agent: Mozilla/5.0 (Macintosh) Chrome/131.0.0.0' \
  -d '{"s":"YOUR_SITE_KEY","u":"https://example.com/"}'
# expect 202
```

A 202 is returned for accepted, rejected and rate-limited requests alike, so
confirm the event actually arrived by checking the dashboard rather than by
trusting the status code.

## 7. Verify the deploy

```bash
curl https://your-domain/up
```

```json
{"status":"ok","version":"0.1.0",
 "checks":{"database":"ok","redis":"ok","redis_privacy":"ok"}}
```

If `redis_privacy` reports an error, ingest cannot compute a visitor identity and
every event will be dropped. Fix that before adding the snippet to a real site.

On first visit you land on the first-run setup screen, which creates the owner
account and your first site. It is reachable only while the database has no users,
so it closes itself.

## Things that differ from the VPS instructions

| | VPS (`docker-compose.prod.yml`) | Railway |
|---|---|---|
| TLS | Caddy, bundled | Railway edge |
| Port | Caddy on 443 → app on 3000 | `PORT` → Thruster → Puma |
| Postgres | `timescale/timescaledb` image | TimescaleDB template |
| Non-persistent Redis | a service with no volume | a service with no volume |
| GeoIP | volume + download task | baked into the image |
| Worker | a compose service | a second Railway service |
| Migrations | entrypoint runs `db:prepare` | same |

## Trusted proxies

`request.remote_ip` feeds both the visitor hash and the country lookup, so it has
to be right. Railway's proxy sets `X-Forwarded-For` and sits in a private range,
which Rails trusts by default, so this needs no configuration.

Do **not** widen `trusted_proxies` to a public range: anything you trust can then
set its own client address, which would let a visitor choose their own identity.

## Backups

Railway's TimescaleDB templates provide volume backups. Note that a logical
`pg_dump` of a TimescaleDB database does **not** round-trip cleanly without
`timescaledb_pre_restore()` / `timescaledb_post_restore()`, and that restoring it
wrongly produces ordinary tables instead of hypertables with **no error**. The
procedure, and how to verify a restore actually worked, is in
[operations.md](operations.md#restoring-is-not-just-pg_restore).

**Never back up the non-persistent Redis.** That is the whole point of it.
