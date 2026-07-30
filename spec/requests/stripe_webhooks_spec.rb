require "rails_helper"

# The highest-risk endpoint in the application: unauthenticated, exempt from CSRF,
# and reachable by anything on the internet. Its only gate is the signature, so the
# real Stripe::Webhook.construct_event is exercised here rather than stubbed.
RSpec.describe "Stripe webhooks", type: :request do
  let!(:account) do
    create(:account, plan: "free", stripe_customer_id: "cus_1", stripe_subscription_id: "sub_1")
  end

  let(:subscription_object) do
    { id: "sub_1", object: "subscription", customer: "cus_1", status: "active" }
  end

  def deliver(payload, signature: nil, headers: {})
    post "/billing/stripe/webhook", params: payload,
         headers: { "CONTENT_TYPE" => "application/json",
                    "HTTP_STRIPE_SIGNATURE" => signature || stripe_signature_header(payload) }.merge(headers)
  end

  def subscription_event(id: "evt_1", type: "customer.subscription.updated")
    stripe_event_payload(id: id, type: type, object: subscription_object)
  end

  before do
    allow(Billing::SyncSubscription).to receive(:call).and_return(Dry::Monads::Success(account))
  end

  describe "a correctly signed event" do
    it "applies it and answers 200" do
      deliver(subscription_event)

      expect(response).to have_http_status(:ok)
      expect(Billing::SyncSubscription).to have_received(:call)
        .with(account: account, subscription_id: "sub_1")
    end

    it "needs no session and no CSRF token" do
      # This example does NOT prove CSRF exemption: the test environment sets
      # allow_forgery_protection = false, so a controller that forgot to escape
      # forgery protection would pass here and fail only in production. What
      # guarantees it is the inheritance, asserted directly below.
      deliver(subscription_event)

      expect(response).to have_http_status(:ok)
    end

    it "is an API controller, which is what actually exempts it from forgery protection" do
      expect(Billing::StripeWebhooksController.ancestors).to include(ActionController::API)
      expect(Billing::StripeWebhooksController.ancestors).not_to include(ApplicationController)
    end
  end

  describe "requests it must refuse" do
    it "answers 400 for a bad signature and applies nothing" do
      deliver(subscription_event, signature: "t=#{Time.now.to_i},v1=deadbeef")

      expect(response).to have_http_status(:bad_request)
      expect(Billing::SyncSubscription).not_to have_received(:call)
    end

    it "answers 400 when the signature header is missing entirely" do
      deliver(subscription_event, signature: "")

      expect(response).to have_http_status(:bad_request)
    end

    # construct_event raises JSON::ParserError here, not a StripeError — so a handler
    # rescuing only StripeError would answer 500 on a public endpoint, and put the
    # backtrace in Sentry for every malformed body anyone cared to send.
    it "answers 400 for a validly signed body that is not JSON" do
      deliver("{not json")

      expect(response).to have_http_status(:bad_request)
    end

    # Replay protection. Stripe::Webhook::DEFAULT_TOLERANCE is 300 seconds.
    it "answers 400 for a signature from an hour ago" do
      payload = subscription_event
      deliver(payload, signature: stripe_signature_header(payload, timestamp: 1.hour.ago))

      expect(response).to have_http_status(:bad_request)
    end

    it "answers 400 for a signed envelope missing the fields every handler needs" do
      payload = { id: "evt_x", object: "event", type: "customer.subscription.updated",
                  data: { object: {} } }.to_json

      deliver(payload)

      expect(response).to have_http_status(:bad_request)
    end
  end

  # A NON-2xx IS A FAILED DELIVERY. Stripe retries with backoff for three days and
  # disables an endpoint that keeps failing — so 2xx means "do not send this again",
  # and it is the right answer even for events we cannot use.
  describe "events it cannot act on" do
    it "answers 200 for an event type it does not handle" do
      deliver(stripe_event_payload(type: "charge.refunded",
                                   object: { id: "ch_1", object: "charge", customer: "cus_1" }))

      expect(response).to have_http_status(:ok)
    end

    # Retrying will never make an account we do not have exist, and repeated
    # failures would cost us every other customer's webhooks.
    it "answers 200 for an event that matches no account" do
      deliver(stripe_event_payload(type: "customer.subscription.updated",
                                   object: { id: "sub_nope", object: "subscription", customer: "cus_nope" }))

      expect(response).to have_http_status(:ok)
    end
  end

  describe "redelivery" do
    it "does the work once and answers 200 both times" do
      payload = subscription_event(id: "evt_repeat")

      deliver(payload)
      expect(response).to have_http_status(:ok)

      deliver(payload)
      expect(response).to have_http_status(:ok)

      expect(Billing::SyncSubscription).to have_received(:call).once
      expect(ProcessedWebhookEvent.where(event_id: "evt_repeat").count).to eq(1)
    end
  end

  # 503, not 400: the fault is ours, and a retry once the secret is set will
  # succeed. That turns a misconfigured deploy into a short gap rather than lost
  # subscription events.
  describe "when the signing secret is missing" do
    it "answers 503 and applies nothing" do
      payload = subscription_event
      signature = stripe_signature_header(payload)
      allow(Rails.configuration).to receive(:stripe).and_return(webhook_secret: nil)

      deliver(payload, signature: signature)

      expect(response).to have_http_status(:service_unavailable)
      expect(Billing::SyncSubscription).not_to have_received(:call)
    end
  end

  describe "when Stripe cannot be reached to apply the change" do
    it "answers 503 so the delivery is retried" do
      allow(Billing::SyncSubscription).to receive(:call)
        .and_return(Dry::Monads::Failure(stripe_error: "timed out"))

      deliver(subscription_event)

      expect(response).to have_http_status(:service_unavailable)
      expect(ProcessedWebhookEvent.count).to eq(0), "the receipt is released so the retry is new work"
    end
  end

  describe "on a self-hosted install" do
    it "does not exist" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)

      deliver(subscription_event)

      expect(response).to have_http_status(:not_found)
    end
  end

  # NOT THROTTLED, and this is not a nicety.
  #
  # Stripe delivers every customer's events from a small fixed set of its own
  # addresses, so under Rack::Attack's per-client limit the whole instance shares one
  # throttle key. At 300 per 5 minutes a busy month-end would 429 — which Stripe
  # counts as a failed delivery, retries for three days, and then disables the
  # endpoint. Losing subscription events silently is how a cancelled account stays on
  # Pro and an upgraded one stays capped.
  describe "rate limiting", :throttled do
    before { Rack::Attack.cache.store.clear }

    it "lets far more webhooks through than the per-client limit allows" do
      310.times do |i|
        deliver(subscription_event(id: "evt_flood_#{i}"))
        expect(response).not_to have_http_status(:too_many_requests)
      end
    end

    it "still throttles an ordinary path, so the exemption is specific" do
      statuses = Array.new(310) do
        get "/pricing"
        response.status
      end

      expect(statuses).to include(429)
    end
  end
end
