# frozen_string_literal: true

# Warns, at boot, about production configuration that is missing.
#
# This exists because of the opposite mistake. `production.rb` used to read
# `ENV.fetch("APP_HOST")` with no fallback, which raises — and since
# `assets:precompile` boots the app in production mode inside the Docker build,
# where APP_HOST is neither set nor needed, that raise failed the image build
# entirely. The app could not be packaged at all.
#
# So nothing here raises. Configuration problems are reported loudly in the log
# of a process that is actually going to serve traffic, and are silent during
# asset compilation and one-off rake tasks, which do not care.
return unless Rails.env.production?

# SECRET_KEY_BASE_DUMMY is set by the Rails-generated Dockerfile during
# `assets:precompile`. Its presence is the reliable signal that this boot is a
# build step rather than a server.
return if ENV["SECRET_KEY_BASE_DUMMY"].present?

Rails.application.config.after_initialize do
  missing = {
    "APP_HOST" => "email links and the installation snippet will point at a placeholder domain",
    "SECRET_KEY_BASE" => "sessions cannot be signed; the app will not stay signed in",
    "DATABASE_URL" => "no database connection",
    "REDIS_URL" => "the ingest buffer, cache and job queue have nowhere to go"
  }.reject { |key, _| ENV[key].present? }

  missing.each do |key, consequence|
    Rails.logger.error("[tastatur] #{key} is not set — #{consequence}")
  end

  # Not an error, but the one setting whose absence silently weakens a privacy
  # claim rather than breaking a feature, so it gets its own message. The Redis
  # initializer warns too; this repeats it where an operator reading boot output
  # will see it alongside everything else.
  if ENV["REDIS_PRIVACY_URL"].blank?
    Rails.logger.warn(
      "[tastatur] REDIS_PRIVACY_URL is not set — the rotating visitor salt will live in the " \
      "main Redis, which persists to disk. A destroyed salt is then recoverable from a backup, " \
      "and the unlinkability claim on your privacy page stops being true. " \
      "See docs/privacy/identity.md"
    )
  end

  if missing.any?
    Rails.logger.error(
      "[tastatur] #{missing.size} required setting(s) missing. See docs/self-hosting/configuration.md"
    )
  end
end
