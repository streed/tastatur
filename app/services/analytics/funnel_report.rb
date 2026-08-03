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
  # A STEP IS A SET OF ALTERNATIVES. Each step holds one or more conditions and
  # is satisfied by whichever matches FIRST, so the step's predicate is the OR
  # of them and nothing else about the query changes: the chain still narrows,
  # and MIN(occurred_at) over an OR is still the earliest moment the step was
  # reached. Each condition carries its own kind, which is what lets one step be
  # "the /welcome pageview OR the Signup event".
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
      steps = @funnel.funnel_steps.includes(:conditions).to_a
      return Failure(:not_enough_steps) if steps.size < Funnel::MIN_STEPS
      # A step with nothing to match cannot be given a predicate at all, and the
      # only shapes available — matching everything or matching nothing — are
      # both a report that quietly means something other than it says. The model
      # forbids it; this is what happens if a row is written around the model.
      return Failure(:step_without_a_match) if steps.any? { |step| step.conditions.empty? }

      counts = execute(steps)
      Success(build(steps, counts))
    end

    private

    def execute(steps)
      ctes = []
      binds = []
      base_sql, base_binds = @scope.raw_conditions(table: "e")

      steps.each_with_index do |step, index|
        match_sql, match_binds = step_predicate(step)

        if index.zero?
          # Everyone who reached step 1 within the reporting window.
          ctes << <<~SQL
            s0 AS (
              SELECT e.visitor_hash, MIN(e.occurred_at) AS t
              FROM events e
              WHERE #{base_sql}
                AND #{match_sql}
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
               AND #{match_sql}
              GROUP BY p.visitor_hash
            )
          SQL
          binds.concat([@scope.site.id, @funnel.window_seconds]).concat(match_binds)
        end
      end

      selects = steps.each_index.map { |i| "(SELECT COUNT(*) FROM s#{i}) AS step_#{i}" }

      @scope.select_one("WITH #{ctes.join(', ')} SELECT #{selects.join(', ')}", binds)
    end

    # What it takes to reach one step: any one of its conditions, each of which
    # is a kind and a matcher that have to hold together.
    #
    # The kind test is not redundant with the matcher. A pageview condition
    # compares `path` and an event condition compares `event_name`, so without
    # it a custom event named "/pricing" would satisfy a step that asks for the
    # /pricing page — the same rule Analytics::GoalReport applies for the same
    # reason. Binds are collected in the order the fragments are concatenated,
    # which is the order the caller must keep.
    def step_predicate(step)
      binds = []

      parts = step.conditions.map do |condition|
        kind_sql = condition.pageview? ? "e.event_name = 'pageview'" : "e.event_name <> 'pageview'"
        match_sql, match_binds = condition.matcher.to_sql("e.#{condition.match_column}")
        binds.concat(match_binds)

        "(#{kind_sql} AND #{match_sql})"
      end

      ["(#{parts.join(' OR ')})", binds]
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
