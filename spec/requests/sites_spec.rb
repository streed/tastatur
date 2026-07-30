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

  describe "adding a domain the account already measures" do
    # Pro, so that what refuses the second site is the duplicate and not the
    # free plan's limit of one — on a free account this whole section would pass
    # for entirely the wrong reason.
    before do
      account.update!(plan: "pro")
      account.sites.create!(domain: "example.com")
    end

    it "re-renders the form with the error and adds nothing" do
      post "/sites", params: { site: { domain: "example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
      expect(account.sites.count).to eq(1)
    end

    it "normalises before comparing, so a pasted URL is caught too" do
      post "/sites", params: { site: { domain: "https://WWW.Example.com/", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.sites.count).to eq(1)
    end

    # THE RACE. The validation SELECTs and the index enforces; between the two a
    # second request fits, and a double-clicked submit button is enough to open
    # that window. Unhandled it is a 500 — an error page and a Sentry alert for
    # something the form above already explains in words.
    #
    # Raising from `save` is the only way to reach that branch deterministically
    # from a single-threaded example. That the database really does raise this,
    # for this index, is asserted in spec/models/site_spec.rb.
    it "renders the form rather than a 500 when two requests race" do
      allow_any_instance_of(Site).to receive(:save).and_raise(
        ActiveRecord::RecordNotUnique.new(
          %(PG::UniqueViolation: ERROR: duplicate key value violates unique ) +
          %(constraint "index_sites_on_account_id_and_domain")
        )
      )

      post "/sites", params: { site: { domain: "raced.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
    end

    # The narrowness is the point. Translating every RecordNotUnique would turn a
    # broken public_token generator into a customer-facing message about a
    # duplicate domain, and nothing would ever reach Sentry to say so.
    it "still raises a unique violation from any other index" do
      allow_any_instance_of(Site).to receive(:save).and_raise(
        ActiveRecord::RecordNotUnique.new(
          %(PG::UniqueViolation: ERROR: duplicate key value violates unique ) +
          %(constraint "index_sites_on_public_token")
        )
      )

      expect do
        post "/sites", params: { site: { domain: "raced.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # Same race, same window, on the other write path: renaming an existing site
    # onto a domain the account already has.
    it "is handled the same way when editing an existing site" do
      other = account.sites.create!(domain: "other.example.com")

      patch "/sites/#{other.public_token}", params: { site: { domain: "example.com" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("has already been taken")
      expect(other.reload.domain).to eq("other.example.com")
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
