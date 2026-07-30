require "rails_helper"

# The spec that exists because of a silent outage.
#
# `FlushEventBufferJob` declared `queue_as :ingest`. No `config/sidekiq.yml`
# existed, and a bare `bundle exec sidekiq` serves only the `default` queue. So
# cron enqueued the job that moves buffered events from Redis into PostgreSQL
# every single minute, and a worker executed it never. Redis grew without bound,
# the dashboard stopped advancing while ingest cheerfully kept answering 202, and
# nothing anywhere raised. Every other spec in this suite passed, because the test
# adapter runs jobs inline and never consults a queue name at all.
#
# That is the failure this file makes impossible: an enqueue target that no worker
# serves. It compares the three places a queue name can be written — job classes,
# the cron schedule, and the framework defaults — against the one file that
# decides what is actually served.
RSpec.describe "Queue names" do
  # The single source of truth: what a worker will pull from.
  SERVED_QUEUES = begin
    config = YAML.safe_load(Rails.root.join("config/sidekiq.yml").read, permitted_classes: [Symbol])
    # Sidekiq accepts either key. Read both so switching styles cannot silently
    # empty this list and turn every assertion below into a no-op.
    (config["queues"] || config[:queues]).map(&:to_s).freeze
  end

  it "declares a non-empty, ordered SLA ladder" do
    expect(SERVED_QUEUES).to eq(%w[within_5_seconds within_30_seconds within_5_minutes within_1_hour])
  end

  it "names every queue for a latency rather than for a subject" do
    # `ingest` and `default` are the names this scheme replaced. A subject-matter
    # name gives no answer to "what breaks if this backs up", which is the only
    # question that matters when a queue is deep.
    expect(SERVED_QUEUES).to all(match(/\Awithin_\d+_(seconds?|minutes?|hours?)\z/))
  end

  describe "every job class" do
    # Eager load so descendants are all present; in development only the jobs that
    # have been referenced would be.
    before { Rails.application.eager_load! }

    it "enqueues to a queue that a worker serves" do
      offenders = ApplicationJob.descendants.reject do |klass|
        SERVED_QUEUES.include?(klass.new.queue_name.to_s)
      end.map { |klass| "#{klass}: #{klass.new.queue_name}" }

      expect(offenders).to be_empty,
                           "These jobs enqueue to a queue no worker serves, so they will never run: " \
                           "#{offenders.join(", ")}. Add the queue to config/sidekiq.yml or move the job."
    end

    it "covers all five jobs, so this spec cannot pass by finding nothing" do
      expect(ApplicationJob.descendants.size).to be >= 5
    end
  end

  describe "the cron schedule" do
    let(:schedule) { YAML.safe_load(Rails.root.join("config/schedule.yml").read) }

    it "enqueues to queues a worker serves" do
      offenders = schedule.filter_map do |name, entry|
        queue = entry["queue"].to_s
        "#{name} -> #{queue}" unless SERVED_QUEUES.include?(queue)
      end

      expect(offenders).to be_empty,
                           "Cron entries targeting an unserved queue: #{offenders.join(", ")}"
    end

    it "agrees with the queue each job class declares" do
      # A cron entry's `queue:` overrides the class's `queue_as`, so the two
      # disagreeing means one of them is a lie about where the work goes.
      disagreements = schedule.filter_map do |name, entry|
        declared = entry.fetch("class").constantize.new.queue_name.to_s
        scheduled = entry["queue"].to_s
        "#{name}: schedule says #{scheduled}, #{entry["class"]} says #{declared}" unless declared == scheduled
      end

      expect(disagreements).to be_empty, disagreements.join("; ")
    end
  end

  describe "framework defaults" do
    it "sends transactional mail to the tightest tier" do
      # nil here means "the ActiveJob default queue", which under Rails 8 defaults
      # is `default` — a queue this application does not serve. Mail would be
      # accepted and never delivered.
      expect(ActionMailer::Base.deliver_later_queue_name.to_s).to eq("within_5_seconds")
      expect(SERVED_QUEUES).to include(ActionMailer::Base.deliver_later_queue_name.to_s)
    end

    it "gives a job that forgets queue_as a served home" do
      expect(SERVED_QUEUES).to include(ActiveJob::Base.default_queue_name.to_s)
    end

    it "fails safe rather than fast for a forgotten queue_as" do
      # Deliberately not the top tier: a job whose author did not think about
      # latency should not be able to jump ahead of one whose author did.
      expect(ActiveJob::Base.default_queue_name.to_s).not_to eq(SERVED_QUEUES.first)
    end
  end
end
