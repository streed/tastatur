module Ingest
  # Turns a request into an Ingest::Identity, and forgets everything it used.
  #
  # This is the single point in the system where an IP address is touched. It
  # is passed in, mixed into a digest, and dropped when this method returns —
  # it is never assigned to an attribute, logged, or written anywhere. If you
  # are about to add a line here that stores `ip` or `user_agent`, that is the
  # line that breaks the product's central promise.
  class Identifier
    DIGEST_BYTES = 16

    # Takes the Site rather than its id, because the salt now rolls over at the
    # site's own local midnight and only the record knows which zone that is.
    # See Ingest::SaltStore for why the rollover follows the reporting day.
    def initialize(site:, ip:, user_agent:)
      @site = site
      @site_id = site.id
      @ip = normalize_ip(ip)
      @user_agent = user_agent.to_s
    end

    def call
      visitor = digest(SaltStore.current(@site))

      session, is_new = SessionWindow.new(site_id: @site_id, visitor_hash: visitor).resolve do
        # Called only when there is no live session under today's hash. Before
        # declaring a genuinely new visit, check whether this person already
        # had a session under YESTERDAY's salt: without this, every visitor
        # online at the moment of rotation would be counted twice and every
        # session in flight would be cut in half.
        previous_salt = SaltStore.previous(@site)
        previous_salt && SessionWindow.new(site_id: @site_id, visitor_hash: digest(previous_salt)).existing
      end

      Identity.new(visitor_hash: visitor, session_hash: session, new_session: is_new)
    end

    private

    # HMAC, not SHA256(salt || message).
    #
    # The bare-concatenation form is length-extension weak: given a digest and
    # the message length, an attacker can compute the digest of an extended
    # message without knowing the salt. Nothing in our threat model obviously
    # exploits that, but HMAC is the construction designed for keyed hashing,
    # costs the same, and removes the question entirely.
    #
    # site_id is part of the message so the same person visiting two different
    # customers' sites produces two unrelated hashes. Without it, one customer
    # could test a hash against their own traffic to learn whether a specific
    # visitor had also been to another customer's site.
    #
    # Truncated to 128 bits — far beyond collision risk for one site-day, and
    # holding less of the digest means holding less of a re-identification
    # handle.
    def digest(salt)
      OpenSSL::HMAC.digest(
        "SHA256", salt, "#{@site_id}\x00#{@ip}\x00#{@user_agent}"
      ).byteslice(0, DIGEST_BYTES)
    end

    # IPv6 is reduced to its /64 network prefix before hashing.
    #
    # RFC 4941 privacy extensions rotate the interface identifier — the low 64
    # bits — periodically and on every network join. Hashing the full address
    # would therefore mint a brand-new "visitor" for the same person several
    # times a day and badly inflate the visitor count. The /64 is the network
    # they are on, which is the part that behaves like an IPv4 address.
    #
    # IPv4 is used whole. It is never stored either way.
    def normalize_ip(ip)
      address = IPAddr.new(ip.to_s)
      address.ipv6? ? address.mask(64).to_s : address.to_s
    rescue IPAddr::InvalidAddressError, ArgumentError
      # An unparseable address still needs to hash to something stable so the
      # request is counted; it just cannot be normalised.
      ip.to_s
    end
  end
end
