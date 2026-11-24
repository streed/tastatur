class McpRevenueContract < McpPeriodContract
  LIMIT = (1..100)

  json do
    optional(:sort).filled(:string, included_in?: Revenue::AttributionReport::SORTS.keys)
    optional(:limit).filled(:integer, gteq?: LIMIT.min, lteq?: LIMIT.max)
  end
end
