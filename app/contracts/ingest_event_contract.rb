# Validates the payload posted by the tracking script.
#
# This is the only genuinely untrusted input in the system: it arrives from
# arbitrary browsers on arbitrary sites, cross-origin, with no authentication
# beyond a public site token that is visible in the page source. Everything it
# contains is either bounded here or discarded.
#
# The short key names are not obfuscation — they are the difference between a
# ~180 byte and a ~260 byte beacon on every pageview of every customer site.
class IngestEventContract < Dry::Validation::Contract
  MAX_URL = 2_048
  MAX_NAME = 120
  MAX_PROPS = 24
  MAX_PROP_KEY = 60
  MAX_PROP_VALUE = 500

  # `revenue_cents` is an int4, so this is the column's ceiling rather than a
  # policy choice. Without it a value above 2^31-1 passed validation and then
  # failed on INSERT with PG::NumericValueOutOfRange, and because a failed batch
  # was returned to the buffer and retried forever, that one event stopped
  # every site's events from being written. Reachable without hostility: a
  # purchase in a minor-unit currency like IDR or VND can exceed this.
  MAX_REVENUE = 2_147_483_647

  # Text fields that end up in PostgreSQL `text` columns.
  TEXT_KEYS = %i[u n r c].freeze

  params do
    required(:s).filled(:string, size?: Site::TOKEN_LENGTH)  # site token
    required(:u).filled(:string, max_size?: MAX_URL)         # current URL
    optional(:n).filled(:string, max_size?: MAX_NAME)        # event name
    optional(:r).maybe(:string, max_size?: MAX_URL)          # referrer
    optional(:w).maybe(:integer, gteq?: 0, lteq?: 20_000)    # screen width
    optional(:p).maybe(:hash)                                # custom properties
    optional(:c).maybe(:string, format?: /\A[A-Za-z]{3}\z/)  # revenue currency
    optional(:v).maybe(:integer, gteq?: 0, lteq?: MAX_REVENUE) # revenue, minor units
  end

  # PostgreSQL `text` cannot hold a NUL byte, and libpq refuses invalid UTF-8
  # before a query is even sent. Both raise on INSERT, not here, which used to be
  # a denial of service for the whole instance rather than a bad row: the ingest
  # buffer is shared by every site, a failed batch was pushed back onto it, and
  # the job retried forever. One request carrying a JSON-escaped \u0000 in an event name
  # stopped all analytics writes, and still answered 202.
  #
  # Rejecting here is the honest boundary. Ingest::WriteBuffer also scrubs, so a
  # future field added to the contract cannot reintroduce this, but the buffer's
  # scrub is silent where this is counted and visible.
  rule(*TEXT_KEYS) do
    TEXT_KEYS.each do |text_key|
      text = values[text_key]
      next unless text.is_a?(String)

      if text.include?("\u0000")
        key(text_key).failure("must not contain a null byte")
      elsif !text.valid_encoding?
        key(text_key).failure("must be valid UTF-8")
      end
    end
  end

  rule(:u) do
    uri = URI.parse(value)
    key.failure("must be an absolute http(s) URL") unless uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    key.failure("is not a valid URL")
  end

  # Custom properties are the one open-ended field, so they are bounded hard.
  # An unbounded props hash would let any visitor to any customer's site write
  # arbitrary volumes of arbitrary text into our database.
  rule(:p) do
    next if value.blank?

    key.failure("supports at most #{MAX_PROPS} properties") if value.size > MAX_PROPS

    value.each do |prop_key, prop_value|
      if prop_key.to_s.length > MAX_PROP_KEY
        key.failure("property names must be #{MAX_PROP_KEY} characters or fewer")
        break
      end

      unless prop_value.is_a?(String) || prop_value.is_a?(Numeric) ||
             prop_value.is_a?(TrueClass) || prop_value.is_a?(FalseClass) || prop_value.nil?
        key.failure("property values must be strings, numbers or booleans")
        break
      end

      if prop_value.is_a?(String) && prop_value.length > MAX_PROP_VALUE
        key.failure("property values must be #{MAX_PROP_VALUE} characters or fewer")
        break
      end
    end
  end

  # Revenue only means something with a currency attached; a bare number would
  # silently mix euros and yen in the same total.
  rule(:v, :c) do
    key(:c).failure("is required when a revenue value is sent") if values[:v].present? && values[:c].blank?
  end
end
