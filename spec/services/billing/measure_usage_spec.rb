require "rails_helper"

RSpec.describe Billing::MeasureUsage do
  let(:account) { create(:account, plan: "free") }

  it "reports the plan's allowances and the month it is measuring" do
    snapshot = described_class.call(account: account, at: Time.utc(2026, 7, 15)).value!

    expect(snapshot.plan).to eq(Billing::Plan.free)
    expect(snapshot.event_limit).to eq(500_000)
    expect(snapshot.site_limit).to eq(1)
    expect(snapshot.period_start).to eq(Time.utc(2026, 7, 1))
    expect(snapshot.period_end).to eq(Time.utc(2026, 8, 1))
  end

  # THE NUMBER SHOWN IS THE NUMBER ENFORCED.
  #
  # It comes from the meter, not from a count of stored rows, because the meter is
  # what Billing::EventQuota consults on the ingest path. Reading the database here
  # instead would let the figure a customer is shown differ from the one deciding
  # whether their events are recorded — and the customer would be right to trust the
  # smaller one. Billing::ReconcileUsage is what keeps the meter honest.
  it "reads the meter rather than the events table" do
    Billing::UsageMeter.record(account.id, count: 4_200)

    snapshot = described_class.call(account: account).value!

    expect(snapshot.events_used).to eq(4_200)
    expect(Event.count).to eq(0), "no rows were stored; the figure came from the meter"
  end

  it "carries last month's figure for comparison" do
    now = Time.utc(2026, 7, 15)
    Billing::UsageMeter.record(account.id, at: now, count: 10)
    Billing::UsageMeter.record(account.id, at: now - 1.month, count: 90)

    snapshot = described_class.call(account: account, at: now).value!

    expect(snapshot.events_used).to eq(10)
    expect(snapshot.events_used_last_month).to eq(90)
  end

  it "counts the account's sites" do
    create(:site, account: account)

    expect(described_class.call(account: account).value!.sites_used).to eq(1)
  end

  it "reports an override rather than the plan when one is set" do
    account.update!(event_limit_override: 250, site_limit_override: 9)

    snapshot = described_class.call(account: account).value!

    expect(snapshot.event_limit).to eq(250)
    expect(snapshot.site_limit).to eq(9)
  end
end
