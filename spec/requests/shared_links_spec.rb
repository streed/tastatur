require "rails_helper"

# Getting a read-only link out to a client used to be: dashboard, Settings, scroll
# to the bottom of the form, Share links, scroll past every existing link to the
# form, create, then select the URL with the mouse. Every example here is about one
# of those steps no longer existing, so they assert on reachability and on what is
# offered rather than on the model, which had no request spec at all.
RSpec.describe "Share links", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account, domain: "northwind.example.com") }

  def sign_in_as(role)
    create(:membership, account: account, user: user, role: role)
    sign_in user
  end

  describe "reaching the page" do
    it "is offered from the dashboard itself, not only from settings" do
      sign_in_as("owner")

      get site_path(site)

      expect(response.body).to include(site_shared_links_path(site))
    end

    # It moved out of `f.actions`' `destructive:` slot, which is where the delete
    # button goes. Sharing a dashboard is not a destructive action and it was being
    # rendered as one.
    it "is no longer buried at the bottom of the settings form" do
      sign_in_as("owner")

      get edit_site_path(site)

      expect(response.body).not_to include(site_shared_links_path(site))
    end
  end

  describe "GET index" do
    it "puts the create form above the existing links" do
      sign_in_as("admin")
      create(:shared_link, site: site, name: "Acme monthly")

      get site_shared_links_path(site)

      expect(response.body.index("New share link")).to be < response.body.index("Existing links")
    end

    it "offers the full URL as something copyable rather than something to select" do
      sign_in_as("admin")
      link = create(:shared_link, site: site)

      get site_shared_links_path(site)

      expect(response.body).to include(shared_dashboard_url(link.slug))
      expect(response.body).to include("Copy link")
      expect(response.body).to include('data-clipboard-target="source"')
    end

    # That URL 404s. Handing somebody a one-click copy of it is worse than making
    # them ask why it stopped working.
    it "does not offer to copy an expired link" do
      sign_in_as("admin")
      create(:shared_link, :expired, site: site)

      get site_shared_links_path(site)

      expect(response.body).not_to include("Copy link")
    end

    # Viewing is member-and-up, creating is admin-and-up, and the dashboard now
    # offers this page to everybody who can view it. A form here would only bounce.
    it "shows a member the links without a form that cannot succeed" do
      sign_in_as("member")
      create(:shared_link, site: site, name: "Acme monthly")

      get site_shared_links_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Acme monthly")
      expect(response.body).not_to include("New share link")
      expect(response.body).to include("Ask an account admin")
    end
  end

  describe "POST create" do
    before { sign_in_as("admin") }

    it "comes back with the new link highlighted and first in the list" do
      create(:shared_link, site: site, name: "Aardvark", created_at: 1.day.ago)

      post site_shared_links_path(site), params: { shared_link: { name: "Zebra" } }
      created = site.shared_links.find_by!(name: "Zebra")

      expect(response).to redirect_to(site_shared_links_path(site, created: created.public_id))

      follow_redirect!
      expect(response.body.index("Zebra")).to be < response.body.index("Aardvark")
    end

    it "refuses a member" do
      user.memberships.update_all(role: "member")

      post site_shared_links_path(site), params: { shared_link: { name: "Sneaky" } }

      expect(response).to have_http_status(:redirect)
      expect(site.shared_links.count).to be_zero
    end
  end
end
