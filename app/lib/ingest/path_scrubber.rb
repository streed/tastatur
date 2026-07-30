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
    NUMERIC_SEGMENT = /\A\d{4,}\z/
    OPAQUE_SEGMENT = /\A[A-Za-z0-9\-_.]{25,}\z/

    # A four-digit number in this range is almost always a year, not a record
    # id, and date-based URLs are extremely common: /2026/07/roundup,
    # /blog/2025/hello. Collapsing those to /:id/:id/roundup would destroy the
    # top-pages report for every publication that organises by date, which is a
    # lot of them. Years are kept; everything else numeric and long enough to
    # look like an id is collapsed.
    YEAR_RANGE = (1900..2100).freeze

    module_function

    # Returns the storable path for a URI.
    def call(uri)
      path = uri.path.presence || "/"
      path = path.split("/").map { |segment| scrub_segment(segment) }.join("/")
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

    def scrub_segment(segment)
      return segment if segment.blank?

      decoded = begin
        CGI.unescape(segment)
      rescue StandardError
        segment
      end

      return ":email" if decoded.match?(EMAIL_SEGMENT)
      return ":uuid"  if decoded.match?(UUID_SEGMENT)
      return ":id"    if decoded.match?(NUMERIC_SEGMENT) && !year?(decoded)
      return ":hash"  if decoded.match?(HEX_SEGMENT)
      return ":token" if decoded.match?(OPAQUE_SEGMENT)

      segment
    end

    def year?(segment)
      segment.length == 4 && YEAR_RANGE.cover?(segment.to_i)
    end
  end
end
