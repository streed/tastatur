require "rails_helper"

RSpec.describe Ingest::Identifier do
  let(:ua) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0" }

  # Nothing here needs a row — the identifier reads `id` for the HMAC message and
  # the session key, and `timezone` for the salt's rollover.
  let(:site) { build_stubbed(:site, id: 1, timezone: "America/New_York") }

  before { Ingest::SaltStore.destroy_all! }
  after { travel_back }

  def identify(target: site, ip: "203.0.113.10", user_agent: ua)
    described_class.new(site: target, ip: ip, agent: Ingest::UserAgent.parse(user_agent)).call
  end

  describe "the identifier itself" do
    it "is 16 bytes" do
      expect(identify.visitor_hash.bytesize).to eq(16)
    end

    it "is stable for the same person within a salt window" do
      expect(identify.visitor_hex).to eq(identify.visitor_hex)
    end

    it "differs for a different IP" do
      expect(identify(ip: "203.0.113.10").visitor_hex)
        .not_to eq(identify(ip: "198.51.100.4").visitor_hex)
    end

    it "differs for a different browser" do
      firefox = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
      expect(identify(user_agent: ua).visitor_hex).not_to eq(identify(user_agent: firefox).visitor_hex)
    end

    # The point of mixing site_id into the message: one customer must not be
    # able to test a hash against their own traffic to learn whether a visitor
    # had also been to another customer's site. Each site also draws its own
    # salt, so the two hashes are unrelated twice over.
    it "is unlinkable across sites for the same person" do
      expect(identify(target: build_stubbed(:site, id: 1)).visitor_hex)
        .not_to eq(identify(target: build_stubbed(:site, id: 2)).visitor_hex)
    end

    it "uses HMAC rather than a salt-prefixed digest" do
      salt = Ingest::SaltStore.current(site)
      message = "#{site.id}\x00203.0.113.10\x00#{Ingest::UserAgent.parse(ua).fingerprint}"
      expected = OpenSSL::HMAC.digest("SHA256", salt, message).byteslice(0, 16)
      expect(identify.visitor_hash).to eq(expected)
    end

    # The message carries the COARSE user-agent, never the string itself. The
    # verbatim form is not merely redundant here, it was actively wrong in both
    # directions — see Ingest::UserAgent#fingerprint.
    it "does not hash the raw user-agent string" do
      salt = Ingest::SaltStore.current(site)
      verbatim = OpenSSL::HMAC.digest("SHA256", salt, "#{site.id}\x00203.0.113.10\x00#{ua}")
                              .byteslice(0, 16)
      expect(identify.visitor_hash).not_to eq(verbatim)
    end
  end

  # The user-agent half of the old construction split one person into two on an
  # ordinary software update, and let anyone mint visitors out of thin air.
  describe "coarsening the user agent" do
    # Apple ships the point release in the string; Chrome and Firefox freeze
    # everything below the major version, so this is where the split showed up.
    it "keeps one visitor across an OS point release" do
      before_update = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 " \
                      "(KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1"
      after_update  = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2_1 like Mac OS X) AppleWebKit/605.1.15 " \
                      "(KHTML, like Gecko) Version/17.2.1 Mobile/15E148 Safari/604.1"

      expect(identify(user_agent: before_update).visitor_hex)
        .to eq(identify(user_agent: after_update).visitor_hex)
    end

    it "still separates a major version upgrade" do
      chrome_130 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/130.0.0.0"
      expect(identify(user_agent: chrome_130).visitor_hex).not_to eq(identify(user_agent: ua).visitor_hex)
    end

    # A user-agent is a header the caller picks. Hashed verbatim, one machine
    # sending a random string per request minted an unbounded number of distinct
    # "visitors" on somebody else's dashboard; parsed first, the garbage all
    # lands in the same Unknown bucket.
    it "collapses unparseable strings instead of minting a visitor for each" do
      hashes = 5.times.map { |i| identify(user_agent: "#{SecureRandom.hex(8)}/#{i}").visitor_hex }
      expect(hashes.uniq.size).to eq(1)
    end
  end

  describe "IPv6 normalisation" do
    # RFC 4941 privacy extensions rotate the low 64 bits periodically. Hashing
    # the full address would mint a new "visitor" for the same person several
    # times a day and badly inflate the visitor count.
    it "treats addresses in the same /64 as one visitor" do
      a = identify(ip: "2001:db8:1234:5678:aaaa:bbbb:cccc:dddd")
      b = identify(ip: "2001:db8:1234:5678:1111:2222:3333:4444")
      expect(a.visitor_hex).to eq(b.visitor_hex)
    end

    it "still separates different /64 networks" do
      a = identify(ip: "2001:db8:1234:5678::1")
      b = identify(ip: "2001:db8:1234:9999::1")
      expect(a.visitor_hex).not_to eq(b.visitor_hex)
    end

    it "does not mask IPv4" do
      expect(identify(ip: "203.0.113.10").visitor_hex)
        .not_to eq(identify(ip: "203.0.113.11").visitor_hex)
    end

    it "survives an unparseable address rather than raising" do
      expect { identify(ip: "not-an-ip") }.not_to raise_error
    end
  end

  describe "sessions" do
    it "marks the first event of a visit as the entry" do
      expect(identify.entry?).to be(true)
      expect(identify.entry?).to be(false)
    end

    it "keeps the same session for a returning-within-the-window visitor" do
      expect(identify.session_hex).to eq(identify.session_hex)
    end

    it "starts a new session once the window has elapsed" do
      first = identify
      # The window is a Redis TTL, so expiring the key is exactly what elapsing
      # the timeout does.
      PRIVACY_REDIS_POOL.with { |r| r.del(*r.keys("tastatur:session:*")) }
      expect(identify.session_hex).not_to eq(first.session_hex)
    end
  end

  describe "salt rotation" do
    # 23:59 and 00:01 in the site's own timezone, which is where the rollover now
    # happens. In UTC these are 03:59 and 04:01 — the point being that the moment
    # is a property of the site, not of the server.
    def before_midnight = travel_to(Time.utc(2026, 6, 16, 3, 59))
    def after_midnight  = travel_to(Time.utc(2026, 6, 16, 4, 1))

    # The two properties that have to hold simultaneously, and which naive
    # midnight rotation gets wrong: yesterday must become unlinkable, but a
    # visit in progress must not be cut in half or counted twice.
    it "makes the visitor hash unlinkable across the rotation" do
      before_midnight
      yesterday = identify

      after_midnight
      expect(identify.visitor_hex).not_to eq(yesterday.visitor_hex)
    end

    it "carries an in-flight session across the rotation" do
      before_midnight
      yesterday = identify

      after_midnight
      today = identify

      expect(today.session_hex).to eq(yesterday.session_hex)
      expect(today.entry?).to be(false), "a rotation must not look like a new visit"
    end

    # The rollover follows the SITE's midnight. A site set to UTC and a site set
    # to New York rotate eight hours apart in June, and each one's window matches
    # the day its own dashboard reports on.
    it "does not rotate a site whose local midnight has not arrived" do
      utc_site = build_stubbed(:site, id: 2, timezone: "Etc/UTC")

      before_midnight
      before = identify(target: utc_site)

      after_midnight
      expect(identify(target: utc_site).visitor_hex).to eq(before.visitor_hex),
                                                        "04:01 UTC is the middle of the UTC site's day"
    end

    it "leaves the salt from two days ago unreachable" do
      travel_to(Time.utc(2026, 6, 15, 12))
      two_days_ago = Ingest::SaltStore.current(site)

      travel_to(Time.utc(2026, 6, 16, 12))
      Ingest::SaltStore.current(site)

      travel_to(Time.utc(2026, 6, 17, 12))
      expect(Ingest::SaltStore.current(site)).not_to eq(two_days_ago)
      expect(Ingest::SaltStore.previous(site)).not_to eq(two_days_ago)
    end
  end

  describe "what it does not keep" do
    # A guard against someone later "helpfully" adding the IP to the value
    # object. The whole privacy claim rests on this.
    it "exposes no attribute containing the IP or user agent" do
      identity = identify(ip: "203.0.113.99", user_agent: "SecretAgent/1.0")
      serialised = identity.to_h.inspect

      expect(serialised).not_to include("203.0.113.99")
      expect(serialised).not_to include("SecretAgent")
      expect(identity.to_h.keys).to contain_exactly(:visitor_hash, :session_hash, :new_session)
    end
  end
end
