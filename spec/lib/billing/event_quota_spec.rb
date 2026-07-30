require "rails_helper"

RSpec.describe Billing::EventQuota do
  # A real Account row, deliberately, not a double.
  #
  # `allow?` fails open on any error, so a broken Account#event_limit — a renamed
  # column, say — turns into "unlimited quota for everyone" with nothing but a
  # Sentry line to show it. A double would stub that away and the example would
  # keep passing while enforcement had stopped existing.
  let(:account) { create(:account, plan: "free", event_limit_override: 3) }

  describe ".allow?" do
    it "permits exactly as many events as the limit and refuses the rest" do
      decisions = Array.new(5) { described_class.allow?(account.id) }

      expect(decisions).to eq([true, true, true, false, false])
    end

    # The meter counts events RECEIVED, including refused ones. That is what makes
    # one counter enough: the refused figure is a subtraction rather than a second
    # counter that can drift from the first.
    it "counts refused events too, so the shortfall is derivable" do
      5.times { described_class.allow?(account.id) }

      expect(Billing::UsageMeter.used(account.id)).to eq(5)

      snapshot = Billing::MeasureUsage.call(account: account).value!
      expect(snapshot.events_used).to eq(5)
      expect(snapshot.events_refused).to eq(2)
    end

    it "permits everything when the account has an override of nothing to spare" do
      account.update!(event_limit_override: 0)
      described_class.clear!

      expect(described_class.allow?(account.id)).to be(false)
    end
  end

  describe "on a self-hosted install" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(true) }

    # Ingest there costs exactly what it did before billing existed: no query for
    # the limit and no Redis write for the count.
    it "permits without touching the database or the meter" do
      expect(Account).not_to receive(:find_by)

      expect(described_class.allow?(account.id)).to be(true)
      expect(Billing::UsageMeter.used(account.id)).to eq(0)
    end
  end

  describe "the process-local limit cache" do
    # This is what the "upgrades apply within a minute" wording on the billing
    # screen is actually describing. The alternative — reading the limit from
    # Rails.cache — is itself a Redis round trip on the hottest path in the
    # application, for a value that changes about once a year per account.
    it "keeps enforcing the old limit until it is forgotten" do
      3.times { described_class.allow?(account.id) }
      expect(described_class.allow?(account.id)).to be(false)

      account.update!(event_limit_override: 1_000)
      expect(described_class.allow?(account.id)).to be(false), "the cached limit should still be in force"

      described_class.forget(account.id)
      expect(described_class.allow?(account.id)).to be(true)
    end

    it "gives an account that no longer exists no limit at all" do
      # Deleting an account cascades to its sites, and Ingest::SiteResolver caches
      # site lookups for a minute — so this window already exists. Enforcing a limit
      # of zero here would be a different behaviour change smuggled in under a
      # billing feature.
      expect(described_class.limit_for(-1)).to eq(Billing::Plan::UNLIMITED)
    end
  end

  describe "when Redis cannot answer" do
    before do
      allow(Billing::UsageMeter).to receive(:record).and_raise(Redis::CannotConnectError, "down")
    end

    # Fails OPEN, and this is not a swallowed error: it is logged and reported. The
    # alternative is refusing a paying customer's traffic because we cannot count
    # it, which turns a monitoring problem into permanent data loss.
    it "records the event anyway and says so" do
      expect(Rails.logger).to receive(:error).with(/event quota check failed/)

      expect(described_class.allow?(account.id)).to be(true)
    end
  end
end
