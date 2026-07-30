require "rails_helper"

RSpec.describe "Billing", type: :request do
  let(:account) { create(:account, plan: "free", name: "Acme") }
  let(:owner) { create(:user) }

  before { create(:membership, account: account, user: owner, role: "owner") }

  def sign_in_as(role)
    user = create(:user)
    create(:membership, account: account, user: user, role: role)
    sign_in user
    user
  end

  # OWNER ONLY, one rung tighter than every other AccountPolicy permission.
  #
  # These buttons commit the account to a recurring charge and can cancel it. An
  # admin can already invite people, change retention and delete a site, because
  # those are operational; spending someone else's money is not, and "an admin
  # cancelled our subscription" cannot be undone by re-reading a policy.
  describe "who may see it" do
    it "lets an owner in" do
      sign_in owner
      get "/billing"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Acme")
    end

    %w[admin member viewer].each do |role|
      it "refuses a #{role}" do
        sign_in_as(role)

        get "/billing"
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("do not have access")

        post "/billing/checkout"
        expect(response).to redirect_to(root_path)

        post "/billing/portal"
        expect(response).to redirect_to(root_path)
      end
    end

    # The same cross-tenant guard as every other policy: without the account check a
    # signed-in owner could read another tenant's billing state by switching the
    # slug in the query string.
    it "does not let an owner of one account read another's" do
      other = create(:account, name: "Someone Else", plan: "pro")
      sign_in owner

      get "/billing", params: { account_slug: other.slug }

      expect(response.body).not_to include("Someone Else")
    end
  end

  describe "what it shows" do
    before { sign_in owner }

    it "reports the month's usage against the plan" do
      Billing::UsageMeter.record(account.id, count: 210_000)

      get "/billing"

      expect(response.body).to include("210,000")
      expect(response.body).to include("500,000")
      expect(response.body).to include("42% used")
    end

    it "says how many events were refused once the allowance is gone" do
      Billing::UsageMeter.record(account.id, count: 518_402)

      get "/billing"

      expect(response.body).to include("18,402 events were not recorded")
    end

    it "offers an upgrade on the free plan" do
      get "/billing"

      expect(response.body).to include("Upgrade to Pro")
      expect(response.body).to include(billing_checkout_path)
    end

    it "offers the portal, and no upgrade, to an account already paying" do
      account.update!(plan: "pro", subscription_status: "active",
                      stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1",
                      current_period_ends_at: 20.days.from_now)

      get "/billing"

      expect(response.body).to include(billing_portal_path)
      expect(response.body).not_to include("Upgrade to Pro")
    end

    # Every button here redirects off to Stripe, and Turbo follows a redirect with
    # fetch(), which Stripe's CORS policy refuses. The customer sees a console error
    # and a button that does nothing — no exception, no failed request in our logs,
    # nothing to alert on. So the opt-out is pinned rather than left to a comment.
    it "leaves for Stripe by navigation, not by fetch" do
      account.update!(plan: "free", stripe_customer_id: "cus_1")

      get "/billing"

      forms = response.body.scan(%r{<form[^>]*action="(#{Regexp.union(billing_checkout_path,
                                                                     billing_portal_path)})"[^>]*>})
      expect(forms.length).to eq(2)

      response.body.scan(/<form[^>]*>/).each do |form|
        next unless form.include?(billing_checkout_path) || form.include?(billing_portal_path)

        expect(form).to include('data-turbo="false"')
      end
    end

    it "says so when a card is failing, without pretending access has stopped" do
      account.update!(plan: "pro", subscription_status: "past_due",
                      stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1")

      get "/billing"

      expect(response.body).to include("last payment did not go through")
      expect(response.body).to include("still collecting")
    end

    it "says a cancelled subscription runs to the end of the period it paid for" do
      account.update!(plan: "pro", subscription_status: "active", cancel_at_period_end: true,
                      stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1",
                      current_period_ends_at: Time.utc(2026, 9, 1))

      get "/billing"

      expect(response.body).to include("set to end")
      expect(response.body).to include(Date.new(2026, 9, 1).to_fs(:long))
    end
  end

  describe "starting a checkout" do
    before { sign_in owner }

    it "redirects to Stripe" do
      allow(Billing::StartCheckout).to receive(:call)
        .and_return(Dry::Monads::Success("https://checkout.stripe.com/c/cs_1"))

      post "/billing/checkout"

      expect(response).to redirect_to("https://checkout.stripe.com/c/cs_1")
    end

    # A misconfigured instance is our problem, not the customer's, so the message
    # says that rather than blaming their card.
    it "explains a missing price without raising" do
      allow(Billing::StartCheckout).to receive(:call)
        .and_return(Dry::Monads::Failure(price_not_configured: "STRIPE_PRICE_PRO"))

      post "/billing/checkout"

      expect(response).to redirect_to(billing_path)
      expect(flash[:alert]).to include("not configured")
    end

    it "reports a Stripe failure back to the customer" do
      allow(Billing::StartCheckout).to receive(:call)
        .and_return(Dry::Monads::Failure(stripe_error: "card network unavailable"))

      post "/billing/checkout"

      expect(flash[:alert]).to include("card network unavailable")
    end
  end

  describe "opening the portal" do
    before { sign_in owner }

    it "redirects to Stripe" do
      allow(Billing::StartPortalSession).to receive(:call)
        .and_return(Dry::Monads::Success("https://billing.stripe.com/p/session/bps_1"))

      post "/billing/portal"

      expect(response).to redirect_to("https://billing.stripe.com/p/session/bps_1")
    end

    it "says there is nothing to manage rather than erroring for an account never billed" do
      post "/billing/portal"

      expect(response).to redirect_to(billing_path)
      expect(flash[:notice]).to include("never been billed")
    end
  end

  # The gap between paying and the webhook landing is where a customer sees "Free"
  # seconds after a successful payment, and decides the payment failed.
  describe "returning from a successful checkout" do
    before { sign_in owner }

    it "asks Stripe directly rather than waiting for the webhook" do
      expect(Billing::SyncSubscription).to receive(:call)
        .with(account: account).and_return(Dry::Monads::Success(account))

      get "/billing", params: { checkout: "success" }
    end

    it "does not ask on an ordinary visit" do
      expect(Billing::SyncSubscription).not_to receive(:call)

      get "/billing"
    end
  end

  # A self-hosted operator must never meet a paywall in software they are running
  # on their own hardware.
  describe "on a self-hosted install" do
    before do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      sign_in owner
    end

    it "sends them away instead of rendering a plan screen" do
      get "/billing"

      expect(response).to redirect_to(sites_path)
    end

    it "offers no upgrade anywhere in the interface" do
      get "/sites"

      expect(response.body).not_to include(billing_path)
      expect(response.body).not_to include(">Plan<")
      expect(response.body).not_to include("Pricing")
    end
  end
end
