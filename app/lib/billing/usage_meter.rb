module Billing
  # How many events an account has been sent this month.
  #
  # WHY A REDIS COUNTER AND NOT A QUERY. The number is needed on the ingest path,
  # once per event, to decide whether the event is inside the account's plan. The
  # authoritative answer lives in the events_by_hour aggregate, and a SUM over a
  # month of it costs milliseconds — which is several orders of magnitude too much
  # to spend per pageview. So the hot path increments an integer, and
  # Billing::ReconcileUsage repairs that integer from the aggregate every hour.
  #
  # WHAT THE NUMBER MEANS: events *attributed* to the account, including any
  # refused for being over the limit. Not "events stored". That is deliberate and
  # it is what makes one counter enough — the refused count is
  # `max(0, used - limit)`, so nothing has to be tracked twice, and the billing
  # screen can say "we received 118,402 events; your plan covers 100,000" rather
  # than the uselessly self-fulfilling "you used exactly your limit".
  #
  # Bots and events refused by the hostname policy are counted by neither, because
  # the meter is only reached after those gates — see Ingest::RecordEvent. Charging
  # a customer's quota for crawler traffic we then throw away would be indefensible.
  #
  # THE MONTH IS THE CALENDAR MONTH IN UTC, not the subscription's billing period.
  # The free plan has no billing period at all, so a period-aligned window would
  # need two implementations of "this month" and the free one would be arbitrary
  # anyway. It also means the window is always defined even when a webhook is late,
  # and it can only ever be generous: a customer who subscribes on the 14th gets
  # the rest of that month plus a fresh allowance on the 1st. Erring towards the
  # customer is the right direction for a quota to err in.
  module UsageMeter
    PREFIX = "tastatur:usage".freeze

    # Long enough that last month's figure is still readable throughout this
    # month, which is what the billing screen compares against. Short enough that
    # the key space is bounded at roughly two rows per account.
    TTL = 62.days

    module_function

    # "202607". Month granularity is the whole point, so the key is the month.
    def period_key(at = Time.current)
      at.utc.strftime("%Y%m")
    end

    def key(account_id, at = Time.current)
      "#{PREFIX}:#{account_id}:#{period_key(at)}"
    end

    # The UTC calendar month containing `at`, as [start, finish). Used by the
    # reconciler to bound its aggregate query and by the UI to say which window
    # the number covers.
    def period_bounds(at = Time.current)
      start = at.utc.beginning_of_month
      [start, start + 1.month]
    end

    # Called once per event on the ingest path. Returns the new total.
    #
    # The EXPIRE is issued only when INCR returns 1 — i.e. only on the first event
    # of the month for this account — so the steady-state cost really is one Redis
    # command. Setting it every time would double the traffic on the hottest path
    # in the application to re-assert a TTL that has not changed.
    def record(account_id, at: Time.current, count: 1)
      redis_key = key(account_id, at)

      total = REDIS_POOL.with do |redis|
        new_total = redis.incrby(redis_key, count)
        redis.expire(redis_key, TTL.to_i) if new_total == count
        new_total
      end

      total
    end

    def used(account_id, at: Time.current)
      REDIS_POOL.with { |redis| redis.get(key(account_id, at)) }.to_i
    end

    # Brings the counter up to what the database actually holds.
    #
    # ONE-WAY, UPWARD ONLY. The counter counts events received; the aggregate
    # counts events stored; the first is always greater than or equal to the
    # second, because refused and buffer-lost events are in one and not the other.
    # So a counter *below* the stored total is drift that must be repaired — Redis
    # was flushed, or a deploy dropped increments — while a counter above it is
    # simply the truth. Lowering it would hand back quota that was genuinely
    # consumed, and worse, would do so repeatedly: an account parked at its limit
    # would be reset to its limit every hour and let another hour of events
    # through, forever.
    #
    # INCRBY rather than SET, so events arriving during the repair are added on top
    # instead of being overwritten by a value read a moment earlier.
    def repair(account_id, recorded:, at: Time.current)
      redis_key = key(account_id, at)

      REDIS_POOL.with do |redis|
        current = redis.get(redis_key).to_i
        shortfall = recorded - current
        next current if shortfall <= 0

        total = redis.incrby(redis_key, shortfall)
        redis.expire(redis_key, TTL.to_i)
        total
      end
    end

    # Test and support hook. Not called from application code — the counter is
    # supposed to be corrected by `repair`, never cleared, because clearing it is
    # indistinguishable from giving away a month of quota.
    def reset!(account_id, at: Time.current)
      REDIS_POOL.with { |redis| redis.del(key(account_id, at)) }
    end
  end
end
