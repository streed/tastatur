require "rails_helper"

RSpec.describe Revenue::RollupAttribution do
  # THE CLOCK IS FROZEN AT MIDDAY, and this is not incidental tidiness.
  #
  # Every example here places an event a few hours in the past and then asserts
  # it lands on today's row. Run at 00:22 UTC — which is exactly when this file
  # first failed — `2.hours.ago` is yesterday, so the assertions fail for a
  # reason that has nothing to do with the code and cannot be reproduced in the
  # morning. A rollup spec is about day boundaries by definition, so the one
  # thing it must not do is inherit an arbitrary position within a day.
  #
  # Midday, and a fixed date, so "3 days ago" is unambiguous too.
  before { travel_to Time.utc(2026, 6, 15, 12, 0, 0) }

  let(:site) { create(:site, timezone: "Etc/UTC", base_currency: "USD") }
  let(:today) { Time.current.utc.to_date }

  def roll(from: today, to: from)
    described_class.call(site: site, from: from, to: to)
  end

  def rollup_for(source:, medium: Revenue::Channel::NONE, campaign: Revenue::Channel::NONE, date: today)
    site.attribution_rollups.find_by(date: date, source: source, medium: medium, campaign: campaign)
  end

  describe "traffic" do
    it "counts distinct visitors per channel" do
      create_event(site, visitor: "a", at: 2.hours.ago, utm_source: "reddit", utm_medium: "social")
      create_event(site, visitor: "a", at: 1.hour.ago, utm_source: "reddit", utm_medium: "social")
      create_event(site, visitor: "b", at: 1.hour.ago, utm_source: "reddit", utm_medium: "social")

      roll

      expect(rollup_for(source: "reddit", medium: "social").visitors).to eq(2)
    end

    it "falls back to the grouped referrer when there is no utm tag" do
      create_event(site, visitor: "a", at: 1.hour.ago,
                   referrer_host: "news.ycombinator.com", referrer_source: "Hacker News")

      roll

      expect(rollup_for(source: "Hacker News").visitors).to eq(1)
    end

    it "buckets untagged direct traffic under Direct" do
      create_event(site, visitor: "a", at: 1.hour.ago, referrer_source: "Direct")

      roll

      expect(rollup_for(source: "Direct").visitors).to eq(1)
    end
  end

  # THE JOIN THIS WHOLE FEATURE RESTS ON. A visit and the customer it produced
  # must land on ONE row. Two spellings of the same channel produce two rows —
  # one with all the visitors and no money, one with all the money and no
  # visitors — and the conversion rate reads 0% for the channel that is working.
  describe "the traffic and revenue halves meeting" do
    it "puts a referrer visit and its customer on the same row" do
      create_event(site, visitor: "a", at: 3.hours.ago,
                   referrer_host: "news.ycombinator.com", referrer_source: "Hacker News")

      # As Revenue::IdentifyCustomer would store it: the raw host classified
      # through the same table the events pipeline used.
      Revenue::IdentifyCustomer.call(
        site: site,
        params: { external_id: "u1", attribution: { referrer_host: "news.ycombinator.com" } }
      )

      roll

      rows = site.attribution_rollups.where(date: today, source: "Hacker News")
      expect(rows.count).to eq(1)
      expect(rows.first).to have_attributes(visitors: 1, signups: 1)
    end

    it "puts a utm-tagged visit and its customer on the same row" do
      create_event(site, visitor: "a", at: 3.hours.ago,
                   utm_source: "reddit", utm_medium: "social", utm_campaign: "launch")
      Revenue::IdentifyCustomer.call(
        site: site,
        params: { external_id: "u1",
                  attribution: { source: "reddit", medium: "social", campaign: "launch" } }
      )

      roll

      row = rollup_for(source: "reddit", medium: "social", campaign: "launch")
      expect(row).to have_attributes(visitors: 1, signups: 1)
    end
  end

  describe "the funnel" do
    # The three dates are different columns on purpose. Counting conversions
    # against the signup date makes every paid campaign look like it converts
    # instantly, which flatters exactly the campaigns that do not.
    it "counts a signup and a conversion on the days they each happened" do
      create(:customer, site: site, attribution_source: "reddit", attribution_medium: nil,
                        identified_at: 3.days.ago, converted_at: 1.day.ago)

      roll(from: today - 3, to: today)

      expect(rollup_for(source: "reddit", date: (Time.current - 3.days).utc.to_date).signups).to eq(1)
      expect(rollup_for(source: "reddit", date: (Time.current - 1.day).utc.to_date).conversions).to eq(1)
      expect(rollup_for(source: "reddit", date: (Time.current - 3.days).utc.to_date).conversions).to eq(0)
    end
  end

  describe "money" do
    let(:customer) do
      create(:customer, site: site, attribution_source: "reddit", attribution_medium: nil,
                        attribution_campaign: nil)
    end

    it "splits MRR movement by kind, and stores churn as a magnitude" do
      create(:revenue_event, site: site, customer: customer, kind: RevenueEvent::NEW,
                             amount_cents: 4_000, normalized_cents: 4_000, occurred_at: 2.hours.ago)
      create(:revenue_event, site: site, customer: customer, kind: RevenueEvent::CHURN,
                             amount_cents: -1_000, normalized_cents: -1_000, occurred_at: 1.hour.ago)

      roll

      row = rollup_for(source: "reddit")
      expect(row.new_mrr_cents).to eq(4_000)
      # Positive under a heading that says "Churned MRR" — a negative there gets
      # rendered as "-$10 churned", which reads as a gain.
      expect(row.churned_mrr_cents).to eq(1_000)
      expect(row.net_mrr_cents).to eq(3_000)
    end

    it "counts what it could not convert instead of folding it into the total" do
      create(:revenue_event, site: site, customer: customer, kind: RevenueEvent::NEW,
                             amount_cents: 4_000, currency: "EUR", normalized_cents: nil,
                             occurred_at: 1.hour.ago)

      roll

      row = rollup_for(source: "reddit")
      expect(row.new_mrr_cents).to eq(0)
      expect(row.unconverted_events).to eq(1)
    end
  end

  # Recomputing must REPLACE a day, not add to it — otherwise a day computed while
  # events were still arriving stays half-counted forever.
  describe "re-running" do
    it "replaces a day rather than accumulating" do
      create_event(site, visitor: "a", at: 1.hour.ago, utm_source: "reddit")
      roll
      expect(rollup_for(source: "reddit").visitors).to eq(1)

      create_event(site, visitor: "b", at: 1.hour.ago, utm_source: "reddit")
      roll

      expect(rollup_for(source: "reddit").visitors).to eq(2)
      expect(site.attribution_rollups.where(date: today, source: "reddit").count).to eq(1)
    end

    # PostgreSQL treats NULL as distinct from NULL in a unique index, so a
    # nullable campaign would let the upsert insert an unlimited number of
    # "direct traffic" rows for one day, each believing it was the first.
    it "never produces duplicate rows for untagged traffic" do
      3.times { create_event(site, visitor: SecureRandom.hex(4), at: 1.hour.ago) }
      3.times { roll }

      expect(site.attribution_rollups.where(date: today).count).to eq(1)
    end
  end

  describe "site-local days" do
    it "buckets by the site's own midnight, not UTC" do
      berlin = create(:site, timezone: "Europe/Berlin")
      # 23:30 UTC is already the next day in Berlin.
      at = Time.utc(2026, 6, 15, 23, 30)
      create_event(berlin, visitor: "a", at: at, utm_source: "reddit")

      described_class.call(site: berlin, from: Date.new(2026, 6, 15), to: Date.new(2026, 6, 16))

      expect(berlin.attribution_rollups.find_by(date: Date.new(2026, 6, 16), source: "reddit").visitors).to eq(1)
      expect(berlin.attribution_rollups.find_by(date: Date.new(2026, 6, 15), source: "reddit")).to be_nil
    end
  end

  describe "isolation" do
    it "never counts another site's traffic or revenue" do
      other = create(:site)
      create_event(other, visitor: "a", at: 1.hour.ago, utm_source: "reddit")

      roll

      expect(site.attribution_rollups.count).to eq(0)
    end
  end
end
