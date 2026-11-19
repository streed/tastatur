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

  # A truncated keyed digest. Twelve bytes is far more than enough to keep two
  # clients apart for the length of a throttle window, and holding less of the
  # digest means holding less of anything.
  def self.hashed(value)
    OpenSSL::HMAC.digest("SHA256", THROTTLE_SECRET, value.to_s)
                 .byteslice(0, 12)
                 .unpack1("H*")
  end

  def self.client_key(request)
    hashed(request.ip)
  end

  INGEST_PATHS = %w[/api/event /api/pixel].freeze

  # The authenticated server-to-server API. A prefix rather than a list, because
  # this one IS versioned and a v2 must not silently arrive unthrottled.
  API_PATH_PREFIX = %r{\A/api/v\d+/}

  # The non-secret, indexed half of a presented API key: `tk_<prefix>_<secret>`.
  #
  # Deliberately does NOT authenticate — that is the controller's job and it
  # costs a bcrypt comparison. Middleware only needs something stable to count
  # against, and the prefix is stable, public within the token, and useless on
  # its own. The secret is never touched.
  def self.api_key_prefix(request)
    header = request.get_header("HTTP_AUTHORIZATION").to_s
    token = header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip : nil
    token = request.get_header("HTTP_X_API_KEY").to_s if token.blank?

    parts = token.to_s.split("_", 3)
    return nil unless parts.length == 3 && parts.first == "tk" && parts[1].present?

    hashed(parts[1])
  end

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
  #
  # The path guard is FIRST here, unlike it used to be. `ingest_site_token` reads
  # and JSON-parses the request body, and this block ran it before checking the
  # path — so every request in the application had its body parsed by middleware,
  # including a Stripe webhook POST. That worked only because the parser rewinds
  # the stream afterwards, which made signature verification (which needs the exact
  # raw body) depend on a `respond_to?(:rewind)` guard several files away. Checking
  # the path first removes that coupling and a wasted parse per request; the
  # discriminator was already nil for non-ingest paths, so throttling is unchanged.
  throttle("ingest/site", limit: 20_000, period: 1.minute) do |req|
    next unless INGEST_PATHS.include?(req.path)

    token = ingest_site_token(req)
    "site:#{token}" if token.present?
  end

  # --- Application ---------------------------------------------------------
  # The general limit explicitly skips ingest, which has its own above, and the
  # Stripe webhook, which must not have one at all.
  #
  # WHY THE WEBHOOK IS EXEMPT RATHER THAN GENEROUSLY LIMITED. Stripe delivers
  # every event for every customer from a small fixed set of its own addresses, so
  # under a per-client limit the entire instance shares ONE throttle key. At 300
  # per 5 minutes a busy month-end would 429 — and Stripe treats a 429 as a failed
  # delivery, retries for three days, and then DISABLES the endpoint. Losing
  # subscription events silently is how an account that cancelled stays on Pro and
  # an account that upgraded stays capped.
  #
  # Nothing is given away by exempting it. The endpoint's real gate is the
  # signature check against STRIPE_WEBHOOK_SECRET, which is a stronger control
  # than a rate limit: an unsigned request is refused whatever its volume, and a
  # signed one came from Stripe. See Billing::StripeWebhooksController.
  #
  # BOTH STRIPE ENDPOINTS ARE LISTED, and the second one needs the exemption more
  # than the first. `/billing/stripe/webhook` carries only OUR subscription events
  # — a handful per customer per month. `/stripe/connect/webhook` carries every
  # subscription, invoice, refund and dispute of every customer's ENTIRE BUSINESS,
  # all arriving from the same small set of Stripe addresses and therefore sharing
  # one throttle key across the whole instance. It would be the first thing to
  # 429, at which point Stripe retries for three days and disables the endpoint,
  # and the revenue screen silently stops advancing for everybody at once.
  UNTHROTTLED_PATHS = (INGEST_PATHS + %w[/billing/stripe/webhook /stripe/connect/webhook]).freeze

  throttle("req/client", limit: 300, period: 5.minutes) do |req|
    client_key(req) unless UNTHROTTLED_PATHS.include?(req.path) || API_PATH_PREFIX.match?(req.path)
  end

  # --- The authenticated API ------------------------------------------------
  #
  # EXEMPT FROM THE RULE ABOVE AND GIVEN ITS OWN, because the browser limit was
  # aimed at the wrong thing entirely. `req/client` keys on the caller's
  # address, and every identify call from one customer arrives from that
  # customer's SERVER — one address carrying every signup they have. 300 per
  # five minutes is a generous allowance for a person clicking around and a
  # painfully tight one for an application, so a customer with real signup
  # volume would start collecting 429s on the endpoint the whole revenue
  # feature rests on.
  #
  # §18 already explains why that is worse than it sounds: identify is
  # first-touch and write-once, so a call that never lands does not retry itself
  # into place later. It produces a customer attributed to nothing, and a
  # channel report that is confidently wrong months afterwards with no way to
  # tell it from a bad quarter.
  #
  # KEYED ON THE API KEY'S PREFIX, not the address. The prefix is the
  # non-secret, indexed half of the token (see ApiKey), so it identifies the
  # caller exactly without the secret going anywhere near Redis, and it is the
  # right bucket besides: two customers behind one NAT get their own budgets,
  # and one customer moving hosts keeps theirs. A request with no usable key
  # falls back to the client, so an unauthenticated flood is still bounded.
  throttle("api/key", limit: 3_000, period: 1.minute) do |req|
    next unless API_PATH_PREFIX.match?(req.path)

    prefix = api_key_prefix(req)
    prefix ? "key:#{prefix}" : "anon:#{client_key(req)}"
  end

  throttle("logins/client", limit: 5, period: 20.seconds) do |req|
    client_key(req) if req.path == "/users/sign_in" && req.post?
  end

  # Keyed on the address, so five guesses against one account cannot be spread
  # across five networks — and HASHED, like every other key in this file.
  #
  # It used to write the address verbatim. That is the one thing the header of
  # this file says not to do, one line down from the rule: Rack::Attack counters
  # live in Redis, the rest of the codebase goes to real trouble never to put an
  # identifier there, and an email address is a stronger identifier than the IP
  # this file already refuses to store. Hashing changes nothing about how the
  # throttle behaves — the same address produces the same key — and stops the
  # plaintext being written.
  throttle("logins/email", limit: 5, period: 20.seconds) do |req|
    next unless req.path == "/users/sign_in" && req.post?

    email = begin
      req.params.dig("user", "email")
    rescue StandardError
      nil
    end
    hashed(email.to_s.downcase.strip) if email.present?
  end

  # --- The second factor ---------------------------------------------------
  # A six-digit code is a 10^6 keyspace, and TwoFactor::VerifyChallenge already
  # destroys a code after five wrong guesses. That per-code budget is the real
  # control; this is what stops somebody paying for a fresh code every five
  # guesses and grinding indefinitely.
  #
  # Keyed on the client rather than the email, because the email is not in the
  # request at all by this point — the pending marker is in an encrypted session
  # cookie, and reading it here would mean decrypting a session in middleware.
  throttle("two_factor/client", limit: 15, period: 5.minutes) do |req|
    client_key(req) if req.path == "/two-factor" && req.post?
  end

  # The resend button sends mail to an address the caller has already named, so
  # it is the same class of exposure as the confirmation and unlock forms below:
  # a free way to make this instance deliver mail, which burns the sending
  # domain's reputation. TwoFactor::IssueChallenge also refuses to send twice
  # within twenty seconds per account, which is the half a distributed caller
  # could otherwise walk around.
  throttle("two_factor_resend/client", limit: 5, period: 10.minutes) do |req|
    client_key(req) if req.path == "/two-factor/resend" && req.post?
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

  # The waitlist form, for the same reason as the two above and then some: it is
  # linked from three public pages, needs no account, and sends mail to whatever
  # address is typed into it. Waitlist::Join's five-minute cooldown already stops
  # one address being mailed repeatedly; this stops one caller working through a
  # list of addresses instead.
  #
  # /waitlist does not exist on a self-hosted instance (§20), where this rule
  # throttles a path that 404s and costs nothing.
  throttle("waitlist/client", limit: 5, period: 1.hour) do |req|
    client_key(req) if req.path == "/waitlist" && req.post?
  end

  # Password-protected shared dashboards are an unauthenticated password form,
  # so they need their own brute-force limit.
  #
  # KEYED ON THE SLUG **AND** THE CLIENT, and the client half was missing. On
  # the slug alone, ten wrong guesses from anybody exhausted the budget for
  # everybody — so a stranger who had been sent one link could spend ten
  # requests and lock its actual audience out for five minutes, repeatedly, for
  # nothing. That is a denial-of-service handed out by the control meant to
  # prevent one, and it is worse here than on a sign-in form because the people
  # locked out have no account, no support route and no way to tell a wrong
  # password from an attack.
  #
  # Keeping the slug in the key is still right: it stops one client working
  # through several links on one budget. Ten guesses per client per link, over a
  # bcrypt comparison, is not a keyspace anybody walks.
  throttle("share_unlock/slug_client", limit: 10, period: 5.minutes) do |req|
    next unless req.post?

    slug = req.path[%r{\A/share/([^/]+)/unlock\z}, 1]
    "#{slug}:#{client_key(req)}" if slug
  end

  # The per-link ceiling the rule above used to be, kept as a circuit breaker
  # rather than as the brute-force control. Generous enough that a shared link
  # in genuine use is never near it, tight enough that a distributed attempt on
  # ONE link — which the per-client rule cannot see — still runs out.
  throttle("share_unlock/slug", limit: 120, period: 5.minutes) do |req|
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
