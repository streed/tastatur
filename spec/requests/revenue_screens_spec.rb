require "rails_helper"

RSpec.describe "Revenue screens", type: :request do
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account) }

  def sign_in_as(role)
    user = create(:user)
    create(:membership, account: account, user: user, role: role)
    sign_in user
    user
  end

  describe "the attribution screen" do
    # Open to viewers, like every other report. A viewer who can see 40,000
    # visitors but not the £3 they were worth is a role that sends someone back
    # to a spreadsheet.
    it "is readable by a viewer" do
      sign_in_as("viewer")

      get site_attribution_path(site)

      expect(response).to have_http_status(:ok)
    end

    it "explains what connecting Stripe gets you when nothing is connected" do
      sign_in_as("viewer")

      get site_attribution_path(site)

      expect(response.body).to include("Connect Stripe")
    end

    it "renders the channels once there is data" do
      sign_in_as("admin")
      create(:stripe_connection, site: site)
      create(:attribution_rollup, site: site, source: "reddit", medium: "social",
                                  net_mrr_cents: 12_000, visitors: 400)

      get site_attribution_path(site)

      expect(response.body).to include("reddit")
    end

    it "refuses a site in another account" do
      sign_in_as("owner")
      stranger = create(:site)

      get site_attribution_path(stranger)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the customers screen" do
    it "lists customers for a member" do
      sign_in_as("member")
      create(:customer, site: site, external_id: "user_42")

      get site_customers_path(site)

      expect(response.body).to include("user_42")
    end

    it "shows one customer's first touch and revenue history" do
      sign_in_as("member")
      customer = create(:customer, :paying, site: site, attribution_source: "reddit")
      create(:revenue_event, site: site, customer: customer)

      get site_customer_path(site, customer)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("reddit")
    end

    it "never shows another account's customer" do
      sign_in_as("owner")
      stranger = create(:customer, site: create(:site), external_id: "not_yours")

      get site_customer_path(site, stranger)

      expect(response).to have_http_status(:not_found)
    end
  end

  # ADMIN-AND-UP. An API key can assert that a visitor is a particular person and
  # can read every customer's revenue through the endpoints it authenticates.
  describe "API keys" do
    it "lets an admin mint one, shown exactly once" do
      sign_in_as("admin")

      post site_api_keys_path(site), params: { api_key: { name: "production" } }
      follow_redirect!

      expect(response.body).to include("tk_")
      expect(response.body).to include("not shown again")
    end

    it "does not show the key again on a later visit" do
      sign_in_as("admin")
      post site_api_keys_path(site), params: { api_key: { name: "production" } }
      plaintext = flash[:api_key]
      follow_redirect!

      get site_api_keys_path(site)

      # The masked form (tk_<prefix>_••••••••abcd) is still there on purpose, so
      # somebody holding three keys can tell which is which. The secret is not.
      expect(plaintext).to be_present
      expect(response.body).not_to include(plaintext)
      expect(response.body).to include(site.api_keys.first.masked)
    end

    it "refuses a member" do
      sign_in_as("member")

      post site_api_keys_path(site), params: { api_key: { name: "production" } }

      expect(site.api_keys).to be_empty
    end

    it "refuses a viewer even to list them" do
      sign_in_as("viewer")
      create(:api_key, site: site, name: "production")

      get site_api_keys_path(site)

      expect(response.body).not_to include("production")
    end

    # Revoked, not deleted: a destroyed key takes with it the answer to "when did
    # this stop working, and was that before or after the incident?"
    it "revokes rather than deletes" do
      sign_in_as("admin")
      key = create(:api_key, site: site)

      expect { delete site_api_key_path(site, key) }.not_to change(ApiKey, :count)
      expect(key.reload).to be_revoked
    end
  end

  describe "connecting Stripe" do
    # The same pin billing_spec holds over its checkout buttons, for the same
    # §12 reason: this POST answers with a redirect to marketplace.stripe.com,
    # and a Turbo-driven submission follows it with fetch straight into
    # Stripe's CORS policy — a console error, a button that does nothing, and
    # nothing to see server-side. Found in production by exactly that symptom.
    it "renders the Connect button with turbo disabled, everywhere it appears" do
      sign_in_as("admin")

      [site_attribution_path(site), edit_site_path(site)].each do |path|
        get path

        form = response.body[/<form[^>]*#{Regexp.escape(site_stripe_connection_path(site))}[^>]*>/]
        expect(form).to include('data-turbo="false"'), "missing data-turbo=false on #{path}"
      end
    end

    it "refuses a member" do
      sign_in_as("member")

      post site_stripe_connection_path(site)

      expect(response).to have_http_status(:found)
      expect(site.stripe_connections).to be_empty
    end

    # No `scope` parameter: what the customer is asked to grant is the app
    # manifest's permission list, rendered by Stripe on the install screen.
    it "sends an admin to the Stripe App install link with a state parameter" do
      sign_in_as("admin")

      post site_stripe_connection_path(site)

      expect(response).to redirect_to(%r{\Ahttps://marketplace\.stripe\.com/oauth/v2/authorize})
      expect(response.location).to include("client_id=ca_test_suite")
      expect(response.location).to include(CGI.escape(stripe_connect_callback_url))
      expect(response.location).to match(/state=[^&]+/)
    end

    # The full happy path through the real route: start the flow to mint a
    # state, come back with it and a code, and end connected. This spec did not
    # exist under the legacy flow — the exchange was never stubbed anywhere —
    # which is how a broken callback could have shipped unnoticed.
    it "connects the site when the callback carries the state this browser started with" do
      sign_in_as("admin")
      allow(Revenue::AppOAuth).to receive(:exchange).with(code: "ac_1")
        .and_return({ stripe_user_id: "acct_new", livemode: true, scope: "stripe_apps" })

      post site_stripe_connection_path(site)
      state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

      get stripe_connect_callback_path(code: "ac_1", state: state)

      expect(response).to redirect_to(site_path(site))
      connection = site.stripe_connections.sole
      expect(connection.stripe_account_id).to eq("acct_new")
      expect(connection).to be_live

      # The state is single-use: `session.delete` on the way in is what makes
      # it so, and it is one character away from `session[:stripe_connect]`,
      # which would pass every other spec here while leaving the state
      # replayable for the life of the session.
      get stripe_connect_callback_path(code: "ac_2", state: state)
      expect(response).to redirect_to(sites_path)
      expect(site.stripe_connections.count).to eq(1)
    end

    # The state is a CSRF token and a routing slip at once. Without the random
    # half, anyone could send a victim a crafted callback URL and attach their own
    # Stripe account to the victim's site.
    it "refuses a callback whose state does not match this browser" do
      sign_in_as("admin")
      post site_stripe_connection_path(site)

      get stripe_connect_callback_path(code: "ac_1", state: "forged")

      expect(site.stripe_connections).to be_empty
    end

    it "refuses a callback with no state at all" do
      sign_in_as("admin")

      get stripe_connect_callback_path(code: "ac_1")

      expect(site.stripe_connections).to be_empty
    end

    it "disconnects without deleting the revenue already recorded" do
      sign_in_as("admin")
      connection = create(:stripe_connection, site: site)
      create(:revenue_event, site: site)

      delete site_stripe_connection_path(site)

      expect(connection.reload).to be_revoked
      expect(site.revenue_events.count).to eq(1)
    end
  end

  # Publishing a company's MRR to an unguessable-but-public URL is not something
  # anybody should be one checkbox away from.
  describe "public shared dashboards" do
    it "never render revenue" do
      link = create(:shared_link, site: site)
      customer = create(:customer, :paying, site: site, external_id: "user_42")
      create(:revenue_event, site: site, customer: customer, amount_cents: 999_999)

      get shared_dashboard_path(link.slug)

      expect(response.body).not_to include("user_42")
      expect(response.body).not_to include("9,999.99")
    end
  end
end
