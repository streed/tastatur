require "rails_helper"

RSpec.describe Ingest::SaltStore do
  def privacy_keys(pattern)
    PRIVACY_REDIS_POOL.with { |redis| redis.keys(pattern) }
  end

  describe "#destroy_all!" do
    before do
      described_class.current
      described_class.rotate!
      PRIVACY_REDIS_POOL.with do |redis|
        3.times { |i| redis.set("#{Ingest::SessionWindow::KEY_PREFIX}1:abcdef#{i}", "session") }
      end
    end

    it "destroys both salts" do
      described_class.destroy_all!

      expect(described_class.previous).to be_nil
      expect(privacy_keys("tastatur:salt:previous")).to be_empty
    end

    # The gap this closes. It deleted the two salt keys while logging "ALL visitor
    # salts destroyed", and left every session mapping in place. Those keys are
    # `tastatur:session:<site_id>:<visitor_hash>` — they contain a visitor hash by
    # construction and map it to a live session, which is precisely the linkable
    # state an operator running the purge is trying to remove.
    it "destroys the session map, which is keyed by visitor hash" do
      expect { described_class.destroy_all! }
        .to change { privacy_keys("#{Ingest::SessionWindow::KEY_PREFIX}*").size }
        .from(3).to(0)
    end

    it "leaves nothing behind under either prefix" do
      described_class.destroy_all!

      expect(privacy_keys("tastatur:salt:*")).to be_empty
      expect(privacy_keys("#{Ingest::SessionWindow::KEY_PREFIX}*")).to be_empty
    end

    # `current` mints a fresh salt on demand, so the store is usable immediately
    # afterwards — the purge is not a way to break the installation.
    it "leaves the store working" do
      described_class.destroy_all!

      expect(described_class.current).to be_present
    end

    it "does not touch unrelated keys" do
      PRIVACY_REDIS_POOL.with { |redis| redis.set("tastatur:ingest:pending", "keep me") }

      described_class.destroy_all!

      expect(PRIVACY_REDIS_POOL.with { |redis| redis.get("tastatur:ingest:pending") }).to eq("keep me")
    end
  end

  describe "#pools" do
    # Compared on the resolved URL rather than object identity, because two
    # separately built pools can point at the same server — and sweeping the same
    # server twice is wasted work, while sweeping only one of two real servers
    # leaves salts behind.
    it "sweeps one pool when both constants are the same object" do
      stub_const("PRIVACY_REDIS_POOL", REDIS_POOL)

      expect(described_class.pools.size).to eq(1)
    end

    it "sweeps one pool when the two URLs are identical" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("REDIS_PRIVACY_URL").and_return("redis://x:6379/0")
      allow(ENV).to receive(:[]).with("REDIS_URL").and_return("redis://x:6379/0")

      expect(described_class.pools.size).to eq(1)
    end
  end

  describe "#rotate!" do
    it "keeps the outgoing salt reachable as previous" do
      first = described_class.current
      described_class.rotate!

      expect(described_class.previous).to eq(first)
      expect(described_class.current).not_to eq(first)
    end

    # Two rotations destroy the original entirely, which is what makes data derived
    # from it unlinkable rather than merely pseudonymous.
    it "destroys a salt after the second rotation" do
      first = described_class.current
      described_class.rotate!
      described_class.rotate!

      expect(described_class.previous).not_to eq(first)
      expect(described_class.current).not_to eq(first)
    end
  end
end
