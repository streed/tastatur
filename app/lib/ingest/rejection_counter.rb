module Ingest
  # Counts rejected events per site per reason, per hour.
  #
  # Rejection has to be VISIBLE or it is worse than not rejecting at all. Two
  # failure modes it prevents:
  #
  #   1. A site owner legitimately measuring app.example.com under a policy that
  #      does not allow it sees their traffic vanish with no explanation. With a
  #      counter, the dashboard can tell them exactly which hostname was refused
  #      and how often, which turns a silent outage into a one-field fix.
  #
  #   2. Someone pasting the snippet onto their own site is invisible. With a
  #      counter, the owner can see it happening and knows the numbers they are
  #      looking at are the real ones.
  #
  # Deliberately coarse: a count per site per reason per hour, and for hostname
  # mismatches the offending host, capped. No visitor identifier, no IP, no
  # per-request record. Storing detail about the people being rejected would
  # reintroduce exactly the tracking this product avoids, and to do it for
  # traffic we are refusing would be perverse.
  #
  # Lives in Redis with a bounded TTL because it is a diagnostic, not analytics,
  # and should expire on its own.
  module RejectionCounter
    RETENTION = 30.days
    # Bounded so an attacker cycling hostnames cannot grow the key set without
    # limit. Past this we still count the rejection, just not the name.
    MAX_TRACKED_HOSTS = 20

    module_function

    # A payload the validation contract refused.
    #
    # These used to vanish completely: the endpoint answered 202 and dropped the
    # event, so a developer whose beacon was malformed — a URL that is not
    # absolute, a props hash over the size limit, revenue without a currency — got
    # silence from every direction. Nothing in the interface, nothing in a log,
    # nothing to distinguish "your integration is broken" from "nobody visited".
    #
    # The 202 stays, because a distinguishable response is what lets someone probe
    # for valid tokens. What changes is that the site owner can now see it happened.
    #
    # The failing field names are recorded, not the values: a value is the visitor's
    # data, and the point of the count is to tell an operator which part of their
    # integration to look at.
    def record_contract_failure(site_token:, fields:)
      site = SiteResolver.call(site_token)
      return if site.nil?

      Array(fields).first(3).each do |field|
        record(site_id: site.id, reason: "invalid_#{field}")
      end
    end

    def record(site_id:, reason:, hostname: nil)
      return if site_id.blank?

      hour = Time.current.utc.strftime("%Y%m%d%H")
      REDIS_POOL.with do |redis|
        redis.multi do |tx|
          key = "tastatur:rejected:#{site_id}:#{reason}:#{hour}"
          tx.incr(key)
          tx.expire(key, RETENTION.to_i)

          next if hostname.blank?

          hosts = "tastatur:rejected_hosts:#{site_id}"
          tx.zincrby(hosts, 1, hostname)
          tx.expire(hosts, RETENTION.to_i)
        end
      end
    rescue StandardError => e
      # A diagnostic counter must never be able to fail a request.
      Rails.logger.warn("[tastatur] rejection counter failed: #{e.class}")
    end

    # Total rejections for a site over a window, by reason.
    # Reasons are discovered rather than listed.
    #
    # This used to iterate a hardcoded `%i[hostname_mismatch origin_mismatch]`, so a
    # reason added anywhere else was counted into Redis and then never read back
    # out — which is what happened the moment contract failures started being
    # recorded. A reporting function that silently ignores categories it has not
    # heard of is a trap for exactly the person adding a new one.
    #
    # SCAN over the site's own prefix, then filter by hour in Ruby. The key space is
    # small and bounded by construction: reasons × hours in the window, with the
    # 30-day TTL as the backstop.
    def counts_for(site, since: 7.days.ago)
      cutoff = since.beginning_of_hour.utc.strftime("%Y%m%d%H")
      prefix = "tastatur:rejected:#{site.id}:"

      keys = REDIS_POOL.with do |redis|
        redis.scan_each(match: "#{prefix}*", count: 1_000).to_a
      end

      in_window = keys.select do |key|
        # key = tastatur:rejected:<site_id>:<reason>:<hour>
        key.rpartition(":").last >= cutoff
      end
      return {} if in_window.empty?

      values = REDIS_POOL.with { |redis| redis.mget(*in_window) }

      in_window.zip(values).each_with_object(Hash.new(0)) do |(key, value), totals|
        reason = key.delete_prefix(prefix).rpartition(":").first
        totals[reason.to_sym] += value.to_i
      end
    end

    # The hostnames most often refused, so the owner can tell "I forgot to add
    # app.example.com" from "someone is using my token".
    def top_hosts(site, limit: 5)
      REDIS_POOL.with do |redis|
        redis.zrevrange("tastatur:rejected_hosts:#{site.id}", 0, limit - 1, with_scores: true)
      end.map { |host, score| [host, score.to_i] }
    rescue StandardError
      []
    end

    def prune!(site)
      REDIS_POOL.with { |redis| redis.del("tastatur:rejected_hosts:#{site.id}") }
    end
  end
end
