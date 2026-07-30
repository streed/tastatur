class HealthController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  # Load balancers and uptime monitors have no session and no account, and this
  # action reads no records. Skipping Pundit verification here is required, not
  # a shortcut.
  skip_after_action :verify_authorized

  # A platform health check must get a real answer even on a brand-new install
  # with no users, or the first deploy never goes healthy and setup can never be
  # completed. See ApplicationController#redirect_to_first_run_setup.
  always_reachable

  def show
    checks = {
      database: check { ActiveRecord::Base.connection.execute("SELECT 1") },
      redis: check { REDIS_POOL.with { |r| r.ping } },
      # Checked separately from the main Redis: if the privacy store is down,
      # ingest cannot compute a visitor identity at all, so a green health
      # check that ignored it would be actively misleading.
      redis_privacy: check { PRIVACY_REDIS_POOL.with { |r| r.ping } }
    }

    healthy = checks.values.all? { |result| result == "ok" }

    render json: {
      status: healthy ? "ok" : "error",
      version: Tastatur.version,
      checks: checks,
      time: Time.current.iso8601
    }, status: healthy ? :ok : :service_unavailable
  end

  private

  def check
    yield
    "ok"
  rescue StandardError => e
    # The class name, not the message: a health endpoint is usually public and
    # a connection error message can leak hostnames or credentials.
    e.class.name
  end
end
