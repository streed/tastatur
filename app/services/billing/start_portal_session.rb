module Billing
  # Sends someone to Stripe's customer portal.
  #
  # WHY THERE IS NO CANCEL BUTTON, NO CARD FORM AND NO INVOICE LIST IN THIS APP.
  # All three are the portal's job, and building them here would mean holding card
  # details, rendering tax-compliant invoices, and implementing dunning — each a
  # standing obligation, for a two-plan product. The portal also handles the things
  # that are easy to forget: proration on a plan change, VAT ids, receipt emails,
  # and reactivating a subscription cancelled by mistake.
  #
  # The session url is single-use and short-lived, so it is redirected to
  # immediately and never stored. Stripe::BillingPortal::Session has no `retrieve`
  # at all, which is the API telling you the same thing.
  class StartPortalSession < ApplicationService
    def initialize(account:, return_url:)
      @account = account
      @return_url = return_url
    end

    def call
      # `billing_manageable?`, NOT `billable?`. An instance that has lost its price id
      # cannot sell, but Stripe is still charging everyone who already bought — and
      # this is the only route in the product to cancelling or fixing a card. Gating
      # it on the same predicate as selling took the cancel button away while the
      # money kept going out.
      return Failure(:not_billable) unless Tastatur.billing_manageable?

      # Keyed on the CUSTOMER, not the subscription, so someone who has cancelled
      # can still open the portal to read their invoices or resubscribe. An account
      # that has never paid has nothing there to look at.
      return Failure(:no_customer) unless @account.stripe_customer?

      session = Stripe::BillingPortal::Session.create(
        customer: @account.stripe_customer_id,
        return_url: @return_url
      )

      Success(session.url)
    rescue Stripe::StripeError => e
      Sentry.capture_exception(e) if defined?(Sentry)
      Rails.logger.error("[tastatur] portal session failed for account #{@account.id}: #{e.class}: #{e.message}")

      Failure(stripe_error: e.message)
    end
  end
end
