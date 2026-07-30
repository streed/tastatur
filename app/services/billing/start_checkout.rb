module Billing
  # Sends someone to Stripe's hosted Checkout to buy a plan.
  #
  # HOSTED CHECKOUT, NOT AN EMBEDDED FORM, and not Stripe Elements. The difference
  # is that no card number ever touches this application or its logs, which keeps
  # the PCI obligation at SAQ-A and means the payment page is maintained by
  # somebody whose full-time job it is. The cost is a redirect off-site, which for
  # a $30/month B2B subscription is not a conversion problem worth taking payment
  # data for. It also means there is nothing for a Content Security Policy to
  # allow — see config/initializers/content_security_policy.rb.
  class StartCheckout < ApplicationService
    # Subscription statuses that mean Stripe still has a live relationship with this
    # customer — either collecting, or retrying, or about to. Buying a second
    # subscription while any of these exists means paying twice for one month.
    #
    # Wider than Billing::SyncSubscription::ENTITLING_STATUSES on purpose: `unpaid`
    # does not entitle the customer to anything, but Stripe will still collect the
    # outstanding invoice if they fix their card, so it is emphatically not a reason
    # to sell them a second subscription.
    LIVE_STATUSES = %w[active trialing past_due unpaid incomplete paused].freeze

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
      return Failure(:already_subscribed) if existing_subscription?

      session = Stripe::Checkout::Session.create(session_params(ensure_customer))

      Success(session.url)
    rescue Stripe::StripeError => e
      Sentry.capture_exception(e) if defined?(Sentry)
      Rails.logger.error("[tastatur] checkout failed for account #{@account.id}: #{e.class}: #{e.message}")

      Failure(stripe_error: e.message)
    end

    private

    # Someone who already has a subscription must go to the portal, not through
    # checkout again. A second checkout creates a SECOND subscription on the same
    # Stripe customer and bills them twice, and Stripe will do it without complaint.
    #
    # ASKS STRIPE, NOT OUR COLUMNS. Checking `plan` and `subscription_status` was
    # not enough, because those are written only by a successful sync — so the exact
    # state where a second charge is most likely is the state where they are stale:
    # the customer has paid, every webhook was refused, and the account still reads
    # `free` with no subscription id. It also let an `unpaid` or `past_due`
    # subscription through, where Stripe is still collecting or still retrying, so
    # the customer could end up paying both.
    #
    # One extra API call, on a path taken a handful of times per customer ever.
    def existing_subscription?
      return false if @account.stripe_customer_id.blank?

      Stripe::Subscription.list({ customer: @account.stripe_customer_id, status: "all", limit: 20 })
                          .data.any? { |subscription| LIVE_STATUSES.include?(subscription[:status].to_s) }
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
