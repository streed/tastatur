# Rack::Attack is OFF by default in specs, and ON only for examples tagged
# `:throttled`, whose counters are cleared before and after.
#
# This became necessary when the throttle store moved from Rails.cache to Redis.
# That change is correct for production — a FileStore counter is per-process and
# per-replica, so a "600 per minute" limit silently became 600 × replicas — but
# it also means counters now persist across examples and across whole suite runs.
# The first symptom was a signup spec failing with 429 because earlier examples
# had already spent the five-per-hour allowance.
#
#   it "throttles the ingest endpoint", :throttled do
#
# One hook, keyed on metadata, rather than a global `before` plus an `around`.
# RSpec runs `before` hooks INSIDE the `around` block's `example.run`, so a
# global `before { enabled = false }` silently undoes an `around` that had just
# enabled it — which is exactly the bug this comment exists to prevent someone
# reintroducing.
RSpec.configure do |config|
  config.before do |example|
    throttled = example.metadata[:throttled].present?
    Rack::Attack.enabled = throttled
    Rack::Attack.cache.store.clear if throttled
  end

  config.after do |example|
    Rack::Attack.cache.store.clear if example.metadata[:throttled].present?
    Rack::Attack.enabled = false
  end
end
