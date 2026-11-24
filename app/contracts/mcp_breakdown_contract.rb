class McpBreakdownContract < McpReportContract
  LIMIT = (1..50)

  json do
    required(:dimension).filled(:string, included_in?: Analytics::Filters::DIMENSIONS.keys)
    optional(:limit).filled(:integer, gteq?: LIMIT.min, lteq?: LIMIT.max)
  end
end
