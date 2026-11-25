require "rails_helper"

# Connecting an AI agent is open to EVERY member of the organisation, and the key
# covers the whole account. That is only safe because of three things asserted here:
# the key can only read, it is bound to the member who made it, and a member sees
# nobody else's.
RSpec.describe "Connecting an AI agent", type: :request do
  # Pro, because a Free account is limited to one site and these tests want several.
  let(:account) { create(:account, plan: "pro") }
  let!(:site) { create(:site, account: account) }

  def member(role, of: account)
    create(:user).tap { |user| create(:membership, account: of, user: user, role: role) }
  end

  def rpc(token, method: "tools/list", params: nil)
    body = { jsonrpc: "2.0", id: 1, method: method }
    body[:params] = params if params
    post "/mcp", params: body.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
  end

  %w[viewer member admin owner].each do |role|
    describe "as a #{role}" do
      let(:person) { member(role) }

      before { sign_in person }

      it "can open the page and sees the instructions" do
        get account_mcp_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("#{Tastatur.base_url}/mcp")
      end

      it "can make a key that reads, owned by them, on the account, and uses it" do
        post account_mcp_keys_path, params: { api_key: { name: "claude" } }

        key = account.api_keys.sole
        expect(key.scopes).to eq(["read:analytics"])
        expect(key.user).to eq(person)
        expect(key.site).to be_nil

        rpc(flash[:api_key])
        expect(response).to have_http_status(:ok)
      end
    end
  end

  it "makes ONE key that reads every site in the account" do
    second = create(:site, account: account)
    create_event(site, path: "/a", visitor: "a", at: 1.day.ago)
    create_event(second, path: "/b", visitor: "b", at: 1.day.ago)
    sign_in member("viewer")
    post account_mcp_keys_path, params: { api_key: { name: "claude" } }
    token = flash[:api_key]

    [site, second].each do |each_site|
      rpc(token, method: "tools/call", params: { name: "get_summary", arguments: { site: each_site.domain, period: "7d" } })
      expect(response.parsed_body.dig("result", "structuredContent", "data", "metrics", "visitors")).to eq(1)
    end
  end

  describe "the boundaries" do
    let(:viewer) { member("viewer") }

    before { sign_in viewer }

    it "cannot choose a different permission by asking for one" do
      post account_mcp_keys_path, params: { api_key: { name: "x", scope: "write:identify", scopes: ["write:identify"] } }

      expect(account.api_keys.sole.scopes).to eq(["read:analytics"])
    end

    it "still cannot make an identify key, which stays admin-only" do
      post site_api_keys_path(site), params: { api_key: { name: "x" } }

      expect(site.api_keys).to be_empty
    end

    it "still cannot open the admin API keys screen" do
      get site_api_keys_path(site)

      expect(response.body).not_to include("Existing keys")
    end

    it "sees and can revoke only their own keys" do
      mine = create(:api_key, :reader, account: account, user: viewer, name: "mine")
      theirs = create(:api_key, :reader, account: account, name: "theirs")

      get account_mcp_path
      expect(response.body).to include("mine")
      expect(response.body).not_to include("theirs")

      delete account_mcp_key_path(theirs)
      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).not_to be_revoked

      delete account_mcp_key_path(mine)
      expect(mine.reload).to be_revoked
    end

    it "never sees or reaches a key belonging to another account" do
      foreign = create(:api_key, :reader, name: "foreign")

      get account_mcp_path
      expect(response.body).not_to include("foreign")

      delete account_mcp_key_path(foreign)
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).not_to be_revoked
    end
  end

  describe "a person in two accounts" do
    it "makes the key in the account they are viewing, and it reads only that one" do
      person = member("viewer")
      other = create(:account, plan: "pro")
      create(:membership, account: other, user: person, role: "viewer")
      other_site = create(:site, account: other)
      sign_in person

      post account_mcp_keys_path(account_slug: other.slug), params: { api_key: { name: "claude" } }
      expect(other.api_keys.count).to eq(1)
      expect(account.api_keys).to be_empty

      rpc(flash[:api_key], method: "tools/call", params: { name: "list_sites", arguments: {} })
      domains = response.parsed_body.dig("result", "structuredContent", "data", "sites").map { |s| s["domain"] }
      expect(domains).to eq([other_site.domain])
    end
  end

  it "lets an admin see and revoke everybody's agent keys" do
    sign_in member("admin")
    other = create(:api_key, :reader, account: account, name: "somebody-elses")

    get account_mcp_path
    expect(response.body).to include("somebody-elses")

    delete account_mcp_key_path(other)
    expect(other.reload).to be_revoked
  end

  it "keeps an agent key out of the identify endpoint, like any other read key" do
    sign_in member("admin")
    post account_mcp_keys_path, params: { api_key: { name: "claude" } }

    post "/api/v1/identify", params: { external_id: "u1" }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{flash[:api_key]}" }

    expect(response).to have_http_status(:forbidden)
  end

  describe "when the member who made the key leaves the organisation" do
    it "stops working at once, with the same 401 as any bad key" do
      key = create(:api_key, :reader, account: account)

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

    expect(response.body).to include(account_mcp_path)
    expect(response.body).not_to include(edit_site_path(site))
  end

  it "points the account page at the setup page" do
    sign_in member("viewer")

    get account_path

    expect(response.body).to include(account_mcp_path)
  end
end
