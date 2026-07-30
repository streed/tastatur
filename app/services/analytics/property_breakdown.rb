module Analytics
  # Top values for each property carried by a custom event.
  #
  # WHY THIS EXISTS. `tastatur('event', 'Signup', { props: { plan: 'pro' } })`
  # has been accepted, bounded by IngestEventContract, and written to the
  # `props` JSONB column since the beginning — and then read by nothing. The
  # install page documents the call, so anyone who followed it was storing data
  # that no screen in the application could show them. That is worse than not
  # supporting properties: the docs promise a feature, the beacon reports 202,
  # and the answer is simply never displayed.
  #
  # WHAT A ROW MEANS. One row is "visitors who fired this event with this
  # property set to this value". The volume column counts the matching EVENTS,
  # not pageviews — an event scoped panel contains no pageviews to count, which
  # is the same reason Scope#volume_expression exists. It rides in the
  # Breakdown::Row struct under the name `pageviews` for that struct's sake; the
  # views render `visitors` and never this.
  #
  # HOW IT IS QUERIED. `jsonb_each_text` in a LATERAL join expands one event
  # into one row per property, so every key and every value come back from a
  # single scan rather than one query per key — the same argument as
  # Breakdown.batch. Verified against TimescaleDB 2.29: the lateral join is
  # planned across ordinary chunks and columnstore chunks alike, and the scan is
  # served by the existing partial index `idx_events_site_custom_event_time`
  # (measured 0.97 ms over 18k events). There is deliberately NO GIN index on
  # `props`:
  #
  #   - a GIN index cannot serve `GROUP BY props->>'key'` at all, which is this
  #     query, and
  #   - the equality filter is already narrowed to one site, one window and one
  #     event name by that partial index, so GIN would buy a residual filter
  #     over a handful of rows in exchange for index maintenance on the ingest
  #     hot path.
  #
  # Add one only with a measurement that says it helps.
  class PropertyBreakdown < ApplicationService
    DEFAULT_LIMIT = 10

    # The number of panels is bounded by IngestEventContract::MAX_PROPS (24),
    # because a property cannot be displayed that could not be sent. So there is
    # no cap here and therefore no silently truncated list of keys.
    def initialize(site:, period:, filters: Filters.new, limit: DEFAULT_LIMIT)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @limit = limit.clamp(1, 500)
    end

    # Returns [[property_name, Breakdown::Result], ...], most-seen property
    # first, so the panel a site owner cares about is not below the fold behind
    # one they set once and forgot.
    def call
      rows = fetch
      return Success([]) if rows.empty?

      total = total_visitors

      grouped = rows.group_by { |row| row["property"] }
      ordered = grouped.sort_by { |name, values| [-values.sum { |row| row["visitors"].to_i }, name] }

      Success(ordered.map { |name, values| [name, result_from(values, total)] })
    end

    private

    def fetch
      where, binds = @scope.raw_conditions(table: "e")

      # jsonb_each_text raises "cannot deconstruct a scalar" on a jsonb that is
      # not an object, and that error would arrive as a 500 on the dashboard
      # rather than as a missing panel. IngestEventContract requires a hash, so
      # this is unreachable today — but the guard is inside the function
      # argument rather than in the WHERE clause on purpose, because the planner
      # is free to evaluate a lateral function before a filter and a guard that
      # depends on clause ordering is not a guard.
      @scope.select_all(<<~SQL, binds)
        SELECT
          kv.key                       AS property,
          kv.value                     AS value,
          COUNT(DISTINCT e.visitor_hash) AS visitors,
          COUNT(*)                     AS pageviews
        FROM events e,
             LATERAL jsonb_each_text(
               CASE WHEN jsonb_typeof(e.props) = 'object' THEN e.props ELSE '{}'::jsonb END
             ) AS kv(key, value)
        WHERE #{where}
        GROUP BY 1, 2
        ORDER BY 1, visitors DESC, pageviews DESC, 2 ASC
      SQL
    end

    # The percentage denominator, matching Analytics::Breakdown exactly: distinct
    # visitors under the scope's filters, NOT the sum of the rows. One visitor can
    # fire the same event with two different property values, so summing the rows
    # would count them twice and understate every percentage.
    def total_visitors
      where, binds = @scope.raw_conditions

      @scope.select_one(<<~SQL, binds)["visitors"].to_i
        SELECT COUNT(DISTINCT visitor_hash) AS visitors FROM events WHERE #{where}
      SQL
    end

    def result_from(rows, total_visitors)
      kept, withheld = Suppression.partition(rows, threshold: @scope.k_threshold)

      Breakdown::Result.new(
        rows: kept.first(@limit).map { |row| to_row(row, total_visitors) },
        suppressed_rows: withheld.size,
        suppressed_visitors: withheld.sum { |row| row["visitors"].to_i },
        threshold: @scope.k_threshold
      )
    end

    def to_row(row, total)
      visitors = row["visitors"].to_i

      Breakdown::Row.new(
        value: row["value"],
        visitors: visitors,
        pageviews: row["pageviews"].to_i,
        percentage: total.zero? ? 0.0 : ((visitors.to_f / total) * 100).round(1)
      )
    end
  end
end
