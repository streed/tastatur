# POST /mcp — the Model Context Protocol endpoint, Streamable HTTP transport.
#
# Authenticated by an ApiKey holding `read:analytics`, exactly as the rest of the
# server-to-server API is, so it inherits that controller's honest 401 / 403
# (§12's "always 202" rule is for anonymous browsers and does not apply here) and
# its freedom from forgery protection, Devise and Pundit: authorization is the key,
# and the key names one site. See Api::V1::BaseController.
#
# The key is read-only by construction: nothing behind this endpoint writes.
class McpController < Api::V1::BaseController
  self.required_scope = Mcp::ToolRegistry::REQUIRED_SCOPE

  def create
    message = parse_body
    return render json: protocol_error("Parse error", -32_700), status: :bad_request if message == :unparseable

    case Mcp::HandleRequest.call(message: message, api_key: api_key)
    in Success(nil) then head :accepted
    in Success(body) then render json: body
    end
  end

  # No server-initiated stream and no sessions: 405 is the spec's way of saying so.
  def unsupported
    response.set_header("Allow", "POST")
    head :method_not_allowed
  end

  private

  def parse_body
    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    :unparseable
  end

  def protocol_error(message, code) = { jsonrpc: "2.0", id: nil, error: { code: code, message: message } }
end
