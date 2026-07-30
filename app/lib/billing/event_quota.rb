module Billing
  # The gate on the ingest path: may this account's next event be recorded?
  #
  # This runs once per pageview across every site on the instance, so its budget
  # is one Redis command and no SQL. It gets there by caching each account's limit
  # IN THE PROCESS rather than in Rails.cache — a cache lookup in production is
  # itself a Redis round trip, and this value changes about once a year per
  # account. The cost of that choice is that a plan change takes up to
  # CACHE_TTL_SECONDS to be noticed by an already-warm process, which is the same
  # bargain Ingest::SiteResolver strikes for site deletion and is stated on the
  # billing screen ("upgrades apply within a minute").
  #
  # Self-hosted installs return early and touch neither the database nor Redis, so
  # ingest there costs exactly what it did before billing existed.
  module EventQuota
    CACHE_TTL_SECONDS = 60

    # A bound on the process-local cache so a very large instance cannot grow it
    # without limit. Cleared wholesale rather than evicted one at a time: this is a
    # 60-second cache of a single integer, so the cost of a cold refill is one
    # query per active account, and an LRU would be more machinery than the
    # problem deserves.
    MAX_CACHED_ACCOUNTS = 20_000

    # account_id => [limit, monotonic_expiry]
    CACHE = Concurrent::Map.new

    module_function

    # True when the event may be recorded. Increments the meter either way, because
    # what the meter counts is events received — see Billing::UsageMeter.
    #
    # FAILS OPEN. If Redis cannot answer, the event is recorded and the incident is
    # reported. This is not a swallowed error: a metering outage must not stop a
    # paying customer's measurement, and the alternative — refusing traffic because
    # we cannot count it — turns a monitoring problem into data loss. The same
    # Redis is needed by the write buffer two lines later, so in practice a real
    # outage stops ingest anyway, via Ingest::RecordEvent's own handling.
    def allow?(account_id, at: Time.current)
      limit = limit_for(account_id)
      return true if limit == Billing::Plan::UNLIMITED

      UsageMeter.record(account_id, at: at) <= limit
    rescue StandardError => e
      Sentry.capture_exception(e) if defined?(Sentry)
      Rails.logger.error("[tastatur] event quota check failed, recording anyway: #{e.class}: #{e.message}")
      true
    end

    # The account's cap, from the process-local cache.
    def limit_for(account_id)
      return Billing::Plan::UNLIMITED unless Tastatur.billing_enabled?
      return Billing::Plan::UNLIMITED if account_id.blank?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = CACHE[account_id]
      return cached.first if cached && cached.last > now

      limit = fetch_limit(account_id)
      CACHE.clear if CACHE.size >= MAX_CACHED_ACCOUNTS
      CACHE[account_id] = [limit, now + CACHE_TTL_SECONDS]
      limit
    end

    # An account that no longer exists gets no cap.
    #
    # Deleting a site cascades from the account, and Ingest::SiteResolver caches
    # site lookups for a minute, so this window is the same one that already lets a
    # deleted site's last few events through. Enforcing a limit of zero here would
    # be a different behaviour change, smuggled in under a billing feature.
    def fetch_limit(account_id)
      Account.find_by(id: account_id)&.event_limit || Billing::Plan::UNLIMITED
    end

    # Drops the cached limit for one account. Called after a subscription change so
    # the process that handled the webhook stops enforcing the old plan
    # immediately; every other process still waits out CACHE_TTL_SECONDS, which is
    # why the UI promises a minute rather than instant.
    def forget(account_id)
      CACHE.delete(account_id)
    end

    def clear!
      CACHE.clear
    end
  end
end
