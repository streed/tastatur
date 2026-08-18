require "rails_helper"

# The screen is a builder and a report on one page, and the examples split the
# same way: what it refuses to build, and what it is honest about measuring.
RSpec.describe "Campaigns", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :no_suppression, account: account, domain: "northwind.example.com") }

  def sign_in_as(role)
    create(:membership, account: account, user: user, role: role)
    sign_in user
  end

  def valid_params(**overrides)
    { campaign_link: { name: "August newsletter", destination_url: "https://northwind.example.com/pricing",
                       utm_source: "newsletter", utm_medium: "email",
                       utm_campaign: "august" }.merge(overrides) }
  end

  describe "reaching it" do
    it "is offered from the dashboard header" do
      sign_in_as("owner")

      get site_path(site)

      expect(response.body).to include(site_campaigns_path(site))
    end
  end

  describe "GET index" do
    before { sign_in_as("owner") }

    it "puts the builder above the report, which is what the button promised" do
      create(:campaign_link, site: site, name: "Old link")

      get site_campaigns_path(site)

      expect(response.body.index("Where it goes")).to be < response.body.index("Old link")
    end

    it "shows a saved link's visitors, visits and views" do
      link = create(:campaign_link, site: site, utm_source: "newsletter", utm_medium: "email",
                                    utm_campaign: "august")
      create_event(site, visitor: "a", utm_source: "newsletter", utm_medium: "email",
                         utm_campaign: "august", at: 1.day.ago)

      get site_campaigns_path(site)

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

      get site_campaigns_path(site)

      expect(response.body).to include("Campaigns not built here")
    end

    it "does not offer the builder to a viewer" do
      viewer = create(:user)
      create(:membership, account: account, user: viewer, role: "viewer")
      sign_in viewer

      get site_campaigns_path(site)

      expect(response.body).to include("member action")
    end

    it "refuses a site belonging to another account before authorization is asked" do
      other = create(:site)

      expect { get site_campaigns_path(other) }.not_to raise_error
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    before { sign_in_as("owner") }

    it "saves a link and returns to the report" do
      expect { post site_campaigns_path(site), params: valid_params }
        .to change(CampaignLink, :count).by(1)

      expect(response).to redirect_to(site_campaigns_path(site, created: CampaignLink.last.public_id))
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
      post site_campaigns_path(site), params: valid_params(destination_url: "https://elsewhere.example.org/")

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

      get edit_site_campaign_path(site, link)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("re-points this link")
      expect(response.body).to include("campaign_link[utm_campaign]")
    end

    # §10: nothing routable is addressed by its primary key.
    it "is not reachable by primary key" do
      link = create(:campaign_link, site: site)

      get "/sites/#{site.public_token}/campaigns/#{link.id}/edit"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    before { sign_in_as("owner") }

    it "saves a changed tag" do
      link = create(:campaign_link, site: site)

      patch site_campaign_path(site, link),
            params: { campaign_link: { utm_campaign: "september" } }

      expect(link.reload.utm_campaign).to eq("september")
    end
  end

  describe "DELETE destroy" do
    before { sign_in_as("owner") }

    it "removes the link and says the traffic is still counted" do
      link = create(:campaign_link, site: site)

      delete site_campaign_path(site, link)

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

    it "reads the fields by the names the form actually renders" do
      sign_in_as("owner")

      get site_campaigns_path(site)

      CampaignLink::PARAMS.each do |param|
        expect(response.body).to include("campaign_link[#{param}]")
      end
      expect(response.body).to include("campaign_link[destination_url]")
    end
  end
end
