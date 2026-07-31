module Revenue
  # Interprets one stored ConnectEvent.
  #
  # THE RECEIPT IS WRITTEN LAST, and only on success. §14 states the rule for our
  # own webhooks and it is the same failure here: mark an event processed on
  # arrival and a delivery that dies halfway is indistinguishable from one that
  # worked, so Stripe's retry is discarded as a duplicate and the money is simply
  # never recorded. Nothing raises, nothing is logged, and the number is wrong
  # forever.
  #
  # SO THIS SERVICE IS RE-ENTRANT BY CONSTRUCTION. Every handler below is safe to
  # run twice: subscription syncs diff against stored state and write nothing when
  # the delta is zero, and every cash row is protected by the partial unique index
  # on (site_id, stripe_object_id, kind). That is what makes "retry until it
  # sticks" a correct strategy rather than a way to double someone's revenue.
  class ApplyConnectEvent < ApplicationService
    def initialize(connect_event:)
      @event = connect_event
      @site = connect_event.site
    end

    def call
      return Failure(:already_processed) if @event.processed?

      result = dispatch
      return result if result.is_a?(Dry::Monads::Result) && result.failure?

      @event.mark_processed!
      Success(@event)
    rescue Stripe::StripeError => e
      # Our side could not reach Stripe. Recoverable: the sweep will try again.
      @event.mark_failed!("#{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Failure(stripe_error: e.message)
    rescue StandardError => e
      # NOT a swallowed error — it is recorded on the row, re-reported to Sentry,
      # and returned as a Failure so the caller can decide. The alternative,
      # letting it raise out of a Sidekiq job, loses the association between the
      # exception and the specific delivery that caused it, which is the one thing
      # needed to diagnose it.
      @event.mark_failed!("#{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Failure(error: e.message)
    end

    private

    def dispatch
      case @event.event_type
      when "customer.created", "customer.updated" then apply_customer
      when "checkout.session.completed"           then apply_checkout_session
      when /\Acustomer\.subscription\./            then apply_subscription
      when "invoice.paid"                          then apply_invoice_paid
      when "invoice.payment_failed"                then apply_payment_failed
      when "charge.refunded"                       then apply_refund
      when "charge.dispute.created"                then apply_dispute
      when "account.application.deauthorized"      then apply_deauthorized
      else
        # Reachable only if HANDLED and this case gain entries at different
        # times. Answered as a success so the delivery is not retried forever.
        Rails.logger.info("[tastatur] no handler for connect event #{@event.event_type}")
        Success(:ignored)
      end
    end

    # --- Handlers ------------------------------------------------------------

    def apply_customer
      object = @event.object
      customer = resolve_customer(stripe_customer_id: object[:id], email: object[:email])
      return Failure(:no_customer) if customer.nil?

      # Attribution from Stripe metadata, if the SDK's checkout helper put it
      # there and identify() has not already supplied it. Write-once applies
      # exactly as it does on the identify path — same service, same rule.
      apply_metadata_attribution(customer, object[:metadata])
      Success(customer)
    end

    # THE EVENT THAT CARRIES ATTRIBUTION THROUGH A PAYMENT.
    #
    # This is what makes the whole design immune to closed tabs, salt rotation,
    # async payment methods and paying on a different device: the customer's app
    # stamps the attribution onto the Checkout Session at creation
    # (`Tastatur::Checkout.metadata`), Stripe hands it back here, and it lands on
    # the customer row server-side with no browser involved at any point.
    def apply_checkout_session
      object = @event.object
      customer = resolve_customer(
        stripe_customer_id: id_of(object[:customer]),
        email: object.dig(:customer_details, :email),
        external_id: object[:client_reference_id]
      )
      return Failure(:no_customer) if customer.nil?

      apply_metadata_attribution(customer, object[:metadata])
      Success(customer)
    end

    def apply_subscription
      object = @event.object
      customer = resolve_customer(stripe_customer_id: id_of(object[:customer]))
      return Failure(:no_customer) if customer.nil?

      apply_metadata_attribution(customer, object[:metadata])

      SyncCustomerSubscription.call(
        site: @site, customer: customer, subscription: object, event_at: @event.occurred_at
      )
    end

    # CASH, recorded separately from MRR. See RevenueEvent's two families.
    #
    # `amount_paid`, not `total`: an invoice discounted to zero by a credit
    # balance has a total and collected nothing, and counting it as revenue
    # inflates lifetime value for exactly the customers on a comp plan.
    def apply_invoice_paid
      object = @event.object
      customer = resolve_customer(stripe_customer_id: id_of(object[:customer]),
                                  email: object[:customer_email])
      return Failure(:no_customer) if customer.nil?

      amount = object[:amount_paid].to_i
      return Success(:zero_invoice) if amount.zero?

      kind = object[:subscription].present? ? RevenueEvent::PAYMENT : RevenueEvent::ONE_TIME
      write_cash(customer, kind: kind, amount_cents: amount,
                 currency: object[:currency], stripe_object_id: object[:id])
    end

    # DELIBERATELY RECORDS NO REVENUE ROW.
    #
    # A failed payment is not churn and it is not a refund — Stripe retries for
    # about two weeks and most of them succeed. Writing a negative row here and a
    # positive one on the eventual success would put a spike and a matching trough
    # into every chart, for an event whose usual outcome is nothing at all. The
    # subscription's status change to `past_due` is the part that matters, and it
    # arrives on its own event.
    def apply_payment_failed
      Success(:noted)
    end

    def apply_refund
      object = @event.object
      customer = resolve_customer(stripe_customer_id: id_of(object[:customer]))
      return Failure(:no_customer) if customer.nil?

      refunded = object[:amount_refunded].to_i
      return Success(:zero_refund) if refunded.zero?

      write_cash(customer, kind: RevenueEvent::REFUND, amount_cents: -refunded,
                 currency: object[:currency], stripe_object_id: object[:id])
    end

    # A dispute is recorded at its full amount the moment it is opened, before it
    # is resolved. That is the conservative direction: a disputed charge is money
    # we should stop counting on immediately, and a dispute won later is a
    # pleasant correction rather than a nasty one.
    def apply_dispute
      object = @event.object
      # A Dispute object carries NO customer field — the charge it names does.
      # Resolving through `object[:customer]` alone meant every dispute failed
      # with :no_customer and was retried pointlessly for a day. The charge
      # read goes through the same wrapper as everything else and is covered by
      # the same charge_read permission the refund handler relies on.
      customer = resolve_customer(stripe_customer_id: id_of(object[:customer]) || dispute_customer_id(object))
      return Failure(:no_customer) if customer.nil?

      amount = object[:amount].to_i
      return Success(:zero_dispute) if amount.zero?

      write_cash(customer, kind: RevenueEvent::DISPUTE, amount_cents: -amount,
                 currency: object[:currency], stripe_object_id: object[:id])
    end

    def dispute_customer_id(object)
      connection = @site.stripe_connection
      return nil if connection.nil? || object[:charge].blank?

      id_of(StripeAccount.retrieve(Stripe::Charge, connection, id_of(object[:charge]))[:customer])
    end

    # The customer uninstalled the app from their own Stripe dashboard. That is
    # a disconnect performed at the other end, and it must land exactly where
    # our own Disconnect button lands: the connection revoked, revenue already
    # recorded kept. Without this, rows would keep flowing into a site whose
    # owner watched themselves uninstall it.
    #
    # Idempotent like every handler here: the connection this event's account
    # names may already be revoked (uninstall raced a manual disconnect, or a
    # retry), and finding nothing to revoke is success, not an error.
    #
    # THE SUPERSEDED GUARD IS NOT OPTIONAL. A deauthorization that failed to
    # apply on the first attempt stays in the retry sweep for 24 hours, and
    # disconnect-then-reconnect is the documented remedy for most problems here
    # — so a stale deauth catching a connection made AFTER it would revoke a
    # reconnect that looked like it worked, and recording would stop with
    # nothing raised. `>=` rather than `>`: with only second precision on both
    # timestamps, an ambiguous tie must keep the connection, because a wrongly
    # kept one is corrected by the next event or a manual disconnect, while a
    # wrongly revoked one is silence.
    def apply_deauthorized
      connection = @site.stripe_connections.live.find_by(stripe_account_id: @event.stripe_account_id)
      return Success(:already_revoked) if connection.nil?
      return Success(:superseded) if connection.connected_at >= @event.occurred_at

      connection.revoke!
      Success(connection)
    end

    # --- Shared ---------------------------------------------------------------

    def write_cash(customer, kind:, amount_cents:, currency:, stripe_object_id:)
      code = currency.to_s.upcase.presence || @site.base_currency

      event = @site.revenue_events.create!(
        customer: customer, kind: kind, amount_cents: amount_cents, currency: code,
        normalized_cents: Normalize.call(amount_cents: amount_cents, from: code, to: @site.base_currency),
        stripe_object_id: stripe_object_id, occurred_at: @event.occurred_at
      )

      RecalculateCustomer.call(customer: customer)
      Success(event)
    rescue ActiveRecord::RecordNotUnique
      # Already recorded. See the class comment on why re-entrancy is the design
      # rather than an accident.
      Success(:duplicate)
    end

    # Finds the customer this event is about, creating one if the identifiers are
    # new.
    #
    # CREATING IS CORRECT HERE, and is not the same as the identify endpoint
    # creating one. A subscription created by hand in the Stripe dashboard, or one
    # that predates the integration, belongs to a real paying person who never
    # passed through `identify` — refusing to record their revenue because we lack
    # a signup event would make the revenue total wrong in order to keep the
    # attribution tidy. They get counted, with attribution unknown, which is the
    # honest answer.
    def resolve_customer(stripe_customer_id: nil, email: nil, external_id: nil)
      email_hash = Customer.hash_email(email)
      existing = CustomerMatcher.call(site: @site, external_id: external_id,
                                      stripe_customer_id: stripe_customer_id,
                                      email_hash: email_hash)

      if existing
        backfill_identifiers(existing, stripe_customer_id, external_id, email_hash)
        return existing
      end

      return nil if stripe_customer_id.blank? && external_id.blank? && email_hash.blank?

      create_customer(stripe_customer_id, external_id, email_hash)
    end

    def create_customer(stripe_customer_id, external_id, email_hash)
      @site.customers.create!(
        stripe_customer_id: stripe_customer_id, external_id: external_id, email_hash: email_hash,
        first_seen_at: @event.occurred_at
      )
    rescue ActiveRecord::RecordNotUnique
      # Two events for the same new customer delivered concurrently — Stripe fans
      # out `customer.created` and `checkout.session.completed` within
      # milliseconds of each other, so this is the common case, not the rare one.
      CustomerMatcher.call(site: @site, external_id: external_id,
                           stripe_customer_id: stripe_customer_id, email_hash: email_hash)
    end

    # FILLS IN, never overwrites — the same rule as IdentifyCustomer, so a
    # customer known only by external_id gains their Stripe id the first time
    # Stripe mentions them, and a customer whose Stripe id somehow differs keeps
    # the one they have.
    def backfill_identifiers(customer, stripe_customer_id, external_id, email_hash)
      changes = {}
      changes[:stripe_customer_id] = stripe_customer_id if customer.stripe_customer_id.blank? && stripe_customer_id.present?
      changes[:external_id] = external_id if customer.external_id.blank? && external_id.present?
      changes[:email_hash] = email_hash if customer.email_hash.blank? && email_hash.present?
      return if changes.empty?

      customer.update!(changes)
    end

    # Attribution arriving through Stripe metadata rather than through identify().
    #
    # Routed through IdentifyCustomer rather than assigning here, so that write-once
    # is enforced in exactly one place. Two implementations of "first touch wins"
    # is one implementation of "first touch wins" and one of "sometimes it does
    # not", and nobody would be able to tell which had run.
    def apply_metadata_attribution(customer, metadata)
      attribution = Checkout.extract_attribution(metadata)
      return if attribution.blank?

      IdentifyCustomer.call(
        site: @site,
        params: { external_id: customer.external_id, stripe_customer_id: customer.stripe_customer_id,
                  attribution: attribution }
      )
    end

    # Stripe fields referencing another object are an id string by default and a
    # nested object when expanded. Accepting both means an `expand:` added
    # upstream cannot silently turn an id into "#<Stripe::Customer...>".
    def id_of(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value[:id] || value["id"]
    end
  end
end
