module Analytics
  # The headline numbers across the top of the dashboard.
  class Summary < ApplicationService
    def initialize(site:, period:, filters: Filters.new, compare: true)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @compare = compare
    end

    def call
      current = measure(@scope)
      previous = @compare ? measure(previous_scope) : nil

      Success(Metrics.new(**current, previous: previous && Metrics.new(**previous)))
    end

    private

    def previous_scope
      Scope.new(site: @scope.site, period: @scope.period.previous, filters: @scope.filters)
    end

    def measure(scope)
      totals = scope.aggregated? ? aggregated_totals(scope) : raw_totals(scope)
      sessions = session_metrics(scope)

      {
        visitors: totals["visitors"].to_i,
        pageviews: totals["pageviews"].to_i,
        sessions: sessions["sessions"].to_i,
        bounce_rate: percentage(sessions["bounces"], sessions["sessions"]),
        avg_duration: sessions["avg_duration"].to_f.round
      }
    end

    # Unfiltered, day-aligned: read the aggregates.
    #
    # visitors comes from visitor_days rather than by summing events_by_hour,
    # because unique counts are correct only WITHIN a bucket and summing them
    # across buckets counts every returning visitor once per hour they were
    # active. visitor_days holds one row per visitor per day, so a DISTINCT
    # over it is exact for any range.
    def aggregated_totals(scope)
      where, binds = scope.aggregate_conditions

      scope.select_one(<<~SQL, binds * 2)
        SELECT
          (SELECT COALESCE(SUM(pageviews), 0) FROM events_by_hour WHERE #{where}) AS pageviews,
          (SELECT COUNT(DISTINCT visitor_hash) FROM visitor_days WHERE #{where}) AS visitors
      SQL
    end

    # Filtered or sub-daily: the aggregates hold no dimension columns and
    # cannot bucket finer than a day, so scan the hypertable.
    #
    # The volume column is pageviews, except under an event filter, where it is
    # the matching events — a WHERE clause pinned to one event name contains no
    # pageviews to count. See Scope#volume_expression.
    def raw_totals(scope)
      where, binds = scope.raw_conditions

      scope.select_one(<<~SQL, binds)
        SELECT
          #{scope.volume_expression}   AS pageviews,
          COUNT(DISTINCT visitor_hash) AS visitors
        FROM events
        WHERE #{where}
      SQL
    end

    # Bounce rate and duration are session-level, so they always start from a
    # session-grain rollup — you cannot tell how many sessions had exactly one
    # pageview from any event-grain count.
    def session_metrics(scope)
      if scope.aggregated?
        where, binds = scope.aggregate_conditions
        scope.select_one(<<~SQL, binds)
          SELECT
            COUNT(*)                                        AS sessions,
            COUNT(*) FILTER (WHERE pageviews <= 1)          AS bounces,
            AVG(EXTRACT(EPOCH FROM ended_at - started_at))  AS avg_duration
          FROM session_days
          WHERE #{where}
        SQL
      elsif scope.filters.empty?
        # Unfiltered but on the raw path, which means the site's timezone does not
        # align to the aggregate buckets. One scan, no session pre-selection needed.
        where, binds = scope.raw_conditions
        rollup(scope, where, binds)
      else
        # QUALIFY, THEN ROLL UP.
        #
        # A filter has to choose which *sessions* are counted, not which of their
        # events are visible. Putting it in the WHERE clause of the rollup — which
        # is what this used to do — left each session holding only its matching
        # events, so bounce rate and duration were computed over fragments of
        # sessions rather than sessions.
        #
        # Measured on two sessions that both visited /pricing, one of which also
        # visited two other pages over five minutes: filtering to page=/pricing
        # reported 100% bounce rate and 0s average duration, where the truth is 50%
        # and 150s. Every session collapses to a single pageview, so a filtered
        # bounce rate was always close to 100% and duration always close to zero —
        # wrong in a direction that looks like a plausible finding about the page.
        #
        # So the filter selects session hashes, and the rollup then reads every
        # event those sessions produced inside the period.
        rollup(scope, *scope.session_qualified_conditions)
      end
    end

    def rollup(scope, where, binds)
      scope.select_one(<<~SQL, binds)
        SELECT
          COUNT(*)                                       AS sessions,
          COUNT(*) FILTER (WHERE pageviews <= 1)         AS bounces,
          AVG(EXTRACT(EPOCH FROM ended_at - started_at)) AS avg_duration
        FROM (
          SELECT session_hash,
                 COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews,
                 MIN(occurred_at) AS started_at,
                 MAX(occurred_at) AS ended_at
          FROM events
          WHERE #{where}
          GROUP BY session_hash
        ) s
      SQL
    end

    def percentage(part, whole)
      return 0.0 if whole.to_i.zero?

      ((part.to_f / whole.to_f) * 100).round(1)
    end

    # Value object returned to the views. Comparison against the previous
    # period is computed here so no template does arithmetic.
    class Metrics < Dry::Struct
      transform_keys(&:to_sym)

      attribute :visitors,    Types::Strict::Integer
      # The volume metric: pageviews, EXCEPT under an event filter, where it
      # carries the count of matching events instead and the views label it
      # "Events". Both periods of a comparison share the same filters, so
      # `change(:pageviews)` always compares like with like.
      attribute :pageviews,   Types::Strict::Integer
      attribute :sessions,    Types::Strict::Integer
      attribute :bounce_rate, Types::Strict::Float
      attribute :avg_duration, Types::Strict::Integer
      attribute? :previous,   Types::Nominal::Any

      def views_per_visit
        return 0.0 if sessions.zero?

        (pageviews.to_f / sessions).round(2)
      end

      # Percent change vs the previous period, or nil when there is nothing to
      # compare against. Returns nil rather than "+100%" when the previous
      # period was zero, because a jump from 0 has no meaningful percentage.
      def change(metric)
        return nil if previous.nil?

        before = previous.public_send(metric).to_f
        return nil if before.zero?

        (((public_send(metric).to_f - before) / before) * 100).round(1)
      end

      def formatted_duration
        return "0s" if avg_duration.zero?
        return "#{avg_duration}s" if avg_duration < 60

        minutes, seconds = avg_duration.divmod(60)
        "#{minutes}m #{seconds}s"
      end
    end
  end
end
