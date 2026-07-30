require "rails_helper"

RSpec.describe Ingest::Identifier do
  let(:ua) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0" }

  before { Ingest::SaltStore.destroy_all! }

  def identify(site_id: 1, ip: "203.0.113.10", user_agent: ua)
    described_class.new(site_id: site_id, ip: ip, user_agent: user_agent).call
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

    it "differs for a different user agent" do
      expect(identify(user_agent: "A").visitor_hex).not_to eq(identify(user_agent: "B").visitor_hex)
    end

    # The point of mixing site_id into the message: one customer must not be
    # able to test a hash against their own traffic to learn whether a visitor
    # had also been to another customer's site.
    it "is unlinkable across sites for the same person" do
      expect(identify(site_id: 1).visitor_hex).not_to eq(identify(site_id: 2).visitor_hex)
    end

    it "uses HMAC rather than a salt-prefixed digest" do
      salt = Ingest::SaltStore.current
      expected = OpenSSL::HMAC.digest("SHA256", salt, "1\x00203.0.113.10\x00#{ua}")
                              .byteslice(0, 16)
      expect(identify.visitor_hash).to eq(expected)
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
    # The two properties that have to hold simultaneously, and which naive
    # midnight rotation gets wrong: yesterday must become unlinkable, but a
    # visit in progress must not be cut in half or counted twice.
    it "makes the visitor hash unlinkable across the rotation" do
      before_rotation = identify
      Ingest::SaltStore.rotate!
      expect(identify.visitor_hex).not_to eq(before_rotation.visitor_hex)
    end

    it "carries an in-flight session across the rotation" do
      before_rotation = identify
      Ingest::SaltStore.rotate!
      after = identify

      expect(after.session_hex).to eq(before_rotation.session_hex)
      expect(after.entry?).to be(false), "a rotation must not look like a new visit"
    end

    it "destroys the salt from two rotations ago" do
      first = Ingest::SaltStore.current
      Ingest::SaltStore.rotate!
      expect(Ingest::SaltStore.previous).to eq(first)

      Ingest::SaltStore.rotate!
      expect(Ingest::SaltStore.previous).not_to eq(first)
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
