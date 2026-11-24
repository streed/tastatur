# The date range every MCP report tool accepts.
#
# STRICT WHERE THE DASHBOARD IS FORGIVING. `Analytics::Period.parse` falls back to
# the 30-day default for a preset it does not recognise, which is right for a URL
# a human may have edited and wrong here: an agent that asks for "last_week" and is
# silently handed 30 days will analyse the wrong window and say so with total
# confidence. So an unknown preset is an error the agent can read and correct.
class McpPeriodContract < Dry::Validation::Contract
  json do
    optional(:period).filled(:string, included_in?: Analytics::Period::PRESETS.keys)
    optional(:from).filled(:string)
    optional(:to).filled(:string)
  end

  rule(:period, :from, :to) do
    if values[:period] == "custom"
      %i[from to].each do |field|
        if values[field].nil?
          key(field).failure("is required when period is \"custom\"")
        elsif !(Date.iso8601(values[field]) rescue nil) # rubocop:disable Style/RescueModifier
          key(field).failure("must be a date like 2026-03-01")
        end
      end
    elsif values[:from] || values[:to]
      key(:from).failure("and `to` are only used with period \"custom\"")
    end
  end
end
