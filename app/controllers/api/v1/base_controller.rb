module Api
  module V1
    # The authenticated, server-to-server API.
    #
    # WHY THIS ANSWERS HONESTLY WHEN THE INGEST ENDPOINT DOES NOT. §12 requires
    # `/api/event` to return 202 for everything — an unknown site token, a
    # malformed body, a bot — because that endpoint is called from a browser by an
    # anonymous stranger, and any distinguishable response lets someone enumerate
    # valid site tokens while printing errors into a customer's console.
    #
    # None of that reasoning survives the move to this path. Every caller here has
    # already proved it holds a secret, so there is nothing left to enumerate; the
    # caller is the customer's own server, so an error goes into their logs where
    # somebody is paid to read it, not into a visitor's console; and the failure
    # mode this endpoint actually has is silent — an identify call that quietly
    # does nothing produces a revenue report that is confidently wrong months
    # later, with no way to tell it apart from a bad quarter.
    #
    # So: 401 for a bad key, 422 with the field names for a bad body, 404 for a
    # site that is gone. The opposite rule, for the opposite reason, and both are
    # deliberate.
    #
    # INHERITS ActionController::API for the same reason Billing::StripeWebhooksController
    # does: no forgery protection to forget (the test environment disables it, so a
    # missing `skip_forgery_protection` would pass every spec and fail only in
    # production), no `authenticate_user!`, and no Pundit verification callbacks —
    # authorization here is the API key, and the key names exactly one site (an identify key) or one account (an agent key).
    class BaseController < ActionController::API
      include Dry::Monads[:result]

      before_action :authenticate_api_key!
      before_action :authorize_scope!

      # Every endpoint names the one permission it needs. There is no default:
      # a controller that forgets to say gets a 500 in its first spec rather
      # than quietly accepting any key, which is the failure that would hand an
      # agent's read-only key a write endpoint.
      class_attribute :required_scope, instance_accessor: false

      private

      attr_reader :api_key, :site

      # `Authorization: Bearer tk_...`.
      #
      # The token is also accepted from `X-Api-Key`, because a surprising number
      # of HTTP clients and serverless platforms strip or rewrite `Authorization`
      # — and a customer whose events silently stop arriving after moving to a new
      # host has no way to discover why from our side.
      def authenticate_api_key!
        token = bearer_token || request.headers["X-Api-Key"]
        @api_key = token.present? ? ApiKey.authenticate(token) : nil

        return refuse_unauthenticated if @api_key.nil?

        @site = @api_key.site
        @api_key.note_use
      end

      # 403, not 401, and a message that names the scope. Unlike a bad key, this
      # caller has already proved who it is, so there is nothing to protect by
      # being vague, and "which permission is missing" is the only thing that
      # lets them fix it.
      def authorize_scope!
        scope = self.class.required_scope
        raise NotImplementedError, "#{self.class} must declare required_scope" if scope.blank?
        return if api_key.nil? || api_key.allows?(scope)

        render json: {
          error: "insufficient_scope",
          message: "This API key lacks the `#{scope}` permission. Create a key with it " \
                   "under Settings → API keys."
        }, status: :forbidden
      end

      def bearer_token
        header = request.headers["Authorization"].to_s
        return nil unless header.start_with?("Bearer ")

        header.delete_prefix("Bearer ").strip.presence
      end

      # ONE MESSAGE FOR EVERY AUTHENTICATION FAILURE. A response that distinguished
      # "no such key" from "revoked key" from "wrong secret" would hand an attacker
      # a working oracle, and would tell a legitimate developer nothing they cannot
      # already determine from their own settings page.
      def refuse_unauthenticated
        render json: {
          error: "unauthorized",
          message: "Provide a live API key as `Authorization: Bearer tk_...`. " \
                   "Create one under a site's Settings → API keys (to identify customers) or " \
                   "Account → AI agents (to read analytics)."
        }, status: :unauthorized
      end

      # dry-validation's error shape, flattened into something a developer reading
      # a log can act on without knowing what dry-validation is.
      def refuse_invalid(errors)
        render json: {
          error: "invalid_request",
          message: "The request body was not valid.",
          details: errors.to_h
        }, status: :unprocessable_entity
      end

      # `request.request_parameters` rather than `params.to_unsafe_h`.
      #
      # `params` merges the query string, the routing parameters (`controller`,
      # `action`, `format`) and the body into one hash. Handing that to a contract
      # means `controller` and `action` arrive as input — harmless today because
      # the contract declares its keys and drops the rest, but it also means a
      # query parameter can override a body field, which is a request-smuggling
      # shape nobody intends. The body is what this API documents; the body is what
      # gets validated.
      def body_params
        request.request_parameters.deep_symbolize_keys
      rescue ActionDispatch::Http::Parameters::ParseError
        {}
      end
    end
  end
end
