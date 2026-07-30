require "rails_helper"

RSpec.describe Billing::NotifyUsageThreshold do
  let(:account) { create(:account, plan: "free", event_limit_override: 100) }

  let!(:owner) { add_member("owner") }
  let!(:admin) { add_member("admin") }
  let!(:member) { add_member("member") }
  let!(:viewer) { add_member("viewer") }

  def add_member(role)
    create(:user).tap { |user| create(:membership, account: account, user: user, role: role) }
  end

  describe "who hears about it" do
    before do
      ActionMailer::Base.deliveries.clear
      Billing::UsageMeter.record(account.id, count: 90)
    end

    # Billing is a decision only an owner or admin can act on. Telling a viewer the
    # plan is nearly full is noise about something they cannot change.
    #
    # Asserted through the delivered mail rather than the enqueued arguments, because
    # the arguments are serialised GlobalIDs and asserting on those tests ActiveJob
    # rather than who was written to.
    it "tells owners and admins and nobody else" do
      perform_enqueued_jobs do
        expect(described_class.call(account: account)).to be_success
      end

      expect(ActionMailer::Base.deliveries.flat_map(&:to)).to contain_exactly(owner.email, admin.email)
    end
  end

  describe "which message" do
    it "warns at 80% of the allowance" do
      Billing::UsageMeter.record(account.id, count: 80)

      expect(described_class.call(account: account).value!).to eq("approaching")
    end

    it "says nothing below the threshold" do
      Billing::UsageMeter.record(account.id, count: 79)

      expect(described_class.call(account: account)).to eq(Dry::Monads::Failure(:within_limits))
    end

    # An account can blow straight past its allowance between two hourly checks, and
    # the message that matters then is "you are over", not "you are getting close".
    it "sends the exceeded message when both would apply" do
      Billing::UsageMeter.record(account.id, count: 500)

      expect(described_class.call(account: account).value!).to eq("exceeded")
    end

    it "never warns an account with no ceiling" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      Billing::UsageMeter.record(account.id, count: 1_000_000)

      expect(described_class.call(account: account)).to eq(Dry::Monads::Failure(:within_limits))
    end
  end

  describe "how often" do
    before { Billing::UsageMeter.record(account.id, count: 500) }

    # The check runs hourly, so without a claim the same account would be emailed
    # every hour for the rest of the month.
    it "sends once per level per month" do
      expect(described_class.call(account: account)).to be_success
      expect(described_class.call(account: account)).to eq(Dry::Monads::Failure(:already_notified))
    end

    # The guard key contains the month, so it cannot fail to reset — which a boolean
    # column would need another scheduled job to do, and that job can stop running
    # silently.
    it "sends again in the next month" do
      now = Time.utc(2026, 7, 20)
      Billing::UsageMeter.record(account.id, at: now, count: 500)
      Billing::UsageMeter.record(account.id, at: now + 1.month, count: 500)

      expect(described_class.call(account: account, at: now)).to be_success
      expect(described_class.call(account: account, at: now + 1.month)).to be_success
    end

    it "sends both levels as an account crosses them" do
      Billing::UsageMeter.reset!(account.id)
      Billing::UsageMeter.record(account.id, count: 85)
      expect(described_class.call(account: account).value!).to eq("approaching")

      Billing::UsageMeter.record(account.id, count: 100)
      expect(described_class.call(account: account).value!).to eq("exceeded")
    end
  end
end
