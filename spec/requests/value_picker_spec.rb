require "rails_helper"

# Goals and funnel steps are strings compared against a column, and a typed one
# that is subtly wrong — `/Pricing`, a trailing slash, `signup` for `Signup` —
# saves cleanly and then reports 0% forever. The forms therefore offer what the
# site has really recorded.
#
# These drive the forms over HTTP because the payload's presence, its escaping,
# and the fact that eight funnel rows share ONE copy of it are all properties of
# the rendered page rather than of the service.
RSpec.describe "Picking a goal or funnel step value", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :no_suppression, account: account) }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  # The one <script type="application/json"> the pickers read, as parsed JSON.
  def payload
    tag = response.body[%r{<script type="application/json" id="known-values">(.*?)</script>}m, 1]
    tag ? JSON.parse(tag) : nil
  end

  describe "the goal form" do
    before do
      create_event(site, path: "/pricing", visitor: "v1", at: 1.hour.ago)
      create_event(site, event_name: "Signup", path: "/pricing", visitor: "v1", at: 1.hour.ago)
      get "/sites/#{site.to_param}/goals/new"
    end

    it "offers the paths and the custom events, kept apart" do
      expect(payload["pageview"].map { |o| o["v"] }).to eq(["/pricing"])
      expect(payload["event"].map { |o| o["v"] }).to eq(["Signup"])
    end

    it "renders the match value as a combobox rather than a bare text field" do
      expect(response.body).to include('role="combobox"')
      expect(response.body).to include('role="listbox"')
    end

    # The field is a text input, not a select, and that is deliberate: a goal for
    # a page that has not shipped yet is the ordinary case.
    it "still accepts a value that has never been recorded" do
      post "/sites/#{site.to_param}/goals",
           params: { goal: { name: "Not launched yet", kind: "pageview",
                             match_value: "/thanks", match_type: "exact" } }

      expect(response).to redirect_to("/sites/#{site.to_param}/goals")
      expect(site.goals.last.match_value).to eq("/thanks")
    end
  end

  describe "the funnel form" do
    before do
      create_event(site, path: "/pricing", visitor: "v1", at: 1.hour.ago)
      get "/sites/#{site.to_param}/funnels/new"
    end

    it "offers the same values to every step" do
      expect(payload["pageview"].map { |o| o["v"] }).to eq(["/pricing"])
    end

    # A funnel holds up to eight step rows plus the <template> the Add button
    # clones. Rendering the options into each of them would put the same
    # payload — hundreds of paths on a real site — on the page nine times.
    it "renders exactly one copy of the payload however many rows there are" do
      expect(response.body.scan('id="known-values"').size).to eq(1)
      expect(response.body.scan('role="combobox"').size).to be > 1
    end
  end

  # A widget's filters are configured on the dashboard itself, in a panel that
  # replaces the widget. The payload belongs to the DASHBOARD and the panels
  # read it by id — twelve widgets opening in turn must not each ship their own
  # copy of the same couple of hundred paths.
  describe "the widget configuration panel" do
    let(:dashboard) { create(:dashboard, site: site) }

    before do
      create_event(site, path: "/pricing", visitor: "v1", at: 1.hour.ago)
      get site_dashboard_path(site, dashboard, configure: dashboard.dashboard_widgets.sole.public_id)
    end

    it "renders one payload and dimension options tagged with their value group" do
      expect(response.body.scan('id="known-values"').size).to eq(1)
      # The filter dimension select is not a kind select: its options carry the
      # group the picker should read values from.
      expect(response.body).to include('data-group="pageview"')
      expect(response.body).to include('data-group="event"')
      expect(response.body).to include('data-group="other"')
    end

    it "renders the filter value as a combobox" do
      expect(response.body).to include('role="combobox"')
    end

    # The panel arrives through a turbo frame, which is extracted from the
    # response and dropped into a page that already has the payload. A second
    # copy under the same id is what the split into two partials prevents.
    it "does not carry a second payload when fetched into the widget's frame" do
      widget = dashboard.dashboard_widgets.sole

      get edit_site_dashboard_widget_path(site, dashboard, widget),
          headers: { "Turbo-Frame" => "widget-#{widget.public_id}" }

      expect(response.body).to include('role="combobox"')
      expect(response.body.scan('id="known-values"').size).to eq(0)
    end

    # ...and a direct visit has no dashboard around it, so it must.
    it "carries the payload when the panel is the whole page" do
      widget = dashboard.dashboard_widgets.sole

      get edit_site_dashboard_widget_path(site, dashboard, widget)

      expect(response.body.scan('id="known-values"').size).to eq(1)
    end
  end

  # The picker is a breakdown: values with distinct-visitor counts, from the same
  # scan the Top pages panel uses. /privacy promises rows under the threshold are
  # withheld and does not qualify that by where they are rendered, so a form is
  # not a way around it.
  describe "k-anonymity" do
    let(:site) { create(:site, account: account, k_anonymity_threshold: 5) }

    before do
      create_events(site, count: 8, path: "/popular", visitor_prefix: "pop", at: 1.hour.ago)
      create_event(site, path: "/rare", visitor: "one-person", at: 1.hour.ago)
      get "/sites/#{site.to_param}/goals/new"
    end

    it "does not offer a value seen by fewer visitors than the threshold" do
      expect(payload["pageview"].map { |o| o["v"] }).not_to include("/rare")
      expect(response.body).not_to include("/rare")
    end

    it "says something was withheld instead of looking like there is no data" do
      expect(response.body).to include("privacy threshold")
    end
  end

  describe "a site with nothing recorded yet" do
    before { get "/sites/#{site.to_param}/goals/new" }

    it "renders an empty payload rather than failing" do
      expect(payload).to eq("pageview" => [], "event" => [])
    end

    it "explains the absence rather than showing a control that opens onto nothing" do
      expect(response.body).to include("Nothing recorded in the last 30 days")
    end
  end

  # These strings are paths from somebody else's website, and they are going
  # inside a <script> element.
  describe "a path that tries to close the script element" do
    before do
      create_event(site, path: "/</script><script>alert(1)</script>", visitor: "v1", at: 1.hour.ago)
      get "/sites/#{site.to_param}/goals/new"
    end

    it "cannot break out of it" do
      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(payload["pageview"].map { |o| o["v"] }).to eq(["/</script><script>alert(1)</script>"])
    end
  end

  # Analytics::KnownValues scans thirty days of raw events. A successful save
  # redirects and never renders a form, which is why OffersKnownValues is a
  # helper method and not a before_action.
  describe "the cost of the scan" do
    it "is not paid on a save that redirects" do
      expect(Analytics::KnownValues).not_to receive(:call)

      post "/sites/#{site.to_param}/goals",
           params: { goal: { name: "Pricing", kind: "pageview",
                             match_value: "/pricing", match_type: "exact" } }

      expect(response).to have_http_status(:redirect)
    end

    it "is paid when a rejected save re-renders the form" do
      post "/sites/#{site.to_param}/goals",
           params: { goal: { name: "", kind: "pageview",
                             match_value: "/pricing", match_type: "exact" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(payload).not_to be_nil
    end
  end
end
