require "rails_helper"

RSpec.describe Analytics::Breakdown do
  let(:site) { create(:site, k_anonymity_threshold: 5) }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  before { delete_all_events }

  def breakdown(dimension: "page", **kwargs)
    described_class.call(site: site, period: period, dimension: dimension, **kwargs).value!
  end

  describe "counting" do
    it "counts distinct visitors, not pageviews" do
      3.times { create_event(site, visitor: "v1", path: "/pricing", at: 1.day.ago) }
      create_event(site, visitor: "v2", path: "/pricing", at: 1.day.ago)

      site.update!(k_anonymity_threshold: 0)
      row = breakdown.rows.find { |r| r.value == "/pricing" }

      expect(row.visitors).to eq(2)
      expect(row.pageviews).to eq(4)
    end

    it "orders by visitors descending" do
      site.update!(k_anonymity_threshold: 0)
      create_events(site, count: 3, path: "/a", visitor_prefix: "a", at: 1.day.ago)
      create_events(site, count: 7, path: "/b", visitor_prefix: "b", at: 1.day.ago)

      expect(breakdown.rows.map(&:value)).to eq(["/b", "/a"])
    end

    it "scopes to the site" do
      other = create(:site)
      create_events(site, count: 6, path: "/mine", visitor_prefix: "m", at: 1.day.ago)
      create_events(other, count: 6, path: "/theirs", visitor_prefix: "t", at: 1.day.ago)

      expect(breakdown.rows.map(&:value)).to eq(["/mine"])
    end

    it "excludes events outside the period" do
      create_events(site, count: 6, path: "/old", visitor_prefix: "o", at: 90.days.ago)
      expect(breakdown.rows).to be_empty
    end
  end

  describe "k-anonymity suppression" do
    it "withholds rows below the threshold" do
      create_events(site, count: 10, path: "/popular", visitor_prefix: "p", at: 1.day.ago)
      create_events(site, count: 2, path: "/obscure", visitor_prefix: "o", at: 1.day.ago)
      create_events(site, count: 2, path: "/rare", visitor_prefix: "r", at: 1.day.ago)

      result = breakdown

      expect(result.rows.map(&:value)).to eq(["/popular"])
      expect(result.suppressed_rows).to eq(2)
      expect(result.suppressed_visitors).to eq(4)
    end

    # THE IMPORTANT ONE. Suppressing a single row protects nothing, because
    # its value is recoverable as (reported total - sum of visible rows). The
    # fix is to withhold a second row so the withheld total covers at least two.
    describe "complementary suppression" do
      before do
        create_events(site, count: 10, path: "/popular", visitor_prefix: "p", at: 1.day.ago)
        create_events(site, count: 8,  path: "/second",  visitor_prefix: "s", at: 1.day.ago)
        create_events(site, count: 2,  path: "/obscure", visitor_prefix: "o", at: 1.day.ago)
      end

      it "withholds a second row when only one falls below the threshold" do
        result = breakdown

        expect(result.suppressed_rows).to eq(2)
        expect(result.rows.map(&:value)).to eq(["/popular"])
      end

      it "withholds the smallest surviving row, not an arbitrary one" do
        expect(breakdown.rows.map(&:value)).not_to include("/second")
      end

      it "leaves the suppressed total un-attributable to either row" do
        result = breakdown
        # 2 (obscure) + 8 (second) = 10, which matches neither row alone.
        expect(result.suppressed_visitors).to eq(10)
        expect(result.suppressed_visitors).not_to eq(2)
      end
    end

    it "suppresses nothing when the threshold is zero" do
      site.update!(k_anonymity_threshold: 0)
      create_event(site, visitor: "v1", path: "/one-visitor", at: 1.day.ago)

      result = breakdown
      expect(result.rows.map(&:value)).to eq(["/one-visitor"])
      expect(result).not_to be_suppressed
    end
  end

  describe "dimensions" do
    before do
      site.update!(k_anonymity_threshold: 0)
      create_event(site, visitor: "v1", country_code: "DE", browser: "Firefox",
                         device_type: "mobile", referrer_source: "Hacker News", at: 1.day.ago)
    end

    it "supports every advertised dimension" do
      Analytics::Filters::DIMENSIONS.each_key do |dimension|
        result = described_class.call(site: site, period: period, dimension: dimension)
        expect(result).to be_success, "dimension #{dimension} failed"
      end
    end

    it "rejects an unknown dimension rather than interpolating it into SQL" do
      result = described_class.call(site: site, period: period, dimension: "path); DROP TABLE events;--")
      expect(result).to be_failure
    end
  end

  describe "entry_page" do
    it "only counts the first pageview of a session" do
      site.update!(k_anonymity_threshold: 0)
      create_event(site, visitor: "v1", path: "/landing", is_entry: true, at: 2.hours.ago)
      create_event(site, visitor: "v1", path: "/second", is_entry: false, at: 1.hour.ago)

      expect(breakdown(dimension: "entry_page").rows.map(&:value)).to eq(["/landing"])
    end
  end
end
