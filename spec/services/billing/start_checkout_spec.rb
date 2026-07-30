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
    def stub_customer_subscriptions(*statuses)
      data = statuses.each_with_index.map do |status, i|
        { id: "sub_#{i}", object: "subscription", status: status }
      end
      allow(Stripe::Subscription).to receive(:list)
        .and_return(Stripe::ListObject.construct_from(object: "list", data: data))
    end

    # ASKS STRIPE, NOT OUR COLUMNS, and that is the point.
    #
    # Checking `plan` and `subscription_status` was not enough, because those are
    # only written by a successful sync — so the state where a second charge is most
    # likely is precisely the state where they are stale: the customer has paid,
    # every webhook was refused, and the account still reads free with no
    # subscription id. A second checkout then creates a second subscription on the
    # same Stripe customer and bills them twice.
    it "refuses when Stripe already has a live subscription, whatever our columns say" do
      account.update!(plan: "free", subscription_status: nil,
                      stripe_subscription_id: nil, stripe_customer_id: "cus_1")
      stub_customer_subscriptions("active")

      expect(start).to eq(Dry::Monads::Failure(:already_subscribed))
    end

    # `unpaid` does not entitle the customer to anything, but Stripe will still
    # collect the outstanding invoice if they fix their card — so selling them a
    # second subscription means they pay twice for one month.
    %w[active trialing past_due unpaid incomplete].each do |status|
      it "refuses while a #{status} subscription exists at Stripe" do
        account.update!(stripe_customer_id: "cus_1")
        stub_customer_subscriptions(status)

        expect(start).to eq(Dry::Monads::Failure(:already_subscribed))
      end
    end

    it "allows a customer whose only subscriptions are finished" do
      account.update!(stripe_customer_id: "cus_1")
      stub_customer_subscriptions("canceled", "incomplete_expired")
      allow(Stripe::Checkout::Session).to receive(:create).and_return(session)

      expect(start).to be_success
    end

    it "does not ask Stripe at all for an account that has never been billed" do
      expect(Stripe::Subscription).not_to receive(:list)
      allow(Stripe::Customer).to receive(:create).and_return(customer)
      allow(Stripe::Checkout::Session).to receive(:create).and_return(session)

      expect(start).to be_success
    end

    # With one paid plan, an unset price means the instance cannot sell anything at
    # all — so `Tastatur.billing_enabled?` is false and billing switches itself off
    # rather than offering a button that fails. The customer never reaches checkout,
    # and nothing enforces a limit they could not lift.
    it "reports billing as off, not as a broken price, when the only paid plan has none" do
      ENV["STRIPE_PRICE_PRO"] = nil

      expect(start).to eq(Dry::Monads::Failure(:not_billable))
      expect(Tastatur.billing_enabled?).to be(false)
    end

    # The per-plan failure fires when SOME paid plan is sellable and the one being
    # bought is not — which is why `billing_configured?` asks `any?` rather than
    # `all?`: one plan missing a price must not take the whole billing system down.
    # Constructed with a second purchasable plan, because there is only one today.
    it "names the missing environment variable for a plan that has no price" do
      team = Billing::Plan.new(key: "team", name: "Team", price_cents: 9_900, currency: "usd",
                               monthly_event_limit: 50_000_000, site_limit: 100, purchasable: true)
      allow(Billing::Plan).to receive(:purchasable_plans).and_return([Billing::Plan.pro, team])

      expect(Tastatur.billing_enabled?).to be(true), "the Pro price is still set, so billing stays on"

      result = described_class.call(account: account, plan: team,
                                    success_url: "https://tastatur.test/billing",
                                    cancel_url: "https://tastatur.test/billing")

      expect(result).to eq(Dry::Monads::Failure(price_not_configured: "STRIPE_PRICE_TEAM"))
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
