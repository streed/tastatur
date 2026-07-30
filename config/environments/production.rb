require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.action_mailer.delivery_method = :resend
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  # Defaulted, NOT ENV.fetch with no fallback.
  #
  # `assets:precompile` boots the app in production mode during the Docker build,
  # where APP_HOST is neither set nor needed — no mail is sent while compiling
  # CSS. A bare fetch raised KeyError there and failed the image build outright,
  # which is exactly the situation SECRET_KEY_BASE_DUMMY exists to avoid.
  #
  # The placeholder is deliberately unusable rather than something plausible like
  # "example.com": if a real server ever boots without APP_HOST, the links in its
  # email should be obviously broken rather than quietly wrong. The initializer
  # in config/initializers/required_env.rb also logs about it at boot.
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "app-host-not-configured.invalid") }
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # --- TLS ------------------------------------------------------------------
  #
  # Both supported deployments terminate TLS in front of the app: Railway's edge,
  # and the bundled Caddy for a plain VPS. So the app sees plain HTTP on the
  # inside of an HTTPS request.
  #
  # Without `assume_ssl`, `force_ssl` would see a non-SSL request and issue a
  # redirect to https — which the proxy forwards back as http, and round it goes.
  # With it, Rails treats every request as already secure, so `force_ssl`
  # contributes what is actually wanted here: Strict-Transport-Security, and
  # session cookies marked `secure`. Previously both were off, so the session
  # cookie carried no secure flag in production.
  #
  # It also means no redirect ever fires, which is what keeps the platform health
  # check working: a 301 on /up would fail the deploy. The ssl_options exclusion
  # below is belt-and-braces for anyone who turns assume_ssl off.
  #
  # ASSUME_SSL=0 is the escape hatch for running behind a proxy that does NOT
  # terminate TLS. Setting it wrongly is a real footgun: cookies marked secure
  # over plain HTTP are never sent back, so nobody can stay signed in.
  config.assume_ssl = ENV.fetch("ASSUME_SSL", "1") == "1"
  config.force_ssl = ENV.fetch("FORCE_SSL", "1") == "1"
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Redis, not the default FileStore under tmp/.
  #
  # The site-token lookup in Ingest::RecordEvent is a cache read on the single
  # hottest path in the application, once per pageview across every measured site.
  # A FileStore puts a disk read there, and because it is per-container the cache
  # is cold for every replica and wiped by every deploy — so the "cached" lookup
  # was frequently an indexed query plus a wasted stat.
  #
  # Redis makes it shared and actually warm. Rack::Attack's counters are
  # configured separately and explicitly in its initializer, for the same reason
  # and with a sharper consequence: a per-container throttle counter silently
  # multiplies every rate limit by the number of replicas.
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    namespace: "tastatur:cache",
    expires_in: 1.day,
    # A cache miss must never become a 500. If Redis is unreachable the app falls
    # back to computing the value, which for the ingest path means one extra
    # indexed query rather than a dropped event.
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.error("[cache] #{method} failed: #{exception.class}: #{exception.message}")
      returning
    }
  }

  # Active Job runs on Sidekiq, set in config/application.rb so every environment
  # agrees. Left here as a pointer, because this is where people look for it.
  # config.active_job.queue_adapter is :sidekiq

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # NOTE: default_url_options is set from APP_HOST at the top of this file.
  # The stock generated line that hardcoded "example.com" was removed: it came
  # later in the file and therefore won, sending every password-reset and
  # confirmation link to example.com.

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
