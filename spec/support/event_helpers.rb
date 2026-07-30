# Helpers for writing events straight into the hypertable.
#
# Specs need backdated events, which the ingest path cannot produce (it always
# stamps the current time), and they need them without going through the Redis
# buffer. So they are inserted directly, via the same column list the write
# buffer uses, so a schema change breaks these helpers rather than silently
# leaving them writing the wrong shape.
module EventHelpers
  DEFAULTS = {
    event_name: "pageview",
    is_entry: false,
    hostname: "example.com",
    path: "/",
    referrer_host: nil,
    referrer_source: "Direct",
    utm_source: nil, utm_medium: nil, utm_campaign: nil, utm_term: nil, utm_content: nil,
    country_code: "DE",
    browser: "Firefox", browser_version: "128",
    os: "GNU/Linux", os_version: "6",
    device_type: "desktop",
    screen_class: "lg",
    revenue_cents: nil, currency: nil, props: nil
  }.freeze

  # create_event(site, path: "/pricing", visitor: "v1", at: 2.hours.ago)
  #
  # `visitor` and `session` are plain strings hashed into 16 bytes, so a spec
  # can say "the same visitor" without constructing digests by hand.
  def create_event(site, visitor: "visitor-1", session: nil, at: Time.current, **attrs)
    session ||= visitor

    row = DEFAULTS.merge(
      occurred_at: at,
      site_id: site.id,
      # Hex, not raw bytes. `WriteBuffer#quote` reverses the hex encoding that
      # `serialize` applies on the way into Redis, so it calls `[value].pack("H*")`
      # on whatever it is given. Handing it raw bytes does not fail — it silently
      # reinterprets them as hex digits and stores a mangled 8-byte value instead
      # of the real 16-byte hash.
      #
      # Nothing caught it because every assertion so far only needed hashes to be
      # *distinct*, and mangled ones still are. It matters for anything that
      # compares against a hash computed by Ingest::Identifier — a subject-access
      # lookup, for instance — which would never match.
      visitor_hash: digest(visitor).unpack1("H*"),
      session_hash: digest(session).unpack1("H*"),
      **attrs
    )

    Ingest::WriteBuffer.insert_all([row.stringify_keys])
  end

  # Bulk variant for the volume needed to clear a k-anonymity threshold.
  def create_events(site, count:, visitor_prefix: "visitor", **attrs)
    count.times { |i| create_event(site, visitor: "#{visitor_prefix}-#{i}", **attrs) }
  end

  def digest(seed)
    OpenSSL::Digest::SHA256.digest(seed.to_s).byteslice(0, 16)
  end

  def delete_all_events
    ActiveRecord::Base.connection.execute("DELETE FROM events")
  end
end

RSpec.configure do |config|
  config.include EventHelpers
end
