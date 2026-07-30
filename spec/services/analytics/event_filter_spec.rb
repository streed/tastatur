require "rails_helper"

# What the dashboard means when it is filtered to one custom event.
#
# An event filter pins event_name in the WHERE clause, and "pageviews" is a
# count of events named 'pageview' — two conditions that cannot both hold. The
# dashboard used to render the collision literally: "0 pageviews" in the
# summary and a flat volume line in the chart, directly above panels listing
# the very visitors who fired the event. Filtering to an event now switches the
# volume metric to the matching events themselves (labelled "Events" in the
# views), keeps the session-grain metrics session-scoped, and gives the
# session-grain panels sessions rather than contradictions.
RSpec.describe "The dashboard under an event filter" do
  let(:site) { create(:site, timezone: "Etc/UTC", k_anonymity_threshold: 0) }
  let(:period) { Analytics::Period.new("7d", site: site) }
  let(:filters) { Analytics::Filters.new("event" => "Signup") }
  let(:base) { 2.days.ago.change(hour: 12) }

  before do
    # Two converting sessions. The second fires the event twice, which is what
    # separates "matching events" (3) from "visitors who fired it" (2).
    create_event(site, visitor: "c1", path: "/home", is_entry: true, at: base)
    create_event(site, visitor: "c1", path: "/pricing", at: base + 2.minutes)
    create_event(site, visitor: "c1", path: "/pricing", event_name: "Signup", at: base + 3.minutes)

    create_event(site, visitor: "c2", path: "/blog", is_entry: true, at: base + 1.hour)
    create_event(site, visitor: "c2", path: "/pricing", at: base + 1.hour + 2.minutes)
    create_event(site, visitor: "c2", path: "/pricing", event_name: "Signup", at: base + 1.hour + 3.minutes)
    create_event(site, visitor: "c2", path: "/pricing", event_name: "Signup", at: base + 1.hour + 4.minutes)

    # A session that never converted, which nothing below should count.
    create_event(site, visitor: "browser", path: "/home", is_entry: true, at: base + 2.hours)
  end

  describe Analytics::Summary do
    let(:metrics) { described_class.call(site: site, period: period, filters: filters).value! }

    it "carries the matching events in the volume metric, not a structural zero" do
      expect(metrics.pageviews).to eq(3)
    end

    it "counts the visitors who fired the event" do
      expect(metrics.visitors).to eq(2)
    end

    it "keeps the session-grain metrics measured over whole sessions" do
      expect(metrics.sessions).to eq(2)
      expect(metrics.bounce_rate).to eq(0.0)
      # (180s + 240s) / 2 — first pageview to last event, per session.
      expect(metrics.avg_duration).to eq(210)
    end
  end

  describe Analytics::Timeseries do
    it "plots the matching events as the volume series" do
      points = described_class.call(site: site, period: period, filters: filters).value!

      expect(points.sum(&:pageviews)).to eq(3)
      expect(points.sum(&:visitors)).to eq(2)
    end
  end

  describe Analytics::Breakdown do
    def panel(dimension)
      Analytics::Breakdown.batch(
        site: site, period: period, dimensions: [dimension], filters: filters
      ).fetch(dimension)
    end

    it "shows where the event fired in the pages panel, with event counts as volume" do
      rows = panel("page").rows

      expect(rows.map(&:value)).to eq(["/pricing"])
      expect(rows.first.visitors).to eq(2)
      expect(rows.first.pageviews).to eq(3)
    end

    # The panel used to AND the filter onto is_entry, which no entry event can
    # satisfy unless the session's very first hit was the custom event — so it
    # sat empty below a summary full of converting visitors. It now answers the
    # question it is named for: where did the converting sessions begin.
    it "shows the entry pages of the sessions that fired the event" do
      expect(panel("entry_page").rows.map(&:value)).to contain_exactly("/home", "/blog")
    end

    it "keeps the custom events panel consistent with the summary" do
      rows = panel("event").rows

      expect(rows.map(&:value)).to eq(["Signup"])
      expect(rows.first.visitors).to eq(2)
      expect(rows.first.pageviews).to eq(3)
    end
  end

  describe Analytics::GoalReport do
    before do
      create(:goal, site: site, name: "Signup", kind: "event", match_type: "exact", match_value: "Signup")
      create(:goal, site: site, name: "Purchase", kind: "event", match_type: "exact", match_value: "Purchase")
      create(:goal, site: site, name: "Viewed pricing", kind: "pageview", match_type: "exact", match_value: "/pricing")
    end

    # A goal the filtered event cannot satisfy is a contradiction, not a zero:
    # its SQL ANDs `event_name = 'Signup'` with its own matcher, so "0
    # conversions, 0.0%" reads as "this goal stopped converting" while
    # measuring nothing. Only the goals the event can satisfy remain.
    it "drops goals the filtered event cannot satisfy" do
      rows = described_class.call(site: site, period: period, filters: filters).value!

      expect(rows.map { |row| row.goal.name }).to eq(["Signup"])
    end

    it "still reports every goal when no event filter is applied" do
      rows = described_class.call(site: site, period: period).value!

      expect(rows.map { |row| row.goal.name })
        .to contain_exactly("Signup", "Purchase", "Viewed pricing")
    end

    it "measures the surviving goal against the filtered audience" do
      row = described_class.call(site: site, period: period, filters: filters).value!.first

      expect(row.conversions).to eq(3)
      expect(row.visitors).to eq(2)
      expect(row.conversion_rate).to eq(100.0)
    end
  end

  # The other half of the contract, pinned so the relabelling cannot drift: an
  # ordinary dimension filter still counts pageviews as pageviews.
  describe "under a page filter, for contrast" do
    it "counts matching pageviews, not events" do
      metrics = Analytics::Summary.call(
        site: site, period: period, filters: Analytics::Filters.new(page: "/pricing")
      ).value!

      expect(metrics.pageviews).to eq(2)
    end
  end
end
