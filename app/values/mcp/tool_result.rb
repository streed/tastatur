module Mcp
  # What a tool hands back to the protocol layer.
  #
  # `data` is a Hash because it IS the JSON document the agent receives — it is
  # built field by field in the tool that owns it, from typed report values, and
  # leaves this struct only to be serialised. Nothing downstream reads keys out of
  # it. `notes` is the part that earns its own attribute: caveats a careful analyst
  # would state alongside the numbers (a distinct count that must not be summed, a
  # withheld row), kept apart from the data so an agent cannot mistake prose for a
  # metric and a human reading a transcript sees them first.
  class ToolResult < Dry::Struct
    attribute :data, Types::Strict::Hash
    attribute :notes, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
  end
end
