# Cross-origin access.
#
# TWO RESOURCES, NOT ONE `/api/*`, and the split is the whole content of this
# file.
#
# The wildcard belongs to ingest and to nothing else. CLAUDE.md §12 makes that
# argument in full: the site token is public by construction — it is pasted into
# a script tag on a page anyone can view the source of — so an origin allowlist
# protects nothing and breaks every legitimate setup we cannot predict, from
# staging domains and reverse proxies to AMP caches and apps in an iframe.
# Api::EventsController sets the same headers itself, for the requests that
# reach it before this middleware would.
#
# NONE OF THAT REASONING SURVIVES THE MOVE TO /api/v1. That path is
# authenticated by an ApiKey — bcrypt-digested, shown once, revocable — and
# `resource "/api/*"` matched it too, so every deployment was announcing to
# every browser on the internet that it would accept an `Authorization` header
# from any origin on the endpoint that WRITES IDENTIFIABLE PEOPLE (§18). It is
# not exploitable on its own, because credentials are not allowed and so no
# cookie is ever sent, and a caller without the key gets nowhere. It simply
# granted more than the decision above intended, in the one place that decision
# was never about.
#
# The v1 API is server-to-server. A browser is not its client, so it is given no
# CORS grant at all rather than a narrower one: an allowlist here would be a
# list nobody maintains of origins that should not be calling it anyway. A
# deployment with a genuine browser client sets API_CORS_ORIGINS and gets an
# explicit allowlist, never `*` — a wildcard on an authenticated endpoint is the
# thing this file exists to stop being accidental.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # CORS_ORIGINS keeps exactly the meaning it always had — the ingest
    # origins — so no existing deployment changes behaviour because of this
    # split. The v1 API gets a new variable of its own below.
    origins ENV.fetch("CORS_ORIGINS", "*").split(",").map(&:strip)

    # Listed literally rather than as a glob. These two paths are baked into
    # script tags on pages we do not control and can never change, which is why
    # they have no version segment — and it is also why naming them here cannot
    # go stale.
    resource "/api/event",
      headers: :any,
      methods: %i[get post options head],
      max_age: 600

    resource "/api/pixel",
      headers: :any,
      methods: %i[get options head],
      max_age: 600
  end

  # The authenticated API, and ONLY when a deployment has named the origins that
  # may reach it from a browser. Unset — the default, and the right answer for
  # every deployment whose identify calls come from its own server — this block
  # contributes nothing and the endpoint has no CORS grant at all.
  api_origins = ENV.fetch("API_CORS_ORIGINS", "").split(",").map(&:strip).reject(&:blank?)

  # A literal "*" is refused rather than honoured. Somebody copying the ingest
  # variable across is the single likeliest way this endpoint ends up with the
  # wildcard again, and the whole point of the split is that it cannot.
  if api_origins.any? && !api_origins.include?("*")
    allow do
      origins(*api_origins)

      resource "/api/v1/*",
        headers: :any,
        methods: %i[get post options head],
        max_age: 600
    end
  end
end
