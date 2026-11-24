module Mcp
  # The tools this instance offers, and the scope a key needs to use them.
  #
  # ONE SCOPE, `read:analytics`, for all of them. Revenue is not split off because
  # a key that can see traffic is already trusted with the site's analytics; the
  # line that matters is read versus write, and that is drawn on ApiKey.
  module ToolRegistry
    REQUIRED_SCOPE = "read:analytics".freeze

    ALL = %w[
      DescribeSite GetSummary GetTimeseries GetBreakdown GetGoals GetFunnel GetCampaigns GetRevenueAttribution
    ].freeze

    module_function

    def tools = ALL.map { |name| Mcp::Tools.const_get(name) }.select(&:available?)

    def find(name) = tools.find { |tool| tool.tool_name == name.to_s }

    def tool_available?(tool) = tool.available?
  end
end
