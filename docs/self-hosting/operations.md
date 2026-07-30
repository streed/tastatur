# Operations

Backups, upgrades, and the one thing that will quietly break the privacy
guarantee if you get it wrong.

## What must never be backed up

**`redis-privacy` must not be backed up, snapshotted, or given a volume.**

That instance holds the rotating visitor salt. The claim that stored analytics
are unlinkable rests entirely on yesterday's salt being *destroyed* — and a salt
written into an AOF file, an RDB snapshot, or a filesystem-level volume backup is
not destroyed. It is sitting in a file, very likely inside the same backup set as
the events it would de-anonymise, and a point-in-time restore would bring it back
and silently invalidate every claim on your privacy page.

It ships configured with `--save "" --appendonly no` and declares **no volume**,
precisely so that a well-meaning "let's back up all the volumes" script has nothing
to capture. Please leave it that way.

The `redis` image itself declares `VOLUME /data`, so Docker attaches an anonymous
volume regardless and `docker volume ls` will show one. It is empty and stays
empty, since Redis is told never to write a snapshot or an append log. The
protection comes from persistence being off, so that is what to check:

```bash
docker compose exec redis-privacy sh -c 'ls -1 /data | wc -l'   # expect 0
docker compose exec redis-privacy redis-cli CONFIG GET appendonly
```

Losing that container costs you one session-timeout window of split visits.
That is the intended trade, and it is a much better failure mode than persisting
visitor state to disk.

If you set `REDIS_PRIVACY_URL` to your persistent Redis, the app logs a warning
at boot. Take the warning seriously; the guarantee is gone at that point and your
privacy page should stop claiming it.

## What to back up

Only PostgreSQL. Everything else is either derived or deliberately disposable.

```bash
docker compose -f docker-compose.prod.yml exec -T timescaledb \
  pg_dump -U postgres -Fc tastatur_production > tastatur-$(date +%F).dump
```

### Restoring is not just `pg_restore`

A dump of a TimescaleDB database does **not** round-trip cleanly. Restoring
requires bracketing the load so the extension does not try to manage the objects
while they are being created:

```sql
SELECT timescaledb_pre_restore();
-- run the restore here
SELECT timescaledb_post_restore();
```

Concretely:

```bash
docker compose -f docker-compose.prod.yml exec -T timescaledb \
  psql -U postgres -d tastatur_production -c "SELECT timescaledb_pre_restore();"

docker compose -f docker-compose.prod.yml exec -T timescaledb \
  pg_restore -U postgres -d tastatur_production --no-owner < tastatur-2026-07-29.dump

docker compose -f docker-compose.prod.yml exec -T timescaledb \
  psql -U postgres -d tastatur_production -c "SELECT timescaledb_post_restore();"
```

**Verify the restore actually produced hypertables**, because the failure mode is
silent — you get working ordinary tables and a dashboard that gradually gets
slower:

```sql
SELECT hypertable_name FROM timescaledb_information.hypertables;
-- expect: events

SELECT view_name, materialized_only
FROM timescaledb_information.continuous_aggregates;
-- expect: events_by_hour, visitor_days, session_days  (all materialized_only = false)

SELECT proc_name, hypertable_name FROM timescaledb_information.jobs
WHERE job_id > 999;
-- expect refresh, retention and compression policies
```

If the aggregates are missing or `materialized_only` is `true`, stop and
investigate rather than carrying on.

All three queries above were run against a live TimescaleDB 2.29 instance and return
exactly what is described, so a difference is a real problem with your restore
rather than a stale document.

**Then check the aggregates contain something.** A continuous aggregate can restore
as an empty shell: the view exists, the policy exists, and there is no materialised
data behind it. The dashboard then reads zero for every period older than the first
refresh, which looks like data loss and is recoverable.

```sql
SELECT (SELECT count(*) FROM events_by_hour) AS hours,
       (SELECT count(*) FROM visitor_days)   AS visitor_days,
       (SELECT count(*) FROM session_days)   AS session_days;
-- all three should be non-zero for any instance with history
```

