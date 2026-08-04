require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# --- Editions ---------------------------------------------------------------
#
# This repository is the community edition, and it is complete: everything below
# this line runs, and every spec in this repository passes, with no editions/
# directory present at all. That is the property to preserve when editing here.
#
# An edition is a Rails engine in editions/<name>, kept in its own repository and
# ignored by this one (see .gitignore). It contributes controllers, views,
# routes, migrations and cron entries the way any engine does, so nothing here
# has to know what is in one. The hosted service loads editions/private, which
# holds the marketing site and the waitlist — the parts that describe and sell
# *our* deployment rather than the parts that measure *a* website.
#
# The extension points an edition may use are deliberately few and each is
# documented where it lives, not here:
#
#   Tastatur.enable_feature      the predicates below (marketing_site?, …)
#   Seo::BuildSitemap.register   an edition's literal URL list
#   Seo::BuildStructuredData     .register_page / .register_offers
#   EditionHelper#edition_partial a view slot that renders nothing when empty
#   config/schedule.yml          merged from editions by the sidekiq initializer
#
# Loaded HERE, before the application class, because a Rails::Engine subclass has
# to exist before the application is initialized for its railtie hooks to run at
# all. `sort` so two editions load in a defined order rather than whatever order
# the filesystem happens to return.
Dir[File.expand_path("../editions/*/lib/edition.rb", __dir__)].sort.each do |edition|
  require edition
end

module Tastatur
  class Application < Rails::Application
    config.active_job.queue_adapter = :sidekiq
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # --- Queue names are SLAs -------------------------------------------------
    #
    # Every queue named here must appear in config/sidekiq.yml, which is the list
    # a worker actually serves. A queue that is enqueued to but not served accepts
    # jobs forever and runs none of them, raising nothing; that is not a
    # hypothetical, it is how the event-buffer flush came to be scheduled every
    # minute and executed never. spec/jobs/queue_names_spec.rb fails if the two
    # files disagree.
    #
    # The fail-safe default. A job that forgets `queue_as` lands here and runs
    # late rather than vanishing. Under Rails 8 defaults this would otherwise be
    # "default", which is not a tier and therefore not served at all.
    config.active_job.default_queue_name = "within_5_minutes"

    # Transactional mail: confirmations, password resets, invitations. Rails 8
    # leaves this nil, which routes mail to the default queue above — survivable
    # but wrong, because these are the jobs with a person waiting on them.
    config.action_mailer.deliver_later_queue_name = "within_5_seconds"

    # First in the stack, so a malformed ingest query string is neutralised before
    # Rack::Attack's throttle blocks or ActionController's instrumentation try to
    # parse it. Both do so outside anything a controller can rescue. See the
    # class for the full explanation.
    require_relative "../lib/middleware/sanitize_ingest_query"
    config.middleware.unshift Middleware::SanitizeIngestQuery

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks middleware mail_delivery tracker])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # --- Schema management -------------------------------------------------
    #
    # We deliberately keep NO schema file. This is not laziness; a schema dump
    # of a TimescaleDB database is actively dangerous.
    #
    # `pg_dump --schema-only` does not emit `create_hypertable(...)`, does not
    # emit `WITH (timescaledb.continuous)`, and does not emit retention or
    # columnstore policies. A continuous aggregate dumps as a plain `CREATE
    # VIEW`. So loading a dumped schema yields a database that *works but is
    # silently wrong*: ordinary tables instead of hypertables, and views that
    # re-scan raw events with no materialization at all. Nothing raises. You
    # find out when production gets slow.
    #
    # Migrations are therefore the single source of truth, and every
    # environment — development, test, CI, and a fresh production install —
    # is built by running them. Timescale DDL in migrations is written
    # idempotently so re-running is safe. See db/migrate and CLAUDE.md.
    config.active_record.dump_schema_after_migration = false
    config.active_record.maintain_test_schema = false
  end
end
