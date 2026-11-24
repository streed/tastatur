module Mcp
  module Tools
    class GetSummary < Base
      NAME = "get_summary".freeze
      DESCRIPTION = "Headline traffic metrics for a period — visitors, pageviews, sessions, bounce rate, average " \
                    "visit duration — with the change against the immediately preceding period of the same length. " \
                    "The right first question for \"how is the site doing?\".".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(Base::FILTERS_PROPERTY).merge(
        compare: { type: "boolean", description: "Include the previous period and percentage change. Default true." }
      ).freeze
      REQUIRED = [].freeze
      CONTRACT = McpReportContract

      private

      def run
        compare = args.fetch(:compare, true)

        case Analytics::Summary.call(site: site, period: period, filters: filters, compare: compare)
        in Success(metrics)
          result(
            {
              period: period_data, filters: filters_data,
              metrics: metrics_data(metrics),
              previous_period: metrics.previous && metrics_data(metrics.previous),
              change_percent: compare ? change_data(metrics) : nil
            },
            notes(metrics)
          )
        end
      end

      def metrics_data(metrics)
        {
          visitors: metrics.visitors, pageviews: metrics.pageviews, sessions: metrics.sessions,
          bounce_rate_percent: metrics.bounce_rate, avg_visit_duration_seconds: metrics.avg_duration
        }
      end

      # nil, not 0, where the previous period was empty: a rise from nothing has no
      # percentage, and 0 would read as "unchanged".
      def change_data(metrics)
        %i[visitors pageviews sessions bounce_rate].index_with { |metric| metrics.change(metric) }
      end

      def notes(metrics)
        notes = []
        notes << "`pageviews` counts the matching custom events, not pageviews, because an event filter is applied." if filters.event_scoped?
        notes << "change_percent is null where the previous period was zero." if metrics.previous && metrics.previous.visitors.zero?
        notes
      end
    end
  end
end
