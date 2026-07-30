module Ingest
  # Counts opted-out requests, and nothing more.
  #
  # A site owner whose numbers are lower than another tool's will ask why. The
  # answer is often "some of your visitors send Do Not Track and we respect it",
  # and being unable to show that turns a feature into a suspected bug.
  #
  # So we keep a single integer per site per hour. There is no visitor hash, no
  # session, no IP, no user-agent — nothing that could reconstruct WHO objected.
  # Recording a per-visitor opt-out marker would mean keeping a durable
  # identifier for precisely the people who asked us not to, which is the
  # perverse outcome this design exists to avoid.
  #
  # It lives in Redis with a bounded TTL rather than PostgreSQL: it is a
  # diagnostic, not analytics, and it should disappear on its own.
  module OptOutCounter
    RETENTION = 45.days

    # The token is interpolated into a Redis key, and it arrives unauthenticated
    # from `params[:s]` on a path that runs before any site has been resolved.
    # `blank?` alone was the only check, so `DNT: 1` plus a fresh random token
    # created a new key on every request, each held for 45 days — an unbounded
    # write into a Redis configured not to evict.
    #
    # Shape first because it is free, then existence, because shape alone still
    # admits 32^16 distinct keys. The existence check reuses the same cached
    # lookup as the ingest path, so a real opt-out costs nothing extra and a
    # fabricated token costs one cache miss.
    #
    module_function

    def record(site_token:)
      return unless SiteResolver.exists?(site_token)

      key = key_for(site_token, Time.current)
      REDIS_POOL.with do |redis|
        redis.multi do |tx|
          tx.incr(key)
          tx.expire(key, RETENTION.to_i)
        end
      end
    rescue StandardError => e
      # A diagnostic counter must never be able to fail a request.
      Rails.logger.warn("[tastatur] opt-out counter failed: #{e.class}")
    end

    # Total opt-outs for a site over a window, for the dashboard footnote.
    def count_for(site, from:, to: Time.current)
      keys = (from.beginning_of_hour.to_i..to.to_i).step(1.hour).map do |epoch|
        key_for(site.public_token, Time.zone.at(epoch))
      end
      return 0 if keys.empty?

      REDIS_POOL.with { |redis| redis.mget(*keys) }.compact.sum(&:to_i)
    end

    def key_for(site_token, time)
      "tastatur:optout:#{site_token}:#{time.utc.strftime('%Y%m%d%H')}"
    end
  end
end
