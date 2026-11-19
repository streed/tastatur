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
    # `Tastatur.cron_schedule`, not config/schedule.yml directly, because that is
    # what the Sidekiq server loads, so the two cannot drift: a job scheduled
    # somewhere nothing verifies is exactly the shape of the outage in this
    # file's header.
    let(:schedule) { Tastatur.cron_schedule }

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

    it "is loaded with the form that also REMOVES what this file no longer lists" do
      # The mirror image of every other assertion here, and the only one that
      # cannot be made by running anything: the schedule a worker obeys lives in
      # Redis, not in this repository. sidekiq-cron's plain `load_from_hash`
      # adds and updates but never deletes, so removing a job and its YAML entry
      # leaves it scheduled in production forever, firing a class that no longer
      # exists — `NameError: uninitialized constant RotateVisitorSaltJob`, weeks
      # after the deletion, with the constant nowhere in the tree to find.
      #
      # Asserting on the source because there is no other seam. Loading the
      # schedule for real needs a Sidekiq server and a Redis that survives the
      # example, and the bug is precisely that the wrong call raises nothing and
      # looks right.
      source = Rails.root.join("config/initializers/sidekiq.rb").read
                    .lines.reject { |line| line.match?(/\A\s*#/) }.join

      expect(source).to include("load_from_hash!"),
                        "config/initializers/sidekiq.rb must load the cron schedule with " \
                        "`load_from_hash!`. The non-bang form cannot unschedule a deleted job."
      expect(source).not_to match(/load_from_hash\(/),
                            "A bare `load_from_hash(` call leaves deleted jobs running in production."
    end

    it "guards the destructive load against an empty schedule" do
      # `load_from_hash!` destroys every cron entry not named in what it is
      # given, so handing it an empty hash unschedules the deployment. Empty
      # means the merge found no files, which is a deploy accident rather than
      # an instruction to stop running cron.
      source = Rails.root.join("config/initializers/sidekiq.rb").read

      expect(source).to match(/load_from_hash!\(schedule\) if schedule\.any\?/),
                        "The destructive load must stay guarded by `if schedule.any?`."
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
