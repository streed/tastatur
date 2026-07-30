# Redis is not rolled back between examples, so anything the app keeps there has
# to be cleared explicitly.
#
# PostgreSQL state disappears with the transaction, which makes it easy to forget
# that these counters do not. They are keyed by site id and hour with a 30-day
# TTL, and test site ids are small numbers that recur every time the test
# database is rebuilt — so a counter written by one suite run was still there for
# the next, and an example expecting a count of 1 saw 4.
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
  ].freeze

  config.before do
    [REDIS_POOL, PRIVACY_REDIS_POOL].uniq.each do |pool|
      pool.with do |redis|
        keys = PREFIXES.flat_map { |prefix| redis.keys("#{prefix}*") }
        redis.del(*keys) if keys.any?
      end
    end
  end
end
