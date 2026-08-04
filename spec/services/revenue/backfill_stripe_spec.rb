require "rails_helper"

RSpec.describe Revenue::BackfillStripe do
  before { travel_to Time.utc(2026, 6, 15, 12, 0, 0) }

  let(:site) { create(:site, base_currency: "USD") }
  let(:connection) { create(:stripe_connection, site: site, stripe_account_id: "acct_1") }

  # Stubs Revenue::StripeAccount.each, which is the single seam every connected
  # call goes through — so a spec stubs one method rather than four Stripe
  # resource classes, and an unstubbed call still fails fast against the closed
  # port spec/support/stripe.rb points the client at.
  def stub_stripe(customers: [], subscriptions: [], invoices: [])
    allow(Revenue::StripeAccount).to receive(:each) do |resource, _conn, _params, &block|
      case resource.name
      when "Stripe::Customer" then customers.each(&block)
      when "Stripe::Subscription" then subscriptions.each(&block)
      when "Stripe::Invoice" then invoices.each(&block)
      end
    end
  end

  def stripe_customer(id: "cus_1", email: nil, metadata: {}, created: 90.days.ago.to_i)
    { id: id, email: email, metadata: metadata, created: created }
  end

  def stripe_subscription(id: "sub_1", customer: "cus_1", status: "active", cents: 4_000, **extra)
    { id: id, customer: customer, status: status, currency: "usd",
      start_date: 60.days.ago.to_i, created: 60.days.ago.to_i,
      items: { data: [{ price: { unit_amount: cents, recurring: { interval: "month", interval_count: 1 } },
                        quantity: 1 }] } }.merge(extra)
  end

  def stripe_invoice(id: "in_1", customer: "cus_1", amount: 4_000, subscription: "sub_1")
    { id: id, customer: customer, currency: "usd", amount_paid: amount, subscription: subscription,
      created: 30.days.ago.to_i, status_transitions: { paid_at: 30.days.ago.to_i } }
  end

  # The shape a CURRENT account sends. Stripe's 2025-03-31 Basil release moved the
  # subscription under `parent` and left no top-level key, so the helper above
  # describes a payload no live account has produced for over a year — which is
  # why the misclassification of every recurring payment as `one_time` survived a
  # green suite and had to be found by seeding a real connected account.
  def stripe_invoice_basil(id: "in_1", customer: "cus_1", amount: 4_000, subscription: "sub_1")
    { id: id, customer: customer, currency: "usd", amount_paid: amount,
      billing_reason: "subscription_create",
      parent: { type: "subscription_details", subscription_details: { subscription: subscription } },
      created: 30.days.ago.to_i, status_transitions: { paid_at: 30.days.ago.to_i } }
  end

  describe "importing" do
    it "creates customers, subscriptions and payments" do
      stub_stripe(customers: [stripe_customer], subscriptions: [stripe_subscription],
                  invoices: [stripe_invoice])

      result = described_class.call(connection: connection)

      expect(result).to be_success
      expect(site.customers.count).to eq(1)
      expect(site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1").mrr_cents).to eq(4_000)
      expect(site.revenue_events.find_by(kind: RevenueEvent::PAYMENT).amount_cents).to eq(4_000)
    end

    it "records a payment when the subscription arrives under parent" do
      stub_stripe(customers: [stripe_customer], subscriptions: [stripe_subscription],
                  invoices: [stripe_invoice_basil])

      described_class.call(connection: connection)

      expect(site.revenue_events.find_by(stripe_object_id: "in_1").kind).to eq(RevenueEvent::PAYMENT)
    end

    it "records one_time for an invoice belonging to no subscription" do
      stub_stripe(customers: [stripe_customer],
                  invoices: [stripe_invoice_basil(subscription: nil).except(:parent)])

      described_class.call(connection: connection)

      expect(site.revenue_events.find_by(stripe_object_id: "in_1").kind).to eq(RevenueEvent::ONE_TIME)
    end

    it "marks the connection as backfilled" do
      stub_stripe(customers: [stripe_customer])

      described_class.call(connection: connection)

      expect(connection.reload).to be_backfilled
    end

    # `(pre-install)`, not `(direct)`. Merging them makes the first month after
    # connecting look like an enormous direct-traffic win, which is both false and
    # exactly the kind of false that gets acted on.
    it "attributes customers with no metadata to (pre-install)" do
      stub_stripe(customers: [stripe_customer])

      described_class.call(connection: connection)

      expect(site.customers.first.attribution_source).to eq(Revenue::Channel::PRE_INSTALL)
    end

    it "uses attribution from metadata when the SDK put it there" do
      metadata = Revenue::Checkout.metadata(source: "reddit", campaign: "launch")
      stub_stripe(customers: [stripe_customer(metadata: metadata)])

      described_class.call(connection: connection)

      expect(site.customers.first.attribution_source).to eq("reddit")
    end

    # Without cancelled subscriptions the churn column is empty on day one, which
    # makes a business with real churn look like one with none — the most
    # flattering and least useful error this import could make.
    it "imports cancelled subscriptions too" do
      stub_stripe(customers: [stripe_customer],
                  subscriptions: [stripe_subscription(status: "canceled", canceled_at: 10.days.ago.to_i)])

      described_class.call(connection: connection)

      expect(site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1").status).to eq("canceled")
    end

    # Using the clock would stamp two years of history with today's date and pile
    # every historical signup onto one day of the attribution report.
    it "dates a subscription by its own history, not by now" do
      stub_stripe(customers: [stripe_customer], subscriptions: [stripe_subscription])

      described_class.call(connection: connection)

      record = site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1")
      expect(record.last_event_at).to be_within(1.day).of(60.days.ago)
    end
  end

  # The button exists on the settings screen, and the overlap between a live
  # webhook and a running backfill is by design.
  describe "running twice" do
    it "does not duplicate anything" do
      stub_stripe(customers: [stripe_customer], subscriptions: [stripe_subscription],
                  invoices: [stripe_invoice])

      2.times { described_class.call(connection: connection) }

      expect(site.customers.count).to eq(1)
      expect(site.customer_subscriptions.count).to eq(1)
      expect(site.revenue_events.where(kind: RevenueEvent::PAYMENT).count).to eq(1)
    end

    # (pre-install) means "we looked and there was nothing", not "they came from
    # nowhere". Real attribution arriving afterwards is strictly better
    # information and is allowed to win — exactly once. Without this the import
    # would permanently poison every customer it touched, pinning them to
    # (pre-install) forever even as the SDK started reporting properly.
    it "lets a later identify() replace the (pre-install) placeholder" do
      stub_stripe(customers: [stripe_customer])
      described_class.call(connection: connection)
      expect(site.customers.first.attribution_source).to eq(Revenue::Channel::PRE_INSTALL)

      Revenue::IdentifyCustomer.call(site: site,
                                     params: { stripe_customer_id: "cus_1",
                                               attribution: { source: "reddit", medium: "social" } })

      customer = site.customers.first
      expect(customer.attribution_source).to eq("reddit")
      expect(customer.attribution_medium).to eq("social")
    end

    it "does not let a re-import undo real attribution" do
      stub_stripe(customers: [stripe_customer])
      described_class.call(connection: connection)
      Revenue::IdentifyCustomer.call(site: site,
                                     params: { stripe_customer_id: "cus_1",
                                               attribution: { source: "reddit" } })

      described_class.call(connection: connection)

      expect(site.customers.first.attribution_source).to eq("reddit")
    end

    # And a real first touch still cannot be overwritten by a later one — the
    # whole point of write-once.
    it "still refuses a second real attribution" do
      Revenue::IdentifyCustomer.call(site: site,
                                     params: { stripe_customer_id: "cus_1",
                                               attribution: { source: "reddit" } })
      Revenue::IdentifyCustomer.call(site: site,
                                     params: { stripe_customer_id: "cus_1",
                                               attribution: { source: "Google" } })

      expect(site.customers.first.attribution_source).to eq("reddit")
    end
  end

  describe "refusals" do
    it "refuses a revoked connection" do
      connection.revoke!

      expect(described_class.call(connection: connection)).to be_failure
    end

    # A rate limit is the overwhelmingly common failure here and resolves itself
    # on retry, so it is returned rather than raised.
    it "returns a failure when Stripe refuses" do
      allow(Revenue::StripeAccount).to receive(:each).and_raise(Stripe::RateLimitError.new("slow down"))

      result = described_class.call(connection: connection)

      expect(result).to be_failure
      expect(connection.reload).not_to be_backfilled
    end
  end

  describe "orphans" do
    it "skips a subscription whose customer was never imported" do
      stub_stripe(subscriptions: [stripe_subscription(customer: "cus_unknown")])

      expect(described_class.call(connection: connection)).to be_success
      expect(site.customer_subscriptions).to be_empty
    end
  end
end
