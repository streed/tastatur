require "rails_helper"

# The only unauthenticated endpoint that renders a tenant's statistics. A mistake
# here shows one customer's traffic to a stranger, so every guard has its own
# example.
RSpec.describe "Shared dashboards", type: :request do
  let(:site) { create(:site, :receiving, domain: "measured.example.com") }
  let(:link) { create(:shared_link, site: site) }

  before do
    delete_all_events
    create_events(site, count: 30, path: "/", visitor_prefix: "v", at: 2.days.ago)
  end

  describe "an open link" do
    it "renders without a session" do
      get "/share/#{link.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("measured.example.com")
    end

    it "keeps itself out of search indexes, which is what makes it 'unlisted'" do
      get "/share/#{link.slug}"
      expect(response.body).to include("noindex")
    end

    it "counts the view" do
      expect { get "/share/#{link.slug}" }.to change { link.reload.view_count }.by(1)
    end
  end

  describe "guards" do
    # 404, not 403. Distinguishing "revoked" from "never existed" tells an
    # anonymous caller that a slug was once valid.
    it "404s an unknown slug" do
      get "/share/#{'A' * 24}"
      expect(response).to have_http_status(:not_found)
    end

    it "404s an expired link rather than saying it expired" do
      expired = create(:shared_link, :expired, site: site)
      get "/share/#{expired.slug}"
      expect(response).to have_http_status(:not_found)
    end

    it "does not accept a site id or domain in place of the slug" do
      get "/share/#{site.id}"
      expect(response).to have_http_status(:not_found)

      get "/share/#{site.public_token}"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "password protection" do
    let(:locked) { create(:shared_link, :with_password, site: site) }

    it "withholds the dashboard until unlocked" do
      get "/share/#{locked.slug}"

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include("Unique visitors")
    end

    it "unlocks with the correct password" do
      post "/share/#{locked.slug}/unlock", params: { password: "correct horse battery staple" }
      expect(response).to redirect_to("/share/#{locked.slug}")

      get "/share/#{locked.slug}"
      expect(response).to have_http_status(:ok)
    end

    it "rejects a wrong password" do
      post "/share/#{locked.slug}/unlock", params: { password: "wrong" }
      follow_redirect!
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not let unlocking one link unlock another" do
      other = create(:shared_link, :with_password, site: site, name: "Another")

      post "/share/#{locked.slug}/unlock", params: { password: "correct horse battery staple" }
      get "/share/#{other.slug}"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "what a public dashboard must not offer" do
    # Filtering someone else's audience is a re-identification tool: narrow
    # enough filters isolate an individual. Public dashboards therefore ignore
    # filter parameters entirely rather than relying on the k threshold alone.
    it "ignores filter parameters" do
      get "/share/#{link.slug}?country=DE&page=/"
      expect(response.body).not_to include("Filtered by")
    end

    it "renders no drill-down links" do
      get "/share/#{link.slug}"
      expect(response.body).not_to include("Filter by")
    end

    it "shows no owner-only management links" do
      get "/share/#{link.slug}"
      expect(response.body).not_to match(%r{>Manage<})
      expect(response.body).not_to include("/goals")
    end

    it "still applies the site's suppression threshold" do
      # One row of two visitors, well under the default threshold of 25.
      create_events(site, count: 2, path: "/secret", visitor_prefix: "s", at: 2.days.ago)

      get "/share/#{link.slug}"
      expect(response.body).not_to include("/secret")
    end
  end

  describe "isolation" do
    it "shows only the linked site's data" do
      other_site = create(:site, domain: "other.example.com")
      create_events(other_site, count: 30, path: "/theirs", visitor_prefix: "o", at: 2.days.ago)

      get "/share/#{link.slug}"

      expect(response.body).to include("measured.example.com")
      expect(response.body).not_to include("other.example.com")
      expect(response.body).not_to include("/theirs")
    end
  end
end
