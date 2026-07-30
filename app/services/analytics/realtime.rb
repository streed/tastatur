module Analytics
  # Visitors active in the last few minutes.
  #
  # Read from the raw hypertable rather than a separate Redis counter. The
  # ingest buffer holds events for at most ten seconds, which is invisible
  # inside a five-minute window, and this avoids maintaining a second source of
  # truth that could drift from the one the rest of the dashboard reads.
  class Realtime < ApplicationService
    WINDOW = 5.minutes

    # An upper bound on the window, because this is the one dashboard query that
    # runs on a timer rather than on a click. It is polled by a Turbo frame every
    # few seconds, and it is a COUNT(DISTINCT) over raw events — so a window wide
    # enough to cross many chunks turns a cheap repeated query into an expensive
    # repeated one. Nothing passes `window:` from a parameter today; this is here so
    # that wiring one up later cannot accidentally become a self-inflicted load test.
    MAX_WINDOW = 1.hour

    def initialize(site:, window: WINDOW)
      @site = site
      @window = [window, MAX_WINDOW].min
    end

    def call
      count = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          [<<~SQL, @site.id, @window.ago]
            SELECT COUNT(DISTINCT visitor_hash)
            FROM events
            WHERE site_id = ? AND occurred_at >= ?
          SQL
        )
      ).to_i

      Success(count)
    end
  end
end
