require "rails_helper"

RSpec.describe Analytics::Timeseries do
  # The series of buckets is generated in Ruby and matched against the database's
  # `time_bucket` output by equality, so the two must agree on where a bucket
  # starts. `time_bucket` aligns to its own origin — Monday for weeks, the 1st for
  # months — and not to whatever date a report happens to begin on.
  #
  # When the series started at `period.from` instead, every generated bucket for a
  # weekly or monthly report existed in Ruby and nowhere in the result set. Every
  # lookup missed, every point read zero, and the chart drew a flat line. Measured
  # on the 12-month preset before the fix: 0 pageviews charted against 17,286 real
  # ones.
  #
  # It was invisible for the day and hour intervals because `period.from` is
  # already midnight and therefore already aligned, which is why the two presets
  # people look at most were fine and the annual view was silently empty.
  describe "bucket alignment" do
    # A filter is applied throughout so the raw-scan path is used and no continuous
    # aggregate needs refreshing. Both paths share the same series generation, so
    # the alignment logic is the same either way.
    let(:filters) { Analytics::Filters.new(page: "/pricing") }

    def totals_for(site, period)
      result = described_class.call(site: site, period: period, filters: filters)
      points = result.value!

      raw = Analytics::Scope.new(site: site, period: period, filters: filters)
      where, binds = raw.raw_conditions
      expected = raw.select_all(
        "SELECT COUNT(*) FILTER (WHERE event_name = 'pageview') AS pv FROM events WHERE #{where}", binds
      ).first["pv"].to_i

      [points, expected]
    end

    context "a weekly report that does not begin on a Monday" do
      let(:site) { create(:site, timezone: "Etc/UTC") }

      before do
        # A Friday start, which is what the 12-month preset produces on most days.
        3.times do |week|
          2.times { |i| create_event(site, path: "/pricing", visitor: "v#{week}#{i}", at: Time.utc(2026, 1, 2) + (week * 7).days) }
        end
      end

      let(:period) do
        Analytics::Period.new("custom", site: site, from: "2026-01-02", to: "2026-04-30")
      end

      it "charts every pageview rather than losing them to unmatched buckets" do
        points, expected = totals_for(site, period)

        expect(expected).to eq(6)
        expect(points.sum(&:pageviews)).to eq(expected)
      end

      it "starts the series on a Monday, as time_bucket does" do
        points, = totals_for(site, period)

        expect(points.first.bucket.strftime("%A")).to eq("Monday")
      end

      it "agrees with time_bucket on every bucket it generates" do
        points, = totals_for(site, period)
        scope = Analytics::Scope.new(site: site, period: period, filters: filters)
        where, binds = scope.raw_conditions

        from_sql = scope.select_all(
          "SELECT DISTINCT #{scope.bucket_expression} AS bucket FROM events WHERE #{where}", binds
        ).map { |row| row["bucket"].in_time_zone(site.timezone) }

        # Every bucket the database produced must be one the series also produced,
        # or its rows are silently dropped from the chart.
        expect(from_sql - points.map(&:bucket)).to be_empty
      end
    end

    context "a monthly report that does not begin on the first" do
      let(:site) { create(:site, timezone: "Etc/UTC") }

      before do
        create_event(site, path: "/pricing", visitor: "a", at: Time.utc(2025, 1, 20))
        create_event(site, path: "/pricing", visitor: "b", at: Time.utc(2025, 6, 15))
        create_event(site, path: "/pricing", visitor: "c", at: Time.utc(2026, 2, 3))
      end

      # Over 400 days, so Period picks the month interval.
      let(:period) do
        Analytics::Period.new("custom", site: site, from: "2025-01-15", to: "2026-04-20")
      end

      it "uses month buckets" do
        expect(period.interval).to eq("month")
      end

      it "charts every pageview" do
        points, expected = totals_for(site, period)

        expect(expected).to eq(3)
        expect(points.sum(&:pageviews)).to eq(expected)
      end

      it "starts the series on the first of a month" do
        points, = totals_for(site, period)

        expect(points.first.bucket.day).to eq(1)
      end
    end

    # The snap has to happen in the site's zone, not UTC, or a non-UTC site's
    # buckets land an offset away from the database's.
    context "a site reporting in a non-UTC timezone" do
      let(:site) { create(:site, timezone: "America/New_York") }

      before do
        create_event(site, path: "/pricing", visitor: "a", at: Time.utc(2026, 1, 7, 12))
        create_event(site, path: "/pricing", visitor: "b", at: Time.utc(2026, 1, 21, 12))
      end

      let(:period) do
        Analytics::Period.new("custom", site: site, from: "2026-01-02", to: "2026-04-30")
      end

      it "charts every pageview" do
        points, expected = totals_for(site, period)

        expect(expected).to eq(2)
        expect(points.sum(&:pageviews)).to eq(expected)
      end

      it "generates buckets at midnight in the site's own zone" do
        points, = totals_for(site, period)

        expect(points.map { |point| point.bucket.strftime("%H:%M") }.uniq).to eq(["00:00"])
      end
    end

    # These two were always correct, and the spec says so explicitly so a future
    # change to the snapping cannot quietly break them.
    %w[7d 30d].each do |preset|
      it "still charts every pageview for the #{preset} preset" do
        site = create(:site, timezone: "Etc/UTC")
        create_event(site, path: "/pricing", visitor: "a", at: 1.day.ago)
        create_event(site, path: "/pricing", visitor: "b", at: 2.days.ago)

        points, expected = totals_for(site, Analytics::Period.new(preset, site: site))

        expect(points.sum(&:pageviews)).to eq(expected)
      end
    end
  end

  describe "gap filling" do
    let(:site) { create(:site, timezone: "Etc/UTC") }
    let(:filters) { Analytics::Filters.new(page: "/pricing") }

    it "returns a point for every bucket, including empty ones" do
      create_event(site, path: "/pricing", visitor: "a", at: 2.days.ago)

      points = described_class.call(
        site: site, period: Analytics::Period.new("7d", site: site), filters: filters
      ).value!

      expect(points.size).to eq(7)
      expect(points.count { |point| point.pageviews.zero? }).to eq(6)
    end
  end
end