If they are empty but `events` is not, refresh them rather than restoring again:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails runner \
  'Analytics::ReconcileAggregates.call(from: 2.years.ago, to: Time.current)'
```

**Do not restore the salt Redis, and check that you have not.** It is excluded from
backups by design, so there should be nothing to restore — but if a snapshot of it
exists somewhere and gets put back, every visitor hash it covers becomes linkable
again and the unlinkability claim on your privacy page stops being true for that
window. After any restore:

```bash
docker compose -f docker-compose.prod.yml exec redis-privacy sh -c 'ls -1 /data | wc -l'
# expect 0
```

A fresh salt is generated on first use, so an empty privacy Redis after a restore is
the correct outcome, not a problem to fix.

## Upgrading

```bash
git pull
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
```

`web` runs `db:prepare` on boot. Because there is no schema file, that means "run
pending migrations", which is exactly what you want.

Before a major upgrade, take a dump. Migrations that touch the hypertable are
written idempotently but a chunk drop is not reversible.

### Never run `db:schema:load` or `db:reset` against production

There is no schema file, so at best they are no-ops. The reason the file does not
exist is that a schema dump of this database is actively dangerous: it produces
ordinary tables instead of hypertables and plain views instead of continuous
aggregates, with nothing raising an error. See
[../architecture/aggregates.md](../architecture/aggregates.md#migrations-and-why-there-is-no-schema-file).

## Monitoring

`GET /up` returns 200 when PostgreSQL and **both** Redis instances answer, and
503 otherwise, with a per-check breakdown:

```json
{"status":"ok","version":"0.1.0",
 "checks":{"database":"ok","redis":"ok","redis_privacy":"ok"}}
```

The check reports exception **class names**, never messages, because a connection
error message can contain hostnames and credentials and this endpoint is usually
public.

### The job worth alerting on

It is in `config/schedule.yml` and it is load-bearing for a promise on your
privacy page, not merely housekeeping:

| Job | If it stops |
|---|---|
| `enforce_data_retention` (daily 03:23) | You hold data longer than you told people you would |

Salt rotation is **not** on this list, and used to be. It is no longer a job at
all: each site's salt is keyed by that site's local date and retires on its own
TTL, so it rolls over at midnight in the site's timezone whether or not cron is
healthy. That is deliberate — the old nightly job failing produced no error and no
visible symptom, while the product quietly stopped being anonymous.

The Sidekiq web UI at `/sidekiq` (admin users only) shows the cron schedule and
last-run times.

`flush_event_buffer` runs every minute as a backstop; the ingest path also
enqueues it whenever the buffer passes its size threshold, so on a busy site the
cron run usually finds an empty buffer.

## Queues, and what to alert on

Queues are named for the latency they promise rather than for the work they carry,
which means the alert is the same for all of them: **queue latency above the number
in the name.** No per-queue thresholds to maintain, and a name that tells you the
severity.

| Queue | Carries | Symptom of a backlog |
|---|---|---|
| `within_5_seconds` | Confirmation, reset and invitation email | New signups conclude the product is broken |
| `within_30_seconds` | The event-buffer flush, first-data email | Dashboards stop advancing while ingest keeps accepting. Redis memory climbs |
| `within_5_minutes` | Post-erasure aggregate reconciliation, usage reconciliation | Privacy claims start slipping. Deleted data may still appear in reports |
| `within_1_hour` | Retention deletion | Nothing urgent, which is why it is last |

They are served in the order listed, strictly: the worker empties
`within_5_seconds` before looking at `within_30_seconds`, and so on. So a
permanently saturated fast queue will starve the slow ones — if retention stops
running, check whether the flush queue is keeping a worker permanently busy before
assuming the retention job itself is broken.

Check depth and latency:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails runner '
  require "sidekiq/api"
  Sidekiq::Queue.all.each { |q| puts "#{q.name}: #{q.size} jobs, #{q.latency.round(1)}s latency" }'
```

