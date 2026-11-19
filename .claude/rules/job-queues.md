---
paths:
  - "app/jobs/**/*.rb"
  - "spec/jobs/**/*.rb"
  - "config/sidekiq.yml"
  - "config/initializers/sidekiq.rb"
---

**Queue names are SLAs.** The four tiers, in strict priority order:

| Queue | For | What a backlog means |
|---|---|---|
| `within_5_seconds` | Transactional mail | Somebody is on the signup screen waiting |
| `within_30_seconds` | The measurement pipeline | Dashboards silently stop advancing |
| `within_5_minutes` | Erasure reconciliation, usage reconciliation | A written privacy or plan claim starts slipping |
| `within_1_hour` | Nightly bulk work: retention, subscription reconciliation | Nothing, which is the point |

Every queue you enqueue to must be listed in `config/sidekiq.yml`, which is what
a worker actually serves. This is not bookkeeping. `FlushEventBufferJob` once
declared `queue_as :ingest` with no `sidekiq.yml` present, and a bare
`bundle exec sidekiq` serves only `default` — so the job that moves buffered
events into PostgreSQL was enqueued every minute by cron and executed never.
Redis grew, dashboards froze, ingest kept answering 202, and nothing raised.

`spec/jobs/queue_names_spec.rb` compares job classes, the cron schedule, and the
framework defaults against that file, so the mismatch now fails a test instead of
silently losing data. Note that the test adapter runs jobs inline and never
consults a queue name, which is why no other spec could have caught it.
