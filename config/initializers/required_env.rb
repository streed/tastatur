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

  # Billing settings, but only on a deployment that actually bills. A self-hosted
  # install has no plans and no Stripe, so warning about a missing Stripe key there
  # would be telling an operator to fix something that is correct.
  #
  # These are reported as errors and are NOT fatal, because a missing one no longer
  # leaves the app half-working: `Tastatur.billing_enabled?` is false until they are
  # all present, so billing switches itself off entirely — no plan limits, no upgrade
  # interface, no webhook endpoint. That is the safe state rather than the correct
  # one, which is why it is still logged at error level with the consequence spelled
  # out. STRIPE_WEBHOOK_SECRET gets the longest note because its absence is the one
  # that would otherwise be invisible from the outside.
  unless Tastatur.self_hosted?
    stripe_missing = {
      "STRIPE_SECRET_KEY" => "nothing can be created at Stripe",
      "STRIPE_WEBHOOK_SECRET" => "every delivery would be refused, so a subscription would be paid for " \
                                 "and never applied — Stripe shows the charge and the customer stays on free",
      "STRIPE_PRICE_PRO" => "there would be nothing to sell"
    }.reject { |key, _| ENV[key].present? }

    if stripe_missing.any?
      Rails.logger.error(
        "[tastatur] BILLING IS DISABLED: #{stripe_missing.keys.join(', ')} not set. " \
        "Plan limits are NOT being enforced, the upgrade interface is hidden and no new subscription " \
        "can be bought. Anyone who ALREADY subscribed is still being charged by Stripe and can still " \
        "cancel through the billing portal, which needs only STRIPE_SECRET_KEY. This is the safe state " \
        "for a half-configured instance — but if this is the hosted service, it is not the state you " \
        "want. Set SELF_HOSTED=1 to make it deliberate, or run `bin/rails tastatur:billing:verify`. " \
        "See docs/architecture/billing.md"
      )
    end

    missing.merge!(stripe_missing)
  end

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
