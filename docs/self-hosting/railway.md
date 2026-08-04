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
| `SELF_HOSTED` | `1` for your own instance. `0` (or unset) runs the billed hosted service — see [Billing](#billing-only-if-self_hosted-is-not-1) below, and set the Stripe variables too |
| `ALLOW_SIGNUP` | `0` to keep an internet-exposed instance invite-only |
| `MAIL_FROM` | `no-reply@yourdomain.com` |
| `RESEND_API_KEY` | from Resend. Leave it unset and email is written to the log instead of sent, so confirmation links appear there in plain text — usable for a first boot, wrong to leave that way |
| `LEGAL_ENTITY`, `LEGAL_EMAIL`, `LEGAL_JURISDICTION` | see [configuration.md](configuration.md#legal-identity) |
| `LEGAL_UPDATED_ON` | `YYYY-MM-DD`, the date you last revised the policy and terms. Unset shows no date, which is better than the alternative it replaced: the pages used to render today's date and so claimed to have been revised daily |

Substitute the actual service names Railway assigned; the references above assume
`TimescaleDB`, `Redis` and `Redis-Privacy`.

### Billing, only if `SELF_HOSTED` is not `1`

Skip this entirely for your own instance. With `SELF_HOSTED=1` there are no plans,
no event or site limits, no upgrade interface, and Stripe is never contacted.

Leaving them unset on a deployment where `SELF_HOSTED` is not `1` is also safe: billing
stays off until all three of the variables it reads are present, so nobody is capped by
a limit they cannot pay to lift. The boot log says `BILLING IS DISABLED` and names what
is missing. Setting `SELF_HOSTED=1` is still better, because then it is deliberate
rather than merely harmless.

For the hosted service, four variables plus three things in the Stripe dashboard:

| Variable | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_…` |
| `STRIPE_PUBLISHABLE_KEY` | `pk_live_…`. Nothing reads it today — payment happens on Stripe's hosted Checkout, so this app renders no card form — but it is half of the pair every deployment expects to set |
| `STRIPE_WEBHOOK_SECRET` | `whsec_…`, from the endpoint you create below |
| `STRIPE_PRICE_PRO` | `price_…`, the recurring monthly price for the Pro plan |

In Stripe:

1. One product with a **recurring monthly** price matching `Billing::Plan::PRO`
   (currently $30). Copy its price id into `STRIPE_PRICE_PRO`.
2. A webhook endpoint at `https://YOUR_DOMAIN/billing/stripe/webhook`, subscribed to
   exactly the events in `Billing::ApplyStripeEvent::HANDLED`:
   `checkout.session.completed`, `customer.subscription.created`,
   `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`,
   `invoice.payment_failed`. Copy its signing secret into `STRIPE_WEBHOOK_SECRET`.
3. Enable the **customer portal** (Settings → Billing → Customer portal). It needs a
   saved configuration before `BillingPortal::Session.create` will succeed, so
   without it the "Billing portal" button returns an error rather than a page.

**`STRIPE_WEBHOOK_SECRET` is the one whose absence fails invisibly.** Without it the
webhook endpoint refuses every delivery with a 503, so a subscription is paid for and
never applied: Stripe shows the charge, the customer stays on the free plan, and
nothing raises. The app logs an error at boot for each missing variable it reads, and
`bin/rails tastatur:billing:verify` checks them deliberately — see step 7.

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
| `enforce_data_retention` | daily 03:23 | You hold data longer than you told people you would |
| `flush_event_buffer` | every minute | Events sit in Redis instead of PostgreSQL. The ingest path also triggers a flush on buffer size, so a busy site still writes; a quiet one stops recording |
| `reconcile_usage` | hourly at :13 | *Hosted only.* The monthly event counter enforcement reads drifts below reality, so published plan allowances quietly stop being the ones applied. Usage warning emails also stop |
| `reconcile_subscriptions` | daily 04:41 | *Hosted only.* A webhook Stripe gave up delivering is never noticed, so an account stays on a plan nobody is paying for — or a paying account stays capped |

The two billing jobs are no-ops when `SELF_HOSTED=1`; they return immediately.

Salt rotation is not in this table because it is not a job. Each site's salt is
keyed by that site's local date and expires on its own TTL, so it rolls over at
midnight in the site's timezone even if the cron service is down.

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

If you are running the hosted service, check the billing wiring too:

```bash
railway run --service <app> bin/rails tastatur:billing:verify
```

It confirms the keys are present and that the live Stripe price still costs what
`/pricing` publishes, in the same currency, recurring monthly. It exits non-zero when
something is wrong, so it is worth putting in a deploy hook. On `SELF_HOSTED=1` it
says there is nothing to verify and exits 0.

Then send Stripe a real event — the CLI is the quickest way — and confirm the
endpoint answers 200 rather than 400 or 503:

```bash
stripe trigger customer.subscription.updated --api-key sk_live_…
```

## Private customizations (editions)

You can keep your own code — a landing page of your own, an internal integration,
anything you would rather not publish — in a second, private repository and have
it built into the image alongside this one. That is what an *edition* is; see
CLAUDE.md §20 for the shape of one and what it may and may not touch. Skip this
section entirely if you are deploying Tastatur as it ships.

Set these as service variables on **both** the app and the worker service. The
Dockerfile declares a matching `ARG` for each, which is what makes Railway pass
them into a Docker build — Railpack does it automatically, Dockerfile builds do
not:

| Variable | Example | |
|---|---|---|
| `EDITION_REPO` | `you/tastatur-edition` | `owner/name`, cloned over HTTPS |
| `EDITION_REF` | a commit SHA, or `main` | see below — prefer the SHA |
| `EDITION_NAME` | `private` | becomes `editions/<name>` |
| `EDITION_TOKEN` | a fine-grained PAT | **seal this one** |

Give the token read-only Contents permission on that one repository and nothing
else. Seal it (Variables → ⋮ → Seal) so it cannot be read back out of the
dashboard afterwards; sealing changes visibility, not availability, and it still
reaches the build.

The token never reaches the image you run. It is declared in the throw-away
build stage, and the final stage copies only `/rails` and the bundle out of it,
so it is absent from both the shipped layers and their metadata. Do not lift
those `ARG` lines to the top of the Dockerfile to tidy them: an `ARG` before the
first `FROM` is in scope for every stage, including the one that ships.

**Both services need the variables**, because they are built from the same
Dockerfile and the worker runs the edition's jobs. A worker built without the
edition accepts its cron entries and runs none of them, which is the silent
failure `spec/jobs/queue_names_spec.rb` exists to catch, arriving by a route that
spec cannot see.

### Deploying a change to the private repository

A push to the private repository does not trigger anything by itself — Railway
watches this repository, and the edition is fetched during the build. `railway
redeploy` will not help either: it reuses the image that has already been built.

So pin `EDITION_REF` to a commit SHA and update the variable when you want the
new commit live. Setting it changes a build argument, which forces a rebuild, and
it has the better property besides: the variable says exactly which edition
commit is running, rather than "whatever `main` was at build time". From the
private repository's CI:

```bash
railway variables --set "EDITION_REF=$GITHUB_SHA" --service app --skip-deploys
railway variables --set "EDITION_REF=$GITHUB_SHA" --service worker
```

`--skip-deploys` on all but the last one, so the two services rebuild together
rather than the app deploying against the previous edition for a minute.

If you would rather not automate it, leave `EDITION_REF=main` and press Redeploy
after pushing — but know that two deploys of the same application commit can then
produce different images, which is exactly the thing that makes a bad deploy hard
to reason about.

### Verifying which edition is running

```bash
railway run --service app bin/rails runner 'puts Tastatur.features.to_a.inspect'
```

An empty list means the community edition: the clone did not happen, or happened
into the wrong path. The build fails loudly if `EDITION_REPO` is set and the
clone produced nothing, precisely so this cannot present as a healthy container
quietly serving the wrong landing page.

## Things that differ from the VPS instructions

| | VPS (`docker-compose.prod.yml`) | Railway |
|---|---|---|
| TLS | Caddy, bundled | Railway edge |
| Port | Caddy on 443 → app on 3000 | `PORT` → Thruster → Puma |
| Postgres | `timescale/timescaledb` image | TimescaleDB template |
| Non-persistent Redis | a service with no volume | a service with no volume |
| GeoIP | volume + download task | baked into the image |
| Worker | a compose service | a second Railway service |
| Migrations | entrypoint runs `db:prepare` | `preDeployCommand`, because Railway wraps the start command in a shell and the entrypoint's check never fires |
| Billing | usually off (`SELF_HOSTED=1`) | same, unless this *is* the hosted service |

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
