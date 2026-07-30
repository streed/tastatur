# Redis is not rolled back between examples, so anything the app keeps there has
# to be cleared explicitly.
#
# PostgreSQL state disappears with the transaction, which makes it easy to forget
# that these counters do not. They are keyed by site id and hour with a 30-day
# TTL, and test site ids are small numbers that recur every time the test
# database is rebuilt — so a counter written by one suite run was still there for
# the next, and an example expecting a count of 1 saw 4.
#
# The usage meter is the same trap with a longer fuse: its keys are keyed by
# account id and calendar month with a 62-day TTL, and `TRUNCATE ... RESTART
# IDENTITY` hands account id 1 to a different account. A leftover counter there
# does not just skew an assertion, it decides whether an event is recorded at all —
# so which examples pass would depend on the random seed.
#
# Cleared by prefix rather than with FLUSHDB, so a developer pointing the test
# suite at a Redis they also use for development does not lose their dev data.
RSpec.configure do |config|
  PREFIXES = %w[
    tastatur:rejected
    tastatur:rejected_hosts
    tastatur:optout
    tastatur:ingest
    tastatur:session
    tastatur:salt
    tastatur:usage
    tastatur:usage_notice
  ].freeze

  config.before do
    [REDIS_POOL, PRIVACY_REDIS_POOL].uniq.each do |pool|
      pool.with do |redis|
        keys = PREFIXES.flat_map { |prefix| redis.keys("#{prefix}*") }
        redis.del(*keys) if keys.any?
      end
    end

    # The quota gate also caches each account's limit IN THE PROCESS for a minute,
    # which outlives both the transaction and the Redis reset. Combined with
    # RESTART IDENTITY reusing account ids, a stale entry would apply one account's
    # plan to another.
    Billing::EventQuota.clear!
  end
end
