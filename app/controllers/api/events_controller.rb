module Api
  # The ingest endpoint. Called from every page of every customer site.
  #
  # Three properties matter more than anything else here:
  #
  #   1. It must be fast. This runs during the customer's page load, so it
  #      answers 202 as soon as the event is buffered and does no work that can
  #      be deferred.
  #
  #   2. It must never 500 into a customer's console. A broken analytics
  #      endpoint that throws errors in the browser console of someone else's
  #      website is worse than one that quietly drops an event, so every
  #      rejection path returns a normal, quiet response.
  #
  #   3. It must not require the customer to configure CORS, an origin
  #      allowlist, or anything else. See the note on origin checking below.
  class EventsController < ActionController::API
    # A 1x1 transparent GIF for the <noscript> fallback. Inlined rather than
    # served from disk so the pixel path touches no filesystem.
    PIXEL = Base64.decode64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7").freeze

    # Raised by Rack while parsing the query string, which happens the first time
    # anything touches `params` — so before this controller gets to be careful.
    #
    # `GET /api/event?s=%` used to answer **400**, not 202, which broke property 2
    # above and the promise in docs/architecture/ingest.md that this endpoint is
    # indistinguishable whatever you send it. It also logged a full exception
    # report per request, so anyone poking the URL filled the log and Sentry.
    #
    # Rack::Attack reaches `params` even earlier, in its throttle blocks, and is
    # guarded separately in its own initializer.
    MALFORMED_REQUEST_ERRORS = [
      ActionController::BadRequest,
      ActionDispatch::Http::Parameters::ParseError,
      Rack::QueryParser::InvalidParameterError,
      Rack::QueryParser::ParamsTooDeepError,
      Rack::Utils::ParameterTypeError
    ].freeze

    before_action :set_cors_headers
    before_action :reject_prefetch
    before_action :honour_opt_out

    # Answers exactly as a valid-but-unusable request does. Nothing is stored,
    # because nothing could be parsed.
    rescue_from(*MALFORMED_REQUEST_ERRORS) do |error|
      Rails.logger.info("[tastatur] discarded an unparseable ingest request: #{error.class}")
      set_cors_headers
      action_name == "pixel" ? send_pixel : head(:accepted)
    end

    def create
      result = IngestEventContract.new.call(event_params)

      if result.failure?
        # Still 202 — see the note below on why this endpoint never distinguishes.
        # But the site owner gets to find out, instead of the event evaporating with
        # no trace anywhere.
        Ingest::RejectionCounter.record_contract_failure(
          site_token: event_params[:s], fields: result.errors.to_h.keys
        )
        return head(:accepted)
      end

      Ingest::RecordEvent.call(
        payload: result.to_h,
        ip: request.remote_ip,
        user_agent: request.user_agent,
        # A browser sets this on a cross-origin POST and JavaScript cannot forge
        # it, so a mismatch is strong evidence the snippet was copied onto
        # someone else's site. Absent for curl and the server-side API, which is
        # why only a PRESENT mismatch is rejected.
        origin: request.headers["Origin"]
      )

      # 202 regardless of outcome. Whether we accepted, dropped a bot, or did
      # not recognise the site token is our business — telling the browser
      # would let anyone probe which site tokens are valid, and would put a
      # visible error in the customer's console for a decision they cannot act
      # on from there.
      head :accepted
    end

    # <noscript><img src="/api/pixel?s=TOKEN&u=..."></noscript>
    def pixel
      result = IngestEventContract.new.call(event_params)

      if result.success?
        Ingest::RecordEvent.call(
          payload: result.to_h,
          ip: request.remote_ip,
          user_agent: request.user_agent
        )
      end

      send_pixel
    end

    # Browsers send this before a cross-origin POST with a JSON content type.
    def options
      head :no_content
    end

    private

    def send_pixel
      response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
      response.headers["Pragma"] = "no-cache"
      send_data PIXEL, type: "image/gif", disposition: "inline"
    end

    def event_params
      # Prefer a parsed body, fall back to query parameters. Deliberately NOT
      # keyed on `request.get?`: Rails routes HEAD like GET but `get?` returns
      # false for it, so a verb check would send a HEAD request down the
      # body-parsing path and silently read nothing. Asking "is there a usable
      # body?" is true regardless of verb.
      source = parsed_body.presence || request.query_parameters

      {
        s: source["s"],
        u: source["u"],
        n: source["n"],
        r: source["r"],
        w: cast_integer(source["w"]),
        p: source["p"].is_a?(Hash) ? source["p"] : nil,
        c: source["c"],
        v: cast_integer(source["v"])
      }.compact
    end

    def parsed_body
      return request.request_parameters if request.request_parameters.present?

      body = request.raw_post
      return nil if body.blank?

      Oj.load(body, mode: :compat)
    rescue StandardError
      nil
    end

    def cast_integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value.to_s, exception: false)
    end

    # ANY origin is allowed at the CORS layer, deliberately.
    #
    # A CORS allowlist would not protect a public token, and it would break every
    # legitimate setup we cannot predict: staging domains, reverse proxies, AMP
    # caches, apps in an iframe, a site served from both example.com and
    # www.example.com. So the browser is always permitted to make the request.
    #
    # The Origin header IS used, just not here. Ingest::HostnamePolicy rejects an
    # event whose Origin is present and does not belong to the site. That is the
    # difference between refusing the request, which breaks things and protects
    # nothing, and refusing to attribute the data, which protects the numbers.
    # The token is not a secret and is never treated as one.
    def set_cors_headers
      headers["Access-Control-Allow-Origin"] = "*"
      headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS"
      headers["Access-Control-Allow-Headers"] = "Content-Type"
      headers["Access-Control-Max-Age"] = "86400"
    end

    # Server-side backstop for the opt-out the tracker already checks.
    #
    # The script honours DNT and Global Privacy Control before it sends
    # anything, so this rarely fires — but the ingest endpoint is a public HTTP
    # API that anything can call, including an older cached copy of the script
    # and the <noscript> pixel, which cannot check a header at all. Enforcing it
    # here means the guarantee holds regardless of what the caller did.
    #
    # Nothing is hashed, geolocated or stored on this path. We deliberately do
    # not even record that an opt-out happened per visitor — only the coarse
    # counter below, so the dashboard can explain a gap in the numbers without
    # keeping a record of the people who objected.
    def honour_opt_out
      return unless opted_out?

      # `event_params[:s]`, not `params[:s]`.
      #
      # The tracker posts with `Content-Type: text/plain` on purpose, to keep the
      # request a CORS "simple request" and avoid a preflight. Rails does not parse
      # a text/plain body into `params`, so `params[:s]` was nil for every real
      # beacon, and `request.query_parameters` is empty on a POST. The counter
      # therefore recorded nothing at all for the transport that carries almost all
      # the traffic — measured: 0 recorded for a text/plain POST, 1 for the noscript
      # pixel, which is the only path that puts the token in the query string.
      #
      # So the dashboard's "some of your visitors send Do Not Track" footnote was
      # undercounting by roughly everything, which is worse than not having it:
      # a site owner comparing against another tool would be told the gap was small.
      Ingest::OptOutCounter.record(site_token: event_params[:s])
      head :accepted
    end

    def opted_out?
      return true if request.headers["Sec-GPC"].to_s == "1"

      request.headers["DNT"].to_s == "1"
    end

    # Chrome and Safari speculatively fetch links the user has not clicked.
    # Counting those as pageviews inflates every number on the dashboard.
    def reject_prefetch
      purpose = request.headers["Sec-Purpose"].to_s + request.headers["Purpose"].to_s
      head :accepted if purpose.include?("prefetch") || purpose.include?("prerender")
    end
  end
end
