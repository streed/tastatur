Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  config.concurrency = Integer(ENV.fetch("SIDEKIQ_CONCURRENCY", 5))

  config.on(:startup) do
    # Merged across this repository and any editions, because an edition ships
    # jobs and a job with no cron entry is a job that never runs — the exact
    # failure spec/jobs/queue_names_spec.rb exists to prevent, arriving by a new
    # route. `Tastatur.cron_schedule` is also what that spec reads, so the two
    # cannot drift.
    schedule = Tastatur.cron_schedule
    Sidekiq::Cron::Job.load_from_hash(schedule) if schedule.any?
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
