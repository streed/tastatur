module Ingest
  # Turns one validated beacon into one buffered event row.
  #
  # Everything privacy-sensitive happens here and only here: the IP address and
  # user-agent arrive as arguments, are used to compute a salted hash and a
  # coarse device profile, and go out of scope when this method returns. They
  # are never assigned to the row, never logged, and never leave this object.
  class RecordEvent < ApplicationService
    # Screen width is a well-known fingerprinting vector — the exact pixel
    # value carries several bits of entropy. Five buckets answer "does my site
    # get used on phones" while carrying almost none — and five is what
    # app/views/compliance/privacy.html.erb publishes, so the count here is a
    # claim, not a note.
    SCREEN_BUCKETS = [
      [576,   "xs"],
      [768,   "sm"],
      [992,   "md"],
      [1200,  "lg"],
      [Float::INFINITY, "xl"]
    ].freeze

    UTM_KEYS = %i[utm_source utm_medium utm_campaign utm_term utm_content].freeze

    # Redis is on the critical path three times here: the rotating salt, the
    # session window, and the write buffer. If it is unreachable, every one of
    # those raises.
    #
    # Letting that propagate meant `POST /api/event` answered **500**, which is
    # the one thing this endpoint must never do — an outage on our side would
    # print an error in the browser console of every page of every customer site,
    # about something the site owner cannot act on. Measured: stopping the salt
    # Redis turned a valid beacon into a 500.
    #
    # So a storage outage is converted into a Failure and the endpoint stays
    # quiet. This is NOT a swallowed error: it is reported to Sentry explicitly
    # below, because an unreachable Redis is an incident even though the response
    # is deliberately boring. The event itself is lost, which is the correct trade
    # when the alternative is breaking someone else's website.
    STORAGE_FAILURES = [
      Redis::BaseConnectionError,   # CannotConnectError, ConnectionError, TimeoutError
      Redis::CommandError,          # e.g. OOM under the noeviction policy
      ConnectionPool::TimeoutError  # every pooled connection busy
    ].freeze

    def initialize(payload:, ip:, user_agent:, origin: nil, received_at: Time.current)
      @payload = payload
      @ip = ip
      @user_agent = user_agent
      @origin = origin
      @received_at = received_at
    end

    def call
      site = resolve_site
      return Failure(:unknown_site) if site.nil?

      agent = UserAgent.parse(@user_agent)
      # Dropped before it can reach the database. Once a bot's pageview is
      # written it is indistinguishable from a person's.
      return Failure(:bot) if agent.bot?

      url = parse_url
      return Failure(:invalid_url) if url.nil?

      # The site token is public, so anyone can post events with it. This is what
      # stops those events being attributed to arbitrary hostnames, and catches
      # the common case of someone pasting the snippet onto their own site.
      # See Ingest::HostnamePolicy for what it can and cannot achieve.
      policy = HostnamePolicy.new(site: site, url_host: url.host, origin: @origin).call
      unless policy.allowed?
        RejectionCounter.record(site_id: site.id, reason: policy.reason,
                                hostname: policy.offending_host)
        return Failure(policy.reason)
      end

      # The account's monthly allowance, checked HERE and deliberately not earlier.
      #
      # Everything above this line is an event we were never going to store: a
      # crawler, an unparseable URL, a hostname that is not the customer's. Billing
      # a customer's quota for traffic we throw away would be indefensible, and
      # would also make the number on their billing screen disagree with the number
      # on their dashboard. Everything below this line does get stored, so this is
      # the last honest place to count.
      #
      # The rejection is recorded rather than silent — see Ingest::RejectionCounter
      # on why an invisible rejection is worse than none — and surfaces on the site
      # settings screen as "Over plan limit". The response is still 202, like every
      # other outcome here.
      unless Billing::EventQuota.allow?(site.account_id)
        RejectionCounter.record(site_id: site.id, reason: "plan_limit")
        return Failure(:plan_limit)
      end

      identity = Identifier.new(site: site, ip: @ip, user_agent: @user_agent).call
      referrer = Referrer.new(@payload[:r], utm: utm_params(url), site_domain: site.domain)

      WriteBuffer.push(row(site, url, agent, identity, referrer))
      note_first_event(site)

      Success(identity)
    rescue *STORAGE_FAILURES => e
      # Reported, not hidden. See STORAGE_FAILURES for why the response is quiet
      # anyway.
      Sentry.capture_exception(e) if defined?(Sentry)
      Rails.logger.error("[tastatur] dropped an event, storage unavailable: #{e.class}: #{e.message}")

      Failure(:storage_unavailable)
    end

    private

    # Cached because this lookup happens on every single pageview across every
    # site. A miss is one indexed query; a hit costs nothing. The window is
    # short so that deleting a site stops collection promptly.
    def resolve_site
      SiteResolver.call(@payload[:s])
    end

    def row(site, url, agent, identity, referrer)
      {
        occurred_at: @received_at,
        site_id: site.id,
        event_name: @payload[:n].presence || Event::PAGEVIEW,
        visitor_hash: identity.visitor_hash,
        session_hash: identity.session_hash,
        is_entry: identity.entry?,
        hostname: url.host,
        path: normalize_path(site, url),
        country_code: Geolocation.country_code(@ip),
        screen_class: screen_class,
        revenue_cents: @payload[:v],
        currency: @payload[:c]&.upcase,
        props: @payload[:p].presence
      }.merge(referrer.to_h).merge(agent.to_h).merge(utm_params(url))
    end

    def parse_url
      URI.parse(@payload[:u].to_s)
    rescue URI::InvalidURIError
      nil
    end

    # Both of these delegate to PathScrubber, which strips personal data out of
    # the path as well as the query string — see that class for why the query
    # string alone is not enough. The site's declared route patterns let the
    # scrubber collapse dynamic segments exactly rather than by shape.
    def normalize_path(site, url)
      PathScrubber.call(url, patterns: site.path_patterns)
    end

    def utm_params(url)
      @utm_params ||= PathScrubber.query_params(url).slice(*UTM_KEYS)
    end

    def screen_class
      width = @payload[:w]
      return nil if width.blank? || width.to_i <= 0

      SCREEN_BUCKETS.find { |max, _| width.to_i < max }&.last
    end

    # Drives the "waiting for your first pageview" screen, and sends the
    # "your site is live" email exactly once.
    #
    # The exactly-once guarantee is the conditional UPDATE, not a Ruby check.
    # Under real ingest load several requests arrive in the same millisecond,
    # and every one of them would pass `if site.first_event_at.nil?`. Only one
    # can win `WHERE first_event_at IS NULL`, and update_all returns the number
    # of rows it changed — so a return value of 1 means this request is the one
    # that flipped it, and is therefore the one that notifies.
    def note_first_event(site)
      return if site.first_event_at.present?

      claimed = Site.where(id: site.id, first_event_at: nil)
                    .update_all(first_event_at: @received_at)

      Rails.cache.delete("site/token/#{@payload[:s]}")
      return unless claimed == 1

      # Enqueued, never sent inline: this is the ingest hot path and an SMTP
      # round trip has no business on it.
      NotifyFirstDataJob.perform_later(site.id)
    end
  end
end
