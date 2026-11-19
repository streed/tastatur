# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# We keep no schema file — a pg_dump of a TimescaleDB database silently loses
# hypertables and turns continuous aggregates into plain views (see
# config/application.rb). So `maintain_test_schema!` has nothing to load and is
# disabled; instead we bring the test database up to date by running the
# migrations themselves, which are the single source of truth.
if ActiveRecord::Base.connection_pool.migration_context.needs_migration?
  puts "[tastatur] Test database has pending migrations — running them..."
  ActiveRecord::Tasks::DatabaseTasks.migrate
  ActiveRecord::Base.connection_pool.schema_cache.clear!
end

RSpec.configure do |config|
  # `create(:site)` rather than `FactoryBot.create(:site)` in every example.
  config.include FactoryBot::Syntax::Methods

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # TimescaleDB refuses to refresh a continuous aggregate inside a transaction:
  #
  #   ERROR: refresh_continuous_aggregate() cannot run inside a transaction block
  #
  # So any spec that needs materialized aggregate data must opt out of the
  # surrounding transaction and clean up by truncation instead. Tag it:
  #
  #   it "rolls up visitors", :continuous_aggregate do
  #
  # The suite assumes it starts from an empty database, and nothing guaranteed
  # that. `bin/dev-setup` builds the test database with `db:prepare`, which seeds
  # a database it has just created — and db/seeds.rb runs in any local env, so a
  # fresh checkout began every run with admin@example.com committed. The specs
  # that count administrators then failed until the first `:continuous_aggregate`
  # example happened to truncate the seeds away mid-run, which made the failures
  # a function of the random seed and unreproducible afterwards. Truncating up
  # front makes the starting state a property of the suite rather than of
  # whatever `db:prepare`, an aborted run, or a stray `rails runner` left behind.
  config.before(:suite) { Tastatur::TestDatabase.truncate! }

  # The flag is restored afterwards because it is set on the example *group*, not
  # on the example. Leaving it false means every later example in that group — and
  # in any group nested inside it — also runs without a transaction, while only the
  # tagged ones truncate. Their rows then survive into the rest of the suite, and
  # what fails is some unrelated example that counted on an empty table
  # (`User.administrators.count`, `Tastatur.needs_first_run_setup?`), on some seeds
  # and not others.
  config.around(:example, :continuous_aggregate) do |example|
    was_transactional = self.class.use_transactional_tests
    self.class.use_transactional_tests = false
    example.run
    Tastatur::TestDatabase.truncate!
    self.class.use_transactional_tests = was_transactional
  end

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
