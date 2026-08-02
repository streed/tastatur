module Ingest
  # Removes personal data that customer sites leak in their own URLs.
  #
  # This is the most under-appreciated hole in a privacy-first analytics tool.
  # Stripping the query string is necessary but nowhere near sufficient, because
  # real sites routinely put personal data in the PATH:
  #
  #   /users/alice@example.com/settings
  #   /reset-password/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
  #   /invoice/7f3a91c2-4b8e-4c1a-9f2d-1e5b8a7c3d90
  #   /player/51
  #
  # If those are persisted, the claim "we store no personal data about your
  # visitors" is false, and it is our fault rather than the customer's. So
  # every path is scrubbed here before it reaches the write buffer.
  #
  # The high-cardinality collapse is a reporting win as well as a privacy one:
  # a million distinct invoice URLs are useless as a "top pages" table, and
  # /invoice/:id is exactly what the site owner wanted to see.
  module PathScrubber
    MAX_LENGTH = 255

    # Query parameters that survive. Everything else is dropped.
    ALLOWED_PARAMS = %w[utm_source utm_medium utm_campaign utm_term utm_content ref].freeze

    # ...except these, which are dropped even if somehow allowlisted. A
    # deny-list that wins over the allowlist means a future widening of
    # ALLOWED_PARAMS cannot accidentally start capturing credentials.
    DENIED_PARAMS = %w[
      token code key secret password passwd pwd email phone access_token
      id_token refresh_token session sessionid auth authorization signature
      sig state otp nonce invite reset confirmation_token api_key
    ].freeze

    # A segment containing "@" is almost always an email address.
    EMAIL_SEGMENT = /@/

    # Long, high-entropy segments are ids or tokens rather than page names.
    # UUIDs, JWTs, hex digests, nanoids and base64 blobs all land here.
    UUID_SEGMENT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    HEX_SEGMENT = /\A[0-9a-f]{16,}\z/i
    NUMERIC_SEGMENT = /\A\d+\z/
    OPAQUE_SEGMENT = /\A[A-Za-z0-9\-_.]{25,}\z/

    # A numeric path segment is a record id — /player/51, /orders/5, /team/172 —
    # and it names an individual just as surely as /orders/1048576 does. The
    # digit COUNT is not what makes a number personal, so every numeric segment
    # collapses to :id, with exactly two exceptions, both about dates:
    #
    #   * A four-digit number in 1900..2100 is almost always a year, not a record
    #     id. Date-based URLs are extremely common (/2026/07/roundup,
    #     /blog/2025/hello) and collapsing the year would destroy the top-pages
    #     report for every publication that organises by date.
    #
    #   * The month and day that FOLLOW such a year (/2026/07/15/roundup) are
    #     also kept, but only there — a bare "07" or "15" with no preceding year
    #     is far more likely to be a record id or a page number than a date, so
    #     it collapses. This is why the scrub is position-aware rather than a
    #     per-segment regex: /player/51 must collapse while /2026/07 must not.
    #
    # The previous rule kept every 1-3 digit number to sidestep the year case,
    # which quietly published small sequential ids (/player/51) straight into the
    # Top pages table. That is the leak this shape exists to close.
    YEAR_RANGE = (1900..2100).freeze
    MONTH_RANGE = (1..12).freeze
    DAY_RANGE = (1..31).freeze

    module_function

    # Returns the storable path for a URI.
    def call(uri)
      path = uri.path.presence || "/"
      path = scrub_path(path)
      path = "/" if path.blank?
      path = path.chomp("/") if path.length > 1 && path.end_with?("/")
      path.first(MAX_LENGTH)
    end

    # Returns the utm_* values that survive, as a symbol-keyed hash.
    def query_params(uri)
      parsed = URI.decode_www_form(uri.query.to_s).to_h
      ALLOWED_PARAMS.index_with { |key| retain?(key, parsed) }.transform_keys(&:to_sym)
    rescue ArgumentError
      ALLOWED_PARAMS.index_with { nil }.transform_keys(&:to_sym)
    end

    def retain?(key, parsed)
      return nil if DENIED_PARAMS.include?(key)

      value = parsed[key].presence
      return nil if value.nil?
      # A "utm_campaign" that looks like a token is not a campaign name.
      return nil if value.match?(EMAIL_SEGMENT) || value.match?(OPAQUE_SEGMENT)

      value.first(255)
    end

    # Walks the segments left to right, carrying a small amount of state so the
    # month and day of a date-organised URL survive while an isolated numeric id
    # does not. `date_slot` is :none, :month (a year was just seen), or :day (a
    # month was just seen).
    def scrub_path(path)
      date_slot = :none
      path.split("/").map do |segment|
        scrubbed, date_slot = scrub_segment(segment, date_slot)
        scrubbed
      end.join("/")
    end

    def scrub_segment(segment, date_slot)
      return [segment, date_slot] if segment.blank?

      decoded = begin
        CGI.unescape(segment)
      rescue StandardError
        segment
      end

      return [":email", :none] if decoded.match?(EMAIL_SEGMENT)
      return [":uuid",  :none] if decoded.match?(UUID_SEGMENT)

      if decoded.match?(NUMERIC_SEGMENT)
        return [segment, :month] if year?(decoded)
        return [segment, next_date_slot(date_slot)] if date_part?(decoded, date_slot)

        return [":id", :none]
      end

      return [":hash",  :none] if decoded.match?(HEX_SEGMENT)
      return [":token", :none] if decoded.match?(OPAQUE_SEGMENT)

      [segment, :none]
    end

    def year?(segment)
      segment.length == 4 && YEAR_RANGE.cover?(segment.to_i)
    end

    # A numeric segment counts as a date part only when it sits right after a
    # year (a month) or right after that month (a day), and only when its value
    # is a plausible month or day. /2026/99 keeps the year and collapses the 99.
    def date_part?(segment, date_slot)
      return false if segment.length > 2

      case date_slot
      when :month then MONTH_RANGE.cover?(segment.to_i)
      when :day   then DAY_RANGE.cover?(segment.to_i)
      else false
      end
    end

    def next_date_slot(date_slot)
      date_slot == :month ? :day : :none
    end
  end
end
