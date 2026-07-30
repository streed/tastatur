RSpec.configure do |config|
  # `have_enqueued_job` and `perform_enqueued_jobs` in any spec type, not just
  # job specs. Several service specs assert on what a service enqueued, and one
  # needs to run the job to observe its effect.
  config.include ActiveJob::TestHelper

  # The test adapter, not Sidekiq. Specs assert that a job was ENQUEUED with the
  # right arguments, which is the contract the calling code is responsible for.
  # Whether Sidekiq then runs it is Sidekiq's concern, and pushing to a real
  # Redis queue from the suite would leak jobs between examples.
  #
  # Where a spec wants the job's effect, it calls `perform_now` explicitly.
  config.before do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
  end
end
