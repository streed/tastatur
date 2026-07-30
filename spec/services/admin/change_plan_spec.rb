require "rails_helper"

RSpec.describe Admin::ChangePlan do
  let(:account) { create(:account, plan: "free") }

  it "comps a plan onto an account with no Stripe history" do
    result = described_class.call(account: account, plan_key: "pro")

    expect(result).to be_success
    expect(account.reload.plan).to eq("pro")
  end

  it "drops the cached event limit so the new plan is enforced at once" do
    allow(Billing::EventQuota).to receive(:forget)

    described_class.call(account: account, plan_key: "pro")

    expect(Billing::EventQuota).to have_received(:forget).with(account.id)
  end

  # An abandoned Checkout leaves a customer id and no subscription. The nightly
  # reconciliation sweeps such accounts, asks Stripe, gets :no_subscription and
  # moves on — so a plan set here holds.
  it "allows an account that only ever opened Checkout" do
    account.update!(stripe_customer_id: "cus_1")

    expect(described_class.call(account: account, plan_key: "pro")).to be_success
    expect(account.reload.plan).to eq("pro")
  end

  # Taking a comp back mid-month must not retroactively spend the month, exactly
  # as a Stripe-driven downgrade does not. The full behaviour is specified in
  # grandfather_allowance_spec; this pins that the admin path goes through it.
  it "grandfathers the allowance when taking a comp back" do
    account.update!(plan: "pro")
    Billing::UsageMeter.record(account.id, count: 3_000_000)

    result = described_class.call(account: account, plan_key: "free")

    expect(result).to be_success
    account.reload
    expect(account.plan).to eq("free")
    expect(account.event_limit).to eq(3_500_000)
    expect(account.event_limit_override_until).to eq(Billing::UsageMeter.period_bounds.last)
  end

  # The plan follows the money. Billing::ReconcileSubscriptions re-applies
  # whatever Stripe holds every night — for every account with a subscription id,
  # including a cancelled one — so a plan written over a subscription would hold
  # until 3am and then silently revert. Refusing is the honest answer.
  it "refuses an account whose plan Stripe owns" do
    account.update!(stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1",
                    subscription_status: "active", plan: "pro")

    result = described_class.call(account: account, plan_key: "free")

    expect(result).to eq(Dry::Monads::Failure(:stripe_owns_plan))
    expect(account.reload.plan).to eq("pro")
  end

  it "refuses even a cancelled subscription, which the reconciler still re-reads" do
    account.update!(stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1",
                    subscription_status: "canceled")

    expect(described_class.call(account: account, plan_key: "pro"))
      .to eq(Dry::Monads::Failure(:stripe_owns_plan))
  end

  it "refuses a plan that is not offered" do
    expect(described_class.call(account: account, plan_key: "platinum"))
      .to eq(Dry::Monads::Failure(:unknown_plan))
  end

  # self_hosted is a deployment mode, not an offer — assigning it on a hosted
  # instance would be unlimited-everything under a different name. That is what
  # the override columns are for, and they say what they are.
  it "refuses the self_hosted plan key" do
    expect(described_class.call(account: account, plan_key: "self_hosted"))
      .to eq(Dry::Monads::Failure(:unknown_plan))
  end

  it "refuses the plan the account is already on" do
    expect(described_class.call(account: account, plan_key: "free"))
      .to eq(Dry::Monads::Failure(:same_plan))
  end

  it "refuses on a self-hosted install, where the plan column is ignored" do
    allow(Tastatur).to receive(:self_hosted?).and_return(true)

    expect(described_class.call(account: account, plan_key: "pro"))
      .to eq(Dry::Monads::Failure(:self_hosted))
    expect(account.reload.plan).to eq("free")
  end
end
