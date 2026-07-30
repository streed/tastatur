require "rails_helper"

# The site token is public: it sits in the HTML of every page it measures, so
# anyone can read it and POST events with it. That is inherent to client-side
# analytics and cannot be closed. These examples pin down what IS achieved.
RSpec.describe Ingest::HostnamePolicy do
  let(:site) { create(:site, domain: "example.com") }

  def policy(host, origin: nil, for_site: site)
    described_class.new(site: for_site, url_host: host, origin: origin).call
  end

  describe "hostnames that belong to the site" do
    it "accepts the domain itself" do
      expect(policy("example.com")).to be_allowed
    end

    it "accepts the www form" do
      expect(policy("www.example.com")).to be_allowed
    end

    # Accepted without configuration because app./blog./docs./shop. is how real
    # sites are laid out, and a policy that rejected them would be switched off
    # by everyone on day one.
    it "accepts subdomains" do
      %w[app.example.com blog.example.com docs.example.com deep.nested.example.com]
        .each { |host| expect(policy(host)).to be_allowed, "#{host} was rejected" }
    end

    it "ignores case, port and a trailing dot" do
      ["EXAMPLE.COM", "example.com:3000", "example.com."]
        .each { |host| expect(policy(host)).to be_allowed, "#{host} was rejected" }
    end
  end

  describe "hostnames that do not" do
    it "rejects an unrelated domain" do
      result = policy("attacker.example.net")

      expect(result).not_to be_allowed
      expect(result.reason).to eq(:hostname_mismatch)
    end

    # The bug this whole class exists for: before it, this stored a row against
    # the victim's site under the attacker's hostname, polluting every breakdown.
    it "rejects a domain that merely ends with the site's name" do
      expect(policy("notexample.com")).not_to be_allowed
      expect(policy("example.com.evil.net")).not_to be_allowed
    end

    it "rejects a blank host" do
      expect(policy(nil)).not_to be_allowed
      expect(policy("")).not_to be_allowed
    end
  end

  describe "extra hostnames" do
    let(:site) { create(:site, domain: "example.com", extra_hostnames: ["example.de", "shop.example.org"]) }

    it "accepts a genuinely separate domain once declared" do
      expect(policy("example.de")).to be_allowed
    end

    it "accepts subdomains of a declared domain" do
      expect(policy("www.example.de")).to be_allowed
    end

    it "still rejects anything undeclared" do
      expect(policy("example.fr")).not_to be_allowed
    end
  end

  describe "the Origin header" do
    # A browser sets Origin on a cross-origin POST and JavaScript cannot forge
    # it, so a present-and-wrong Origin is strong evidence the snippet was pasted
    # onto someone else's site.
    it "rejects a mismatched Origin even when the URL claims the right domain" do
      result = policy("example.com", origin: "https://thief.example.net")

      expect(result).not_to be_allowed
      expect(result.reason).to eq(:origin_mismatch)
    end

    it "reports the OFFENDING origin, not the victim's own domain" do
      # Recording the URL host here would show the owner their own hostname in
      # the refused list, which tells them nothing.
      expect(policy("example.com", origin: "https://thief.example.net").offending_host)
        .to eq("thief.example.net")
    end

    it "accepts a matching Origin" do
      expect(policy("example.com", origin: "https://example.com")).to be_allowed
      expect(policy("example.com", origin: "https://www.example.com")).to be_allowed
      expect(policy("app.example.com", origin: "https://app.example.com")).to be_allowed
    end

    # curl and the documented server-side API send no Origin, and that has to
    # keep working, which is why only a PRESENT mismatch is rejected.
    it "allows a missing Origin" do
      expect(policy("example.com", origin: nil)).to be_allowed
      expect(policy("example.com", origin: "")).to be_allowed
    end

    # A sandboxed iframe or a file:// page sends the literal string "null",
    # which carries no information.
    it "treats an opaque origin as absent" do
      expect(policy("example.com", origin: "null")).to be_allowed
    end

    it "treats an unparseable Origin as absent rather than raising" do
      expect { policy("example.com", origin: "://nonsense") }.not_to raise_error
    end
  end

  describe "when enforcement is disabled for a site" do
    let(:site) { create(:site, domain: "example.com", enforce_hostname: false) }

    it "allows anything, so an owner with an exotic setup is not stuck" do
      expect(policy("attacker.example.net")).to be_allowed
      expect(policy("example.com", origin: "https://thief.example.net")).to be_allowed
    end
  end
end

RSpec.describe "Ingest hostname enforcement", type: :request do
  let(:site) { create(:site, domain: "measured.example.com") }
  let(:chrome) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0" }

  before do
    delete_all_events
    Ingest::WriteBuffer.clear!
    Ingest::RejectionCounter.prune!(site)
  end

  def post_event(url, origin: nil)
    headers = { "CONTENT_TYPE" => "text/plain", "HTTP_USER_AGENT" => chrome }
    headers["HTTP_ORIGIN"] = origin if origin
    post "/api/event", params: { s: site.public_token, u: url }.to_json, headers: headers
    Ingest::WriteBuffer.flush!
  end

  it "stores an event for the site's own domain" do
    post_event "https://measured.example.com/pricing"
    expect(Event.count).to eq(1)
  end

  it "stores an event for a subdomain" do
    post_event "https://app.measured.example.com/dashboard"
    expect(Event.count).to eq(1)
  end

  it "does not store an event claiming someone else's hostname" do
    post_event "https://attacker.example.net/spam"

    expect(response).to have_http_status(:accepted), "must stay quiet, not 4xx into a console"
    expect(Event.count).to eq(0)
  end

  it "does not store an event whose Origin belongs to someone else" do
    post_event "https://measured.example.com/pricing", origin: "https://thief.example.net"
    expect(Event.count).to eq(0)
  end

  describe "the rejection is visible to the owner" do
    it "counts a hostname mismatch and names the host" do
      post_event "https://attacker.example.net/spam"

      expect(site.rejection_counts[:hostname_mismatch]).to eq(1)
      expect(site.rejected_hostnames.map(&:first)).to include("attacker.example.net")
    end

    it "counts an origin mismatch and names the origin" do
      post_event "https://measured.example.com/x", origin: "https://thief.example.net"

      expect(site.rejection_counts[:origin_mismatch]).to eq(1)
      expect(site.rejected_hostnames.map(&:first)).to include("thief.example.net")
    end

    # Recording who was rejected would reintroduce exactly the tracking this
    # product avoids, and doing it for traffic we are refusing would be perverse.
    it "records no visitor identifier for a rejected event" do
      post_event "https://attacker.example.net/spam"

      keys = REDIS_POOL.with { |r| r.keys("tastatur:rejected*") }
      expect(keys).to be_present
      expect(keys.join).not_to match(/visitor|session/)
    end
  end
end
