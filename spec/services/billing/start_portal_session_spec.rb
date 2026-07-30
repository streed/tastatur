require "rails_helper"

RSpec.describe Billing::StartPortalSession do
  let(:account) { create(:account, plan: "pro", stripe_customer_id: "cus_1") }
  let(:session) do
    Stripe::BillingPortal::Session.construct_from(
      id: "bps_1", object: "billing_portal.session", url: "https://billing.stripe.com/p/session/bps_1"
    )
  end

  def start = described_class.call(account: account, return_url: "https://tastatur.test/billing")

  it "returns the portal URL for the account's customer" do
    allow(Stripe::BillingPortal::Session).to receive(:create).and_return(session)

    expect(start.value!).to eq("https://billing.stripe.com/p/session/bps_1")
    expect(Stripe::BillingPortal::Session).to have_received(:create)
      .with(customer: "cus_1", return_url: "https://tastatur.test/billing")
  end

  # Keyed on the CUSTOMER rather than the subscription, so somebody who has
  # cancelled can still open the portal to read their invoices or resubscribe.
  it "still opens for an account whose subscription has ended" do
    account.update!(plan: "free", subscription_status: "canceled")
    allow(Stripe::BillingPortal::Session).to receive(:create).and_return(session)

    expect(start).to be_success
  end

  it "has nothing to open for an account that has never been billed" do
    account.update!(stripe_customer_id: nil)

    expect(start).to eq(Dry::Monads::Failure(:no_customer))
  end

  it "refuses on a self-hosted install" do
    allow(Tastatur).to receive(:self_hosted?).and_return(true)

    expect(start).to eq(Dry::Monads::Failure(:not_billable))
  end

  it "returns a Stripe error rather than raising it" do
    allow(Stripe::BillingPortal::Session).to receive(:create)
      .and_raise(Stripe::InvalidRequestError.new("no configuration", "configuration"))

    result = start

    expect(result).to be_failure
    expect(result.failure[:stripe_error]).to include("no configuration")
  end
end
