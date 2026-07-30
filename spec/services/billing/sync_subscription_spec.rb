require "rails_helper"

RSpec.describe Billing::SyncSubscription do
  let(:account) { create(:account, plan: "free", stripe_customer_id: "cus_1") }
  let(:period_end) { Time.utc(2026, 8, 14, 9, 30) }

  around do |example|
    original = ENV["STRIPE_PRICE_PRO"]
    ENV["STRIPE_PRICE_PRO"] = "price_pro"
    example.run
    ENV["STRIPE_PRICE_PRO"] = original
  end

  # The shape stripe 19.3.1 actually receives. Period boundaries live on the
  # subscription ITEM, not the subscription.
  def stripe_subscription(status: "active", items: nil, id: "sub_1", **attrs)
    Stripe::Subscription.construct_from(
      {
        id: id,
        object: "subscription",
        status: status,
        customer: "cus_1",
        cancel_at_period_end: false,
        items: {
          object: "list",
          data: items || [{
            id: "si_1",
            object: "subscription_item",
            current_period_start: (period_end - 30.days).to_i,
            current_period_end: period_end.to_i,
            price: { id: "price_pro", object: "price" }
          }]
        }
      }.merge(attrs)
    )
  end

  def sync(subscription = stripe_subscription, id: "sub_1")
    allow(Stripe::Subscription).to receive(:retrieve).with(id).and_return(subscription)
    described_class.call(account: account, subscription_id: id)
  end

  describe "where the period end comes from" do
    # Stripe moved current_period_start/end off the Subscription object onto its
    # items in the 2025-03-31 "basil" release, and this gem generates its readers
    # from the version it pins — so `subscription.current_period_end` raises
    # NoMethodError rather than returning nil. A `sub.current_period_end || item...`
    # fallback chain would therefore crash instead of falling through, which is why
    # the service reads with `[]`.
    it "reads it from the subscription item, not the subscription" do
      subscription = stripe_subscription

      expect(subscription.respond_to?(:current_period_end)).to be(false),
             "if this ever becomes true the API shape has changed and the reader below can be simplified"
      expect(subscription[:current_period_end]).to be_nil

      expect(sync(subscription)).to be_success
      expect(account.reload.current_period_ends_at).to eq(period_end)
    end

    # A subscription that gains a second item — a metered add-on — must report the
    # end of the period the customer has actually paid through, not whichever item
    # happens to be listed first.
    it "takes the latest across several items" do
      later = period_end + 10.days
      subscription = stripe_subscription(items: [
        { id: "si_1", object: "subscription_item", current_period_end: period_end.to_i,
          price: { id: "price_pro", object: "price" } },
        { id: "si_2", object: "subscription_item", current_period_end: later.to_i,
          price: { id: "price_addon", object: "price" } }
      ])

      sync(subscription)

      expect(account.reload.current_period_ends_at).to eq(later)
    end

    it "copes with a subscription that reports no period at all" do
      subscription = stripe_subscription(items: [
        { id: "si_1", object: "subscription_item", price: { id: "price_pro", object: "price" } }
      ])

      expect(sync(subscription)).to be_success
      expect(account.reload.current_period_ends_at).to be_nil
    end
  end

  describe "entitlement" do
    # past_due entitles and unpaid does not, and the difference is deliberate.
    # Stripe retries a failed charge for about two weeks while the subscription sits
    # at past_due; stopping a paying customer's measurement on the first failure
    # destroys data they can never recover, usually over a card that has expired.
    # `unpaid` means those retries are finished.
    %w[active trialing past_due].each do |status|
      it "puts the account on the paid plan while the status is #{status}" do
        sync(stripe_subscription(status: status))

        expect(account.reload.plan).to eq("pro")
        expect(account.subscription_status).to eq(status)
        expect(account.event_limit).to eq(10_000_000)
      end
    end

    %w[unpaid canceled incomplete incomplete_expired paused].each do |status|
      it "puts the account back on free when the status is #{status}" do
        account.update!(plan: "pro")

        sync(stripe_subscription(status: status))

        expect(account.reload.plan).to eq("free")
        expect(account.subscription_status).to eq(status)
      end
    end

    # A cancellation scheduled for the end of the period changes nothing about what
    # the customer has already paid for.
    it "records a pending cancellation without taking the plan away" do
      sync(stripe_subscription(cancel_at_period_end: true))

      expect(account.reload.plan).to eq("pro")
      expect(account.cancel_at_period_end).to be(true)
      expect(account).to be_cancelling
    end
  end

  describe "an unrecognised price" do
    # The mundane cause is STRIPE_PRICE_PRO being unset in this environment, in which
    # case nothing matches. Refusing the sync would leave a customer who has paid on
    # the free plan, which is the worse error — and with exactly one purchasable plan
    # the fallback is not a guess.
    it "falls back to the only purchasable plan, loudly" do
      expect(Rails.logger).to receive(:error).with(/matches no configured plan/)

      sync(stripe_subscription(items: [
        { id: "si_1", object: "subscription_item", current_period_end: period_end.to_i,
          price: { id: "price_something_else", object: "price" } }
      ]))

      expect(account.reload.plan).to eq("pro")
    end
  end

  describe "the customer reference" do
    it "accepts an id string" do
      sync

      expect(account.reload.stripe_customer_id).to eq("cus_1")
    end

    # An `expand:` added upstream turns the field into a nested object. Accepting both
    # is what stops that silently writing "#<Stripe::Customer...>" into the column.
    it "accepts an expanded customer object" do
      sync(stripe_subscription(customer: { id: "cus_expanded", object: "customer" }))

      expect(account.reload.stripe_customer_id).to eq("cus_expanded")
    end
  end

  # THE RE-SUBSCRIBE BUG. `stripe_subscription_id` is written for cancelled
  # subscriptions too, so falling back to the column first meant it was never blank
  # for anyone who had ever subscribed — and the discovery below was dead code for
  # exactly the customers who needed it. A customer who cancelled and re-subscribed
  # had their OLD, cancelled subscription re-read on returning from Checkout and was
  # written back to `free` seconds after a successful charge.
  describe "an account re-subscribing after a cancellation" do
    let(:cancelled) { stripe_subscription(status: "canceled", id: "sub_old") }
    let(:fresh) { stripe_subscription(status: "active", id: "sub_new") }

    before do
      account.update!(plan: "free", subscription_status: "canceled", stripe_subscription_id: "sub_old")

      allow(Stripe::Subscription).to receive(:list)
        .with({ customer: "cus_1", status: "all", limit: 1 })
        .and_return(Stripe::ListObject.construct_from(object: "list", data: [fresh.to_hash]))
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_new").and_return(fresh)
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_old").and_return(cancelled)
    end

    it "asks Stripe what the customer is on now instead of re-reading the old id" do
      expect(described_class.call(account: account)).to be_success

      expect(account.reload.plan).to eq("pro")
      expect(account.stripe_subscription_id).to eq("sub_new")
    end
  end

  # A late or retried event about a subscription the account has already moved off.
  # Stripe emits the old subscription's `deleted` at its period end and retries for
  # three days, so it can land after the new one is live — and both carry the same
  # account metadata, so it is attributed correctly and then applied, taking a paying
  # customer down to free. The nightly reconciliation would then re-confirm that
  # forever.
  describe "an event about a superseded subscription" do
    before do
      account.update!(plan: "pro", subscription_status: "active", stripe_subscription_id: "sub_new")
    end

    it "is ignored rather than downgrading a paying account" do
      cancelled = stripe_subscription(status: "canceled", id: "sub_old")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_old").and_return(cancelled)

      result = described_class.call(account: account, subscription_id: "sub_old")

      expect(result).to eq(Dry::Monads::Failure(:superseded))
      expect(account.reload.plan).to eq("pro")
      expect(account.stripe_subscription_id).to eq("sub_new")
    end

    it "still accepts an event about the subscription the account is actually on" do
      cancelled = stripe_subscription(status: "canceled", id: "sub_new")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_new").and_return(cancelled)

      expect(described_class.call(account: account, subscription_id: "sub_new")).to be_success
      expect(account.reload.plan).to eq("free")
    end

    it "still accepts a different subscription that DOES entitle, which is a re-subscribe" do
      account.update!(plan: "free", subscription_status: "canceled", stripe_subscription_id: "sub_old")
      fresh = stripe_subscription(status: "active", id: "sub_new")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_new").and_return(fresh)

      expect(described_class.call(account: account, subscription_id: "sub_new")).to be_success
      expect(account.reload.plan).to eq("pro")
    end
  end

  # A downgrade must not retroactively spend the month. The meter counts the whole
  # calendar month, so a Pro account that recorded three million events and then
  # cancels on the 20th would be measured against Free's 100,000 and refused
  # everything until the 1st — while /pricing promises that cancelling leaves every
  # site collecting, and that Free includes 100,000 events a month.
  describe "a mid-month downgrade" do
    before do
      account.update!(plan: "pro", subscription_status: "active", stripe_subscription_id: "sub_1")
      Billing::UsageMeter.record(account.id, count: 3_000_000)
    end

    it "grants the new plan's full allowance for the rest of the month" do
      cancelled = stripe_subscription(status: "canceled")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(cancelled)

      described_class.call(account: account, subscription_id: "sub_1")
      account.reload

      expect(account.plan).to eq("free")
      expect(account.event_limit).to eq(3_100_000)
      expect(account.event_limit_override_until).to eq(Billing::UsageMeter.period_bounds.last)

      Billing::EventQuota.clear!
      expect(Billing::EventQuota.allow?(account.id)).to be(true),
             "collection must continue after a downgrade, not stop until the 1st"
    end

    it "lets the grandfathering expire so next month is the plan's own number" do
      cancelled = stripe_subscription(status: "canceled")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(cancelled)
      described_class.call(account: account, subscription_id: "sub_1")

      account.reload.update_column(:event_limit_override_until, 1.second.ago)

      expect(account.reload.event_limit).to eq(100_000)
    end

    it "does not grandfather an account that was under the new allowance anyway" do
      Billing::UsageMeter.reset!(account.id)
      Billing::UsageMeter.record(account.id, count: 40)
      cancelled = stripe_subscription(status: "canceled")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(cancelled)

      described_class.call(account: account, subscription_id: "sub_1")

      expect(account.reload.event_limit_override).to be_nil
      expect(account.event_limit).to eq(100_000)
    end

    # Applying it on every sync would ratchet: the nightly reconciliation would
    # re-read a larger "used" and raise the ceiling again, so the cap would recede
    # forever.
    it "does not raise the ceiling again on a later sync of the same plan" do
      cancelled = stripe_subscription(status: "canceled")
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(cancelled)
      described_class.call(account: account, subscription_id: "sub_1")
      granted = account.reload.event_limit_override

      Billing::UsageMeter.record(account.id, count: 50_000)
      described_class.call(account: account, subscription_id: "sub_1")

      expect(account.reload.event_limit_override).to eq(granted)
    end

    # An override of 3,100,000 left over from a downgrade would otherwise sit below
    # Pro's ten million and quietly become the real limit.
    it "is cleared again by an upgrade" do
      account.update!(plan: "free", event_limit_override: 3_100_000,
                      event_limit_override_until: 10.days.from_now)

      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(stripe_subscription)
      described_class.call(account: account, subscription_id: "sub_1")

      expect(account.reload.plan).to eq("pro")
      expect(account.event_limit_override).to be_nil
      expect(account.event_limit).to eq(10_000_000)
    end

    it "leaves a support-granted override without an expiry alone" do
      account.update!(plan: "free", event_limit_override: 500_000, event_limit_override_until: nil)

      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(stripe_subscription)
      described_class.call(account: account, subscription_id: "sub_1")

      expect(account.reload.event_limit_override).to eq(500_000)
    end
  end

  describe "discovering a subscription" do
    # The gap this closes: the customer's browser gets back from Checkout before the
    # webhook arrives, so the account has a Stripe subscription and no record of it.
    # Without this the billing screen says "Free" moments after payment, which is
    # exactly when somebody tries to pay a second time.
    it "asks Stripe which subscriptions the customer has when none is known" do
      list = Stripe::ListObject.construct_from(
        object: "list", data: [stripe_subscription.to_hash]
      )
      allow(Stripe::Subscription).to receive(:list)
        .with({ customer: "cus_1", status: "all", limit: 1 }).and_return(list)
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_1").and_return(stripe_subscription)

      expect(described_class.call(account: account)).to be_success
      expect(account.reload.plan).to eq("pro")
    end

    it "fails plainly when there is nothing to discover" do
      account.update!(stripe_customer_id: nil)

      expect(described_class.call(account: account)).to eq(Dry::Monads::Failure(:no_subscription))
    end
  end

  describe "when Stripe cannot be reached" do
    # Returned as a Failure rather than raised, so the webhook endpoint can answer
    # 503 and let Stripe retry — and so an ordinary Stripe outage is distinguishable
    # in Sentry from a bug of ours.
    it "returns the error instead of raising" do
      allow(Stripe::Subscription).to receive(:retrieve)
        .and_raise(Stripe::APIConnectionError.new("timed out"))

      result = described_class.call(account: account, subscription_id: "sub_1")

      expect(result).to be_failure
      expect(result.failure[:stripe_error]).to include("timed out")
      expect(account.reload.plan).to eq("free")
    end
  end

  it "drops the cached quota so the process stops enforcing the old plan" do
    expect(Billing::EventQuota).to receive(:forget).with(account.id)

    sync
  end

  it "does nothing on a self-hosted install" do
    allow(Tastatur).to receive(:self_hosted?).and_return(true)

    expect(described_class.call(account: account, subscription_id: "sub_1"))
      .to eq(Dry::Monads::Failure(:not_billable))
  end
end
