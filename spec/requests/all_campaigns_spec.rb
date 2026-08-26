require "rails_helper"

# /campaigns — every campaign on every site you can read, and nothing you can do
# to one. The builder is under the site it builds for; this is the directory.
#
# MOST OF THESE EXAMPLES ARE ABOUT WHAT IT REFUSES TO ADD UP. A period preset
# resolves against ONE site's timezone (Analytics::Period), so "last 30 days"
# across sites in Berlin and Kolkata is two different windows — which is fine
# per row and a lie the moment anything is totalled. There is no total on this
# page and there must not be one.
RSpec.describe "All campaigns", type: :request do
  let(:user) { create(:user) }
  # Pro, because the point of this screen is several sites at once and Free
  # allows one — see Billing::Plan.
  let(:account) { create(:account, plan: "pro") }
  let(:site) do
    create(:site, :no_suppression, account: account, domain: "northwind.example.com")
  end

  def sign_in_as(role = "owner")
    create(:membership, account: account, user: user, role: role)
    sign_in user
  end

  def tag(target, visitor:, campaign:, source: "newsletter", medium: "email")
    create_event(target, visitor: visitor, utm_source: source, utm_medium: medium,
                         utm_campaign: campaign, at: 2.days.ago)
  end

  describe "reaching it" do
    it "is in the application navigation, from anywhere" do
      sign_in_as
      site

      get account_path

      expect(response.body).to include(">Campaigns<")
      expect(response.body).to include(campaigns_path)
    end

    # It takes no site parameter at all, which is the point: it is the one
    # screen that answers "what is running" without picking a site first.
    it "needs no site chosen" do
      sign_in_as
      create(:campaign, site: site, name: "August launch")

      get campaigns_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("August launch")
      expect(response.body).to include(site.domain)
    end
  end

  describe "what it lists" do
    before { sign_in_as }

    # THE FEATURE. Campaigns on two sites, in one list, each grouped under the
    # site whose window and timezone its figures were measured in.
    it "lists campaigns from every site the viewer can read, grouped by site" do
      other = create(:site, :no_suppression, account: account, domain: "contoso.example.com")
      create(:campaign, site: site, name: "August launch", utm_campaign: "august")
      create(:campaign, site: other, name: "Winter sale", utm_campaign: "winter")

      get campaigns_path

      expect(response.body).to include("August launch")
      expect(response.body).to include("Winter sale")
      expect(response.body).to include("northwind.example.com")
      expect(response.body).to include("contoso.example.com")
    end

    it "shows what a campaign did over the site's window" do
      create(:campaign, site: site, name: "August launch", utm_campaign: "august")
      tag(site, visitor: "a", campaign: "august")
      tag(site, visitor: "b", campaign: "august")

      get campaigns_path

      expect(response.body).to include(">2<")
    end

    # The same figure the site's own campaigns screen shows, which is what makes
    # the two screens one product rather than two opinions. Both read
    # Analytics::CampaignPerformance.
    it "agrees with the site's own screen about the same campaign" do
      create(:campaign, site: site, name: "August launch", utm_campaign: "august")
      tag(site, visitor: "a", campaign: "august")
      tag(site, visitor: "a", campaign: "august", source: "discord", medium: "social")

      get campaigns_path
      across = response.body

      get site_campaigns_path(site)
      within = response.body

      # One visitor who followed two links: one on the campaign, both screens.
      expect(across).to include(">1<")
      expect(within).to include(">1<")
    end

    # A campaign with nothing yet is still named. It was built five minutes ago
    # and is exactly the one somebody is checking on.
    it "lists a campaign that has no traffic yet, with a dash" do
      create(:campaign, site: site, name: "Quiet launch", utm_campaign: "quiet")

      get campaigns_path

      expect(response.body).to include("Quiet launch")
      expect(response.body).to include("—")
    end

    it "does not list a campaign belonging to another account" do
      create(:campaign, name: "Somebody else's launch")

      get campaigns_path

      expect(response.body).not_to include("Somebody else's launch")
    end

    # Each row goes to the dashboard filtered to that campaign, carrying the
    # window it was measured over, and the site's card head goes to the builder.
    it "leads into the site it belongs to" do
      create(:campaign, site: site, name: "August launch", utm_campaign: "august")

      get campaigns_path

      expect(response.body).to include(ERB::Util.html_escape(site_campaigns_path(site)))
      expect(response.body).to include("utm_campaign=august")
    end
  end

  # THE RULE THIS SCREEN EXISTS UNDER. §12 forbids an all-sites roll-up because
  # a preset resolves against one site's timezone. Grouping per site is how this
  # page keeps a period at all, so the absence of a cross-site total is the
  # property worth pinning.
  describe "what it will not say" do
    before { sign_in_as }

    it "carries no total across sites" do
      other = create(:site, :no_suppression, account: account, domain: "contoso.example.com")
      create(:campaign, site: site, utm_campaign: "august")
      create(:campaign, site: other, utm_campaign: "winter")
      tag(site, visitor: "a", campaign: "august")
      tag(other, visitor: "b", campaign: "winter")

      get campaigns_path

      expect(response.body).to include("nothing here is added")
      expect(response.body).not_to match(/across every site/i)
    end

    it "states the timezone each site's figures were measured in" do
      site.update!(timezone: "Europe/Berlin")
      create(:campaign, site: site, utm_campaign: "august")

      get campaigns_path

      expect(response.body).to include("Europe/Berlin")
    end

    # A custom range is two absolute dates resolved in a site's own zone, which
    # several sites cannot agree on — so it is not offered, and one asked for in
    # the URL falls back to the default rather than being honoured differently
    # per row.
    it "refuses a custom range and falls back to the default preset" do
      create(:campaign, site: site, utm_campaign: "august")

      get campaigns_path(period: "custom", from: "2026-01-01", to: "2026-02-01")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(Analytics::Period::PRESETS[Analytics::Period::DEFAULT])
    end

    it "honours a preset it does offer" do
      create(:campaign, site: site, utm_campaign: "august")

      get campaigns_path(period: "7d")

      expect(response.body).to include("Last 7 days")
    end

    # Every campaign the account built is named here whether or not it has a
    # figure, so a withheld count beside the dashes would say "somebody came,
    # fewer than k of them" about a campaign that can be sent to one person.
    it "does not say how many campaigns were withheld" do
      strict = create(:site, account: account, domain: "strict.example.com",
                             k_anonymity_threshold: 5)
      create(:campaign, site: strict, name: "Small launch", utm_campaign: "small")
      2.times { |i| tag(strict, visitor: "v#{i}", campaign: "small") }

      get campaigns_path

      expect(response.body).to include("Small launch")
      expect(response.body).to include("—")
      expect(response.body).not_to match(/withheld/i)
    end
  end

  describe "an account with nothing on it" do
    it "says to add a site when there are none" do
      sign_in_as

      get campaigns_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add a site first")
    end

    it "offers the sites to build on when there are no campaigns" do
      sign_in_as
      site

      get campaigns_path

      expect(response.body).to include("No campaigns yet")
      expect(response.body).to include(ERB::Util.html_escape(site_campaigns_path(site)))
    end
  end

  # There is nothing to authorize on this screen — it renders no form and no
  # button that changes anything — so a viewer reads it like anybody else, and
  # sees only what CampaignPolicy::Scope gives them.
  it "is readable by a viewer" do
    sign_in_as("viewer")
    create(:campaign, site: site, name: "August launch")

    get campaigns_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("August launch")
  end
end
