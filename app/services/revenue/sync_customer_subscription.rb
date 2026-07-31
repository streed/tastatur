module Revenue
  # Applies one subscription state to the ledger.
  #
  # THE ONLY PLACE MRR IS DECIDED, in the same way Billing::SyncSubscription is
  # the only place an account's entitlement is decided. Webhooks and the historical
  # backfill both come through here, so there is one answer to "what is this
  # subscription worth" and no chance of a second implementation drifting.
  #
  # IT DIFFS RATHER THAN OVERWRITES. What the customer's Stripe account says a
  # subscription is worth right now is a fact we can simply store; what changed is
  # the thing the attribution report is actually made of, and it is only knowable
  # by comparing against what we held a moment ago. So every call computes a delta
  # and writes at most one RevenueEvent describing it.
  #
  # A ZERO DELTA WRITES NOTHING. Stripe emits `customer.subscription.updated` for
  # a great many things that do not touch money — a card updated, metadata
  # changed, a period rolling over. Recording those as expansions of £0 would bury
  # the real events in noise and would make "how many times did this customer
  # expand?" unanswerable.
  class SyncCustomerSubscription < ApplicationService
    def initialize(site:, customer:, subscription:, event_at:)
      @site = site
      @customer = customer
      @subscription = subscription
      @event_at = event_at
    end

    def call
      record = find_or_initialize
      return Failure(:stale) if record.persisted? && record.stale?(@event_at)

      previous_mrr = record.persisted? ? record.contributed_mrr_cents : 0
      previously_live = record.persisted? && record.live?

      apply_stripe_state(record)
      record.save!

      revenue_event = record_change(record, previous_mrr, previously_live)
      RecalculateCustomer.call(customer: @customer)

      Success(subscription: record, revenue_event: revenue_event)
    end

    private

    def find_or_initialize
      @site.customer_subscriptions.find_or_initialize_by(stripe_subscription_id: subscription_id) do |record|
        record.customer = @customer
      end
    end

    def apply_stripe_state(record)
      record.customer = @customer
      record.status = status
      record.currency = currency
      record.mrr_cents = MonthlyValue.for_subscription(@subscription)
      record.started_at = timestamp(@subscription[:start_date]) || record.started_at
      record.trial_ends_at = timestamp(@subscription[:trial_end])
      record.canceled_at = timestamp(@subscription[:canceled_at])
      record.last_event_at = @event_at
    end

    # THE CLASSIFICATION TABLE, and the order of these branches is the logic.
    #
    # Both the direction of the change and the PRIOR STATE are needed: a
    # subscription going from £0 to £40 is a `new` if this customer has never
    # paid, and a `reactivation` if they have. Those are the same delta and
    # completely different facts — one is acquisition working, the other is
    # win-back working, and a marketer spends different money on each.
    def record_change(record, previous_mrr, previously_live)
      delta = record.contributed_mrr_cents - previous_mrr
      kind = classify(delta, previous_mrr, previously_live, record)
      return nil if kind.nil?

      write_event(record, kind, delta)
    end

    def classify(delta, previous_mrr, previously_live, record)
      # Churn is decided by STATE, not by the delta, because a subscription can
      # end while its MRR was already zero — a trial that was never converted, or
      # one cancelled during a past_due retry that had already been written down.
      # Keyed off the delta alone, those disappear from the report entirely.
      return RevenueEvent::CHURN if previously_live && !record.live?

      return nil if delta.zero?

      if previous_mrr.zero?
        @customer.converted? ? RevenueEvent::REACTIVATION : RevenueEvent::NEW
      elsif delta.positive?
        RevenueEvent::EXPANSION
      else
        RevenueEvent::CONTRACTION
      end
    end

    def write_event(record, kind, delta)
      amount = kind == RevenueEvent::CHURN ? -record.mrr_cents.abs : delta

      event = @site.revenue_events.new(
        customer: @customer,
        kind: kind,
        amount_cents: amount,
        currency: record.currency,
        normalized_cents: Normalize.call(amount_cents: amount, from: record.currency, to: @site.base_currency),
        mrr_delta_cents: kind == RevenueEvent::CHURN ? -record.mrr_cents.abs : delta,
        # SCOPED BY SUBSCRIPTION AND EVENT TIME, not by subscription alone.
        #
        # The unique index is (site_id, stripe_object_id, kind), so a plain
        # subscription id would let a customer expand exactly once, ever — the
        # second expansion would collide with the first and be silently dropped by
        # the rescue below. Including the timestamp keeps replays of the SAME
        # delivery idempotent (they carry the same event time) while leaving
        # genuinely separate changes distinct.
        stripe_object_id: "#{record.stripe_subscription_id}:#{@event_at.to_i}",
        occurred_at: @event_at
      )

      event.save!
      event
    rescue ActiveRecord::RecordNotUnique
      # A redelivery of an event we already applied. Idempotency enforced by the
      # database rather than by a Ruby check, because the Ruby check loses the race
      # under concurrent delivery and the visible symptom is a customer's MRR
      # doubling — which reads as a good month, not as a bug.
      Rails.logger.info("[tastatur] revenue event for #{record.stripe_subscription_id} already recorded")
      nil
    end

    def subscription_id = @subscription[:id].to_s

    def status = @subscription[:status].to_s

    # Falls back to the site's base currency rather than to a hardcoded "USD". A
    # subscription with no currency field is not something Stripe sends, but if it
    # ever does, inheriting the site's own currency is the answer least likely to
    # produce a silently wrong conversion.
    def currency
      @subscription[:currency].to_s.upcase.presence || @site.base_currency
    end

    def timestamp(value)
      return nil if value.blank?

      Time.zone.at(value.to_i)
    end
  end
end
