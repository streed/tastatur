module Mcp
  module Tools
    class GetBreakdown < Base
      NAME = "get_breakdown".freeze
      DESCRIPTION = "Top values of one dimension — pages, entry pages, referrer sources, countries, browsers, devices, " \
                    "UTM campaigns, custom events — ranked by visitors, with each row's share of the audience. Combine " \
                    "with `filters` to drill down (e.g. top pages for visitors from one source).".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(Base::FILTERS_PROPERTY).merge(
        dimension: { type: "string", enum: Analytics::Filters::DIMENSIONS.keys, description: "What to group by." },
        limit: { type: "integer", minimum: McpBreakdownContract::LIMIT.min, maximum: McpBreakdownContract::LIMIT.max,
                 description: "Rows to return, default #{Analytics::Breakdown::DEFAULT_LIMIT}." }
      ).except(:compare).freeze
      REQUIRED = %i[dimension].freeze
      CONTRACT = McpBreakdownContract

      private

      def run
        report = Analytics::Breakdown.call(
          site: site, period: period, dimension: args[:dimension], filters: filters,
          limit: args.fetch(:limit, Analytics::Breakdown::DEFAULT_LIMIT)
        )

        case report
        in Success(breakdown)
          result(
            {
              period: period_data, filters: filters_data, dimension: args[:dimension],
              rows: breakdown.rows.map do |row|
                { value: row.label, visitors: row.visitors, pageviews: row.pageviews, share_percent: row.percentage }
              end,
              withheld: withheld(breakdown)
            },
            ["Shares are of the audience, not of the rows, so they can legitimately sum past 100%: a visitor " \
             "who read three pages is in three rows."]
          )
        in Failure(:unknown_dimension)
          Failure(invalid: { dimension: ["is not a known dimension"] })
        end
      end

      def withheld(breakdown)
        {
          rows: breakdown.suppressed_rows,
          visitors: breakdown.suppressed_visitors,
          reason: "Rows with fewer than #{breakdown.threshold} visitors are withheld to keep visitors anonymous."
        }
      end
    end
  end
end
