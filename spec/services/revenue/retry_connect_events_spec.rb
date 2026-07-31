require "rails_helper"

RSpec.describe Revenue::RetryConnectEvents do
  let(:site) { create(:site, base_currency: "USD") }
  let!(:connection) { create(:stripe_connection, site: site, stripe_account_id: "acct_1") }

  def subscription_payload(id: "sub_1", cents: 4_000, customer: "cus_1")
    { "id" => "evt_1", "type" => "customer.subscription.created", "account" => "acct_1",
      "data" => { "object" => {
        "id" => id, "status" => "active", "customer" => customer, "currency" => "usd",
        "start_date" => 10.days.ago.to_i,
        "items" => { "data" => [{ "price" => { "unit_amount" => cents,
                                               "recurring" => { "interval" => "month",
                                                                "interval_count" => 1 } },
                                  "quantity" => 1 }] }
      } } }
  end

  def unprocessed_event(**attrs)
    create(:connect_event, site: site, event_type: "customer.subscription.created",
                           payload: subscription_payload, occurred_at: 1.hour.ago, **attrs)
  end

  it "applies an event that was stored and never processed" do
    event = unprocessed_event

    result = described_class.call

    expect(result).to be_success
    expect(event.reload).to be_processed
    expect(site.customers.find_by(stripe_customer_id: "cus_1")).to be_present
  end

  it "leaves an already-processed event alone" do
    event = unprocessed_event(processed_at: 1.minute.ago)

    expect { described_class.call }.not_to change { site.revenue_events.count }
    expect(event.reload.processed_at).to be_present
  end

  # An event that has been failing for a day is not going to start working, and
  # re-running it hourly forever hides the fact that it never will.
  it "ignores an event older than the retry window" do
    event = unprocessed_event(occurred_at: 3.days.ago)

    described_class.call

    expect(event.reload).not_to be_processed
  end

  # Stripe delivers out of order and the sweep must not preserve that: applying a
  # cancellation before the subscription it cancels leaves the row wrong, and the
  # ordering guard would then discard the newer event as stale.
  it "applies events oldest first" do
    create(:connect_event, site: site, stripe_event_id: "evt_newer",
                           event_type: "customer.subscription.created",
                           payload: subscription_payload(cents: 9_000), occurred_at: 1.hour.ago)
    create(:connect_event, site: site, stripe_event_id: "evt_older",
                           event_type: "customer.subscription.created",
                           payload: subscription_payload(cents: 4_000), occurred_at: 5.hours.ago)

    described_class.call

    # Ending at the newer value proves the older one was applied first.
    expect(site.customer_subscriptions.find_by(stripe_subscription_id: "sub_1").mrr_cents).to eq(9_000)
  end

  it "records a failure on the row rather than raising" do
    event = create(:connect_event, site: site, event_type: "customer.subscription.created",
                                   payload: { "data" => { "object" => nil } }, occurred_at: 1.hour.ago)

    expect { described_class.call }.not_to raise_error
    expect(event.reload).not_to be_processed
  end

  it "reports nothing to do when the backlog is empty" do
    expect(described_class.call.value!).to eq(attempted: 0, applied: 0)
  end

  # One site with a large backlog must not occupy the whole window.
  it "stops at the batch ceiling" do
    3.times do |i|
      create(:connect_event, site: site, stripe_event_id: "evt_#{i}",
                             event_type: "customer.subscription.created",
                             payload: subscription_payload(id: "sub_#{i}"), occurred_at: (i + 1).minutes.ago)
    end

    expect(described_class.call(limit: 2).value![:attempted]).to eq(2)
  end
end
