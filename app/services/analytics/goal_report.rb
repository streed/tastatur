module Analytics
  # Conversions per goal.
  #
  # THE DENOMINATOR IS THE THING TO GET RIGHT. A conversion rate is
  # "converting visitors ÷ visitors in the same window, under the same
  # filters". Two mistakes are easy and both inflate the number:
  #
  #   - dividing by sessions while counting unique converting visitors
  #   - dividing by a total computed without the filters applied
  #
  # So the denominator here is computed from the same scope as the numerator,
  # and both are counts of DISTINCT visitors.
  class GoalReport < ApplicationService
    # Revenue is a hash of currency => minor units, never a single number.
    #
    # It used to be `SUM(revenue_cents)` across every matching event regardless of
    # currency, so a site taking both euros and dollars got those added together and
    # presented as one figure with no unit attached. 4900 EUR + 4900 USD came out as
    # 9800 of nothing. The tracking API takes a currency on every revenue event and
    # the docs example uses EUR, so mixed currencies are the expected case rather
    # than an exotic one.
    #
    # There is no exchange-rate conversion here on purpose: rates move, we would
    # have to pick a date and a source, and a total silently computed at yesterday's
    # rate is a worse answer than two honest numbers side by side.
    Row = Struct.new(:goal, :conversions, :visitors, :conversion_rate, :revenue_by_currency,
                     keyword_init: true) do
      def revenue? = revenue_by_currency.present?

      # Largest first, so the currency that matters leads.
      def revenue
        revenue_by_currency.sort_by { |_currency, cents| -cents }
      end
    end

    def initialize(site:, period:, filters: Filters.new)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @site = site
    end

    def call
      goals = @site.goals.order(:name).to_a
      return Success([]) if goals.empty?

      denominator = total_visitors
      Success(goals.map { |goal| measure(goal, denominator) })
    end

    private

    def total_visitors
      where, binds = @scope.raw_conditions

      @scope.select_one(<<~SQL, binds)["visitors"].to_i
        SELECT COUNT(DISTINCT visitor_hash) AS visitors FROM events WHERE #{where}
      SQL
    end

    def measure(goal, denominator)
      where, binds = @scope.raw_conditions
      match_sql, match_binds = goal.matcher.to_sql(goal.match_column)

      # A pageview goal must not be satisfied by a custom event that happens to
      # carry the same string, and vice versa.
      kind_sql = goal.pageview? ? "event_name = 'pageview'" : "event_name <> 'pageview'"

      # GROUPING SETS so one scan yields both the overall counts and the per-currency
      # revenue. The `()` set is the grand total; each `(currency)` set is one
      # currency. `GROUPING(currency)` is what distinguishes the total row from a
      # real row whose currency happens to be NULL — comparing `currency IS NULL`
      # would conflate the two and count non-revenue events as a currency.
      rows = @scope.select_all(<<~SQL, binds + match_binds)
        SELECT
          GROUPING(currency)              AS is_total,
          currency,
          COUNT(DISTINCT visitor_hash)    AS visitors,
          COUNT(*)                        AS conversions,
          COALESCE(SUM(revenue_cents), 0) AS revenue_cents
        FROM events
        WHERE #{where} AND #{kind_sql} AND #{match_sql}
        GROUP BY GROUPING SETS ((), (currency))
      SQL

      total = rows.find { |row| row["is_total"].to_i == 1 } || {}
      visitors = total["visitors"].to_i

      revenue = rows.each_with_object({}) do |row, acc|
        next if row["is_total"].to_i == 1

        currency = row["currency"]
        cents = row["revenue_cents"].to_i
        # Events without revenue still form a currency group (a NULL one); only
        # actual money belongs in the result.
        acc[currency] = cents if currency.present? && cents.positive?
      end

      Row.new(
        goal: goal,
        conversions: total["conversions"].to_i,
        visitors: visitors,
        conversion_rate: denominator.zero? ? 0.0 : ((visitors.to_f / denominator) * 100).round(1),
        revenue_by_currency: revenue
      )
    end
  end
end
