require "rails_helper"

# The marketing page and the docs answer `Accept: text/markdown` with a
# markdown rendering of the same content, for LLM agents and AI crawlers that
# read pages as text. Two things are worth pinning beyond "it responds": that
# the negotiation never takes HTML away from a browser, and that the code
# snippets arrive unescaped — ERB's HTML escaping would turn `<script>` into
# `&lt;script&gt;` inside a fenced code block, which corrupts the one thing an
# agent comes to the docs for (see config/initializers/mime_types.rb).
RSpec.describe "Markdown for machine readers", type: :request do
  describe "the marketing page" do
    it "serves markdown when the request asks for it" do
      get "/", headers: { "Accept" => "text/markdown" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
      expect(response.body).to include("# Tastatur")
      expect(response.body).not_to include("<div")
    end

    it "prefers markdown when the agent ranks it above HTML" do
      get "/", headers: { "Accept" => "text/markdown;q=1.0, text/html;q=0.8" }

      expect(response.media_type).to eq("text/markdown")
    end

    it "still serves HTML to a browser" do
      get "/", headers: { "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }

      expect(response.media_type).to eq("text/html")
    end

    it "still sends a signed-in user to their sites" do
      sign_in create(:user)

      get "/", headers: { "Accept" => "text/markdown" }

      expect(response).to redirect_to("/sites")
    end

    it "points the reader at the markdown docs" do
      get "/", headers: { "Accept" => "text/markdown" }

      expect(response.body).to include("/docs.md")
    end
  end

  describe "the docs" do
    it "serves markdown for Accept: text/markdown" do
      get "/docs", headers: { "Accept" => "text/markdown" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
    end

    it "serves markdown at /docs.md" do
      get "/docs.md"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
    end

    it "keeps code snippets unescaped" do
      get "/docs.md"

      expect(response.body).to include(%(<script defer data-site="YOUR_SITE_KEY"))
      expect(response.body).not_to include("&lt;script")
      expect(response.body).not_to include("&quot;")
    end

    it "fills in a signed-in user's real site key, like the HTML docs do" do
      user = create(:user)
      account = create(:account)
      create(:membership, account: account, user: user, role: "owner")
      site = create(:site, account: account)
      sign_in user

      get "/docs.md"

      expect(response.body).to include(site.public_token)
      expect(response.body).not_to include("YOUR_SITE_KEY")
    end
  end

  describe "llms.txt" do
    it "serves the index at the well-known path" do
      get "/llms.txt"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
      expect(response.body.lines.first).to start_with("# Tastatur")
    end

    it "is markdown even when the agent asks for HTML, because the path already chose" do
      get "/llms.txt", headers: { "Accept" => "text/html" }

      expect(response.media_type).to eq("text/markdown")
    end

    it "links the markdown-native pages absolutely, on the host that was asked" do
      get "/llms.txt"

      expect(response.body).to include("http://www.example.com/index.md")
      expect(response.body).to include("http://www.example.com/docs.md")
    end

    # The pricing page redirects away wherever billing is off, so an index that
    # listed it there would point an agent at a bounce. The suite's Stripe
    # support configures dummy keys, so billing is ON by default here and the
    # self-hosted shape is the one that needs stubbing.
    it "omits pricing where there is nothing to buy" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      get "/llms.txt"

      expect(response.body).not_to include("/pricing")
    end

    it "lists pricing when billing is enabled" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(true)

      get "/llms.txt"

      expect(response.body).to include("http://www.example.com/pricing")
    end

    it "stays reachable before first-run setup, like the other public documents" do
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(true)

      get "/llms.txt"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the marketing page at /index.md" do
    it "serves the same markdown the Accept header gets" do
      get "/index.md"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
      expect(response.body).to include("# Tastatur — cookieless web analytics")
    end
  end

  it "answers a format nobody offers with 406, not a 500" do
    get "/docs", headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:not_acceptable)
  end
end
