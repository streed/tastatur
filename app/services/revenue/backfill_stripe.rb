module Revenue
  # Imports a connected account's history, so the screen has something on it the
  # first time somebody looks.
  #
  # THIS IS AN ACTIVATION FEATURE, NOT A COMPLETENESS ONE. A revenue dashboard that
  # is empty for a month after connecting is a dashboard nobody comes back to; the
  # customer cannot tell "no data yet" from "this does not work", and the honest
  # answer — wait for your next billing cycle — is not one anybody waits for. So
  # the history is imported at connect time and the charts are populated at first
  # login.
  #
  # CUSTOMERS WITH NO ATTRIBUTION GET `(pre-install)`, NOT `(direct)`. They
  # predate measurement, and merging them into direct traffic would make the first
  # month after connecting look like an enormous direct-traffic win — which is
  # both false and exactly the kind of false that gets acted on.
  #
  # IT IS SAFE TO RUN REPEATEDLY, which is why the button exists on the settings
  # screen. Customers are matched rather than duplicated, subscriptions upsert by
  # Stripe id, and every ledger row is protected by the partial unique index on
  # (site_id, stripe_object_id, kind).
  class BackfillStripe < ApplicationService
    # How far back to import. Two years is well past the point where a marketing
    # decision is being made from the data, and it bounds the work on a mature
    # account — Stripe's own rate limit is the real constraint, and an account
    # with a decade of invoices would otherwise spend an hour of it.
    DEFAULT_SINCE = 2.years

    def initialize(connection:, since: DEFAULT_SINCE.ago)
      @connection = connection
      @site = connection.site
      @since = since
    end

    def call
      return Failure(:revoked) if @connection.revoked?
      return Failure(:not_configured) unless Tastatur.revenue_enabled?

      counts = { customers: 0, subscriptions: 0, invoices: 0 }

      counts[:customers] = import_customers
      counts[:subscriptions] = import_subscriptions
      counts[:invoices] = import_invoices

      @connection.update!(backfilled_at: Time.current)
      Rails.logger.info("[tastatur] backfilled #{@site.domain} from Stripe: #{counts.inspect}")

      Success(counts)
    rescue Stripe::StripeError => e
      # Returned rather than raised so the job can decide, and so a rate limit —
      # which is the overwhelmingly common failure here — does not fill Sentry
      # with something that resolves itself on the retry. Everything ELSE does
      # go to Sentry: a permission or auth failure here is the customer's
      # history silently never arriving while the screen says "importing", and
      # a log line nobody greps for is not an alert.
      Rails.logger.error("[tastatur] backfill failed for #{@site.domain}: #{e.class}: #{e.message}")
      unless e.is_a?(Stripe::RateLimitError)
        Sentry.capture_exception(e) if defined?(Sentry)
      end
      Failure(stripe_error: e.message)
    end

    private

    def import_customers
      count = 0

      StripeAccount.each(Stripe::Customer, @connection, created: { gte: @since.to_i }) do |stripe_customer|
        upsert_customer(stripe_customer)
        count += 1
      end

      count
    end

    def upsert_customer(stripe_customer)
      email_hash = Customer.hash_email(stripe_customer[:email])
      customer = CustomerMatcher.call(site: @site, stripe_customer_id: stripe_customer[:id],
                                      email_hash: email_hash)

      customer ||= @site.customers.create!(
        stripe_customer_id: stripe_customer[:id],
        email_hash: email_hash,
        first_seen_at: timestamp(stripe_customer[:created])
      )

      apply_attribution(customer, stripe_customer[:metadata])
      customer
    rescue ActiveRecord::RecordNotUnique
      CustomerMatcher.call(site: @site, stripe_customer_id: stripe_customer[:id], email_hash: email_hash)
    end

    # Attribution from metadata if the SDK put it there, and `(pre-install)`
    # otherwise — but only for a customer who has none at all, so a later
    # identify() call is never overwritten by a re-run of this import.
    def apply_attribution(customer, metadata)
      attribution = Checkout.extract_attribution(metadata)

      # SOURCE ONLY, and deliberately no medium. Writing the "(none)" medium
      # sentinel here would make that column non-blank, and write-once would then
      # refuse the real medium when the SDK starts reporting it next week — the
      # import would be silently destroying the data it exists to make room for.
      # `(pre-install)` itself is overwritable exactly once; see
      # Revenue::IdentifyCustomer#attributed?.
      attribution = { source: Customer::PRE_INSTALL } if attribution.blank?

      IdentifyCustomer.call(
        site: @site,
        params: { stripe_customer_id: customer.stripe_customer_id, external_id: customer.external_id,
                  attribution: attribution }
      )
    end

    # `status: "all"` so cancelled subscriptions are imported too. Without them
    # the churn column is empty on day one, which makes a business with real churn
    # look like one with none — the single most flattering and least useful error
    # this import could make.
    def import_subscriptions
      count = 0

      StripeAccount.each(Stripe::Subscription, @connection, status: "all") do |subscription|
        customer = CustomerMatcher.call(site: @site, stripe_customer_id: id_of(subscription[:customer]))
        next if customer.nil?

        # `event_at` is the subscription's own last change, not now. Using the
        # clock would stamp two years of history with today's date and pile every
        # historical signup onto one day of the attribution report.
        SyncCustomerSubscription.call(
          site: @site, customer: customer, subscription: subscription,
          event_at: subscription_changed_at(subscription)
        )
        count += 1
      end

      count
    end

    def import_invoices
      count = 0

      StripeAccount.each(Stripe::Invoice, @connection, status: "paid", created: { gte: @since.to_i }) do |invoice|
        customer = CustomerMatcher.call(site: @site, stripe_customer_id: id_of(invoice[:customer]))
        next if customer.nil?

        amount = invoice[:amount_paid].to_i
        next if amount.zero?

        record_payment(customer, invoice, amount)
        count += 1
      end

      count
    end

    def record_payment(customer, invoice, amount)
      currency = invoice[:currency].to_s.upcase.presence || @site.base_currency
      kind = subscription_id_on(invoice).present? ? RevenueEvent::PAYMENT : RevenueEvent::ONE_TIME

      @site.revenue_events.create!(
        customer: customer, kind: kind, amount_cents: amount, currency: currency,
        normalized_cents: Normalize.call(amount_cents: amount, from: currency, to: @site.base_currency),
        stripe_object_id: invoice[:id],
        occurred_at: timestamp(invoice[:status_transitions]&.[](:paid_at)) || timestamp(invoice[:created])
      )

      RecalculateCustomer.call(customer: customer)
    rescue ActiveRecord::RecordNotUnique
      # Already imported, or delivered by webhook while this ran. The overlap
      # between a live webhook and a backfill is by design — see the class comment.
      nil
    end

    # The best available "when did this last change". `start_date` for a
    # subscription that has never changed, `canceled_at` for one that ended.
    def subscription_changed_at(subscription)
      timestamp(subscription[:canceled_at]) ||
        timestamp(subscription[:start_date]) ||
        timestamp(subscription[:created]) ||
        Time.current
    end

    def timestamp(value)
      return nil if value.blank?

      Time.zone.at(value.to_i)
    end

    # See the long note on ApplyConnectEvent#subscription_id_on: Stripe's Basil
    # release moved an invoice's subscription under `parent`, and reading only the
    # old top-level key files every recurring payment as `one_time`. The webhook
    # path and this one must agree, because they write the same rows for the same
    # invoices and a backfill deliberately overlaps live delivery.
    #
    # Here `invoice` is a Stripe::Invoice rather than a Hash, and `[]` on a
    # removed attribute can raise KeyError rather than return nil — verified that
    # `subscription` returns nil, unlike `payment_intent`, which raises.
    def subscription_id_on(invoice)
      direct = id_of(invoice[:subscription])
      return direct if direct.present?

      parent = invoice[:parent]
      details = parent && parent[:subscription_details]
      id_of(details && details[:subscription])
    end

    def id_of(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value[:id] || value["id"]
    end
  end
end
