require "rails_helper"

# What a breakdown panel says when k-anonymity withholds everything.
#
# The panel used to render "No data." in that case, because the suppression notice
# was nested inside the `result.any?` arm and `any?` counts the rows that SURVIVED.
# So the one situation where an owner most needs the explanation — a new or quiet
# site where every row sits under the threshold — was the exact one that told them
# there was nothing there.
#
# It also put the panel in direct contradiction with the summary above it, which
# reports the visitors those withheld rows are made of. Reproduced on a fresh site
# at the default threshold of 25: the summary said 6 visitors while the pages panel
# said "No data."
RSpec.describe "Breakdown suppression", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user) }
  let!(:membership) { create(:membership, account: account, user: user, role: "owner") }
  let(:site) { create(:site, account: account, k_anonymity_threshold: threshold) }

  before { sign_in user }

  # The dashboard renders eight panels. A fixture that only creates pageviews
  # leaves the other seven genuinely empty, and those SHOULD say "No data." — so an
  # assertion against the whole page cannot tell this bug from correct behaviour.
  # This slices out a single panel, from its heading to the start of the next card.
  def panel(title)
    body = response.body
    start = body.index(">#{title}<") or raise "no #{title.inspect} panel on the page"
    finish = body.index(%r{<div class="card"}, start) || body.length
    body[start...finish]
  end

  context "when every row is below the threshold" do
    let(:threshold) { 25 }

    before do
      6.times { |i| create_event(site, path: "/", visitor: "v#{i}", at: 1.hour.ago) }
      get site_path(site)
    end

    it "does not claim there is no data" do
      expect(panel("Top pages")).not_to include("No data.")
    end

    it "says plainly that something was withheld" do
      expect(response.body).to include("not because nothing happened")
      expect(response.body).to include("withheld")
    end

    it "states the threshold that caused it" do
      expect(response.body).to include("fewer than 25 visitors")
    end

    # The owner can act on this; being told a number without being told where to
    # change it is the kind of dead end that makes people think the tool is broken.
    it "points the owner at the setting" do
      expect(response.body).to include(edit_site_path(site))
    end
  end

  context "when rows survive" do
    let(:threshold) { 0 }

    before do
      3.times { |i| create_event(site, path: "/pricing", visitor: "v#{i}", at: 1.hour.ago) }
      get site_path(site)
    end

    it "shows them" do
      expect(response.body).to include("/pricing")
    end

    it "does not show the everything-withheld message" do
      expect(response.body).not_to include("not because nothing happened")
    end
  end

  context "when there genuinely is no data" do
    let(:threshold) { 25 }

    before { get site_path(site) }

    it "still says so" do
      expect(response.body).to include("No data.")
    end

    it "does not imply something was hidden" do
      expect(response.body).not_to include("not because nothing happened")
    end
  end

  # The public shared dashboard renders the same partial with drillable: false. Its
  # readers are a customer's own audience: they cannot reach site settings, and
  # telling them the privacy threshold is adjustable invites exactly the wrong
  # question.
  context "on a public shared dashboard" do
    let(:threshold) { 25 }
    let(:shared_link) { create(:shared_link, site: site) }

    before do
      sign_out user
      6.times { |i| create_event(site, path: "/", visitor: "v#{i}", at: 1.hour.ago) }
      get shared_dashboard_path(shared_link.slug)
    end

    it "still explains the suppression" do
      expect(response.body).to include("withheld")
    end

    it "does not offer a settings link to someone who is not the owner" do
      expect(response.body).not_to include(edit_site_path(site))
      expect(response.body).not_to include("lower the threshold")
    end
  end
end
