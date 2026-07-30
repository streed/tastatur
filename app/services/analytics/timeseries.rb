module Analytics
  # The visitors/pageviews chart.
  #
  # Returns one point per bucket across the whole period, including buckets
  # with no traffic — a chart that silently omits empty days draws a
  # misleadingly smooth line.
  #
  # The gap filling is done in Ruby rather than with generate_series in SQL on
  # purpose. Stepping a timestamptz by '1 day' across a daylight-saving
  # boundary is only correct if the database session's TimeZone happens to be
  # set to the site's zone, which is a fragile thing to depend on. ActiveSupport
  # gets DST right, and the series is at most a few hundred entries.
  class Timeseries < ApplicationService
    Point = Struct.new(:bucket, :visitors, :pageviews, keyword_init: true)

    def initialize(site:, period:, filters: Filters.new)
      @scope = Scope.new(site: site, period: period, filters: filters)
    end

    def call
      rows = fetch
      indexed = rows.index_by { |row| row["bucket"].in_time_zone(@scope.site.timezone) }

      Success(
        buckets.map do |bucket|
          row = indexed[bucket]
          Point.new(
            bucket: bucket,
            visitors: row&.fetch("visitors", 0).to_i,
            pageviews: row&.fetch("pageviews", 0).to_i
          )
        end
      )
    end

    private

    def period = @scope.period

    # Step size, and how to snap a timestamp to the start of its bucket.
    #
    # THE SNAP IS LOAD-BEARING. `time_bucket` aligns to its own origin, not to
    # whatever date the report happens to start on, and the series generated here
    # is matched against its output by equality. Starting the series at
    # `period.from` therefore produced buckets that existed in Ruby and nowhere in
    # the result set, so every lookup missed and every point read zero.
    #
    # It was invisible for day and hour reports, where `period.from` is already
    # midnight and already aligned, and total for the two coarser intervals.
    # Measured on the 12-month preset: Ruby generated 52 Friday-aligned weeks, the
    # database returned Monday-aligned ones, and the chart drew a flat line at zero
    # against 17,286 real pageviews.
    #
    # `:monday` is passed explicitly rather than relying on `Date.beginning_of_week`:
    # `time_bucket`'s week origin is 2000-01-03, a Monday, and it has no idea what
    # Rails is configured to think. Verified against the running TimescaleDB for
    # all four intervals across four timezones and six dates including DST
    # transitions — ActiveSupport and `time_bucket` agree on every one.
    SERIES = {
      "hour" => [1.hour, ->(time) { time.beginning_of_hour }],
      "day" => [1.day, ->(time) { time.beginning_of_day }],
      "week" => [1.week, ->(time) { time.beginning_of_week(:monday) }],
      "month" => [1.month, ->(time) { time.beginning_of_month }]
    }.freeze

    def buckets
      step, snap = SERIES.fetch(period.interval)
      zone = ActiveSupport::TimeZone[@scope.site.timezone]

      # Snapping can start the series slightly before `period.from` — a 12-month
      # report beginning on a Friday starts at the preceding Monday. That is
      # correct: the SQL still only counts events inside the period, so the first
      # bucket is a partial one, which is exactly how `time_bucket` treats it.
      cursor = snap.call(period.from.in_time_zone(zone))
      series = []
      while cursor < period.to
        series << cursor
        cursor += step
      end
      series
    end

    def fetch
      if period.interval == "hour"
        @scope.hourly_aggregated? ? hourly_from_aggregate : from_raw
      elsif @scope.aggregated?
        daily_from_aggregates
      else
        from_raw
      end
    end

    # Native hourly buckets — visitors is already the exact distinct count for
    # each hour, so it can be read straight out.
    def hourly_from_aggregate
      where, binds = @scope.aggregate_conditions

      @scope.select_all(<<~SQL, binds)
        SELECT bucket, visitors, pageviews
        FROM events_by_hour
        WHERE #{where}
        ORDER BY bucket
      SQL
    end

    # Coarser than an hour. Pageviews are additive so they are summed out of
    # events_by_hour, but visitors are NOT — summing hourly unique counts would
    # count a visitor once for every hour they were active. Unique visitors per
    # bucket therefore come from visitor_days, where a DISTINCT over the
    # re-bucketed rows is exact.
    def daily_from_aggregates
      where, binds = @scope.aggregate_conditions
      bucket = @scope.bucket_expression("bucket")

      @scope.select_all(<<~SQL, binds * 2)
        SELECT
          COALESCE(v.bucket, p.bucket) AS bucket,
          COALESCE(v.visitors, 0)      AS visitors,
          COALESCE(p.pageviews, 0)     AS pageviews
        FROM (
          SELECT #{bucket} AS bucket, COUNT(DISTINCT visitor_hash) AS visitors
          FROM visitor_days WHERE #{where} GROUP BY 1
        ) v
        FULL OUTER JOIN (
          SELECT #{bucket} AS bucket, SUM(pageviews) AS pageviews
          FROM events_by_hour WHERE #{where} GROUP BY 1
        ) p USING (bucket)
        ORDER BY 1
      SQL
    end

    # Filtered, or a timezone whose offset does not align to the aggregate
    # buckets. Exact, and bounded by the (site_id, occurred_at) index.
    def from_raw
      where, binds = @scope.raw_conditions
      bucket = @scope.bucket_expression

      @scope.select_all(<<~SQL, binds)
        SELECT
          #{bucket}                                       AS bucket,
          COUNT(DISTINCT visitor_hash)                    AS visitors,
          COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews
        FROM events
        WHERE #{where}
        GROUP BY 1
        ORDER BY 1
      SQL
    end
  end
end
