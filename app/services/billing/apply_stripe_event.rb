module Billing
  # Turns one validated Stripe webhook event into a change on an account.
  #
  # Everything it does converges on Billing::SyncSubscription, which re-fetches the
  # subscription and writes the result. That is deliberate: a handler per event type
  # would mean six places that each decide what a plan is, and the interesting
  # failures in webhook handling are never "we mishandled a type" but "we handled
  # two events in the wrong order". Re-fetching makes order irrelevant, so the only
  # per-type logic left here is finding the account and finding the subscription id.
  #
  # IDEMPOTENCY LIVES HERE, not in the controller, so a replay from `stripe trigger`
  # or a rake task is protected too. See ProcessedWebhookEvent.
  class ApplyStripeEvent < ApplicationService
    # Subscribe the Stripe endpoint to exactly these.
    #
    # The invoice pair is not strictly required — Stripe always follows a payment
    # outcome with customer.subscription.updated — but handling them makes the
    # "your card failed" banner appear on the first signal rather than the second,
    # and since every branch just re-syncs, they cost one API call and no new logic.
    HANDLED = %w[
      checkout.session.completed
      customer.subscription.created
      customer.subscription.updated
      customer.subscription.deleted
      invoice.paid
      invoice.payment_failed
    ].freeze

    SUBSCRIPTION_EVENTS = %w[
      customer.subscription.created
      customer.subscription.updated
      customer.subscription.deleted
    ].freeze

    # `public_id` is a uuid column, and PostgreSQL raises on a comparison against
    # anything that is not a valid uuid literal — so an event whose
    # client_reference_id came from somewhere other than our own checkout (a
    # hand-made Payment Link, say) would turn a lookup into a 500. Checked here
    # rather than rescued, because a malformed reference is a missing account, not
    # an error.
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def initialize(event:)
      @event = event
      @type = event[:type].to_s
      @object = event.dig(:data, :object) || {}
    end

    def call
      return Failure(:not_billable) if Tastatur.self_hosted?
      return Failure(unhandled: @type) unless HANDLED.include?(@type)

      account = locate_account
      return Failure(:unknown_account) if account.nil?

      receipt = ProcessedWebhookEvent.claim(event_id: @event[:id], event_type: @type)
      return Failure(:duplicate) if receipt.nil?

      settle(receipt) { apply(account) }
    end

    private

    # The receipt records that the work was DONE, so it only survives if it was.
    # Releasing it on failure is what lets Stripe's retry — the mechanism that
    # actually fixes a transient outage — be treated as new work rather than as a
    # duplicate to discard.
    #
    # Re-raising rather than swallowing, per CLAUDE.md: an exception here is a bug
    # and belongs in Sentry.
    def settle(receipt)
      result = yield
      receipt.destroy if result.failure?
      result
    rescue StandardError
      receipt.destroy
      raise
    end

    def apply(account)
      if @type == "checkout.session.completed"
        # The customer id normally arrives with the session, and this is a belt to
        # StartCheckout's braces: an account whose customer was created by Checkout
        # itself (or by a Payment Link) gets it recorded here, which is what makes
        # the portal reachable afterwards.
        account.update!(stripe_customer_id: customer_id) if customer_id.present? && account.stripe_customer_id.blank?
      end

      subscription_id = subscription_id_for(account)
      return Failure(:no_subscription) if subscription_id.blank?

      SyncSubscription.call(account: account, subscription_id: subscription_id)
    end

    def subscription_id_for(account)
      return @object[:subscription] if @type == "checkout.session.completed"
      return @object[:id] if SUBSCRIPTION_EVENTS.include?(@type)

      # An invoice. Its own link to the subscription has moved around between API
      # versions (it lives under `parent.subscription_details` on current ones), so
      # rather than depending on a shape that keeps changing, this uses the
      # subscription we already have on file. The account was found by customer id,
      # so it is the same subscription either way.
      account.stripe_subscription_id
    end

    # Three ways to attribute an event, tried best-first.
    #
    # The reference is the strongest — we put it there ourselves, on both the
    # session and the subscription metadata — and survives an account changing its
    # Stripe customer. The subscription id is next. Customer id is the fallback that
    # makes invoice events work at all.
    def locate_account
      by_reference || by_subscription || by_customer
    end

    def by_reference
      token = @object[:client_reference_id].presence || metadata_reference
      return nil unless token.is_a?(String) && token.match?(UUID)

      Account.find_by(public_id: token)
    end

    # Both key types accepted. A Stripe object hashes to symbol keys, but the
    # contract passes an undeclared inner hash through untouched, so a payload built
    # from JSON with string keys reaches here as it was written. Handling one and
    # not the other is a bug that only shows up on the path that has no spec.
    def metadata_reference
      metadata = @object[:metadata]
      return nil unless metadata.is_a?(Hash)

      (metadata[:account_public_id] || metadata["account_public_id"]).presence
    end

    def by_subscription
      id = SUBSCRIPTION_EVENTS.include?(@type) ? @object[:id] : @object[:subscription]
      return nil if id.blank? || !id.is_a?(String)

      Account.find_by(stripe_subscription_id: id)
    end

    def by_customer
      return nil if customer_id.blank?

      Account.find_by(stripe_customer_id: customer_id)
    end

    def customer_id
      value = @object[:customer]
      return nil if value.nil?
      return value if value.is_a?(String)

      value[:id]
    end
  end
end
