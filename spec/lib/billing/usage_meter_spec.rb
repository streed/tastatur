require "rails_helper"

RSpec.describe Billing::UsageMeter do
  let(:account) { create(:account) }

  def ttl_for(at: Time.current)
    REDIS_POOL.with { |redis| redis.ttl(described_class.key(account.id, at)) }
  end

  describe "the period" do
    # The window is the UTC calendar month, not the subscription's billing period.
    # The free plan has no billing period at all, so a period-aligned window would
    # need two implementations and the free one would be arbitrary — and a calendar
    # month is hour-aligned, which is what events_by_hour buckets require.
    it "is the UTC calendar month, so a month boundary starts a new counter" do
      july = Time.utc(2026, 7, 31, 23, 30)
      august = Time.utc(2026, 8, 1, 0, 30)

      expect(described_class.period_key(july)).to eq("202607")
      expect(described_class.period_key(august)).to eq("202608")

      described_class.record(account.id, at: july)

      expect(described_class.used(account.id, at: july)).to eq(1)
      expect(described_class.used(account.id, at: august)).to eq(0)
    end

    it "reports the month's boundaries in UTC" do
      from, to = described_class.period_bounds(Time.utc(2026, 7, 15, 12))

      expect(from).to eq(Time.utc(2026, 7, 1))
      expect(to).to eq(Time.utc(2026, 8, 1))
    end
  end

  describe ".record" do
    it "counts up and returns the running total" do
      expect(described_class.record(account.id)).to eq(1)
      expect(described_class.record(account.id)).to eq(2)
      expect(described_class.used(account.id)).to eq(2)
    end

    it "reads zero for an account that has sent nothing" do
      expect(described_class.used(account.id)).to eq(0)
    end

    # The TTL is issued only on the first event of the month, so the steady-state
    # cost on the hottest path in the application really is one Redis command.
    # Asserting it by squashing the TTL and showing a later increment does not
    # restore it — a `record` that re-issued EXPIRE every time would double the
    # traffic to re-assert a value that has not changed.
    it "sets the expiry once rather than on every event" do
      described_class.record(account.id)
      expect(ttl_for).to be_within(60).of(described_class::TTL.to_i)

      REDIS_POOL.with { |redis| redis.expire(described_class.key(account.id), 120) }
      described_class.record(account.id)

      expect(ttl_for).to be <= 120
    end
  end

  describe ".repair" do
    # UPWARD ONLY, and this is the example that matters most in the file.
    #
    # The counter counts events received; the aggregate counts events stored; the
    # first is always at least the second, because refused and buffer-lost events
    # are in one and not the other. So a counter below the stored total is drift to
    # be repaired, and a counter above it is the truth. Lowering it would hand back
    # quota that was genuinely consumed — and would do so every hour, letting an
    # account parked at its limit through another hour of events, forever.
    it "raises a counter that has fallen behind the database" do
      described_class.record(account.id, count: 10)

      expect(described_class.repair(account.id, recorded: 400)).to eq(400)
      expect(described_class.used(account.id)).to eq(400)
    end

    it "leaves a counter that is ahead of the database alone" do
      described_class.record(account.id, count: 500)

      expect(described_class.repair(account.id, recorded: 400)).to eq(500)
      expect(described_class.used(account.id)).to eq(500)
    end

    it "does nothing when the two already agree" do
      described_class.record(account.id, count: 400)

      expect { described_class.repair(account.id, recorded: 400) }
        .not_to change { described_class.used(account.id) }
    end

    # INCRBY rather than SET, which only shows up in the race the repair is exposed
    # to: ingest keeps incrementing while the reconciler is deciding what to add.
    # The hook below lands an event in exactly that window — after the current total
    # is read and before the correction is applied. With INCRBY the event survives;
    # a SET of the freshly computed total would silently discard it.
    it "does not overwrite an event that lands mid-repair" do
      described_class.record(account.id, count: 10)
      key = described_class.key(account.id)

      allow_any_instance_of(Redis).to receive(:get).and_wrap_original do |original, *args|
        value = original.call(*args)
        REDIS_POOL.with { |redis| redis.incrby(key, 5) }
        value
      end

      expect(described_class.repair(account.id, recorded: 400)).to eq(405)
    end

    it "gives a repaired counter an expiry, since it may not have existed" do
      described_class.repair(account.id, recorded: 250)

      expect(described_class.used(account.id)).to eq(250)
      expect(ttl_for).to be_within(60).of(described_class::TTL.to_i)
    end
  end

  # The prefix has to be in the spec-suite reset list or counters survive between
  # examples and between whole suite runs — with a 62-day TTL, keyed by an account
  # id that `TRUNCATE ... RESTART IDENTITY` hands out again. That is not a skewed
  # assertion, it is whether an event gets recorded, so which examples pass would
  # depend on the random seed.
  it "is cleared between examples by spec/support/redis.rb" do
    expect(PREFIXES).to include(described_class::PREFIX)
  end
end
