# Which of the account's sites a tool call is about. Optional here because a
# single-site account needs no argument; Mcp::Tools::Base#find_site decides when it
# is required, since that depends on the account and a contract only sees the call.
class McpSiteContract < Dry::Validation::Contract
  json do
    optional(:site).filled(:string, max_size?: 253)
  end
end
