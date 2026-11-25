class McpEventPropertiesContract < McpReportContract
  LIMIT = (1..50)

  json do
    required(:event).filled(:string, max_size?: Analytics::Filters::MAX_VALUE)
    optional(:limit).filled(:integer, gteq?: LIMIT.min, lteq?: LIMIT.max)
  end
end
