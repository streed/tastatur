module Ingest
  # Turns a public site token into a Site, cheaply and safely.
  #
  # Three places on the ingest path need this — recording an event, counting an
  # opt-out, and counting a malformed payload — and they were each growing their
  # own copy. Two of them had already drifted: the opt-out counter interpolated an
  # unvalidated token straight into a Redis key, which let anyone create unbounded
  # keys with a 45-day TTL just by sending a random one.
  #
  # SHAPE FIRST, THEN EXISTENCE. The shape check is free and rejects the overwhelming
  # majority of junk without touching the cache or the database. Existence is a
  # 60-second cached lookup shared with every other caller, so a real request pays
  # nothing extra and a fabricated token costs one miss.
  module SiteResolver
    # 60 seconds is short enough that deleting a site takes effect promptly and long
    # enough that the hottest lookup in the application is almost always a hit.
    TTL = 60.seconds

    TOKEN_CHARS = Site::TOKEN_ALPHABET.join.freeze

    module_function

    # Returns the Site, or nil.
    def call(token)
      return nil unless well_formed?(token)

      Rails.cache.fetch(cache_key(token), expires_in: TTL) do
        Site.find_by(public_token: token)
      end
    end

    def exists?(token)
      call(token).present?
    end

    # Character-set membership rather than a regular expression: both operands are
    # frozen constants, and `delete` says the same thing without a pattern for
    # Brakeman to flag as a RegexDoS candidate.
    def well_formed?(token)
      return false unless token.is_a?(String)

      token.length == Site::TOKEN_LENGTH && token.delete(TOKEN_CHARS).empty?
    end

    def cache_key(token)
      "site/token/#{token}"
    end
  end
end
