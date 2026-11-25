require "rails_helper"

RSpec.describe "POST /mcp", type: :request do
  let(:site) { create(:site, timezone: "Etc/UTC") }
  let!(:api_key) { create(:api_key, :reader, account: site.account) }

  def rpc(method, params = nil, id: 1, token: api_key.plaintext)
    body = { jsonrpc: "2.0", id: id, method: method }
    body[:params] = params if params
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token
    post "/mcp", params: body.to_json, headers: headers
  end

  def call_tool(name, arguments = {}, **opts) = rpc("tools/call", { name: name, arguments: arguments }, **opts)

  def result = response.parsed_body.fetch("result")
  def payload = result.fetch("structuredContent")

  describe "authentication and scope" do
    it "refuses a missing key" do
      rpc("tools/list", token: nil)
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a key that can only write identity, and says which permission is missing" do
      writer = create(:api_key, site: site)
      rpc("tools/list", token: writer.plaintext)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["message"]).to include("read:analytics")
    end

    it "keeps a read-only key out of the identify endpoint" do
      post "/api/v1/identify", params: { external_id: "u1" }.to_json,
           headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key.plaintext}" }

      expect(response).to have_http_status(:forbidden)
      expect(site.customers).to be_empty
    end

    it "refuses a revoked key" do
      api_key.revoke!
      rpc("tools/list")
      expect(response).to have_http_status(:unauthorized)
    end

    it "declines GET, because there is no server-initiated stream" do
      get "/mcp", headers: { "Authorization" => "Bearer #{api_key.plaintext}" }
      expect(response).to have_http_status(:method_not_allowed)
    end
  end

  describe "protocol" do
    it "negotiates a supported protocol version" do
      rpc("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "t", version: "1" } })

      expect(result["protocolVersion"]).to eq("2025-03-26")
      expect(result["capabilities"]).to include("tools")
    end

    it "answers a notification with 202 and no body" do
      post "/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
           headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key.plaintext}" }

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it "rejects a batch" do
      post "/mcp", params: [{ jsonrpc: "2.0", id: 1, method: "ping" }].to_json,
           headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key.plaintext}" }

      expect(response.parsed_body.dig("error", "code")).to eq(-32_600)
    end

    it "reports unparseable JSON as a parse error" do
      post "/mcp", params: "{nope", headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key.plaintext}" }
      expect(response).to have_http_status(:bad_request)
    end

    it "lists every read tool, each declared read-only" do
      rpc("tools/list")
      tools = result["tools"]

      expect(tools.map { |t| t["name"] }).to include("list_sites", "describe_site", "get_summary", "get_timeseries",
                                                      "get_breakdown", "get_goals", "get_funnel", "get_campaigns")
      expect(tools).to all(satisfy { |t| t.dig("annotations", "readOnlyHint") == true })
    end

    it "treats an unknown tool as a protocol error" do
      call_tool("drop_tables")
      expect(response.parsed_body.dig("error", "code")).to eq(-32_602)
    end
  end

  describe "argument validation" do
    it "returns bad arguments as a tool error the model can read" do
      call_tool("get_summary", { period: "last_week" })

      expect(result["isError"]).to be(true)
      expect(result["content"].first["text"]).to include("period")
    end

    it "refuses a misspelt filter rather than silently running unfiltered" do
      call_tool("get_summary", { filters: { contry: "DE" } })

      expect(result["isError"]).to be(true)
      expect(result["content"].first["text"]).to include("contry")
    end

    it "refuses an unknown argument" do
      call_tool("get_summary", { perid: "7d" })
      expect(result["isError"]).to be(true)
    end

    it "does not reach a site in another account, and does not say whether it exists" do
      other = create(:site)
      call_tool("get_summary", { site: other.public_token })

      expect(result["isError"]).to be(true)
      expect(result["content"].first["text"]).to include("not one of this account's sites")
      expect(result["content"].first["text"]).not_to include(other.domain)
    end
  end

  describe "an account with several sites" do
    # Pro, because a Free account is limited to one site.
    let(:site) { create(:site, account: create(:account, plan: "pro"), timezone: "Etc/UTC") }
    let!(:second) { create(:site, account: site.account, timezone: "Etc/UTC") }

    before do
      create_event(site, path: "/a", visitor: "a", session: "a", at: 1.day.ago)
      create_event(second, path: "/b", visitor: "b1", session: "b1", at: 1.day.ago)
      create_event(second, path: "/b", visitor: "b2", session: "b2", at: 1.day.ago)
    end

    it "lists the account's sites, and only those" do
      stranger = create(:site)
      call_tool("list_sites")

      domains = payload["data"]["sites"].map { |s| s["domain"] }
      expect(domains).to contain_exactly(site.domain, second.domain)
      expect(response.body).not_to include(stranger.domain)
    end

    it "asks which site when none is given, naming the choices" do
      call_tool("get_summary", { period: "7d" })

      expect(result["isError"]).to be(true)
      expect(result["content"].first["text"]).to include(site.domain, second.domain)
    end

    it "answers for the site named by domain, case-insensitively" do
      call_tool("get_summary", { site: second.domain.upcase, period: "7d" })

      expect(payload["data"]["metrics"]["visitors"]).to eq(2)
    end

    it "answers for the site named by token" do
      call_tool("get_summary", { site: site.public_token, period: "7d" })

      expect(payload["data"]["metrics"]["visitors"]).to eq(1)
    end

    it "keeps one site's funnel out of another's report" do
      funnel = create(:funnel, site: second)
      call_tool("get_funnel", { site: site.domain, funnel_id: funnel.public_id })

      expect(result["isError"]).to be(true)
    end
  end

  describe "a site with no data" do
    it "answers goals and timeseries with empty lists rather than failing" do
      call_tool("get_goals")
      expect(payload["data"]["goals"]).to eq([])
      expect(payload["notes"].join).to include("no goals")

      call_tool("get_breakdown", { dimension: "page" })
      expect(payload["data"]["rows"]).to eq([])
    end
  end

  describe "tools" do
    before do
      base = 2.days.ago.change(hour: 12)
      create_event(site, path: "/pricing", visitor: "a", session: "a", at: base, country_code: "DE")
      create_event(site, path: "/signup", visitor: "a", session: "a", at: base + 1.minute, country_code: "DE")
      (1..40).each { |n| create_event(site, path: "/", visitor: "v#{n}", session: "v#{n}", at: base + n.minutes, country_code: "US") }
    end

    it "describes the site, its goals and its funnels" do
      goal = create(:goal, site: site)
      funnel = create(:funnel, site: site)
      call_tool("describe_site")

      expect(payload["data"]["site"]["timezone"]).to eq("Etc/UTC")
      expect(payload["data"]["goals"].map { |g| g["id"] }).to eq([goal.public_id])
      expect(payload["data"]["funnels"].map { |f| f["id"] }).to eq([funnel.public_id])
    end

    it "summarises traffic with the comparison" do
      call_tool("get_summary", { period: "7d" })
      data = payload["data"]

      expect(data["metrics"]["visitors"]).to eq(41)
      expect(data["metrics"]["pageviews"]).to eq(42)
      expect(data).to have_key("previous_period")
    end

    it "applies a filter" do
      call_tool("get_summary", { period: "7d", filters: { country: "DE" } })
      expect(payload["data"]["metrics"]["visitors"]).to eq(1)
    end

    it "returns a timeseries with its non-additivity caveat" do
      call_tool("get_timeseries", { period: "7d" })

      expect(payload["data"]["points"].size).to eq(7)
      expect(payload["notes"].join).to include("Do not add")
    end

    it "withholds small rows, and the smallest kept one with them, without naming either" do
      # DE has one visitor, below the threshold of 25. Withheld alone, its count
      # would be total - sum(visible), so the next smallest row goes with it.
      base = 2.days.ago.change(hour: 12)
      (1..30).each { |n| create_event(site, path: "/", visitor: "f#{n}", session: "f#{n}", at: base + n.minutes, country_code: "FR") }

      call_tool("get_breakdown", { dimension: "country", period: "7d" })
      data = payload["data"]

      expect(data["rows"].map { |r| r["value"] }).to eq(["US"])
      expect(data["withheld"]["rows"]).to eq(2)
      expect(data["withheld"]["visitors"]).to eq(31)
      expect(response.body).not_to include("DE", "FR")
    end

    it "reports goal conversions" do
      create(:goal, site: site, match_value: "/signup")
      call_tool("get_goals", { period: "7d" })

      expect(payload["data"]["goals"].first["conversions"]).to eq(1)
    end

    it "reports a funnel" do
      funnel = create(:funnel, site: site, steps: [{ name: "Pricing", match_value: "/pricing" }, { name: "Signup", match_value: "/signup" }])
      call_tool("get_funnel", { funnel_id: funnel.public_id, period: "7d" })

      expect(payload["data"]["steps"].map { |s| s["visitors"] }).to eq([1, 1])
    end

    it "cannot reach another site's funnel" do
      foreign = create(:funnel, site: create(:site))
      call_tool("get_funnel", { funnel_id: foreign.public_id })

      expect(result["isError"]).to be(true)
      expect(result["content"].first["text"]).to include("No funnel")
    end

    it "reports campaigns" do
      call_tool("get_campaigns", { period: "7d" })
      expect(payload["data"]).to include("campaigns", "links", "withheld")
    end

    it "reports revenue attribution when revenue is enabled" do
      allow(Tastatur).to receive(:revenue_enabled?).and_return(true)
      call_tool("get_revenue_attribution", { period: "30d" })

      expect(payload["data"]).to include("channels", "totals")
    end

    it "neither lists nor serves revenue attribution when revenue is not enabled" do
      allow(Tastatur).to receive(:revenue_enabled?).and_return(false)

      rpc("tools/list")
      expect(result["tools"].map { |t| t["name"] }).not_to include("get_revenue_attribution")

      call_tool("get_revenue_attribution")
      expect(response.parsed_body.dig("error", "code")).to eq(-32_602)
    end
  end
end
