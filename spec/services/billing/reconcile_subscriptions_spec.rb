require "rails_helper"

RSpec.describe Billing::ReconcileSubscriptions do
  let!(:subscribed) do
    create(:account, plan: "pro", subscription_status: "active",
                     stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1")
  end
  let!(:never_paid) { create(:account, plan: "free") }

  def stub_sync(&block)
    allow(Billing::SyncSubscription).to receive(:call) do |account:, **|
      block&.call(account)
      Dry::Monads::Success(account)
    end
  end

  it "visits only the accounts that have a subscription" do
    stub_sync

    report = described_class.call.value!

    expect(report.checked).to eq(1)
    expect(Billing::SyncSubscription).to have_received(:call).once
      .with(hash_including(account: subscribed))
  end

  # THE FAILURE THIS JOB EXISTS FOR.
  #
  # Stripe gives up retrying a webhook after three days, and disables an endpoint
  # that keeps failing — so a cancellation can be delivered while the app is
  # mid-deploy and then never again. The account stays on a plan nobody is paying
  # for, and nothing anywhere raises. Asking once a day is what notices.
  it "corrects an account left on the wrong plan by a webhook that never arrived" do
    stub_sync { |account| account.update!(plan: "free", subscription_status: "canceled") }
    allow(Rails.logger).to receive(:warn)

    report = described_class.call.value!

    expect(subscribed.reload.plan).to eq("free")
    expect(report.changed).to eq(1)
    expect(Rails.logger).to have_received(:warn).with(/A webhook was missed/)
  end

  it "says nothing when Stripe agrees with what is already stored" do
    stub_sync

    expect(described_class.call.value!.changed).to eq(0)
  end

  # One account whose subscription cannot be read must not stop the sweep, or a
  # single bad row freezes reconciliation for every other customer.
  it "counts a failure and carries on" do
    create(:account, plan: "pro", stripe_customer_id: "cus_2", stripe_subscription_id: "sub_2")
    allow(Billing::SyncSubscription).to receive(:call)
      .and_return(Dry::Monads::Failure(stripe_error: "gone"), Dry::Monads::Success(subscribed))

    report = described_class.call.value!

    expect(report.checked).to eq(2)
    expect(report.failed).to eq(1)
  end

  # Pruned here rather than by a cron entry of its own: this is the job that owns
  # webhook reliability, and a second scheduled entry for one DELETE is a second
  # thing that can silently stop running.
  it "prunes webhook receipts that can no longer be redelivered" do
    stub_sync
    ProcessedWebhookEvent.create!(provider: "stripe", event_id: "evt_old",
                                  event_type: "invoice.paid", processed_at: 40.days.ago)
    ProcessedWebhookEvent.create!(provider: "stripe", event_id: "evt_new",
                                  event_type: "invoice.paid", processed_at: 1.hour.ago)

    expect(described_class.call.value!.receipts_pruned).to eq(1)
    expect(ProcessedWebhookEvent.pluck(:event_id)).to eq(["evt_new"])
  end

  it "does nothing on a self-hosted install" do
    allow(Tastatur).to receive(:self_hosted?).and_return(true)
    expect(Billing::SyncSubscription).not_to receive(:call)

    expect(described_class.call.value!.checked).to eq(0)
  end
end
