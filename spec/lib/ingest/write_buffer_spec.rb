require "rails_helper"

RSpec.describe Ingest::WriteBuffer do
  # Built as a Ruby symbol rather than written literally, because a real NUL byte
  # in a source file is invisible in review and breaks grep.
  NUL = 0.chr

  let(:site) { create(:site) }

  def row(path:, **overrides)
    {
      occurred_at: Time.current,
      site_id: site.id,
      event_name: "pageview",
      visitor_hash: SecureRandom.bytes(16),
      session_hash: SecureRandom.bytes(16),
      is_entry: true,
      hostname: site.domain,
      path: path,
      referrer_host: nil,
      referrer_source: nil,
      country_code: nil,
      browser: nil,
      browser_version: nil,
      os: nil,
      os_version: nil,
      device_type: nil,
      screen_class: nil,
      revenue_cents: nil,
      currency: nil,
      props: nil
    }.merge(overrides)
  end

  # Pushes a row onto the buffer WITHOUT going through `serialize`, so its scrub is
  # bypassed. This is what a future code path that builds a row by hand looks like,
  # and it is the case the quarantine exists to survive.
  def push_unscrubbed(attributes)
    payload = attributes.merge(
      visitor_hash: attributes[:visitor_hash].unpack1("H*"),
      session_hash: attributes[:session_hash].unpack1("H*"),
      occurred_at: attributes[:occurred_at].utc.iso8601(3)
    )
    REDIS_POOL.with { |redis| redis.rpush(described_class::PENDING_KEY, Oj.dump(payload, mode: :compat)) }
  end

  def stored_paths
    ActiveRecord::Base.connection.select_values(
      "SELECT path FROM events WHERE site_id = #{site.id} ORDER BY path"
    )
  end

  describe "COLUMNS" do
    # The claim this file was named after: the module's comment says a mismatch
    # between COLUMNS and the hypertable is caught here rather than at 3am. For a
    # while that comment was aspirational, because this file did not exist.
    it "matches the events hypertable exactly" do
      actual = ActiveRecord::Base.connection.columns("events").map { |column| column.name.to_sym }

      expect(described_class::COLUMNS.sort).to eq(actual.sort)
    end
  end

  describe "text scrubbing" do
    it "removes NUL bytes, which PostgreSQL text columns cannot hold" do
      result = described_class.serialize(row(path: "/a#{NUL}b"))

      expect(result[:path]).to eq("/ab")
    end

    it "replaces invalid UTF-8 rather than letting libpq reject the whole batch" do
      result = described_class.serialize(row(path: (+"/a\xC3\x28b").force_encoding("UTF-8")))

      expect(result[:path]).to be_valid_encoding
      expect(result[:path]).not_to include(NUL)
    end

    it "scrubs inside props, including keys" do
      result = described_class.serialize(row(path: "/x", props: { "k#{NUL}" => "v#{NUL}w" }))

      expect(result[:props]).to eq("k" => "vw")
    end

    it "truncates a string wider than MAX_TEXT_BYTES" do
      result = described_class.serialize(row(path: "/#{'a' * 9_000}"))

      expect(result[:path].bytesize).to be <= described_class::MAX_TEXT_BYTES
    end

    it "leaves legitimate multi-byte text alone" do
      result = described_class.serialize(row(path: "/über/日本語"))

      expect(result[:path]).to eq("/über/日本語")
    end

    it "keeps control characters PostgreSQL does accept" do
      # Only NUL is structurally impossible; a tab is ordinary data.
      result = described_class.serialize(row(path: "/a\tb"))

      expect(result[:path]).to eq("/a\tb")
    end
  end

  describe "#flush!" do
    it "writes a clean batch" do
      3.times { |i| push_unscrubbed(row(path: "/clean-#{i}")) }

      expect(described_class.flush!).to eq(3)
      expect(described_class.depth).to be_zero
      expect(stored_paths).to eq(%w[/clean-0 /clean-1 /clean-2])
    end

    # The regression this whole mechanism exists for.
    #
    # Before it, a row PostgreSQL structurally cannot store was returned to the
    # shared buffer and re-raised, so the flush job failed, retried, and failed
    # again forever. One event stopped writes for every site on the instance, and
    # the endpoint that accepted it answered 202.
    context "with an unstorable row in the batch" do
      before do
        push_unscrubbed(row(path: "/before"))
        push_unscrubbed(row(path: "/poison", event_name: "bad#{NUL}name"))
        push_unscrubbed(row(path: "/after"))
      end

      it "writes every other row instead of blocking on it" do
        expect(described_class.flush!).to eq(2)
        expect(stored_paths).to eq(%w[/after /before])
      end

      it "drains the buffer rather than leaving the poison row on it" do
        described_class.flush!

        expect(described_class.depth).to be_zero
      end

      it "sets the offending row aside so it can be looked at" do
        expect { described_class.flush! }.to change { described_class.quarantine_depth }.by(1)
      end

      it "does not raise" do
        expect { described_class.flush! }.not_to raise_error
      end
    end

    it "isolates a revenue value too large for the int4 column" do
      # Reachable without hostility: a purchase in a minor-unit currency such as
      # IDR or VND can exceed 2^31-1.
      push_unscrubbed(row(path: "/ok"))
      push_unscrubbed(row(path: "/overflow", revenue_cents: 3_000_000_000, currency: "IDR"))

      expect(described_class.flush!).to eq(1)
      expect(described_class.depth).to be_zero
      expect(stored_paths).to eq(%w[/ok])
    end

    it "finds several unstorable rows in one batch" do
      push_unscrubbed(row(path: "/good-1"))
      push_unscrubbed(row(path: "/bad-1", event_name: "x#{NUL}"))
      push_unscrubbed(row(path: "/good-2"))
      push_unscrubbed(row(path: "/bad-2", revenue_cents: 3_000_000_000, currency: "IDR"))
      push_unscrubbed(row(path: "/good-3"))

      expect(described_class.flush!).to eq(3)
      expect(described_class.depth).to be_zero
      expect(described_class.quarantine_depth).to eq(2)
    end

    # The other half of the contract. Quarantining is only safe because it is
    # reserved for failures that are a property of the data; a database that is
    # merely unreachable must not cost a single event.
    context "when the database is transiently unavailable" do
      before do
        2.times { |i| push_unscrubbed(row(path: "/transient-#{i}")) }
        allow(described_class).to receive(:insert_all).and_raise(ActiveRecord::ConnectionFailed)
      end

      it "raises so the job retries" do
        expect { described_class.flush! }.to raise_error(ActiveRecord::ConnectionFailed)
      end

      it "returns every event to the buffer rather than quarantining it" do
        suppress(ActiveRecord::ConnectionFailed) { described_class.flush! }

        expect(described_class.depth).to eq(2)
        expect(described_class.quarantine_depth).to be_zero
      end
    end
  end
end
