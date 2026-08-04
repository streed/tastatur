require "rails_helper"

RSpec.describe "Stripe Connect webhooks", type: :request do
  let(:site) { create(:site, base_currency: "USD") }
  let!(:connection) { create(:stripe_connection, site: site, stripe_account_id: "acct_1") }

  # THE CONTROLLER'S CONTRACT IS "store, enqueue, 200" — interpreting the event is
  # ApplyConnectEventJob's job, and the suite uses the :test adapter, so nothing
  # runs unless a spec asks. Examples asserting on the resulting revenue use this;
  # examples asserting on the endpoint's own behaviour use post_connect_webhook.
  def deliver(payload)
    perform_enqueued_jobs { post_connect_webhook(payload) }
  end

  def subscription_object(id: "sub_1", status: "active", cents: 4_000, customer: "cus_1")
    { id: id, status: status, customer: customer, currency: "usd", start_date: 10.days.ago.to_i,
      items: { data: [{ price: { unit_amount: cents, recurring: { interval: "month", interval_count: 1 } },
                        quantity: 1 }] } }
  end

  describe "signature verification" do
    it "accepts a correctly signed delivery" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      post_connect_webhook(payload)

      expect(response).to have_http_status(:ok)
      expect(site.connect_events.count).to eq(1)
    end

    it "refuses an unsigned delivery" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      post stripe_connect_webhook_path, params: payload,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:bad_request)
      expect(site.connect_events).to be_empty
    end

    # THE SECRETS ARE DISTINCT BY DESIGN. Stripe issues one per endpoint, and an
    # "account" endpoint cannot also be a "connect" endpoint. A controller reading
    # the wrong one would reject every real delivery — and because a 400 counts as
    # a failed delivery, Stripe would disable the endpoint after three days.
    it "refuses a delivery signed with the billing endpoint's secret" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      post stripe_connect_webhook_path, params: payload,
           headers: { "Stripe-Signature" => stripe_signature_header(payload, secret: StripeWebhookHelpers::SECRET),
                      "Content-Type" => "application/json" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "routing an event to a site" do
    it "resolves the site from the connected account id" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      post_connect_webhook(payload)

      expect(site.connect_events.first.site_id).to eq(site.id)
    end

    # 200, not 404: this will never become an account we have, so a retry is
    # pointless and Stripe disables endpoints that keep failing.
    it "answers 200 and stores nothing for an unknown account" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_stranger")
      post_connect_webhook(payload)

      expect(response).to have_http_status(:ok)
      expect(ConnectEvent.count).to eq(0)
    end

    # Disconnecting has to stop revenue being recorded immediately, or the button
    # is a lie.
    it "ignores an event for a revoked connection" do
      connection.revoke!
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      post_connect_webhook(payload)

      expect(response).to have_http_status(:ok)
      expect(ConnectEvent.count).to eq(0)
    end
  end

  describe "events we do not handle" do
    it "answers 200 and stores nothing" do
      payload = stripe_connect_event_payload(type: "balance.available",
                                             object: { id: "ba_1" }, account: "acct_1")
      post_connect_webhook(payload)

      expect(response).to have_http_status(:ok)
      expect(ConnectEvent.count).to eq(0)
    end
  end

  # THE RECEIPT IS `processed_at`, NOT THE ROW. A row written on arrival and
  # treated as a receipt makes Stripe's retry look like a duplicate, so a delivery
  # that died halfway is discarded and the money is never recorded.
  describe "idempotency" do
    it "stores one row for a redelivered event" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1",
                                             id: "evt_same")

      2.times { post_connect_webhook(payload) }

      expect(response).to have_http_status(:ok)
      expect(site.connect_events.count).to eq(1)
    end

    it "does not double-count the revenue behind a redelivery" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1",
                                             id: "evt_same")

      2.times { deliver(payload) }

      expect(site.revenue_events.where(kind: RevenueEvent::NEW).count).to eq(1)
    end
  end

  describe "end to end" do
    it "turns a subscription event into a customer, a subscription and MRR" do
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      deliver(payload)

      customer = site.customers.find_by(stripe_customer_id: "cus_1")
      expect(customer).to be_present
      expect(customer.current_mrr_cents).to eq(4_000)
      expect(site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1").mrr_cents).to eq(4_000)
      expect(site.connect_events.first).to be_processed
    end

    it "records cash from a paid invoice separately from MRR" do
      create(:customer, site: site, stripe_customer_id: "cus_1", external_id: nil)
      payload = stripe_connect_event_payload(
        type: "invoice.paid",
        object: { id: "in_1", customer: "cus_1", currency: "usd", amount_paid: 48_000,
                  subscription: "sub_1", status_transitions: { paid_at: Time.current.to_i } },
        account: "acct_1"
      )
      deliver(payload)

      event = site.revenue_events.find_by(kind: RevenueEvent::PAYMENT)
      expect(event.amount_cents).to eq(48_000)
      expect(site.customers.find_by(stripe_customer_id: "cus_1").lifetime_revenue_cents).to eq(48_000)
    end

    # THE SHAPE ABOVE IS THE OLD ONE, AND NO CURRENT ACCOUNT SENDS IT. Stripe's
    # 2025-03-31 Basil release moved an invoice's subscription to
    # `parent.subscription_details.subscription`, leaving no top-level key — so a
    # spec that builds `subscription:` by hand passes against a payload Stripe has
    # not sent for over a year, while every real recurring payment was recorded as
    # `one_time`. Found by seeding a real connected account, not by this suite.
    # Both shapes are kept: the account's own pinned API version decides which
    # arrives, and that is the customer's choice rather than ours.
    it "records cash as a recurring payment when the subscription arrives under parent" do
      create(:customer, site: site, stripe_customer_id: "cus_1", external_id: nil)
      payload = stripe_connect_event_payload(
        type: "invoice.paid",
        object: { id: "in_2", customer: "cus_1", currency: "usd", amount_paid: 48_000,
                  billing_reason: "subscription_create",
                  parent: { type: "subscription_details",
                            subscription_details: { subscription: "sub_1" } },
                  status_transitions: { paid_at: Time.current.to_i } },
        account: "acct_1"
      )
      deliver(payload)

      event = site.revenue_events.find_by(stripe_object_id: "in_2")
      expect(event.kind).to eq(RevenueEvent::PAYMENT)
      expect(event.amount_cents).to eq(48_000)
    end

    it "records cash as one_time when an invoice belongs to no subscription" do
      create(:customer, site: site, stripe_customer_id: "cus_1", external_id: nil)
      payload = stripe_connect_event_payload(
        type: "invoice.paid",
        object: { id: "in_3", customer: "cus_1", currency: "usd", amount_paid: 9_900,
                  status_transitions: { paid_at: Time.current.to_i } },
        account: "acct_1"
      )
      deliver(payload)

      expect(site.revenue_events.find_by(stripe_object_id: "in_3").kind).to eq(RevenueEvent::ONE_TIME)
    end

    it "records a refund as negative cash" do
      create(:customer, site: site, stripe_customer_id: "cus_1", external_id: nil)
      payload = stripe_connect_event_payload(
        type: "charge.refunded",
        object: { id: "ch_1", customer: "cus_1", currency: "usd", amount_refunded: 2_000 },
        account: "acct_1"
      )
      deliver(payload)

      expect(site.revenue_events.find_by(kind: RevenueEvent::REFUND).amount_cents).to eq(-2_000)
    end

    # A REAL dispute payload names a charge and carries NO customer field — the
    # shape that used to fail with :no_customer and burn a day of retries. The
    # customer is resolved by reading the named charge through the same wrapper
    # the backfill uses.
    it "records a dispute by resolving the customer through its charge" do
      create(:customer, site: site, stripe_customer_id: "cus_1", external_id: nil)
      allow(Revenue::StripeAccount).to receive(:retrieve)
        .with(Stripe::Charge, anything, "ch_1")
        .and_return({ id: "ch_1", customer: "cus_1" })
      payload = stripe_connect_event_payload(
        type: "charge.dispute.created",
        object: { id: "dp_1", charge: "ch_1", currency: "usd", amount: 4_000 },
        account: "acct_1"
      )
      deliver(payload)

      expect(site.revenue_events.find_by(kind: RevenueEvent::DISPUTE).amount_cents).to eq(-4_000)
    end

    # A failed payment is not churn and not a refund — Stripe retries for about
    # two weeks and most succeed. A negative row here plus a positive one on the
    # eventual success puts a spike and a trough into every chart for an event
    # whose usual outcome is nothing at all.
    it "writes no revenue row for a failed payment" do
      create(:customer, site: site, stripe_customer_id: "cus_1", external_id: nil)
      payload = stripe_connect_event_payload(
        type: "invoice.payment_failed",
        object: { id: "in_2", customer: "cus_1", currency: "usd", amount_due: 4_000 },
        account: "acct_1"
      )
      deliver(payload)

      expect(site.revenue_events).to be_empty
      expect(site.connect_events.first).to be_processed
    end
  end

  describe "attribution passed through Stripe" do
    # THE MECHANISM THAT SURVIVES A CLOSED TAB. The attribution travels inside the
    # payment, so no browser is involved when it lands.
    it "applies attribution from checkout session metadata" do
      payload = stripe_connect_event_payload(
        type: "checkout.session.completed",
        object: { id: "cs_1", customer: "cus_1", client_reference_id: "user_9182",
                  metadata: Revenue::Checkout.metadata(source: "reddit", medium: "social",
                                                       campaign: "launch", landing_path: "/pricing") },
        account: "acct_1"
      )
      deliver(payload)

      customer = site.customers.find_by(stripe_customer_id: "cus_1")
      expect(customer.attribution_source).to eq("reddit")
      expect(customer.attribution_campaign).to eq("launch")
      expect(customer.external_id).to eq("user_9182")
    end
  end

  # THE EXEMPTION IS PINNED, because losing it produces the worst-shaped outage
  # this feature has. Stripe delivers every customer's events from a small fixed
  # set of its own addresses, so under the general per-client throttle the ENTIRE
  # instance shares one key — and this endpoint carries every subscription,
  # invoice, refund and dispute of every customer's whole business, so it is the
  # first thing to hit 300 in 5 minutes. Stripe then treats each 429 as a failed
  # delivery, retries for three days, and disables the endpoint; the revenue
  # screen stops advancing for everybody at once, with nothing raised.
  # ASSERTED AGAINST THE THROTTLE ITSELF, not by sending traffic. The limit is 300
  # in 5 minutes, so a behavioural test would have to issue 301 signed webhooks —
  # slow enough that nobody would keep it, and a smaller loop passes whether or not
  # the exemption exists, which is worse than no test at all (the first draft of
  # this sent 40 and was therefore green either way).
  #
  # The throttle block returns a discriminator to count against, or nil to exempt.
  # Calling it directly is the actual contract.
  describe "rate limiting" do
    def throttle_key_for(path)
      request = Rack::Attack::Request.new(Rack::MockRequest.env_for("https://example.com#{path}"))

      Rack::Attack.throttles["req/client"].block.call(request)
    end

    it "is exempt from the general per-client throttle" do
      expect(throttle_key_for("/stripe/connect/webhook")).to be_nil
    end

    it "still throttles an ordinary path, so the exemption is specific" do
      expect(throttle_key_for("/dashboard")).to be_present
    end
  end

  # Uninstalling the app from the customer's own Stripe dashboard is a
  # disconnect performed at the other end, and it must land exactly where our
  # Disconnect button lands: connection revoked, recorded revenue kept.
  describe "the customer uninstalling the app" do
    def deauthorized_payload(id: "evt_test_#{SecureRandom.hex(6)}")
      stripe_connect_event_payload(type: "account.application.deauthorized",
                                   object: { id: "ca_app", object: "application" },
                                   account: "acct_1", id: id)
    end

    it "revokes the connection and keeps recorded revenue" do
      create(:revenue_event, site: site)

      deliver(deauthorized_payload)

      expect(response).to have_http_status(:ok)
      expect(connection.reload).to be_revoked
      expect(site.revenue_events.count).to eq(1)
    end

    # Stripe retries, and the first delivery already revoked the connection —
    # which also means `site_for` no longer resolves it. 200 without storage is
    # the contract for events that can never become ours again.
    it "answers 200 to a retry after the connection is already revoked" do
      connection.revoke!

      deliver(deauthorized_payload)

      expect(response).to have_http_status(:ok)
      expect(site.connect_events).to be_empty
    end

    # The stale-deauth race: a deauthorization that failed to apply stays in
    # the 24-hour retry sweep, and disconnect-then-reconnect is the documented
    # remedy for most problems — so without the superseded guard, the sweep
    # would revoke a reconnection made AFTER the uninstall it describes, and
    # recording would stop with nothing raised.
    it "does not let a stale deauthorization revoke a newer reconnection" do
      stale = create(:connect_event, site: site,
                     event_type: "account.application.deauthorized",
                     occurred_at: 2.hours.ago,
                     payload: { "id" => "evt_stale", "type" => "account.application.deauthorized",
                                "account" => "acct_1", "data" => { "object" => { "object" => "application" } } })
      connection.update!(connected_at: 1.hour.ago)

      result = Revenue::ApplyConnectEvent.call(connect_event: stale)

      expect(result).to be_success
      expect(connection.reload).to be_live
      expect(stale.reload).to be_processed
    end
  end

  describe "when Connect is not configured" do
    it "answers 404 rather than storing anything" do
      Rails.configuration.stripe = Rails.configuration.stripe.merge(connect_client_id: nil)
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      deliver(payload)

      expect(response).to have_http_status(:not_found)
    end

    # 503, not 404: the fault is ours and a retry after the secret is set will
    # succeed, which turns a misconfigured deploy into a short gap rather than
    # permanently lost revenue data.
    it "answers 503 when only the signing secret is missing" do
      Rails.configuration.stripe = Rails.configuration.stripe.merge(connect_webhook_secret: nil)
      payload = stripe_connect_event_payload(type: "customer.subscription.created",
                                             object: subscription_object, account: "acct_1")
      deliver(payload)

      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
