module Mcp
  module Tools
    class DescribeSite < Base
      NAME = "describe_site".freeze
      DESCRIPTION = "Describes one site: its timezone, the date presets and " \
                    "filter dimensions the other tools accept, and the goals and funnels that exist (with the " \
                    "ids get_funnel needs). Cheap; reads no event data.".freeze
      PROPERTIES = {}.freeze
      REQUIRED = [].freeze
      CONTRACT = McpSiteContract

      private

      def run
        result(
          {
            site: { domain: site.domain, timezone: site.timezone },
            periods: Analytics::Period::PRESETS.except("custom"),
            filter_dimensions: Analytics::Filters::DIMENSIONS.keys,
            goals: site.goals.order(:name).map { |goal| goal_data(goal) },
            funnels: site.funnels.ordered.includes(:funnel_steps).map { |funnel| funnel_data(funnel) },
            revenue_attribution: Mcp::ToolRegistry.tool_available?(GetRevenueAttribution)
          },
          [
            "Every figure is anonymous and cookieless: a visitor is a hash that changes at midnight in the " \
            "site's timezone, so \"visitors\" over a long range counts visitor-days, not people.",
            "Breakdown and campaign rows with too few visitors are withheld to protect privacy; the tools " \
            "say how many, never which."
          ]
        )
      end

      def goal_data(goal)
        {
          id: goal.public_id, name: goal.name, kind: goal.kind,
          match: "#{goal.match_type} #{goal.match_value}", currency: goal.currency
        }
      end

      def funnel_data(funnel)
        {
          id: funnel.public_id, name: funnel.name,
          window_seconds: funnel.window_seconds,
          steps: funnel.funnel_steps.map(&:name)
        }
      end
    end
  end
end
