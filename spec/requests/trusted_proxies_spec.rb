require "rails_helper"

# Which address out of the forwarding chain becomes the visitor.
#
# This is not a formatting detail. `request.remote_ip` feeds the country lookup
# AND `Ingest::Identifier`, which mixes it into the visitor HMAC — so picking a
# proxy's address does not merely mislabel a country, it gives every visitor
# behind that proxy the SAME identity, on a product whose whole job is counting
# distinct people.
#
# Rails' stock trusted list is loopback plus the RFC 1918 ranges, and it takes the
# right-most address not in it. Cloudflare's edge is a public address, so out of
# the box a Cloudflare-fronted deployment resolves every request to Cloudflare.
RSpec.describe "Trusted proxies" do
  # A real routable address (Canada), so the assertion is about the resolution and
  # not about a documentation range that has no country either way.
  let(:client) { "24.48.0.1" }
  let(:cloudflare) { "172.71.150.22" }

  # Resolves a chain through the real middleware against a given trusted list.
  def resolve(remote_addr:, forwarded_for: nil, trusted: TrustedProxies.list)
    env = Rack::MockRequest.env_for("https://tastatur.dev/api/event")
    env["REMOTE_ADDR"] = remote_addr
    env["HTTP_X_FORWARDED_FOR"] = forwarded_for if forwarded_for
    ActionDispatch::RemoteIp.new(->(_e) { [200, {}, []] }, true, trusted).call(env)
    ActionDispatch::Request.new(env).remote_ip
  end

  describe "without any deployment-specific configuration" do
    it "sees a direct client as itself" do
      expect(resolve(remote_addr: client)).to eq(client)
    end

    it "looks past a private reverse proxy, as Rails always did" do
      expect(resolve(remote_addr: "10.250.3.7", forwarded_for: client)).to eq(client)
    end

    # Carrier-grade NAT is not routable, so it is never a visitor — only platform
    # plumbing. Rails omits it because RFC 6598 postdates its list. This is the
    # shape that produced "Unknown" for every country rather than a wrong one.
    it "looks past a carrier-grade NAT hop" do
      expect(resolve(remote_addr: "100.64.0.5", forwarded_for: "#{client}, 100.64.0.5"))
        .to eq(client)
    end

    it "looks past an IPv6 unique-local hop" do
      expect(resolve(remote_addr: "fd12:3456::1", forwarded_for: "#{client}, fd12:3456::1"))
        .to eq(client)
    end

    # Both are unconditional, because neither can ever be a real visitor.
    it "trusts the platform-internal ranges by default" do
      expect(TrustedProxies.list).to include(IPAddr.new("100.64.0.0/10"), IPAddr.new("fd00::/8"))
    end
  end

  # Everything above builds its own middleware, which would still pass if the
  # initializer set the config too late for the real stack to see it. This asserts
  # the running application resolves the chain, through its own middleware, on a
  # real request.
  describe "the application's own middleware", type: :request do
    it "was configured with the list" do
      expect(Rails.application.config.action_dispatch.trusted_proxies)
        .to include(IPAddr.new("100.64.0.0/10"))
    end

    it "resolves a real request past a platform NAT hop" do
      get "/up", headers: { "REMOTE_ADDR" => "100.64.0.5",
                            "HTTP_X_FORWARDED_FOR" => "#{client}, 100.64.0.5" }

      expect(request.remote_ip).to eq(client)
    end
  end

  describe "behind Cloudflare" do
    before { allow(TrustedProxies).to receive(:cloudflare?).and_return(true) }

    let(:trusted) { TrustedProxies.list }

    it "looks past Cloudflare's public edge to the visitor" do
      expect(resolve(remote_addr: "10.250.3.7",
                     forwarded_for: "#{client}, #{cloudflare}", trusted: trusted))
        .to eq(client)
    end

    it "handles Cloudflare and a platform NAT hop together" do
      expect(resolve(remote_addr: "100.64.0.5",
                     forwarded_for: "#{client}, #{cloudflare}, 100.64.0.5", trusted: trusted))
        .to eq(client)
    end

    # Cloudflare appends the connecting address to whatever the client sent, so a
    # forged entry lands to the LEFT of the real one. Trusting the range rather
    # than believing a header is what makes the forgery inert.
    it "ignores a forged X-Forwarded-For entry from the client" do
      expect(resolve(remote_addr: "10.250.3.7",
                     forwarded_for: "8.8.8.8, #{client}, #{cloudflare}", trusted: trusted))
        .to eq(client)
    end

    it "resolves the visitor's country rather than the edge's" do
      skip "no GeoIP database in this environment" unless Ingest::Geolocation.available?

      ip = resolve(remote_addr: "10.250.3.7",
                   forwarded_for: "#{client}, #{cloudflare}", trusted: trusted)

      expect(Ingest::Geolocation.country_code(ip)).to eq("CA")
      # What it reported before the fix, for every visitor on earth.
      expect(Ingest::Geolocation.country_code(cloudflare)).to eq("US")
    end

    it "loads the published ranges" do
      expect(TrustedProxies.cloudflare_ranges).to include(IPAddr.new("172.64.0.0/13"))
    end
  end

  # Off by default, and deliberately so: Cloudflare's ranges are also the exit
  # addresses of Cloudflare WARP. On an install that is NOT behind Cloudflare,
  # trusting them would discard the true address of every WARP user.
  it "does not trust Cloudflare unless asked" do
    allow(TrustedProxies).to receive(:cloudflare?).and_return(false)
    expect(TrustedProxies.cloudflare_ranges).to be_empty
  end

  describe "the consequence that matters most" do
    # Two people behind the same edge must not become one visitor.
    it "keeps visitors distinct when they share a proxy" do
      allow(TrustedProxies).to receive(:cloudflare?).and_return(true)
      site = create(:site)

      hashes = ["24.48.0.1", "24.48.0.2"].map do |visitor_ip|
        ip = resolve(remote_addr: "10.250.3.7", forwarded_for: "#{visitor_ip}, #{cloudflare}")
        Ingest::Identifier.new(site_id: site.id, ip: ip, user_agent: "UA").call.visitor_hash
      end

      expect(hashes.uniq.size).to eq(2)
    end

    # The same two people, resolved the broken way, are indistinguishable. This is
    # what the numbers on the live dashboard were made of.
    it "collapses them into one when the proxy address is used" do
      site = create(:site)

      hashes = ["24.48.0.1", "24.48.0.2"].map do |_visitor_ip|
        Ingest::Identifier.new(site_id: site.id, ip: cloudflare, user_agent: "UA").call.visitor_hash
      end

      expect(hashes.uniq.size).to eq(1)
    end
  end

  describe "TRUSTED_PROXY_RANGES parsing" do
    it "accepts comma or whitespace separated CIDRs" do
      expect(TrustedProxies.parse("10.0.0.0/8, 1.2.3.4  fd00::/8").size).to eq(3)
    end

    it "ignores an empty setting" do
      expect(TrustedProxies.parse(nil)).to be_empty
      expect(TrustedProxies.parse("")).to be_empty
    end

    # A silently dropped range restores the bug, and the bug is invisible from
    # inside the application — so a typo has to stop boot rather than be skipped.
    it "refuses to start on a malformed range" do
      expect { TrustedProxies.parse("10.0.0.0/8, not-an-ip") }
        .to raise_error(/not a valid CIDR/)
    end
  end
end
