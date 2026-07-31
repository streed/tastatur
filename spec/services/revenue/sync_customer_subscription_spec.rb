require "rails_helper"

RSpec.describe Revenue::SyncCustomerSubscription do
  let(:site) { create(:site, base_currency: "USD") }
  let(:customer) { create(:customer, site: site) }

  def subscription(id: "sub_1", status: "active", cents: 4_000, interval: "month", **extra)
    {
      id: id, status: status, currency: "usd", start_date: 10.days.ago.to_i,
      items: { data: [{ price: { unit_amount: cents, recurring: { interval: interval, interval_count: 1 } },
                        quantity: 1 }] }
    }.merge(extra)
  end

  def sync(payload, at: Time.current)
    described_class.call(site: site, customer: customer, subscription: payload, event_at: at)
  end

  describe "the first paid subscription" do
    it "records a `new` for the full MRR" do
      result = sync(subscription)

      expect(result).to be_success
      event = result.value![:revenue_event]
      expect(event.kind).to eq(RevenueEvent::NEW)
      expect(event.amount_cents).to eq(4_000)
      expect(event.mrr_delta_cents).to eq(4_000)
    end

    it "stores the subscription with its normalised monthly value" do
      sync(subscription(cents: 48_000, interval: "year"))

      record = site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1")
      expect(record.mrr_cents).to eq(4_000)
      expect(record.status).to eq("active")
    end

    # A trial is a commitment, not a payment. Counting it as MRR reports revenue
    # that in a large fraction of cases never arrives.
    it "records no revenue event for a trial" do
      result = sync(subscription(status: "trialing"))

      expect(result.value![:revenue_event]).to be_nil
      expect(site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1").mrr_cents).to eq(4_000)
      expect(customer.reload.current_mrr_cents).to eq(0)
    end
  end

  describe "changes" do
    before { sync(subscription, at: 5.days.ago) }

    it "records an expansion when the value goes up" do
      event = sync(subscription(cents: 9_000), at: 1.day.ago).value![:revenue_event]

      expect(event.kind).to eq(RevenueEvent::EXPANSION)
      expect(event.amount_cents).to eq(5_000)
    end

    it "records a contraction when the value goes down, signed negative" do
      event = sync(subscription(cents: 1_000), at: 1.day.ago).value![:revenue_event]

      expect(event.kind).to eq(RevenueEvent::CONTRACTION)
      expect(event.amount_cents).to eq(-3_000)
    end

    # Stripe emits `customer.subscription.updated` for a card change, a metadata
    # edit, a period rolling over. Recording those as £0 expansions would bury the
    # real events and make "how often did this customer expand?" unanswerable.
    it "writes nothing when the value has not moved" do
      expect { sync(subscription, at: 1.day.ago) }.not_to change { site.revenue_events.count }
    end

    it "records a churn when the subscription ends" do
      event = sync(subscription(status: "canceled", canceled_at: 1.day.ago.to_i), at: 1.day.ago)
              .value![:revenue_event]

      expect(event.kind).to eq(RevenueEvent::CHURN)
      expect(event.amount_cents).to eq(-4_000)
      expect(customer.reload.current_mrr_cents).to eq(0)
      expect(customer.churned_at).to be_present
    end
  end

  # Churn is decided by STATE, not by the delta — a subscription can end while its
  # MRR is already zero (a trial that never converted, or one cancelled during a
  # past_due write-down). Keyed off the delta alone, those vanish from the report.
  describe "a trial that ends without converting" do
    it "still records a churn" do
      sync(subscription(status: "trialing"), at: 5.days.ago)

      event = sync(subscription(status: "canceled", canceled_at: 1.day.ago.to_i), at: 1.day.ago)
              .value![:revenue_event]

      expect(event.kind).to eq(RevenueEvent::CHURN)
    end
  end

  # The same delta, and a completely different fact: acquisition working versus
  # win-back working. A marketer spends different money on each.
  describe "a returning customer" do
    it "records a reactivation rather than a new" do
      sync(subscription, at: 30.days.ago)
      sync(subscription(status: "canceled", canceled_at: 20.days.ago.to_i), at: 20.days.ago)

      event = sync(subscription(id: "sub_2"), at: 1.day.ago).value![:revenue_event]

      expect(event.kind).to eq(RevenueEvent::REACTIVATION)
    end
  end

  # Stripe does not guarantee delivery order. Applying an older event after a
  # newer one leaves the row permanently wrong with nothing to correct it.
  describe "out-of-order delivery" do
    it "drops an event older than the last one applied" do
      sync(subscription(cents: 9_000), at: 1.hour.ago)

      result = sync(subscription(cents: 4_000), at: 5.hours.ago)

      expect(result).to be_failure
      expect(site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1").mrr_cents).to eq(9_000)
    end

    it "applies an event with the same timestamp, so a plan change and its invoice both land" do
      at = 1.hour.ago
      sync(subscription(cents: 4_000), at: at)

      expect(sync(subscription(cents: 9_000), at: at)).to be_success
    end
  end

  # Redelivery is routine — Stripe retries, the backfill overlaps live webhooks by
  # design, and the sweep re-runs anything that failed halfway. The visible symptom
  # of getting this wrong is a customer's MRR doubling, which reads as a good month.
  describe "idempotency" do
    it "does not double-count a replayed delivery" do
      at = 2.hours.ago
      sync(subscription, at: at)

      expect { sync(subscription, at: at) }.not_to change { site.revenue_events.count }
    end

    # The unique index is (site_id, stripe_object_id, kind), so a bare
    # subscription id would let a customer expand exactly once ever — the second
    # expansion would collide with the first and be silently dropped.
    it "allows a customer to expand more than once" do
      sync(subscription, at: 5.days.ago)
      sync(subscription(cents: 6_000), at: 3.days.ago)
      sync(subscription(cents: 8_000), at: 1.day.ago)

      expect(site.revenue_events.where(kind: RevenueEvent::EXPANSION).count).to eq(2)
    end
  end

  describe "denormalised customer columns" do
    it "keeps current MRR in step with paying subscriptions only" do
      sync(subscription, at: 2.days.ago)
      expect(customer.reload.current_mrr_cents).to eq(4_000)

      sync(subscription(status: "canceled", canceled_at: 1.day.ago.to_i), at: 1.day.ago)
      expect(customer.reload.current_mrr_cents).to eq(0)
    end

    # `converted_at` is history and never moves; `churned_at` describes right now
    # and has to be able to become nil again.
    it "clears churned_at when a customer comes back" do
      sync(subscription, at: 30.days.ago)
      sync(subscription(status: "canceled", canceled_at: 20.days.ago.to_i), at: 20.days.ago)
      expect(customer.reload.churned_at).to be_present

      converted = customer.reload.converted_at
      sync(subscription(id: "sub_2"), at: 1.day.ago)

      expect(customer.reload.churned_at).to be_nil
      expect(customer.converted_at).to be_within(1.second).of(converted)
    end
  end

  describe "currency" do
    it "leaves normalized_cents nil when it cannot convert, rather than guessing" do
      event = sync(subscription.merge(currency: "eur")).value![:revenue_event]

      expect(event.currency).to eq("EUR")
      expect(event.amount_cents).to eq(4_000)
      expect(event.normalized_cents).to be_nil
    end

    it "converts an amount already in the site's currency" do
      event = sync(subscription).value![:revenue_event]

      expect(event.normalized_cents).to eq(4_000)
    end
  end
end
