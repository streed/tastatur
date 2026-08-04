require "rails_helper"

# The All funnels page lists funnels next to how well they convert. The service
# spec covers the numbers; these examples cover the thing only the delivered
# page can be wrong about — that the rate reaches it, that the period control
# changes it, and that a funnel with no report to show still appears.
RSpec.describe "Funnels index", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :no_suppression, account: account) }

  let!(:funnel) do
    create(:funnel, site: site, name: "Signup flow", window_seconds: 3600, steps: [
             { name: "Landed", match_value: "/" },
             { name: "Priced", match_value: "/pricing" }
           ])
  end

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
    delete_all_events
  end

  it "shows each funnel's overall conversion rate" do
    create_event(site, visitor: "v1", path: "/",        at: 2.hours.ago)
    create_event(site, visitor: "v1", path: "/pricing", at: 2.hours.ago + 1.minute)
    create_event(site, visitor: "v2", path: "/",        at: 2.hours.ago)

    get site_funnels_path(site)

    expect(response.body).to include("50.0%")
    expect(response.body).to include("Signup flow")
  end

  it "counts over the requested period" do
    # Inside 30 days, outside 7.
    create_event(site, visitor: "v1", path: "/",        at: 20.days.ago)
    create_event(site, visitor: "v1", path: "/pricing", at: 20.days.ago + 1.minute)

    get site_funnels_path(site, period: "7d")
    expect(response.body).to include("Last 7 days")
    expect(response.body).to include("0.0%")

    get site_funnels_path(site, period: "30d")
    expect(response.body).to include("100.0%")
  end

  # A funnel written around the model has no rate to quote. It must still be on
  # the page, because opening it is how the reader finds out why.
  it "lists a funnel it cannot report on" do
    funnel.funnel_steps.first.conditions.delete_all

    get site_funnels_path(site)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Signup flow")
  end
end
