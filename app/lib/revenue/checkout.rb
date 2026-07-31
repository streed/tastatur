module Revenue
  # Attribution passed THROUGH Stripe, on the Checkout Session's metadata.
  #
  # THIS IS THE MECHANISM THAT MAKES REVENUE ATTRIBUTION SURVIVE REALITY. The
  # browser knows where somebody came from; the payment happens somewhere else,
  # possibly days later, possibly on a different device, possibly through a bank
  # redirect that never returns. Anything that tries to reconnect those two ends
  # with a session, a cookie or a hash is reconnecting them with something that is
  # allowed to disappear — and in this product the identifier is *designed* to
  # disappear, every midnight.
  #
  # So it is not reconnected at all. The attribution travels with the payment,
  # inside the payment, as metadata Stripe stores and hands back on every event
  # about that subscription forever.
  #
  # The customer's app does this at the point it creates the session:
  #
  #   Stripe::Checkout::Session.create(
  #     mode: "subscription",
  #     line_items: [...],
  #     client_reference_id: current_user.id,
  #     metadata: Revenue::Checkout.metadata(current_user.tastatur_attribution)
  #   )
  #
  # THE KEYS ARE PREFIXED, and that is not tidiness. Metadata is a flat namespace
  # the customer already uses for their own things, and an unprefixed `source` key
  # would collide with theirs — silently, in whichever direction the last writer
  # went. `tst_` makes the collision impossible and makes our keys obvious to
  # somebody reading a payment in the Stripe dashboard wondering what they are.
  module Checkout
    PREFIX = "tst_".freeze

    # The subset of attribution worth spending metadata slots on. Stripe allows 50
    # key/value pairs per object and the customer needs most of them for their own
    # purposes; taking eight and leaving forty-two is the polite split.
    #
    # `referrer_host` IS ON THIS LIST, and leaving it off was a real bug worth
    # naming: `tastatur.attribution()` returns a bare referrer host and no source
    # whenever a visit carries no UTM tags — which is every piece of organic and
    # word-of-mouth traffic there is. Without this key that host was dropped on the
    # way into Stripe, so the customer created from `checkout.session.completed`
    # arrived with nothing to classify and fell back to Direct.
    #
    # The result would have been a report where every tagged campaign was
    # attributed correctly and every untagged referral was silently relabelled as
    # direct traffic — which is both the largest bucket on most sites and the one
    # people are actually trying to measure.
    FIELDS = %i[source medium campaign content term landing_path referrer_host first_seen_at].freeze

    # Stripe's own limits, enforced here rather than discovered at their API.
    # A value over 500 characters fails the whole Checkout Session — which means
    # our analytics helper would break the customer's checkout, the single worst
    # thing this library could do. Truncation is the right trade: a campaign name
    # clipped at 500 characters is still the campaign.
    MAX_VALUE_LENGTH = 500

    module_function

    # Builds the metadata hash. String keys and string values, because that is
    # what Stripe stores — a Time or an Integer put in here comes back as a
    # string anyway, and doing the conversion at this end means the round trip is
    # symmetrical.
    def metadata(attribution)
      return {} if attribution.blank?

      source = attribution.respond_to?(:to_h) ? attribution.to_h : attribution
      source = source.symbolize_keys

      FIELDS.each_with_object({}) do |field, result|
        value = serialize(source[field])
        next if value.blank?

        result["#{PREFIX}#{field}"] = value.truncate(MAX_VALUE_LENGTH)
      end
    end

    # The inverse, applied to metadata coming back on any Stripe object.
    #
    # Returns a hash suitable for IdentifyContract's `attribution` block, so the
    # value travelling out and the value coming back have exactly one shape.
    def extract_attribution(metadata)
      return {} if metadata.blank?

      pairs = metadata.respond_to?(:to_h) ? metadata.to_h : metadata
      pairs = pairs.transform_keys(&:to_s)

      FIELDS.each_with_object({}) do |field, result|
        value = pairs["#{PREFIX}#{field}"]
        next if value.blank?

        result[field] = field == :first_seen_at ? parse_time(value) : value
      end.compact
    end

    def serialize(value)
      case value
      when nil then nil
      when Time, DateTime, ActiveSupport::TimeWithZone then value.iso8601
      else value.to_s
      end
    end

    # A malformed timestamp yields nil rather than raising.
    #
    # This value came from a third party's metadata, through a customer's own
    # application, and an unparseable one must not be able to fail a webhook — the
    # rest of the attribution is still good, and refusing all of it over the
    # timestamp would discard the part that matters to keep the part that does not.
    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
