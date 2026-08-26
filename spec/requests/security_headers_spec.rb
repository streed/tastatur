require "rails_helper"

# THE HEADERS THE APPLICATION EMITS, not the ones something in front of it might.
#
# config/Caddyfile sets X-Frame-Options, nosniff and Referrer-Policy, and for a
# long time that was the only place a Content-Security-Policy was going to come
# from — which is to say nowhere, because Caddy is only in front of the bundled
# compose deployment. Railway has nothing in front of the app at all. A header
# configured in a proxy that half the deployments do not run is a header those
# deployments do not have, and nothing anywhere said so.
#
# That is the same shape as the bug TrackerController documents: /t.js was
# corrected in the Caddyfile while production, which had no Caddy, kept serving
# it with a year-long cache header. So this spec asserts against the Rack
# response, deliberately bypassing any proxy, and it is the reason the policy
# lives in an initializer rather than in config/Caddyfile.
RSpec.describe "Security headers", type: :request do
  # An authenticated screen, a public informational page and the unauthenticated
  # shared dashboard, because the three take different layouts and two of them
  # take a different base controller.
  def policy_for(response)
    response.headers["Content-Security-Policy"] ||
      response.headers["Content-Security-Policy-Report-Only"]
  end

  describe "on a public page" do
    before { get "/privacy" }

    it "sends a content security policy" do
      expect(policy_for(response)).to be_present
    end

    it "refuses plugins and a rewritten base URI outright" do
      expect(policy_for(response)).to include("object-src 'none'")
      expect(policy_for(response)).to include("base-uri 'self'")
    end

    it "does not allow inline script" do
      expect(policy_for(response)).not_to include("'unsafe-inline' ")
      expect(policy_for(response)).to match(/script-src [^;]*'nonce-/)
    end

    # A nonce that were stable across responses would be a nonce an attacker who
    # had seen one page already knew. The generated Rails comment suggests the
    # session id, which is exactly that.
    it "issues a fresh nonce per response" do
      first = policy_for(response)[/'nonce-([^']+)'/, 1]
      get "/privacy"
      second = policy_for(response)[/'nonce-([^']+)'/, 1]

      expect(first).to be_present
      expect(second).not_to eq(first)
    end

    it "still carries the framework defaults the Caddyfile also sets" do
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(response.headers["Referrer-Policy"]).to eq("strict-origin-when-cross-origin")
    end
  end

  # The highest-risk page in the application: no session, no account, and it
  # renders strings that arrived from strangers' browsers.
  describe "on a public shared dashboard" do
    let(:site) { create(:site) }
    let!(:link) { create(:shared_link, site: site) }

    it "sends the policy to somebody with no session at all" do
      get "/share/#{link.slug}"

      expect(response).to have_http_status(:ok)
      expect(policy_for(response)).to include("default-src 'self'")
    end
  end

  describe "on an authenticated screen" do
    let(:user) { create(:user) }
    let(:account) { create(:account) }

    before do
      create(:membership, account: account, user: user, role: "owner")
      sign_in user
      get "/account"
    end

    it "sends the policy there too" do
      expect(policy_for(response)).to include("default-src 'self'")
    end

    # The bar fills on every breakdown, funnel and flow panel are inline style
    # ATTRIBUTES, which no nonce can cover. The narrow directive is deliberate
    # and the broad one would be a regression, so both halves are pinned.
    it "admits inline style attributes without admitting inline stylesheets" do
      expect(policy_for(response)).to include("style-src-attr 'unsafe-inline'")
      expect(policy_for(response)).to match(/style-src 'self'\s*(;|\z)/)
    end
  end

  # The one inline script this application writes for itself. If it ever loses
  # its nonce, the value pickers stop having any options and the forms look
  # broken for a reason no Ruby stack trace would explain.
  describe "the inline JSON payloads" do
    let(:user) { create(:user) }
    let(:account) { create(:account) }
    let(:site) { create(:site, account: account) }

    before do
      create(:membership, account: account, user: user, role: "admin")
      sign_in user
    end

    it "nonces the known-values payload" do
      get new_site_goal_path(site)

      nonce = policy_for(response)[/'nonce-([^']+)'/, 1]
      expect(response.body).to include(%(nonce="#{nonce}"))
    end
  end

  # SeoHelper#canonical_url builds an absolute URL from the host that was asked
  # for, deliberately, so a self-hosted install publishes its own domain rather
  # than ours. That is only safe while the Host is constrained.
  #
  # A TEXT SCAN, because the test environment cannot observe this any other way:
  # host authorization is configured in config/environments/production.rb and
  # the suite runs under test.rb, where turning it on would reject every request
  # spec (they all arrive as www.example.com). Booting a second environment to
  # assert three lines is a worse trade than reading them. The same technique,
  # for the same reason, is what spec/privacy_invariants_spec.rb and
  # spec/requests/destructive_buttons_spec.rb already do.
  describe "host authorization" do
    let(:production_config) { Rails.root.join("config/environments/production.rb").read }

    it "constrains the Host in production" do
      expect(production_config).to match(/^\s*config\.hosts\s*=/)
    end

    it "derives the allowlist from APP_HOST rather than hard-coding a domain" do
      expect(production_config).to include("APP_HOST")
    end

    it "excludes the health check, or the first deploy never goes healthy" do
      expect(production_config).to match(/host_authorization\s*=\s*\{\s*exclude:.*"\/up"/m)
    end

    # An instance with no APP_HOST is misconfigured and loud about it, but it is
    # still reachable — which is what lets somebody finish setting it up. If this
    # ever became unconditional, a first deploy would 403 its own operator.
    it "leaves the allowlist empty rather than locking out an unconfigured instance" do
      expect(production_config).to match(/app_host \? \[.*\] : \[\]/)
    end
  end

  # CORS. The wildcard belongs to ingest, where the site token is public by
  # construction, and to nothing else — least of all to the endpoint that writes
  # identifiable people behind an API key.
  describe "cross-origin grants" do
    it "allows any origin on the ingest endpoint" do
      post "/api/event",
           params: { s: "nope", u: "https://example.com/" }.to_json,
           headers: { "CONTENT_TYPE" => "text/plain", "HTTP_ORIGIN" => "https://stranger.example" }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "grants nothing to a stranger's origin on the authenticated API" do
      post "/api/v1/identify",
           params: {}.to_json,
           headers: { "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "https://stranger.example" }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end
end
