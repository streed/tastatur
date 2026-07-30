require "rails_helper"

# The tracking script, served by the application rather than from public/.
#
# It moved because ActionDispatch::Static stamps everything it serves with
# `config.public_file_server.headers`, which in production is max-age=31556952.
# One year, on a file whose name carries no digest and whose path is baked into
# every customer's HTML — so a fix to the tracker would not reach returning
# visitors for a year. config/Caddyfile corrected it for the compose deployment,
# but Railway has no Caddy and the year-long header is what actually shipped.
RSpec.describe "GET /t.js", type: :request do
  it "serves the tracker" do
    get "/t.js"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/javascript")
    expect(response.body).to include("Tastatur")
    expect(response.body).to eq(Rails.root.join("lib/tracker/t.js").read)
  end

  describe "caching" do
    it "is cacheable for an hour, not a year" do
      get "/t.js"

      cache = response.headers["Cache-Control"]
      expect(cache).to include("public")
      expect(cache).to include("max-age=3600")
      expect(cache).not_to include("31556952")
    end

    # The short window is the only invalidation lever there is, so
    # stale-while-revalidate is what keeps that from costing page speed: the
    # visitor still gets an instant cached response and the refresh happens out
    # of band.
    it "revalidates out of band rather than blocking" do
      get "/t.js"

      expect(response.headers["Cache-Control"]).to include("stale-while-revalidate=86400")
    end

    it "answers a conditional request with 304" do
      get "/t.js"
      etag = response.headers["ETag"]

      get "/t.js", headers: { "HTTP_IF_NONE_MATCH" => etag }

      expect(response).to have_http_status(:not_modified)
    end
  end

  # THE ONE THAT NEARLY SHIPPED BROKEN.
  #
  # Rails guards against a cross-origin <script src> reading a JavaScript
  # response, since for a normal app that response can carry per-session data.
  # This endpoint is embedded by <script src> on every customer's site and is
  # cross-origin by definition, so the check refused it with:
  #
  #   Security warning: an embedded <script> tag on another site requested
  #   protected JavaScript.
  #
  # A static file in public/ was never subject to that, which is why the failure
  # appeared only once the file moved — and why it would have broken every
  # installation at once rather than showing up in development.
  it "serves a cross-origin embed, which is how every customer loads it" do
    get "/t.js", headers: {
      "HTTP_REFERER" => "https://somecustomer.example.com/pricing",
      "HTTP_SEC_FETCH_SITE" => "cross-site",
      "HTTP_SEC_FETCH_DEST" => "script",
      "HTTP_SEC_FETCH_MODE" => "no-cors"
    }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/javascript")
    expect(response.body).to eq(Rails.root.join("lib/tracker/t.js").read)
    expect(response.body).not_to include("Security warning")
  end

  # ActionDispatch::Static runs before the router. If the file is ever moved back
  # into public/, the static server answers first and silently restores the
  # year-long cache header, with every test above still passing.
  it "is not in public/, where the static server would shadow this route" do
    expect(Rails.root.join("public/t.js")).not_to exist
    expect(Rails.root.join("lib/tracker/t.js")).to exist
  end

  # The measurement script has to run wherever the visitors are. ApplicationController
  # applies `allow_browser versions: :modern`, which would refuse exactly the older
  # browsers whose visits a customer is trying to count.
  it "does not inherit the modern-browser gate" do
    expect(TrackerController.ancestors).not_to include(ApplicationController)
  end

  it "is reachable without a session" do
    get "/t.js"

    expect(response).to have_http_status(:ok)
  end
end
