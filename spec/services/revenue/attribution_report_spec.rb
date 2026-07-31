require "rails_helper"

RSpec.describe Revenue::AttributionReport do
  before { travel_to Time.utc(2026, 6, 15, 12, 0, 0) }

  let(:site) { create(:site, timezone: "Etc/UTC", base_currency: "USD") }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  def report(sort: "revenue")
    described_class.call(site: site, period: period, sort: sort).value!
  end

  def rollup(date:, source:, **attrs)
    create(:attribution_rollup, site: site, date: date, source: source,
                                medium: Revenue::Channel::NONE, campaign: Revenue::Channel::NONE,
                                **{ visitors: 0, signups: 0, conversions: 0, net_mrr_cents: 0,
                                    new_mrr_cents: 0, lifetime_revenue_cents: 0 }.merge(attrs))
  end

  describe "summing across days" do
    it "adds up visitors, signups and MRR movement" do
      rollup(date: Date.new(2026, 6, 13), source: "reddit", visitors: 100, signups: 5, net_mrr_cents: 4_000)
      rollup(date: Date.new(2026, 6, 14), source: "reddit", visitors: 150, signups: 3, net_mrr_cents: 2_000)

      row = report[:rows].find { |r| r.source == "reddit" }

      expect(row.visitors).to eq(250)
      expect(row.signups).to eq(8)
      expect(row.net_mrr_cents).to eq(6_000)
    end

    # THE TRAP THIS SPEC EXISTS FOR, and it is the same one §8 documents for
    # distinct counts. `lifetime_revenue_cents` is a SNAPSHOT — everything the
    # channel has ever produced, written onto every single day's row. Summing it
    # over 30 days multiplies the business by thirty, and the number looks
    # entirely plausible.
    it "takes lifetime revenue from the latest day only, never the sum" do
      rollup(date: Date.new(2026, 6, 13), source: "reddit", lifetime_revenue_cents: 50_000)
      rollup(date: Date.new(2026, 6, 14), source: "reddit", lifetime_revenue_cents: 60_000)
      rollup(date: Date.new(2026, 6, 15), source: "reddit", lifetime_revenue_cents: 75_000)

      row = report[:rows].find { |r| r.source == "reddit" }

      expect(row.lifetime_revenue_cents).to eq(75_000)
    end

    it "takes the latest per channel independently" do
      rollup(date: Date.new(2026, 6, 13), source: "reddit", lifetime_revenue_cents: 10_000)
      rollup(date: Date.new(2026, 6, 15), source: "reddit", lifetime_revenue_cents: 30_000)
      rollup(date: Date.new(2026, 6, 14), source: "Google", lifetime_revenue_cents: 20_000)

      rows = report[:rows].index_by(&:source)

      expect(rows["reddit"].lifetime_revenue_cents).to eq(30_000)
      expect(rows["Google"].lifetime_revenue_cents).to eq(20_000)
    end
  end

  # SORTED BY MONEY BY DEFAULT. That single default is the product: sorting by
  # visitors reliably puts the channel sending the most people at the top, and
  # that is very often the channel sending the fewest customers.
  describe "sorting" do
    before do
      rollup(date: Date.new(2026, 6, 14), source: "Google", visitors: 10_000, net_mrr_cents: 1_000)
      rollup(date: Date.new(2026, 6, 14), source: "reddit", visitors: 50, net_mrr_cents: 40_000)
    end

    it "puts the highest revenue first by default" do
      expect(report[:rows].first.source).to eq("reddit")
    end

    it "can sort by visitors when asked" do
      expect(report(sort: "visitors")[:rows].first.source).to eq("Google")
    end

    it "falls back to revenue for an unknown sort rather than raising" do
      expect(report(sort: "'; DROP TABLE customers; --")[:rows].first.source).to eq("reddit")
    end

    # Without a tiebreak, channels with equal revenue — and the commonest revenue
    # figure is zero — swap places between page loads as PostgreSQL's row order
    # changes, which reads as data moving under the reader.
    it "is stable across repeated calls when revenue ties" do
      5.times { |i| rollup(date: Date.new(2026, 6, 14), source: "tied-#{i}", net_mrr_cents: 0) }

      expect(report[:rows].map(&:source)).to eq(report[:rows].map(&:source))
    end
  end

  describe "conversion rate" do
    # An em dash rather than 0%. A channel with conversions and no recorded
    # visitors is not converting at zero — it is a channel whose traffic we did
    # not see, which is what the Stripe backfill and every ad blocker produce.
    it "is nil when there are no recorded visitors" do
      rollup(date: Date.new(2026, 6, 14), source: "(pre-install)", visitors: 0, conversions: 4)

      expect(report[:rows].first.conversion_rate).to be_nil
    end

    it "is a fraction when there are" do
      rollup(date: Date.new(2026, 6, 14), source: "reddit", visitors: 200, conversions: 10)

      expect(report[:rows].first.conversion_rate).to be_within(0.0001).of(0.05)
    end
  end

  describe "totals" do
    it "reports what could not be converted rather than hiding it" do
      rollup(date: Date.new(2026, 6, 14), source: "reddit", unconverted_events: 3)

      expect(report[:totals][:unconverted_events]).to eq(3)
    end
  end

  describe "staleness" do
    it "reports nothing when there are no rollups at all" do
      expect(report[:stale_since]).to be_nil
      expect(report[:rows]).to be_empty
    end

    # A precomputed table that silently stops updating looks exactly like a
    # business that stopped growing.
    it "reports when it was last computed" do
      rollup(date: Date.new(2026, 6, 14), source: "reddit")

      expect(report[:stale_since]).to be_present
    end
  end

  describe "isolation" do
    it "never reads another site's rollups" do
      other = create(:site)
      create(:attribution_rollup, site: other, date: Date.new(2026, 6, 14), source: "reddit")

      expect(report[:rows]).to be_empty
    end
  end
end
