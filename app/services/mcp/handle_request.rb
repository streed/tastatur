module Mcp
  # One JSON-RPC message from an MCP client, in; the reply, out.
  #
  # STATELESS ON PURPOSE. There is no session id, no server-initiated message and no
  # SSE stream: every request is authenticated by its own key and answered in
  # full, which is what lets any web process behind the load balancer serve it and
  # leaves nothing to expire or leak. The MCP spec permits exactly this (a server
  # may answer every POST with plain JSON and decline GET).
  #
  # TWO KINDS OF ERROR, and the difference is load-bearing. A malformed request or
  # an unknown tool is a JSON-RPC protocol error. Bad ARGUMENTS to a real tool are
  # not: they come back as a normal result with `isError: true`, because that is the
  # form a model is shown and can correct itself from — a protocol error is
  # swallowed by the client and the agent just sees the call fail.
  #
  # Success(Hash) is the JSON body to send; Success(nil) is a notification, which
  # gets no body. The hash is wire format, not domain data.
  class HandleRequest < ApplicationService
    PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze

    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602

    def initialize(message:, api_key:)
      @message = message
      @api_key = api_key
    end

    def call
      return error(nil, INVALID_REQUEST, "Expected a single JSON-RPC object (batches are not supported).") unless @message.is_a?(Hash)
      return error(@message["id"], INVALID_REQUEST, "Missing \"method\".") unless @message["method"].is_a?(String)

      # No `id` means a notification (notifications/initialized and friends): the
      # client expects nothing back.
      return Success(nil) unless @message.key?("id")

      id = @message["id"]
      case @message["method"]
      when "initialize" then reply(id, initialize_result)
      when "ping" then reply(id, {})
      when "tools/list" then reply(id, tools: Mcp::ToolRegistry.tools.map(&:definition))
      when "tools/call" then call_tool(id)
      else error(id, METHOD_NOT_FOUND, "Unsupported method: #{@message['method']}")
      end
    end

    private

    def initialize_result
      requested = @message.dig("params", "protocolVersion")
      {
        protocolVersion: PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "tastatur", version: "1" },
        instructions: "Read-only analytics for the sites in one account. Call list_sites, then describe_site. " \
                      "Figures are anonymous and cookieless; every tool states the caveats that apply to its numbers."
      }
    end

    def call_tool(id)
      params = @message["params"]
      name = params.is_a?(Hash) ? params["name"] : nil
      tool = Mcp::ToolRegistry.find(name)
      return error(id, INVALID_PARAMS, "Unknown tool: #{name.inspect}") if tool.nil?

      arguments = params["arguments"] || {}
      return error(id, INVALID_PARAMS, "\"arguments\" must be an object.") unless arguments.is_a?(Hash)

      case tool.call(account: @api_key.account, arguments: arguments)
      in Success(tool_result) then reply(id, success_content(tool_result))
      in Failure(invalid: problems) then reply(id, failure_content("Invalid arguments: #{problems.to_json}"))
      in Failure(not_found: message) then reply(id, failure_content(message))
      in Failure(unavailable: message) then reply(id, failure_content(message))
      end
    end

    def success_content(tool_result)
      body = { data: tool_result.data, notes: tool_result.notes }
      { content: [{ type: "text", text: body.to_json }], structuredContent: body, isError: false }
    end

    def failure_content(message)
      { content: [{ type: "text", text: message }], isError: true }
    end

    def reply(id, result) = Success({ jsonrpc: "2.0", id: id, result: result })

    def error(id, code, message) = Success({ jsonrpc: "2.0", id: id, error: { code: code, message: message } })
  end
end
