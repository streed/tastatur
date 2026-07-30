require "rails_helper"

RSpec.describe Ingest::SaltStore do
  # Only #id and #timezone are read, and nothing here needs a row, so the whole
  # file stays off the database.
  def site_in(zone, id: nil)
    build_stubbed(:site, **{ timezone: zone, id: id }.compact)
  end

  let(:site) { site_in("Etc/UTC") }

  # This suite does not call `infer_spec_type_from_file_location!`, so a file here
  # is a plain example group and never runs rspec-rails' Minitest teardown adapter
  # — which is what would otherwise unwind `travel_to`. Almost every example below
  # stands on a specific instant, so unwinding it explicitly is the difference
  # between a local failure and a suite that fails somewhere else entirely.
  after { travel_back }

  def privacy_keys(pattern)
    PRIVACY_REDIS_POOL.with { |redis| redis.keys(pattern) }
  end

  def ttl_of(site, date)
    PRIVACY_REDIS_POOL.with { |redis| redis.ttl(described_class.key_for(site, date)) }
  end

  describe "#current" do
    it "mints a salt on demand" do
      expect(described_class.current(site)).to be_present
    end

    it "returns the same salt for the same site within its local day" do
      expect(described_class.current(site)).to eq(described_class.current(site))
    end

    # Not merely a different hash — a different secret. The HMAC already mixes
    # site_id into the message, so this is defence in depth: one site's salt
    # leaking says nothing at all about another site's traffic.
    it "gives each site its own salt" do
      expect(described_class.current(site_in("Etc/UTC", id: 1)))
        .not_to eq(described_class.current(site_in("Etc/UTC", id: 2)))
    end
  end

  describe "rotation at the site's local midnight" do
    let(:site) { site_in("America/New_York") }

    it "keeps one salt for the whole local day" do
      travel_to(Time.utc(2026, 6, 15, 4, 1))  # 00:01 in New York
      morning = described_class.current(site)

      travel_to(Time.utc(2026, 6, 16, 3, 59)) # 23:59 the same New York day
      expect(described_class.current(site)).to eq(morning)
    end

    it "replaces the salt once local midnight passes" do
      travel_to(Time.utc(2026, 6, 16, 3, 59)) # 23:59 in New York
      yesterday = described_class.current(site)

      travel_to(Time.utc(2026, 6, 16, 4, 1))  # 00:01 in New York
      expect(described_class.current(site)).not_to eq(yesterday)
    end

    it "keeps the outgoing salt reachable as previous" do
      travel_to(Time.utc(2026, 6, 16, 3, 59))
      yesterday = described_class.current(site)

      travel_to(Time.utc(2026, 6, 16, 4, 1))
      expect(described_class.previous(site)).to eq(yesterday)
      expect(described_class.current(site)).not_to eq(yesterday)
    end

    # The rollover follows the site's clock, not the server's. This is the whole
    # point of the change: a reporting day is built in `site.timezone`, so a salt
    # rotating on any other schedule cuts through the middle of a day the customer
    # is being shown, and one person browsing across the cut is counted twice.
    it "rotates two sites at different moments when they are in different zones" do
      auckland = site_in("Pacific/Auckland", id: 11)  # UTC+12 in June
      new_york = site_in("America/New_York", id: 12)  # UTC-4 in June

      travel_to(Time.utc(2026, 6, 15, 11, 0))         # 23:00 in Auckland, 07:00 in New York
      auckland_before = described_class.current(auckland)
      new_york_before = described_class.current(new_york)

      travel_to(Time.utc(2026, 6, 15, 13, 0))         # 01:00 in Auckland, 09:00 in New York
      expect(described_class.current(auckland)).not_to eq(auckland_before)
      expect(described_class.current(new_york)).to eq(new_york_before), "New York is still mid-afternoon"
    end

    # No cron schedule can express this, which is one of the reasons rotation is
    # derived from the clock rather than driven by a job: Kathmandu is UTC+05:45,
    # so its local midnight falls at 18:15 UTC.
    it "handles a zone whose offset is not a whole hour" do
      kathmandu = site_in("Asia/Kathmandu")

      travel_to(Time.utc(2026, 6, 15, 18, 14))
      before = described_class.current(kathmandu)

      travel_to(Time.utc(2026, 6, 15, 18, 16))
      expect(described_class.current(kathmandu)).not_to eq(before)
    end

    it "does not mint a salt for yesterday when there was no traffic" do
      travel_to(Time.utc(2026, 6, 16, 4, 1))

      expect(described_class.previous(site)).to be_nil
      expect(privacy_keys("#{described_class::KEY_PREFIX}*")).to be_empty
    end
  end

  describe "the expiry that destroys a retired salt" do
    # There is no rotation job to overwrite the old value any more, so the TTL is
    # the entire destruction mechanism. A salt written without one would live
    # forever and the unlinkability claim would silently become false.
    it "never writes a salt without an expiry" do
      travel_to(Time.utc(2026, 6, 15, 12))
      described_class.current(site)

      # Redis answers -1 for a key with no expiry, which is exactly what a salt
      # that lives forever looks like, and -2 for a key that is not there.
      expect(ttl_of(site, Date.new(2026, 6, 15))).to be_positive
    end

    it "expires 24 hours after the local day it belongs to ends" do
      travel_to(Time.utc(2026, 6, 15, 15, 0)) # nine hours left in the UTC day
      described_class.current(site)

      expect(ttl_of(site, Date.new(2026, 6, 15))).to be_within(2).of(9.hours.to_i + 24.hours.to_i)
    end

    it "caps the life of any salt at about 48 hours" do
      travel_to(Time.utc(2026, 6, 15, 0, 0))
      described_class.current(site)

      expect(ttl_of(site, Date.new(2026, 6, 15))).to be <= 48.hours.to_i
    end

    # A local day is 23 or 25 hours long on the two changeover dates. Adding a
    # flat 86,400 seconds would retire the salt an hour early or an hour late,
    # which on the short day means the previous salt disappears while sessions
    # opened under it are still being carried across.
    it "measures the local day rather than adding a fixed 24 hours across DST" do
      new_york = site_in("America/New_York")
      travel_to(Time.utc(2026, 3, 8, 5, 0)) # 00:00 EST, the start of a 23-hour day
      described_class.current(new_york)

      expect(ttl_of(new_york, Date.new(2026, 3, 8))).to be_within(60).of(23.hours.to_i + 24.hours.to_i)
    end

    # Exactly two salts per site are reachable at any moment: today's and
    # yesterday's. The day before that is unreachable through this API and its key
    # has already expired.
    it "leaves the salt from two days ago unreachable" do
      travel_to(Time.utc(2026, 6, 14, 12))
      two_days_ago = described_class.current(site)

      travel_to(Time.utc(2026, 6, 15, 12))
      described_class.current(site)

      travel_to(Time.utc(2026, 6, 16, 12))
      expect(described_class.current(site)).not_to eq(two_days_ago)
      expect(described_class.previous(site)).not_to eq(two_days_ago)
    end
  end

  describe "#available?" do
    # Reachability rather than presence: on a quiet instance no site has minted a
    # salt yet, and reporting that as a fault would put a red light on the admin
    # page of every fresh install.
    it "is true with no salt stored at all" do
      expect(privacy_keys("#{described_class::KEY_PREFIX}*")).to be_empty
      expect(described_class).to be_available
    end
  end

  describe "#destroy_all!" do
    before do
      travel_to(Time.utc(2026, 6, 15, 10))
      described_class.current(site_in("Etc/UTC", id: 1))

      travel_to(Time.utc(2026, 6, 16, 10))
      described_class.current(site_in("Etc/UTC", id: 1))       # a second, current salt
      described_class.current(site_in("Pacific/Auckland", id: 2))

      PRIVACY_REDIS_POOL.with do |redis|
        3.times { |i| redis.set("#{Ingest::SessionWindow::KEY_PREFIX}1:abcdef#{i}", "session") }
      end
    end

    it "destroys every site's salts, current and previous alike" do
      expect { described_class.destroy_all! }
        .to change { privacy_keys("#{described_class::KEY_PREFIX}*").size }
        .from(3).to(0)
    end

    # Per site rather than in total, so a sweep that missed one site's keys
    # cannot hide behind the aggregate count above. Asserted on the stored keys
    # because reading a salt back through `current` would mint a fresh one.
    it "leaves no site holding a stored salt" do
      described_class.destroy_all!

      expect(privacy_keys("#{described_class::KEY_PREFIX}1:*")).to be_empty
      expect(privacy_keys("#{described_class::KEY_PREFIX}2:*")).to be_empty
    end

    # The gap this closes. It deleted the salt keys while logging "ALL visitor
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

      expect(described_class.current(site)).to be_present
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
end
