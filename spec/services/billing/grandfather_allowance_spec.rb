require "rails_helper"

# The shared half of a plan change: what happens to the event-limit override when
# the allowance shrinks or grows mid-month. The end-to-end behaviour through a
# Stripe sync is covered in sync_subscription_spec; what is pinned here is the
# CONTRACT — most importantly that this service assigns and never saves, because
# both callers persist the override in the same write as the plan itself.
RSpec.describe Billing::GrandfatherAllowance do
  let(:account) { create(:account, plan: "pro") }

  it "does nothing when the plan is not actually changing" do
    Billing::UsageMeter.record(account.id, count: 3_000_000)

    result = described_class.call(account: account, plan: Billing::Plan.pro)

    expect(result).to eq(Dry::Monads::Success(:unchanged))
    expect(account.event_limit_override).to be_nil
  end

  it "does nothing where billing is off — there is no cap to grandfather" do
    allow(Tastatur).to receive(:billing_enabled?).and_return(false)
    Billing::UsageMeter.record(account.id, count: 3_000_000)

    result = described_class.call(account: account, plan: Billing::Plan.free)

    expect(result).to eq(Dry::Monads::Success(:unchanged))
    expect(account.event_limit_override).to be_nil
  end

  describe "a downgrade" do
    it "assigns used-plus-allowance, expiring at the end of the month" do
      Billing::UsageMeter.record(account.id, count: 3_000_000)

      result = described_class.call(account: account, plan: Billing::Plan.free)

      expect(result).to eq(Dry::Monads::Success(:granted))
      expect(account.event_limit_override).to eq(3_500_000)
      expect(account.event_limit_override_until).to eq(Billing::UsageMeter.period_bounds.last)
    end

    it "assigns without saving — the caller's plan write persists it" do
      Billing::UsageMeter.record(account.id, count: 3_000_000)

      described_class.call(account: account, plan: Billing::Plan.free)

      expect(account.reload.event_limit_override).to be_nil
    end

    it "grants nothing to an account already under the new allowance" do
      Billing::UsageMeter.record(account.id, count: 40)

      result = described_class.call(account: account, plan: Billing::Plan.free)

      expect(result).to eq(Dry::Monads::Success(:unchanged))
      expect(account.event_limit_override).to be_nil
    end
  end

  describe "an upgrade" do
    let(:account) do
      create(:account, plan: "free",
                       event_limit_override: 3_500_000,
                       event_limit_override_until: 10.days.from_now)
    end

    it "clears the expiring override a downgrade left behind" do
      result = described_class.call(account: account, plan: Billing::Plan.pro)

      expect(result).to eq(Dry::Monads::Success(:cleared))
      expect(account.event_limit_override).to be_nil
      expect(account.event_limit_override_until).to be_nil
    end

    it "leaves a support-granted override without an expiry alone" do
      account.update!(event_limit_override: 500_000, event_limit_override_until: nil)

      result = described_class.call(account: account, plan: Billing::Plan.pro)

      expect(result).to eq(Dry::Monads::Success(:unchanged))
      expect(account.event_limit_override).to eq(500_000)
    end
  end
end
