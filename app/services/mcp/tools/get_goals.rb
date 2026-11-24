module Mcp
  module Tools
    class GetGoals < Base
      NAME = "get_goals".freeze
      DESCRIPTION = "Conversions for every goal the site has defined: how many conversions, how many distinct " \
                    "visitors converted, the conversion rate against all visitors, and any revenue the goal " \
                    "carries (per currency, never converted between them).".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(Base::FILTERS_PROPERTY).freeze
      REQUIRED = [].freeze
      CONTRACT = McpReportContract

      private

      def run
        case Analytics::GoalReport.call(site: site, period: period, filters: filters)
        in Success(*rows)
          notes = []
          notes << "This site has no goals defined." if rows.empty? && !filters.event_scoped?
          notes << "Goals that the event filter cannot satisfy are omitted rather than shown as zero." if filters.event_scoped?
          result({ period: period_data, filters: filters_data, goals: rows.map { |row| row_data(row) } }, notes)
        end
      end

      def row_data(row)
        {
          id: row.goal.public_id, name: row.goal.name,
          conversions: row.conversions, converting_visitors: row.visitors,
          conversion_rate_percent: row.conversion_rate,
          revenue: row.revenue_by_currency.to_h.map { |currency, cents| { currency: currency, cents: cents } }
        }
      end
    end
  end
end
