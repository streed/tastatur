module Mcp
  module Tools
    class GetEventProperties < Base
      NAME = "get_event_properties".freeze
      DESCRIPTION = "Breaks one custom event down by its properties: for each property the event was sent with " \
                    "(e.g. plan, source), the top values ranked by visitors. Answers \"Signups by plan\". " \
                    "Name the event exactly as it appears in get_breakdown with dimension \"event\". To then narrow " \
                    "any other report to one property value, pass it in `filters.props`.".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(Base::FILTERS_PROPERTY).merge(
        event: { type: "string", description: "Custom event name, exact match." },
        limit: { type: "integer", minimum: McpEventPropertiesContract::LIMIT.min,
                 maximum: McpEventPropertiesContract::LIMIT.max,
                 description: "Values to return per property, default #{Analytics::PropertyBreakdown::DEFAULT_LIMIT}." }
      ).except(:compare).freeze
      REQUIRED = %i[event].freeze
      CONTRACT = McpEventPropertiesContract

      private

      def run
        scoped = filters.with("event", args[:event])
        report = Analytics::PropertyBreakdown.call(
          site: site, period: period, filters: scoped,
          limit: args.fetch(:limit, Analytics::PropertyBreakdown::DEFAULT_LIMIT)
        ).value!

        result(
          {
            period: period_data, filters: scoped.to_param, event: args[:event],
            properties: report.map { |name, breakdown| property_data(name, breakdown) }
          },
          [
            "`visitors` counts people who fired this event with that value; `events` counts the events. " \
            "A visitor who sent two different values appears in both rows, so shares can sum past 100%.",
            "Property values are chosen by the site's own code, and values seen by too few visitors are withheld " \
            "with the rows beside them; the counts say how many, never which."
          ] + (report.empty? ? ["No properties were found for this event in this period: it may not exist, may carry none, or may be below the privacy threshold."] : [])
        )
      end

      def property_data(name, breakdown)
        {
          property: name,
          values: breakdown.rows.map do |row|
            { value: row.label, visitors: row.visitors, events: row.pageviews, share_percent: row.percentage }
          end,
          withheld: {
            rows: breakdown.suppressed_rows,
            visitors: breakdown.suppressed_visitors,
            reason: "Values with fewer than #{breakdown.threshold} visitors are withheld to keep visitors anonymous."
          }
        }
      end
    end
  end
end
