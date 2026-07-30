require "rails_helper"

# db/seeds.rb creates admin@example.com / password with admin = true, and this is
# a public repository, so those are published credentials.
#
# `bin/rails db:prepare` seeds a database it has just created, and
# `bin/docker-entrypoint` runs `db:prepare` on boot. So every fresh production
# deployment came up with a known administrator who could reach /sidekiq. Measured
# before the fix by running db:prepare against an empty database with
# RAILS_ENV=production: both users were created, no warning anywhere.
#
# Two independent guards, and a spec for each, because either one being edited away
# should not be enough to bring the hole back.
RSpec.describe "Seeds" do
  describe "the environment guard in db/seeds.rb" do
    it "refuses to run in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { load Rails.root.join("db/seeds.rb").to_s }
        .to raise_error(SystemExit)
        .and output(/Refusing to seed in production/).to_stderr
    end

    it "refuses to run in staging or any other non-local environment" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))

      expect { load Rails.root.join("db/seeds.rb").to_s }.to raise_error(SystemExit)
    end

    it "still runs in development and test" do
      # `local?` is the whole condition, so this asserts the guard has not been
      # tightened into uselessness — seeds that never run are not seeds.
      expect(Rails.env.local?).to be(true)
    end
  end

  describe "the seeds: false guard in config/database.yml" do
    let(:config) do
      YAML.safe_load(
        ERB.new(Rails.root.join("config/database.yml").read).result,
        aliases: true
      )
    end

    # ActiveRecord::Tasks::DatabaseTasks.prepare_all only seeds when
    # `db_config.seeds?`, so this stops db:prepare before seeds.rb is even loaded.
    it "disables seeding for the production database" do
      expect(config.dig("production", "seeds")).to be(false)
    end

    it "leaves development and test seedable" do
      expect(config.dig("development", "seeds")).to be_nil
      expect(config.dig("test", "seeds")).to be_nil
    end

    # The template left `username: tastatur` behind with no such role ever created.
    # It only ever worked because DATABASE_URL overrode it, and it produced a
    # confusing connection error for anyone deploying against a managed PostgreSQL
    # configured through PGUSER/PGHOST instead.
    it "does not pin a username that no deployment creates" do
      expect(config["production"]).not_to have_key("username")
      expect(config["production"]).not_to have_key("password")
    end
  end
end
