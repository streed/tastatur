require "rails_helper"

RSpec.describe "Journeys", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user) }
  let!(:membership) { create(:membership, account: account, user: user, role: "owner") }
  let(:site) { create(:site, :no_suppression, account: account) }

  def visit_pages(session, paths, base: 2.hours.ago, visitor: session)
    paths.each_with_index do |path, index|
      create_event(site, visitor: visitor, session: session, path: path,
                        is_entry: index.zero?, at: base + index.minutes)
    end
  end

  before do
    sign_in user
    delete_all_events
  end

  describe "the default view" do
    before do
      2.times { |i| visit_pages("s#{i}", ["/", "/pricing", "/checkout"]) }
      visit_pages("s9", ["/", "/docs"])
      get site_journeys_path(site)
    end

    it "opens on the busiest entry page" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("After /")
    end

    it "lists where visitors went next" do
      expect(response.body).to include("/pricing")
      expect(response.body).to include("/docs")
    end

    it "offers the entry pages as starting points" do
      expect(response.body).to include("Start from")
    end
  end

  describe "walking the tree" do
    before do
      2.times { |i| visit_pages("s#{i}", ["/", "/pricing", "/checkout"]) }
      visit_pages("s9", ["/", "/docs"])
    end

    # The walked path is the URL, which is what makes an expanded tree something
    # you can send to a colleague. A branch link that did not carry the whole
    # prefix would silently reset the tree to depth one.
    it "links a branch to the path extended by one hop" do
      get site_journeys_path(site)

      expect(response.body).to include(CGI.escapeHTML(
        site_journeys_path(site, path: ["/", "/pricing"], period: "30d")
      ))
    end

    it "renders every level of the walked path" do
      get site_journeys_path(site, path: ["/", "/pricing"])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("After /")
      expect(response.body).to include("After / → /pricing")
      expect(response.body).to include("/checkout")
    end

    it "does not offer a hop past the depth cap" do
      deep = ["/"] * Analytics::PageFlow::MAX_DEPTH
      get site_journeys_path(site, path: deep)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("as deep as the tree goes")
    end

    it "survives a hand-edited path deeper than the cap" do
      get site_journeys_path(site, path: ["/"] * 40)

      expect(response).to have_http_status(:ok)
    end

    it "ignores a path that matches nothing" do
      get site_journeys_path(site, path: ["/nowhere"])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No data.")
    end
  end

  describe "when every row is suppressed" do
    let(:site) { create(:site, account: account, k_anonymity_threshold: 25) }

    before do
      visit_pages("s1", ["/", "/pricing"])
      get site_journeys_path(site)
    end

    # The distinction sites/_breakdown draws and spec/requests/breakdown_suppression_spec.rb
    # pins, and it matters more here: a tree divides the crowd at every hop, so a
    # site comfortably over the threshold on Top pages still runs out of people
    # partway down. Saying "No data." would report that as an empty site.
    it "does not claim there is no data" do
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("No journeys yet.")
      expect(response.body).to include("not because nothing happened")
    end

    it "says how much was withheld and why" do
      expect(response.body).to include("withheld")
      expect(response.body).to include("fewer than 25 visitors")
      expect(response.body).to include(edit_site_path(site))
    end
  end

  describe "a site with no traffic" do
    it "explains what the report will show" do
      get site_journeys_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No journeys yet.")
    end
  end

  describe "authorization" do
    it "is reachable from the dashboard" do
      get site_path(site)

      expect(response.body).to include(site_journeys_path(site))
    end

    # SiteScoped resolves through policy_scope, so another account's token is a
    # 404 before any authorization question is asked — the tenant boundary, not a
    # permission check.
    it "refuses another account's site" do
      stranger = create(:site)

      get site_journeys_path(stranger)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses a signed-out visitor" do
      sign_out user
      get site_journeys_path(site)

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # The two panels that appear on the dashboard when it is scoped to one page —
  # the quick answer, with the tree a click away. See Analytics::Dashboard#flows.
  describe "the dashboard flow panels" do
    before do
      2.times { |i| visit_pages("s#{i}", ["/", "/pricing", "/checkout"]) }
      visit_pages("s9", ["/docs", "/pricing"])
    end

    it "are absent on the unfiltered dashboard" do
      get site_path(site)

      expect(response.body).not_to include("Page flow")
    end

    it "appear when the dashboard is filtered to a page" do
      get site_path(site, page: "/pricing")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Page flow")
      expect(response.body).to include("Came from")
      expect(response.body).to include("Went to")
    end

    it "name the page they describe" do
      get site_path(site, page: "/pricing")

      expect(response.body).to include("around /pricing")
    end

    it "link into the tree rooted at that page" do
      get site_path(site, page: "/pricing")

      expect(response.body).to include(CGI.escapeHTML(
        site_journeys_path(site, path: ["/pricing"], period: "30d")
      ))
    end

    # An entry page is by definition the first thing in the visit, so its "Came
    # from" panel could only ever read "Entered here" for everybody. The Journeys
    # screen answers that question properly; a pair of degenerate cards does not.
    it "are absent under an entry-page filter" do
      get site_path(site, entry_page: "/")

      expect(response.body).not_to include("Page flow")
    end
  end

  # A journey is a conjunction that narrows the crowd at every hop, which makes
  # it a sharper re-identification tool than any single filter. Public shared
  # dashboards drop filter parameters for that reason (CLAUDE.md §12), so this
  # report must not be reachable — or linked — from one.
  describe "public shared dashboards" do
    let(:site) { create(:site, :no_suppression, account: account) }
    let!(:link) { create(:shared_link, site: site) }

    before do
      2.times { |i| visit_pages("s#{i}", ["/", "/pricing"]) }
      sign_out user
    end

    it "does not link to the journey report" do
      get shared_dashboard_path(link.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("/journeys")
    end

    it "does not render flow panels even when a page parameter is supplied" do
      get shared_dashboard_path(link.slug, page: "/pricing")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Page flow")
    end
  end
end
