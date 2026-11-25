# For a tool that takes no arguments. Unknown ones are refused by Mcp::Tools::Base,
# which compares the call against the tool's declared properties.
class McpEmptyContract < Dry::Validation::Contract
  json { }
end
