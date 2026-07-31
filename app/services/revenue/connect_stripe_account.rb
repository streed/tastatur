module Revenue
  # Exchanges an OAuth authorization code for a connected account, and records it.
  #
  # THE ACCESS TOKEN IS DELIBERATELY THROWN AWAY. Stripe returns one, and every
  # tutorial stores it. We do not: the platform's own secret key plus a
  # `Stripe-Account` header reaches exactly the same data, so keeping the token
  # would mean holding a long-lived third-party credential on disk — one that
  # needs encrypting, rotating, and excluding from backups — in exchange for
  # nothing at all. See the StripeConnection model.
  #
  # `stripe_user_id` from the token response is the only thing kept.
  class ConnectStripeAccount < ApplicationService
    def initialize(site:, code:)
      @site = site
      @code = code
    end

    def call
      return Failure(:not_configured) unless Tastatur.revenue_enabled?
      return Failure(:missing_code) if @code.blank?

      response = AppOAuth.exchange(code: @code)
      account_id = response[:stripe_user_id]
      return Failure(:no_account) if account_id.blank?

      connection = record(account_id, response)
      return connection if connection.is_a?(Dry::Monads::Result)

      # Enqueued rather than run inline: paging a mature Stripe account's history
      # takes minutes and is not something to do inside the redirect the customer
      # is currently waiting on.
      BackfillStripeJob.perform_later(connection.id)

      Success(connection)
    rescue AppOAuth::Refused => e
      # A code that was already used, expired, or belongs to another app.
      # Expected: a customer double-clicking the button produces exactly this.
      Rails.logger.info("[tastatur] stripe connect oauth refused: #{e.message}")
      Failure(oauth_error: e.message)
    rescue AppOAuth::Unavailable, Stripe::StripeError => e
      Sentry.capture_exception(e) if defined?(Sentry)
      Failure(stripe_error: e.message)
    end

    private

    def record(account_id, response)
      # RECONNECTING THE SAME ACCOUNT IS AN UPDATE, NOT A DUPLICATE.
      #
      # A customer who disconnects and reconnects — which is the documented
      # remedy for almost every problem here — would otherwise hit the partial
      # unique index on `stripe_account_id`, and the error they would see is
      # "already connected" on a screen showing them not connected. Reviving the
      # revoked row keeps their history and their backfill timestamp.
      existing = @site.stripe_connections.find_by(stripe_account_id: account_id)

      if existing
        existing.update!(revoked_at: nil, connected_at: Time.current,
                         livemode: livemode?(response), scope: response[:scope].presence || StripeConnection::SCOPE)
        return existing
      end

      @site.stripe_connections.create!(
        stripe_account_id: account_id,
        livemode: livemode?(response),
        scope: response[:scope].presence || StripeConnection::SCOPE,
        connected_at: Time.current
      )
    rescue ActiveRecord::RecordInvalid => e
      # The live-connection-per-site validation. Reached when a DIFFERENT Stripe
      # account is already connected here, which is a real thing to want to say.
      Failure(invalid: e.record.errors.full_messages.to_sentence)
    end

    # `livemode` is absent from the token response on some Stripe API versions.
    # Defaulting to false rather than true is the safe direction: a live
    # connection mislabelled as test shows a visible banner somebody will
    # question, while a test connection mislabelled as live quietly puts fake
    # money on a real revenue chart.
    def livemode?(response)
      response[:livemode] == true
    end
  end
end
