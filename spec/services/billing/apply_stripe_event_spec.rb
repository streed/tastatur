require "rails_helper"

RSpec.describe Billing::ApplyStripeEvent do
  # `let!`, not `let`. Several examples assert on a Failure, and a lazily-created
  # account means the service answers Failure(:unknown_account) before it reaches the
  # branch under test — so the example passes for entirely the wrong reason.
  let!(:account) { create(:account, plan: "free", stripe_customer_id: "cus_1") }

  # Built through the contract in one example below, and by hand elsewhere so each
  # example can say exactly which field it is exercising.
  def event(type:, object:, id: "evt_#{SecureRandom.hex(4)}")
    { id: id, type: type, created: Time.current.to_i, data: { object: object } }
  end

  def expect_sync(subscription_id)
    expect(Billing::SyncSubscription).to receive(:call)
      .with(account: account, subscription_id: subscription_id)
      .and_return(Dry::Monads::Success(account))
  end

  describe "the shape the contract produces" do
    # Run through StripeEventContract for real once, so the service and the boundary
    # that feeds it cannot drift apart.
    it "is what the service reads" do
      validated = StripeEventContract.new.call(
        id: "evt_contract",
        type: "customer.subscription.updated",
        created: Time.current.to_i,
        data: { object: { id: "sub_9", object: "subscription", customer: "cus_1", status: "active" } }
      )
      expect(validated).to be_success

      expect_sync("sub_9")
      expect(described_class.call(event: validated.to_h)).to be_success
    end
  end

  describe "which subscription each event points at" do
    it "uses the session's subscription for a completed checkout" do
      expect_sync("sub_from_session")

      described_class.call(event: event(
        type: "checkout.session.completed",
        object: { id: "cs_1", object: "checkout.session", customer: "cus_1", subscription: "sub_from_session" }
      ))
    end

    %w[created updated deleted].each do |suffix|
      it "uses the object's own id for customer.subscription.#{suffix}" do
        expect_sync("sub_itself")

        described_class.call(event: event(
          type: "customer.subscription.#{suffix}",
          object: { id: "sub_itself", object: "subscription", customer: "cus_1" }
        ))
      end
    end

    # An invoice's own link to the subscription has moved between API versions (it
    # lives under `parent.subscription_details` on current ones), so the handler uses
    # the subscription already on file rather than depending on a shape that keeps
    # changing. The account was found by customer id, so it is the same subscription.
    it "uses the subscription already on file for an invoice" do
      account.update!(stripe_subscription_id: "sub_on_file")
      expect_sync("sub_on_file")

      described_class.call(event: event(
        type: "invoice.payment_failed",
        object: { id: "in_1", object: "invoice", customer: "cus_1" }
      ))
    end

    it "gives up quietly on an invoice for an account with no subscription" do
      result = described_class.call(event: event(
        type: "invoice.paid",
        object: { id: "in_1", object: "invoice", customer: "cus_1" }
      ))

      expect(result).to eq(Dry::Monads::Failure(:no_subscription))
    end
  end

  describe "finding the account" do
    before { allow(Billing::SyncSubscription).to receive(:call).and_return(Dry::Monads::Success(account)) }

    it "prefers the reference we put on the checkout session" do
      other = create(:account, stripe_customer_id: "cus_other")

      described_class.call(event: event(
        type: "checkout.session.completed",
        object: { id: "cs_1", object: "checkout.session", customer: "cus_1",
                  subscription: "sub_1", client_reference_id: other.public_id }
      ))

      expect(Billing::SyncSubscription).to have_received(:call).with(hash_including(account: other))
    end

    it "falls back to the subscription metadata" do
      described_class.call(event: event(
        type: "customer.subscription.updated",
        object: { id: "sub_1", object: "subscription", customer: "cus_nope",
                  metadata: { account_public_id: account.public_id } }
      ))

      expect(Billing::SyncSubscription).to have_received(:call).with(hash_including(account: account))
    end

    it "falls back to the stored subscription id" do
      account.update!(stripe_subscription_id: "sub_known", stripe_customer_id: nil)

      described_class.call(event: event(
        type: "customer.subscription.deleted",
        object: { id: "sub_known", object: "subscription" }
      ))

      expect(Billing::SyncSubscription).to have_received(:call).with(hash_including(account: account))
    end

    it "falls back to the customer id" do
      account.update!(stripe_subscription_id: "sub_1")

      described_class.call(event: event(
        type: "invoice.paid",
        object: { id: "in_1", object: "invoice", customer: "cus_1" }
      ))

      expect(Billing::SyncSubscription).to have_received(:call).with(hash_including(account: account))
    end

    it "reports an account it cannot find" do
      result = described_class.call(event: event(
        type: "customer.subscription.updated",
        object: { id: "sub_unknown", object: "subscription", customer: "cus_unknown" }
      ))

      expect(result).to eq(Dry::Monads::Failure(:unknown_account))
    end

    # `public_id` is a uuid column and PostgreSQL raises on a malformed literal, so
    # without the format check a hand-made Payment Link with an arbitrary reference
    # would turn this public endpoint into a 500.
    it "treats a reference that is not a UUID as an account it cannot find" do
      expect do
        result = described_class.call(event: event(
          type: "checkout.session.completed",
          object: { id: "cs_1", object: "checkout.session", subscription: "sub_1",
                    client_reference_id: "order-4711", customer: "cus_unknown" }
        ))

        expect(result).to eq(Dry::Monads::Failure(:unknown_account))
      end.not_to raise_error
    end
  end

  describe "idempotency" do
    let(:payload) do
      event(id: "evt_repeat", type: "customer.subscription.updated",
            object: { id: "sub_1", object: "subscription", customer: "cus_1" })
    end

    before { allow(Billing::SyncSubscription).to receive(:call).and_return(Dry::Monads::Success(account)) }

    # Stripe delivers at least once and retries for three days, so the same event
    # arriving twice is normal traffic rather than an anomaly.
    it "does the work once however many times the event arrives" do
      expect(described_class.call(event: payload)).to be_success
      expect(described_class.call(event: payload)).to eq(Dry::Monads::Failure(:duplicate))

      expect(Billing::SyncSubscription).to have_received(:call).once
      expect(ProcessedWebhookEvent.where(event_id: "evt_repeat").count).to eq(1)
    end

    it "writes no receipt for an event it does not handle" do
      described_class.call(event: event(type: "customer.created", object: { id: "cus_1", object: "customer" }))

      expect(ProcessedWebhookEvent.count).to eq(0)
    end
  end

  # THE RECEIPT MEANS THE WORK WAS DONE.
  #
  # Leaving one behind for work that failed makes Stripe's retry — the only thing
  # that fixes a transient outage — look like a duplicate and get discarded, so a
  # subscription change is lost permanently with nothing raised.
  describe "when the work fails" do
    let(:payload) do
      event(id: "evt_fail", type: "customer.subscription.updated",
            object: { id: "sub_1", object: "subscription", customer: "cus_1" })
    end

    it "releases the receipt so a retry is treated as new work" do
      allow(Billing::SyncSubscription).to receive(:call)
        .and_return(Dry::Monads::Failure(stripe_error: "timed out"))

      expect(described_class.call(event: payload)).to be_failure
      expect(ProcessedWebhookEvent.count).to eq(0)
    end

    it "releases the receipt and re-raises when something breaks outright" do
      allow(Billing::SyncSubscription).to receive(:call).and_raise(ActiveRecord::Deadlocked, "deadlock")

      expect { described_class.call(event: payload) }.to raise_error(ActiveRecord::Deadlocked)
      expect(ProcessedWebhookEvent.count).to eq(0)
    end
  end

  describe "refusals" do
    it "ignores an event type it was not written for" do
      result = described_class.call(event: event(type: "charge.refunded",
                                                object: { id: "ch_1", object: "charge", customer: "cus_1" }))

      expect(result).to eq(Dry::Monads::Failure(unhandled: "charge.refunded"))
    end

    it "does nothing on a self-hosted install" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)

      result = described_class.call(event: event(type: "invoice.paid",
                                                object: { id: "in_1", object: "invoice", customer: "cus_1" }))

      expect(result).to eq(Dry::Monads::Failure(:not_billable))
      expect(ProcessedWebhookEvent.count).to eq(0)
    end
  end
end
