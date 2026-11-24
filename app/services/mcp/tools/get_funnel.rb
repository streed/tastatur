module Mcp
  module Tools
    class GetFunnel < Base
      NAME = "get_funnel".freeze
      DESCRIPTION = "Step-by-step drop-off for one saved funnel: how many visitors reached each step in order, the " \
                    "conversion from the first step, and where people leave. Get funnel ids from describe_site.".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(Base::FILTERS_PROPERTY).merge(
        funnel_id: { type: "string", format: "uuid", description: "A funnel id from describe_site." }
      ).except(:compare).freeze
      REQUIRED = %i[funnel_id].freeze
      CONTRACT = McpFunnelContract

      private

      def run
        # Looked up THROUGH the site, so another site's funnel id is simply not found.
        funnel = site.funnels.find_by(public_id: args[:funnel_id])
        return Failure(not_found: "No funnel with that id on this site. Call describe_site for the valid ids.") if funnel.nil?

        case Analytics::FunnelReport.call(funnel: funnel, period: period, filters: filters)
        in Success(report)
          result(data(funnel, report), notes(funnel))
        in Failure(:not_enough_steps)
          Failure(unavailable: "This funnel has fewer than #{Funnel::MIN_STEPS} steps, so it cannot be measured.")
        in Failure(:step_without_a_match)
          Failure(unavailable: "A step of this funnel has nothing to match, so it cannot be measured.")
        end
      end

      def data(funnel, report)
        {
          period: period_data, filters: filters_data,
          funnel: { id: funnel.public_id, name: funnel.name, window_seconds: funnel.window_seconds },
          entered: report.entered, completed: report.completed, overall_conversion_percent: report.overall_rate,
          steps: report.steps.map do |step|
            {
              position: step.step.position, name: step.step.name, visitors: step.visitors,
              conversion_percent_of_entered: step.conversion_rate,
              dropped_off: step.dropoff, dropoff_percent_of_previous_step: step.dropoff_rate
            }
          end
        }
      end

      def notes(funnel)
        return [] unless funnel.window_exceeds_identity_lifetime?

        ["This funnel's window is longer than a day, but a visitor cannot be followed past midnight in the site's " \
         "timezone, so later steps are undercounted. Treat low completion as a floor, not a measurement."]
      end
    end
  end
end
