module Billing
  # Sends someone to Stripe's hosted Checkout to buy a plan.
  #
  # HOSTED CHECKOUT, NOT AN EMBEDDED FORM, and not Stripe Elements. The difference
  # is that no card number ever touches this application or its logs, which keeps
  # the PCI obligation at SAQ-A and means the payment page is maintained by
  # somebody whose full-time job it is. The cost is a redirect off-site, which for
  # a $40/month B2B subscription is not a conversion problem worth taking payment
  # data for. It also means there is nothing for a Content Security Policy to
  # allow — see config/initializers/content_security_policy.rb.
  class StartCheckout < ApplicationService
    def initialize(account:, success_url:, cancel_url:, plan: Billing::Plan.pro)
      @account = account
      @plan = plan
      @success_url = success_url
      @cancel_url = cancel_url
    end

    def call
      return Failure(:not_billable) unless @account.billable?
      return Failure(:not_purchasable) unless @plan.purchasable
      return Failure(price_not_configured: @plan.stripe_price_env_var) if @plan.stripe_price_id.blank?
      return Failure(:already_subscribed) if already_on_this_plan?

      session = Stripe::Checkout::Session.create(session_params(ensure_customer))

      Success(session.url)
    rescue Stripe::StripeError => e
      Sentry.capture_exception(e) if defined?(Sentry)
      Rails.logger.error("[tastatur] checkout failed for account #{@account.id}: #{e.class}: #{e.message}")

      Failure(stripe_error: e.message)
    end

    private

    # Someone already paying should be sent to the portal to change their
    # subscription, not through checkout again — a second checkout would create a
    # SECOND subscription and bill them twice, and Stripe will happily do it.
    def already_on_this_plan?
      @account.billing_plan.key == @plan.key && @account.subscription_in_good_standing?
    end

    # A Stripe customer for the account, created once and kept.
    #
    # Checkout can create one itself, but then the id only arrives with the webhook
    # — so the billing screen has no customer to open the portal for until that
    # lands, and a customer who abandons checkout leaves nothing behind at all.
    #
    # No idempotency key. Two simultaneous first-time checkout clicks could create
    # two Stripe customers, and the loser is simply orphaned: it has no
    # subscription, no charge, and the account row keeps whichever id was written
    # last. That is a strictly better failure than an IdempotencyError shown to
    # someone trying to pay, which is what a key derived from the account gets you
    # the moment any of these parameters changes within Stripe's 24-hour window.
    def ensure_customer
      return @account.stripe_customer_id if @account.stripe_customer_id.present?

      customer = Stripe::Customer.create(
        {
          name: @account.name,
          email: @account.owner&.email,
          # The PUBLIC id, never the primary key — see CLAUDE.md rule 10. This ends
          # up visible in the Stripe dashboard, which is exactly the kind of place a
          # sequential id leaks how many customers exist.
          metadata: { account_public_id: @account.public_id }
        }.compact
      )

      @account.update!(stripe_customer_id: customer.id)
      customer.id
    end

    def session_params(customer_id)
      {
        mode: "subscription",
        customer: customer_id,
        line_items: [{ price: @plan.stripe_price_id, quantity: 1 }],
        success_url: @success_url,
        cancel_url: @cancel_url,

        # Two copies of the account reference, on purpose. `client_reference_id`
        # identifies the account on the checkout.session.completed event; the
        # subscription metadata carries it onto every later
        # customer.subscription.* event, which has no session attached and would
        # otherwise be attributable only by customer id.
        client_reference_id: @account.public_id,
        metadata: { account_public_id: @account.public_id },
        subscription_data: { metadata: { account_public_id: @account.public_id } },

        allow_promotion_codes: true
      }
    end
  end
end
