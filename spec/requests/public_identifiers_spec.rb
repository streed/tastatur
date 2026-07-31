require "rails_helper"

# Regression specs for two related mistakes, both of which are silent.
#
# 1. `resources :sites, param: :public_token` renames the route SEGMENT, but
#    `site_path(site)` still calls `to_param`, which defaults to `id`. Every
#    generated link then points at /sites/2 while the route expects a token, and
#    every link 404s. Nothing errors at boot; the app simply stops working, and a
#    controller spec that builds URLs by hand will not notice.
#
# 2. Sequential integers in URLs leak how many sites and goals exist across the
#    whole instance, and invite enumeration.
#
# So these examples assert on the URLs the app GENERATES, not on hand-written
# paths.
RSpec.describe "Public identifiers", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :receiving, account: account, domain: "measured.example.com") }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  describe "to_param" do
    it "routes a site by its public token, never its id" do
      expect(site.to_param).to eq(site.public_token)
      expect(site.to_param).not_to eq(site.id.to_s)
    end

    it "routes goals, funnels, dashboards, links and memberships by UUID" do
      goal = create(:goal, site: site)
      funnel = create(:funnel, site: site)
      dashboard = create(:dashboard, site: site)
      link = create(:shared_link, site: site)
      membership = user.membership_for(account)

      [goal, funnel, dashboard, link, membership].each do |record|
        expect(record.to_param).to eq(record.public_id)
        expect(record.to_param).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-/), "#{record.class} is not a UUID"
        expect(record.to_param).not_to eq(record.id.to_s)
      end
    end
  end

  describe "generated links actually resolve" do
    it "follows every site link from the site list" do
      site
      get "/sites"

      links = response.body.scan(%r{href="(/sites/[^"/]+)"}).flatten.uniq
                      .reject { |href| href.end_with?("/new") }

      expect(links).not_to be_empty, "the site list rendered no site links"

      links.each do |href|
        get href
        expect(response).to have_http_status(:ok), "#{href} did not resolve"
      end
    end

    it "follows every goal, funnel and dashboard link generated on their index pages" do
      create(:goal, site: site)
      create(:funnel, site: site)
      create(:dashboard, site: site)

      %W[/sites/#{site.to_param}/goals /sites/#{site.to_param}/funnels
         /sites/#{site.to_param}/dashboards].each do |index|
        get index
        expect(response).to have_http_status(:ok)

        response.body.scan(%r{href="(/sites/[^"]*/(?:goals|funnels|dashboards)/[^"]+)"}).flatten.uniq.each do |href|
          get CGI.unescapeHTML(href)
          expect(response).to have_http_status(:ok), "#{href} did not resolve"
        end
      end
    end
  end

  describe "no integer identifiers are exposed" do
    it "emits no /sites/<integer> or /goals/<integer> anywhere on the dashboard" do
      create(:goal, site: site)
      create(:funnel, site: site)
      create(:dashboard, site: site)
      get "/sites/#{site.to_param}"

      hrefs = response.body.scan(/href="([^"]+)"/).flatten
      offenders = hrefs.grep(%r{/(sites|goals|funnels|dashboards|shared_links|members)/\d+(/|\z|\?)})

      expect(offenders).to be_empty
    end

    it "404s when an id is used in place of a public identifier" do
      goal = create(:goal, site: site)
      dashboard = create(:dashboard, site: site)

      get "/sites/#{site.id}"
      expect(response).to have_http_status(:not_found)

      get "/sites/#{site.to_param}/goals/#{goal.id}/edit"
      expect(response).to have_http_status(:not_found)

      get "/sites/#{site.to_param}/dashboards/#{dashboard.id}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
