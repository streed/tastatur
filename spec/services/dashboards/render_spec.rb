require "rails_helper"

# The render service is where widget configuration meets the analytics
# services, so these examples cover both directions: that each kind produces
# the data its partial consumes, and that a widget whose configuration has
# gone stale states so instead of taking the page down.
#
# The site sits in a half-hour-offset timezone so Analytics::Scope reads the
# raw hypertable for every widget — no continuous-aggregate materialisation to
# reason about, and no :continuous_aggregate tag needed.
RSpec.describe Dashboards::Render do
  let(:site) { create(:site, :no_suppression, timezone: "Asia/Kolkata") }
  let(:period) { Analytics::Period.new("30d", site: site) }

  def render(dashboard)
    described_class.call(dashboard: dashboard, period: period).value!
  end

  before do
    delete_all_events
    # Three pages with distinct volumes, one referred visit, one custom event,
    # and one visitor walking the funnel below.
    4.times { |i| create_event(site, path: "/a", visitor: "a#{i}", at: 2.days.ago) }
    3.times { |i| create_event(site, path: "/b", visitor: "b#{i}", at: 2.days.ago) }
    create_event(site, path: "/c", visitor: "c0", at: 2.days.ago, referrer_source: "Hacker News")
    create_event(site, event_name: "Signup", path: "/b", visitor: "b0", at: 2.days.ago)
    create_event(site, path: "/", visitor: "walker", at: 3.days.ago)
    create_event(site, path: "/pricing", visitor: "walker", at: 3.days.ago + 10.minutes)
  end

  describe "one widget of every kind" do
    let(:funnel) { create(:funnel, site: site) }
    let(:dashboard) do
      create(:dashboard, site: site, widgets: [
               { kind: "stat", metric: "visitors" },
               { kind: "timeseries" },
               { kind: "breakdown", dimension: "page", row_limit: 2 },
               { kind: "goals" },
               { kind: "funnel", funnel: funnel }
             ])
    end

    before { create(:goal, site: site, name: "Priced", match_value: "/pricing") }

    it "returns each widget's data in the shape its partial consumes" do
      report = render(dashboard)

      expect(report.widgets).to all(be_ok)
      stat, timeseries, breakdown, goals, funnel_result = report.widgets

      expect(stat.data).to be_a(Analytics::Summary::Metrics)
      # a0-a3, b0-b2, c0, walker — b0's Signup event is the same visitor twice.
      expect(stat.data.visitors).to eq(9)
      expect(stat.data.previous).not_to be_nil, "stat tiles need the previous period for their delta"

      expect(timeseries.data).to all(be_a(Analytics::Timeseries::Point))

      expect(breakdown.data).to be_a(Analytics::Breakdown::Result)
      expect(goals.data).to all(be_a(Analytics::GoalReport::Row))

      expect(funnel_result.data).to be_a(Analytics::FunnelReport::Report)
      expect(funnel_result.data.entered).to eq(1)
      expect(funnel_result.data.completed).to eq(1)

      expect(report.realtime).to eq(0)
    end

    it "matches what the breakdown service reports on its own, truncated to the widget's rows" do
      direct = Analytics::Breakdown.call(site: site, period: period,
                                         dimension: "page", limit: 2).value!
      rendered = render(dashboard).widgets[2].data

      expect(rendered.rows.map { |r| [r.value, r.visitors, r.percentage] })
        .to eq(direct.rows.map { |r| [r.value, r.visitors, r.percentage] })
      expect(rendered.rows.length).to eq(2)
    end
  end

  describe "query economy" do
    it "issues one Summary per distinct filter set, not per stat tile" do
      dashboard = create(:dashboard, site: site, widgets: [
                           { kind: "stat", metric: "visitors" },
                           { kind: "stat", metric: "pageviews" },
                           { kind: "stat", metric: "bounce_rate",
                             filters: { "page" => "/a" } }
                         ])

      expect(Analytics::Summary).to receive(:call).twice.and_call_original

      render(dashboard)
    end

    it "issues one batch per distinct filter set for breakdown widgets" do
      dashboard = create(:dashboard, site: site, widgets: [
                           { kind: "breakdown", dimension: "page", row_limit: 5 },
                           { kind: "breakdown", dimension: "source", row_limit: 10 }
                         ])

      expect(Analytics::Breakdown).to receive(:batch).once.and_call_original

      render(dashboard)
    end
  end

  describe "per-widget truncation under shared batching" do
    # Two widgets share one scan issued at the larger limit; each truncates its
    # own rows. The suppression counts must be identical either way, because
    # suppression partitions the FULL result set before any limit applies.
    let(:site) { create(:site, timezone: "Asia/Kolkata", k_anonymity_threshold: 3) }

    it "truncates rows per widget while suppression counts stay whole-result" do
      dashboard = create(:dashboard, site: site, widgets: [
                           { kind: "breakdown", dimension: "page", row_limit: 1 },
                           { kind: "breakdown", dimension: "page", row_limit: 10 }
                         ])

      short, long = render(dashboard).widgets.map(&:data)

      expect(short.rows.length).to eq(1)
      expect(long.rows.map(&:value)).to contain_exactly("/a", "/b")
      expect(short.suppressed_rows).to eq(long.suppressed_rows)
      expect(short.suppressed_visitors).to eq(long.suppressed_visitors)
    end
  end

  describe "saved filters" do
    it "applies each widget's own filters" do
      dashboard = create(:dashboard, site: site, widgets: [
                           { kind: "breakdown", dimension: "page" },
                           { kind: "breakdown", dimension: "page",
                             filters: { "source" => "Hacker News" } }
                         ])

      unfiltered, filtered = render(dashboard).widgets.map(&:data)

      expect(unfiltered.rows.map(&:value)).to include("/a", "/b", "/c")
      expect(filtered.rows.map(&:value)).to eq(["/c"])
    end

    it "applies them to funnel widgets too" do
      funnel = create(:funnel, site: site)
      dashboard = create(:dashboard, site: site, widgets: [
                           { kind: "funnel", funnel: funnel,
                             filters: { "country" => "US" } }
                         ])

      # Every event in this file is from DE, so a US-scoped funnel sees nobody.
      expect(render(dashboard).widgets.first.data.entered).to eq(0)
    end
  end

  describe "widgets that can no longer answer" do
    it "marks a widget whose funnel was deleted, without failing the page" do
      funnel = create(:funnel, site: site)
      dashboard = create(:dashboard, site: site, widgets: [
                           { kind: "stat", metric: "visitors" },
                           { kind: "funnel", funnel: funnel }
                         ])

      funnel.destroy!
      report = render(dashboard)

      expect(report.widgets.first).to be_ok
      expect(report.widgets.last.status).to eq(:missing_funnel)
      expect(report.widgets.last.data).to be_nil
    end

    it "marks a breakdown whose stored dimension is no longer known" do
      dashboard = create(:dashboard, site: site,
                         widgets: [{ kind: "breakdown", dimension: "page" }])
      dashboard.dashboard_widgets.first.update_column(:dimension, "retired_dimension")

      expect(render(dashboard).widgets.first.status).to eq(:invalid)
    end
  end
end
