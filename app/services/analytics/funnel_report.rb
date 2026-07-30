module Analytics
  # Step-by-step conversion through a funnel.
  #
  # HOW THE QUERY WORKS, and why it is not the obvious one.
  #
  # The obvious version computes `MIN(occurred_at) FILTER (WHERE <step n>)` per
  # visitor in a single GROUP BY and then checks the timestamps increase. That
  # is one pass and it is wrong: it takes the FIRST time each step matched, so
  # a visitor who hits /checkout, backs out to /pricing, then returns to
  # /checkout is recorded as having reached checkout BEFORE pricing, and is
  # dropped from a strictly-ordered funnel they actually completed.
  #
  # Instead each step is a CTE that searches only the window AFTER the previous
  # step's timestamp for that same visitor. Step n starts from the set that
  # reached step n-1, so the chain narrows at every stage and each lookup rides
  # the (site_id, visitor_hash, occurred_at) index that exists for exactly this
  # query.
  #
  # THE HONEST LIMITATION: without a persistent identifier, a visitor cannot be
  # followed past the daily salt rotation. A funnel whose window crosses that
  # boundary will undercount, because the same person is a different
  # visitor_hash on the far side of it. Funnel#window_exceeds_identity_lifetime?
  # is true in that case and the UI says so rather than quietly reporting a low
  # number. This is inherent to cookieless measurement, not a bug to fix.
  class FunnelReport < ApplicationService
    Step = Struct.new(:step, :visitors, :conversion_rate, :dropoff, :dropoff_rate, keyword_init: true)
    Report = Struct.new(:funnel, :steps, :entered, :completed, :overall_rate, keyword_init: true)

    def initialize(funnel:, period:, filters: Filters.new)
      @funnel = funnel
      @scope = Scope.new(site: funnel.site, period: period, filters: filters)
    end

    def call
      steps = @funnel.funnel_steps.to_a
      return Failure(:not_enough_steps) if steps.size < Funnel::MIN_STEPS

      counts = execute(steps)
      Success(build(steps, counts))
    end

    private

    def execute(steps)
      ctes = []
      binds = []
      base_sql, base_binds = @scope.raw_conditions(table: "e")

      steps.each_with_index do |step, index|
        match_sql, match_binds = step.matcher.to_sql("e.#{step.match_column}")
        kind_sql = step.pageview? ? "e.event_name = 'pageview'" : "e.event_name <> 'pageview'"

        if index.zero?
          # Everyone who reached step 1 within the reporting window.
          ctes << <<~SQL
            s0 AS (
              SELECT e.visitor_hash, MIN(e.occurred_at) AS t
              FROM events e
              WHERE #{base_sql}
                AND #{kind_sql} AND #{match_sql}
              GROUP BY e.visitor_hash
            )
          SQL
          binds.concat(base_binds).concat(match_binds)
        else
          # Only events for the same visitor, at or after the previous step,
          # and inside the funnel's completion window measured from step 1.
          ctes << <<~SQL
            s#{index} AS (
              SELECT p.visitor_hash, MIN(e.occurred_at) AS t
              FROM s#{index - 1} p
              JOIN events e
                ON e.site_id = ?
               AND e.visitor_hash = p.visitor_hash
               AND e.occurred_at >= p.t
               AND e.occurred_at <= p.t + (? * INTERVAL '1 second')
               AND #{kind_sql} AND #{match_sql}
              GROUP BY p.visitor_hash
            )
          SQL
          binds.concat([@scope.site.id, @funnel.window_seconds]).concat(match_binds)
        end
      end

      selects = steps.each_index.map { |i| "(SELECT COUNT(*) FROM s#{i}) AS step_#{i}" }

      @scope.select_one("WITH #{ctes.join(', ')} SELECT #{selects.join(', ')}", binds)
    end

    def build(steps, counts)
      entered = counts["step_0"].to_i
      completed = counts["step_#{steps.size - 1}"].to_i

      rows = steps.each_with_index.map do |step, index|
        visitors = counts["step_#{index}"].to_i
        previous = index.zero? ? visitors : counts["step_#{index - 1}"].to_i

        Step.new(
          step: step,
          visitors: visitors,
          conversion_rate: entered.zero? ? 0.0 : ((visitors.to_f / entered) * 100).round(1),
          dropoff: previous - visitors,
          dropoff_rate: previous.zero? ? 0.0 : (((previous - visitors).to_f / previous) * 100).round(1)
        )
      end

      Report.new(
        funnel: @funnel,
        steps: rows,
        entered: entered,
        completed: completed,
        overall_rate: entered.zero? ? 0.0 : ((completed.to_f / entered) * 100).round(1)
      )
    end
  end
end
