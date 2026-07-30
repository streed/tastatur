module Analytics
  # Decides which physical table answers a report, and builds its WHERE clause.
  #
  # This is the one place that knows the rule, so no individual report has to
  # get it right:
  #
  #   Continuous aggregates hold NO dimension columns and bucket by day. They
  #   can therefore answer a question only when it is unfiltered and no finer
  #   than daily. The moment a report is filtered by country, or asks for
  #   hourly buckets, the aggregates cannot help and the raw hypertable must be
  #   scanned.
  #
  # That is not a limitation to work around — it is the deliberate trade
  # documented in db/migrate/*_create_analytics_aggregates.rb. Aggregates make
  # the common, unfiltered dashboard fast; raw scans keep filtered reports
  # exact instead of approximate.
  class Scope
    attr_reader :site, :period, :filters

    def initialize(site:, period:, filters: Filters.new)
      @site = site
      @period = period
      @filters = filters
    end

    # Can the DAILY aggregates (visitor_days, session_days) answer this?
    #
    # Two conditions, and the second is subtle enough to be worth spelling out:
    #
    #   1. No filters, because the aggregates carry no dimension columns.
    #
    #   2. The requested range must begin and end exactly on a UTC midnight.
    #      Continuous aggregate buckets are UTC-aligned — one aggregate serves
    #      every site, so it cannot be bucketed per-site-timezone. For a site
    #      reporting in Europe/Berlin, "today" is 22:00 UTC yesterday to 22:00
    #      UTC today, which slices through the middle of two UTC day buckets.
    #      Filtering `bucket >= from` would then silently drop the bucket the
    #      range starts inside and report a number that is wrong by most of a
    #      day, with nothing to indicate it. So we simply do not use the daily
    #      aggregates unless the boundaries line up, and scan raw events
    #      instead — exact, and fast enough at the scale where this arises.
    def aggregated?
      filters.empty? && aligned_to?(1.day)
    end

    # Can events_by_hour answer this? Same reasoning, but hour buckets, which
    # every whole-hour timezone offset aligns to — that is all of them except
    # the :30 and :45 offsets (India, Nepal, Chatham Islands, parts of
    # Australia), which fall through to raw scans.
    def hourly_aggregated?
      filters.empty? && aligned_to?(1.hour)
    end

    def aligned_to?(unit)
      seconds = unit.to_i
      (period.from.to_i % seconds).zero? && (period.to.to_i % seconds).zero?
    end

    # WHERE clause and binds against the raw events hypertable.
    #
    # `table` prefixes every column, for queries that join events to itself
    # (funnels) where a bare `site_id` would be ambiguous.
    def raw_conditions(table: nil)
      prefix = table ? "#{table}." : ""
      filter_sql, filter_binds = filters.to_sql(table: table)

      sql = +"#{prefix}site_id = ? AND #{prefix}occurred_at >= ? AND #{prefix}occurred_at < ?"
      binds = [site.id, period.from, period.to]

      if filter_sql.present?
        sql << " AND #{filter_sql}"
        binds.concat(filter_binds)
      end

      [sql, binds]
    end

    # WHERE clause and binds against any of the continuous aggregates, all of
    # which share the same (bucket, site_id) leading columns.
    def aggregate_conditions
      ["site_id = ? AND bucket >= ? AND bucket < ?", [site.id, period.from, period.to]]
    end

    # Site and period only, with the dimension filters deliberately left off.
    #
    # For session-grain metrics the filter has to select which *sessions* count,
    # not which of their events are visible. Applying it before the rollup — which
    # is what `raw_conditions` does — leaves each session holding only its matching
    # events, so a session that saw /pricing and five other pages is measured as a
    # one-pageview visit lasting no time at all. See Analytics::Summary.
    def unfiltered_conditions
      ["site_id = ? AND occurred_at >= ? AND occurred_at < ?", [site.id, period.from, period.to]]
    end

    # Every event of every session that has at least one event matching the
    # filters — the qualify-then-roll-up shape that session-grain reads need.
    # The filter chooses which sessions count; the outer conditions then admit
    # everything those sessions did inside the period.
    def session_qualified_conditions
      qualifying, qualifying_binds = raw_conditions
      all_events, all_binds = unfiltered_conditions

      [
        "#{all_events} AND session_hash IN (SELECT session_hash FROM events WHERE #{qualifying})",
        all_binds + qualifying_binds
      ]
    end

    # The event-grain volume column, aliased "pageviews" by every query that
    # reads it.
    #
    # Under an event filter the WHERE clause pins event_name to the filtered
    # event, so COUNT(*) FILTER (WHERE event_name = 'pageview') is structurally
    # zero — the two conditions cannot both hold, and the dashboard rendered
    # "0 pageviews" above panels full of the very visitors it claimed not to
    # have. The volume that means something there is the matching events
    # themselves, and the views relabel the tile and series "Events"
    # (DashboardHelper#volume_label).
    def volume_expression
      filters.event_scoped? ? "COUNT(*)" : "COUNT(*) FILTER (WHERE event_name = 'pageview')"
    end

    def sanitize(sql, binds)
      ActiveRecord::Base.sanitize_sql_array([sql, *binds])
    end

    def select_all(sql, binds = [])
      ActiveRecord::Base.connection.select_all(sanitize(sql, binds)).to_a
    end

    def select_one(sql, binds = [])
      select_all(sql, binds).first || {}
    end

    # time_bucket with an explicit timezone so day boundaries land where the
    # site owner expects them, not where UTC puts them.
    def bucket_expression(column = "occurred_at")
      sanitize("time_bucket(INTERVAL ?, #{column}, ?)", [period.postgres_interval, site.timezone])
    end

    # Breakdown rows below the site's k-anonymity threshold are withheld. See
    # Analytics::Breakdown for what happens to the suppressed remainder.
    def k_threshold
      site.suppress_small_rows? ? site.k_anonymity_threshold : 0
    end
  end
end
