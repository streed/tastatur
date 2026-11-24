class McpFunnelContract < McpReportContract
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  json do
    required(:funnel_id).filled(:string, format?: UUID)
  end
end
