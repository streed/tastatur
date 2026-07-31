require "rails_helper"

RSpec.describe Revenue::ConnectStripeAccount do
  let(:site) { create(:site) }

  # The exchange itself is Revenue::AppOAuth's job and is specced there; here it
  # is stubbed at that seam, which is the point of the seam.
  def stub_exchange(response)
    allow(Revenue::AppOAuth).to receive(:exchange).with(code: "ac_1").and_return(response)
  end

  describe "a successful exchange" do
    let(:response) { { stripe_user_id: "acct_9", livemode: true, scope: "stripe_apps" } }

    it "records the connection and enqueues the backfill" do
      stub_exchange(response)

      result = described_class.call(site: site, code: "ac_1")

      expect(result).to be_success
      connection = result.value!
      expect(connection.stripe_account_id).to eq("acct_9")
      expect(connection.livemode).to be(true)
      expect(connection.scope).to eq("stripe_apps")
      expect(BackfillStripeJob).to have_been_enqueued.with(connection.id)
    end

    # Disconnect-then-reconnect is the documented remedy for almost everything;
    # it must revive the row rather than trip the one-live-connection index.
    it "revives a revoked connection for the same account" do
      existing = create(:stripe_connection, site: site, stripe_account_id: "acct_9", revoked_at: 1.day.ago)
      stub_exchange(response)

      result = described_class.call(site: site, code: "ac_1")

      expect(result).to be_success
      expect(result.value!.id).to eq(existing.id)
      expect(existing.reload).to be_live
    end

    it "refuses a second, different account while one is connected" do
      create(:stripe_connection, site: site, stripe_account_id: "acct_other")
      stub_exchange(response)

      result = described_class.call(site: site, code: "ac_1")

      expect(result.failure[:invalid]).to include("already connected")
    end
  end

  describe "failure mapping" do
    it "maps a refused code to oauth_error" do
      allow(Revenue::AppOAuth).to receive(:exchange)
        .and_raise(Revenue::AppOAuth::Refused, "authorization code expired")

      result = described_class.call(site: site, code: "ac_1")

      expect(result.failure[:oauth_error]).to eq("authorization code expired")
    end

    it "maps an unreachable Stripe to stripe_error" do
      allow(Revenue::AppOAuth).to receive(:exchange)
        .and_raise(Revenue::AppOAuth::Unavailable, "Stripe answered 500 to the token exchange")

      result = described_class.call(site: site, code: "ac_1")

      expect(result.failure[:stripe_error]).to include("500")
    end

    it "fails cleanly when the response carries no account id" do
      stub_exchange({ scope: "stripe_apps" })

      result = described_class.call(site: site, code: "ac_1")

      expect(result.failure).to eq(:no_account)
      expect(site.stripe_connections).to be_empty
    end

    it "refuses a blank code without calling Stripe" do
      expect(Revenue::AppOAuth).not_to receive(:exchange)

      expect(described_class.call(site: site, code: "").failure).to eq(:missing_code)
    end
  end
end
