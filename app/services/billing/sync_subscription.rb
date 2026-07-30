module Billing
  # Reads a subscription from Stripe and writes what it means onto the account.
  #
  # THE ONLY PLACE THAT DECIDES WHAT A CUSTOMER IS ENTITLED TO. Webhooks, the
  # return from checkout, and the nightly reconciliation all come through here, so
  # there is exactly one answer to "what plan is this account on" and no chance of
  # a second implementation drifting from it.
  #
  # IT ALWAYS RE-FETCHES, and never trusts the object in the webhook payload.
  # Stripe does not guarantee delivery order: a `customer.subscription.updated`
  # from a cancellation and one from a plan change can arrive in either order, and
  # applying the older one last would leave the account permanently wrong with
  # nothing to correct it. Re-fetching costs one API call on an endpoint that
  # handles a handful of events per customer per month, and it makes ordering
  # irrelevant — whatever is at Stripe now is what gets written.
  class SyncSubscription < ApplicationService
    # Statuses that entitle the account to its paid plan.
    #
    # `past_due` is included and `unpaid` is not. Stripe retries a failed charge
    # for up to about two weeks and the subscription sits at past_due throughout;
    # cutting off measurement at the first failure destroys data the customer can
    # never recover, usually over an expired card, so access continues while the
    # retries run. `unpaid` means the retries finished and failed, which is where
    # entitlement stops. `incomplete` never entitled anything — the first payment
    # never succeeded.
    ENTITLING_STATUSES = %w[active trialing past_due].freeze

    def initialize(account:, subscription_id: nil)
      @account = account
      @subscription_id = subscription_id.presence || account.stripe_subscription_id
    end

    def call
      return Failure(:not_billable) unless @account.billable?

      # An account that has just paid has a Stripe subscription and no record of it
      # yet, because the customer's browser gets back from Checkout before the
      # webhook arrives. Asking Stripe which subscriptions the customer has closes
      # that gap; without it the billing screen says "Free" moments after payment,
      # which is exactly when somebody tries to pay a second time.
      #
      # Only reached when no id is known. Every other caller — both webhook paths
      # and the nightly reconciliation — passes one, so this costs nothing there.
      @subscription_id = @subscription_id.presence || discover_subscription_id
      return Failure(:no_subscription) if @subscription_id.blank?

      # No `expand:` — a subscription already carries its items inline, and each
      # item already carries its full price object. It also avoids a trap in the
      # gem: the second positional argument of the resource-style `retrieve` is
      # `opts`, not params, and any key it does not recognise is turned into an HTTP
      # header — so `retrieve(id, expand: [...])` fails inside Net::HTTP before a
      # request is even sent. The safe form, if expansion is ever needed, folds the
      # id into the params hash: `retrieve({ id: id, expand: [...] })`.
      subscription = Stripe::Subscription.retrieve(@subscription_id)

      apply(subscription)
    rescue Stripe::StripeError => e
      # Not swallowed: reported, and returned as a Failure so the webhook endpoint
      # can answer 503 and let Stripe retry. Raising instead would work too, but it
      # would make an ordinary "card declined at Stripe" indistinguishable in
      # Sentry from a bug of ours.
      Sentry.capture_exception(e) if defined?(Sentry)
      Rails.logger.error("[tastatur] could not sync subscription #{@subscription_id}: #{e.class}: #{e.message}")

      Failure(stripe_error: e.message)
    end

    private

    # The customer's most recent subscription, whatever its state. `status: "all"`
    # so a subscription that failed its first payment is still found and recorded
    # as incomplete, rather than being invisible and looking like no purchase
    # happened at all.
    def discover_subscription_id
      return nil if @account.stripe_customer_id.blank?

      Stripe::Subscription.list({ customer: @account.stripe_customer_id, status: "all", limit: 1 })
                          .data.first&.id
    end

    def apply(subscription)
      status = subscription[:status].to_s
      plan = plan_for(subscription, status)
      return Failure(:unknown_price) if plan.nil?

      @account.update!(
        stripe_customer_id: id_of(subscription[:customer]) || @account.stripe_customer_id,
        stripe_subscription_id: subscription[:id],
        subscription_status: status,
        current_period_ends_at: period_end(subscription),
        cancel_at_period_end: subscription[:cancel_at_period_end] == true,
        plan: plan.key
      )

      # The ingest path caches each account's event limit for a minute. Dropping it
      # here means the process that handled the upgrade stops enforcing the old cap
      # at once; other processes still wait out the TTL, which is why the billing
      # screen promises "within a minute" rather than "instantly".
      EventQuota.forget(@account.id)

      Rails.logger.info(
        "[tastatur] account #{@account.id} synced to #{plan.key} (#{status}) from #{@subscription_id}"
      )

      Success(@account)
    end

    def plan_for(subscription, status)
      return Billing::Plan.free unless ENTITLING_STATUSES.include?(status)

      price_id = id_of(subscription_item(subscription)&.[](:price))

      Billing::Plan.for_stripe_price(price_id) || fallback_plan(price_id)
    end

    # A paying subscription whose price matches no plan we know about.
    #
    # The common cause is mundane and needs to not break: STRIPE_PRICE_PRO unset in
    # this environment, so `for_stripe_price` matches nothing at all. Refusing the
    # sync would leave a customer who has paid on the free plan, which is the worse
    # error — so when there is exactly ONE purchasable plan the fallback is
    # unambiguous and is taken, loudly. With two paid plans it would be a guess
    # about how much someone paid, and it returns nil instead so the sync fails
    # visibly.
    def fallback_plan(price_id)
      candidates = Billing::Plan.purchasable_plans
      return nil unless candidates.one?

      plan = candidates.first
      message = "[tastatur] subscription #{@subscription_id} has price #{price_id.inspect}, which matches no " \
                "configured plan — falling back to #{plan.key}. Is #{plan.stripe_price_env_var} set?"
      Rails.logger.error(message)
      Sentry.capture_message(message) if defined?(Sentry)

      plan
    end

    def subscription_item(subscription)
      items = subscription[:items]
      data = items && items[:data]

      Array(data).first
    end

    # WHERE THE PERIOD END LIVES, which moved.
    #
    # Stripe took `current_period_start`/`current_period_end` off the Subscription
    # object and put them on its items in the 2025-03-31 "basil" release, and the
    # gem generates typed readers from the API version it pins — so on this gem
    # `subscription.current_period_end` raises NoMethodError rather than returning
    # nil. A `subscription.current_period_end || item...` fallback chain would
    # therefore crash instead of falling through, which is why both reads below use
    # `[]`: bracket access on a Stripe object is nil-safe for an absent field.
    #
    # `max` across items rather than `items.data.first`, so a subscription that
    # ever gains a second item (a metered add-on, say) reports the end of the
    # period the customer has actually paid through rather than whichever item
    # happened to be listed first.
    def period_end(subscription)
      timestamps = [subscription[:current_period_end]]
      timestamps += Array(subscription[:items] && subscription[:items][:data]).map { |item| item[:current_period_end] }

      latest = timestamps.compact.max
      latest && Time.zone.at(latest)
    end

    # Stripe fields that reference another object are an id string by default and a
    # nested object when expanded. Accepting both means an added `expand:` upstream
    # cannot silently turn an id into "#<Stripe::Customer...>" in the database.
    def id_of(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value[:id]
    end
  end
end
