require "rails_helper"

# Custom events had nowhere to appear.
#
# `tastatur('event', 'Signup')` was accepted by the endpoint, written to the
# hypertable and indexed — there is a partial index on
# (site_id, event_name, occurred_at) WHERE event_name <> 'pageview' built for
# exactly this query — and then rendered on no screen. The only way to see one was
# to first create a Goal whose name happened to match it. So anyone following the
# "Track a custom event" instructions on the install page saw nothing appear and
# had no way to tell a broken snippet from a working one.
RSpec.describe "The custom events panel" do
  let(:site) { create(:site, k_anonymity_threshold: 0) }
  let(:period) { Analytics::Period.new("30d", site: site) }

  def report = Analytics::Dashboard.call(site: site, period: period).value!
  def panel = report.breakdowns.find { |p| p[:dimension] == "event" }

  context "when the site sends custom events" do
    before do
      3.times { |i| create_event(site, visitor: "v#{i}", event_name: "Signup", at: 1.day.ago) }
      2.times { |i| create_event(site, visitor: "v#{i}", event_name: "Purchase", at: 1.day.ago) }
      5.times { |i| create_event(site, visitor: "v#{i}", at: 1.day.ago) }
    end

    it "appears on the dashboard" do
      expect(panel).to be_present
      expect(panel[:title]).to eq("Custom events")
    end

    it "shows each event name" do
      expect(panel[:result].rows.map(&:value)).to contain_exactly("Signup", "Purchase")
    end

    it "does not show pageviews, which would swamp every real row" do
      expect(panel[:result].rows.map(&:value)).not_to include("pageview")
    end
  end

  # A ninth card reading "No data." on every site that has never sent a custom
  # event is clutter that never resolves. The other eight are always shown because
  # for those an empty panel is itself an answer.
  context "when the site has only pageviews" do
    before { 5.times { |i| create_event(site, visitor: "v#{i}", at: 1.day.ago) } }

    it "is not shown at all" do
      expect(panel).to be_nil
    end

    it "does not disturb the panels that are always shown" do
      expect(report.breakdowns.map { |p| p[:dimension] })
        .to eq(%w[page entry_page source country device browser os utm_campaign])
    end
  end

  # A site whose custom events are all below the threshold HAS custom events.
  # Hiding the panel would make that indistinguishable from not collecting them,
  # which is the same failure the panel exists to fix.
  context "when every custom event is below the k-anonymity threshold" do
    let(:site) { create(:site, k_anonymity_threshold: 25) }

    before do
      3.times { |i| create_event(site, visitor: "v#{i}", event_name: "Signup", at: 1.day.ago) }
    end

    it "is still shown" do
      expect(panel).to be_present
    end

    it "withholds the rows but says that it did" do
      expect(panel[:result].rows).to be_empty
      expect(panel[:result]).to be_suppressed
    end
  end

  # Clicking a custom event filters the dashboard to the visitors who did it.
  # `event` was already an allowed filter dimension long before it was a panel.
  it "is drillable through the existing filter machinery" do
    3.times { |i| create_event(site, visitor: "v#{i}", event_name: "Signup", path: "/pricing", at: 1.day.ago) }
    2.times { |i| create_event(site, visitor: "other#{i}", path: "/blog", at: 1.day.ago) }

    filtered = Analytics::Dashboard.call(
      site: site, period: period, filters: Analytics::Filters.new("event" => "Signup")
    ).value!

    expect(filtered.summary.visitors).to eq(3)
  end
end
