require "rails_helper"

RSpec.describe Revenue::StripeAccount do
  let(:connection) { build(:stripe_connection, stripe_account_id: "acct_9") }

  # The key every Connect call is made with is the APP OWNER's, which is not
  # necessarily billing's. Passing it explicitly in the per-request options —
  # rather than leaning on the global Stripe.api_key — is what makes the
  # two-account deployment (tastatur.dev's) work at all.
  describe ".options" do
    it "carries the billing key when no separate connect key is configured" do
      expect(described_class.options(connection))
        .to eq(api_key: "sk_test_suite", stripe_account: "acct_9")
    end

    it "carries the connect key when the app is owned by a separate account" do
      Rails.configuration.stripe = Rails.configuration.stripe.merge(connect_secret_key: "sk_test_appowner")

      expect(described_class.options(connection))
        .to eq(api_key: "sk_test_appowner", stripe_account: "acct_9")
    end
  end
end
