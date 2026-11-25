require "rails_helper"

# Connecting an AI agent is open to EVERY member of the organisation, which is only
# safe because of three things asserted here: the key can only read, it is bound to
# the member who made it, and a member sees nobody else's.
RSpec.describe "Connecting an AI agent", type: :request do
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account) }

  def member(role)
    create(:user).tap { |user| create(:membership, account: account, user: user, role: role) }
  end

  def rpc(token)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
  end

  %w[viewer member admin owner].each do |role|
    describe "as a #{role}" do
      before { sign_in member(role) }

      it "can open the page and sees the instructions" do
        get site_mcp_path(site)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("#{Tastatur.base_url}/mcp")
      end

      it "can make a key that reads, owned by them, and uses it" do
        post site_mcp_keys_path(site), params: { api_key: { name: "claude" } }

        key = site.api_keys.sole
        expect(key.scopes).to eq(["read:analytics"])
        expect(key.user).to eq(controller.current_user)

        rpc(flash[:api_key])
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "the boundaries" do
    let(:viewer) { member("viewer") }

    before { sign_in viewer }

    it "cannot choose a different permission by asking for one" do
      post site_mcp_keys_path(site), params: { api_key: { name: "x", scope: "write:identify", scopes: ["write:identify"] } }

      expect(site.api_keys.sole.scopes).to eq(["read:analytics"])
    end

    it "still cannot make an identify key, which stays admin-only" do
      post site_api_keys_path(site), params: { api_key: { name: "x", scope: "write:identify" } }

      expect(site.api_keys).to be_empty
    end

    it "still cannot open the admin API keys screen" do
      get site_api_keys_path(site)

      expect(response.body).not_to include("Existing keys")
    end

    it "sees and can revoke only their own keys" do
      mine = create(:api_key, :reader, site: site, user: viewer, name: "mine")
      theirs = create(:api_key, :reader, site: site, name: "theirs")

      get site_mcp_path(site)
      expect(response.body).to include("mine")
      expect(response.body).not_to include("theirs")

      delete site_mcp_key_path(site, theirs)
      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).not_to be_revoked

      delete site_mcp_key_path(site, mine)
      expect(mine.reload).to be_revoked
    end

    it "gets a 404 for a site in another organisation" do
      get site_mcp_path(create(:site))

      expect(response).to have_http_status(:not_found)
    end
  end

  it "lets an admin see and revoke everybody's agent keys" do
    sign_in member("admin")
    other = create(:api_key, :reader, site: site, name: "somebody-elses")

    get site_mcp_path(site)
    expect(response.body).to include("somebody-elses")

    delete site_mcp_key_path(site, other)
    expect(other.reload).to be_revoked
  end

  it "keeps an admin's agent key out of the identify endpoint, like any other read key" do
    admin = member("admin")
    sign_in admin
    post site_mcp_keys_path(site), params: { api_key: { name: "claude" } }

    post "/api/v1/identify", params: { external_id: "u1" }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{flash[:api_key]}" }

    expect(response).to have_http_status(:forbidden)
  end

  describe "when the member who made the key leaves the organisation" do
    it "stops working at once, with the same 401 as any bad key" do
      key = create(:api_key, :reader, site: site)

      rpc(key.plaintext)
      expect(response).to have_http_status(:ok)

      Membership.find_by!(user: key.user, account: account).destroy
      rpc(key.plaintext)

      expect(response).to have_http_status(:unauthorized)
    end

    it "does not touch an identify key, which belongs to a deployment" do
      key = create(:api_key, site: site)

      post "/api/v1/identify", params: { external_id: "u1" }.to_json,
           headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.plaintext}" }

      expect(response).to have_http_status(:ok)
    end
  end

  it "shows the link on the dashboard to a viewer, who cannot see Settings" do
    sign_in member("viewer")

    get site_path(site)

    expect(response.body).to include(site_mcp_path(site))
    expect(response.body).not_to include(edit_site_path(site))
  end
end
