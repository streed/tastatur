module Mcp
  module Tools
    class GetTimeseries < Base
      NAME = "get_timeseries".freeze
      DESCRIPTION = "Visitors and pageviews per hour, day, week or month across a period (the bucket size follows " \
                    "the range and is reported as `period.bucket`). Empty buckets are included as zeros. Use it " \
                    "to find trends, spikes and drops.".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(Base::FILTERS_PROPERTY).freeze
      REQUIRED = [].freeze
      CONTRACT = McpReportContract

      private

      def run
        case Analytics::Timeseries.call(site: site, period: period, filters: filters)
        in Success(*points)
          result(
            {
              period: period_data, filters: filters_data,
              points: points.map { |point| { bucket_start: iso(point.bucket), visitors: point.visitors, pageviews: point.pageviews } }
            },
            ["Do not add `visitors` across buckets: a visitor active on several days is counted in each. " \
             "Use get_summary for the unique total over the whole period."]
          )
        end
      end
    end
  end
end
