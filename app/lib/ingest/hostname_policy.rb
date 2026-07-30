module Ingest
  # Decides whether an event may be attributed to a site.
  #
  # THE PROBLEM THIS BOUNDS, and it cannot be closed completely.
  #
  # The site token is public: it is in the HTML of every page it measures. Anyone
  # can read it and POST events with it. That is inherent to client-side
  # analytics and is equally true of Google Analytics' measurement ID,
  # Plausible's domain and Fathom's site ID. No amount of validation makes a
  # public identifier secret.
  #
  # What validation does achieve:
  #
  #   1. An event can no longer be attributed to an arbitrary hostname. Before
  #      this, `u=https://attacker.example.net/` with a stolen token stored a row
  #      against the victim's site under that hostname, polluting every breakdown.
  #      Now the claimed host must plausibly belong to the site.
  #
  #   2. The realistic attack — someone pastes your snippet onto their own site —
  #      is caught by the Origin header. A browser sets Origin on a cross-origin
  #      POST and JavaScript cannot forge it, so a mismatched Origin from a real
  #      browser is strong evidence of exactly that. curl can omit Origin, which
  #      is why a missing Origin is allowed (the server-side API depends on it)
  #      and only a PRESENT, MISMATCHED one is rejected.
  #
  #   3. What remains possible is someone spoofing your real domain from a script.
  #      That is bounded by the rate limits, confined to plausible-looking pages,
  #      and reversible with `rails tastatur:events:purge`. It is not preventable,
  #      and the docs say so rather than implying otherwise.
  # `offending_host` is the host that caused the rejection, which is NOT always
  # the URL's host. For an Origin mismatch the URL usually claims the victim's own
  # domain, so recording that would show the owner their own hostname in the
  # refused list and tell them nothing. The useful value is the Origin.
  Result = Struct.new(:allowed, :reason, :offending_host, keyword_init: true) do
    def allowed? = allowed
  end

  class HostnamePolicy
    def initialize(site:, url_host:, origin: nil)
      @site = site
      @url_host = normalize(url_host)
      @origin_host = normalize(origin_host_from(origin))
    end

    def call
      return Result.new(allowed: true, reason: :enforcement_disabled) unless @site.enforce_hostname?

      # A browser-set Origin is the highest-value signal available, so it is
      # checked first: if it is present and wrong, the claimed URL is untrusted
      # regardless of what it says.
      if @origin_host.present? && !permitted?(@origin_host)
        return Result.new(allowed: false, reason: :origin_mismatch, offending_host: @origin_host)
      end

      unless permitted?(@url_host)
        return Result.new(allowed: false, reason: :hostname_mismatch, offending_host: @url_host)
      end

      Result.new(allowed: true, reason: :ok)
    end

    private

    # Accepted: the domain itself, its www form, any subdomain of it, and any
    # explicitly configured extra hostname (plus subdomains of those).
    #
    # Subdomains are accepted without configuration because app., blog., docs.
    # and shop. are how real sites are actually laid out, and a policy that
    # rejected them would be switched off by everyone on day one. A separate
    # domain still has to be declared, because no rule can infer it.
    def permitted?(host)
      return false if host.blank?

      candidates.any? { |allowed| host == allowed || host.end_with?(".#{allowed}") }
    end

    def candidates
      @candidates ||= ([@site.domain] + @site.extra_hostnames.to_a)
                      .compact_blank
                      .map { |h| normalize(h) }
                      .compact_blank
                      .uniq
    end

    def normalize(host)
      return nil if host.blank?

      host.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first.to_s
          .sub(/:\d+\z/, "").sub(/\Awww\./, "").chomp(".").presence
    end

    def origin_host_from(origin)
      return nil if origin.blank?
      # "null" is what a browser sends for an opaque origin, e.g. a sandboxed
      # iframe or a file:// page. It tells us nothing, so treat it as absent.
      return nil if origin == "null"

      URI.parse(origin).host
    rescue URI::InvalidURIError
      nil
    end
  end
end
