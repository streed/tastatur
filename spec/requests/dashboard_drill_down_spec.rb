require "rails_helper"

# Clicking a breakdown row navigates the "dashboard" turbo-frame it sits inside.
#
# Turbo swaps in the frame it finds *in the response*, so a frame request whose
# body has no <turbo-frame id="dashboard"> renders "Content Missing" — with a 200
# status, nothing in the log, and nothing raised. sites#show answered frame
# requests with the bare partial while the frame tag lived in show.html.erb around
# the render, so every drill-down did exactly that. A full page load looked
# perfect, which is the only reason it lasted.
RSpec.describe "Dashboard drill-down", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user) }
  let!(:membership) { create(:membership, account: account, user: user, role: "owner") }
  let(:site) { create(:site, account: account, k_anonymity_threshold: 0) }

  before do
    sign_in user
    3.times { |i| create_event(site, path: "/pricing", visitor: "v#{i}", at: 1.hour.ago) }
  end

  # The header a browser sends when a link inside <turbo-frame id="dashboard"> is
  # followed. Without it the request is an ordinary page load and the bug hides.
  def get_in_frame(path)
    get path, headers: { "Turbo-Frame" => "dashboard" }
  end

  describe "the frame response" do
    before { get_in_frame site_path(site, page: "/pricing") }

    it "carries a frame for Turbo to swap in" do
      expect(response.body).to include(%(id="dashboard"))
    end

    it "renders the filtered dashboard rather than Content Missing" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Unique visitors")
    end

    # Turbo does not touch the URL on a frame navigation unless told to. The whole
    # filter design puts state in the query string so a filtered view is
    # shareable and survives the back button, and that is worth nothing if the
    # address bar never changes.
    it "advances the URL so the filtered view stays shareable" do
      expect(response.body).to include(%(data-turbo-action="advance"))
    end

    # The chips are the only way to see that a filter is applied, and the only way
    # to take it off. Rendered outside the frame they never arrive.
    it "shows the filter that was just applied, with a way to remove it" do
      expect(response.body).to include("Filtered by")
      expect(response.body).to include(site_path(site))
    end
  end

  it "renders the same frame on an ordinary page load" do
    get site_path(site)
    expect(response.body).to include(%(id="dashboard"))
  end

  # The public shared dashboard renders the same partial with drillable: false. It
  # must not grow filter chips: filtering someone else's audience is a
  # re-identification tool, which is why its rows are not links in the first place.
  it "does not put filter controls on a public shared dashboard" do
    shared_link = create(:shared_link, site: site)
    sign_out user

    get shared_dashboard_path(shared_link.slug, page: "/pricing")

    expect(response.body).not_to include("Filtered by")
    expect(response.body).not_to include("Clear all")
  end
end
