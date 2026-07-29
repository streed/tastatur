class HealthController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  def show
    ActiveRecord::Base.connection.execute("SELECT 1")
    REDIS_POOL.with { |r| r.ping }
    render json: { status: "ok", time: Time.current.iso8601 }
  rescue => e
    render json: { status: "error", error: e.message }, status: 503
  end
end