**A queue that is deep and has zero workers is the failure to look for first.** If
`config/sidekiq.yml` and a job disagree about the queue name, the job is enqueued
to a queue nothing serves: it accumulates forever, runs never, and raises nothing.
That exact bug shipped once and stopped every event from reaching PostgreSQL. The
process list should show all four names:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails runner '
  require "sidekiq/api"
  Sidekiq::ProcessSet.new.each { |p| puts p["queues"].inspect }'
```

## Useful commands

```bash
# Watch everything
docker compose -f docker-compose.prod.yml logs -f web worker

# Console
docker compose -f docker-compose.prod.yml exec web bin/rails console

# Is geolocation configured?
docker compose -f docker-compose.prod.yml exec web bin/rails tastatur:geoip:status

# Enforce retention now rather than waiting for tonight
docker compose -f docker-compose.prod.yml exec web bin/rails tastatur:privacy:enforce_retention

# Sever every stored identifier immediately (incident response)
docker compose -f docker-compose.prod.yml exec web bin/rails tastatur:privacy:purge_salts

# How much is the buffer holding right now?
docker compose -f docker-compose.prod.yml exec web \
  bin/rails runner 'puts Ingest::WriteBuffer.depth'
```

## Storage housekeeping

Per-account retention uses `DELETE`, which leaves dead tuples for autovacuum
rather than reclaiming space immediately. The global chunk-drop policy is what
keeps total storage bounded. To see where space is going:

```sql
SELECT hypertable_name,
       pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes)  AS after
FROM hypertable_compression_stats('events');
```

If a site was deleted and you expect space back, note that
`Sites::Delete` issues a `DELETE` on the events table rather than dropping
chunks — chunks hold every site's rows, so they cannot be dropped per-tenant.
The space returns after autovacuum.

## Administrators, and what they can and cannot see

`admin` on a user is the **instance** operator flag. It is deliberately not the
same thing as being an admin *of* an account — that is a membership role, set
per-account from the team screen, and it confers nothing over the instance.

```bash
bin/rails tastatur:admin:list
bin/rails 'tastatur:admin:grant[you@example.com]'
bin/rails 'tastatur:admin:revoke[them@example.com]'
```

Or declaratively, which is what a deployment should prefer: set `ADMIN_EMAILS`
to a comma-separated list and run `tastatur:admin:sync` from your deploy step
(the Railway config already does). It is idempotent and **only ever grants**.
Revoking from an env var would mean a typo, or a variable that failed to load,
silently locking every administrator out of the console you would go to in order
to fix it. Somebody listed who has not signed up yet is picked up by a later run.

Neither the console nor the rake task will remove the **last** administrator, and
nobody can remove their own flag. An instance with zero administrators can only be
recovered from a shell on the server.

### What /admin shows

Instance operations: user and account counts, signups, event volume, which sites
are still waiting for their first event, queue depths, and whether the salt,
GeoIP database and write buffer are healthy. Support actions on a person —
confirm an address, unlock an account, resend a confirmation, send a password
reset.

### What it deliberately does not

- **No customer measurement data.** Sites are listed, never opened.
  `Admin::SitePolicy#show?` returns `false`, so a link into someone's dashboard
  cannot be added by accident. What a site measured belongs to that customer's
  audience, and `/dpa` commits to not using it for our own purposes — a support
  console rendering somebody's top pages would make that a sentence needing
  qualification.
- **No impersonation, and no setting a password.** Either would hand an operator
  every dashboard on the instance. The reset action emails a token to the address
  on file, so the person who can use it is the person who owns the mailbox.
- **No sign-in IP.** Devise's trackable does store it, and
  `docs/privacy/claims.md` is explicit that it exists so a *customer* can notice a
  sign-in that was not theirs. That is a reason for them to see it, not a reason
  for an operator to browse it.

Administrative actions are written to the log with the administrator's address,
so "who unlocked this account" has an answer that does not rely on memory.
