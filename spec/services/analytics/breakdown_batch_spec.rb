require "rails_helper"

# The dashboard renders eight breakdown panels over identical rows with identical
# conditions, and used to scan the events table once per panel. Measured on 600,000
# events over 90 days: 152 ms for one panel, 1,233 ms for the eight — the entire
# cost of the page, since summary and timeseries come from the continuous
# aggregates and take 2–12 ms. One GROUPING SETS pass brings it to 836 ms.
#
# THIS FILE EXISTS FOR THE OTHER HALF OF THAT CHANGE. Breakdown is where
# k-anonymity is enforced, so an optimisation here can quietly leak a row that
# should have been withheld. The batch path deliberately shares `partition` and
# `to_row` with the single-dimension path and changes only how rows are fetched,
# and these examples assert the two produce identical output — not merely similar
# numbers, but the same rows, the same suppression counts and the same threshold.
RSpec.describe "Analytics::Breakdown.batch" do
  let(:site) { create(:site, k_anonymity_threshold: threshold) }
  let(:threshold) { 0 }
  let(:period) { Analytics::Period.new("30d", site: site) }
  let(:dimensions) { Analytics::Dashboard::PANELS.map { |panel| panel[:dimension] } }

  def snapshot(result)
    {
      rows: result.rows.map { |row| [row.value, row.visitors, row.pageviews, row.percentage] },
      suppressed_rows: result.suppressed_rows,
      suppressed_visitors: result.suppressed_visitors,
      threshold: result.threshold
    }
  end

  def one(dimension, filters: Analytics::Filters.new)
    Analytics::Breakdown.call(
      site: site, period: period, dimension: dimension, filters: filters
    ).value!
  end

  def batch(filters: Analytics::Filters.new)
    Analytics::Breakdown.batch(
      site: site, period: period, dimensions: dimensions, filters: filters
    )
  end

  before do
    # Enough shape that every panel has something in it, including NULL values —
    # country, campaign and referrer are all legitimately null, which is why the
    # batch query identifies a row's dimension with GROUPING() rather than by
    # looking for a non-null column.
    12.times do |i|
      create_event(
        site,
        visitor: "v#{i % 5}",
        session: "s#{i % 4}",
        at: (i % 20).days.ago + 3.hours,
        path: "/p/#{i % 3}",
        is_entry: i.even?,
        referrer_source: (i % 3).zero? ? nil : "Hacker News",
        country_code: (i % 4).zero? ? nil : %w[US GB DE][i % 3],
        browser: %w[Chrome Safari][i % 2],
        os: %w[macOS Windows][i % 2],
        device_type: %w[desktop mobile tablet][i % 3],
        utm_campaign: (i % 5).zero? ? nil : "launch"
      )
    end
  end

  shared_examples "identical to the per-dimension query" do |filters_builder|
    it "matches for every panel" do
      filters = filters_builder ? instance_exec(&filters_builder) : Analytics::Filters.new
      results = batch(filters: filters)

      dimensions.each do |dimension|
        expect(snapshot(results[dimension]))
          .to eq(snapshot(one(dimension, filters: filters))),
              "#{dimension} differed between the batch and per-dimension queries"
      end
    end
  end

  context "unfiltered, no suppression" do
    include_examples "identical to the per-dimension query"
  end

  # The case that matters most: suppression is the thing an optimisation here could
  # silently break, and it is a privacy guarantee rather than a display detail.
  context "with k-anonymity suppression active" do
    let(:threshold) { 3 }

    # The fixture above gives every path at least three visitors, so nothing would
    # be withheld and the assertions below would pass without testing anything. This
    # is the row that has to disappear.
    before { create_event(site, visitor: "lonely", path: "/seen-by-one", at: 2.days.ago) }

    include_examples "identical to the per-dimension query"

    it "withholds the row seen by too few people" do
      expect(batch["page"].rows.map(&:value)).not_to include("/seen-by-one")
    end

    it "reports that something was withheld rather than hiding it silently" do
      expect(batch["page"].suppressed_rows).to be_positive
    end

    it "keeps no row below the threshold" do
      expect(batch["page"].rows.map(&:visitors)).to all(be >= threshold)
    end

    # Complementary suppression: withholding exactly one row tells you its value,
    # because it is the reported total minus everything visible. So a second row
    # goes too.
    it "withholds a second row when only one fell below" do
      expect(batch["page"].suppressed_rows).to be >= 2
    end
  end

  context "with a filter applied" do
    include_examples "identical to the per-dimension query", -> { Analytics::Filters.new(country: "GB") }
  end

  context "with a filter that matches nothing" do
    include_examples "identical to the per-dimension query", -> { Analytics::Filters.new(country: "ZZ") }
  end

  describe "entry_page" do
    # entry_page is not a column: it is "path, for the first event of a visit". The
    # batch expresses it as `CASE WHEN is_entry THEN path END`, which collects every
    # non-entry event into a NULL bucket that has to be discarded — otherwise the
    # panel gains a phantom "(none)" row larger than all the real ones.
    it "counts only entry events" do
      expect(batch["entry_page"].rows.map(&:value)).to all(be_present)
    end

    it "matches the per-dimension query exactly" do
      expect(snapshot(batch["entry_page"])).to eq(snapshot(one("entry_page")))
    end

    it "is not the same as the page panel" do
      expect(snapshot(batch["entry_page"])).not_to eq(snapshot(batch["page"]))
    end
  end

  # `event` is the second conditional dimension and behaves exactly like
  # entry_page: a CASE that yields NULL for the rows it does not describe. Its NULL
  # bucket is every pageview on the site, so failing to discard it does not produce
  # a merely wrong panel — it produces one row bigger than every real row put
  # together, labelled "(none)".
  #
  # The fixture above sends only pageviews, so without these events both paths
  # would return nothing and compare equal while testing nothing at all.
  describe "event" do
    before do
      3.times { |i| create_event(site, visitor: "c#{i}", event_name: "Signup", path: "/pricing", at: 1.day.ago) }
      2.times { |i| create_event(site, visitor: "c#{i}", event_name: "Purchase", path: "/pricing", at: 1.day.ago) }
    end

    it "lists the custom event names" do
      expect(batch["event"].rows.map(&:value)).to contain_exactly("Signup", "Purchase")
    end

    it "excludes pageviews, which are not custom events" do
      expect(batch["event"].rows.map(&:value)).not_to include("pageview")
    end

    it "discards the NULL bucket rather than showing it as a row" do
      expect(batch["event"].rows.map(&:value)).to all(be_present)
    end

    it "counts distinct visitors per event name" do
      signup = batch["event"].rows.find { |row| row.value == "Signup" }
      expect(signup.visitors).to eq(3)
    end

    it "matches the per-dimension query exactly" do
      expect(snapshot(batch["event"])).to eq(snapshot(one("event")))
    end

    # The custom events all landed on /pricing, so if the exclusion were dropped
    # from one path and not the other this is where it would show.
    it "leaves the pageview panels alone" do
      expect(snapshot(batch["page"])).to eq(snapshot(one("page")))
    end
  end

  describe "the interface" do
    it "returns one result per requested dimension" do
      expect(batch.keys).to match_array(dimensions)
    end

    it "ignores a dimension it does not know" do
      results = Analytics::Breakdown.batch(
        site: site, period: period, dimensions: %w[page not_a_dimension]
      )

      expect(results.keys).to eq(["page"])
    end

    it "returns nothing when asked for nothing" do
      expect(Analytics::Breakdown.batch(site: site, period: period, dimensions: [])).to eq({})
    end
  end
end
