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

    it "creates a dashboard from nested widget rows, including saved filters" do
      post site_dashboards_path(site), params: {
        dashboard: {
          name: "Marketing",
          dashboard_widgets_attributes: {
            "0" => { position: 1, kind: "stat", metric: "visitors", title: "",
                     filter_pairs_attributes: {
                       "sentinel" => { dimension: "", value: "" },
                       "0" => { dimension: "source", value: "Google" }
                     } },
            "1" => { position: 2, kind: "breakdown", dimension: "page", row_limit: 10 }
          }
        }
      }

      dashboard = site.dashboards.find_by!(name: "Marketing")
      expect(response).to redirect_to(site_dashboard_path(site, dashboard))

      stat, breakdown = dashboard.dashboard_widgets.to_a
      expect(stat.filters).to eq("source" => "Google")
      expect(breakdown.dimension).to eq("page")
    end

    it "creates a funnel widget through the funnel's public id" do
      funnel = create(:funnel, site: site)

      post site_dashboards_path(site), params: {
        dashboard: { name: "Conversion",
                     dashboard_widgets_attributes: {
                       "0" => { position: 1, kind: "funnel", funnel_public_id: funnel.public_id }
                     } }
      }

      expect(site.dashboards.find_by!(name: "Conversion").dashboard_widgets.first.funnel).to eq(funnel)
    end

    it "refuses another site's funnel even by public id" do
      foreign = create(:funnel)

      post site_dashboards_path(site), params: {
        dashboard: { name: "Sneaky",
                     dashboard_widgets_attributes: {
                       "0" => { position: 1, kind: "funnel", funnel_public_id: foreign.public_id }
                     } }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(site.dashboards.count).to be_zero
    end

    it "re-renders an invalid submission with the error summary and a usable form" do
      post site_dashboards_path(site), params: {
        dashboard: { name: "", dashboard_widgets_attributes: {
          "0" => { position: 1, kind: "stat", metric: "visitors" }
        } }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This could not be saved")
      expect(response.body).to include("dashboard_widgets_attributes")
    end

    it "updates widgets, removing and adding in one submission" do
      dashboard = create(:dashboard, site: site)
      existing = dashboard.dashboard_widgets.first

      patch site_dashboard_path(site, dashboard), params: {
        dashboard: {
          name: dashboard.name,
          dashboard_widgets_attributes: {
            "0" => { id: existing.id, _destroy: "1", position: 1, kind: existing.kind,
                     metric: existing.metric },
            "1" => { position: 2, kind: "timeseries" }
          }
        }
      }

      expect(response).to redirect_to(site_dashboard_path(site, dashboard))
      expect(dashboard.reload.dashboard_widgets.map(&:kind)).to eq(["timeseries"])
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
      expect(response.body).to include(edit_site_dashboard_path(site, dashboard))
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

      post site_dashboards_path(site), params: {
        dashboard: { name: "Nope", dashboard_widgets_attributes: {
          "0" => { position: 1, kind: "stat", metric: "visitors" }
        } }
      }
      expect(response).to have_http_status(:redirect)
      expect(site.dashboards.where(name: "Nope")).to be_empty
    end
  end
end
