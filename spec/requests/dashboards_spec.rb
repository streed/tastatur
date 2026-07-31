require "rails_helper"

RSpec.describe "Custom dashboards", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :receiving, :no_suppression, account: account, domain: "measured.example.com") }

  def sign_in_as(role)
    create(:membership, account: account, user: user, role: role)
    sign_in user
  end

  before do
    delete_all_events
    create_events(site, count: 30, path: "/a", visitor_prefix: "v", at: 2.days.ago)
  end

  describe "CRUD" do
    before { sign_in_as("owner") }

    # A dashboard is created from a name alone and opens with one working tile.
    # It cannot be created empty — Dashboard::MIN_WIDGETS — so "name only" and
    # "starts with a widget" are one requirement, not two.
    it "creates a dashboard from a name and opens it on its first widget" do
      post site_dashboards_path(site), params: { dashboard: { name: "Marketing" } }

      dashboard = site.dashboards.find_by!(name: "Marketing")
      widget = dashboard.dashboard_widgets.sole

      expect(widget).to have_attributes(kind: "stat", metric: "visitors", position: 1)
      expect(response).to redirect_to(
        site_dashboard_path(site, dashboard, configure: widget.public_id)
      )
    end

    it "re-renders an invalid submission with the error summary" do
      post site_dashboards_path(site), params: { dashboard: { name: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This could not be saved")
      expect(site.dashboards.count).to be_zero
    end

    it "renames a dashboard from the dashboard itself" do
      dashboard = create(:dashboard, site: site, name: "Old")

      patch site_dashboard_path(site, dashboard), params: { dashboard: { name: "New" } }

      expect(response).to redirect_to(site_dashboard_path(site, dashboard))
      expect(dashboard.reload.name).to eq("New")
    end

    # The rename is in the dashboard's own header, so a rejected one has to come
    # back as the dashboard rather than as a form on its own page.
    it "re-renders the dashboard when a rename is rejected" do
      create(:dashboard, site: site, name: "Taken")
      dashboard = create(:dashboard, site: site, name: "Mine")

      patch site_dashboard_path(site, dashboard), params: { dashboard: { name: "Taken" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("has already been taken")
      expect(dashboard.reload.name).to eq("Mine")
    end

    it "ignores a widget attribute smuggled into the rename" do
      dashboard = create(:dashboard, site: site)
      widget = dashboard.dashboard_widgets.sole

      patch site_dashboard_path(site, dashboard), params: {
        dashboard: { name: dashboard.name,
                     dashboard_widgets_attributes: { "0" => { id: widget.id, kind: "timeseries" } } }
      }

      expect(widget.reload.kind).to eq("stat")
    end

    it "deletes a dashboard" do
      dashboard = create(:dashboard, site: site)

      delete site_dashboard_path(site, dashboard)

      expect(response).to redirect_to(site_dashboards_path(site))
      expect(Dashboard.exists?(dashboard.id)).to be(false)
    end
  end

  describe "GET show" do
    before { sign_in_as("owner") }

    it "renders every widget kind" do
      funnel = create(:funnel, site: site)
      create(:goal, site: site, name: "Priced", match_value: "/a")
      dashboard = create(:dashboard, site: site, name: "Everything", widgets: [
                           { kind: "stat", metric: "visitors" },
                           { kind: "timeseries" },
                           { kind: "breakdown", dimension: "page" },
                           { kind: "goals" },
                           { kind: "funnel", funnel: funnel }
                         ])

      get site_dashboard_path(site, dashboard)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Everything")
      expect(response.body).to include("Unique visitors")
      expect(response.body).to include("Traffic")
      expect(response.body).to include("Top pages")
      expect(response.body).to include("Goal conversions")
      expect(response.body).to include(funnel.name)
    end

    # A widget's filters are its author's, and the viewer supplies only the
    # period — the same rule the public copy lives by, enforced in the same
    # place (Dashboards::Render takes no filter input at all).
    it "ignores viewer filter parameters" do
      dashboard = create(:dashboard, site: site,
                         widgets: [{ kind: "breakdown", dimension: "page" }])

      get site_dashboard_path(site, dashboard, country: "US", page: "/nothing")

      expect(response.body).to include("/a")
    end

    it "states a widget's saved filters on its face" do
      dashboard = create(:dashboard, site: site,
                         widgets: [{ kind: "breakdown", dimension: "page",
                                     filters: { "source" => "Google" } }])

      get site_dashboard_path(site, dashboard)

      expect(response.body).to include("Source is Google")
    end

    it "answers a frame request with the widgets partial alone" do
      dashboard = create(:dashboard, site: site)

      get site_dashboard_path(site, dashboard), headers: { "Turbo-Frame" => "dashboard" }

      expect(response.body).to match(/<turbo-frame[^>]*id="dashboard"/)
      expect(response.body).not_to include("<html")
    end

    it "explains a widget whose funnel was deleted instead of failing the page" do
      funnel = create(:funnel, site: site)
      dashboard = create(:dashboard, site: site,
                         widgets: [{ kind: "funnel", funnel: funnel }])
      funnel.destroy!

      get site_dashboard_path(site, dashboard)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("has been deleted")
      expect(response.body).to include(
        edit_site_dashboard_widget_path(site, dashboard, dashboard.dashboard_widgets.sole)
      )
    end
  end

  describe "tenancy" do
    before { sign_in_as("owner") }

    it "404s another account's site token" do
      foreign_site = create(:site)
      dashboard = create(:dashboard, site: foreign_site)

      get site_dashboard_path(foreign_site, dashboard)

      expect(response).to have_http_status(:not_found)
    end

    it "404s another site's dashboard under this site's token" do
      foreign = create(:dashboard)

      get site_dashboard_path(site, foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "roles" do
    it "lets a viewer read but not write" do
      sign_in_as("viewer")
      dashboard = create(:dashboard, site: site)

      get site_dashboards_path(site)
      expect(response).to have_http_status(:ok)

      get site_dashboard_path(site, dashboard)
      expect(response).to have_http_status(:ok)

      post site_dashboards_path(site), params: { dashboard: { name: "Nope" } }
      expect(response).to have_http_status(:redirect)
      expect(site.dashboards.where(name: "Nope")).to be_empty
    end

    # The widget endpoints authorize the DASHBOARD rather than the widget, so
    # the check has to be shown to actually happen there.
    it "refuses a viewer every widget action" do
      sign_in_as("viewer")
      dashboard = create(:dashboard, site: site)
      widget = dashboard.dashboard_widgets.sole

      post site_dashboard_widgets_path(site, dashboard)
      expect(response).to have_http_status(:redirect)

      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "timeseries" } }
      expect(response).to have_http_status(:redirect)

      delete site_dashboard_widget_path(site, dashboard, widget)
      expect(response).to have_http_status(:redirect)

      expect(dashboard.reload.dashboard_widgets.map(&:kind)).to eq(["stat"])
    end
  end
end
