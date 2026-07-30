# Rate limiting.
#
# Two things make this configuration different from a stock one:
#
# 1. THE INGEST ENDPOINT IS THE BUSIEST PATH IN THE APPLICATION and must not be
#    caught by a generic per-IP limit. It gets its own, far higher allowance.
#
# 2. THROTTLE KEYS ARE HASHED, NOT RAW IPs. Rack::Attack keys live in Redis for
#    the length of the window, so a stock configuration writes every visitor's
#    IP address into Redis — while the rest of this codebase goes to some
#    trouble never to persist one. A truncated HMAC is just as unique per
#    client, so rate limiting works identically and no IP is written down.
#    (The key is deliberately derived with a per-process secret rather than the
#    rotating visitor salt: this is operational data with a minutes-long life,
#    and it must not be correlatable with anything in the analytics tables.)
class Rack::Attack
  # Counters live in Redis explicitly, NOT in Rails.cache.
  #
  # Rack::Attack defaults to Rails.cache, which in production is a FileStore
  # under tmp/. That is per-process and per-container, so the effective limit is
  # silently multiplied by the number of Puma workers and replicas — on a
  # three-replica deploy a "600 per minute" limit is really 1800, and nothing
  # anywhere says so. It also puts a disk write on the ingest hot path.
  #
  # Rate limiting is the only remaining defence against someone who spoofs a
  # site's real hostname (see Ingest::HostnamePolicy for why that case cannot be
  # prevented outright), so a limit that quietly does not hold is worse than
  # having none: it is a control we would claim in the docs and not actually
  # have.
  self.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    namespace: "rack_attack",
    # A throttle counter is not worth failing a request over. If Redis is
    # unreachable the store degrades to allowing traffic rather than 500ing, and
    # the error surfaces in the log.
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.warn("[Rack::Attack] cache #{method} failed: #{exception.class}")
      returning
    }
  )

  THROTTLE_SECRET = Rails.application.secret_key_base

  def self.client_key(request)
    OpenSSL::HMAC.digest("SHA256", THROTTLE_SECRET, request.ip.to_s)
                 .byteslice(0, 12)
                 .unpack1("H*")
  end

  INGEST_PATHS = %w[/api/event /api/pixel].freeze

  # The site token from a query parameter or a JSON body.
  #
  # Memoised on the Rack env because two throttles need it and parsing the body
  # twice per ingest request would be wasteful on the hottest path in the app.
  # The body must be rewound afterwards or the controller reads an empty stream.
  def self.ingest_site_token(request)
    env = request.env
    return env["tastatur.site_token"] if env.key?("tastatur.site_token")

    # `request.params` parses the query string, and Rack raises on malformed
    # %-encoding, an over-deep nesting, or a type mismatch. That happens here, in
    # middleware, before the controller can be careful about it — and an
    # unhandled raise in a throttle block turned `GET /api/event?s=%` into a 400
    # with a full exception report, when this endpoint is supposed to be
    # indistinguishable whatever you send it.
    #
    # A request we cannot parse simply has no site token, which is a perfectly
    # good answer: it falls through to the per-client limits, which do not need one.
    token = begin
      request.params["s"].presence
    rescue StandardError
      nil
    end

    token ||= begin
      Oj.load(request.body.read, mode: :compat)&.dig("s")
    rescue StandardError
      nil
    ensure
      request.body.rewind if request.body.respond_to?(:rewind)
    end

    env["tastatur.site_token"] = token.presence
  end

  # --- Ingest --------------------------------------------------------------
  # 600 per minute per client. A real browser sends one event per pageview and
  # a handful more for custom events; even an aggressive single-page app stays
  # far below this. It is high enough that a large corporate NAT or a university
  # network sharing one address is not throttled, and low enough to stop a
  # single host flooding one site's statistics.
  throttle("ingest/client", limit: 600, period: 1.minute) do |req|
    client_key(req) if INGEST_PATHS.include?(req.path)
  end

  # Per (site, client). This is the tightest limit and the one that matters most
  # against metric poisoning.
  #
  # Hostname validation forces an attacker to claim the site's real domain, and
  # the Origin check catches a snippet pasted onto another site — but a scripted
  # attacker sends no Origin at all, so for them rate limiting is the whole
  # remaining defence. The 600/min client limit above is per client across ALL
  # sites, which still allowed one address to aim 600/min at a single victim:
  # 864,000 fabricated pageviews a day, enough to ruin a small site's numbers.
  #
  # 120/min is far above any real browser (a person generates a handful of events
  # a minute, an aggressive SPA maybe thirty) and cuts the single-address attack
  # fivefold. It does not make poisoning impossible — a distributed attacker with
  # many addresses defeats any per-address limit — which is why
  # `rails tastatur:events:purge` exists and why the docs say plainly that this
  # is bounded rather than prevented.
  throttle("ingest/site_client", limit: 120, period: 1.minute) do |req|
    next unless INGEST_PATHS.include?(req.path)

    token = ingest_site_token(req)
    "#{token}:#{client_key(req)}" if token.present?
  end

  # Per-site ceiling, so one customer cannot be flooded into distorted numbers
  # by a distributed source that stays under the per-client limit. Deliberately
  # generous — this is a circuit breaker, not a quota.
  throttle("ingest/site", limit: 20_000, period: 1.minute) do |req|
    token = ingest_site_token(req)
    "site:#{token}" if INGEST_PATHS.include?(req.path) && token.present?
  end

  # --- Application ---------------------------------------------------------
  # The general limit explicitly skips ingest, which has its own above.
  throttle("req/client", limit: 300, period: 5.minutes) do |req|
    client_key(req) unless INGEST_PATHS.include?(req.path)
  end

  throttle("logins/client", limit: 5, period: 20.seconds) do |req|
    client_key(req) if req.path == "/users/sign_in" && req.post?
  end

  throttle("logins/email", limit: 5, period: 20.seconds) do |req|
    req.params.dig("user", "email")&.downcase&.strip if req.path == "/users/sign_in" && req.post?
  end

  throttle("signups/client", limit: 5, period: 1.hour) do |req|
    client_key(req) if req.path == "/users" && req.post?
  end

  throttle("password_resets/client", limit: 5, period: 1.hour) do |req|
    client_key(req) if req.path == "/users/password" && req.post?
  end

  # The two flows that were left unthrottled while their sibling was not.
  #
  # Both send mail to an address the caller supplies, so without a limit they are a
  # free way to have this instance deliver mail to arbitrary people, at whatever
  # rate the attacker likes. That burns the sending domain's reputation, which is
  # the kind of damage that is slow and expensive to undo.
  #
  # With `config.paranoid` now enabled neither reveals whether an address exists,
  # so the remaining exposure is the mail volume itself.
  throttle("confirmations/client", limit: 5, period: 1.hour) do |req|
    client_key(req) if req.path == "/users/confirmation" && req.post?
  end

  throttle("unlocks/client", limit: 5, period: 1.hour) do |req|
    client_key(req) if req.path == "/users/unlock" && req.post?
  end

  # Password-protected shared dashboards are an unauthenticated password form,
  # so they need their own brute-force limit — keyed on the slug as well, so
  # attacking one link does not lock out another.
  throttle("share_unlock/slug", limit: 10, period: 5.minutes) do |req|
    req.path[%r{\A/share/([^/]+)/unlock\z}, 1] if req.post?
  end

  # --- Response ------------------------------------------------------------
  # A throttled ingest request gets 202, not 429. It is fire-and-forget from a
  # beacon that cannot react, and a 429 in a customer's browser console reads as
  # "your analytics are broken" for something they cannot act on. Everything
  # else gets a normal 429 with Retry-After.
  self.throttled_responder = lambda do |request|
    if INGEST_PATHS.include?(request.path)
      [202, {}, []]
    else
      retry_after = (request.env["rack.attack.match_data"] || {})[:period]
      [429, { "Content-Type" => "text/plain", "Retry-After" => retry_after.to_s },
       ["Too many requests. Try again shortly.\n"]]
    end
  end
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_, _, _, _, payload|
  # The matched rule and the hashed key — never the IP, which is the whole point
  # of hashing it above.
  Rails.logger.warn(
    "[Rack::Attack] throttled rule=#{payload[:request].env['rack.attack.matched']} " \
    "path=#{payload[:request].path}"
  )
end
