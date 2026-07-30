# Shared, thread-safe Redis pool. Use REDIS_POOL.with { |r| r.get(...) }.
REDIS_POOL = ConnectionPool.new(size: ENV.fetch("REDIS_POOL_SIZE", 10).to_i, timeout: 3) do
  Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
end

# A SEPARATE Redis for the two secrets that must never touch disk: the rotating
# visitor salt, and the visitor -> session map derived from it.
#
# Why this cannot share the pool above. The main Redis persists (the ingest
# buffer holds real events, so losing it loses data). But the whole basis for
# calling our stored analytics unlinkable is that yesterday's salt is *gone* —
# and a salt that was written to an AOF or an RDB snapshot is not gone. It is
# sitting in a file, very likely inside a backup, next to the events it would
# de-anonymise. A point-in-time restore would resurrect it and silently
# invalidate the claim.
#
# So this instance runs with `--save "" --appendonly no --maxmemory-policy
# noeviction`, is excluded from every backup set, and holds nothing else. If it
# is lost, in-flight sessions restart and today's visitors are recounted once.
# That is a trivial cost and exactly the failure mode we want.
#
# Falls back to REDIS_URL when unset so a small self-hosted install still works
# out of the box — with a startup warning, because that configuration trades
# away the guarantee above.
PRIVACY_REDIS_POOL =
  if ENV["REDIS_PRIVACY_URL"].present?
    ConnectionPool.new(size: ENV.fetch("REDIS_POOL_SIZE", 10).to_i, timeout: 3) do
      Redis.new(url: ENV.fetch("REDIS_PRIVACY_URL"))
    end
  else
    Rails.logger.warn(
      "[tastatur] REDIS_PRIVACY_URL is not set — visitor salts will live in the main Redis, " \
      "which persists to disk. Set REDIS_PRIVACY_URL to a non-persistent instance so a " \
      "database or Redis backup cannot resurrect a destroyed salt. " \
      "See docs/privacy/identity.md."
    )
    REDIS_POOL
  end
