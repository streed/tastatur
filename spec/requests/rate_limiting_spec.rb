require "rails_helper"

# Rate limiting is the last line of defence against metric poisoning. Hostname
# validation forces an attacker to claim the site's real domain and the Origin
# check catches a copied snippet, but a scripted attacker sends no Origin at all,
# so for them the limits are all that remain. A limit that quietly does not hold
# is worse than none, because it is a control the docs claim and the system does
# not have.
RSpec.describe "Rate limiting", :throttled, type: :request do
  let(:site) { create(:site, domain: "measured.example.com") }
  let(:chrome) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0" }

  before do
    delete_all_events
    Ingest::WriteBuffer.clear!
  end

  def post_event(path, ip: "203.0.113.10")
    post "/api/event",
         params: { s: site.public_token, u: "https://measured.example.com#{path}" }.to_json,
         headers: { "CONTENT_TYPE" => "text/plain", "HTTP_USER_AGENT" => chrome,
                    "REMOTE_ADDR" => ip }
  end

  # The counters have to be shared across processes and replicas or the limit is
  # multiplied by however many are running. Rack::Attack defaults to Rails.cache,
  # which in production is a per-container FileStore.
  it "keeps throttle counters in a store shared across processes" do
    expect(Rack::Attack.cache.store.class.name).to match(/Redis/)
  end

  describe "the per-(site, client) ingest limit" do
    it "stops storing past the limit while still answering 202" do
      statuses = 130.times.map { |i| post_event("/flood-#{i}"); response.status }
      Ingest::WriteBuffer.flush!

      # Never 429 on ingest: a beacon cannot react to it, and an error in a
      # stranger's console on a customer's site is noise they cannot act on.
      expect(statuses.uniq).to eq([202])
      expect(Event.count).to eq(120)
    end

    it "does not let one client's flood block another client" do
      130.times { |i| post_event("/flood-#{i}", ip: "203.0.113.10") }
      post_event("/legitimate", ip: "198.51.100.7")
      Ingest::WriteBuffer.flush!

      expect(Event.where(path: "/legitimate").count).to eq(1)
    end
  end

  describe "the dashboard" do
    # A 429 is correct here: a human can read it and retry, unlike a beacon.
    it "returns 429 rather than a silent 202" do
      301.times { get "/privacy" }
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to be_present
    end
  end

  describe "credential endpoints" do
    it "throttles sign-in attempts" do
      6.times do
        post "/users/sign_in", params: { user: { email: "victim@example.test", password: "wrong" } }
      end
      expect(response).to have_http_status(:too_many_requests)
    end

    # A throttle whose path does not match the route it means to guard fails
    # silently: nothing raises, nothing logs, and the endpoint is simply
    # unprotected. Both of these are typed by hand in the initializer and neither
    # is exercised anywhere else, which makes them exactly the kind of thing to
    # pin.
    #
    # TwoFactor::VerifyChallenge already destroys a code after five wrong
    # guesses; this is what stops somebody buying a fresh code every five guesses
    # and grinding a six-digit keyspace indefinitely.
    it "throttles guesses at a two-factor code" do
      16.times { post "/two-factor", params: { two_factor_challenge: { code: "000000" } } }

      expect(response).to have_http_status(:too_many_requests)
    end

    # The resend button sends mail to an address the caller named, so without a
    # limit it is a free way to make this instance deliver mail at whatever rate
    # a script likes — which burns the sending domain's reputation.
    it "throttles requests for a new two-factor code" do
      6.times { post "/two-factor/resend" }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  # The whole point of hashing: a stock configuration writes every visitor's IP
  # into Redis for the length of the window, which is exactly what the rest of
  # this codebase avoids.
  describe "the throttle key" do
    it "contains no raw IP address" do
      post_event("/x", ip: "203.0.113.99")

      keys = REDIS_POOL.with { |r| r.keys("rack_attack*") }
      expect(keys).to be_present
      expect(keys.join).not_to include("203.0.113.99")
    end
  end
end
