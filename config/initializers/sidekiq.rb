Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  config.concurrency = Integer(ENV.fetch("SIDEKIQ_CONCURRENCY", 5))

  config.on(:startup) do
    # A job with no cron entry is a job that never runs — the exact failure
    # spec/jobs/queue_names_spec.rb exists to prevent. `Tastatur.cron_schedule` is
    # also what that spec reads, so the two cannot drift.
    schedule = Tastatur.cron_schedule

    # THE BANG IS LOAD-BEARING: this file is not the schedule, Redis is.
    #
    # sidekiq-cron persists every entry it is given, and the plain
    # `load_from_hash` only ever adds and updates. Deleting a job and its YAML
    # entry therefore removes it from the repository and leaves it running in
    # production forever, firing against a class that no longer exists. That is
    # not hypothetical: `RotateVisitorSaltJob` was deleted in 3b53ba3 when salt
    # rotation became a property of the site-local date key rather than a job
    # (§13), and production went on raising `NameError: uninitialized constant
    # RotateVisitorSaltJob` on its schedule for weeks afterwards. Nothing here
    # was wrong — a grep for the constant across the whole repository finds
    # nothing, which is what makes the report so confusing to read.
    #
    # `load_from_hash!` calls `destroy_removed_jobs(schedule.keys)` first, so
    # the deploy that removes an entry is the deploy that stops it running. The
    # guard below is what makes that safe: an empty schedule means the merge
    # found no files to read, and destroying every cron entry on the strength of
    # that would silently unschedule the whole deployment.
    Sidekiq::Cron::Job.load_from_hash!(schedule) if schedule.any?
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
