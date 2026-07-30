require "rails_helper"

RSpec.describe BillingMailer do
  let(:owner) { create(:user, email: "owner@example.test") }
  let(:account) { create(:account, name: "Acme", plan: "free") }

  before { create(:membership, account: account, user: owner, role: "owner") }

  describe "the warning at 80%" do
    before { Billing::UsageMeter.record(account.id, count: 410_000) }

    subject(:mail) { described_class.usage_threshold(account, owner, "approaching") }

    it "says how far through the allowance the account is" do
      expect(mail.to).to eq([owner.email])
      expect(mail.subject).to eq("Acme is at 82% of its monthly events")
      expect(mail.body.encoded).to include("410,000")
      expect(mail.body.encoded).to include("500,000")
      expect(mail.body.encoded).to include("Nothing has been dropped")
    end

    it "offers the upgrade and its terms" do
      expect(mail.body.encoded).to include("Upgrade to Pro")
      expect(mail.body.encoded).to include("10,000,000")
    end
  end

  describe "the message once the allowance is gone" do
    before { Billing::UsageMeter.record(account.id, count: 518_402) }

    subject(:mail) { described_class.usage_threshold(account, owner, "exceeded") }

    it "says plainly that events are no longer being recorded, and how many" do
      expect(mail.subject).to eq("Acme has used its Free plan's monthly events")
      expect(mail.body.encoded).to include("not being recorded")
      expect(mail.body.encoded).to include("18,402 not recorded")
    end

    it "says when collection resumes" do
      _, period_end = Billing::UsageMeter.period_bounds

      expect(mail.body.encoded).to include(period_end.to_date.to_fs(:long))
    end
  end

  describe "for an account already paying" do
    before do
      account.update!(plan: "pro")
      Billing::UsageMeter.record(account.id, count: 9_000_000)
    end

    it "sends them to their plan rather than offering an upgrade they have" do
      body = described_class.usage_threshold(account, owner, "approaching").body.encoded

      expect(body).to include("Review your plan")
      expect(body).not_to include("Upgrade to Pro")
    end
  end

  # The mailer takes a level STRING rather than the usage snapshot precisely
  # because ActiveJob has to serialise its arguments and a Dry::Struct cannot be
  # serialised. Enqueuing for real is what proves that, and it is the only path
  # anything uses.
  it "can be delivered later, which is how it is always sent" do
    Billing::UsageMeter.record(account.id, count: 450_000)

    expect { described_class.usage_threshold(account, owner, "approaching").deliver_later }
      .to have_enqueued_mail(described_class, :usage_threshold)
  end

  it "goes to the tightest queue, like every other transactional email" do
    expect(ActionMailer::Base.deliver_later_queue_name.to_s).to eq("within_5_seconds")
  end
end
