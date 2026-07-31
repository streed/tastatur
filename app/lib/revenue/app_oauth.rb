module Revenue
  # The one place that exchanges a Stripe App authorization code for the account
  # that granted it.
  #
  # NOT `Stripe::OAuth.token`. The gem's OAuth helper is the legacy Connect
  # flow: it posts to `connect.stripe.com/oauth/token`, and a Stripe App code is
  # exchanged at `#{api_base}/v1/oauth/token` with the platform secret key as
  # basic auth — different host, different path, different authentication. The
  # gem (19.x) has no wrapper for the app-flavoured endpoint, so this builds the
  # request itself.
  #
  # The URL is derived from `Stripe.api_base` DELIBERATELY. The test suite has
  # no WebMock; its guard against a forgotten stub is pointing `Stripe.api_base`
  # at a closed local port (spec/support/stripe.rb). A hardcoded host here would
  # step around that guard and make an unstubbed spec hit api.stripe.com for
  # real. The timeouts are inherited for the same reason — the suite flattens
  # them so an unstubbed call fails in microseconds, not eighty seconds.
  module AppOAuth
    # A 4xx from the exchange: the code was already used, expired, or belongs
    # to another app. Expected traffic — a customer double-clicking the button
    # produces exactly this — so callers map it to a polite refusal.
    class Refused < StandardError; end

    # Anything else standing between us and a token response: transport
    # failure, TLS trouble, or a 5xx. The caller's fault in no scenario, so it
    # maps to "could not reach Stripe" rather than "Stripe refused".
    class Unavailable < StandardError; end

    module_function

    def exchange(code:)
      response = post_token_request(code)
      body = parse(response.body)

      case response
      when Net::HTTPSuccess     then body
      when Net::HTTPClientError then raise Refused, refusal_message(body, response)
      else raise Unavailable, "Stripe answered #{response.code} to the token exchange"
      end
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      # SocketError is on the list because DNS failure raises
      # Socket::ResolutionError, which is a SocketError and NOT a
      # SystemCallError — without it, an instance with broken DNS answers 500
      # to the customer mid-OAuth instead of "could not reach Stripe".
      raise Unavailable, e.message
    end

    def post_token_request(code)
      uri = URI.parse("#{Stripe.api_base}/v1/oauth/token")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = Stripe.open_timeout
      http.read_timeout = Stripe.read_timeout

      request = Net::HTTP::Post.new(uri.path)
      # The APP OWNER's key, which is not necessarily billing's — see
      # Tastatur.stripe_connect_key for why they can differ.
      request.basic_auth(Tastatur.stripe_connect_key.to_s, "")
      request.set_form_data(grant_type: "authorization_code", code: code)

      http.request(request)
    end

    # OAuth error bodies carry a string `error` ("invalid_grant") and a human
    # `error_description`; prefer the human one.
    def refusal_message(body, response)
      body[:error_description].presence || body[:error].presence || "code refused (#{response.code})"
    end

    # Anything that is not a JSON object — a proxy's error page, a bare JSON
    # string or array — becomes an empty hash: on the success branch the caller
    # then finds no `stripe_user_id` and fails cleanly, and on the error
    # branches the status code still names the fault. The is_a? guard matters:
    # `"\"oops\""` parses without error and then raises TypeError on [:key].
    def parse(raw)
      parsed = JSON.parse(raw.to_s, symbolize_names: true)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
