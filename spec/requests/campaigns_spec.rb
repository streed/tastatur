require "rails_helper"

# The screen is a builder and a report on one page, and the examples split the
# same way: what it refuses to build, and what it is honest about measuring.
#
# It lives UNDER THE SITE — /sites/:token/campaigns — beside goals and funnels,
# because a campaign is a property of a site: its tag is unique per site and its
# links are validated against that site's own hostnames. The list across every
# site is a separate screen with no builder on it; see
# spec/requests/all_campaigns_spec.rb.
RSpec.describe "A site's campaigns", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :no_suppression, account: account, domain: "northwind.example.com") }

  def sign_in_as(role)
    create(:membership, account: account, user: user, role: role)
    sign_in user
  end

  def screen(**params) = site_campaigns_path(site, **params)

  # Overrides land on the CAMPAIGN by default and on its one link under `link:`,
  # because the two halves now fail for different reasons and the examples need
  # to aim at one or the other: a bad tag kills every link in the campaign, a
  # bad destination kills one.
  def valid_params(link: {}, **overrides)
    { campaign: { name: "August launch", utm_campaign: "august",
                  campaign_links_attributes: [
                    { name: "Newsletter", destination_url: "https://northwind.example.com/pricing",
                      utm_source: "newsletter", utm_medium: "email" }.merge(link)
                  ] }.merge(overrides) }
  end

  describe "reaching it" do
    # THE POINT OF THE MOVE BACK UNDER THE SITE. It is one of this site's
    # screens, in the row beside Goals and Funnels, so reading what a campaign
    # did and then looking at anything else about the site is one click rather
    # than picking the site again.
    it "is on the site's own header, beside its other reports" do
      sign_in_as("owner")

      get site_path(site)

      expect(response.body).to include(ERB::Util.html_escape(site_campaigns_path(site)))
    end

    # The dashboard's Campaigns panel crosses over too, so somebody reading a
    # campaign row is one click from building the next link.
    it "is linked from the dashboard's campaign panel" do
      sign_in_as("owner")

      get site_path(site)

      expect(response.body).to include("Build a link")
    end

    # The tenant boundary is SiteScoped's now, not a second copy of it living in
    # CampaignScreen — which is the whole reason the screen moved into the
    # /sites tree rather than keeping a `?site=` parameter.
    it "refuses a site token belonging to another account" do
      sign_in_as("owner")
      other = create(:site)

      expect { get site_campaigns_path(other) }.not_to raise_error
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index" do
    before { sign_in_as("owner") }

    it "puts the builder above the report, which is what the button promised" do
      create(:campaign_link, site: site, name: "Old link")

      get screen

      expect(response.body.index("Where it goes")).to be < response.body.index("Old link")
    end

    # THE FEATURE, in one example. Several links under one heading, and a
    # heading figure that is NOT their sum.
    it "groups a campaign's links under its name and totals it over the tag" do
      campaign = create(:campaign, site: site, name: "August launch", utm_campaign: "august")
      create(:campaign_link, campaign: campaign, name: "Discord",
                             utm_source: "discord", utm_medium: "social")
      create(:campaign_link, campaign: campaign, name: "Facebook",
                             utm_source: "facebook", utm_medium: "social")

      # One person follows BOTH links. Two link rows of one visitor each, and
      # one visitor on the campaign — which is the whole reason the heading gets
      # its own query rather than adding the rows up.
      create_event(site, visitor: "a", utm_source: "discord", utm_medium: "social",
                         utm_campaign: "august", at: 1.day.ago)
      create_event(site, visitor: "a", utm_source: "facebook", utm_medium: "social",
                         utm_campaign: "august", at: 1.day.ago)

      get screen

      expect(response.body).to include("August launch")
      expect(response.body).to include("Discord")
      expect(response.body).to include("Facebook")
      expect(response.body).to include("counted over its whole tag, not added up")
    end

    it "shows a saved link's visitors, visits and views" do
      link = create(:campaign_link, site: site, utm_source: "newsletter", utm_medium: "email",
                                    utm_campaign: "august")
      create_event(site, visitor: "a", utm_source: "newsletter", utm_medium: "email",
                         utm_campaign: "august", at: 1.day.ago)

      get screen

      expect(response.body).to include(link.name)
      # Escaped, because the "&" between two utm parameters is an entity in the
      # rendered page and a raw comparison would fail on every link that has
      # more than one tag — which is all of them.
      expect(response.body).to include(ERB::Util.html_escape(link.url))
      expect(response.body).to include(">1<")
    end

    # The half of the screen that finds the typo. A hand-built `Newsletter`
    # sitting beside the saved `newsletter` is invisible on the dashboard's
    # Campaigns panel, which groups by utm_campaign alone.
    it "lists tagged traffic that no saved link explains" do
      create_event(site, visitor: "a", utm_source: "Newsletter", utm_medium: "email",
                         utm_campaign: "august", at: 1.day.ago)

      get screen

      expect(response.body).to include("Campaigns not built here")
    end

    it "does not offer the builder to a viewer" do
      viewer = create(:user)
      create(:membership, account: account, user: viewer, role: "viewer")
      sign_in viewer

      get screen

      expect(response.body).to include("member action")
    end

    it "does not list a campaign belonging to another account" do
      other = create(:campaign, name: "Somebody else's launch")

      get screen

      expect(response.body).not_to include(other.name)
    end
  end

  describe "POST create" do
    before { sign_in_as("owner") }

    it "saves a link and returns to the report" do
      expect { post site_campaigns_path(site), params: valid_params }
        .to change(CampaignLink, :count).by(1)

      expect(response).to redirect_to(site_campaigns_path(site, created: Campaign.last.public_id))
    end

    # The failure this whole screen exists to prevent: a link that saves
    # cleanly, is sent to a mailing list, and reports nothing forever because
    # Ingest::PathScrubber discards a token-shaped value on arrival.
    it "refuses a value the scrubber would discard, and says why" do
      post site_campaigns_path(site), params: valid_params(utm_campaign: "c" * 30)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("discarded on arrival")
      expect(CampaignLink.count).to be_zero
    end

    it "refuses a destination this site does not measure" do
      post site_campaigns_path(site),
           params: valid_params(link: { destination_url: "https://elsewhere.example.org/" })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("does not measure")
    end

    # A re-rendered form has to come back with the report around it, or the
    # 422 is a blank page with a form on it.
    it "re-renders the whole screen on failure, not a bare form" do
      create(:campaign_link, site: site, name: "Existing link")

      post site_campaigns_path(site), params: valid_params(utm_campaign: "d" * 30)

      expect(response.body).to include("Existing link")
    end

    it "refuses a member of another account" do
      other = create(:site)

      post site_campaigns_path(other), params: valid_params

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET edit" do
    before { sign_in_as("owner") }

    it "renders the same builder, and says what changing a tag does" do
      link = create(:campaign_link, site: site)

      get edit_site_campaign_link_path(site, link.campaign, link)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("re-points this link")
      expect(response.body).to include("campaign_link[utm_campaign]")
    end

    # §10: nothing routable is addressed by its primary key.
    it "is not reachable by primary key" do
      link = create(:campaign_link, site: site)

      get "/sites/#{site.public_token}/campaigns/#{link.campaign.public_id}/links/#{link.id}/edit"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    before { sign_in_as("owner") }

    it "saves a changed tag" do
      link = create(:campaign_link, site: site)

      patch site_campaign_link_path(site, link.campaign, link),
            params: { campaign_link: { utm_source: "discord" } }

      expect(link.reload.utm_source).to eq("discord")
    end
  end

  describe "DELETE destroy" do
    before { sign_in_as("owner") }

    it "removes the link and says the traffic is still counted" do
      link = create(:campaign_link, site: site)

      delete site_campaign_link_path(site, link.campaign, link)

      expect(CampaignLink.exists?(link.id)).to be(false)
      follow_redirect!
      expect(response.body).to include("still counted")
    end
  end

  # THE PREVIEW AND THE SAVED URL MUST AGREE.
  #
  # campaign_builder_controller.js builds the URL shown while the form is being
  # typed; CampaignLink#url builds the one shown everywhere else. Two
  # implementations of one string is exactly the sort of thing that drifts on
  # the awkward cases, and the drift would be invisible — the preview is what
  # gets copied, so a wrong one is a campaign that measures nothing.
  #
  # A request spec cannot run the JavaScript, so what it pins is the contract
  # the JavaScript is written against: the parameter order, and the two cases
  # (existing query string, fragment) where a naive implementation of either
  # half would differ.
  describe "the builder contract" do
    let(:builder) { Rails.root.join("app/javascript/controllers/campaign_builder_controller.js").read }

    it "declares the same parameters, in the same order, as the model" do
      declared = builder[/static PARAMS = \[(.*?)\]/m, 1].scan(/"([^"]+)"/).flatten

      expect(declared).to eq(CampaignLink::PARAMS.map(&:to_s))
    end

    # THE SUFFIX IS THE CONTRACT, not the prefix. The builder finds a field with
    # `[name$="[utm_source]"]`, which is what lets one implementation serve the
    # nested rows of the campaign form (campaign[campaign_links_attributes][0]
    # [utm_source]) and the standalone link form (campaign_link[utm_source])
    # alike. Asserting the prefix would have pinned the shape the fields
    # happened to have before they were nested.
    it "reads the fields by the names the form actually renders" do
      sign_in_as("owner")

      get screen

      (CampaignLink::PARAMS + [:destination_url]).each do |param|
        expect(response.body).to match(/name="[^"]*\[#{param}\]"/)
      end
    end
  end

  # ADDING A CHANNEL TO A CAMPAIGN THAT ALREADY EXISTS — the common return
  # visit. The campaign was built for Discord and Facebook in March; the
  # newsletter goes out in April.
  describe "POST a link under a campaign" do
    before { sign_in_as("owner") }

    let(:campaign) { create(:campaign, site: site, name: "August launch", utm_campaign: "august") }

    def link_params(**overrides)
      { campaign_link: { name: "Discord", destination_url: "https://northwind.example.com/",
                         utm_source: "discord", utm_medium: "social" }.merge(overrides) }
    end

    it "adds it, tagged with the campaign's own value rather than one it was given" do
      expect { post site_campaign_links_path(site, campaign), params: link_params }
        .to change(CampaignLink, :count).by(1)

      expect(CampaignLink.last.utm_campaign).to eq("august")
      expect(CampaignLink.last.campaign).to eq(campaign)
    end

    # utm_campaign is not in the permitted list, and CampaignLink copies it down
    # on every save regardless. Two independent reasons a posted tag cannot take
    # a link out of the group it is displayed under.
    it "ignores a utm_campaign posted alongside it" do
      post site_campaign_links_path(site, campaign), params: link_params(utm_campaign: "somewhere-else")

      expect(CampaignLink.last.utm_campaign).to eq("august")
    end

    it "re-renders the whole screen on failure, with the campaign still on it" do
      post site_campaign_links_path(site, campaign),
           params: link_params(destination_url: "https://elsewhere.example.org/")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("does not measure")
      expect(response.body).to include("August launch")
    end

    it "refuses a campaign belonging to another account" do
      other = create(:campaign)

      expect { post site_campaign_links_path(other.site, other), params: link_params }.not_to raise_error
      expect(response).to have_http_status(:not_found)
      expect(CampaignLink.where(campaign: other)).to be_empty
    end

    it "is refused to a viewer" do
      viewer = create(:user)
      create(:membership, account: account, user: viewer, role: "viewer")
      sign_in viewer

      post site_campaign_links_path(site, campaign), params: link_params

      expect(CampaignLink.count).to be_zero
    end
  end

  describe "the campaign itself" do
    before { sign_in_as("owner") }

    let(:campaign) { create(:campaign, site: site, name: "August launch", utm_campaign: "august") }

    # §10: nothing routable is addressed by its primary key.
    it "is not reachable by primary key" do
      get "/sites/#{site.public_token}/campaigns/#{campaign.id}/edit"

      expect(response).to have_http_status(:not_found)
    end

    it "says what changing the tag does before it is changed" do
      get edit_site_campaign_path(site, campaign)

      expect(response.body).to include("re-points every link")
    end

    # The property that makes the campaign the one place the tag is spelled.
    it "re-points its links when the tag is renamed" do
      link = create(:campaign_link, campaign: campaign)

      patch site_campaign_path(site, campaign), params: { campaign: { utm_campaign: "september" } }

      expect(link.reload.utm_campaign).to eq("september")
    end

    it "takes its links with it when deleted, and says the traffic is still counted" do
      create(:campaign_link, campaign: campaign)

      expect { delete site_campaign_path(site, campaign) }.to change(CampaignLink, :count).by(-1)

      follow_redirect!
      expect(response.body).to include("still counted")
    end
  end
end
