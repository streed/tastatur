require "rails_helper"

RSpec.describe Billing::StartCheckout do
  let(:owner) { create(:user, email: "owner@example.test") }
  let(:account) { create(:account, plan: "free", name: "Acme") }

  let(:session) { Stripe::Checkout::Session.construct_from(id: "cs_1", object: "checkout.session", url: "https://checkout.stripe.com/c/cs_1") }
  let(:customer) { Stripe::Customer.construct_from(id: "cus_new", object: "customer") }

  before { create(:membership, account: account, user: owner, role: "owner") }

  around do |example|
    original = ENV["STRIPE_PRICE_PRO"]
    ENV["STRIPE_PRICE_PRO"] = "price_pro"
    example.run
    ENV["STRIPE_PRICE_PRO"] = original
  end

  def start
    described_class.call(account: account,
                         success_url: "https://tastatur.test/billing?checkout=success",
                         cancel_url: "https://tastatur.test/billing?checkout=cancelled")
  end

  describe "a successful start" do
    before do
      allow(Stripe::Customer).to receive(:create).and_return(customer)
      allow(Stripe::Checkout::Session).to receive(:create).and_return(session)
    end

    it "returns the hosted checkout URL" do
      expect(start.value!).to eq("https://checkout.stripe.com/c/cs_1")
    end

    it "asks for a monthly subscription against the configured price" do
      start

      expect(Stripe::Checkout::Session).to have_received(:create) do |params|
        expect(params[:mode]).to eq("subscription")
        expect(params[:line_items]).to eq([{ price: "price_pro", quantity: 1 }])
        expect(params[:customer]).to eq("cus_new")
        expect(params[:success_url]).to include("checkout=success")
      end
    end

    # THE ACCOUNT REFERENCE IS CARRIED TWICE, on purpose.
    #
    # `client_reference_id` identifies the account on checkout.session.completed;
    # the subscription metadata carries it onto every later customer.subscription.*
    # event, which has no session attached and would otherwise only be attributable
    # by customer id.
    #
    # And it is the PUBLIC id, never the primary key (CLAUDE.md rule 10) — this value
    # is visible in the Stripe dashboard, which is exactly the sort of place a
    # sequential id leaks how many customers exist.
    it "carries the account's public id into both places a webhook can read" do
      start

      expect(Stripe::Checkout::Session).to have_received(:create) do |params|
        expect(params[:client_reference_id]).to eq(account.public_id)
        expect(params[:metadata]).to eq({ account_public_id: account.public_id })
        expect(params[:subscription_data]).to eq({ metadata: { account_public_id: account.public_id } })
        expect(params.to_s).not_to include("\"#{account.id}\"")
      end
    end

    it "creates the Stripe customer once and remembers it" do
      start
      expect(account.reload.stripe_customer_id).to eq("cus_new")

      start
      expect(Stripe::Customer).to have_received(:create).once
    end

    it "names the account and its owner on the Stripe customer" do
      start

      expect(Stripe::Customer).to have_received(:create) do |params|
        expect(params[:name]).to eq("Acme")
        expect(params[:email]).to eq("owner@example.test")
        expect(params[:metadata]).to eq({ account_public_id: account.public_id })
      end
    end
  end

  describe "refusals" do
    # A second checkout for somebody already paying would create a SECOND
    # subscription and bill them twice, and Stripe will happily do it. They are sent
    # to the portal instead.
    it "refuses to start a second subscription for a paying account" do
      account.update!(plan: "pro", subscription_status: "active", stripe_subscription_id: "sub_1")

      expect(start).to eq(Dry::Monads::Failure(:already_subscribed))
    end

    it "lets a past_due account start again, since Stripe may have given up on the old card" do
      account.update!(plan: "pro", subscription_status: "past_due", stripe_customer_id: "cus_1")
      allow(Stripe::Checkout::Session).to receive(:create).and_return(session)

      expect(start).to be_success
    end

    # A deployment problem, and the message has to name the variable rather than
    # blaming the customer's card.
    it "names the missing environment variable when the price is not configured" do
      ENV["STRIPE_PRICE_PRO"] = nil

      expect(start).to eq(Dry::Monads::Failure(price_not_configured: "STRIPE_PRICE_PRO"))
    end

    it "refuses on a self-hosted install" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)

      expect(start).to eq(Dry::Monads::Failure(:not_billable))
    end

    it "returns a Stripe error rather than raising it" do
      allow(Stripe::Customer).to receive(:create).and_return(customer)
      allow(Stripe::Checkout::Session).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("no such price", "price"))

      result = start

      expect(result).to be_failure
      expect(result.failure[:stripe_error]).to include("no such price")
    end
  end
end
