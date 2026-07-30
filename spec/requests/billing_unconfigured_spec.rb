require "rails_helper"

# WHAT THIS FILE IS ABOUT.
#
# There are two reasons billing might not work, and only one of them is a choice. A
# self-hosted operator has switched it off. A hosted deployment with no Stripe keys
# has not switched anything off — it is half-configured, and that used to produce the
# worst available state: plan limits enforced, so every account was capped at one site
# and 100,000 events, with an upgrade button whose only possible answer was "payments
# are not configured on this instance". A paywall with no cashier, chosen by nobody.
#
# So configuration is now treated exactly like deployment mode. Until Stripe is wired
# up, billing does not exist — and the moment the variables are set, it does.
RSpec.describe "Billing when Stripe is not configured", type: :request do
  let(:account) { create(:account, plan: "free") }
  let(:owner) { create(:user) }

  before { create(:membership, account: account, user: owner, role: "owner") }

  # Each of the three separately, because each is a different way to arrive here and
  # every one of them has to reach the same state.
  def unconfigure!(which)
    case which
    when :secret_key then Rails.configuration.stripe = Rails.configuration.stripe.merge(secret_key: nil)
    when :webhook_secret then Rails.configuration.stripe = Rails.configuration.stripe.merge(webhook_secret: nil)
    when :price then ENV["STRIPE_PRICE_PRO"] = nil
    end
    Billing::EventQuota.clear!
  end

  around do |example|
    original = ENV["STRIPE_PRICE_PRO"]
    example.run
    ENV["STRIPE_PRICE_PRO"] = original
  end

  describe "the predicate" do
    %i[secret_key webhook_secret price].each do |missing|
      it "reports billing as disabled when #{missing} is not set" do
        expect(Tastatur.billing_enabled?).to be(true)

        unconfigure!(missing)

        expect(Tastatur.billing_configured?).to be(false)
        expect(Tastatur.billing_enabled?).to be(false)
      end
    end

    # Nothing reads it — payment happens on Stripe's hosted Checkout, so this app
    # renders no card form. Requiring a variable nothing uses would mean telling a
    # correct deployment it is broken.
    it "does not require the publishable key" do
      Rails.configuration.stripe = Rails.configuration.stripe.merge(publishable_key: nil)

      expect(Tastatur.billing_enabled?).to be(true)
    end

    it "is off on a self-hosted install however well Stripe is configured" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)

      expect(Tastatur.billing_configured?).to be(true)
      expect(Tastatur.billing_enabled?).to be(false)
    end
  end

  # THE POINT OF THE WHOLE CHANGE. A limit nobody can lift is worse than no limit.
  describe "plan limits" do
    before { unconfigure!(:price) }

    it "does not cap events" do
      expect(account.event_limit).to eq(Billing::Plan::UNLIMITED)
      expect(Billing::EventQuota.allow?(account.id)).to be(true)
    end

    it "does not cap sites, so a free account is not stuck at one" do
      expect(account.site_limit).to eq(Billing::Plan::UNLIMITED)

      sign_in owner
      2.times do |i|
        post "/sites", params: { site: { domain: "n#{i}.example.com", timezone: "Etc/UTC",
                                         k_anonymity_threshold: 25 } }
        expect(response).to have_http_status(:redirect)
      end

      expect(account.sites.count).to eq(2)
    end

    it "ignores an override left in the columns, since there is nothing to override" do
      account.update!(event_limit_override: 5, site_limit_override: 1)

      expect(account.event_limit).to eq(Billing::Plan::UNLIMITED)
      expect(account.site_limit).to eq(Billing::Plan::UNLIMITED)
    end

    it "records events past what the free plan would have allowed" do
      site = create(:site, account: account)
      Billing::UsageMeter.record(account.id, count: 600_000)

      result = Ingest::RecordEvent.call(
        payload: { s: site.public_token, u: "https://#{site.domain}/" },
        ip: "203.0.113.9",
        user_agent: "Mozilla/5.0 (Macintosh) Chrome/131.0.0.0"
      )

      expect(result).to be_success
    end
  end

  describe "the interface" do
    before do
      # A SITE, or `GET /sites` redirects to the new-site form and every assertion
      # below runs against an empty body — asserting nothing while looking thorough.
      # The positive control in the link example is the other half of that guard.
      create(:site, account: account)
      unconfigure!(:secret_key)
      sign_in owner
    end

    it "offers no plan screen to an account that has never been billed" do
      get "/billing"

      expect(response).to redirect_to(sites_path)
    end

    it "publishes no prices, because they could not be charged" do
      get "/pricing"

      expect(response).to redirect_to(root_path)
    end

    it "shows no billing links anywhere" do
      get "/sites"

      # The control. Without it this example passed against the empty body of a 302.
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sites")

      expect(response.body).not_to include(billing_path)
      expect(response.body).not_to include(">Plan<")
      expect(response.body).not_to include("Pricing")
    end

    it "refuses a checkout even if the form is posted directly" do
      post "/billing/checkout"

      expect(response).to redirect_to(sites_path)
    end
  end

  describe "the webhook endpoint" do
    let(:payload) do
      stripe_event_payload(type: "customer.subscription.updated",
                           object: { id: "sub_1", object: "subscription", customer: "cus_1", status: "active" })
    end

    def deliver(signature)
      post "/billing/stripe/webhook", params: payload,
           headers: { "CONTENT_TYPE" => "application/json", "HTTP_STRIPE_SIGNATURE" => signature }
    end

    # 503 and not 404, because this one is transient and ours: a retry after the
    # secret is set will succeed, and the log names the variable. It is checked before
    # the general gate for exactly that reason.
    it "answers 503 when only the signing secret is missing" do
      signature = stripe_signature_header(payload)
      unconfigure!(:webhook_secret)

      deliver(signature)

      expect(response).to have_http_status(:service_unavailable)
    end

    # Nothing to sell, so nothing to hear about. Every service downstream would refuse
    # the event anyway, so accepting it would only write a receipt for work that
    # cannot happen.
    it "does not exist when there is no price to sell" do
      signature = stripe_signature_header(payload)
      unconfigure!(:price)

      deliver(signature)

      expect(response).to have_http_status(:not_found)
      expect(ProcessedWebhookEvent.count).to eq(0)
    end
  end

  # Both examples carry state the ENABLED path would visit, so a zero here means the
  # gate fired rather than that there was nothing to do. Without that, they would
  # report the same numbers whether the gates existed or not.
  describe "the scheduled jobs" do
    let!(:site) { create(:site, account: account) }
    let!(:subscriber) { create(:account, plan: "pro", stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1") }

    before do
      delete_all_events
      create_event(site, at: 1.hour.ago)
    end

    it "would visit this state if billing were on" do
      expect(Billing::ReconcileUsage.call(notify: false).value!.accounts_checked).to eq(1)

      allow(Billing::SyncSubscription).to receive(:call).and_return(Dry::Monads::Success(subscriber))
      expect(Billing::ReconcileSubscriptions.call.value!.checked).to eq(1)
    end

    it "does nothing once billing is off" do
      unconfigure!(:price)

      expect(Billing::ReconcileUsage.call.value!.accounts_checked).to eq(0)
      expect(Billing::ReconcileSubscriptions.call.value!.checked).to eq(0)
      expect(Billing::UsageMeter.used(account.id)).to eq(0)
    end

    it "makes no Stripe calls at all" do
      unconfigure!(:price)
      expect(Stripe::Subscription).not_to receive(:retrieve)
      expect(Stripe::Subscription).not_to receive(:list)

      Billing::ReconcileSubscriptions.call
    end
  end

  # THE FAILURE THIS SPLIT EXISTS TO PREVENT. Stripe keeps charging whatever our
  # configuration holds, so an instance that can no longer sell must still let a
  # subscriber cancel or fix a card. Gating both on one predicate meant taking the
  # money and removing the only cancel button in the product.
  describe "an existing subscriber when the instance can no longer sell" do
    let(:subscriber) do
      create(:account, plan: "pro", subscription_status: "active",
                       stripe_customer_id: "cus_live", stripe_subscription_id: "sub_live")
    end
    let(:subscriber_owner) { create(:user) }

    before do
      create(:membership, account: subscriber, user: subscriber_owner, role: "owner")
      create(:site, account: subscriber)
      # The price is gone; the API key is not. The portal needs only the key.
      unconfigure!(:price)
      sign_in subscriber_owner
      get "/", params: { account_slug: subscriber.slug }
    end

    it "can still reach the plan screen" do
      get "/billing", params: { account_slug: subscriber.slug }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Billing is not configured on this instance")
      expect(response.body).to include("Your existing subscription is unaffected")
    end

    it "can still open the Stripe portal, which is the only way to cancel" do
      allow(Stripe::BillingPortal::Session).to receive(:create).and_return(
        Stripe::BillingPortal::Session.construct_from(
          id: "bps_1", object: "billing_portal.session", url: "https://billing.stripe.com/p/session/bps_1"
        )
      )

      post "/billing/portal", params: { account_slug: subscriber.slug }

      expect(response).to redirect_to("https://billing.stripe.com/p/session/bps_1")
    end

    it "is offered no upgrade and no allowance it is not subject to" do
      get "/billing", params: { account_slug: subscriber.slug }

      expect(response.body).not_to include("Upgrade to")
      expect(response.body).not_to include("Events this month")
      expect(response.body).to include(billing_portal_path)
    end

    it "is refused a checkout posted directly, with an explanation" do
      post "/billing/checkout", params: { account_slug: subscriber.slug }

      expect(response).to redirect_to(billing_path)
      expect(flash[:alert]).to include("New subscriptions are not available")
    end

    it "still keeps its plan link in the nav, since there is something to manage" do
      get "/sites", params: { account_slug: subscriber.slug }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(billing_path)
    end

    # The API key is the one thing the portal cannot do without.
    it "loses the portal only when the API key itself is gone" do
      unconfigure!(:secret_key)

      post "/billing/portal", params: { account_slug: subscriber.slug }

      expect(response).to redirect_to(sites_path)
    end
  end

  # The instance is not permanently crippled: it comes back on by itself, with no
  # migration and no restart-order dance.
  describe "once the variables are set" do
    it "enforces limits again" do
      unconfigure!(:price)
      expect(account.event_limit).to eq(Billing::Plan::UNLIMITED)

      ENV["STRIPE_PRICE_PRO"] = "price_restored"
      Billing::EventQuota.clear!

      expect(Tastatur.billing_enabled?).to be(true)
      expect(account.event_limit).to eq(500_000)
      expect(account.site_limit).to eq(1)
    end
  end
end
