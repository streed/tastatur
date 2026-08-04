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

  # The click between two pages is usually the interesting part of the journey,
  # so it is a step. See Analytics::PageFlow.
  describe "custom events as steps" do
    # "/" at T, the Signup click at T+30s, "/welcome" at T+1m — so the event is
    # genuinely between the two pages rather than beside them.
    before do
      2.times do |i|
        visit_pages("s#{i}", ["/", "/welcome"])
        create_event(site, visitor: "s#{i}", session: "s#{i}", event_name: "Signup",
                          path: "/", at: 2.hours.ago + 30.seconds)
      end
    end

    it "shows an event as a branch, and says it is one" do
      get site_journeys_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Where visitors went after the Signup event")
    end

    # The kind travels in a parallel array, because a custom event may be named
    # after a page — see Analytics::FlowStep.
    it "links a branch to the path extended by one hop, carrying its kind" do
      get site_journeys_path(site)

      expect(response.body).to include(CGI.escapeHTML(
        site_journeys_path(site, path: ["/", "Signup"], kind: %w[pageview event], period: "30d")
      ))
    end

    it "walks past an event to the page after it" do
      get site_journeys_path(site, path: ["/", "Signup"], kind: %w[pageview event])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("After / → Signup")
      expect(response.body).to include("Where visitors went after /welcome")
    end

    it "opens a journey rooted at an event" do
      get site_journeys_path(site, path: ["Signup"], kind: %w[event])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/welcome")
    end

    # `?steps=pages` is the report as it was, for the site that fires one event
    # on every page and would otherwise have a step between every pair of them.
    describe "with events switched off" do
      it "leaves them out and joins the pages directly" do
        get site_journeys_path(site, steps: "pages")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Where visitors went after the Signup event")
        expect(response.body).to include("Where visitors went after /welcome")
      end

      # Truncated at the first event, not filtered — dropping the event from the
      # middle of the path would silently substitute a different journey.
      it "truncates a walked path at its first event" do
        get site_journeys_path(site, path: ["/", "Signup"], kind: %w[pageview event],
                                     steps: "pages")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("After / → Signup")
      end

      it "keeps every link on the screen in the same mode" do
        get site_journeys_path(site, steps: "pages")

        expect(response.body).to include(CGI.escapeHTML(
          site_journeys_path(site, path: ["/", "/welcome"], steps: "pages", period: "30d")
        ))
      end
    end
  end

  # The tree drawn as a directed graph (FlowMapHelper). Asserted on the DELIVERED
  # MARKUP rather than through a helper spec, because the thing that can silently
  # break is the correspondence between the numbers PageFlow measured and the
  # picture — a layout that renders happily while drawing the wrong edge weight
  # is a chart that lies, and nothing raises.
  describe "the flow map" do
    # 6 of 8 to /pricing, 2 of 8 to /docs: two branches whose shares are a 3:1
    # ratio, so the line weights can be compared as well as read.
    before do
      6.times { |i| visit_pages("a#{i}", ["/", "/pricing"]) }
      2.times { |i| visit_pages("b#{i}", ["/", "/docs"]) }
      get site_journeys_path(site)
    end

    # Percentage and stroke width are emitted as adjacent siblings, one edge at
    # a time, so this pairs each weight with the share it is supposed to draw.
    def edges
      response.body.scan(%r{stroke-width="([\d.]+)"[^>]*/><text[^>]*>(\d+)%</text>})
                   .map { |width, share| [share.to_i, width.to_f] }
    end

    it "draws a node per branch, carrying the visitors at it" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("flow-map")
      expect(response.body).to include(">/pricing</span><span class=\"flow-node-sub num\">6 visitors")
      expect(response.body).to include(">/docs</span><span class=\"flow-node-sub num\">2 visitors")
    end

    # THE WEIGHT IS THE PROBABILITY. Both halves matter: the number printed on
    # the edge is the branch's measured share of the visitors at that node, and
    # the width is a monotone function of it. A picture whose thicknesses did not
    # rank the same way as its numbers would be worse than no picture.
    it "weights each line by the share of visitors taking it" do
      expect(edges.map(&:first)).to contain_exactly(75, 25)
      expect(edges.max_by(&:first).last).to be > edges.min_by(&:first).last
    end

    # A 1% branch drawn to scale is invisible, and an edge nobody can see is a
    # route the reader concludes does not exist.
    it "keeps the smallest line visible" do
      expect(edges.map(&:last)).to all(be >= FlowMapHelper::STROKE_MIN)
    end

    it "links a node to the path extended by one hop" do
      expect(response.body).to include(CGI.escapeHTML(
        site_journeys_path(site, path: ["/", "/pricing"], period: "30d")
      ))
    end

    # The map is drawn from the same walked path the cards below it are, so the
    # step the reader is standing on has to be findable on it.
    it "marks the step the reader is on" do
      get site_journeys_path(site, path: ["/", "/pricing"])

      expect(response.body).to match(/data-current="true"[^>]*>\s*<span class="flow-node-label">\/pricing/)
    end

    # "Left the site" is usually the biggest edge on the picture. A tree that
    # dropped it would show a site nobody ever leaves.
    it "draws the branch that leaves the site" do
      get site_journeys_path(site, path: ["/", "/pricing"])

      expect(response.body).to match(/flow-node[^>]*>\s*<span class="flow-node-label">Left the site/)
    end

    # A hand-edited URL naming a step nobody took. The map must still show the
    # reader where they are, or it is the only thing on screen disagreeing with
    # the heading and the breadcrumb — see FlowMapHelper#flow_unmatched_node.
    it "still draws a walked step that no branch accounts for" do
      get site_journeys_path(site, path: ["/", "/nowhere"])

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/data-current="true"[^>]*>\s*<span class="flow-node-label">\/nowhere/)
      expect(response.body).to include("No data.")
    end

    # Nothing to draw at all: a start step with nothing after it. One box and no
    # lines is not a picture of anything, and there is nothing to step back
    # through either — which is what lets the text breadcrumb stay deleted.
    it "is absent when there is no tree" do
      get site_journeys_path(site, path: ["/nowhere"])

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("flow-map")
      expect(response.body).to include("No data.")
    end

    # The spine is the breadcrumb now, so every hop above the current one has to
    # remain one click away.
    it "steps back up the walked path from any hop on the spine" do
      get site_journeys_path(site, path: ["/", "/pricing"])

      expect(response.body).to include(CGI.escapeHTML(site_journeys_path(site, path: ["/"], period: "30d")))
    end
  end

  # A partially-suppressed node must not look like a complete one. The map draws
  # the withheld fan as its own node for the same reason sites/_flow_branches
  # spells it out underneath: "nobody went there" and "we are not saying where
  # they went" are different facts.
  describe "the flow map under suppression" do
    let(:site) { create(:site, account: account, k_anonymity_threshold: 5) }

    # TWO branches under the threshold, deliberately. With only one,
    # Analytics::Suppression withholds the smallest survivor as well — which
    # here is the only survivor — and the level collapses to a withheld node
    # with nothing beside it. That case is its own example below.
    before do
      8.times { |i| visit_pages("a#{i}", ["/", "/pricing"]) }
      2.times { |i| visit_pages("b#{i}", ["/", "/docs"]) }
      2.times { |i| visit_pages("c#{i}", ["/", "/blog"]) }
      get site_journeys_path(site)
    end

    it "draws the withheld branches as a node of their own, beside the survivors" do
      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/flow-node-label">2 branches withheld/)
      expect(response.body).to match(/flow-node-label">\/pricing/)
    end

    # Complementary suppression can take every branch. The node then has one
    # dashed child saying so — never a bare box, which would read as a place
    # visitors simply stopped.
    it "draws a fully withheld level as a withheld node rather than a dead end" do
      2.times { |i| visit_pages("d#{i}", ["/", "/pricing", "/checkout"]) }
      get site_journeys_path(site, path: ["/", "/pricing"])

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/flow-node-label">\d+ branches withheld/)
      expect(response.body).to include("not because nobody went anywhere")
    end

    # No percentage on that edge. The share is recoverable from the node total
    # that is already on screen, and printing it beside a node that says how many
    # visitors it holds is the complement the suppression exists to protect.
    it "puts no share on the withheld edge" do
      expect(response.body.scan(/class="flow-edge-label"/).size).to eq(1)
    end
  end

  # Twelve entry-page chips cannot answer "what happens after somebody clicks
  # this". The field can, and it is free text over a k-anonymous list — the same
  # combobox the goal and funnel forms use.
  describe "the start-from picker" do
    before do
      2.times { |i| visit_pages("s#{i}", ["/", "/pricing"]) }
      get site_journeys_path(site)
    end

    it "offers a kind and a value, named as the URL's two arrays" do
      expect(response.body).to include('name="kind[]"')
      expect(response.body).to include('name="path[]"')
    end

    it "carries the values this site has recorded" do
      expect(response.body).to include(OffersKnownValues::KNOWN_VALUES_DOM_ID)
      expect(response.body).to include("or type anything else")
    end

    # A GET form: the answer is a URL like every other piece of state here, and
    # the screen still works with no JavaScript.
    it "starts a journey at a typed page" do
      get site_journeys_path(site, path: ["/pricing"], kind: %w[pageview])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("After /pricing")
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
