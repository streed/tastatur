require "rails_helper"

# The custom event property panels, end to end.
#
# The route into them is the Custom events panel: click "Signup", the dashboard
# scopes to that event, and its properties appear beneath the breakdowns. These
# specs pin where they appear, where they must NOT appear, and the one thing
# about them that is a privacy decision rather than a layout one.
RSpec.describe "Custom event properties", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user) }
  let!(:membership) { create(:membership, account: account, user: user, role: "owner") }
  let(:site) { create(:site, account: account, timezone: "Etc/UTC", k_anonymity_threshold: 0) }

  before do
    sign_in user

    create_event(site, visitor: "a", event_name: "Signup", props: { "plan" => "pro" }, at: 1.hour.ago)
    create_event(site, visitor: "b", event_name: "Signup", props: { "plan" => "free" }, at: 1.hour.ago)
    create_event(site, visitor: "c", path: "/pricing", at: 1.hour.ago)
  end

  describe "on the unfiltered dashboard" do
    before { get site_path(site) }

    # A property detached from its event is not a fact about anything: plan=pro
    # on Signup and plan=pro on Cancelled would pool into one row. It is also
    # the scan the ordinary dashboard has no reason to pay for.
    it "shows no property panels" do
      expect(response.body).not_to include("Properties")
    end

    # ...but the way in is on screen, which is the whole fix. The custom events
    # panel was already here; it just led nowhere.
    it "offers the custom events panel to drill into" do
      expect(response.body).to include("Custom events")
      expect(response.body).to include("Signup")
    end
  end

  describe "scoped to one custom event" do
    before { get site_path(site, event: "Signup") }

    it "renders a panel per property key, naming the event they came from" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Properties")
      expect(response.body).to include("sent with Signup")
    end

    it "shows the values that were sent" do
      expect(response.body).to include("pro")
      expect(response.body).to include("free")
    end

    # Drilling further has to produce a URL that survives a reload, which means
    # the nested shape `params.permit(props: {})` can read back — `props[plan]`,
    # not a flat key of our own invention that permit could never name.
    it "links each value to a dashboard filtered by it" do
      expect(response.body).to include("props%5Bplan%5D=pro")
      expect(response.body).to include("event=Signup")
    end
  end

  describe "filtered down to one property value" do
    before { get site_path(site, event: "Signup", props: { plan: "pro" }) }

    it "applies the filter" do
      expect(response).to have_http_status(:ok)
    end

    # The chip is the only way to see a filter is on, and the only way off.
    it "shows a removable chip labelled with the property name" do
      expect(response.body).to include("Filtered by")
      expect(response.body).to include("plan")
      expect(response.body).to include(CGI.escapeHTML(site_path(site, event: "Signup")))
    end

    it "keeps the panels on screen so the chip does not point at nothing" do
      expect(response.body).to include("Properties")
    end
  end

  # THE PRIVACY DECISION. This application measures itself with its own tracker,
  # and a property key is the customer's schema — `plan`, but equally `user_id`
  # or `email_domain`. Recording which property someone filtered by would put
  # that schema in our database, which is the thing §13 exists to prevent and
  # the same rule that already keeps `row.value` out of these attributes.
  describe "what our own analytics is told" do
    before { get site_path(site, event: "Signup", props: { plan: "pro" }) }

    it "records that a property was used, not which one" do
      # Rails renders a Hash data attribute as HTML-escaped JSON in double
      # quotes, so the payload is matched in the form it actually ships in.
      analytics_attributes = response.body.scan(/data-analytics-props="([^"]*)"/).flatten

      expect(analytics_attributes)
        .to include(a_string_including("&quot;dimension&quot;:&quot;property&quot;"))
      expect(analytics_attributes.join(" ")).not_to include("plan")
    end
  end

  # Public shared dashboards are rendered with no filters at all, deliberately —
  # filtering someone else's audience is a re-identification tool. Property
  # values are the finest-grained thing a customer can send us, so a panel of
  # them on an unauthenticated page would be the worst version of that.
  describe "on a public shared dashboard" do
    let(:link) { create(:shared_link, site: site) }

    before { get shared_dashboard_path(link.slug) }

    it "shows no property panels" do
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Properties")
    end
  end
end
