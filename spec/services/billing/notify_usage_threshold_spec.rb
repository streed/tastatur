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

    # OWNERS ONLY. The email's primary action is a button that changes the plan, and
    # AccountPolicy#manage_billing? is owner-only — so mailing an admin would be
    # mailing them a link that bounces them off /billing with "you do not have access
    # to that".
    #
    # Asserted through the delivered mail rather than the enqueued arguments, because
    # the arguments are serialised GlobalIDs and asserting on those tests ActiveJob
    # rather than who was written to.
    it "tells the owner and nobody else" do
      perform_enqueued_jobs do
        expect(described_class.call(account: account)).to be_success
      end

      expect(ActionMailer::Base.deliveries.flat_map(&:to)).to contain_exactly(owner.email)
    end

    it "reaches everyone who can act on it, and only them" do
      expect(described_class::NOTIFIED_ROLES).to eq(%w[owner])

      context = AuthorizationContext.new(user: admin, account: account)
      expect(AccountPolicy.new(context, account).manage_billing?).to be(false),
             "if an admin can manage billing, they belong in NOTIFIED_ROLES too"
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

  # The claim means the warning was SENT. Holding it for one that was not suppresses
  # the warning for the rest of the month — and the whole point of this email is that
  # an account whose events stop being recorded is told, rather than left to conclude
  # the product is broken. Same rule as Billing::ApplyStripeEvent's receipt.
  describe "when the mail cannot be enqueued" do
    before { Billing::UsageMeter.record(account.id, count: 500) }

    it "releases the claim so the next run tries again" do
      allow(BillingMailer).to receive(:usage_threshold).and_raise(Redis::CannotConnectError, "queue down")

      expect { described_class.call(account: account) }.to raise_error(Redis::CannotConnectError)

      allow(BillingMailer).to receive(:usage_threshold).and_call_original
      expect(described_class.call(account: account)).to be_success
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
