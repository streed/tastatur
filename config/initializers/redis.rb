# Shared, thread-safe Redis pool. Use REDIS_POOL.with { |r| r.get(...) }.
REDIS_POOL = ConnectionPool.new(size: ENV.fetch("REDIS_POOL_SIZE", 10).to_i, timeout: 3) do
  Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
end
