require "rails_helper"

# Source-level checks on the privacy invariants.
#
# Every other spec in this suite exercises behaviour. These read the source
# instead, which is unusual enough to deserve a justification: the failure mode
# they cover is not a wrong result, it is *new code in a new place* quietly
# acquiring an IP address. Behavioural specs cannot catch that, because the code
# that breaks the invariant is by definition code no existing spec calls.
#
# A migration that adds an `ip_address` column, a debugging `Rails.logger.info
# request.remote_ip` left in a controller, a well-meant "let's record the IP for
# abuse handling" — each of those breaks a claim on the /privacy page while every
# behavioural spec stays green.
#
# These are deliberately about visitors. An account holder's sign-in IP *is*
# stored, by Devise trackable, so the customer can spot a login that was not
# theirs; the allowlists below name it explicitly rather than letting it read as
# an oversight. See docs/privacy/claims.md.
RSpec.describe "Privacy invariants" do
  def source_files(*globs)
    globs.flat_map { |glob| Rails.root.glob(glob) }.select(&:file?)
  end

  describe "the raw client IP" do
    # Only this file may pull the IP off the request. Note what is *not* here:
    # Ingest::Identifier, which never touches `request` at all and receives the
    # address as an `ip:` argument. That is worth preserving — it means the code
    # doing the sensitive work can be tested with a literal string and has no
    # ambient access to a request it might log.
    #
    # ComplianceController was on this list until 2026-07-30, for the
    # `/data-request` subject-access page. Deriving a caller's identifier from
    # their live connection turned out to identify their *network* rather than
    # them — the user-agent half of the HMAC is a header anyone can set — so the
    # page was removed. See docs/privacy/data-requests.md.
    #
    # Adding to this list is a deliberate act, and the reviewer's question should
    # be "and where does it go next?"
    ALLOWED_TO_READ_IP = [
      # Reads it from the request and hands it straight to the identifier.
      "app/controllers/api/events_controller.rb"
    ].freeze

    it "is read from the request only by the ingest endpoint" do
      readers = source_files("app/**/*.rb", "app/**/*.erb", "lib/**/*.rb").select do |file|
        file.read.match?(/remote_ip|REMOTE_ADDR/)
      end.map { |file| file.relative_path_from(Rails.root).to_s }.sort

      expect(readers).to eq(ALLOWED_TO_READ_IP.sort),
                         "Unexpected files read the client IP: #{(readers - ALLOWED_TO_READ_IP).join(", ")}. " \
                         "The IP is passed to Ingest::Identifier and must not spread. " \
                         "See docs/privacy/identity.md"
    end

    it "is never persisted by a migration" do
      # Devise trackable's two columns are the sole exception and live in the
      # generated users migration.
      allowed = "20260729190037_devise_create_users.rb"

      offenders = source_files("db/migrate/*.rb").reject { |f| f.basename.to_s == allowed }.select do |file|
        file.read.match?(/^\s*(t\.\w+|add_column\b).*\b(ip_address|remote_ip|client_ip|visitor_ip|user_agent)\b/)
      end.map { |file| file.basename.to_s }

      expect(offenders).to be_empty,
                           "These migrations add a column for an IP or user-agent: #{offenders.join(", ")}. " \
                           "Neither is persisted for visitors. See docs/privacy/identity.md"
    end

    it "stores a sign-in IP only against a user, never against measurement data" do
      # The positive half of the same invariant: assert the exception is exactly
      # where we say it is, so this spec fails if someone copies the pattern onto
      # a table that holds analytics.
      columns = ActiveRecord::Base.connection.tables.to_h do |table|
        [table, ActiveRecord::Base.connection.columns(table).map(&:name).grep(/ip$|ip_/)]
      end.reject { |_, matches| matches.empty? }

      expect(columns).to eq("users" => %w[current_sign_in_ip last_sign_in_ip])
    end
  end

  describe "the rotating salt" do
    it "is random rather than derived from a long-lived key" do
      # HKDF(master_key, date) would look like an improvement — deterministic,
      # no state to lose — and would quietly destroy the guarantee, because every
      # historical salt stays regenerable forever. Nothing would ever actually be
      # destroyed, and the unlinkability claim would become false with no visible
      # change in behaviour.
      offenders = source_files("app/**/*.rb", "lib/**/*.rb").select do |file|
        file.read.match?(/HKDF|derive_salt|salt.*master_key|master_key.*salt/i)
      end.map { |file| file.relative_path_from(Rails.root).to_s }

      expect(offenders).to be_empty,
                           "Salt derivation from a long-lived key found in: #{offenders.join(", ")}. " \
                           "Salts must be random. See docs/privacy/identity.md"
    end

    it "is written to the privacy Redis, not the persistent one" do
      salt = Ingest::SaltStore.current(build_stubbed(:site))

      expect(salt).to be_present
      PRIVACY_REDIS_POOL.with { |redis| expect(redis.keys("tastatur:salt*")).not_to be_empty }

      # The check that matters. If REDIS_PRIVACY_URL is misconfigured to point at
      # the main instance, the assertion above still passes while the salt is
      # being written to something with an AOF on disk.
      if REDIS_POOL != PRIVACY_REDIS_POOL
        REDIS_POOL.with { |redis| expect(redis.keys("tastatur:salt*")).to be_empty }
      end
    end
  end

  # "Revenue is never shown on a public or shared dashboard" is a claim on
  # /revenue, and today it holds only because nothing in the shared render path
  # happens to mention revenue. That is true and structurally fragile: the shared
  # dashboard renders the same widgets the private one does, so a revenue widget
  # added to DashboardWidget::KINDS would inherit the public path by default and
  # break the claim silently. Exactly the "new code in a new place" failure this
  # file exists for.
  describe "revenue on a public shared dashboard" do
    # The widget kinds that have been looked at and judged safe to render to an
    # unauthenticated reader. Adding a kind to DashboardWidget::KINDS without
    # adding it here fails this spec — which is the entire point. If the new kind
    # is safe, add it and say so in the commit; if it is not, it needs gating out
    # of Dashboards::Render for the share path first.
    REVIEWED_FOR_PUBLIC_SHARING = %w[stat timeseries breakdown goals funnel].freeze

    it "has no widget kind that has not been reviewed for the public path" do
      expect(DashboardWidget::KINDS).to match_array(REVIEWED_FOR_PUBLIC_SHARING)
    end

    # The templates and the service that a share URL actually renders through.
    # `revenue`, `mrr` and `currency` are the vocabulary the revenue layer uses;
    # none of them belongs on an unauthenticated page.
    it "renders through no source that reads the revenue layer" do
      offenders = source_files(
        "app/controllers/shared_dashboards_controller.rb",
        "app/views/shared_dashboards/*.erb",
        "app/views/sites/_dashboard.html.erb",
        "app/views/sites/dashboards/_widgets.html.erb",
        "app/views/sites/dashboards/widgets/*.erb",
        "app/services/dashboards/render.rb"
      ).select { |file| file.read.match?(/\b(revenue|mrr|revenue_cents|Revenue::)\b/i) }

      expect(offenders).to be_empty,
                           "revenue reaches the public share path via:\n#{offenders.join("\n")}"
    end
  end

  describe "the salt Redis service definition" do
    # Parsed rather than grepped. A `grep -A 12` for persistence flags near
    # `redis-privacy` reads twelve lines past the end of the service and into
    # whatever comes next, which in docker-compose.prod.yml is Caddy's volume
    # list — so the naive version reports a failure that is not there.
    %w[docker-compose.yml docker-compose.prod.yml].each do |compose_file|
      context compose_file do
        let(:service) do
          YAML.safe_load(Rails.root.join(compose_file).read, aliases: true)
              .fetch("services").fetch("redis-privacy")
        end

        it "declares no volume" do
          # The redis image declares VOLUME /data itself, so docker attaches an
          # empty anonymous volume regardless; this asserts we do not add a named
          # one that would survive `docker compose down`.
          expect(service["volumes"]).to be_nil
        end

        it "disables both forms of persistence" do
          command = Array(service.fetch("command")).join(" ")

          expect(command).to include("--save")
          expect(command).to match(/--save\s+(""|''|\s*--)/),
                             "--save must be empty to disable RDB snapshots"
          expect(command).to include("--appendonly no")
        end

        it "fails loudly under memory pressure instead of evicting the live salt" do
          # An eviction policy that drops the current salt would silently recount
          # every visitor as new, which looks like a traffic spike rather than a bug.
          expect(Array(service.fetch("command")).join(" ")).to include("--maxmemory-policy noeviction")
        end
      end
    end
  end
end
