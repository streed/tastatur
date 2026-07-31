require "rails_helper"

# A widget is added, configured and removed on the dashboard itself. There is no
# editor page; `edit` renders a configuration panel into the widget's own turbo
# frame, and saving renders the widget back into the same frame with fresh
# numbers under the configuration that was just saved.
RSpec.describe "Dashboard widgets", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :receiving, :no_suppression, account: account, domain: "measured.example.com") }
  let(:dashboard) { create(:dashboard, site: site, name: "Marketing") }

  before do
    delete_all_events
    create_events(site, count: 30, path: "/a", visitor_prefix: "v", at: 2.days.ago)
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  describe "adding" do
    it "appends a stat tile and opens its configuration panel" do
      expect { post site_dashboard_widgets_path(site, dashboard) }
        .to change { dashboard.dashboard_widgets.count }.by(1)

      added = dashboard.dashboard_widgets.order(:position).last
      expect(added).to have_attributes(kind: "stat", metric: "visitors", position: 2)
      expect(response).to redirect_to(
        site_dashboard_path(site, dashboard, configure: added.public_id, period: nil)
      )
    end

    it "refuses past the per-dashboard cap and says so" do
      create_list(:dashboard_widget, Dashboard::MAX_WIDGETS - 1, dashboard: dashboard)

      expect { post site_dashboard_widgets_path(site, dashboard) }
        .not_to(change { dashboard.dashboard_widgets.count })

      expect(flash[:alert]).to include("already has #{Dashboard::MAX_WIDGETS} widgets")
    end

    it "opens the panel on the dashboard rather than on a page of its own" do
      post site_dashboard_widgets_path(site, dashboard)
      follow_redirect!

      added = dashboard.dashboard_widgets.order(:position).last
      expect(response.body).to match(/<turbo-frame[^>]*id="widget-#{added.public_id}"/)
      # The panel, in place of the tile: the form is inside the frame.
      expect(response.body).to include("Save widget")
    end
  end

  describe "configuring" do
    let(:widget) { dashboard.dashboard_widgets.sole }

    it "renders the panel into the widget's own frame" do
      get edit_site_dashboard_widget_path(site, dashboard, widget),
          headers: { "Turbo-Frame" => "widget-#{widget.public_id}" }

      expect(response.body).to match(/<turbo-frame[^>]*id="widget-#{widget.public_id}"/)
      # turbo-rails wraps a frame response in a bare html document of its own,
      # so the assertion that matters is that the application layout — nav,
      # footer, the dashboard around it — did not come along.
      expect(response.body).not_to include("<footer")
    end

    it "saves a new kind and answers with the widget, not a redirect" do
      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "breakdown", dimension: "page", row_limit: 10 } }

      expect(response).to have_http_status(:ok)
      expect(widget.reload).to have_attributes(kind: "breakdown", dimension: "page")
      # The widget back in its frame, with real numbers under the new config.
      expect(response.body).to match(/<turbo-frame[^>]*id="widget-#{widget.public_id}"/)
      expect(response.body).to include("Top pages")
      expect(response.body).to include("/a")
    end

    it "saves filters as a hash and clears them when the last pair is removed" do
      patch site_dashboard_widget_path(site, dashboard, widget), params: {
        dashboard_widget: { kind: "stat", metric: "visitors",
                            filter_pairs_attributes: { "0" => { dimension: "source", value: "Google" } } }
      }
      expect(widget.reload.filters).to eq("source" => "Google")

      # Removing the last filter row submits no pairs at all, and that has to
      # mean none. It did not used to: see the comment on widget_params.
      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "stat", metric: "visitors" } }

      expect(widget.reload.filters).to eq({})
    end

    it "drops a pair whose dimension is blank rather than storing it" do
      patch site_dashboard_widget_path(site, dashboard, widget), params: {
        dashboard_widget: { kind: "stat", metric: "visitors",
                            filter_pairs_attributes: {
                              "0" => { dimension: "", value: "" },
                              "1" => { dimension: "source", value: "Google" }
                            } }
      }

      expect(widget.reload.filters).to eq("source" => "Google")
    end

    it "takes a funnel by public id and refuses another site's" do
      mine = create(:funnel, site: site)
      foreign = create(:funnel)

      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "funnel", funnel_public_id: mine.public_id } }
      expect(widget.reload.funnel).to eq(mine)

      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "funnel", funnel_public_id: foreign.public_id } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(widget.reload.funnel).to eq(mine)
    end

    it "re-renders the panel with its errors when the save is rejected" do
      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "funnel", funnel_public_id: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("This could not be saved")
      expect(response.body).to match(/<turbo-frame[^>]*id="widget-#{widget.public_id}"/)
    end

    # Position is the dashboard's business and removal is its own action, so
    # neither may arrive through a widget's own form.
    it "ignores a posted position" do
      patch site_dashboard_widget_path(site, dashboard, widget),
            params: { dashboard_widget: { kind: "stat", metric: "visitors", position: 99 } }

      expect(widget.reload.position).to eq(1)
    end

    it "cancels back to the widget through its own frame" do
      get site_dashboard_widget_path(site, dashboard, widget),
          headers: { "Turbo-Frame" => "widget-#{widget.public_id}" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/<turbo-frame[^>]*id="widget-#{widget.public_id}"/)
      expect(response.body).not_to include("Save widget")
    end
  end

  describe "removing" do
    it "removes a widget and closes the gap in the positions" do
      second = create(:dashboard_widget, dashboard: dashboard, kind: "timeseries", position: 2)
      third = create(:dashboard_widget, dashboard: dashboard, kind: "goals", position: 3)

      delete site_dashboard_widget_path(site, dashboard, second)

      expect(response).to redirect_to(site_dashboard_path(site, dashboard))
      expect(DashboardWidget.exists?(second.id)).to be(false)
      expect(third.reload.position).to eq(2)
    end

    # Destroying a child never consults Dashboard#has_enough_widgets, so a
    # dashboard would happily empty itself and then refuse every later rename
    # with a message about widgets.
    it "refuses to remove the last one and says what to do instead" do
      widget = dashboard.dashboard_widgets.sole

      delete site_dashboard_widget_path(site, dashboard, widget)

      expect(DashboardWidget.exists?(widget.id)).to be(true)
      expect(flash[:alert]).to include("Delete the dashboard instead")
    end
  end

  describe "tenancy" do
    it "404s another site's dashboard under this site's token" do
      foreign = create(:dashboard)

      post site_dashboard_widgets_path(site, foreign)

      expect(response).to have_http_status(:not_found)
    end

    it "404s a widget belonging to another dashboard" do
      other = create(:dashboard, site: site, name: "Other")

      get edit_site_dashboard_widget_path(site, dashboard, other.dashboard_widgets.sole)

      expect(response).to have_http_status(:not_found)
    end
  end
end
