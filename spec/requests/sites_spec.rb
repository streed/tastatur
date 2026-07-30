require "rails_helper"

# SitesController had no request spec at all, and the two things worth asserting
# here are both about what the CUSTOMER is told: that a refused site says why in
# words, and that an account over its limit is not locked out of the sites it
# already has.
RSpec.describe "Sites", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account, plan: "free") }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  describe "POST /sites" do
    it "creates the first site and sends the owner to the snippet" do
      post "/sites", params: { site: { domain: "first.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }

      site = account.sites.sole
      expect(response).to redirect_to(site_installation_path(site))
      expect(site.domain).to eq("first.example.com")
    end

    # 422 alone would be a form that refuses without explaining. The message is the
    # deliverable: it names the limit and what to do about it.
    it "refuses the second site on a free account and says why" do
      create(:site, account: account)

      post "/sites", params: { site: { domain: "second.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("limited to 1 site")
      expect(response.body).to include("Upgrade to Pro")
      expect(account.sites.count).to eq(1)
    end

    it "allows a paid account past the free limit" do
      account.update!(plan: "pro")
      create(:site, account: account)

      post "/sites", params: { site: { domain: "second.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }

      expect(response).to have_http_status(:redirect)
      expect(account.sites.count).to eq(2)
    end
  end

  describe "GET /sites" do
    it "states the site allowance and offers to add one when there is room" do
      account.update!(plan: "pro")
      create(:site, account: account)

      get "/sites"

      expect(response.body).to include("1 of 20 sites")
      expect(response.body).to include("Add a site")
    end

    # Offering a button that cannot succeed is worse than not offering it: the
    # customer types a domain before finding out.
    it "replaces the add button with the plan screen at the limit" do
      create(:site, account: account)

      get "/sites"

      expect(response.body).not_to include(">Add a site<")
      expect(response.body).to include("Add more sites")
      expect(response.body).to include(billing_path)
    end
  end

  describe "an account left over its limit by a downgrade" do
    let!(:sites) do
      account.update!(site_limit_override: 3)
      Array.new(3) { |i| account.sites.create!(domain: "kept-#{i}.example.com") }
    end

    before { account.update!(site_limit_override: nil) }

    it "can still save changes to an existing site" do
      patch "/sites/#{sites.first.public_token}", params: { site: { timezone: "Europe/Berlin" } }

      expect(response).to redirect_to(site_path(sites.first))
      expect(sites.first.reload.timezone).to eq("Europe/Berlin")
    end

    it "can still read its dashboards" do
      get "/sites/#{sites.last.public_token}"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "on a self-hosted install" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(true) }

    it "applies no site limit and shows no allowance" do
      create(:site, account: account)

      post "/sites", params: { site: { domain: "second.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }
      expect(account.sites.count).to eq(2)

      get "/sites"
      expect(response.body).not_to include("of 1 sites")
      expect(response.body).not_to include(billing_path)
    end
  end
end
