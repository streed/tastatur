require "rails_helper"

# Only the quota interaction. Hashing, referrers, path scrubbing and the hostname
# policy are covered by spec/requests/api/events_spec.rb, spec/lib/ingest/*_spec.rb
# and spec/privacy_invariants_spec.rb; repeating them here would be two files to
# update for one change.
RSpec.describe Ingest::RecordEvent do
  # A tiny event allowance so the cap is reachable in two calls, and room for a
  # second site so the SITE limit — a different feature, covered in
  # spec/models/site_spec.rb — does not get in the way of examples about events.
  let(:account) { create(:account, plan: "free", event_limit_override: 2, site_limit_override: 5) }
  let(:site) { create(:site, account: account, domain: "example.com") }

  let(:chrome) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0 Safari/537.36" }
  let(:crawler) { "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" }

  before do
    delete_all_events
    Ingest::WriteBuffer.clear!
  end

  def record(url: "https://example.com/pricing", user_agent: chrome, **payload)
    described_class.call(
      payload: { s: site.public_token, u: url }.merge(payload),
      ip: "203.0.113.9",
      user_agent: user_agent
    )
  end

  def usage = Billing::UsageMeter.used(account.id)

  describe "inside the allowance" do
    it "records the event and counts it once" do
      expect(record).to be_success

      expect(Ingest::WriteBuffer.depth).to eq(1)
      expect(usage).to eq(1)
    end
  end

  describe "past the allowance" do
    before { 2.times { record } }

    it "refuses the event and buffers nothing further" do
      expect(record).to eq(Dry::Monads::Failure(:plan_limit))

      expect(Ingest::WriteBuffer.depth).to eq(2), "only the two events inside the allowance are stored"
    end

    # An invisible rejection is worse than no rejection: the site owner sees their
    # numbers stop and has no way to tell a broken snippet from a full allowance.
    it "records a rejection the site owner can see" do
      record

      expect(site.rejection_counts(since: 1.hour.ago)).to include(plan_limit: 1)
    end

    it "does not claim a first event for a site that has recorded nothing" do
      fresh = create(:site, account: account, domain: "fresh.example.com")

      described_class.call(payload: { s: fresh.public_token, u: "https://fresh.example.com/" },
                           ip: "203.0.113.9", user_agent: chrome)

      expect(fresh.reload.first_event_at).to be_nil
    end
  end

  # THE TWO EXAMPLES THE METER'S DOCUMENTATION RESTS ON.
  #
  # Billing::UsageMeter promises the allowance is spent only on events we actually
  # store, and the gate is placed after the bot and hostname checks precisely so
  # that promise holds. Charging a customer's quota for crawler traffic we discard,
  # or for someone else abusing their public site key, would be indefensible — and
  # it would also make the figure on the billing screen disagree with the figure on
  # the dashboard.
  describe "what never touches the allowance" do
    it "spends nothing on a bot" do
      expect(record(user_agent: crawler)).to eq(Dry::Monads::Failure(:bot))

      expect(usage).to eq(0)
    end

    it "spends nothing on an event claiming a hostname that is not the site's" do
      result = record(url: "https://attacker.example.net/")

      expect(result).to be_failure
      expect(usage).to eq(0)
    end

    it "spends nothing on an unparseable URL" do
      expect(record(url: "http://[")).to eq(Dry::Monads::Failure(:invalid_url))

      expect(usage).to eq(0)
    end

    it "spends nothing on an unknown site token" do
      described_class.call(payload: { s: "ZZZZZZZZZZZZZZZZ", u: "https://example.com/" },
                           ip: "203.0.113.9", user_agent: chrome)

      expect(usage).to eq(0)
    end
  end

  describe "on a self-hosted install" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(true) }

    it "records without metering, whatever the stored plan says" do
      5.times { record }

      expect(Ingest::WriteBuffer.depth).to eq(5)
      expect(usage).to eq(0)
    end
  end
end
